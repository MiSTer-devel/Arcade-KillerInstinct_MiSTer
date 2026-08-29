// SPDX-License-Identifier: GPL-3.0-only
// Killer Instinct MiSTer board-shell bring-up top level.

// Comment this line out for a release build.
//`define KI_DEBUG_BUILD

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

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
	"S0,IMG,Mount HDD Image;",
	"-;",
	"P1,Video Settings;",
	"P1O1,Aspect Ratio,Original,Full Screen;",
	"P1O2,Video Timing,Native,60Hz CRT;",
	"-;",
	"DIP;",
	"-;",
`ifdef KI_DEBUG_BUILD
	"P2,Debug;",
	"P2O4,Video Output,Game,Debug;",
	"P2O5,Debug Page,Status,Trace;",
	"P2O3,FPS Overlay,Off,On;",
	"-;",
`endif
	"R0,Reset;",
	"J1,High Quick,High Medium,High Fierce,Low Quick,Low Medium,Low Fierce,Start,Coin,Service,Test;",
	"V,1.59"
};

wire [1:0] buttons;
wire [127:0] status;
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
wire startup_osd_button;
wire [31:0] sd_lba;
wire [5:0] sd_blk_cnt;
wire sd_rd;
wire sd_wr;
wire sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din;
wire sd_buff_wr;

wire clk_core;
wire clk_cpu_75;
wire clk_cpu_100;
wire clk_sdram_shifted;
wire pll_locked;

