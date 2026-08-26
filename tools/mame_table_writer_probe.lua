-- Who BUILDS the permutation table?
--
-- The scan at 9FC00CD8 is a consumer, and every consumer tested so far is
-- clean. The table at 0x087FFF10..0x087FFF3F is a shuffled permutation of
-- 0x00..0x1F; on our core it must be missing the value being searched for, so
-- the producer is what matters.
--
-- Memory taps cannot see this: kinst registers RAM as fastram, which bypasses
-- the memory system entirely. Debugger WATCHPOINTS can, because the debugger
-- forces those fast paths off while they are armed.
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
        print("KI_WP " .. log[logged])
    end
end

emu.add_machine_frame_notifier(function()
    attach()
    frame = frame + 1
    if not debugger then return end

    -- Arm IMMEDIATELY. The steady-state writer turned out to be the deal
    -- routine itself (9FC00D08 / 9FC00D10), which MOVES a2 to the end and so
    -- preserves the permutation by construction. That means a bad table can
    -- only come from INITIALISATION, which happens long before frame 40.
    if frame == 1 and not armed then
        armed = true
        debugger:command(
            'wpset 0x887fff10,0x30,w,1,{printf "W pc=%08X addr=%08X data=%08X",pc,wpaddr,wpdata;g}')
        drain()
        print("KI_WP watchpoint armed on 887FFF10..887FFF3F")
    end

    if armed then drain() end

    -- A short window is plenty: the table is rewritten constantly.
    if frame == 3 then
        debugger:command('wpclear')
        drain()
        print("KI_WP done")
        manager.machine:exit()
    end
end)
