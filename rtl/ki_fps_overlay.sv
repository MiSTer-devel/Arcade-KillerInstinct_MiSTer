// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// Rendered-frame-rate measurement and a two-digit top-right video overlay.
//
// The raster itself is generated locally and therefore stays at 58.98/59.94
// Hz even when the emulated game falls behind.  A change of framebuffer_base,
// on the other hand, is the game's VRAM page flip and represents a newly
// rendered frame.  Count those flips over 64 output frames, then scale the
// result to the selected output timing's integer frame rate.
module ki_fps_overlay (
  input  wire         clk,
  input  wire         reset,
  input  wire         frame_start,
  input  wire         timing_60hz,
  input  wire  [18:0] framebuffer_base,
  input  wire   [9:0] h_count,
  input  wire   [9:0] v_count,

  output logic  [6:0] fps,
  output logic        box_pixel,
  output logic        glyph_pixel
);
  logic [18:0] framebuffer_base_d;
  logic  [5:0] raster_frames;
  logic  [6:0] page_flips;

  wire page_flip = (framebuffer_base != framebuffer_base_d);
  wire [7:0] closing_flips = {1'b0, page_flips} +
                             (page_flip ? 8'd1 : 8'd0);

  // Round(flips * refresh / 64).  Shift/subtract forms avoid a divider and
  // keep the arithmetic small: 59*x = 64*x - 4*x - x; 60*x = 64*x - 4*x.
  function automatic [6:0] scaled_fps(
    input logic [7:0] flips,
    input logic       use_60hz
  );
    logic [14:0] product;
    begin
      if (use_60hz)
        product = ({7'd0, flips} << 6) - ({7'd0, flips} << 2);
      else
        product = ({7'd0, flips} << 6) - ({7'd0, flips} << 2) - flips;
      product = product + 15'd32;
      scaled_fps = (product[14:6] > 9'd127) ? 7'd127
                                             : product[12:6];
    end
  endfunction

  always_ff @(posedge clk) begin
    framebuffer_base_d <= framebuffer_base;

    if (reset) begin
      framebuffer_base_d <= framebuffer_base;
      raster_frames       <= 6'd0;
      page_flips          <= 7'd0;
      fps                 <= 7'd0;
    end else if (frame_start) begin
      if (raster_frames == 6'd63) begin
        fps           <= scaled_fps(closing_flips, timing_60hz);
        raster_frames <= 6'd0;
        page_flips    <= 7'd0;
      end else begin
        raster_frames <= raster_frames + 1'b1;
        if (page_flip && ~&page_flips)
          page_flips <= page_flips + 1'b1;
      end
    end else if (page_flip && ~&page_flips) begin
      page_flips <= page_flips + 1'b1;
    end
  end

  function automatic [34:0] glyph_bits(input logic [3:0] digit);
    begin
      case (digit)
        4'd0: glyph_bits={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
        4'd1: glyph_bits={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
        4'd2: glyph_bits={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
        4'd3: glyph_bits={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
        4'd4: glyph_bits={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
        4'd5: glyph_bits={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
        4'd6: glyph_bits={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
        4'd7: glyph_bits={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
        4'd8: glyph_bits={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
        4'd9: glyph_bits={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
        default: glyph_bits=35'd0;
      endcase
    end
  endfunction

  // Two 16x16 cells, the tens digit at 280..295 and the ones digit at
  // 296..311: 8 pixels in from the right edge, inside what Crop keeps.
  localparam logic [9:0] BOX_LEFT = 10'd280;

  logic  [6:0] clipped;
  logic  [3:0] tens;
  logic  [3:0] units;
  logic  [3:0] digit;
  logic  [9:0] box_x;
  logic [34:0] glyph;
  logic  [4:0] glyph_row;
  logic  [2:0] font_x;
  logic  [2:0] font_y;

  always_comb begin
    // The 5x7 font is doubled to 10x14 pixels.
    box_x = h_count - BOX_LEFT;
    box_pixel = (h_count >= BOX_LEFT) && (h_count < BOX_LEFT + 10'd32) &&
                (v_count < 10'd16);

    clipped = (fps > 7'd99) ? 7'd99 : fps;
    tens = clipped / 10;
    units = clipped % 10;
    digit = box_x[4] ? units : tens;

    font_x = box_x[3:1];
    font_y = v_count[3:1];
    glyph = glyph_bits(digit);
    glyph_row = (font_y < 7) ? (glyph >> ((6-font_y)*5)) : 5'd0;
    glyph_pixel = box_pixel && (font_x < 5) && glyph_row[4-font_x];
  end
endmodule

`default_nettype wire
