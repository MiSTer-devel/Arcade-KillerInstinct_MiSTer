-- Does real KI2 take a TLB store exception at 8801BA68, and what is it storing to?
--
-- V1.22 hardware on kinst2:
--
--   RR : BFC00200   the TLB REFILL vector, BEV = 1
--   CS : 0000000C   ExcCode = 3 = TLBS, a TLB miss on a store
--   DO : AD090170   sw $t1,0x170($t0)
--   RL : 8801BA68
--   AC : 00000000   no ATA command has ever been issued
--
-- A store, a store-TLB exception code and the TLB refill vector all agree, so
-- the CPU took this deliberately. A TLB refill exception is NORMAL on MIPS -
-- the handler fills the entry and returns - so the question is not why it
-- happened but whether our TLB and the ROM handler complete it.
--
-- Three things this answers, in order of value:
--
--   1. `$t0` at 8801BA68. The opcode gives the offset, 0x170, but not the base,
--      and the base decides the REGION. Below 0x80000000, or 0xC0000000 and
--      above, is mapped and a TLB exception is legitimate. KSEG0/KSEG1 are
--      unmapped and one would be our bug.
--   2. Whether REAL KI2 takes the exception at all. If MAME reaches 8801BA68
--      without vectoring to BFC00200, our TLB is deciding differently. If MAME
--      takes it too, the exception is expected and the fault is in how we
--      complete it.
--   3. A disassembly of 88010000-8801FFFF, which the tree does not have -
--      ki2ram.asm starts at 88020000, so the faulting instruction cannot
--      currently be read at all.
--
-- Three traps this file exists to avoid, all of which cost a run when the KI1
-- timeout probe was written:
--
--   * emu.add_machine_*_notifier returns a subscription that MUST be held, or
--     the notifier is cancelled at the next GC and the probe goes silent -
--     which is indistinguishable from "the event never happened".
--   * MAME's debugger parses numeric literals as HEX. Frame counts printed
--     through it are hex, not decimal.
--   * cpu.debug:bpset(addr) with no condition or action CRASHES MAME with an
--     access violation. Use debugger:command("bpset ...").
--
-- Every debugger call is pcall-wrapped because an error raised inside a MAME
-- notifier is swallowed and stops the notifier.
KI2_SUBS = {}

local cpu, debugger
local frame = 0
local logged = 0
local installed = false

local FRAMES = 3600
local FAULT_PC = 0x8801BA68
local TLB_VECTOR = 0xBFC00200

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
        print("KI2 " .. log[logged])
    end
end

local function cmd(text)
    if not debugger then return false end
    local ok, err = pcall(function() debugger:command(text) end)
    if not ok then
        print("KI2 COMMAND FAILED: " .. text .. " -> " .. tostring(err))
    end
    return ok
end

local function install()
    if installed or not debugger then return end
    installed = true

    cmd("temp0=0")   -- times 8801BA68 executed
    cmd("temp1=0")   -- times the TLB refill vector executed
    cmd("temp2=0")   -- prints emitted from the fault site

    -- THE measurement. $t0 names the region.
    --
    -- ONE breakpoint, counting and printing together. Two breakpoints at the
    -- SAME address does not work: the first one's action ends in `g`, which
    -- resumes execution before the second is ever evaluated, so the second
    -- silently never fires. The first version of this probe split them and got
    -- a count with no register values - and the KI1 timeout probe has the same
    -- construct at 8802DBC0, which is why its WAIT1 line never appeared.
    cmd('bpset 0x8801ba68,1,{temp0=temp0+1;' ..
        'printf "FAULT #%d t0=%08X t1=%08X addr=%08X",temp0,t0,t1,t0+0x170;g}')

    -- Does real KI2 vector here at all? If this stays at zero while temp0
    -- climbs, MAME completes the store without a TLB exception and our TLB is
    -- deciding differently.
    cmd('bpset 0xbfc00200,1,{temp1=temp1+1;g}')

    cmd("bplist")
    cmd("go")
    drain()
    print("KI2 breakpoints installed")
end

KI2_SUBS[#KI2_SUBS + 1] = emu.add_machine_reset_notifier(function()
    attach()
    install()
    print("KI2 reset")
end)

KI2_SUBS[#KI2_SUBS + 1] = emu.add_machine_frame_notifier(function()
    attach()
    install()
    frame = frame + 1
    if not debugger then return end
    drain()

    -- The gap the tree cannot read. Taken once, late enough that the region is
    -- decompressed. dasm writes to a file, so this survives the run.
    if frame == 1800 then
        -- Path is relative to MAME's own working directory, not the project.
        cmd('dasm ../KillerInstinct_MiSTer/ki2ram_low.asm,0x88010000,0x10000')
        print("KI2 dumped 88010000-8801FFFF to ki2ram_low.asm")
        drain()
    end

    if frame % 600 == 0 then
        cmd('printf "mark pc=%08X faults=%d tlbvec=%d",pc,temp0,temp1')
        drain()
    end

    if frame >= FRAMES then
        cmd('printf "FINAL faultsite=%d tlbvector=%d",temp0,temp1')
        drain()
        print("KI2 done after " .. frame .. " frames")
        manager.machine:exit()
    end
end)
