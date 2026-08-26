`timescale 1ns/1ps


module tb_ki_io_poll;

    localparam logic [31:0] BOOT_BASE  = 32'h1fc0_0000;
    localparam integer      BOOT_BYTES = 524288;
    localparam integer      ITERATIONS = 16;

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
    wire [63:0] debug_v0, debug_v1;
    wire [63:0] debug_a0, debug_a1, debug_t2, debug_a3, debug_s5, debug_s6;
    wire  [5:0] debug_errors;

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
    integer      io_reads = 0;

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
            if (mem_address == 32'h1000_00a0) begin
                io_reads = io_reads + 1;
                $display("  IO READ %0d: addr=%08x req64=%0b size=%0d",
                         io_reads, mem_address, mem_req64, mem_size);
            end
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

    localparam logic [31:0] DONE_PC = 32'hbfc0_0028;
    logic reached_done = 1'b0;

    // Progress watchdog: if the pc stops advancing the loop has deadlocked,
    // which is the whole point of the bench, so say so rather than hanging.
    logic [63:0] last_pc = 64'hx;
    integer      stuck = 0;

    always @(posedge clk93) begin
        if (!reset_93) begin
            if (debug_pc !== last_pc) begin
                last_pc <= debug_pc;
                stuck   <= 0;
            end else begin
                stuck <= stuck + 1;
            end
            if (debug_pc[31:0] == DONE_PC) reached_done <= 1'b1;
        end
    end

    initial begin
        integer index;

        for (index = 0; index < BOOT_BYTES; index = index + 1)
            boot[index] = 8'h00;

        //  00  lui  v1,0xb000        v1 = 0xB0000000
        //  04  lui  at,0
        //  08  ori  at,at,ITERATIONS
        //  0C  lw   $0,0xa0(v1)      <- LOOP, the stalling instruction
        //  10  mfc0 v0,Cause
        //  14  beqz at,0x28          exit when the counter runs out
        //  18  andi v0,v0,0x0800     delay slot
        //  1C  beqz v0,0x0C          poll again
        //  20  addi at,at,-1         delay slot
        //  24  nop
        //  28  j 0x28                DONE, park here
        patch_word('h00, 32'h3c03b000);
        patch_word('h04, 32'h3c010000);
        patch_word('h08, 32'h34210000 | ITERATIONS[15:0]);
        patch_word('h0c, 32'h8c6000a0);
        patch_word('h10, 32'h40026800);
        patch_word('h14, 32'h10200004);
        patch_word('h18, 32'h30420800);
        patch_word('h1c, 32'h1040fffb);
        patch_word('h20, 32'h2021ffff);
        patch_word('h24, 32'h00000000);
        patch_word('h28, 32'h0bf0000a);
        patch_word('h2c, 32'h00000000);

        $display("");
        $display("uncached I/O poll loop on the real CPU (%0d iterations)",
                 ITERATIONS);
        $display("");

        repeat (8) @(posedge clk1x);
        reset_1x <= 0;
        reset_93 <= 0;
    end

    initial begin
        wait (reached_done == 1'b1);
        repeat (4) @(posedge clk93);
        $display("");
        // ITERATIONS + 1: the counter is tested AFTER the load, so the loop
        // runs `lw` once more than it decrements - the same shape the real
        // code has, where `beqz $at` sits below `lw $0,0xa0($v1)`.
        $display("  reached DONE with %0d I/O reads (expected %0d)",
                 io_reads, ITERATIONS + 1);
        if (io_reads != ITERATIONS + 1) begin
            $display("FAIL: %0d I/O reads, expected %0d",
                     io_reads, ITERATIONS + 1);
            $fatal(1, "wrong number of I/O reads");
        end
        $display("");
        $display("PASS: the poll loop completes - no CPU-side deadlock");
        $display("");
        $finish;
    end

    // The deadlock this bench exists to catch.
    initial begin
        forever begin
            @(posedge clk93);
            if (stuck > 5000) begin
                $display("");
                $display("DEADLOCK: pc stuck at %016x for %0d cycles",
                         debug_pc, stuck);
                $display("          io_reads=%0d errors=%02x", io_reads,
                         debug_errors);
                $display("");
                $fatal(1, "the poll loop deadlocked - reproduced");
            end
        end
    end

    initial begin
        #3000000;
        $display("FAIL: timeout, pc=%016x io_reads=%0d errors=%02x",
                 debug_pc, io_reads, debug_errors);
        $fatal(1);
    end

endmodule
