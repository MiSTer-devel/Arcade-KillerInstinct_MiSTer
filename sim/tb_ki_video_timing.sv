// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_video_timing;
  localparam int H_VISIBLE = 4;
  localparam int H_TOTAL = 7;
  localparam int V_VISIBLE = 3;
  localparam int V_TOTAL = 5;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic ce_pixel;
  logic [9:0] h_count;
  logic [9:0] v_count;
  logic display_enable;
  logic hsync_n;
  logic vsync_n;
  logic vblank;
  logic frame_start;
  logic [31:0] vblank_count;
  logic vblank_seen;
  logic [9:0] max_v_count;
  int pixel_count = 0;
  int frame_count = 0;

  always #5 clk = !clk;

  ki_video_timing #(
    .CLOCK_DIVIDE(2),
    .H_VISIBLE(H_VISIBLE),
    .H_SYNC_START(5),
    .H_SYNC_END(6),
    .H_TOTAL(H_TOTAL),
    .V_VISIBLE(V_VISIBLE),
    .V_SYNC_START(3),
    .V_SYNC_END(4),
    .V_TOTAL(V_TOTAL)
  ) dut (
    .clk,
    .reset,
    .ce_pixel,
    .h_count,
    .v_count,
    .display_enable,
    .hsync_n,
    .vsync_n,
    .vblank,
    .frame_start,
    .vblank_count,
    .vblank_seen,
    .max_v_count
  );

  always @(posedge clk) begin
    if (!reset && ce_pixel) begin
      pixel_count <= pixel_count + 1;
      if (frame_start) begin
        frame_count <= frame_count + 1;
      end
      assert (display_enable == ((h_count < H_VISIBLE) && (v_count < V_VISIBLE)));
      assert (vblank == (v_count >= V_VISIBLE));
    end
  end

  // ki_framebuffer queues its line prefetch on a (ce_pixel, h_count) match, so
  // exactly WHEN v_count advances relative to ce_pixel decides how much lead
  // that prefetch gets. h_count, v_count and ce_pixel are all assigned on the
  // same edge, so during a ce_pixel cycle the counts are already the new ones:
  // h_count == H_TOTAL-1 is the last pixel of the CURRENT line (v_count has NOT
  // rolled) and h_count == 0 is the first pixel of the NEXT one (it HAS).
  // Assert both, so the framebuffer's trigger choice rests on a checked fact.
  logic [9:0] v_count_at_prev_ce;
  logic       prev_ce_valid = 1'b0;

  always @(posedge clk) begin
    if (reset) begin
      prev_ce_valid <= 1'b0;
    end else if (ce_pixel) begin
      if (prev_ce_valid) begin
        if (h_count == H_TOTAL - 1)
          assert (v_count == v_count_at_prev_ce)
            else $fatal(1, "v_count rolled to %0d at the final h_count", v_count);
        if (h_count == 0)
          assert (v_count == ((v_count_at_prev_ce == V_TOTAL - 1) ?
                              10'd0 : v_count_at_prev_ce + 10'd1))
            else $fatal(1, "v_count is %0d at h_count 0, previous line %0d",
                        v_count, v_count_at_prev_ce);
      end
      v_count_at_prev_ce <= v_count;
      prev_ce_valid <= 1'b1;
    end
  end

  initial begin
    repeat (2) @(posedge clk);
    reset = 1'b0;

    wait (frame_count == 2);
    assert (pixel_count >= H_TOTAL * V_TOTAL)
      else $fatal(1, "frame ended after only %0d pixels", pixel_count);
    assert (vblank_count >= 1)
      else $fatal(1, "vblank entry was not counted");
    assert (vblank_seen)
      else $fatal(1, "vblank level was never observed");
    assert (max_v_count == V_TOTAL - 1)
      else $fatal(1, "raster only reached line %0d", max_v_count);

    $display("tb_ki_video_timing: PASS");
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $fatal(1, "tb_ki_video_timing timeout");
  end
endmodule

`default_nettype wire
