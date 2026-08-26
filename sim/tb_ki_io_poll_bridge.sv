`timescale 1ns/1ps
`default_nettype none


module tb_ki_io_poll_bridge;
  localparam real    TCK = 20.0;
  localparam integer ROM_BYTES = 524288;
  // Only the first 0x30 bytes are the program and the icache never fetches
  // past 0x20, so a short image is enough - and the ioctl download writes
  // every byte through the real SDRAM model, which is what makes a full
  // 8 KiB image take minutes of wall time for no extra coverage.
  localparam integer DOWNLOAD_BYTES = 4096;
  localparam integer ITERATIONS = 16;

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

  // ---- bridge <-> board I/O -------------------------------------------
  wire        io_request, io_write;
  wire [31:0] io_address, io_write_data;
  wire  [3:0] io_byte_enable;
  wire [31:0] io_read_data;
  wire        io_done;

  ki_board_io board_io (
    .clk(clk), .reset(reset), .game_ki2(1'b0),
    .bus_request(io_request), .bus_write(io_write),
    .bus_address(io_address), .bus_write_data(io_write_data),
    .bus_byte_enable(io_byte_enable),
    .bus_read_data(io_read_data), .bus_done(io_done),
    .input_p1(32'hffff_ffff), .input_p2(32'hffff_ffff),
    .input_volume(32'hffff_ffff), .input_dip(32'hffff_a55a),
    .input_unused(32'hffff_ffff),
    .irq_vblank(1'b0), .irq_ata(1'b0), .cpu_irq(),
    .framebuffer_base(), .sound_reset(), .sound_data(),
    .sound_data_strobe(), .coin_control()
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

  integer io_reads = 0;
  always @(posedge clk)
    if (io_request && !io_write && io_address == 32'h1000_00a0)
      io_reads = io_reads + 1;

  localparam logic [31:0] DONE_PC = 32'hbfc0_0028;
  logic reached_done = 1'b0;
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
      if (debug_pc[31:0] == DONE_PC) reached_done <= 1'b1;
    end
  end

  integer index;

  initial begin
    for (index = 0; index < ROM_BYTES; index = index + 1) rom[index] = 8'h00;

    //  00  lui  v1,0xb000
    //  04  lui  at,0
    //  08  ori  at,at,ITERATIONS
    //  0C  lw   $0,0xa0(v1)     <- the stalling instruction
    //  10  mfc0 v0,Cause
    //  14  beqz at,0x28
    //  18  andi v0,v0,0x0800    delay slot
    //  1C  beqz v0,0x0C
    //  20  addi at,at,-1        delay slot
    //  24  nop
    //  28  j 0x28               DONE
    patch_word('h00, 32'h3c03b000);
    patch_word('h04, 32'h3c010000);
    patch_word('h08, 32'h34210000 | ITERATIONS[15:0]);
    patch_word('h0c, 32'h8c6000a0);
    patch_word('h10, 32'h40026800);
    patch_word('h14, 32'h10200004);
    patch_word('h18, 32'h30420800);
    patch_word('h1c, 32'h1040fffb);
    patch_word('h20, 32'h2021ffff);
    patch_word('h24, 32'h00000000);
    patch_word('h28, 32'h0bf0000a);
    patch_word('h2c, 32'h00000000);

    $display("");
    $display("I/O poll loop through the REAL bridge and ki_board_io");
    $display("");

    repeat (8) @(posedge clk);
    reset <= 1'b0;
    init  <= 1'b0;
    repeat (400) @(posedge clk);

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

    // Poll rather than wait a fixed number of cycles: boot_loaded needs the
    // download queue drained into SDRAM and the bridge back in IDLE, and how
    // long that takes depends on the image size.
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
    $display("  boot image loaded, releasing the CPU");

    reset_1x <= 1'b0;
    reset_93 <= 1'b0;
  end

  initial begin
    wait (reached_done == 1'b1);
    repeat (4) @(posedge clk93);
    $display("");
    $display("  reached DONE with %0d I/O reads (expected %0d)",
             io_reads, ITERATIONS + 1);
    if (io_reads != ITERATIONS + 1) begin
      $display("FAIL: %0d I/O reads, expected %0d", io_reads, ITERATIONS + 1);
      $fatal(1, "wrong number of I/O reads");
    end
    $display("");
    $display("PASS: the poll loop completes through the real bridge");
    $display("");
    $finish;
  end

  initial begin
    forever begin
      @(posedge clk93);
      if (stuck > 20000) begin
        $display("");
        $display("DEADLOCK: pc stuck at %016x for %0d cycles",
                 debug_pc, stuck);
        $display("          io_reads=%0d errors=%02x bridge_state=%0d",
                 io_reads, debug_errors, bridge.state);
        $display("          io_request=%0b io_done=%0b io_address=%08x",
                 io_request, io_done, io_address);
        $display("          cpu_request=%0b cpu_done=%0b cpu_address=%08x",
                 cpu_request, cpu_done, cpu_address);
        $display("");
        $fatal(1, "the poll loop deadlocked through the real bridge");
      end
    end
  end

  initial begin
    #60000000;
    $display("FAIL: timeout, pc=%016x io_reads=%0d errors=%02x",
             debug_pc, io_reads, debug_errors);
    $fatal(1);
  end
endmodule

`default_nettype wire
