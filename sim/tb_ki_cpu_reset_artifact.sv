`timescale 1ns/1ps

module tb_ki_cpu_reset_artifact;
    localparam logic [31:0] BOOT_BASE = 32'h1fc0_0000;
    localparam integer BOOT_BYTES = 4096;
    localparam integer LOW_RAM_BYTES = 512 * 1024;
    localparam logic [31:0] MAIN_RAM_BASE = 32'h0800_0000;
    // Big enough to hold a block above 0x8801_0000, which is what makes the
    // program 'deep' and turns a jump back to the first 4 KB into a re-entry.
    localparam integer MAIN_RAM_BYTES = 'h10800;
    localparam logic [31:0] RAM_VIRTUAL = 32'h8800_0000;

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
    wire [63:0] debug_pc;
    wire [5:0] debug_errors;
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
    integer ram_decodes = 0;
    logic deep_program = 1'b0;
    integer phase = 1;

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
        .debug_pc(debug_pc),
        .debug_errors(debug_errors),
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
                for (i = 0; i < 8; i = i + 1) begin
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
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            cache_grant <= mem_rnw;
        end
    end

    // Count decodes inside the RAM loop, so the reset can be timed to land
    // while the fetch stage is unambiguously holding a 0x88xxxxxx address -
    // the exact condition the stale pcOld0 needed.
    always @(posedge clk93) begin
        if (reset_93)
            ram_decodes <= 0;
        else if (dut.core.decodeNewPulse === 1'b1 &&
                 dut.core.pcOld1[31:24] === 8'h88)
            ram_decodes <= ram_decodes + 1;
    end

    task automatic load_program(input logic ram_loops);
        begin
            for (i = 0; i < BOOT_BYTES; i = i + 1) boot[i] = 8'h00;
            for (i = 0; i < MAIN_RAM_BYTES; i = i + 1) main_ram[i] = 8'h00;

            // The real boot ROM's first word, so the artifact reproduces with
            // the value hardware actually reported: 0BF000E2 at 0xBFC00000.
            write_boot(32'h000, 32'h0bf0_00e2);  // j 0xBFC00388
            write_boot(32'h004, 32'h0000_0000);
            write_boot(32'h388, 32'h3c08_8800);  // lui  t0, 0x8800
            write_boot(32'h38c, 32'h0000_0000);
            write_boot(32'h390, 32'h0100_0008);  // jr   t0
            write_boot(32'h394, 32'h0000_0000);

            write_ram(32'h000, 32'h2401_0001);  // addiu at, zero, 1
            write_ram(32'h004, 32'h2402_0002);  // addiu v0, zero, 2
            write_ram(32'h008, 32'h2403_0003);  // addiu v1, zero, 3
            write_ram(32'h00c, 32'h2404_0004);  // addiu a0, zero, 4
            if (ram_loops) begin
                // b back to 0x88000004 - deliberately NOT 0x88000000, so the
                // loop never re-executes the entry point. It never leaves RAM
                // either, so ANY reported restart of any shape is false by
                // construction.
                write_ram(32'h010, 32'h1000_fffc);
                write_ram(32'h014, 32'h0000_0000);
            end else if (deep_program) begin
                // 0x88000000 -> 0x88010000 -> back to 0x88000000. The second
                // arrival is the re-entry: control reaches the startup page
                // from outside it after the program has run deep.
                write_ram(32'h00010, 32'h3c08_8801);  // lui  t0, 0x8801
                write_ram(32'h00014, 32'h0000_0000);
                write_ram(32'h00018, 32'h0100_0008);  // jr   t0  -> 0x88010000
                write_ram(32'h0001c, 32'h0000_0000);
                write_ram(32'h10000, 32'h2405_0005);  // addiu a1, zero, 5
                write_ram(32'h10004, 32'h3c09_8800);  // lui   t1, 0x8800
                write_ram(32'h10008, 32'h0120_0008);  // jr    t1 -> 0x88000000
                write_ram(32'h1000c, 32'h0000_0000);  // delay slot
            end else begin
                write_ram(32'h010, 32'h3c09_bfc0);  // lui   t1, 0xBFC0
                write_ram(32'h014, 32'h2529_0004);  // addiu t1, t1, 4
                write_ram(32'h018, 32'h0000_0000);
                write_ram(32'h01c, 32'h0120_0008);  // jr    t1
                write_ram(32'h020, 32'h0000_0000);
            end
        end
    endtask

    // Wall clock for the whole bench. A phase that never completes is almost
    // always a trigger that stopped firing, so name the phase rather than
    // guessing at a cause.
    initial begin
        #400000;
        $fatal(1, "phase %0d never completed - a detector stopped firing", phase);
    end

    initial begin
        load_program(1'b1);
        repeat (4) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;

        // Let the loop run long enough that the fetch stage is deep inside it.
        wait (ram_decodes > 40);
        if (debug_trace_frozen !== 1'b0)
            $fatal(1, "the trace froze while the program never left RAM");

        // THE RESET. Asserted asynchronously to the pipeline, exactly as
        // cpu_reset is on hardware when a shell-level term drops.
        @(posedge clk93);
        reset_1x = 1;
        reset_93 = 1;
        repeat (6) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;

        wait (ram_decodes > 40);
        repeat (64) @(posedge clk93);

        if (debug_trace_frozen !== 1'b0)
            $fatal(1, {"a CPU reset was reported as a RAM -> boot ROM ",
                       "transition: the stale-pc artifact is back"});
        // The departure capture is the other half of the same lie. RC counting
        // a transition is what put RL and RR on every hardware screenshot.
        if (dut.core.debug_ret_count_register != 0)
            $fatal(1, {"the departure detector counted a RAM -> boot ROM ",
                       "transition across a reset that never left RAM"});
        // The counter is cleared by reset_93, so after the second boot it must
        // read exactly 1 - the one entry-point execution of THIS boot. More
        // would mean the loop itself is being counted as a restart.
        if (dut.core.debug_entry_count_register != 1)
            $fatal(1, "entry count is %0d after a boot, expected 1",
                   dut.core.debug_entry_count_register);
        if (debug_errors != 0)
            $fatal(1, "CPU raised error flags %02h across the reset", debug_errors);

        // ...and the detector must still fire on a REAL transition. Rewrite
        // the loop into a jump to the boot ROM and reset once more so the
        // instruction cache cannot serve the old line.
        phase = 2;
        load_program(1'b0);
        @(posedge clk93);
        reset_1x = 1;
        reset_93 = 1;
        repeat (6) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;

        wait (debug_trace_frozen === 1'b1);
        repeat (32) @(posedge clk93);
        // Entry i occupies [i*64 +: 64] as {pc, op}, so entry 7 - the newest,
        // and the landing - has its pc at [511:480] and entry 6's at [447:416].
        if (debug_trace_bus[511:480] !== 32'hbfc0_0004)
            $fatal(1, "a real jump to the boot ROM was not captured, landing %08h",
                   debug_trace_bus[511:480]);
        if (debug_trace_bus[447:416] !== RAM_VIRTUAL + 32'h020)
            $fatal(1, "the departure entry is %08h, expected the delay slot %08h",
                   debug_trace_bus[447:416], RAM_VIRTUAL + 32'h020);

        deep_program = 1'b1;
        phase = 3;
        load_program(1'b0);
        @(posedge clk93);
        reset_1x = 1;
        reset_93 = 1;
        repeat (6) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;

        wait (debug_trace_frozen === 1'b1);
        repeat (32) @(posedge clk93);
        // Boot enters 0x88000000 once and the loop re-enters it once more, so
        // the count must be 2 and the freeze must be on the SECOND.
        if (dut.core.debug_entry_count_register < 2)
            $fatal(1, "the re-entry to the entry point was not counted");
        if (debug_trace_bus[511:480] !== RAM_VIRTUAL)
            $fatal(1, "the re-entry landing is %08h, expected %08h",
                   debug_trace_bus[511:480], RAM_VIRTUAL);
        // The departure is the delay slot of the deep jump, one instruction
        // past the jr - the same relationship the boot-ROM case has.
        if (debug_trace_bus[447:416] !== 32'h8801_000c)
            $fatal(1, "the re-entry departure is %08h, expected 8801000C",
                   debug_trace_bus[447:416]);
        if (dut.core.debug_ret_count_register != 0)
            $fatal(1, "a software self-restart was miscounted as a boot-ROM jump");

        $display("tb_ki_cpu_reset_artifact: PASS");
        $finish;
    end
endmodule
