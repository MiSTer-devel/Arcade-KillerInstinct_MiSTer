-- Capture the CPU's RAM data accesses on kinst for replay through
-- tools/mame_dcache_sim.py.
--
-- WHAT THIS CAN AND CANNOT SEE. MAME 0.288's MIPS3 core reads and writes RAM
-- directly for ordinary accesses once a driver registers "fastram", which
-- kinst does - in the DRC AND in the -nodrc interpreter. Taps only see what
-- falls back to the address space: every 64-bit access (RDOUBLE/WDOUBLE
-- never consult fastram, and arrive as two 32-bit halves at +0 and +4) and
-- the masked ones (halfwords). Plain 32-bit and 8-bit loads and stores are
-- INVISIBLE. Measured, not assumed: a mask histogram over gameplay shows only
-- halfword masks and paired 32-bit halves.
--
-- So this is not the whole data stream. It is exactly the game's 64-bit
-- block copies - which dominate KI's per-frame traffic - plus halfwords. Use
-- it for questions about those streams, not for total miss counts.
--
-- It must run under -nodrc (the recompiler bypasses taps entirely) and is
-- meant to start from a mid-match save state, because -nodrc boot is slow:
--
--   mame kinst -nodrc -state kigame -autoboot_script this.lua ...
--
-- Output: little-endian uint32 records. Bits 27..0 the physical byte
-- address, bit 31 set for a write, bit 30 set for a halfword (masked)
-- access. 0xFFFFFFFF ends each frame.
--
-- Traps accounted for (see the MAME harness notes): every tap and notifier
-- handle is kept in a global, or it is garbage-collected and silently stops;
-- no cpu.state reads inside a tap (~100x slower); inputs are driven by an
-- explicit field list only.

OUT     = os.getenv("KI_DCACHE_TRACE") or "C:/temp/kitrace/dcache.bin"
FRAMES  = tonumber(os.getenv("KI_DCACHE_FRAMES") or "4")
FRAME   = 0
N       = 0
BUF     = {}
FH      = assert(io.open(OUT, "wb"))

local program = manager.machine.devices[":maincpu"].spaces["program"]

local function rec_r(o, d, m)
   N = N + 1
   BUF[N] = (m == 0xffffffff) and o or (o | 0x40000000)
   return d
end
local function rec_w(o, d, m)
   N = N + 1
   BUF[N] = (m == 0xffffffff) and (o | 0x80000000) or (o | 0xc0000000)
   return d
end

TAPS = {}
TAPS[1] = program:install_read_tap (0x00000000, 0x0007ffff, "dt_lr", rec_r)
TAPS[2] = program:install_write_tap(0x00000000, 0x0007ffff, "dt_lw", rec_w)
TAPS[3] = program:install_read_tap (0x08000000, 0x088fffff, "dt_mr", rec_r)
TAPS[4] = program:install_write_tap(0x08000000, 0x088fffff, "dt_mw", rec_w)

local CHUNK = 1024
local FMT_CHUNK = "<" .. string.rep("I4", CHUNK)

local function flush_frame()
   local i = 1
   while i + CHUNK - 1 <= N do
      FH:write(string.pack(FMT_CHUNK, table.unpack(BUF, i, i + CHUNK - 1)))
      i = i + CHUNK
   end
   if i <= N then
      FH:write(string.pack("<" .. string.rep("I4", N - i + 1), table.unpack(BUF, i, N)))
   end
   FH:write(string.pack("<I4", 0xffffffff))
   BUF = {}
   N = 0
end

local function field(name)
   for _, port in pairs(manager.machine.ioport.ports) do
      local f = port.fields[name]
      if f then return f end
   end
end
local function hold(name, on)
   local f = field(name)
   if f then f:set_value(on and 1 or 0) end
end

TRACE_SUB = emu.add_machine_frame_notifier(function()
   FRAME = FRAME + 1
   -- Keep fighting so the match does not end mid-capture.
   local on = (FRAME % 24) < 12
   hold("P1 Button 1", on)
   hold("P1 Button 2", not on)
   -- Frame 1 is partial (the state loaded mid-frame); drop it.
   if FRAME == 1 then
      BUF = {}
      N = 0
      return
   end
   local n = N
   flush_frame()
   print(string.format("KIDTRACE frame=%d records=%d", FRAME, n))
   if FRAME > FRAMES then
      FH:close()
      print("KIDTRACE wrote " .. OUT)
      manager.machine:exit()
   end
end)
