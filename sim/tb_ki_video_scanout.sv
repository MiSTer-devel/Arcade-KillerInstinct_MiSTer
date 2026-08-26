`timescale 1ns/1ps
`default_nettype none

// Does the video scanout port return the right pixels, including while the CPU
// is hammering the same bus?
//
// This is the gap every other bench left. tb_ki_cpu_system_boot enables scanout
// contention but wires the framebuffer's pixel outputs to (), so nothing ever
// checked that a video read returns the data that is actually in memory. The
// hardware symptom - blue fill covering only the right of each line, in ragged
// stripes whose left edge shifts per line - is exactly a scanout addressing or
// data fault, and is precisely what an unchecked video port would hide.
//
// The mechanism under suspicion: in ki_memory_bridge, CPU reads and video reads
// SHARE read_buffer / read_word_index / read_words_remaining /
// memory_word_address:
//
//   if (sdram_data_valid && ((state == SDRAM_READ_WAIT) ||
//                            (state == VIDEO_READ_WAIT))) begin
//     read_buffer <= read_buffer_next; ...
//
// That is only safe if the two never overlap. This bench checks the outcome
// rather than the argument: every video beat is compared against known memory
// contents, first uncontended, then with continuous CPU traffic.
//
// Memory is seeded directly in the device model, so a wrong result cannot be
// blamed on the write path. Video address A (8-byte aligned) maps to word
// indices (A>>3)*4 + 0..3 (see the bridge's memory_word_address for video),
// and word index w lands at device key {8'd0, w[23:0]} - the composition of
// the adapter's {addr[23:0],1'b0} and the controller's col/row/bank split.
module tb_ki_video_scanout;
  localparam real TCK = 20.0;
  localparam logic [27:0] FB_BASE = 28'h010_0000;   // storage byte address
  localparam integer FB_QWORDS = 512;               // 4 KiB of framebuffer
  localparam logic [31:0] CPU_RAM = 32'h0820_0000;  // CPU traffic, elsewhere

  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  integer errors = 0;
  integer checked = 0;

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
  wire         cpu_done, cpu_grant;
  wire  [63:0] cpu_cache_data;
  wire         cpu_cache_data_ready;

  logic        video_request = 1'b0;
  logic [27:0] video_address = 28'd0;
  logic  [2:0] video_words = 3'd1;
  wire  [63:0] video_data;
  wire         video_data_valid;
  wire         video_done;

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
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_index(16'd0),
    .ioctl_addr(27'd0), .ioctl_dout(16'd0), .ioctl_wait(),
    .boot_loaded(),
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
    .ddram_busy(1'b0), .ddram_burstcnt(ddram_burstcnt),
    .ddram_addr(ddram_addr), .ddram_dout(64'd0), .ddram_dout_ready(1'b0),
    .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
    .ddram_we(ddram_we),
    .debug_state(), .debug_cpu_pending(),
    .debug_last_write_address(), .debug_last_write_data(),
    .debug_last_write_info(), .debug_write_count(),
    .debug_low_write_count(), .debug_main_write_count(),
    .debug_main_write0(), .debug_main_write1(), .debug_main_write2()
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

  // Distinct per qword so a swapped or skewed beat is unmistakable.
  function automatic logic [63:0] pattern(input integer qword);
    pattern = {32'hF00D0000 | qword[15:0], 16'hA500 | qword[7:0],
               16'h5A00 | (~qword[7:0])};
  endfunction

  task automatic seed_qword(input integer qword, input logic [63:0] value);
    integer k;
    logic [23:0] w;
    begin
      for (k = 0; k < 4; k = k + 1) begin
        w = (((FB_BASE + qword * 8) >> 3) * 4) + k;
        memory.mem[{8'd0, w}] = value[k*16 +: 16];
      end
    end
  endtask

  task automatic video_read(input integer qword, output logic [63:0] value);
    begin
      // video_done stays asserted for a cycle after the transfer. Without
      // waiting for it to clear, the wait below sees the PREVIOUS request's
      // done and samples stale data - which reads as a clean off-by-one and
      // looks exactly like an RTL addressing fault.
      while (video_done) @(posedge clk);
      @(posedge clk);
      video_address <= FB_BASE + qword * 8;
      video_request <= 1'b1;
      @(posedge clk);
      // Hold the request until the bridge ACCEPTS it (state 8 =
      // VIDEO_READ_ISSUE), then drop it immediately.
      //   - A one-cycle pulse is missed whenever the bridge is mid-CPU
      //     operation, which starves scanout completely under load.
      //   - Holding it through completion lets the bridge return to IDLE and
      //     relaunch at the still-asserted address; the next call then
      //     consumes that stale result, which looks exactly like an RTL
      //     off-by-one until a reverse-order pass shows the value tracks the
      //     previously READ qword rather than address-1.
      while (bridge.state != 5'd8) @(posedge clk);
      video_request <= 1'b0;
      while (!video_done) @(posedge clk);
      value = video_data;
      @(posedge clk);
    end
  endtask

  // One scanline at the 6.25 MHz pixel clock (clk/8), ~400 pixel times
  // including blanking. A line fetch is 80 serialised round trips and must
  // finish inside this, or ki_framebuffer paints black until it lands.
  // 400 pixel times per line incl. blanking, 8 clk per pixel (ce_pixel =
  // clk/8), TCK ns per clk.
  localparam real SCANLINE_NS = 400.0 * 8.0 * TCK;

  task automatic check_scanout(input string phase, input logic reverse = 1'b0);
    integer q;
    logic [63:0] got, want;
    integer reported;
    real t0, per_read, per_line;
    begin
      reported = 0;
      t0 = $realtime;
      for (q = 0; q < FB_QWORDS; q = q + 1) begin
        video_read(reverse ? (FB_QWORDS - 1 - q) : q, got);
        want = pattern(reverse ? (FB_QWORDS - 1 - q) : q);
        checked = checked + 1;
        if (got !== want) begin
          errors = errors + 1;
          if (reported < 10) begin
            reported = reported + 1;
            $display("FAIL[%0s]: qword %0d = %016x, want %016x",
                     phase, reverse ? (FB_QWORDS - 1 - q) : q, got, want);
          end
        end
      end
      per_read = ($realtime - t0) / FB_QWORDS;
      per_line = per_read * 80.0;
      $display("%0s: %0d qwords, %0d errors, %.1f ns/read -> %.1f us per 80-word line (budget %.1f us) %0s",
               phase, FB_QWORDS, errors, per_read, per_line / 1000.0,
               SCANLINE_NS / 1000.0,
               (per_line > SCANLINE_NS) ? "*** OVER BUDGET ***" : "ok");
    end
  endtask

  task automatic check_burst_scanout(input string phase);
    integer q, k;
    logic [63:0] got, want;
    integer reported;
    real t0, per_read, per_line;
    begin
      reported = 0;
      t0 = $realtime;
      video_words <= 3'd4;
      for (q = 0; q < FB_QWORDS; q = q + 4) begin
        while (video_done) @(posedge clk);
        @(posedge clk);
        video_address <= FB_BASE + q * 8;
        video_request <= 1'b1;
        @(posedge clk);
        while (bridge.state != 5'd8) @(posedge clk);
        video_request <= 1'b0;
        for (k = 0; k < 4; k = k + 1) begin
          while (!video_data_valid) @(posedge clk);
          got = video_data;
          want = pattern(q + k);
          checked = checked + 1;
          if (got !== want) begin
            errors = errors + 1;
            if (reported < 10) begin
              reported = reported + 1;
              $display("FAIL[%0s]: qword %0d = %016x, want %016x",
                       phase, q + k, got, want);
            end
          end
          @(posedge clk);
        end
        while (!video_done) @(posedge clk);
        @(posedge clk);
      end
      video_words <= 3'd1;
      per_read = ($realtime - t0) / FB_QWORDS;
      per_line = per_read * 80.0;
      $display("%0s: %0d qwords, %0d errors, %.1f ns/qword -> %.1f us per 80-word line (budget %.1f us) %0s",
               phase, FB_QWORDS, errors, per_read, per_line / 1000.0,
               SCANLINE_NS / 1000.0,
               (per_line > SCANLINE_NS) ? "*** OVER BUDGET ***" : "ok");
    end
  endtask

  // Continuous CPU traffic on the same bus: cache-line reads and 64-bit
  // stores, the mix the framebuffer clear actually produces.
  logic cpu_traffic_enable = 1'b0;
  integer cpu_ops = 0;

  initial begin : cpu_traffic
    integer i;
    forever begin
      @(posedge clk);
      if (cpu_traffic_enable) begin
        cpu_address    <= CPU_RAM + ((cpu_ops * 32) % 32'h0001_0000);
        cpu_rnw        <= (cpu_ops[0] == 1'b0);
        cpu_req64      <= 1'b1;
        cpu_size       <= (cpu_ops[0] == 1'b0) ? 3'd4 : 3'd1;
        cpu_write_mask <= (cpu_ops[0] == 1'b0) ? 8'h00 : 8'hff;
        cpu_data_write <= {32'hCAFE0000, cpu_ops[31:0]};
        cpu_request    <= 1'b1;
        @(posedge clk);
        cpu_request    <= 1'b0;
        while (!cpu_done) @(posedge clk);
        cpu_ops = cpu_ops + 1;
      end
    end
  end

  integer q;

  initial begin
    repeat (8) @(posedge clk);
    reset = 1'b0;
    init  = 1'b0;
    wait (sdram_ready);
    repeat (8) @(posedge clk);

    for (q = 0; q < FB_QWORDS; q = q + 1)
      seed_qword(q, pattern(q));
    $display("seeded %0d framebuffer qwords at %07x", FB_QWORDS, FB_BASE);

    // Baseline: scanout alone. If this fails the fault is not contention.
    check_scanout("uncontended");
    check_scanout("reverse", 1'b1);

    // The real case: scanout while the CPU works the same bus.
    cpu_traffic_enable = 1'b1;
    repeat (50) @(posedge clk);
    check_scanout("contended");
    check_burst_scanout("contended 4-qword bursts");
    cpu_traffic_enable = 1'b0;
    $display("cpu operations issued during contended pass: %0d", cpu_ops);

    if (errors == 0)
      $display("PASS: scanout returns correct pixels, contended and not (%0d reads)",
               checked);
    else
      $fatal(1, "FAIL: %0d scanout error(s) of %0d reads", errors, checked);
    $finish;
  end

  initial begin
    #200000000;
    $display("FAIL: timeout errors=%0d checked=%0d cpu_ops=%0d",
             errors, checked, cpu_ops);
    $fatal(1);
  end

endmodule
`default_nettype wire
