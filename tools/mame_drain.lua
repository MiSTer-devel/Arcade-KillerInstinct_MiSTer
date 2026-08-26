-- Drain the MAME debugger console to a file. Nothing else.
--
-- Pair this with -debugscript, which is what actually sets the breakpoints.
-- Keeping the two jobs apart matters: an earlier run left the decode-word
-- probe attached alongside a debugscript, so SIX breakpoints were live, the
-- emulation dropped to ~38% speed, and 90 emulated seconds were not enough to
-- reach the handoff at all - the probe's own breakpoints starved the thing it
-- was waiting for.
--
-- Constraints, all measured (see tools/mame_decodeword_probe.lua):
--   * -debugscript is NOT processed under -debugger none. Use the GUI
--     debugger: -debug on its own, and let the script's trailing `go` start
--     the machine.
--   * emu.add_machine_*_notifier returns a subscription object; if it is
--     collected the notifier stops firing. Hold it at file scope.
--   * KI boots at roughly nine emulated frames per second under the debugger,
--     so budget -seconds_to_run by the event, not by wall time.
--
-- Output file is fixed so the callers stay simple:
--   KillerInstinct_MiSTer/mamelog.txt

local OUT = "KillerInstinct_MiSTer/mamelog.txt"

local debugger
local frame = 0

local function flush(reason)
    local out = io.open(OUT, "w")
    if not out then return end
    out:write("# " .. reason .. " at frame " .. frame .. "\n")
    if debugger then
        local log = debugger.consolelog
        out:write("# console lines: " .. #log .. "\n")
        for i = 1, #log do out:write(log[i] .. "\n") end
    else
        out:write("# no debugger - was -debug passed?\n")
    end
    out:close()
end

local subs = {}

subs.frame = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if not debugger then debugger = manager.machine.debugger end
    if frame % 20 == 0 then pcall(flush, "periodic") end
    if frame % 120 == 0 then
        print(string.format("KI_DRAIN f=%d lines=%d", frame,
                            debugger and #debugger.consolelog or -1))
    end
end)

subs.stop = emu.add_machine_stop_notifier(function()
    flush("machine stopped")
    print("KI_DRAIN log written to " .. OUT)
end)
