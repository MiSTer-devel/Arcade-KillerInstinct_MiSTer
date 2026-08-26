`timescale 1ns/1ps
`default_nettype none

// The bridge and ki_board_io disagree about which addresses are I/O.
//
//   ki_memory_bridge.sv:311   io_selected = addr in 0x10000080..0x100000bb
//                                           or the ATA ranges
//   ki_board_io.sv:40         io_selected = addr in 0x10000080..0x100000bb
//                                           AND addr[1:0] == 2'b00
//
// The bridge routes ANY address in that window to I/O. ki_board_io answers
// only word-aligned ones. So an unaligned access into the window is routed to
// I/O, `bus_done` never asserts, and the bridge waits in IO_WAIT forever -
// there is no timeout on that state and no default response.
//
// This is a deadlock reachable by a single instruction: `lbu` or `lhu` from an
// odd address in the I/O window. Any code that reads an I/O register a byte at
// a time hangs the machine.
//
// Just the bridge and ki_board_io: an I/O access never touches SDRAM, so
// nothing else is needed and the test runs in milliseconds. That matters -
// the full CPU-plus-SDRAM version of this question spends minutes in its
// ioctl download before it reaches the first instruction.

module tb_ki_io_align;
  import ki_board_pkg::*;

  logic clk = 1'b0;
  logic reset = 1'b1;
  always #10 clk = ~clk;

  logic        cpu_request = 1'b0;
  logic        cpu_rnw = 1'b1;
  logic [31:0] cpu_address = 32'd0;
  logic        cpu_req64 = 1'b0;
  logic  [2:0] cpu_size = 3'd1;
  logic  [7:0] cpu_write_mask = 8'h00;
  logic [63:0] cpu_data_write = 64'd0;
  wire  [63:0] cpu_data_read;
  wire         cpu_done, cpu_grant;
  wire  [63:0] cpu_cache_data;
  wire         cpu_cache_data_ready;

  wire        io_request, io_write;
  wire [31:0] io_address, io_write_data;
  wire  [3:0] io_byte_enable;
  wire [31:0] io_read_data;
  wire        io_done;

  wire [24:0] bridge_address;
  wire [63:0] bridge_write_data;
  wire  [7:0] bridge_byte_enable;
  wire  [4:0] bridge_burst;
  wire        bridge_read, bridge_write;
  wire [28:0] ddram_addr;
  wire  [7:0] ddram_burstcnt, ddram_be;
  wire [63:0] ddram_din;
  wire        ddram_rd, ddram_we;

  integer errors = 0;

  ki_memory_bridge bridge (
    .clk(clk), .ddr_clk(clk), .reset(reset),
    .cpu_request(cpu_request), .cpu_rnw(cpu_rnw),
    .cpu_address(cpu_address), .cpu_req64(cpu_req64), .cpu_size(cpu_size),
    .cpu_write_mask(cpu_write_mask), .cpu_data_write(cpu_data_write),
    .cpu_data_read(cpu_data_read), .cpu_done(cpu_done), .cpu_grant(cpu_grant),
    .cpu_cache_data(cpu_cache_data),
    .cpu_cache_data_ready(cpu_cache_data_ready),
    .io_request(io_request), .io_write(io_write), .io_address(io_address),
    .io_write_data(io_write_data), .io_byte_enable(io_byte_enable),
    .io_read_data(io_read_data), .io_done(io_done),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_index(16'd0),
    .ioctl_addr(27'd0), .ioctl_dout(8'd0), .ioctl_wait(),
    .boot_loaded(),
    .video_request(1'b0), .video_address(28'd0), .video_words(3'd1),
    .video_data(), .video_data_valid(), .video_done(),
    .sdram_address(bridge_address), .sdram_write_data(bridge_write_data),
    .sdram_byte_enable(bridge_byte_enable), .sdram_burst(bridge_burst),
    .sdram_read(bridge_read), .sdram_write(bridge_write),
    .sdram_read_data(16'd0), .sdram_data_valid(1'b0), .sdram_done(1'b0),
    .sdram_ready(1'b1),
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

  ki_board_io board_io (
    .clk(clk), .reset(reset), .game_ki2(1'b0),
    .bus_request(io_request), .bus_write(io_write),
    .bus_address(io_address), .bus_write_data(io_write_data),
    .bus_byte_enable(io_byte_enable),
    .bus_read_data(io_read_data), .bus_done(io_done),
    .input_p1(32'h1111_1111), .input_p2(32'h2222_2222),
    .input_volume(32'h3333_3333), .input_dip(32'hdead_beef),
    .input_unused(32'h5555_5555),
    .irq_vblank(1'b0), .irq_ata(1'b0), .cpu_irq(),
    .framebuffer_base(), .sound_reset(), .sound_data(),
    .sound_data_strobe(), .coin_control()
  );

  // One CPU read. Returns whether it completed within the guard, so the test
  // can report a hang instead of hanging.
  task automatic io_read(input logic [31:0] address,
                         output logic completed,
                         output logic [31:0] value);
    integer guard;
    begin
      @(posedge clk);
      cpu_address <= address;
      cpu_rnw     <= 1'b1;
      cpu_req64   <= 1'b0;
      cpu_size    <= 3'd1;
      cpu_request <= 1'b1;
      @(posedge clk);
      cpu_request <= 1'b0;
      completed = 1'b0;
      guard = 0;
      while (!completed && guard < 500) begin
        @(posedge clk);
        if (cpu_done) completed = 1'b1;
        guard = guard + 1;
      end
      value = cpu_data_read[31:0];
      @(posedge clk);
    end
  endtask

  logic        ok;
  logic [31:0] got;

  initial begin
    repeat (8) @(posedge clk);
    reset <= 1'b0;
    repeat (8) @(posedge clk);

    $display("");
    $display("bridge <-> ki_board_io address-window agreement");
    $display("");

    // Word-aligned reads: the addresses the game and boot ROM use.
    io_read(32'h1000_0080, ok, got);
    if (!ok) begin
      $display("FAIL: aligned read of 1000_0080 never completed");
      errors = errors + 1;
    end else $display("  1000_0080 -> %08x", got);

    io_read(32'h1000_00a0, ok, got);
    if (!ok) begin
      $display("FAIL: aligned read of 1000_00a0 never completed");
      errors = errors + 1;
    end else $display("  1000_00a0 -> %08x  (the address the game polls)", got);

    // Unaligned reads into the SAME window. The bridge routes these to I/O;
    // ki_board_io refuses them because addr[1:0] != 0, so bus_done never
    // asserts and IO_WAIT never exits.
    io_read(32'h1000_00a1, ok, got);
    if (!ok) begin
      $display("FAIL: UNALIGNED read of 1000_00a1 never completed - the bridge is stuck in IO_WAIT");
      errors = errors + 1;
    end else $display("  1000_00a1 -> %08x", got);

    io_read(32'h1000_00a2, ok, got);
    if (!ok) begin
      $display("FAIL: UNALIGNED read of 1000_00a2 never completed - the bridge is stuck in IO_WAIT");
      errors = errors + 1;
    end else $display("  1000_00a2 -> %08x", got);

    io_read(32'h1000_0083, ok, got);
    if (!ok) begin
      $display("FAIL: UNALIGNED read of 1000_0083 never completed - the bridge is stuck in IO_WAIT");
      errors = errors + 1;
    end else $display("  1000_0083 -> %08x", got);

    // And the machine must still work afterwards - a stuck IO_WAIT would take
    // every later access with it.
    io_read(32'h1000_0088, ok, got);
    if (!ok) begin
      $display("FAIL: aligned read of 1000_0088 after the unaligned ones never completed");
      errors = errors + 1;
    end else $display("  1000_0088 -> %08x  (recovered)", got);

    $display("");
    if (errors == 0)
      $display("tb_ki_io_align: PASS");
    else
      $display("tb_ki_io_align: FAIL: %0d error(s)", errors);
    $display("");
    $finish;
  end

  initial begin
    #200000;
    $display("tb_ki_io_align: FAIL: timeout");
    $fatal(1);
  end
endmodule

`default_nettype wire
