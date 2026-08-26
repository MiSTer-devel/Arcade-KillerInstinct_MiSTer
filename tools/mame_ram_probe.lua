local cpu = manager.machine.devices[":maincpu"]
local program = cpu.spaces["program"]
local frame = 0

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 0x180 then
        print(string.format("KI_RAM PC=%08X", cpu.state["PC"].value & 0xffffffff))
        for _, base in ipairs({0x08000000, 0x080001b8}) do
            for address = base, base + 0x3c, 4 do
                print(string.format(
                    "KI_RAM %08X=%08X",
                    address,
                    program:read_u32(address) & 0xffffffff))
            end
        end
    end
end)
