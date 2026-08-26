-- Dump the CPU program-space memory map.
--
-- ki_board_pkg uses the SAME KI_ATA_CS0_BASE for kinst and kinst2, which has
-- never been checked. KI2's decompressed code contains no store to 0x138 or
-- 0x170 - the command and alternate-status offsets KI1 uses - so either its
-- driver lives outside the region dumped so far or its register layout is
-- different. The memory map settles where the IDE actually is, for both sets,
-- without guessing from code patterns.

local dumped = false

local function dump()
    if dumped then return end
    dumped = true
    local cpu = manager.machine.devices[":maincpu"]
    local space = cpu.spaces["program"]
    print(string.format("KIMAP space %s  bytewidth=%d  addrmask=%08X",
                        space.name, space.data_width // 8, space.address_mask))
    local map = space.map
    if not map then
        print("KIMAP no .map on this space (MAME version too old)")
        return
    end
    for _, entry in ipairs(map.entries) do
        print(string.format(
            "KIMAP %08X-%08X  r=%-28s w=%-28s",
            entry.address_start, entry.address_end,
            tostring(entry.read.tag or entry.read.name or "-"),
            tostring(entry.write.tag or entry.write.name or "-")))
    end
    print("KIMAP done")
end

emu.add_machine_frame_notifier(function()
    local ok, err = pcall(dump)
    if not ok then print("KIMAP failed: " .. tostring(err)) end
    if dumped then manager.machine:exit() end
end)
