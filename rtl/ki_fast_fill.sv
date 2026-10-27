// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// The CPU's direct fill path, between the data cache and ki_sdram_burst's
// second port.
//
// The data cache asks for a clean line, or its read-ahead's next line, and
// an uncached 64-bit load for its qword, straight from the CPU's clock when
// nothing of the CPU's is in the bridge's path (cpu.vhd, fast_go, fast_ra_go
// and fast_unc_go): a toggle, with the physical address in a register beside
// it - a line's, or a qword's with bit 0 set to say so. The address is
// mapped here to its SDRAM storage address with the bridge's own map,
// ki_board_pkg::ki_storage_address, and goes to the controller with the
// toggle. Both hold until the next request, which cannot come before this
// one's done.
//
// The controller returns the line's sixteen words on its clock, one a clock.
// Four make a qword, which goes on clk - into the cache's fill port, or a
// read-ahead's line buffer - one a clk cycle, as the bridge's beats do: beat
// is high on the clk cycle after a
// qword completes, and first marks the line's first. A qword completes every
// four controller clocks, two clk cycles, so clk always keeps up, and the
// qword register holds for both. window is high from the request until the
// fourth beat - the first, for a qword - and done_tog changes on that beat;
// the CPU's clock takes it as the read's completion.
//
// A second request may come while a window is open: a demand fill queued
// behind the one in flight (cpu.vhd, fast_go_q), asked for only once that
// one's first beat has come, so the controller has taken it. Its window
// opens when the first's closes. The controller takes it once the first has
// drained, so its words come after all of the first's.
module ki_fast_fill (
  input  wire         clk,          // clk_core
  input  wire         clk_ctl,      // clk_sdram_ctl, twice clk, same PLL
  // From the CPU's clock.
  input  wire         req_tog,
  input  wire  [31:0] req_line,
  // To and from the controller, on clk_ctl.
  output wire         ctl_tog,
  output wire  [24:0] ctl_addr,
  input  wire  [15:0] word,
  input  wire         word_valid,
  // The cache's fill port, on clk.
  output logic        window = 1'b0,
  output wire         beat,
  output wire         first,
  output wire  [63:0] qword,
  output logic        done_tog = 1'b0
);
  import ki_board_pkg::*;

  // Bit 0 marks a qword read, to the controller as here.
  wire [27:0] storage = ki_storage_address({req_line[31:1], 1'b0});
  assign ctl_tog  = req_tog;
  assign ctl_addr = {storage[24:1], req_line[0]};

  // Four words to a qword, low word first.
  logic  [1:0] widx = 2'd0;
  logic [47:0] acc  = 48'd0;
  logic [63:0] q    = 64'd0;
  logic        qtog = 1'b0;
  always_ff @(posedge clk_ctl) begin
    if (word_valid) begin
      widx <= widx + 2'd1;
      if (widx == 2'd3) begin
        q    <= {word, acc};
        qtog <= ~qtog;
      end else begin
        acc[widx * 16 +: 16] <= word;
      end
    end
  end

  // One beat a qword on clk.
  logic       qseen = 1'b0;
  logic       rseen = 1'b0;
  logic       req_tog_d = 1'b0;
  logic [1:0] bcnt  = 2'd0;
  logic       qword_read = 1'b0;
  assign beat  = window && (qtog != qseen);
  assign first = beat && (bcnt == 2'd0);
  assign qword = q;
  always_ff @(posedge clk) begin
    if (req_tog != rseen && !window) begin
      rseen      <= req_tog;
      window     <= 1'b1;
      bcnt       <= 2'd0;
      qword_read <= req_line[0];
    end
    if (beat) begin
      qseen <= qtog;
      bcnt  <= bcnt + 2'd1;
      if (bcnt == 2'd3 || qword_read) begin
        window   <= 1'b0;
        done_tog <= ~done_tog;
      end
    end
  end

`ifndef SYNTHESIS
  // The CPU's eligibility test and ki_board_pkg's map describe the same
  // memory: a direct read is a line, or a qword, of low or main RAM outside
  // the framebuffer pages.
  wire [31:0] req_at = {req_line[31:5], 5'd0};
  wire line_is_ram =
      ((req_at <= KI_LOW_RAM_LAST) &&
       !((req_at >= KI_FB0_LOW) && (req_at < KI_FB0_HIGH)) &&
       !((req_at >= KI_FB1_LOW) && (req_at < KI_FB1_HIGH))) ||
      ((req_at >= KI_MAIN_RAM_BASE) && (req_at <= KI_MAIN_RAM_ALIAS_LAST));
  always @(posedge clk) begin
    if ((req_tog != rseen) &&
        (!line_is_ram || (req_line[0] ? (req_line[2:1] != 2'd0) : (req_line[4:0] != 5'd0)))) begin
      $error("ki_fast_fill: a direct read of %08h, which is not a line or a qword of SDRAM RAM", req_line);
      $fatal(1);
    end
    // One request waits at most: a second may come during a window, not a
    // third before the second's opens.
    req_tog_d <= req_tog;
    if ((req_tog != req_tog_d) && (req_tog_d != rseen)) begin
      $error("ki_fast_fill: a direct read was asked for while another still waited for its window");
      $fatal(1);
    end
  end
`endif
endmodule

`default_nettype wire
