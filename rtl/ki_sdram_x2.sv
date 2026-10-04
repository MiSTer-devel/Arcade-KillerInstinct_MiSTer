// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// Run ki_sdram_burst at twice the requester's clock, and hand back two 16-bit
// words per requester clock instead of one.
//
// WHY. In a D-cache miss the three qwords after the first stream out of a
// 16-bit part one word per device clock. That term is set by the device clock
// and nothing above it can touch it: a 32-byte line is sixteen transfers
// whatever the bridge does. Doubling the device clock halves it.
//
// What it cannot do is hand 16 bits per 10 ns to a bridge that consumes one
// beat per 20 ns; half the words would simply be dropped. This module is the
// join: the controller runs on clk2x, and the 32-bit beat it assembles is held
// for a full clk cycle.
//
// THE CROSSING IS SYNCHRONOUS, NOT ASYNCHRONOUS. clk and clk2x come from one
// PLL, clk2x 0.5 ns after clk (pll_0002.v), so a fast-to-slow path is an
// ordinary 9.5 ns path for the fitter. There is no FIFO here and there must
// not be one: a FIFO would put back the latency this exists to remove. What
// the design DOES avoid is any assumption about WHICH clk2x cycle a clk edge
// lands on - see the hold rule below.
//
// SLOW TO FAST needs nothing. A request strobe held for one clk cycle is two
// clk2x cycles, and ki_sdram_burst edge-detects rd/we (new_rd = rd && !old_rd),
// so a two-cycle-wide strobe still produces exactly one request. Address,
// burst, data and byte enables are registered on the slow side and stable
// across both fast cycles.
//
// FAST TO SLOW is the whole of this module. A completed beat is registered and
// HELD for two clk2x cycles, so it spans exactly one clk edge whichever fast
// cycle that edge falls on. At full rate a beat completes every two clk2x
// cycles, so the held beat changes exactly once per clk cycle and the slow side
// takes one beat per cycle with no gaps - which is the point: two words per
// 20 ns, twice what one 16-bit word per 20 ns would give.
module ki_sdram_x2 (
  input  wire         clk,      // requester clock (50 MHz)
  input  wire         clk2x,    // controller clock, 2 x clk, same PLL
  input  wire         init,

  // ---------------- requester side, clk -------------------------------------
  input  wire  [24:0] req_addr,
  input  wire [255:0] req_din,
  input  wire  [31:0] req_wtbt,
  input  wire   [4:0] req_burst,
  input  wire         req_rd,
  input  wire         req_we,
  // Two words per beat, LOW word first, which is address order.
  output logic [31:0] req_dout = 32'd0,
  // Which halves of req_dout carry a word. Always 2'b11 except on the final
  // beat of an ODD burst, which the core only issues at burst 1 (the BIST's
  // single-word probe); every cache, video and ROM path uses 2, 4 or 16.
  //
  // Like req_dout, this HOLDS between beats rather than clearing. A
  // single-word requester is allowed to take its data at the completion
  // handshake rather than at req_dout_valid - ki_sdram_adapter's header says
  // so - and data that persisted while its width did not would be a trap.
  output logic  [1:0] req_dout_be = 2'b00,
  output logic        req_dout_valid = 1'b0,
  output wire         req_ready,

  // ---------------- controller side, clk2x ----------------------------------
  output wire  [24:0] ctl_addr,
  output wire [255:0] ctl_din,
  output wire  [31:0] ctl_wtbt,
  output wire   [4:0] ctl_burst,
  output wire         ctl_rd,
  output wire         ctl_we,
  input  wire  [15:0] ctl_dout,
  input  wire         ctl_dout_valid,
  input  wire         ctl_ready
);
  // Slow to fast: straight through. See the header.
  assign ctl_addr  = req_addr;
  assign ctl_din   = req_din;
  assign ctl_wtbt  = req_wtbt;
  assign ctl_burst = req_burst;
  assign ctl_rd    = req_rd;
  assign ctl_we    = req_we;


  // ---------------------------------------------------------------- packing
  logic        half = 1'b0;          // a word is waiting for its partner
  logic [15:0] low  = 16'd0;
  // Set while the current beat still has to be held for one more clk2x
  // cycle, so a beat is presented for TWO fast cycles and spans exactly one
  // clk edge whichever fast cycle that edge lands on; at full rate the next
  // beat completes before the hold runs out, so req_dout_valid stays
  // continuously high and req_dout changes once per clk cycle - one beat per
  // slow cycle, no gaps.
  logic        hold = 1'b0;

  // An ODD burst ends with a word that has no partner, and it must go out on
  // the same beat it arrives on - not after the transaction closes. Counting
  // the words is what makes that possible.
  //
  // Both of the obvious alternatives are wrong. Edge-triggering a flush on
  // ctl_ready fails outright: ki_sdram_burst raises `ready` on the very edge
  // that captures the last beat, so for a ONE-word burst the
  // end-of-transaction edge and the word arrive together, the flush looks a
  // cycle later and finds the edge gone, and the word sits in `low` until it
  // is emitted as the first half of the NEXT read. Using the level instead
  // does flush, but a cycle or two LATE - after the adapter has raised done -
  // so a requester that takes its data at the completion handshake can miss
  // it.
  //
  // With the count, the tail beat has exactly the same latency as any other.
  logic [4:0] words_left = 5'd0;
  logic       rd_d = 1'b0;
  wire        rd_start = ctl_rd && !rd_d;

  wire        last_word = ctl_dout_valid && (words_left == 5'd1);
  wire        pair_now  = ctl_dout_valid && half;
  wire        tail_now  = last_word && !half;
  wire        emit_now  = pair_now || tail_now;

  // `ready` is a LEVEL, not a strobe: ki_sdram_burst lowers it when it takes a
  // request and raises it when the transaction ends, so sampling it on the slow
  // clock cannot miss an event. The adapter above already waits a full slow
  // cycle after launching before it polls (ADAPTER_SETTLE), which is two fast
  // cycles.
  //
  // But it must ALSO wait for the pack to drain. ki_sdram_burst raises ready
  // on the edge that captures the last word, and this stage is a register
  // behind that, so passing ready straight through would report the
  // transaction complete one or two cycles BEFORE its final beat came out.
  // ki_sdram_adapter turns ready into request_done, and both the boot-ROM
  // path and the self test take their data at done - they would lose the last
  // two words of every read. The condition is "nothing is still OWED": no
  // words left to arrive and none half-packed. It deliberately does NOT also
  // wait for req_dout_valid to fall. ready and the final beat's valid then go
  // high in the SAME cycle, which is safe because ki_sdram_adapter spends a
  // cycle turning ready into request_done - by which point a requester
  // watching valid has taken the beat, and one watching done finds req_dout
  // still holding it. That cycle is not free to give away: request_done
  // becomes the data cache's ram_done, so it lands straight on F3 of every
  // miss.
  assign req_ready = ctl_ready && (words_left == 5'd0) && !half;

  always_ff @(posedge clk2x) begin
    rd_d <= ctl_rd;
    if (rd_start) words_left <= (ctl_burst == 5'd0) ? 5'd1 : ctl_burst;
    else if (ctl_dout_valid && (words_left != 5'd0))
      words_left <= words_left - 1'b1;

    if (emit_now) begin
      half <= 1'b0;
      req_dout <= pair_now ? {ctl_dout, low} : {16'd0, ctl_dout};
      req_dout_be <= pair_now ? 2'b11 : 2'b01;
      req_dout_valid <= 1'b1;
      hold <= 1'b1;
    end else begin
      if (ctl_dout_valid) begin
        low <= ctl_dout;
        half <= 1'b1;
      end
      if (hold) hold <= 1'b0;
      else req_dout_valid <= 1'b0;
    end

    if (init) begin
      half <= 1'b0;
      hold <= 1'b0;
      words_left <= 5'd0;
      rd_d <= 1'b0;
      req_dout_valid <= 1'b0;
      req_dout_be <= 2'b00;
    end

`ifndef SYNTHESIS
    // Nothing may be stranded when a new read starts. The flush above is what
    // guarantees it, and this is what would notice if it ever stopped.
    if (!init && ctl_rd && half) begin
      $error("ki_sdram_x2: a read started with a word still stranded in the pack");
      $fatal(1);
    end
`endif
  end
endmodule

`default_nettype wire
