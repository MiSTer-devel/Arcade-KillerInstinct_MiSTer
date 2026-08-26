-- Does real KI have interrupts enabled during the boot loop?
--
-- Every hardware capture shows I:00000000 - our CPU has never taken an
-- interrupt. That is only a bug if the boot code has ENABLED interrupts by
-- this point, so ask the real machine. SR is the COP0 Status register (bit 0
-- IE, bits 15..8 the interrupt mask) and Cause bits 15..8 are pending.
--
-- Registers are formatted by MAME's debugger printf, because reading them
-- from Lua throws on sign-extended values.
local cpu, debugger
local frame, logged = 0, 0

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
        print("KI_IRQ " .. log[logged])
    end
end

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not debugger then return end
    if frame == 2 or frame == 20 or frame == 60 or frame == 120 then
        debugger:command(string.format(
            'printf "frame=%d pc=%%08X SR=%%08X Cause=%%08X Count=%%08X Compare=%%08X",pc,SR,Cause,Count,Compare',
            frame))
        drain()
    end
    if frame == 140 then drain(); manager.machine:exit() end
end)
