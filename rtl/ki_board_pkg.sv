// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

package ki_board_pkg;
  localparam logic [31:0] KI_LOW_RAM_BASE  = 32'h0000_0000;
  localparam logic [31:0] KI_LOW_RAM_LAST  = 32'h0007_ffff;
  localparam logic [31:0] KI_MAIN_RAM_BASE = 32'h0800_0000;
  // Sixteen 1M x 4 DRAMs provide 8 MiB, so address bit 23 is not presented to
  // the memory array.  The service diagnostic proves that the following ninth
  // MiB is still selected and mirrors the first MiB of main RAM.
  localparam logic [31:0] KI_MAIN_RAM_LAST = 32'h087f_ffff;
  localparam logic [31:0] KI_MAIN_RAM_ALIAS_BASE = 32'h0880_0000;
  localparam logic [31:0] KI_MAIN_RAM_ALIAS_LAST = 32'h088f_ffff;
  localparam logic [31:0] KI_IO_BASE       = 32'h1000_0080;
  localparam logic [31:0] KI_IO_LAST       = 32'h1000_00bb;
  localparam logic [31:0] KI_ATA_CS0_BASE  = 32'h1000_0100;
  localparam logic [31:0] KI_ATA_CS0_LAST  = 32'h1000_013f;
  localparam logic [31:0] KI_ATA_CS1_ADDR  = 32'h1000_0170;
  localparam logic [31:0] KI_BOOT_BASE     = 32'h1fc0_0000;
  localparam logic [31:0] KI_BOOT_LAST     = 32'h1fc7_ffff;

  localparam logic [18:0] KI_FB_PAGE0 = 19'h3_0000;
  localparam logic [18:0] KI_FB_PAGE1 = 19'h5_8000;

  typedef enum logic {
    KI_GAME_1 = 1'b0,
    KI_GAME_2 = 1'b1
  } ki_game_e;

  function automatic logic [31:0] merge_bytes(
    input logic [31:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0]  byte_enable
  );
    logic [31:0] merged;
    merged = old_value;
    for (int lane = 0; lane < 4; lane++) begin
      if (byte_enable[lane]) begin
        merged[lane * 8 +: 8] = new_value[lane * 8 +: 8];
      end
    end
    return merged;
  endfunction
endpackage

`default_nettype wire
