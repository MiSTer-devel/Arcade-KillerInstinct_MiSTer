`timescale 1ns/1ps

// Executes the boot ROM's unaligned 64-bit load pair in isolation.
//
// The ROM gates its permutation-table initialiser on a bitstream reader whose
// only data source is this pair (9FC00D5C/9FC00D60):
//
//     ldl v1,7(s1)
//     ldr v1,0(s1)
//
// tools/bitreader_model.py, validated against two syscall-guarded checks the
// ROM itself enforces, says the gate value must be 0x88000000. On hardware it
// is 0, which skips the initialiser and hangs boot in an unbounded scan.
//
// The value v1 takes is decisive because ITS ENTIRE PAYLOAD IS IN THE UPPER 32
// BITS AND COMES SOLELY FROM THE LDL - the low half is zero. If LDL contributes
// nothing, v1 = 0 and the gate reads 0, exactly the observed failure.
//
// The full-system bench cannot answer this: it deadlocks at instruction 597 on
// the cache-init routine's KSEG0 load, long before the gate. This runs the two
// instructions directly against the real ROM bytes in milliseconds.
//
// The memory responder masks reads to the doubleword, matching what
// ki_memory_bridge actually does (boot_cache_read_address <= addr[14:3], and
// memory_word_address <= {storage[25:3],2'b00}). Without that the harness would
// answer LDL from the wrong doubleword and the result would say nothing about
// hardware.

module tb_ki_ldl_ldr;

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
    wire [63:0] debug_v0, debug_v1, debug_a0, debug_a1;
    wire [63:0] debug_t2, debug_a3, debug_s5, debug_s6;
    wire [5:0]  debug_errors;

    byte unsigned boot [0:BOOT_BYTES-1];

    always #10.000        clk1x = ~clk1x;
    always #6.666666667   clk93 = ~clk93;
    always #5.000         clk2x = ~clk2x;

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

    function automatic [7:0] read_byte(input logic [31:0] address);
        if (address >= BOOT_BASE && address < BOOT_BASE + BOOT_BYTES)
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

    // Match ki_memory_bridge: 64-bit reads are answered from the containing
    // doubleword, 32-bit reads from the containing word.
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
            // Only the two loads under test touch this window.
            if (mem_rnw && (mem_address >= 32'h1fc0_0fc0) &&
                (mem_address <= 32'h1fc0_0ff0))
                $display("  BUS: addr=%08x req64=%0b size=%0d -> serviced from %08x",
                    mem_address, mem_req64, mem_size,
                    aligned(mem_address, mem_req64));
        end
    end

    logic [63:0] result1 = 64'hx;
    logic [63:0] result2 = 64'hx;
    logic        captured1 = 0;
    logic        captured2 = 0;
    integer      failures = 0;

    // Expected values, computed by tools/bitreader_model.py from the real ROM
    // and independently re-derived by hand from the LDL/LDR definitions.
    localparam logic [63:0] EXPECT1 = 64'h4A00A78800000000;  // s1 = BFC00FD7
    localparam logic [63:0] EXPECT2 = 64'h022300400002054A;  // s1 = BFC00FDE

    task automatic check(input string name, input logic [63:0] got,
                         input logic [63:0] want);
        begin
            if (got === want)
                $display("PASS: %s = %016x", name, got);
            else begin
                $display("FAIL: %s = %016x, expected %016x", name, got, want);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        integer index;
        integer hexfile;

        for (index = 0; index < BOOT_BYTES; index = index + 1)
            boot[index] = 8'h00;
        $readmemh("sim/media/kinst_boot.hex", boot);

        // Sanity: the bitstream signature must be present, or the ROM image is
        // not what the model was built against and nothing below means anything.
        if ({boot[32'h0fd1], boot[32'h0fd0]} != 16'h7262) begin
            $display("FAIL: ROM signature at 0xFD0 is %02x%02x, expected 7262",
                boot[32'h0fd1], boot[32'h0fd0]);
            $fatal(1);
        end

        // Test 1: s1 = BFC00FD7 (the reader's first source pointer)
        patch_word('h00, 32'h3c11bfc0);   // lui s1,0xbfc0
        patch_word('h04, 32'h36310fd7);   // ori s1,s1,0x0fd7
        patch_word('h08, 32'h6a230007);   // ldl v1,7(s1)
        patch_word('h0c, 32'h6e230000);   // ldr v1,0(s1)
        patch_word('h10, 32'h00000000);
        patch_word('h14, 32'h00000000);
        patch_word('h18, 32'h00000000);
        patch_word('h1c, 32'h00000000);

        // Test 2: s1 = BFC00FDE (the pointer after the reader advances by 7)
        patch_word('h20, 32'h3c11bfc0);   // lui s1,0xbfc0
        patch_word('h24, 32'h36310fde);   // ori s1,s1,0x0fde
        patch_word('h28, 32'h6a230007);   // ldl v1,7(s1)
        patch_word('h2c, 32'h6e230000);   // ldr v1,0(s1)
        patch_word('h30, 32'h00000000);
        patch_word('h34, 32'h00000000);
        patch_word('h38, 32'h00000000);
        patch_word('h3c, 32'h00000000);
        patch_word('h40, 32'h0bf00010);   // j 0xbfc00040 (self)
        patch_word('h44, 32'h00000000);

        $display("ROM @0FD0 = %02x %02x %02x %02x %02x %02x %02x %02x",
            boot['h0fd0], boot['h0fd1], boot['h0fd2], boot['h0fd3],
            boot['h0fd4], boot['h0fd5], boot['h0fd6], boot['h0fd7]);
        $display("ROM @0FD8 = %02x %02x %02x %02x %02x %02x %02x %02x",
            boot['h0fd8], boot['h0fd9], boot['h0fda], boot['h0fdb],
            boot['h0fdc], boot['h0fdd], boot['h0fde], boot['h0fdf]);

        repeat (8) @(posedge clk1x);
        reset_1x <= 0;
        reset_93 <= 0;
    end

    always @(posedge clk1x) begin
        if (!reset_1x) begin
            if (!captured1 && (debug_pc[31:0] >= 32'hbfc0_0020) &&
                (debug_pc[31:0] < 32'hbfc0_0040)) begin
                captured1 <= 1;
                result1 <= debug_v1;
            end
            if (captured1 && !captured2 &&
                (debug_pc[31:0] >= 32'hbfc0_0040)) begin
                captured2 <= 1;
                result2 <= debug_v1;
            end
        end
    end

    initial begin
        wait (captured2 == 1);
        repeat (4) @(posedge clk1x);
        $display("");
        check("ldl/ldr @BFC00FD7", result1, EXPECT1);
        check("ldl/ldr @BFC00FDE", result2, EXPECT2);
        $display("");
        if (failures == 0)
            $display("PASS: unaligned 64-bit loads match the boot ROM model");
        else
            $fatal(1, "FAIL: %0d unaligned 64-bit load(s) wrong", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout pc=%016x v1=%016x captured=%0d/%0d errors=%02x",
            debug_pc, debug_v1, captured1, captured2, debug_errors);
        $fatal(1);
    end

endmodule
