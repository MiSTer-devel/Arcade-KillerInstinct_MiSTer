local frame = 0
local max_frames = 1600

emu.register_frame_done(function()
    frame = frame + 1

    local cpu = manager.machine.devices[":maincpu"]
    if frame == 1 then
        local names = {}
        for name, _ in pairs(cpu.state) do
            table.insert(names, name)
        end
        table.sort(names)
        print("CPU_STATE " .. table.concat(names, ","))
    end

    if frame <= max_frames then
        local pc = cpu.state["PC"].value
        local s5 = cpu.state["s5"].value
        local t2 = cpu.state["t2"].value
        print(string.format(
            "KI_FRAME %03X PC=%08X S5=%08X T2=%08X A3=%s S6=%s RA=%s",
            frame, pc & 0xffffffff, s5 & 0xffffffff, t2 & 0xffffffff,
            tostring(cpu.state["a3"]), tostring(cpu.state["s6"]),
            tostring(cpu.state["ra"])))
    end
end)
