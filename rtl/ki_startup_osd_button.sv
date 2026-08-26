// SPDX-License-Identifier: GPL-3.0-only

// Simulate the MiSTer OSD button when startup remains idle without an HDD
// image. The default timing waits one second, then holds the button for 200 ms
// on the 50 MHz core clock so the HPS observes one deliberate press.
module ki_startup_osd_button
#(
	parameter [25:0] WAIT_CYCLES = 26'd05000000,
	parameter [25:0] END_CYCLES  = 26'd15000000,
	parameter [15:0] LAST_ROM_INDEX = 16'd9
)
(
	input  wire clk_i,
	input  wire reset_i,
	input  wire rom_download_i,
	input  wire [15:0] rom_index_i,
	input  wire image_present_i,
	output wire osd_button_o
);

	reg [25:0] timeout_q = 26'd0;
	reg        last_rom_seen_q = 1'b0;

	// An MRA loads the boot ROM at index 1 and the eight DCS ROMs at indices
	// 2..9. The OSD cannot accept the simulated button until that entire MRA
	// sequence is over, so seeing boot_loaded alone is too early.
	wire mra_roms_loaded_w = last_rom_seen_q && !rom_download_i;
	wire idle_without_image_w = !reset_i && mra_roms_loaded_w &&
		!image_present_i;
	wire button_window_w = (timeout_q >= WAIT_CYCLES) &&
		(timeout_q < END_CYCLES);

	always @(posedge clk_i) begin
		if (reset_i) begin
			last_rom_seen_q <= 1'b0;
		end else if (rom_download_i &&
			(rom_index_i == LAST_ROM_INDEX)) begin
			last_rom_seen_q <= 1'b1;
		end

		// Hold the timer at zero throughout the MRA ROM sequence. Once the final
		// transfer has ended, a mounted image still suppresses the startup press.
		if (reset_i || !mra_roms_loaded_w || image_present_i) begin
			timeout_q <= 26'd0;
		end else if (timeout_q < END_CYCLES) begin
			timeout_q <= timeout_q + 26'd1;
		end
	end

	assign osd_button_o = idle_without_image_w && button_window_w;

endmodule
