// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// ki_memory_bridge against the REAL memory path: adapter, burst controller and
// a device model with a realistic access time.
//
// This verifies the burst contract against the production adapter and
// controller: beats arrive as consecutive data_valid pulses and done follows
// the last of them.
//
// It also produces the number that matters: sustained ns/word for a 32-byte
// cache-line fill, measured through the bridge, against the 203 ns/word the
// framebuffer scanout needs.
module tb_ki_memory_bridge_sdram;
  localparam real TCK = 20.0;
  localparam real SCANOUT_BUDGET_NS = 203.0;
  localparam real SINGLE_WORD_BASELINE_NS = 242.8;
  // 320 words per visible line x 240 lines, four words per 64-bit store.
  localparam real FULL_CLEAR_STORES = 320.0 * 240.0 / 4.0;
  localparam real FRAME_MS = 16.7;

  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  integer errors = 0;

  always #(TCK / 2.0) clk = ~clk;
  always #(TCK / 4.0) ddr_clk = ~ddr_clk;

  // The SDRAM device clock is the phase-shifted pin clock, as on hardware.
  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  logic cpu_request = 1'b0;
  logic cpu_rnw = 1'b1;
  logic [31:0] cpu_address = 32'd0;
  logic cpu_req64 = 1'b0;
  logic [2:0] cpu_size = 3'd1;
  logic [7:0] cpu_write_mask = 8'd0;
  logic [63:0] cpu_data_write = 64'd0;
  wire [63:0] cpu_data_read;
  wire cpu_done;
  wire cpu_grant;
  wire [63:0] cpu_cache_data;
  wire cpu_cache_data_ready;

  wire io_request;
  wire io_write;
  wire [31:0] io_address;
  wire [31:0] io_write_data;
  wire [3:0] io_byte_enable;
  logic [31:0] io_read_data = 32'd0;
  wire io_done;
  assign io_done = io_request;

  logic ioctl_download = 1'b0;
  logic ioctl_wr = 1'b0;
  logic [15:0] ioctl_index = 16'd0;
  logic [26:0] ioctl_addr = 27'd0;
  logic [15:0] ioctl_dout = 16'd0;
  wire ioctl_wait;
  wire boot_loaded;

  logic video_request = 1'b0;
  logic [27:0] video_address = 28'd0;
  logic [2:0] video_words = 3'd1;
  wire [63:0] video_data;
  wire video_data_valid;
  wire video_done;

  wire [24:0] bridge_address;
  wire [63:0] bridge_write_data;
  wire  [7:0] bridge_byte_enable;
  wire  [4:0] bridge_burst;
  wire bridge_read, bridge_write;
  wire [15:0] bridge_read_data;
  wire bridge_data_valid, bridge_done;
  wire sdram_ready;

  wire [24:0] controller_address;
  wire [63:0] controller_write_data;
  wire  [7:0] controller_byte_enable;
  wire  [4:0] controller_burst;
  wire controller_read, controller_write;
  wire [15:0] controller_read_data;
  wire controller_dout_valid, controller_ready;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire SDRAM_DQML, SDRAM_DQMH;
  wire [1:0] SDRAM_BA;
  wire SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

  // The DCS/DDR3 path is not under test here.
  wire [7:0] ddram_burstcnt;
  wire [28:0] ddram_addr;
  wire ddram_rd, ddram_we;
  wire [63:0] ddram_din;
  wire [7:0] ddram_be;

  wire [2:0] debug_state;
  wire debug_cpu_pending;
  wire [31:0] debug_last_write_address;
  wire [63:0] debug_last_write_data;
  wire [31:0] debug_last_write_info;
  wire [31:0] debug_write_count;
  wire [31:0] debug_low_write_count;
  wire [31:0] debug_main_write_count;
  wire [31:0] debug_main_write0;
  wire [31:0] debug_main_write1;
  wire [31:0] debug_main_write2;

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
    .io_read_data(io_read_data), .io_done(io_done),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .boot_loaded(boot_loaded),
    .dcs_rom_request(1'b0), .dcs_rom_address(19'd0),
    .dcs_rom_ready(), .dcs_rom_data(),
    .video_request(video_request), .video_address(video_address),
    .video_words(video_words),
    .video_data(video_data), .video_data_valid(video_data_valid),
    .video_done(video_done),
    .sdram_address(bridge_address), .sdram_write_data(bridge_write_data),
    .sdram_byte_enable(bridge_byte_enable), .sdram_burst(bridge_burst),
    .sdram_read(bridge_read), .sdram_write(bridge_write),
    .sdram_read_data(bridge_read_data),
    .sdram_data_valid(bridge_data_valid), .sdram_done(bridge_done),
    .sdram_ready(sdram_ready),
    .ddram_busy(1'b0), .ddram_burstcnt(ddram_burstcnt), .ddram_addr(ddram_addr),
    .ddram_dout(64'd0), .ddram_dout_ready(1'b0),
    .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
    .ddram_we(ddram_we),
    .fb_read_accept(), .fb_write_accept(),
    .debug_state(debug_state), .debug_cpu_pending(debug_cpu_pending),
    .debug_fill_b0(), .debug_fill_b1(),
    .debug_last_write_address(debug_last_write_address),
    .debug_last_write_data(debug_last_write_data),
    .debug_last_write_info(debug_last_write_info),
    .debug_write_count(debug_write_count),
    .debug_low_write_count(debug_low_write_count),
    .debug_main_write_count(debug_main_write_count),
    .debug_main_write0(debug_main_write0),
    .debug_main_write1(debug_main_write1),
    .debug_main_write2(debug_main_write2),
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

  // Cache-fill beats are latched as they stream past because
  // cpu_cache_data_ready precedes cpu_done.
  logic [63:0] beat [0:7];
  integer beat_n;
  always @(posedge clk) begin
    if (cpu_cache_data_ready) begin
      if (beat_n < 8) beat[beat_n] <= cpu_cache_data;
      beat_n <= beat_n + 1;
    end
  end

  integer store_requests = 0;
  integer read_requests = 0;
  integer rom_requests_before = 0;
  integer rom_line_requests = 0;

  // Measure the three parts of a burst:
  //
  //   setup   request -> first beat   ACTIVE + tRCD + CAS, plus the adapter
  //                                   handshake. Mostly SDRAM-clock work.
  //   stream  first beat -> last beat one word per clock out of the CAS pipe.
  //   finish  last beat -> cpu_done   drain, adapter ACK, bridge completion.
  //
  // ki_memory_bridge samples sdram_data_valid on posedge clk, one beat per
  // clk_core cycle.
  time t_request = 0;
  time t_first_beat = 0;
  time t_last_beat = 0;
  integer beats_seen = 0;

  always @(posedge clk) begin
    if (bridge_read) begin
      t_request = $time;
      beats_seen = 0;
    end
  end

  // Watch the CONTROLLER's beat output, not the bridge's, so this measures
  // when the data was available rather than when the bridge got round to it.
  always @(posedge clk) begin
    if (controller_dout_valid) begin
      if (beats_seen == 0) t_first_beat = $time;
      t_last_beat = $time;
      beats_seen = beats_seen + 1;
    end
  end

  // Accumulated across many operations. A single sample is not enough: a
  // refresh landing inside one transaction moves its setup phase by hundreds
  // of nanoseconds, and reading one sample as the typical case is how this
  // project has repeatedly convinced itself of the wrong thing.
  real acc_setup = 0.0;
  real acc_stream = 0.0;
  real acc_finish = 0.0;
  integer acc_n = 0;
  real worst_stream = 0.0;

  task automatic accumulate_phases(input integer words, input time t_done);
    begin
      if (beats_seen != words) begin
        $error("phase sample saw %0d beats, expected %0d", beats_seen, words);
        errors = errors + 1;
      end
      acc_setup  = acc_setup  + (t_first_beat - t_request) * 1.0;
      acc_stream = acc_stream + (t_last_beat - t_first_beat) * 1.0;
      acc_finish = acc_finish + (t_done - t_last_beat) * 1.0;
      if (((t_last_beat - t_first_beat) * 1.0) > worst_stream)
        worst_stream = (t_last_beat - t_first_beat) * 1.0;
      acc_n = acc_n + 1;
    end
  endtask

  task automatic report_phases(input string label, input integer words);
    real setup_ns, stream_ns, finish_ns, floor_ns;
    begin
      setup_ns  = acc_setup  / acc_n;
      stream_ns = acc_stream / acc_n;
      finish_ns = acc_finish / acc_n;
      // N beats need N clk_core cycles to be assembled; the interval measured
      // spans the first beat to the last, so it is N-1 cycles.
      floor_ns = (words - 1) * 20.0;
      $display("  %-17s %2d beats  setup %5.1f  stream %5.1f  finish %5.1f  total %5.1f ns  (mean of %0d)",
               label, words, setup_ns, stream_ns, finish_ns,
               setup_ns + stream_ns + finish_ns, acc_n);
      $display("                    stream floor at 50 MHz clk_core %.0f ns, worst sample %.0f",
               floor_ns, worst_stream);
      // A positive statement about work done, not the absence of a failure.
      // If the stream phase sits AT the clk_core floor then the bridge is what
      // limits beat delivery and no controller speed can recover that time -
      // which is the whole question this measurement exists to settle. Below
      // the floor would mean the bridge could not have assembled the beats.
      if (stream_ns < floor_ns) begin
        $error("%s streamed a mean %0.1f ns for %0d beats, below the %0.0f ns clk_core floor - the bridge cannot have assembled them",
               label, stream_ns, words, floor_ns);
        errors = errors + 1;
      end
      acc_setup = 0.0; acc_stream = 0.0; acc_finish = 0.0;
      acc_n = 0; worst_stream = 0.0;
    end
  endtask

  // The bridge must never hand the controller a burst that runs off the end of
  // a 512-word row: ki_sdram_burst walks columns without re-ACTIVATEing, so it
  // would wrap to the start of the same row and return the wrong data.
  always @(posedge clk) begin
    if (bridge_read || bridge_write) begin
      if (({1'b0, bridge_address[8:0]} + {5'd0, bridge_burst}) > 10'd512) begin
        $error("%s burst of %0d from word 0x%h crosses a 512-word row",
               bridge_read ? "read" : "write", bridge_burst, bridge_address);
        errors = errors + 1;
      end
    end
    if (bridge_read) read_requests <= read_requests + 1;
    if (bridge_write) begin
      store_requests <= store_requests + 1;
      if (bridge_burst > 4) begin
        $error("write burst of %0d exceeds the controller's 4-word payload",
               bridge_burst);
        errors = errors + 1;
      end
    end
  end

  task automatic cpu_op;
    integer timeout;
    begin
      beat_n = 0;
      @(posedge clk);
      cpu_request <= 1'b1;
      @(posedge clk);
      cpu_request <= 1'b0;
      timeout = 0;
      while (!cpu_done) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 20000) $fatal(1, "CPU transaction timed out");
      end
      @(posedge clk);
    end
  endtask

  task automatic write64(input logic [31:0] a, input logic [63:0] d);
    begin
      cpu_rnw <= 1'b0; cpu_address <= a; cpu_req64 <= 1'b1;
      cpu_size <= 3'd1; cpu_write_mask <= 8'hff; cpu_data_write <= d;
      cpu_op();
    end
  endtask

  task automatic read_line(input logic [31:0] a);
    begin
      cpu_rnw <= 1'b1; cpu_address <= a; cpu_req64 <= 1'b1;
      cpu_size <= 3'd4; cpu_write_mask <= 8'd0;
      cpu_op();
    end
  endtask

  task automatic read64(input logic [31:0] a);
    begin
      cpu_rnw <= 1'b1; cpu_address <= a; cpu_req64 <= 1'b1;
      cpu_size <= 3'd1; cpu_write_mask <= 8'd0;
      cpu_op();
    end
  endtask

  task automatic read32(input logic [31:0] a);
    begin
      cpu_rnw <= 1'b1; cpu_address <= a; cpu_req64 <= 1'b0;
      cpu_size <= 3'd1; cpu_write_mask <= 8'd0;
      cpu_op();
    end
  endtask

  function automatic logic [63:0] pattern(input integer index);
    return {32'hCAFE_0000 + index[31:0], 32'h1234_0000 + index[31:0]};
  endfunction

  // One 16-bit boot-cache seed word. A function, not an inline expression,
  // because operands inside a concatenation are self-determined: written as
  // `16'hB000 + (i[15:0] * 4)` the multiply is 32 bits wide, so the sum is 32
  // bits and contributes FOUR bytes to the concatenation instead of two. That
  // silently shifts every word and the first version of this seeding read back
  // 0000B000 where B001B000 was expected.
  function automatic logic [15:0] boot_seed(input integer n);
    return 16'hB000 + n[15:0];
  endfunction

  integer i, t0, t1;
  real ns_per_word;
  real ns_per_store;
  real full_clear_ms;

  initial begin
    beat_n = 0;
    repeat (4) @(posedge clk);
    init = 1'b0;
    wait (sdram_ready);
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    $display("");
    $display("ki_memory_bridge -> ki_sdram_adapter -> ki_sdram_burst -> device");
    $display("");

    // Low RAM, 0x000..0x07F: sixteen 64-bit words, four 32-byte cache lines.
    for (i = 0; i < 16; i = i + 1)
      write64(32'h0000_0000 + (i * 8), pattern(i));

    // A 32-byte line is four 64-bit beats and must arrive in address order.
    read_line(32'h0000_0000);
    if (beat_n != 4) begin
      $error("cache line returned %0d beats, expected 4", beat_n);
      errors = errors + 1;
    end else begin
      for (i = 0; i < 4; i = i + 1)
        if (beat[i] !== pattern(i)) begin
          $error("cache line beat %0d: got %h expected %h",
                 i, beat[i], pattern(i));
          errors = errors + 1;
        end
      if (errors == 0) $display("  32-byte cache line: 4 beats, data OK");
    end

    read_line(32'h0000_0040);
    if (beat[0] !== pattern(8) || beat[3] !== pattern(11)) begin
      $error("second cache line returned %h..%h", beat[0], beat[3]);
      errors = errors + 1;
    end else begin
      $display("  second cache line at +0x40: data OK");
    end

    read64(32'h0000_0018);
    if (cpu_data_read !== pattern(3)) begin
      $error("64-bit read returned %h, expected %h",
             cpu_data_read, pattern(3));
      errors = errors + 1;
    end else begin
      $display("  64-bit read: data OK");
    end

    read32(32'h0000_0018);
    if (cpu_data_read[31:0] !== pattern(3)[31:0]) begin
      $error("32-bit read returned %h, expected %h",
             cpu_data_read[31:0], pattern(3)[31:0]);
      errors = errors + 1;
    end else begin
      $display("  32-bit read: data OK");
    end

    read32(32'h0000_001c);
    if (cpu_data_read[31:0] !== pattern(3)[63:32]) begin
      $error("32-bit read of the upper half returned %h, expected %h",
             cpu_data_read[31:0], pattern(3)[63:32]);
      errors = errors + 1;
    end else begin
      $display("  32-bit read, upper half: data OK");
    end

    // Scanout takes the same words through the video port.
    video_address <= 28'h000_0010;
    video_request <= 1'b1;
    @(posedge clk);
    while (!video_done) @(posedge clk);
    video_request <= 1'b0;
    if (video_data !== pattern(2)) begin
      $error("scanout fetch returned %h, expected %h", video_data, pattern(2));
      errors = errors + 1;
    end else begin
      $display("  scanout fetch: data OK");
    end
    @(posedge clk);

    // A cache line is only 4-word aligned, so it can start at word 500 of a
    // 512-word row and run past the end. Byte 0x3E8 does exactly that; the
    // bridge has to split it into 12 + 4 words.
    for (i = 0; i < 4; i = i + 1)
      write64(32'h0000_03e8 + (i * 8), pattern(100 + i));
    read_line(32'h0000_03e8);
    if (beat_n != 4) begin
      $error("row-crossing line returned %0d beats, expected 4", beat_n);
      errors = errors + 1;
    end else begin
      for (i = 0; i < 4; i = i + 1)
        if (beat[i] !== pattern(100 + i)) begin
          $error("row-crossing beat %0d: got %h expected %h",
                 i, beat[i], pattern(100 + i));
          errors = errors + 1;
        end
      $display("  row-crossing cache line (word 500, 12+4 split): data OK");
    end

    // Sustained cache-line throughput as the CPU sees it.
    t0 = $time;
    for (i = 0; i < 32; i = i + 1) read_line(32'h0000_0000);
    t1 = $time;
    ns_per_word = (t1 - t0) * 1.0 / (32.0 * 16.0);
    $display("");
    $display("  cache-line fill:  %6.1f ns/word   (%.1f ns per 32-byte line)",
             ns_per_word, ns_per_word * 16.0);

    t0 = $time;
    for (i = 0; i < 32; i = i + 1) read64(32'h0000_0000);
    t1 = $time;
    $display("  64-bit read:      %6.1f ns/word",
             (t1 - t0) * 1.0 / (32.0 * 4.0));

    // ---- burst phase timing ----
    $display("");
    $display("  Burst time split:");
    for (i = 0; i < 32; i = i + 1) begin
      read_line(32'h0000_0000);
      accumulate_phases(16, $time);
    end
    report_phases("cache line (16w)", 16);
    for (i = 0; i < 32; i = i + 1) begin
      read64(32'h0000_0000);
      accumulate_phases(4, $time);
    end
    report_phases("64-bit read (4w)", 4);
    for (i = 0; i < 32; i = i + 1) begin
      read32(32'h0000_0000);
      accumulate_phases(2, $time);
    end
    report_phases("32-bit read (2w)", 2);

    // Store throughput, and what it means for the framebuffer. Hardware showed
    // the clear could only reach ~1/3 of the screen before the game restarted
    // it, which is what a full-screen clear costing more than a frame looks
    // like. FULL_CLEAR_STORES is 320 words x 240 lines / 4 words per store.
    t0 = $time;
    for (i = 0; i < 32; i = i + 1)
      write64(32'h0000_0000 + (i * 8), pattern(i));
    t1 = $time;
    ns_per_store = (t1 - t0) * 1.0 / 32.0;
    full_clear_ms = ns_per_store * FULL_CLEAR_STORES / 1_000_000.0;
    $display("");
    $display("  64-bit store:     %6.1f ns        (%.1f ns/word)",
             ns_per_store, ns_per_store / 4.0);
    $display("  full-screen clear: %5.1f ms       frame is %.1f ms, CPU gets ~55%%",
             full_clear_ms, FRAME_MS);
    if (full_clear_ms > (FRAME_MS * 0.55)) begin
      $error("a full-screen clear costs %.1f ms but the CPU only gets ~%.1f ms per frame, so it cannot finish",
             full_clear_ms, FRAME_MS * 0.55);
      errors = errors + 1;
    end

    t0 = $time;
    for (i = 0; i < 32; i = i + 1) begin
      video_address <= 28'h000_0000;
      video_request <= 1'b1;
      @(posedge clk);
      while (!video_done) @(posedge clk);
      video_request <= 1'b0;
      @(posedge clk);
    end
    t1 = $time;
    $display("  scanout fetch:    %6.1f ns/word   budget %.1f",
             (t1 - t0) * 1.0 / (32.0 * 4.0), SCANOUT_BUDGET_NS);
    $display("  single-word baseline before bursting: %.1f ns/word",
             SINGLE_WORD_BASELINE_NS);

    if (ns_per_word >= SCANOUT_BUDGET_NS) begin
      $error("cache-line fill (%.1f ns/word) is still over the scanout budget (%.1f)",
             ns_per_word, SCANOUT_BUDGET_NS);
      errors = errors + 1;
    end

    // ---- boot-ROM line buffer ----
    // The boot decompressor reads the ROM one BYTE at a time through KSEG1,
    // which MIPS defines as uncached, so the CPU data cache correctly does not
    // absorb it. The bridge caches the ROM instead - safe because it is
    // immutable - and this is the traffic that decides boot time.
    //
    // Two things this test has to get right, both of which caught me out:
    //   * the address must be BEYOND the 8 KiB M10K cache, or the existing
    //     boot cache answers and the line buffer never runs;
    //   * CPU writes to boot addresses are deliberately DISCARDED by the
    //     bridge, so the ROM image has to be seeded into the device model
    //     directly. Under this controller a bridge word address W maps to
    //     {bank,row,col} = W[23:0], so the model key is just W.
    for (i = 0; i < 32; i = i + 1)
      memory.mem[{8'd0, 24'h4a0000 + i[23:0]}] = 16'hB000 + i[15:0];

    // 0x1FC40000 is ROM offset 0x40000, well past the cache. Eight
    // consecutive 32-bit reads span exactly one 16-word line.
    // Sample AFTER the line is resident, so the measurement cannot pick up a
    // stray request left in flight by whatever ran before this.
    read32(32'h1fc4_0000);
    if (cpu_data_read[31:0] !== 32'h_B001_B000) begin
      $error("first boot-ROM read returned %h, expected B001B000",
             cpu_data_read[31:0]);
      errors = errors + 1;
    end

    rom_requests_before = read_requests;
    t0 = $time;
    for (i = 0; i < 8; i = i + 1) read32(32'h1fc4_0000 + (i * 4));
    t1 = $time;
    rom_line_requests = read_requests - rom_requests_before;
    $display("");
    $display("  boot-ROM walk: 8 reads inside a resident line cost %0d SDRAM request(s), %.0f ns each",
             rom_line_requests, (t1 - t0) * 1.0 / 8.0);
    if (rom_line_requests != 0) begin
      $error("8 reads inside a resident line issued %0d SDRAM requests, expected 0",
             rom_line_requests);
      errors = errors + 1;
    end
    if (cpu_data_read[31:0] !== 32'h_B00F_B00E) begin
      $error("last read of the line returned %h, expected B00FB00E",
             cpu_data_read[31:0]);
      errors = errors + 1;
    end

    // ---- the same walk against the resident M10K boot cache ----
    // The first 8 KiB of the ROM is in boot_cache, so the SDRAM line-buffer
    // and on-chip paths can be timed side by side.
    //
    // Seeded by poking boot_cache directly. The bridge deliberately discards
    // CPU writes to boot addresses, and the ioctl download path is not what is
    // under test here. Index is active_address[12:3], so 0x1FC00100 is
    // boot_cache[0x20].
    for (i = 0; i < 8; i = i + 1)
      bridge.boot_cache[12'h020 + i[11:0]] =
          {boot_seed(4*i + 3), boot_seed(4*i + 2),
           boot_seed(4*i + 1), boot_seed(4*i)};

    read32(32'h1fc0_0100);
    if (cpu_data_read[31:0] !== 32'h_B001_B000) begin
      $error("first boot-cache read returned %h, expected B001B000",
             cpu_data_read[31:0]);
      errors = errors + 1;
    end

    rom_requests_before = read_requests;
    t0 = $time;
    for (i = 0; i < 8; i = i + 1) read32(32'h1fc0_0100 + (i * 4));
    t1 = $time;
    $display("  boot-cache (M10K) walk: 8 reads cost %0d SDRAM request(s), %.0f ns each",
             read_requests - rom_requests_before, (t1 - t0) * 1.0 / 8.0);
    if ((read_requests - rom_requests_before) != 0) begin
      $error("8 reads inside the M10K boot cache issued %0d SDRAM requests, expected 0",
             read_requests - rom_requests_before);
      errors = errors + 1;
    end
    // Eight 32-bit reads from 0x1FC00100 span four qwords (boot_cache[0x20]
    // through [0x23]), so the last one is the high half of [0x23] = words
    // 15 and 14.
    if (cpu_data_read[31:0] !== 32'h_B00F_B00E) begin
      $error("last boot-cache read returned %h, expected B00FB00E",
             cpu_data_read[31:0]);
      errors = errors + 1;
    end

    // The next line must MISS and refill rather than serve the previous one.
    rom_requests_before = read_requests;
    read32(32'h1fc4_0020);
    if (cpu_data_read[31:0] !== 32'h_B011_B010) begin
      $error("second line returned %h, expected B011B010", cpu_data_read[31:0]);
      errors = errors + 1;
    end else if ((read_requests - rom_requests_before) != 1) begin
      $error("crossing into the next line issued %0d SDRAM requests, expected 1",
             read_requests - rom_requests_before);
      errors = errors + 1;
    end else begin
      $display("  boot-ROM line buffer: data OK, next line refills");
    end

    // A 64-bit read inside a cached line must also be served from it.
    rom_requests_before = read_requests;
    read64(32'h1fc4_0028);
    if (cpu_data_read !== 64'h_B017_B016_B015_B014) begin
      $error("64-bit read from the line returned %h, expected B017B016B015B014",
             cpu_data_read);
      errors = errors + 1;
    end else if ((read_requests - rom_requests_before) != 0) begin
      $error("64-bit read inside a cached line issued %0d SDRAM requests, expected 0",
             read_requests - rom_requests_before);
      errors = errors + 1;
    end else begin
      $display("  boot-ROM line buffer: 64-bit read served from the line");
    end

    $display("");
    if (errors == 0) $display("tb_ki_memory_bridge_sdram: PASS");
    else $display("tb_ki_memory_bridge_sdram: FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #40_000_000;
    $display("tb_ki_memory_bridge_sdram: FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule

`default_nettype wire
