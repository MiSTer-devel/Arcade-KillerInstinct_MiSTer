// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// Does the framebuffer put the right pixel on the screen, at the right time,
// while the CPU works the same bus?
//
// This is the gap tb_ki_video_scanout left open. That bench drives
// video_address itself, so it proves the bridge returns what was asked for but
// says nothing about the module that decides WHAT to ask for or WHEN. The
// hardware symptom - blue covering only part of each line, left edge shifting
// per line - is a fetch that has not landed by the time its line displays, and
// that is a property of ki_framebuffer plus the real bus, together.
//
// So this runs the whole chain at real rates:
//
//   ki_video_timing -> ki_framebuffer -> ki_memory_bridge -> ki_sdram_adapter
//                   -> ki_sdram_burst -> mt48lc16m16_ki (TAC_NS=6.0)
//
// and checks every visible pixel of a run of lines against known memory
// contents, sampled on ce_pixel exactly where the scaler samples it. A pixel
// that is merely LATE fails as loudly as a pixel that is wrong: pixel_valid low
// inside the visible area is counted, because that is precisely the black that
// eats the left of each line on hardware.
module tb_ki_framebuffer_fetch;
  import ki_board_pkg::*;

  localparam real TCK = 20.0;                     // 50 MHz core clock
  localparam int H_TOTAL = 406;
  localparam int V_TOTAL = 261;
  localparam int H_VISIBLE = 320;
  localparam real SCANLINE_NS = H_TOTAL * 8.0 * TCK;   // ~64.96 us

  // Lines seeded and swept. 0 is partially black (its fetch only starts when
  // reset releases) and 1 is black (nothing queued it - the frame's first
  // prefetch tick queues line 2), so checking starts at 2. Both are first-frame
  // artifacts of a cold start, not steady-state behaviour.
  localparam int FIRST_CHECKED_LINE = 2;
  localparam int CONTENDED_FROM_LINE = 8;
  localparam int LAST_CHECKED_LINE = 13;
  localparam int SEEDED_LINES = LAST_CHECKED_LINE + 1;

  localparam logic [31:0] CPU_RAM = 32'h0005_8000;

  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;

  // The bridge leaves reset before the raster does, so the framebuffer can be
  // seeded through its CPU write port while scanout is still held. Seeding used
  // to poke storage directly, which worked under reset; writing through the
  // port does not, and holding both resets together made the bench sit in the
  // seed loop until its timeout with checked=0.
  logic bridge_reset = 1'b1;
  logic init = 1'b1;

  always #(TCK / 2.0) clk = ~clk;
  always #(TCK / 4.0) ddr_clk = ~ddr_clk;
  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  // ---- raster ------------------------------------------------------------
  wire       ce_pixel;
  wire [9:0] h_count;
  wire [9:0] v_count;

  ki_video_timing timing (
    .clk(clk), .reset(reset), .ce_pixel(ce_pixel),
    .h_count(h_count), .v_count(v_count),
    .display_enable(), .hsync_n(), .vsync_n(), .vblank(),
    .frame_start(), .vblank_count(), .vblank_seen(), .max_v_count()
  );

  // ---- framebuffer -------------------------------------------------------
  wire        video_request;
  wire [27:0] video_address;
  wire  [2:0] video_words;
  wire [63:0] video_data;
  wire        video_data_valid;
  wire        video_done;
  wire  [7:0] red, green, blue;
  wire        pixel_valid;

  ki_framebuffer framebuffer (
    .clk(clk), .reset(reset), .ce_pixel(ce_pixel),
    .h_count(h_count), .v_count(v_count),
    .framebuffer_base(KI_FB_PAGE0),
    .memory_request(video_request), .memory_address(video_address),
    .memory_words(video_words), .memory_data(video_data),
    .memory_data_valid(video_data_valid), .memory_done(video_done),
    .red(red), .green(green), .blue(blue), .pixel_valid(pixel_valid)
  );

  // ---- CPU port ----------------------------------------------------------
  logic        cpu_request = 1'b0;
  logic        cpu_rnw = 1'b1;
  logic [31:0] cpu_address = 32'd0;
  logic        cpu_req64 = 1'b0;
  logic  [2:0] cpu_size = 3'd1;
  logic  [7:0] cpu_write_mask = 8'd0;
  logic [63:0] cpu_data_write = 64'd0;
  wire  [63:0] cpu_data_read;
  wire         cpu_done, cpu_grant;
  wire [63:0]  cpu_cache_data;
  wire         cpu_cache_data_ready;

  // ---- memory path -------------------------------------------------------
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

  ki_memory_bridge bridge (
    .clk(clk), .ddr_clk(ddr_clk), .reset(bridge_reset),
    // Tied off: this bench checks the GAME's path, not the core pattern.
    .fb_read_accept(), .fb_write_accept(),
    .cpu_request(cpu_request), .cpu_rnw(cpu_rnw),
    .cpu_address(cpu_address), .cpu_req64(cpu_req64), .cpu_size(cpu_size),
    .cpu_write_mask(cpu_write_mask), .cpu_data_write(cpu_data_write),
    .cpu_data_read(cpu_data_read), .cpu_done(cpu_done), .cpu_grant(cpu_grant),
    .cpu_cache_data(cpu_cache_data),
    .cpu_cache_data_ready(cpu_cache_data_ready),
    .io_request(), .io_write(), .io_address(),
    .io_write_data(), .io_byte_enable(),
    .io_read_data(32'd0), .io_done(1'b0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_index(16'd0),
    .ioctl_addr(27'd0), .ioctl_dout(16'd0), .ioctl_wait(), .boot_loaded(),
    .video_request(video_request), .video_address(video_address),
    .video_words(video_words), .video_data(video_data),
    .video_data_valid(video_data_valid), .video_done(video_done),
    .sdram_address(bridge_address), .sdram_write_data(bridge_write_data),
    .sdram_byte_enable(bridge_byte_enable), .sdram_burst(bridge_burst),
    .sdram_read(bridge_read), .sdram_write(bridge_write),
    .sdram_read_data(bridge_read_data),
    .sdram_data_valid(bridge_data_valid), .sdram_done(bridge_done),
    .sdram_ready(sdram_ready),
    .ddram_busy(1'b0), .ddram_burstcnt(), .ddram_addr(),
    .ddram_dout(64'd0), .ddram_dout_ready(1'b0),
    .ddram_rd(), .ddram_din(), .ddram_be(), .ddram_we(),
    .debug_state(), .debug_cpu_pending(),
    .debug_last_write_address(), .debug_last_write_data(),
    .debug_last_write_info(), .debug_write_count(),
    .debug_low_write_count(), .debug_main_write_count(),
    .debug_main_write0(), .debug_main_write1(), .debug_main_write2(),
    .debug_table_write_count(), .debug_table_write_address(),
    .debug_table_write_data()
  );

  ki_sdram_adapter adapter (
    .clk(clk), .reset(1'b0),
    .request_address(bridge_address), .request_write_data(bridge_write_data),
    .request_byte_enable(bridge_byte_enable), .request_burst(bridge_burst),
    .request_read(bridge_read), .request_write(bridge_write),
    .request_read_data(bridge_read_data),
    .request_data_valid(bridge_data_valid), .request_done(bridge_done),
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

  // ---- expected contents -------------------------------------------------
  // Unique per (line, x) so a shifted, repeated or dropped word is unmistakable
  // rather than merely "some wrong colour".
  function automatic logic [15:0] expect_pixel(input integer line,
                                               input integer x);
    expect_pixel = 16'((line * H_VISIBLE + x) & 32'h7fff);
  endfunction

  // The 16-bit device word holding pixel (line, x). Composing the three address
  // spaces: the framebuffer's byte address >> 3 is the bridge's qword, the
  // bridge issues word index qword*4, and word w lands at device key
  // {8'd0, w[23:0]} (see the adapter's {addr,1'b0} and the controller's split).
  function automatic logic [23:0] word_index(input integer line,
                                             input integer x);
    logic [27:0] line_base;
    begin
      line_base = {9'd0, KI_FB_PAGE0} + 28'(line * 640);
      word_index = 24'(((line_base >> 3) * 4) + x);
    end
  endfunction

  // Seed one 16-bit pixel into the on-chip framebuffer.
  //
  // The store is eight byte-wide RAMs rather than one 64-bit array, because the
  // 64-bit form does not infer block RAM in Quartus 17.0 (see the note in
  // ki_memory_bridge.sv). A pixel therefore straddles two adjacent byte lanes
  // of one 64-bit word, and the bench has to place both halves itself.
  // Write one 64-bit word - four pixels - into the framebuffer through the
  // bridge's CPU port. w_index is a 16-bit-word index into storage, so the byte
  // address is twice it; a 4-word-aligned index is therefore 8-byte aligned,
  // which every call site satisfies because H_VISIBLE is a multiple of four.
  task automatic fb_write_qword(input logic [23:0] w_index,
                                input logic [63:0] value);
    begin
      @(posedge clk);
      cpu_address    <= 32'(w_index) * 32'd2;
      cpu_rnw        <= 1'b0;
      cpu_req64      <= 1'b1;
      cpu_size       <= 3'd1;
      cpu_write_mask <= 8'hff;
      cpu_data_write <= value;
      cpu_request    <= 1'b1;
      @(posedge clk);
      cpu_request    <= 1'b0;
      while (!cpu_done) @(posedge clk);
    end
  endtask

  // ---- checking ----------------------------------------------------------
  integer colour_errors = 0;
  integer blank_pixels = 0;
  integer checked = 0;
  integer reported = 0;
  integer first_blank_line = -1;
  integer first_blank_x = -1;

  always @(negedge clk) begin
    logic [15:0] want;
    if (!reset && ce_pixel && (h_count < H_VISIBLE) &&
        (v_count >= FIRST_CHECKED_LINE) && (v_count <= LAST_CHECKED_LINE)) begin
      checked = checked + 1;
      want = expect_pixel(v_count, h_count);
      if (!pixel_valid) begin
        blank_pixels = blank_pixels + 1;
        if (first_blank_line < 0) begin
          first_blank_line = v_count;
          first_blank_x = h_count;
        end
      end else if ((red !== {want[4:0], want[4:2]}) ||
                   (green !== {want[9:5], want[9:7]}) ||
                   (blue !== {want[14:10], want[14:12]})) begin
        colour_errors = colour_errors + 1;
        if (reported < 10) begin
          reported = reported + 1;
          $display("FAIL: line %0d x %0d = %02h/%02h/%02h, want pixel %04h",
                   v_count, h_count, red, green, blue, want);
        end
      end
    end
  end

  // ---- line fetch timing -------------------------------------------------
  // The number that decides whether a line can be drawn at all: wall time from
  // the framebuffer starting a line fetch to all 80 words having landed,
  // against one scanline.
  logic fetch_active_d = 1'b0;
  real  fetch_start = 0.0;
  real  worst_fetch = 0.0;
  real  total_fetch = 0.0;
  integer fetches = 0;
  integer requests = 0;

  always @(negedge clk) begin
    if (video_request && video_done) requests = requests + 1;
    if (framebuffer.fetch_active && !fetch_active_d)
      fetch_start = $realtime;
    if (!framebuffer.fetch_active && fetch_active_d && !reset) begin
      fetches = fetches + 1;
      total_fetch = total_fetch + ($realtime - fetch_start);
      if (($realtime - fetch_start) > worst_fetch)
        worst_fetch = $realtime - fetch_start;
    end
    fetch_active_d <= framebuffer.fetch_active;
  end

  // ---- CPU contention ----------------------------------------------------
  // The mix the framebuffer clear actually produces: 32-byte cache-line reads
  // and 64-bit stores, back to back, on a different region of the same bus.
  logic cpu_traffic_enable = 1'b0;
  integer cpu_ops = 0;
  // The RMW sweep covers the seeded, checked region of page 0 - the page
  // scanout is displaying.
  localparam logic [31:0] RMW_BASE  = {13'd0, KI_FB_PAGE0};
  localparam int          RMW_LINES = (SEEDED_LINES * 640) / 32;
  logic [31:0] rmw_base = 32'd0;
  logic [63:0] rmw_line [0:3];
  integer      rmw_beats_seen = 0;

  initial begin : cpu_traffic
    forever begin
      @(posedge clk);
      if (cpu_traffic_enable) begin
        // READ-MODIFY-WRITE ON THE PAGE BEING SCANNED.
        //
        // This is what the game actually does and what no bench has ever
        // reproduced. Hardware evidence: FR reads 26DF9A6D, so the game
        // performs ~9,951 framebuffer reads per frame against 39,533 writes;
        // the banding is absent during video playback, which writes pixels
        // straight out without reading; and it is present in scenes that
        // composite sprites over a background, which must read it first.
        //
        // Every other bench keeps the two apart - CPU traffic went to page 1
        // while scanout read page 0, or ran with no scanout in flight at all.
        // Port A reading an address while port B reads the same region, with
        // port A writes interleaved, is the one combination never exercised,
        // and every component has now been proven correct in isolation.
        //
        // A line is fetched as the data cache fetches it - one 32-byte read -
        // and written back UNCHANGED, qword by qword. If the path is correct
        // the memory is left exactly as it was and the pixel checker still
        // passes. If a read returns the wrong data, the write-back commits it,
        // and the corruption shows up as wrong pixels - which is precisely the
        // hardware failure, where bad reads are modified and stored back.
        rmw_base = RMW_BASE + ((cpu_ops % RMW_LINES) * 32);

        rmw_beats_seen = 0;
        cpu_address    <= rmw_base;
        cpu_rnw        <= 1'b1;
        cpu_req64      <= 1'b1;
        cpu_size       <= 3'd4;
        cpu_request    <= 1'b1;
        @(posedge clk);
        cpu_request    <= 1'b0;
        while (!cpu_done) @(posedge clk);
        repeat (2) @(posedge clk);

        // Write the same four qwords straight back.
        for (int qw = 0; qw < 4; qw++) begin
          cpu_address    <= rmw_base + (qw * 8);
          cpu_rnw        <= 1'b0;
          cpu_req64      <= 1'b1;
          cpu_size       <= 3'd1;
          cpu_write_mask <= 8'hff;
          cpu_data_write <= rmw_line[qw];
          cpu_request    <= 1'b1;
          @(posedge clk);
          cpu_request    <= 1'b0;
          while (!cpu_done) @(posedge clk);
        end
        cpu_ops = cpu_ops + 1;
      end
    end
  end

  // Capture the fill beats in order, so the write-back returns exactly what
  // the read produced.
  always @(posedge clk) begin
    if (cpu_cache_data_ready && rmw_beats_seen < 4) begin
      rmw_line[rmw_beats_seen] <= cpu_cache_data;
      rmw_beats_seen <= rmw_beats_seen + 1;
    end
  end

  integer line, x;
  integer blank_uncontended = 0;
  integer ops_at_switch = 0;

  initial begin
    reset = 1'b1;
    bridge_reset = 1'b1;
    repeat (8) @(posedge clk);
    init = 1'b0;
    wait (sdram_ready);
    repeat (8) @(posedge clk);

    // The bridge only - the raster stays held until seeding is done.
    bridge_reset = 1'b0;
    repeat (4) @(posedge clk);

    // Seed the on-chip framebuffer through the bridge's own CPU write port,
    // which is how it is populated on hardware, rather than poking storage.
    // The store is now an explicit altsyncram (rtl/ki_fb_ram.sv) whose contents
    // live inside the megafunction model, and reaching into that would couple
    // the bench to a simulation model's internals. Writing through the port is
    // both robust and a better test - the seeding exercises the FB_WRITE path
    // that the game's blit uses.
    //
    // cpu_traffic_enable is still low here, so this has the port to itself.
    //
    // The SDRAM model is seeded too. Scanout should never read it for this
    // range, and tb_ki_memory_bridge asserts exactly that; here the copy simply
    // means a stray SDRAM read would return plausible data rather than X, so a
    // leak shows up as a correctness failure elsewhere and not as noise here.
    for (line = 0; line < SEEDED_LINES; line = line + 1) begin
      for (x = 0; x < H_VISIBLE; x = x + 1)
        memory.mem[{8'd0, word_index(line, x)}] = expect_pixel(line, x);
      for (x = 0; x < H_VISIBLE; x = x + 4)
        fb_write_qword(word_index(line, x),
                       {expect_pixel(line, x + 3), expect_pixel(line, x + 2),
                        expect_pixel(line, x + 1), expect_pixel(line, x)});
    end
    $display("seeded %0d lines x %0d pixels at framebuffer page %05h",
             SEEDED_LINES, H_VISIBLE, KI_FB_PAGE0);

    // Release the raster and the framebuffer together, so line 0's fetch
    // starts where it does on a real cold start.
    @(negedge clk);
    reset = 1'b0;

    // Scanout alone first. If this shows black the fault is not contention.
    wait (v_count == CONTENDED_FROM_LINE);
    blank_uncontended = blank_pixels;
    $display("uncontended lines %0d..%0d: %0d blank of %0d checked",
             FIRST_CHECKED_LINE, CONTENDED_FROM_LINE - 1,
             blank_uncontended, checked);

    cpu_traffic_enable = 1'b1;
    ops_at_switch = cpu_ops;

    wait (v_count == LAST_CHECKED_LINE + 1);
    cpu_traffic_enable = 1'b0;

    $display("contended lines %0d..%0d: %0d blank, %0d CPU operations",
             CONTENDED_FROM_LINE, LAST_CHECKED_LINE,
             blank_pixels - blank_uncontended, cpu_ops - ops_at_switch);
    $display("line fetch: %0d lines, %0d requests, mean %.1f us, worst %.1f us, budget %.1f us %0s",
             fetches, requests, (total_fetch / fetches) / 1000.0,
             worst_fetch / 1000.0, SCANLINE_NS / 1000.0,
             (worst_fetch > SCANLINE_NS) ? "*** OVER BUDGET ***" : "ok");
    $display("checked %0d visible pixels", checked);

    if (requests != fetches * 20)
      $fatal(1, "FAIL: %0d requests for %0d lines, expected %0d - a line is not being fetched in 20 four-word bursts",
             requests, fetches, fetches * 20);
    if (worst_fetch > SCANLINE_NS)
      $fatal(1, "FAIL: worst line fetch %.1f us exceeds the %.1f us scanline",
             worst_fetch / 1000.0, SCANLINE_NS / 1000.0);
    if (blank_pixels != 0)
      $fatal(1, "FAIL: %0d visible pixels were black; first at line %0d x %0d",
             blank_pixels, first_blank_line, first_blank_x);
    if (colour_errors != 0)
      $fatal(1, "FAIL: %0d wrong pixels of %0d", colour_errors, checked);

    $display("tb_ki_framebuffer_fetch: PASS (%0d pixels, no black, no wrong colours)",
             checked);
    $finish;
  end

  // SDRAM init is ~120 us and the sweep is ~14 scanlines of ~65 us.
  initial begin
    #2000000;
    $fatal(1, "tb_ki_framebuffer_fetch timeout at line %0d x %0d, checked=%0d",
           v_count, h_count, checked);
  end
endmodule

`default_nettype wire
