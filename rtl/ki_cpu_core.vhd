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
      DEBUG_TRACE    : integer := 1
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
      debug_trace_trigger     : in  std_logic
   );
end entity;

architecture rtl of ki_cpu_core is
   signal address_u      : unsigned(31 downto 0);
   signal size_u         : unsigned(2 downto 0);
   signal reset_1x_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal reset_93_pipe  : std_logic_vector(1 downto 0) := (others => '1');
   signal irq_meta       : std_logic_vector(1 downto 0) := (others => '0');
   signal irq_sync       : std_logic_vector(1 downto 0) := (others => '0');
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
         debug_retired         => debug_retired,
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
         debug_ds_first          => debug_ds_first,
         debug_trace_trigger     => debug_trace_trigger,
         mem_request           => mem_request,
         mem_rnw               => mem_rnw,
         mem_address           => address_u,
         mem_req64             => mem_req64,
         mem_size              => size_u,
         mem_writeMask         => mem_writeMask,
         mem_dataWrite         => mem_dataWrite,
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
end architecture;
