-- What does the boot scan actually read?
--
-- The scan at 9FC00CD8 walks a1 = 0x887FFF1C (KSEG0, physical 0x087FFF1C) one
-- byte at a time and exits ONLY when a byte equals a2. Real KI exits within
-- ~20 bytes; ours never does. The data cache has been tested and does not
-- corrupt that buffer, so the question is what the buffer is supposed to
-- contain.
--
-- Memory TAPS do not work here: the kinst driver registers RAM as fastram,
-- which bypasses the memory system, so a write tap on 0x087FFFxx never fires
-- (the earlier ROM tap worked because ROM is not fastram). Direct reads still
-- see the real contents, so this dumps the buffer over time instead of tracing
-- its writer.
--
-- PC is readable from Lua; general-purpose registers are not - they throw
-- "integer value will be misrepresented in lua" when sign-extended.
local cpu
local program
local frame = 0

local BUF_BASE = 0x087fff00
local BUF_LEN  = 0x40

local function attach()
    if program then return end
    cpu = manager.machine.devices[":maincpu"]
    program = cpu.spaces["program"]
end

local function dump(tag)
    local bytes = {}
    local ascii = {}
    for i = 0, BUF_LEN - 1 do
        local b = program:read_u8(BUF_BASE + i) & 0xff
        bytes[#bytes + 1] = string.format("%02X", b)
        if b >= 32 and b < 127 then
            ascii[#ascii + 1] = string.char(b)
        else
            ascii[#ascii + 1] = "."
        end
    end
    for row = 0, (BUF_LEN / 16) - 1 do
        local lo = row * 16 + 1
        print(string.format("KI_BUF %s %08X  %s  |%s|",
            tag, BUF_BASE + row * 16,
            table.concat(bytes, " ", lo, lo + 15),
            table.concat(ascii, "", lo, lo + 15)))
    end
end

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not cpu then return end

    if frame == 2 or frame == 30 or frame == 120 or frame == 300 then
        print(string.format("KI_BUF --- frame %d, pc=%08X ---",
            frame, cpu.state["PC"].value & 0xffffffff))
        dump(string.format("f%03d", frame))
    end

    if frame == 300 then
        manager.machine:exit()
    end
end)
