-- Does KI ever hold a register whose upper 32 bits are not the sign extension
-- of bit 31? cpu.vhd's CMP32_ONLY narrows the branch comparators to 32 bits,
-- which is only sound while that never happens where a compare consumes it.
-- Simulation covers boot; this covers gameplay.
--
-- Traps this script already accounts for (see the MAME harness notes):
--  * the notifier handle MUST stay in a global or it is GC'd and never fires
--  * emu.register_frame_done does not exist in this build
--  * per-frame state reads are fine; per-access reads are ~100x slower
--  * KI1 attract is silent/idle - you must coin up and start a match
--  * cpu.state is sol2 userdata, so cpu.state["at"] returns the container's
--    at() METHOD, not register at. Always go through cpu.state:get(name),
--    which has no name collisions - it returns the entry OBJECT. Read it with
--    tostring(entry), which is 16 hex digits: entry.value throws "integer
--    value will be misrepresented in lua" as soon as bit 63 is set, which is
--    exactly the case this probe exists to find.

FRAME      = 0
BAD_TOTAL  = 0
BAD_FRAMES = 0
SHOWN      = 0
PHASE      = "boot"
SEEN       = {}
BYREG      = {}
PCSEEN     = {}
LAST_FRAME = 17800
GAMEPC     = {}

local GPR = {"at","v0","v1","a0","a1","a2","a3",
             "t0","t1","t2","t3","t4","t5","t6","t7",
             "s0","s1","s2","s3","s4","s5","s6","s7",
             "t8","t9","k0","k1","gp","sp","fp","ra"}

local function field(name)
   for _, port in pairs(manager.machine.ioport.ports) do
      local f = port.fields[name]
      if f then return f end
   end
   return nil
end

local function hold(name, on)
   local f = field(name)
   if f then f:set_value(on and 1 or 0) end
end

KI_CANON_SUB = emu.add_machine_frame_notifier(function()
   FRAME = FRAME + 1
   local cpu = manager.machine.devices[":maincpu"]

   -- Drive: boot, coin, start, then keep attacking so we stay in a match.
   if FRAME == 9600  then hold("Coin 1", true)  end
   if FRAME == 9612  then hold("Coin 1", false) end
   if FRAME == 9700  then hold("1 Player Start", true)  end
   if FRAME == 9712  then hold("1 Player Start", false) end
   if FRAME > 9800 then
      PHASE = "game"
      local on = (FRAME % 24) < 12
      hold("P1 Button 1", on)
      hold("P1 Button 2", not on)
      if (FRAME % 180) < 20 then hold("P1 Right", true) else hold("P1 Right", false) end
   elseif FRAME > 9000 then
      PHASE = "attract"
   end

   local badthis = 0
   local pc = tostring(cpu.state:get("PC"))
   for _, r in ipairs(GPR) do
      local e = cpu.state:get(r)
      local t = e and tostring(e) or nil
      if t and #t == 16 then
         local hi = tonumber(t:sub(1, 8), 16)
         local lo = tonumber(t:sub(9, 16), 16)
         local ex = (((lo >> 31) & 1) == 1) and 0xffffffff or 0
         if hi ~= ex then
            badthis   = badthis + 1
            BAD_TOTAL = BAD_TOTAL + 1
            local bk  = PHASE .. "/" .. r
            BYREG[bk] = (BYREG[bk] or 0) + 1
            local key = string.format("%s:%08x%08x", r, hi, lo)
            if not SEEN[key] and SHOWN < 40 then
               SEEN[key] = true
               SHOWN = SHOWN + 1
               print(string.format("NONCANON frame=%d phase=%s %s=%08x%08x pc=%s",
                     FRAME, PHASE, r, hi, lo, pc))
            end
         end
      end
   end
   if badthis > 0 then BAD_FRAMES = BAD_FRAMES + 1 end

   -- Which register, in which phase, and where. The earlier version capped the
   -- printed samples and so showed only boot, while the totals kept rising -
   -- count everything instead of sampling it.
   PCSEEN[pc] = (PCSEEN[pc] or 0) + badthis
   if FRAME % 2400 == 0 or FRAME == LAST_FRAME then
      local parts = {}
      for k, n in pairs(BYREG) do parts[#parts+1] = k .. "=" .. n end
      table.sort(parts)
      print(string.format("CANON frame=%d phase=%s badframes=%d badregs=%d | %s",
            FRAME, PHASE, BAD_FRAMES, BAD_TOTAL, table.concat(parts, " ")))
      local hot = {}
      for a, n in pairs(PCSEEN) do hot[#hot+1] = {a, n} end
      table.sort(hot, function(x, y) return x[2] > y[2] end)
      local top = {}
      for i = 1, math.min(6, #hot) do
         top[#top+1] = string.format("%s:%d", hot[i][1], hot[i][2])
      end
      print("CANON_PC " .. table.concat(top, " "))
   end
end)
