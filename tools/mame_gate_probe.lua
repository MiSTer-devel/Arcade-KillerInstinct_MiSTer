-- What does t2 hold at EVERY crossing of the boot gate on real KI?
--
-- This exists to test an assumption nobody has checked. Our hardware shows
-- t2 = 0x00032CB0 at the FIRST crossing - correct, and matched independently by
-- tools/bitreader_model.py and by tb_ki_cpu_system_boot - but 0x087FFF10 at a
-- later one. That later value has been treated as garbage because it is
-- implausible as a byte count and because it happens to equal the permutation
-- table's physical address.
--
-- Nothing has verified that. bitreader_model.py computes only the first few
-- reads: after that the sequence of read(n) calls depends on the decompressor's
-- control flow, which the model does not emulate. The bitstream is COMPRESSED
-- DATA, so a 32-bit field can legitimately hold anything, including something
-- that looks like an address.
--
-- If real KI's later crossings are also large, t2 is not the fault at all and
-- the divergence is upstream in the decompressor, with the reader faithfully
-- returning whatever the stream says at a position we reached differently.
--
-- The gate, from tools/disasm.py:
--
--   9FC00724  jal  9FC00D48        read(32)
--   9FC00728  or   t2,v0,zero      DELAY SLOT - so t2 takes the PREVIOUS
--                                  read(32), the pass byte count, while
--                                  0x88000000 goes on to s6 as a destination
--   9FC0073C  beq  t2,zero,9FC00C74   <- sampled here
--   9FC00C74  addi s5,s5,-1        one pass done
--   9FC00C78  bne  s5,zero,9FC00708 next pass
--
-- Real KI enters with s5 = 3 and t2 counts down ~1,523 per frame from 0x32728,
-- reaching zero near frame 136 - so expect a small number of crossings spread
-- over a few hundred frames.
--
-- Three constraints this project has already learned the hard way:
--   * Reading 64-bit MIPS registers from Lua throws "integer value will be
--     misrepresented". Lua only decides WHEN to act; MAME's own debugger printf
--     formats the registers.
--   * MAME needs -debug for manager.machine.debugger to exist, but plain -debug
--     opens the debugger GUI and starts the machine PAUSED, so the frame
--     notifier never fires. Pair it with -debugger none.
--   * tools/mame_table_init_probe.lua arms via the reset vector and then
--     soft-resets so boot replays with the breakpoint live. Do NOT copy that
--     here: a soft reset RE-RUNS the autoboot script, which re-arms and resets
--     again, and the probe never terminates.
--   * Arm in the RESET notifier, not the frame notifier. The frame-1 notifier
--     fires at the END of frame 1, by which point boot has already crossed the
--     gate once - doing it there reported a first sample of s5 = 2, i.e.
--     crossing #2, and silently lost the one value that is comparable to the
--     model. s5 = 3 on the first sample is the check that nothing was missed.
--
-- Run:
--   mame kinst -rompath games -autoboot_script tools/mame_gate_probe.lua \
--        -window -nomaximize -skip_gameinfo -nothrottle -debug -debugger none \
--        -seconds_to_run 40
--
-- Output lines are prefixed KI_GATE and carry the frame they were drained on.
--
-- MEASURED on real KI (MAME 0.288):
--
--   crossing 1  s5=3  t2=00032CB0  s1=BFC00FDE  v0=88000000
--   crossing 2  s5=2  t2=00051100  s1=BFC1DC07  v0=88033900
--
-- So the pass lengths are 208,048 and 332,032 bytes, and v0 - the destination
-- pointer - advances 211,200 bytes over pass 1, which matches its length. t2 is
-- a segment byte count, exactly as modelled.
--
-- Our hardware shows 0x087FFF10 = 142,606,096, which is 429x real KI's largest
-- and SEVENTEEN TIMES the whole 8 MB of main RAM. It cannot be a legitimate
-- length, so the value really is wrong - the assumption this probe was written
-- to test is confirmed rather than refuted.
--
-- Known limitations, all measured, none affecting the conclusion:
--   * The frame notifier stops being called partway through boot - it printed
--     at f=50, f=100, f=138 and f=150 and then never again while the machine ran
--     on to 44 emulated seconds. Crossing 3 (s5=1) is therefore not captured
--     here. emu.add_machine_stop_notifier does not exist in this build, so a
--     final drain is not available either.
--   * The frame-1 fallback arm misses crossing 1. To capture it, arm via the
--     reset vector instead:
--       bpset 0xBFC00000,1,{bpset 0x9FC0073C,1,{printf ...;g};g}
--     followed by manager.machine:soft_reset(). That WILL loop, because a soft
--     reset re-runs the autoboot script - but it prints crossing 1 on each pass,
--     so killing it after a few seconds and reading the first GATE line works.
--     That is how the crossing-1 line above was taken.

