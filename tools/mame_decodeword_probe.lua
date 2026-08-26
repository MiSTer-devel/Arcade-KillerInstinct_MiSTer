-- Real KI's 24 decode-word pointers, and its first output words.
--
-- V0.79 measured, on hardware:
--
--   WA 087FFF50   the address the first decode word went to - so t3 really is
--                 0x887FFF10 and the region is where it was inferred to be
--   W0 BFC00FDE   the first three decode words. NOT zero: they are ROM
--   W1 BFC01087   pointers, and they look healthy. W0 sits just past
--   W2 BFC01148   BFC00FD0, which V0.67 verified as the reader's correct
--                 initial source pointer, and the deltas +0xA9 / +0xC1 match
--                 the loop's `addu v0,v0,at` running sum
--
-- So the decompressor keeps a separate bitstream per instruction field and
-- these are their start pointers. They are built and they are plausible. That
-- refutes the V0.79 hypothesis, which was that the four instruction fields
-- decoding to zero did so because these words were never built.
--
-- What is still true (V0.78): the output word is assembled as
--
--   t0 = (t1<<26)|(t5<<21)|(t6<<16)|(t7<<11)|(s3<<6)|t4
--         opcode    rs       rt       rd      shamt  funct
--
-- and ours come out 001FF000 then 001DE000, i.e. opcode/rs/shamt/funct all
-- zero while rt/rd walk 31, 30, 29, 28 - the permutation tables' untouched
-- initial contents, read in order.
--
-- So the question is whether our POINTERS are correct, not whether they exist.
-- This probe reads real KI's, and its first output words for comparison:
--
--   9FC00770  sw v0,0(a2)   the decode-word fill loop - print a2 and v0
--   9FC00C68  sw t0,0(a3)   the output store        - print a3 and t0
--
-- Both are EXECUTION breakpoints. That matters: kinst registers its RAM as
-- fastram in the MIPS3 DRC, so Lua write taps never fire and debugger
-- watchpoints never trigger on RAM (see tools/mame_imagestore_probe.lua, which
-- is kept only to record that dead end). Execution breakpoints are unaffected,
-- which is why tools/mame_handoff_probe.lua worked.
--
-- These events also happen EARLY, in the first decompression pass, rather than
-- at the handoff - so this needs far less emulated time than the handoff probe.
-- KI boots at roughly nine emulated frames per second under the debugger, so
-- budget emulated seconds by the event.
--
-- Run from the workspace root:
--   mame kinst -rompath games \
--        -autoboot_script KillerInstinct_MiSTer/tools/mame_decodeword_probe.lua \
--        -window -nomaximize -skip_gameinfo -nothrottle -debug -debugger none \
--        -seconds_to_run 40
--
-- Produces KillerInstinct_MiSTer/decodewords.txt.

local OUT = "KillerInstinct_MiSTer/decodewords.txt"

local cpu, debugger
local frame = 0
local armed = false

local function flush_log(reason)
    local out = io.open(OUT, "w")
    if not out then return end
    out:write("# real KI: decode words at 9FC00770, output words at 9FC00C68\n")
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

-- Hold the subscriptions at file scope. emu.add_machine_*_notifier returns a
-- subscription object and collecting it unregisters the notifier.
local subs = {}

-- ARM FROM THE RESET NOTIFIER, NOT THE FRAME NOTIFIER.
--
-- The frame notifier first fires roughly 13 million CPU cycles in, by which
-- point the first decompression pass is already ~350 output words along - the
-- run that armed there caught OUT lines at s5=3 but never the s5=3 decode-word
-- loop, so the values could only be compared pass-for-pass against the wrong
-- pass. MAME's own -debugscript would arm before the machine runs, but it is
-- not processed when -debugger none is given: that run set three breakpoints,
-- not six. The reset notifier fires before the CPU executes and is not subject
-- to either problem.
local function arm()
    if armed then return end
    cpu = manager.machine.devices[":maincpu"]
    debugger = manager.machine.debugger
    if not debugger then return end
    debugger.visible_cpu = cpu
    armed = true

    -- temp0/temp1 cap the hit counts so the log stays readable and the
    -- emulation is not slowed to a crawl by thousands of breaks. The
    -- decode-word loop runs 24 times per pass; the output store runs
    -- once per decompressed instruction, so only the first few matter.
    debugger:command('temp0=0')
    debugger:command('temp1=0')
    -- Tag everything with s5, the pass counter. Real KI enters with
    -- s5 = 3 and counts down, and MAME's autoboot script cannot arm
    -- before the first pass has already started - even with
    -- -autoboot_delay 0 the first frame is ~13 million CPU cycles in, and
        -- the run without it produced OUT lines BEFORE any DW line, which is
    -- impossible within one pass. So the pass has to be labelled rather
    -- than inferred from ordering.
    debugger:command(
        'bpset 0x9FC00744,1,{' ..
        'printf "PASS s5=%d t2=%08X a3=%08X s6=%08X t3=%08X",s5,t2,a3,s6,t3;' ..
        'g}')
    debugger:command(
        'bpset 0x9FC00770,temp0<26,{' ..
        'printf "DW %d s5=%d a2=%08X v0=%08X",temp0,s5,a2,v0;' ..
        'temp0=temp0+1;g}')
    debugger:command(
        'bpset 0x9FC00C68,temp1<10,{' ..
        'printf "OUT %d s5=%d a3=%08X t0=%08X",temp1,s5,a3,t0;' ..
        'temp1=temp1+1;g}')
    print("KI_DW breakpoints armed on 9FC00770 and 9FC00C68")
end

subs.reset = emu.add_machine_reset_notifier(arm)

subs.frame = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    arm()

    if frame % 20 == 0 then
        local ok, err = pcall(flush_log, "periodic")
        if not ok then print("KI_DW flush error: " .. tostring(err)) end
    end
    if frame % 60 == 0 then
        print(string.format("KI_DW tick f=%d lines=%d", frame,
                            debugger and #debugger.consolelog or -1))
    end
end)

subs.stop = emu.add_machine_stop_notifier(function()
    flush_log("machine stopped")
    print("KI_DW log written to " .. OUT)
end)
