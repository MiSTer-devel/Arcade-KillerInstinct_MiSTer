`timescale 1ns/1ps

// Runs the boot ROM's real bitstream-reader sequence and checks the value that
// gates the permutation-table initialiser.
//
// Entry is the ROM's own setup at 9FC006A8, which computes the stream pointer
// (0xBFC00FD0), the reader context block (0x887FFF00) and the table base
// (0x887FFF10), then calls the reader five times. The gate is:
//
//     9FC00724: jal  9FC00D48      read 32 bits
//     9FC00728: or   t2,v0,zero    (delay slot)
//     9FC0073C: beq  t2,zero,...   t2 == 0 skips the initialiser
//
// tools/bitreader_model.py says t2 must be 0x88000000. On hardware the
// initialiser never runs, which implies 0.
//
// The ROM guards its own stream with two syscall traps (9FC006F0 and 9FC00718)
// before the gate, so a trap here is itself a result: it means the reader went
// wrong earlier than the gate. Both are detected and reported.
//
// This deliberately runs the REAL routine rather than isolated instructions.
// Every primitive it uses - LDL/LDR, DSLLV/DSRLV, DADDI, SD/LD/LB - has now
// been checked individually and matches the N64 donor, so if the composite
// still fails, the fault is in their interaction or in the memory beneath them.

module tb_ki_bitreader;

    localparam logic [31:0] BOOT_BASE      = 32'h1fc0_0000;
    localparam integer      BOOT_BYTES     = 524288;
    localparam integer      LOW_RAM_BYTES  = 512 * 1024;
    localparam logic [31:0] MAIN_RAM_BASE  = 32'h0800_0000;
    localparam integer      MAIN_RAM_BYTES = 8 * 1024 * 1024;

    localparam logic [63:0] EXPECT_T2 = 64'h0000_0000_8800_0000;

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

    byte unsigned boot     [0:BOOT_BYTES-1];
    byte unsigned low_ram  [0:LOW_RAM_BYTES-1];
    byte unsigned main_ram [0:MAIN_RAM_BYTES-1];

    always #10.000      clk1x = ~clk1x;
    always #6.666666667 clk93 = ~clk93;
    always #5.000       clk2x = ~clk2x;

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
        else if (address < LOW_RAM_BYTES)
            read_byte = low_ram[address];
        else if (address >= MAIN_RAM_BASE &&
                 address < MAIN_RAM_BASE + MAIN_RAM_BYTES)
            read_byte = main_ram[address - MAIN_RAM_BASE];
        else
            read_byte = 8'hff;
    endfunction

    task automatic write_byte(input logic [31:0] address,
                              input logic [7:0] value);
        begin
            if (address < LOW_RAM_BYTES)
                low_ram[address] = value;
            else if (address >= MAIN_RAM_BASE &&
                     address < MAIN_RAM_BASE + MAIN_RAM_BYTES)
                main_ram[address - MAIN_RAM_BASE] = value;
        end
    endtask

    task automatic patch_word(input integer offset, input logic [31:0] value);
        begin
            boot[offset + 0] = value[7:0];
            boot[offset + 1] = value[15:8];
            boot[offset + 2] = value[23:16];
            boot[offset + 3] = value[31:24];
        end
    endtask

    integer      bus_file;
    integer      bus_trace = 1;

    logic        pending = 0;
    logic [31:0] pending_address;
    logic        pending_rnw;
    logic [7:0]  pending_mask;
    logic [63:0] pending_data;
    logic        pending_req64;
    logic [2:0]  pending_size;
    logic [2:0]  pending_beat;
    integer      lane;

    // ki_memory_bridge answers 64-bit reads from the containing doubleword and
    // 32-bit reads from the containing word. The CPU turns out to issue already
    // aligned addresses (proved by tb_ki_ldl_ldr's bus trace), so this is
    // belt-and-braces rather than load-bearing.
    function automatic [31:0] aligned(input logic [31:0] address,
                                      input logic req64);
        aligned = req64 ? {address[31:3], 3'b000} : {address[31:2], 2'b00};
    endfunction

    always @(posedge clk1x) begin
        mem_done <= 0;
        cache_grant <= 0;
        cache_data_ready <= 0;

        if (pending) begin
            if (pending_rnw) begin
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
            end else begin
                for (lane = 0; lane < 8; lane = lane + 1)
                    if (pending_mask[lane])
                        write_byte(pending_address + lane,
                                   pending_data[lane*8 +: 8]);
                mem_done <= 1;
                pending <= 0;
            end
        end

        if (mem_request && !pending) begin
            pending <= 1;
            pending_address <= mem_address;
            pending_rnw <= mem_rnw;
            pending_mask <= mem_writeMask;
            pending_data <= mem_dataWrite;
            pending_req64 <= mem_req64;
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            cache_grant <= mem_rnw;
            if (bus_trace)
                $fdisplay(bus_file,
                    "%0t %s addr=%08x req64=%0b size=%0d mask=%02h data=%016x pc=%08x",
                    $time, mem_rnw ? "R" : "W", mem_address, mem_req64,
                    mem_size, mem_writeMask, mem_dataWrite, debug_pc[31:0]);
        end
    end

    // ---- observation -----------------------------------------------------
    logic [63:0] gate_t2  = 64'hx;
    logic        gate_hit = 0;
    logic        trapped  = 0;
    logic [31:0] trap_pc  = 0;
    integer      reads_seen = 0;
    logic [31:0] last_pc = 0;

    always @(posedge clk1x) begin
        if (!reset_1x) begin
            if (debug_pc[31:0] != last_pc) begin
                last_pc <= debug_pc[31:0];

                if (debug_pc[31:0] == 32'hbfc0_0d5c) begin
                    reads_seen <= reads_seen + 1;
                    $display("  reader call %0d entered", reads_seen + 1);
                end

                // The ROM's own guards. Reaching either means the stream went
                // wrong before the gate, which is a finding in itself.
                if (debug_pc[31:0] == 32'hbfc0_06f0) begin
                    trapped <= 1;
                    trap_pc <= 32'hbfc0_06f0;
                end
                if (debug_pc[31:0] == 32'hbfc0_0718) begin
                    trapped <= 1;
                    trap_pc <= 32'hbfc0_0718;
                end

                if (!gate_hit && (debug_pc[31:0] == 32'hbfc0_073c)) begin
                    gate_hit <= 1;
                    gate_t2 <= debug_t2;
                end
            end
        end
    end

    initial begin
        integer index;

        for (index = 0; index < BOOT_BYTES; index = index + 1)
            boot[index] = 8'h00;
        for (index = 0; index < LOW_RAM_BYTES; index = index + 1)
            low_ram[index] = 8'h00;
        for (index = 0; index < MAIN_RAM_BYTES; index = index + 1)
            main_ram[index] = 8'h00;

        bus_file = $fopen("sim/bitreader_bus.log", "w");
        $readmemh("sim/media/kinst_boot.hex", boot);

        if ({boot[32'h0fd1], boot[32'h0fd0]} != 16'h7262) begin
            $display("FAIL: ROM signature at 0xFD0 is %02x%02x, expected 7262",
                boot[32'h0fd1], boot[32'h0fd0]);
            $fatal(1);
        end

        // Reset vector jumps straight to the ROM's reader setup at BFC006A8,
        // which is self-contained (it builds a0/a1/t3 itself).
        patch_word('h00, 32'h0bf001aa);   // j 0xbfc006a8
        patch_word('h04, 32'h00000000);   // delay slot

        repeat (8) @(posedge clk1x);
        reset_1x <= 0;
        reset_93 <= 0;
    end

    initial begin
        wait (gate_hit || trapped);
        repeat (4) @(posedge clk1x);
        $display("");
        if (trapped) begin
            $display("FAIL: ROM syscall guard at %08x reached - the bitstream",
                trap_pc);
            $display("      reader produced a wrong value BEFORE the gate.");
            $display("      reader calls completed: %0d", reads_seen);
            $fatal(1);
        end
        $display("GATE: t2 = %016x  expected %016x", gate_t2, EXPECT_T2);
        $display("      reader calls completed: %0d", reads_seen);
        if (gate_t2 === EXPECT_T2)
            $display("PASS: gate value matches the boot ROM model - the initialiser runs");
        else begin
            $display("FAIL: gate value wrong -> initialiser is %0s",
                (gate_t2 == 64'd0) ? "SKIPPED (reproduces hardware)" : "mis-gated");
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout pc=%016x t2=%016x reads=%0d errors=%02x",
            debug_pc, debug_t2, reads_seen, debug_errors);
        $display("      pending=%0d addr=%08x rnw=%0d beat=%0d size=%0d",
            pending, pending_address, pending_rnw, pending_beat, pending_size);
        $fclose(bus_file);
        $fatal(1);
    end

endmodule
