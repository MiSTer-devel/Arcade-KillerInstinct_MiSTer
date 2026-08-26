// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_dcs_rom_map;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic rom_req = 1'b0;
    logic [22:0] rom_addr = '0;
    wire rom_rdy;
    wire [7:0] rom_q;
    wire ext_req;
    wire [18:0] ext_addr;
    logic ext_rdy = 1'b0;
    logic [63:0] ext_q = '0;

    integer external_reads = 0;
    logic response_armed = 1'b1;
    logic response_pending = 1'b0;
    logic [18:0] response_address = '0;

    always #5 clk = !clk;

    dcs_mem #(
        .DDR_LATENCY(8),
        .PF_LINES(16),
        .EXT_ROM(1),
        .KI_ROM_MAP(1),
        .CORE_CE_EN(0)
    ) dut (
        .clk(clk),
        .rst(rst),
        .core_ce(1'b1),
        .rom_req(rom_req),
        .rom_addr(rom_addr),
        .rom_rdy(rom_rdy),
        .rom_q(rom_q),
        .ext_req(ext_req),
        .ext_addr(ext_addr),
        .ext_rdy(ext_rdy),
        .ext_q(ext_q)
    );

    function automatic [63:0] make_beat(input logic [18:0] beat_address);
        logic [21:0] byte_base;
        integer lane;
        begin
            byte_base = {beat_address, 3'b000};
            for (lane = 0; lane < 8; lane = lane + 1)
                make_beat[(lane * 8) +: 8] = byte_base[7:0] + lane[7:0];
        end
    endfunction

    // Model a one-outstanding, one-cycle response DDR client. The armed flag
    // prevents the level request from being counted twice before it drops.
    always_ff @(posedge clk) begin
        ext_rdy <= 1'b0;
        if (!ext_req)
            response_armed <= 1'b1;

        if (ext_req && response_armed && !response_pending) begin
            response_armed <= 1'b0;
            response_pending <= 1'b1;
            response_address <= ext_addr;
            external_reads <= external_reads + 1;
        end else if (response_pending) begin
            response_pending <= 1'b0;
            ext_q <= make_beat(response_address);
            ext_rdy <= 1'b1;
        end
    end

    task automatic read_byte(
        input logic [22:0] logical_address,
        input logic [7:0] expected_data,
        input integer expected_new_reads,
        input logic [18:0] expected_beat
    );
        integer reads_before;
        integer timeout;
        begin
            reads_before = external_reads;
            rom_addr = logical_address;
            rom_req = 1'b1;
            timeout = 0;
            while (!rom_rdy) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
                if (timeout > 40)
                    $fatal(1, "DCS ROM read timed out at logical address %06h", logical_address);
            end
            if (rom_q !== expected_data)
                $fatal(1, "DCS ROM data mismatch at %06h: got %02h expected %02h",
                       logical_address, rom_q, expected_data);
            if ((external_reads - reads_before) != expected_new_reads)
                $fatal(1, "DCS ROM request count mismatch at %06h: got %0d expected %0d",
                       logical_address, external_reads - reads_before, expected_new_reads);
            if (expected_new_reads && response_address !== expected_beat)
                $fatal(1, "DCS packed beat mismatch at %06h: got %05h expected %05h",
                       logical_address, response_address, expected_beat);
            rom_req = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // First chip, two lanes in one cached DDR beat.
        read_byte(23'h000005, 8'h05, 1, 19'h00000);
        read_byte(23'h000006, 8'h06, 0, 19'h00000);

        // Empty upper half of chip 0's 2 MiB MAME window must read as FF and
        // must never reach DDR.
        read_byte(23'h080000, 8'hff, 0, 19'h00000);

        // The next populated window packs directly after the first 512 KiB.
        read_byte(23'h100003, 8'h03, 1, 19'h10000);

        // Final byte of the eighth KI DCS ROM.
        read_byte(23'h77ffff, 8'hff, 1, 19'h7ffff);

        if (external_reads != 3)
            $fatal(1, "unexpected total DDR reads: %0d", external_reads);

        $display("PASS: KI DCS sparse ROM mapping and cache behavior");
        $finish;
    end
endmodule

`default_nettype wire
