`timescale 1ns/1ps

module tb_ki_startup_osd_button;

	reg clk = 1'b0;
	reg reset = 1'b1;
	reg rom_download = 1'b0;
	reg [15:0] rom_index = 16'd0;
	reg image_present = 1'b0;
	wire osd_button;

	always #5 clk = ~clk;

	ki_startup_osd_button #(
		.WAIT_CYCLES(26'd4),
		.END_CYCLES(26'd7),
		.LAST_ROM_INDEX(16'd9)
	) dut (
		.clk_i(clk),
		.reset_i(reset),
		.rom_download_i(rom_download),
		.rom_index_i(rom_index),
		.image_present_i(image_present),
		.osd_button_o(osd_button)
	);

	task check_button;
		input expected;
		input [255:0] message;
		begin
			#1;
			if (osd_button !== expected) begin
				$error("%s: expected %b, got %b", message, expected,
					osd_button);
				$fatal(1);
			end
		end
	endtask

	task load_rom;
		input [15:0] index;
		begin
			@(negedge clk);
			rom_index = index;
			rom_download = 1'b1;
			repeat (2) @(posedge clk);
			check_button(1'b0, "button asserted during MRA ROM transfer");
			@(negedge clk);
			rom_download = 1'b0;
		end
	endtask

	initial begin
		repeat (2) @(negedge clk);
		reset = 1'b0;

		// PLL lock alone must not start the timer: the MRA has not finished and
		// the HPS cannot service an OSD-button press yet.
		repeat (10) @(posedge clk);
		check_button(1'b0, "button asserted before MRA ROM loading began");

		// Earlier ROMs, including the boot ROM, must not arm the timer. Model
		// gaps between transfers that are longer than the shortened test timeout.
		load_rom(16'd1);
		repeat (10) @(posedge clk);
		check_button(1'b0, "boot ROM alone armed the startup OSD");
		load_rom(16'd2);
		load_rom(16'd3);
		load_rom(16'd4);
		load_rom(16'd5);
		load_rom(16'd6);
		load_rom(16'd7);
		load_rom(16'd8);
		repeat (10) @(posedge clk);
		check_button(1'b0, "timer armed before final MRA ROM");

		// The timeout begins only after index 9's transfer ends.
		load_rom(16'd9);
		repeat (3) begin
			@(posedge clk);
			check_button(1'b0, "button asserted before post-MRA wait elapsed");
		end
		@(posedge clk);
		check_button(1'b1, "button did not assert after final MRA ROM");
		repeat (2) begin
			@(posedge clk);
			check_button(1'b1, "button did not remain asserted in window");
		end
		@(posedge clk);
		check_button(1'b0, "button did not release at end of window");
		repeat (3) @(posedge clk);
		check_button(1'b0, "button press repeated without a new startup");

		// A mounted image after the MRA suppresses and clears the timer.
		@(negedge clk);
		reset = 1'b1;
		@(negedge clk);
		reset = 1'b0;
		load_rom(16'd9);
		repeat (2) @(posedge clk);
		@(negedge clk);
		image_present = 1'b1;
		repeat (5) @(posedge clk);
		check_button(1'b0, "mounted image did not suppress startup OSD");

		// Removing it starts a fresh full timeout because the MRA is complete.
		@(negedge clk);
		image_present = 1'b0;
		repeat (3) begin
			@(posedge clk);
			check_button(1'b0, "timer was not cleared while image was mounted");
		end
		@(posedge clk);
		check_button(1'b1, "button did not assert after a fresh timeout");

		$display("PASS: ki_startup_osd_button waits for final MRA ROM");
		$finish;
	end

endmodule
