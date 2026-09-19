// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// Does the data cache write back a whole dirty line?
//
// The KI port changed the data cache line from the donor's 16 bytes to 32,
// which doubled the write-back from two beats to four. Reading the resulting
// state machine, WRITEBACK1WRITE and WRITEBACK3WRITE each advance
// tag_read_addr, but WRITEBACK2WRITE does not - so the address presented
// during WRITEBACK3WRITE is unchanged and the fourth beat re-reads the third
// word. The last 8 bytes of every dirty line would be a duplicate of the
// previous 8.
//
// That would corrupt a quarter of everything the CPU writes back to RAM, which
// is exactly the shape of the hardware symptom: the boot decompressor executes
// correctly, raises no CPU errors, reads a boot ROM proven byte-perfect
// through both paths (CS = CV = 47571D1B on hardware), and still loops
// forever because its own output is wrong.
//
// This drives the cache directly rather than through the CPU. Two cache
// commands make that cheap: 0x09 (index store tag) marks a line valid+dirty
// without needing a fill, and 0x01 (index write back invalidate) jumps
// straight to WRITEBACK1ADDR.
module tb_ki_datacache_writeback;
  localparam int LINE_INDEX = 9'h010;
  // Tag field is address[31:12]; the line's byte address is index<<5.
  localparam logic [19:0] LINE_TAG = 20'h00234;
  localparam logic [31:0] LINE_ADDR = {LINE_TAG, 12'h000} | (LINE_INDEX << 5);
  // Same index, different tag - forces a miss and therefore a fill.
  localparam logic [19:0] LINE_TAG2 = 20'h00567;
  localparam logic [31:0] LINE_ADDR2 = {LINE_TAG2, 12'h000} | (LINE_INDEX << 5);
  // Two ADJACENT lines, as the boot table initialiser uses.
  localparam logic [31:0] TBL_BASE = {LINE_TAG, 12'h400};
  // The bitstream reader's 16-byte context block, and the permutation table
  // 16 bytes above it - the real layout, a0 = 0x887FFF00 and t3 = a0 + 16.
  // 32-byte aligned, so the context and table A's first 16 bytes are ONE line.
  localparam logic [31:0] CTX_BASE = {LINE_TAG, 12'h800};
  localparam logic [31:0] RDR_TBL  = CTX_BASE + 32'd16;
  // Same index as CTX_BASE (0x800 >> 5 = 64), different tag: reading this
  // forces the reader's line out. LINE_ADDR2 is index 16 and evicts nothing
  // here, which is what made the first attempt at this test report
  // 'cache never requested a fill'.
  localparam logic [31:0] CTX_ALT  = {LINE_TAG2, 12'h800};
  // Lines that genuinely share a set, built from the slices the RTL actually
  // uses rather than from a tag/offset split that happens to look right. The
  // cache is 2-way: it indexes on addr[12:5] and compares addr[31:13], so two
  // addresses share a set if their low 13 bits match. LINE_ADDR and LINE_ADDR2
  // differ in addr[12] - they are 0x234 and 0x567 in the addr[31:12] field -
  // so they land in DIFFERENT sets, which is the trap already recorded for
  // CTX_ALT above and which these avoid by construction. All four have
  // addr[13] clear, which only matters to index ops: that bit names the way.
  //
  // Two ways means two lines in a set displace nothing, so displacement takes
  // a third, and the dirty-on-store test a fourth to start from a line it
  // brought in itself.
  localparam logic [8:0]  DISP_INDEX = 9'h0C0;
  localparam logic [31:0] DISP_A = {18'h00234, DISP_INDEX, 5'h00};
  localparam logic [31:0] DISP_B = {18'h00567, DISP_INDEX, 5'h00};
  localparam logic [31:0] DISP_C = {18'h0089A, DISP_INDEX, 5'h00};
  localparam logic [31:0] DISP_D = {18'h00ABC, DISP_INDEX, 5'h00};
  // One set, one line per way, placed by index store tag: addr[31:13] is odd
  // for IDX1 and even for IDX0, so addr[13] puts them in ways 1 and 0.
  localparam logic [31:0] IDX1_ADDR = {19'h00123, 8'h55, 5'h00};
  localparam logic [31:0] IDX0_ADDR = {19'h00124, 8'h55, 5'h00};

  logic clk1x = 1'b0;
  logic clk93 = 1'b0;
  logic clk2x = 1'b0;
  logic reset_93 = 1'b1;
  logic ss_reset = 1'b1;
  integer errors = 0;

  always #10 clk1x = ~clk1x;   // 50 MHz
  always #6.667 clk93 = ~clk93; // 75 MHz
  always #5 clk2x = ~clk2x;     // 100 MHz

  logic  [4:0] stall = 5'd0;
  logic        stall4 = 1'b0;
  logic        fifo_block = 1'b0;
  logic  [3:0] slow_in = 4'd0;
  logic        force_wb_in = 1'b0;

  wire         ram_request;
  wire [31:0]  ram_reqAddr;
  logic        ram_active = 1'b0;
  logic        ram_grant = 1'b0;
  logic        ram_done = 1'b0;
  logic [63:0] ddr3_DOUT = 64'd0;
  logic        ddr3_DOUT_READY = 1'b0;

  wire         writeback_ena;
  wire [31:0]  writeback_addr;
  wire [63:0]  writeback_data;

  logic [31:0] tag_addr = 32'd0;
  logic        read_ena = 1'b0;
  logic [31:0] rw_addr = 32'd0;
  logic        rw_64 = 1'b1;
  wire         read_busy;
  wire         read_done;
  wire [63:0]  read_data_w;
  // What the CPU would take: read_data_w in the cycle read_done is high. The
  // read tasks latch it there. Checking the live output after the task
  // returns is not the same thing - by then the way prediction has updated
  // and shows the right way, so a load that returned the WRONG way's data
  // passed that check.
  logic [63:0] read_data = 64'd0;

  logic        write_ena = 1'b0;
  logic  [7:0] write_be = 8'hff;
  logic [63:0] write_data = 64'd0;
  wire         write_done;

  logic        cache_command_ena = 1'b0;
  logic  [4:0] cache_command = 5'd0;
  wire         cache_command_stall;
  wire         cache_command_done;

  logic        taglo_valid = 1'b0;
  logic        taglo_dirty = 1'b0;
  logic [19:0] taglo_addr = 20'd0;

  wire         write_tag_ena;
  wire [21:0]  write_tag_value;
  wire  [3:0]  debug_state;

  // Skipped store-miss fills (SKIP_FILL): one set, four lines, so that
  // evictions can be steered. addr[13] is clear in all four.
  localparam logic [8:0]  SKIP_INDEX = 9'h0A0;
  localparam logic [31:0] SK_A = {18'h00234, SKIP_INDEX, 5'h00};
  localparam logic [31:0] SK_B = {18'h00567, SKIP_INDEX, 5'h00};
  localparam logic [31:0] SK_C = {18'h0089A, SKIP_INDEX, 5'h00};
  localparam logic [31:0] SK_D = {18'h00ABC, SKIP_INDEX, 5'h00};

  wire  [3:0]  writeback_mask;

  cpu_datacache #(.LITTLE_ENDIAN(1'b1), .SKIP_FILL(1'b1)) dut (
    .clk1x(clk1x), .clk93(clk93), .clk2x(clk2x),
    // One reset for both domains in the bench; see tb_ki_instrcache.sv.
    .reset_1x(reset_93), .reset_93(reset_93), .ce_93(1'b1),
    .stall(stall), .stall4(stall4), .fifo_block(fifo_block),
    .slow_in(slow_in), .force_wb_in(force_wb_in), .write_through_in(1'b0),
    .ram_request(ram_request), .ram_reqAddr(ram_reqAddr),
    .ram_active(ram_active), .ram_grant(ram_grant), .ram_done(ram_done),
    .ddr3_DOUT(ddr3_DOUT), .ddr3_DOUT_READY(ddr3_DOUT_READY),
    .writeback_ena(writeback_ena), .writeback_addr(writeback_addr),
    .writeback_data(writeback_data), .writeback_mask(writeback_mask),
    .tag_addr(tag_addr),
    .read_ena(read_ena), .RW_addr(rw_addr), .RW_64(rw_64),
    .read_busy(read_busy), .read_done(read_done), .read_data(read_data_w),
    .write_ena(write_ena), .write_be(write_be), .write_data(write_data),
    .write_done(write_done),
    .CacheCommandEna(cache_command_ena), .CacheCommand(cache_command),
    .CachecommandStall(cache_command_stall),
    .CachecommandDone(cache_command_done),
    .TagLo_Valid(taglo_valid), .TagLo_Dirty(taglo_dirty),
    .TagLo_Addr(taglo_addr),
    .writeTagEna(write_tag_ena), .writeTagValue(write_tag_value),
    .debug_state(debug_state), .SS_reset(ss_reset)
  );

  // Capture the write-back burst, and the qword mask the line goes out with.
  // The mask must hold still across the beats: the CPU takes it once, when
  // the line is issued after the fourth.
  logic [63:0] wb_data [0:7];
  logic [31:0] wb_addr [0:7];
  integer wb_n = 0;
  logic [3:0] wb_mask_cap = 4'h0;
  logic       wb_mask_moved = 1'b0;
  always @(posedge clk93) begin
    if (writeback_ena) begin
      if (wb_n < 8) begin
        wb_data[wb_n] <= writeback_data;
        wb_addr[wb_n] <= writeback_addr;
      end
      if (wb_n != 0 && writeback_mask !== wb_mask_cap) wb_mask_moved <= 1'b1;
      wb_mask_cap <= writeback_mask;
      wb_n <= wb_n + 1;
    end
    if (debug_state == 4'd11 && writeback_mask !== wb_mask_cap && wb_n != 0)   // WRITEBACKDONE
      wb_mask_moved <= 1'b1;
  end

  // serve_fill clears saw_ram_request once it has served, so a fork cannot
  // test it afterwards; count the requests instead.
  integer skip_n = 0, absent_n = 0, ram_req_n = 0;
  always @(posedge clk93) begin
    if (ram_request)          ram_req_n <= ram_req_n + 1;
    if (dut.perf_fill_skip)   skip_n   <= skip_n + 1;
    if (dut.perf_fill_absent) absent_n <= absent_n + 1;
  end

  // Cycles in WAYFIX (state 14): one per load that hit in the way the
  // prediction did not pick.
  integer wayfix_n = 0;
  always @(posedge clk93)
    if (debug_state == 4'd14) wayfix_n <= wayfix_n + 1;

  // Index load tag's answer.
  logic [21:0] tag_read_back = 22'd0;
  always @(posedge clk93)
    if (write_tag_ena) tag_read_back <= write_tag_value;

  task automatic step(input int n);
    repeat (n) @(posedge clk93);
  endtask

  // Visibility while bringing the stimulus up: the state machine and the tag
  // it is comparing against.
  logic trace_on = 1'b0;
  logic [3:0] prev_state = 4'hf;
  always @(posedge clk93) begin
    if (trace_on && (debug_state !== prev_state)) begin
      $display("    t=%0t state=%0d tag_compare=%h read_hit=%b",
               $time, debug_state, dut.tag_compare, dut.read_hit);
      prev_state <= debug_state;
    end
  end

  // Mark the line valid + dirty without needing a fill.
  task automatic mark_line_dirty;
    begin
      // tag_addr_cmd is taken from the REGISTERED tag_addr_1, so the address
      // has to be stable for a couple of cycles before the command or the tag
      // is written at the wrong index.
      tag_addr <= LINE_ADDR;
      rw_addr  <= LINE_ADDR;
      taglo_valid <= 1'b1;
      taglo_dirty <= 1'b1;
      taglo_addr  <= LINE_TAG;
      cache_command <= 5'h09;      // dcache index store tag
      step(3);
      cache_command_ena <= 1'b1;
      step(1);
      cache_command_ena <= 1'b0;
      step(6);
    end
  endtask

  // Write one 64-bit word of the line. The tag is already valid so this hits.
  task automatic write_word(input int word_index, input logic [63:0] value);
    begin
      tag_addr   <= LINE_ADDR + (word_index * 8);
      rw_addr    <= LINE_ADDR + (word_index * 8);
      write_data <= value;
      write_be   <= 8'hff;
      rw_64      <= 1'b1;
      step(2);
      write_ena  <= 1'b1;
      step(1);
      write_ena  <= 1'b0;
      step(4);
    end
  endtask

  // Store ONE byte, the way the boot decompressor's `sb` does. The CPU
  // presents byte enables in the low 32 bits; write_be_rot moves them to the
  // upper half when RW_addr(2) is set, so drive it the same way the CPU would.
  task automatic write_byte(input int byte_offset, input logic [7:0] value);
    logic [2:0] k;
    begin
      k = byte_offset[2:0];
      tag_addr   <= LINE_ADDR + byte_offset;
      rw_addr    <= LINE_ADDR + byte_offset;
      rw_64      <= 1'b0;
      write_be   <= 8'd0;
      write_data <= 64'd0;
      write_be[{1'b0, k[1:0]}]                <= 1'b1;
      write_data[{2'd0, k[1:0], 3'd0} +: 8]   <= value;
      step(2);
      write_ena  <= 1'b1;
      step(1);
      write_ena  <= 1'b0;
      step(4);
    end
  endtask

  // Start a read that is expected to MISS, so the fill can be served in
  // parallel. LINE_ADDR2 is a different tag at the same index.
  // Set while cache_read_miss runs, so the fill split can be observed without
  // disturbing the sequence it is measuring.
  integer f1_cycles = 0;
  integer f2_cycles = 0;
  integer f3_cycles = 0;
  integer fill_cycles = 0;
  integer f_both    = 0;

  task automatic cache_read_miss(input int byte_offset);
    integer guard;
    begin
      f1_cycles = 0;
      f2_cycles = 0;
      f3_cycles = 0;
      fill_cycles = 0;
      f_both    = 0;
      tag_addr <= LINE_ADDR2 + byte_offset;
      rw_addr  <= LINE_ADDR2 + byte_offset;
      rw_64    <= 1'b1;
      step(2);
      read_ena <= 1'b1;
      guard = 0;
      forever begin
        step(1);
        if (dut.perf_fill_wait) f1_cycles = f1_cycles + 1;
        if (dut.perf_fill_data) f2_cycles = f2_cycles + 1;
        if (dut.perf_fill_hold) f3_cycles = f3_cycles + 1;
        if (dut.state == 2) fill_cycles = fill_cycles + 1;
        // The three are a partition, so no two may ever be high together.
        if ((dut.perf_fill_wait && dut.perf_fill_data) ||
            (dut.perf_fill_wait && dut.perf_fill_hold) ||
            (dut.perf_fill_data && dut.perf_fill_hold)) f_both = f_both + 1;
        if (read_done) begin
          read_data = read_data_w;
          break;
        end
        guard = guard + 1;
        if (guard > 400) begin
          $error("fill read never completed");
          errors = errors + 1;
          break;
        end
      end
      read_ena <= 1'b0;
      step(2);
    end
  endtask

  // Read back through the cache and wait for the hit to complete.
  logic [31:0] read_base = LINE_ADDR;
  task automatic cache_read(input int byte_offset, input logic wide);
    integer guard;
    begin
      tag_addr <= read_base + byte_offset;
      rw_addr  <= read_base + byte_offset;
      rw_64    <= wide;
      step(2);
      read_ena <= 1'b1;
      guard = 0;
      forever begin
        step(1);
        if (read_done) begin
          read_data = read_data_w;
          break;
        end
        guard = guard + 1;
        if (guard > 40) begin
          $error("cached read at +%0d never completed", byte_offset);
          errors = errors + 1;
          break;
        end
      end
      read_ena <= 1'b0;
      step(2);
    end
  endtask

  // Serve one 32-byte line fill. ddr3_DOUT_READY is driven on clk1x because
  // that is the domain the KI bridge returns beats in, and the fill machine
  // was rewritten to consume them there.
  logic saw_ram_request = 1'b0;
  always @(posedge clk93) if (ram_request) saw_ram_request <= 1'b1;

  logic [63:0] fill_words [0:3];
  task automatic serve_fill;
    integer guard;
    begin
      guard = 0;
      while (!saw_ram_request && guard < 400) begin
        @(posedge clk1x);
        guard = guard + 1;
      end
      if (!saw_ram_request) begin
        $error("cache never requested a fill");
        errors = errors + 1;
      end else begin
        @(posedge clk1x);
        ram_active <= 1'b1;
        ram_grant  <= 1'b1;
        ddr3_DOUT  <= fill_words[0];
        ddr3_DOUT_READY <= 1'b1;
        @(posedge clk1x);
        ram_grant  <= 1'b0;
        for (int b = 1; b < 4; b = b + 1) begin
          ddr3_DOUT <= fill_words[b];
          @(posedge clk1x);
        end
        ddr3_DOUT_READY <= 1'b0;
        ram_done   <= 1'b1;
        @(posedge clk1x);
        ram_done   <= 1'b0;
        ram_active <= 1'b0;
        saw_ram_request <= 1'b0;
      end
    end
  endtask

  // Mark an arbitrary line valid + dirty (the existing helper is fixed to
  // LINE_ADDR). Tag field is address[31:12].
  task automatic mark_dirty_at(input logic [31:0] addr);
    begin
      tag_addr <= addr;
      rw_addr  <= addr;
      taglo_valid <= 1'b1;
      taglo_dirty <= 1'b1;
      taglo_addr  <= addr[31:12];
      cache_command <= 5'h09;
      step(3);
      cache_command_ena <= 1'b1;
      step(1);
      cache_command_ena <= 1'b0;
      step(6);
    end
  endtask

  // One byte store at an absolute address, driven the way the CPU drives it.
  task automatic write_byte_at(input logic [31:0] addr, input logic [7:0] value);
    logic [2:0] k;
    begin
      k = addr[2:0];
      tag_addr   <= addr;
      rw_addr    <= addr;
      rw_64      <= 1'b0;
      write_be   <= 8'd0;
      write_data <= 64'd0;
      write_be[{1'b0, k[1:0]}]              <= 1'b1;
      write_data[{2'd0, k[1:0], 3'd0} +: 8] <= value;
      step(2);
      write_ena  <= 1'b1;
      step(1);
      write_ena  <= 1'b0;
      step(3);
    end
  endtask

  // 64-bit store at an absolute address - the reader's `sd at,0(a0)`.
  task automatic write_dword_at(input logic [31:0] addr,
                                input logic [63:0] value);
    begin
      tag_addr   <= addr;
      rw_addr    <= addr;
      write_data <= value;
      write_be   <= 8'hff;
      rw_64      <= 1'b1;
      step(2);
      write_ena  <= 1'b1;
      step(1);
      write_ena  <= 1'b0;
      step(4);
    end
  endtask

  // 32-bit store at an absolute address - the reader's `sw a1,8(a0)`. The CPU
  // presents enables in the low half and write_be_rot moves them up when
  // RW_addr(2) is set, so drive them low exactly as the CPU does.
  task automatic write_word_at(input logic [31:0] addr,
                               input logic [31:0] value);
    begin
      tag_addr   <= addr;
      rw_addr    <= addr;
      rw_64      <= 1'b0;
      write_be   <= 8'h0f;
      write_data <= {32'd0, value};
      step(2);
      write_ena  <= 1'b1;
      step(1);
      write_ena  <= 1'b0;
      step(4);
    end
  endtask

  task automatic read_at(input logic [31:0] addr, input logic wide);
    integer guard;
    begin
      tag_addr <= addr;
      rw_addr  <= addr;
      rw_64    <= wide;
      step(2);
      read_ena <= 1'b1;
      guard = 0;
      forever begin
        step(1);
        if (read_done) begin
          read_data = read_data_w;
          break;
        end
        guard = guard + 1;
        if (guard > 40) begin
          $error("read at %08h never completed", addr);
          errors = errors + 1;
          break;
        end
      end
      read_ena <= 1'b0;
      step(2);
    end
  endtask

  // A read that is expected to MISS at an absolute address, so a fill can be
  // served in parallel. Longer guard than read_at, which only covers hits.
  task automatic read_miss_at(input logic [31:0] addr);
    integer guard;
    begin
      tag_addr <= addr;
      rw_addr  <= addr;
      rw_64    <= 1'b1;
      step(2);
      read_ena <= 1'b1;
      guard = 0;
      forever begin
        step(1);
        if (read_done) begin
          read_data = read_data_w;
          break;
        end
        guard = guard + 1;
        if (guard > 400) begin
          $error("miss read at %08h never completed", addr);
          errors = errors + 1;
          break;
        end
      end
      read_ena <= 1'b0;
      step(2);
    end
  endtask

  task automatic read_byte_at(input logic [31:0] addr);
    integer guard;
    begin
      tag_addr <= addr;
      rw_addr  <= addr;
      rw_64    <= 1'b0;
      step(2);
      read_ena <= 1'b1;
      guard = 0;
      forever begin
        step(1);
        if (read_done) begin
          read_data = read_data_w;
          break;
        end
        guard = guard + 1;
        if (guard > 40) begin
          $error("read at %08h never completed", addr);
          errors = errors + 1;
          break;
        end
      end
      read_ena <= 1'b0;
      step(2);
    end
  endtask

  // A store the way the CPU makes one that may MISS: write_ena for the
  // cache's IDLE cycle only, then stall4 held - so the cache takes the store
  // from write_data_1 - until write_done. The other store tasks never wait,
  // which is fine for hits and nothing else.
  // write_done is combinational and can last less than a clk93 cycle's second
  // half when ram_done arrives late in it, so count it where the CPU samples
  // it: at the edge.
  integer write_done_n = 0;
  always @(posedge clk93) if (write_done) write_done_n <= write_done_n + 1;

  task automatic store_wait(input logic [31:0] addr, input logic [63:0] value,
                            input logic [7:0] be, input logic wide);
    integer guard;
    integer done_before;
    begin
      tag_addr   <= addr;
      rw_addr    <= addr;
      write_data <= value;
      write_be   <= be;
      rw_64      <= wide;
      step(2);
      done_before = write_done_n;
      write_ena  <= 1'b1;
      @(posedge clk93);          // the cache's IDLE cycle with the store
      write_ena  <= 1'b0;
      #1;
      if (write_done_n == done_before) begin
        stall4 <= 1'b1;
        guard = 0;
        while (write_done_n == done_before && guard <= 400) begin
          @(posedge clk93);
          #1;
          guard = guard + 1;
        end
        if (write_done_n == done_before) begin
          $error("store at %08h never completed", addr);
          errors = errors + 1;
        end
        stall4 <= 1'b0;
      end
      step(3);
    end
  endtask

  // Replace one byte of a qword, little-endian.
  function automatic logic [63:0] with_byte(input logic [63:0] q, input int k,
                                            input logic [7:0] b);
    logic [63:0] r;
    begin
      r = q;
      r[k * 8 +: 8] = b;
      return r;
    end
  endfunction

  integer i;
  integer k;
  integer bad;
  logic [63:0] expect_word;
  logic [63:0] byte_word;

  initial begin
    step(4);
    ss_reset = 1'b0;
    reset_93 = 1'b0;
    step(700);          // CLEARCACHE walks all 256 sets

    $display("");
    $display("cpu_datacache: 32-byte dirty line write-back");
    $display("");

    trace_on = 1'b1;
    mark_line_dirty();
    $display("    after tag store: tag_compare=%h", dut.tag_compare);
    for (i = 0; i < 4; i = i + 1)
      write_word(i, {32'hD0D0_0000 + i, 32'hA5A5_0000 + i});

    // Force the whole line out.
    wb_n = 0;
    tag_addr <= LINE_ADDR;
    rw_addr  <= LINE_ADDR;
    cache_command <= 5'h01;        // dcache index write back invalidate
    step(3);
    cache_command_ena <= 1'b1;
    step(1);
    cache_command_ena <= 1'b0;
    step(40);

    $display("  write-back produced %0d beats", wb_n);
    for (i = 0; i < ((wb_n > 8) ? 8 : wb_n); i = i + 1)
      $display("    beat %0d  addr=%08h  data=%016h", i, wb_addr[i], wb_data[i]);
    $display("");

    if (wb_n != 4) begin
      $error("a 32-byte line must write back in exactly 4 beats, got %0d", wb_n);
      errors = errors + 1;
    end else begin
      for (i = 0; i < 4; i = i + 1) begin
        expect_word = {32'hD0D0_0000 + i, 32'hA5A5_0000 + i};
        if (wb_data[i] !== expect_word) begin
          $error("beat %0d carried %016h, expected word %0d = %016h",
                 i, wb_data[i], i, expect_word);
          errors = errors + 1;
        end
        if (wb_addr[i][4:0] !== (i * 8)) begin
          $error("beat %0d went to offset %0d, expected %0d",
                 i, wb_addr[i][4:0], i * 8);
          errors = errors + 1;
        end
      end
    end

    // The specific defect: the last beat repeating the previous word. Call it
    // out by name so a regression is unmistakable rather than just "wrong".
    if (wb_n >= 4 && wb_data[3] === wb_data[2]) begin
      $error("beat 3 duplicates beat 2 - WRITEBACK2WRITE is not advancing tag_read_addr, so the last 8 bytes of every dirty line are lost");
      errors = errors + 1;
    end

    // ---- cached read-after-write ----
    // The boot decompressor fills a ~32-byte KSEG0 buffer with `sb` byte
    // stores and then scans it with `lb`, looking for a terminator. The scan
    // at 9FC00CD8 has NO iteration bound - it exits only when a byte matches -
    // so if a byte written into a cached line does not read back correctly,
    // the terminator is never found and boot loops forever. Which is exactly
    // what hardware does.
    $display("");
    $display("  cached read-after-write (byte stores, the `sb`/`lb` pattern)");

    mark_line_dirty();
    byte_word = 64'd0;
    for (i = 0; i < 8; i = i + 1) begin
      write_byte(i, 8'h40 + i[7:0]);
      byte_word[(i * 8) +: 8] = 8'h40 + i[7:0];
    end

    cache_read(0, 1'b1);
    if (read_data !== byte_word) begin
      $error("byte stores read back as %016h, expected %016h",
             read_data, byte_word);
      errors = errors + 1;
    end else begin
      $display("    eight byte stores read back correctly: %016h", read_data);
    end

    // ...and each byte individually, which also exercises the read_data shift
    // mux that a byte load depends on.
    for (i = 0; i < 8; i = i + 1) begin
      cache_read(i, 1'b0);
      if (read_data[7:0] !== (8'h40 + i[7:0])) begin
        $error("byte read at +%0d returned %02h, expected %02h",
               i, read_data[7:0], 8'h40 + i[7:0]);
        errors = errors + 1;
      end
    end
    if (errors == 0)
      $display("    each byte reads back at its own offset");

    // ---- line fill ----
    // The mirror of the write-back defect: the same 16 -> 32 byte change means
    // a fill must place FOUR beats, and its machine was rewritten from clk2x
    // to clk1x for the KI bridge. If a fill misplaces or drops a beat, the
    // bytes the CPU did not write itself are garbage - and the decompressor's
    // scan reads exactly those.
    $display("");
    $display("  32-byte line fill");

    for (i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hF111_0000 + i, 32'hE222_0000 + i};

    fork
      serve_fill();
      cache_read_miss(0);
    join

    // -----------------------------------------------------------------
    // The fill split actually splits.
    //
    // perf_fill_wait / perf_fill_data partition the FILL state either side of
    // the first data beat. The point of a partition over a proxy is that
    // neither half can quietly read zero while the time goes elsewhere, so
    // check exactly that against the real fill just performed. Four earlier
    // taps on this path measured ~nothing on hardware and no bench caught any
    // of them; this one is checkable here.
    // -----------------------------------------------------------------
    if (f1_cycles == 0) begin
      $error("perf_fill_wait counted nothing across a whole line fill");
      errors = errors + 1;
    end
    if (f2_cycles == 0) begin
      $error("perf_fill_data counted nothing across a whole line fill");
      errors = errors + 1;
    end
    if (f_both != 0) begin
      $error("fill phases overlapped %0d cycles; they partition FILL", f_both);
      errors = errors + 1;
    end
    // The real property: the three phases account for EVERY cycle of FILL.
    // A tap that stopped counting would break this even if each phase looked
    // individually plausible. f3 may legitimately be 0 here - this bench's
    // memory model returns ram_done with the last beat, where hardware waits
    // for a clk1x-to-clk93 mailbox round trip.
    if (f1_cycles + f2_cycles + f3_cycles != fill_cycles) begin
      $error("fill phases summed to %0d but FILL lasted %0d cycles",
             f1_cycles + f2_cycles + f3_cycles, fill_cycles);
      errors = errors + 1;
    end
    $display("tb_ki_datacache_writeback: fill split %0d wait + %0d data + %0d hold",
             f1_cycles, f2_cycles, f3_cycles);

    read_base = LINE_ADDR2;
    for (i = 0; i < 4; i = i + 1) begin
      cache_read(i * 8, 1'b1);
      if (read_data !== fill_words[i]) begin
        $error("filled word %0d read back as %016h, expected %016h",
               i, read_data, fill_words[i]);
        errors = errors + 1;
      end
    end
    $display("    four filled words read back");

    // ---- the boot ROM's table initialiser, exactly ----
    //
    //   9FC00CB8: sb v1, 0(a1)     table A
    //   9FC00CBC: sb v1, 32(a1)    table B
    //   9FC00CC0: v1 = v1 - 1
    //   9FC00CC4: bgez v1, -0x10
    //   9FC00CC8: a1 = a1 + 1
    //
    // 32 iterations writing 31 down to 0 into two tables 32 bytes apart -
    // which means every iteration stores a byte into ONE cache line and then
    // another into the NEXT one, alternating 32 times. The earlier byte-store
    // test only ever wrote within a single line, so this pattern is untested,
    // and it is exactly what produces the permutation table whose corruption
    // hangs boot.
    $display("");
    $display("  boot table initialiser (alternating byte stores, two lines)");

    mark_dirty_at(TBL_BASE);
    mark_dirty_at(TBL_BASE + 32);

    for (k = 0; k < 32; k = k + 1) begin
      write_byte_at(TBL_BASE + k,      8'd31 - k[7:0]);
      write_byte_at(TBL_BASE + 32 + k, 8'd31 - k[7:0]);
    end

    bad = 0;
    for (k = 0; k < 32; k = k + 1) begin
      read_byte_at(TBL_BASE + k);
      if (read_data[7:0] !== (8'd31 - k[7:0])) begin
        if (bad < 6)
          $error("table A[%0d] = %02h, expected %02h",
                 k, read_data[7:0], 8'd31 - k[7:0]);
        bad = bad + 1;
      end
      read_byte_at(TBL_BASE + 32 + k);
      if (read_data[7:0] !== (8'd31 - k[7:0])) begin
        if (bad < 6)
          $error("table B[%0d] = %02h, expected %02h",
                 k, read_data[7:0], 8'd31 - k[7:0]);
        bad = bad + 1;
      end
    end
    if (bad != 0) begin
      $error("%0d of 64 table bytes are wrong - the initialiser's alternating byte stores do not land", bad);
      errors = errors + 1;
    end else begin
      $display("    both 32-entry tables initialised correctly (31 down to 0)");
    end

    $display("");
    $display("  bitstream reader context round-trip, sharing a line with the table");

    mark_dirty_at(CTX_BASE);

    // Reader init, in the ROM's order: sw, then sd, then sb.
    write_word_at (CTX_BASE + 8,  32'hBFC0_0FD7);
    write_dword_at(CTX_BASE + 0,  64'h4A00_A788_0000_0000);
    write_byte_at (CTX_BASE + 12, 8'hC8);

    // The deal routine writing table A, in the SAME line.
    for (k = 0; k < 16; k = k + 1)
      write_byte_at(RDR_TBL + k, 8'd31 - k[7:0]);

    // Reader restore.
    read_at(CTX_BASE + 0, 1'b1);
    if (read_data !== 64'h4A00_A788_0000_0000) begin
      $error("reader accumulator read back as %016h, expected 4A00A78800000000",
             read_data);
      errors = errors + 1;
    end
    read_at(CTX_BASE + 8, 1'b0);
    if (read_data[31:0] !== 32'hBFC0_0FD7) begin
      $error("reader source pointer read back as %08h, expected BFC00FD7",
             read_data[31:0]);
      errors = errors + 1;
    end
    read_byte_at(CTX_BASE + 12);
    if (read_data[7:0] !== 8'hC8) begin
      $error("reader bit count read back as %02h, expected C8", read_data[7:0]);
      errors = errors + 1;
    end

    // And the table half of the same line must be intact - a 64-bit store
    // that spilled past its eight bytes would land here.
    bad = 0;
    for (k = 0; k < 16; k = k + 1) begin
      read_byte_at(RDR_TBL + k);
      if (read_data[7:0] !== (8'd31 - k[7:0])) begin
        if (bad < 6)
          $error("table byte %0d in the reader's line = %02h, expected %02h",
                 k, read_data[7:0], 8'd31 - k[7:0]);
        bad = bad + 1;
      end
    end
    if (bad != 0) begin
      $error("%0d of 16 table bytes sharing the reader's line are wrong", bad);
      errors = errors + 1;
    end else begin
      $display("    context and table survive sharing one line");
    end

    $display("");
    $display("  ...and the same line through a write-back");

    wb_n = 0;
    tag_addr <= CTX_BASE;
    rw_addr  <= CTX_BASE;
    cache_command <= 5'h01;        // dcache index write back invalidate
    step(3);
    cache_command_ena <= 1'b1;
    step(1);
    cache_command_ena <= 1'b0;
    step(40);

    if (wb_n != 4) begin
      $error("eviction produced %0d write-back beats, expected 4", wb_n);
      errors = errors + 1;
    end else begin
      $display("    evicted: %016h %016h %016h %016h",
               wb_data[0], wb_data[1], wb_data[2], wb_data[3]);
      if (wb_data[0] !== 64'h4A00_A788_0000_0000) begin
        $error("written-back accumulator = %016h, expected 4A00A78800000000",
               wb_data[0]);
        errors = errors + 1;
      end
      if (wb_data[1][31:0] !== 32'hBFC0_0FD7) begin
        $error("written-back source pointer = %08h, expected BFC00FD7",
               wb_data[1][31:0]);
        errors = errors + 1;
      end
      if (wb_data[1][39:32] !== 8'hC8) begin
        $error("written-back bit count = %02h, expected C8",
               wb_data[1][39:32]);
        errors = errors + 1;
      end
      // Beats 2 and 3 are the table half of the line: bytes 31 down to 16.
      for (k = 0; k < 16; k = k + 1) begin
        byte_word = (k < 8) ? wb_data[2] : wb_data[3];
        if (byte_word[{1'b0, k[2:0], 3'd0} +: 8] !== (8'd31 - k[7:0])) begin
          $error("written-back table byte %0d = %02h, expected %02h", k,
                 byte_word[{1'b0, k[2:0], 3'd0} +: 8], 8'd31 - k[7:0]);
          errors = errors + 1;
        end
      end
    end

    $display("");
    $display("  two ways: a miss takes the empty way and keeps the dirty line");

    mark_dirty_at(DISP_A);          // addr[13] clear: way 0, valid + dirty
    for (i = 0; i < 4; i = i + 1)
      write_dword_at(DISP_A + i * 8, {32'hDEAD_0000 + i, 32'hBEEF_0000 + i});

    wb_n = 0;
    saw_ram_request = 1'b0;
    for (i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hFACE_0000 + i * 2 + 1, 32'hFACE_0000 + i * 2};

    fork
      serve_fill();
      read_miss_at(DISP_B);
    join
    step(40);

    if (wb_n != 0) begin
      $error("filling DISP_B wrote back %0d beats although the set's other way was empty",
             wb_n);
      errors = errors + 1;
    end

    // Both lines are resident. Each of the next two reads hits in the way the
    // prediction did NOT pick - the other line was used last - so each takes
    // one WAYFIX cycle, and must still return its own line's data. A third,
    // to the line used last, is predicted right and takes none.
    wayfix_n = 0;
    saw_ram_request = 1'b0;
    read_at(DISP_A + 8, 1'b1);
    if (read_data !== {32'hDEAD_0001, 32'hBEEF_0001}) begin
      $error("DISP_A read back %016h beside DISP_B, expected DEAD0001BEEF0001",
             read_data);
      errors = errors + 1;
    end
    read_at(DISP_B + 16, 1'b1);
    if (read_data !== {32'hFACE_0005, 32'hFACE_0004}) begin
      $error("DISP_B read back %016h beside DISP_A, expected FACE0005FACE0004",
             read_data);
      errors = errors + 1;
    end
    if (wayfix_n != 2) begin
      $error("two reads alternating between the ways took %0d WAYFIX cycles, expected 2",
             wayfix_n);
      errors = errors + 1;
    end
    wayfix_n = 0;
    read_at(DISP_B + 24, 1'b1);
    if (read_data !== {32'hFACE_0007, 32'hFACE_0006}) begin
      $error("DISP_B read back %016h, expected FACE0007FACE0006", read_data);
      errors = errors + 1;
    end
    if (wayfix_n != 0) begin
      $error("a hit in the most recently used way took %0d WAYFIX cycles", wayfix_n);
      errors = errors + 1;
    end
    if (saw_ram_request) begin
      $error("two lines in one set did not both stay resident - a read missed");
      errors = errors + 1;
    end
    if (errors == 0)
      $display("    both lines resident; mispredicted hits return the right way's data");

    $display("");
    $display("  displacement write-back (a third line evicts the LRU dirty line)");

    // DISP_B was used last, so DISP_A is least recently used and must go.
    wb_n = 0;
    saw_ram_request = 1'b0;
    for (i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hC1C1_0000 + i * 2 + 1, 32'hC1C1_0000 + i * 2};

    fork
      serve_fill();
      read_miss_at(DISP_C);
    join

    step(40);

    if (wb_n != 4) begin
      $error("a displaced dirty line must write back in 4 beats, got %0d",
             wb_n);
      errors = errors + 1;
      if (wb_n == 0)
        $display("    NOTHING was written back - the dirty line was dropped");
    end else begin
      for (i = 0; i < 4; i = i + 1) begin
        expect_word = {32'hDEAD_0000 + i, 32'hBEEF_0000 + i};
        if (wb_data[i] !== expect_word) begin
          $error("displaced beat %0d carried %016h, expected %016h",
                 i, wb_data[i], expect_word);
          errors = errors + 1;
        end
        // The eviction must go to the OLD line's address. Writing it to the
        // address being filled would corrupt the line just fetched and leave
        // the original stale - silently, and only for code that writes a
        // line and then reads a different one at the same index.
        if (wb_addr[i][31:5] !== DISP_A[31:5]) begin
          $error("displaced beat %0d went to %08h, expected the line at %08h",
                 i, wb_addr[i], DISP_A);
          errors = errors + 1;
        end
      end
      if (errors == 0)
        $display("    the dirty line wrote back, 4 beats, at its own address");
    end

    // ...and the line that was used last is the one still resident.
    saw_ram_request = 1'b0;
    read_at(DISP_B, 1'b1);
    if (saw_ram_request) begin
      $error("DISP_B, the most recently used line, was evicted instead of DISP_A");
      errors = errors + 1;
    end else if (read_data !== {32'hFACE_0001, 32'hFACE_0000}) begin
      $error("DISP_B read back %016h after the eviction, expected FACE0001FACE0000",
             read_data);
      errors = errors + 1;
    end else begin
      $display("    the most recently used line survived");
    end

    $display("");
    $display("  a store to a clean resident line must mark it dirty");

    // The set holds DISP_C (clean, least recently used) and DISP_B. Bring in
    // a fourth tag so this starts from a line it filled itself; it replaces
    // DISP_C, which is clean, so nothing may be written back.
    wb_n = 0;
    saw_ram_request = 1'b0;
    for (i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hC0DE_0000 + i * 2 + 1, 32'hC0DE_0000 + i * 2};

    // 1. Bring the line in by MISSING on it. It is now valid and clean.
    fork
      serve_fill();
      read_miss_at(DISP_D);
    join
    step(20);

    if (wb_n != 0) begin
      $error("filling over a clean line wrote back %0d beats, expected none", wb_n);
      errors = errors + 1;
    end

    // 2. Store into it. This hits, and must set the dirty bit.
    write_dword_at(DISP_D, 64'hFEED_FACE_1234_5678);
    step(10);

    // 3. Make it the least recently used line, then displace it. The store
    //    must come back out.
    read_at(DISP_B, 1'b1);
    wb_n = 0;
    saw_ram_request = 1'b0;
    for (i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'h5A5A_0000 + i * 2 + 1, 32'h5A5A_0000 + i * 2};
    fork
      serve_fill();
      read_miss_at(DISP_A);
    join
    step(40);

    if (wb_n == 0) begin
      $error("a stored-into line was displaced WITHOUT a write-back - the store did not mark it dirty");
      errors = errors + 1;
    end else if (wb_n != 4) begin
      $error("displaced stored-into line produced %0d beats, expected 4", wb_n);
      errors = errors + 1;
    end else begin
      if (wb_data[0] !== 64'hFEED_FACE_1234_5678) begin
        $error("write-back beat 0 carried %016h, expected the stored FEEDFACE12345678",
               wb_data[0]);
        errors = errors + 1;
      end
      for (i = 1; i < 4; i = i + 1) begin
        expect_word = {32'hC0DE_0000 + i * 2 + 1, 32'hC0DE_0000 + i * 2};
        if (wb_data[i] !== expect_word) begin
          $error("write-back beat %0d carried %016h, expected the filled %016h",
                 i, wb_data[i], expect_word);
          errors = errors + 1;
        end
      end
      if (wb_addr[0][31:5] !== DISP_D[31:5]) begin
        $error("write-back went to %08h, expected the line at %08h",
               wb_addr[0], DISP_D);
        errors = errors + 1;
      end
    end

    $display("");
    $display("  index ops select their way with address bit 13");

    // Index store tag at an address with bit 13 set writes WAY 1 of the set,
    // with bit 13 clear way 0 - so two lines placed that way are both
    // resident, and index ops at each address act on that line alone.
    mark_dirty_at(IDX1_ADDR);
    mark_dirty_at(IDX0_ADDR);
    saw_ram_request = 1'b0;
    for (i = 0; i < 4; i = i + 1)
      write_dword_at(IDX1_ADDR + i * 8, {32'h1111_0000 + i, 32'h1111_1000 + i});
    for (i = 0; i < 4; i = i + 1)
      write_dword_at(IDX0_ADDR + i * 8, {32'h0000_A000 + i, 32'h0000_B000 + i});
    if (saw_ram_request) begin
      $error("a store to a line placed by index store tag missed");
      errors = errors + 1;
    end

    // Index load tag: valid & dirty & addr[31:12] of whichever line is there.
    for (k = 0; k < 2; k = k + 1) begin
      tag_read_back = 22'd0;
      tag_addr <= (k == 0) ? IDX0_ADDR : IDX1_ADDR;
      rw_addr  <= (k == 0) ? IDX0_ADDR : IDX1_ADDR;
      cache_command <= 5'h05;        // dcache index load tag
      step(3);
      cache_command_ena <= 1'b1;
      step(1);
      cache_command_ena <= 1'b0;
      step(6);
      if (tag_read_back !== {2'b11, ((k == 0) ? IDX0_ADDR[31:12] : IDX1_ADDR[31:12])}) begin
        $error("index load tag for way %0d returned %06h, expected %06h", k,
               tag_read_back, {2'b11, ((k == 0) ? IDX0_ADDR[31:12] : IDX1_ADDR[31:12])});
        errors = errors + 1;
      end
    end

    // Index write back invalidate at IDX1_ADDR writes back way 1's line.
    wb_n = 0;
    tag_addr <= IDX1_ADDR;
    rw_addr  <= IDX1_ADDR;
    cache_command <= 5'h01;
    step(3);
    cache_command_ena <= 1'b1;
    step(1);
    cache_command_ena <= 1'b0;
    step(40);
    if (wb_n != 4) begin
      $error("index write back invalidate on way 1 produced %0d beats, expected 4", wb_n);
      errors = errors + 1;
    end else begin
      for (i = 0; i < 4; i = i + 1) begin
        expect_word = {32'h1111_0000 + i, 32'h1111_1000 + i};
        if (wb_data[i] !== expect_word || wb_addr[i][31:5] !== IDX1_ADDR[31:5]) begin
          $error("way 1 write-back beat %0d = %016h at %08h, expected %016h at %08h",
                 i, wb_data[i], wb_addr[i], expect_word, IDX1_ADDR);
          errors = errors + 1;
        end
      end
    end

    // Way 0 is untouched and still hits.
    saw_ram_request = 1'b0;
    read_at(IDX0_ADDR + 8, 1'b1);
    if (saw_ram_request || read_data !== {32'h0000_A001, 32'h0000_B001}) begin
      $error("way 0's line after invalidating way 1: %s, read %016h, expected 0000A0010000B001",
             saw_ram_request ? "MISSED" : "hit", read_data);
      errors = errors + 1;
    end
    if (errors == 0)
      $display("    index ops act on the way addr[13] names, and only on it");

    // -----------------------------------------------------------------
    // SKIP_FILL: a 64-bit store that misses takes its line without a fill.
    //
    // Everything a skipped fill leaves behind has to hold: the store's own
    // qword reads back; a load of an absent qword fills ONLY the absent
    // qwords, around the stored one; a 64-bit store into an absent qword needs
    // no fill; a narrower one does, and lands on top of it; a write-back
    // names only the qwords the line really holds, and holds that mask still
    // until the line is taken; an index op writes back with the same mask.
    // -----------------------------------------------------------------
    $display("");
    $display("  skipped store-miss fills");
    begin
      logic [63:0] fa [0:3], fb [0:3], fc [0:3], fd [0:3];
      int errors_before, skips_before, absents_before, way_c, req_before;
      errors_before  = errors;
      for (i = 0; i < 4; i = i + 1) begin
        fa[i] = {32'hA0A0_0000 + i, 32'h0000_0A00 + i};
        fb[i] = {32'hB0B0_0000 + i, 32'h0000_0B00 + i};
        fc[i] = {32'hC0C0_0000 + i, 32'h0000_0C00 + i};
        fd[i] = {32'hD0D0_0000 + i, 32'h0000_0D00 + i};
      end

      // A and B in by load misses; A dirtied and left least recently used.
      for (i = 0; i < 4; i = i + 1) fill_words[i] = fa[i];
      fork serve_fill(); read_miss_at(SK_A); join
      for (i = 0; i < 4; i = i + 1) fill_words[i] = fb[i];
      fork serve_fill(); read_miss_at(SK_B); join
      store_wait(SK_A + 8, 64'h1111_2222_3333_4444, 8'hff, 1'b1);
      read_at(SK_B, 1'b1);
      step(4);
      skips_before   = skip_n;
      absents_before = absent_n;

      // 1. C's qword 2 by a 64-bit store miss: A goes back whole, C is not read.
      wb_n = 0;
      wb_mask_moved = 1'b0;
      saw_ram_request = 1'b0;
      store_wait(SK_C + 16, 64'hC2C2_C2C2_0000_0002, 8'hff, 1'b1);
      step(10);
      if (saw_ram_request) begin
        $error("a 64-bit store miss requested a fill");
        errors = errors + 1;
      end
      if (wb_n != 4 || wb_mask_cap !== 4'b1111 || wb_addr[0][31:5] !== SK_A[31:5]) begin
        $error("evicting A for C wrote %0d beats, mask %b, at %08h - expected 4, 1111, A",
               wb_n, wb_mask_cap, wb_addr[0]);
        errors = errors + 1;
      end
      read_at(SK_C + 16, 1'b1);
      if (saw_ram_request || read_data !== 64'hC2C2_C2C2_0000_0002) begin
        $error("C's stored qword read back %016h%s", read_data,
               saw_ram_request ? " after a fill" : "");
        errors = errors + 1;
      end

      // 2. A load of an absent qword fills the line around the stored one.
      for (i = 0; i < 4; i = i + 1) fill_words[i] = fc[i];
      req_before = ram_req_n;
      fork serve_fill(); read_miss_at(SK_C); join
      if (ram_req_n - req_before != 1) begin
        $error("a load of C's absent qword 0 made %0d fill requests, expected 1",
               ram_req_n - req_before);
        errors = errors + 1;
      end
      if (read_data !== fc[0]) begin
        $error("C's filled qword 0 read %016h, expected %016h", read_data, fc[0]);
        errors = errors + 1;
      end
      saw_ram_request = 1'b0;
      read_at(SK_C + 16, 1'b1);
      if (read_data !== 64'hC2C2_C2C2_0000_0002) begin
        $error("the fill overwrote C's stored qword 2: %016h", read_data);
        errors = errors + 1;
      end
      read_at(SK_C + 8, 1'b1);
      if (read_data !== fc[1]) begin
        $error("C's filled qword 1 read %016h, expected %016h", read_data, fc[1]);
        errors = errors + 1;
      end
      read_at(SK_C + 24, 1'b1);
      if (read_data !== fc[3]) begin
        $error("C's filled qword 3 read %016h, expected %016h", read_data, fc[3]);
        errors = errors + 1;
      end
      if (saw_ram_request) begin
        $error("C was filled twice");
        errors = errors + 1;
      end

      // 3. D by a store miss over B (clean: nothing written back), then a
      //    64-bit store into its absent qword 3, which needs no fill.
      wb_n = 0;
      saw_ram_request = 1'b0;
      store_wait(SK_D + 8, 64'hD1D1_D1D1_0000_0001, 8'hff, 1'b1);
      store_wait(SK_D + 24, 64'hD3D3_D3D3_0000_0003, 8'hff, 1'b1);
      step(10);
      if (saw_ram_request || wb_n != 0) begin
        $error("D by two 64-bit stores took %0d fill request(s) and %0d write-back beats",
               saw_ram_request, wb_n);
        errors = errors + 1;
      end
      read_at(SK_D + 24, 1'b1);
      if (read_data !== 64'hD3D3_D3D3_0000_0003) begin
        $error("D's qword 3 read %016h after a store into it while absent", read_data);
        errors = errors + 1;
      end

      // 4. D goes back holding qwords 1 and 3 only.
      read_at(SK_C + 8, 1'b1);                 // C most recent, D least
      wb_n = 0;
      wb_mask_moved = 1'b0;
      for (i = 0; i < 4; i = i + 1) fill_words[i] = fa[i];
      fork serve_fill(); read_miss_at(SK_A); join
      step(10);
      if (wb_n != 4 || wb_addr[0][31:5] !== SK_D[31:5]) begin
        $error("evicting D wrote %0d beats at %08h", wb_n, wb_addr[0]);
        errors = errors + 1;
      end else begin
        if (wb_mask_cap !== 4'b1010) begin
          $error("D went back with mask %b, expected 1010 - only qwords 1 and 3 were ever in it",
                 wb_mask_cap);
          errors = errors + 1;
        end
        if (wb_data[1] !== 64'hD1D1_D1D1_0000_0001 || wb_data[3] !== 64'hD3D3_D3D3_0000_0003) begin
          $error("D's present qwords went back as %016h and %016h", wb_data[1], wb_data[3]);
          errors = errors + 1;
        end
      end
      if (wb_mask_moved) begin
        $error("writeback_mask changed while D's line was going out");
        errors = errors + 1;
      end

      // 5. A narrower store into an absent qword: B by a 64-bit store miss
      //    over C (dirty, whole), then a byte into B's absent qword 2. That
      //    fills B's absent qwords and puts the byte on top.
      wb_n = 0;
      store_wait(SK_B + 8, 64'hB1B1_B1B1_0000_0001, 8'hff, 1'b1);
      step(10);
      if (wb_n != 4 || wb_mask_cap !== 4'b1111 || wb_addr[0][31:5] !== SK_C[31:5]) begin
        $error("evicting C for B wrote %0d beats, mask %b, at %08h - expected 4, 1111, C",
               wb_n, wb_mask_cap, wb_addr[0]);
        errors = errors + 1;
      end
      for (i = 0; i < 4; i = i + 1) fill_words[i] = fb[i];
      req_before = ram_req_n;
      fork
        serve_fill();
        store_wait(SK_B + 19, 64'h0000_0000_5A00_0000, 8'h08, 1'b0);
      join
      if (ram_req_n - req_before != 1) begin
        $error("a byte store into an absent qword did not fill it first");
        errors = errors + 1;
      end
      read_at(SK_B + 16, 1'b1);
      if (read_data !== with_byte(fb[2], 3, 8'h5A)) begin
        $error("B's qword 2 read %016h, expected the fill with the stored byte, %016h",
               read_data, with_byte(fb[2], 3, 8'h5A));
        errors = errors + 1;
      end
      read_at(SK_B + 8, 1'b1);
      if (read_data !== 64'hB1B1_B1B1_0000_0001) begin
        $error("the fill for B's byte store overwrote its stored qword 1: %016h", read_data);
        errors = errors + 1;
      end
      read_at(SK_B + 0, 1'b1);
      if (read_data !== fb[0]) begin
        $error("B's filled qword 0 read %016h, expected %016h", read_data, fb[0]);
        errors = errors + 1;
      end

      // 6. Index write back invalidate names the way; the line goes back with
      //    its mask. C by a 64-bit store miss over A (clean), qword 0 only.
      wb_n = 0;
      store_wait(SK_C + 0, 64'hC0C0_C0C0_0000_0000, 8'hff, 1'b1);
      way_c = dut.data_way;
      step(4);
      wb_n = 0;
      wb_mask_moved = 1'b0;
      tag_addr <= {SK_C[31:14], way_c[0], SK_C[12:0]};
      rw_addr  <= {SK_C[31:14], way_c[0], SK_C[12:0]};
      cache_command <= 5'h01;
      step(3);
      cache_command_ena <= 1'b1;
      step(1);
      cache_command_ena <= 1'b0;
      step(40);
      if (wb_n != 4 || wb_mask_cap !== 4'b0001 || wb_data[0] !== 64'hC0C0_C0C0_0000_0000) begin
        $error("index write back of C (way %0d) wrote %0d beats, mask %b, qword 0 %016h - expected 4, 0001, C0C0C0C000000000",
               way_c, wb_n, wb_mask_cap, wb_data[0]);
        errors = errors + 1;
      end

      if (skip_n - skips_before != 4 || absent_n - absents_before != 2) begin
        $error("counted %0d skipped fills and %0d absent-qword fills, expected 4 and 2",
               skip_n - skips_before, absent_n - absents_before);
        errors = errors + 1;
      end
      if (errors == errors_before)
        $display("    skipped fills: stored qwords survive fills, write-backs carry only what the line holds");
    end

    $display("");
    if (errors == 0) $display("tb_ki_datacache_writeback: PASS");
    else $display("tb_ki_datacache_writeback: FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #500_000;
    $display("tb_ki_datacache_writeback: FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule

`default_nettype wire
