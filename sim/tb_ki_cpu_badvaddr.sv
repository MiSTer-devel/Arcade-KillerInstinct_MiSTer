// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

// Verify the software-visible COP0 state for a real address error while the KI
// wrapper uses its 32-bit address configuration. The handler reads BadVAddr
// with mfc0, matching the architectural path used by game software.
//
// THE PROGRAM. Interrupts are off (Status = 0, BEV clear), so the ONLY
// exception that can occur is the one under test:
//
//   88000014: ori  a1,zero,1      <-- setup done
//   88000018: lui  t1,0x8800
//   88000020: ori  t1,t1,2            t1 = 0x88000002, not word aligned
//   88000028: lw   t2,0(t1)       <-- AdEL. cpu.vhd:3987 raises this on
//                                     EXCTYPE_ADDRW with calcMemAddr(1:0) > 0
//   8800002c: ori  a1,zero,2      <-- must NOT run; a1 == 2 means no exception
//
// The handler at 0x80000180 captures BadVAddr and Cause into v0 and v1 and
// parks, rather than eret-ing: returning would re-execute the faulting load and
// fault forever.
//
// THE CONTRACT.
//   - BadVAddr, read back through mfc0, is the faulting address
//   - Cause.ExcCode is 4 (AdEL)
module tb_ki_cpu_badvaddr;
    localparam BOOT_BASE      = 32'h1FC0_0000;
    localparam BOOT_BYTES     = 4096;
    localparam MAIN_RAM_BASE  = 32'h0800_0000;
    localparam MAIN_RAM_BYTES = 4096;
    localparam LOW_RAM_BYTES  = 4096;

    // The faulting address. Bit 31 is set, so its correct 64-bit form is
    // 0xFFFFFFFF_88000002 - a sign-extension, which is exactly the case the
    // narrowing assumes and the probe must not flag.
    localparam [31:0] BAD_ADDR = 32'h8800_0002;

    logic clk1x = 0, clk93 = 0, clk2x = 0;
    logic reset_1x = 1, reset_93 = 1;
    logic [1:0] irq = 0;

    wire mem_request, mem_rnw, mem_req64;
    wire [31:0] mem_address;
    wire [2:0]  mem_size;
    wire [7:0]  mem_writeMask;
    wire [63:0] mem_dataWrite;
    logic [63:0] mem_dataRead = 0;
    logic mem_done = 0, cache_grant = 0, cache_data_ready = 0;
    logic [63:0] cache_data = 0;
    wire [31:0] debug_cop0_cause, debug_cop0_epc;
    wire [63:0] debug_pc, debug_v0, debug_v1, debug_a1;

    byte unsigned boot     [0:BOOT_BYTES-1];
    byte unsigned main_ram [0:MAIN_RAM_BYTES-1];
    byte unsigned low_ram  [0:LOW_RAM_BYTES-1];

    integer i;
    logic pending = 0, pending_rnw;
    logic [31:0] pending_address;
    logic [2:0]  pending_size, pending_beat;
    localparam MEM_WAIT = 8;
    integer wait_ctr = 0;

    always #10.000 clk1x = ~clk1x;
    always #6.666666667 clk93 = ~clk93;
    always #5.000 clk2x = ~clk2x;

    ki_cpu_wrapper dut (
        .clk1x(clk1x), .clk93(clk93), .clk2x(clk2x),
        .reset_1x(reset_1x), .reset_93(reset_93), .irq(irq),
        .mem_request(mem_request), .mem_rnw(mem_rnw), .mem_address(mem_address),
        .mem_req64(mem_req64), .mem_size(mem_size), .mem_writeMask(mem_writeMask),
        .mem_dataWrite(mem_dataWrite),
        .mem_dataRead(mem_dataRead), .mem_done(mem_done),
        .cache_grant(cache_grant), .cache_data(cache_data),
        .cache_data_ready(cache_data_ready),
        .debug_done(), .debug_pc(debug_pc), .debug_opcode(),
        .debug_v0(debug_v0), .debug_v1(debug_v1), .debug_a0(), .debug_a1(debug_a1),
        .debug_t2(), .debug_a3(), .debug_s5(), .debug_s6(),
        .debug_errors(),
        .debug_trace_bus(), .debug_trace_frozen(),
        .debug_cop0_cause(debug_cop0_cause),
        .debug_cop0_epc(debug_cop0_epc)
    );

    function automatic [7:0] read_byte(input logic [31:0] address);
        if (address >= BOOT_BASE && address < BOOT_BASE + BOOT_BYTES)
            read_byte = boot[address - BOOT_BASE];
        else if (address >= MAIN_RAM_BASE && address < MAIN_RAM_BASE + MAIN_RAM_BYTES)
            read_byte = main_ram[address - MAIN_RAM_BASE];
        else if (address < LOW_RAM_BYTES)
            read_byte = low_ram[address];
        else
            read_byte = 8'h00;
    endfunction

    task automatic write_boot(input integer offset, input logic [31:0] value);
        begin
            boot[offset+0] = value[7:0];   boot[offset+1] = value[15:8];
            boot[offset+2] = value[23:16]; boot[offset+3] = value[31:24];
        end
    endtask
    task automatic write_ram(input integer offset, input logic [31:0] value);
        begin
            main_ram[offset+0] = value[7:0];   main_ram[offset+1] = value[15:8];
            main_ram[offset+2] = value[23:16]; main_ram[offset+3] = value[31:24];
        end
    endtask
    task automatic write_low(input integer offset, input logic [31:0] value);
        begin
            low_ram[offset+0] = value[7:0];   low_ram[offset+1] = value[15:8];
            low_ram[offset+2] = value[23:16]; low_ram[offset+3] = value[31:24];
        end
    endtask

    // Same memory model as tb_ki_cpu_delayslot_irq, wait states included: an
    // access that is effectively free never stalls the pipeline, and stall = 0
    // is precisely the condition cop0 latches its exception state under.
    always @(posedge clk1x) begin
        mem_done <= 0;
        cache_grant <= 0;
        cache_data_ready <= 0;
        if (pending) begin
            if (wait_ctr != 0) begin
                wait_ctr <= wait_ctr - 1;
            end else if (pending_rnw) begin
                for (i = 0; i < 8; i = i + 1) begin
                    mem_dataRead[i*8 +: 8] <= read_byte(pending_address + (pending_beat * 8) + i);
                    cache_data[i*8 +: 8]   <= read_byte(pending_address + (pending_beat * 8) + i);
                end
                cache_data_ready <= 1;
                if (pending_beat + 1 >= pending_size) begin
                    mem_done <= 1;
                    pending <= 0;
                end else begin
                    pending_beat <= pending_beat + 1'b1;
                    wait_ctr <= MEM_WAIT;
                end
            end else begin
                mem_done <= 1;
                pending <= 0;
            end
        end else if (mem_request) begin
            pending <= 1;
            pending_address <= {mem_address[31:3], 3'b000};
            pending_rnw <= mem_rnw;
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            wait_ctr <= MEM_WAIT;
            cache_grant <= 1;
        end
    end

    integer errors = 0;
    integer timeout;

    task automatic check(input logic cond, input string what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %s", what);
            end
        end
    endtask

    initial begin
        for (i = 0; i < BOOT_BYTES; i = i + 1)     boot[i] = 8'h00;
        for (i = 0; i < MAIN_RAM_BYTES; i = i + 1) main_ram[i] = 8'h00;
        for (i = 0; i < LOW_RAM_BYTES; i = i + 1)  low_ram[i] = 8'h00;

        // Boot ROM is only a trampoline into RAM; real code in the ROM does not
        // execute reliably under this bench's uncached fetch model. See the
        // note in tb_ki_cpu_delayslot_irq.
        write_boot(32'h000, 32'h0bf0_0004);  // j    0xBFC00010
        write_boot(32'h004, 32'h0000_0000);
        write_boot(32'h010, 32'h3c08_8800);  // lui  t0,0x8800
        write_boot(32'h014, 32'h0000_0000);
        write_boot(32'h018, 32'h0100_0008);  // jr   t0
        write_boot(32'h01c, 32'h0000_0000);

        // General exception vector, 0x80000180, BEV clear - where KI's lives.
        // It parks instead of eret-ing: eret would return to the faulting load
        // and fault again forever.
        write_low(32'h180, 32'h4002_4000);  // mfc0 v0,$8   (BadVAddr)
        write_low(32'h184, 32'h0000_0000);
        write_low(32'h188, 32'h4003_6800);  // mfc0 v1,$13  (Cause)
        write_low(32'h18c, 32'h0000_0000);
        write_low(32'h190, 32'h3405_0003);  // ori  a1,zero,3   handler ran
        write_low(32'h194, 32'h0000_0000);
        write_low(32'h198, 32'h1000_ffff);  // b .
        write_low(32'h19c, 32'h0000_0000);

        // Status = 0: BEV clear so the vector is 0x80000180, IE clear so no
        // interrupt can race the address error and claim the capture.
        write_ram(32'h000, 32'h3408_0000);  // ori  t0,zero,0
        write_ram(32'h004, 32'h0000_0000);
        write_ram(32'h008, 32'h4088_6000);  // mtc0 t0,$12 (Status)
        write_ram(32'h00c, 32'h0000_0000);
        write_ram(32'h010, 32'h0000_0000);
        write_ram(32'h014, 32'h3405_0001);  // ori  a1,zero,1   setup done
        write_ram(32'h018, 32'h3c09_8800);  // lui  t1,0x8800
        write_ram(32'h01c, 32'h0000_0000);
        write_ram(32'h020, 32'h3529_0002);  // ori  t1,t1,2  -> 0x88000002
        write_ram(32'h024, 32'h0000_0000);
        write_ram(32'h028, 32'h8d2a_0000);  // lw   t2,0(t1)    <-- AdEL
        write_ram(32'h02c, 32'h3405_0002);  // ori  a1,zero,2   must not run
        write_ram(32'h030, 32'h1000_ffff);  // b .
        write_ram(32'h034, 32'h0000_0000);

        // Released ONCE. Benches here that re-reset per pass never got an mtc0
        // to take effect at all.
        repeat (10) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;

        timeout = 0;
        while (debug_a1[31:0] != 32'd3 && debug_a1[31:0] != 32'd2 &&
               timeout < 200000) begin
            @(posedge clk93);
            timeout = timeout + 1;
        end

        if (debug_a1[31:0] == 32'd2) begin
            $display("FAIL: execution continued past the unaligned lw - no address");
            $display("      exception was raised, so the probe was never tested.");
            errors = errors + 1;
        end else if (debug_a1[31:0] != 32'd3) begin
            $display("FAIL: handler never reached (a1=%0d, pc=%08x) after %0d cycles",
                     debug_a1[31:0], debug_pc[31:0], timeout);
            errors = errors + 1;
        end else begin
            repeat (20) @(posedge clk93);

            $display("tb_ki_cpu_badvaddr: BadVAddr=%08x Cause=%08x ExcCode=%0d",
                     debug_v0[31:0], debug_v1[31:0], debug_v1[6:2]);

            // Verify the software-visible exception state.
            check(debug_v0[31:0] == BAD_ADDR,
                  $sformatf("BadVAddr read back as %08x, expected %08x",
                            debug_v0[31:0], BAD_ADDR));
            check(debug_v1[6:2] == 5'd4,
                  $sformatf("Cause.ExcCode is %0d, expected 4 (AdEL)", debug_v1[6:2]));
        end

        if (errors == 0)
            $display("tb_ki_cpu_badvaddr: PASS");
        else
            $display("tb_ki_cpu_badvaddr: %0d FAILURE(S)", errors);
        $finish;
    end
endmodule

`default_nettype wire