// Keep this instance name aligned with sys/sys_top.sdc's core clock group.
pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_core),
	.outclk_1(clk_cpu_75),
	.outclk_2(clk_cpu_100),
	.outclk_3(clk_sdram_shifted),
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
	.status_in(status),
	.status_set(1'b0),
	.status_menumask(16'h0000),
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

ki_startup_osd_button startup_osd_button_inst
(
	.clk_i(clk_core),
	.reset_i(~pll_locked | RESET),
	.rom_download_i(ioctl_download),
	.rom_index_i(ioctl_index),
	.image_present_i(hdd_image_present),
	.osd_button_o(startup_osd_button)
);

reg game_ki2 = 1'b0;
reg [15:0] dip_switches = 16'hffff;

always @(posedge clk_core) begin
	if(ioctl_wr && (ioctl_index == 16'h0000) && (ioctl_addr < 27'd2)) begin
		game_ki2 <= ioctl_dout[0];
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
// Declared here rather than beside their instances because cpu_reset below
// uses all four. boot_loaded and sdram_ready were already hoisted for that
// reason; bist_busy and verify_active were not, and verify_pending needs
// bist_done and verify_done as well. Quartus tolerates the forward
// reference, but relying on that for a term that gates the CPU reset is not
// worth the risk.
wire bist_busy;
wire bist_done;
wire verify_active;
wire verify_done;
// Hold the CPU continuously while the SDRAM self-test and boot verification
// own the memory path. verify_pending bridges the registered handoff into
// verify_active so reset cannot deassert for one cycle between the two phases.
wire verify_pending = boot_loaded & bist_done & ~bist_busy &
                      ~verify_active & ~verify_done;
wire cpu_reset = core_reset | ~boot_loaded | ~sdram_ready | bist_busy |
                 verify_active | verify_pending;
wire [9:0] h_count;
wire [9:0] v_count;

wire vblank;
wire frame_start;
wire [31:0] video_vblank_count;
wire video_vblank_seen;
wire [9:0] video_max_v_count;

// ---------------------------------------------------------------------------
// Video timing selection.
//
// Native Killer Instinct timing, as documented by MAME and the original
// board, is 50 MHz / 8 = 6.25 MHz with 406 clocks/line and 261 lines/frame:
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
wire [9:0]  native_h_count;
wire [9:0]  native_v_count;
wire        native_de;
wire        native_hs;
wire        native_vs;
wire        native_vblank;
wire        native_frame_start;
wire [31:0] native_vblank_count;
wire        native_vblank_seen;
wire [9:0]  native_max_v_count;

// Keep the original generator running in both modes. Its CE_PIXEL is only
// the 1-in-8 pixel strobe, so it is safe to use as the common 6.25 MHz pixel
// enable for the alternate counters below.
ki_video_timing #(.CLOCK_DIVIDE(8)) video_timing
(
	.clk(clk_core),
	.reset(core_reset),
	.ce_pixel(native_ce_pixel),
	.h_count(native_h_count),
	.v_count(native_v_count),
	.display_enable(native_de),
	.hsync_n(native_hs),
	.vsync_n(native_vs),
	.vblank(native_vblank),
	.frame_start(native_frame_start),
	.vblank_count(native_vblank_count),
	.vblank_seen(native_vblank_seen),
	.max_v_count(native_max_v_count)
);

// NTSC-consumer-CRT-friendly 240p timing. Active video is kept at the same
// 0..319 / 0..239 coordinates expected by ki_framebuffer and debug_screen.
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
reg [31:0] crt_vblank_count = 32'd0;
reg crt_vblank_seen = 1'b0;
reg crt_frame_start = 1'b0;

always @(posedge clk_core) begin
	crt_frame_start <= 1'b0;

	if(core_reset) begin
		crt_h_count <= 10'd0;
		crt_v_count <= 10'd0;
		crt_vblank_count <= 32'd0;
		crt_vblank_seen <= 1'b0;
	end
	else if(native_ce_pixel) begin
		if(crt_h_count == CRT_H_TOTAL-1) begin
			crt_h_count <= 10'd0;

			if(crt_v_count == CRT_V_TOTAL-1) begin
				crt_v_count <= 10'd0;
				crt_frame_start <= 1'b1;
			end
			else begin
				crt_v_count <= crt_v_count + 1'b1;

				// Count the transition into vertical blank once per frame.
				if(crt_v_count == CRT_V_ACTIVE-1) begin
					crt_vblank_count <= crt_vblank_count + 1'b1;
					crt_vblank_seen <= 1'b1;
				end
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

assign CE_PIXEL = native_ce_pixel;
assign h_count = crt_60hz ? crt_h_count : native_h_count;
assign v_count = crt_60hz ? crt_v_count : native_v_count;
assign VGA_DE = crt_60hz ? crt_de : native_de;
assign VGA_HS = crt_60hz ? crt_hs : native_hs;
assign VGA_VS = crt_60hz ? crt_vs : native_vs;
assign vblank = crt_60hz ? crt_vblank : native_vblank;
assign frame_start = crt_60hz ? crt_frame_start : native_frame_start;
assign video_vblank_count = crt_60hz ? crt_vblank_count : native_vblank_count;
assign video_vblank_seen = crt_60hz ? crt_vblank_seen : native_vblank_seen;
assign video_max_v_count = crt_60hz ? CRT_V_TOTAL-1 : native_max_v_count;

// Board input bits, taken from MAME's own ioport definitions for kinst
// (tools/mame_inputs_probe.lua) rather than inferred:
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
// Low Medium, Low Fierce, Start, Coin, Service, Test.
//
// Merge MAME's default arcade keyboard controls with the matching MiSTer
// joystick bits before translating them to the board's active-low ports.
wire [12:0] keyboard_p1;
wire [12:0] keyboard_p2;

ki_keyboard keyboard
(
	.clk_i(clk_core),
	.ps2_key_i(ps2_key),
	.p1_o(keyboard_p1),
	.p2_o(keyboard_p2)
);

wire [12:0] controls_p1 = joystick_0[12:0] | keyboard_p1;
wire [12:0] controls_p2 = joystick_1[12:0] | keyboard_p2;

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
// P2 differs above bit 11: bit 12 is TILT, not Service Mode. Driving it from
// player 2's Service button tilted the game. Player 2's Service now goes to
// bit 13, Service 1, which is the genuine service input on this port, and Tilt
// is left inactive because nothing should assert it.
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

// The CONF_STR advertises a Test button that was wired to nothing. The test
// switch is DSW bit 15 (MAME :DSW mask 00008000), active low like the rest, so
// pressing Test on either pad clears it.
wire test_pressed = joystick_0[13] | joystick_1[13];
wire [15:0] dip_switches_live =
	dip_switches & {~test_pressed, 15'h7fff};

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
wire [63:0] cpu_mem_data_read;
wire cpu_mem_done;
wire cpu_mem_grant;
wire [63:0] cpu_cache_data;
wire cpu_cache_data_ready;
wire [5:0] cpu_errors;
wire [31:0] debug_cpu_pc;
wire [31:0] debug_cpu_retired;
wire [31:0] debug_cpu_irq_count;
wire [31:0] debug_cpu_t2_reload_count;
// ---------------------------------------------------------------------------
// The frozen pre-event execution trace, brought across from the CPU domain.
//
// This one is NOT a per-bit two-flop sync like every other field below, and
// deliberately so. Those carry live counters where a torn sample is merely a
// wrong digit for one frame; this carries 736 bits that must all describe the
// SAME instant, and independent bit synchronisers cannot promise that.
//
// What makes a single wide latch safe here is that the source stops changing.
// cpu.vhd freezes the whole capture on the first RAM -> boot ROM transition
// and never writes it again until reset. So: synchronise the one-bit frozen
// flag, wait for the clk93 side to have been static for a settling window,
// then take the payload once. After that the shadow is held, which also means
// the boot ROM's own execution after the restart cannot disturb what is on
// screen while it is being photographed.
//
// DEBUG_TRACE_SETTLE is counted in clk_core cycles at 50 MHz. Sixteen is
// ~320 ns against a 100 MHz source that went quiet at least two clk_core
// edges earlier, which is orders of magnitude more than the paths need.
localparam int DEBUG_TRACE_SETTLE = 16;
wire [895:0] debug_cpu_trace_bus;
wire debug_cpu_trace_frozen;
// D-cache pressure census, {line fills, writebacks} per fixed clk93 window.
// Peak over the run and the last completed window. Slow-changing, so the
// ordinary per-bit sync is fine.
// State at the last eret before the trace froze. Held inside the CPU from the
// freeze onward, so these are stable by the time the video domain samples them
// - the same treatment the other frozen CPU counters get.
wire [31:0] debug_cpu_eret_epc;
wire [31:0] debug_cpu_eret_target;
wire [31:0] debug_cpu_eret_flags;
// DS/DP: how often the delay-slot suppression actually changed a recorded
// EPC, and the first EPC it changed. Live, because a freeze or a reset may
// fire no trace trigger at all.
wire [31:0] debug_cpu_ds_count;
wire [31:0] debug_cpu_ds_first;
reg  [31:0] debug_ds_count_meta = 32'd0, debug_ds_count_sync = 32'd0;
reg  [31:0] debug_ds_first_meta = 32'd0, debug_ds_first_sync = 32'd0;
// PCM FIFO health, reported as AU and AF. Already in clk_core, so no
// synchroniser is needed - ki_dcs_audio runs on the same clock the debug
// screen does.
wire [31:0] dcs_pcm_health;
wire [31:0] dcs_pcm_level;
reg  [31:0] debug_eret_epc_meta = 32'd0,      debug_eret_epc_sync = 32'd0;
reg  [31:0] debug_eret_target_meta = 32'd0,   debug_eret_target_sync = 32'd0;
reg  [31:0] debug_eret_flags_meta = 32'd0,    debug_eret_flags_sync = 32'd0;
reg debug_trace_frozen_meta = 1'b0;
reg debug_trace_frozen_sync = 1'b0;
reg [4:0] debug_trace_settle = 5'd0;
reg [895:0] debug_trace_shadow = 896'd0;
reg debug_trace_valid = 1'b0;
wire [31:0] debug_cpu_ret_count;
reg [31:0] debug_cpu_ret_count_meta = 32'h0, debug_cpu_ret_count_sync = 32'h0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_pc_meta = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_pc_sync = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_retired_meta = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_retired_sync = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_irq_count_meta = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_irq_count_sync = 32'h0000_0000;
reg [31:0] debug_cpu_t2_reload_count_meta = 32'h0000_0000;
reg [31:0] debug_cpu_t2_reload_count_sync = 32'h0000_0000;
wire [2:0] debug_ata_state;
wire [7:0] debug_ata_status;
wire [7:0] debug_ata_error;
wire debug_ata_image_ready;
wire [31:0] debug_ata_info;

// Release switch for everything diagnostic; driven by KI_DEBUG_BUILD at the
// top of this file, which also decides whether CONF_STR carries the Debug page.
`ifdef KI_DEBUG_BUILD
localparam DEBUG_BUILD = 1;
`else
localparam DEBUG_BUILD = 0;
`endif

// Build the CPU's pre-event execution trace.
//
// Set to 0 for builds where CPU Fmax is what matters. It removes the 896-bit
// debug_trace_bus leaving cpu:core, the 736-bit shadow that latches it here,
// and - by leaving them unread - the trace capture registers inside the CPU.
// The SDC false-paths all of it so none of it appears in a timing report, but
// it is ~900 wires pulling CPU registers toward the debug screen, and this
// design's CPU paths are 61-78% interconnect.
//
// The debug screen itself stays either way. Only its trace rows go blank.
// Separate from DEBUG_BUILD so the trace - which is the part that anchors CPU
// placement - can be dropped while keeping the screen.
localparam DEBUG_TRACE = DEBUG_BUILD;
reg [31:0] debug_ata_info_meta = 32'h0000_0000;
reg [31:0] debug_ata_info_sync = 32'h0000_0000;
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
wire framebuffer_pixel_valid;
wire [24:0] bridge_sdram_address;
wire [63:0] bridge_sdram_write_data;
wire [7:0] bridge_sdram_byte_enable;
wire [4:0] bridge_sdram_burst;
wire bridge_sdram_read;
wire bridge_sdram_write;
wire [15:0] bridge_sdram_read_data;
wire bridge_sdram_data_valid;
wire bridge_sdram_done;
wire [24:0] controller_sdram_address;
wire [63:0] controller_sdram_write_data;
wire [7:0] controller_sdram_byte_enable;
wire [4:0] controller_sdram_burst;
wire controller_sdram_read;
wire controller_sdram_write;
wire [15:0] controller_sdram_read_data;
wire controller_sdram_dout_valid;
wire controller_sdram_ready;

// Physical SDRAM self test. Owns the SDRAM port until it completes, then hands
// it to the bridge for the rest of the session.
wire [24:0] bist_sdram_address;
wire [63:0] bist_sdram_write_data;
wire [7:0] bist_sdram_byte_enable;
wire [4:0] bist_sdram_burst;
wire bist_sdram_read;
wire bist_sdram_write;
wire bist_pass;
wire [15:0] bist_error_count;
wire [24:0] bist_first_bad_address;
wire [15:0] bist_first_bad_expected;
wire [15:0] bist_first_bad_actual;

// The BIST is a second requester on the adapter's auxiliary port, NOT a mux in
// front of the primary one. Steering the request lines by ownership discards
// whichever single-shot pulse is in flight when ownership changes, which
// deadlocked the ROM download.
// Boot-table write snoop, straight off the bridge's existing write path.
wire [31:0] bist_rom_checksum;

// Boot-ROM checksum taken through the CPU's own read path - the M10K mirror
// and the line buffer, neither of which the BIST's auxiliary port touches.
wire [31:0] verify_checksum;
wire verify_request;
wire [31:0] verify_address;
// Safe because the CPU is held in reset for the whole time verify_active is
// high, so cpu_mem_request is idle and nothing is in flight when ownership
// changes.
wire        bridge_cpu_request    = verify_active ? verify_request : cpu_mem_request;
wire [31:0] bridge_cpu_address    = verify_active ? verify_address : cpu_mem_address;
wire        bridge_cpu_rnw        = verify_active ? 1'b1  : cpu_mem_rnw;
wire        bridge_cpu_req64      = verify_active ? 1'b0  : cpu_mem_req64;
wire  [2:0] bridge_cpu_size       = verify_active ? 3'd1  : cpu_mem_size;
wire  [7:0] bridge_cpu_write_mask = verify_active ? 8'd0  : cpu_mem_write_mask;
wire [63:0] bridge_cpu_data_write = verify_active ? 64'd0 : cpu_mem_data_write;
wire [15:0] bist_sdram_read_data;
wire bist_sdram_data_valid;
wire bist_sdram_done;
wire sound_reset;
wire [31:0] sound_data;
wire sound_data_strobe;
wire [31:0] coin_control;

// DCS audio board, merged from KillerInstinct_MiSTer-audio. The RTL under
// rtl/dcs was already identical in both trees and only the wiring was missing:
// AUDIO_L/R were tied to zero and ki_dcs_audio was never instantiated.
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

reg debug_vblank_cpu_meta = 1'b0;
reg debug_vblank_cpu_sync = 1'b0;
reg debug_vblank_cpu_seen = 1'b0;
reg debug_cpu_reset_d = 1'b1;
reg debug_ioctl_download_d = 1'b0;
// Reset provenance is retained across the resets it records:
//   verify_rises  rising edges of verify_active over the WHOLE run. Boot is 1.
//                 2 or more would mean it really did re-trigger.
//   total_resets  rising edges of cpu_reset over the whole run.
//   late_resets   resets after the CPU has been continuously OUT of reset for
//                 2^24 core clocks, about a third of a second - far past any
//                 boot activity, so a nonzero value is a genuine mid-game
//                 reset and zero means the CPU reached BFC00000 on its own.
//   mask          cause terms, sampled only at late resets.
//
// These counters use only their initial value so reset provenance survives.
reg [3:0]  debug_rs_verify = 4'd0;
reg [3:0]  debug_rs_total = 4'd0;
reg [7:0]  debug_rs_count = 8'd0;
reg [7:0]  debug_rs_pulse_count = 8'd0;
reg [15:0] debug_rs_mask = 16'd0;
reg        debug_rs_armed = 1'b0;
reg [24:0] debug_rs_settle = 25'd0;
reg        debug_verify_active_d = 1'b0;
// Digits 2-3 are the debounced pulse count. A difference between the raw and
// debounced totals identifies a stuttering reset source.
wire [31:0] debug_reset_info =
    {debug_rs_verify, debug_rs_total, debug_rs_pulse_count, debug_rs_mask};
// The sticky mask ORs every late reset together, so one OSD reset by the
// operator contaminates it permanently and hides which term caused the FIRST
// one. This freezes the first SPONTANEOUS late reset's terms on their own.
//
// Spontaneous matters because the test procedure is: load the MRA, mount the
// image, then issue an OSD reset. That reset lands long after debug_rs_armed
// has set, so it is a "late" reset by every measure and it would otherwise be
// the one this field froze - the operator's own reset, reported as the answer.
// A pulse carrying status[0] or buttons[1] is the operator and is skipped.
//
// RESET is deliberately NOT treated as operator-initiated. The OSD reset drives
// status[0], not that pin, and an HPS asserting RESET on its own is a real
// candidate for what stops the game.
//
// Accumulated across the whole reset PULSE rather than sampled on its rising
// edge. If the cause is a PLL that has lost lock then clk_core is exactly the
// thing that cannot be trusted at that edge, and a level-sensitive OR over the
// pulse has many more chances to catch it than one clock edge does.
//
// The pulse is DEBOUNCED: it is over only once cpu_reset has been continuously
// low for 2^20 core clocks, about 21 ms. The bist/verify glitch above is one
// cycle and any other term that stutters will be similar, while the events this
// has to separate - an operator reset at the start of a run and a failure
// minutes later - are seconds apart. Belt and braces with verify_pending: the
// glitch is fixed at source, and a new one cannot silently re-create the same
// wrong reading.
localparam int RS_GAP_BITS = 20;
reg [15:0] debug_rs_first_mask = 16'd0;
reg        debug_rs_first_done = 1'b0;
reg [15:0] debug_rs_pulse_mask = 16'd0;
reg        debug_rs_pulse_active = 1'b0;
reg [RS_GAP_BITS-1:0] debug_rs_gap = {RS_GAP_BITS{1'b0}};
reg [3:0]  debug_rs_spont_count = 4'd0;
// PLL lock, watched from the RAW 50 MHz reference instead of from a clock the
// PLL produces. If pll_locked is what drops, every counter in the clk_core
// domain is suspect at precisely the moment that matters; CLK_50M keeps
// running regardless. Never reset - it has to survive what it counts.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg debug_pll_lock_meta = 1'b0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg debug_pll_lock_sync = 1'b0;
reg debug_pll_lock_d = 1'b0;
reg [7:0] debug_pll_unlock_count = 8'd0;

always @(posedge CLK_50M) begin
	debug_pll_lock_meta <= pll_locked;
	debug_pll_lock_sync <= debug_pll_lock_meta;
	debug_pll_lock_d    <= debug_pll_lock_sync;
	if(!debug_pll_lock_sync && debug_pll_lock_d &&
	   debug_pll_unlock_count != 8'hff)
		debug_pll_unlock_count <= debug_pll_unlock_count + 8'd1;
end

// The unlock count changes at most a handful of times in a run, so reading it
// through a plain two-flop sync can at worst show one stale digit for one
// frame. That is acceptable here and a handshake is not worth the logic.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [7:0] debug_pll_unlock_meta = 8'd0;
reg [7:0] debug_pll_unlock_sync = 8'd0;
reg [7:0] debug_ioctl_download_count = 8'h00;
wire [31:0] debug_reset_first =
    {debug_rs_first_mask, debug_pll_unlock_sync,
     debug_rs_spont_count, debug_ioctl_download_count[3:0]};
always @(posedge clk_core) begin
	debug_cpu_reset_d <= cpu_reset;
	debug_ioctl_download_d <= ioctl_download;
	// Every verify_active rise, over the whole run. Boot contributes exactly 1.
	debug_verify_active_d <= verify_active;
	if(verify_active && !debug_verify_active_d && debug_rs_verify != 4'hf)
		debug_rs_verify <= debug_rs_verify + 1'b1;
	// Every cpu_reset rise, over the whole run.
	if(cpu_reset && !debug_cpu_reset_d && debug_rs_total != 4'hf)
		debug_rs_total <= debug_rs_total + 1'b1;
	// Arm only after the CPU has been continuously out of reset long enough
	// that boot cannot still be in progress.
	if(cpu_reset) debug_rs_settle <= 25'd0;
	else if(!debug_rs_armed) begin
		if(debug_rs_settle == 25'h1ffffff) debug_rs_armed <= 1'b1;
		else debug_rs_settle <= debug_rs_settle + 1'b1;
	end
	debug_pll_unlock_meta <= debug_pll_unlock_count;
	debug_pll_unlock_sync <= debug_pll_unlock_meta;
	// Accumulate the terms of the late reset PULSE currently in progress, then
	// judge it once the pulse has been over for the debounce window. A pulse is
	// the operator's if status[0] or buttons[1] appeared anywhere in it;
	// anything else is spontaneous, gets counted, and the first one freezes RF.
	if(cpu_reset) begin
		debug_rs_gap <= {RS_GAP_BITS{1'b0}};
		if(debug_rs_armed) begin
			debug_rs_pulse_active  <= 1'b1;
			debug_rs_pulse_mask[0] <= debug_rs_pulse_mask[0] | shell_reset;
			debug_rs_pulse_mask[1] <= debug_rs_pulse_mask[1] | ioctl_download;
			debug_rs_pulse_mask[2] <= debug_rs_pulse_mask[2] | ~boot_loaded;
			debug_rs_pulse_mask[3] <= debug_rs_pulse_mask[3] | ~sdram_ready;
			debug_rs_pulse_mask[4] <= debug_rs_pulse_mask[4] | bist_busy;
			debug_rs_pulse_mask[5] <= debug_rs_pulse_mask[5] | verify_active;
			debug_rs_pulse_mask[6] <= debug_rs_pulse_mask[6] | ~pll_locked;
			debug_rs_pulse_mask[7] <= debug_rs_pulse_mask[7] | status[0];
			debug_rs_pulse_mask[8] <= debug_rs_pulse_mask[8] | RESET;
			debug_rs_pulse_mask[9] <= debug_rs_pulse_mask[9] | buttons[1];
		end
	end else begin
		if(debug_rs_gap != {RS_GAP_BITS{1'b1}})
			debug_rs_gap <= debug_rs_gap + 1'b1;
		else if(debug_rs_pulse_active) begin
			debug_rs_pulse_active <= 1'b0;
			debug_rs_pulse_mask   <= 16'd0;
			if(debug_rs_pulse_count != 8'hff)
				debug_rs_pulse_count <= debug_rs_pulse_count + 8'd1;
			if(!debug_rs_pulse_mask[7] && !debug_rs_pulse_mask[9]) begin
				if(debug_rs_spont_count != 4'hf)
					debug_rs_spont_count <= debug_rs_spont_count + 4'd1;
				if(!debug_rs_first_done) begin
					debug_rs_first_mask <= debug_rs_pulse_mask;
					debug_rs_first_done <= 1'b1;
				end
			end
		end
	end
	if(debug_rs_armed && cpu_reset && !debug_cpu_reset_d) begin
		if(debug_rs_count != 8'hff)
			debug_rs_count <= debug_rs_count + 1'b1;
		debug_rs_mask[0] <= debug_rs_mask[0] | shell_reset;
		debug_rs_mask[1] <= debug_rs_mask[1] | ioctl_download;
		debug_rs_mask[2] <= debug_rs_mask[2] | ~boot_loaded;
		debug_rs_mask[3] <= debug_rs_mask[3] | ~sdram_ready;
		debug_rs_mask[4] <= debug_rs_mask[4] | bist_busy;
		debug_rs_mask[5] <= debug_rs_mask[5] | verify_active;
		debug_rs_mask[6] <= debug_rs_mask[6] | ~pll_locked;
		debug_rs_mask[7] <= debug_rs_mask[7] | status[0];
		debug_rs_mask[8] <= debug_rs_mask[8] | RESET;
		debug_rs_mask[9] <= debug_rs_mask[9] | buttons[1];
	end
	if(ioctl_download && !debug_ioctl_download_d)
		debug_ioctl_download_count <= debug_ioctl_download_count + 1'b1;
end

// Mirror the CPU wrapper's vblank synchronizer for diagnostics. The sampled
// value is sticky so the 50 MHz debug page can report a pulse seen by CPU time.
always @(posedge clk_cpu_75) begin
	if(cpu_reset) begin
		debug_vblank_cpu_meta <= 1'b0;
		debug_vblank_cpu_sync <= 1'b0;
		debug_vblank_cpu_seen <= 1'b0;
	end else begin
		debug_vblank_cpu_meta <= vblank;
		debug_vblank_cpu_sync <= debug_vblank_cpu_meta;
		if(debug_vblank_cpu_sync)
			debug_vblank_cpu_seen <= 1'b1;
	end
end

always @(posedge clk_core) begin
	debug_cpu_pc_meta <= debug_cpu_pc;
	debug_cpu_pc_sync <= debug_cpu_pc_meta;
	debug_cpu_retired_meta <= debug_cpu_retired;
	debug_cpu_retired_sync <= debug_cpu_retired_meta;
	debug_cpu_irq_count_meta <= debug_cpu_irq_count;
	debug_cpu_irq_count_sync <= debug_cpu_irq_count_meta;
	debug_cpu_t2_reload_count_meta <= debug_cpu_t2_reload_count;
	debug_cpu_t2_reload_count_sync <= debug_cpu_t2_reload_count_meta;
	debug_cpu_ret_count_meta <= debug_cpu_ret_count;
	debug_cpu_ret_count_sync <= debug_cpu_ret_count_meta;
	debug_ata_info_meta <= debug_ata_info;
	debug_ata_info_sync <= debug_ata_info_meta;
	debug_ds_count_meta <= debug_cpu_ds_count;
	debug_ds_count_sync <= debug_ds_count_meta;
	debug_ds_first_meta <= debug_cpu_ds_first;
	debug_ds_first_sync <= debug_ds_first_meta;
	debug_eret_epc_meta <= debug_cpu_eret_epc;
	debug_eret_epc_sync <= debug_eret_epc_meta;
	debug_eret_target_meta <= debug_cpu_eret_target;
	debug_eret_target_sync <= debug_eret_target_meta;
	debug_eret_flags_meta <= debug_cpu_eret_flags;
	debug_eret_flags_sync <= debug_eret_flags_meta;
	if(shell_reset) begin
		debug_cpu_pc_meta <= 32'h0000_0000;
		debug_cpu_pc_sync <= 32'h0000_0000;
		debug_cpu_retired_meta <= 32'h0000_0000;
		debug_cpu_retired_sync <= 32'h0000_0000;
		debug_cpu_irq_count_meta <= 32'h0000_0000;
		debug_cpu_irq_count_sync <= 32'h0000_0000;
		debug_cpu_t2_reload_count_meta <= 32'h0000_0000;
		debug_cpu_t2_reload_count_sync <= 32'h0000_0000;
	end
end

assign io_read_data = ata_done ? ata_read_data : board_io_read_data;
assign io_done = board_io_done | ata_done;

// ki_ata drives bus_done combinationally from bus_request, so the command
// request itself is edge-detected to separate adjacent accesses.
wire ata_cmd_write = io_request && io_write &&
                     (io_address == 32'h1000_0138) && io_byte_enable[0];
reg        ata_cmd_write_d = 1'b0;

always @(posedge clk_core) begin
	if(core_reset)
		ata_cmd_write_d <= 1'b0;
	else
		ata_cmd_write_d <= ata_cmd_write;
end

// ---------------------------------------------------------------------------
// "THE GAME HAS RESTARTED", from the board side.
//
// The trace's own triggers are pc comparisons and can only catch a restart
// that goes where they are looking. This one does not care: INITIALIZE DEVICE
// PARAMETERS is issued by the disk-init routine, which is reached only from
// the game's startup path, so a later invocation means startup ran again.
//
// Held once asserted, so the CPU-domain synchronizer cannot miss it.
// Disk init issues 0x91 twice per startup, so the third invocation is the first
// one that can indicate a restart.
reg  [7:0] ata_init_count = 8'd0;
// The THIRD disk init. Exactly two per startup in both games, measured, so the
// third belongs to the restart. Counted rather than gated: the CPU's
// end-of-boot flag opens before the first handoff and cannot be used here.
wire ata_restart_seen = (ata_init_count >= 8'd3);

always @(posedge clk_core) begin
	if(core_reset) begin
		ata_init_count <= 8'd0;
	end else begin
		if(ata_cmd_write && !ata_cmd_write_d &&
		   io_write_data[7:0] == 8'h91 && ata_init_count != 8'hff)
			ata_init_count <= ata_init_count + 8'd1;
	end
end

ki_cpu_core #(.DEBUG_TRACE(DEBUG_TRACE)) cpu
(
	.clk1x(clk_core),
	.clk93(clk_cpu_75),
	.clk2x(clk_cpu_100),
	.reset(cpu_reset),
	.irq(cpu_irq),
	.mem_request(cpu_mem_request),
	.mem_rnw(cpu_mem_rnw),
	.mem_address(cpu_mem_address),
	.mem_req64(cpu_mem_req64),
	.mem_size(cpu_mem_size),
	.mem_writeMask(cpu_mem_write_mask),
	.mem_dataWrite(cpu_mem_data_write),
	.mem_dataRead(cpu_mem_data_read),
	.mem_done(cpu_mem_done),
	.cache_grant(cpu_mem_grant),
	.cache_data(cpu_cache_data),
	.cache_data_ready(cpu_cache_data_ready),
	.errors(cpu_errors),
	.debug_fetch_pc(debug_cpu_pc),
	.debug_retired(debug_cpu_retired),
	.debug_gpr_s1(),
	.debug_irq_count(debug_cpu_irq_count),
	.debug_t2_reload_count(debug_cpu_t2_reload_count),
	.debug_h1_op(),
	.debug_exc_cause(),
	.debug_ret_count(debug_cpu_ret_count),
	.debug_trace_bus(debug_cpu_trace_bus),
	.debug_trace_frozen(debug_cpu_trace_frozen),
	.debug_trace_trigger(ata_restart_seen),
	.debug_ds_count(debug_cpu_ds_count),
	.debug_ds_first(debug_cpu_ds_first),
	.debug_eret_epc(debug_cpu_eret_epc),
	.debug_eret_target(debug_cpu_eret_target),
	.debug_eret_flags(debug_cpu_eret_flags),
	.debug_retire_pc(),
	.debug_retire_opcode()
);

generate if (DEBUG_TRACE) begin : g_trace_shadow
	// Latch the frozen trace once, on the clk_core side. See the declaration
	// comment for why this is a single wide capture instead of the usual per-bit
	// two-flop sync.
	always @(posedge clk_core) begin
		debug_trace_frozen_meta <= debug_cpu_trace_frozen;
		debug_trace_frozen_sync <= debug_trace_frozen_meta;

		if(shell_reset) begin
			debug_trace_frozen_meta <= 1'b0;
			debug_trace_frozen_sync <= 1'b0;
			debug_trace_settle <= 5'd0;
			debug_trace_valid <= 1'b0;
			debug_trace_shadow <= 896'd0;
		end else if(!debug_trace_valid) begin
			if(!debug_trace_frozen_sync) begin
				debug_trace_settle <= 5'd0;
			end else if(debug_trace_settle != DEBUG_TRACE_SETTLE[4:0]) begin
				debug_trace_settle <= debug_trace_settle + 5'd1;
			end else begin
				debug_trace_shadow <= debug_cpu_trace_bus;
				debug_trace_valid <= 1'b1;
			end
		end
	end
end else begin : g_no_trace_shadow
	// Nothing to latch: cpu.vhd drives the bus to zero when the trace is not
	// built, so the shadow and its settle counter would be 896 registers
	// holding a constant.
	always @(posedge clk_core) begin
		debug_trace_frozen_meta <= 1'b0;
		debug_trace_frozen_sync <= 1'b0;
		debug_trace_settle      <= 5'd0;
		debug_trace_valid       <= 1'b0;
		debug_trace_shadow      <= 896'd0;
	end
end endgenerate

ki_memory_bridge memory_bridge
(
	.clk(clk_core),
	.ddr_clk(clk_cpu_100),
	.reset(shell_reset),
	.cpu_request(bridge_cpu_request),
	.cpu_rnw(bridge_cpu_rnw),
	.cpu_address(bridge_cpu_address),
	.cpu_req64(bridge_cpu_req64),
	.cpu_size(bridge_cpu_size),
	.cpu_write_mask(bridge_cpu_write_mask),
	.cpu_data_write(bridge_cpu_data_write),
	.cpu_data_read(cpu_mem_data_read),
	.cpu_done(cpu_mem_done),
	.cpu_grant(cpu_mem_grant),
	.cpu_cache_data(cpu_cache_data),
	.cpu_cache_data_ready(cpu_cache_data_ready),
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
	.debug_fill_b0(),
	.debug_fill_b1(),
	.fb_read_accept(),
	.fb_write_accept(),
	.debug_state(),
	.debug_cpu_pending(),
	.debug_last_write_address(),
	.debug_last_write_data(),
	.debug_last_write_info(),
	.debug_write_count(),
	.debug_low_write_count(),
	.debug_main_write_count(),
	.debug_main_write0(),
	.debug_main_write1(),
	.debug_main_write2(),
	.debug_table_write_count(),
	.debug_table_write_address(),
	.debug_table_write_data()
);

// 256 words per pass. Hardware reported a stall at transaction 2517 of the
// 4096-word sweep (EP:49D5 AC:09D5 = WRITE_ACK, index 2517). A short sweep
// completes well inside that and finally exercises the READ-BACK path, which
// is the phase question we have been trying to answer. The long-sweep stall
// is tracked separately as a real arbitration/handshake defect.
ki_sdram_bist #(.WORDS(256)) sdram_bist
(
	.clk(clk_core),
	.reset(shell_reset),
	.sdram_ready(sdram_ready),
	.boot_loaded(boot_loaded),
	.request_address(bist_sdram_address),
	.request_write_data(bist_sdram_write_data),
	.request_byte_enable(bist_sdram_byte_enable),
	.request_burst(bist_sdram_burst),
	.request_read(bist_sdram_read),
	.request_write(bist_sdram_write),
	.request_read_data(bist_sdram_read_data),
	.request_data_valid(bist_sdram_data_valid),
	.request_done(bist_sdram_done),
	.rom_checksum(bist_rom_checksum),
	.busy(bist_busy),
	.done(bist_done),
	.pass(bist_pass),
	.error_count(bist_error_count),
	.first_bad_address(bist_first_bad_address),
	.first_bad_expected(bist_first_bad_expected),
	.first_bad_actual(bist_first_bad_actual)
);

// Runs once, after the ROM is loaded and the SDRAM self test has released the
// memory port, while the CPU is still held in reset.
ki_boot_verify boot_verify
(
	.clk(clk_core),
	.reset(shell_reset),
	.start(boot_loaded & bist_done & ~bist_busy),
	.active(verify_active),
	.done(verify_done),
	.checksum(verify_checksum),
	.cpu_request(verify_request),
	.cpu_address(verify_address),
	.cpu_data_read(cpu_mem_data_read),
	.cpu_done(cpu_mem_done)
);

ki_sdram_adapter sdram_adapter
(
	.clk(clk_core),
	.reset(~pll_locked),
	.request_address(bridge_sdram_address),
	.request_write_data(bridge_sdram_write_data),
	.request_byte_enable(bridge_sdram_byte_enable),
	.request_burst(bridge_sdram_burst),
	.request_read(bridge_sdram_read),
	.request_write(bridge_sdram_write),
	.request_read_data(bridge_sdram_read_data),
	.request_data_valid(bridge_sdram_data_valid),
	.request_done(bridge_sdram_done),
	.aux_address(bist_sdram_address),
	.aux_write_data(bist_sdram_write_data),
	.aux_byte_enable(bist_sdram_byte_enable),
	.aux_burst(bist_sdram_burst),
	.aux_read(bist_sdram_read),
	.aux_write(bist_sdram_write),
	.aux_read_data(bist_sdram_read_data),
	.aux_data_valid(bist_sdram_data_valid),
	.aux_done(bist_sdram_done),
	.sdram_ready(sdram_ready),
	.controller_address(controller_sdram_address),
	.controller_write_data(controller_sdram_write_data),
	.controller_byte_enable(controller_sdram_byte_enable),
	.controller_burst(controller_sdram_burst),
	.controller_read(controller_sdram_read),
	.controller_write(controller_sdram_write),
	.controller_read_data(controller_sdram_read_data),
	.controller_dout_valid(controller_sdram_dout_valid),
	.controller_ready(controller_sdram_ready)
);

// The address decomposition uses col = addr[9:1], so 512 consecutive words
// share a row and a burst is a sequence of back-to-back column accesses.
// SDRAM contents are transient because the ROM download repopulates memory on
// every core load.
ki_sdram_burst sdram_controller
(
	.init(~pll_locked),
	.clk(clk_core),
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
	.ready(controller_sdram_ready)
);

ki_framebuffer framebuffer
(
	.clk(clk_core),
	.reset(core_reset),
	.ce_pixel(CE_PIXEL),
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
	.pixel_valid(framebuffer_pixel_valid)
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
	// DCS host status. It read all-ones while audio was stubbed out; the game
	// polls it, so it has to reflect the real board now that one exists.
	.input_volume({30'h3fff_ffff, dcs_host_status[11], 1'b1}),
	.input_dip({16'hffff, dip_switches_live}),
	.input_unused(32'hffff_ffff),
	.irq_vblank(vblank),
	.irq_ata(ata_irq),
	.cpu_irq(cpu_irq),
	.framebuffer_base(framebuffer_base),
	.sound_reset(sound_reset),
	.sound_data(sound_data),
	.sound_data_strobe(sound_data_strobe),
	.coin_control(coin_control)
);

ki_dcs_audio dcs_audio_board
(
	.clk(clk_core),
	.rst(shell_reset),
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
	.dbg_pc(),
	.dbg_pcm_health(dcs_pcm_health),
	.dbg_pcm_level(dcs_pcm_level)
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
	.debug_info(debug_ata_info),
	.debug_read_lba(),
	.debug_write_lba(),
	.debug_write_info(),
	.debug_dataport_info(),
	.debug_state(debug_ata_state),
	.debug_status(debug_ata_status),
	.debug_error(debug_ata_error),
	.debug_image_ready(debug_ata_image_ready)
);

// RC, repacked so all three restart shapes fit one row:
//
//   digits 0-1  executions of 0x88000000, the entry point. Boot is 1.
//   digits 2-3  ATA INITIALIZE DEVICE PARAMETERS commands. Boot is 1.
//   digits 4-7  RAM -> boot ROM transitions.
//
// The CPU exports {entry[15:0], transitions[15:0]}; only the low byte of the
// entry count can plausibly be non-zero, so bits 23:16 carry it.
wire [31:0] debug_restart_info =
    {debug_cpu_ret_count_sync[23:16], ata_init_count,
     debug_cpu_ret_count_sync[15:0]};

wire [7:0] debug_red;
wire [7:0] debug_green;
wire [7:0] debug_blue;

wire [6:0] fps_value;
wire fps_box_pixel;
wire fps_glyph_pixel;

generate if (DEBUG_BUILD) begin : g_overlays
	ki_fps_overlay fps_overlay
	(
		.clk(clk_core),
		.reset(core_reset),
		.frame_start(frame_start),
		.timing_60hz(crt_60hz),
		.framebuffer_base(framebuffer_base),
		.h_count(h_count),
		.v_count(v_count),
		.fps(fps_value),
		.box_pixel(fps_box_pixel),
		.glyph_pixel(fps_glyph_pixel)
	);

	ki_debug_screen debug_screen
	(
		.clk(clk_core),
		.frame_start(frame_start),
		.h_count(h_count),
		.v_count(v_count),
		.display_enable(VGA_DE),
		.cpu_reset(cpu_reset),
		.boot_loaded(boot_loaded),
		.pll_locked(pll_locked),
		.image_present((img_size >= 64'd512) | debug_ata_image_ready),
		.cpu_errors(cpu_errors),
		.cpu_pc(debug_cpu_pc_sync),
		.cpu_retired(debug_cpu_retired_sync),
		.cpu_irq_count(debug_cpu_irq_count_sync),
		.cpu_prev_op(debug_ds_first_sync),
		.cpu_ret_prev(debug_eret_target_sync),
		.cpu_eret_flags(debug_eret_flags_sync),
		.cpu_ret_count(debug_restart_info),
		.cpu_ret_pc(debug_ds_count_sync),
		.pcm_health(dcs_pcm_health),
		.pcm_level(dcs_pcm_level),
		.cpu_response_status(debug_eret_epc_sync),
		.reset_info(debug_reset_info),
		.reset_first(debug_reset_first),
		.ata_info(debug_ata_info_sync),
		.cpu_t2_reload_count(debug_cpu_t2_reload_count_sync),
		.video_max_v_count(video_max_v_count),
		.video_vblank_seen(video_vblank_seen),
		.cpu_vblank_seen(debug_vblank_cpu_seen),
		.vblank_count(video_vblank_count),
		.ata_state(debug_ata_state),
		.ata_status(debug_ata_status),
		.ata_error(debug_ata_error),
		// Page 1 is the frozen pre-event trace. It is fed from the clk_core
		// shadow, not from the CPU domain directly, so what is on screen is a
		// coherent capture rather than a live sample of a 736-bit bus.
		.page(status[5]),
		.trace_bus(debug_trace_shadow),
		.trace_valid(debug_trace_valid),
		.bist_done(bist_done),
		.bist_pass(bist_pass),
		.bist_error_count(bist_error_count),
		.bist_first_bad_expected(bist_first_bad_expected),
		.bist_first_bad_actual(bist_first_bad_actual),
		.red(debug_red),
		.green(debug_green),
		.blue(debug_blue)
	);
end else begin : g_no_overlays
	// Release: nothing renders. The video mux below folds these constants
	// away, so neither overlay nor the registers feeding them are built.
	assign fps_box_pixel   = 1'b0;
	assign fps_glyph_pixel = 1'b0;
	assign debug_red       = 8'h00;
	assign debug_green     = 8'h00;
	assign debug_blue      = 8'h00;
end endgenerate

reg [7:0] red;
reg [7:0] green;
reg [7:0] blue;
always @(*) begin
	red = 8'h00;
	green = 8'h00;
	blue = 8'h00;
	if(VGA_DE) begin
		// Game or Debug. With DEBUG_BUILD off there is no debug raster to
		// select, so the option falls back to the game instead of black.
		if(!DEBUG_BUILD || !status[4]) begin
			red = framebuffer_red;
			green = framebuffer_green;
			blue = framebuffer_blue;
		end else begin
			red = debug_red;
			green = debug_green;
			blue = debug_blue;
		end

		if(status[3] && fps_box_pixel) begin
			red = fps_glyph_pixel ? 8'hf0 : 8'h08;
			green = fps_glyph_pixel ? 8'hf0 : 8'h08;
			blue = fps_glyph_pixel ? 8'hf0 : 8'h08;
		end
	end
end

assign CLK_VIDEO = clk_core;
assign VGA_R = red;
assign VGA_G = green;
assign VGA_B = blue;
assign VIDEO_ARX = status[1] ? 13'd16 : 13'd4;
assign VIDEO_ARY = status[1] ? 13'd9 : 13'd3;
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
assign BUTTONS = {1'b0, startup_osd_button};
// DCS is a mono board, so both channels carry the same sample. AUDIO_S stays 1
// because dcs_audio is signed.
assign AUDIO_L = dcs_audio;
assign AUDIO_R = dcs_audio;
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'b00;
assign ADC_BUS = 4'bzzzz;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bzzz;

assign DDRAM_CLK = clk_cpu_100;

assign SDRAM_CLK = clk_sdram_shifted;

assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign USER_OUT = 7'h7f;

`ifdef MISTER_FB
// The framebuffer now resides in physical SDRAM, so use the FPGA scanout
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

`undef KI_DEBUG_BUILD
