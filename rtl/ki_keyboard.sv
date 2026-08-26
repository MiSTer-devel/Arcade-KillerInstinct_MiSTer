// SPDX-License-Identifier: GPL-3.0-only
// MAME-compatible keyboard controls for the Killer Instinct board shell.

module ki_keyboard
(
	input             clk_i,
	input      [10:0] ps2_key_i,
	output reg [12:0] p1_o = 13'd0,
	output reg [12:0] p2_o = 13'd0
);

// ps2_key_i contains Set-2 scan codes. Bit 10 toggles for each make/break
// event, bit 9 is the pressed state and bit 8 marks E0-extended keys. Keeping
// bit 8 in the selector prevents keypad keys from masquerading as arrows and
// distinguishes the left modifiers used by MAME from their right variants.
reg key_toggle = 1'b0;

always @(posedge clk_i) begin
	key_toggle <= ps2_key_i[10];
	if(key_toggle != ps2_key_i[10]) begin
		case(ps2_key_i[8:0])
			9'h016: p1_o[10] <= ps2_key_i[9]; // 1: P1 Start
			9'h01e: p2_o[10] <= ps2_key_i[9]; // 2: P2 Start
			9'h02e: p1_o[11] <= ps2_key_i[9]; // 5: Coin 1
			9'h036: p2_o[11] <= ps2_key_i[9]; // 6: Coin 2

			9'h175: p1_o[3] <= ps2_key_i[9]; // Up Arrow
			9'h172: p1_o[2] <= ps2_key_i[9]; // Down Arrow
			9'h16b: p1_o[1] <= ps2_key_i[9]; // Left Arrow
			9'h174: p1_o[0] <= ps2_key_i[9]; // Right Arrow
			9'h014: p1_o[4] <= ps2_key_i[9]; // Left Ctrl: P1 Button 1
			9'h011: p1_o[5] <= ps2_key_i[9]; // Left Alt: P1 Button 2
			9'h029: p1_o[6] <= ps2_key_i[9]; // Space: P1 Button 3
			9'h012: p1_o[7] <= ps2_key_i[9]; // Left Shift: P1 Button 4
			9'h01a: p1_o[8] <= ps2_key_i[9]; // Z: P1 Button 5
			9'h022: p1_o[9] <= ps2_key_i[9]; // X: P1 Button 6

			9'h02d: p2_o[3] <= ps2_key_i[9]; // R: P2 Up
			9'h02b: p2_o[2] <= ps2_key_i[9]; // F: P2 Down
			9'h023: p2_o[1] <= ps2_key_i[9]; // D: P2 Left
			9'h034: p2_o[0] <= ps2_key_i[9]; // G: P2 Right
			9'h01c: p2_o[4] <= ps2_key_i[9]; // A: P2 Button 1
			9'h01b: p2_o[5] <= ps2_key_i[9]; // S: P2 Button 2
			9'h015: p2_o[6] <= ps2_key_i[9]; // Q: P2 Button 3
			9'h01d: p2_o[7] <= ps2_key_i[9]; // W: P2 Button 4
			9'h024: p2_o[8] <= ps2_key_i[9]; // E: P2 Button 5
		endcase
	end
end

endmodule
