library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ki_cpu_core is
   generic
   (
      -- Build the CPU's pre-event execution trace. See cpu.vhd's generic of
      -- the same name for what it costs and what turning it off blanks.
      --
      -- Integer, not boolean, because this crosses the language boundary: the
      -- instantiation is in KillerInstinct.sv and Quartus will not convert a
      -- SystemVerilog bit into a VHDL boolean. Converted below.
      DEBUG_TRACE    : integer := 1;
      -- The framebuffer line buffer; see cpu.vhd's generic of the same name.
      -- Integer for the same reason as DEBUG_TRACE. tb_ki_perfbench turns it
      -- off to compare every framebuffer load against the unbuffered path.
      FBLINE_BUFFER  : integer := 1;
      -- Lines in that buffer. Four: hardware found KI2's heaviest frame
      -- thrashing a single line (0 hits) with 94% of its loads inside the
      -- last four lines the buffer had fetched.
      FBLINE_WAYS    : integer := 4;
      -- Fetch the next line after a miss; see cpu.vhd's FBLINE_PREFETCH.
      -- Hardware: most framebuffer misses in both games are the line after
      -- one already held, which capacity cannot fix.
      FBLINE_PREFETCH : integer := 1;
      -- 64-bit store misses skip their fill; see cpu.vhd's DCACHE_SKIP_FILL.
      -- tb_ki_perfbench turns it off to compare against the filling cache.
      DCACHE_SKIP_FILL : integer := 1
   );
   port
   (
      clk1x          : in  std_logic;
      clk93          : in  std_logic;
      clk2x          : in  std_logic;
      reset          : in  std_logic;
      irq            : in  std_logic_vector(1 downto 0);

      mem_request    : out std_logic;
      mem_rnw        : out std_logic;
      mem_address    : out std_logic_vector(31 downto 0);
      mem_req64      : out std_logic;
      mem_size       : out std_logic_vector(2 downto 0);
      mem_writeMask  : out std_logic_vector(7 downto 0);
      mem_dataWrite  : out std_logic_vector(63 downto 0);
      -- A dirty cache line in one request; see cpu.vhd's mem_line_write.
      mem_line_write : out std_logic;
      mem_line_data  : out std_logic_vector(255 downto 0);
      mem_dataRead   : in  std_logic_vector(63 downto 0);
      mem_done       : in  std_logic;
      cache_grant    : in  std_logic;
      cache_data     : in  std_logic_vector(63 downto 0);
      cache_data_ready : in std_logic;

      errors         : out std_logic_vector(5 downto 0);
      debug_fetch_pc : out std_logic_vector(31 downto 0);
      debug_retired  : out std_logic_vector(31 downto 0);
      debug_gpr_s1       : out std_logic_vector(31 downto 0);
      debug_irq_count : out std_logic_vector(31 downto 0);
      debug_t2_reload_count : out std_logic_vector(31 downto 0);
      debug_h1_op           : out std_logic_vector(31 downto 0);
      debug_exc_cause       : out std_logic_vector(31 downto 0);
      debug_ret_count       : out std_logic_vector(31 downto 0);
      debug_retire_pc       : out std_logic_vector(31 downto 0);
      debug_retire_opcode   : out std_logic_vector(31 downto 0);
      -- Pre-event execution trace, frozen at the first RAM -> boot ROM
      -- transition. The layout is documented on cpu.vhd's port of the same
      -- name; it is passed through as one vector so adding a field to the
      -- capture does not mean editing three port lists.
      debug_trace_bus         : out std_logic_vector(895 downto 0);
      debug_trace_frozen      : out std_logic;
      -- State at the last eret before the trace froze; see cpu_cop0.vhd.
      debug_eret_epc          : out std_logic_vector(31 downto 0);
      debug_eret_target       : out std_logic_vector(31 downto 0);
      debug_eret_flags        : out std_logic_vector(31 downto 0);
      -- Suppression census; see cpu_cop0.vhd.
      debug_ds_count          : out std_logic_vector(31 downto 0);
      debug_ds_first          : out std_logic_vector(31 downto 0);
      -- Board-side freeze request; see cpu.vhd's port of the same name.
      debug_trace_trigger     : in  std_logic;

      -- Per-frame stall census, built from cpu.vhd's debug_perf_events.
      --
      -- Effective speed is clock x IPC, and only the clock has ever been
      -- measured on this core. These answer the other half: of the cycles in
      -- a frame, how many retired an instruction and how many went to each
      -- kind of stall.
      --
      -- perf_frame is a free-running frame strobe from the video domain; it is
      -- synchronised and edge-detected here. On each edge the counters are
      -- latched and cleared, so the exported values describe ONE frame and are
      -- stable for the whole of the next one - which is what makes them safe
      -- to sample from another clock domain without a handshake.
      --
      -- Each field is 16 bits counting units of 256 cycles, saturating. A
      -- 100 MHz frame is ~1.67M cycles, about 6510 units, so a full frame of
      -- any single cause reads ~1970 hex.
      --
      --   field 0 cycles           CY    6 other uncached load     UO
      --         1 retired          RT    7 stall4, cached          DC
      --         2 FB fetch, recent FR    8 FB load COUNT           FL
      --         3 uncached store   UW    9 FB buffer hit COUNT     FH
      --         4 stall4           S4   10 FB fetch, adjacent      FA
      --         5 uncached FB load UF   11 narrow uncached store  NS
      --
      -- Fields 2 and 8-11 are the framebuffer load census (see cpu.vhd's
      -- perf_fb_load); FR, FA and NS are COUNTS too. They replaced F1, SK, AF,
      -- MC and WB, the skipped store-miss fill's fields.
      --
      -- Fields 7, 3, 5 and 6 partition field 4 (see cpu.vhd), so
      -- S4 - (DC + UW + UF + UO) is the non-memory remainder and should read
      -- about zero - the same self-check that kept UC + DC = S4 honest. S4 - DC
      -- is the old UC. UO is what UI, UB and UM were, merged: I/O, boot ROM
      -- and uncached RAM loads, all zero in every gameplay capture.
      --
      -- The skipped fill's fields answered on hardware: SK 42 of 69 misses,
      -- AF 0, 51 cycles per miss in KI1's heavy frame. Before them fields 8, 9
      -- and 11 were W8, W4 and UN, WB and SF, and DQ and SQ.
      --
      -- F1 (off the page during the framebuffer census; still in cpu.vhd as
      -- datacache_perf_fill_wait) is the D-cache waiting for its first fill
      -- beat. Now that a dirty
      -- victim's writeback is attributed to it, F1 / MC above ~40 is the
      -- writeback share. The retired F2 and F3 sat at their floors (~25 and ~8
      -- cycles per miss) once fill_beat_seen was fixed, and DH read the same as
      -- SH in every capture; see docs/OPTIMIZATION-HISTORY.md.
      --
      -- Field 11 has been SH (next-line miss share), WF (the 2-way D-cache's
      -- wrong-way hits, settled at 0.12% of a frame), FN and FQ - framebuffer
      -- load locality by line and by qword, which chose a line buffer - and FH,
      -- that buffer's hits, 56 units in KI2's heaviest frame on hardware. See
      -- docs/OPTIMIZATION-HISTORY.md.
      perf_frame              : in  std_logic;
      -- While high, hold the worst-frame capture cleared. Release it to start
      -- a fresh capture window.
      perf_clear              : in  std_logic;
      -- Per-frame values from ki_memory_bridge. Stable for a whole frame, so
      -- two flops are enough to bring them over; the residual risk is a torn
      -- read in the single cycle they change, once per frame, on a diagnostic.
      perf_bridge_out         : in  std_logic_vector(15 downto 0);
      perf_bridge_burst       : in  std_logic_vector(15 downto 0);
      debug_perf_bus          : out std_logic_vector(191 downto 0) := (others => '0');
      -- The single worst frame seen since the last clear, chosen by the field
      -- the current work is measured by - now UF, the framebuffer load stall.
      -- Gameplay slowdowns are occasional, so a photograph of the live values
      -- usually catches a good frame; this keeps the bad one. All ten fields
      -- come from the SAME frame, so the row still reads as one coherent
      -- census rather than ten unrelated maxima.
      --
      -- It was chosen by S4 until the skipped store-miss fill, then by DC: once
      -- the D-cache frames stopped stalling hardest, S4 caught a disk-load
      -- frame (UO) and a framebuffer frame (UF 84%) instead. The header names
      -- the key.
      debug_perf_worst        : out std_logic_vector(191 downto 0) := (others => '0')
   );
