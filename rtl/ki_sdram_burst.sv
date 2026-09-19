// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// Burst-capable 16-bit SDRAM controller for Killer Instinct.
//
// Two design choices provide the required throughput:
//
// 1. ADDRESS DECOMPOSITION. The controller uses col = addr[9:1],
//    row = addr[22:10], bank = addr[24:23], so 512
//    consecutive words share a row and any naturally-aligned burst up to 512
//    words stays inside it.
//
// 2. COLUMN STREAMING. The mode register stays at BURST_LENGTH=1; a burst is
//    produced by issuing N back-to-back READ commands on consecutive columns
//    inside one open row. After the initial ACTIVE + tRCD + CAS latency, that
//    is one word per clock.
//
// 3. NO CLOCK THE DEVICE DOES NOT NEED. S_IDLE acts on a request on the edge
//    it arrives, a row change issues PRECHARGE, ACTIVE and the command one
//    clock apart - each pair at its 18 ns floor, which one 20 ns clock meets -
//    and a read releases on the edge that captures its last word. Together
//    with ki_sdram_adapter launching an arriving request directly and passing
//    words straight through, that takes three clocks off every read and three
//    more off every row change. The MT48 model $fatals on a violated tRP, tRCD or tRC, so
//    every bench using it checks the spacing.
//
// Writes burst up to 16 words. A write burst needs no streaming handshake
// because the payload is presented all at once: `din` is 16 words wide - one
// 32-byte cache line, the largest write anything above issues - and `wtbt` is
// one enable pair per word, driven onto DQM per beat. A word with no enabled
// bytes still consumes its column but writes nothing.
module ki_sdram_burst #(
  // DRAM timing floors in CYCLES of clk. Defaults are for a 50 MHz (20 ns)
  // clock: tRP 18ns -> 1, tRCD 18ns -> 1. Recompute if the clock changes; the
  // MT48 simulation model $fatals on a violated floor, so a too-small value
  // fails loudly rather than silently corrupting data.
  parameter [3:0] T_RP  = 4'd1,
  parameter [3:0] T_RCD = 4'd1,
  parameter [14:0] STARTUP_CYCLES = 15'd6000,   // 120 us @ 50 MHz, >= 100 us
  parameter [12:0] REFRESH_PERIOD = 13'd365     // 7.3 us @ 50 MHz, < 7.8 us
) (
  input  wire         init,
  input  wire         clk,

  inout  wire  [15:0] SDRAM_DQ,
  output logic [12:0] SDRAM_A,
  output logic        SDRAM_DQML,
  output logic        SDRAM_DQMH,
  output logic  [1:0] SDRAM_BA,
  output wire         SDRAM_nCS,
  output wire         SDRAM_nWE,
  output wire         SDRAM_nRAS,
  output wire         SDRAM_nCAS,
  output wire         SDRAM_CKE,

  // Write byte mask, one pair per word: [2n+1]=high byte, [2n]=low byte.
  input  wire  [31:0] wtbt,
  input  wire  [24:0] addr,      // BYTE address; addr[0]=0 for 16-bit access
  // Words to transfer: 1..16 on a read, 1..MAX_WRITE_BURST on a write.
  input  wire   [4:0] burst,
  output logic [15:0] dout,
  // One pulse per returned word, in order. The LAST word's pulse and `ready`
  // rise on the same edge: S_READ_DRAIN releases as it captures that word.
  // ki_sdram_adapter turns `ready` into a done a clock later, so its own
  // ports keep the final word strictly before done.
  output logic        dout_valid,
  input  wire [255:0] din,       // up to 16 words, low word first
  input  wire         we,
  input  wire         rd,
  output logic        ready = 1'b0
);
  // Bounded by the width of `din`, not by DRAM. A 32-byte cache line is
  // 16 words, and issuing it as ONE burst instead of four 4-word ones saves
  // three lots of the per-transaction overhead - measured at ~16 CPU cycles
  // each against 8 cycles of actual data. See docs/OPTIMIZATION-HISTORY.md.
  localparam [4:0] MAX_WRITE_BURST = 5'd16;
  localparam [2:0] CAS_LATENCY = 3'd2;
  localparam logic [12:0] MODE =
      {3'b000, 1'b1 /*single write*/, 2'b00, CAS_LATENCY, 1'b0, 3'b000};

  localparam [2:0] CMD_NOP          = 3'b111;
  localparam [2:0] CMD_ACTIVE       = 3'b011;
  localparam [2:0] CMD_READ         = 3'b101;
  localparam [2:0] CMD_WRITE        = 3'b100;
  localparam [2:0] CMD_PRECHARGE    = 3'b010;
  localparam [2:0] CMD_AUTO_REFRESH = 3'b001;
  localparam [2:0] CMD_LOAD_MODE    = 3'b000;

  typedef enum logic [3:0] {
    S_STARTUP,
    S_IDLE,
    S_REFRESH,
    S_ACTIVE,
    S_RCD,
    S_READ,
    S_READ_DRAIN,
    S_WRITE,
    S_PRECHARGE,
    S_TURNAROUND,
    S_RP
  } state_t;

  state_t state = S_STARTUP;
  logic [2:0] command = CMD_NOP;

  logic [14:0] init_cnt = '0;
  logic [12:0] refresh_cnt = '0;
  logic refresh_due = 1'b0;
  logic [3:0] wait_cnt = '0;
  logic [3:0] refresh_wait = '0;

  logic        open_valid = 1'b0;
  logic [12:0] open_row = '0;
  logic  [1:0] open_bank = 2'b00;

  logic [24:0] req_addr = '0;
  logic [255:0] req_din = '0;
  logic [31:0] req_wtbt = 32'h0000_0000;
  logic  [4:0] req_burst = 5'd1;
  logic req_we = 1'b0;
  logic pending = 1'b0;

  logic [8:0] col;
  logic [4:0] beats_left;
  logic [4:0] beats_out;

  // Which word of req_din the next WRITE command carries.
  logic [3:0] wr_index = 4'd0;
  // {wr_index, 4'd0} is wr_index * 16 in 8 bits, which a 4-bit index cannot
  // overflow; likewise {wr_index, 1'b0} is wr_index * 2.
  wire [15:0] wr_word = req_din[{wr_index, 4'd0} +: 16];
  wire  [1:0] wr_be   = req_wtbt[{wr_index, 1'b0} +: 2];

  logic [CAS_LATENCY:0] cas_pipe = '0;

  logic [15:0] dq_out = 16'd0;
  logic dq_oe = 1'b0;

  logic old_we = 1'b0;
  logic old_rd = 1'b0;

  assign SDRAM_DQ   = dq_oe ? dq_out : 16'bz;
  assign SDRAM_CKE  = 1'b1;
  assign SDRAM_nCS  = 1'b0;
  assign SDRAM_nRAS = command[2];
  assign SDRAM_nCAS = command[1];
  assign SDRAM_nWE  = command[0];

  // Column carries the LOW address bits so a burst walks inside one row.
  wire [8:0]  req_col  = req_addr[9:1];
  wire [12:0] req_row  = req_addr[22:10];
  wire [1:0]  req_bank = req_addr[24:23];

  // The request S_IDLE acts on this cycle: one arriving NOW, taken straight
  // from the inputs, or one held in `pending` from a state that could not take
  // it. Acting on the arriving edge saves the clock the edge detector used to
  // spend loading `pending` before S_IDLE looked at it - a clock on every
  // SDRAM operation this core makes.
  wire        new_rd    = rd && !old_rd;
  wire        new_we    = we && !old_we;
  wire        new_req   = new_rd || new_we;
  wire        cur_valid = new_req || pending;
  wire        cur_we    = new_req ? new_we : req_we;
  wire [24:0] cur_addr  = new_req ? addr : req_addr;
  wire  [4:0] cur_burst = new_req ?
      ((burst == 0) ? 5'd1 :
       (new_we && (burst > MAX_WRITE_BURST)) ? MAX_WRITE_BURST : burst) :
      req_burst;
  wire [8:0]  cur_col   = cur_addr[9:1];
  wire [12:0] cur_row   = cur_addr[22:10];
  wire [1:0]  cur_bank  = cur_addr[24:23];
  wire        cur_row_hit = open_valid && (cur_row == open_row) && (cur_bank == open_bank);
  // S_IDLE starts the arriving request itself - a row hit, or no row open -
  // so the capture block below must not also leave it pending. A row CHANGE
  // still captures it: S_ACTIVE issues it a clock later from req_*.
  wire        take_new  = (state == S_IDLE) && !refresh_due && new_req &&
                          (cur_row_hit || !open_valid);

  always_ff @(posedge clk) begin
    command <= CMD_NOP;
    dq_oe <= 1'b0;
    dout_valid <= 1'b0;

    // CAS return pipeline. One bit per outstanding READ; back-to-back reads
    // keep several in flight at once.
    cas_pipe <= {1'b0, cas_pipe[CAS_LATENCY:1]};
    if (cas_pipe[0]) begin
      dout <= SDRAM_DQ;
      dout_valid <= 1'b1;
      beats_out <= beats_out - 1'b1;
    end

    if (refresh_cnt >= REFRESH_PERIOD) begin
      refresh_cnt <= '0;
      refresh_due <= 1'b1;
    end else begin
      refresh_cnt <= refresh_cnt + 1'b1;
    end

    case (state)
      S_STARTUP: begin
        SDRAM_A <= 13'd0;
        SDRAM_BA <= 2'd0;
        init_cnt <= init_cnt + 1'b1;
        if (init_cnt == STARTUP_CYCLES - 200) begin
          command <= CMD_PRECHARGE;
          SDRAM_A[10] <= 1'b1;
        end
        if (init_cnt == STARTUP_CYCLES - 150) command <= CMD_AUTO_REFRESH;
        if (init_cnt == STARTUP_CYCLES - 100) command <= CMD_AUTO_REFRESH;
        if (init_cnt == STARTUP_CYCLES - 50) begin
          command <= CMD_LOAD_MODE;
          SDRAM_A <= MODE;
        end
        if (init_cnt >= STARTUP_CYCLES) begin
          state <= S_IDLE;
          ready <= 1'b1;
          refresh_due <= 1'b0;
          refresh_cnt <= '0;
        end
      end

      S_IDLE: begin
        if (refresh_due) begin
          // AUTO_REFRESH needs every bank precharged. Close the row first and
          // come back: refresh_due is still set, and open_valid will be clear.
          if (open_valid) begin
            state <= S_PRECHARGE;
          end else begin
            command <= CMD_AUTO_REFRESH;
            refresh_due <= 1'b0;
            refresh_wait <= 4'd8;        // tRFC
            state <= S_REFRESH;
          end
        end else if (cur_valid) begin
          if (cur_row_hit) begin
            // ROW HIT: the row is already ACTIVE, so no ACTIVE and no tRCD.
            pending <= 1'b0;
            SDRAM_BA <= cur_bank;
            col <= cur_col;
            beats_left <= cur_burst;
            beats_out <= cur_we ? 5'd0 : cur_burst;
            wr_index <= 4'd0;
            state <= cur_we ? S_WRITE : S_READ;
          end else if (open_valid) begin
            // Row change: PRECHARGE on THIS clock, ACTIVE on the next (S_ACTIVE)
            // and the command on the one after. Each pair is one clock - 20 ns
            // at 50 MHz against the 18 ns tRP and tRCD floors - where this used
            // to go S_PRECHARGE, S_RP, S_IDLE, ACTIVE, S_RCD: five clocks before
            // the command instead of two. The request is held in req_* and
            // pending (the capture block below keeps an arriving one).
            open_valid <= 1'b0;
            command <= CMD_PRECHARGE;
            SDRAM_A[10] <= 1'b1;             // all banks
            if (T_RP <= 4'd1) begin
              state <= S_ACTIVE;
            end else begin
              wait_cnt <= T_RP - 4'd1;
              state <= S_RP;
            end
          end else begin
            // Nothing open: ACTIVE now, the command T_RCD clocks later.
            pending <= 1'b0;
            command <= CMD_ACTIVE;
            SDRAM_A <= cur_row;
            SDRAM_BA <= cur_bank;
            open_valid <= 1'b1;
            open_row <= cur_row;
            open_bank <= cur_bank;
            col <= cur_col;
            beats_left <= cur_burst;
            beats_out <= cur_we ? 5'd0 : cur_burst;
            wr_index <= 4'd0;
            if (T_RCD <= 4'd1) begin
              state <= cur_we ? S_WRITE : S_READ;
            end else begin
              wait_cnt <= T_RCD - 4'd1;
              state <= S_RCD;
            end
          end
        end
      end

      // One clock after a row change's PRECHARGE (tRP), open the new row from
      // the held request.
      S_ACTIVE: begin
        pending <= 1'b0;
        command <= CMD_ACTIVE;
        SDRAM_A <= req_row;
        SDRAM_BA <= req_bank;
        open_valid <= 1'b1;
        open_row <= req_row;
        open_bank <= req_bank;
        col <= req_col;
        beats_left <= req_burst;
        beats_out <= req_we ? 5'd0 : req_burst;
        wr_index <= 4'd0;
        if (T_RCD <= 4'd1) begin
          state <= req_we ? S_WRITE : S_READ;
        end else begin
          wait_cnt <= T_RCD - 4'd1;
          state <= S_RCD;
        end
      end

      S_REFRESH: begin
        if (refresh_wait <= 1) state <= S_IDLE;
        else refresh_wait <= refresh_wait - 1'b1;
      end

      S_RCD: begin
        if (wait_cnt <= 1) state <= req_we ? S_WRITE : S_READ;
        else wait_cnt <= wait_cnt - 1'b1;
      end

      // Back-to-back column reads inside the open row: one word per clock.
      S_READ: begin
        command <= CMD_READ;
        SDRAM_A <= {2'b00, 2'b00, col};   // A[10]=0: no auto-precharge
        SDRAM_DQMH <= 1'b0;
        SDRAM_DQML <= 1'b0;
        cas_pipe[CAS_LATENCY] <= 1'b1;
        col <= col + 1'b1;
        if (beats_left <= 1) state <= S_READ_DRAIN;
        else beats_left <= beats_left - 1'b1;
      end

      S_READ_DRAIN: begin
        // Wait for every issued read to return before closing the row.
        // STRICTLY zero outstanding. The old condition also released while the
        // final beat was still in the CAS pipe, which was safe only because a
        // PRECHARGE always followed and burned the cycles. Now that IDLE can
        // start the next burst immediately on a row hit, releasing early lets
        // that last beat land after beats_out has been reloaded, and it is
        // counted into the following burst - the bench saw 2N-2 beats.
        //
        // Releasing on the edge that captures the LAST beat is not that: the
        // capture above takes beats_out to zero on this same edge, so nothing
        // is left in the pipe, and the next burst cannot load beats_out before
        // the next edge. It saves the clock spent seeing zero.
        if ((beats_out == 0) || ((beats_out == 5'd1) && cas_pipe[0])) begin
          ready <= 1'b1;
          state <= S_IDLE;               // row stays open
        end
      end

      // Back-to-back column writes inside the open row, mirroring S_READ.
      // Write data has no latency: it is sampled by the device on the same
      // edge as its WRITE command, so command, column, DQM and DQ all advance
      // together. A word whose enables are clear is still issued, with both
      // DQM bits high so the device writes none of it.
      S_WRITE: begin
        command <= CMD_WRITE;
        SDRAM_A <= {2'b00, 2'b00, col};   // A[10]=0: no auto-precharge
        SDRAM_DQMH <= ~wr_be[1];
        SDRAM_DQML <= ~wr_be[0];
        dq_out <= wr_word;
        dq_oe <= 1'b1;
        col <= col + 1'b1;
        wr_index <= wr_index + 1'b1;
        // PRECHARGE lands one clock after the last WRITE, which at 50 MHz is
        // 20 ns and satisfies tWR (15 ns) - the same spacing the single-word
        // path used and proved on hardware.
        if (beats_left <= 1) begin
          wait_cnt <= 4'd2;
          state <= S_TURNAROUND;         // row stays open
        end else beats_left <= beats_left - 1'b1;
      end

      // tWR before any PRECHARGE that follows, and tWTR before any READ.
      // The old path put PRECHARGE one clock after the last WRITE, which met
      // tWR at 50 MHz; two clocks is more margin, not less.
      S_TURNAROUND: begin
        if (wait_cnt <= 1) begin
          ready <= 1'b1;
          state <= S_IDLE;
        end else wait_cnt <= wait_cnt - 1'b1;
      end

      S_PRECHARGE: begin
        open_valid <= 1'b0;
        command <= CMD_PRECHARGE;
        SDRAM_A[10] <= 1'b1;             // all banks
        wait_cnt <= T_RP;
        state <= S_RP;
      end

      S_RP: begin
        if (wait_cnt <= 1) begin
          // Only when nothing is outstanding. A row miss precharges with the
          // request still pending, and signalling ready there would invite the
          // requester to overwrite it before it has been serviced.
          if (!pending) ready <= 1'b1;
          state <= S_IDLE;
        end else begin
          wait_cnt <= wait_cnt - 1'b1;
        end
      end

      default: state <= S_IDLE;
    endcase

    if (init) begin
      state <= S_STARTUP;
      init_cnt <= '0;
      ready <= 1'b0;
      pending <= 1'b0;
      cas_pipe <= '0;
      refresh_due <= 1'b0;
    end

    // Edge-detected request capture, matching the stock controller's contract.
    // A request S_IDLE started on this same edge (take_new) is captured all
    // the same - S_WRITE needs req_din and req_wtbt, S_RCD req_we - but is not
    // left pending.
    old_we <= we;
    if (new_we) begin
      req_addr <= addr;
      req_din <= din;
      req_wtbt <= wtbt;
      req_we <= 1'b1;
      req_burst <= (burst == 0) ? 5'd1 :
                   (burst > MAX_WRITE_BURST) ? MAX_WRITE_BURST : burst;
      pending <= !take_new;
      ready <= 1'b0;
    end

    old_rd <= rd;
    if (new_rd) begin
      req_addr <= addr;
      req_we <= 1'b0;
      req_burst <= (burst == 0) ? 5'd1 : burst;
      pending <= !take_new;
      ready <= 1'b0;
    end

`ifndef SYNTHESIS
    // One request at a time: the adapter launches only on `ready`, which the
    // capture above lowers. A second edge while one is pending would be lost.
    if (!init && new_req && pending) begin
      $error("ki_sdram_burst: a request arrived while another was pending");
      $fatal(1);
    end
    if (!init && new_rd && new_we) begin
      $error("ki_sdram_burst: read and write requested on the same edge");
      $fatal(1);
    end
`endif
  end
endmodule

`default_nettype wire
