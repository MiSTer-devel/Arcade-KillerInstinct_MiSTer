// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// SDRAM read-window sweep.
//
// The controller's logic clock and the clock forwarded to the SDRAM device pin
// are the same frequency but different phases. The device presents read data
// TAC_NS after ITS OWN edge; the controller captures on ITS edge. Whether those
// line up is decided entirely by the phase shift, and every pre-existing KI
// testbench drove both from one zero-shift clock, so none of them could observe
// this.
//
// This sweeps the phase and reports, for each value, whether the SDRAM path
// stores and returns data correctly. Run it before choosing a phase_shift for
// the PLL, and re-run it whenever the SDRAM clock frequency or the controller's
// read capture path changes.
//
// It sweeps BOTH access shapes the core issues, because they capture
// differently: a single-word read has an idle DQ bus either side of it, while a
// burst captures one word per clock out of a pipelined stream with the device
// driving DQ continuously. The usable phase is the intersection.
module tb_ki_sdram_phase;
  parameter real TCK = 20.0;      // controller clock period (50 MHz)
  parameter real TAC = 6.0;       // device access time
  parameter integer WORDS = 64;   // words per phase point

  logic clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;

  real phase_ns;
  integer pass_count;
  integer fail_count;
  integer point;
  integer run_start;
  integer best_start;
  integer best_end;

  // Controller logic clock.
  always #(TCK / 2.0) clk = ~clk;

  // Device pin clock: every edge of clk reproduced phase_ns later.
  //
  // This must schedule each edge INDEPENDENTLY. A blocking-delay follower
  // (`@(posedge clk); #phase ...`) silently degenerates into a half-rate clock
  // once phase exceeds the half period, because the block is still suspended
  // when the next master edge arrives. `fork ... join_none` with an automatic
  // task argument gives each edge its own scheduled copy, so the device clock
  // is a faithful phase-shifted replica for any phase in [0, TCK).
  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask

  always @(clk) fork emit_edge(clk, phase_ns); join_none

  logic [24:0] request_address = 25'd0;
  logic [63:0] request_write_data = 64'd0;
  logic  [7:0] request_byte_enable = 8'b0000_0011;
  logic  [4:0] request_burst = 5'd1;
  logic request_read = 1'b0;
  logic request_write = 1'b0;
  wire [15:0] request_read_data;
  wire request_data_valid;
  wire request_done;
  wire sdram_ready;

  wire [24:0] controller_address;
  wire [63:0] controller_write_data;
  wire  [7:0] controller_byte_enable;
  wire  [4:0] controller_burst;
  wire controller_read;
  wire controller_write;
  wire [15:0] controller_read_data;
  wire controller_dout_valid;
  wire controller_ready;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire SDRAM_DQML;
  wire SDRAM_DQMH;
  wire [1:0] SDRAM_BA;
  wire SDRAM_nCS;
  wire SDRAM_nWE;
  wire SDRAM_nRAS;
  wire SDRAM_nCAS;
  wire SDRAM_CKE;

  ki_sdram_adapter adapter (
    .clk(clk),
    .reset(reset),
    .request_address(request_address),
    .request_write_data(request_write_data),
    .request_byte_enable(request_byte_enable),
    .request_burst(request_burst),
    .request_read(request_read),
    .request_write(request_write),
    .request_read_data(request_read_data),
    .request_data_valid(request_data_valid),
    .request_done(request_done),
    // Auxiliary (BIST) port unused in this bench.
    .aux_address(25'd0),
    .aux_write_data(64'd0),
    .aux_byte_enable(8'h00),
    .aux_burst(5'd1),
    .aux_read(1'b0),
    .aux_write(1'b0),
    .aux_read_data(),
    .aux_data_valid(),
    .aux_done(),
    .sdram_ready(sdram_ready),
    .controller_address(controller_address),
    .controller_write_data(controller_write_data),
    .controller_byte_enable(controller_byte_enable),
    .controller_burst(controller_burst),
    .controller_read(controller_read),
    .controller_write(controller_write),
    .controller_read_data(controller_read_data),
    .controller_dout_valid(controller_dout_valid),
    .controller_ready(controller_ready)
  );

  ki_sdram_burst controller (
    .init(init),
    .clk(clk),
    .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA),
    .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CKE(SDRAM_CKE),
    .wtbt(controller_byte_enable),
    .addr(controller_address),
    .burst(controller_burst),
    .dout(controller_read_data),
    .dout_valid(controller_dout_valid),
    .din(controller_write_data),
    .we(controller_write),
    .rd(controller_read),
    .ready(controller_ready)
  );

  mt48lc16m16_ki #(.TAC_NS(TAC)) memory (
    .clk(clk_dev),
    .dq(SDRAM_DQ),
    .addr(SDRAM_A),
    .ba(SDRAM_BA),
    .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS),
    .nCAS(SDRAM_nCAS),
    .nWE(SDRAM_nWE),
    .dqm({SDRAM_DQMH, SDRAM_DQML}),
    .cke(SDRAM_CKE)
  );

  // Burst beats, captured as the adapter streams them.
  logic [15:0] got_beat [0:15];
  integer got_n;
  always @(posedge clk) begin
    if (request_data_valid) begin
      if (got_n < 16) got_beat[got_n] <= request_read_data;
      got_n <= got_n + 1;
    end
  end

  task automatic do_write(
    input logic [24:0] word_address,
    input logic [15:0] value
  );
    begin
      @(posedge clk);
      request_address <= word_address;
      request_write_data <= {48'd0, value};
      request_byte_enable <= 8'b0000_0011;
      request_burst <= 5'd1;
      request_write <= 1'b1;
      @(posedge clk);
      request_write <= 1'b0;
      do @(posedge clk); while (!request_done);
    end
  endtask

  task automatic do_read(
    input logic [24:0] word_address,
    input integer words
  );
    begin
      got_n = 0;
      @(posedge clk);
      request_address <= word_address;
      request_burst <= words[4:0];
      request_read <= 1'b1;
      @(posedge clk);
      request_read <= 1'b0;
      do @(posedge clk); while (!request_done);
      @(posedge clk);
    end
  endtask

  // One sweep point: fill a block, read it back single-word and as 16-word
  // bursts, count mismatches across both.
  task automatic measure(
    output integer single_errors,
    output integer burst_errors
  );
    logic [15:0] want;
    integer i, j;
    begin
      single_errors = 0;
      burst_errors = 0;
      for (i = 0; i < WORDS; i = i + 1)
        do_write(25'h0500000 + i, 16'hA5A5 ^ i[15:0]);

      for (i = 0; i < WORDS; i = i + 1) begin
        want = 16'hA5A5 ^ i[15:0];
        do_read(25'h0500000 + i, 1);
        if ((got_n != 1) || (got_beat[0] !== want))
          single_errors = single_errors + 1;
      end

      for (i = 0; i < WORDS; i = i + 16) begin
        do_read(25'h0500000 + i, 16);
        if (got_n != 16) begin
          burst_errors = burst_errors + 16;
        end else begin
          for (j = 0; j < 16; j = j + 1) begin
            want = 16'hA5A5 ^ (i + j);
            if (got_beat[j] !== want) burst_errors = burst_errors + 1;
          end
        end
      end
    end
  endtask

  integer single_errors;
  integer burst_errors;
  integer errors;

  initial begin
    phase_ns = TCK / 2.0;
    reset = 1'b1;
    init = 1'b1;
    repeat (8) @(posedge clk);

    run_start = -1;
    best_start = -1;
    best_end = -2;
    pass_count = 0;
    fail_count = 0;

    $display("");
    $display("SDRAM read-window sweep: TCK=%.2f ns, tAC=%.2f ns, %0d words/point",
             TCK, TAC, WORDS);
    $display("phase_ns is the delay from the controller edge to the device pin edge.");
    $display("");
    $display("  phase_ns   phase_ps   deg     single   burst  result");

    // Sweep the period in 0.5 ns steps, excluding the degenerate endpoints
    // (phase 0 and phase TCK put both clock edges at the same simulation time,
    // where the result is decided by delta ordering rather than by timing, and
    // which is not a real operating point anyway).
    for (point = 1; point <= 39; point = point + 1) begin
      phase_ns = point * 0.5;

      // Re-run the controller's power-up sequence at each phase so the
      // device's mode register is loaded under the phase being measured.
      init = 1'b1;
      reset = 1'b1;
      repeat (4) @(posedge clk);
      reset = 1'b0;
      init = 1'b0;
      wait (sdram_ready);
      repeat (4) @(posedge clk);

      measure(single_errors, burst_errors);
      errors = single_errors + burst_errors;

      // Track the LARGEST CONTIGUOUS passing run, not merely the first and
      // last passing point: an isolated pass surrounded by failures is noise,
      // and averaging across a gap would report a phase that does not work.
      if (errors == 0) begin
        pass_count = pass_count + 1;
        if (run_start < 0) run_start = point;
        if ((point - run_start + 1) > (best_end - best_start + 1)) begin
          best_start = run_start;
          best_end = point;
        end
      end else begin
        fail_count = fail_count + 1;
        run_start = -1;
      end

      $display("  %8.2f   %8.0f   %5.1f   %6d  %6d  %s",
               phase_ns, phase_ns * 1000.0, phase_ns / TCK * 360.0,
               single_errors, burst_errors, (errors == 0) ? "PASS" : "FAIL");
    end

    $display("");
    if (pass_count == 0) begin
      $display("RESULT: no phase in the sweep produced correct reads.");
      $display("        The failure is not phase alignment alone.");
    end else begin
      $display("RESULT: largest contiguous passing window is %.2f ns to %.2f ns (%0d points; %0d passed overall).",
               best_start * 0.5, best_end * 0.5,
               best_end - best_start + 1, pass_count);
      $display("        Centre of that window = %.2f ns = %.0f ps = %.1f deg.",
               (best_start + best_end) * 0.25,
               (best_start + best_end) * 250.0,
               (best_start + best_end) * 0.25 / TCK * 360.0);
      $display("        Set the PLL's SDRAM output phase_shift to the centre value.");
      if ((16.75 < best_start * 0.5) || (16.75 > best_end * 0.5))
        $display("        NOTE: the configured 16.75 ns is OUTSIDE this window.");
      else
        $display("        NOTE: the configured 16.75 ns is inside this window.");
    end
    $display("");
    $display("Current KI configuration for reference: 50 MHz, phase_shift3 = 16750 ps = 16.75 ns (was 14480 ps).");
    $display("");
    $finish;
  end

  // Safety net so a hang in the handshake fails loudly instead of running forever.
  initial begin
    #50_000_000;
    $display("TIMEOUT: SDRAM handshake did not complete.");
    $fatal(1, "timeout");
  end
endmodule

`default_nettype wire
