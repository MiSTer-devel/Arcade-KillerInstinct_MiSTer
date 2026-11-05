// SPDX-License-Identifier: GPL-3.0-only
//============================================================================
// DB15 SNAC reader for MiSTer's user port (Killer Instinct integration).
//
// Based on the Irem M72 joy_db15.sv implementation, itself adapted from
// Antonio Villena's DB15 splitter controller by Aitor Pelaez (NeuroRulez).
//
// Each 26-bit frame is captured by pulsing LOAD low, then clocking the
// cascaded 74HC165 shift registers.  Inputs are active low on the wire;
// joystick1/joystick2 report active-high button presses.
//
// Output map (matches MiSTer's low joystick bits):
//   [3:0]   Up(3), Down(2), Left(1), Right(0)
//   [9:4]   A, B, C, D, E, F (KI: HQ, HM, HF, LQ, LM, LF)
//   [10]    Start
//   [11]    Select (mapped to Coin by the KI top level)
//   [15:12] Always zero
//
// At clk = 50 MHz, DIV_BITS = 9 produces a ~48.8 kHz serial clock,
// close to the M72 reader's ~62.5 kHz at 32 MHz (DIV_BITS = 8).
// The slower rate allows settling on the user port's weak pull-ups.
//============================================================================

module joy_db15 #(
    parameter integer DIV_BITS = 9
)(
    input         clk,
    input         rst,

    output        JOY_CLK,
    output        JOY_LOAD,
    input         JOY_DATA,

    output [15:0] joystick1,
    output [15:0] joystick2
);

// Generate both serial clock edges with a clock enable: no derived clock.
reg [DIV_BITS-1:0] div = {DIV_BITS{1'b0}};
reg                joy_clk = 1'b0;
wire               tick = &div;
wire               joy_clk_rise = tick & ~joy_clk;

always @(posedge clk) begin
    if (rst) begin
        div <= {DIV_BITS{1'b0}};
        joy_clk <= 1'b0;
    end else begin
        div <= div + 1'b1;
        if (tick) joy_clk <= ~joy_clk;
    end
end

// Synchronize serial data from the external connector.
reg [1:0] data_sync = 2'b11;
always @(posedge clk) data_sync <= {data_sync[0], JOY_DATA};
wire joy_data = data_sync[1];

reg [15:0] joy1 = 16'hffff;
reg [15:0] joy2 = 16'hffff;
reg        joy_renew = 1'b1;
reg [4:0]  joy_count = 5'd0;

always @(posedge clk) begin
    if (rst) begin
        joy_count <= 5'd0;
        joy_renew <= 1'b1;
        joy1 <= 16'hffff;
        joy2 <= 16'hffff;
    end else if (joy_clk_rise) begin
        // LOAD is active low for the first clock slot of each frame.
        joy_renew <= (joy_count != 5'd0);
        joy_count <= (joy_count == 5'd25) ? 5'd0 : joy_count + 1'b1;

        case (joy_count)
            5'd2:  joy1[7]  <= joy_data;  // P1 D
            5'd3:  joy1[6]  <= joy_data;  // P1 C
            5'd4:  joy1[5]  <= joy_data;  // P1 B
            5'd5:  joy1[4]  <= joy_data;  // P1 A
            5'd6:  joy1[0]  <= joy_data;  // P1 Right
            5'd7:  joy1[1]  <= joy_data;  // P1 Left
            5'd8:  joy1[2]  <= joy_data;  // P1 Down
            5'd9:  joy1[3]  <= joy_data;  // P1 Up
            5'd10: joy2[0]  <= joy_data;  // P2 Right
            5'd11: joy2[1]  <= joy_data;  // P2 Left
            5'd12: joy2[2]  <= joy_data;  // P2 Down
            5'd13: joy2[3]  <= joy_data;  // P2 Up
            5'd14: joy1[9]  <= joy_data;  // P1 F
            5'd15: joy1[8]  <= joy_data;  // P1 E
            5'd16: joy1[11] <= joy_data;  // P1 Select
            5'd17: joy1[10] <= joy_data;  // P1 Start
            5'd18: joy2[9]  <= joy_data;  // P2 F
            5'd19: joy2[8]  <= joy_data;  // P2 E
            5'd20: joy2[11] <= joy_data;  // P2 Select
            5'd21: joy2[10] <= joy_data;  // P2 Start
            5'd22: joy2[7]  <= joy_data;  // P2 D
            5'd23: joy2[6]  <= joy_data;  // P2 C
            5'd24: joy2[5]  <= joy_data;  // P2 B
            5'd25: joy2[4]  <= joy_data;  // P2 A
            default: ;
        endcase
    end
end

assign JOY_CLK = joy_clk;
assign JOY_LOAD = joy_renew;
assign joystick1 = ~joy1;
assign joystick2 = ~joy2;

endmodule
