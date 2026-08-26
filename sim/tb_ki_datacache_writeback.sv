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
  // A pair that genuinely shares an index, built from the slices the RTL
  // actually uses rather than from a tag/offset split that happens to look
  // right. cpu_datacache indexes on addr[13:5] and compares addr[31:14], so
  // two addresses collide only if their low 14 bits match. LINE_ADDR and
  // LINE_ADDR2 differ in addr[13:12] - they are 0x234 and 0x567 in the
  // addr[31:12] field - so they land on DIFFERENT lines, which is the trap
  // already recorded for CTX_ALT above and which this pair avoids by
  // construction.
  localparam logic [8:0]  DISP_INDEX = 9'h0C0;
  localparam logic [31:0] DISP_A = {18'h00234, DISP_INDEX, 5'h00};
  localparam logic [31:0] DISP_B = {18'h00567, DISP_INDEX, 5'h00};
  // A third tag at the same index, so the dirty-on-store test can start from
  // a line it brought in itself rather than from whatever the displacement
  // test left resident.
  localparam logic [31:0] DISP_C = {18'h0089A, DISP_INDEX, 5'h00};

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
  wire [63:0]  read_data;

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

  cpu_datacache #(.LITTLE_ENDIAN(1'b1)) dut (
    .clk1x(clk1x), .clk93(clk93), .clk2x(clk2x),
    // One reset for both domains in the bench; see tb_ki_instrcache.sv.
    .reset_1x(reset_93), .reset_93(reset_93), .ce_93(1'b1),
    .stall(stall), .stall4(stall4), .fifo_block(fifo_block),
    .slow_in(slow_in), .force_wb_in(force_wb_in), .write_through_in(1'b0),
    .ram_request(ram_request), .ram_reqAddr(ram_reqAddr),
    .ram_active(ram_active), .ram_grant(ram_grant), .ram_done(ram_done),
    .ddr3_DOUT(ddr3_DOUT), .ddr3_DOUT_READY(ddr3_DOUT_READY),
    .writeback_ena(writeback_ena), .writeback_addr(writeback_addr),
    .writeback_data(writeback_data),
    .tag_addr(tag_addr),
    .read_ena(read_ena), .RW_addr(rw_addr), .RW_64(rw_64),
    .read_busy(read_busy), .read_done(read_done), .read_data(read_data),
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

  // Capture the write-back burst.
  logic [63:0] wb_data [0:7];
  logic [31:0] wb_addr [0:7];
  integer wb_n = 0;
  always @(posedge clk93) begin
    if (writeback_ena) begin
      if (wb_n < 8) begin
        wb_data[wb_n] <= writeback_data;
        wb_addr[wb_n] <= writeback_addr;
      end
      wb_n <= wb_n + 1;
    end
  end

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
  task automatic cache_read_miss(input int byte_offset);
    integer guard;
    begin
      tag_addr <= LINE_ADDR2 + byte_offset;
      rw_addr  <= LINE_ADDR2 + byte_offset;
      rw_64    <= 1'b1;
      step(2);
      read_ena <= 1'b1;
      guard = 0;
      forever begin
        step(1);
        if (read_done) break;
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
        if (read_done) break;
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
        if (read_done) break;
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
        if (read_done) break;
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
        if (read_done) break;
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

  integer i;
  integer k;
  integer bad;
  logic [63:0] expect_word;
  logic [63:0] byte_word;

  initial begin
    step(4);
    ss_reset = 1'b0;
    reset_93 = 1'b0;
    step(700);          // CLEARCACHE walks all 512 tags

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
    $display("  displacement write-back (a miss evicts a dirty line)");

    mark_dirty_at(DISP_A);
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

    $display("");
    $display("  a store to a clean resident line must mark it dirty");

    // Use a third tag at the shared index so this starts from a known state
    // rather than from whatever the displacement test left behind.
    wb_n = 0;
    saw_ram_request = 1'b0;
    for (i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hC0DE_0000 + i * 2 + 1, 32'hC0DE_0000 + i * 2};

    // 1. Bring the line in by MISSING on it. It is now valid and clean.
    fork
      serve_fill();
      read_miss_at(DISP_C);
    join
    step(20);

    if (wb_n != 0) begin
      $error("filling a clean line wrote back %0d beats, expected none", wb_n);
      errors = errors + 1;
    end

    // 2. Store into it. This hits, and must set the dirty bit.
    write_dword_at(DISP_C, 64'hFEED_FACE_1234_5678);
    step(10);

    // 3. Displace it. The store must come back out.
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
      if (wb_addr[0][31:5] !== DISP_C[31:5]) begin
        $error("write-back went to %08h, expected the line at %08h",
               wb_addr[0], DISP_C);
        errors = errors + 1;
      end
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
