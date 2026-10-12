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
      -- Base of the PROF page's 256 KB window; must be 256 KB aligned, since
      -- the buckets are absolute address bits 17:15 and 14:12. Hardware uses
      -- the default. A bench running its own program elsewhere has to move
      -- the window onto it, or every retire there lands in OT and the PROF
      -- invariant assertion only ever checks 0 = 0.
      PROF_BASE      : std_logic_vector(31 downto 0) := x"88000000";
      -- 64-bit store misses skip their fill; see cpu.vhd's DCACHE_SKIP_FILL.
      DCACHE_SKIP_FILL : integer := 1;
      -- Partial framebuffer stores skip their fill too; see cpu.vhd's
      -- DCACHE_FB_PARTIAL.
      DCACHE_FB_PARTIAL : integer := 1;
      -- A write-back followed by an ALLOC does not wait for the line to
      -- cross; see cpu.vhd's DCACHE_WB_EARLY.
      DCACHE_WB_EARLY : integer := 1;
      -- The load-delay bubble only for a dependent instruction; see cpu.vhd's
      -- LOAD_INTERLOCK.
      LOAD_INTERLOCK : integer := 1;
      -- A one-entry store buffer in the data cache; see cpu.vhd's
      -- DCACHE_STORE_BUFFER.
      DCACHE_STORE_BUFFER : integer := 1;
      -- The crossing to the bridge without synchronisers; see cpu.vhd's
      -- SYNC_CROSSING. clk_cpu and clk_core are phase-0 outputs of one PLL
      -- at 2:1, and KillerInstinct.sdc times the paths between them.
      SYNC_CROSSING : integer := 1;
      -- An LWL/LWR/LDL/LDR behind a load of its rt takes no bubble, as on the
      -- R4600; see cpu.vhd's LOAD_MERGE_BYPASS.
      LOAD_MERGE_BYPASS : integer := 1;
      -- The data cache reads the next line ahead; see cpu.vhd's
      -- DCACHE_READ_AHEAD. KI's heavy frames miss almost always on the line
      -- after the previous miss.
      DCACHE_READ_AHEAD : integer := 1
   );
   port
   (
      clk1x          : in  std_logic;
      clk93          : in  std_logic;
      reset          : in  std_logic;
      irq            : in  std_logic_vector(1 downto 0);
      -- The system is paused. Synchronised into clk93, it stops Count and
      -- keeps the stall watchdog from flagging a CPU the memory bridge is
      -- holding on purpose; see ki_memory_bridge's cpu_hold.
      pause          : in  std_logic := '0';

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
      mem_line_bytes : out std_logic_vector(31 downto 0);
      mem_dataRead   : in  std_logic_vector(63 downto 0);
      mem_done       : in  std_logic;
      cache_grant    : in  std_logic;
      cache_data     : in  std_logic_vector(63 downto 0);
      cache_data_ready : in std_logic;

      errors         : out std_logic_vector(5 downto 0);
      debug_fetch_pc : out std_logic_vector(31 downto 0);
      debug_retired  : out std_logic_vector(31 downto 0);
      -- WHERE the frame's instructions retired, in seventeen 16-bit fields of
      -- 256: nine COARSE buckets and eight FINE ones. See PROF_LO below.
      debug_perf_prof : out std_logic_vector(271 downto 0);
      -- Which coarse bucket the fine map currently covers. The page has to
      -- say so, or F0..F7 are eight numbers with no address attached.
      debug_prof_fine : out std_logic_vector(2 downto 0);
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

      -- Per-game-frame stall census, built from cpu.vhd's debug_perf_events.
      --
      -- Effective speed is clock x IPC. These answer the IPC half: of the
      -- cycles in a game frame, how many retired an instruction and how many
      -- went to each kind of stall.
      --
      -- perf_flip changes level on every page flip, the game's switch to a
      -- newly drawn frame; it is synchronised here, and each change closes a
      -- window: the counters are latched and cleared, so the exported values
      -- describe ONE game frame and are stable for the whole of the next one -
      -- which is what makes them safe to sample from another clock domain
      -- without a handshake. A window is a whole game frame, however many
      -- vblanks it took, including any wait for the vblank it flips at.
      --
      -- A window also closes when CY saturates: 2^24 cycles with no flip,
      -- about ten vblanks at 100 MHz. A scene that is not flipping still
      -- updates the page, and reads CY FFFF.
      --
      -- Each field is 16 bits counting units of 256 cycles, saturating. One
      -- vblank at 100 MHz is about 1.70M cycles, 19DE hex units, so a game
      -- frame at 59 fps reads about 19DE and one at 30 fps twice that.
      --
      --   field 0 cycles           CY    6 other uncached load     UO
      --         1 retired          RT    7 stall4, cached          DC
      --         2 D-cache miss COUNT      MC   8 multiply / divide   MD
      --         3 uncached store   UW    9 other stage-3 stall     S3
      --         4 stall4           S4   10 fetch stall             S1
      --         5 uncached FB load UF   11 load delay              LB
      --                                    12 low-region miss COUNT   LM
      --                                    13 recoverable load bubble DI
      --
      -- THE LOST-CYCLE CENSUS (see debug_perf_events in cpu.vhd). Every cycle
      -- either retires an instruction or is lost to exactly one cause, so
      --    CY - RT = S4 + MD + S3 + S1 + LB (+ FL, off the page and ~0)
      -- to within a unit or two of rounding, and S4 = DC + UW + UF + UO -
      -- the page's two self-checks. UO holds the disk's data-port reads, so
      -- a frame waiting on the disk shows there.
      --
      -- The second block keeps the slowest game frame since the last clear,
      -- header SLOWEST: the longest window a flip both opened and closed.
      perf_flip               : in  std_logic;
      -- While high, hold the slowest-frame capture cleared. Release it to
      -- start a fresh capture.
      perf_clear              : in  std_logic;
      -- Per-frame values from ki_memory_bridge. Stable for a whole frame, so
      -- two flops are enough to bring them over; the residual risk is a torn
      -- read in the single cycle they change, once per frame, on a diagnostic.
      perf_bridge_out         : in  std_logic_vector(15 downto 0);
      perf_bridge_burst       : in  std_logic_vector(15 downto 0);
      debug_perf_bus          : out std_logic_vector(223 downto 0) := (others => '0');
      -- The slowest game frame seen since the last clear. Gameplay slowdowns
      -- are occasional, so a photograph of the live values usually catches a
      -- good frame; this keeps the bad one. Every field comes from the SAME
      -- frame, so the row still reads as one coherent census rather than a set
      -- of unrelated maxima.
      debug_perf_worst        : out std_logic_vector(223 downto 0) := (others => '0')
   );
