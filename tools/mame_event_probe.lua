local cpu = manager.machine.devices[":maincpu"]
local debugger = manager.machine.debugger
local frame = 0

debugger.visible_cpu = cpu
for index = 0, 4 do
    debugger:command(string.format("do temp%d=0", index))
end

local function count_breakpoint(address, index)
    cpu.debug:bpset(
        address,
        "1",
        string.format("do temp%d=temp%d+1;g", index, index))
end

count_breakpoint(0x9fc006fc, 0)
count_breakpoint(0x9fc00728, 1)
count_breakpoint(0x9fc00c74, 2)
count_breakpoint(0x9fc00c78, 3)
count_breakpoint(0x9fc00f08, 4)

cpu.debug:go()

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 0x180 then
        debugger:command(
            'printf "KI_COUNTS SI=%X RL=%X DC=%X BR=%X F08=%X",temp0,temp1,temp2,temp3,temp4')
        local log = debugger.consolelog
        local first = math.max(1, #log - 8)
        for index = first, #log do
            print("KI_DEBUGLOG " .. log[index])
        end
        print(string.format("KI_TARGET PC=%08X",
            cpu.state["PC"].value & 0xffffffff))
    end
end)
