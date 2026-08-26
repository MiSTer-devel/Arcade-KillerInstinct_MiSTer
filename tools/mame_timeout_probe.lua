-- Does real KI ever take the disk driver's TIMEOUT unwind?
--
-- The three wait routines in the disk driver all give up to the same place:
--
--   8802DBC0  wait for Cause bit 0x0800  (IP3 = irq_ata)
--   8802DBE4  wait for status 0x40 at 0x170($v1)
--   8802DC10  wait for DRQ 0x08 at 0x170($v1)
--       ...all three:  beqz $at,0x8802dc38   when the counter runs out
--
--   8802DC38: jr   $a0        non-local return to the caller's caller
--   8802DC3C: li   $v0,0x100      with 0x100 as the error status
--
-- $a0 is this driver's unwind register - set by `move $a0,$ra` at routine
-- entry (8802D948, 8802D9A8) because the nested jal's clobber $ra - so it
-- should always hold a 0x8802xxxx address. Our core lands in the BOOT ROM from
-- here, and nothing in 384 KiB of game RAM ever loads $a0 with a boot address,
-- so that destination is not designed.
--
-- Two explanations remain and they are NOT the same bug:
--
--   A. the timeout genuinely fires and $a0 is corrupt on our core
--   B. the timeout never fires, and the jump happens at 8802DBCC itself
--      because the fetched INSTRUCTION word is wrong (V0.81 captured
--      O0=0BF000E2 at R0=8802DBCC - the boot ROM's own first word,
--      `j 0xBFC00388`, appearing at a RAM address)
--
-- This probe settles what REAL KI does, which is the half that can be measured
-- offline: if real KI never reaches 8802DC38, then our reaching it at all is
-- already the anomaly and A is about a path that should never run.
--
-- Reading 64-bit MIPS registers straight out of Lua throws "integer value will
-- be misrepresented in lua" for sign-extended values. PC survives, so Lua is
-- used only for sequencing and MAME's own debugger printf formats registers.
local cpu
local debugger
local frame = 0
local logged = 0
local installed = false

local FRAMES = 1800

local function attach()
    if cpu then return end
    cpu = manager.machine.devices[":maincpu"]
    debugger = manager.machine.debugger
    if debugger then debugger.visible_cpu = cpu end
end

local function drain_console()
    if not debugger then return end
    local log = debugger.consolelog
    while logged < #log do
        logged = logged + 1
        print("KI_TMO " .. log[logged])
    end
end

-- Every debugger call goes through here. An error raised inside a MAME
-- notifier is swallowed and the notifier stops firing, which is exactly how
-- the first version of this probe produced one line of output and then went
-- silent - indistinguishable from "real KI never timed out". A probe that can
-- fail invisibly is worse than no probe.
local function cmd(text)
    if not debugger then return false end
    local ok, err = pcall(function() debugger:command(text) end)
    if not ok then
        print("KI_TMO COMMAND FAILED: " .. text .. " -> " .. tostring(err))
    end
    return ok
end

local function install()
    if installed or not debugger then return end
    installed = true

    -- Counters. temp0..temp2 are the three wait-routine entries, temp3 the
    -- shared timeout exit. The entry counters are the LIVENESS FLOOR: without
    -- them "no timeout" is indistinguishable from a probe that never armed,
    -- which is the exact shape of three earlier probes in this project that
    -- reported success while measuring nothing.
    cmd("temp0=0")
    cmd("temp1=0")
    cmd("temp2=0")
    cmd("temp3=0")
    cmd("temp4=0")

    cmd("bpset 0x8802dbc0,1,{temp0=temp0+1;g}")
    cmd("bpset 0x8802dbe4,1,{temp1=temp1+1;g}")
    cmd("bpset 0x8802dc10,1,{temp2=temp2+1;g}")

    -- The one that matters. Print every hit - if this fires at all on real KI
    -- the unwind is a normal path and $a0 is the whole question.
    cmd('bpset 0x8802dc38,1,{temp3=temp3+1;printf "TIMEOUT #%d a0=%08X v0=%08X sp=%08X",temp3,a0,v0,sp;g}')

    -- The contract, sampled a few times: at wait-routine entry $a0 must
    -- already be a 0x8802xxxx return address.
    cmd('bpset 0x8802dbc0,temp4<8,{temp4=temp4+1;printf "WAIT1 a0=%08X ra=%08X v1=%08X",a0,ra,v1;g}')

    -- Prove the temp variables and the breakpoint list took, rather than
    -- assuming a command that returned without error did what was asked.
    cmd('printf "installed temp0=%d temp3=%d",temp0,temp3')
    cmd("bplist")
    cmd("go")
    drain_console()
    print("KI_TMO breakpoints installed")
end

-- MUST be held. emu.add_machine_*_notifier returns a subscription object and
-- the notifier is cancelled when that object is collected. Dropping it gives a
-- probe that runs for a few hundred frames and then goes silent - which is
-- indistinguishable from "the event never happened", and is what the first two
-- runs of this probe actually reported. The diagnostic run survived only
-- because it exited at frame 120, before a GC pass.
KI_TMO_SUBS = {}

KI_TMO_SUBS[#KI_TMO_SUBS + 1] = emu.add_machine_reset_notifier(function()
    attach()
    install()
    print("KI_TMO reset")
end)

KI_TMO_SUBS[#KI_TMO_SUBS + 1] = emu.add_machine_frame_notifier(function()
    attach()
    install()
    frame = frame + 1
    if not debugger then return end

    -- Drained every frame, not only at the marks: a TIMEOUT print must not sit
    -- in the log until the next multiple of 300, or a run that ends early
    -- loses exactly the event being hunted.
    drain_console()

    if frame % 300 == 0 then
        cmd('printf "frame %d pc=%08X wait1=%d wait2=%d wait3=%d timeouts=%d"'
            .. string.format(",%d,pc,temp0,temp1,temp2,temp3", frame))
        drain_console()
    end

    if frame >= FRAMES then
        cmd('printf "FINAL wait1=%d wait2=%d wait3=%d timeouts=%d",temp0,temp1,temp2,temp3')
        drain_console()
        print("KI_TMO done after " .. frame .. " frames")
        manager.machine:exit()
    end
end)