end entity;

architecture rtl of ki_cpu_core is
   signal address_u      : unsigned(31 downto 0);
   signal size_u         : unsigned(2 downto 0);
   signal reset_1x_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal reset_93_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal irq_meta       : std_logic_vector(1 downto 0) := (others => '0');
   signal irq_sync       : std_logic_vector(1 downto 0) := (others => '0');
   signal pause_meta     : std_logic := '0';
   signal pause_sync     : std_logic := '0';

   -- Performance census. See debug_perf_bus in the port list.
   -- 0 CY, 1 RT, then one per debug_perf_events bit.
   constant PERF_N       : integer := 14;
   -- The profile's window and bucket size. 0x88000000 is KSEG0 RAM, where the
   -- game runs from, and 32 KB buckets put a KI frame's two hot regions in
   -- separate bins: B2 (0x88010000) and B6 (0x88030000, the sprite blitter).
   -- Anything outside the window lands in the ninth field rather than
   -- aliasing into a real bucket, which is what stops the boot ROM or an
   -- exception vector being read as game code.
   constant PROF_N       : integer := 9;
   constant PROF_LO      : unsigned(31 downto 0) := unsigned(PROF_BASE);
   constant PROF_HI      : unsigned(31 downto 0) := unsigned(PROF_BASE) + x"0003FFFF";
   -- A SECOND, finer map inside ONE coarse bucket, because 32 KB is too wide
   -- to name a loop. Eight 4 KB bins, counted at the same time as the coarse
   -- ones so the page shows both maps of one frame.
   --
   -- It follows the hottest coarse bucket rather than a fixed one, so it aims
   -- itself at whichever game is running.
   constant FINE_N       : integer := 8;
   type t_prof is array(0 to PROF_N - 1) of unsigned(23 downto 0);
   type t_fine is array(0 to FINE_N - 1) of unsigned(23 downto 0);
   type t_perf is array(0 to PERF_N - 1) of unsigned(23 downto 0);
   signal perf_cnt       : t_perf := (others => (others => '0'));
   signal perf_events    : std_logic_vector(11 downto 0);
   signal debug_retired_i : std_logic_vector(31 downto 0);
   signal prof_pc_i       : std_logic_vector(31 downto 0);
   signal prof_valid_i    : std_logic;
   signal perf_flip_meta  : std_logic_vector(2 downto 0) := (others => '0');
   -- perf_clear comes from the OSD, so it crosses into clk93 like perf_flip
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
         pause_meta    <= '0';
         pause_sync    <= '0';
      elsif (rising_edge(clk93)) then
         reset_93_pipe <= reset_93_pipe(0) & '0';
         irq_meta      <= irq;
         irq_sync      <= irq_meta;
         pause_meta    <= pause;
         pause_sync    <= pause_meta;
      end if;
   end process;

   core : entity work.cpu
      generic map
      (
         LITTLE_ENDIAN        => true,
         DCACHE_SKIP_FILL     => (DCACHE_SKIP_FILL /= 0),
         DCACHE_FB_PARTIAL    => (DCACHE_FB_PARTIAL /= 0),
         DCACHE_WB_EARLY      => (DCACHE_WB_EARLY /= 0),
         LOAD_INTERLOCK       => (LOAD_INTERLOCK /= 0),
         DCACHE_STORE_BUFFER  => (DCACHE_STORE_BUFFER /= 0),
         SYNC_CROSSING        => (SYNC_CROSSING /= 0),
         LOAD_MERGE_BYPASS    => (LOAD_MERGE_BYPASS /= 0),
         DCACHE_READ_AHEAD    => (DCACHE_READ_AHEAD /= 0),
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
         cpuPaused             => pause_sync,
         error_instr           => errors(0),
         error_stall           => errors(1),
         error_FPU             => errors(2),
         error_exception       => errors(3),
         error_fifo            => errors(4),
         error_TLB             => errors(5),
         debug_fetch_pc        => debug_fetch_pc,
         debug_retired         => debug_retired_i,
         debug_prof_pc         => prof_pc_i,
         debug_prof_valid      => prof_valid_i,
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
         mem_line_bytes        => mem_line_bytes,
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
      -- The slowest frame's CY: the second block's key.
      signal worst_key    : unsigned(23 downto 0) := (others => '0');
      -- CY has reached 2^24 - 1: the window closes on the next clock.
      -- Registered, so the window's end is two flops' function rather than a
      -- 24-bit compare on a signal that fans out to every counter.
      signal cy_full      : std_logic := '0';
      -- A flip opened this window. Only such a window, closed by a flip, is
      -- one game frame; one opened by reset or by a full CY started part way
      -- through a frame.
      signal win_flip     : std_logic := '0';
      signal prof_cnt     : t_prof := (others => (others => '0'));
      signal fine_cnt     : t_fine := (others => (others => '0'));
      -- The PROF page and the Perf page's second block latch the SAME window:
      -- the slowest game frame since the last clear, so SUM(B)/CY is a real
      -- check rather than two pages describing two frames.
      --
      -- The frame rate is set by exactly these windows: the game shows a frame
      -- at each flip, so the longest flip-to-flip window is the frame that
      -- held the rate down. Its wait for the vblank it flips at, if any, is
      -- inside it; the PROF page shows which code that time ran.
      --
      -- It is the slowest frame SINCE CLEAR, of ANY scene: a video playing at
      -- a lower rate than the fight around it wins. To measure a scene, Clear
      -- DURING it.
      -- The hottest coarse bucket, tracked incrementally: one compare against
      -- the bucket being bumped, never a 9-way maximum, because this design is
      -- placement-bound at 100 MHz and a comparison tree here is not free.
      -- Copied into fine_base when a slowest frame is latched, so the fine map
      -- follows the slowest type of frame rather than whichever came last.
      signal hot_val      : unsigned(23 downto 0) := (others => '0');
      signal hot_idx      : unsigned(2 downto 0)  := (others => '0');
      signal fine_base    : unsigned(2 downto 0)  := (others => '0');
      -- Which bucket the instruction retiring this cycle belongs to, and
      -- whether it belongs to any. Combinational from the CPU's own retire
      -- condition, so these sum to RT.
      signal prof_pc_u    : unsigned(31 downto 0);
      signal prof_idx     : integer range 0 to PROF_N - 1;
      signal fine_idx     : integer range 0 to FINE_N - 1;
      signal fine_hit     : std_logic;

      -- Saturating so a long frame reads as "pinned" rather than wrapping to a
      -- small number.
      function bump(v : unsigned(23 downto 0); e : std_logic) return unsigned is
      begin
         if (e = '1' and v /= x"FFFFFF") then
            return v + 1;
         end if;
         return v;
      end function;

   -- DI (13) is NOT in this list: it is a count of load-bubble CYCLES and is
   -- read against LB, so it has LB's units of 256. A frame has far more of
   -- them than a raw 16-bit count can hold.
   --
   -- MC (2) and LM (12) are COUNTS, not cycles. Scaling them by 256 like a
   -- cycle counter would throw away the resolution that matters, so these two
   -- export their LOW bits and the page shows the count itself, up to 65,535.
   -- A game frame of several vblanks can miss more often than that, so a
   -- larger count reads FFFF rather than its low 16 bits.
   function perf_slice(v : unsigned(23 downto 0); idx : integer)
      return std_logic_vector is
   begin
      if (idx = 2 or idx = 12) then
         if (v(23 downto 16) /= 0) then
            return x"FFFF";
         end if;
         return std_logic_vector(v(15 downto 0));
      end if;
      return std_logic_vector(v(23 downto 8));
   end function;

   begin
      prof_pc_u <= unsigned(prof_pc_i);
      -- Bucket 8 is "outside the window", deliberately NOT bucket 0: a
      -- counter that folds the unknown into a real bin reads as game code.
      prof_idx  <= to_integer(prof_pc_u(17 downto 15))
                   when (prof_pc_u >= PROF_LO and prof_pc_u <= PROF_HI)
                   else PROF_N - 1;
      fine_hit  <= '1' when (prof_pc_u >= PROF_LO and prof_pc_u <= PROF_HI and
                             prof_pc_u(17 downto 15) = fine_base)
                   else '0';
      fine_idx  <= to_integer(prof_pc_u(14 downto 12));

      process (clk93)
         variable flip : std_logic;
         variable tick : std_logic;
         -- synthesis translate_off
         variable fsum : unsigned(27 downto 0);
         -- synthesis translate_on
      begin
         if (rising_edge(clk93)) then
            flip := perf_flip_meta(1) xor perf_flip_meta(2);
            tick := flip or cy_full;
            -- synthesis translate_off
            -- THE PROF INVARIANT, checked at EVERY window end, not just at a
            -- latch. Within a window the fine map counts only the bucket
            -- fine_base names and fine_base moves only at a window end, so the
            -- fine bins must sum to that bucket's coarse count EXACTLY.
            if (tick = '1' and reset_93_pipe(1) = '0') then
               fsum := (others => '0');
               for i in 0 to FINE_N - 1 loop
                  fsum := fsum + resize(fine_cnt(i), 28);
               end loop;
               -- Printed every frame so a run can SHOW it was not vacuous:
               -- an assertion that only ever compares 0 with 0 passes forever.
               report "PROF tick: B" & integer'image(to_integer(fine_base)) &
                      " = " & integer'image(to_integer(prof_cnt(to_integer(fine_base)))) &
                      ", SUM(F) = " & integer'image(to_integer(fsum)) &
                      ", hot B" & integer'image(to_integer(hot_idx))
                  severity note;
               assert fsum = resize(prof_cnt(to_integer(fine_base)), 28)
                  report "PROF: fine bins sum to " & integer'image(to_integer(fsum)) &
                         " but bucket B" & integer'image(to_integer(fine_base)) &
                         " counted " & integer'image(to_integer(prof_cnt(to_integer(fine_base))))
                  severity error;
            end if;
            -- synthesis translate_on
            perf_flip_meta  <= perf_flip_meta(1 downto 0) & perf_flip;
            perf_clear_meta <= perf_clear_meta(0) & perf_clear;

            if (reset_93_pipe(1) = '1') then
               perf_cnt         <= (others => (others => '0'));
               prof_cnt         <= (others => (others => '0'));
               fine_cnt         <= (others => (others => '0'));
               hot_val          <= (others => '0');
               hot_idx          <= (others => '0');
               fine_base        <= (others => '0');
               debug_perf_prof  <= (others => '0');
               debug_prof_fine  <= (others => '0');
               retired_prev     <= (others => '0');
               retired_cnt      <= (others => '0');
               worst_key        <= (others => '0');
               debug_perf_worst <= (others => '0');
               cy_full          <= '0';
               win_flip         <= '0';
            elsif (tick = '1') then
               -- Latch the window just closed, then open the next.
               for i in 0 to PERF_N - 1 loop
                  debug_perf_bus(i * 16 + 15 downto i * 16)
                     <= perf_slice(perf_cnt(i), i);
               end loop;
               debug_perf_bus(31 downto 16)
                  <= std_logic_vector(retired_cnt(23 downto 8));
               -- Keep the slowest game frame - for BOTH pages, so they
               -- describe one frame. Compared before the counters are
               -- cleared. A window that reached a full CY is not one, even if
               -- a flip closes it on that same clock.
               --
               -- PROF latches UNCONDITIONALLY with the Perf slowest block, not
               -- only when hot_idx = fine_base, i.e. only when the fine map is
               -- already aimed at this frame's own hottest bucket. When frames
               -- alternate between hot buckets, such a gate can drop every
               -- frame. A guard that silently discards the measurement is
               -- worse than a measurement that is sometimes mis-aimed.
               --
               -- The aim follows the last LATCHED frame rather than the last
               -- frame, so it converges on the slowest type of frame even when
               -- frames alternate. The header names the bucket the fine
               -- counts were taken in, so SUM(F) against that bucket still
               -- shows whether a given capture was aimed: equal means aimed,
               -- anything else means the fine map describes another bucket.
               -- The coarse map is right either way.
               if (perf_clear_meta(1) = '1') then
                  debug_perf_prof  <= (others => '0');
                  debug_perf_worst <= (others => '0');
                  worst_key        <= (others => '0');
               elsif (flip = '1' and cy_full = '0' and win_flip = '1' and
                      perf_cnt(0) > worst_key) then
                  worst_key <= perf_cnt(0);
                  -- The base the fine counts were binned under, captured
                  -- before it moves.
                  debug_prof_fine <= std_logic_vector(fine_base);
                  fine_base       <= hot_idx;
                  for i in 0 to PROF_N - 1 loop
                     debug_perf_prof(i * 16 + 15 downto i * 16)
                        <= std_logic_vector(prof_cnt(i)(23 downto 8));
                  end loop;
                  for i in 0 to FINE_N - 1 loop
                     debug_perf_prof((PROF_N + i) * 16 + 15 downto (PROF_N + i) * 16)
                        <= std_logic_vector(fine_cnt(i)(23 downto 8));
                  end loop;
                  for i in 0 to PERF_N - 1 loop
                     debug_perf_worst(i * 16 + 15 downto i * 16)
                        <= perf_slice(perf_cnt(i), i);
                  end loop;
                  debug_perf_worst(31 downto 16)
                     <= std_logic_vector(retired_cnt(23 downto 8));
               end if;

               win_flip     <= flip;
               cy_full      <= '0';
               perf_cnt     <= (others => (others => '0'));
               prof_cnt     <= (others => (others => '0'));
               fine_cnt     <= (others => (others => '0'));
               hot_val      <= (others => '0');
               retired_cnt  <= (others => '0');
               retired_prev <= unsigned(debug_retired_i);
            else
               perf_cnt(0) <= bump(perf_cnt(0), '1');
               if (perf_cnt(0) = x"FFFFFE") then
                  cy_full <= '1';
               end if;
               for b in 0 to 11 loop
                  perf_cnt(b + 2) <= bump(perf_cnt(b + 2), perf_events(b));
               end loop;
               -- Retired is a free-running total in cpu.vhd, so difference it
               -- against the value at the start of this window.
               retired_cnt <= resize(unsigned(debug_retired_i) - retired_prev, 24);
               prof_cnt(prof_idx) <= bump(prof_cnt(prof_idx), prof_valid_i);
               fine_cnt(fine_idx) <= bump(fine_cnt(fine_idx),
                                          prof_valid_i and fine_hit);
               -- One compare, against the bucket that just moved, never a
               -- 9-way maximum: this design is placement-bound at 100 MHz and
               -- a comparison tree here would not be free. The OT bucket is
               -- excluded - it is "outside the window", so aiming the fine map
               -- at it would mean nothing.
               if (prof_valid_i = '1' and prof_idx < PROF_N - 1 and
                   bump(prof_cnt(prof_idx), '1') > hot_val) then
                  hot_val <= bump(prof_cnt(prof_idx), '1');
                  hot_idx <= to_unsigned(prof_idx, 3);
               end if;
            end if;
         end if;
      end process;
   end generate gperf;

   gperf_off : if DEBUG_TRACE = 0 generate
      debug_perf_bus   <= (others => '0');
      debug_perf_worst <= (others => '0');
      debug_perf_prof  <= (others => '0');
      debug_prof_fine  <= (others => '0');
   end generate gperf_off;
end architecture;
