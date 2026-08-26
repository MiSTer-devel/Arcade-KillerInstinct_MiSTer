library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pexport.all;

entity ki_cpu_wrapper is
   port
   (
      clk1x          : in  std_logic;
      clk93          : in  std_logic;
      clk2x          : in  std_logic;
      reset_1x       : in  std_logic;
      reset_93       : in  std_logic;
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

      debug_done     : out std_logic;
      debug_pc       : out std_logic_vector(63 downto 0);
      debug_opcode   : out std_logic_vector(31 downto 0);
      debug_v0       : out std_logic_vector(63 downto 0);
      debug_v1       : out std_logic_vector(63 downto 0);
      debug_a0       : out std_logic_vector(63 downto 0);
      debug_a1       : out std_logic_vector(63 downto 0);
      debug_t2       : out std_logic_vector(63 downto 0);
      debug_a3       : out std_logic_vector(63 downto 0);
      debug_s5       : out std_logic_vector(63 downto 0);
      debug_s6       : out std_logic_vector(63 downto 0);
      debug_errors   : out std_logic_vector(5 downto 0);
      -- The frozen pre-event execution trace. Layout is documented on cpu.vhd's
      -- port of the same name; sim/tb_ki_cpu_trace.sv checks it end to end.
      debug_trace_bus    : out std_logic_vector(895 downto 0);
      debug_trace_frozen : out std_logic;
      debug_cop0_cause   : out std_logic_vector(31 downto 0);
      debug_cop0_epc     : out std_logic_vector(31 downto 0)
   );
end entity;

architecture sim of ki_cpu_wrapper is
   signal address_u    : unsigned(31 downto 0);
   signal size_u       : unsigned(2 downto 0);
   signal export_state : cpu_export_type := export_init;
   signal cpu_done     : std_logic;
   signal errors       : std_logic_vector(5 downto 0);
begin
   mem_address  <= std_logic_vector(address_u);
   mem_size     <= std_logic_vector(size_u);
   debug_done   <= cpu_done;
   debug_pc     <= std_logic_vector(export_state.pc);
   debug_opcode <= std_logic_vector(export_state.opcode);
   debug_v0     <= std_logic_vector(export_state.regs(2));
   debug_v1     <= std_logic_vector(export_state.regs(3));
   debug_a0     <= std_logic_vector(export_state.regs(4));
   debug_a1     <= std_logic_vector(export_state.regs(5));
   debug_t2     <= std_logic_vector(export_state.regs(10));
   debug_a3     <= std_logic_vector(export_state.regs(7));
   debug_s5     <= std_logic_vector(export_state.regs(21));
   debug_s6     <= std_logic_vector(export_state.regs(22));
   debug_errors <= errors;

   core : entity work.cpu
      generic map
      (
         LITTLE_ENDIAN => true,
         -- Match ki_cpu_core: the benches must exercise the configuration
         -- that actually ships, or tb_ki_cpu_badvaddr would be guarding a
         -- capture path the hardware does not build.
         ADDR32_ONLY => true,
         NO_TRAP_INSTR => true,
         INSTR_KSEG_ONLY => true,
         -- Eight decodes without boot ROM arms the restart detectors. The
         -- bench programs are a dozen instructions long, so the hardware
         -- default of 2^26 could never arm inside one; this keeps the gate in
         -- the path being tested rather than bypassing it.
         BOOT_QUIET_BITS => 3
      )
      port map
      (
         clk1x                 => clk1x,
         clk93                 => clk93,
         clk2x                 => clk2x,
         ce_1x                 => '1',
         ce_93                 => '1',
         reset_1x              => reset_1x,
         reset_93              => reset_93,
         preNMI                => '0',
         INSTRCACHEON          => '1',
         DATACACHEON           => '1',
         DATACACHESLOW         => (others => '0'),
         DATACACHEFORCEWEB     => '0',
         -- Match the hardware wrapper's coherent KI bootstrap policy.
         DATACACHEWRITETHROUGH => '0',
         DATACACHETLBON        => '1',
         RANDOMMISS            => (others => '0'),
         DISABLE_BOOTCOUNT     => '0',
         DISABLE_DTLBMINI      => '0',
         ALECK64               => '1',
         irqRequest            => irq,
         cpuPaused             => '0',
         error_instr           => errors(0),
         error_stall           => errors(1),
         error_FPU             => errors(2),
         error_exception       => errors(3),
         error_fifo            => errors(4),
         error_TLB             => errors(5),
         debug_fetch_pc        => open,
         debug_retired         => open,
         debug_irq_count       => open,
         debug_t2_reload_count => open,
         debug_retire_pc       => open,
         debug_retire_opcode   => open,
         debug_trace_bus       => debug_trace_bus,
         debug_trace_frozen    => debug_trace_frozen,
         debug_cop0_cause_live => debug_cop0_cause,
         debug_cop0_epc_live   => debug_cop0_epc,
         debug_eret_epc        => open,
         debug_eret_target     => open,
         debug_eret_flags      => open,
         debug_ds_count        => open,
         debug_ds_first        => open,
         debug_trace_trigger   => '0',
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
         cpu_done              => cpu_done,
         cpu_export            => export_state,
         SS_reset              => reset_93,
         loading_savestate     => '0',
         SS_DataWrite          => (others => '0'),
         SS_Adr                => (others => '0'),
         SS_wren_CPU           => '0',
         SS_rden_CPU           => '0',
         SS_DataRead_CPU       => open,
         SS_idle               => open
      );
end architecture;
