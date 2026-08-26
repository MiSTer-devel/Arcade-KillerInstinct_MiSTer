`timescale 1ns/1ps


module tb_ki_rom_lbu;

    localparam logic [31:0] BOOT_BASE  = 32'h1fc0_0000;
    localparam integer      BOOT_BYTES = 524288;

    logic clk1x = 0;
    logic clk93 = 0;
    logic clk2x = 0;
    logic reset_1x = 1;
    logic reset_93 = 1;
    logic [1:0] irq = 0;

    wire        mem_request;
    wire        mem_rnw;
    wire [31:0] mem_address;
    wire        mem_req64;
    wire [2:0]  mem_size;
    wire [7:0]  mem_writeMask;
    wire [63:0] mem_dataWrite;
    logic [63:0] mem_dataRead = 0;
    logic        mem_done = 0;
    logic        cache_grant = 0;
    logic [63:0] cache_data = 0;
    logic        cache_data_ready = 0;

    wire        debug_done;
    wire [63:0] debug_pc;
    wire [31:0] debug_opcode;
    wire [63:0] debug_v0;
    wire [63:0] debug_v1;
    wire [63:0] debug_a0, debug_a1, debug_t2, debug_a3, debug_s5, debug_s6;
    wire  [5:0] debug_errors;

    // Same ratios tb_ki_ldl_ldr uses: 50 MHz clk1x, 75 MHz clk93, 100 MHz clk2x.
    always #10.000       clk1x = ~clk1x;
    always #6.666666667  clk93 = ~clk93;
    always #5.000        clk2x = ~clk2x;

    byte unsigned boot [0:BOOT_BYTES-1];

    function automatic [7:0] read_byte(input logic [31:0] address);
        if ((address >= BOOT_BASE) && (address < BOOT_BASE + BOOT_BYTES))
            read_byte = boot[address - BOOT_BASE];
        else
            read_byte = 8'h00;
    endfunction

    task automatic patch_word(input integer offset, input logic [31:0] value);
        begin
            boot[offset + 0] = value[7:0];
            boot[offset + 1] = value[15:8];
            boot[offset + 2] = value[23:16];
            boot[offset + 3] = value[31:24];
        end
    endtask

    logic        pending = 0;
    logic [31:0] pending_address;
    logic        pending_rnw;
    logic        pending_req64;
    logic [2:0]  pending_size;
    logic [2:0]  pending_beat;
    integer      lane;

    function automatic [31:0] aligned(input logic [31:0] address,
                                      input logic req64);
        aligned = req64 ? {address[31:3], 3'b000} : {address[31:2], 2'b00};
    endfunction

    always @(posedge clk1x) begin
        mem_done <= 0;
        cache_grant <= 0;
        cache_data_ready <= 0;

        if (pending) begin
            for (lane = 0; lane < 8; lane = lane + 1) begin
                mem_dataRead[lane*8 +: 8] <=
                    read_byte(aligned(pending_address, pending_req64) +
                              (pending_beat * 8) + lane);
                cache_data[lane*8 +: 8] <=
                    read_byte(aligned(pending_address, pending_req64) +
                              (pending_beat * 8) + lane);
            end
            cache_data_ready <= 1;
            if (pending_beat + 1 >= pending_size) begin
                mem_done <= 1;
                pending <= 0;
            end else begin
                pending_beat <= pending_beat + 1'b1;
            end
        end

        if (mem_request && !pending) begin
            pending <= 1;
            pending_address <= mem_address;
            pending_rnw <= mem_rnw;
            pending_req64 <= mem_req64;
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            cache_grant <= mem_rnw;
            if (mem_rnw && (mem_address >= 32'h1fc0_11c0) &&
                (mem_address <= 32'h1fc0_1220))
                $display("  BUS: addr=%08x req64=%0b size=%0d -> serviced from %08x",
                    mem_address, mem_req64, mem_size,
                    aligned(mem_address, mem_req64));
        end
    end

    ki_cpu_wrapper dut (
        .clk1x(clk1x), .clk93(clk93), .clk2x(clk2x),
        .reset_1x(reset_1x), .reset_93(reset_93), .irq(irq),
        .mem_request(mem_request), .mem_rnw(mem_rnw),
        .mem_address(mem_address), .mem_req64(mem_req64), .mem_size(mem_size),
        .mem_writeMask(mem_writeMask), .mem_dataWrite(mem_dataWrite),
        .mem_dataRead(mem_dataRead), .mem_done(mem_done),
        .cache_grant(cache_grant), .cache_data(cache_data),
        .cache_data_ready(cache_data_ready),
        .debug_done(debug_done), .debug_pc(debug_pc),
        .debug_opcode(debug_opcode), .debug_v0(debug_v0), .debug_v1(debug_v1),
        .debug_a0(debug_a0), .debug_a1(debug_a1), .debug_t2(debug_t2),
        .debug_a3(debug_a3), .debug_s5(debug_s5), .debug_s6(debug_s6),
        .debug_errors(debug_errors)
    );

    // ---- the four addresses MAME measured, plus every lane of one word ----
    localparam integer NTEST = 8;
    logic [31:0] test_addr [0:NTEST-1];
    logic  [7:0] test_want [0:NTEST-1];
    logic [63:0] test_got  [0:NTEST-1];
    logic        test_seen [0:NTEST-1];
    integer      failures = 0;

    integer t;

    initial begin
        integer index;

        for (index = 0; index < BOOT_BYTES; index = index + 1)
            boot[index] = 8'h00;
        $readmemh("sim/media/kinst_boot.hex", boot);

        if ({boot[32'h0fd1], boot[32'h0fd0]} != 16'h7262) begin
            $display("FAIL: ROM signature at 0xFD0 is %02x%02x, expected 7262",
                boot[32'h0fd1], boot[32'h0fd0]);
            $fatal(1);
        end

        // The four MAME reported, then all four lanes of the word at 11F8 so a
        // lane-selection fault is separated from a wholesale read failure.
        test_addr[0] = 32'hbfc011fb; // MAME: 1D
        test_addr[1] = 32'hbfc011e3; // MAME: 1C
        test_addr[2] = 32'hbfc0120f; // MAME: 1E
        test_addr[3] = 32'hbfc011fe; // MAME: 1B
        test_addr[4] = 32'hbfc011f8;
        test_addr[5] = 32'hbfc011f9;
        test_addr[6] = 32'hbfc011fa;
        test_addr[7] = 32'hbfc011dd;

        for (index = 0; index < NTEST; index = index + 1) begin
            test_want[index] = boot[test_addr[index] - 32'hbfc00000];
            test_seen[index] = 1'b0;
            // Each test is eight words: build the pointer, load the byte,
            // then padding so the capture window is unambiguous.
            patch_word(index * 32 + 'h00,
                       32'h3c110000 | (test_addr[index] >> 16));      // lui s1,hi
            patch_word(index * 32 + 'h04,
                       32'h36310000 | (test_addr[index] & 16'hffff)); // ori s1,s1,lo
            patch_word(index * 32 + 'h08, 32'h92230000);              // lbu v1,0(s1)
            patch_word(index * 32 + 'h0c, 32'h00000000);
            patch_word(index * 32 + 'h10, 32'h00000000);
            patch_word(index * 32 + 'h14, 32'h00000000);
            patch_word(index * 32 + 'h18, 32'h00000000);
            patch_word(index * 32 + 'h1c, 32'h00000000);
        end
        // Park.
        patch_word(NTEST * 32 + 'h00, 32'h0bf00000 | (((NTEST * 32) >> 2) & 26'h3ffffff));
        patch_word(NTEST * 32 + 'h04, 32'h00000000);

        $display("");
        $display("cpu lbu from uncached KSEG1 boot ROM");
        $display("");
        for (index = 0; index < NTEST; index = index + 1)
            $display("  test %0d: %08x expect %02x",
                     index, test_addr[index], test_want[index]);
        $display("");

        repeat (8) @(posedge clk1x);
        reset_1x <= 0;
        reset_93 <= 0;
    end

    // Capture v1 once execution has left each test's own block.
    always @(posedge clk1x) begin
        if (!reset_1x) begin
            for (t = 0; t < NTEST; t = t + 1) begin
                if (!test_seen[t] &&
                    (debug_pc[31:0] >= 32'hbfc00000 + (t * 32) + 32'h18)) begin
                    test_seen[t] <= 1'b1;
                    test_got[t]  <= debug_v1;
                end
            end
        end
    end

    initial begin
        wait (test_seen[NTEST-1] == 1'b1);
        repeat (4) @(posedge clk1x);
        $display("");
        for (t = 0; t < NTEST; t = t + 1) begin
            if (test_got[t][7:0] === test_want[t] && test_got[t][63:8] === 56'd0)
                $display("PASS: lbu %08x = %02x", test_addr[t], test_got[t][7:0]);
            else begin
                $display("FAIL: lbu %08x = %016x, expected %02x",
                         test_addr[t], test_got[t], test_want[t]);
                failures = failures + 1;
            end
        end
        $display("");
        if (failures == 0)
            $display("PASS: uncached byte loads from the boot ROM are correct");
        else
            $display("FAIL: %0d byte load(s) wrong", failures);
        $display("");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout, pc=%016x", debug_pc);
        $fatal(1);
    end

endmodule
