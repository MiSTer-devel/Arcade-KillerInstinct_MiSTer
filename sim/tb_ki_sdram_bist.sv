// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// ki_sdram_bist against the real adapter, burst controller and device model.
//
// The BIST is the only thing that can prove the SDRAM path works on real
// silicon, so the one failure mode that must not exist is a BIST that always
// says PASS. This bench therefore runs TWO complete instances of the whole
// path: one at the configured 16.75 ns pin-clock phase, which must pass, and
// one at 5.00 ns, which the phase sweep (tb_ki_sdram_phase) shows is inside
// the total-failure region and which must therefore report a failure.
//
// It also checks that the burst read-back pass is actually reached and is
// actually counted, by requiring the good instance to complete more
// transactions than the single-word pass alone would take.
module tb_ki_sdram_bist;
  localparam real TCK = 20.0;
localparam integer WORDS = 256;
  localparam integer BURST_WORDS = 16;
  localparam integer ROM_WORDS = 64;
  logic boot_loaded = 1'b0;
  wire [31:0] good_rom_checksum, bad_rom_checksum;
  integer expected_sum = 0;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  integer errors = 0;

  always #(TCK / 2.0) clk = ~clk;

  // Two device clocks: the configured phase and one inside the failing region.
  logic clk_good = 1'b0;
  logic clk_bad = 1'b0;
  task automatic emit_edge_good(input logic value);
    #(16.75) clk_good = value;
  endtask
  task automatic emit_edge_bad(input logic value);
    #(5.00) clk_bad = value;
  endtask
  always @(clk) fork emit_edge_good(clk); join_none
  always @(clk) fork emit_edge_bad(clk); join_none

  wire good_busy, good_done, good_pass;
  wire [15:0] good_error_count;
  wire [24:0] good_first_bad_address;
  wire [15:0] good_first_bad_expected, good_first_bad_actual;
  wire good_ready;

  wire bad_busy, bad_done, bad_pass;
  wire [15:0] bad_error_count;
  wire [24:0] bad_first_bad_address;
  wire [15:0] bad_first_bad_expected, bad_first_bad_actual;
  wire bad_ready;

  ki_sdram_bist_path #(.WORDS(WORDS), .BURST_WORDS(BURST_WORDS),
                       .ROM_WORDS(ROM_WORDS)) good (
    .clk(clk), .clk_dev(clk_good), .reset(reset), .init(init),
    .boot_loaded(boot_loaded), .rom_checksum(good_rom_checksum),
    .sdram_ready(good_ready),
    .busy(good_busy), .done(good_done), .pass(good_pass),
    .error_count(good_error_count),
    .first_bad_address(good_first_bad_address),
    .first_bad_expected(good_first_bad_expected),
    .first_bad_actual(good_first_bad_actual)
  );

  ki_sdram_bist_path #(.WORDS(WORDS), .BURST_WORDS(BURST_WORDS),
                       .ROM_WORDS(ROM_WORDS)) bad (
    .clk(clk), .clk_dev(clk_bad), .reset(reset), .init(init),
    .boot_loaded(boot_loaded), .rom_checksum(bad_rom_checksum),
    .sdram_ready(bad_ready),
    .busy(bad_busy), .done(bad_done), .pass(bad_pass),
    .error_count(bad_error_count),
    .first_bad_address(bad_first_bad_address),
    .first_bad_expected(bad_first_bad_expected),
    .first_bad_actual(bad_first_bad_actual)
  );

  // Beats that came back with X or Z bits, i.e. the capture edge landed on an
  // undriven DQ bus. The BIST itself cannot count these: it compares with `!=`
  // because `!==` is not synthesisable, and `!=` against an X/Z operand
  // evaluates to X, which `if` treats as false. That is correct for hardware,
  // where the pins always carry real levels, but it means a SIMULATED capture
  // of a floating bus passes silently. This is what covers that gap - and it
  // is exactly what the 5.00 ns instance does on its single-word pass, which
  // is why that pass reports zero errors while the burst pass reports many.
  integer good_undriven = 0;
  integer bad_undriven = 0;
  always @(posedge clk) begin
    if (good.bist_data_valid && (^good.bist_read_data === 1'bx))
      good_undriven <= good_undriven + 1;
    if (bad.bist_data_valid && (^bad.bist_read_data === 1'bx))
      bad_undriven <= bad_undriven + 1;
  end

  // Which REGIONS the sweep actually visited. The BIST now covers low RAM
  // (word 0, where KI's own CPU Board Test reports an SRAM error) as well as
  // the original free region at word 0x500000, and "both were swept" has to be
  // a positive statement: at a good phase every region passes, so dropping one
  // would leave the result identical and the coverage silently halved.
  logic low_region_seen = 1'b0;
  logic fb_region_seen = 1'b0;
  logic high_region_seen = 1'b0;
  always @(posedge clk) begin
    if (good.bist_read || good.bist_write) begin
      if (good.bist_address < 25'h0010000) low_region_seen <= 1'b1;
      if ((good.bist_address >= 25'h0018000) &&
          (good.bist_address < 25'h0030000)) fb_region_seen <= 1'b1;
      if (good.bist_address >= 25'h0700000) high_region_seen <= 1'b1;
    end
  end

  // Longest burst the BIST actually asked the controller for. If the burst
  // pass were skipped or degraded to single words this would stay at 1 and the
  // whole point of the change would be lost silently.
  integer longest_burst = 0;
  always @(posedge clk) begin
    if (good.bist_read && (good.bist_burst > longest_burst))
      longest_burst <= good.bist_burst;
    if (good.bist_read &&
        (({1'b0, good.bist_address[8:0]} + {5'd0, good.bist_burst}) >
         10'd512)) begin
      $error("BIST burst of %0d from word 0x%h crosses a 512-word row",
             good.bist_burst, good.bist_address);
      errors = errors + 1;
    end
  end

  initial begin
    repeat (4) @(posedge clk);
    init = 1'b0;
    reset = 1'b0;

    $display("");
    $display("ki_sdram_bist over the real adapter / ki_sdram_burst / device");
    $display("");

    // Seed a known "boot ROM" so the checksum pass has something to sum. Under
    // this controller a bridge word address W maps to {bank,row,col} = W[23:0],
    // so the model key is just W.
    expected_sum = 0;
    for (int w = 0; w < ROM_WORDS; w = w + 1) begin
      good.memory.mem[{8'd0, 24'h480000 + w[23:0]}] = 16'h3000 + w[15:0];
      bad.memory.mem[{8'd0, 24'h480000 + w[23:0]}] = 16'h3000 + w[15:0];
      expected_sum = expected_sum + (16'h3000 + w);
    end
    // The pattern test runs first; release the checksum pass behind it.
    boot_loaded = 1'b1;

    wait (good_done && bad_done);
    repeat (4) @(posedge clk);

    // The configured phase must pass BOTH read shapes cleanly.
    if (!good_pass || (good_error_count !== 16'd0)) begin
      $error("16.75 ns phase: BIST reported FAIL, EC=%h (single=%0d burst=%0d) addr=%h exp=%h act=%h",
             good_error_count, good_error_count[7:0], good_error_count[15:8],
             good_first_bad_address, good_first_bad_expected,
             good_first_bad_actual);
      errors = errors + 1;
    end else begin
      $display("  16.75 ns phase: PASS, EC=0000 (single 0, burst 0)");
    end

    // A clean run must never capture an undriven bus. If it does, the data
    // happened to compare equal only because X/Z masked the comparison, and
    // the PASS is meaningless.
    if (good_undriven != 0) begin
      $error("16.75 ns phase: %0d beats captured an undriven DQ bus, so PASS is not trustworthy",
             good_undriven);
      errors = errors + 1;
    end else begin
      $display("  16.75 ns phase: no beat captured an undriven bus");

    if (!low_region_seen) begin
      $error("the BIST never addressed LOW RAM - the region KI's own CPU Board Test reports an SRAM error on");
      errors = errors + 1;
    end
    if (!fb_region_seen) begin
      $error("the BIST never addressed the FRAMEBUFFER page - the part of low RAM scanout is reading while the test runs");
      errors = errors + 1;
    end
    if (!high_region_seen) begin
      $error("the BIST never addressed the original free region at word 0x500000");
      errors = errors + 1;
    end
    if (low_region_seen && fb_region_seen && high_region_seen)
      $display("  three regions swept: low RAM, the framebuffer page, and the free region");
    end

    if (longest_burst != BURST_WORDS) begin
      $error("BIST never issued a %0d-word burst (longest was %0d) - the burst pass is not running",
             BURST_WORDS, longest_burst);
      errors = errors + 1;
    end else begin
      $display("  burst read-back pass issued %0d-word bursts", longest_burst);
    end

    // A BIST that cannot fail is worthless. At 5.00 ns the sweep says every
    // word is wrong, so this must report a failure - not necessarily a
    // timeout, but never a pass.
    if (bad_pass) begin
      $error("5.00 ns phase: BIST reported PASS, so it cannot detect a bad capture phase");
      errors = errors + 1;
    end else begin
      $display("  5.00 ns phase: FAIL as expected, EC=%h (single=%0d burst=%0d), %0d undriven captures",
               bad_error_count, bad_error_count[7:0], bad_error_count[15:8],
               bad_undriven);
    end

    // The point of the whole change: at a phase this bad the single-word pass
    // alone is NOT a reliable detector, so a BIST without the burst pass could
    // report PASS on a board that cannot run the game.
    if (bad_error_count[15:8] == 8'd0) begin
      $error("5.00 ns phase: burst pass reported no errors, so it is not detecting a bad capture phase");
      errors = errors + 1;
    end

    // The checksum is the test that answers "is the CPU being fed the right
    // bytes". A BIST that reports a checksum it did not actually compute would
    // be worse than none, so verify it against the seeded image.
    if (good_rom_checksum !== expected_sum[31:0]) begin
      $error("ROM checksum returned %08h, expected %08h",
             good_rom_checksum, expected_sum[31:0]);
      errors = errors + 1;
    end else begin
      $display("  ROM checksum over %0d words: %08h, matches the seeded image",
               ROM_WORDS, good_rom_checksum);
    end

    $display("");
    if (errors == 0) $display("tb_ki_sdram_bist: PASS");
    else $display("tb_ki_sdram_bist: FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #40_000_000;
    $display("tb_ki_sdram_bist: FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule

// One complete BIST -> adapter -> controller -> device stack, so the bench can
// instantiate it twice at different pin-clock phases.
module ki_sdram_bist_path #(
  parameter integer WORDS = 64,
  parameter integer BURST_WORDS = 16,
  parameter integer ROM_WORDS = 262144
) (
  input  wire         clk,
  input  wire         clk_dev,
  input  wire         reset,
  input  wire         init,
  input  wire         boot_loaded,
  output wire  [31:0] rom_checksum,
  output wire         sdram_ready,
  output wire         busy,
  output wire         done,
  output wire         pass,
  output wire  [15:0] error_count,
  output wire  [24:0] first_bad_address,
  output wire  [15:0] first_bad_expected,
  output wire  [15:0] first_bad_actual
);
  wire [24:0] bist_address;
  wire [63:0] bist_write_data;
  wire  [7:0] bist_byte_enable;
  wire  [4:0] bist_burst;
  wire bist_read, bist_write;
  wire [15:0] bist_read_data;
  wire bist_data_valid, bist_done;

  wire [24:0] controller_address;
  wire [63:0] controller_write_data;
  wire  [7:0] controller_byte_enable;
  wire  [4:0] controller_burst;
  wire controller_read, controller_write;
  wire [15:0] controller_read_data;
  wire controller_dout_valid, controller_ready;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire SDRAM_DQML, SDRAM_DQMH;
  wire [1:0] SDRAM_BA;
  wire SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

  ki_sdram_bist #(.WORDS(WORDS), .BURST_WORDS(BURST_WORDS),
                  .ROM_WORDS(ROM_WORDS)) bist (
    .clk(clk), .reset(reset), .sdram_ready(sdram_ready),
    .boot_loaded(boot_loaded),
    .request_address(bist_address),
    .request_write_data(bist_write_data),
    .request_byte_enable(bist_byte_enable),
    .request_burst(bist_burst),
    .request_read(bist_read), .request_write(bist_write),
    .request_read_data(bist_read_data),
    .request_data_valid(bist_data_valid),
    .request_done(bist_done),
    .rom_checksum(rom_checksum), .busy(busy), .done(done), .pass(pass),
    .error_count(error_count),
    .first_bad_address(first_bad_address),
    .first_bad_expected(first_bad_expected),
    .first_bad_actual(first_bad_actual)
  );

  // The BIST sits on the AUXILIARY port on hardware, so it is exercised
  // through that port here too - the primary is idle, as it is before the CPU
  // is released.
  ki_sdram_adapter adapter (
    .clk(clk), .reset(1'b0),
    .request_address(25'd0), .request_write_data(64'd0),
    .request_byte_enable(8'h00), .request_burst(5'd1),
    .request_read(1'b0), .request_write(1'b0),
    .request_read_data(), .request_data_valid(), .request_done(),
    .aux_address(bist_address), .aux_write_data(bist_write_data),
    .aux_byte_enable(bist_byte_enable), .aux_burst(bist_burst),
    .aux_read(bist_read), .aux_write(bist_write),
    .aux_read_data(bist_read_data), .aux_data_valid(bist_data_valid),
    .aux_done(bist_done),
    .sdram_ready(sdram_ready),
    .controller_address(controller_address),
    .controller_write_data(controller_write_data),
    .controller_byte_enable(controller_byte_enable),
    .controller_burst(controller_burst),
    .controller_read(controller_read), .controller_write(controller_write),
    .controller_read_data(controller_read_data),
    .controller_dout_valid(controller_dout_valid),
    .controller_ready(controller_ready)
  );

  ki_sdram_burst controller (
    .init(init), .clk(clk),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
    .wtbt(controller_byte_enable), .addr(controller_address),
    .burst(controller_burst),
    .dout(controller_read_data), .dout_valid(controller_dout_valid),
    .din(controller_write_data),
    .we(controller_write), .rd(controller_read), .ready(controller_ready)
  );

  mt48lc16m16_ki #(.TAC_NS(6.0)) memory (
    .clk(clk_dev), .dq(SDRAM_DQ), .addr(SDRAM_A), .ba(SDRAM_BA),
    .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .dqm({SDRAM_DQMH, SDRAM_DQML}), .cke(SDRAM_CKE)
  );
endmodule

`default_nettype wire
