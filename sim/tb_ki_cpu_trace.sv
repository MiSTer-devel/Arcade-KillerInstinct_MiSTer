`timescale 1ns/1ps

module tb_ki_cpu_trace;
    localparam logic [31:0] BOOT_BASE = 32'h1fc0_0000;
    localparam integer BOOT_BYTES = 4096;
    localparam integer LOW_RAM_BYTES = 512 * 1024;
    localparam logic [31:0] MAIN_RAM_BASE = 32'h0800_0000;
    localparam integer MAIN_RAM_BYTES = 4096;

    // Where the RAM program lives, in both the CPU's view and physically.
    localparam logic [31:0] RAM_VIRTUAL = 32'h8800_0000;
    // The uncached board-register window the test store targets. 0xB0000098 is
    // KSEG1, so the store never touches the data cache - which is the case the
    // capture has to cover, because every real control-register write is one.
    localparam logic [31:0] STORE_PHYSICAL = 32'h1000_0098;

    logic clk1x = 0;
    logic clk93 = 0;
    logic clk2x = 0;
    logic reset_1x = 1;
    logic reset_93 = 1;
    logic [1:0] irq = 0;

    wire mem_request;
    wire mem_rnw;
    wire [31:0] mem_address;
    wire mem_req64;
    wire [2:0] mem_size;
    wire [7:0] mem_writeMask;
    wire [63:0] mem_dataWrite;
    logic [63:0] mem_dataRead = 0;
    logic mem_done = 0;
    logic cache_grant = 0;
    logic [63:0] cache_data = 0;
    logic cache_data_ready = 0;
    wire [5:0] debug_errors;
    wire [63:0] debug_v0;
    wire [895:0] debug_trace_bus;
    wire debug_trace_frozen;

    byte unsigned boot [0:BOOT_BYTES-1];
    byte unsigned main_ram [0:MAIN_RAM_BYTES-1];
    byte unsigned low_ram [0:LOW_RAM_BYTES-1];

    integer i;
    logic pending = 0;
    logic [31:0] pending_address;
    logic pending_rnw;
    logic [7:0] pending_mask;
    logic [63:0] pending_data;
    logic [2:0] pending_size;
    logic [2:0] pending_beat;
    integer store_seen = 0;

    always #10.000 clk1x = ~clk1x;
    always #6.666666667 clk93 = ~clk93;
    always #5.000 clk2x = ~clk2x;

    ki_cpu_wrapper dut (
        .clk1x(clk1x), .clk93(clk93), .clk2x(clk2x),
        .reset_1x(reset_1x), .reset_93(reset_93), .irq(irq),
        .mem_request(mem_request), .mem_rnw(mem_rnw),
        .mem_address(mem_address), .mem_req64(mem_req64), .mem_size(mem_size),
        .mem_writeMask(mem_writeMask), .mem_dataWrite(mem_dataWrite),
        .mem_dataRead(mem_dataRead), .mem_done(mem_done),
        .cache_grant(cache_grant), .cache_data(cache_data),
        .cache_data_ready(cache_data_ready),
        .debug_errors(debug_errors),
        .debug_v0(debug_v0),
        .debug_trace_bus(debug_trace_bus),
        .debug_trace_frozen(debug_trace_frozen)
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
            boot[offset + 0] = value[7:0];
            boot[offset + 1] = value[15:8];
            boot[offset + 2] = value[23:16];
            boot[offset + 3] = value[31:24];
        end
    endtask

    task automatic write_ram(input integer offset, input logic [31:0] value);
        begin
            main_ram[offset + 0] = value[7:0];
            main_ram[offset + 1] = value[15:8];
            main_ram[offset + 2] = value[23:16];
            main_ram[offset + 3] = value[31:24];
        end
    endtask

    always @(posedge clk1x) begin
        mem_done <= 0;
        cache_grant <= 0;
        cache_data_ready <= 0;
        if (pending) begin
            if (pending_rnw) begin
                for (i = 0; i < 8; i = i + 1)begin
                    mem_dataRead[i*8 +: 8] <= read_byte(pending_address + (pending_beat * 8) + i);
                    cache_data[i*8 +: 8] <= read_byte(pending_address + (pending_beat * 8) + i);
                end
                cache_data_ready <= 1;
                if (pending_beat + 1 >= pending_size) begin
                    mem_done <= 1;
                    pending <= 0;
                end else begin
                    pending_beat <= pending_beat + 1'b1;
                end
            end else begin
                if (pending_address >= MAIN_RAM_BASE &&
                    pending_address < MAIN_RAM_BASE + MAIN_RAM_BYTES) begin
                    for (i = 0; i < 8; i = i + 1)
                        if (pending_mask[i])
                            main_ram[pending_address - MAIN_RAM_BASE + i] <= pending_data[i*8 +: 8];
                end else if (pending_address < LOW_RAM_BYTES) begin
                    for (i = 0; i < 8; i = i + 1)
                        if (pending_mask[i])
                            low_ram[pending_address + i] <= pending_data[i*8 +: 8];
                end
                mem_done <= 1;
                pending <= 0;
            end
        end

        if (mem_request && !pending) begin
            if (!mem_rnw && mem_address == STORE_PHYSICAL)
                store_seen <= store_seen + 1;
            pending <= 1;
            pending_address <= mem_address;
            pending_rnw <= mem_rnw;
            pending_mask <= mem_writeMask;
            pending_data <= mem_dataWrite;
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            cache_grant <= mem_rnw;
        end
    end

    // -----------------------------------------------------------------
    // Expected trace, derived from the program below rather than from a run.
    // Index 0 is the OLDEST of the eight decodes that end at the landing.
    // -----------------------------------------------------------------
    logic [31:0] expect_pc [0:7];
    logic [31:0] expect_op [0:7];
    logic  [3:0] expect_src [0:7];

    function automatic [31:0] trace_pc(input integer index);
        trace_pc = debug_trace_bus[index*64 + 32 +: 32];
    endfunction

    function automatic [31:0] trace_op(input integer index);
        trace_op = debug_trace_bus[index*64 +: 32];
    endfunction

    function automatic [3:0] trace_src(input integer index);
        trace_src = debug_trace_bus[512 + index*4 +: 4];
    endfunction

    initial begin
        for (i = 0; i < BOOT_BYTES; i = i + 1) boot[i] = 8'h00;
        for (i = 0; i < MAIN_RAM_BYTES; i = i + 1) main_ram[i] = 8'h00;
        for (i = 0; i < LOW_RAM_BYTES; i = i + 1) low_ram[i] = 8'h00;

        // Boot ROM, executed uncached from 0xBFC00000. Reach RAM the way the
        // real boot ROM does, through a register jump.
        write_boot(32'h000, 32'h0bf0_0004);  // j 0xBFC00010
        write_boot(32'h004, 32'h0000_0000);  // delay slot
        write_boot(32'h010, 32'h3c08_8800);  // lui  t0, 0x8800
        write_boot(32'h014, 32'h0000_0000);  // nop
        write_boot(32'h018, 32'h0100_0008);  // jr   t0
        write_boot(32'h01c, 32'h0000_0000);  // delay slot

        // RAM program at 0x88000000. The last eight decodes before the landing
        // are what the trace must hold, so they are all distinct.
        write_ram(32'h000, 32'h2401_0001);  // addiu at, zero, 1
        write_ram(32'h004, 32'h4002_7800);  // mfc0  v0, PRId
        write_ram(32'h008, 32'h2403_0003);  // addiu v1, zero, 3
        write_ram(32'h00c, 32'h2404_0004);  // addiu a0, zero, 4
        write_ram(32'h010, 32'h2405_0005);  // addiu a1, zero, 5
        write_ram(32'h014, 32'h3c09_bfc0);  // lui   t1, 0xBFC0
        write_ram(32'h018, 32'h2529_0004);  // addiu t1, t1, 4   -> 0xBFC00004
        write_ram(32'h01c, 32'h3c0a_b000);  // lui   t2, 0xB000
        write_ram(32'h020, 32'h240b_00a5);  // addiu t3, zero, 0xA5
        write_ram(32'h024, 32'ha14b_0098);  // sb    t3, 0x98(t2)
        write_ram(32'h028, 32'h0120_0008);  // jr    t1
        write_ram(32'h02c, 32'h0000_0000);  // delay slot

        expect_pc[0] = RAM_VIRTUAL + 32'h014; expect_op[0] = 32'h3c09_bfc0; expect_src[0] = 4'h0;
        expect_pc[1] = RAM_VIRTUAL + 32'h018; expect_op[1] = 32'h2529_0004; expect_src[1] = 4'h0;
        expect_pc[2] = RAM_VIRTUAL + 32'h01c; expect_op[2] = 32'h3c0a_b000; expect_src[2] = 4'h0;
        expect_pc[3] = RAM_VIRTUAL + 32'h020; expect_op[3] = 32'h240b_00a5; expect_src[3] = 4'h0;
        expect_pc[4] = RAM_VIRTUAL + 32'h024; expect_op[4] = 32'ha14b_0098; expect_src[4] = 4'h0;
        expect_pc[5] = RAM_VIRTUAL + 32'h028; expect_op[5] = 32'h0120_0008; expect_src[5] = 4'h0;
        expect_pc[6] = RAM_VIRTUAL + 32'h02c; expect_op[6] = 32'h0000_0000; expect_src[6] = 4'h0;
        // The landing. Tag 5 is the jr/jalr arm of the fetch-address mux, and
        // this is the field the whole page exists for: on hardware it says
        // whether a register really held the reset vector.
        expect_pc[7] = 32'hbfc0_0004;         expect_op[7] = 32'h0000_0000; expect_src[7] = 4'h5;

        repeat (4) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;
    end

    initial begin
        // The whole program is nineteen instructions with uncached ROM fetches
        // and one cached RAM line fill. If it has not frozen by here it never
        // will, and reporting that is more useful than hanging the suite.
        #200000;
        $fatal(1, "the trace never froze: the RAM -> boot ROM transition was not detected");
    end

    initial begin
        wait (debug_trace_frozen === 1'b1);
        // Give the store window time to close. cpu.vhd holds the store capture
        // open for 16 clk93 cycles past the freeze on purpose: the departure
        // store is still in the pipeline when the pc is redirected.
        repeat (64) @(posedge clk93);

        if (debug_errors != 0)
            $fatal(1, "CPU raised error flags %02h during the trace run", debug_errors);

        // CP0 PRId must identify the IDT79R4600 used by Killer Instinct.
        if (debug_v0 !== 64'h0000_0000_0000_2020)
            $fatal(1, "CP0 PRId is %016h, expected R4600 value 0000000000002020",
                   debug_v0);

        for (i = 0; i < 8; i = i + 1) begin
            if (trace_pc(i) !== expect_pc[i])
                $fatal(1, "trace entry %0d pc is %08h, expected %08h",
                       i, trace_pc(i), expect_pc[i]);
            if (trace_op(i) !== expect_op[i])
                $fatal(1, "trace entry %0d opcode is %08h, expected %08h at %08h",
                       i, trace_op(i), expect_op[i], expect_pc[i]);
            if (trace_src(i) !== expect_src[i])
                $fatal(1, "trace entry %0d fetch source is %0h, expected %0h at %08h",
                       i, trace_src(i), expect_src[i], expect_pc[i]);
        end

        // The departure and the landing must be the pair the status page's RL
        // and RR name. Checking them by name as well as by index is what stops
        // a reversed export from passing the loop above by symmetry.
        if (trace_pc(6)[31:24] !== 8'h88)
            $fatal(1, "entry 6 should be the departure in RAM, got %08h", trace_pc(6));
        if (trace_pc(7) !== 32'hbfc0_0004)
            $fatal(1, "entry 7 should be the landing, got %08h", trace_pc(7));

        // No exception was taken. ExcCode lives in bits 6:2 of the COP0 pack,
        // and this run redirects the pc entirely through a register jump, so a
        // non-zero code here would mean the capture is reading the wrong word.
        if (debug_trace_bus[550:546] !== 5'd0)
            $fatal(1, "COP0 pack reports exception code %0d on a clean run",
                   debug_trace_bus[550:546]);
        if (debug_trace_bus[607:576] !== 32'h0000_0000)
            $fatal(1, "EPC is %08h with no exception taken",
                   debug_trace_bus[607:576]);

        // Store provenance. The bench's only store is the uncached `sb`, so
        // its effective address must be what the capture reports - this is the
        // field TRIAGE needs for KI2's `sb $a2,1($v0)` departure.
        if (store_seen == 0)
            $fatal(1, "the uncached test store never reached the bus");
        if (debug_trace_bus[639:608] !== STORE_PHYSICAL)
            $fatal(1, "store address is %08h, expected %08h",
                   debug_trace_bus[639:608], STORE_PHYSICAL);
        if (debug_trace_bus[647:640] !== 8'ha5)
            $fatal(1, "store data byte is %02h, expected a5",
                   debug_trace_bus[647:640]);
        if (debug_trace_bus[703:696] !== 8'h88)
            $fatal(1, "the storing pc %08h is not in the RAM program",
                   debug_trace_bus[703:672]);

        // The entry counter sees the boot ROM's handoff and nothing else, so
        // it must read exactly 1. The FREEZE is gated on the second execution,
        // which is what keeps ordinary startup from tripping it - and this
        // trace froze on the boot-ROM jump above, not on the handoff.
        if (dut.core.debug_entry_count_register != 1)
            $fatal(1, "entry count is %0d after one boot handoff, expected 1",
                   dut.core.debug_entry_count_register);

        $display("tb_ki_cpu_trace: PASS");
        $finish;
    end
endmodule
