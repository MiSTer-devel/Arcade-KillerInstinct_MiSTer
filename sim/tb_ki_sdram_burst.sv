// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// Burst-controller correctness and throughput against the framebuffer
// scanout budget.
module tb_ki_sdram_burst;
  localparam real TCK = 20.0;
  localparam real SCANOUT_BUDGET_NS = 203.0;

  logic clk = 1'b0;
  logic clk_dev = 1'b0;
  logic init = 1'b1;
  integer errors = 0;

  always #(TCK / 2.0) clk = ~clk;

  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  logic [24:0] addr = 25'd0;
  logic [63:0] din = 64'd0;
  logic  [7:0] wtbt = 8'b0000_0011;
  logic  [4:0] burst = 5'd1;
  logic we = 1'b0;
  logic rd = 1'b0;
  wire [15:0] dout;
  wire dout_valid;
  wire ready;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire SDRAM_DQML, SDRAM_DQMH;
  wire [1:0] SDRAM_BA;
  wire SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

  ki_sdram_burst dut (
    .init(init), .clk(clk),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
    .wtbt(wtbt), .addr(addr), .burst(burst),
    .dout(dout), .dout_valid(dout_valid), .din(din),
    .we(we), .rd(rd), .ready(ready)
  );

  // The model enforces tRP/tRCD/tRC and $fatals on a violation, so the
  // parameterised timing floors are checked here rather than assumed.
  mt48lc16m16_ki #(.TAC_NS(6.0)) memory (
    .clk(clk_dev), .dq(SDRAM_DQ), .addr(SDRAM_A), .ba(SDRAM_BA),
    .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .dqm({SDRAM_DQMH, SDRAM_DQML}), .cke(SDRAM_CKE)
  );

  task automatic wr(input logic [24:0] a, input logic [15:0] v);
    begin
      @(posedge clk);
      addr <= a; din <= {48'd0, v}; wtbt <= 8'b0000_0011;
      burst <= 5'd1; we <= 1'b1;
      @(posedge clk);
      we <= 1'b0;
      @(posedge clk);
      wait (ready);
    end
  endtask

  // Four-word write burst: one transaction instead of four. This is what the
  // bridge issues for every 64-bit CPU store and every downloaded ROM word.
  task automatic wr4(input logic [24:0] a, input logic [63:0] v);
    begin
      @(posedge clk);
      addr <= a; din <= v; wtbt <= 8'hff; burst <= 5'd4; we <= 1'b1;
      @(posedge clk);
      we <= 1'b0;
      @(posedge clk);
      wait (ready);
    end
  endtask

  logic [15:0] got [0:31];
  integer got_n;

  // Collect burst beats as they stream back.
  always @(posedge clk) begin
    if (dout_valid) begin
      if (got_n < 32) got[got_n] <= dout;
      got_n <= got_n + 1;
    end
  end

  task automatic rd_burst(input logic [24:0] a, input integer n);
    begin
      got_n = 0;
      @(posedge clk);
      addr <= a; burst <= n[4:0]; rd <= 1'b1;
      @(posedge clk);
      rd <= 1'b0;
      @(posedge clk);
      wait (ready);
      @(posedge clk);
    end
  endtask

  integer i, t0, t1, reps, bad;
  real ns_per_word;

  // Row-open census. The controller keeps the row ACTIVE across bursts and
  // closes it only for a refresh or a row/bank miss, so "the row stayed open"
  // is the whole claim of that change - and a throughput number alone cannot
  // distinguish it from a controller that got faster for some other reason.
  // Counted here rather than in the RTL so nothing synthesisable moves.
  integer row_hits = 0;
  integer row_misses = 0;
  integer hits0, misses0;

  // Count only the cycle a transaction is COMMITTED, which is where `pending`
  // clears. A row miss passes through S_IDLE twice - once to decide to close
  // the row, once after S_RP to issue the ACTIVE - so counting every visit
  // would double every miss and understate the hit rate.
  always @(posedge clk) begin
    if (dut.state == dut.S_IDLE && dut.pending && !dut.refresh_due) begin
      if (dut.open_valid && (dut.req_row == dut.open_row) &&
          (dut.req_bank == dut.open_bank))
        row_hits = row_hits + 1;          // straight to S_READ/S_WRITE
      else if (!dut.open_valid)
        row_misses = row_misses + 1;      // ACTIVE + tRCD
      // open_valid with a different row: the close pass, counted next time
      // round as a miss once open_valid has dropped.
    end
  end

  initial begin
    got_n = 0;
    repeat (4) @(posedge clk);
    init = 1'b0;
    wait (ready);
    repeat (4) @(posedge clk);

    $display("");
    $display("Burst SDRAM controller: correctness and throughput");
    $display("");

    // Seed 16 consecutive words.
    for (i = 0; i < 16; i = i + 1)
      wr(25'h0100000 + (i * 2), 16'hC000 + i[15:0]);

    // ---- correctness: every burst length must return the same data ----
    for (reps = 1; reps <= 16; reps = reps * 2) begin
      rd_burst(25'h0100000, reps);
      if (got_n != reps) begin
        $error("burst %0d: returned %0d beats, expected %0d", reps, got_n, reps);
        errors = errors + 1;
      end else begin
        bad = 0;
        for (i = 0; i < reps; i = i + 1) begin
          if (got[i] !== (16'hC000 + i[15:0])) begin
            $error("burst %0d beat %0d: got %h expected %h",
                   reps, i, got[i], 16'hC000 + i[15:0]);
            errors = errors + 1;
            bad = bad + 1;
          end
        end
        if (bad == 0) $display("  burst %2d: %0d beats, data OK", reps, got_n);
        else $display("  burst %2d: %0d beats, %0d WRONG", reps, got_n, bad);
      end
    end

    // A burst must not disturb a neighbouring row.
    wr(25'h0100400, 16'hBEEF);   // a different column in the same row
    rd_burst(25'h0100000, 4);
    if (got[0] !== 16'hC000) begin
      $error("burst corrupted by neighbouring write: got %h", got[0]);
      errors = errors + 1;
    end

    // ---- write bursts ----
    // Four words in one transaction, read back to prove they landed in the
    // right columns in the right order.
    wr4(25'h0100800, 64'h4444_3333_2222_1111);
    rd_burst(25'h0100800, 4);
    if (got_n != 4) begin
      $error("write burst read-back returned %0d beats", got_n);
      errors = errors + 1;
    end else if (got[0] !== 16'h1111 || got[1] !== 16'h2222 ||
                 got[2] !== 16'h3333 || got[3] !== 16'h4444) begin
      $error("write burst stored %h %h %h %h, expected 1111 2222 3333 4444",
             got[0], got[1], got[2], got[3]);
      errors = errors + 1;
    end else begin
      $display("  write burst 4: stored in order, data OK");
    end

    // Per-word byte enables must mask individual words within the burst. Word
    // 1 is fully masked and word 2 keeps only its low byte; both must leave
    // the previous contents alone rather than shifting the burst.
    wr4(25'h0100810, 64'hAAAA_BBBB_CCCC_DDDD);
    @(posedge clk);
    addr <= 25'h0100810; din <= 64'h1111_2222_3333_4444;
    wtbt <= 8'b0001_0011; burst <= 5'd4; we <= 1'b1;
    @(posedge clk);
    we <= 1'b0;
    @(posedge clk);
    wait (ready);
    rd_burst(25'h0100810, 4);
    if (got[0] !== 16'h4444 || got[1] !== 16'hCCCC ||
        got[2] !== 16'hBB22 || got[3] !== 16'hAAAA) begin
      $error("masked write burst gave %h %h %h %h, expected 4444 CCCC BB22 AAAA",
             got[0], got[1], got[2], got[3]);
      errors = errors + 1;
    end else begin
      $display("  write burst 4: per-word byte enables mask correctly");
    end

    // ---- throughput ----
    $display("");
    for (reps = 1; reps <= 16; reps = reps * 2) begin
      t0 = $time;
      for (i = 0; i < 32; i = i + 1)
        rd_burst(25'h0100000, reps);
      t1 = $time;
      ns_per_word = (t1 - t0) * 1.0 / (32.0 * reps);
      $display("  burst %2d words:  %7.1f ns/word   %s",
               reps, ns_per_word,
               (ns_per_word < SCANOUT_BUDGET_NS) ? "within scanout budget"
                                                 : "OVER scanout budget");
      if (reps == 4 && ns_per_word >= 242.8) begin
        $error("4-word burst (%.1f ns/word) is no better than the 242.8 ns/word single-word baseline",
               ns_per_word);
        errors = errors + 1;
      end
    end

    // The loop above re-reads ONE address, so every burst but the first is a
    // row hit by construction - the best case, not the real one. Scanout walks
    // strictly forward, and a row holds 512 words, so it takes a miss every
    // 128 four-word bursts. This measures that walk and reports the hit rate
    // it actually achieved, which is the only thing that says the row-open
    // path is carrying the traffic it was built for.
    $display("");
    hits0 = row_hits;
    misses0 = row_misses;
    t0 = $time;
    for (i = 0; i < 256; i = i + 1)
      rd_burst(25'h0100000 + (i * 8), 4);
    t1 = $time;
    ns_per_word = (t1 - t0) * 1.0 / (256.0 * 4.0);
    $display("  sequential walk, burst 4: %6.1f ns/word over 2 rows", ns_per_word);
    $display("    row hits %0d, row misses %0d",
             row_hits - hits0, row_misses - misses0);
    // 256 bursts across exactly two 512-word rows: 2 opening misses, plus one
    // per refresh (a refresh must precharge, so the next burst re-activates).
    // Anything close to 256 misses means the row is not staying open at all.
    if ((row_hits - hits0) < 200) begin
      $error("sequential walk took only %0d row hits in 256 bursts - the row is not staying open",
             row_hits - hits0);
      errors = errors + 1;
    end

    // Write throughput. This is the number that decides whether the game's
    // framebuffer clear fits in a frame: ~19,200 64-bit stores per full-screen
    // clear, against 16.7 ms and a bus already ~45% consumed by scanout.
    $display("");
    t0 = $time;
    for (i = 0; i < 32; i = i + 1) wr(25'h0100000, 16'h5A5A);
    t1 = $time;
    $display("  single-word write:  %6.1f ns/word", (t1 - t0) * 1.0 / 32.0);

    t0 = $time;
    for (i = 0; i < 32; i = i + 1) wr4(25'h0100000, 64'h5A5A_5A5A_5A5A_5A5A);
    t1 = $time;
    ns_per_word = (t1 - t0) * 1.0 / (32.0 * 4.0);
    $display("  4-word write burst: %6.1f ns/word  (%.0f ns per 64-bit store)",
             ns_per_word, ns_per_word * 4.0);
    if (ns_per_word >= 150.0) begin
      $error("4-word write burst (%.1f ns/word) is not amortising the ACTIVE/precharge",
             ns_per_word);
      errors = errors + 1;
    end

    $display("");
    $display("  scanout budget:                      %.1f ns/word", SCANOUT_BUDGET_NS);
    $display("");
    if (errors == 0) $display("PASS");
    else $display("FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #10_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule

`default_nettype wire
