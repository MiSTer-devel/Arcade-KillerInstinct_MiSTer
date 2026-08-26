`timescale 1ns/1ps

module tb_ki_cpu_boot #(
    parameter integer RETIRE_TARGET = 1000
);
    localparam logic [31:0] BOOT_BASE = 32'h1fc0_0000;
    localparam integer BOOT_BYTES = 524288;
    localparam integer LOW_RAM_BYTES = 512 * 1024;
    localparam logic [31:0] MAIN_RAM_BASE = 32'h0800_0000;
    localparam integer MAIN_RAM_BYTES = 8 * 1024 * 1024;

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
    wire debug_done;
    wire [63:0] debug_pc;
    wire [31:0] debug_opcode;
    wire [63:0] debug_v0;
    wire [63:0] debug_v1;
    wire [63:0] debug_a0;
    wire [63:0] debug_a1;
    wire [63:0] debug_t2;
    wire [63:0] debug_a3;
    wire [63:0] debug_s5;
    wire [63:0] debug_s6;
    wire [5:0] debug_errors;

    byte unsigned boot [0:BOOT_BYTES-1];
    byte unsigned low_ram [0:LOW_RAM_BYTES-1];
    byte unsigned main_ram [0:MAIN_RAM_BYTES-1];
    integer retired = 0;
    integer trace_file;
    integer bus_file;
    integer pass_file;
    integer i;
    integer fast_boot;
    integer game_ki2;
    integer t2_loop_test;
    integer v1_loop_test;
    integer a0a1_loop_test;
    integer read_delay;
    integer write_delay;
    integer trace_enable;
    integer timeout_ns;
    integer stop_on_io;
    integer write_through_store_count = 0;
    integer dependency_drain_wait = 0;
    logic saw_self_test = 0;
    logic dependency_done = 0;
    string boot_hex;
    logic pending = 0;
    logic [31:0] pending_address;
    logic pending_rnw;
    logic [7:0] pending_mask;
    logic [63:0] pending_data;
    logic pending_req64;
    logic [2:0] pending_size;
    logic [2:0] pending_beat;
    integer pending_wait = 0;

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
        else if (address >= MAIN_RAM_BASE && address < MAIN_RAM_BASE + MAIN_RAM_BYTES)
            read_byte = main_ram[address - MAIN_RAM_BASE];
        // The board inputs are active-low and idle high.  The standalone
        // CPU harness has no board-I/O instance, so mirror that reset state
        // instead of returning a fabricated zero for the first DIP read.
        else if (address >= 32'h1000_0080 && address <= 32'h1000_00bb)
            read_byte = 8'hff;
        else
            read_byte = 8'h00;
    endfunction

    task automatic complete_read(input logic [31:0] address);
        integer lane;
        begin
            for (lane = 0; lane < 8; lane = lane + 1) begin
                mem_dataRead[lane*8 +: 8] <= read_byte(address + lane);
                cache_data[lane*8 +: 8] <= read_byte(address + lane);
            end
        end
    endtask

    task automatic patch_boot_word(input integer offset, input logic [31:0] value);
        begin
            boot[offset + 0] = value[7:0];
            boot[offset + 1] = value[15:8];
            boot[offset + 2] = value[23:16];
            boot[offset + 3] = value[31:24];
        end
    endtask

    always @(posedge clk1x) begin
        mem_done <= 0;
        cache_grant <= 0;
        cache_data_ready <= 0;
        if (pending && pending_wait > 0) begin
            pending_wait <= pending_wait - 1;
        end else if (pending) begin
            if (pending_rnw) begin
                complete_read(pending_address + (pending_beat * 8));
                cache_data_ready <= 1;
                if (pending_beat + 1 >= pending_size) begin
                    mem_done <= 1;
                    pending <= 0;
                end else begin
                    pending_beat <= pending_beat + 1'b1;
                end
            end else if (pending_address < LOW_RAM_BYTES) begin
                for (i = 0; i < 8; i = i + 1) begin
                    if (pending_mask[i]) begin
                        low_ram[pending_address + i] <= pending_data[i*8 +: 8];
                    end
                end
                mem_done <= 1;
                pending <= 0;
            end else if (pending_address >= MAIN_RAM_BASE &&
                         pending_address < MAIN_RAM_BASE + MAIN_RAM_BYTES) begin
                for (i = 0; i < 8; i = i + 1) begin
                    if (pending_mask[i])
                        main_ram[pending_address - MAIN_RAM_BASE + i] <= pending_data[i*8 +: 8];
                end
                mem_done <= 1;
                pending <= 0;
            end else begin
                mem_done <= 1;
                pending <= 0;
            end
        end

        if (mem_request && !pending) begin
            if (trace_enable != 0)
                $fdisplay(bus_file, "%0t %s addr=%08h size=%0d req64=%0b mask=%02h data=%016h",
                          $time, mem_rnw ? "R" : "W", mem_address, mem_size,
                          mem_req64, mem_writeMask, mem_dataWrite);
            if (!mem_rnw && !mem_req64 && mem_writeMask == 8'h0f &&
                mem_address >= 32'h0003_001c && mem_address <= 32'h0003_0030)
                write_through_store_count <= write_through_store_count + 1;
            pending <= 1;
            pending_address <= mem_address;
            pending_rnw <= mem_rnw;
            pending_mask <= mem_writeMask;
            pending_data <= mem_dataWrite;
            pending_req64 <= mem_req64;
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            pending_wait <= mem_rnw ? read_delay : write_delay;
            cache_grant <= mem_rnw;
            // The direct-memory harness normally returns zeroes for I/O.
            // In this mode stop before completing that fabricated access so
            // a full boot run can identify the first real board/ATA touch.
            if (stop_on_io != 0 &&
                ((mem_address >= 32'h1000_0080 && mem_address <= 32'h1000_00bb) ||
                 (mem_address >= 32'h1000_0100 && mem_address <= 32'h1000_013f) ||
                 (mem_address == 32'h1000_0170))) begin
                $display("PASS: first KI I/O access retired=%0d %s addr=%08h data=%016h mask=%02h",
                         retired, mem_rnw ? "R" : "W", mem_address,
                         mem_dataWrite, mem_writeMask);
                pass_file = $fopen("sim/cpu_boot_pass.flag", "w");
                if (pass_file != 0) begin
                    $fdisplay(pass_file,
                              "first_io=1 retired=%0d rnw=%0d addr=%08h data=%016h mask=%02h",
                              retired, mem_rnw, mem_address, mem_dataWrite,
                              mem_writeMask);
                    $fclose(pass_file);
                end
                $fclose(trace_file);
                $fclose(bus_file);
                $finish;
            end
        end

        if (dependency_done) begin
            dependency_drain_wait <= dependency_drain_wait + 1;
            if (!pending && dependency_drain_wait >= 32) begin
                // Dirty lines are visible to the CPU immediately but only
                // reach backing RAM on eviction or an explicit cache command.
                // Validate the architectural dependency chain here rather
                // than incorrectly requiring write-through behaviour.
                $display("PASS: dependency loops T2=%016h A3=%016h S5=%016h S6=%016h retired=%0d stores=%0d",
                         debug_t2, debug_a3, debug_s5, debug_s6, retired,
                         write_through_store_count);
                pass_file = $fopen("sim/cpu_boot_pass.flag", "w");
                if (pass_file != 0) begin
                    $fdisplay(pass_file,
                              "dependency_loops=1 write_back=1 retired=%0d stores=%0d t2=%016h a3=%016h s5=%016h s6=%016h",
                              retired, write_through_store_count, debug_t2,
                              debug_a3, debug_s5, debug_s6);
                    $fclose(pass_file);
                end
                $fclose(trace_file);
                $fclose(bus_file);
                $finish;
            end
        end
    end

    always @(posedge clk93) begin
        if (!reset_93 && debug_done) begin
            if (trace_enable != 0)
                $fdisplay(trace_file,
                          "%0d pc=%016h opcode=%08h v0=%016h v1=%016h a0=%016h a1=%016h",
                          retired, debug_pc, debug_opcode, debug_v0, debug_v1, debug_a0, debug_a1);
            retired <= retired + 1;
            if (debug_errors != 0)
                $fatal(1, "CPU error flags %02h at PC %016h", debug_errors, debug_pc);
            if (debug_pc[31:0] == 32'h9fc0_06e8) begin
                if (debug_v0 != 64'h0000_0000_0000_7262)
                    $fatal(1, "KI CPU/RAM self-test got %016h, expected 0000000000007262", debug_v0);
                saw_self_test <= 1;
            end
            if (a0a1_loop_test != 0 && debug_v0[31:0] == 32'h0000_5678) begin
                if (debug_a0 != 64'hffff_ffff_8003_0000)
                    $fatal(1, "A0/A1 clear loop ended with A0=%016h", debug_a0);
                if (debug_a1 != 64'hffff_ffff_8003_0000)
                    $fatal(1, "A0/A1 clear loop lost A1=%016h", debug_a1);
                $display("PASS: A0/A1 ROM clear loop retired=%0d A0=%016h A1=%016h",
                         retired + 1, debug_a0, debug_a1);
                pass_file = $fopen("sim/cpu_boot_pass.flag", "w");
                if (pass_file != 0) begin
                    $fdisplay(pass_file,
                              "a0a1_clear_loop=1 retired=%0d a0=%016h a1=%016h",
                              retired + 1, debug_a0, debug_a1);
                    $fclose(pass_file);
                end
                $fclose(trace_file);
                $fclose(bus_file);
                $finish;
            end else if (a0a1_loop_test != 0 && retired + 1 >= RETIRE_TARGET) begin
                $fatal(1, "A0/A1 clear loop did not terminate; A0=%016h A1=%016h PC=%016h",
                       debug_a0, debug_a1, debug_pc);
            end else if (t2_loop_test != 0 && !dependency_done &&
                debug_v0[31:0] == 32'h0000_5678) begin
                if (debug_t2 != 64'h0)
                    $fatal(1, "T2 dependency loop ended with T2=%016h", debug_t2);
                if (debug_a3 != 64'hffff_ffff_8003_0034)
                    $fatal(1, "Nested dependency loop ended with A3=%016h", debug_a3);
                if (debug_s5 != 64'h0)
                    $fatal(1, "S5 immediate dependency loop ended with S5=%016h", debug_s5);
                if (debug_s6 != 64'hffff_ffff_8003_001c)
                    $fatal(1, "JAL return destination ended with S6=%016h", debug_s6);
                dependency_done <= 1;
            end else if (t2_loop_test != 0 && !dependency_done &&
                         retired + 1 >= RETIRE_TARGET)
                $fatal(1, "T2 dependency loop did not terminate; T2=%016h A3=%016h PC=%016h",
                       debug_t2, debug_a3, debug_pc);
            if (v1_loop_test != 0 && debug_v0[31:0] == 32'h0000_5678) begin
                if (debug_v1 != 64'h0)
                    $fatal(1, "V1 long loop ended with V1=%016h", debug_v1);
                $display("PASS: 8192-iteration V1/LW/BNEZ loop retired=%0d V1=%016h",
                         retired + 1, debug_v1);
                pass_file = $fopen("sim/cpu_boot_pass.flag", "w");
                if (pass_file != 0) begin
                    $fdisplay(pass_file,
                              "v1_long_loop=1 retired=%0d v1=%016h",
                              retired + 1, debug_v1);
                    $fclose(pass_file);
                end
                $fclose(trace_file);
                $fclose(bus_file);
                $finish;
            end else if (v1_loop_test != 0 && retired + 1 >= RETIRE_TARGET)
                $fatal(1, "V1 long loop did not terminate; V1=%016h PC=%016h",
                       debug_v1, debug_pc);
            if (t2_loop_test == 0 && v1_loop_test == 0 && a0a1_loop_test == 0 &&
                retired + 1 >= RETIRE_TARGET) begin
                $display("PASS: retired %0d KI boot instructions; last PC=%016h opcode=%08h",
                         retired + 1, debug_pc, debug_opcode);
                pass_file = $fopen("sim/cpu_boot_pass.flag", "w");
                if (pass_file != 0) begin
                    $fdisplay(pass_file,
                              "retired=%0d pc=%016h opcode=%08h set=%s fast_boot=%0d self_test=%0d",
                              retired + 1, debug_pc, debug_opcode,
                              game_ki2 ? "kinst2" : "kinst", fast_boot, saw_self_test);
                    $fclose(pass_file);
                end
                $fclose(trace_file);
                $fclose(bus_file);
                $finish;
            end
        end
    end

    initial begin
        if (!$value$plusargs("BOOT_HEX=%s", boot_hex))
            boot_hex = "sim/media/kinst_boot.hex";
        $readmemh(boot_hex, boot);
        if (!$value$plusargs("KI2=%d", game_ki2)) game_ki2 = 0;
        if (!$value$plusargs("FAST_BOOT=%d", fast_boot)) fast_boot = 1;
        if (!$value$plusargs("T2_LOOP_TEST=%d", t2_loop_test)) t2_loop_test = 0;
        if (!$value$plusargs("V1_LOOP_TEST=%d", v1_loop_test)) v1_loop_test = 0;
        if (!$value$plusargs("A0A1_LOOP_TEST=%d", a0a1_loop_test)) a0a1_loop_test = 0;
        if (!$value$plusargs("READ_DELAY=%d", read_delay)) read_delay = 0;
        if (!$value$plusargs("WRITE_DELAY=%d", write_delay)) write_delay = 0;
        if (!$value$plusargs("TRACE=%d", trace_enable)) trace_enable = 1;
        if (!$value$plusargs("TIMEOUT_NS=%d", timeout_ns)) timeout_ns = 20000000;
        if (!$value$plusargs("STOP_ON_IO=%d", stop_on_io)) stop_on_io = 0;
        if (a0a1_loop_test != 0) begin
            // Isolate the adjacent A0/A1 LUI writes and their immediately
            // following BNE source hazard from the KI low-RAM clear loop.
            patch_boot_word(32'h0480, 32'h3c04_8003); // lui   a0,8003
            patch_boot_word(32'h0484, 32'h3c05_8003); // lui   a1,8003
            patch_boot_word(32'h0488, 32'h1485_0003); // bne   a0,a1,BFC00498
            patch_boot_word(32'h048c, 32'h0000_0000); // nop
            patch_boot_word(32'h0490, 32'h3402_5678); // pass: ori v0,zero,5678
            patch_boot_word(32'h0494, 32'h0bf0_0126); // j     BFC00498
            patch_boot_word(32'h0498, 32'h3402_dead); // fail: ori v0,zero,dead
            patch_boot_word(32'h049c, 32'h0bf0_0127); // j     BFC0049C
        end else if (t2_loop_test != 0) begin
            // Preserve startup cache initialization, then enter the ROM's
            // nested T2/S5 dependency sequence. The final store of the first
            // inner loop starts a new cache line, exercising completion of a
            // cache miss immediately before the S5 decrement.
            patch_boot_word(32'h03ec, 32'h2403_0003);
            patch_boot_word(32'h0438, 32'h2403_0003);
            patch_boot_word(32'h0484, 32'h2485_0020);
            patch_boot_word(32'h04a0, 32'h2403_0004);
            patch_boot_word(32'h04c8, 32'h2403_0003);
            patch_boot_word(32'h03b8, 32'h0bf0_0040); // j BFC00100
            patch_boot_word(32'h03bc, 32'h0000_0000);
            patch_boot_word(32'h0100, 32'h0ff0_0058); // jal   BFC00160
            patch_boot_word(32'h0104, 32'h0000_0000); // nop
            patch_boot_word(32'h0108, 32'h0ff0_005c); // jal   BFC00170
            patch_boot_word(32'h010c, 32'h0040_5025); // move  t2,v0 (delay slot)
            patch_boot_word(32'h0110, 32'h0002_383c); // dsll  a3,v0,32
            patch_boot_word(32'h0114, 32'h0007_383f); // dsra  a3,a3,32
            patch_boot_word(32'h0118, 32'h00e0_b025); // move  s6,a3
            patch_boot_word(32'h011c, 32'h2415_0003); // addiu s5,zero,3
            patch_boot_word(32'h0120, 32'h214a_fffc); // inner: addi t2,t2,-4
            patch_boot_word(32'h0124, 32'hacea_0000); // sw    t2,0(a3)
            patch_boot_word(32'h0128, 32'h1540_fffd); // bnez  t2,BFC00120
            patch_boot_word(32'h012c, 32'h24e7_0004); // addiu a3,a3,4
            patch_boot_word(32'h0130, 32'h22b5_ffff); // addi  s5,s5,-1
            patch_boot_word(32'h0134, 32'h12a0_0003); // beqz  s5,BFC00144
            patch_boot_word(32'h0138, 32'h0000_0000); // nop
            patch_boot_word(32'h013c, 32'h240a_0008); // addiu t2,zero,8
            patch_boot_word(32'h0140, 32'h0bf0_0048); // j     BFC00120
            patch_boot_word(32'h0144, 32'h0000_0000); // nop
            patch_boot_word(32'h0148, 32'h3402_5678); // ori   v0,zero,5678
            patch_boot_word(32'h014c, 32'h0bf0_0053); // j     BFC0014C
            patch_boot_word(32'h0150, 32'h0000_0000); // nop
            patch_boot_word(32'h0160, 32'h3402_0008); // ori   v0,zero,8
            patch_boot_word(32'h0164, 32'h03e0_0008); // jr    ra
            patch_boot_word(32'h0168, 32'h0000_0000); // nop
            patch_boot_word(32'h0170, 32'h3c02_8003); // lui   v0,8003
            patch_boot_word(32'h0174, 32'h3442_001c); // ori   v0,v0,001c
            patch_boot_word(32'h0178, 32'h03e0_0008); // jr    ra
            patch_boot_word(32'h017c, 32'h0000_0000); // nop
        end else if (v1_loop_test != 0) begin
            // Enter an exact copy of the ROM's 8192-iteration cache-warm
            // loop after shortening the preceding deterministic sweeps.
            patch_boot_word(32'h03ec, 32'h2403_0003);
            patch_boot_word(32'h0438, 32'h2403_0003);
            patch_boot_word(32'h0484, 32'h2485_0020);
            patch_boot_word(32'h03b8, 32'h0bf0_0040); // j BFC00100
            patch_boot_word(32'h03bc, 32'h0000_0000);
            patch_boot_word(32'h0100, 32'h3c02_8000); // lui   v0,8000
            patch_boot_word(32'h0104, 32'h2403_2000); // addiu v1,zero,2000
            patch_boot_word(32'h0108, 32'h2463_ffff); // addiu v1,v1,-1
            patch_boot_word(32'h010c, 32'h8c40_0000); // lw    zero,0(v0)
            patch_boot_word(32'h0110, 32'h1460_fffd); // bnez  v1,BFC00108
            patch_boot_word(32'h0114, 32'h2442_0004); // addiu v0,v0,4
            patch_boot_word(32'h0118, 32'h3402_5678); // ori   v0,zero,5678
            patch_boot_word(32'h011c, 32'h0bf0_0046); // j     BFC00118
            patch_boot_word(32'h0120, 32'h0000_0000); // nop
        end else if (fast_boot != 0 && game_ki2 == 0) begin
            // Preserve control flow while shortening deterministic sweeps.
            patch_boot_word(32'h03ec, 32'h2403_0003);
            patch_boot_word(32'h0438, 32'h2403_0003);
            patch_boot_word(32'h0484, 32'h2485_0020);
            patch_boot_word(32'h04a0, 32'h2403_0004);
            patch_boot_word(32'h04c8, 32'h2403_0003);
        end
        if (t2_loop_test == 0) begin
            for (i = 0; i < LOW_RAM_BYTES; i = i + 1) low_ram[i] = 0;
            for (i = 0; i < MAIN_RAM_BYTES; i = i + 1) main_ram[i] = 0;
        end
        trace_file = $fopen("sim/cpu_boot_trace.log", "w");
        if (trace_file == 0) $fatal(1, "Could not create CPU trace file");
        bus_file = $fopen("sim/cpu_bus_trace.log", "w");
        if (bus_file == 0) $fatal(1, "Could not create bus trace file");

        repeat (12) @(posedge clk93);
        reset_93 <= 0;
        @(posedge clk1x);
        reset_1x <= 0;

        #timeout_ns;
        $fatal(1, "Timeout after retiring %0d instructions; PC=%016h errors=%02h",
               retired, debug_pc, debug_errors);
    end
endmodule
