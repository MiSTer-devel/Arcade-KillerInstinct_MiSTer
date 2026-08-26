`timescale 1ns/1ps
`default_nettype none

module tb_ki_icache_stream;
  localparam real    TCK = 20.0;
  localparam integer ROM_BYTES = 524288;
  localparam integer DOWNLOAD_BYTES = 4096;

  // 1024 lines x 32 bytes = 32 KiB, twice the instruction cache.
  localparam integer CODE_LINES = 1024;
  // Completed passes required before this run may claim anything. Each pass is
  // CODE_LINES instruction-cache fills, so two passes is 2048 fills against
  // the one fill tb_ki_cache_scanout manages.
  localparam integer MIN_PASSES = 2;

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
  wire        board_io_done, ata_done;

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

  ki_ata ata (
    .clk(clk), .reset(reset), .game_ki2(1'b0),
    .bus_request(io_request), .bus_write(io_write),
    .bus_address(io_address), .bus_write_data(io_write_data),
    .bus_byte_enable(io_byte_enable),
    .bus_read_data(ata_read_data), .bus_done(ata_done), .irq(),
    .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd1048576),
    .sd_lba(), .sd_rd(), .sd_wr(), .sd_ack(1'b0),
    .sd_buff_addr(8'd0), .sd_buff_dout(16'd0),
    .sd_buff_din(), .sd_buff_wr(1'b0),
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
  // The real reader needs a 32-byte burst about every 3.2 us - roughly one per
  // 160 core clocks - so this is a realistic cadence rather than a saturating
  // one. Saturating the port starves the CPU without making the INTERLEAVING,
  // which is what matters here, any more representative.
  localparam integer VIDEO_GAP = 120;
  integer video_wait = 0;
  integer video_reads = 0;

  always @(posedge clk) begin
    if (reset) begin
      video_request <= 1'b0;
      video_address <= 28'h010_0000;
      video_wait <= 0;
    end else if (video_done) begin
      video_request <= 1'b0;
      video_address <= (video_address + 28'd32) & 28'h01f_ffff;
      video_wait <= VIDEO_GAP;
      video_reads <= video_reads + 1;
    end else if (!video_request) begin
      if (video_wait != 0) video_wait <= video_wait - 1;
      else video_request <= 1'b1;
    end
  end

  task automatic patch_word(input integer offset, input logic [31:0] value);
    begin
      rom[offset + 0] = value[7:0];
      rom[offset + 1] = value[15:8];
      rom[offset + 2] = value[23:16];
      rom[offset + 3] = value[31:24];
    end
  endtask

  // HALFWORDS at even byte addresses. ioctl_dout is 16 bits and the bridge
  // assembles a 64-bit word from four of them selected by
  // incoming_download_address[2:1]; driving one BYTE per address makes the
  // selector run 0,0,1,1,2,2,3,3 and every lane gets the wrong half.
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

  // The trap the checker parks at when a pass did not execute exactly
  // CODE_LINES counted instructions.
  localparam logic [31:0] FAIL_PC = 32'h8800_1030;

  logic reached_fail = 1'b0;
  logic [63:0] last_pc = 64'hx;
  integer      stuck = 0;

  always @(posedge clk93) begin
    if (!reset_93) begin
      if (debug_pc !== last_pc) begin
        last_pc <= debug_pc;
        stuck   <= 0;
      end else begin
        stuck <= stuck + 1;
      end
      if (debug_pc[31:0] == FAIL_PC) reached_fail <= 1'b1;
    end
  end

  integer index;

  initial begin
    for (index = 0; index < ROM_BYTES; index = index + 1) rom[index] = 8'h00;

    // ---- generator, runs once from the boot ROM (KSEG1, uncached) ----
    //
    // Writes the code block through the UNCACHED alias 0xA802xxxx so it lands
    // in memory without going through the data cache. Executing it from the
    // CACHED alias 0x8802xxxx is then a genuine instruction-cache fill from
    // SDRAM, which is the whole point.
    patch_word('h00, 32'h3c08a802); // lui   $t0,0xa802   write ptr
    patch_word('h04, 32'h3c09a802); // lui   $t1,0xa802
    patch_word('h08, 32'h35298000); // ori   $t1,$t1,0x8000  end = base + 32 KiB
    // The seven words of one chain line, held in $t2..$t8.
    // 0xDEE50000, not 0xDCE5: the base register is bits 25:21, so $s7 is
    // 23<<21 = 0x02E00000. The first version wrote 0xDCE50000, which decodes
    // as `ld $a1,0($a3)` - the loop COUNTER as a base address - and
    // tools/disasm.py caught it before the run.
    patch_word('h0c, 32'h3c0adee5); // lui   $t2,0xdee5    ld    $a1,0($s7)
    patch_word('h10, 32'h3c0b26f7); // lui   $t3,0x26f7
    patch_word('h14, 32'h356b0020); // ori   $t3,$t3,0x20  addiu $s7,$s7,32
    patch_word('h18, 32'h3c0cfe85); // lui   $t4,0xfe85    sd    $a1,0($s4)
    patch_word('h1c, 32'h3c0d2694); // lui   $t5,0x2694
    patch_word('h20, 32'h35ad0020); // ori   $t5,$t5,0x20  addiu $s4,$s4,32
    patch_word('h24, 32'h3c0e24e7); // lui   $t6,0x24e7
    patch_word('h28, 32'h35ce0001); // ori   $t6,$t6,1     addiu $a3,$a3,1
    patch_word('h2c, 32'h3c0f02c0); // lui   $t7,0x02c0
    patch_word('h30, 32'h35ef0008); // ori   $t7,$t7,8     jr    $s6
    patch_word('h34, 32'h3c1826d6); // lui   $t8,0x26d6
    patch_word('h38, 32'h37180020); // ori   $t8,$t8,0x20  addiu $s6,$s6,32
    // gen loop at 0x3c
    patch_word('h3c, 32'had0a0000); // sw    $t2,0($t0)
    patch_word('h40, 32'had0b0004); // sw    $t3,4($t0)
    patch_word('h44, 32'had0c0008); // sw    $t4,8($t0)
    patch_word('h48, 32'had0d000c); // sw    $t5,12($t0)
    patch_word('h4c, 32'had0e0010); // sw    $t6,16($t0)
    patch_word('h50, 32'had0f0014); // sw    $t7,20($t0)
    patch_word('h54, 32'had180018); // sw    $t8,24($t0)
    patch_word('h58, 32'h25080020); // addiu $t0,$t0,32
    patch_word('h5c, 32'h1509fff7); // bne   $t0,$t1,0x3c
    patch_word('h60, 32'h00000000); // nop

    // Patch the LAST line to leave the chain for the checker instead of
    // running off the end of the block. The jr is word 5 (+20) now.
    patch_word('h64, 32'h3c0da802); // lui   $t5,0xa802
    patch_word('h68, 32'h35ad7fe0); // ori   $t5,$t5,0x7fe0  last line
    patch_word('h6c, 32'h3c0e0a00); // lui   $t6,0x0a00
    patch_word('h70, 32'h35ce0400); // ori   $t6,$t6,0x0400  j 0x88001000
    patch_word('h74, 32'hadae0014); // sw    $t6,20($t5)
    patch_word('h78, 32'hada00018); // sw    $0,24($t5)

    // Copy the checker from ROM 0xBFC00900 into RAM at 0xA8001000 so it also
    // runs cached.
    patch_word('h7c, 32'h3c0dbfc0); // lui   $t5,0xbfc0
    patch_word('h80, 32'h35ad0900); // ori   $t5,$t5,0x900
    patch_word('h84, 32'h3c0ea800); // lui   $t6,0xa800
    patch_word('h88, 32'h35ce1000); // ori   $t6,$t6,0x1000
    patch_word('h8c, 32'h25af0038); // addiu $t7,$t5,56     14 words
    patch_word('h90, 32'h8db80000); // lw    $t8,0($t5)
    patch_word('h94, 32'hadd80000); // sw    $t8,0($t6)
    patch_word('h98, 32'h25ad0004); // addiu $t5,$t5,4
    patch_word('h9c, 32'h15affffc); // bne   $t5,$t7,0x90
    patch_word('ha0, 32'h25ce0004); // addiu $t6,$t6,4      delay slot

    // Arm and enter. $s6 points at the line AFTER the first, because `jr $s6`
    // reads the register before its delay slot advances it. $s7 is the data
    // source (the code block, already written) and $s4 the destination.
    patch_word('ha4, 32'h00003825); // move  $a3,$zero      counter
    patch_word('ha8, 32'h0000a825); // move  $s5,$zero      passes
    patch_word('hac, 32'h3c168802); // lui   $s6,0x8802
    patch_word('hb0, 32'h36d60020); // ori   $s6,$s6,0x20
    patch_word('hb4, 32'h3c178802); // lui   $s7,0x8802     data source
    patch_word('hb8, 32'h3c148803); // lui   $s4,0x8803     data dest
    patch_word('hbc, 32'h3c198802); // lui   $t9,0x8802
    patch_word('hc0, 32'h03200008); // jr    $t9            enter the chain
    patch_word('hc4, 32'h00000000); // nop

    // ---- the checker, staged to 0x88001000 and run CACHED ----
    patch_word('h900, 32'h240c0400); // li    $t4,1024
    patch_word('h904, 32'h14ec000a); // bne   $a3,$t4,0x88001030   MISMATCH
    patch_word('h908, 32'h00000000); // nop
    patch_word('h90c, 32'h26b50001); // addiu $s5,$s5,1     pass++
    patch_word('h910, 32'h00003825); // move  $a3,$zero
    patch_word('h914, 32'h3c168802); // lui   $s6,0x8802
    patch_word('h918, 32'h36d60020); // ori   $s6,$s6,0x20
    patch_word('h91c, 32'h3c178802); // lui   $s7,0x8802    re-arm source
    patch_word('h920, 32'h3c148803); // lui   $s4,0x8803    re-arm dest
    patch_word('h924, 32'h3c198802); // lui   $t9,0x8802
    patch_word('h928, 32'h03200008); // jr    $t9           round again
    patch_word('h92c, 32'h00000000); // nop
    patch_word('h930, 32'h0a00040c); // j     0x88001030    FAIL, park here
    patch_word('h934, 32'h00000000); // nop

    $display("");
    $display("Instruction-stream integrity under scanout contention");
    $display("  %0d lines x 32 bytes = %0d KiB of code against a 16 KiB icache",
             CODE_LINES, (CODE_LINES * 32) / 1024);
    $display("");

    repeat (8) @(posedge clk);
    reset <= 1'b0;
    init  <= 1'b0;
    repeat (400) @(posedge clk);

    // Index 1: the bridge only recognises a BOOT image at index 1, and
    // boot_loaded is gated on that.
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
        $fatal(1, "download never drained");
      end
      $display("  download drained after %0d cycles", guard);
    end

    reset_1x <= 1'b0;
    reset_93 <= 1'b0;
  end

  // A run that is merely slow and one that has stopped look identical from
  // outside. Say which.
  initial begin
    forever begin
      #500000;
      $display("  [%0t] pc=%08x a3=%0d passes=%0d scanout=%0d",
               $time, debug_pc[31:0], debug_a3[31:0], debug_s5[31:0],
               video_reads);
    end
  end

  initial begin
    wait (reached_fail == 1'b1);
    repeat (50) @(posedge clk);
    $display("");
    $display("  completed passes : %0d", debug_s5[31:0]);
    $display("  counted this pass: %0d, expected %0d",
             debug_a3[31:0], CODE_LINES);
    $display("  scanout reads    : %0d", video_reads);
    $display("");
    $display("FAIL: a pass did not execute exactly %0d counted instructions.",
             CODE_LINES);
    $display("      The instruction stream fetched from cached RAM under");
    $display("      scanout contention was not what memory holds - REPRODUCED.");
    $fatal(1, "instruction-stream corruption reproduced");
  end

  initial begin
    forever begin
      @(posedge clk93);
      if (stuck > 400000) begin
        $display("");
        $display("DEADLOCK: pc stuck at %016x for %0d cycles", debug_pc, stuck);
        $display("  opcode=%08x errors=%02x", debug_opcode, debug_errors);
        $display("  a3=%0d passes=%0d s6=%08x",
                 debug_a3[31:0], debug_s5[31:0], debug_s6[31:0]);
        $display("  cpu_request=%0b cpu_rnw=%0b cpu_done=%0b cpu_grant=%0b",
                 cpu_request, cpu_rnw, cpu_done, cpu_grant);
        $display("  cpu_address=%08x bridge.state=%0d sdram_ready=%0b",
                 cpu_address, bridge.state, sdram_ready);
        $display("  stall_pc=%08x stall_addr=%08x",
                 cpu.core.debug_stall_pc, cpu.core.debug_stall_addr);
        $display("");
        $fatal(1, "the instruction chain deadlocked");
      end
    end
  end

  // Longer than the load/store-free version needed: setup is now 7168 uncached
  // stores rather than 3072, and each hop costs an instruction fill, a data
  // fill and a dirty writeback instead of one fill.
  initial begin
    #16000000;
    $display("");
    $display("  completed passes : %0d", debug_s5[31:0]);
    $display("  scanout reads    : %0d", video_reads);
    $display("  final pc         : %08x", debug_pc[31:0]);
    $display("  cpu errors       : %02x", debug_errors);
    $display("");
    if (debug_errors != 6'd0) begin
      $display("FAIL: the CPU raised an error flag");
      $fatal(1, "cpu error under contention");
    end
    if (debug_s5[31:0] < MIN_PASSES) begin
      $display("FAIL: only %0d passes completed, needed %0d.",
               debug_s5[31:0], MIN_PASSES);
      $display("      That is %0d instruction-cache fills, too few for this",
               debug_s5[31:0] * CODE_LINES);
      $display("      run to say anything about cached fetch under scanout.");
      $fatal(1, "bench did not exercise the path it claims to test");
    end
    $display("PASS: %0d passes x %0d lines = %0d instruction-cache fills,",
             debug_s5[31:0], CODE_LINES, debug_s5[31:0] * CODE_LINES);
    $display("      every one of them verified by the CPU's own count.");
    $display("      This does NOT clear the hardware fault - it bounds it:");
    $display("      cached instruction fetch against scanout alone does not");
    $display("      reproduce what corrupts 88028DCC during video.");
    $finish;
  end
endmodule

`default_nettype wire
