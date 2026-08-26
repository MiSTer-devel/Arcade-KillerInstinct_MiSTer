-- What is the KI boot ROM doing around 0x9FC00DEC?
--
-- V58 hardware shows the core parked there for 20+ seconds while issuing
-- ~30,000 memory transactions per frame against boot-ROM addresses spread
-- across the whole 512 KiB. This asks real hardware, via MAME, how long the
-- real machine takes to leave that region and what the loop counter in t2 is
-- doing while it is there.
--
-- If real KI passes through in a couple of seconds and ours has not in twenty,
-- the loop is real and we are simply running it far too slowly. If real KI
-- also parks there, it is waiting on something we have not implemented and
-- memory throughput is beside the point.
--
-- Uses add_machine_frame_notifier and plain state reads, matching
-- sim/mame_kinst_probe.lua. The debugger API is deliberately avoided: it
-- throws "integer value will be misrepresented in lua" on this build's 64-bit
-- MIPS registers.
local cpu
local program
local frame = 0

local REGION_LO = 0x9fc00900
local REGION_HI = 0x9fc00f00

local entered = false
local left_frame = -1
local boot_reads = 0
local boot_reads_beyond_32k = 0

local function attach()
    if program then return end
    cpu = manager.machine.devices[":maincpu"]
    program = cpu.spaces["program"]
    -- Every boot-ROM read the CPU makes, and how many land outside the first
    -- 32 KiB - which is exactly the window our M10K mirror covers.
    program:install_read_tap(
        0x1fc00000, 0x1fc7ffff, "ki_bootrom_probe",
        function(offset, data, mask)
            boot_reads = boot_reads + 1
            if (offset & 0x7ffff) >= 0x8000 then
                boot_reads_beyond_32k = boot_reads_beyond_32k + 1
            end
            return data
        end)
end

emu.add_machine_reset_notifier(function()
    attach()
    print("KI_BOOTLOOP reset")
end)

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not cpu then return end

    local pc = cpu.state["PC"].value & 0xffffffff
    local t2 = cpu.state["t2"].value & 0xffffffff
    local s5 = cpu.state["s5"].value & 0xffffffff

    if pc >= REGION_LO and pc <= REGION_HI then
        entered = true
    elseif entered and left_frame < 0 then
        left_frame = frame
        print(string.format(
            "KI_BOOTLOOP left region at frame=%d (%.2f s) PC=%08X t2=%08X s5=%08X",
            frame, frame / 60.0, pc, t2, s5))
    end

    -- v0 is the decompressor's source pointer. Its REGION decides everything:
    -- 0x9Fxxxxxx is KSEG0 and cacheable, so a working data cache should
    -- collapse 32 sequential byte loads into one line fill. 0xBFxxxxxx is
    -- KSEG1 and architecturally UNCACHED, in which case no cache fix applies
    -- and the cost has to come out of the memory path instead.
    local v0 = cpu.state["v0"].value & 0xffffffff
    local s1 = cpu.state["s1"].value & 0xffffffff

    if frame <= 12 or (frame % 60) == 0 then
        local region = "other"
        if (v0 & 0xe0000000) == 0x80000000 then region = "KSEG0-cached"
        elseif (v0 & 0xe0000000) == 0xa0000000 then region = "KSEG1-UNCACHED" end
        print(string.format(
            "KI_BOOTLOOP frame=%4d pc=%08X t2=%08X s5=%08X v0=%08X %s s1=%08X romrd=%d beyond32k=%d",
            frame, pc, t2, s5, v0, region, s1, boot_reads, boot_reads_beyond_32k))
    end
end)
