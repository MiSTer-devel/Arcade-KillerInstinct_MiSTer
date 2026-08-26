`timescale 1ns/1ps
`default_nettype none

// The real ioctl ROM download path, end to end.
//
// Every other bench in this tree preloads `bridge.boot_cache` and pokes the
// SDRAM device directly, so a fault anywhere in the download - byte lane,
// 16->64 assembly, address, FIFO, the SDRAM write burst, or the boot-cache
// fill - is invisible to all of them. This is the largest piece of
// KI-specific logic that has never been exercised.
//
// Downloads the ROM through ioctl exactly as the framework does, then checks
// it two independent ways:
//
//   1. bridge.boot_cache, compared word for word against the ROM file. This
//      is the line buffer added during the throughput work and serves every
//      boot fetch below 8 KiB.
//   2. Read-back through the CPU port, which for addresses below 8 KiB is
//      answered from the boot cache and above it from SDRAM - so both the
//      cache fill and the SDRAM write burst are covered.
//
// DOWNLOAD_BYTES defaults past the 8 KiB boot-cache window so both paths are
// hit. Raise it to 524288 for the whole ROM at the cost of sim time.
module tb_ki_rom_download #(
    parameter integer DOWNLOAD_BYTES = 65536
);
  localparam real TCK = 20.0;
  localparam integer ROM_BYTES = 524288;
  localparam integer BOOT_CACHE_BYTES = 8 * 1024;
  localparam logic [31:0] BOOT_BASE = 32'h1fc0_0000;

  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  integer errors = 0;

  always #(TCK / 2.0) clk = ~clk;
  always #(TCK / 4.0) ddr_clk = ~ddr_clk;

  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  logic        cpu_request = 1'b0;
  logic        cpu_rnw = 1'b1;
  logic [31:0] cpu_address = 32'd0;
  logic        cpu_req64 = 1'b0;
  logic  [2:0] cpu_size = 3'd1;
  logic  [7:0] cpu_write_mask = 8'd0;
  logic [63:0] cpu_data_write = 64'd0;
  wire  [63:0] cpu_data_read;
  wire         cpu_done;
  wire         cpu_grant;
  wire  [63:0] cpu_cache_data;
  wire         cpu_cache_data_ready;

  logic        ioctl_download = 1'b0;
  logic [15:0] ioctl_index = 16'h0001;
  logic        ioctl_wr = 1'b0;
  logic [26:0] ioctl_addr = 27'd0;
  logic [15:0] ioctl_dout = 16'd0;
  wire         ioctl_wait;
  wire         boot_loaded;

  wire        io_request, io_write;
  wire [31:0] io_address, io_write_data;
  wire  [3:0] io_byte_enable;

  wire [24:0] bridge_address;
  wire [63:0] bridge_write_data;
  wire  [7:0] bridge_byte_enable;
  wire  [4:0] bridge_burst;
  wire        bridge_read, bridge_write;
  wire [15:0] bridge_read_data;
  wire        bridge_data_valid, bridge_done;
  wire        sdram_ready;

  wire [24:0] controller_address;
  wire [63:0] controller_write_data;
  wire  [7:0] controller_byte_enable;
  wire  [4:0] controller_burst;
  wire        controller_read, controller_write;
  wire [15:0] controller_read_data;
  wire        controller_dout_valid, controller_ready;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire        SDRAM_DQML, SDRAM_DQMH;
  wire  [1:0] SDRAM_BA;
  wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

  wire [28:0] ddram_addr;
  wire  [7:0] ddram_burstcnt, ddram_be;
  wire [63:0] ddram_din;
  wire        ddram_rd, ddram_we;

  byte unsigned rom [0:ROM_BYTES-1];

  ki_memory_bridge bridge (
    .clk(clk), .ddr_clk(ddr_clk), .reset(reset),
    .cpu_request(cpu_request), .cpu_rnw(cpu_rnw),
    .cpu_address(cpu_address), .cpu_req64(cpu_req64), .cpu_size(cpu_size),
    .cpu_write_mask(cpu_write_mask), .cpu_data_write(cpu_data_write),
    .cpu_data_read(cpu_data_read), .cpu_done(cpu_done), .cpu_grant(cpu_grant),
    .cpu_cache_data(cpu_cache_data),
    .cpu_cache_data_ready(cpu_cache_data_ready),
    .io_request(io_request), .io_write(io_write), .io_address(io_address),
    .io_write_data(io_write_data), .io_byte_enable(io_byte_enable),
    .io_read_data(32'd0), .io_done(1'b0),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .boot_loaded(boot_loaded),
    .dcs_rom_request(1'b0), .dcs_rom_address(19'd0),
    .dcs_rom_ready(), .dcs_rom_data(),
    .video_request(1'b0), .video_address(28'd0), .video_words(3'd1),
    .video_data(), .video_data_valid(), .video_done(),
    .sdram_address(bridge_address), .sdram_write_data(bridge_write_data),
    .sdram_byte_enable(bridge_byte_enable), .sdram_burst(bridge_burst),
    .sdram_read(bridge_read), .sdram_write(bridge_write),
    .sdram_read_data(bridge_read_data),
    .sdram_data_valid(bridge_data_valid), .sdram_done(bridge_done),
    .sdram_ready(sdram_ready),
    .ddram_busy(1'b0), .ddram_burstcnt(ddram_burstcnt),
    .ddram_addr(ddram_addr), .ddram_dout(64'd0), .ddram_dout_ready(1'b0),
    .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
    .ddram_we(ddram_we),
    .fb_read_accept(), .fb_write_accept(),
    .debug_state(), .debug_cpu_pending(),
    .debug_fill_b0(), .debug_fill_b1(),
    .debug_last_write_address(), .debug_last_write_data(),
    .debug_last_write_info(), .debug_write_count(),
    .debug_low_write_count(), .debug_main_write_count(),
    .debug_main_write0(), .debug_main_write1(), .debug_main_write2(),
    .debug_table_write_count(), .debug_table_write_address(),
    .debug_table_write_data()
  );

  ki_sdram_adapter adapter (
    .clk(clk), .reset(1'b0),
    .request_address(bridge_address),
    .request_write_data(bridge_write_data),
    .request_byte_enable(bridge_byte_enable),
    .request_burst(bridge_burst),
    .request_read(bridge_read), .request_write(bridge_write),
    .request_read_data(bridge_read_data),
    .request_data_valid(bridge_data_valid),
    .request_done(bridge_done),
    .aux_address(25'd0), .aux_write_data(64'd0), .aux_byte_enable(8'h00),
    .aux_burst(5'd1), .aux_read(1'b0), .aux_write(1'b0),
    .aux_read_data(), .aux_data_valid(), .aux_done(),
    .sdram_ready(sdram_ready),
    .controller_address(controller_address),
    .controller_write_data(controller_write_data),
    .controller_byte_enable(controller_byte_enable),
    .controller_burst(controller_burst),
    .controller_read(controller_read), .controller_write(controller_write),
    .controller_read_data(controller_read_data),
    .controller_dout_valid(controller_dout_valid),
    .controller_ready(controller_ready)
  );

  ki_sdram_burst controller (
    .init(init), .clk(clk),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
    .wtbt(controller_byte_enable), .addr(controller_address),
    .burst(controller_burst),
    .dout(controller_read_data), .dout_valid(controller_dout_valid),
    .din(controller_write_data),
    .we(controller_write), .rd(controller_read), .ready(controller_ready)
  );

  mt48lc16m16_ki #(.TAC_NS(6.0)) memory (
    .clk(clk_dev), .dq(SDRAM_DQ), .addr(SDRAM_A), .ba(SDRAM_BA),
    .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .dqm({SDRAM_DQMH, SDRAM_DQML}), .cke(SDRAM_CKE)
  );

  function automatic logic [63:0] rom_qword(input integer offset);
    rom_qword = {rom[offset+7], rom[offset+6], rom[offset+5], rom[offset+4],
                 rom[offset+3], rom[offset+2], rom[offset+1], rom[offset+0]};
  endfunction

  // One ioctl beat, honouring ioctl_wait backpressure the same way the
  // framework does - the FIFO high-water mark is a real part of this path.
  task automatic ioctl_beat(input integer offset);
    begin
      while (ioctl_wait) @(posedge clk);
      ioctl_addr <= offset[26:0];
      ioctl_dout <= {rom[offset+1], rom[offset]};
      ioctl_wr   <= 1'b1;
      @(posedge clk);
      ioctl_wr   <= 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic cpu_read64(input logic [31:0] address,
                            output logic [63:0] value);
    begin
      @(posedge clk);
      cpu_address <= address;
      cpu_rnw     <= 1'b1;
      cpu_req64   <= 1'b1;
      cpu_size    <= 3'd1;
      cpu_request <= 1'b1;
      @(posedge clk);
      cpu_request <= 1'b0;
      while (!cpu_done) @(posedge clk);
      value = cpu_data_read;
      @(posedge clk);
    end
  endtask

  // A 32-bit read - req64 low. This is the path an UNCACHED byte load takes,
  // and it is the one the bitstream field decoder uses: `lbu a2,0(v0)` at
  // 9FC009B8, reading a symbol index straight out of the boot ROM through
  // KSEG1. Every read in this bench before now was req64 high, so the 32-bit
  // return path has never been exercised here.
  task automatic cpu_read32(input logic [31:0] address,
                            output logic [31:0] value);
    begin
      @(posedge clk);
      cpu_address <= address;
      cpu_rnw     <= 1'b1;
      cpu_req64   <= 1'b0;
      cpu_size    <= 3'd1;
      cpu_request <= 1'b1;
      @(posedge clk);
      cpu_request <= 1'b0;
      while (!cpu_done) @(posedge clk);
      value = cpu_data_read[31:0];
      @(posedge clk);
      cpu_req64   <= 1'b1;
    end
  endtask

  integer offset;
  integer index;
  logic [63:0] got, want;
  integer reported;

  // ---- ROM line-buffer sweep bookkeeping -------------------------------
  integer line_checked = 0;
  integer line_reported = 0;
  integer s1;
  integer pass;
  integer a;
  integer b;

  // One aligned 64-bit read, compared against the ROM image. `byte_offset`
  // must be 8-aligned, which is what the CPU issues: tb_ki_ldl_ldr's bus
  // trace shows LDL/LDR present already-aligned addresses and do the merge
  // inside the core.
  task automatic check_qword(input integer byte_offset, input string phase);
    logic [63:0] g, w;
    begin
      cpu_read64(BOOT_BASE + byte_offset, g);
      w = rom_qword(byte_offset);
      line_checked = line_checked + 1;
      if (g !== w) begin
        errors = errors + 1;
        if (line_reported < 10) begin
          line_reported = line_reported + 1;
          $display("FAIL[%0s]: %08x = %016x, want %016x (line %0d offset %0d)",
                   phase, BOOT_BASE + byte_offset, g, w,
                   byte_offset / 32, (byte_offset % 32) / 8);
        end
      end
    end
  endtask

  initial begin
    $readmemh("sim/media/kinst_boot.hex", rom);

    if ({rom['h0fd1], rom['h0fd0]} != 16'h7262) begin
      $display("FAIL: ROM signature at 0xFD0 is %02x%02x, expected 7262",
        rom['h0fd1], rom['h0fd0]);
      $fatal(1);
    end

    repeat (8) @(posedge clk);
    reset = 1'b0;
    init  = 1'b0;
    wait (sdram_ready);
    $display("SDRAM initialised at t=%0t", $time);
    repeat (8) @(posedge clk);

    // ---- the real download ----------------------------------------------
    $display("downloading %0d bytes through ioctl (index=%04x)...",
             DOWNLOAD_BYTES, ioctl_index);
    ioctl_download <= 1'b1;
    @(posedge clk);
    for (offset = 0; offset < DOWNLOAD_BYTES; offset = offset + 2)
      ioctl_beat(offset);
    ioctl_download <= 1'b0;
    repeat (200) @(posedge clk);
    $display("download finished at t=%0t, boot_loaded=%0b", $time, boot_loaded);

    if (!boot_loaded) begin
      $display("FAIL: boot_loaded never asserted");
      errors = errors + 1;
    end

    // ---- check 1: the boot line buffer -----------------------------------
    reported = 0;
    for (index = 0;
         (index < BOOT_CACHE_BYTES / 8) && (index * 8 < DOWNLOAD_BYTES);
         index = index + 1) begin
      want = rom_qword(index * 8);
      got  = bridge.boot_cache[index];
      if (got !== want) begin
        errors = errors + 1;
        if (reported < 8) begin
          reported = reported + 1;
          $display("FAIL: boot_cache[%0d] (offset %05x) = %016x, want %016x",
                   index, index * 8, got, want);
        end
      end
    end
    $display("boot_cache checked: %0d entries, %0d errors so far",
             (DOWNLOAD_BYTES < BOOT_CACHE_BYTES ? DOWNLOAD_BYTES : BOOT_CACHE_BYTES) / 8,
             errors);

    // ---- check 2: read back through the CPU port -------------------------
    // Below 8 KiB this is answered from the boot cache, above it from SDRAM,
    // so one sweep covers the cache fill and the write burst.
    reported = 0;
    for (offset = 0; offset < DOWNLOAD_BYTES; offset = offset + 8) begin
      cpu_read64(BOOT_BASE + offset, got);
      want = rom_qword(offset);
      if (got !== want) begin
        errors = errors + 1;
        if (reported < 8) begin
          reported = reported + 1;
          $display("FAIL: read back %08x = %016x, want %016x (%0s)",
                   BOOT_BASE + offset, got, want,
                   (offset < BOOT_CACHE_BYTES) ? "boot cache" : "SDRAM");
        end
      end
    end
    $display("read-back checked: %0d qwords", DOWNLOAD_BYTES / 8);

    // ---- check 3: the bitstream reader's ROM access pattern --------------
    //
    // The reader's ONLY memory access is
    //   9FC00D5C: ldl v1,7(s1)
    //   9FC00D60: ldr v1,0(s1)
    // an unaligned 64-bit pair from s1, which is a KSEG1 - uncached - boot
    // ROM address. It misses the data cache entirely and is served by
    // ki_memory_bridge's 16-word ROM LINE BUFFER, on a miss from SDRAM.
    // Everything else in read(n) is register arithmetic, so this is the one
    // memory path the reader depends on.
    //
    // s1 advances by SEVEN per call, so it visits every alignment mod 8 and
    // crosses the 32-byte line at irregular offsets. What the bridge sees is
    // the two doublewords containing s1 and s1+7.
    //
    // Check 2 above is ascending and aligned. A monotone sweep cannot
    // separate a stale line buffer from correct data - the lesson recorded
    // for tb_ki_video_scanout, where reading backwards is what distinguished
    // a held request from an addressing fault. These passes are built to
    // break that: the reader's own walk, then descending, then deliberate
    // thrash between two distant lines.
    //
    // All of it sits ABOVE the 8 KiB boot-cache window so the line buffer
    // is the path under test rather than the M10K boot cache.
    if (DOWNLOAD_BYTES > BOOT_CACHE_BYTES + 8192) begin
      $display("");
      $display("ROM line buffer, unaligned reader pattern:");

      // Pass A: the reader's own walk, s1 += 7.
      s1 = BOOT_CACHE_BYTES + 32'h101;      // deliberately not line-aligned
      for (pass = 0; pass < 300; pass = pass + 1) begin
        a = (s1 + 7) & ~32'd7;              // ldl 7(s1)
        b = s1 & ~32'd7;                    // ldr 0(s1)
        if ((a + 8) <= DOWNLOAD_BYTES) check_qword(a, "reader ldl");
        if ((b + 8) <= DOWNLOAD_BYTES) check_qword(b, "reader ldr");
        s1 = s1 + 7;
      end
      $display("  reader walk (s1 += 7): %0d reads", line_checked);

      // Pass B: descending across several line boundaries.
      for (offset = BOOT_CACHE_BYTES + 2048; offset >= BOOT_CACHE_BYTES;
           offset = offset - 8)
        check_qword(offset, "descending");
      $display("  descending sweep done");

      // Pass C: alternate between two lines far enough apart that every read
      // misses, so the buffer is refilled on each access and a stale hit or a
      // wrong tag shows up immediately.
      for (pass = 0; pass < 200; pass = pass + 1) begin
        a = BOOT_CACHE_BYTES + (pass % 4) * 8;
        b = BOOT_CACHE_BYTES + 16384 + (pass % 4) * 8;
        check_qword(a, "thrash lo");
        check_qword(b, "thrash hi");
      end
      $display("  line-buffer thrash done");

      // Pass D: every doubleword of four consecutive lines, in a shuffled
      // order, so neither ascending nor descending locality can hide a
      // wrong-offset return within a correctly fetched line.
      for (pass = 0; pass < 16; pass = pass + 1) begin
        a = BOOT_CACHE_BYTES + 4096 + ((pass * 7) % 16) * 8;
        check_qword(a, "shuffled");
      end
      $display("  shuffled within-line order done");

      $display("ROM line buffer: %0d unaligned-pattern reads checked",
               line_checked);
    end

    // ---- check 4: 32-bit reads, and the bytes inside them ----------------
    //
    // MAME measured real KI's field decoder reading a byte at BFC011FB and
    // getting 0x1D, which indexes the permutation table to 0x02. Our core
    // behaves as though that byte reads 0: its rt/rd fields walk 31, 30, 29,
    // 28, and under the ROM's move-to-BACK reorder at 9FC00CD4 a constant
    // index i produces a descending run starting at 31-i, so ours pins the
    // index at 0.
    //
    // KI's CPU is little-endian, so the byte at ROM address A is simply
    // rom[A - BFC00000] - which is where the 0x1D is, confirmed against
    // MAME for four separate addresses.
    //
    // So: read 32 bits at a time the way an uncached load does, and check both
    // the word and every byte inside it. The addresses cover the boot cache
    // (below 8 KiB, served from M10K) and beyond it (served through the ROM
    // line buffer), aligned and unaligned, because the bridge picks its 32-bit
    // half from operation_address[2] and the two paths choose it in different
    // places.
    $display("");
    $display("32-bit reads and byte extraction:");
    begin
      integer bad32;
      integer checked32;
      logic [31:0] got32;
      logic [31:0] want32;
      integer addr32;
      integer k;
      logic [7:0] want_byte;
      logic [7:0] got_byte;
      bad32 = 0;
      checked32 = 0;

      for (index = 0; index < 64; index = index + 1) begin
        // A spread that includes the exact addresses MAME reported, both
        // halves of a doubleword, and addresses past the 8 KiB boot cache.
        case (index)
          0: addr32 = 32'h11f8;
          1: addr32 = 32'h11e0;
          2: addr32 = 32'h120c;
          3: addr32 = 32'h11fc;
          4: addr32 = 32'h11dc;
          5: addr32 = 32'h0fdc;
          default: addr32 = (index * 32'h1a4) & 32'h7fffc;
        endcase
        if (addr32 + 3 >= DOWNLOAD_BYTES) addr32 = addr32 % (DOWNLOAD_BYTES - 4);
        addr32 = addr32 & ~32'd3;

        cpu_read32(BOOT_BASE + addr32, got32);
        want32 = {rom[addr32 + 3], rom[addr32 + 2],
                  rom[addr32 + 1], rom[addr32 + 0]};
        checked32 = checked32 + 1;
        if (got32 !== want32) begin
          if (bad32 < 8)
            $display("FAIL: 32-bit read at %05x = %08x, want %08x",
                     addr32, got32, want32);
          bad32 = bad32 + 1;
          errors = errors + 1;
        end else begin
          // Every byte inside the word, extracted the little-endian way the
          // CPU does. This is the actual quantity the field decoder consumes.
          for (k = 0; k < 4; k = k + 1) begin
            want_byte = rom[addr32 + k];
            got_byte = got32[k*8 +: 8];
            if (got_byte !== want_byte) begin
              if (bad32 < 8)
                $display("FAIL: byte at %05x = %02x, want %02x",
                         addr32 + k, got_byte, want_byte);
              bad32 = bad32 + 1;
              errors = errors + 1;
            end
          end
        end
      end
      $display("  %0d 32-bit reads, %0d errors", checked32, bad32);

      // The four addresses MAME reported, called out by name so a failure
      // names the measurement it contradicts rather than an offset.
      if (bad32 == 0) begin
        $display("  BFC011FB reads %02x (MAME: 1D)", rom[32'h11fb]);
        $display("  BFC011E3 reads %02x (MAME: 1C)", rom[32'h11e3]);
        $display("  BFC0120F reads %02x (MAME: 1E)", rom[32'h120f]);
        $display("  BFC011FE reads %02x (MAME: 1B)", rom[32'h11fe]);
      end
    end

    if (errors == 0)
      $display("PASS: ioctl ROM download is byte-exact through both paths");
    else
      $fatal(1, "FAIL: %0d download error(s)", errors);
    $finish;
  end

  initial begin
    #400000000;
    $display("FAIL: timeout, boot_loaded=%0b errors=%0d", boot_loaded, errors);
    $fatal(1);
  end

endmodule
`default_nettype wire
