`timescale 1ns/1ps
`default_nettype none

module tb_ki_instrcache;
  // 0x01D is the one index cpu_instrcache traces internally (its
  // `-- synthesis translate_off` reports), so a bench on that line gets the
  // RTL's own view of grant/beat/done for free.
  localparam logic [8:0]  LINE_INDEX = 9'h01D;
  localparam logic [31:0] ADDR_A = {18'h00123, LINE_INDEX, 5'h00};
  // Same index, different tag - must MISS, and is what a too-narrow tag
  // compare would wrongly report as a hit.
  localparam logic [31:0] ADDR_B = {18'h00456, LINE_INDEX, 5'h00};

  // For the split-fill test: a different tag AND a different index.
  localparam logic [8:0]  OTHER_INDEX = 9'h0C3;
  localparam logic [31:0] ADDR_C = {18'h00789, OTHER_INDEX, 5'h00};
  // The address that would hit if the tag came from ADDR_C while the index
  // came from ADDR_A. It is neither of them, and nothing ever fills it.
  localparam logic [31:0] ADDR_PHANTOM = {18'h00789, LINE_INDEX, 5'h00};

  logic clk1x = 1'b0;
  logic clk93 = 1'b0;
  logic clk2x = 1'b0;
  logic reset_93 = 1'b1;
  logic ss_reset = 1'b1;
  logic ce_93 = 1'b1;
  integer errors = 0;

  // Same ratios the datacache bench uses.
  always #10 clk1x = ~clk1x;
  always #5  clk93 = ~clk93;
  always #5  clk2x = ~clk2x;

  wire        ram_request;
  logic       ram_active = 1'b0;
  logic       ram_grant = 1'b0;
  logic       ram_done = 1'b0;
  logic [63:0] ddr3_DOUT = 64'd0;
  logic       ddr3_DOUT_READY = 1'b0;

  logic        read_select = 1'b0;
  logic [31:0] read_addr1 = 32'd0;
  logic [31:0] read_addr2 = 32'd0;
  logic [31:0] read_addrCompare1 = 32'd0;
  logic [31:0] read_addrCompare2 = 32'd0;
  wire         read_hit;
  wire  [31:0] read_data;

  logic        fill_request = 1'b0;
  logic [31:0] fill_addrData = 32'd0;
  logic [31:0] fill_addrTag = 32'd0;
  wire         fill_done;

  logic        CacheCommandEna = 1'b0;
  logic  [4:0] CacheCommand = 5'd0;
  logic [31:0] CacheCommandAddr = 32'd0;
  logic        TagLo_Valid = 1'b0;
  logic [19:0] TagLo_Addr = 20'd0;

  cpu_instrcache #(.LITTLE_ENDIAN(1'b1)) dut (
    .clk1x(clk1x), .clk93(clk93), .clk2x(clk2x),
    // The bench drives both domains from one reset, so the clk1x fill path
    // takes the same signal the clk93 side does.
    .reset_1x(reset_93), .reset_93(reset_93), .ce_93(ce_93),
    .ram_request(ram_request), .ram_active(ram_active),
    .ram_grant(ram_grant), .ram_done(ram_done),
    .ddr3_DOUT(ddr3_DOUT), .ddr3_DOUT_READY(ddr3_DOUT_READY),
    .read_select(read_select),
    .read_addr1(read_addr1), .read_addr2(read_addr2),
    .read_addrCompare1(read_addrCompare1),
    .read_addrCompare2(read_addrCompare2),
    .read_hit(read_hit), .read_data(read_data),
    .fill_request(fill_request),
    .fill_addrData(fill_addrData), .fill_addrTag(fill_addrTag),
    .fill_done(fill_done),
    .CacheCommandEna(CacheCommandEna), .CacheCommand(CacheCommand),
    .CacheCommandAddr(CacheCommandAddr),
    .TagLo_Valid(TagLo_Valid), .TagLo_Addr(TagLo_Addr),
    .SS_reset(ss_reset)
  );

  task automatic step(input int n);
    repeat (n) @(posedge clk93);
  endtask

  logic [63:0] fill_words [0:3];

  // ram_request is a single-cycle registered pulse; latch it so the wait loop
  // cannot step past it.
  logic ram_request_seen = 1'b0;
  always @(posedge clk93) if (ram_request) ram_request_seen <= 1'b1;

  // One 32-byte line fill: request it, wait for ram_request, then deliver four
  // 64-bit beats on clk1x - the domain the fill path was rewritten to consume
  // them in.
  task automatic do_fill(input logic [31:0] addr);
    integer guard;
    begin
      fill_addrData <= addr;
      fill_addrTag  <= addr;
      step(2);
      // One cycle only. cpu_instrcache latches fill_request into fill_latched
      // unconditionally, every cycle, in whatever state it is in - so a
      // request held across the transfer re-arms itself and the cache dives
      // straight back into FILL when the first one completes. The CPU pulses
      // it; the bench has to as well.
      ram_request_seen = 1'b0;
      fill_request  <= 1'b1;
      step(1);
      fill_request  <= 1'b0;
      guard = 0;
      while (!ram_request_seen && guard < 200) begin
        step(1);
        guard = guard + 1;
      end
      if (!ram_request_seen) begin
        $error("instruction cache never requested a fill for %08h", addr);
        errors = errors + 1;
      end
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
      step(6);
    end
  endtask

  // A fill whose two address ports DISAGREE.
  //
  // cpu_instrcache takes the tag-RAM index and the tag VALUE from different
  // ports:
  //
  //   :371  tag_address_a <= fill_addrTag_sav(13 downto 5)    from fill_addrTag
  //   :370  tag_data_a    <= '1' & fill_addrData(31 downto 14) from fill_addrData
  //
  // cpu.vhd drives fill_addrTag from a LATCHED FetchAddr and fill_addrData from
  // mem1_address, the live memory-request address. They are equivalent only
  // while mem1_address still describes the line the fill was requested for.
  //
  // This asks the narrow question the cache alone can answer: IF those two ever
  // disagree, does the cache mis-tag the line? It deliberately does NOT claim
  // cpu.vhd makes them disagree - that is a separate question about
  // mem1_address stability across a granted fill.
  task automatic do_fill_split(input logic [31:0] addr_tag,
                               input logic [31:0] addr_data);
    integer guard;
    begin
      fill_addrData <= addr_data;
      fill_addrTag  <= addr_tag;
      step(2);
      ram_request_seen = 1'b0;
      fill_request  <= 1'b1;
      step(1);
      fill_request  <= 1'b0;
      guard = 0;
      while (!ram_request_seen && guard < 200) begin
        step(1);
        guard = guard + 1;
      end
      if (!ram_request_seen) begin
        $error("split fill never requested for tag=%08h data=%08h",
               addr_tag, addr_data);
        errors = errors + 1;
      end
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
      step(6);
    end
  endtask

  // Present an address on port 1 and sample hit/data. read_addrCompare1 is the
  // address the tag is compared against; read_addr1 selects the index.
  task automatic probe(input logic [31:0] addr);
    begin
      read_select <= 1'b0;
      read_addr1 <= addr;
      read_addrCompare1 <= addr;
      step(3);
    end
  endtask

  // The ROM's invalidate: mtc0 zero,$28 then `cache 0x08` - I-cache Index
  // Store Tag with TagLo = 0, so the stored valid bit is 0.
  task automatic rom_invalidate(input logic [31:0] addr);
    begin
      TagLo_Valid <= 1'b0;
      TagLo_Addr  <= 20'd0;
      CacheCommandAddr <= addr;
      CacheCommand <= 5'h08;
      step(3);
      CacheCommandEna <= 1'b1;
      step(1);
      CacheCommandEna <= 1'b0;
      step(6);
    end
  endtask

  function automatic logic [31:0] word_of(input logic [63:0] pair,
                                          input int half);
    word_of = half ? pair[63:32] : pair[31:0];
  endfunction

  task automatic expect_line(input logic [31:0] base, input string what);
    logic [31:0] want;
    begin
      for (int w = 0; w < 8; w = w + 1) begin
        probe(base + w * 4);
        want = word_of(fill_words[w / 2], w % 2);
        if (!read_hit) begin
          $error("%0s: word %0d at %08h MISSED, expected a hit",
                 what, w, base + w * 4);
          errors = errors + 1;
        end else if (read_data !== want) begin
          $error("%0s: word %0d at %08h = %08h, expected %08h",
                 what, w, base + w * 4, read_data, want);
          errors = errors + 1;
        end
      end
    end
  endtask

  // A fill that is GRANTED, delivered fewer than four beats, and then
  // COMPLETED - ram_done asserted and ram_active dropped, exactly as the
  // arbiter ends any transaction. This is the condition the ram_active guard
  // exists for and which no bench has ever created: under the original rules
  // fill_active_2x is closed only by the fourth beat, so it stays set once the
  // transaction is over.
  //
  // The completion matters. A first version of this task simply stopped
  // driving and dropped ram_active with no ram_done; the cache then sat
  // mid-fill and every probe returned a held value rather than the array's
  // contents, so the test measured nothing. On every real bridge path
  // ram_active is held until mem_done, so a fill always ends this way.
  task automatic underserved_fill(input logic [31:0] addr,
                                  input logic [63:0] w0,
                                  input logic [63:0] w1);
    integer guard;
    begin
      fill_addrData <= addr;
      fill_addrTag  <= addr;
      step(2);
      ram_request_seen = 1'b0;
      fill_request <= 1'b1;
      step(1);
      fill_request <= 1'b0;
      guard = 0;
      while (!ram_request_seen && guard < 200) begin
        step(1);
        guard = guard + 1;
      end
      if (!ram_request_seen) begin
        $error("no fill request for the underserved fill at %08h", addr);
        errors = errors + 1;
      end
      @(posedge clk1x);
      ram_active <= 1'b1;
      ram_grant  <= 1'b1;
      ddr3_DOUT  <= w0;
      ddr3_DOUT_READY <= 1'b1;
      @(posedge clk1x);
      ram_grant <= 1'b0;
      ddr3_DOUT <= w1;
      @(posedge clk1x);
      // Beats 2 and 3 never arrive, but the transaction still COMPLETES.
      ddr3_DOUT_READY <= 1'b0;
      ram_done <= 1'b1;
      @(posedge clk1x);
      ram_done <= 1'b0;
      ram_active <= 1'b0;
      step(6);
    end
  endtask

  // 64-bit returns belonging to somebody else - the data cache's fill, or a
  // plain uncached 64-bit load. ddr3_DOUT_READY is ONE shared signal, so these
  // pulse here too; ram_active stays low because the arbiter did not assign
  // this transaction to the instruction cache.
  task automatic foreign_beats(input int n, input logic [63:0] base);
    begin
      for (int i = 0; i < n; i = i + 1) begin
        @(posedge clk1x);
        ddr3_DOUT <= base + i;
        ddr3_DOUT_READY <= 1'b1;
      end
      @(posedge clk1x);
      ddr3_DOUT_READY <= 1'b0;
      step(4);
    end
  endtask

  initial begin
    step(4);
    ss_reset = 1'b0;
    reset_93 = 1'b0;
    step(700);          // the cache clears all 512 tags out of reset

    $display("");
    $display("cpu_instrcache: fill, hit, and the boot ROM's invalidate");
    $display("");

    // ---- 1. a line fills and reads back, all eight words ----
    for (int i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hAAAA_0000 + i * 2 + 1, 32'hAAAA_0000 + i * 2};
    do_fill(ADDR_A);
    expect_line(ADDR_A, "after fill");
    $display("  a 32-byte line fills and all eight words read back");

    // ---- 2. a different TAG at the same index must MISS ----
    // The tag is addr[31:14] and the index addr[13:5], so these two addresses
    // share an index and differ only above bit 14. A tag compare that is too
    // narrow, or one that compares the wrong slice, reports a false hit here
    // and the CPU executes another address's instructions.
    probe(ADDR_B);
    if (read_hit) begin
      $error("a different tag at the same index HIT - tag compare is wrong");
      errors = errors + 1;
    end else begin
      $display("  a different tag at the same index correctly misses");
    end

    // ---- 3. the boot ROM's invalidate must actually invalidate ----
    probe(ADDR_A);
    if (!read_hit) begin
      $error("line went cold before the invalidate was even issued");
      errors = errors + 1;
    end
    rom_invalidate(ADDR_A);
    probe(ADDR_A);
    if (read_hit) begin
      $error("cache 0x08 with TagLo=0 did NOT invalidate - the line still hits");
      errors = errors + 1;
    end else begin
      $display("  cache 0x08 with TagLo = 0 invalidates the line");
    end

    // ---- 4. THE CASE THAT MATTERS: refill returns the NEW contents ----
    //
    // Write code, flush, execute it. If the cache answers with the old line the
    // CPU runs whatever was there before, which is what the handoff to
    // 0x88000000 looks like on hardware: 001FF000 fetched where the memory
    // should hold 0A00006E.
    for (int i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hBBBB_0000 + i * 2 + 1, 32'hBBBB_0000 + i * 2};
    do_fill(ADDR_A);
    expect_line(ADDR_A, "after invalidate and refill");
    $display("  refill after invalidate returns the NEW memory contents");

    for (int i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'hCCCC_0000 + i * 2 + 1, 32'hCCCC_0000 + i * 2};
    do_fill(ADDR_A);
    expect_line(ADDR_A, "baseline before the underserved fill");

    underserved_fill(ADDR_B, 64'hDDDD_0001_DDDD_0000, 64'hDDDD_0003_DDDD_0002);
    foreign_beats(8, 64'hEEEE_0001_EEEE_0000);

    begin
      logic [31:0] want;
      int foreign_words;
      foreign_words = 0;
      // Beats 2 and 3 are words 4..7. Beats 0 and 1 were legitimately
      // overwritten by the abandoned fill while ram_active was HIGH, so they
      // are not part of this check - only the words no transaction of ours was
      // ever entitled to write.
      for (int w = 4; w < 8; w = w + 1) begin
        probe(ADDR_B + w * 4);
        want = word_of(fill_words[w / 2], w % 2);
        if (!read_hit) begin
          $error("hypothesis B: word %0d at %08h missed - the completed fill should own this line",
                 w, ADDR_B + w * 4);
          errors = errors + 1;
        end else if (read_data[31:16] == 16'hEEEE) begin
          $error("HYPOTHESIS B CONFIRMED: word %0d at %08h = %08h - a FOREIGN 64-bit return was written into this cache line",
                 w, ADDR_B + w * 4, read_data);
          errors = errors + 1;
          foreign_words = foreign_words + 1;
        end else if (read_data !== want) begin
          $error("hypothesis B: word %0d at %08h = %08h, expected %08h",
                 w, ADDR_B + w * 4, read_data, want);
          errors = errors + 1;
        end
      end
      if (foreign_words == 0)
        $display("  an abandoned fill plus 8 foreign returns leaves beats 2-3 intact");
    end

    for (int i = 0; i < 4; i = i + 1)
      fill_words[i] = {32'h9999_0000 + i * 2 + 1, 32'h9999_0000 + i * 2};
    do_fill_split(.addr_tag(ADDR_A), .addr_data(ADDR_C));

    // CHARACTERISATION, not a bug report. The two ports are SUPPOSED to
    // differ - index from virtual FetchAddr, tag from physical mem1_address -
    // because this is a virtually-indexed, physically-tagged cache. What this
    // pins down is that there is NO coherence check between them: the cache
    // will faithfully store a tag from one address at an index from another.
    //
    // So the cache is correct exactly as long as its two ports remain the
    // virtual and physical views of the SAME line, and it has no way to notice
    // if they stop being that. Whether they can stop is a question about
    // mem1_address stability across a granted fill in cpu.vhd, NOT about this
    // module - and it is unanswered.
    //
    // Asserted positively so the property is locked in: if this ever stops
    // hitting, the structure has changed and this comment is stale.
    probe(ADDR_PHANTOM);
    if (!read_hit) begin
      $error("split fill: %08h did not hit, so the index/tag sourcing has changed - re-read the VIPT note above",
             ADDR_PHANTOM);
      errors = errors + 1;
    end else if (read_data !== 32'h9999_0000) begin
      $error("split fill: %08h hit but returned %08h, expected 99990000",
             ADDR_PHANTOM, read_data);
      errors = errors + 1;
    end else begin
      $display("  split fill: index from one port, tag from the other - %08h,",
               ADDR_PHANTOM);
      $display("    which was never filled, hits and returns %08h. The cache has",
               read_data);
      $display("    NO coherence check between its two address ports.");
    end

    // And whichever address the fill really belonged to must be the one that
    // hits. Reporting only the phantom would leave "so where did the line go?"
    // unanswered.
    probe(ADDR_C);
    $display("    ADDR_C  (tag and index both from the data port) hit=%0b", read_hit);
    probe(ADDR_A);
    $display("    ADDR_A  (tag and index both from the tag port)  hit=%0b", read_hit);

    $display("");
    if (errors == 0) $display("tb_ki_instrcache: PASS");
    else $display("tb_ki_instrcache: FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #500_000;
    $display("tb_ki_instrcache: FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule

`default_nettype wire
