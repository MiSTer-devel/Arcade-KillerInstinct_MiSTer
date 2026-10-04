`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

	// interface 'outclk3'
	output wire outclk_3,
	output wire outclk_4,
	output wire outclk_5,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(6),
		.output_clock_frequency0("50.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		// clk_cpu: the MIPS core. 100 MHz - the name in KillerInstinct.sv used to
		// say 75 and was wrong for as long as it said it.
		.output_clock_frequency1("100.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		// clk_ddr: DDRAM_CLK and the bridge's DDR side. Configured identically to
		// outclk_1, so Quartus merges the two onto one network and general[2] never
		// appears in the STA clock list. Kept separate because the two have
		// unrelated jobs and the merge is the fitter's call.
		.output_clock_frequency2("100.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("100.000000 MHz"),
		// clk_sdram_pin: leaves the chip as SDRAM_CLK.
		//
		// 6750 ps is the 100 MHz descendant of the 16750 ps this design used at
		// 50 MHz, chosen as TCK - 3.25 ns when the controller captured DQ on its
		// own clock. With DQ captured on clk_sdram_cap, sim/tb_ki_sdram_phase.sv
		// measures the read window as 5.50..10.00 ns of this phase_shift: 6750 ps
		// sits 1.25 ns above its low edge and 3.25 ns below its high one.
		//
		// Why it is measured rather than chosen: the 14480 ps that preceded the
		// 50 MHz value sat 0.48 ns from the edge of the working window, which is no
		// margin at all once pad delay, board trace and PVT are added - and every
		// zero-access-time testbench passed while silicon read corrupt data.
		.phase_shift3("6750 ps"),
		.duty_cycle3(50),
		// clk_sdram_ctl: the SDRAM controller's logic clock.
		//
		// 500 ps, NOT 0, and the offset is load-bearing. At 0 ps this output is
		// configured identically to outclk_1 (clk_cpu, also 100 MHz at 0 ps)
		// and Quartus MERGES them. A build with it at 0 ps put the SDRAM
		// controller on general[1] - the CPU clock, which KillerInstinct.sdc
		// declares ASYNCHRONOUS - so the pack's 2:1 crossing came out
		// unconstrained, in a domain already failing setup at -2.508 ns. The
		// giveaway was outclk_4 appearing ZERO times in the fit report while
		// general[4] existed as a clock with no paths and no transfers at all.
		//
		// 500 ps is the smallest offset that makes the counter configuration
		// distinct - the VCO runs at 500 MHz, so phase steps are 250 ps - while
		// costing the least window. It leaves clk_sdram_ctl -> clk_core at 9.5 ns,
		// which carries the pack's 32-bit beat and must NOT be relaxed by a
		// multicycle (ki_sdram_x2's header says why). The other direction drops
		// to 0.5 ns and is covered by a multicycle in KillerInstinct.sdc, which
		// IS provable there: everything crossing clk_core -> clk_sdram_ctl is
		// registered on clk_core and so stable for two clk_sdram cycles.
		.output_clock_frequency4("100.000000 MHz"),
		.phase_shift4("500 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("100.000000 MHz"),
		// clk_sdram_cap: captures SDRAM_DQ inside the device's data eye.
		//
		// The controller's own clock has no edge where the data is. The device
		// drives a word at pin-phase + tAC and replaces it a clock later, so with
		// the 6750 ps pin phase the eye is 12.75..19.25 ns while clk_sdram_ctl's
		// edges fall at 10.50 and 20.50 - missing it by 1.25 ns. That is what made
		// the first 100 MHz build read garbage and hang loading the ROM, and why no
		// fitter seed rescued it (7 DSE points, zero closing, the spread entirely
		// negative): the constraint already named the nearest edge and there was no
		// better one to name.
		//
		// 1500 ps is MEASURED: sim/tb_ki_sdram_phase.sv with SWEEP_CAP, the dq_stg
		// handoff stage present, reports the window as 1.00..2.50 ns of this
		// phase_shift, checked point by point and not a wrap. 1500 ps sits 0.50 ns
		// above its low edge; the centre is 1750 ps. The windows quoted below were
		// measured against clk_sdram_ctl, 0.50 ns later than this reference.
		//
		// THIS PHASE IS NOT DERIVABLE, and three attempts to derive it all shipped
		// broken builds before that was believed:
		//   6000 ps - ignored insertion delay. SDRAM_CLK spends 13.79 ns reaching
		//             the device PIN, 8.3 of it in the output buffer, while this
		//             clock spends 8.21 ns reaching a REGISTER. That 5.58 ns is
		//             invisible in nominal time and put the capture 3.44 ns early.
		//   4500 ps - traded capture margin for handoff margin by hand. The capture
		//             and the handoff out of the I/O cell pull opposite ways, and
		//             guessing the balance is still guessing.
		//   6250 ps - the measured centre, but measured WITHOUT the handoff stage.
		//             On hardware the ROM loaded (writes correct) and the boot
		//             screen drew a third of the way and restarted forever, which
		//             is what corrupt reads look like.
		// Adding the handoff stage moved the working window from 3.00-9.50 down to
		// 0.50-2.50 and narrowed it from 7.00 ns to 2.50. Re-measure after ANY
		// change to the capture path; do not re-derive.
		.phase_shift5("1500 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_5, outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

