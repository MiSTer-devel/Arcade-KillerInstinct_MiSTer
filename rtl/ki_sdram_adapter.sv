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

  // Primary requester (CPU/video/download bridge). Wins arbitration.
  // Word address (16-bit words); only [23:0] reach the 25-bit byte-addressed
  // controller.
  input  wire  [24:0] request_address,
  // Up to 16 words - one 32-byte cache line - so a dirty line goes out as a
  // single burst instead of four. aux stays 64-bit: the BIST never bursts
  // more than four words, and is zero-extended onto the controller below.
  input  wire [255:0] request_write_data,
  input  wire  [31:0] request_byte_enable,
  // Words to transfer: 1..16 on a read, 1..4 on a write (the controller
  // clamps writes to the width of its 4-word payload).
  input  wire   [4:0] request_burst,
  input  wire         request_read,
  input  wire         request_write,
  // TWO 16-bit words per beat, low word first, with request_read_be naming
  // which halves carry one. be is 2'b11 for every even burst and 2'b01 only on
  // the last beat of an odd one, which is the self test's single-word probe
  // and nothing else. Both hold their value between beats, so a single-word
  // requester may still take its data at the completion handshake.
  output wire  [31:0] request_read_data,
  output wire   [1:0] request_read_be,
  // One pulse per returned word, in address order, for burst reads. The
  // single-word path may ignore this and take request_read_data at done.
  output logic        request_data_valid,
  output logic        request_done,

  // Auxiliary requester (SDRAM self test). Served only when the primary has
  // nothing outstanding, so it can never delay a ROM download or CPU access
  // by more than one transaction.
  //
  // It gets the same burst capability as the primary port. That is not
  // symmetry for its own sake: the self test is the only thing that can prove
  // the BURST read path works on real silicon, and a burst captures one word
  // per clock out of a continuously driven DQ bus, which is a tighter case
  // than the single-word read with idle turnaround either side of it.
  input  wire  [24:0] aux_address,
  input  wire  [63:0] aux_write_data,
  input  wire   [7:0] aux_byte_enable,
  input  wire   [4:0] aux_burst,
  input  wire         aux_read,
  input  wire         aux_write,
  output wire  [31:0] aux_read_data,
  output wire   [1:0] aux_read_be,
  output logic        aux_data_valid,
  output logic        aux_done,

  output logic        sdram_ready,

  output wire  [24:0] controller_address,
  output wire [255:0] controller_write_data,
  output wire  [31:0] controller_byte_enable,
  output wire   [4:0] controller_burst,
  output wire         controller_read,
  output wire         controller_write,
  input  wire  [15:0] controller_read_data,
  // A controller without per-beat validity may tie this low; single-word read
  // data is then taken at the completion handshake.
  input  wire         controller_dout_valid,
  input  wire         controller_ready
);
  // What the arbitration below launches. ki_sdram_x2 carries these to the
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

  // Returned beats pass straight through to the port that owns the
  // transaction: the pack already registers each one, and a second register
  // here would cost a clock on every beat of every read. Data and width both
  // hold between beats, so a single-word requester can still take them at
  // done.
  logic owner = 1'b0;   // 0 = primary owns the in-flight transaction, 1 = auxiliary
  assign request_read_data  = packed_data;
  assign request_read_be    = packed_be;
  assign request_data_valid = packed_valid && !owner;
  assign aux_read_data      = packed_data;
  assign aux_read_be        = packed_be;
  assign aux_data_valid     = packed_valid && owner;
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

  logic aux_pending = 1'b0;
  logic aux_pending_write = 1'b0;
  logic [24:0] aux_pending_address = 25'd0;
  logic [63:0] aux_pending_write_data = 64'd0;
  logic  [7:0] aux_pending_byte_enable = 8'h00;
  logic  [4:0] aux_pending_burst = 5'd1;

  localparam integer AUX_STARVE_LIMIT = 32;
  logic [5:0] aux_wait = '0;
  wire aux_starved = (aux_wait >= AUX_STARVE_LIMIT[5:0]);

  assign sdram_ready = startup_done;

  // A primary request arriving while nothing is queued and the controller is
  // free goes straight out on this clock, rather than being captured into
  // req_pending first and launched from there on the next, which would cost a
  // clock on every SDRAM operation. A request that arrives while one is queued,
  // or while the adapter is busy, still queues.
  wire request_now = request_read || request_write;
  wire launch_direct = (state == ADAPTER_IDLE) && packed_ready && startup_done &&
                       !req_pending && request_now && !(aux_pending && aux_starved);

  always_ff @(posedge clk) begin
    request_done <= 1'b0;
    aux_done <= 1'b0;
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
      aux_pending <= 1'b0;
      aux_pending_burst <= 5'd1;
      owner <= 1'b0;
      aux_wait <= '0;
    end else begin
      if (!aux_pending)
        aux_wait <= '0;
      else if (!aux_starved)
        aux_wait <= aux_wait + 1'b1;

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
            owner <= 1'b0;
            state <= ADAPTER_SETTLE;
          end else if (packed_ready && startup_done) begin
            if (req_pending && !(aux_pending && aux_starved)) begin
              issue_address <= {req_pending_address[23:0], 1'b0};
              issue_write_data <= req_pending_write_data;
              issue_byte_enable <= req_pending_byte_enable;
              issue_burst <= req_pending_burst;
              issue_read <= !req_pending_write;
              issue_write <= req_pending_write;
              req_pending <= 1'b0;
              owner <= 1'b0;
              state <= ADAPTER_SETTLE;
            end else if (aux_pending) begin
              issue_address <= {aux_pending_address[23:0], 1'b0};
              issue_write_data <= {192'd0, aux_pending_write_data};
              issue_byte_enable <= {24'd0, aux_pending_byte_enable};
              issue_burst <= aux_pending_burst;
              issue_read <= !aux_pending_write;
              issue_write <= aux_pending_write;
              aux_pending <= 1'b0;
              owner <= 1'b1;
              state <= ADAPTER_SETTLE;
            end
          end
        end

        // The controller detects requests on the rising edge of rd/we and
        // lowers `ready` one cycle later. Wait that cycle out before polling
        // `ready`, otherwise the still-high pre-request value is mistaken for
        // completion.
        ADAPTER_SETTLE: state <= ADAPTER_WAIT;

        ADAPTER_WAIT: begin
          if (packed_ready) begin
            if (owner) begin
              aux_done <= 1'b1;
            end else begin
              request_done <= 1'b1;
            end
            state <= ADAPTER_ACK;
          end
        end

        ADAPTER_ACK: state <= ADAPTER_IDLE;
      endcase

      // Sequenced last on purpose: see rule 1 in the header comment. A
      // request launched directly above is not queued as well.
      if (request_now && !launch_direct) begin
        req_pending <= 1'b1;
        req_pending_write <= request_write;
        req_pending_address <= request_address;
        req_pending_write_data <= request_write_data;
        req_pending_byte_enable <= request_byte_enable;
        req_pending_burst <= (request_burst == 0) ? 5'd1 : request_burst;
      end
      if (aux_read || aux_write) begin
        aux_pending <= 1'b1;
        aux_pending_write <= aux_write;
        aux_pending_address <= aux_address;
        aux_pending_write_data <= aux_write_data;
        aux_pending_byte_enable <= aux_byte_enable;
        aux_pending_burst <= (aux_burst == 0) ? 5'd1 : aux_burst;
      end
    end
  end
endmodule

`default_nettype wire
