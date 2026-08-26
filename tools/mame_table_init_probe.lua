-- Where is the permutation table INITIALISED?
--
-- The only steady-state writers are 9FC00D08 and 9FC00D10 - the deal routine
-- itself, which moves a2 to the tail and therefore PRESERVES the permutation
-- by construction. So a bad table can only originate at initialisation, which
-- happens before the autoboot script gets a chance to arm anything.
--
-- Fix: set a breakpoint on the reset vector whose action arms the watchpoint
-- and continues, then soft-reset so boot runs again with it live.
local cpu, debugger
local frame, logged = 0, 0
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
        print("KI_INIT " .. log[logged])
    end
end

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not debugger then return end

    if stage == 0 then
        stage = 1
        -- Arm the watchpoint the moment the reset vector is reached, then run.
        debugger:command(
            'bpset 0xBFC00000,1,{wpset 0x887fff10,0x30,w,1,{printf "W pc=%08X addr=%08X data=%08X",pc,wpaddr,wpdata;g};g}')
        drain()
        manager.machine:soft_reset()
        print("KI_INIT breakpoint armed, soft reset issued")
        return
    end

    drain()

    -- Only a short window is needed; initialisation is early and dense.
    if frame >= 4 then
        debugger:command('wpclear')
        debugger:command('bpclear')
        drain()
        print("KI_INIT done")
        manager.machine:exit()
    end
end)
