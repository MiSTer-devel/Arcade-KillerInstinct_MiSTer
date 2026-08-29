`timescale 1ns/1ps
`default_nettype none

// Cached instruction fetch and data reads under scanout contention.
//
// Hardware corrupts the INSTRUCTION STREAM during the intro video and nowhere
// else. At 8802DBCC, where 1020001A lives, the CPU decoded 0BF000E2 - a value
// that is nonsense as an instruction either way, and whose halves (0BF0, 00E2)
// are entirely plausible as two BGR555 pixels.
//
// The intro is where full-frame 64-bit blits, continuous scanout and disk
// streaming all hit the single SDRAM port at once, and gameplay never does all
// three. The bridge shares read_buffer and read_word_index between CPU reads
// and scanout reads, and ki_memory_bridge.sv:653 already documents this exact
// hazard class biting once on the video side - "the stale burst is consumed as
// the answer to the requester's next request... no bench saw it until scanout
// burst".
//
// So this thrashes the caches against continuous scanout and checks the CPU's
// own view of memory. The program fills 20 KiB - larger than the 16 KiB data
// cache, so every pass misses and refills - with each word holding its own
// address, then verifies that forever. A single wrong word parks the CPU at a
// FAIL address, which this bench detects.
//
// It checks the CPU's RESULT rather than snooping the bridge deliberately: a
// white-box check would only find the mechanism I currently suspect, while a
// wrong word is wrong however it got there.

