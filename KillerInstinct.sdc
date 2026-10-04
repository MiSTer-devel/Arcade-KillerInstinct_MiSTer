derive_pll_clocks
derive_clock_uncertainty

# The CPU clock is asynchronous to the SDRAM clocks - and RELATED to clk_core.
#
# sys_top.sdc puts every output of this PLL in ONE -exclusive group. When the
# CPU ran at 75 MHz, it and the 50 MHz clk_core were therefore analysed as
# RELATED clocks. Related clocks are given a setup window of gcd(T_a, T_b): at
# 75/50 MHz that was 6.667 ns. The window is NOT monotonic in frequency - it
# collapses to 2.5 ns at 80 MHz and 2.222 ns at 90 MHz, then reopens at the
# current 100 MHz target, where the ratio is a clean 2:1. Raising the CPU clock
# with the pair related therefore used to break ~1867 paths that had nothing
# to do with CPU speed, and no fitter seed can recover a window that
# arithmetic has closed. Quartus hides this: Fmax is computed only for
# same-clock paths, so the Fmax Summary never showed them. So from 75 MHz on,
# this file made the CPU clock asynchronous to everything.
#
# AT 2:1 THE PAIR IS RELATED AGAIN, ON PURPOSE. clk_cpu and clk_core are PLL
# outputs 1 and 0, both at 0 ps: every clk_core edge falls on a clk_cpu edge,
# and each direction has a 10 ns setup window. The CPU-to-bridge crossing
# relies on that under SYNC_CROSSING (cpu.vhd, "THE CROSSING"; ki_cpu_core
# defaults it on): its mailbox request and acknowledge, the write-back line
# release and the response FIFO's pointers are read straight from the other
# domain's register, with no synchroniser - 4.9% of KI2's renderer, measured
# in tb_ki_renderbench. Those paths MUST be timed. A false path or an
# asynchronous group here would let the fitter route one of them in 12 ns,
# and nothing else protects them.
#
# THE 2:1 RATIO IS THE CONTRACT. Before moving the CPU clock off twice
# clk_core, build with SYNC_CROSSING=0 and make the CPU clock asynchronous to
# everything again.
#
# With SYNC_CROSSING=0 the crossing is asynchronous by construction, and
# timing it as well costs nothing. Every crossing is one of:
#   - the memory REQUEST mailbox in cpu.vhd, a two-phase req/ack handshake
#     whose payload is held stable until the acknowledge returns;
#   - the memory RESPONSE FIFO (cpu_cdc_fifo.vhd), whose gray-coded pointers
#     change one bit per increment, so a pointer sampled mid-transition reads
#     the old value or the new one and never a mixture. Its payload array is
#     bundled data on the same argument as the mailbox's payload register:
#     an entry is complete no later than the pointer that exposes it;
#   - the cache fill line address (cpu_instrcache fill_addrTag_sav,
#     cpu_datacache fill_line_saved), written only in the clk93 state
#     machine's IDLE state and frozen from the request until ram_done, which
#     is itself produced by the response handshake;
#   - the data cache read-ahead's fetched line (cpu.vhd line_fill_1x),
#     written in clk1x only while its own fetch is outstanding and copied
#     into clk93 only when that fetch's completion has crossed the response
#     FIFO, so its last beat is in no later than the completion;
#   - the first stage of a two-flop synchroniser (irq_meta, trace_trigger_meta,
#     debug_vblank_cpu_meta, the debug counter mirrors below).
# Reset was the one exception: the caches' clk1x fill processes were reset by
# reset_93. They now take reset_1x, which ki_cpu_core already synchronises
# into that domain, so nothing crosses unsynchronised.
#
# This must stay in THIS file: sys.tcl loads sys_top.sdc first, and its
# -exclusive group would otherwise be applied after this one. The SDRAM pin
# clock, KI_SDRAM_CLK, is created below and is made asynchronous to the CPU
# there.
set_clock_groups -asynchronous \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
                      emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk \
                      emu|pll|pll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}]

