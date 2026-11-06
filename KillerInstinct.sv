// SPDX-License-Identifier: GPL-3.0-only
// Killer Instinct MiSTer board-shell bring-up top level.

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [45:0] HPS_BUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

	input   [5:0] LFB_FMT,
	input  [31:0] LFB_BASE,
	input  [11:0] LFB_WIDTH,
	input  [11:0] LFB_HEIGHT,
	input  [13:0] LFB_STRIDE,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,
	input         OSD_STATUS
);

localparam CONF_STR = {
	"KillerInstinct;;",
	"H0S0,IMG,HDD Image;",
	"-;",
	"P1,Video Settings;",
	"P1O1,Aspect Ratio,Original,Wide Screen;",
	"P1O2,Video Timing,Native,60Hz CRT;",
	"P1OD,Crop,Off,On;",
	"-;",
	"O8,OSD Pause,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"h1P2,Extras;",
	"h1P2-,Use on Character Selection;",
	"h1P2R4,Activate Gargos (P1);",
	"h1P2R5,Activate Gargos (P2);",
	"-;",
	"R0,Reset;",
	"J1,High Quick,High Medium,High Fierce,Low Quick,Low Medium,Low Fierce,Start,Coin,Service,Test,Pause;",
	"V,1.60"
};

wire [1:0] buttons;
wire [127:0] status;
reg [127:0] status_in = 128'd0;
reg         status_set = 1'b0;
reg         crop_default_pending = 1'b0;
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [10:0] ps2_key;
wire forced_scandoubler;
wire ioctl_download;
wire ioctl_wr;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire ioctl_wait;
wire img_mounted;
wire img_readonly;
wire [63:0] img_size;
wire hdd_image_present = (img_size >= 64'd512);
wire [31:0] sd_lba;
wire [5:0] sd_blk_cnt;
wire sd_rd;
wire sd_wr;
wire sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din;
wire sd_buff_wr;

// Every clock in the core, and what each one is FOR. None of these names
// carries a frequency.
//
//   wire              PLL out   freq     phase   purpose
//   clk_core          0         50 MHz   0       video, I/O, bridge
//   clk_cpu           1         100 MHz  0       the MIPS core. RELATED to
//                                                clk_core at 2:1 and timed
//                                                against it (SYNC_CROSSING);
//                                                see KillerInstinct.sdc.
//   clk_ddr           2         100 MHz  0       DDRAM_CLK and the bridge's
//                                                DDR side
//   clk_sdram_pin     3         100 MHz  6750ps  leaves the chip as SDRAM_CLK
//   clk_sdram_ctl     4         100 MHz  500ps   ki_sdram_burst's logic
//   clk_sdram_cap     5         100 MHz  1500ps  captures SDRAM_DQ in the
//                                                device's data eye
//
// clk_cpu and clk_ddr are configured identically, so Quartus MERGES them onto
// one network - general[2] does not appear in the STA clock list at all. They
// are kept as two wires because they have two unrelated jobs, and because the
// merge is the fitter's decision to make, not this file's.
//
// Inside the CPU, clk_cpu arrives as clk93 and clk_core as clk1x. Those names
// come from the N64 core this CPU is derived from (93.75 and 62.5 MHz) and are
// wrong here - but the `_93` and `_1x` SUFFIXES on ~28 signals below them are
// a domain tag that CDC code depends on, so renaming the clocks without
// renaming every suffix would be worse than leaving both. This table is the
// mapping.
//
// The SDRAM phases above cannot be derived from nominal timing;
// rtl/pll/pll_0002.v records why.
wire clk_core;
wire clk_cpu;
wire clk_ddr;
wire clk_sdram_pin;
wire clk_sdram_ctl;
wire clk_sdram_cap;
wire pll_locked;

// Keep this instance name aligned with sys/sys_top.sdc's core clock group.
pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_core),
	.outclk_1(clk_cpu),
	.outclk_2(clk_ddr),
	.outclk_3(clk_sdram_pin),
	.outclk_4(clk_sdram_ctl),
	.outclk_5(clk_sdram_cap),
	.locked(pll_locked)
);

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_core),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key),
	.joystick_0_rumble(16'h0000),
	.joystick_1_rumble(16'h0000),
	.status(status),
	.status_in(status_in),
	.status_set(status_set),
	.status_menumask({14'b0, game_ki2, 1'b1}),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'h00),
	.ioctl_din(16'h0000),
	.ioctl_wait(ioctl_wait),
	.sd_lba('{sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size)
);

reg game_ki2 = 1'b0;
reg [15:0] dip_switches = 16'hffff;

always @(posedge clk_core) begin
	// Pulse once to request a menu update, then leave user changes alone.
	status_set <= 1'b0;

	if(ioctl_wr && (ioctl_index == 16'h0000) && (ioctl_addr < 27'd2)) begin
		game_ki2 <= ioctl_dout[0];
		crop_default_pending <= 1'b1;
	end
	else if(crop_default_pending && !ioctl_download) begin
		// Default Crop to On for KI2 and Off for KI1; preserve other settings.
		status_in <= {status[127:14], game_ki2, status[12:0]};
		status_set <= 1'b1;
		crop_default_pending <= 1'b0;
	end

	if(ioctl_wr && (ioctl_index == 16'h00fe) && (ioctl_addr < 27'd2)) begin
		dip_switches <= ioctl_dout;
	end
end

wire shell_reset = RESET | buttons[1] | status[0] | ~pll_locked;

reg [3:0]  img_reset_delay = 4'd0;
reg [15:0] img_reset_count = 16'd0;

always @(posedge clk_core) begin
	if(shell_reset) begin
		img_reset_delay <= 4'd0;
		img_reset_count <= 16'd0;
	end
	else begin
		if(img_mounted && hdd_image_present) begin
			// Let ATA logic process the mount first.
			img_reset_delay <= 4'd8;
		end
		else if(img_reset_delay != 0) begin
			img_reset_delay <= img_reset_delay - 1'b1;

			if(img_reset_delay == 1)
				img_reset_count <= 16'd50000;
		end
		else if(img_reset_count != 0) begin
			img_reset_count <= img_reset_count - 1'b1;
		end
	end
end

wire img_reset = (img_reset_count != 0);

wire core_reset = shell_reset | ioctl_download | img_reset;

wire boot_loaded;
wire sdram_ready;
wire cpu_reset = core_reset | ~boot_loaded | ~sdram_ready;
wire [9:0] h_count;
wire [9:0] v_count;

wire vblank;
wire frame_start;

// ---------------------------------------------------------------------------
// Video timing selection.
//
// Native Killer Instinct timing, matching the original board, is
// 50 MHz / 8 = 6.25 MHz with 406 clocks/line and 261 lines/frame:
//
//     H = 6.25 MHz / 406       = 15.394 kHz
//     V = 6.25 MHz / 406 / 261 = 58.981 Hz
//
// 15.394 kHz is low enough that some NTSC consumer televisions will not lock
// to it reliably. status[2] therefore selects an alternate 320x240 timing
// which keeps the ORIGINAL 6.25 MHz pixel cadence but changes only blanking:
//
//     398 clocks/line, 262 lines/frame
//     H = 15.704 kHz
//     V = 59.937 Hz
//
// This is deliberately a timing-compatibility mode rather than a scaler.
// The framebuffer remains 320x240 and no pixels are duplicated or dropped.
// Because vblank is generated by this timing, game speed/IRQ cadence rises by
// about 1.62% in CRT mode. Native remains the default and exact board mode.
wire crt_60hz = status[2];

wire        native_ce_pixel;
wire        native_advance;
wire [9:0]  native_h_count;
wire [9:0]  native_v_count;
wire        native_de;
wire        native_hs;
wire        native_vs;
wire        native_vblank;
wire        native_frame_start;

// The timing is reset only until the PLL locks. ROM and DIP downloads and HDD
// mounts all reset the core; resetting the timing with it stopped CE_PIXEL and
// both syncs for a whole download, then restarted them mid-frame. MiSTer's
// video_calc reports each stop or short frame as a new video mode, and with
// vsync_adjust, VRR or vscale_mode >= 4 the HPS reprograms the HDMI PLL for
// every one - the reconfiguration sys/ascal.vhd notes can leave its output
// stuck. Free-running, the scaler and analog displays see one steady signal
// from configuration on. The framebuffer and CPU still reset with the core:
// the picture is black until lines are fetched again, and vblank arrives at
// whatever phase the timing is in, as it would on the board.
wire video_reset = ~pll_locked;

// Keep the original generator running in both modes. Its CE_PIXEL is the
// common 6.25 MHz pixel strobe. The alternate counters below step on its
// advance output instead - the clock before CE_PIXEL, whose edge steps the
// generator's own counters - so h_count and v_count change on the same edge in
// either mode. ki_framebuffer issues the next column's line-buffer read in
// that clock, so counters stepping on CE_PIXEL, a clock later, would show
// pixel N+1 in column N.
ki_video_timing #(.CLOCK_DIVIDE(8)) video_timing
(
	.clk(clk_core),
	.reset(video_reset),
	.ce_pixel(native_ce_pixel),
	.advance(native_advance),
	.h_count(native_h_count),
	.v_count(native_v_count),
	.display_enable(native_de),
	.hsync_n(native_hs),
	.vsync_n(native_vs),
	.vblank(native_vblank),
	.frame_start(native_frame_start)
);

// NTSC-consumer-CRT-friendly 240p timing. Active video is kept at the same
// 0..319 / 0..239 coordinates expected by ki_framebuffer.
// Horizontal: 320 active + 16 front + 32 sync + 30 back = 398.
// Vertical:   240 active +  3 front +  3 sync + 16 back = 262.
localparam int CRT_H_ACTIVE = 320;
localparam int CRT_H_FP     = 16;
localparam int CRT_H_SYNC   = 32;
localparam int CRT_H_TOTAL  = 398;
localparam int CRT_V_ACTIVE = 240;
localparam int CRT_V_FP     = 3;
localparam int CRT_V_SYNC   = 3;
localparam int CRT_V_TOTAL  = 262;

reg [9:0] crt_h_count = 10'd0;
reg [9:0] crt_v_count = 10'd0;
reg crt_frame_start = 1'b0;

always @(posedge clk_core) begin
	crt_frame_start <= 1'b0;

	if(video_reset) begin
		crt_h_count <= 10'd0;
		crt_v_count <= 10'd0;
	end
	else if(native_advance) begin
		if(crt_h_count == CRT_H_TOTAL-1) begin
			crt_h_count <= 10'd0;

			if(crt_v_count == CRT_V_TOTAL-1) begin
				crt_v_count <= 10'd0;
				crt_frame_start <= 1'b1;
			end
			else begin
				crt_v_count <= crt_v_count + 1'b1;
			end
		end
		else begin
			crt_h_count <= crt_h_count + 1'b1;
		end
	end
end

wire crt_de = (crt_h_count < CRT_H_ACTIVE) &&
              (crt_v_count < CRT_V_ACTIVE);
wire crt_hs = ~((crt_h_count >= CRT_H_ACTIVE + CRT_H_FP) &&
                (crt_h_count <  CRT_H_ACTIVE + CRT_H_FP + CRT_H_SYNC));
wire crt_vs = ~((crt_v_count >= CRT_V_ACTIVE + CRT_V_FP) &&
                (crt_v_count <  CRT_V_ACTIVE + CRT_V_FP + CRT_V_SYNC));
wire crt_vblank = (crt_v_count >= CRT_V_ACTIVE);

// Crop blanks the first and last 8 columns of the 320-pixel line, leaving
// 304 x 240 active in either timing mode. Only DE changes: sync, the
// framebuffer fetch and the vblank IRQ still run on the full line, so game
// timing is identical with it on or off. VIDEO_ARX/ARY follow it below.
wire crop = status[13];
wire crop_de = !crop || ((h_count >= 10'd8) && (h_count < 10'd312));

assign CE_PIXEL = native_ce_pixel;
assign h_count = crt_60hz ? crt_h_count : native_h_count;
assign v_count = crt_60hz ? crt_v_count : native_v_count;
assign VGA_DE = (crt_60hz ? crt_de : native_de) && crop_de;
assign VGA_HS = crt_60hz ? crt_hs : native_hs;
assign VGA_VS = crt_60hz ? crt_vs : native_vs;
assign vblank = crt_60hz ? crt_vblank : native_vblank;
assign frame_start = crt_60hz ? crt_frame_start : native_frame_start;

// Board input bits:
//
//   0 High Quick   1 High Medium   2 High Fierce
//   3 Low Quick    4 Low Medium    5 Low Fierce
//   6 Up   7 Down   8 Left   9 Right
//  10 Start (1P on the P1 port, 2P on the P2 port)
//  11 Coin  (Coin 1 / Coin 2)
//  12 Service Mode on P1, TILT on P2
//  13 Coin 3 on P1, Service 1 on P2
//  14 Coin 4 on P1, Banknote 1 on P2
//
// MiSTer joystick bits are right/left/down/up in 3:0, then the CONF_STR J1
// order from bit 4: High Quick, High Medium, High Fierce, Low Quick,
// Low Medium, Low Fierce, Start, Coin, Service, Test, Pause.
//
// DB15 SNAC through the MiSTer user port:
// USER_OUT[0] = LOAD, USER_OUT[1] = CLK, USER_IN[5] = DATA.
// A-F map to the six KI attack buttons, Start to Start and Select to Coin.
// Leave all user-port outputs released while DB15 is disabled.
wire        db15_en = status[26];
wire        db15_clk;
wire        db15_load;
wire [15:0] db15_joy1;
wire [15:0] db15_joy2;

joy_db15 db15_reader
(
	.clk(clk_core),
	.rst(~db15_en),
	.JOY_CLK(db15_clk),
	.JOY_LOAD(db15_load),
	.JOY_DATA(USER_IN[5]),
	.joystick1(db15_joy1),
	.joystick2(db15_joy2)
);

// Bit 12 (service) and higher are not provided by the DB15 adapter.
// The enable mask also prevents any stale data affecting USB inputs.
wire [12:0] db15_p1 = db15_en ? {1'b0, db15_joy1[11:0]} : 13'd0;
wire [12:0] db15_p2 = db15_en ? {1'b0, db15_joy2[11:0]} : 13'd0;

//MAME style keyboard input
wire [12:0] keyboard_p1;
wire [12:0] keyboard_p2;
wire        keyboard_pause;

ki_keyboard keyboard
(
	.clk_i(clk_core),
	.ps2_key_i(ps2_key),
	.p1_o(keyboard_p1),
	.p2_o(keyboard_p2),
	.pause_o(keyboard_pause)
);

// Input Codes
wire [12:0] extras_p1;
wire [12:0] extras_p2;

ki_extras extras
(
    .clk(clk_core),
    .reset(core_reset),
    .game_ki2(game_ki2),
    .osd_open(OSD_STATUS),
    .core_pause(core_pause),
    .frame_start(frame_start),
    .gargos_trigger(status[5:4]),
    .controls_p1(extras_p1),
    .controls_p2(extras_p2)
);

// Merge arcade keyboard, USB, and DB15 controls before translating them
// to the board's active-low ports.
wire [12:0] controls_p1 = joystick_0[12:0] | keyboard_p1 | db15_p1 | extras_p1;
wire [12:0] controls_p2 = joystick_1[12:0] | keyboard_p2 | db15_p2 | extras_p2;

// Active low throughout: the board reads a released control as 1.
wire [31:0] input_p1 = {
	16'hffff,          // 31:16 unused
	3'b111,            // 15:13 Coin 4, Coin 3 inactive
	~controls_p1[12],  //    12 Service Mode
	~controls_p1[11],  //    11 Coin 1
	~controls_p1[10],  //    10 1P Start
	~controls_p1[0],   //     9 Right
	~controls_p1[1],   //     8 Left
	~controls_p1[2],   //     7 Down
	~controls_p1[3],   //     6 Up
	~controls_p1[9],   //     5 Low Fierce
	~controls_p1[8],   //     4 Low Medium
	~controls_p1[7],   //     3 Low Quick
	~controls_p1[6],   //     2 High Fierce
	~controls_p1[5],   //     1 High Medium
	~controls_p1[4]    //     0 High Quick
};
// P2 differs above bit 11: bit 12 is TILT, not Service Mode. Player 2's
// Service goes to bit 13, Service 1, which is the genuine service input on
// this port, and Tilt is left inactive because nothing should assert it.
wire [31:0] input_p2 = {
	16'hffff,          // 31:16 unused
	2'b11,             // 15:14 Banknote 1 inactive
	~controls_p2[12],  //    13 Service 1
	1'b1,              //    12 Tilt - never asserted
	~controls_p2[11],  //    11 Coin 2
	~controls_p2[10],  //    10 2P Start
	~controls_p2[0],   //     9 Right
	~controls_p2[1],   //     8 Left
	~controls_p2[2],   //     7 Down
	~controls_p2[3],   //     6 Up
	~controls_p2[9],   //     5 Low Fierce
	~controls_p2[8],   //     4 Low Medium
	~controls_p2[7],   //     3 Low Quick
	~controls_p2[6],   //     2 High Fierce
	~controls_p2[5],   //     1 High Medium
	~controls_p2[4]    //     0 High Quick
};

// The test switch is DSW bit 15 (mask 00008000), active low like the rest, so
// pressing the CONF_STR Test button on either pad clears it.
wire test_pressed = joystick_0[13] | joystick_1[13];
wire [15:0] dip_switches_live =
	dip_switches & {~test_pressed, 15'h7fff};

// Pause: the game stands still while the OSD is open with OSD Pause on, and
// from one press of P or a pad's Pause button to the next. The memory bridge
// starts no CPU request, so the CPU stops at its next miss or I/O access;
// Count stops with it, so the game's own frame timing sees no time pass; and
// the sound board stops in step. Scanout carries on, so the frame the game
// last flipped to stays on screen. ki_pause decides when.
wire core_pause;

ki_pause pause_control
(
	.clk(clk_core),
	.reset(cpu_reset),
	.osd_open(OSD_STATUS),
	.osd_pause(status[8]),
	.button(keyboard_pause | joystick_0[14] | joystick_1[14]),
	.pause(core_pause)
);

wire [31:0] io_read_data;
wire io_done;
wire [31:0] board_io_read_data;
wire board_io_done;
wire [31:0] ata_read_data;
wire ata_done;
wire ata_irq;
wire io_request;
wire io_write;
wire [31:0] io_address;
wire [31:0] io_write_data;
wire [3:0] io_byte_enable;
wire [1:0] cpu_irq;
wire cpu_mem_request;
wire cpu_mem_rnw;
wire [31:0] cpu_mem_address;
wire cpu_mem_req64;
wire [2:0] cpu_mem_size;
wire [7:0] cpu_mem_write_mask;
wire [63:0] cpu_mem_data_write;
wire        cpu_mem_line_write;
wire [255:0] cpu_mem_line_data;
wire  [31:0] cpu_mem_line_bytes;
wire        cpu_mem_line_ra;
wire [63:0] cpu_mem_data_read;
wire cpu_mem_done;
wire cpu_mem_grant;
wire [63:0] cpu_cache_data;
wire cpu_cache_data_ready;
wire [5:0] cpu_errors;
wire [18:0] framebuffer_base;
wire framebuffer_memory_request;
wire [27:0] framebuffer_memory_address;
wire [2:0] framebuffer_memory_words;
wire [63:0] framebuffer_memory_data;
wire framebuffer_memory_data_valid;
wire framebuffer_memory_done;
wire [7:0] framebuffer_red;
wire [7:0] framebuffer_green;
wire [7:0] framebuffer_blue;
wire [24:0] bridge_sdram_address;
wire [255:0] bridge_sdram_write_data;
wire [31:0] bridge_sdram_byte_enable;
wire [4:0] bridge_sdram_burst;
wire bridge_sdram_read;
wire bridge_sdram_write;
wire [31:0] bridge_sdram_read_data;
wire  [1:0] bridge_sdram_read_be;
wire bridge_sdram_data_valid;
wire bridge_sdram_done;
wire [24:0] controller_sdram_address;
wire [255:0] controller_sdram_write_data;
wire [31:0] controller_sdram_byte_enable;
wire [4:0] controller_sdram_burst;
wire controller_sdram_read;
wire controller_sdram_write;
wire [15:0] controller_sdram_read_data;
wire controller_sdram_dout_valid;
wire controller_sdram_ready;

wire sound_reset;
wire [31:0] sound_data;
wire sound_data_strobe;

// DCS audio board.
//
// host_reset is asserted while the core is in reset OR while the game holds
// the sound board reset low, so sound_reset is active-low here.
wire [15:0] dcs_host_status;
wire dcs_rom_request;
wire [18:0] dcs_rom_address;
wire dcs_rom_ready;
wire [63:0] dcs_rom_data;
wire signed [15:0] dcs_audio;
wire dcs_host_reset = core_reset | ~sound_reset;

assign io_read_data = ata_done ? ata_read_data : board_io_read_data;
assign io_done = board_io_done | ata_done;

// The data cache's direct fill path: from the CPU's clock to the SDRAM
// controller's second port and back through ki_fast_fill, inside the adapter.
wire        cpu_fast_ok;
wire        cpu_fast_req_tog;
wire [31:0] cpu_fast_req_line;
// The line read is a stream's; ki_sdram_burst's RA_ROW_HOLD.
wire        cpu_fast_req_stream;
wire        cpu_fast_window;
wire        cpu_fast_beat;
wire        cpu_fast_first;
wire [63:0] cpu_fast_qword;
wire        cpu_fast_done_tog;
// An uncached qword back from the controller's clock, and a read-ahead
// line's qwords on cpu_fast_ra_valid; see ki_fast_fill.
wire        cpu_fast_unc_valid;
wire [63:0] cpu_fast_unc_qword;
wire        cpu_fast_ra_valid;
wire        controller_fast_tog;
wire [24:0] controller_fast_addr;
wire        controller_fast_stream;
wire        controller_fast_valid;

ki_cpu_core cpu
(
	.clk1x(clk_core),
	.clk93(clk_cpu),
	.reset(cpu_reset),
	.irq(cpu_irq),
	.pause(core_pause),
	.mem_request(cpu_mem_request),
	.mem_rnw(cpu_mem_rnw),
	.mem_address(cpu_mem_address),
	.mem_req64(cpu_mem_req64),
	.mem_size(cpu_mem_size),
	.mem_writeMask(cpu_mem_write_mask),
	.mem_dataWrite(cpu_mem_data_write),
	.mem_line_write(cpu_mem_line_write),
	.mem_line_data(cpu_mem_line_data),
	.mem_line_bytes(cpu_mem_line_bytes),
	.mem_line_ra(cpu_mem_line_ra),
	.mem_dataRead(cpu_mem_data_read),
	.mem_done(cpu_mem_done),
	.cache_grant(cpu_mem_grant),
	.cache_data(cpu_cache_data),
	.cache_data_ready(cpu_cache_data_ready),
	.fast_ok(cpu_fast_ok),
	.fast_req_tog(cpu_fast_req_tog),
	.fast_req_line(cpu_fast_req_line),
	.fast_req_stream(cpu_fast_req_stream),
	.fast_window(cpu_fast_window),
	.fast_beat(cpu_fast_beat),
	.fast_first(cpu_fast_first),
	.fast_qword(cpu_fast_qword),
	.fast_done_tog(cpu_fast_done_tog),
	.fast_unc_valid(cpu_fast_unc_valid),
	.fast_unc_qword(cpu_fast_unc_qword),
	.fast_ra_valid(cpu_fast_ra_valid),
	.errors(cpu_errors),
	.debug_fetch_pc(),
	.debug_retired(),
	.debug_retire_pc(),
	.debug_retire_opcode()
);

ki_memory_bridge memory_bridge
(
	.clk(clk_core),
	.ddr_clk(clk_ddr),
	.reset(shell_reset),
	.cpu_request(cpu_mem_request),
	.cpu_hold(core_pause),
	.cpu_rnw(cpu_mem_rnw),
	.cpu_address(cpu_mem_address),
	.cpu_req64(cpu_mem_req64),
	.cpu_size(cpu_mem_size),
	.cpu_write_mask(cpu_mem_write_mask),
	.cpu_data_write(cpu_mem_data_write),
	.cpu_line_write(cpu_mem_line_write),
	.cpu_line_data(cpu_mem_line_data),
	.cpu_line_bytes(cpu_mem_line_bytes),
	.cpu_line_ra(cpu_mem_line_ra),
	.cpu_data_read(cpu_mem_data_read),
	.cpu_done(cpu_mem_done),
	.cpu_grant(cpu_mem_grant),
	.cpu_cache_data(cpu_cache_data),
	.cpu_cache_data_ready(cpu_cache_data_ready),
	.fast_ok(cpu_fast_ok),
	.io_request(io_request),
	.io_write(io_write),
	.io_address(io_address),
	.io_write_data(io_write_data),
	.io_byte_enable(io_byte_enable),
	.io_read_data(io_read_data),
	.io_done(io_done),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.boot_loaded(boot_loaded),
	.video_request(framebuffer_memory_request),
	.video_address(framebuffer_memory_address),
	.video_words(framebuffer_memory_words),
	.video_data(framebuffer_memory_data),
	.video_data_valid(framebuffer_memory_data_valid),
	.video_done(framebuffer_memory_done),
	.dcs_rom_request(dcs_rom_request),
	.dcs_rom_address(dcs_rom_address),
	.dcs_rom_ready(dcs_rom_ready),
	.dcs_rom_data(dcs_rom_data),
	.sdram_address(bridge_sdram_address),
	.sdram_write_data(bridge_sdram_write_data),
	.sdram_byte_enable(bridge_sdram_byte_enable),
	.sdram_burst(bridge_sdram_burst),
	.sdram_read(bridge_sdram_read),
	.sdram_write(bridge_sdram_write),
	.sdram_read_data(bridge_sdram_read_data),
	.sdram_read_be(bridge_sdram_read_be),
	.sdram_data_valid(bridge_sdram_data_valid),
	.sdram_done(bridge_sdram_done),
	.sdram_ready(sdram_ready),
	.ddram_busy(DDRAM_BUSY),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr(DDRAM_ADDR),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_rd(DDRAM_RD),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_we(DDRAM_WE),
	.fb_read_accept(),
	.fb_write_accept(),
	.debug_write_count(),
	.debug_low_write_count(),
	.debug_main_write_count()
);

// ki_sdram_x2 lives inside the adapter and packs the controller's 16-bit beats
// into the 32 bits clk_core expects. clk_sdram_ctl runs at twice clk_core, so
// a 32-bit beat comes out every clk_core cycle.
ki_sdram_adapter sdram_adapter
(
	.clk(clk_core),
	.clk2x(clk_sdram_ctl),
	.reset(~pll_locked),
	.request_address(bridge_sdram_address),
	.request_write_data(bridge_sdram_write_data),
	.request_byte_enable(bridge_sdram_byte_enable),
	.request_burst(bridge_sdram_burst),
	.request_read(bridge_sdram_read),
	.request_write(bridge_sdram_write),
	.request_read_data(bridge_sdram_read_data),
	.request_read_be(bridge_sdram_read_be),
	.request_data_valid(bridge_sdram_data_valid),
	.request_done(bridge_sdram_done),
	.sdram_ready(sdram_ready),
	.fast_req_tog(cpu_fast_req_tog),
	.fast_req_line(cpu_fast_req_line),
	.fast_req_stream(cpu_fast_req_stream),
	.fast_window(cpu_fast_window),
	.fast_beat(cpu_fast_beat),
	.fast_first(cpu_fast_first),
	.fast_qword(cpu_fast_qword),
	.fast_done_tog(cpu_fast_done_tog),
	.fast_unc_valid(cpu_fast_unc_valid),
	.fast_unc_qword(cpu_fast_unc_qword),
	.fast_ra_valid(cpu_fast_ra_valid),
	.controller_address(controller_sdram_address),
	.controller_write_data(controller_sdram_write_data),
	.controller_byte_enable(controller_sdram_byte_enable),
	.controller_burst(controller_sdram_burst),
	.controller_read(controller_sdram_read),
	.controller_write(controller_sdram_write),
	.controller_read_data(controller_sdram_read_data),
	.controller_dout_valid(controller_sdram_dout_valid),
	.controller_ready(controller_sdram_ready),
	.controller_fast_tog(controller_fast_tog),
	.controller_fast_addr(controller_fast_addr),
	.controller_fast_stream(controller_fast_stream),
	.controller_fast_valid(controller_fast_valid)
);

// The address decomposition uses col = addr[9:1], so 512 consecutive words
// share a row and a burst is a sequence of back-to-back column accesses.
// SDRAM contents are transient because the ROM download repopulates memory on
// every core load.
// 100 MHz floors: tRP 18->2, tRCD 18->2, tRAS 42->5, tRC 7, tRFC 66->7,
// tWR 15->2. CL2 is in spec for a -75 part at 100 MHz.
ki_sdram_burst #(
	.T_RP(4'd2), .T_RCD(4'd2), .T_RAS(5'd5), .T_RC(5'd7),
	.T_RFC(4'd7), .T_WR(4'd2), .CAS_LATENCY(3'd2),
	.STARTUP_CYCLES(15'd12000), .REFRESH_PERIOD(13'd730)
) sdram_controller
(
	.init(~pll_locked),
	.clk(clk_sdram_ctl), .clk_cap(clk_sdram_cap),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),
	.wtbt(controller_sdram_byte_enable),
	.addr(controller_sdram_address),
	.burst(controller_sdram_burst),
	.dout(controller_sdram_read_data),
	.dout_valid(controller_sdram_dout_valid),
	.din(controller_sdram_write_data),
	.we(controller_sdram_write),
	.rd(controller_sdram_read),
	.ready(controller_sdram_ready),
	.fast_tog(controller_fast_tog),
	.fast_addr(controller_fast_addr),
	.fast_stream(controller_fast_stream),
	.fast_valid(controller_fast_valid)
);

ki_framebuffer framebuffer
(
	.clk(clk_core),
	.reset(core_reset),
	.ce_pixel(CE_PIXEL),
	.advance(native_advance),
	.h_count(h_count),
	.v_count(v_count),
	.framebuffer_base(framebuffer_base),
	.memory_request(framebuffer_memory_request),
	.memory_address(framebuffer_memory_address),
	.memory_words(framebuffer_memory_words),
	.memory_data(framebuffer_memory_data),
	.memory_data_valid(framebuffer_memory_data_valid),
	.memory_done(framebuffer_memory_done),
	.red(framebuffer_red),
	.green(framebuffer_green),
	.blue(framebuffer_blue),
	.pixel_valid()
);

ki_board_io board_io
(
	.clk(clk_core),
	.reset(core_reset),
	.game_ki2(game_ki2),
	.bus_request(io_request),
	.bus_write(io_write),
	.bus_address(io_address),
	.bus_write_data(io_write_data),
	.bus_byte_enable(io_byte_enable),
	.bus_read_data(board_io_read_data),
	.bus_done(board_io_done),
	.input_p1(input_p1),
	.input_p2(input_p2),
	// Bit 1 is the sound board's "ready" line back to the game, taken from the
	// DCS host status. The game polls it, so it has to reflect the real board.
	.input_volume({30'h3fff_ffff, dcs_host_status[11], 1'b1}),
	.input_dip({16'hffff, dip_switches_live}),
	.input_unused(32'hffff_ffff),
	.irq_vblank(vblank),
	.irq_ata(ata_irq),
	.cpu_irq(cpu_irq),
	.framebuffer_base(framebuffer_base),
	.sound_reset(sound_reset),
	.sound_data(sound_data),
	.sound_data_strobe(sound_data_strobe)
);

ki_dcs_audio dcs_audio_board
(
	.clk(clk_core),
	.rst(shell_reset),
	.pause(core_pause),
	.host_reset(dcs_host_reset),
	.host_cmd_wr(sound_data_strobe),
	.host_cmd_data(sound_data[15:0]),
	.host_status(dcs_host_status),
	.rom_req(dcs_rom_request),
	.rom_addr(dcs_rom_address),
	.rom_rdy(dcs_rom_ready),
	.rom_q(dcs_rom_data),
	.audio(dcs_audio),
	.dbg_valid(),
	.dbg_unimpl(),
	.dbg_pcm_push(),
	.dbg_pc()
);

ki_ata ata
(
	.clk(clk_core),
	.reset(core_reset),
	.game_ki2(game_ki2),
	.bus_request(io_request),
	.bus_write(io_write),
	.bus_address(io_address),
	.bus_write_data(io_write_data),
	.bus_byte_enable(io_byte_enable),
	.bus_read_data(ata_read_data),
	.bus_done(ata_done),
	.irq(ata_irq),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.debug_read_lba(),
	.debug_write_lba(),
	.debug_state(),
	.debug_status()
);

// Keep RGB black while the ROM is loading or the CPU is held in reset.
// cpu_reset already includes ioctl_download, !boot_loaded, !sdram_ready,
// shell reset and the HDD-mount reset. Unlike waiting for a framebuffer page
// flip, releasing this gate lets the game's blue boot screen appear normally.
// Video timing (clock, DE, HS and VS) continues uninterrupted.
wire video_blank = cpu_reset;

reg [7:0] red;
reg [7:0] green;
reg [7:0] blue;
always @(*) begin
	red = 8'h00;
	green = 8'h00;
	blue = 8'h00;
	if(VGA_DE && !video_blank) begin
		red = framebuffer_red;
		green = framebuffer_green;
		blue = framebuffer_blue;
	end
end

assign CLK_VIDEO = clk_core;
assign VGA_R = red;
assign VGA_G = green;
assign VGA_B = blue;
// Original is square pixels, so the cropped 304 x 240 picture is 19:15 rather
// than 4:3; the dropped columns are removed, not stretched over. Wide Screen
// fills 16:9 with whatever is active either way.
assign VIDEO_ARX = status[1] ? 13'd16 : (crop ? 13'd19 : 13'd4);
assign VIDEO_ARY = status[1] ? 13'd9 : (crop ? 13'd15 : 13'd3);
assign VGA_F1 = 1'b0;
assign VGA_SL = 2'b00;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

assign LED_USER = ioctl_download | ~boot_loaded | (|cpu_errors);
assign LED_POWER = 2'b00;
assign LED_DISK = {2{sd_rd | sd_wr}};
assign BUTTONS = {1'b0, 1'b0};
// DCS is a mono board, so both channels carry the same sample. AUDIO_S stays 1
// because dcs_audio is signed.
assign AUDIO_L = dcs_audio;
assign AUDIO_R = dcs_audio;
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'b00;
assign ADC_BUS = 4'bzzzz;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bzzz;

assign DDRAM_CLK = clk_ddr;

assign SDRAM_CLK = clk_sdram_pin;

assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign USER_OUT = db15_en ? {5'b11111, db15_clk, db15_load} : 7'h7f;

`ifdef MISTER_FB
// The framebuffer is in on-chip block RAM, not DDR3, so use the FPGA scanout
// path rather than MiSTer's DDR3-only direct-framebuffer path.
assign FB_EN = 1'b0;
assign FB_FORMAT = 5'b11100;
assign FB_WIDTH = 12'd320;
assign FB_HEIGHT = 12'd240;
assign FB_BASE = 32'h3000_0000 + {13'd0, framebuffer_base};
assign FB_STRIDE = 14'd640;
assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK = CLK_50M;
assign FB_PAL_ADDR = 8'h00;
assign FB_PAL_DOUT = 24'h000000;
assign FB_PAL_WR = 1'b0;
`endif
`endif

endmodule

