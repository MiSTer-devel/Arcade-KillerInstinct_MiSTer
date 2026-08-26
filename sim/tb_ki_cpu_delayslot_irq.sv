// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_cpu_delayslot_irq;
    localparam BOOT_BASE = 32'h1FC0_0000;
    localparam BOOT_BYTES = 4096;
    localparam MAIN_RAM_BASE = 32'h0800_0000;
    localparam MAIN_RAM_BYTES = 4096;
    localparam LOW_RAM_BYTES = 4096;
    localparam [31:0] RAM_VIRTUAL = 32'h8800_0000;

    // A THREE instruction loop, so the delay slot has an address of its own.
    // With a two-instruction self-branch both the branch and its slot produce
    // EPC = branch, and the two cases cannot be told apart.
    // The loop body runs 0x040..0x058 inclusive. EVERY exception taken inside
    // it must record an EPC somewhere in that range: for a delay-slot
    // interrupt EPC is the branch, which is also in range. An EPC outside the
    // body is the defect - in particular RAM+0x03C, which is
    // (branch target) - 4 and matches the KI captures exactly.
    localparam [31:0] LOOP_BASE   = RAM_VIRTUAL;
    localparam [31:0] LOOP_LO     = LOOP_BASE + 32'h040;
    localparam [31:0] LOOP_HI     = LOOP_BASE + 32'h054;
    localparam [31:0] BAD_EPC     = LOOP_BASE + 32'h03c;
    localparam [31:0] JR_BRANCH   = LOOP_BASE + 32'h044;
    localparam [31:0] BDS_BRANCH  = LOOP_BASE + 32'h04c;

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
    wire [895:0] debug_trace_bus;
    wire debug_trace_frozen;
    wire [31:0] debug_cop0_cause;
    wire [31:0] debug_cop0_epc;
    wire [63:0] debug_pc;

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
    // Wait states, so a memory access is not effectively free. Without these
    // the loop never stalls, and `stall = 0` is precisely the condition
    // cpu_cop0 uses to latch nextEPC_1 and isDelaySlot_1.
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
        .debug_v0(), .debug_v1(), .debug_a0(), .debug_a1(), .debug_t2(),
        .debug_a3(), .debug_s5(), .debug_s6(),
        .debug_errors(debug_errors),
        .debug_trace_bus(debug_trace_bus),
        .debug_trace_frozen(debug_trace_frozen),
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

    task automatic write_low(input integer offset, input logic [31:0] value);
        begin
            low_ram[offset + 0] = value[7:0];
            low_ram[offset + 1] = value[15:8];
            low_ram[offset + 2] = value[23:16];
            low_ram[offset + 3] = value[31:24];
        end
    endtask

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
                    cache_data[i*8 +: 8] <= read_byte(pending_address + (pending_beat * 8) + i);
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
            pending_mask <= mem_writeMask;
            pending_data <= mem_dataWrite;
            pending_size <= (mem_size == 0) ? 3'd1 : mem_size;
            pending_beat <= 0;
            wait_ctr <= MEM_WAIT;
            cache_grant <= 1;
        end
    end

    // ---- diagnostic ring buffer -------------------------------------------
    // What is the CPU actually holding when the bad EPC is recorded? Four fix
    // attempts guessed at this; this measures it. Captures the decode pc, the
    // hardware's own delay-slot flag and the decode pulse every cycle, and
    // dumps the window once the target-4 EPC is seen.
    localparam RB = 28;
    logic [31:0] rb_pc  [0:RB-1];
    logic        rb_ds  [0:RB-1];
    logic        rb_np  [0:RB-1];
    logic        rb_ch  [0:RB-1];
    logic [31:0] rb_epc [0:RB-1];
    logic        rb_exl [0:RB-1];
    integer rb_i = 0;
    logic   rb_dumped = 0;

    always @(posedge clk93) begin
        if (!reset_93) begin
            rb_pc [rb_i] <= dut.core.PCold1[31:0];
            rb_ds [rb_i] <= dut.core.executeBranchdelaySlot;
            rb_np [rb_i] <= dut.core.decodeNewPulse;
            rb_ch [rb_i] <= dut.core.chainedDelaySlot;
            rb_epc[rb_i] <= debug_cop0_epc;
            rb_exl[rb_i] <= debug_cop0_cause[16];
            rb_i <= (rb_i + 1) % RB;
        end
    end

    task automatic dump_ring;
        integer k, j;
        begin
            $display("  --- ring, oldest first: pc = PCold1, ds = executeBranchdelaySlot ---");
            for (k = 0; k < RB; k = k + 1) begin
                j = (rb_i + k) % RB;
                $display("    pc=%08x ds=%0d chain=%0d np=%0d exl=%0d epc=%08x",
                         rb_pc[j], rb_ds[j], rb_ch[j], rb_np[j], rb_exl[j], rb_epc[j]);
            end
        end
    endtask

    // Exception bookkeeping, driven off the EXL rising edge. EPC is sampled a
    // few cycles later so cop0's exception process has committed it.
    // Exception bookkeeping, driven off the EXL rising edge. Cause.IP is
    // sampled AT the edge because the handler clears IP7 almost immediately;
    // EPC is sampled a few cycles later so cop0 has committed it.
    integer exceptions_seen = 0;
    integer ext_total = 0, tmr_total = 0;
    integer epc_outside = 0, bad_epc_exact = 0;
    integer bd_jr = 0, bd_bds = 0;
    logic [31:0] first_bad_epc = 0;
    // The invariant only applies once execution is actually in the loop. The
    // setup code runs with interrupts already enabled, and an exception taken
    // there legitimately reports an EPC outside the loop body.
    logic loop_reached = 0;
    always @(posedge clk93) begin
        if (reset_93) loop_reached <= 0;
        else if (debug_pc[31:0] >= LOOP_LO && debug_pc[31:0] <= LOOP_HI)
            loop_reached <= 1;
    end
    logic exl_d = 0;
    logic [3:0] settle = 0;
    logic sampling = 0;
    logic [7:0] ip_at_entry = 0;

    always @(posedge clk93) begin
        if (reset_93) begin
            exl_d <= 0;
            settle <= 0;
            sampling <= 0;
        end else begin
            exl_d <= debug_cop0_cause[16];
            if (debug_cop0_cause[16] && !exl_d && !sampling) begin
                sampling <= 1;
                settle <= 0;
                ip_at_entry <= debug_cop0_cause[15:8];
            end else if (sampling) begin
                if (settle == 4'd3) begin
                    sampling <= 0;
                    exceptions_seen = exceptions_seen + 1;
                    // The invariant: EPC must land inside the loop body.
                    if (loop_reached &&
                        (debug_cop0_epc < LOOP_LO || debug_cop0_epc > LOOP_HI)) begin
                        if (epc_outside == 0) first_bad_epc = debug_cop0_epc;
                        epc_outside = epc_outside + 1;
                        if (debug_cop0_epc == BAD_EPC) begin
                            bad_epc_exact = bad_epc_exact + 1;
                            if (!rb_dumped) begin
                                rb_dumped = 1;
                                $display("  BAD EPC %08x seen", debug_cop0_epc);
                                dump_ring();
                            end
                        end
                    end
                    // Coverage: BD set means the interrupt landed on a delay
                    // slot and EPC was backed up to its branch.
                    if (debug_cop0_cause[31]) begin
                        if (debug_cop0_epc == JR_BRANCH)  bd_jr  = bd_jr + 1;
                        if (debug_cop0_epc == BDS_BRANCH) bd_bds = bd_bds + 1;
                    end
                    if (ip_at_entry[7])      tmr_total = tmr_total + 1;
                    else if (ip_at_entry[2]) ext_total = ext_total + 1;
                end else begin
                    settle <= settle + 4'd1;
                end
            end
        end
    end


    integer pulse;

    initial begin
        for (i = 0; i < BOOT_BYTES; i = i + 1) boot[i] = 8'h00;
        for (i = 0; i < MAIN_RAM_BYTES; i = i + 1) main_ram[i] = 8'h00;
        for (i = 0; i < LOW_RAM_BYTES; i = i + 1) low_ram[i] = 8'h00;

        // Boot ROM: a trampoline into RAM, exactly as tb_ki_cpu_trace does it.
        write_boot(32'h000, 32'h0bf0_0004);  // j    0xBFC00010
        write_boot(32'h004, 32'h0000_0000);  // delay slot
        write_boot(32'h010, 32'h3c08_8800);  // lui t0, base
        write_boot(32'h014, 32'h0000_0000);  // nop
        write_boot(32'h018, 32'h0100_0008);  // jr   t0
        write_boot(32'h01c, 32'h0000_0000);  // delay slot
        // General exception vector at 0x80000180 with BEV = 0 - low RAM,
        // physical 0x180, exactly where KI puts its own handler.
        //
        // It does NOT live in the boot ROM. A one-instruction eret there works,
        // but longer sequences do not: the first revision of this bench ran its
        // whole program from the ROM and could not get a lui/ori pair or an
        // mtc0 to take effect. Whatever that is, it is a property of this
        // bench's uncached fetch model, and putting real code in RAM avoids it.
        //
        // Rearming Compare is what clears Cause.IP7 (cpu_cop0 clears
        // interruptPending(7) on a Compare write) and is harmless when the
        // external line fired instead. It touches k0 only, so nothing the loop
        // depends on is disturbed.
        // The reload interval is a PRIME plus jitter taken from Count's low
        // bits. A round 0x200 locked in phase with the loop period once the
        // loop started stalling, and the timer then hit the same instruction
        // every time - 143 interrupts, not one of them on the delay slot. The
        // coverage guard caught it, but a test that silently stops exercising
        // its own case is the failure mode to design out.
        write_low(32'h180, 32'h401a_4800);  // mfc0  k0,$9  (Count)
        write_low(32'h184, 32'h0000_0000);  // nop
        write_low(32'h188, 32'h335b_00ff);  // andi  k1,k0,0x00FF
        write_low(32'h18c, 32'h275a_00f7);  // addiu k0,k0,0x00F7
        write_low(32'h190, 32'h035b_d021);  // addu  k0,k0,k1
        write_low(32'h194, 32'h409a_5800);  // mtc0  k0,$11 (Compare)
        write_low(32'h198, 32'h0000_0000);  // nop
        write_low(32'h19c, 32'h4200_0018);  // eret
        write_low(32'h1a0, 32'h0000_0000);  // nop

        // RAM program at 0x88000000.
        //
        //   Status = IM7(15) | IM2(10) | IE(0) = 0x00008401,  BEV CLEAR
        //
        // BOTH interrupt sources are enabled so one run can compare them.
        // irqRequest[0] drives Cause.IP2 (cpu_cop0.vhd: interruptPending(3
        // downto 2) <= irqRequest); IP7 is the COP0 Count/Compare timer, which
        // cop0 raises internally on a completely different path. KI masks
        // everything except IP7, so the timer is the case that matters.
        write_ram(32'h000, 32'h3408_8401);  // ori   t0,zero,0x8401
        write_ram(32'h004, 32'h0000_0000);  // nop
        write_ram(32'h008, 32'h4088_6000);  // mtc0  t0,$12 (Status)
        write_ram(32'h00c, 32'h0000_0000);  // nop
        // Start the timer: Compare = Count + 0x200.
        write_ram(32'h010, 32'h4009_4800);  // mfc0  t1,$9  (Count)
        write_ram(32'h014, 32'h0000_0000);  // nop
        write_ram(32'h018, 32'h2529_00f7);  // addiu t1,t1,0x0F7
        write_ram(32'h01c, 32'h4089_5800);  // mtc0  t1,$11 (Compare)
        write_ram(32'h020, 32'h0000_0000);  // nop
        write_ram(32'h024, 32'h3c0a_8800);  // lui t2, base
        write_ram(32'h028, 32'h0000_0000);  // nop
        write_ram(32'h02c, 32'h354a_004c);  // ori   t2,t2,0x004C -> 0x8800004C
        // t4 = 0xA8000000: KSEG1, so every load through it is UNCACHED and
        // takes a real bus transaction. Physical 0x08000000, which the memory
        // model serves from main_ram.
        write_ram(32'h030, 32'h3c0c_a800);  // lui   t4,0xA800
        write_ram(32'h034, 32'h0000_0000);  // nop
        write_ram(32'h038, 32'h3405_0000);  // ori   a1,zero,0  (a1 = 0)
        // 0x03C is deliberately a nop and NOT part of the loop. If it ever
        // shows up as EPC, that is (branch target) - 4 and the bug is real.
        write_ram(32'h03c, 32'h0000_0000);  // nop
        // The loop. 0x044 jumps back to 0x040, so 0x048 is ALWAYS a delay slot.
        //
        // The loop head is an UNCACHED LOAD, so every iteration stalls for the
        // full memory latency and the branch/delay-slot pair flows through the
        // pipeline immediately AFTER a stall clears. That transition is the
        // interesting window: cpu_cop0 latches nextEPC_1 and isDelaySlot_1 only
        // when stall = 0, so it is where the branch address and the delay-slot
        // flag could in principle be captured from different instructions.
        //
        // Putting the load IN the delay slot instead was tried first and is the
        // weaker test: the core does not take interrupts while stalled at all -
        // decode_irq is gated on stall = 0 - so the stall simply defers the
        // interrupt until after the slot retires, and slot coverage collapsed
        // to 2 of 138.
        //
        // The delay slot does real register work, like KI's subu, rather than
        // being a nop.
        // A TIGHT five-instruction loop holding both constructs, so the
        // branch target is a large fraction of it and interrupts land there
        // often. The uncached load that earlier revisions ran here is gone:
        // stalls only defer interrupts (decode_irq is gated on stall = 0) and
        // slowed the loop enough to starve coverage. The stall variants were
        // run separately and are recorded in TRIAGE.md.
        write_ram(32'h040, 32'h38a5_0001);  // xori  a1,a1,1   <-- TARGET / head
        write_ram(32'h044, 32'h0140_0008);  // jr    t2  -> 0x8800004C  BRANCH
        write_ram(32'h048, 32'h01ab_6821);  // addu  t5,t5,t3           DELAY SLOT
        // KI's idiom: a BRANCH in a BRANCH's delay slot, both arms to the same
        // target. KI1 has it at 880322D4/880322D8, KI2 at 8802F074/8802F078.
        // a1 alternates every iteration so both polarities are exercised - with
        // a1 pinned at 0 the FIRST branch never takes and the case never arises.
        write_ram(32'h04c, 32'h14a0_fffc);  // bnez  a1,0x88000040  BRANCH 1
        write_ram(32'h050, 32'h10a0_fffb);  // beqz  a1,0x88000040  BRANCH 2

        repeat (4) @(posedge clk93);
        reset_1x = 0;
        reset_93 = 0;
    end

    initial begin
        // Let the trampoline run and Status be written before any interrupt.
        wait (reset_93 == 0);
        repeat (600) @(posedge clk93);

        if (debug_cop0_cause[0] !== 1'b1)
            $fatal(1, "tb_ki_cpu_delayslot_irq: Status.IE is not set (cause=%08x pc=%08x) - the program never enabled interrupts",
                   debug_cop0_cause, debug_pc[31:0]);

        for (pulse = 0; pulse < (75); pulse = pulse + 1) begin
            irq = 2'b01;
            repeat (3) @(posedge clk93);
            irq = 2'b00;
            repeat (31 + (pulse % 13)) @(posedge clk93);
        end

        // Phase 2: the COP0 TIMER, free running, with the external line quiet.
        // This is KI's case - the game masks everything except IP7.
        irq = 2'b00;
        repeat (45000) @(posedge clk93);

        $display("tb_ki_cpu_delayslot_irq: %0d exceptions (%0d external, %0d timer)",
                 exceptions_seen, ext_total, tmr_total);
        $display("tb_ki_cpu_delayslot_irq: delay-slot coverage: jr=%0d  branch-in-delay-slot=%0d",
                 bd_jr, bd_bds);
        $display("tb_ki_cpu_delayslot_irq: EPC outside the loop body: %0d (exactly target-4: %0d, first %08x)",
                 epc_outside, bad_epc_exact, first_bad_epc);

        if (ext_total == 0)
            $fatal(1, "tb_ki_cpu_delayslot_irq: the external line never delivered");
        if (tmr_total == 0)
            $fatal(1, "tb_ki_cpu_delayslot_irq: the timer never fired");

        // Coverage. Both constructs must actually have been interrupted on
        // their delay slot, or a clean result says nothing about either.
        if (bd_jr < 3)
            $fatal(1, "tb_ki_cpu_delayslot_irq: only %0d interrupts landed on the jr delay slot - that construct was not exercised enough", bd_jr);
        if (bd_bds < 3)
            $fatal(1, "tb_ki_cpu_delayslot_irq: only %0d interrupts landed on the branch-in-delay-slot pair - the construct under test was not exercised enough", bd_bds);

        if (epc_outside != 0)
            $fatal(1, "tb_ki_cpu_delayslot_irq: FAIL - EPC landed outside the loop body %0d times, first %08x (%0d of them exactly (branch target)-4 = %08x). eret resumes there and control falls THROUGH the branch target, which is the KI FMV signature.",
                   epc_outside, first_bad_epc, bad_epc_exact, BAD_EPC);

        $display("tb_ki_cpu_delayslot_irq: PASS");
        $finish;
    end

    initial begin
        #400_000_000;
        $fatal(1, "tb_ki_cpu_delayslot_irq: timeout");
    end
endmodule

`default_nettype wire
