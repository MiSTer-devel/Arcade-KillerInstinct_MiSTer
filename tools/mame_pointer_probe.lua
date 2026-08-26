-- Where does the boot decompressor's copy loop actually point?
--
-- At 9FC00CF0 the loop reads and writes through a1:
--
--   9FC00CF8: lb   v0,1(a1)
--   9FC00D08: sb   v0,-1(a1)      (delay slot)
--
-- If a1 is 0x8xxxxxxx (KSEG0) those accesses are CACHED and the data cache is
-- on the critical path. If a1 is 0xAxxxxxxx / 0xBxxxxxxx (KSEG1) they are
-- architecturally UNCACHED, the data cache is not involved at all, and the
-- whole cache subsystem can be eliminated as a suspect - which would explain
-- why fixing the write-back doubled write traffic but changed no behaviour.
--
-- Reading 64-bit MIPS registers straight out of Lua throws "integer value will
-- be misrepresented in lua" for sign-extended values, which is what killed the
-- first attempt at this. PC happens to survive, so PC is read in Lua to decide
-- WHEN to sample, and the registers themselves are formatted by MAME's own
-- debugger printf and recovered from the console log.
local cpu
local debugger
local frame = 0
local samples = 0
local logged = 0

local LOOP_LO = 0x9fc00cd0
local LOOP_HI = 0x9fc00d10

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
        print("KI_PTR " .. log[logged])
    end
end

emu.add_machine_reset_notifier(function()
    attach()
    print("KI_PTR reset")
end)

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not cpu or not debugger then return end

    local pc = cpu.state["PC"].value & 0xffffffff

    -- Sample only while inside the copy loop, and only a handful of times.
    if samples < 12 and pc >= LOOP_LO and pc <= LOOP_HI then
        samples = samples + 1
        debugger:command(string.format(
            'printf "frame=%d pc=%%08X a1=%%08X v0=%%08X a2=%%08X v1=%%08X",pc,a1,v0,a2,v1',
            frame))
        drain_console()
    end

    -- A few unconditional samples too, so we see the surrounding context even
    -- if the loop is never caught at a frame boundary.
    if frame == 60 or frame == 240 or frame == 600 then
        debugger:command(string.format(
            'printf "mark frame=%d pc=%%08X a1=%%08X s1=%%08X sp=%%08X",pc,a1,s1,sp',
            frame))
        drain_console()
    end

    if frame == 900 then
        drain_console()
        print(string.format("KI_PTR done, %d in-loop samples", samples))
        manager.machine:exit()
    end
end)
