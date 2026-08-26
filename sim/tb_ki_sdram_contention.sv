`timescale 1ns/1ps

module tb_ki_sdram_contention;

  localparam real TCK = 20.0;
  localparam real PHASE_NS = 16.75;   // the configured pin-clock phase

  // Match the hardware instance exactly. Index 147 does not exist below 148
  // words, so a smaller sweep cannot reach the failure at all.
  localparam integer WORDS = 256;
  localparam integer BURST_WORDS = 16;
  localparam integer ROM_WORDS = 64;

  logic clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  logic boot_loaded = 1'b0;

  always #(TCK/2.0) clk = ~clk;

  initial begin
    #(PHASE_NS);
    forever #(TCK/2.0) clk_dev = ~clk_dev;
  end

  // Three primary loads, weakest first, so the report says WHERE it breaks
  // rather than just that it broke.
  //
  //   gap 8   a primary that pauses between transactions
  //   gap 1   near back-to-back, which is what scanout plus CPU looks like
  //   gap 0   relentless: a new request in the same cycle the last one retired.
  //           This is the case AUX_STARVE_LIMIT was written for.
  localparam integer LOADS = 3;
  int unsigned gaps [LOADS] = '{8, 1, 0};

  wire [LOADS-1:0] done, pass, busy;
  wire [15:0] error_count      [LOADS];
  wire [24:0] first_bad_address[LOADS];
  wire [15:0] first_bad_expect [LOADS];
  wire [15:0] first_bad_actual [LOADS];
  wire [31:0] primary_served   [LOADS];

  genvar g;
  generate
    for (g = 0; g < LOADS; g = g + 1) begin : load
      ki_sdram_contention_path #(
        .WORDS(WORDS), .BURST_WORDS(BURST_WORDS), .ROM_WORDS(ROM_WORDS)
      ) path (
        .clk(clk), .clk_dev(clk_dev), .reset(reset), .init(init),
        .boot_loaded(boot_loaded),
        .primary_gap(gaps[g]),
        .busy(busy[g]), .done(done[g]), .pass(pass[g]),
        .error_count(error_count[g]),
        .first_bad_address(first_bad_address[g]),
        .first_bad_expected(first_bad_expect[g]),
        .first_bad_actual(first_bad_actual[g]),
        .primary_served(primary_served[g])
      );
    end
  endgenerate

  // Decode a timeout report the same way the debug screen's EP field is read,
  // so a simulation failure and a photograph of the board can be compared
  // field by field without doing the arithmetic twice.
  task automatic report(input int unsigned idx);
    logic [3:0] st;
    logic       inv;
    logic [7:0] ix;
    begin
      st  = first_bad_expect[idx][15:12];
      inv = first_bad_expect[idx][11];
      ix  = first_bad_expect[idx][7:0];
      $display("    EP=%04x AC=%04x  addr=%07x  EC=%04x",
               first_bad_expect[idx], first_bad_actual[idx],
               first_bad_address[idx], error_count[idx]);
      if (error_count[idx] == 16'hFFFF)
        $display("    TIMEOUT: state=%0d invert=%0d index=%0d pad=%03b  completed=%0d",
                 st, inv, ix, first_bad_expect[idx][10:8], first_bad_actual[idx]);
      else
        $display("    DATA MISMATCH, not a stall");
    end
  endtask

  int unsigned cycles;
  int unsigned failures;

  initial begin
    failures = 0;
    repeat (10) @(posedge clk);
    reset <= 1'b0;
    init  <= 1'b0;
    repeat (50) @(posedge clk);
    boot_loaded <= 1'b1;

    // Generous: the relentless case makes every aux transaction wait out
    // AUX_STARVE_LIMIT, so the sweep legitimately takes far longer than it
    // does undisturbed. This must not be so tight that a slow pass is
    // mistaken for a stall - the BIST has its own watchdog and reports it.
    cycles = 0;
    while (cycles < 40_000_000 && !(&done)) begin
      @(posedge clk);
      cycles = cycles + 1;
    end

    $display("tb_ki_sdram_contention: %0d cycles", cycles);

    for (int unsigned i = 0; i < LOADS; i = i + 1) begin
      $display("  primary gap %0d: done=%0d pass=%0d, primary served %0d",
               gaps[i], done[i], pass[i], primary_served[i]);

      // A primary that never got served would make the aux result meaningless -
      // it would be testing an idle bus again, which is the bench we already
      // have. Assert the contention actually happened.
      if (primary_served[i] == 0) begin
        $display("    BENCH BUG: the primary was never served, so this load "
                 , "applied no contention at all");
        failures = failures + 1;
      end

      if (!done[i]) begin
        $display("    FAIL: the self test never finished");
        failures = failures + 1;
      end else if (!pass[i]) begin
        $display("    FAIL: the self test reported failure under contention");
        report(i);
        failures = failures + 1;
      end
    end

    if (failures == 0)
      $display("tb_ki_sdram_contention: PASS");
    else
      $display("tb_ki_sdram_contention: FAIL (%0d)", failures);
    $finish;
  end

endmodule


// The BIST on the auxiliary port and a synthetic requester on the primary,
// through the real adapter, the real burst controller and the SDRAM model.
//
// The primary reads ONLY, and from 0x0400000, which is none of the three BIST
// regions (0x0000000 low, 0x0018000 framebuffer page 0, 0x0800000). Contention
// is the variable under test; corrupting the pattern would confound it.
module ki_sdram_contention_path #(
  parameter integer WORDS = 256,
  parameter integer BURST_WORDS = 16,
  parameter integer ROM_WORDS = 64
) (
  input  wire         clk,
  input  wire         clk_dev,
  input  wire         reset,
  input  wire         init,
  input  wire         boot_loaded,
  input  int unsigned primary_gap,
  output wire         busy,
  output wire         done,
  output wire         pass,
  output wire  [15:0] error_count,
  output wire  [24:0] first_bad_address,
  output wire  [15:0] first_bad_expected,
  output wire  [15:0] first_bad_actual,
  output logic [31:0] primary_served = 32'd0
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

  wire sdram_ready;
  wire [31:0] rom_checksum;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire SDRAM_DQML, SDRAM_DQMH;
  wire [1:0] SDRAM_BA;
  wire SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

  // ---- the synthetic primary -------------------------------------------
  //
  // Follows the adapter's contract: pulse the request for ONE cycle, then wait
  // for done. Alternates single-word and burst reads, because scanout fetches
  // lines in bursts while the CPU fetches words, and the two occupy the
  // controller for very different lengths of time.
  localparam logic [24:0] PRIMARY_BASE = 25'h0400000;

  logic [24:0] primary_address = PRIMARY_BASE;
  logic  [4:0] primary_burst = 5'd1;
  logic        primary_read = 1'b0;
  logic        primary_alt = 1'b0;
  int unsigned primary_wait = 0;
  logic        primary_inflight = 1'b0;

  wire primary_done;
  wire primary_data_valid;
  wire [15:0] primary_read_data;

  always_ff @(posedge clk) begin
    if (reset) begin
      primary_read <= 1'b0;
      primary_inflight <= 1'b0;
      primary_wait <= 0;
      primary_address <= PRIMARY_BASE;
      primary_served <= 32'd0;
      primary_alt <= 1'b0;
    end else begin
      primary_read <= 1'b0;

      if (!primary_inflight) begin
        if (primary_wait == 0) begin
          primary_read <= 1'b1;
          primary_burst <= primary_alt ? BURST_WORDS[4:0] : 5'd1;
          primary_inflight <= 1'b1;
        end else begin
          primary_wait <= primary_wait - 1;
        end
      end else if (primary_done) begin
        primary_inflight <= 1'b0;
        primary_served <= primary_served + 1'b1;
        primary_wait <= primary_gap;
        primary_alt <= ~primary_alt;
        // Walk the address so this is not one permanently open row, which
        // would be an unrealistically cheap primary.
        primary_address <= (primary_address + 25'd16 >= PRIMARY_BASE + 25'd4096)
                           ? PRIMARY_BASE : primary_address + 25'd16;
      end
    end
  end

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

  ki_sdram_adapter adapter (
    .clk(clk), .reset(1'b0),
    .request_address(primary_address), .request_write_data(64'd0),
    .request_byte_enable(8'h00), .request_burst(primary_burst),
    .request_read(primary_read), .request_write(1'b0),
    .request_read_data(primary_read_data),
    .request_data_valid(primary_data_valid),
    .request_done(primary_done),
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