module tb_ki_cache_scanout;
  localparam real    TCK = 20.0;
  localparam integer ROM_BYTES = 524288;
  // The program lives in the first 0x80 bytes and the source data it feeds to
  // the drive at 0x800, so 4 KiB is enough to download - and every byte of
  // that goes through the real SDRAM model, which is what makes a full image
  // take minutes of wall clock for no extra coverage.
  localparam integer DOWNLOAD_BYTES = 4096;
  localparam integer BLOCK_WORDS = 256;

  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic clk_dev = 1'b0;
  logic clk93 = 1'b0;
  logic clk2x = 1'b0;
  logic reset = 1'b1;
  logic init = 1'b1;
  logic reset_1x = 1'b1;
  logic reset_93 = 1'b1;

  always #(TCK / 2.0) clk = ~clk;
  always #(TCK / 4.0) ddr_clk = ~ddr_clk;
  always #5.000       clk2x = ~clk2x;
  always #6.666666667 clk93 = ~clk93;

  task automatic emit_edge(input logic value, input real delay_ns);
    #(delay_ns) clk_dev = value;
  endtask
  always @(clk) fork emit_edge(clk, 16.75); join_none

  // ---- CPU <-> bridge -------------------------------------------------
  wire        cpu_request, cpu_rnw, cpu_req64;
  wire [31:0] cpu_address;
  wire  [2:0] cpu_size;
  wire  [7:0] cpu_write_mask;
  wire [63:0] cpu_data_write;
  wire [63:0] cpu_data_read;
  wire        cpu_done, cpu_grant;
  wire [63:0] cpu_cache_data;
  wire        cpu_cache_data_ready;

  wire [63:0] debug_pc;
  wire [31:0] debug_opcode;
  wire [63:0] debug_v0, debug_v1, debug_a0, debug_a1;
  wire [63:0] debug_t2, debug_a3, debug_s5, debug_s6;
  wire  [5:0] debug_errors;
  wire        debug_done;

  ki_cpu_wrapper cpu (
    .clk1x(clk), .clk93(clk93), .clk2x(clk2x),
    .reset_1x(reset_1x), .reset_93(reset_93), .irq(2'b00),
    .mem_request(cpu_request), .mem_rnw(cpu_rnw),
    .mem_address(cpu_address), .mem_req64(cpu_req64), .mem_size(cpu_size),
    .mem_writeMask(cpu_write_mask), .mem_dataWrite(cpu_data_write),
    .mem_dataRead(cpu_data_read), .mem_done(cpu_done),
    .cache_grant(cpu_grant), .cache_data(cpu_cache_data),
    .cache_data_ready(cpu_cache_data_ready),
    .debug_done(debug_done), .debug_pc(debug_pc),
    .debug_opcode(debug_opcode), .debug_v0(debug_v0), .debug_v1(debug_v1),
    .debug_a0(debug_a0), .debug_a1(debug_a1), .debug_t2(debug_t2),
    .debug_a3(debug_a3), .debug_s5(debug_s5), .debug_s6(debug_s6),
    .debug_errors(debug_errors)
  );

  // ---- bridge <-> board I/O and ATA ------------------------------------
  wire        io_request, io_write;
  wire [31:0] io_address, io_write_data;
  wire  [3:0] io_byte_enable;
  wire [31:0] board_io_read_data, ata_read_data;
  wire        board_io_done, ata_done, ata_irq;

  // Same mux as KillerInstinct.sv:890.
  wire [31:0] io_read_data = ata_done ? ata_read_data : board_io_read_data;
  wire        io_done      = board_io_done | ata_done;

  ki_board_io board_io (
    .clk(clk), .reset(reset), .game_ki2(1'b0),
    .bus_request(io_request), .bus_write(io_write),
    .bus_address(io_address), .bus_write_data(io_write_data),
    .bus_byte_enable(io_byte_enable),
    .bus_read_data(board_io_read_data), .bus_done(board_io_done),
    .input_p1(32'hffff_ffff), .input_p2(32'hffff_ffff),
    .input_volume(32'hffff_ffff), .input_dip(32'hffff_a55a),
    .input_unused(32'hffff_ffff),
    .irq_vblank(1'b0), .irq_ata(1'b0), .cpu_irq(),
    .framebuffer_base(), .sound_reset(), .sound_data(),
    .sound_data_strobe(), .coin_control()
  );

  logic         img_mounted = 1'b0;
  wire  [31:0]  sd_lba;
  wire          sd_rd, sd_wr;
  logic         sd_ack = 1'b0;
  logic [12:0]  sd_buff_addr = 13'd0;
  wire   [5:0]  sd_blk_cnt;
  logic [15:0]  sd_buff_dout = 16'd0;
  wire  [15:0]  sd_buff_din;
  logic         sd_buff_wr = 1'b0;

  ki_ata ata (
    .clk(clk), .reset(reset), .game_ki2(1'b0),
    .bus_request(io_request), .bus_write(io_write),
    .bus_address(io_address), .bus_write_data(io_write_data),
    .bus_byte_enable(io_byte_enable),
    .bus_read_data(ata_read_data), .bus_done(ata_done), .irq(ata_irq),
    .img_mounted(img_mounted), .img_readonly(1'b0),
    .img_size(64'd1048576),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
    .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
    .debug_state(), .debug_status(), .debug_error(), .debug_image_ready(),
    .debug_info(), .debug_read_lba(), .debug_write_lba(),
    .debug_write_info(), .debug_dataport_info()
  );

  // ---- bridge <-> SDRAM ------------------------------------------------
  wire [24:0] bridge_address, controller_address;
  wire [63:0] bridge_write_data, controller_write_data;
  wire  [7:0] bridge_byte_enable, controller_byte_enable;
  wire  [4:0] bridge_burst, controller_burst;
  wire        bridge_read, bridge_write, controller_read, controller_write;
  wire [15:0] bridge_read_data, controller_read_data;
  wire        bridge_data_valid, controller_dout_valid;
  wire        bridge_done, sdram_ready, controller_ready;

  wire [15:0] SDRAM_DQ;
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_BA;
  wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS;
  wire        SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

  logic        ioctl_download = 1'b0;
  logic        ioctl_wr = 1'b0;
  logic [15:0] ioctl_index = 16'd0;
  logic [26:0] ioctl_addr = 27'd0;
  logic [15:0] ioctl_dout = 16'd0;
  wire         ioctl_wait, boot_loaded;

  wire [28:0] ddram_addr;
  wire  [7:0] ddram_burstcnt, ddram_be;
  wire [63:0] ddram_din;
  wire        ddram_rd, ddram_we;

  byte unsigned rom [0:ROM_BYTES-1];

  logic        video_request = 1'b0;
  logic [27:0] video_address = 28'h010_0000;
  wire         video_done;

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
    .video_words(3'd4),
    .video_data(), .video_data_valid(), .video_done(video_done),
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

  // ---- scanout contention ---------------------------------------------
  //
  // On hardware the framebuffer reader competes with the CPU for the bridge
  // every scanline (ki_memory_bridge.sv:591), so writefifo_mem4_ready spends
  // real time LOW and stage-4 stores get parked on writeback_fifoStall. With
  // video tied off, that never happens and this bench passed while hardware
  // lost 56% of its stores - the missing ingredient, not a missing bug.
  //
  // A continuous four-word requester, which is what the real scanout reader
  // looks like to the arbiter.
  // A REALISTIC scanout cadence, not a saturating one.
  //
  // The first version requested back to back with no gap, which is nothing
  // like the real reader: 320 pixels is 640 bytes per 65 us line, so a 32-byte
  // burst is needed about every 3.2 us - roughly one burst per 160 core
  // clocks, a few percent duty cycle. Saturating the port instead starved the
  // CPU so badly that a 20 KiB fill had not finished after 3 ms of simulated
  // time, and it made the test harsher without making the INTERLEAVING - which
  // is what actually matters here - any more representative.
  localparam integer VIDEO_GAP = 120;
  integer video_wait = 0;

  always @(posedge clk) begin
    if (reset) begin
      video_request <= 1'b0;
      video_address <= 28'h010_0000;
      video_wait <= 0;
    end else if (video_done) begin
      video_request <= 1'b0;
      video_address <= (video_address + 28'd32) & 28'h01f_ffff;
      video_wait <= VIDEO_GAP;
    end else if (!video_request) begin
      if (video_wait != 0) video_wait <= video_wait - 1;
      else video_request <= 1'b1;
    end
  end

  // ---- the HPS side of the MiSTer sd interface -------------------------
  //
  // sd_wr is a level held until ack. The HPS answers with sd_ack, walks
  // sd_buff_addr across the 256 words reading sd_buff_din, then drops ack.
  logic [15:0] disk_block [0:BLOCK_WORDS-1];
  integer      hps_blocks_written = 0;
  integer      sd_wr_edges = 0;
  logic        sd_wr_d = 1'b0;

  always @(posedge clk) begin
    sd_wr_d <= sd_wr;
    if (sd_wr && !sd_wr_d) sd_wr_edges <= sd_wr_edges + 1;
  end

  integer hps_index;
  initial begin
    forever begin
      @(posedge clk);
      if (sd_wr) begin
        repeat (24) @(posedge clk);   // HPS turnaround
        sd_ack <= 1'b1;
        for (hps_index = 0; hps_index < BLOCK_WORDS; hps_index = hps_index + 1)
        begin
          sd_buff_addr <= {5'd0, hps_index[7:0]};
          @(posedge clk);
          @(posedge clk);             // the sector buffer is registered
          disk_block[hps_index] = sd_buff_din;
        end
        @(posedge clk);
        sd_ack <= 1'b0;
        hps_blocks_written = hps_blocks_written + 1;
        @(posedge clk);
        @(posedge clk);
      end
    end
  end

  // ---- counters at both ends of the store path -------------------------
  //
  // The CPU holds mem_request until the bridge takes it, so count the cycle
  // the bridge ACCEPTS rather than the level, or one store counts many times.
  integer cpu_stores = 0;
  integer ata_stores = 0;
  integer video_reads = 0;
  always @(posedge clk) if (video_done) video_reads <= video_reads + 1;

  // Does this bench exercise the path the hardware fails on at all?
  //
  // Hardware loses 56% of its stores between the stage-4 decision and the
  // FIFO, and the only way a store fails to reach the FIFO is
  // writefifo_mem4_ready being low when it is offered. If these read zero,
  // the bench never even opens the window and its PASS says nothing about
  // the bug - which is the honest reading of two clean runs so far.
  integer fifostall_events = 0;
  integer stall_high_cycles = 0;
  integer replay_ready_cycles = 0;
  integer replay_issue_cycles = 0;
  integer stall_without_stall4 = 0;
  integer r_rnw = 0, r_wb = 0, r_dcl = 0, r_m1l = 0, r_wr = 0, r_blk = 0;
  integer r_addr_ok = 0, r_addr_bad = 0;
  integer notready_cycles  = 0;
  integer st4_stores       = 0;
  integer fifo_stores      = 0;
  logic   fifostall_d = 1'b0;

  always @(posedge clk93) begin
    fifostall_d <= cpu.core.writeback_fifoStall;
    if (cpu.core.writeback_fifoStall && !fifostall_d)
      fifostall_events <= fifostall_events + 1;
    if (cpu.core.ce_93 && !cpu.core.writefifo_mem4_ready)
      notready_cycles <= notready_cycles + 1;
    st4_stores  <= cpu.core.debug_st4_register;
    fifo_stores <= cpu.core.debug_stfifo_register;

    // Every stalled store is lost and none is abandoned by another release,
    // so the replay itself must be failing. Its two halves:
    //   stall_high    cycles the store is parked at all
    //   replay_ready  parked AND the FIFO says it can take it
    //   replay_issue  parked, ready, AND mem4_request re-offered
    // replay_ready = 0 means the stall ends before the FIFO frees up;
    // replay_ready > 0 with replay_issue = 0 means the combinational re-offer
    // is not happening.
    if (cpu.core.ce_93) begin
      if (cpu.core.writeback_fifoStall) begin
        stall_high_cycles <= stall_high_cycles + 1;
        if (cpu.core.writefifo_mem4_ready) begin
          replay_ready_cycles <= replay_ready_cycles + 1;
          if (cpu.core.mem4_request) begin
            replay_issue_cycles <= replay_issue_cycles + 1;
            // Every guard in the FIFO writer's elsif chain, sampled in the
            // very cycle the replay is offered. One of these is why
            //   elsif (mem4_request and not mem4_rnw and mem4_ready)
            // is not taken.
            if (cpu.core.mem4_rnw)                  r_rnw  <= r_rnw + 1;
            if (cpu.core.datacache_wb_ena)          r_wb   <= r_wb + 1;
            if (cpu.core.datacache_request_latched) r_dcl  <= r_dcl + 1;
            if (cpu.core.mem1_request_latched)      r_m1l  <= r_m1l + 1;
            if (cpu.core.writefifo_wr)              r_wr   <= r_wr + 1;
            if (cpu.core.writefifo_block)           r_blk  <= r_blk + 1;
            // What ADDRESS and DATA does the replay actually carry? The
            // FIFO-accept counter is address-matched, so a replay that
            // re-offers the store with a stale executeMemAddress would be
            // invisible to it AND to DW - counted as "never issued" while
            // actually writing somewhere else entirely.
            if (cpu.core.mem4_address == 32'h1000_0100) r_addr_ok <= r_addr_ok + 1;
            else if (r_addr_bad < 6) begin
              $display("  replay #%0d carries address %08x data %04x mask %02x",
                       replay_issue_cycles, cpu.core.mem4_address,
                       cpu.core.mem4_dataWrite[15:0], cpu.core.mem4_writeMask);
              r_addr_bad <= r_addr_bad + 1;
            end
          end
        end
      end
      if (cpu.core.writeback_fifoStall && !cpu.core.stall4)
        stall_without_stall4 <= stall_without_stall4 + 1;
    end
  end
  logic   cpu_request_d = 1'b0;

  always @(posedge clk) begin
    cpu_request_d <= cpu_request;
    if (cpu_request && !cpu_request_d && !cpu_rnw &&
        cpu_address == 32'h1000_0100)
      cpu_stores <= cpu_stores + 1;
    if (io_request && io_write && io_address == 32'h1000_0100)
      ata_stores <= ata_stores + 1;
  end

  task automatic patch_word(input integer offset, input logic [31:0] value);
    begin
      rom[offset + 0] = value[7:0];
      rom[offset + 1] = value[15:8];
      rom[offset + 2] = value[23:16];
      rom[offset + 3] = value[31:24];
    end
  endtask

  // HALFWORDS at even byte addresses, held until the bridge accepts them.
  //
  // ioctl_dout is 16 bits (ki_memory_bridge.sv:34) and the bridge assembles a
  // 64-bit word from four halfwords selected by incoming_download_address[2:1],
  // pushing when that selector reaches 3. Driving one BYTE per address - which
  // is what this bench did originally, inherited from tb_ki_io_poll_bridge -
  // makes the selector run 0,0,1,1,2,2,3,3, so every lane is written twice with
  // the wrong half of the data and the image is garbage. The CPU then fetched
  // nothing but zeros and nop-sledded out of the program entirely.
  //
  // This matches sim/tb_ki_cpu_bridge_boot.sv, which does boot the real ROM.
  task automatic ioctl_beat(input integer byte_address);
    begin
      @(negedge clk);
      ioctl_addr = byte_address[26:0];
      ioctl_dout = {rom[byte_address + 1], rom[byte_address]};
      ioctl_wr   = 1'b1;
      do begin
        @(posedge clk);
      end while (ioctl_wait);
      @(negedge clk);
      ioctl_wr   = 1'b0;
    end
  endtask

  // The FAIL park. Reaching it means the CPU read a word that was not
  // what it wrote, which is corruption however it arose.
  localparam logic [31:0] DONE_PC = 32'h8800_1054;

  // Each pass walks 20 KiB against a 16 KiB cache, so every pass
  // misses throughout. Ten is far below what the time limit allows
  // and far above what a stalled CPU can reach.
  localparam integer MIN_PASSES = 10;
  logic reached_done = 1'b0;
  logic [63:0] last_pc = 64'hx;
  integer      stuck = 0;
  integer      verify_passes = 0;

  always @(posedge clk93) begin
    if (!reset_93) begin
      if (debug_pc !== last_pc) begin
        last_pc <= debug_pc;
        stuck   <= 0;
      end else begin
        stuck <= stuck + 1;
      end
      if (debug_pc[31:0] == DONE_PC) reached_done <= 1'b1;

      if (debug_pc[31:0] == 32'h8800_104c && last_pc[31:0] != 32'h8800_104c)
        verify_passes <= verify_passes + 1;
    end
  end

  integer index;

  // A run that is merely slow and a run that has stopped look identical from
  // outside. Say which.
  initial begin
    forever begin
      #100000;
      $display("  [%0t] pc=%08x cpu_stores=%0d ata_stores=%0d index=%02x state=%0d",
               $time, debug_pc[31:0], cpu_stores, ata_stores,
               ata.data_index, ata.state);
    end
  end

  initial begin
    for (index = 0; index < ROM_BYTES; index = index + 1) rom[index] = 8'h00;

    // Phase 0: stage the loop body into RAM through the uncached alias, then
    // run it CACHED, exactly as the ATA bench does - the game's code runs from
    // cached RAM and that is what has to be exercised.
    patch_word('h00, 32'h3c03b000); // lui   $v1,0xb000
    patch_word('h04, 32'h3c09bfc0); // lui   $t1,0xbfc0     code source in ROM
    patch_word('h08, 32'h35290a00); // ori   $t1,$t1,0xa00
    patch_word('h0c, 32'h3c08a800); // lui   $t0,0xa800     RAM, uncached alias
    patch_word('h10, 32'h35081000); // ori   $t0,$t0,0x1000
    patch_word('h14, 32'h25210060); // addiu $at,$t1,0x60   96 bytes of code
    patch_word('h18, 32'h8d220000); // lw    $v0,0($t1)
    patch_word('h1c, 32'h25290004); // addiu $t1,$t1,4
    patch_word('h20, 32'had020000); // sw    $v0,0($t0)
    patch_word('h24, 32'h1521fffc); // bne   $t1,$at,0x18
    patch_word('h28, 32'h25080004); // addiu $t0,$t0,4      delay slot
    patch_word('h2c, 32'h3c198800); // lui   $t9,0x8800
    patch_word('h30, 32'h37391000); // ori   $t9,$t9,0x1000
    patch_word('h34, 32'h03200008); // jr    $t9            run it cached
    patch_word('h38, 32'h00000000); // nop


    // Fill 20 KiB, each word holding its own address. Cached stores, so this
    // exercises dirty writeback against scanout too.
    patch_word('ha00, 32'h3c088801); // lui   $t0,0x8801     dest 0x88010000
    patch_word('ha04, 32'h3c098801); // lui   $t1,0x8801     value = address
    patch_word('ha08, 32'h3c018801); // lui   $at,0x8801
    patch_word('ha0c, 32'h34215000); // ori   $at,$at,0x5000 end 0x88015000
    patch_word('ha10, 32'had090000); // sw    $t1,0($t0)
    patch_word('ha14, 32'h25290004); // addiu $t1,$t1,4
    patch_word('ha18, 32'h25080004); // addiu $t0,$t0,4
    patch_word('ha1c, 32'h1501fffc); // bne   $t0,$at,+0x10
    patch_word('ha20, 32'h00000000); // nop

    // Verify it, forever, striding one CACHE LINE at a time. 20 KiB against a
    // 16 KiB cache means every pass misses throughout; walking 4 bytes at a
    // time spent seven eighths of its instructions on loads that HIT, so a
    // pass cost 5120 iterations to produce 640 fills and only one pass fitted
    // in the time budget. A 32-byte stride produces the same 640 fills in 640
    // iterations - every load misses, which is the point of the bench.
    patch_word('ha24, 32'h3c088801); // lui   $t0,0x8801
    patch_word('ha28, 32'h3c098801); // lui   $t1,0x8801
    patch_word('ha2c, 32'h3c018801); // lui   $at,0x8801
    patch_word('ha30, 32'h34215000); // ori   $at,$at,0x5000
    patch_word('ha34, 32'h8d020000); // lw    $v0,0($t0)
    patch_word('ha38, 32'h14490006); // bne   $v0,$t1,+0x54  MISMATCH -> FAIL
    patch_word('ha3c, 32'h25290020); // addiu $t1,$t1,32     delay slot
    patch_word('ha40, 32'h25080020); // addiu $t0,$t0,32
    patch_word('ha44, 32'h1501fffb); // bne   $t0,$at,+0x34
    patch_word('ha48, 32'h00000000); // nop
    patch_word('ha4c, 32'h0a200409); // j     0x88001024     round again
    patch_word('ha50, 32'h00000000); // nop
    patch_word('ha54, 32'h0a200415); // j     0x88001054     FAIL, park here
    patch_word('ha58, 32'h00000000); // nop

    // 512 bytes of recognisable source data at 0x800.
    for (index = 0; index < BLOCK_WORDS; index = index + 1) begin
      rom['h800 + index * 2 + 0] = index[7:0];
      rom['h800 + index * 2 + 1] = 8'hA5;
    end

    $display("");
    $display("ATA PIO write block: the game's 256-store loop through the real");
    $display("CPU, bridge and ki_ata");
    $display("");

    repeat (8) @(posedge clk);
    reset <= 1'b0;
    init  <= 1'b0;
    repeat (400) @(posedge clk);

    img_mounted <= 1'b1;
    @(posedge clk);
    img_mounted <= 1'b0;

    // Index 1, not 0: ki_memory_bridge.sv:276 only recognises a BOOT
    // image at index 1, and boot_seen - and so boot_loaded - is gated on
    // that. Downloading at index 0 drains into nothing and the CPU is
    // never released.
    ioctl_index    <= 16'h0001;
    ioctl_download <= 1'b1;
    @(posedge clk);
    for (index = 0; index < DOWNLOAD_BYTES; index = index + 2)
      ioctl_beat(index);
    ioctl_download <= 1'b0;

    begin
      integer guard;
      guard = 0;
      while (!boot_loaded && guard < 200000) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (!boot_loaded) begin
        $display("FAIL: boot_loaded never asserted after %0d cycles", guard);
        $fatal(1);
      end
      $display("  download drained after %0d cycles", guard);
    end

    reset_1x <= 1'b0;
    reset_93 <= 1'b0;
  end

  initial begin
    wait (reached_done == 1'b1);
    repeat (50) @(posedge clk);
    $display("");
    $display("  scanout reads      : %0d", video_reads);
    $display("  fifoStall events   : %0d", fifostall_events);
    $display("  mem4_ready low     : %0d cycles", notready_cycles);
    $display("");
    $display("FAIL: the CPU read back a word it did not write.");
    $display("      pc parked at the mismatch trap, so cached memory returned");
    $display("      wrong data under scanout contention - REPRODUCED.");
    $fatal(1, "cache/scanout corruption reproduced");
  end

  initial begin
    forever begin
      @(posedge clk93);
      if (stuck > 400000) begin
        $display("");
        $display("DEADLOCK: pc stuck at %016x for %0d cycles", debug_pc, stuck);
        $display("  opcode=%08x errors=%02x", debug_opcode, debug_errors);
        $display("  cpu_stores=%0d ata_stores=%0d data_index=%02x state=%0d",
                 cpu_stores, ata_stores, ata.data_index, ata.state);
        $display("  status=%02x sd_wr=%0b sd_ack=%0b",
                 ata.status, sd_wr, sd_ack);
        $display("  io_request=%0b io_done=%0b io_address=%08x io_write=%0b",
                 io_request, io_done, io_address, io_write);
        // Which side of the CPU/bridge handshake is waiting, and on what.
        $display("  cpu_request=%0b cpu_rnw=%0b cpu_done=%0b cpu_grant=%0b",
                 cpu_request, cpu_rnw, cpu_done, cpu_grant);
        $display("  cpu_address=%08x cpu_size=%0d cpu_req64=%0b cache_ready=%0b",
                 cpu_address, cpu_size, cpu_req64, cpu_cache_data_ready);
        $display("  bridge.state=%0d cpu_pending=%0b sdram_ready=%0b",
                 bridge.state, bridge.cpu_pending, sdram_ready);
        // The CPU latches its own stall diagnosis at 4095 stalled cycles
        // (cpu.vhd:4885), long before this watchdog. The wrapper leaves these
        // ports open, so read them out of the instance rather than re-deriving
        // what the core already recorded.
        $display("  stall_pc=%08x stall_addr=%08x",
                 cpu.core.debug_stall_pc, cpu.core.debug_stall_addr);
        $display("  stall_why=%032b", cpu.core.debug_stall_why);
        $display("    UseCache=%0b MemWrite=%0b fifoStall=%0b COP1=%0b",
                 cpu.core.debug_stall_why[31], cpu.core.debug_stall_why[30],
                 cpu.core.debug_stall_why[29], cpu.core.debug_stall_why[28]);
        $display("    dc_readdone=%0b dc_writedone=%0b CmdDone=%0b TLBDone=%0b",
                 cpu.core.debug_stall_why[27], cpu.core.debug_stall_why[26],
                 cpu.core.debug_stall_why[25], cpu.core.debug_stall_why[24]);
        $display("    fifo_ready=%0b mem4_req=%0b mem4_rnw=%0b muxStage4=%0b",
                 cpu.core.debug_stall_why[23], cpu.core.debug_stall_why[22],
                 cpu.core.debug_stall_why[21], cpu.core.debug_stall_why[20]);
        $display("    mem_rnw=%0b mem_done=%0b fin_read=%0b fin_instr=%0b",
                 cpu.core.debug_stall_why[19], cpu.core.debug_stall_why[18],
                 cpu.core.debug_stall_why[17], cpu.core.debug_stall_why[16]);
        $display("    exeUseCache=%0b exeRead=%0b exeWrite=%0b exeNew=%0b",
                 cpu.core.debug_stall_why[15], cpu.core.debug_stall_why[14],
                 cpu.core.debug_stall_why[13], cpu.core.debug_stall_why[12]);
        $display("    dcEnable=%0b dc_readena=%0b dc_writeena=%0b dc_busy=%0b",
                 cpu.core.debug_stall_why[11], cpu.core.debug_stall_why[10],
                 cpu.core.debug_stall_why[9], cpu.core.debug_stall_why[8]);
        $display("    fifoEmpty=%0b fifoBlock=%0b fifoRd=%0b paused=%0b",
                 cpu.core.debug_stall_why[7], cpu.core.debug_stall_why[6],
                 cpu.core.debug_stall_why[5], cpu.core.debug_stall_why[4]);
        $display("  stall_status=%032b", cpu.core.debug_stall_status);
        $display("");
        $fatal(1, "the PIO write block deadlocked");
      end
    end
  end

  // Running to the limit without tripping the trap IS the pass condition.
  initial begin
    #9000000;
    $display("");
    $display("  scanout reads    : %0d", video_reads);
    $display("  fifoStall events : %0d", fifostall_events);
    $display("  mem4_ready low   : %0d cycles", notready_cycles);
    $display("  final pc         : %08x", debug_pc[31:0]);
    $display("  cpu errors       : %02x", debug_errors);
    $display("");
    if (debug_errors != 6'd0) begin
      $display("FAIL: the CPU raised an error flag");
      $fatal(1, "cpu error under contention");
    end
    $display("  verify passes    : %0d", verify_passes);
    $display("");
    // A bench that proves nothing must not report PASS. MIN_PASSES is a floor
    // on work actually done, not a performance target.
    if (verify_passes < MIN_PASSES) begin
      $display("FAIL: only %0d verify passes completed, needed %0d.",
               verify_passes, MIN_PASSES);
      $display("      The CPU did not walk the region enough times for this");
      $display("      run to say anything about cached reads under scanout.");
      $fatal(1, "bench did not exercise the path it claims to test");
    end
    $display("PASS: no cached read returned wrong data under scanout");
    $display("      contention. This does NOT clear the hardware fault - it");
    $display("      bounds it: whatever corrupts the intro video is not");
    $display("      reproduced by cache thrash against scanout alone.");
    $finish;
  end
endmodule

`default_nettype wire
