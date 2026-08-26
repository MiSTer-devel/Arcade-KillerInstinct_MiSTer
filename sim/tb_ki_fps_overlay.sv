`timescale 1ns/1ps
`default_nettype none

module tb_ki_fps_overlay;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic frame_start = 1'b0;
  logic timing_60hz = 1'b0;
  logic [18:0] framebuffer_base = 19'h3_0000;
  logic [9:0] h_count = 10'd0;
  logic [9:0] v_count = 10'd0;
  logic [6:0] fps;
  logic box_pixel;
  logic glyph_pixel;

  always #5 clk = ~clk;

  ki_fps_overlay dut (
    .clk,
    .reset,
    .frame_start,
    .timing_60hz,
    .framebuffer_base,
    .h_count,
    .v_count,
    .fps,
    .box_pixel,
    .glyph_pixel
  );

  task automatic raster_frame(input bit flip_page);
    begin
      if (flip_page)
        framebuffer_base = (framebuffer_base == 19'h3_0000) ?
                           19'h5_8000 : 19'h3_0000;
      frame_start = 1'b1;
      @(posedge clk);
      #1;
      frame_start = 1'b0;
      @(posedge clk);
      #1;
    end
  endtask

  integer i;
  initial begin
    repeat (2) @(posedge clk);
    #1 reset = 1'b0;

    // Verify the scale endpoints with one page flip per raster frame.  The
    // game may deliberately render at a lower cadence (KI1 commonly presents
    // every other raster frame), which this counter must report as-is.
    for (i = 0; i < 64; i = i + 1)
      raster_frame(1'b1);
    assert (fps == 7'd59)
      else $fatal(1, "native full-speed result was %0d, expected 59", fps);

    timing_60hz = 1'b1;
    for (i = 0; i < 64; i = i + 1)
      raster_frame(1'b1);
    assert (fps == 7'd60)
      else $fatal(1, "CRT full-speed result was %0d, expected 60", fps);

    // Eight missed updates in the 64-frame window must lower the reading.
    for (i = 0; i < 64; i = i + 1)
      raster_frame(i >= 8);
    assert (fps == 7'd53)
      else $fatal(1, "missed-frame result was %0d, expected 53", fps);

    // A completely static presentation reports no newly rendered frames.
    for (i = 0; i < 64; i = i + 1)
      raster_frame(1'b0);
    assert (fps == 7'd0)
      else $fatal(1, "static-frame result was %0d, expected 0", fps);

    // Page changes normally happen during vblank, between frame_start pulses.
    // Exercise that independent event path as well as coincident boundaries.
    framebuffer_base = (framebuffer_base == 19'h3_0000) ?
                       19'h5_8000 : 19'h3_0000;
    @(posedge clk);
    #1;
    for (i = 0; i < 64; i = i + 1)
      raster_frame(1'b0);
    assert (fps == 7'd1)
      else $fatal(1, "between-frame flip result was %0d, expected 1", fps);

    // The top-left pixel of the F is lit; its cell padding is background,
    // and the pixel immediately to the left is outside the overlay box.
    h_count = 10'd224;
    v_count = 10'd0;
    #1;
    assert (box_pixel && glyph_pixel)
      else $fatal(1, "F glyph origin did not render");

    h_count = 10'd234;
    #1;
    assert (box_pixel && !glyph_pixel)
      else $fatal(1, "glyph cell padding was not transparent");

    h_count = 10'd223;
    #1;
    assert (!box_pixel && !glyph_pixel)
      else $fatal(1, "overlay escaped its left boundary");

    h_count = 10'd319;
    v_count = 10'd15;
    #1;
    assert (box_pixel)
      else $fatal(1, "overlay right/bottom boundary was clipped early");

    h_count = 10'd319;
    v_count = 10'd16;
    #1;
    assert (!box_pixel && !glyph_pixel)
      else $fatal(1, "overlay escaped its bottom boundary");

    reset = 1'b1;
    @(posedge clk);
    #1;
    assert (fps == 7'd0)
      else $fatal(1, "reset did not clear FPS");

    $display("tb_ki_fps_overlay: PASS");
    $finish;
  end
endmodule

`default_nettype wire
