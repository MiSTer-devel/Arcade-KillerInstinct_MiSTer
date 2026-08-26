// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_board_io (
  input  wire         clk,
  input  wire         reset,
  input  wire         game_ki2,

  input  wire         bus_request,
  input  wire         bus_write,
  input  wire  [31:0] bus_address,
  input  wire  [31:0] bus_write_data,
  input  wire  [3:0]  bus_byte_enable,
  output logic [31:0] bus_read_data,
  output logic        bus_done,

  input  wire  [31:0] input_p1,
  input  wire  [31:0] input_p2,
  input  wire  [31:0] input_volume,
  input  wire  [31:0] input_dip,
  input  wire  [31:0] input_unused,

  input  wire         irq_vblank,
  input  wire         irq_ata,
  output logic [1:0]  cpu_irq,

  output logic [18:0] framebuffer_base,
  output logic        sound_reset,
  output logic [31:0] sound_data,
  output logic        sound_data_strobe,
  output logic [31:0] coin_control
);
  import ki_board_pkg::*;

  logic [31:0] vram_control;
  logic [31:0] sound_control;
  logic [31:0] next_sound_control;
  logic        io_selected;

  wire [31:0] bus_word_address = {bus_address[31:2], 2'b00};

  assign io_selected = (bus_address >= KI_IO_BASE) &&
                       (bus_address <= KI_IO_LAST);
  assign bus_done = bus_request && io_selected;
  assign cpu_irq = {irq_ata, irq_vblank};
  assign framebuffer_base = vram_control[2] ? KI_FB_PAGE1 : KI_FB_PAGE0;
  assign next_sound_control = merge_bytes(sound_control, bus_write_data,
                                          bus_byte_enable);

  always_comb begin
    bus_read_data = 32'hffff_ffff;

    if (!game_ki2) begin
      unique case (bus_word_address)
        32'h1000_0080: bus_read_data = input_p1;
        32'h1000_0088: bus_read_data = input_p2;
        32'h1000_0090: bus_read_data = input_volume;
        32'h1000_0098: bus_read_data = input_unused;
        32'h1000_00a0: bus_read_data = input_dip;
        default:       bus_read_data = 32'hffff_ffff;
      endcase
    end else begin
      unique case (bus_word_address)
        32'h1000_0080: bus_read_data = input_volume;
        32'h1000_0088: bus_read_data = input_dip;
        32'h1000_0090: bus_read_data = input_p2;
        32'h1000_0098: bus_read_data = input_p1;
        32'h1000_00a0: bus_read_data = input_unused;
        default:       bus_read_data = 32'hffff_ffff;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    sound_data_strobe <= 1'b0;

    if (reset) begin
      vram_control     <= 32'h0000_0000;
      // RELEASED at power-on, not held. This bit reaches the DCS as
      // dcs_host_reset = core_reset | ~sound_reset, so a 0 here pins the sound
      // board in reset until the game happens to write a 1 - and the game does
      // not do that for several seconds.
      //
      // The real board does not work that way. Its DCS runs from power-on and
      // sounds a power-on self-test chime entirely on its own: MAME plays that
      // chime 2.823 s after reset while the first write to this register does
      // not arrive until 6.459 s. Holding the board off until the game asks
      // means the chime either lands far too late or, once the disk is mounted
      // and commands start flowing, is overwritten in the one-word mailbox
      // before it is ever heard. Both are exactly what hardware showed.
      //
      // core_reset still gates the DCS separately, so it stays in reset while
      // its ROM is being written into DDR.
      sound_reset      <= 1'b1;
      sound_control    <= 32'h0000_0000;
      sound_data       <= 32'h0000_0000;
      coin_control     <= 32'h0000_0000;
      sound_data_strobe <= 1'b0;
    end else if (bus_request && bus_write && io_selected) begin
      if ((!game_ki2 && (bus_word_address == 32'h1000_0080)) ||
          ( game_ki2 && (bus_word_address == 32'h1000_0098))) begin
        vram_control <= merge_bytes(vram_control, bus_write_data,
                                    bus_byte_enable);
      end

      if ((!game_ki2 && (bus_word_address == 32'h1000_0088)) ||
          ( game_ki2 && (bus_word_address == 32'h1000_0090))) begin
        if (bus_byte_enable[0]) begin
          sound_reset <= bus_write_data[0];
        end
      end

      if ((!game_ki2 && (bus_word_address == 32'h1000_0090)) ||
          ( game_ki2 && (bus_word_address == 32'h1000_0080))) begin
        sound_control <= next_sound_control;
        sound_data_strobe <= !sound_control[1] && next_sound_control[1];
      end

      if ((!game_ki2 && (bus_word_address == 32'h1000_0098)) ||
          ( game_ki2 && (bus_word_address == 32'h1000_00a0))) begin
        sound_data <= merge_bytes(sound_data, bus_write_data,
                                  bus_byte_enable);
      end

      if ((!game_ki2 && (bus_word_address == 32'h1000_00b0)) ||
          ( game_ki2 && (bus_word_address == 32'h1000_00b8))) begin
        coin_control <= merge_bytes(coin_control, bus_write_data,
                                    bus_byte_enable);
      end
    end
  end
endmodule

`default_nettype wire