end entity;

architecture rtl of ki_cpu_core is
   signal address_u      : unsigned(31 downto 0);
   signal size_u         : unsigned(2 downto 0);
   signal reset_1x_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal reset_93_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal irq_meta       : std_logic_vector(1 downto 0) := (others => '0');
   signal irq_sync       : std_logic_vector(1 downto 0) := (others => '0');

   -- Performance census. See debug_perf_bus in the port list.
   constant PERF_N       : integer := 12;
   type t_perf is array(0 to PERF_N - 1) of unsigned(23 downto 0);
   signal perf_cnt       : t_perf := (others => (others => '0'));
   signal perf_events    : std_logic_vector(9 downto 0);
   signal debug_retired_i : std_logic_vector(31 downto 0);
   signal perf_frame_meta : std_logic_vector(2 downto 0) := (others => '0');
   -- perf_clear comes from the OSD, so it crosses into clk93 like perf_frame
   -- does. It is a manual toggle and a one-frame mis-sample would be
   -- harmless, but leaving one control synchronised and its neighbour not is
   -- the kind of inconsistency that reads as an oversight later.
   signal perf_clear_meta : std_logic_vector(1 downto 0) := (others => '0');
begin
   mem_address <= std_logic_vector(address_u);
   mem_size    <= std_logic_vector(size_u);

   -- Assert immediately, then release reset independently in each CPU domain.
   process (clk1x, reset)
   begin
      if (reset = '1') then
         reset_1x_pipe <= (others => '1');
      elsif (rising_edge(clk1x)) then
         reset_1x_pipe <= reset_1x_pipe(0) & '0';
      end if;
   end process;

   process (clk93, reset)
   begin
      if (reset = '1') then
         reset_93_pipe <= (others => '1');
         irq_meta      <= (others => '0');
         irq_sync      <= (others => '0');
      elsif (rising_edge(clk93)) then
         reset_93_pipe <= reset_93_pipe(0) & '0';
         irq_meta      <= irq;
         irq_sync      <= irq_meta;
      end if;
   end process;

   core : entity work.cpu
      generic map
      (
         LITTLE_ENDIAN        => true,
         FRAMEBUFFER_UNCACHED => true,
         FBLINE_BUFFER        => (FBLINE_BUFFER /= 0),
         FBLINE_WAYS          => FBLINE_WAYS,
         FBLINE_PREFETCH      => (FBLINE_PREFETCH /= 0),
         DCACHE_SKIP_FILL     => (DCACHE_SKIP_FILL /= 0),
         -- KI uses the 32-bit exception-address contract.
         ADDR32_ONLY          => true,
         -- KI does not use the optional trap-instruction exception path.
         NO_TRAP_INSTR        => true,
         -- KI instruction fetches use KSEG0/KSEG1.
         INSTR_KSEG_ONLY      => true,
         DEBUG_TRACE          => (DEBUG_TRACE /= 0)
      )
      port map
      (
         clk1x                 => clk1x,
         clk93                 => clk93,
         clk2x                 => clk2x,
         ce_1x                 => '1',
         ce_93                 => '1',
         reset_1x              => reset_1x_pipe(1),
         reset_93              => reset_93_pipe(1),
         preNMI                => '0',
         INSTRCACHEON          => '1',
         DATACACHEON           => '1',
         DATACACHESLOW         => (others => '0'),
         DATACACHEFORCEWEB     => '0',
         -- KI writes code and its visible framebuffers through KSEG0 during
         -- bootstrap. Keep those stores coherent with instruction fetch and
         -- scanout until the complete R4600 cache-op path is proven.
         DATACACHEWRITETHROUGH => '0',
         DATACACHETLBON        => '1',
         RANDOMMISS            => (others => '0'),
         DISABLE_BOOTCOUNT     => '0',
         DISABLE_DTLBMINI      => '0',
         ALECK64               => '1',
         irqRequest            => irq_sync,
         cpuPaused             => '0',
         error_instr           => errors(0),
         error_stall           => errors(1),
         error_FPU             => errors(2),
         error_exception       => errors(3),
         error_fifo            => errors(4),
         error_TLB             => errors(5),
         debug_fetch_pc        => debug_fetch_pc,
         debug_retired         => debug_retired_i,
         debug_gpr_s1          => debug_gpr_s1,
         debug_irq_count       => debug_irq_count,
         debug_t2_reload_count => debug_t2_reload_count,
         debug_h1_op           => debug_h1_op,
         debug_exc_cause       => debug_exc_cause,
         debug_ret_count       => debug_ret_count,
         debug_retire_pc       => debug_retire_pc,
         debug_retire_opcode   => debug_retire_opcode,
         debug_trace_bus         => debug_trace_bus,
         debug_trace_frozen      => debug_trace_frozen,
         -- Simulation-only taps; the board reads the frozen copies instead.
         debug_cop0_cause_live   => open,
         debug_cop0_epc_live     => open,
         debug_eret_epc          => debug_eret_epc,
         debug_eret_target       => debug_eret_target,
         debug_eret_flags        => debug_eret_flags,
         debug_ds_count          => debug_ds_count,
         debug_perf_events       => perf_events,
         debug_ds_first          => debug_ds_first,
         debug_trace_trigger     => debug_trace_trigger,
         mem_request           => mem_request,
         mem_rnw               => mem_rnw,
         mem_address           => address_u,
         mem_req64             => mem_req64,
         mem_size              => size_u,
         mem_writeMask         => mem_writeMask,
         mem_dataWrite         => mem_dataWrite,
         mem_line_write        => mem_line_write,
         mem_line_data         => mem_line_data,
         mem_dataRead          => mem_dataRead,
         mem_done              => mem_done,
         rdram_granted2x       => cache_grant,
         rdram_done            => '0',
         ddr3_DOUT             => cache_data,
         ddr3_DOUT_READY       => cache_data_ready,
         ram_done              => '0',
         ram_rnw               => '1',
         ram_dataRead          => (others => '0'),
-- synthesis translate_off
         cpu_done              => open,
         cpu_export            => open,
-- synthesis translate_on
         SS_reset              => reset_93_pipe(1),
         loading_savestate     => '0',
         SS_DataWrite          => (others => '0'),
         SS_Adr                => (others => '0'),
         SS_wren_CPU           => '0',
         SS_rden_CPU           => '0',
         SS_DataRead_CPU       => open,
         SS_idle               => open
      );

   debug_retired <= debug_retired_i;

   gperf : if DEBUG_TRACE /= 0 generate
      signal retired_prev : unsigned(31 downto 0) := (others => '0');
      signal retired_cnt  : unsigned(23 downto 0) := (others => '0');
      signal worst_key    : unsigned(23 downto 0) := (others => '0');

      -- Saturating so a long frame reads as "pinned" rather than wrapping to a
      -- small number, which is how the HP/HW counters misled us before.
      function bump(v : unsigned(23 downto 0); e : std_logic) return unsigned is
      begin
         if (e = '1' and v /= x"FFFFFF") then
            return v + 1;
         end if;
         return v;
      end function;
   begin
      process (clk93)
         variable tick : std_logic;
      begin
         if (rising_edge(clk93)) then
            perf_frame_meta <= perf_frame_meta(1 downto 0) & perf_frame;
            perf_clear_meta <= perf_clear_meta(0) & perf_clear;
            tick := perf_frame_meta(1) and (not perf_frame_meta(2));

            if (reset_93_pipe(1) = '1') then
               perf_cnt         <= (others => (others => '0'));
               retired_prev     <= (others => '0');
               retired_cnt      <= (others => '0');
               worst_key        <= (others => '0');
               debug_perf_worst <= (others => '0');
            elsif (tick = '1') then
               -- Latch the frame just finished, then restart the window.
               for i in 0 to PERF_N - 1 loop
                  debug_perf_bus(i * 16 + 15 downto i * 16)
                     <= std_logic_vector(perf_cnt(i)(23 downto 8));
               end loop;
               debug_perf_bus(31 downto 16)
                  <= std_logic_vector(retired_cnt(23 downto 8));
               -- Bridge fields pass through; they are counted in ki_memory_bridge.

               -- Keep the frame that stalled hardest on framebuffer loads.
               -- perf_cnt(5) is UF; compare before it is cleared.
               if (perf_clear_meta(1) = '1') then
                  debug_perf_worst <= (others => '0');
                  worst_key        <= (others => '0');
               elsif (perf_cnt(5) > worst_key) then
                  worst_key <= perf_cnt(5);
                  for i in 0 to PERF_N - 1 loop
                     debug_perf_worst(i * 16 + 15 downto i * 16)
                        <= std_logic_vector(perf_cnt(i)(23 downto 8));
                  end loop;
                  debug_perf_worst(31 downto 16)
                     <= std_logic_vector(retired_cnt(23 downto 8));
               end if;

               perf_cnt     <= (others => (others => '0'));
               retired_cnt  <= (others => '0');
               retired_prev <= unsigned(debug_retired_i);
            else
               perf_cnt(0) <= bump(perf_cnt(0), '1');
               for b in 0 to 9 loop
                  perf_cnt(b + 2) <= bump(perf_cnt(b + 2), perf_events(b));
               end loop;
               -- Retired is a free-running total in cpu.vhd, so difference it
               -- against the value at the start of this window.
               retired_cnt <= resize(unsigned(debug_retired_i) - retired_prev, 24);
            end if;
         end if;
      end process;
   end generate gperf;

   gperf_off : if DEBUG_TRACE = 0 generate
      debug_perf_bus   <= (others => '0');
      debug_perf_worst <= (others => '0');
   end generate gperf_off;
end architecture;
