-- Ground truth for the ATA WRITE SECTORS transaction, taken off real KI.
--
-- The MiSTer core's drive never issues a single sd_wr: the write block never
-- reaches its 256th halfword, so it never completes. That leaves two very
-- different possibilities, and the hardware probe alone cannot separate them:
--
--   a. the host really does write 256 halfwords and the core loses some
--   b. the host abandons the transfer early, for a reason of its own
--
-- The disassembly at 8802D9E8 says the inner loop is
--
--     8802D9F4  lh    $v0,0($t0)
--     8802D9F8  addiu $t0,$t0,2
--     8802D9FC  bne   $t0,$at,0x8802d9f4
--     8802DA00  sh    $v0,0x100($v1)     <- delay slot
--
-- with $at = $t0 + 0x200, so it should be exactly 256 halfword stores per
-- command with no status polling between them. This measures whether that is
-- what the drive actually SEES, and what surrounds it.
--
-- Board I/O is not fastram, so taps work here (unlike RAM).
--
-- Register file: base 0xB0000000 (physical 0x10000000), stride 8.
--   0x100 data    0x110 sector count   0x118 sector number
--   0x120 cyl low 0x128 cyl high       0x130 device/head   0x138 command/status
--   0x170 alternate status (CS1)       0x0A0 dummy read used as a bus sync

local cpu
local program
local frame = 0

local ATA = 0x10000000

-- One entry per command, in issue order.
local commands = {}
local current = nil
local other_writes = {}
tap_error = nil

local function note(fmt, ...)
    print(string.format("ATAW " .. fmt, ...))
end

local function attach()
    if program then return end
    cpu = manager.machine.devices[":maincpu"]
    program = cpu.spaces["program"]

    -- An error thrown inside a tap kills the Lua context silently: the frame
    -- notifier simply stops firing and no report ever appears. Guard both.
    program:install_write_tap(ATA + 0x100, ATA + 0x17f, "ki_ata_w",
        function(offset, data, mask)
          local ok, err = pcall(function()
            local reg = offset & 0xff
            if reg == 0x00 then
                if current then
                    current.data_writes = current.data_writes + 1
                else
                    other_writes[#other_writes + 1] =
                        string.format("data write with no command in flight, pc=%08X",
                                      cpu.state["PC"].value & 0xffffffff)
                end
            elseif reg == 0x38 then
                local value = data & 0xff
                current = {
                    command      = value,
                    data_writes  = 0,
                    data_reads   = 0,
                    status_reads = 0,
                    alt_reads    = 0,
                    frame        = frame,
                    pc           = cpu.state["PC"].value & 0xffffffff,
                    sector_count = other_writes.sector_count,
                    sector       = other_writes.sector,
                    cyl_lo       = other_writes.cyl_lo,
                    cyl_hi       = other_writes.cyl_hi,
                    head         = other_writes.head,
                }
                commands[#commands + 1] = current
            elseif reg == 0x10 then other_writes.sector_count = data & 0xff
            elseif reg == 0x18 then other_writes.sector       = data & 0xff
            elseif reg == 0x20 then other_writes.cyl_lo       = data & 0xff
            elseif reg == 0x28 then other_writes.cyl_hi       = data & 0xff
            elseif reg == 0x30 then other_writes.head         = data & 0xff
            end
          end)
          if not ok and not tap_error then
              tap_error = tostring(err)
          end
          return data
        end)

    program:install_read_tap(ATA + 0x100, ATA + 0x17f, "ki_ata_r",
        function(offset, data, mask)
          local ok, err = pcall(function()
            if not current then return end
            local reg = offset & 0xff
            if     reg == 0x00 then current.data_reads   = current.data_reads + 1
            elseif reg == 0x38 then current.status_reads = current.status_reads + 1
            elseif reg == 0x70 then current.alt_reads    = current.alt_reads + 1
            end
          end)
          if not ok and not tap_error then
              tap_error = tostring(err)
          end
          return data
        end)
end

local function report()
    note("%d commands issued", #commands)
    note("cmd  frame  C/H/S        cnt  datawr  datard  statrd  altrd   pc")
    for index, c in ipairs(commands) do
        note("%02X   %-6d %3d/%2d/%-3d   %-4s %-7d %-7d %-7d %-6d %08X",
             c.command, c.frame,
             (c.cyl_hi or 0) * 256 + (c.cyl_lo or 0),
             (c.head or 0) & 0x0f, c.sector or 0,
             tostring(c.sector_count), c.data_writes, c.data_reads,
             c.status_reads, c.alt_reads, c.pc)
        if index >= 60 then
            note("... %d more", #commands - index)
            break
        end
    end
    for _, line in ipairs(other_writes) do note("%s", line) end
end

emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 1 then print("ATAW probe alive") end
    local ok, err = pcall(attach)
    if not ok then print("ATAW attach failed: " .. tostring(err)) end
    if frame % 120 == 0 then
        print(string.format("ATAW frame %d, %d commands so far%s", frame, #commands,
            tap_error and (" TAP ERROR: " .. tap_error) or ""))
    end
    if frame == 900 then
        local rok, rerr = pcall(report)
        if not rok then print("ATAW report failed: " .. tostring(rerr)) end
        manager.machine:exit()
    end
end)
