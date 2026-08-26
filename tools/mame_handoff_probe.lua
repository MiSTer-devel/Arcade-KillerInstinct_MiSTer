-- What does the decompressed program at 0x88000000 look like on real KI?
--
-- V0.75 measured, on hardware:
--
--   R0 = 88000000    the handoff HAPPENS - execution reaches the decompressed
--                    program at exactly the address the boot ROM jumps to
--   O0 = 001FF000    the opcode fetched there: sll s8,ra,0
--   RP = 88000028    the last pc executed in RAM - ten instructions in
--   RR = BFC00380    the MIPS III GENERAL EXCEPTION vector for Status.BEV = 1
--
-- So the decompressed code runs ten instructions and takes an exception. The
-- question this probe answers is whether the IMAGE is wrong or the execution
-- is: dump what real KI has at 0x88000000 and disassemble it, then compare
-- the first word against our O0 and look at what sits around +0x28.
--
-- If real KI's first word is also 001FF000 the decompressor's output is right
-- at least there, and the fault is ours. If it differs, the decompressed image
-- is wrong and the target becomes the decompressor's output - which nothing in
-- this investigation has examined, because every probe so far is keyed on ROM
-- addresses and blind to code that only exists in RAM.
--
-- Constraints inherited from tools/mame_gate_probe.lua, all measured:
--   * -debug is needed for manager.machine.debugger to exist, but on its own it
--     opens the GUI and starts the machine PAUSED. Pair it with -debugger none.
--   * Do NOT soft-reset to arm earlier: that re-runs the autoboot script, which
--     re-arms and resets again, and the probe never terminates.
--   * The frame notifier stops being called partway through boot, so anything
--     logged after that would be stranded. This probe therefore writes to FILES
--     via the debugger's own dump/dasm commands rather than relying on draining
--     the console.
--
-- Run from the workspace root:
--   mame kinst -rompath games \
--        -autoboot_script KillerInstinct_MiSTer/tools/mame_handoff_probe.lua \
--        -window -nomaximize -skip_gameinfo -nothrottle -debug -debugger none \
--        -seconds_to_run 60
--
-- Produces KillerInstinct_MiSTer/handoff.asm and handoff.txt.

local cpu, debugger
local frame, logged = 0, 0
local armed = false

local function attach()
    if cpu then return end
    cpu = manager.machine.devices[":maincpu"]
    debugger = manager.machine.debugger
    if debugger then debugger.visible_cpu = cpu end
end

local function drain()
    if not debugger then return end
    local log = debugger.consolelog
    while logged < #log do
        logged = logged + 1
        print("KI_HANDOFF f=" .. frame .. " " .. log[logged])
    end
end

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not debugger then return end

    if not armed then
        armed = true
        -- Break the first time the decompressed program is entered, write the
        -- image to disk two ways, report the registers, and continue.
        debugger:command(
            'bpset 0x88000000,1,{' ..
            'dasm KillerInstinct_MiSTer/handoff.asm,0x88000000,0x80;' ..
            'dump KillerInstinct_MiSTer/handoff.txt,0x88000000,0x80,4;' ..
            'printf "HANDOFF pc=%08X ra=%08X sp=%08X s6=%08X",pc,ra,sp,s6;' ..
            'g}')
        drain()
        print("KI_HANDOFF armed on 0x88000000")
        return
    end

    drain()

    if frame % 200 == 0 then
        print(string.format("KI_HANDOFF f=%d still running", frame))
    end
end)