local MAX_CROSSINGS = 60
local LAST_FRAME    = 2000

local cpu, debugger
local frame, logged = 0, 0
local crossings = 0
local stage = 0

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
        local line = log[logged]
        if line:find("GATE") then crossings = crossings + 1 end
        print(string.format("KI_GATE f=%d %s", frame, line))
    end
end

-- Arm at machine reset, NOT in the frame notifier. The frame-1 notifier fires
-- at the END of frame 1, by which point boot has already crossed the gate once:
-- arming there reported a first sample of s5 = 2, i.e. crossing #2. The reset
-- notifier runs before any instruction executes, so s5 = 3 on the first sample
-- confirms nothing was missed.
local function arm(where)
    if stage ~= 0 or not debugger then return end
    stage = 1
    debugger:command(
        'bpset 0x9FC0073C,1,' ..
        '{printf "GATE t2=%08X s5=%08X s0=%08X s1=%08X s2=%08X",' ..
        't2,s5,s0,s1,s2;g}')
    print("KI_GATE armed on 9FC0073C at " .. where)
end

-- manager.machine.debugger is usually still nil this early, so this arm often
-- does nothing and the frame-1 fallback below does the work. It is kept because
-- when it DOES fire it catches crossing #1, and the fallback cannot.
emu.add_machine_reset_notifier(function()
    attach()
    arm("reset")
end)

-- The frame notifier stops being called partway through KI's boot - measured:
-- it printed at f=50, f=100, f=138 and f=150 and then never again, while the
-- machine ran on to 44 emulated seconds. Whatever the cause, anything the
-- breakpoint logs after that point would be stranded in the debugger console
-- and never printed. So drain once more when the machine stops, which does not
-- depend on the frame notifier being alive.
if emu.add_machine_stop_notifier then
    emu.add_machine_stop_notifier(function()
        print("KI_GATE draining at machine stop")
        drain()
        print(string.format("KI_GATE done: %d crossings total", crossings))
    end)
end

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not debugger then return end

    -- Fallback: if the reset notifier could not arm, do it now. This misses
    -- crossing #1 - boot passes the gate before the end of frame 1 - which is
    -- why the first sample's s5 must be checked. s5 = 3 means nothing was
    -- missed; s5 = 2 means this fallback armed and crossing #1 is absent.
    arm("frame 1")

    drain()

    -- Progress, so a long quiet stretch is distinguishable from a wedged run.
    if frame % 50 == 0 then
        print(string.format("KI_GATE f=%d still running, %d crossings so far",
                            frame, crossings))
    end

    -- Stop once the answer is in, so a pass that crosses the gate rapidly
    -- cannot flood the log.
    if crossings >= MAX_CROSSINGS then
        debugger:command('bpclear')
        drain()
        print(string.format("KI_GATE done: %d crossings, stopped at frame %d",
                            crossings, frame))
        manager.machine:exit()
        return
    end

    if frame >= LAST_FRAME then
        debugger:command('bpclear')
        drain()
        print(string.format("KI_GATE done: %d crossings in %d frames",
                            crossings, frame))
        manager.machine:exit()
    end
end)