# Physical SDRAM runs from clk_sdram_ctl (PLL output 4) at 100 MHz. The pin
# clock is PLL output 3 at the same frequency with a 6.75 ns (243 deg) shift.
# Do not change it without re-running sim/tb_ki_sdram_phase.sv.
#
# 6.75 was chosen as TCK - 3.25, the centre of the window that sweep measured
# with the controller capturing DQ on its own clock. The shipped design no
# longer does that - clk_sdram_cap captures, with a handoff stage behind it -
# and re-measuring in THAT configuration moves the window:
#
#   window 5.50 .. 10.00 ns of the PLL phase_shift, centre 7.75
#   6.75 sits 1.25 ns above the low edge and 3.25 ns below the high one
#
# So the pin phase is inside the window but no longer central, and the low edge
# is nearer than TCK - 3.25 implies. The sweep's top point is the 10.00 ns
# period itself, so the true window may extend past it.
#
# This is recorded rather than acted on. The value works on hardware, and the
# sweep's phase is not the PLL's: SDRAM_CLK takes 13.79 ns to reach the device
# pin while a capture clock takes 8.21 ns to reach a register, and ignoring
# that 5.58 ns is exactly what produced three broken builds. Moving the pin
# phase is an A/B on hardware, not an edit.
create_generated_clock -name KI_SDRAM_CLK \
  -source [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]
set_clock_groups -asynchronous \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {KI_SDRAM_CLK}]

# MT48LC16M16 CAS2 interface timing. These bounds match the established
# MiSTer SDRAM controller constraints used by the local Wolf-unit donor.
set_input_delay -clock KI_SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock KI_SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock KI_SDRAM_CLK -max 1.5 \
  [get_ports {SDRAM_A* SDRAM_BA* SDRAM_D* SDRAM_CKE SDRAM_n*}]
set_output_delay -clock KI_SDRAM_CLK -min -0.8 \
  [get_ports {SDRAM_A* SDRAM_BA* SDRAM_D* SDRAM_CKE SDRAM_n*}]

# The request direction of the 2:1 crossing inside ki_sdram_adapter.
# clk_sdram_ctl sits 500 ps after clk_core (see rtl/pll/pll_0002.v for why it
# cannot sit at 0), which leaves only 0.5 ns to the very next clk_sdram_ctl
# edge. Two cycles is
# the right number and it is provable rather than hopeful: every signal on this
# path - the adapter's issue_* registers, and the burst controller's addr, din,
# wtbt and burst inputs - is registered on clk_core, so it holds its value for
# a full clk_core period, which is two clk_sdram cycles.
#
# The OPPOSITE direction gets no such relaxation. The pack's 32-bit beat is
# held for two clk_sdram_ctl cycles, but which clk_core edge captures it depends
# on when the burst started, so the honest budget there is one cycle - 9.5 ns at
# this phase. See ki_sdram_x2's header.
set_multicycle_path -setup -end   -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]   -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -hold -end   -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]   -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 1

# The DQ capture path: SDRAM_CLK launches, clk_sdram_cap (general[5]) captures.
#
# Both multicycles below are 2, and BOTH ARE REQUIRED. The capture clock moves
# the sampling edge into the device's data eye; it does not change the fact that
# the eye sits about two periods past the edge TimeQuest picks by default, so
# the multicycle is still what names the right one. Deleting it was a mistake
# once already - the build read garbage.
#
# general[5] is the capture register's clock. general[4] is the handoff out of
# the I/O cell into the controller's domain, one clk_sdram_ctl edge later.
#
# UNVERIFIED: with DQ_CAP=1 every SDRAM_DQ input path should terminate in
# general[5], which would leave the general[4] constraint matching nothing.
# It is kept because that has NOT been checked against a fitted netlist, and
# because a multicycle that matches nothing costs nothing while a missing one
# cost a day. Confirm it applies to zero paths before removing it.
#
# If either phase changes, re-measure with sim/tb_ki_sdram_phase.sv before
# assuming any of this still holds.
set_multicycle_path -setup -end   -rise_from [get_clocks {KI_SDRAM_CLK}]   -rise_to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -setup -end   -rise_from [get_clocks {KI_SDRAM_CLK}]   -rise_to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 2

# Passive CPU diagnostics cross from the 100 MHz CPU domain through explicit
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
