// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// Burst-capable 16-bit SDRAM controller for Killer Instinct.
//
// Six design choices provide the required throughput:
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
// 3. NO CLOCK THE DEVICE DOES NOT NEED. A row change issues PRECHARGE, waits
//    out tRP and issues ACTIVE from S_IDLE on the next clock, a read that
//    hits the open row issues its first READ from S_IDLE itself - the direct
//    port's qword read, and a stream's line read, on the edge that takes it,
//    its row compared as it arrives - a read releases on the edge that
//    captures its last word, and a write with its last WRITE command: its
//    tWR runs out in S_TURNAROUND behind the release, and a request taken
//    meanwhile waits there for S_IDLE.
//    ki_sdram_adapter launches an arriving request directly and passes words
//    straight through.
//
// 4. THE ROW CLOSES WHEN IDLE. With nothing pending and tRAS met, S_IDLE
//    precharges every bank, so the next access to another row starts with
//    ACTIVE instead of waiting out PRECHARGE and tRP first. Only one row is
//    open at a time, across all four banks, so most accesses are to another
//    row; one to the row just closed pays ACTIVE and tRCD instead of hitting
//    it. A write has already waited out tWR in S_TURNAROUND before S_IDLE
//    sees it.
//
//    The exceptions are the direct port's reads that come in runs. A qword
//    read - an uncached load's - keeps its row open for ROW_HOLD idle clocks
//    first: such loads come in runs through one row, and the next then hits
//    it. So does a line read its requester marks as a stream's (fast_stream:
//    the data cache's read-ahead of the line after one the CPU waited for),
//    for ROW_HOLD_RA idle clocks, unless it is the last line of its row: the
//    stream's next line then hits the row and, marked the same way, issues
//    its first READ on the edge that takes it, as a qword read does. Any
//    request taken ends a hold, so only those reads leave a row open, and
//    refresh still closes it.
//
//    A stream line that IS the last of its row opens the row after it. Its
//    drain precharges the row on its first edge, tRAS allowing - S_IDLE
//    closes it as above otherwise - and S_IDLE, tRP later - with nothing
//    pending, nothing taken on that edge and no refresh due - issues the
//    ACTIVE for the next row number, carrying into the bank bits, with no
//    request behind it (S_RCD_NEXT waits out tRCD). It then holds that row
//    ROW_HOLD_RA idle clocks, as after a stream line in mid-row, so the
//    stream's next line finds it open; a request to another row waits for
//    tRAS from that ACTIVE before its PRECHARGE, as after any ACTIVE. Any
//    request taken before the ACTIVE, and any refresh, drops it.
//
// 5. A SECOND PORT FOR THE CPU'S READS. A toggle on fast_tog asks for one
//    16-word read at fast_addr - a cache line - or, with fast_addr's bit 0
//    set, a 4-word one, a qword; no SDRAM address uses bit 0. It is taken
//    into req_* on the first clock that sees it with nothing pending, and
//    its words come back on fast_valid instead of dout_valid. The CPU uses it
//    only when nothing of its own is in the bridge's path (cpu.vhd,
//    fast_path_clear), so nothing else can be waiting for this controller
//    then. A second request may toggle while the first is being served (a
//    fill queued behind it, cpu.vhd's fast_go_q, asked for once the first's
//    first word is back); it is taken when the first has drained. fast_stream
//    holds beside fast_addr, like it, and marks a line read as a stream's
//    (design choice 4).
//
// 6. REFRESH BESIDE THE READS. A refresh due while a read drains starts in
//    S_READ_DRAIN: PRECHARGE on the first edge that sees it - the edge after
//    the last READ at the earliest, which at CAS latency 2 still returns that
//    READ's word - and AUTO_REFRESH T_RP later; the release then goes to
//    S_REFRESH for the rest of tRFC. Never on the release edge, so S_IDLE,
//    which refreshes on the edge after it, still finds tRP met. A stream line
//    read whose last READ comes within RF_EARLY clocks of the refresh falling
//    due ends the refresh period on its drain's first edge, as the counter
//    would have, and refreshes there: the stream's next line would otherwise
//    find it due. The period only ever ends early. S_IDLE's own refresh
//    precharges on the edge that sees it and waits T_RP - 1, and S_REFRESH
//    counts T_RFC - 1: tRP and tRFC exactly, as the row change's PRECHARGE
//    and ACTIVE wait T_RP and T_RCD.
//
// Writes burst up to 16 words. A write burst needs no streaming handshake
// because the payload is presented all at once: `din` is 16 words wide - one
// 32-byte cache line, the largest write anything above issues - and `wtbt` is
// one enable pair per word, driven onto DQM per beat. A word with no enabled
// bytes still consumes its column but writes nothing.
module ki_sdram_burst #(
  // DRAM timing floors in CYCLES of clk, a 100 MHz (10 ns) clock. Recompute
  // EVERY one of them if the clock changes.
  //
  //                     ns   @100 MHz
  //   tRP    precharge  18      2
  //   tRCD   act->cmd   18      2
  //   tRAS   act->pre   42      5
  //   tRC    act->act   60      7
  //   tRFC   refresh    66      7
  //   tWR    write rec  15      2
  //   CL     cas        --      2    in spec for a -75 part at 100 MHz
  //
  // T_RAS and T_RC are load-bearing: without them a single-word access would
  // precharge 30 ns after its ACTIVE. Every ACTIVE waits for T_RC from the
  // last one and every PRECHARGE for T_RAS.
  //
  // T_RP must be 2 and T_RCD at least 2: the row-change and open-row paths
  // each spend a counted wait state between their two commands, so a 1 would
  // silently behave as 2; and S_IDLE may decide a command on the edge after a
  // release, two clocks after a PRECHARGE the drain decided on the edge
  // before it (design choice 6).
  parameter [3:0] T_RP  = 4'd2,
  parameter [3:0] T_RCD = 4'd2,
  parameter [4:0] T_RAS = 5'd5,
  parameter [4:0] T_RC  = 5'd7,
  parameter [3:0] T_RFC = 4'd7,
  parameter [3:0] T_WR  = 4'd2,
  parameter [2:0] CAS_LATENCY = 3'd2,
  parameter [14:0] STARTUP_CYCLES = 15'd12000,  // 120 us, >= 100 us
  parameter [12:0] REFRESH_PERIOD = 13'd730     // 7.3 us, < 7.8 us
) (
  input  wire         init,
  input  wire         clk,
  // The DQ capture clock. DQ is captured on its own clock, positioned inside
  // the device's data eye, because clk has no edge there. The device drives a
  // word at pin-phase + tAC and replaces it a clock later; with the 6.75 ns
  // pin phase the eye is 12.75..19.25 ns, while clk's edges fall at 10.50 and
  // 20.50 and miss it by 1.25 ns. No seed and no multicycle can rescue a
  // capture on clk: there is no edge inside the eye to name.
  //
  // The capture clock's word transfers into clk on the edge a capture on clk
  // would have used, so cas_take and the state machine only see where the
  // data comes from, not when. It must come from the SAME PLL as clk so that
  // handoff is synchronous rather than a domain crossing.
  input  wire         clk_cap,

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
  output logic        ready = 1'b0,

  // The CPU's direct fill port; see design choice 5. fast_tog and fast_addr
  // come from the CPU's clock, which runs at this one's frequency 0.5 ns
  // earlier; KillerInstinct.sdc gives that path two of these clocks.
  input  wire         fast_tog,
  input  wire  [24:0] fast_addr,
  // A line read is a stream's; see design choice 4.
  input  wire         fast_stream,
  output logic        fast_valid = 1'b0
);
  // Bounded by the width of `din`, not by DRAM. A 32-byte cache line is
  // 16 words, and issuing it as ONE burst instead of four 4-word ones saves
  // three lots of the per-transaction overhead.
  localparam [4:0] MAX_WRITE_BURST = 5'd16;
  localparam logic [12:0] MODE =
      {3'b000, 1'b1 /*single write*/, 2'b00, CAS_LATENCY, 1'b0, 3'b000};

  // Idle clocks a row stays open after a direct qword read, and after a
  // stream's line read in mid-row or the row after's ACTIVE (design choice
  // 4).
  localparam [5:0] ROW_HOLD    = 6'd32;
  localparam [5:0] ROW_HOLD_RA = 6'd12;
  // How close to the refresh falling due a stream line's last READ ends the
  // refresh period early (design choice 6).
  localparam [4:0] RF_EARLY = 5'd8;

  localparam [2:0] CMD_NOP          = 3'b111;
  localparam [2:0] CMD_ACTIVE       = 3'b011;
  localparam [2:0] CMD_READ         = 3'b101;
  localparam [2:0] CMD_WRITE        = 3'b100;
  localparam [2:0] CMD_PRECHARGE    = 3'b010;
  localparam [2:0] CMD_AUTO_REFRESH = 3'b001;
  localparam [2:0] CMD_LOAD_MODE    = 3'b000;

  // Elaboration-time checks of the configuration, for simulation only.
  // synthesis translate_off
  if ((T_RP < 4'd2) || (T_RCD < 4'd2)) begin : g_bad_floor
    $error("ki_sdram_burst: T_RP %0d and T_RCD %0d must each be at least 2",
           T_RP, T_RCD);
  end
  if (T_RFC < 4'd2) begin : g_bad_rfc
    $error("ki_sdram_burst: T_RFC %0d must be at least 2", T_RFC);
  end
  // S_IDLE may decide a command on the edge after a release, two clocks after
  // a PRECHARGE the drain decided on the edge before it.
  if (T_RP != 4'd2) begin : g_bad_drain_rp
    $error("ki_sdram_burst: T_RP must be 2, not %0d", T_RP);
  end
  // rf_near compares refresh_cnt with REFRESH_PERIOD - RF_EARLY: at or past
  // the period that is zero or wraps, and every stream line would end it.
  if (RF_EARLY >= REFRESH_PERIOD) begin : g_bad_early
    $error("ki_sdram_burst: RF_EARLY %0d must be under REFRESH_PERIOD %0d",
           RF_EARLY, REFRESH_PERIOD);
  end
  // synthesis translate_on

  // The same T_RP check for the build. Quartus takes no elaboration-time
  // $error, so an instance of a module that does not exist stops it
  // instead; the module's name says why.
  generate
    if (T_RP != 4'd2) begin : g_need_t_rp_2
      ki_sdram_burst_needs_T_RP_2 stop ();
    end
  endgenerate

  typedef enum logic [3:0] {
    S_STARTUP,
    S_IDLE,
    S_REFRESH,
    S_RCD,
    S_READ,
    S_READ_DRAIN,
    S_WRITE,
    S_TURNAROUND,
    S_RP,
    // tRCD after the ACTIVE of the row after a stream's row end.
    S_RCD_NEXT
  } state_t;

  state_t state = S_STARTUP;
  logic [2:0] command = CMD_NOP;

  logic [14:0] init_cnt = '0;
  logic [12:0] refresh_cnt = '0;
  logic refresh_due = 1'b0;
  logic [3:0] wait_cnt = '0;
  logic [3:0] refresh_wait = '0;
  // The drain has closed the row (for a refresh, or for a stream's row end)
  // / has decided its AUTO_REFRESH (tRFC then runs in refresh_wait).
  logic rf_pre = 1'b0;
  logic rf_ref = 1'b0;
  // The edge before was in S_READ_DRAIN, so this one is not its first.
  logic drain_d = 1'b0;
  // The refresh falls due within RF_EARLY clocks of the edge before.
  logic rf_near = 1'b0;

  // Clocks since the last ACTIVE, saturating. tRAS and tRC are the only two
  // floors measured from ACTIVE rather than from the command before, so one
  // counter serves both: PRECHARGE waits for tRAS, the next ACTIVE for tRC.
  // Saturation matters - an idle controller must not wrap back under a floor.
  logic [4:0] act_age = 5'd31;
  wire ras_ok = (act_age >= T_RAS);
  wire rc_ok  = (act_age >= T_RC);

  logic        open_valid = 1'b0;
  // Idle clocks the open row is still held; see ROW_HOLD.
  logic  [5:0] hold_cnt = 6'd0;
  logic [12:0] open_row = '0;
  logic  [1:0] open_bank = 2'b00;

  logic [24:0] req_addr = '0;
  // The transaction in req_* is the direct port's: its words go out on
  // fast_valid. Changes only when a request is taken, after the last word of
  // the one before.
  logic        req_fast = 1'b0;
  // ...and a line read marked fast_stream. Changes with req_fast.
  logic        req_stream = 1'b0;
  // S_IDLE is to open the row after a stream line read that
  // ended its row, next_bank_row as {bank, row} - that row's number plus
  // one, carrying into the bank, registered at the release so that no adder
  // sits on S_IDLE's command path. Cleared by any request taken and by a
  // refresh.
  logic        next_due = 1'b0;
  logic [14:0] next_bank_row = 15'd0;
  logic        fast_seen = 1'b0;
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

  // Unconditional - no enable, no reset - because that is what lets it pack
  // into the I/O cell, which is the whole point of capturing here.
  logic [15:0] dq_cap = 16'd0;
  // dq_stg exists because dq_cap lives in the I/O CELL and everything that
  // consumes it lives in the core. That trip is longer than the gap between
  // the capture edge and the next clk edge - the handoff, not the capture, is
  // what limits it.
  //
  // It cannot be fixed with the phase: the capture slack moves one for one
  // with the phase and the handoff far less, so it is routing-bound rather
  // than phase-bound. Nor with a multicycle - dq_cap is unconditional
  // and is overwritten every capture cycle, so there is no second edge at
  // which it still holds the word.
  //
  // Staging it on clk_cap gives that trip a FULL capture period instead of the
  // gap between two different clocks' edges. dq_stg is then an ordinary fabric
  // register sitting beside its consumer, and cas_take waits one more cycle
  // for it.
  logic [15:0] dq_stg = 16'd0;
  always_ff @(posedge clk_cap) begin
    dq_cap <= SDRAM_DQ;
    dq_stg <= dq_cap;
  end

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
  wire        req_row_hit = open_valid && (req_row == open_row) &&
                            (req_bank == open_bank);

  wire        new_rd    = rd && !old_rd;
  wire        new_we    = we && !old_we;
  wire        new_req   = new_rd || new_we;

  // The direct port's request as it arrives, before req_* holds it, and
  // whether S_IDLE starts it on this edge: a qword read, or a line read
  // marked fast_stream, to the open row, with nothing pending and no refresh
  // due.
  wire  [8:0] fast_col   = fast_addr[9:1];
  wire [12:0] fast_row   = fast_addr[22:10];
  wire  [1:0] fast_bank  = fast_addr[24:23];
  wire        fast_take  = !init && (fast_tog != fast_seen) && ready && !pending && !new_req;
  wire        fast_line_issue = !fast_addr[0] && fast_stream;
  wire        fast_issue = fast_take &&
                           (fast_addr[0] || fast_line_issue) &&
                           (state == S_IDLE) && !refresh_due && open_valid &&
                           (fast_row == open_row) && (fast_bank == open_bank);

  // One register stage between the command decode and the SDRAM output
  // cells. The path `old_we -> command[2]` is long, and a large part of it is
  // a SINGLE interconnect hop from the last decode LUT to command[2] - that
  // register is packed into the I/O cell at the SDRAM pins
  // (FAST_OUTPUT_REGISTER in the QSF) while the decode sits in the core, and
  // no logic change shortens the trip. Splitting there, AND acting on the
  // request from the req_* registers rather than the live inputs, makes both
  // halves short enough for 100 MHz. Either cut alone still misses.
  //
  // Every pin-facing signal moves together or they reach the device skewed.
  logic [2:0]  cmd_d  = CMD_NOP;
  logic [12:0] a_d    = 13'd0;
  logic [1:0]  ba_d   = 2'd0;
  logic        dqml_d = 1'b1;
  logic        dqmh_d = 1'b1;
  logic [15:0] dqo_d  = 16'd0;
  logic        dqoe_d = 1'b0;

  // cas_pipe counts from the clock the state machine ISSUED the read. There
  // is ONE DELAY PER REGISTER BETWEEN THE PIN AND dout, and there are three:
  // the command stage, which makes the device see the READ a clock later, and
  // dq_cap and dq_stg on the way back. So the word for a READ issued from
  // cas_pipe lands three clocks after cas_pipe[0].
  logic cas_d = 1'b0;
  logic cas_d2 = 1'b0;
  logic cas_d3 = 1'b0;
  wire  cas_take = cas_d3;
  // S_READ_DRAIN's release: the edge capturing the last word.
  wire  rd_release = (beats_out == 0) || ((beats_out == 5'd1) && cas_take);
  // The refresh period ended early, on a stream line's drain's first edge.
  wire  rf_early = !drain_d && rf_near && req_stream;
  // The row closed on the drain's first edge of a stream line ending its row.
  wire  end_pre = !drain_d && req_stream && (req_addr[9:5] == 5'h1F);
  // The drain's AUTO_REFRESH, decided on this edge: tRP met after its close.
  wire  dr_ref_now = rf_pre && !rf_ref && (wait_cnt <= 1) && refresh_due;

  always_ff @(posedge clk) begin
    command    <= cmd_d;
    SDRAM_A    <= a_d;
    SDRAM_BA   <= ba_d;
    SDRAM_DQML <= dqml_d;
    SDRAM_DQMH <= dqmh_d;
    dq_out     <= dqo_d;
    dq_oe      <= dqoe_d;
  end

  always_ff @(posedge clk) begin
    cmd_d <= CMD_NOP;
    dqoe_d <= 1'b0;
    dout_valid <= 1'b0;
    fast_valid <= 1'b0;

    // Saturating, so an idle controller cannot wrap back under a floor. The
    // ACTIVE branch below resets it, and because `command` is registered the
    // device sees ACTIVE one clock after the reset - which makes every gate
    // here conservative by one clock rather than short by one.
    if (act_age != 5'd31) act_age <= act_age + 1'b1;

    // CAS return pipeline. One bit per outstanding READ; back-to-back reads
    // keep several in flight at once.
    cas_pipe <= {1'b0, cas_pipe[CAS_LATENCY:1]};
    cas_d <= cas_pipe[0];
    cas_d2 <= cas_d;
    cas_d3 <= cas_d2;
    if (cas_take) begin
      dout <= dq_stg;
      if (req_fast) fast_valid <= 1'b1;
      else dout_valid <= 1'b1;
      beats_out <= beats_out - 1'b1;
    end

    if (refresh_cnt >= REFRESH_PERIOD) begin
      refresh_cnt <= '0;
      refresh_due <= 1'b1;
    end else begin
      refresh_cnt <= refresh_cnt + 1'b1;
    end
    rf_near <= (refresh_cnt >= REFRESH_PERIOD - RF_EARLY);
    drain_d <= (state == S_READ_DRAIN);

    case (state)
      S_STARTUP: begin
        a_d <= 13'd0;
        ba_d <= 2'd0;
        init_cnt <= init_cnt + 1'b1;
        if (init_cnt == STARTUP_CYCLES - 200) begin
          cmd_d <= CMD_PRECHARGE;
          a_d[10] <= 1'b1;
        end
        if (init_cnt == STARTUP_CYCLES - 150) cmd_d <= CMD_AUTO_REFRESH;
        if (init_cnt == STARTUP_CYCLES - 100) cmd_d <= CMD_AUTO_REFRESH;
        if (init_cnt == STARTUP_CYCLES - 50) begin
          cmd_d <= CMD_LOAD_MODE;
          a_d <= MODE;
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
            if (ras_ok) begin
              open_valid <= 1'b0;
              cmd_d <= CMD_PRECHARGE;
              a_d[10] <= 1'b1;             // all banks
              wait_cnt <= T_RP - 4'd1;
              state <= S_RP;
            end
          end else begin
            cmd_d <= CMD_AUTO_REFRESH;
            refresh_due <= 1'b0;
            refresh_wait <= T_RFC - 4'd1;
            next_due <= 1'b0;
            state <= S_REFRESH;
          end
        end else if (pending) begin
          hold_cnt <= 6'd0;
          if (req_row_hit) begin
            // ROW HIT: the row is already ACTIVE, so no ACTIVE and no tRCD.
            pending <= 1'b0;
            ba_d <= req_bank;
            col <= req_col;
            beats_left <= req_burst;
            beats_out <= req_we ? 5'd0 : req_burst;
            wr_index <= 4'd0;
            state <= req_we ? S_WRITE : S_READ;
            if (!req_we) begin
              // The first READ now, as S_READ would issue it a clock later;
              // S_READ goes on from the second.
              cmd_d <= CMD_READ;
              a_d <= {2'b00, 2'b00, req_col};   // A[10]=0: no auto-precharge
              dqmh_d <= 1'b0;
              dqml_d <= 1'b0;
              cas_pipe[CAS_LATENCY] <= 1'b1;
              col <= req_col + 1'b1;
              if (req_burst <= 1) state <= S_READ_DRAIN;
              else beats_left <= req_burst - 1'b1;
            end
          end else if (open_valid && ras_ok) begin
            // Row change: PRECHARGE now, and back here once tRP has passed,
            // with no row open, to issue the ACTIVE below. The request stays
            // in req_* and pending.
            open_valid <= 1'b0;
            cmd_d <= CMD_PRECHARGE;
            a_d[10] <= 1'b1;             // all banks
            wait_cnt <= T_RP - 4'd1;
            state <= S_RP;
          end else if (!open_valid && rc_ok) begin
            // Nothing open: ACTIVE now, the command T_RCD clocks later.
            pending <= 1'b0;
            cmd_d <= CMD_ACTIVE;
            act_age <= 5'd0;
            a_d <= req_row;
            ba_d <= req_bank;
            open_valid <= 1'b1;
            open_row <= req_row;
            open_bank <= req_bank;
            col <= req_col;
            beats_left <= req_burst;
            beats_out <= req_we ? 5'd0 : req_burst;
            wr_index <= 4'd0;
            wait_cnt <= T_RCD - 4'd1;
            state <= S_RCD;
          end
        end else if (fast_issue) begin
          // The direct port's qword read - or stream line read - arriving on
          // this edge: the ROW HIT branch above, from the request itself.
          hold_cnt <= 6'd0;
          ba_d <= fast_bank;
          beats_out <= fast_addr[0] ? 5'd4 : 5'd16;
          wr_index <= 4'd0;
          cmd_d <= CMD_READ;
          a_d <= {2'b00, 2'b00, fast_col};   // A[10]=0: no auto-precharge
          dqmh_d <= 1'b0;
          dqml_d <= 1'b0;
          cas_pipe[CAS_LATENCY] <= 1'b1;
          col <= fast_col + 1'b1;
          beats_left <= fast_addr[0] ? 5'd3 : 5'd15;
          state <= S_READ;
        end else if (open_valid && hold_cnt != 6'd0) begin
          // A direct qword read's row, or a stream line read's, held for the
          // next of its run.
          hold_cnt <= hold_cnt - 6'd1;
        end else if (open_valid && ras_ok) begin
          // Nothing waiting: close the row now, so the next access to another
          // row does not wait for it. A request arriving during tRP stays
          // pending and is taken in S_IDLE after.
          open_valid <= 1'b0;
          cmd_d <= CMD_PRECHARGE;
          a_d[10] <= 1'b1;             // all banks
          wait_cnt <= T_RP - 4'd1;
          state <= S_RP;
        end else if (next_due && !open_valid && rc_ok && !new_req && !fast_take) begin
          // The row after a stream's row end, with no request
          // behind it, opened and held for the stream's next line (design
          // choice 4). Last, so a refresh, a pending request and a request
          // taken on this edge all come first; the take-edge READ, the hold
          // and the close all need a row open, and this needs none.
          next_due <= 1'b0;
          cmd_d <= CMD_ACTIVE;
          act_age <= 5'd0;
          a_d <= next_bank_row[12:0];
          ba_d <= next_bank_row[14:13];
          open_valid <= 1'b1;
          open_row <= next_bank_row[12:0];
          open_bank <= next_bank_row[14:13];
          hold_cnt <= ROW_HOLD_RA;
          wait_cnt <= T_RCD - 4'd1;
          state <= S_RCD_NEXT;
        end
      end

      // tRCD after the row after's ACTIVE, before S_IDLE may read or write
      // it. A request taken here is pending, and S_IDLE serves it, as from
      // S_RP; ready stays up, for no request is being served.
      S_RCD_NEXT: begin
        if (wait_cnt <= 1) state <= S_IDLE;
        else wait_cnt <= wait_cnt - 1'b1;
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
        cmd_d <= CMD_READ;
        a_d <= {2'b00, 2'b00, col};   // A[10]=0: no auto-precharge
        dqmh_d <= 1'b0;
        dqml_d <= 1'b0;
        cas_pipe[CAS_LATENCY] <= 1'b1;
        col <= col + 1'b1;
        if (beats_left <= 1) state <= S_READ_DRAIN;
        else beats_left <= beats_left - 1'b1;
      end

      S_READ_DRAIN: begin
        // Wait for every issued read to return before closing the row.
        // STRICTLY zero outstanding. Releasing while the final beat is still in
        // the CAS pipe would be wrong, because IDLE can start the next burst
        // immediately on a row hit: that last beat would land after beats_out
        // has been reloaded, and be counted into the following burst.
        //
        // Releasing on the edge that captures the LAST beat is not that: the
        // capture above takes beats_out to zero on this same edge, so nothing
        // is left in the pipe, and the next burst cannot load beats_out before
        // the next edge. It saves the clock spent seeing zero.
        //
        // A refresh due, or about to fall due behind a stream line, closes
        // the row and refreshes while the last words are on their way in; a
        // stream line ending its row closes it for the row after (design
        // choices 4 and 6).
        if (rf_ref) begin
          if (refresh_wait > 1) refresh_wait <= refresh_wait - 1'b1;
        end else if (rf_pre) begin
          if (wait_cnt > 1) wait_cnt <= wait_cnt - 1'b1;
          else if (dr_ref_now) begin
            cmd_d <= CMD_AUTO_REFRESH;
            refresh_due <= 1'b0;
            refresh_wait <= T_RFC - 4'd1;
            rf_ref <= 1'b1;
          end
        end else if ((refresh_due || rf_early || end_pre) &&
                     open_valid && ras_ok && !rd_release) begin
          open_valid <= 1'b0;
          cmd_d <= CMD_PRECHARGE;
          a_d[10] <= 1'b1;             // all banks
          wait_cnt <= T_RP;
          rf_pre <= 1'b1;
          if (rf_early && !refresh_due) begin
            // The period ends here, as the counter ends it.
            refresh_cnt <= '0;
            refresh_due <= 1'b1;
          end
        end
        if (rd_release) begin
          ready <= 1'b1;
          // After the drain's AUTO_REFRESH, S_REFRESH waits out tRFC; after
          // its PRECHARGE alone, S_IDLE refreshes.
          state <= (rf_ref || dr_ref_now) ? S_REFRESH : S_IDLE;
          // A stream line read that ends its row holds nothing: the next
          // line is in another. Nor does a row the drain closed.
          hold_cnt <= (rf_pre || rf_ref) ? 6'd0 :
                      (req_fast && req_burst == 5'd4) ? ROW_HOLD :
                      (req_stream && (req_addr[9:5] != 5'h1F)) ? ROW_HOLD_RA : 6'd0;
          // One that does: the row after is opened once this one has
          // closed - not after a refresh, which drops it.
          next_due <= req_stream && (req_addr[9:5] == 5'h1F) &&
                      !(rf_ref || (rf_pre && refresh_due));
          next_bank_row <= req_addr[24:10] + 15'd1;
          rf_pre <= 1'b0;
          rf_ref <= 1'b0;
        end
      end

      // Back-to-back column writes inside the open row, mirroring S_READ.
      // Write data has no latency: it is sampled by the device on the same
      // edge as its WRITE command, so command, column, DQM and DQ all advance
      // together. A word whose enables are clear is still issued, with both
      // DQM bits high so the device writes none of it.
      S_WRITE: begin
        cmd_d <= CMD_WRITE;
        a_d <= {2'b00, 2'b00, col};   // A[10]=0: no auto-precharge
        dqmh_d <= ~wr_be[1];
        dqml_d <= ~wr_be[0];
        dqo_d <= wr_word;
        dqoe_d <= 1'b1;
        col <= col + 1'b1;
        wr_index <= wr_index + 1'b1;
        if (beats_left <= 1) begin
          wait_cnt <= T_WR;
          state <= S_TURNAROUND;         // row open until S_IDLE closes it
          ready <= 1'b1;
        end else beats_left <= beats_left - 1'b1;
      end

      // tWR before any PRECHARGE that follows, and tWTR before any READ. A
      // request may be taken here; it is pending, and ready stays low for it,
      // as in S_RP.
      S_TURNAROUND: begin
        if (wait_cnt <= 1) begin
          if (!pending) ready <= 1'b1;
          state <= S_IDLE;
        end else wait_cnt <= wait_cnt - 1'b1;
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
      cas_d <= 1'b0;
      cas_d2 <= 1'b0;
      cas_d3 <= 1'b0;
      refresh_due <= 1'b0;
      next_due <= 1'b0;
      rf_pre <= 1'b0;
      rf_ref <= 1'b0;
      // The startup sequence below PRECHARGES every bank, so whatever row this
      // thought was open is not. Leaving open_valid set would make the next
      // access take the row-hit path and issue a READ or WRITE with no ACTIVE
      // in front of it.
      //
      // That cannot happen in the core, where init only fires at power-up
      // before any traffic, so open_valid is already clear. It matters for
      // anything that re-initialises AFTER traffic.
      open_valid <= 1'b0;
      act_age <= 5'd31;
    end

    // Edge-detected request capture. Every request is held in req_* and left pending; S_IDLE acts on it from
    // there on a later clock - but for the direct port's read that S_IDLE
    // started on this edge, which is held but not pending.
    old_we <= we;
    if (new_we) begin
      req_addr <= addr;
      req_din <= din;
      req_wtbt <= wtbt;
      req_we <= 1'b1;
      req_burst <= (burst == 0) ? 5'd1 :
                   (burst > MAX_WRITE_BURST) ? MAX_WRITE_BURST : burst;
      pending <= 1'b1;
      ready <= 1'b0;
      req_fast <= 1'b0;
      req_stream <= 1'b0;
      next_due <= 1'b0;
    end

    old_rd <= rd;
    if (new_rd) begin
      req_addr <= addr;
      req_we <= 1'b0;
      req_burst <= (burst == 0) ? 5'd1 : burst;
      pending <= 1'b1;
      ready <= 1'b0;
      req_fast <= 1'b0;
      req_stream <= 1'b0;
      next_due <= 1'b0;
    end

    // The direct port. Taken only with nothing pending and no request on the
    // adapter's port this clock; otherwise it waits.
    if (fast_take) begin
      req_addr <= {fast_addr[24:1], 1'b0};
      req_we <= 1'b0;
      req_burst <= fast_addr[0] ? 5'd4 : 5'd16;
      pending <= !fast_issue;
      ready <= 1'b0;
      req_fast <= 1'b1;
      req_stream <= !fast_addr[0] && fast_stream;
      next_due <= 1'b0;
      fast_seen <= fast_tog;
    end

`ifndef SYNTHESIS
    // ready is never up over a pending request: whoever asked would take it
    // for that request's completion.
    if (!init && (state != S_STARTUP) && ready && pending) begin
      $error("ki_sdram_burst: ready while a request is pending, in %s", state.name());
      $fatal(1);
    end
    // One request at a time: the adapter launches only on `ready`, which the
    // capture above lowers. A second edge while one is pending would be lost.
    // A line read starts at a line, a qword read at a qword.
    if (!init && (fast_tog != fast_seen) && ready && !pending && !new_req &&
        (fast_addr[0] ? (fast_addr[2:1] != 2'd0) : (fast_addr[4:0] != 5'd0))) begin
      $error("ki_sdram_burst: a direct read of %07h, which is not a %s",
             fast_addr, fast_addr[0] ? "qword" : "line");
      $fatal(1);
    end
    if (!init && new_req && pending) begin
      $error("ki_sdram_burst: a request arrived while another was pending%s",
             req_fast ? " - the direct port's" : "");
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
