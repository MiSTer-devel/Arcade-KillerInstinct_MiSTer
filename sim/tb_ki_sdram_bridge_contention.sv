// Does the SDRAM self test survive the REAL primary - ki_memory_bridge - with
// the HPS still streaming?
//
// Two benches already exist and they are mirror images of each other:
//
//   tb_ki_sdram_bist         BIST on aux, primary tied to zero
//   tb_ki_memory_bridge_sdram  bridge on primary, aux tied to zero
//
// Neither has ever had both requesters on the bus at once, which is the only
// state the board is ever in. tb_ki_sdram_contention closed half the gap with a
// synthetic reader on the primary and did NOT reproduce the failure - but a
// synthetic reader models the CPU and scanout, not the bridge.
//
// What the board reports, on KI1 and KI2, with and without an OSD core reset:
//
//   EP:4890 AC:0BE0 SD:F     (and earlier, EP:4893 AC:0BE3)
//
// decoding as {state[3:0], invert_pass, 3'b000, index[7:0]}: BIST_READ_ACK,
// inverted pass, single-read index 144 (and 147), after 3040 (3043) completed
// transactions - region 2, pass 1, both times, the three pad bits zero as a
// decode self-check. A read was issued and its done never came back. The BIST
// watchdog is refreshed by EVERY completed transaction and fires at 100_000
// cycles, which is 2 ms at 50 MHz, so this is a real stall and not a marginal
// timeout.
//
// Two suspects were eliminated before this bench was written:
//
//   * CPU and scanout contention. The board shows an IDENTICAL EP/AC with and
//     without the OSD core reset, and the BIST gates CPU reset, so whether the
//     CPU is running does not move it. tb_ki_sdram_contention agrees.
//   * The watchdog being too tight. It is per transaction, not cumulative.
//
// What was NOT varied on hardware is the HPS. The MRA and IMG are loaded in
// both runs, and boot_loaded - which is what releases the BIST - is asserted by
// ioctl_index 1 ALONE (ki_memory_bridge.sv:342). Every other index, including
// the DCS sound ROM, keeps streaming to STORE_DCS afterwards, and the bridge
// calls that out itself: "a third requester on the DDR service state". So the
// BIST sweeps while the HPS is still loading, on every hardware run recorded.
//
// This bench puts that state on the bus. It FAILS LOUDLY: the criterion is that
// the BIST reaches done AND passes, and a stall is reported with the same EP/AC
// decode the debug screen shows, so a failure here is directly comparable to a
// photograph of the board.
`timescale 1ns/1ps

module tb_ki_sdram_bridge_contention;

  localparam real TCK = 20.0;
  localparam integer WORDS = 256;       // the hardware instance
  localparam integer BURST_WORDS = 16;
  localparam integer ROM_WORDS = 64;

  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic clk_dev = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;

  always #(TCK / 2.0) clk = ~clk;
  always #(TCK / 4.0) ddr_clk = ~ddr_clk;

  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  // Two loads, so a failure says which requester carries it.
  //
  //   0  scanout + CPU through the real bridge, HPS quiet after boot
  //   1  the same, plus the HPS still streaming the DCS ROM - the state every
  //      recorded hardware run was actually in
  localparam integer LOADS = 2;

  wire [LOADS-1:0] done, pass;
  wire [15:0] error_count      [LOADS];
  wire [24:0] first_bad_address[LOADS];
  wire [15:0] first_bad_expect [LOADS];
  wire [15:0] first_bad_actual [LOADS];
  wire [31:0] video_served     [LOADS];
  wire [31:0] cpu_served       [LOADS];
  wire [31:0] ioctl_beats      [LOADS];
  wire [LOADS-1:0] boot_loaded, bist_busy;

  genvar g;
  generate
    for (g = 0; g < LOADS; g = g + 1) begin : load
      ki_sdram_bridge_path #(
        .WORDS(WORDS), .BURST_WORDS(BURST_WORDS), .ROM_WORDS(ROM_WORDS),
        .WITH_IOCTL(g)
      ) path (
        .clk(clk), .ddr_clk(ddr_clk), .clk_dev(clk_dev),
        .reset(reset), .init(init),
        .done(done[g]), .pass(pass[g]),
        .error_count(error_count[g]),
        .first_bad_address(first_bad_address[g]),
        .first_bad_expected(first_bad_expect[g]),
        .first_bad_actual(first_bad_actual[g]),
        .video_served(video_served[g]), .cpu_served(cpu_served[g]),
        .ioctl_beats(ioctl_beats[g]),
        .boot_loaded_o(boot_loaded[g]), .busy_o(bist_busy[g])
      );
    end
  endgenerate

  // Read a timeout report exactly the way the debug screen's EP field is read.
  task automatic report(input int unsigned i);
    begin
      $display("    EP=%04x AC=%04x  addr=%07x  EC=%04x",
               first_bad_expect[i], first_bad_actual[i],
               first_bad_address[i], error_count[i]);
      if (error_count[i] == 16'hFFFF)
        $display("    TIMEOUT: state=%0d invert=%0d pad=%03b index=%0d  completed=%0d",
                 first_bad_expect[i][15:12], first_bad_expect[i][11],
                 first_bad_expect[i][10:8], first_bad_expect[i][7:0],
                 first_bad_actual[i]);
      else
        $display("    DATA MISMATCH, not a stall");
    end
  endtask

  int unsigned cycles;
  int unsigned failures;

  initial begin
    failures = 0;
    repeat (10) @(posedge clk);
    reset <= 1'b0;
    init  <= 1'b0;

    // The cap IS the termination guarantee, so it must be REACHABLE. The
    // original 60_000_000 was not: the suite kills a bench at 180 s wall clock
    // and this never got near its own limit, so a hang looked like a hang
    // instead of reporting. tb_ki_sdram_contention completes its identical
    // 3168-transaction sweep in 118_846 cycles, so 1_500_000 is over 12x
    // margin and still finishes well inside the wall-clock limit.
    cycles = 0;
    while (cycles < 1_500_000 && !(&done)) begin
      @(posedge clk);
      cycles = cycles + 1;
    end

    $display("tb_ki_sdram_bridge_contention: %0d cycles", cycles);

    for (int unsigned i = 0; i < LOADS; i = i + 1) begin
      $display("  load %0d (%s): done=%0d pass=%0d  video=%0d cpu=%0d ioctl=%0d",
               i, i == 0 ? "scanout+cpu" : "scanout+cpu+HPS",
               done[i], pass[i], video_served[i], cpu_served[i], ioctl_beats[i]);

      // A load that applied no load would silently re-run the bench we already
      // have. Assert the contention actually happened.
      if (video_served[i] == 0 || cpu_served[i] == 0) begin
        $display("    BENCH BUG: the bridge was not exercised, so this load applied nothing");
        failures = failures + 1;
      end
      if (i == 1 && ioctl_beats[i] == 0) begin
        $display("    BENCH BUG: the HPS never streamed, so load 1 equals load 0");
        failures = failures + 1;
      end

      if (!done[i]) begin
        // Say WHERE it stopped. "never finished" alone cannot tell a BIST that
        // stalled mid-sweep from one that was never released, and those have
        // completely different causes.
        $display("    FAIL: the self test never finished  boot_loaded=%0d busy=%0d",
                 boot_loaded[i], bist_busy[i]);
        if (!boot_loaded[i])
          $display("    ...it was NEVER RELEASED: boot_loaded low, so the BIST "
                   , "sat in BIST_WAIT_BOOT. That is a bench wiring problem, "
                   , "not an RTL finding.");
        else
          $display("    ...it WAS released and then stopped - this is the "
                   , "hardware symptom, look at EP/AC");
        failures = failures + 1;
      end else if (!pass[i]) begin
        $display("    FAIL: the self test reported failure under bridge traffic");
        report(i);
        failures = failures + 1;
      end
    end

    if (failures == 0)
      $display("tb_ki_sdram_bridge_contention: PASS");
    else
      $display("tb_ki_sdram_bridge_contention: FAIL (%0d)", failures);
    $finish;
  end

endmodule


// The BIST on aux and the REAL ki_memory_bridge on primary, through the real
// adapter, burst controller and SDRAM model.
module ki_sdram_bridge_path #(
  parameter integer WORDS = 256,
  parameter integer BURST_WORDS = 16,
  parameter integer ROM_WORDS = 64,
  parameter integer WITH_IOCTL = 0
) (
  input  wire clk,
  input  wire ddr_clk,
  input  wire clk_dev,
  input  wire reset,
  input  wire init,
  output wire done,
  output wire pass,
  output wire [15:0] error_count,
  output wire [24:0] first_bad_address,
  output wire [15:0] first_bad_expected,
  output wire [15:0] first_bad_actual,
  output logic [31:0] video_served = 32'd0,
  output logic [31:0] cpu_served = 32'd0,
  output logic [31:0] ioctl_beats = 32'd0,
  // Exposed so a run that does not finish can say WHY rather than just hanging.
  output wire         boot_loaded_o,
  output wire         busy_o
);

  // ---- bridge stimulus --------------------------------------------------
  logic cpu_request = 1'b0;
  logic cpu_rnw = 1'b1;
  logic [31:0] cpu_address = 32'h8800_0000;
  logic cpu_req64 = 1'b0;
  logic [2:0] cpu_size = 3'd1;
  logic [7:0] cpu_write_mask = 8'd0;
  logic [63:0] cpu_data_write = 64'd0;
  wire [63:0] cpu_data_read;
  wire cpu_done, cpu_grant;
  wire [63:0] cpu_cache_data;
  wire cpu_cache_data_ready;

  wire io_request, io_write;
  wire [31:0] io_address, io_write_data;
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
  logic [2:0] video_words = 3'd4;
  wire [63:0] video_data;
  wire video_data_valid, video_done;

  wire [24:0] bridge_address;
  wire [63:0] bridge_write_data;
  wire  [7:0] bridge_byte_enable;
  wire  [4:0] bridge_burst;
  wire bridge_read, bridge_write;
  wire [15:0] bridge_read_data;
  wire bridge_data_valid, bridge_done;
  wire sdram_ready;

  wire [24:0] bist_address;
  wire [63:0] bist_write_data;
  wire  [7:0] bist_byte_enable;
  wire  [4:0] bist_burst;
  wire bist_read, bist_write;
  wire [15:0] bist_read_data;
  wire bist_data_valid, bist_done_h;
  wire busy;
  wire [31:0] rom_checksum;

  assign boot_loaded_o = boot_loaded;
  assign busy_o = busy;

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

  wire [7:0] ddram_burstcnt;
  wire [28:0] ddram_addr;
  wire ddram_rd, ddram_we;
  wire [63:0] ddram_din;
  wire [7:0] ddram_be;

  wire [2:0] debug_state;
  wire debug_cpu_pending;
  wire [31:0] debug_last_write_address, debug_last_write_info;
  wire [63:0] debug_last_write_data;
  wire [31:0] debug_write_count, debug_low_write_count, debug_main_write_count;
  wire [31:0] debug_main_write0, debug_main_write1, debug_main_write2;

  // Boot download first: boot_loaded is asserted by ioctl_index 1 alone, and it
  // is what releases the BIST. Keep it short - the point is to start the sweep,
  // not to model the real ROM size.
  localparam integer BOOT_BEATS = 64;

  typedef enum logic [1:0] { HPS_BOOT, HPS_GAP, HPS_STREAM, HPS_IDLE } hps_t;
  hps_t hps = HPS_BOOT;
  int unsigned hps_count = 0;

  always_ff @(posedge clk) begin
    if (reset) begin
      hps <= HPS_BOOT;
      hps_count <= 0;
      ioctl_download <= 1'b0;
      ioctl_wr <= 1'b0;
      ioctl_index <= 16'd1;
      ioctl_addr <= 27'd0;
      ioctl_beats <= 32'd0;
    end else begin
      ioctl_wr <= 1'b0;
      case (hps)
        HPS_BOOT: begin
          ioctl_download <= 1'b1;
          ioctl_index <= 16'd1;
          if (!ioctl_wait && !ioctl_wr) begin
            ioctl_wr <= 1'b1;
            ioctl_dout <= 16'hA5A5;
            ioctl_addr <= ioctl_addr + 27'd2;
            hps_count <= hps_count + 1;
            if (hps_count >= BOOT_BEATS) begin
              hps <= HPS_GAP;
              hps_count <= 0;
            end
          end
        end
        HPS_GAP: begin
          // Drop download so boot_loaded latches, then pick the DCS index up
          // again - which is exactly the hardware sequence.
          //
          // WAIT FOR THE REAL SIGNAL, not a fixed delay. boot_loaded needs
          // !ioctl_download AND download_count == 0 AND !download_inflight AND
          // state == IDLE simultaneously (ki_memory_bridge.sv:715). With video
          // and CPU traffic on the bridge, state is often not IDLE, so a fixed
          // 20-cycle gap can miss it - and once HPS_STREAM raises ioctl_download
          // again it can never latch, leaving the BIST parked in BIST_WAIT_BOOT
          // forever. That state is excluded from the BIST watchdog, so it hangs
          // SILENTLY. This was the second cause of the original hang.
          ioctl_download <= 1'b0;
          if (boot_loaded) begin
            hps <= (WITH_IOCTL != 0) ? HPS_STREAM : HPS_IDLE;
            hps_count <= 0;
            ioctl_addr <= 27'd0;
          end
        end
        HPS_STREAM: begin
          // The DCS sound ROM, still loading while the BIST sweeps.
          ioctl_download <= 1'b1;
          ioctl_index <= 16'd2;
          if (!ioctl_wait && !ioctl_wr) begin
            ioctl_wr <= 1'b1;
            ioctl_dout <= ioctl_addr[15:0];
            ioctl_addr <= ioctl_addr + 27'd2;
            ioctl_beats <= ioctl_beats + 1'b1;
          end
        end
        HPS_IDLE: ioctl_download <= 1'b0;
      endcase
    end
  end

  // Scanout: a line's worth of words, continuously, walking the framebuffer.
  logic video_inflight = 1'b0;
  always_ff @(posedge clk) begin
    if (reset) begin
      video_request <= 1'b0;
      video_inflight <= 1'b0;
      video_address <= 28'd0;
      video_served <= 32'd0;
    end else begin
      // video_request is a LEVEL, not a pulse: the bridge qualifies it with
      // `video_request && !video_done` (ki_memory_bridge.sv:765/905), so a
      // one-cycle pulse is never seen and video_served stayed at zero. The
      // cpu and ioctl ports are pulse/handshake and are driven differently -
      // do not unify these three, they have different contracts.
      if (!video_inflight && sdram_ready) begin
        video_request <= 1'b1;
        video_inflight <= 1'b1;
      end else if (video_inflight && video_done) begin
        video_request <= 1'b0;
        video_inflight <= 1'b0;
        video_served <= video_served + 1'b1;
        video_address <= (video_address >= 28'd76800) ? 28'd0
                                                      : video_address + 28'd8;
      end
    end
  end

  // The CPU, reading main RAM.
  logic cpu_inflight = 1'b0;
  always_ff @(posedge clk) begin
    if (reset) begin
      cpu_request <= 1'b0;
      cpu_inflight <= 1'b0;
      cpu_address <= 32'h8800_0000;
      cpu_served <= 32'd0;
    end else begin
      cpu_request <= 1'b0;
      if (!cpu_inflight && sdram_ready) begin
        cpu_request <= 1'b1;
        cpu_inflight <= 1'b1;
      end else if (cpu_inflight && cpu_done) begin
        cpu_inflight <= 1'b0;
        cpu_served <= cpu_served + 1'b1;
        cpu_address <= (cpu_address >= 32'h8800_8000) ? 32'h8800_0000
                                                      : cpu_address + 32'd8;
      end
    end
  end

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
    // The DCS ROM port must be DRIVEN, not left open: dcs_rom_request is an
    // INPUT, and an X on a request line wedges the DDR service state machine.
    // The first run of this bench hung for exactly that reason.
    .dcs_rom_request(1'b0), .dcs_rom_address(19'd0),
    .dcs_rom_ready(), .dcs_rom_data(),
    .ddram_busy(1'b0), .ddram_burstcnt(ddram_burstcnt), .ddram_addr(ddram_addr),
    .ddram_dout(64'd0), .ddram_dout_ready(1'b0),
    .ddram_rd(ddram_rd), .ddram_din(ddram_din), .ddram_be(ddram_be),
    .ddram_we(ddram_we),
    .debug_state(debug_state), .debug_cpu_pending(debug_cpu_pending),
    .debug_last_write_address(debug_last_write_address),
    .debug_last_write_data(debug_last_write_data),
    .debug_last_write_info(debug_last_write_info),
    .debug_write_count(debug_write_count),
    .debug_low_write_count(debug_low_write_count),
    .debug_main_write_count(debug_main_write_count),
    .debug_main_write0(debug_main_write0),
    .debug_main_write1(debug_main_write1),
    .debug_main_write2(debug_main_write2)
  );

  ki_sdram_bist #(.WORDS(WORDS), .BURST_WORDS(BURST_WORDS),
                  .ROM_WORDS(ROM_WORDS)) bist (
    .clk(clk), .reset(reset), .sdram_ready(sdram_ready),
    .boot_loaded(boot_loaded),
    .request_address(bist_address),
    .request_write_data(bist_write_data),
    .request_byte_enable(bist_byte_enable),
    .request_burst(bist_burst),
    .request_read(bist_read), .request_write(bist_write),
    .request_read_data(bist_read_data),
    .request_data_valid(bist_data_valid),
    .request_done(bist_done_h),
    .rom_checksum(rom_checksum), .busy(busy), .done(done), .pass(pass),
    .error_count(error_count),
    .first_bad_address(first_bad_address),
    .first_bad_expected(first_bad_expected),
    .first_bad_actual(first_bad_actual)
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
    .aux_address(bist_address), .aux_write_data(bist_write_data),
    .aux_byte_enable(bist_byte_enable), .aux_burst(bist_burst),
    .aux_read(bist_read), .aux_write(bist_write),
    .aux_read_data(bist_read_data), .aux_data_valid(bist_data_valid),
    .aux_done(bist_done_h),
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

endmodule
