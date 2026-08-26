// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_video_timing #(
  parameter int unsigned CLOCK_DIVIDE = 8,
  parameter int unsigned H_VISIBLE    = 320,
  parameter int unsigned H_SYNC_START = 336,
  parameter int unsigned H_SYNC_END   = 368,
  parameter int unsigned H_TOTAL      = 406,
  parameter int unsigned V_VISIBLE    = 240,
  parameter int unsigned V_SYNC_START = 244,
  parameter int unsigned V_SYNC_END   = 247,
  parameter int unsigned V_TOTAL      = 261
) (
  input  wire        clk,
  input  wire        reset,
  output logic       ce_pixel,
  output logic [9:0] h_count,
  output logic [9:0] v_count,
  output logic       display_enable,
  output logic       hsync_n,
  output logic       vsync_n,
  output logic       vblank,
  output logic       frame_start,
  output logic [31:0] vblank_count,
  output logic       vblank_seen,
  output logic  [9:0] max_v_count
);
  localparam int unsigned DIV_WIDTH =
    (CLOCK_DIVIDE <= 1) ? 1 : $clog2(CLOCK_DIVIDE);

  logic [DIV_WIDTH-1:0] pixel_divider;

  assign display_enable = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);
  assign hsync_n = !((h_count >= H_SYNC_START) && (h_count < H_SYNC_END));
  assign vsync_n = !((v_count >= V_SYNC_START) && (v_count < V_SYNC_END));
  assign vblank = (v_count >= V_VISIBLE);

  always_ff @(posedge clk) begin
    ce_pixel <= 1'b0;

    if (reset) begin
      pixel_divider <= '0;
      h_count       <= 10'd0;
      v_count       <= 10'd0;
      ce_pixel      <= 1'b0;
      frame_start   <= 1'b0;
      vblank_count  <= 32'd0;
      vblank_seen   <= 1'b0;
      max_v_count   <= 10'd0;
  end else if (pixel_divider == CLOCK_DIVIDE - 1) begin
      pixel_divider <= '0;
      ce_pixel      <= 1'b1;
      frame_start   <= 1'b0;
      if (v_count > max_v_count)
        max_v_count <= v_count;
      if (vblank)
        vblank_seen <= 1'b1;

      if (h_count == H_TOTAL - 1) begin
        h_count <= 10'd0;
        if (v_count == V_TOTAL - 1) begin
          v_count <= 10'd0;
          frame_start <= 1'b1;
          vblank_count <= vblank_count + 32'd1;
        end else begin
          v_count <= v_count + 10'd1;
        end
      end else begin
        h_count <= h_count + 10'd1;
      end
    end else begin
      pixel_divider <= pixel_divider + 1'b1;
      frame_start   <= 1'b0;
    end
  end
endmodule

`default_nettype wire
