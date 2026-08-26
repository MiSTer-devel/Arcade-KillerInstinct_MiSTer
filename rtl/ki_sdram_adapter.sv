// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_sdram_adapter (
  input  wire         clk,
  input  wire         reset,

  // Primary requester (CPU/video/download bridge). Wins arbitration.
  // Word address (16-bit words); only [23:0] reach the 25-bit byte-addressed
  // controller.
  input  wire  [24:0] request_address,
  input  wire  [63:0] request_write_data,
  input  wire   [7:0] request_byte_enable,
  // Words to transfer: 1..16 on a read, 1..4 on a write (the controller
  // clamps writes to the width of its 4-word payload).
  input  wire   [4:0] request_burst,
  input  wire         request_read,
  input  wire         request_write,
  output logic [15:0] request_read_data,
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
  output logic [15:0] aux_read_data,
  output logic        aux_data_valid,
  output logic        aux_done,

  output logic        sdram_ready,

  output logic [24:0] controller_address,
  output logic [63:0] controller_write_data,
  output logic  [7:0] controller_byte_enable,
  output logic  [4:0] controller_burst,
  output logic        controller_read,
  output logic        controller_write,
  input  wire  [15:0] controller_read_data,
  // A controller without per-beat validity may tie this low; single-word read
  // data is then captured from the completion handshake.
  input  wire         controller_dout_valid,
  input  wire         controller_ready
);
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
  logic [63:0] req_pending_write_data = 64'd0;
  logic  [7:0] req_pending_byte_enable = 8'h00;
  logic  [4:0] req_pending_burst = 5'd1;

  logic aux_pending = 1'b0;
  logic aux_pending_write = 1'b0;
  logic [24:0] aux_pending_address = 25'd0;
  logic [63:0] aux_pending_write_data = 64'd0;
  logic  [7:0] aux_pending_byte_enable = 8'h00;
  logic  [4:0] aux_pending_burst = 5'd1;

  // 0 = primary owns the in-flight transaction, 1 = auxiliary owns it.
  logic owner = 1'b0;

  localparam integer AUX_STARVE_LIMIT = 32;
  logic [5:0] aux_wait = '0;
  wire aux_starved = (aux_wait >= AUX_STARVE_LIMIT[5:0]);

  assign sdram_ready = startup_done;

  always_ff @(posedge clk) begin
    request_done <= 1'b0;
    request_data_valid <= 1'b0;
    aux_done <= 1'b0;
    aux_data_valid <= 1'b0;
    controller_read <= 1'b0;
    controller_write <= 1'b0;

    // Stream burst beats straight through to whichever port owns the
    // transaction. Harmless when the controller never asserts it.
    if (controller_dout_valid) begin
      if (owner) begin
        aux_read_data <= controller_read_data;
        aux_data_valid <= 1'b1;
      end else begin
        request_read_data <= controller_read_data;
        request_data_valid <= 1'b1;
      end
    end

    if (reset) begin
      state <= ADAPTER_IDLE;
      startup_done <= 1'b0;
      request_read_data <= 16'd0;
      aux_read_data <= 16'd0;
      controller_address <= 25'd0;
      controller_write_data <= 64'd0;
      controller_byte_enable <= 8'h00;
      controller_burst <= 5'd1;
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

      if (controller_ready)
        startup_done <= 1'b1;

      case (state)
        ADAPTER_IDLE: begin
          if (controller_ready && startup_done) begin
            if (req_pending && !(aux_pending && aux_starved)) begin
              controller_address <= {req_pending_address[23:0], 1'b0};
              controller_write_data <= req_pending_write_data;
              controller_byte_enable <= req_pending_byte_enable;
              controller_burst <= req_pending_burst;
              controller_read <= !req_pending_write;
              controller_write <= req_pending_write;
              req_pending <= 1'b0;
              owner <= 1'b0;
              state <= ADAPTER_SETTLE;
            end else if (aux_pending) begin
              controller_address <= {aux_pending_address[23:0], 1'b0};
              controller_write_data <= aux_pending_write_data;
              controller_byte_enable <= aux_pending_byte_enable;
              controller_burst <= aux_pending_burst;
              controller_read <= !aux_pending_write;
              controller_write <= aux_pending_write;
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
          if (controller_ready) begin
            if (owner) begin
              aux_read_data <= controller_read_data;
              aux_done <= 1'b1;
            end else begin
              request_read_data <= controller_read_data;
              request_done <= 1'b1;
            end
            state <= ADAPTER_ACK;
          end
        end

        ADAPTER_ACK: state <= ADAPTER_IDLE;
      endcase

      // Sequenced last on purpose: see rule 1 in the header comment.
      if (request_read || request_write) begin
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
