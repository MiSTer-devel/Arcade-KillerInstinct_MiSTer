library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- clk1x and clk2x must be phase-0 outputs of one PLL at 2:1, with
-- KillerInstinct.sdc timing the paths between them: cpu.vhd crosses between
-- them without synchronisers (see its "THE CROSSING").
entity ki_cpu_core is
   port
   (
      clk1x          : in  std_logic;
      clk2x          : in  std_logic;
      reset          : in  std_logic;
      irq            : in  std_logic_vector(1 downto 0);
      -- The system is paused. Synchronised into clk2x, it stops Count and
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
   signal reset_2x_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal irq_meta       : std_logic_vector(1 downto 0) := (others => '0');
   signal irq_sync       : std_logic_vector(1 downto 0) := (others => '0');
   signal pause_meta     : std_logic := '0';
   signal pause_sync     : std_logic := '0';

   -- The core's lost-cycle census, cpu.vhd's debug_perf_events, in
   -- simulation only. Nothing here reads it; it is there to measure the CPU
   -- by.
-- synthesis translate_off
   signal perf_events    : std_logic_vector(11 downto 0);
-- synthesis translate_on
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

   process (clk2x, reset)
   begin
      if (reset = '1') then
         reset_2x_pipe <= (others => '1');
         irq_meta      <= (others => '0');
         irq_sync      <= (others => '0');
         pause_meta    <= '0';
         pause_sync    <= '0';
      elsif (rising_edge(clk2x)) then
         reset_2x_pipe <= reset_2x_pipe(0) & '0';
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
         -- KI uses the 32-bit exception-address contract.
         ADDR32_ONLY          => true,
         -- KI does not use the optional trap-instruction exception path.
         NO_TRAP_INSTR        => true,
         -- KI instruction fetches use KSEG0/KSEG1.
         INSTR_KSEG_ONLY      => true,
         -- KI never converts a long outside +-2^55 to floating point.
         FPU_CVT_L_NARROW     => true,
         -- Both games' exception handlers serve only the timer interrupt and
         -- restart the board on any other cause, so neither takes an address
         -- error or a floating-point trap.
         NO_ADDRESS_ERROR     => true,
         NO_FPU_EXCEPTION     => true
      )
      port map
      (
         clk1x                 => clk1x,
         clk2x                 => clk2x,
         reset_1x              => reset_1x_pipe(1),
         reset_2x              => reset_2x_pipe(1),
         -- The data cache is write-back, as on the R4600; write-through is
         -- not used.
         DATACACHEWRITETHROUGH => '0',
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
-- synthesis translate_off
         debug_perf_events       => perf_events,
         cpu_done              => open,
         cpu_export            => open,
-- synthesis translate_on
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
         fast_ra_valid         => fast_ra_valid
      );
end architecture;
