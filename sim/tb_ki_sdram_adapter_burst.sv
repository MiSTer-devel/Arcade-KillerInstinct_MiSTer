// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// Burst reads through ki_sdram_adapter into ki_sdram_burst.
//
// The controller alone was proven by tb_ki_sdram_burst. What matters for the
// core is the throughput a REQUESTER sees, because the per-word cost that made
// the single-word path unusable was dominated by the adapter handshake round
// trip, not by DRAM core timing. This measures the end-to-end number the memory
// bridge will actually get, and checks that adding bursts did not break the
// two-port arbitration the ROM download depends on.
module tb_ki_sdram_adapter_burst;
  localparam real TCK = 20.0;
  localparam real SCANOUT_BUDGET_NS = 203.0;
  localparam real SINGLE_WORD_BASELINE_NS = 242.8;

  logic clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  integer errors = 0;

  always #(TCK / 2.0) clk = ~clk;
  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  logic [24:0] request_address = 25'd0;
  logic [63:0] request_write_data = 64'd0;
  logic  [7:0] request_byte_enable = 8'b0000_0011;
  logic  [4:0] request_burst = 5'd1;
  logic request_read = 1'b0;
  logic request_write = 1'b0;
  wire [15:0] request_read_data;
  wire request_data_valid;
  wire request_done;

  logic [24:0] aux_address = 25'd0;
  logic [63:0] aux_write_data = 64'd0;
  logic  [7:0] aux_byte_enable = 8'b0000_0011;
  logic aux_read = 1'b0;
  logic aux_write = 1'b0;
  wire [15:0] aux_read_data;
  wire aux_done;
  wire sdram_ready;

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

  ki_sdram_adapter adapter (
    .clk(clk), .reset(reset),
    .request_address(request_address),
    .request_write_data(request_write_data),
    .request_byte_enable(request_byte_enable),
    .request_burst(request_burst),
    .request_read(request_read), .request_write(request_write),
    .request_read_data(request_read_data),
    .request_data_valid(request_data_valid),
    .request_done(request_done),
    .aux_address(aux_address), .aux_write_data(aux_write_data),
    .aux_byte_enable(aux_byte_enable),
    .aux_burst(5'd1),
    .aux_read(aux_read), .aux_write(aux_write),
    .aux_read_data(aux_read_data), .aux_data_valid(),
    .aux_done(aux_done),
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

  logic [15:0] got [0:31];
  integer got_n;
  always @(posedge clk) begin
    if (request_data_valid) begin
      if (got_n < 32) got[got_n] <= request_read_data;
      got_n <= got_n + 1;
    end
  end

  task automatic pwrite(input logic [24:0] a, input logic [15:0] v);
    begin
      @(posedge clk);
      request_address <= a; request_write_data <= {48'd0, v};
      request_byte_enable <= 8'b0000_0011; request_burst <= 5'd1;
      request_write <= 1'b1;
      @(posedge clk);
      request_write <= 1'b0;
      do @(posedge clk); while (!request_done);
    end
  endtask

  task automatic pread(input logic [24:0] a, input integer n);
    begin
      got_n = 0;
      @(posedge clk);
      request_address <= a; request_burst <= n[4:0]; request_read <= 1'b1;
      @(posedge clk);
      request_read <= 1'b0;
      do @(posedge clk); while (!request_done);
      @(posedge clk);
    end
  endtask

  task automatic auxread(input logic [24:0] a, output logic [15:0] v);
    begin
      @(posedge clk);
      aux_address <= a; aux_read <= 1'b1;
      @(posedge clk);
      aux_read <= 1'b0;
      do @(posedge clk); while (!aux_done);
      v = aux_read_data;
    end
  endtask

  integer i, t0, t1, reps, bad;
  real ns_per_word;
  logic [15:0] auxv;

  initial begin
    got_n = 0;
    repeat (4) @(posedge clk);
    reset = 1'b0; init = 1'b0;
    wait (sdram_ready);
    repeat (4) @(posedge clk);

    $display("");
    $display("Burst reads through ki_sdram_adapter -> ki_sdram_burst");
    $display("");

    // NOTE: the ADAPTER takes WORD addresses and shifts to byte internally
    // (controller_address <= {request_address[23:0], 1'b0}), whereas the
    // controller's own port is a BYTE address. Consecutive words are +1 here
    // and +2 there. Getting this wrong makes a burst read every other column.
    for (i = 0; i < 16; i = i + 1)
      pwrite(25'h0100000 + i, 16'hD000 + i[15:0]);

    for (reps = 1; reps <= 16; reps = reps * 2) begin
      pread(25'h0100000, reps);
      bad = 0;
      if (got_n != reps) begin
        $error("burst %0d: adapter delivered %0d beats, expected %0d",
               reps, got_n, reps);
        errors = errors + 1;
      end else begin
        for (i = 0; i < reps; i = i + 1)
          if (got[i] !== (16'hD000 + i[15:0])) begin
            $error("burst %0d beat %0d: got %h expected %h",
                   reps, i, got[i], 16'hD000 + i[15:0]);
            errors = errors + 1;
            bad = bad + 1;
          end
        if (bad == 0) $display("  burst %2d: %0d beats through adapter, data OK",
                               reps, got_n);
      end
    end

    // Arbitration must survive bursts: the auxiliary port still gets served
    // and returns its own data, not a beat of someone else's burst.
    pwrite(25'h0200000, 16'hA11E);
    auxread(25'h0200000, auxv);
    if (auxv !== 16'hA11E) begin
      $error("aux port returned %h, expected A11E", auxv);
      errors = errors + 1;
    end else begin
      $display("  aux single-word read alongside bursts: OK");
    end

    $display("");
    for (reps = 1; reps <= 16; reps = reps * 2) begin
      t0 = $time;
      for (i = 0; i < 32; i = i + 1) pread(25'h0100000, reps);
      t1 = $time;
      ns_per_word = (t1 - t0) * 1.0 / (32.0 * reps);
      $display("  burst %2d words:  %7.1f ns/word   %s",
               reps, ns_per_word,
               (ns_per_word < SCANOUT_BUDGET_NS) ? "within scanout budget"
                                                 : "OVER scanout budget");
      // The bridge will use 4 for a 64-bit access and 16 for a cache line.
      if ((reps == 4 || reps == 16) &&
          (ns_per_word >= SINGLE_WORD_BASELINE_NS)) begin
        $error("burst %0d through the adapter (%.1f ns/word) is no better than the %.1f ns/word single-word baseline",
               reps, ns_per_word, SINGLE_WORD_BASELINE_NS);
        errors = errors + 1;
      end
      if (reps == 4 && ns_per_word >= SCANOUT_BUDGET_NS) begin
        $error("4-word burst (%.1f ns/word) still cannot sustain scanout (%.1f ns/word)",
               ns_per_word, SCANOUT_BUDGET_NS);
        errors = errors + 1;
      end
    end

    $display("");
    $display("  single-word baseline: %.1f ns/word", SINGLE_WORD_BASELINE_NS);
    $display("  scanout budget:       %.1f ns/word", SCANOUT_BUDGET_NS);
    $display("");
    if (errors == 0) $display("PASS");
    else $display("FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule

`default_nettype wire
