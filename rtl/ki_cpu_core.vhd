library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ki_cpu_core is
   generic
   (
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
      -- A load of the buffered doubleword is answered from the buffer; see
      -- cpu.vhd's DCACHE_SB_FORWARD.
      DCACHE_SB_FORWARD : integer := 1;
      -- A load miss is answered as soon as its own qword is in, and the next
      -- demand fill may queue behind the rest of the line; see cpu.vhd's
      -- DCACHE_EARLY_RESTART.
      DCACHE_EARLY_RESTART : integer := 1;
      -- A load missing on the staged read-ahead line is answered from the
      -- staging register as the copy ends; see cpu.vhd's DCACHE_RA_ANSWER.
      DCACHE_RA_ANSWER : integer := 1;
      -- A framebuffer line is filled from its access's qword, in sub-block
      -- order; see cpu.vhd's DCACHE_CWF_FB.
      DCACHE_CWF_FB : integer := 1;
      -- A framebuffer miss with a dirty victim is filled before the victim is
      -- written back; see cpu.vhd's DCACHE_FILL_FIRST.
      DCACHE_FILL_FIRST : integer := 1;
      -- That fill is asked for at the miss, the victim staged while it comes;
      -- see cpu.vhd's DCACHE_FILL_AT_MISS.
      DCACHE_FILL_AT_MISS : integer := 1;
      -- A direct uncached load completes without the rotation; see cpu.vhd's
      -- UNC_FAST_DONE.
      UNC_FAST_DONE : integer := 1;
      -- The uncached qword load waiting in stage 3 goes to the direct port on
      -- the edge the uncached load in stage 4 completes; see cpu.vhd's
      -- UNC_LAUNCH_S3.
      UNC_LAUNCH_S3 : integer := 1;
      -- An uncached 64-bit load through the bridge completes without the
      -- rotation; see cpu.vhd's UNC_BRIDGE_FAST_DONE.
      UNC_BRIDGE_FAST_DONE : integer := 1;
      -- The crossing to the bridge without synchronisers; see cpu.vhd's
      -- SYNC_CROSSING. clk_cpu and clk_core are phase-0 outputs of one PLL
      -- at 2:1, and KillerInstinct.sdc times the paths between them.
      SYNC_CROSSING : integer := 1;
      -- An LWL/LWR/LDL/LDR behind a load of its rt takes no bubble, as on the
      -- R4600; see cpu.vhd's LOAD_MERGE_BYPASS.
      LOAD_MERGE_BYPASS : integer := 1;
      -- A load's follower waits for its rt field only if it reads rt, as on
      -- the R4600; see cpu.vhd's LOAD_RT_EXACT.
      LOAD_RT_EXACT : integer := 1;
      -- An FPU add or subtract with no cancellation takes 4 cycles to a
      -- dependent instruction, as on the R4600; see cpu.vhd's FPU_ADD_FAST
      -- and FPU_FORWARD.
      FPU_ADD_FAST : integer := 1;
      FPU_FORWARD : integer := 1;
      -- The data cache reads the next line ahead; see cpu.vhd's
      -- DCACHE_READ_AHEAD. KI's heavy frames miss almost always on the line
      -- after the previous miss.
      DCACHE_READ_AHEAD : integer := 1;
      -- A clean data-cache demand miss fetches its line straight from
      -- ki_sdram_burst's second port, as do the read-ahead's line fetch and
      -- an uncached 64-bit load of SDRAM RAM; see cpu.vhd's DIRECT_FILL.
      DIRECT_FILL : integer := 1;
      -- The read-ahead's line fetch takes the direct port from the data
      -- cache's ask, a cycle sooner; see cpu.vhd's RA_LAUNCH_EARLY.
      RA_LAUNCH_EARLY : integer := 1;
      -- The data cache's read-ahead crosses a 4 KB page for an unmapped load
      -- of low or main RAM; see cpu.vhd's DCACHE_RA_CROSS_PAGE.
      RA_CROSS_PAGE : integer := 1;
      -- A direct read-ahead's line comes back a qword at a time on the
      -- controller's clock, as an uncached qword does; see cpu.vhd's
      -- RA_CTL_RETURN.
      RA_CTL_RETURN : integer := 1;
      -- The read-ahead after the one the data cache waits for leaves as that
      -- one completes; see cpu.vhd's RA_CHAIN (1, or 2 a cycle sooner).
      RA_CHAIN : integer := 1
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
      -- The read is the data cache's read-ahead; see cpu.vhd's mem_line_ra.
      mem_line_ra    : out std_logic;
      mem_line_data  : out std_logic_vector(255 downto 0);
      mem_line_bytes : out std_logic_vector(31 downto 0);
      mem_dataRead   : in  std_logic_vector(63 downto 0);
      mem_done       : in  std_logic;
      cache_grant    : in  std_logic;
      cache_data     : in  std_logic_vector(63 downto 0);
      cache_data_ready : in std_logic;
      -- The direct fill path; see cpu.vhd's port of the same names. Tied off
      -- (fast_ok '0'), it is never used.
      fast_ok        : in  std_logic := '0';
      fast_req_tog   : out std_logic;
      fast_req_line  : out std_logic_vector(31 downto 0);
      fast_req_stream : out std_logic;
      fast_window    : in  std_logic := '0';
      fast_beat      : in  std_logic := '0';
      fast_first     : in  std_logic := '0';
      fast_qword     : in  std_logic_vector(63 downto 0) := (others => '0');
      fast_done_tog  : in  std_logic := '0';
      fast_unc_valid : in  std_logic := '0';
      fast_unc_qword : in  std_logic_vector(63 downto 0) := (others => '0');
      fast_ra_valid  : in  std_logic := '0';

      errors         : out std_logic_vector(5 downto 0);
      debug_fetch_pc : out std_logic_vector(31 downto 0);
      debug_retired  : out std_logic_vector(31 downto 0);
      debug_retire_pc       : out std_logic_vector(31 downto 0);
      debug_retire_opcode   : out std_logic_vector(31 downto 0)
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

   -- The core's lost-cycle census, cpu.vhd's debug_perf_events. Nothing
   -- here reads it; it is there to measure the CPU by, and synthesis prunes
   -- it.
   signal perf_events    : std_logic_vector(11 downto 0);
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
         DCACHE_SB_FORWARD    => (DCACHE_SB_FORWARD /= 0),
         DCACHE_EARLY_RESTART => (DCACHE_EARLY_RESTART /= 0),
         DCACHE_RA_ANSWER     => (DCACHE_RA_ANSWER /= 0),
         DCACHE_CWF_FB        => (DCACHE_CWF_FB /= 0),
         DCACHE_FILL_FIRST    => (DCACHE_FILL_FIRST /= 0),
         DCACHE_FILL_AT_MISS  => (DCACHE_FILL_AT_MISS /= 0),
         UNC_FAST_DONE        => (UNC_FAST_DONE /= 0),
         UNC_LAUNCH_S3        => (UNC_LAUNCH_S3 /= 0),
         UNC_BRIDGE_FAST_DONE => (UNC_BRIDGE_FAST_DONE /= 0),
         SYNC_CROSSING        => (SYNC_CROSSING /= 0),
         LOAD_MERGE_BYPASS    => (LOAD_MERGE_BYPASS /= 0),
         LOAD_RT_EXACT        => (LOAD_RT_EXACT /= 0),
         FPU_ADD_FAST         => (FPU_ADD_FAST /= 0),
         FPU_FORWARD          => (FPU_FORWARD /= 0),
         DCACHE_READ_AHEAD    => (DCACHE_READ_AHEAD /= 0),
         DIRECT_FILL          => (DIRECT_FILL /= 0),
         RA_LAUNCH_EARLY      => (RA_LAUNCH_EARLY /= 0),
         DCACHE_RA_CROSS_PAGE => (RA_CROSS_PAGE /= 0),
         RA_CTL_RETURN        => (RA_CTL_RETURN /= 0),
         RA_CHAIN             => RA_CHAIN,
         -- KI uses the 32-bit exception-address contract.
         ADDR32_ONLY          => true,
         -- KI does not use the optional trap-instruction exception path.
         NO_TRAP_INSTR        => true,
         -- KI instruction fetches use KSEG0/KSEG1.
         INSTR_KSEG_ONLY      => true,
         -- KI never converts a long outside +-2^55 to floating point.
         FPU_CVT_L_NARROW     => true
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
         debug_retired         => debug_retired,
         debug_retire_pc       => debug_retire_pc,
         debug_retire_opcode   => debug_retire_opcode,
         -- Simulation-only taps.
         debug_cop0_cause_live   => open,
         debug_cop0_epc_live     => open,
         debug_perf_events       => perf_events,
         mem_request           => mem_request,
         mem_rnw               => mem_rnw,
         mem_address           => address_u,
         mem_req64             => mem_req64,
         mem_size              => size_u,
         mem_writeMask         => mem_writeMask,
         mem_dataWrite         => mem_dataWrite,
         mem_line_write        => mem_line_write,
         mem_line_ra           => mem_line_ra,
         mem_line_data         => mem_line_data,
         mem_line_bytes        => mem_line_bytes,
         mem_dataRead          => mem_dataRead,
         mem_done              => mem_done,
         rdram_granted2x       => cache_grant,
         rdram_done            => '0',
         ddr3_DOUT             => cache_data,
         ddr3_DOUT_READY       => cache_data_ready,
         fast_ok               => fast_ok,
         fast_req_tog          => fast_req_tog,
         fast_req_line         => fast_req_line,
         fast_req_stream       => fast_req_stream,
         fast_window           => fast_window,
         fast_beat             => fast_beat,
         fast_first            => fast_first,
         fast_qword            => fast_qword,
         fast_done_tog         => fast_done_tog,
         fast_unc_valid        => fast_unc_valid,
         fast_unc_qword        => fast_unc_qword,
         fast_ra_valid         => fast_ra_valid,
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
end architecture;
