// SPDX-License-Identifier: GPL-3.0-only
// When the core stands still. KillerInstinct.sv says what standing still
// means; this decides when.
//
// Two sources, either of which pauses:
//   - the OSD being open, while the OSD Pause option is on;
//   - the pause button - P on the keyboard, or Pause on either pad - which
//     pauses on one press and resumes on the next, whatever the OSD does.
//
// The CPU's reset cancels a button pause, so a reset always comes back to a
// running game, and nothing pauses while it is high: a request held across
// the CPU's reset would be answered to the CPU that comes out of it.
module ki_pause
(
	input  wire clk,
	input  wire reset,
	// OSD_STATUS comes from the HPS side of the shell, so it is synchronised
	// here before anything uses it.
	input  wire osd_open,
	input  wire osd_pause,
	// Level, in clk's domain: high while the button is held.
	input  wire button,
	output reg  pause = 1'b0
);

reg [1:0] osd_sync = 2'b00;
reg       button_d = 1'b0;
reg       toggled  = 1'b0;

always @(posedge clk) begin
	osd_sync <= {osd_sync[0], osd_open};
	button_d <= button;

	if(reset)
		toggled <= 1'b0;
	else if(button && !button_d)
		toggled <= ~toggled;

	pause <= ((osd_sync[1] && osd_pause) || toggled) && !reset;
end

endmodule
