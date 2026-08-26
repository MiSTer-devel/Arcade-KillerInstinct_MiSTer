-- Ground truth for KI's input port bits, straight out of MAME's own ioport
-- definitions rather than inferred from behaviour.
--
-- The core builds input_p1/input_p2 in KillerInstinct.sv by hand-placing
-- joystick bits, and the game boots but reads the wrong buttons. MAME knows
-- the real tag/mask for every field, so print them and map against that.
--
-- field.mask is the bit within the port; the port tag says which board
-- register it lands in.

local dumped = false

local function dump()
    if dumped then return end
    dumped = true
    local ports = manager.machine.ioport.ports
    local tags = {}
    for tag, _ in pairs(ports) do tags[#tags + 1] = tag end
    table.sort(tags)
    for _, tag in ipairs(tags) do
        print(string.format("KIIN PORT %s", tag))
        local rows = {}
        for name, field in pairs(ports[tag].fields) do
            rows[#rows + 1] = { name = name, mask = field.mask,
                                ftype = tostring(field.type),
                                player = field.player }
        end
        table.sort(rows, function(a, b) return a.mask < b.mask end)
        for _, r in ipairs(rows) do
            local bit = -1
            for b = 0, 31 do
                if (r.mask >> b) & 1 == 1 then bit = b break end
            end
            print(string.format("KIIN   bit %2d mask %08X  p%s  %s  [%s]",
                                bit, r.mask, tostring(r.player), r.name,
                                r.ftype))
        end
    end
    print("KIIN done")
end

emu.add_machine_frame_notifier(function()
    local ok, err = pcall(dump)
    if not ok then print("KIIN failed: " .. tostring(err)) end
    if dumped then manager.machine:exit() end
end)
