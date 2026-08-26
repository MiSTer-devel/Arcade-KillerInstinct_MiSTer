derive_pll_clocks
derive_clock_uncertainty

# The CPU clock is asynchronous to the rest of the design.
#
# sys_top.sdc puts every output of this PLL in ONE -exclusive group, so the
# 75 MHz CPU clock and the 50 MHz clk_core were analysed as RELATED clocks.
# Related clocks are given a setup window of gcd(T_a, T_b): at 75/50 MHz that
# is 6.667 ns, and the 1867 paths crossing the boundary passed with about 1 ns
# to spare. The window is NOT monotonic in frequency - it collapses to 2.5 ns
# at 80 MHz and 2.222 ns at 90 MHz, and only reopens at 100 MHz, where the
# ratio is a clean 2:1. Raising the CPU clock at all therefore used to break
# ~1867 paths that had nothing to do with CPU speed, and no fitter seed can
# recover a window that arithmetic has closed. Quartus hides this: Fmax is
# computed only for same-clock paths, so the Fmax Summary never showed them.
#
# The boundary is genuinely asynchronous by construction. Every crossing is
# one of:
#   - the memory request/response mailboxes in cpu.vhd, two-phase req/ack
#     handshakes whose payload is held stable until the acknowledge returns;
#   - the cache fill line address (cpu_instrcache fill_addrTag_sav,
#     cpu_datacache fill_line_saved), written only in the clk93 state
#     machine's IDLE state and frozen from the request until ram_done, which
#     is itself produced by the response handshake;
#   - the first stage of a two-flop synchroniser (irq_meta, trace_trigger_meta,
#     debug_vblank_cpu_meta, the debug counter mirrors below).
# Reset was the one exception: the caches' clk1x fill processes were reset by
# reset_93. They now take reset_1x, which ki_cpu_core already synchronises
# into that domain, so nothing crosses unsynchronised.
#
# This must stay in THIS file: sys.tcl loads sys_top.sdc first, and its
# -exclusive group would otherwise be applied after this one.
set_clock_groups -asynchronous -group [get_clocks \
  {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

# Physical SDRAM runs from clk_core at 50 MHz. The pin clock is PLL output 3
# at the same frequency with a 16.75 ns (301.5 degree) phase shift - the centre
# of the read window measured by sim/tb_ki_sdram_phase.sv. Do not change this
# without re-running that sweep; the window has a hard lower edge at 14.00 ns
# and the previous 14.48 ns value sat 0.48 ns above it.
create_generated_clock -name KI_SDRAM_CLK \
  -source [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# MT48LC16M16 CAS2 interface timing. These bounds match the established
# MiSTer SDRAM controller constraints used by the local Wolf-unit donor.
set_input_delay -clock KI_SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock KI_SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock KI_SDRAM_CLK -max 1.5 \
  [get_ports {SDRAM_A* SDRAM_BA* SDRAM_D* SDRAM_CKE SDRAM_n*}]
set_output_delay -clock KI_SDRAM_CLK -min -0.8 \
  [get_ports {SDRAM_A* SDRAM_BA* SDRAM_D* SDRAM_CKE SDRAM_n*}]

set_multicycle_path -setup -end \
  -rise_from [get_clocks {KI_SDRAM_CLK}] \
  -rise_to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 2

# Passive CPU diagnostics cross from the 75 MHz CPU domain through explicit
# two-stage synchronizers. Only the metastability-catching stages are async.
set_false_path -to [get_keepers {*|debug_cpu_pc_meta[*]}]
set_false_path -to [get_keepers {*|debug_cpu_retired_meta[*]}]

# The frozen pre-event trace. debug_trace_frozen_meta is the ordinary
# metastability-catching stage; debug_trace_shadow is a 736-bit single-shot
# capture of a source that has already stopped changing, taken only after the
# frozen flag has been synchronised and allowed to settle. Neither is a
# functional path and neither may be allowed to set the clk_core critical
# path - this is a diagnostic, and it must not cost the design a fit.
set_false_path -to [get_keepers {*|debug_trace_frozen_meta}]
set_false_path -to [get_keepers {*|debug_trace_shadow[*]}]
