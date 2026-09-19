-- What LBAs does real KI ask the disk for, and in what order?
--
-- Written to settle whether a RETAINED sector cache across ATA commands would
-- buy anything in rtl/ki_ata.sv. The theory was that because KI's backgrounds
-- are FMV that changes with the player's horizontal position, panning the
-- camera would make the game revisit LBAs it had recently read, and the core
-- throws its banks away at every READ SECTORS (bank_valid <= 2'b00).
--
-- The measurement says no. Over 359 emulated seconds with a live match and the
-- stick sweeping full left/right the whole time: 501 reads, 390 of them the
-- full 256 sectors, and the LBA advances monotonically THROUGH the sweeping
-- (193528 -> 194606 -> 196859 -> 199065 -> 201654). The pan is windowed out of
-- RAM and never reaches the disk. 85% of commands start exactly where the
-- previous one ended; simulated LRU retention hits 0/172 commands in the
-- sweeping phase and stays flat from 8 KB to 512 KB of cache.
--
-- Run it (about 6 minutes wall for 360 emulated seconds):
--
--   mame.exe kinst -noreadconfig -rompath games \
--     -diff_directory C:/temp/kiata -nvram_directory C:/temp/kiata \
--     -cfg_directory C:/temp/kiata -video none -sound none -nothrottle \
--     -seconds_to_run 360 -debug -debugger none \
--     -autoboot_script KillerInstinct_MiSTer/tools/mame_ata_lba_probe.lua \
--     > ata.log 2>&1
--
-- then decode the taskfile writes into commands with
-- tools/mame_ata_lba_report.py ata.log
--
-- METHOD, and why it is not the obvious one: install_write_tap on the ATA
-- range catches NOTHING on kinst - the MIPS3 recompiler bypasses tap handlers,
-- and -nodrc is too slow to matter. A debugger WATCHPOINT is honoured by the
-- DRC and costs ~47% speed, which is affordable.
--
-- The trap that cost the first run: MIPS3 watchpoints take LOGICAL addresses.
-- `wp 10000108` fails with "Address 10000108 in logical space program does not
-- map to anything"; the ATA registers have to be watched through their KSEG1
-- (uncached) alias at 0xB00001xx. wpaddr still reports the physical address.
--
-- kinst.cpp maps 0x10000100-0x1000013f and dispatches offset/2, so the ATA
-- registers sit 8 bytes apart:
--   n=2 ..110 sector count   n=3 ..118 sector number   n=4 ..120 cylinder low
--   n=5 ..128 cylinder high  n=6 ..130 device/head     n=7 ..138 command
-- The data port (n=0, ..100) is deliberately OUTSIDE the watched range -
-- including it would log every PIO halfword.

local FRAMES     = tonumber(os.getenv("KI_PROBE_FRAMES") or "21600")
-- Boot needs ~9600 frames before the game will take a coin.
local COIN_FRAME  = tonumber(os.getenv("KI_PROBE_COIN") or "9600")
local START_FRAME = COIN_FRAME + 100
local MASH_FRAME  = COIN_FRAME + 200
local SWEEP_FRAME = tonumber(os.getenv("KI_PROBE_SWEEP") or "11000")
local SWEEP_PERIOD = 300   -- frames; 2.5 s hard left, then 2.5 s hard right

local cpu, debugger
local frame = 0
local logged = 0
local installed = false

local function attach()
    if cpu then return end
    cpu = manager.machine.devices[":maincpu"]
    debugger = manager.machine.debugger
    if debugger then debugger.visible_cpu = cpu end
end

-- The watchpoint's printf goes to the debugger console, not stdout. Draining
-- it every frame is what makes the output capturable under -video none.
local function drain()
    if not debugger then return end
    local log = debugger.consolelog
    while logged < #log do
        logged = logged + 1
        print("KI_ATA " .. log[logged])
    end
end

local function cmd(text)
    if not debugger then return false end
    local ok, err = pcall(function() debugger:command(text) end)
    if not ok then
        print("KI_ATA COMMAND FAILED: " .. text .. " -> " .. tostring(err))
    end
    return ok
end

local function install()
    if installed or not debugger then return end
    installed = true

    -- temp9 is the LIVENESS FLOOR. Without a hit counter, "no taskfile writes
    -- logged" reads identically to "the watchpoint never armed" - which is
    -- exactly what the logical/physical address mistake produced, and is the
    -- shape of several earlier probes in this project that reported success
    -- while measuring nothing.
    cmd("temp9=0")
    cmd('wp b0000108,38,w,1,{temp9=temp9+1;printf "TF %08X %02X f=%d",wpaddr,wpdata,temp9;g}')
    cmd("wplist")   -- proves the watchpoint took, rather than assuming it did
    cmd("go")
    drain()
    print("KI_ATA watchpoint installed")
end

-- ---- autoplay -------------------------------------------------------------
-- Attract mode is not enough: the question is what the disk does when the
-- PLAYER pans the camera, so this coins up, starts a match, and then sweeps
-- the stick in long strokes. Short jitter would keep the camera near centre
-- and never exercise the pan at all.
--
-- ONLY the fields listed here are ever touched. An earlier version released
-- *every* field in :P1 each frame - which includes "Service Mode" and the
-- spare coin slots - and MAME died ~40 s in, twice, with no error message and
-- a shell exit of 127. Never blanket-write a port whose fields you have not
-- enumerated.
local DRIVEN = {"Coin 1", "1 Player Start", "P1 Left", "P1 Right",
                "P1 High Attack - Quick"}

local fields = {}
local armed = false

local function hold(name, on)
    local f = fields[name]
    if f then f:set_value(on and 1 or 0) end
end

local function autoplay()
    if not armed then
        local p1 = manager.machine.ioport.ports[":P1"]
        if not p1 then return end
        for _, n in ipairs(DRIVEN) do
            fields[n] = p1.fields[n]
            if not fields[n] then print("KI_ATA MISSING FIELD " .. n) end
        end
        armed = true
        print("KI_ATA autoplay armed")
    end

    for _, n in ipairs(DRIVEN) do hold(n, false) end

    if frame >= COIN_FRAME and frame < COIN_FRAME + 40 then
        hold("Coin 1", true)
    elseif frame >= START_FRAME and frame < START_FRAME + 40 then
        hold("1 Player Start", true)
    elseif frame >= MASH_FRAME and frame < SWEEP_FRAME then
        -- Mash an attack to clear character select and the intro.
        if (frame % 20) < 10 then hold("P1 High Attack - Quick", true) end
    elseif frame >= SWEEP_FRAME then
        local phase = (frame - SWEEP_FRAME) % SWEEP_PERIOD
        if phase < SWEEP_PERIOD / 2 then hold("P1 Left", true)
        else hold("P1 Right", true) end
        -- Occasional attack so the match does not time out.
        if (frame % 97) < 6 then hold("P1 High Attack - Quick", true) end
    end
end

-- MUST be held in a global. emu.add_machine_*_notifier returns a subscription
-- object and the notifier is cancelled when it is collected - a probe that
-- runs a few hundred frames and then silently stops.
KI_ATA_SUBS = {}

KI_ATA_SUBS[#KI_ATA_SUBS + 1] = emu.add_machine_reset_notifier(function()
    attach(); install(); print("KI_ATA reset")
end)

KI_ATA_SUBS[#KI_ATA_SUBS + 1] = emu.add_machine_frame_notifier(function()
    attach(); install()
    frame = frame + 1
    if not debugger then return end

    local ok, err = pcall(autoplay)
    if not ok then print("KI_ATA AUTOPLAY ERROR " .. tostring(err)) end

    drain()
    if frame % 600 == 0 then
        cmd(string.format('printf "MARK frame %d hits=%%d",temp9', frame))
        drain()
    end
    if frame >= FRAMES then
        cmd('printf "FINAL hits=%d",temp9')
        drain()
        print("KI_ATA done at frame " .. frame)
        manager.machine:exit()
    end
end)
