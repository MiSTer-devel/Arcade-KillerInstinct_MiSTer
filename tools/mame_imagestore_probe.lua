-- What does real KI actually STORE at 0x88000000, and from where?
--
-- V0.77 measured our core's whole chain for that one word and found the break
-- at the very first link:
--
--   IL 001DE000   what the CPU stored        (last store before the handoff)
--   WB 001FF000   what the cache wrote back
--   FD 001FF000   what memory returned on the instruction fill
--   O0 001FF000   what the CPU decoded
--   IC 02 0F 01 01   two stores, mask 0F, one write-back, one fill
--
-- WB/FD/O0 agree, so memory and the instruction path are faithful, and the
-- data cache is cleared in simulation for every path this could have used
-- (fill, displacement write-back, and dirty-on-store). Two things are left
-- unexplained and this probe answers both against real hardware:
--
--   1. Neither stored value is 0A00006E, which is what real KI has there
--      (tools/mame_handoff_probe.lua, handoff.asm). So what DOES real KI
--      store, how many times, and with what width?
--   2. The PC that performs the store. Same PC as ours means the decompressor
--      is executing the right routine and being fed wrong input; a different
--      PC means control flow diverged well before this and the stored value
--      is a symptom rather than the fault.
--
-- TWO MEASURED CONSTRAINTS SHAPE THIS PROBE, and both cost an attempt:
--
--   * A Lua memory write tap on 0x08000000 installs cleanly and NEVER FIRES.
--     kinst registers its RAM as fastram in the MIPS3 DRC, which bypasses the
--     memory system entirely - the same reason the debugger's `dump` returns
--     FFFFFFFF for RAM while `dasm` reads it correctly. Watchpoints do work,
--     because the DRC checks for them.
--   * A watchpoint's only reporting verb is printf, which goes to the
--     debugger console, and `logfile` is not a command in MAME 0.288. So the
--     console log has to be drained from Lua and written out here.
--
-- On the "frame notifier stops being called partway through boot" that the
-- earlier probes in this directory both record: it does not. Instrumenting it
-- shows KI boots at about NINE emulated frames per second under a watchpoint,
-- so -seconds_to_run 45 reaches only a few hundred frames and a probe waiting
-- on a late event simply has not got there yet. Budget emulated seconds by the
-- event, not by wall time, and drain periodically as well as at stop.
--
-- Other constraints, inherited:
--   * -debug is needed for manager.machine.debugger to exist, but on its own
--     it opens the GUI and starts the machine PAUSED. Pair it with
--     -debugger none.
--   * Do NOT soft-reset to arm earlier: that re-runs the autoboot script,
--     which re-arms and resets again, and the probe never terminates.
--
-- Run from the workspace root:
--   mame kinst -rompath games \
--        -autoboot_script KillerInstinct_MiSTer/tools/mame_imagestore_probe.lua \
--        -window -nomaximize -skip_gameinfo -nothrottle -debug -debugger none \
--        -seconds_to_run 45
--
-- Produces KillerInstinct_MiSTer/imagestore.txt.

local OUT = "KillerInstinct_MiSTer/imagestore.txt"

local cpu, debugger
local frame = 0
local armed = false

local function flush_log(reason)
    local out = io.open(OUT, "w")
    if not out then return end
    out:write("# writes to 0x88000000..0x88000007 on real KI\n")
    out:write("# " .. reason .. " at frame " .. frame .. "\n")
    if debugger then
        local log = debugger.consolelog
        out:write("# console lines: " .. #log .. "\n")
        for i = 1, #log do
            out:write(log[i] .. "\n")
        end
    else
        out:write("# no debugger - was -debug passed?\n")
    end
    out:close()
end

-- KEEP THE SUBSCRIPTION ALIVE.
--
-- emu.add_machine_*_notifier returns a subscription object, and when that
-- object is garbage collected the notifier is silently unregistered. Every
-- probe in tools/ discarded it, which is why all of them recorded that "the
-- frame notifier stops being called partway through boot" - it was not the
-- machine resetting, it was Lua's collector, firing at whatever moment suited
-- it. Holding the handles at file scope keeps them registered for the whole
-- run, which is what makes draining the log at stop time work at all.
local subs = {}

subs.frame = emu.add_machine_frame_notifier(function()
    frame = frame + 1

    if not armed then
        cpu = manager.machine.devices[":maincpu"]
        debugger = manager.machine.debugger
        if not debugger then return end
        debugger.visible_cpu = cpu
        armed = true

        -- Every write to the first eight bytes of the decompressed image:
        -- the jump and its delay slot. wpdata is the value written, wpsize
        -- its width, pc the instruction that wrote it.
        debugger:command(
            'wpset 0x88000000,8,w,1,{' ..
            'printf "STORE pc=%08X addr=%08X size=%d data=%08X",pc,wpaddr,wpsize,wpdata;' ..
            'g}')
        -- The handoff itself, so the log ends with the state the stores were
        -- building toward.
        debugger:command(
            'bpset 0x88000000,1,{' ..
            'printf "HANDOFF pc=%08X ra=%08X s6=%08X",pc,ra,s6;' ..
            'g}')
        print("KI_STORE watchpoint armed on 0x88000000..07")
        return
    end

    -- Flush periodically as well as at stop: if the notifier dies partway
    -- through, whatever it managed to write still lands on disk.
    if frame % 60 == 0 then
        print(string.format("KI_STORE tick f=%d lines=%d", frame,
                            debugger and #debugger.consolelog or -1))
    end
    if frame % 20 == 0 then
        local ok, err = pcall(flush_log, "periodic")
        if not ok then
            print("KI_STORE flush error: " .. tostring(err))
        end
    end
end)

subs.stop = emu.add_machine_stop_notifier(function()
    flush_log("machine stopped")
    print("KI_STORE log written to " .. OUT)
end)
