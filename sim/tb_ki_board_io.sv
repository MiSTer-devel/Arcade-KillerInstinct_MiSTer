// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_board_io;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic game_ki2 = 1'b0;
  logic request = 1'b0;
  logic write = 1'b0;
  logic [31:0] address = 32'h0;
  logic [31:0] write_data = 32'h0;
  logic [3:0] byte_enable = 4'h0;
  logic [31:0] read_data;
  logic done;
  logic [1:0] cpu_irq;
  // Driven, not tied. These were constants - irq_vblank at 1 and irq_ata at 0 -
  // so the ATA half of this bus was never exercised and `cpu_irq == 2'b01`
  // passed without proving anything about it. The disk driver polls COP0 Cause
  // bit 0x0800, which is irqRequest(1), which is THIS bit.
  logic irq_vblank = 1'b1;
  logic irq_ata = 1'b0;
  logic [18:0] framebuffer_base;
  logic sound_reset;
  logic [31:0] sound_data;
  logic sound_strobe;
  logic [31:0] coin_control;

  always #5 clk = !clk;

  ki_board_io dut (
    .clk,
    .reset,
    .game_ki2,
    .bus_request(request),
    .bus_write(write),
    .bus_address(address),
    .bus_write_data(write_data),
    .bus_byte_enable(byte_enable),
    .bus_read_data(read_data),
    .bus_done(done),
    .input_p1(32'h1111_1111),
    .input_p2(32'h2222_2222),
    .input_volume(32'h3333_3333),
    .input_dip(32'h4444_4444),
    .input_unused(32'hffff_ffff),
    .irq_vblank(irq_vblank),
    .irq_ata(irq_ata),
    .cpu_irq,
    .framebuffer_base,
    .sound_reset,
    .sound_data,
    .sound_data_strobe(sound_strobe),
    .coin_control
  );

  task automatic bus_read(input logic [31:0] addr, input logic [31:0] expected);
    address = addr;
    write = 1'b0;
    request = 1'b1;
    #1;
    assert (done && (read_data == expected))
      else $fatal(1, "read %08x returned %08x", addr, read_data);
    @(posedge clk);
    request = 1'b0;
  endtask

  task automatic bus_write_word(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  be
  );
    address = addr;
    write_data = data;
    byte_enable = be;
    write = 1'b1;
    request = 1'b1;
    @(posedge clk);
    #1;
    request = 1'b0;
    write = 1'b0;
  endtask

  initial begin
    repeat (2) @(posedge clk);
    reset = 1'b0;

    assert (framebuffer_base == 19'h3_0000);

    // cpu_irq = {irq_ata, irq_vblank}. Bit 1 becomes COP0 Cause bit 11
    // (0x0800) via irqRequest(1) -> interruptPending(3), which is the bit the
    // disk driver's wait routine at 8802DBC0 polls. All four combinations, so
    // a swapped pair or a stuck bit cannot pass.
    irq_vblank = 1'b1; irq_ata = 1'b0; @(posedge clk); #1;
    assert (cpu_irq == 2'b01) else $fatal(1, "vblank alone should be cpu_irq[0]");
    irq_vblank = 1'b0; irq_ata = 1'b1; @(posedge clk); #1;
    assert (cpu_irq == 2'b10)
      else $fatal(1, "ATA alone should be cpu_irq[1] - this is Cause bit 0x0800");
    irq_vblank = 1'b1; irq_ata = 1'b1; @(posedge clk); #1;
    assert (cpu_irq == 2'b11) else $fatal(1, "both sources should be visible");
    irq_vblank = 1'b0; irq_ata = 1'b0; @(posedge clk); #1;
    assert (cpu_irq == 2'b00) else $fatal(1, "neither source should be asserted");
    irq_vblank = 1'b1; @(posedge clk); #1;

    bus_read(32'h1000_0080, 32'h1111_1111);
    bus_read(32'h1000_0088, 32'h2222_2222);
    bus_read(32'h1000_00a0, 32'h4444_4444);

    bus_write_word(32'h1000_0080, 32'h0000_0004, 4'b0001);
    assert (framebuffer_base == 19'h5_8000);

    bus_write_word(32'h1000_0098, 32'ha5a5_5a5a, 4'b1111);
    assert (sound_data == 32'ha5a5_5a5a);
    bus_write_word(32'h1000_0090, 32'h0000_0002, 4'b0001);
    assert (sound_strobe);
    @(posedge clk);
    #1;
    assert (!sound_strobe);

    game_ki2 = 1'b1;
    bus_read(32'h1000_0080, 32'h3333_3333);
    bus_read(32'h1000_0098, 32'h1111_1111);
    bus_write_word(32'h1000_0098, 32'h0000_0000, 4'b0001);
    assert (framebuffer_base == 19'h3_0000);
    bus_write_word(32'h1000_00b8, 32'h1234_5678, 4'b0011);
    assert (coin_control == 32'h0000_5678);

    $display("tb_ki_board_io: PASS");
    $finish;
  end
endmodule

`default_nettype wire
