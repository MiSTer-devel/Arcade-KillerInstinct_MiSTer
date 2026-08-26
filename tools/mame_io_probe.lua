-- Which board registers does the boot code actually read?
--
-- The buffer the boot scan walks is a shuffled permutation of 0x00..0x1F, and
-- the scan exits only when it finds the value in a2. Real KI always finds it
-- because the table is complete; ours never does, so our table must be wrong.
-- A shuffle needs a randomness source, and if that source reads a register we
-- do not decode, ki_memory_bridge returns 0xFFFFFFFFFFFFFFFF for it - which
-- would corrupt the shuffle.
--
-- I/O is NOT fastram, so taps work here (unlike RAM).
local cpu
local program
local frame = 0
local seen = {}
local order = {}

local function attach()
    if program then return end
    cpu = manager.machine.devices[":maincpu"]
    program = cpu.spaces["program"]

    -- Narrow range: installing a tap across unmapped space throws, which
    -- silently killed the frame callback on the first attempt.
    program:install_read_tap(0x10000000, 0x100000ff, "ki_io_read",
        function(offset, data, mask)
            local a = offset & 0xffffffff
            if not seen[a] then
                seen[a] = { reads = 0, first_frame = frame,
                            pc = cpu.state["PC"].value & 0xffffffff }
                order[#order + 1] = a
            end
            seen[a].reads = seen[a].reads + 1
            seen[a].last = data & 0xffffffff
            return data
        end)
end

emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 1 then print("KI_IO probe alive") end
    local ok, err = pcall(attach)
    if not ok and frame == 1 then print("KI_IO attach failed: " .. tostring(err)) end
    if frame == 150 then
        print("KI_IO distinct board addresses read during boot:")
        for _, a in ipairs(order) do
            local e = seen[a]
            print(string.format(
                "KI_IO   addr=%08X reads=%-8d firstframe=%-4d pc=%08X last=%08X",
                a, e.reads, e.first_frame, e.pc, e.last))
        end
        print(string.format("KI_IO %d distinct addresses", #order))
        manager.machine:exit()
    end
end)
