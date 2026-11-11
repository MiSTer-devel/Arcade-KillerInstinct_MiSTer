// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_sdram_adapter (
  input  wire         clk,
  // The controller's clock, 2 x clk from the same PLL. ki_sdram_x2, which
  // lives inside here, packs the controller's 16-bit words two to a beat, one
  // beat per clk cycle. The adapter already owns the relationship with
  // ki_sdram_burst, so the pack that joins the 100 MHz controller to a 50 MHz
  // requester belongs here too rather than beside it.
  input  wire         clk2x,
  input  wire         reset,

  // The requester (ki_memory_bridge).
  // Word address (16-bit words); only [23:0] reach the 25-bit byte-addressed
  // controller.
  input  wire  [24:0] request_address,
  // Up to 16 words - one 32-byte cache line - so a dirty line goes out as a
  // single burst instead of four.
  input  wire [255:0] request_write_data,
  input  wire  [31:0] request_byte_enable,
  // Words to transfer: 1..16 (the controller clamps writes to the width of
  // its 16-word payload).
  input  wire   [4:0] request_burst,
  input  wire         request_read,
  input  wire         request_write,
  // TWO 16-bit words per beat, low word first, with request_read_be naming
  // which halves carry one. be is 2'b11 for every even burst and 2'b01 only on
  // the last beat of an odd one. Both hold their value between beats, so a
  // single-word requester may still take its data at the completion handshake.
  output wire  [31:0] request_read_data,
  output wire   [1:0] request_read_be,
  // High for each returned beat, in address order, for burst reads. The
  // single-word path may ignore this and take request_read_data at done.
  output logic        request_data_valid,
  output logic        request_done,

  output logic        sdram_ready,

  // The CPU's direct fill path; see ki_fast_fill. The request comes from the
  // CPU's clock; the line goes back on clk.
  input  wire         fast_req_tog,
  input  wire  [31:0] fast_req_line,
  input  wire         fast_req_stream,
  output wire         fast_window,
  output wire         fast_beat,
  output wire         fast_first,
  output wire  [63:0] fast_qword,
  output wire         fast_done_tog,
  // An uncached qword read's qword, on clk2x, and a marked line read's
  // qwords on fast_ra_valid; see ki_fast_fill.
  output wire         fast_unc_valid,
  output wire  [63:0] fast_unc_qword,
  output wire         fast_ra_valid,

  output wire  [24:0] controller_address,
  output wire [255:0] controller_write_data,
  output wire  [31:0] controller_byte_enable,
  output wire   [4:0] controller_burst,
  output wire         controller_read,
  output wire         controller_write,
  input  wire  [15:0] controller_read_data,
  input  wire         controller_dout_valid,
  input  wire         controller_ready,
  output wire         controller_fast_tog,
  output wire  [24:0] controller_fast_addr,
  output wire         controller_fast_stream,
  input  wire         controller_fast_valid
);
  // What the state machine below launches. ki_sdram_x2 carries these to the
  // controller unchanged and packs the words that come back.
  logic  [24:0] issue_address = 25'd0;
  logic [255:0] issue_write_data = 256'd0;
  logic  [31:0] issue_byte_enable = 32'h0000_0000;
  logic   [4:0] issue_burst = 5'd1;
  logic         issue_read = 1'b0;
  logic         issue_write = 1'b0;

  wire [31:0] packed_data;
  wire  [1:0] packed_be;
  wire        packed_valid;
  wire        packed_ready;

  ki_sdram_x2 pack (
    .clk(clk), .clk2x(clk2x), .init(reset),
    .req_addr(issue_address), .req_din(issue_write_data),
    .req_wtbt(issue_byte_enable), .req_burst(issue_burst),
    .req_rd(issue_read), .req_we(issue_write),
    .req_dout(packed_data), .req_dout_be(packed_be),
    .req_dout_valid(packed_valid), .req_ready(packed_ready),
    .ctl_addr(controller_address), .ctl_din(controller_write_data),
    .ctl_wtbt(controller_byte_enable), .ctl_burst(controller_burst),
    .ctl_rd(controller_read), .ctl_we(controller_write),
    .ctl_dout(controller_read_data), .ctl_dout_valid(controller_dout_valid),
    .ctl_ready(controller_ready)
  );

  // The direct fill path bypasses the state machine below: ki_sdram_burst takes
  // its requests on a port of their own, and only when nothing else is
  // pending. ki_fast_fill maps the line and assembles what comes back.
  ki_fast_fill fast (
    .clk(clk), .clk_ctl(clk2x),
    .req_tog(fast_req_tog), .req_line(fast_req_line), .req_stream(fast_req_stream),
    .ctl_tog(controller_fast_tog), .ctl_addr(controller_fast_addr),
    .ctl_stream(controller_fast_stream),
    .word(controller_read_data), .word_valid(controller_fast_valid),
    .window(fast_window), .beat(fast_beat), .first(fast_first),
    .qword(fast_qword), .done_tog(fast_done_tog),
    .unc_valid(fast_unc_valid), .unc_qword(fast_unc_qword),
    .ra_valid(fast_ra_valid)
  );

  // Returned beats pass straight through to the requester: the pack already
  // registers each one, and a second register here would cost a clock on
  // every beat of every read. Data and width both hold between beats, so a
  // single-word requester can still take them at done.
  assign request_read_data  = packed_data;
  assign request_read_be    = packed_be;
  assign request_data_valid = packed_valid;
  typedef enum logic [1:0] {
    ADAPTER_IDLE,
    ADAPTER_SETTLE,
    ADAPTER_WAIT,
    ADAPTER_ACK
  } adapter_state_t;

  adapter_state_t state = ADAPTER_IDLE;
  logic startup_done = 1'b0;

  logic req_pending = 1'b0;
  logic req_pending_write = 1'b0;
  logic [24:0] req_pending_address = 25'd0;
  logic [255:0] req_pending_write_data = 256'd0;
  logic  [31:0] req_pending_byte_enable = 32'h0000_0000;
  logic  [4:0] req_pending_burst = 5'd1;

  assign sdram_ready = startup_done;

  // A request arriving while nothing is queued and the controller is
  // free goes straight out on this clock, rather than being captured into
  // req_pending first and launched from there on the next, which would cost a
  // clock on every SDRAM operation. A request that arrives while one is queued,
  // or while the adapter is busy, still queues.
  wire request_now = request_read || request_write;
  wire launch_direct = (state == ADAPTER_IDLE) && packed_ready && startup_done &&
                       !req_pending && request_now;

  always_ff @(posedge clk) begin
    request_done <= 1'b0;
    issue_read <= 1'b0;
    issue_write <= 1'b0;

    if (reset) begin
      state <= ADAPTER_IDLE;
      startup_done <= 1'b0;
      issue_address <= 25'd0;
      issue_write_data <= 256'd0;
      issue_byte_enable <= 32'h0000_0000;
      issue_burst <= 5'd1;
      req_pending <= 1'b0;
      req_pending_burst <= 5'd1;
    end else begin
      if (packed_ready)
        startup_done <= 1'b1;

      case (state)
        ADAPTER_IDLE: begin
          if (launch_direct) begin
            issue_address <= {request_address[23:0], 1'b0};
            issue_write_data <= request_write_data;
            issue_byte_enable <= request_byte_enable;
            issue_burst <= (request_burst == 0) ? 5'd1 : request_burst;
            issue_read <= !request_write;
            issue_write <= request_write;
            state <= ADAPTER_SETTLE;
          end else if (packed_ready && startup_done && req_pending) begin
            issue_address <= {req_pending_address[23:0], 1'b0};
            issue_write_data <= req_pending_write_data;
            issue_byte_enable <= req_pending_byte_enable;
            issue_burst <= req_pending_burst;
            issue_read <= !req_pending_write;
            issue_write <= req_pending_write;
            req_pending <= 1'b0;
            state <= ADAPTER_SETTLE;
          end
        end

        // The controller detects requests on the rising edge of rd/we and
        // lowers `ready` one cycle later. Wait that cycle out before polling
        // `ready`, otherwise the still-high pre-request value is mistaken for
        // completion.
        ADAPTER_SETTLE: state <= ADAPTER_WAIT;

        ADAPTER_WAIT: begin
          if (packed_ready) begin
            request_done <= 1'b1;
            state <= ADAPTER_ACK;
          end
        end

        ADAPTER_ACK: state <= ADAPTER_IDLE;
      endcase

      // Sequenced last on purpose: a request arriving on the clock a queued
      // one launches must win over that launch's clear of req_pending. A
      // request launched directly above is not queued as well.
      if (request_now && !launch_direct) begin
        req_pending <= 1'b1;
        req_pending_write <= request_write;
        req_pending_address <= request_address;
        req_pending_write_data <= request_write_data;
        req_pending_byte_enable <= request_byte_enable;
        req_pending_burst <= (request_burst == 0) ? 5'd1 : request_burst;
      end
    end
  end
endmodule

`default_nettype wire
