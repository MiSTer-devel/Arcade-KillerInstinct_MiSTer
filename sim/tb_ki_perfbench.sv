`timescale 1ps/1ps
`default_nettype none

// Microbenchmark harness: the real CPU against the real memory chain, running
// a program we control.
//
// WHY THIS EXISTS. Every performance measurement on this core so far has been
// stuck between two unsatisfying options:
//
//   * Hardware, via the debug Perf page. Real timing, but only per-frame
//     aggregates over uncontrolled mixed traffic - which is why the D-cache
//     miss cost is a RANGE (93-155 cycles) rather than a number, and why a
//     signal shared between the two caches silently corrupted a whole capture.
//   * tb_ki_datacache_writeback. Full visibility, but an IDEALISED memory
//     model that returns ram_done with the last beat. The 80-cycle tail that
//     dominates a real fill does not exist there at all.
//
// This bench is the missing third option: ki_cpu_core -> ki_memory_bridge ->
// ki_sdram_adapter -> ki_sdram_burst -> a device model, exactly the hardware
// chain, driven by a program short enough to reason about completely. One
// isolated cache miss becomes a number instead of a range, and it is visible
// in a waveform.
//
// WHAT IT CANNOT DO. It measures the CORE, not the GAME. It says nothing
// about KI's real miss rate or working set - that needs hardware or MAME. See
// docs/OPTIMIZATION-HISTORY.md.
//
// Not built on tb_ki_cpu_system_boot: that bench connects 25 ki_cpu_core debug
// ports which no longer exist, so it cannot elaborate, and its boot checking
// would fight a synthetic program anyway.

module tb_ki_perfbench;

    // clk_1x 50 MHz, clk_93 100 MHz, clk_2x 100 MHz - the hardware ratios.
    // The bridge and the SDRAM chain run on clk_1x, so one of its cycles is
    // two CPU cycles, which is why measurements here are reported in BOTH.
    logic clk_1x = 1'b0;
    logic clk_93 = 1'b0;
    logic clk_2x = 1'b0;
    always #10000 clk_1x = ~clk_1x;
    always #5000  clk_93 = ~clk_93;
    always #5000  clk_2x = ~clk_2x;

    // The device model samples on a phase-shifted copy, as on hardware.
    logic clk_dev;
    task automatic emit_dev_edge(input logic value, input integer delay_ps);
        begin #delay_ps; clk_dev = value; end
    endtask
    initial clk_dev = 1'b0;
    always @(clk_1x) fork emit_dev_edge(clk_1x, 16750); join_none

    logic reset     = 1'b1;
    logic cpu_reset = 1'b1;
    logic init      = 1'b1;

    // ---------------------------------------------------------------- CPU
    wire        cpu_request, cpu_rnw, cpu_req64, cpu_done;
    wire [31:0] cpu_address;
    wire  [2:0] cpu_size;
    wire  [7:0] cpu_write_mask;
    wire [63:0] cpu_write_data;
    wire        cpu_line_write;
    wire [255:0] cpu_line_data;
    wire [63:0] cpu_read_data;
    wire        cpu_cache_grant, cpu_cache_data_ready;
    wire [63:0] cpu_cache_data;
    wire  [5:0] debug_errors;
    wire [31:0] debug_pc, debug_retired;
    wire [191:0] debug_perf_bus, debug_perf_worst;

    ki_cpu_core cpu (
        .clk1x(clk_1x), .clk93(clk_93), .clk2x(clk_2x),
        .reset(cpu_reset),
        .irq(2'b00),
        .mem_request(cpu_request), .mem_rnw(cpu_rnw),
        .mem_address(cpu_address), .mem_req64(cpu_req64),
        .mem_size(cpu_size), .mem_writeMask(cpu_write_mask),
        .mem_dataWrite(cpu_write_data),
        .mem_line_write(cpu_line_write), .mem_line_data(cpu_line_data),
        .mem_dataRead(cpu_read_data),
        .mem_done(cpu_done),
        .cache_grant(cpu_cache_grant), .cache_data(cpu_cache_data),
        .cache_data_ready(cpu_cache_data_ready),
        .errors(debug_errors),
        .debug_fetch_pc(debug_pc), .debug_retired(debug_retired),
        .debug_gpr_s1(), .debug_irq_count(), .debug_t2_reload_count(),
        .debug_h1_op(), .debug_exc_cause(), .debug_ret_count(),
        .debug_retire_pc(), .debug_retire_opcode(),
        .debug_trace_bus(), .debug_trace_frozen(),
        .debug_eret_epc(), .debug_eret_target(), .debug_eret_flags(),
        .debug_ds_count(), .debug_ds_first(),
        .debug_trace_trigger(1'b0),
        .perf_frame(1'b0), .perf_clear(1'b0),
        .perf_bridge_out(16'd0), .perf_bridge_burst(16'd0),
        .debug_perf_bus(debug_perf_bus), .debug_perf_worst(debug_perf_worst)
    );

    // ------------------------------------------------------------- bridge
    wire [24:0] sdram_address;
    wire [255:0] sdram_write_data;
    wire  [31:0] sdram_byte_enable;
    wire  [4:0] sdram_burst;
    wire        sdram_read, sdram_write, sdram_data_valid, sdram_done, sdram_ready;
    wire [63:0] sdram_read_data;
    wire        boot_loaded;

    // Board I/O answers a few cycles later with zero. Only the uncached census
    // at the end of the program addresses it, to prove the I/O tap fires.
    wire        io_request;
    logic [3:0] io_pipe = 4'd0;
    wire        io_done = io_pipe[3];
    always @(posedge clk_1x) io_pipe <= {io_pipe[2:0], io_request};

    // Scanout, with +video=1: a requester that reads framebuffer lines the way
    // ki_framebuffer does, dropping its request on video_done and asking again
    // a few clocks later. It holds the bridge's CPU burst paths - a line
    // write-back waits while a video request is up - so the write-back that
    // hardware defers behind scanout is deferred here too. Off by default, so
    // every other measurement in this bench is unchanged.
    int          video = 0;
    logic        vid_req = 1'b0;
    logic [27:0] vid_addr = 28'h003_0000;
    logic  [3:0] vid_gap = 4'd0;
    wire         vid_done;
    always @(posedge clk_1x) begin
        if (reset || video == 0) begin
            vid_req <= 1'b0;
        end else if (!vid_req) begin
            if (vid_gap == 0) vid_req <= 1'b1;
            else vid_gap <= vid_gap - 4'd1;
        end else if (vid_done) begin
            vid_req  <= 1'b0;
            vid_gap  <= 4'(1 + (vid_addr[8:5] % 7));
            vid_addr <= (vid_addr >= 28'h005_5000) ? 28'h003_0000 : vid_addr + 28'd32;
        end
    end

    ki_memory_bridge bridge (
        .clk(clk_1x), .ddr_clk(clk_2x), .reset(reset),
        .cpu_request(cpu_request), .cpu_rnw(cpu_rnw),
        .cpu_address(cpu_address), .cpu_req64(cpu_req64),
        .cpu_size(cpu_size), .cpu_write_mask(cpu_write_mask),
        .cpu_data_write(cpu_write_data), .cpu_line_write(cpu_line_write), .cpu_line_data(cpu_line_data), .cpu_data_read(cpu_read_data),
        .cpu_done(cpu_done), .cpu_grant(cpu_cache_grant),
        .cpu_cache_data(cpu_cache_data),
        .cpu_cache_data_ready(cpu_cache_data_ready),
        .io_request(io_request), .io_write(), .io_address(), .io_write_data(),
        .io_byte_enable(), .io_read_data(32'd0), .io_done(io_done),
        .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_index(16'd0),
        .ioctl_addr(27'd0), .ioctl_dout(16'd0), .ioctl_wait(),
        .boot_loaded(boot_loaded),
        .video_request(vid_req), .video_address(vid_addr), .video_words(3'd4),
        .video_data(), .video_data_valid(), .video_done(vid_done),
        .sdram_address(sdram_address), .sdram_write_data(sdram_write_data),
        .sdram_byte_enable(sdram_byte_enable), .sdram_burst(sdram_burst),
        .sdram_read(sdram_read), .sdram_write(sdram_write),
        .sdram_read_data(sdram_read_data),
        .sdram_data_valid(sdram_data_valid), .sdram_done(sdram_done),
        .sdram_ready(sdram_ready),
        .ddram_busy(1'b0), .ddram_burstcnt(), .ddram_addr(),
        .ddram_dout(64'd0), .ddram_dout_ready(1'b0), .ddram_rd(),
        .ddram_din(), .ddram_be(), .ddram_we(),
        .perf_frame(1'b0), .perf_cpu_outstanding(), .perf_cpu_burst(),
        .debug_state(), .debug_cpu_pending(),
        .debug_last_write_address(), .debug_last_write_data(),
        .debug_last_write_info(), .debug_write_count(),
        .debug_low_write_count(), .debug_main_write_count(),
        .debug_main_write0(), .debug_main_write1(), .debug_main_write2(),
        .debug_fill_b0(), .debug_fill_b1()
    );

    // -------------------------------------------------------- SDRAM chain
    wire [24:0] controller_address;
    wire [255:0] controller_write_data;
    wire  [63:0] controller_read_data;
    wire  [31:0] controller_byte_enable;
    wire  [4:0] controller_burst;
    wire        controller_read, controller_write;
    wire        controller_dout_valid, controller_ready;

    wire [15:0] SDRAM_DQ;
    wire [12:0] SDRAM_A;
    wire  [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE;
    wire        SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

    ki_sdram_adapter adapter (
        .clk(clk_1x), .reset(1'b0),
        .request_address(sdram_address),
        .request_write_data(sdram_write_data),
        .request_byte_enable(sdram_byte_enable),
        .request_burst(sdram_burst),
        .request_read(sdram_read), .request_write(sdram_write),
        .request_read_data(sdram_read_data),
        .request_data_valid(sdram_data_valid),
        .request_done(sdram_done),
        .aux_address(25'd0), .aux_write_data(64'd0), .aux_byte_enable(8'h00),
        .aux_burst(5'd1), .aux_read(1'b0), .aux_write(1'b0),
        .aux_read_data(), .aux_data_valid(), .aux_done(),
        .sdram_ready(sdram_ready),
        .controller_address(controller_address),
        .controller_write_data(controller_write_data),
        .controller_byte_enable(controller_byte_enable),
        .controller_burst(controller_burst),
        .controller_read(controller_read),
        .controller_write(controller_write),
        .controller_read_data(controller_read_data),
        .controller_dout_valid(controller_dout_valid),
        .controller_ready(controller_ready)
    );

    ki_sdram_burst controller (
        .init(init), .clk(clk_1x),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE),
        .wtbt(controller_byte_enable), .addr(controller_address),
        .burst(controller_burst),
        .dout(controller_read_data), .dout_valid(controller_dout_valid),
        .din(controller_write_data),
        .we(controller_write), .rd(controller_read), .ready(controller_ready)
    );

    mt48lc16m16_ki #(.TAC_NS(6.0)) memory (
        .clk(clk_dev), .dq(SDRAM_DQ), .addr(SDRAM_A), .ba(SDRAM_BA),
        .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS),
        .nWE(SDRAM_nWE),
        .dqm({SDRAM_DQMH, SDRAM_DQML}), .cke(SDRAM_CKE)
    );

    // ------------------------------------------------------- the program
    //
    // Hand-assembled rather than built with a toolchain, so the bench has no
    // external dependency and every instruction is visible here.
    //
    // Layout. Reset enters at 0xBFC00000, which is KSEG1 and therefore
    // UNCACHED, so the first thing the program does is jump to the KSEG0
    // alias of itself to run cached. J cannot do that - it keeps the top four
    // bits of the current PC - so the jump goes through a register.
    //
    // This core decides cacheability from the address alone (fetchCache tests
    // address bits 31:29 for "100"), so no COP0 Config setup is needed, and
    // both caches self-clear out of reset via their CLEARCACHE state.

    localparam int BOOT_BYTES = 8192;
    byte boot_rom [0:BOOT_BYTES-1];

    localparam logic [31:0] DATA_BASE  = 32'h8800_0000; // cached main RAM
    // One cache size (16 KB) above DATA_BASE, so the same cache indexes.
    localparam logic [31:0] DIRTY_BASE = 32'h8800_4000;
    localparam logic [31:0] MARK_BASE  = 32'hA007_0000; // uncached low RAM
    localparam logic [31:0] MARK_PHYS  = 32'h0007_0000;

    // Uncached census, after the measured walk. Five phases, each a run of
    // uncached accesses to one region, bracketed by marker stores at
    // PHASE_BASE + 4*k that the harness watches in STAGE 4, so every stall of
    // a phase is counted before its closing marker issues.
    localparam logic [31:0] PHASE_BASE = 32'hA007_0010;  // uncached low RAM
    localparam logic [31:0] PHASE_PHYS = 32'h0007_0010;
    localparam int          PHASES     = 5;

    // How many lines to walk. 32-byte stride over a span LARGER than the
    // 16 KB data cache, single pass, so every access is a genuine miss and
    // none of them can be a hit on a line an earlier iteration pulled in.
    localparam int LINES = 256;    // 8 KB, single cold pass

    task automatic emit(input integer offset, input logic [31:0] value);
        begin
            boot_rom[offset + 0] = value[7:0];
            boot_rom[offset + 1] = value[15:8];
            boot_rom[offset + 2] = value[23:16];
            boot_rom[offset + 3] = value[31:24];
        end
    endtask

    // Minimal MIPS-I encoders, named so the program below reads as assembly.
    function automatic logic [31:0] I_LUI (input int rt, input logic [15:0] imm);
        I_LUI  = {6'h0f, 5'd0, rt[4:0], imm};
    endfunction
    function automatic logic [31:0] I_ORI (input int rt, input int rs, input logic [15:0] imm);
        I_ORI  = {6'h0d, rs[4:0], rt[4:0], imm};
    endfunction
    function automatic logic [31:0] I_ADDIU(input int rt, input int rs, input logic [15:0] imm);
        I_ADDIU= {6'h09, rs[4:0], rt[4:0], imm};
    endfunction
    function automatic logic [31:0] I_LW  (input int rt, input int rs, input logic [15:0] off);
        I_LW   = {6'h23, rs[4:0], rt[4:0], off};
    endfunction
    function automatic logic [31:0] I_SW  (input int rt, input int rs, input logic [15:0] off);
        I_SW   = {6'h2b, rs[4:0], rt[4:0], off};
    endfunction
    function automatic logic [31:0] I_BNE (input int rs, input int rt, input logic [15:0] off);
        I_BNE  = {6'h05, rs[4:0], rt[4:0], off};
    endfunction
    function automatic logic [31:0] I_BEQ (input int rs, input int rt, input logic [15:0] off);
        I_BEQ  = {6'h04, rs[4:0], rt[4:0], off};
    endfunction
    function automatic logic [31:0] I_JR  (input int rs);
        I_JR   = {6'h00, rs[4:0], 15'd0, 6'h08};
    endfunction
    function automatic logic [31:0] I_ADDU(input int rd, input int rs, input int rt);
        I_ADDU = {6'h00, rs[4:0], rt[4:0], rd[4:0], 5'd0, 6'h21};
    endfunction
    function automatic logic [31:0] I_DADDU(input int rd, input int rs, input int rt);
        I_DADDU = {6'h00, rs[4:0], rt[4:0], rd[4:0], 5'd0, 6'h2d};
    endfunction
    // Every load and store width, for the framebuffer line buffer's
    // differential check: each reduces a buffered qword differently.
    function automatic logic [31:0] I_MEM(input logic [5:0] op, input int rt, input int rs,
                                          input logic [15:0] off);
        I_MEM = {op, rs[4:0], rt[4:0], off};
    endfunction
    localparam logic [5:0] OP_LB = 6'h20, OP_LH = 6'h21, OP_LWL = 6'h22, OP_LW = 6'h23, OP_LBU = 6'h24,
                           OP_LHU = 6'h25, OP_LWR = 6'h26, OP_LWU = 6'h27, OP_LD = 6'h37,
                           OP_LDL = 6'h1a, OP_LDR = 6'h1b,
                           OP_SB = 6'h28, OP_SH = 6'h29, OP_SW = 6'h2b, OP_SD = 6'h3f;

    // Iterations of the two-lines-one-set loop; see build_program.
    localparam int TWOWAY_ITERS = 16;

    // The framebuffer line buffer's two phases. RMW is shaped like KI2's
    // heaviest frame: one load and one store per qword at an 8-byte stride,
    // so each 32-byte line takes one fetch and three hits. MIXED is every
    // load and store width against a line held in the buffer, a line that is
    // not, and a store burst long enough to back the write FIFO up.
    localparam logic [31:0] FBL_RMW_BASE   = 32'hA003_1000;
    localparam int          FBL_RMW_ITERS  = 64;             // 16 lines
    localparam logic [31:0] FBL_MIX_BASE   = 32'hA003_2000;
    typedef struct { logic [5:0] op; logic [15:0] off; } mix_t;
    typedef struct { logic [5:0] op; int base; logic [15:0] off; } wbc_t;
    // The skipped-fill phase: an access relative to its base register, and
    // whether two independent instructions follow it (see its comment).
    typedef struct { logic [5:0] op; logic [15:0] off; bit settle; } skp_t;
    int fbl_mix_loads = 0;   // counted as build_program emits them
    // The framebuffer census window's loads, as byte offsets from its base.
    // build_program emits them; the check below models the buffer over the
    // same list, so the expected counts follow the number of lines it holds.
    int fbc_off [$];
    // The narrow-store phase's two bases: the same physical line twice would
    // compare with itself, so they are separate qwords, one reached through
    // KSEG0 and one through KSEG1.
    localparam logic [31:0] NS_CACHED   = 32'h8820_7000;
    localparam logic [31:0] NS_UNCACHED = 32'hA820_7080;
    // Uncached narrow stores it makes, which is what NS must count.
    localparam int          NS_STORES   = 4;
    // The framebuffer stress phase: its lines in FB page 0, clear of every
    // other phase's, and the running sums it must report.
    localparam logic [31:0] FBS_BASE    = 32'hA004_0000;
    localparam int          FBS_LINES   = 6;
    localparam int          FBS_OPS     = 100;
    localparam int          FBS_PASSES  = 8;
    // The pinned-victim phase: fresh lines per pass in FB page 0, clear of
    // every other phase, and what each pass must report.
    localparam logic [31:0] PV_BASE     = 32'hA004_4000;
    localparam int          PV_PASSES   = 8;
    logic [63:0] pv_expect [$];
    logic [63:0] fbs_expect [$];
    int          fbs_counts [0:8] = '{default: 0};
    // Lines the buffer holds, and whether it reads ahead. Read from the CPU's
    // own generics, so a run with -G/tb_ki_perfbench/cpu/FBLINE_WAYS=N (note
    // the CAPITAL -G: the lower-case one does not override a generic the
    // instantiation assigns) needs no second switch.
    int fbways = 4;
    int fbprefetch = 1;

    // That model: fbways lines replaced round-robin, and the fbways lines
    // thrown away most recently, which is what FR counts. The buffer starts
    // holding L0, loaded just before the window. Lines the earlier phases
    // left in it are 256 lines away and match nothing here, so they change
    // which way a fetch takes but no count.
    task automatic fb_census_model(output int want [0:4]);
        int tag [];
        bit val [];
        int hist [];
        bit hval [];
        int repl, line;
        bit hit, fr, fa, fv;
        tag = new[fbways];  val  = new[fbways];
        hist = new[fbways]; hval = new[fbways];
        for (int w = 0; w < fbways; w = w + 1) begin
            tag[w] = 0; val[w] = 1'b0; hist[w] = 0; hval[w] = 1'b0;
        end
        tag[0] = 0; val[0] = 1'b1;
        repl = (fbways > 1) ? 1 : 0;
        want = '{0, 0, 0, 0, 0};
        foreach (fbc_off[i]) begin
            line = fbc_off[i] / 32;
            want[0] = want[0] + 1;                        // FL
            hit = 1'b0;
            for (int w = 0; w < fbways; w = w + 1)
                if (val[w] && tag[w] == line) hit = 1'b1;
            if (hit) begin
                want[1] = want[1] + 1;                    // FH
            end else begin
                fr = 1'b0; fa = 1'b0; fv = 1'b0;
                for (int h = 0; h < fbways; h = h + 1)
                    if (hval[h] && hist[h] == line) fr = 1'b1;
                for (int w = 0; w < fbways; w = w + 1) if (val[w]) begin
                    if (line == tag[w] + 1  || line == tag[w] - 1)  fa = 1'b1;
                    if (line == tag[w] + 20 || line == tag[w] - 20) fv = 1'b1;
                end
                if (fr) want[2] = want[2] + 1;            // FR
                if (fa) want[3] = want[3] + 1;            // FA
                if (fv) want[4] = want[4] + 1;            // FV
                for (int h = fbways - 1; h > 0; h = h - 1) begin
                    hist[h] = hist[h-1];
                    hval[h] = hval[h-1];
                end
                hist[0] = tag[repl];
                hval[0] = val[repl];
                tag[repl] = line;
                val[repl] = 1'b1;
                repl = (repl + 1) % fbways;
            end
        end
    endtask

    // The skipped-fill phase's expected results, computed while the program is
    // assembled: memory as the program sees it, byte by byte, keyed by physical
    // address, and every register value the phase adds up. Only 64-bit stores
    // can skip a fill, so this is what must come out regardless.
    localparam logic [31:0] SKP_BASE0 = 32'h8820_4840;   // line C; set 0x42
    localparam logic [31:0] SKP_BASE1 = 32'hA820_4840;   // the same, uncached
    localparam int          STREAM_LINES = 64;
    logic [7:0]  skp_mem [logic [31:0]];
    logic [63:0] skp_t2 = 64'd0;
    logic [63:0] skp_expect_cached = 64'd0, skp_expect_sdram = 64'd0;

    function automatic logic [63:0] skp_read(input logic [31:0] a, input int n);
        logic [63:0] v;
        begin
            v = 64'd0;
            for (int i = 0; i < n; i = i + 1)
                v[i * 8 +: 8] = skp_mem[(a + i) & 32'h1FFF_FFFF];
            return v;
        end
    endfunction
    task automatic skp_write(input logic [31:0] a, input logic [63:0] v, input int n);
        for (int i = 0; i < n; i = i + 1)
            skp_mem[(a + i) & 32'h1FFF_FFFF] = v[i * 8 +: 8];
    endtask
    function automatic logic [63:0] sext32(input logic [31:0] v);
        return {{32{v[31]}}, v};
    endfunction

    // The data cache stress phase: random loads and stores of every width over
    // three sets of seven lines each, with the expected running sums computed
    // here. xorshift32, so the program is the same on every run.
    localparam logic [31:0] STR_BASE0 = 32'h8840_4A00;   // set 0x50, tag 0
    localparam logic [31:0] STR_BASE1 = 32'hA840_4A00;   // the same, uncached
    localparam logic [31:0] STR_PHYS  = 32'h0840_4A00;
    localparam int          STR_OPS   = 240;
    localparam int          STR_EVERY = 30;
    logic [63:0] str_expect [$];
    // The seed bytes as they were BEFORE the model applied the phase's stores:
    // the SDRAM is loaded from these, not from skp_mem, which by the time the
    // program is assembled holds the phase's final memory.
    logic [7:0]  str_seed [logic [31:0]];
    // Per load: its address, kind, and what the data cache must return for it
    // - the qword shifted down by the byte offset, before any extension.
    logic [31:0] str_load_addr [$];
    int          str_load_kind [$];
    logic [63:0] str_load_raw  [$];
    int unsigned str_rng = 32'h2545_F491;
    int          strtrace = 0;   // +strtrace=N: trace the first N accesses
    int          str_counts [0:9] = '{default: 0};   // by op kind, for the report
    function automatic int unsigned str_next();
        str_rng ^= str_rng << 13;
        str_rng ^= str_rng >> 17;
        str_rng ^= str_rng << 5;
        return str_rng;
    endfunction

    localparam int R0 = 0, T0 = 8, T1 = 9, T2 = 10, T3 = 11, T4 = 12, T5 = 13, T6 = 14, T7 = 15;
    integer loop_start, halt_pc;

    // Independent filler instructions between the loads, set with +pad=N.
    //
    // The walk already blocks on every fill, so this asks a different
    // question: does work that does NOT depend on the load get absorbed into
    // the fill, or does the CPU stall regardless? If cycles per iteration
    // rises by exactly PAD the pipeline is hard-blocked and there is no
    // overlap to exploit; if it rises by less, part of the fill is already
    // being hidden and more could be.
    //
    // The filler touches t4 only, so it cannot stall on the load result in t2.
    int pad = 0;

    // Bytes between successive loads, set with +stride=N. 32 is one cache
    // line, so the walk is exactly the next-line pattern a prefetcher would
    // predict; anything larger is still a miss every time but NOT next-line,
    // which is what proves the stride detector distinguishes the two rather
    // than just counting misses.
    int stride = 32;

    // Dirty victims, set with +dirty=1. Every walk otherwise only loads, so
    // every eviction is clean. Hardware's worst frames are FMV decode, which
    // writes, so there the victim is usually dirty - and cpu_datacache writes
    // it back BEFORE the fill, with cpu.vhd's scheduler draining those four
    // 64-bit beats ahead of the fill read, each as its own bridge
    // transaction. This pre-dirties the whole cache at DIRTY_BASE so every
    // measured miss pays for that. The pre-pass covers 16 KB, both ways of
    // every set of the 2-way cache, so each measured miss still evicts a
    // dirty line: the least recently used of two dirty ones.
    //
    // The F1/F2/F3 split of a dirty miss was wrong until 2cd6764:
    // cpu_datacache cleared fill_beat_seen on IDLE -> FILL but not on
    // WRITEBACKDONE -> FILL, so the first-beat wait was filed as F3. The
    // dirty F1 check in report_and_finish guards the fix.
    int dirty = 0;
    localparam int CODE = 'h100;   // cached entry, virtual 0x9FC00100

    task automatic build_program;
        integer p;
        integer pre_loop;
        begin
            for (int i = 0; i < BOOT_BYTES; i = i + 1) boot_rom[i] = 8'h00;

            // Reset vector: hop from KSEG1 to the KSEG0 alias.
            emit('h000, I_LUI (T0, 16'h9FC0));
            emit('h004, I_ORI (T0, T0, CODE[15:0]));
            emit('h008, I_JR  (T0));
            emit('h00c, 32'h0000_0000);            // delay slot

            p = CODE;
            emit(p, I_LUI  (T0, DATA_BASE[31:16])); p += 4;
            emit(p, I_LUI  (T1, 16'h0000));        p += 4;
            emit(p, I_ORI  (T1, T1, LINES[15:0])); p += 4;
            emit(p, I_LUI  (T3, MARK_BASE[31:16]));p += 4;
            emit(p, I_ORI  (T3, T3, MARK_BASE[15:0])); p += 4;

            if (dirty != 0) begin
                // Store to every line of the cache at DIRTY_BASE. A store
                // miss allocates and marks the line dirty, so afterwards each
                // measured miss evicts a dirty line. Before the START marker,
                // so none of this is measured.
                //
                // Four lines per pass, each with its own written-qword pattern:
                // line 4j+0 writes qword 0, 4j+1 qwords 1-2, 4j+2 qwords 0 and 3,
                // 4j+3 all four. They were the known totals of a write-back
                // census that has since answered and gone (see
                // docs/OPTIMIZATION-HISTORY.md); every store is 32-bit, so none
                // of these misses skips its fill.
                emit(p, I_LUI  (T5, DIRTY_BASE[31:16]));    p += 4;
                emit(p, I_ORI  (T5, T5, DIRTY_BASE[15:0])); p += 4;
                emit(p, I_LUI  (T6, 16'h0000));             p += 4;
                emit(p, I_ORI  (T6, T6, 16'd128));          p += 4;
                pre_loop = p;
                emit(p, I_SW   (R0, T5, 16'd0));            p += 4;  // 4j+0: q0
                emit(p, I_SW   (R0, T5, 16'd44));           p += 4;  // 4j+1: q1
                emit(p, I_SW   (R0, T5, 16'd48));           p += 4;  //       q2
                emit(p, I_SW   (R0, T5, 16'd64));           p += 4;  // 4j+2: q0
                emit(p, I_SW   (R0, T5, 16'd88));           p += 4;  //       q3
                emit(p, I_SW   (R0, T5, 16'd96));           p += 4;  // 4j+3: q0
                emit(p, I_SW   (R0, T5, 16'd104));          p += 4;  //       q1
                emit(p, I_SW   (R0, T5, 16'd112));          p += 4;  //       q2
                emit(p, I_SW   (R0, T5, 16'd120));          p += 4;  //       q3
                emit(p, I_ADDIU(T5, T5, 16'd128));          p += 4;
                emit(p, I_ADDIU(T6, T6, 16'hffff));         p += 4;
                emit(p, I_BNE  (T6, R0,
                                16'((pre_loop - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                     p += 4;
            end

            // START marker. Uncached, so it reaches the bus immediately and
            // the harness can timestamp it.
            emit(p, I_SW   (R0, T3, 16'h0000));    p += 4;

            // The measured loop. One load per 32-byte line, so exactly one
            // D-cache miss per iteration.
            loop_start = p;
            emit(p, I_LW   (T2, T0, 16'h0000));    p += 4;
            for (int f = 0; f < pad; f = f + 1) begin
                emit(p, I_ADDIU(T4, T4, 16'h0001)); p += 4;
            end
            emit(p, I_ADDIU(T0, T0, 16'(stride)));  p += 4;
            emit(p, I_ADDIU(T1, T1, 16'hffff));    p += 4;   // -1
            // Branch back to loop_start. Offset counts from the delay slot.
            emit(p, I_BNE  (T1, R0,
                            16'((loop_start - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                p += 4;   // delay slot

            // END marker.
            emit(p, I_SW   (R0, T3, 16'h0004));    p += 4;

            // Uncached census. Phase k's accesses land between markers k and
            // k+1; the harness checks each phase fills its own tap and no
            // other. I/O re-reads one address rather than walking off the end
            // of the register block. The stores outrun the write FIFO so they
            // stall, which is the only way a store is counted at all.
            for (int ph = 0; ph < PHASES; ph = ph + 1) begin
                logic [31:0] base;
                logic [15:0] step;
                int          count;
                case (ph)
                    0: begin base = 32'hA003_0000; step = 16'd4; count = 16; end // framebuffer
                    1: begin base = 32'hB000_0080; step = 16'd0; count = 16; end // board I/O
                    2: begin base = 32'hBFC0_0400; step = 16'd4; count = 16; end // boot ROM
                    3: begin base = 32'hA801_0000; step = 16'd4; count = 16; end // main RAM
                    default: begin base = 32'hA801_1000; step = 16'd4; count = 32; end // stores
                endcase
                emit(p, I_SW   (R0, T3, 16'(32'h10 + ph * 4))); p += 4;  // marker k
                emit(p, I_LUI  (T5, base[31:16]));             p += 4;
                emit(p, I_ORI  (T5, T5, base[15:0]));          p += 4;
                emit(p, I_LUI  (T6, 16'h0000));                p += 4;
                emit(p, I_ORI  (T6, T6, 16'(count)));          p += 4;
                pre_loop = p;
                if (ph < 4) emit(p, I_LW(T2, T5, 16'h0000));
                else        emit(p, I_SW(R0, T5, 16'h0000));
                p += 4;
                emit(p, I_ADDIU(T5, T5, step));                p += 4;
                emit(p, I_ADDIU(T6, T6, 16'hffff));            p += 4;
                emit(p, I_BNE  (T6, R0,
                                16'((pre_loop - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                        p += 4;
            end
            emit(p, I_SW   (R0, T3, 16'(32'h10 + PHASES * 4))); p += 4; // last

            // Framebuffer line buffer, RMW. Every word of the 16 lines is
            // first stored with its own address, stores only, so no load in
            // the window reads uninitialised memory. Then one load, modify
            // and store per qword at an 8-byte stride.
            emit(p, I_LUI  (T6, FBL_RMW_BASE[31:16]));        p += 4;
            emit(p, I_ORI  (T6, T6, FBL_RMW_BASE[15:0]));     p += 4;
            emit(p, I_ADDIU(T1, R0, 16'(FBL_RMW_ITERS * 2))); p += 4;
            pre_loop = p;
            emit(p, I_SW   (T6, T6, 16'h0000));               p += 4;
            emit(p, I_ADDIU(T6, T6, 16'd4));                  p += 4;
            emit(p, I_ADDIU(T1, T1, 16'hffff));               p += 4;
            emit(p, I_BNE  (T1, R0, 16'((pre_loop - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                           p += 4;
            emit(p, I_LUI  (T5, FBL_RMW_BASE[31:16]));        p += 4;
            emit(p, I_ORI  (T5, T5, FBL_RMW_BASE[15:0]));     p += 4;
            emit(p, I_ADDIU(T1, R0, 16'(FBL_RMW_ITERS)));     p += 4;
            emit(p, I_SW   (R0, T3, 16'h0120));               p += 4;  // window opens
            pre_loop = p;
            emit(p, I_LW   (T2, T5, 16'h0000));               p += 4;
            emit(p, I_ADDIU(T2, T2, 16'h0101));               p += 4;
            emit(p, I_SW   (T2, T5, 16'h0000));               p += 4;
            emit(p, I_ADDIU(T5, T5, 16'd8));                  p += 4;
            emit(p, I_ADDIU(T1, T1, 16'hffff));               p += 4;
            emit(p, I_BNE  (T1, R0, 16'((pre_loop - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                           p += 4;
            emit(p, I_SW   (R0, T3, 16'h0124));               p += 4;  // window closes

            // Framebuffer line buffer, MIXED. Lines B-32, B and B+32 are
            // stored with their own addresses first. B and B+32 differ only in
            // address bit 5, so a tag compare one bit short answers one with
            // the other. Every load is summed into t4, 64-bit, and reported.
            emit(p, I_LUI  (T5, FBL_MIX_BASE[31:16]));        p += 4;
            emit(p, I_ORI  (T5, T5, FBL_MIX_BASE[15:0]));     p += 4;
            emit(p, I_ADDIU(T6, T5, 16'hffe0));               p += 4;  // B - 32
            emit(p, I_ADDIU(T1, R0, 16'd24));                 p += 4;
            pre_loop = p;
            emit(p, I_SW   (T6, T6, 16'h0000));               p += 4;
            emit(p, I_ADDIU(T6, T6, 16'd4));                  p += 4;
            emit(p, I_ADDIU(T1, T1, 16'hffff));               p += 4;
            emit(p, I_BNE  (T1, R0, 16'((pre_loop - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                           p += 4;
            emit(p, I_LUI  (T2, 16'h89AB));                   p += 4;
            emit(p, I_ORI  (T2, T2, 16'hCDEF));               p += 4;
            emit(p, I_ADDIU(T4, R0, 16'h0000));               p += 4;
            emit(p, I_SW   (R0, T3, 16'h0128));               p += 4;  // window opens
            begin
                // {op, offset from B}; loads add into t4, stores write t2.
                // Offsets are signed 16-bit, relative to B.
                mix_t mix [$];
                mix = '{
                    // First touch of B: a fetch, then hits of every width.
                    '{OP_LB,  16'd3},  '{OP_LHU, 16'd6},
                    // Stores into the line the buffer holds, each read back.
                    '{OP_SB,  16'd1},  '{OP_LBU, 16'd1},  '{OP_LB, 16'd0},
                    '{OP_SH,  16'd10}, '{OP_LH,  16'd10}, '{OP_LWU, 16'd8},
                    '{OP_SW,  16'd20}, '{OP_LD,  16'd16}, '{OP_LWU, 16'd20},
                    '{OP_SD,  16'd24}, '{OP_LWU, 16'd28}, '{OP_LD,  16'd24},
                    // Partial-word loads across qword and half boundaries.
                    '{OP_LWL, 16'd13}, '{OP_LWR, 16'd18}, '{OP_LWL, 16'd6},
                    '{OP_LWR, 16'd1},  '{OP_LDL, 16'd5},  '{OP_LDR, 16'd27},
                    // The neighbouring line, then back: two fetches.
                    '{OP_LWU, 16'd32}, '{OP_LWU, 16'd4},
                    // A store to a line the buffer does NOT hold, then its load:
                    // the fetch must include the store.
                    '{OP_SW,  16'd36}, '{OP_LWU, 16'd36}, '{OP_LD, 16'd32},
                    // The line below, from its last byte.
                    '{OP_LBU, 16'hffff}, '{OP_LWU, 16'h0000},
                    // A store burst into the held line, back to back, then a
                    // read of every qword.
                    '{OP_SB,  16'd0},  '{OP_SH,  16'd2},  '{OP_SB, 16'd5},
                    '{OP_SW,  16'd8},  '{OP_SB,  16'd13}, '{OP_SH, 16'd14},
                    '{OP_SW,  16'd16}, '{OP_SB,  16'd21}, '{OP_SH, 16'd22},
                    '{OP_SD,  16'd24}, '{OP_SB,  16'd3},  '{OP_SH, 16'd6},
                    '{OP_SW,  16'd12}, '{OP_SB,  16'd31}, '{OP_SH, 16'd18},
                    '{OP_LD,  16'd0},  '{OP_LD,  16'd8},  '{OP_LD, 16'd16},
                    '{OP_LD,  16'd24}
                };
                foreach (mix[i]) begin
                    if (mix[i].op inside {OP_SB, OP_SH, OP_SW, OP_SD}) begin
                        emit(p, I_ADDIU(T2, T2, 16'h1357));                 p += 4;
                        emit(p, I_MEM  (mix[i].op, T2, T5, mix[i].off));   p += 4;
                    end else begin
                        emit(p, I_MEM  (mix[i].op, T7, T5, mix[i].off));   p += 4;
                        emit(p, I_DADDU(T4, T4, T7));                       p += 4;
                        fbl_mix_loads = fbl_mix_loads + 1;
                    end
                end
            end
            emit(p, I_SW   (R0, T3, 16'h012C));               p += 4;  // window closes
            emit(p, I_MEM  (OP_SD, T4, T3, 16'h0130));        p += 4;  // report the sum

            // Store-then-load hazard. A load that hits in the cycle right after
            // a store cannot use the data RAM output - the store addressed that
            // RAM - so cpu_datacache sends it through READWAIT to re-read.
            // Warm two cached lines, store to one, load the other IMMEDIATELY,
            // and report what the load returned through an uncached store.
            emit(p, I_LUI  (T5, 16'h8801));             p += 4;
            emit(p, I_ORI  (T5, T5, 16'h2000));         p += 4;  // line A
            emit(p, I_LUI  (T6, 16'h8801));             p += 4;
            emit(p, I_ORI  (T6, T6, 16'h2100));         p += 4;  // line B
            emit(p, I_LUI  (T2, 16'h1234));             p += 4;
            emit(p, I_ORI  (T2, T2, 16'h5678));         p += 4;
            emit(p, I_SW   (T2, T6, 16'h0000));         p += 4;  // B := 12345678
            emit(p, I_LW   (T4, T5, 16'h0000));         p += 4;  // bring A in
            emit(p, I_LW   (T4, T6, 16'h0000));         p += 4;  // B resident
            emit(p, I_ADDIU(T4, R0, 16'h0000));         p += 4;  // T4 := 0
            emit(p, I_SW   (R0, T5, 16'h0000));         p += 4;  // store, hits A
            emit(p, I_LW   (T4, T6, 16'h0000));         p += 4;  // load B next cycle
            emit(p, I_SW   (T4, T3, 16'h0100));         p += 4;  // report, uncached

            // The same, but with INDEPENDENT instructions after the load, so
            // no load-use hazard is involved. Written to test whether the data
            // RAM moves on to the next instruction's address while the load
            // waits in READWAIT. It does not: every cached load stalls stage 3
            // in its own issue cycle (the load-delay stall in cpu.vhd), which
            // holds the RAM on the load's address whatever follows - the fact
            // the 2-way cache's WAYFIX relies on too.
            // Two passes: the first runs straight after an I-cache miss, and a
            // fetch bubble between the store and the load keeps READWAIT from
            // being entered at all. The second pass runs from the I-cache.
            emit(p, I_ADDIU(T1, R0, 16'h0002));         p += 4;  // passes
            pre_loop = p;
            emit(p, I_ADDIU(T4, R0, 16'h0000));         p += 4;  // T4 := 0
            emit(p, I_SW   (R0, T5, 16'h0000));         p += 4;  // store, hits A
            emit(p, I_LW   (T4, T6, 16'h0000));         p += 4;  // load B next cycle
            emit(p, I_ADDIU(T2, T2, 16'h0001));         p += 4;  // independent
            emit(p, I_ADDIU(T2, T2, 16'h0001));         p += 4;  // independent
            emit(p, I_ADDIU(T1, T1, 16'hffff));         p += 4;
            emit(p, I_BNE  (T1, R0,
                            16'((pre_loop - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                     p += 4;
            emit(p, I_SW   (T4, T3, 16'h0104));         p += 4;  // report, uncached

            // Two lines in ONE set, loaded alternately - what the 2-way cache
            // is for. A and B are 16 KB apart, so they also share an index in
            // a direct-mapped 16 KB cache, which would take a dirty miss at
            // every change of line here.
            // Each iteration loads A, A+8, B, B+8 and sums them. The first
            // load of each line hits in the way the prediction did not pick -
            // the other line was used last - and takes WAYFIX; the second is
            // predicted right. The sum proves every load returned its own
            // line's data, through the real pipeline and its load-use stall.
            emit(p, I_LUI  (T5, 16'h8802));             p += 4;  // A = 88020000
            emit(p, I_LUI  (T6, 16'h8802));             p += 4;
            emit(p, I_ORI  (T6, T6, 16'h4000));         p += 4;  // B = 88024000
            emit(p, I_ORI  (T2, R0, 16'h1111));         p += 4;
            emit(p, I_SW   (T2, T5, 16'h0000));         p += 4;
            emit(p, I_ORI  (T2, R0, 16'h0100));         p += 4;
            emit(p, I_SW   (T2, T5, 16'h0008));         p += 4;
            emit(p, I_ORI  (T2, R0, 16'h2222));         p += 4;
            emit(p, I_SW   (T2, T6, 16'h0000));         p += 4;
            emit(p, I_ORI  (T2, R0, 16'h0010));         p += 4;
            emit(p, I_SW   (T2, T6, 16'h0008));         p += 4;
            emit(p, I_ADDIU(T4, R0, 16'h0000));         p += 4;  // sum
            emit(p, I_ADDIU(T1, R0, 16'(TWOWAY_ITERS))); p += 4;
            // Both loops start on an I-cache line boundary and have the same
            // length, so their instruction fetches cost the same and the
            // difference between the windows is the data side alone.
            while ((p % 32) != 28) begin emit(p, 32'h0000_0000); p += 4; end
            emit(p, I_SW   (R0, T3, 16'h0108));         p += 4;  // window opens
            pre_loop = p;
            emit(p, I_LW   (T2, T5, 16'h0000));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_LW   (T2, T5, 16'h0008));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_LW   (T2, T6, 16'h0000));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_LW   (T2, T6, 16'h0008));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_ADDIU(T1, T1, 16'hffff));         p += 4;
            emit(p, I_BNE  (T1, R0,
                            16'((pre_loop - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                     p += 4;
            emit(p, I_SW   (R0, T3, 16'h010C));         p += 4;  // window closes
            emit(p, I_SW   (T4, T3, 16'h0110));         p += 4;  // report the sum

            // The same loop with every load predicted right - A, A+8, A, A+8 -
            // after one load of A to make A the most recently used line. Same
            // instructions and load-use stalls, so the cycle difference
            // between the two windows is what the first loop's WAYFIX cost.
            emit(p, I_LW   (T2, T5, 16'h0000));         p += 4;
            emit(p, I_ADDIU(T4, R0, 16'h0000));         p += 4;
            emit(p, I_ADDIU(T1, R0, 16'(TWOWAY_ITERS))); p += 4;
            while ((p % 32) != 28) begin emit(p, 32'h0000_0000); p += 4; end
            emit(p, I_SW   (R0, T3, 16'h0114));         p += 4;  // window opens
            pre_loop = p;
            emit(p, I_LW   (T2, T5, 16'h0000));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_LW   (T2, T5, 16'h0008));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_LW   (T2, T5, 16'h0000));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_LW   (T2, T5, 16'h0008));         p += 4;
            emit(p, I_ADDU (T4, T4, T2));               p += 4;
            emit(p, I_ADDIU(T1, T1, 16'hffff));         p += 4;
            emit(p, I_BNE  (T1, R0,
                            16'((pre_loop - (p + 4)) >>> 2))); p += 4;
            emit(p, 32'h0000_0000);                     p += 4;
            emit(p, I_SW   (R0, T3, 16'h0118));         p += 4;  // window closes
            emit(p, I_SW   (T4, T3, 16'h011C));         p += 4;  // report the sum

            // Write-back phase (markers 0x140 / 0x144): three lines of one set,
            // A, B and C, each written back once. The first two loads bring A
            // and B in before the window opens, so whatever the set held is
            // evicted outside it. Then A is written in all four qwords and B in
            // qword 0; C evicts A and is written in qword 1; A evicts B; B
            // evicts C. So WB 3, and every store hits: no SF, no SK. (It was
            // built as the census of written qwords per write-back.)
            //
            // Two independent instructions after each access let the set's
            // most-recently-used bit settle; see the LRU note in
            // cpu_datacache.vhd.
            emit(p, I_LUI  (T5, 16'h8810));             p += 4;  // A 88100800
            emit(p, I_ORI  (T5, T5, 16'h0800));         p += 4;
            emit(p, I_LUI  (T6, 16'h8810));             p += 4;  // B 88102800
            emit(p, I_ORI  (T6, T6, 16'h2800));         p += 4;
            emit(p, I_LUI  (T7, 16'h8810));             p += 4;  // C 88104800
            emit(p, I_ORI  (T7, T7, 16'h4800));         p += 4;
            begin
                // {op, base register, offset}; op 0 is a window marker.
                wbc_t seq [$];
                seq = '{
                    '{6'h23, T5, 16'd0}, '{6'h23, T6, 16'd0},          // A, B in
                    '{6'h00, 0, 16'h0140},                              // window opens
                    '{6'h2b, T5, 16'd4}, '{6'h2b, T5, 16'd8},
                    '{6'h2b, T5, 16'd20}, '{6'h2b, T5, 16'd28},         // A: 1111
                    '{6'h2b, T6, 16'd0},                                // B: 0001
                    '{6'h23, T7, 16'd0},                                // C evicts A
                    '{6'h2b, T7, 16'd12},                               // C: 0010
                    '{6'h23, T5, 16'd0},                                // A evicts B
                    '{6'h23, T6, 16'd0},                                // B evicts C
                    '{6'h00, 0, 16'h0144}                               // window closes
                };
                foreach (seq[i]) begin
                    if (seq[i].op == 6'h00) begin
                        emit(p, I_SW(R0, T3, seq[i].off));              p += 4;
                    end else begin
                        emit(p, I_MEM(seq[i].op, (seq[i].op == 6'h23) ? T4 : R0,
                                      seq[i].base, seq[i].off));       p += 4;
                        emit(p, I_ADDIU(T2, T2, 16'h0001));             p += 4;
                        emit(p, I_ADDIU(T2, T2, 16'h0001));             p += 4;
                    end
                end
            end

            // Fill-need phase (markers 0x148 / 0x14C): the next set, lines E,
            // F, G, H, and X and Y to clear it before the window opens. It was
            // built as the census of unneeded fills. Inside it:
            //   E is store-missed by a 64-bit store and written whole by four,
            //     then loaded where already written (SK, or SF without
            //     DCACHE_SKIP_FILL);
            //   F is store-missed by a 32-bit store (SF), an unwritten qword
            //     loaded before its stores cover it;
            //   G load-missed evicts E (WB);
            //   H store-missed (SF) evicts F (WB);
            //   E load-missed evicts G (clean);
            //   F load-missed evicts H (WB);
            //   I store-missed (SF) evicts E (clean);
            //   E and F load-missed evict F (clean) and I (WB).
            // So WB 4, and SF 3 with SK 1, or SF 4 without.
            emit(p, I_LUI  (T5, 16'h8810));             p += 4;  // base 88100820
            emit(p, I_ORI  (T5, T5, 16'h0820));         p += 4;
            begin
                wbc_t seq2 [$];
                seq2 = '{
                    '{6'h23, T5, 16'h8000}, '{6'h23, T5, 16'hA000},     // X, Y in
                    '{6'h00, 0,  16'h0148},                             // window opens
                    '{OP_SD, T5, 16'h0000}, '{OP_SD, T5, 16'h0008},
                    '{OP_SD, T5, 16'h0010}, '{OP_SD, T5, 16'h0018},     // E: 1111, 64-bit
                    '{6'h23, T5, 16'h0008},                             // E: load q1, written
                    '{6'h2b, T5, 16'h2000},                             // F: store miss
                    '{6'h23, T5, 16'h2008},                             // F: load q1, unwritten
                    '{6'h2b, T5, 16'h2008}, '{6'h2b, T5, 16'h2010},
                    '{6'h2b, T5, 16'h2018},                             // F: 1111
                    '{6'h23, T5, 16'h4000},                             // G evicts E
                    '{6'h2b, T5, 16'h6004},                             // H evicts F
                    '{6'h2b, T5, 16'h600C}, '{6'h2b, T5, 16'h6014},
                    '{6'h2b, T5, 16'h601C},                             // H: 1111, high halves
                    '{6'h23, T5, 16'h0000},                             // E evicts G
                    '{6'h23, T5, 16'h2000},                             // F evicts H
                    '{6'h2b, T5, 16'hE000}, '{6'h2b, T5, 16'hE004},     // I (base - 2000)
                    '{6'h2b, T5, 16'hE008}, '{6'h2b, T5, 16'hE00C},     //   evicts E, clean
                    '{6'h2b, T5, 16'hE010}, '{6'h2b, T5, 16'hE014},
                    '{6'h2b, T5, 16'hE018}, '{6'h2b, T5, 16'hE01C},     // I: every half
                    '{6'h23, T5, 16'h0000},                             // E evicts F, clean
                    '{6'h23, T5, 16'h2000},                             // F evicts I
                    '{6'h00, 0,  16'h014C}                              // window closes
                };
                foreach (seq2[i]) begin
                    if (seq2[i].op == 6'h00) begin
                        emit(p, I_SW(R0, T3, seq2[i].off));             p += 4;
                    end else begin
                        emit(p, I_MEM(seq2[i].op, (seq2[i].op == 6'h23) ? T4 : R0,
                                      seq2[i].base, seq2[i].off));     p += 4;
                        emit(p, I_ADDIU(T2, T2, 16'h0001));             p += 4;
                        emit(p, I_ADDIU(T2, T2, 16'h0001));             p += 4;
                    end
                end
            end

            // Skipped-fill phase (markers 0x150 / 0x154). Eight lines of one
            // set, C = 0x88204840 in t5 and the others 0x2000 apart: D, E, F
            // above it, B, A, G, H below. Every qword of all eight is first
            // written through KSEG1 with its own address, so a fill has
            // something to bring and SDRAM a known state. G and H are loaded
            // to leave the set clean. In the window, each case a skipped fill
            // creates (the counts are with DCACHE_SKIP_FILL; without it every
            // store miss fills):
            //   1  64-bit store miss on C q2 over G (clean)       SK
            //   2  C q2 loads the store; C q0 loads the SDRAM data AF, and
            //      C q2 must still be the store afterwards
            //   6  64-bit store miss on D q1 over H (clean)       SK
            //   7  a BYTE store into D's absent q3                AF + SF
            //   8  D q3 is the SDRAM data with that byte in it
            //  11  E q0 by store miss over C (dirty, whole)       SK, WB
            //  12  a 64-bit store into E's absent q3: no fill
            //  14  F q2 over D (dirty, whole)                     SK, WB
            //  16  A q1 over E (dirty, q0 and q3 only)            SK, WB
            //  17  A q0 loads the SDRAM data                      AF
            //  18  B q0 over F (dirty, q2 only)                   SK, WB
            //  19  C q1 over A (dirty, whole), then at once the load of it,
            //      and of C q2 - which is absent now, so it must come back
            //      from SDRAM as the store step 1 made: step 11 wrote it  SK, WB, AF
            //  20  G and H load over B (q0 only) and C (whole)    WB, WB
            // So SK 7, AF 4, SF 1, WB 7 and MC 13 - or SF 7, MC 9 and no SK or
            // AF without it. Loads are summed into t7 (0x158). After the
            // window every qword of the eight lines is read back through
            // KSEG1, straight from SDRAM, into another sum (0x168): a write-back
            // that wrote an absent qword, or skipped a present one, shows there.
            // Stores write t2, which each store first changes: a 32-bit add,
            // then a 64-bit add of t5, so every stored qword is distinct in
            // both halves.
            emit(p, I_LUI  (T5, SKP_BASE0[31:16]));        p += 4;
            emit(p, I_ORI  (T5, T5, SKP_BASE0[15:0]));     p += 4;
            emit(p, I_LUI  (T6, SKP_BASE1[31:16]));        p += 4;
            emit(p, I_ORI  (T6, T6, SKP_BASE1[15:0]));     p += 4;
            begin
                logic [15:0] lines [0:7];
                skp_t        seq3 [$];
                logic [63:0] t5v, v;
                lines = '{16'hC000, 16'hE000, 16'h0000, 16'h2000,       // A B C D
                          16'h4000, 16'h6000, 16'hA000, 16'h8000};      // E F G H
                t5v = sext32(SKP_BASE0);
                foreach (lines[l])
                    for (int q = 0; q < 4; q = q + 1) begin
                        logic [15:0] off;
                        off = lines[l] + 16'(q * 8);
                        emit(p, I_ADDIU(T2, T6, off));             p += 4;
                        emit(p, I_MEM  (OP_SD, T2, T6, off));      p += 4;
                        skp_write(SKP_BASE1 + {{16{off[15]}}, off},
                                  sext32(SKP_BASE1 + {{16{off[15]}}, off}), 8);
                    end
                emit(p, I_MEM  (OP_LD, T4, T5, 16'hA000));        p += 4;  // G
                emit(p, I_ADDIU(T1, T1, 16'h0001));               p += 4;
                emit(p, I_ADDIU(T1, T1, 16'h0001));               p += 4;
                emit(p, I_MEM  (OP_LD, T4, T5, 16'h8000));        p += 4;  // H
                emit(p, I_ADDIU(T1, T1, 16'h0001));               p += 4;
                emit(p, I_ADDIU(T1, T1, 16'h0001));               p += 4;
                emit(p, I_ADDIU(T7, R0, 16'h0000));               p += 4;
                emit(p, I_ADDIU(T2, R0, 16'h0000));               p += 4;
                skp_t2 = 64'd0;
                emit(p, I_SW   (R0, T3, 16'h0150));               p += 4;  // window opens
                seq3 = '{
                    '{OP_SD,  16'h0010, 1}, '{OP_LD,  16'h0010, 1},     //  1  2
                    '{OP_LD,  16'h0000, 1}, '{OP_LD,  16'h0010, 1},
                    '{OP_LD,  16'h0018, 1},
                    '{OP_SD,  16'h2008, 1}, '{OP_SB,  16'h201B, 1},     //  6  7
                    '{OP_LD,  16'h2018, 1}, '{OP_LB,  16'h201B, 1},     //  8
                    '{OP_LD,  16'h2000, 1},
                    '{OP_SD,  16'h4000, 1}, '{OP_SD,  16'h4018, 1},     // 11 12
                    '{OP_LD,  16'h4018, 1},
                    '{OP_SD,  16'h6010, 1}, '{OP_LWU, 16'h6014, 1},     // 14
                    '{OP_SD,  16'hC008, 1}, '{OP_LD,  16'hC000, 1},     // 16 17
                    '{OP_SD,  16'hE000, 1},                             // 18
                    '{OP_SD,  16'h0008, 0}, '{OP_LD,  16'h0008, 0},     // 19
                    '{OP_LD,  16'h0010, 1},
                    '{OP_LD,  16'hA000, 1}, '{OP_LD,  16'h8000, 1}      // 20
                };
                foreach (seq3[i]) begin
                    logic [31:0] a;
                    a = SKP_BASE0 + {{16{seq3[i].off[15]}}, seq3[i].off};
                    if (seq3[i].op inside {OP_SB, OP_SD}) begin
                        emit(p, I_ADDIU(T2, T2, 16'h1357));                p += 4;
                        emit(p, I_DADDU(T2, T2, T5));                      p += 4;
                        emit(p, I_MEM  (seq3[i].op, T2, T5, seq3[i].off)); p += 4;
                        skp_t2 = sext32(skp_t2[31:0] + 32'h1357) + t5v;
                        skp_write(a, skp_t2, (seq3[i].op == OP_SD) ? 8 : 1);
                    end else begin
                        emit(p, I_MEM  (seq3[i].op, T4, T5, seq3[i].off)); p += 4;
                        emit(p, I_DADDU(T7, T7, T4));                      p += 4;
                        case (seq3[i].op)
                            OP_LD:   v = skp_read(a, 8);
                            OP_LWU:  v = skp_read(a, 4);
                            default: begin                                   // LB
                                v = skp_read(a, 1);
                                v = {{56{v[7]}}, v[7:0]};
                            end
                        endcase
                        skp_expect_cached = skp_expect_cached + v;
                    end
                    if (seq3[i].settle) begin
                        emit(p, I_ADDIU(T1, T1, 16'h0001));                p += 4;
                        emit(p, I_ADDIU(T1, T1, 16'h0001));                p += 4;
                    end
                end
                emit(p, I_SW   (R0, T3, 16'h0154));               p += 4;  // window closes
                emit(p, I_MEM  (OP_SD, T7, T3, 16'h0158));        p += 4;  // report
                emit(p, I_ADDIU(T7, R0, 16'h0000));               p += 4;
                foreach (lines[l])
                    for (int q = 0; q < 4; q = q + 1) begin
                        logic [15:0] off;
                        off = lines[l] + 16'(q * 8);
                        emit(p, I_MEM  (OP_LD, T4, T6, off));      p += 4;
                        emit(p, I_DADDU(T7, T7, T4));              p += 4;
                        skp_expect_sdram = skp_expect_sdram +
                            skp_read(SKP_BASE1 + {{16{off[15]}}, off}, 8);
                    end
                // 0x168, not 0x15C: an SD to an address that is not 8-byte
                // aligned is an address error (cpu.vhd, EXCTYPE_ADDRD).
                emit(p, I_MEM  (OP_SD, T7, T3, 16'h0168));        p += 4;  // report
            end

            // Store stream (markers 0x160 / 0x164): the heavy frames' shape,
            // 64 lines written whole by 64-bit stores, each line's first store
            // a miss that evicts a dirty line. Two passes at 0x88300000 and
            // 0x88304000 fill both ways of sets 0-63 with dirty lines; the
            // measured third pass at 0x88308000 evicts the first pass's. So
            // WB 64 and MC 64, and SK 64 with DCACHE_SKIP_FILL or SF 64
            // without - the cycles per line between the two are the saving.
            for (int pass = 0; pass < 3; pass = pass + 1) begin
                emit(p, I_LUI  (T6, 16'h8830));                   p += 4;
                emit(p, I_ORI  (T6, T6, 16'(pass * 16'h4000)));   p += 4;
                emit(p, I_ADDIU(T1, R0, 16'(STREAM_LINES)));      p += 4;
                if (pass == 2) begin
                    while ((p % 32) != 28) begin emit(p, 32'h0000_0000); p += 4; end
                    emit(p, I_SW(R0, T3, 16'h0160));              p += 4;  // window opens
                end
                pre_loop = p;
                for (int q = 0; q < 4; q = q + 1) begin
                    emit(p, I_MEM(OP_SD, T2, T6, 16'(q * 8)));    p += 4;
                end
                emit(p, I_ADDIU(T6, T6, 16'd32));                 p += 4;
                emit(p, I_ADDIU(T1, T1, 16'hffff));               p += 4;
                emit(p, I_BNE  (T1, R0, 16'((pre_loop - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                if (pass == 2) begin
                    emit(p, I_SW(R0, T3, 16'h0164));              p += 4;  // window closes
                end
            end

            // Framebuffer load census (markers 0x170 / 0x174): what the line
            // buffer's misses fetched. Lines L(n) are 32 bytes apart from
            // 0xA0034000, a stretch of FB0 no earlier phase touches; L(0) is
            // loaded before the window, so the buffer holds it. In order:
            //   L2 L8                      two scattered fetches
            //   L2+4 L8+4 L2+8             lines still held: 3 FH
            //   L40 L41 L42 L43            one scattered, then 3 FA (+1)
            //   L60 L59                    L60 is L40 + 20 rows, then 1 FA
            //   L100 L120 L140 L160        one scattered, then 3 FV (+640)
            //   L160+4 L160+8              2 FH
            //   L300 L7                    two scattered
            //   L140                       four fetches ago, so still held
            //   L500 L600 L700             three scattered, evicting L140
            //   L140 L300                  thrown away, remembered: 2 FR
            // The classes a miss can fall in depend on how many lines the
            // buffer holds, so the counts are modelled at the check rather
            // than written here; the sequence is sized for the four-line
            // buffer, where it gives FL 25, FH 6, FR 2, FA 4, FV 4. Earlier
            // phases leave lines in the buffer, but they are 256 lines away
            // and match nothing here.
            emit(p, I_LUI  (T5, 16'hA003));                       p += 4;
            emit(p, I_ORI  (T5, T5, 16'h4000));                   p += 4;
            emit(p, I_LW   (T4, T5, 16'h0000));                   p += 4;  // L0
            emit(p, I_SW   (R0, T3, 16'h0170));                   p += 4;  // window opens
            begin
                fbc_off = '{2*32, 8*32, 2*32+4, 8*32+4, 2*32+8,
                            40*32, 41*32, 42*32, 43*32,
                            60*32, 59*32,
                            100*32, 120*32, 140*32, 160*32,
                            160*32+4, 160*32+8,
                            300*32, 7*32,
                            140*32,
                            500*32, 600*32, 700*32,
                            140*32, 300*32};
                foreach (fbc_off[i]) begin
                    emit(p, I_LW(T4, T5, 16'(fbc_off[i])));       p += 4;
                end
            end
            emit(p, I_SW   (R0, T3, 16'h0174));                   p += 4;  // window closes

            // Narrow uncached stores (markers 0x190 / 0x194). An sh or sb to
            // SDRAM covers part of its burst; that used to go out with the
            // rest masked off by DQM, which this board ignores, so the bridge
            // now reads, merges and writes back. Proving that needs no
            // knowledge of byte order: run the SAME sequence against a CACHED
            // line, which merges inside the cache and never asks the device
            // to mask anything, and require the two to read back identical.
            // NS counts the uncached narrow stores - four here.
            emit(p, I_SW   (R0, T3, 16'h0190));                   p += 4;  // window opens
            emit(p, I_LUI  (T5, NS_CACHED[31:16]));               p += 4;
            emit(p, I_ORI  (T5, T5, NS_CACHED[15:0]));            p += 4;
            emit(p, I_LUI  (T6, NS_UNCACHED[31:16]));             p += 4;
            emit(p, I_ORI  (T6, T6, NS_UNCACHED[15:0]));          p += 4;
            begin
                // {opcode, offset, value} - the same store to each base.
                logic [5:0] ops [0:5];
                logic [15:0] offs [0:5];
                logic [15:0] vals [0:5];
                ops  = '{OP_SW, OP_SW, OP_SH, OP_SB, OP_SH, OP_SB};
                offs = '{16'd0, 16'd4, 16'd2, 16'd1, 16'd6, 16'd4};
                vals = '{16'h1234, 16'h5678, 16'h00ab, 16'h00cd, 16'h00ef, 16'h0099};
                for (int i = 0; i < 6; i = i + 1) begin
                    emit(p, I_ADDIU(T4, R0, vals[i]));            p += 4;
                    emit(p, I_MEM(ops[i], T4, T5, offs[i]));      p += 4;
                    emit(p, I_MEM(ops[i], T4, T6, offs[i]));      p += 4;
                end
            end
            emit(p, I_MEM  (OP_LD, T4, T5, 16'd0));               p += 4;  // cached
            emit(p, I_MEM  (OP_LD, T7, T6, 16'd0));               p += 4;  // uncached
            emit(p, I_MEM  (OP_SD, T4, T3, 16'h0198));            p += 4;
            emit(p, I_MEM  (OP_SD, T7, T3, 16'h01A0));            p += 4;
            emit(p, I_SW   (R0, T3, 16'h0194));                   p += 4;  // window closes

            // Framebuffer stress (markers 0x1A8 / 0x1AC, reports 0x1B0).
            // Random framebuffer loads and stores of every width over
            // FBS_LINES contiguous lines - more than the buffer's four - so
            // lines are evicted constantly, read-aheads land while other
            // loads are waiting, and stores race them. Every earlier
            // framebuffer phase is a fixed pattern a buffer bug can miss: the
            // sequential walk never makes the round-robin victim the line in
            // use, and on hardware exactly that served wrong pixels.
            //
            // The race it hunts is a cycle or two wide, so one pass of
            // accesses rarely lines it up. The same FBS_OPS accesses run
            // FBS_PASSES times, with a delay loop between passes that changes
            // length each time: every pass starts with a different buffer and
            // lands every read-ahead at a different point against the loads.
            // The byte model replays the passes, and each pass reports its
            // running sum.
            begin
                logic [63:0] t2v, t5v, sum, v;
                int          l, q, kind, r, outer;
                logic [5:0]  op;
                logic [15:0] off;
                logic [31:0] a;
                int          fk [$];
                logic [15:0] foff [$];
                logic [15:0] fimm [$];
                t5v = sext32(FBS_BASE);
                t2v = 64'd0;
                sum = 64'd0;
                emit(p, I_LUI  (T5, FBS_BASE[31:16]));            p += 4;
                emit(p, I_ORI  (T5, T5, FBS_BASE[15:0]));         p += 4;
                emit(p, I_ADDIU(T7, R0, 16'h0000));               p += 4;
                emit(p, I_ADDIU(T2, R0, 16'h0000));               p += 4;
                for (int ll = 0; ll < FBS_LINES; ll = ll + 1)
                    for (int qq = 0; qq < 4; qq = qq + 1) begin
                        logic [15:0] imm;
                        imm = 16'(str_next() & 32'h7FFF);
                        emit(p, I_ADDIU(T2, T2, imm));                 p += 4;
                        emit(p, I_DADDU(T2, T2, T5));                  p += 4;
                        emit(p, I_MEM  (OP_SD, T2, T5, 16'(ll * 32 + qq * 8))); p += 4;
                        t2v = sext32(t2v[31:0] + {16'd0, imm}) + t5v;
                        skp_write(FBS_BASE + ll * 32 + qq * 8, t2v, 8);
                    end
                emit(p, I_ADDIU(T6, R0, 16'(FBS_PASSES)));        p += 4;
                emit(p, I_SW   (R0, T3, 16'h01A8));               p += 4;  // window opens
                outer = p;
                for (int i = 0; i < FBS_OPS; i = i + 1) begin
                    l = str_next() % FBS_LINES;
                    q = str_next() % 4;
                    r = str_next() % 100;
                    kind = (r < 12) ? 0 : (r < 22) ? 1 : (r < 32) ? 2 : (r < 40) ? 3 :
                           (r < 58) ? 4 : (r < 72) ? 5 : (r < 80) ? 6 : (r < 90) ? 7 : 8;
                    fbs_counts[kind] = fbs_counts[kind] + FBS_PASSES;
                    case (kind)
                        0: begin op = OP_SD;  off = 16'(q * 8); end
                        1: begin op = OP_SW;  off = 16'(q * 8 + 4 * (str_next() % 2)); end
                        2: begin op = OP_SH;  off = 16'(q * 8 + 2 * (str_next() % 4)); end
                        3: begin op = OP_SB;  off = 16'(q * 8 + (str_next() % 8)); end
                        4: begin op = OP_LD;  off = 16'(q * 8); end
                        5: begin op = OP_LW;  off = 16'(q * 8 + 4 * (str_next() % 2)); end
                        6: begin op = 6'h27;  off = 16'(q * 8 + 4 * (str_next() % 2)); end  // LWU
                        7: begin op = OP_LH;  off = 16'(q * 8 + 2 * (str_next() % 4)); end
                        default: begin op = OP_LB; off = 16'(q * 8 + (str_next() % 8)); end
                    endcase
                    off = off + 16'(l * 32);
                    fk.push_back(kind);
                    foff.push_back(off);
                    if (kind <= 3) begin
                        logic [15:0] imm;
                        imm = 16'(str_next() & 32'h7FFF);
                        fimm.push_back(imm);
                        emit(p, I_ADDIU(T2, T2, imm));                 p += 4;
                        emit(p, I_DADDU(T2, T2, T5));                  p += 4;
                        emit(p, I_MEM  (op, T2, T5, off));             p += 4;
                    end else begin
                        fimm.push_back(16'd0);
                        emit(p, I_MEM  (op, T4, T5, off));             p += 4;
                        emit(p, I_DADDU(T7, T7, T4));                  p += 4;
                    end
                    // One independent instruction a quarter of the time.
                    if ((str_next() % 4) == 0) begin
                        emit(p, I_ADDIU(T1, T1, 16'h0001));            p += 4;
                    end
                end
                emit(p, I_MEM  (OP_SD, T7, T3, 16'h01B0));        p += 4;
                // A delay of T6 + 1 iterations, different for every pass.
                // The branch delay slot is a nop.
                begin
                    int dly;
                    emit(p, I_ADDIU(T0, T6, 16'h0001));           p += 4;
                    dly = p;
                    emit(p, I_ADDIU(T0, T0, 16'hffff));           p += 4;
                    emit(p, I_BNE  (T0, R0, 16'((dly - (p + 4)) >>> 2))); p += 4;
                    emit(p, 32'h0000_0000);                       p += 4;
                end
                emit(p, I_ADDIU(T6, T6, 16'hffff));               p += 4;
                emit(p, I_BNE  (T6, R0, 16'((outer - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                // The model: the same accesses, FBS_PASSES times.
                for (int pass = 0; pass < FBS_PASSES; pass = pass + 1) begin
                    foreach (fk[i]) begin
                        a = FBS_BASE + {16'd0, foff[i]};
                        kind = fk[i];
                        if (kind <= 3) begin
                            t2v = sext32(t2v[31:0] + {16'd0, fimm[i]}) + t5v;
                            skp_write(a, t2v, (kind == 0) ? 8 : (kind == 1) ? 4 : (kind == 2) ? 2 : 1);
                        end else begin
                            case (kind)
                                4: v = skp_read(a, 8);
                                5: begin v = skp_read(a, 4); v = sext32(v[31:0]); end
                                6: v = skp_read(a, 4);
                                7: begin v = skp_read(a, 2); v = {{48{v[15]}}, v[15:0]}; end
                                default: begin v = skp_read(a, 1); v = {{56{v[7]}}, v[7:0]}; end
                            endcase
                            sum = sum + v;
                        end
                    end
                    fbs_expect.push_back(sum);
                end
                emit(p, I_SW   (R0, T3, 16'h01AC));               p += 4;  // window closes
            end

            // Pinned victim (markers 0x1C0 / 0x1C4, reports 0x1B8). A
            // directed test of the race that put wrong pixels on the KI2
            // title screen, which random traffic did not line up in 960
            // accesses. When a read-ahead lands it replaces the round-robin
            // victim - and that can be the very line a load is being answered
            // from. Built so the victim IS that line:
            //   L       fetch (way r), read-ahead brings L+1 (way r+1)
            //   M = L+8 fetch (way r+2), read-ahead brings M+1 (way r+3)
            // Four fills, so the round-robin pointer is back on L's way.
            //   L+1     first touch: asks for L+2, whose victim is L's way
            //   L x24   back to back while L+2 is in flight
            // A load of L waiting to be answered as L+2 lands must still get
            // L. Eight passes, fresh lines each time, with a delay before the
            // run that shrinks every pass so the landing moves against the
            // loads. Each pass reports its sum: 24 times L's first qword,
            // which is the pass's base address, stored there first.
            begin
                int outer, dly, ham;
                emit(p, I_LUI  (T5, PV_BASE[31:16]));             p += 4;
                emit(p, I_ORI  (T5, T5, PV_BASE[15:0]));          p += 4;
                emit(p, I_ADDIU(T6, R0, 16'(PV_PASSES)));         p += 4;
                emit(p, I_SW   (R0, T3, 16'h01C0));               p += 4;  // window opens
                outer = p;
                emit(p, I_MEM  (OP_SD, T5, T5, 16'd0));           p += 4;  // L = base
                emit(p, I_ADDIU(T7, R0, 16'h0000));               p += 4;
                emit(p, I_MEM  (OP_LD, T4, T5, 16'd0));           p += 4;  // L
                emit(p, I_ADDIU(T0, R0, 16'd80));                 p += 4;
                dly = p;
                emit(p, I_ADDIU(T0, T0, 16'hffff));               p += 4;
                emit(p, I_BNE  (T0, R0, 16'((dly - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                emit(p, I_MEM  (OP_LD, T4, T5, 16'd256));         p += 4;  // M
                emit(p, I_ADDIU(T0, R0, 16'd80));                 p += 4;
                dly = p;
                emit(p, I_ADDIU(T0, T0, 16'hffff));               p += 4;
                emit(p, I_BNE  (T0, R0, 16'((dly - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                emit(p, I_MEM  (OP_LD, T4, T5, 16'd32));          p += 4;  // L+1
                emit(p, I_ADDIU(T0, T6, 16'h0000));               p += 4;
                dly = p;
                emit(p, I_ADDIU(T0, T0, 16'hffff));               p += 4;
                emit(p, I_BNE  (T0, R0, 16'((dly - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                emit(p, I_ADDIU(T1, R0, 16'd24));                 p += 4;
                ham = p;
                emit(p, I_MEM  (OP_LD, T4, T5, 16'd0));           p += 4;  // L
                emit(p, I_DADDU(T7, T7, T4));                     p += 4;
                emit(p, I_ADDIU(T1, T1, 16'hffff));               p += 4;
                emit(p, I_BNE  (T1, R0, 16'((ham - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                emit(p, I_MEM  (OP_SD, T7, T3, 16'h01B8));        p += 4;
                emit(p, I_ADDIU(T5, T5, 16'h0200));               p += 4;  // 16 lines on
                emit(p, I_ADDIU(T6, T6, 16'hffff));               p += 4;
                emit(p, I_BNE  (T6, R0, 16'((outer - (p + 4)) >>> 2))); p += 4;
                emit(p, 32'h0000_0000);                           p += 4;
                emit(p, I_SW   (R0, T3, 16'h01C4));               p += 4;  // window closes
                for (int i = 0; i < PV_PASSES; i = i + 1)
                    pv_expect.push_back(64'(24) * sext32(PV_BASE + i * 32'h200));
            end

            // Data cache stress (markers 0x178 / 0x17C). STR_OPS random
            // accesses to three sets (0x50-0x52) of five tags each - fifteen
            // lines contending for six cache lines - so nearly every access
            // shuffles lines in and out: skipped fills, fills of absent qwords,
            // masked write-backs, the store-then-load hazard (no filler), and
            // framebuffer loads in between, which share the response path. The
            // lines' SDRAM is seeded with random bytes before the CPU starts
            // (sdram_poke), so every load has a known answer. Loads are summed
            // into t7 and the sum is reported every STR_EVERY accesses (0x180),
            // so a wrong answer is placed to within that many. At the end two
            // other tags per set evict every line, and all 60 qwords are read
            // back through KSEG1, from SDRAM, into one more report (0x188).
            begin
                logic [63:0] t2v, t5v, sum, v;
                int unsigned r;
                int          s, t, q, kind, off;
                logic [5:0]  op;
                // Seed SDRAM: the five tags in play and the two that evict.
                for (int tt = -3; tt <= 3; tt = tt + 1)
                    for (int ss = 0; ss < 3; ss = ss + 1)
                        for (int b = 0; b < 32; b = b + 1) begin
                            logic [7:0] sb;
                            sb = 8'(str_next());
                            skp_mem [STR_PHYS + tt * 32'h2000 + ss * 32 + b] = sb;
                            str_seed[STR_PHYS + tt * 32'h2000 + ss * 32 + b] = sb;
                        end
                t5v = sext32(STR_BASE0);
                t2v = 64'd0;
                sum = 64'd0;
                emit(p, I_LUI  (T5, STR_BASE0[31:16]));           p += 4;
                emit(p, I_ORI  (T5, T5, STR_BASE0[15:0]));        p += 4;
                emit(p, I_ADDIU(T7, R0, 16'h0000));               p += 4;
                emit(p, I_ADDIU(T2, R0, 16'h0000));               p += 4;
                emit(p, I_SW   (R0, T3, 16'h0178));               p += 4;  // window opens
                for (int i = 0; i < STR_OPS; i = i + 1) begin
                    logic [31:0] a;
                    s = str_next() % 3;
                    t = int'(str_next() % 5) - 2;
                    q = str_next() % 4;
                    r = str_next() % 100;
                    kind = (r < 28) ? 0 : (r < 36) ? 1 : (r < 41) ? 2 : (r < 46) ? 3 :
                           (r < 71) ? 4 : (r < 79) ? 5 : (r < 84) ? 6 : (r < 89) ? 7 :
                           (r < 94) ? 8 : 9;
                    str_counts[kind] = str_counts[kind] + 1;
                    case (kind)
                        0: begin op = OP_SD;  off = q * 8; end
                        1: begin op = OP_SW;  off = q * 8 + 4 * (str_next() % 2); end
                        2: begin op = OP_SH;  off = q * 8 + 2 * (str_next() % 4); end
                        3: begin op = OP_SB;  off = q * 8 + (str_next() % 8); end
                        4: begin op = OP_LD;  off = q * 8; end
                        5: begin op = OP_LW;  off = q * 8 + 4 * (str_next() % 2); end
                        6: begin op = 6'h27;  off = q * 8 + 4 * (str_next() % 2); end  // LWU
                        7: begin op = OP_LH;  off = q * 8 + 2 * (str_next() % 4); end
                        8: begin op = OP_LB;  off = q * 8 + (str_next() % 8); end
                        default: begin op = OP_LW; off = 0; end                       // FB
                    endcase
                    off = off + t * 32'h2000 + s * 32;
                    a = STR_BASE0 + off;
                    if (strtrace != 0 && i < strtrace)
                        $display("  str op %0d: kind %0d at %08h (off %04h) - model before: %016h",
                                 i, kind, a, 16'(off), skp_read({a[31:3], 3'b000}, 8));
                    if (kind == 9) begin
                        // A framebuffer load whose answer is not checked.
                        emit(p, I_LUI (T0, 16'hA003));                         p += 4;
                        emit(p, I_MEM (OP_LW, T0, T0, 16'(32'h6000 + (str_next() % 64) * 32))); p += 4;
                    end else if (kind <= 3) begin
                        logic [15:0] imm;
                        imm = 16'(str_next() & 32'h7FFF);
                        emit(p, I_ADDIU(T2, T2, imm));                         p += 4;
                        emit(p, I_DADDU(T2, T2, T5));                          p += 4;
                        emit(p, I_MEM  (op, T2, T5, 16'(off)));                p += 4;
                        t2v = sext32(t2v[31:0] + {16'd0, imm}) + t5v;
                        skp_write(a, t2v, (kind == 0) ? 8 : (kind == 1) ? 4 : (kind == 2) ? 2 : 1);
                        if (strtrace != 0 && i < strtrace)
                            $display("  str op %0d:   stores %016h", i, t2v);
                    end else begin
                        emit(p, I_MEM  (op, T4, T5, 16'(off)));                p += 4;
                        emit(p, I_DADDU(T7, T7, T4));                          p += 4;
                        str_load_addr.push_back(a);
                        str_load_kind.push_back(kind);
                        str_load_raw.push_back(skp_read({a[31:3], 3'b000}, 8) >> (8 * a[2:0]));
                        case (kind)
                            4: v = skp_read(a, 8);
                            5: begin v = skp_read(a, 4); v = sext32(v[31:0]); end
                            6: v = skp_read(a, 4);
                            7: begin v = skp_read(a, 2); v = {{48{v[15]}}, v[15:0]}; end
                            default: begin v = skp_read(a, 1); v = {{56{v[7]}}, v[7:0]}; end
                        endcase
                        sum = sum + v;
                    end
                    r = str_next() % 4;
                    if (r <= 1) begin
                        emit(p, I_ADDIU(T1, T1, 16'h0001));                    p += 4;
                    end
                    if (r == 0) begin
                        emit(p, I_ADDIU(T1, T1, 16'h0001));                    p += 4;
                    end
                    if ((i % STR_EVERY) == STR_EVERY - 1) begin
                        emit(p, I_MEM(OP_SD, T7, T3, 16'h0180));               p += 4;
                        str_expect.push_back(sum);
                    end
                end
                // Two more tags per set evict whatever is resident.
                for (int ss = 0; ss < 3; ss = ss + 1)
                    for (int k = 0; k < 2; k = k + 1) begin
                        int ft;
                        ft = (k == 0) ? -3 : 3;
                        emit(p, I_MEM  (OP_LD, T4, T5, 16'(ft * 32'h2000 + ss * 32))); p += 4;
                        emit(p, I_ADDIU(T1, T1, 16'h0001));                    p += 4;
                        emit(p, I_ADDIU(T1, T1, 16'h0001));                    p += 4;
                    end
                emit(p, I_SW   (R0, T3, 16'h017C));               p += 4;  // window closes
                // Read back all 60 qwords from SDRAM: tags -2..2 (0x2000 apart),
                // twelve consecutive qwords each.
                emit(p, I_LUI  (T6, STR_BASE1[31:16]));           p += 4;
                emit(p, I_ORI  (T6, T6, STR_BASE1[15:0]));        p += 4;
                emit(p, I_LUI  (T0, 16'hFFFF));                   p += 4;
                emit(p, I_ORI  (T0, T0, 16'hC000));               p += 4;  // -0x4000
                emit(p, I_DADDU(T6, T6, T0));                     p += 4;  // tag -2
                emit(p, I_ADDIU(T7, R0, 16'h0000));               p += 4;
                emit(p, I_ADDIU(T1, R0, 16'd5));                  p += 4;
                begin
                    int outer, inner;
                    outer = p;
                    emit(p, I_ADDIU(T0, T6, 16'h0000));           p += 4;
                    emit(p, I_ADDIU(T2, R0, 16'd12));             p += 4;
                    inner = p;
                    emit(p, I_MEM  (OP_LD, T4, T0, 16'h0000));    p += 4;
                    emit(p, I_DADDU(T7, T7, T4));                 p += 4;
                    emit(p, I_ADDIU(T0, T0, 16'd8));              p += 4;
                    emit(p, I_ADDIU(T2, T2, 16'hffff));           p += 4;
                    emit(p, I_BNE  (T2, R0, 16'((inner - (p + 4)) >>> 2))); p += 4;
                    emit(p, 32'h0000_0000);                       p += 4;
                    emit(p, I_ADDIU(T6, T6, 16'h2000));           p += 4;
                    emit(p, I_ADDIU(T1, T1, 16'hffff));           p += 4;
                    emit(p, I_BNE  (T1, R0, 16'((outer - (p + 4)) >>> 2))); p += 4;
                    emit(p, 32'h0000_0000);                       p += 4;
                end
                emit(p, I_MEM  (OP_SD, T7, T3, 16'h0188));        p += 4;
                sum = 64'd0;
                for (int tt = -2; tt <= 2; tt = tt + 1)
                    for (int b = 0; b < 96; b = b + 8)
                        sum = sum + skp_read(STR_BASE1 + tt * 32'h2000 + b, 8);
                str_expect.push_back(sum);
            end

            // Park.
            halt_pc = p;
            emit(p, I_BEQ  (R0, R0, 16'hffff));    p += 4;
            emit(p, 32'h0000_0000);
            // The bridge's boot line buffer holds the first 8 KB.
            if (p + 4 > 8 * 1024) begin
                $error("the program is %0d bytes, past the 8 KB the boot buffer holds", p + 4);
                $fatal(1);
            end
        end
    endtask

    // ------------------------------------------------------ measurement
    //
    // Counted in clk_93 - CPU cycles - because that is the unit every other
    // measurement in this project uses.
    longint cpu_cycles = 0;
    always @(posedge clk_93) if (!cpu_reset) cpu_cycles <= cpu_cycles + 1;

    longint mark_start = 0, mark_end = 0;
    integer marks_seen = 0;
    longint retired_at_start = 0, retired_at_end = 0;

    // The markers are uncached stores, so they appear on the CPU bus. Watch
    // for the request rather than the completion: the request edge is what
    // brackets the loop.
    logic cpu_request_d = 1'b0;
    // The store-then-load hazard's report, and proof the path was exercised.
    logic [63:0] hazard_value = 64'd0;
    logic        hazard_seen  = 1'b0;
    logic [63:0] hazard2_value = 64'd0;
    logic        hazard2_seen  = 1'b0;
    integer      readwait_at_h1 = 0, readwait_at_h2 = 0;
    integer      readwait_cycles = 0;
    always @(posedge clk_93)
        if (cpu.core.icpu_datacache.debug_state == 4'd3)
            readwait_cycles <= readwait_cycles + 1;

    // The two-lines-one-set loop: misses and WAYFIX cycles inside its window,
    // bracketed where each marker store is ACCEPTED at stage 4 (see the
    // census below for why accepted rather than offered), and its sum.
    // Index 0 is the alternating loop, index 1 the predicted-right one.
    integer twoway_misses [0:1] = '{0, 0}, twoway_wayfix [0:1] = '{0, 0};
    longint twoway_cycles [0:1] = '{0, 0};
    integer twoway_marks = 0;
    integer wayfix_total = 0;
    logic   twoway_open [0:1] = '{1'b0, 1'b0};
    logic [63:0] twoway_sum [0:1] = '{64'd0, 64'd0};
    logic        twoway_seen [0:1] = '{1'b0, 1'b0};
    always @(posedge clk_93) if (!cpu_reset) begin
        if (cpu.core.icpu_datacache.perf_way_slow) wayfix_total <= wayfix_total + 1;
        for (int w = 0; w < 2; w = w + 1) if (twoway_open[w]) begin
            twoway_cycles[w] <= twoway_cycles[w] + 1;
            if (cpu.core.icpu_datacache.perf_miss)     twoway_misses[w] <= twoway_misses[w] + 1;
            if (cpu.core.icpu_datacache.perf_way_slow) twoway_wayfix[w] <= twoway_wayfix[w] + 1;
        end
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            for (int w = 0; w < 2; w = w + 1) begin
                if (cpu.core.mem4_address == (MARK_PHYS + 32'h108 + 12 * w)) begin
                    twoway_open[w] <= 1'b1;
                    twoway_marks   <= twoway_marks + 1;
                end
                if (cpu.core.mem4_address == (MARK_PHYS + 32'h10C + 12 * w)) begin
                    twoway_open[w] <= 1'b0;
                    twoway_marks   <= twoway_marks + 1;
                end
            end
        end
    end

    always @(posedge clk_1x) begin
        cpu_request_d <= cpu_request;
        for (int w = 0; w < 2; w = w + 1)
            if (cpu_request && !cpu_request_d && !cpu_rnw &&
                cpu_address == (MARK_PHYS + 32'h110 + 12 * w)) begin
                twoway_sum[w]  <= cpu_write_data;
                twoway_seen[w] <= 1'b1;
            end
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h100)) begin
            hazard_value   <= cpu_write_data;
            hazard_seen    <= 1'b1;
            readwait_at_h1 <= readwait_cycles;
        end
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h104)) begin
            hazard2_value  <= cpu_write_data;
            hazard2_seen   <= 1'b1;
            readwait_at_h2 <= readwait_cycles;
        end
        if (cpu_request && !cpu_request_d && !cpu_rnw) begin
            if (cpu_address == MARK_PHYS) begin
                mark_start       <= cpu_cycles;
                retired_at_start <= debug_retired;
                marks_seen       <= marks_seen + 1;
            end
            if (cpu_address == (MARK_PHYS + 4)) begin
                mark_end       <= cpu_cycles;
                retired_at_end <= debug_retired;
                marks_seen     <= marks_seen + 1;
            end
        end
    end

    // Framebuffer line buffer windows: RMW (index 0) and MIXED (index 1),
    // bracketed where their marker stores are ACCEPTED at stage 4.
    //
    // +fblbuf=0 says the CPU was elaborated with the buffer off
    // (-g/tb_ki_perfbench/cpu/FBLINE_BUFFER=0), so the checks expect no hits.
    //
    // Every framebuffer load inside the windows is hashed, in order, at its
    // completion: the answer in mem_finished_dataRot and the address it was
    // for. That answer is what the rest of stage 4 turns into a register
    // value, the same logic either way, so the buffer is correct if and only
    // if the hash matches the unbuffered run's. tools/run_perfbench.ps1
    // compares the two.
    int     fblbuf = 1;
    integer fbl_marks = 0;
    logic   fbl_open [0:1] = '{1'b0, 1'b0};
    longint fbl_cycles [0:1] = '{0, 0};
    longint fbl_uf [0:1] = '{0, 0};
    integer fbl_hits [0:1] = '{0, 0};
    integer fbl_fetches [0:1] = '{0, 0};
    integer fbl_pf [0:1] = '{0, 0};
    integer fbl_loads [0:1] = '{0, 0};
    logic [63:0] fbl_hash = 64'hcbf2_9ce4_8422_2325;   // FNV-1a offset basis
    logic   fbl_hash_unknown = 1'b0;
    logic [63:0] fbl_mix_sum = 64'd0;
    logic        fbl_mix_seen = 1'b0;
    wire fb_load_done = cpu.core.stall4 && !cpu.core.writeback_UseCache &&
                        cpu.core.mem_finished_read && cpu.core.perf_st4_read &&
                        !cpu.core.writebackMemWrite &&
                        (cpu.core.perf_st4_region == 2'b01);
    // A framebuffer line fetch entering the FIFO, and which kind it is. Only
    // one is ever outstanding (cpu.vhd asserts that), so a fetch accepted
    // while the read-ahead is busy IS the read-ahead.
    wire fbl_fetch_issued = cpu.core.writefifo_wr_accept && cpu.core.writefifo_Din[117];
    wire fbl_pf_issued    = fbl_fetch_issued && cpu.core.fbl_pf_busy;
    wire fbl_dem_issued   = fbl_fetch_issued && !cpu.core.fbl_pf_busy;

    function automatic logic [63:0] fnv(input logic [63:0] h, input logic [63:0] v);
        fnv = (h ^ v) * 64'h0000_0100_0000_01b3;
    endfunction

    always @(posedge clk_93) if (!cpu_reset) begin
        for (int w = 0; w < 2; w = w + 1) if (fbl_open[w]) begin
            fbl_cycles[w] <= fbl_cycles[w] + 1;
            if (cpu.core.perf_uc_fb) fbl_uf[w]      <= fbl_uf[w] + 1;
            if (cpu.core.perf_fb_hit) fbl_hits[w]   <= fbl_hits[w] + 1;
            if (fbl_dem_issued)      fbl_fetches[w] <= fbl_fetches[w] + 1;
            if (fbl_pf_issued)       fbl_pf[w]      <= fbl_pf[w] + 1;
            if (fb_load_done)        fbl_loads[w]   <= fbl_loads[w] + 1;
        end
        if (fb_load_done && (fbl_open[0] || fbl_open[1])) begin
            if ($isunknown(cpu.core.mem_finished_dataRot)) fbl_hash_unknown <= 1'b1;
            fbl_hash <= fnv(fnv(fbl_hash, cpu.core.mem_finished_dataRot),
                            {32'd0, cpu.core.writebackReadAddress});
        end
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            for (int w = 0; w < 2; w = w + 1) begin
                if (cpu.core.mem4_address == (MARK_PHYS + 32'h120 + 8 * w)) begin
                    fbl_open[w] <= 1'b1;
                    fbl_marks   <= fbl_marks + 1;
                end
                if (cpu.core.mem4_address == (MARK_PHYS + 32'h124 + 8 * w)) begin
                    fbl_open[w] <= 1'b0;
                    fbl_marks   <= fbl_marks + 1;
                end
            end
        end
    end

    always @(posedge clk_1x)
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h130)) begin
            fbl_mix_sum  <= cpu_write_data;
            fbl_mix_seen <= 1'b1;
        end

    // Fill-phase census, straight off cpu_datacache's own partition. These
    // are the F1/F2/F3 fields from the hardware Perf page, counted here per
    // run instead of per frame.
    longint f1_cycles = 0, f2_cycles = 0, f3_cycles = 0, fill_cycles = 0;
    logic   measuring = 1'b0;
    always @(posedge clk_93) if (measuring) begin
        if (cpu.core.icpu_datacache.perf_fill_wait) f1_cycles <= f1_cycles + 1;
        if (cpu.core.icpu_datacache.perf_fill_data) f2_cycles <= f2_cycles + 1;
        if (cpu.core.icpu_datacache.perf_fill_hold) f3_cycles <= f3_cycles + 1;
        if (cpu.core.icpu_datacache.perf_fill_wait ||
            cpu.core.icpu_datacache.perf_fill_data ||
            cpu.core.icpu_datacache.perf_fill_hold) fill_cycles <= fill_cycles + 1;
    end

    // Anatomy of a dirty miss. F1 - the wait for the fill's first beat - holds
    // the write-back's cost as well as the fill's own latency.
    //
    // wbq splits F1 by datacache_wb_busy and reads 0.0: by the time the cache
    // is in FILL the STAGING queue is already drained, so the staging queue is
    // not where a dirty miss loses its time. That is the point of keeping a
    // counter that reads zero here - it rules a suspect out.
    //
    // The serialization is downstream of it, in the clk93 <-> clk1x mailbox,
    // which carries ONE transaction at a time: cdc_busy and cdc_txns measure
    // it, and four beats cross it four times before the fill's request can.
    longint wbq_cycles = 0, f1_free_cycles = 0, cdc_busy_cycles = 0;
    integer cdc_txns = 0;
    logic   cdc_req_d = 1'b0;
    always @(posedge clk_93) begin
        cdc_req_d <= cpu.core.write_cdc_req_93;
        if (measuring) begin
            if (cpu.core.icpu_datacache.perf_fill_wait &&  cpu.core.datacache_wb_busy)
                wbq_cycles <= wbq_cycles + 1;
            if (cpu.core.icpu_datacache.perf_fill_wait && !cpu.core.datacache_wb_busy)
                f1_free_cycles <= f1_free_cycles + 1;
            if (cpu.core.write_cdc_busy_93) cdc_busy_cycles <= cdc_busy_cycles + 1;
            if (cpu.core.write_cdc_req_93 !== cdc_req_d) cdc_txns <= cdc_txns + 1;
        end
    end

    // Timeline of a D-cache miss, hop by hop, from the IDLE branch that decides
    // the miss (perf_miss) to the cycle stage 4 is released. Each event below
    // records the CPU cycle of its FIRST occurrence in the current miss, in
    // its own clock domain's block, keyed by miss_id so neither domain writes
    // the other's variables. At the release, each event seen in this miss adds
    // its arrival time to a running sum; the report sorts events by mean
    // arrival, so the gaps between consecutive rows partition the miss.
    //
    // Only misses inside the measured walk count. Events 8-12, 14, 16 and 17
    // belong to a dirty victim's write-back and only fire with +dirty=1.
    localparam int AN_N = 24;
    string  an_name [0:AN_N-1] = '{
        "cache enters FILL",                        //  0 clk93
        "ram_request to the scheduler",             //  1
        "fill request loaded for the write FIFO",   //  2
        "fill request accepted by the write FIFO",  //  3
        "fill request in the write CDC mailbox",    //  4
        "fill completion reaches clk93",            //  5
        "mem_finished_read (the cache's ram_done)", //  6
        "cache sees its first fill beat",           //  7
        "cache enters WRITEBACK1ADDR",              //  8
        "cache enters WRITEBACKDONE",               //  9
        "line write-back loaded for the write FIFO",// 10
        "line write-back accepted by the FIFO",     // 11
        "line write-back in the write CDC mailbox", // 12
        "clk1x takes the fill request",             // 13 clk1x
        "clk1x takes the line write-back",          // 14
        "bridge grants the fill",                   // 15
        "bridge issues the 16-word write burst",    // 16
        "the write burst completes",                // 17
        "bridge issues the fill's SDRAM read",      // 18
        "first SDRAM word of the fill",             // 19
        "bridge hands over fill beat 0",            // 20
        "bridge hands over fill beat 3",            // 21
        "bridge cpu_done for the fill",             // 22
        "clk1x raises the fill's response"          // 23
    };
    longint an_t     [0:AN_N-1];
    longint an_id    [0:AN_N-1] = '{default: -1};
    longint an_sum   [0:AN_N-1] = '{default: 0};
    integer an_cnt   [0:AN_N-1] = '{default: 0};
    longint an_miss_id = 0, an_start = 0;
    logic   an_active = 1'b0;
    longint an_release_sum = 0;
    integer an_misses = 0;
    logic   an_stall4_d = 1'b0;
    logic   an_last_sdram_write = 1'b0;
    wire [AN_N-1:0] an_ev93 = {
        11'd0,                                                                // 23-13: clk1x
        cpu.core.write_cdc_busy_93 && cpu.core.write_cdc_data_93[116],        // 12
        cpu.core.writefifo_wr_accept && cpu.core.writefifo_Din[116],          // 11
        cpu.core.writefifo_issue_pending && cpu.core.writefifo_Din[116],      // 10
        cpu.core.icpu_datacache.debug_state == 4'd11,                         //  9
        cpu.core.icpu_datacache.debug_state == 4'd5,                          //  8
        cpu.core.icpu_datacache.debug_state == 4'd2 &&
            cpu.core.icpu_datacache.fill_beat_seen,                           //  7
        cpu.core.mem_finished_read,                                           //  6
        cpu.core.read_meta_pop && cpu.core.response_cdc_data_1x[64],          //  5
        cpu.core.write_cdc_busy_93 && cpu.core.write_cdc_data_93[107] &&
            cpu.core.write_cdc_data_93[104],                                  //  4
        cpu.core.writefifo_wr_accept && cpu.core.writefifo_Din[107] &&
            cpu.core.writefifo_Din[104],                                      //  3
        cpu.core.writefifo_issue_pending && cpu.core.writefifo_Din[107] &&
            cpu.core.writefifo_Din[104],                                      //  2
        cpu.core.datacache_request,                                           //  1
        cpu.core.icpu_datacache.debug_state == 4'd2                           //  0
    };
    wire [AN_N-1:0] an_ev1x = {
        cpu.core.response_cdc_busy_1x,                                        // 23
        cpu_done && cpu.core.datacache_active,                                // 22
        // dbg_fill_beat counts on the same edge the beat is handed over, so
        // it already reads the NEXT beat's index; the fourth wraps it to 0.
        cpu_cache_data_ready && cpu.core.datacache_active &&
            bridge.dbg_fill_beat == 2'd0,                                     // 21
        cpu_cache_data_ready && cpu.core.datacache_active,                    // 20
        sdram_data_valid && cpu.core.datacache_active,                        // 19
        sdram_read && cpu.core.datacache_active,                              // 18
        sdram_done && an_last_sdram_write,                                    // 17
        sdram_write && sdram_burst == 5'd16,                                  // 16
        cpu_cache_grant && cpu.core.datacache_active,                         // 15
        cpu.core.mem_request && cpu.core.mem_line_write,                      // 14
        cpu.core.mem_request && cpu.core.datacache_active,                    // 13
        13'd0                                                                 // 12-0: clk93
    };
    always @(posedge clk_93) if (!cpu_reset) begin
        an_stall4_d <= cpu.core.stall4;
        if (measuring && !an_active && cpu.core.icpu_datacache.perf_miss) begin
            an_active  <= 1'b1;
            an_start   <= cpu_cycles;
            an_miss_id <= an_miss_id + 1;
        end
        if (an_active) begin
            for (int k = 0; k < 13; k = k + 1)
                if (an_ev93[k] && an_id[k] != an_miss_id) begin
                    an_t[k]  <= cpu_cycles - an_start;
                    an_id[k] <= an_miss_id;
                end
            // Released: stage 4 was stalled on this access and is not now.
            if (an_stall4_d && !cpu.core.stall4 && cpu_cycles > an_start + 1) begin
                an_active      <= 1'b0;
                an_misses      <= an_misses + 1;
                an_release_sum <= an_release_sum + (cpu_cycles - an_start);
                for (int k = 0; k < AN_N; k = k + 1)
                    if (an_id[k] == an_miss_id) begin
                        an_sum[k] <= an_sum[k] + an_t[k];
                        an_cnt[k] <= an_cnt[k] + 1;
                    end
            end
        end
    end
    always @(posedge clk_1x) if (!cpu_reset) begin
        if (sdram_write) an_last_sdram_write <= 1'b1;
        if (sdram_read)  an_last_sdram_write <= 1'b0;
        if (an_active)
            for (int k = 13; k < AN_N; k = k + 1)
                if (an_ev1x[k] && an_id[k] != an_miss_id) begin
                    an_t[k]  <= cpu_cycles - an_start;
                    an_id[k] <= an_miss_id;
                end
    end

    // Fill census off cpu.vhd's taps: WB (write-backs), SF (fills a store
    // caused), SK (store misses that skipped the fill), AF (fills of a resident
    // line's absent qwords) and MC (misses), during the measured walk and in
    // four windows bracketed where their markers are ACCEPTED at stage 4:
    // 0x140 the write-back phase, 0x148 the fill-need phase, 0x150 the
    // skipped-fill phase, 0x160 the store stream (whose cycles are counted
    // too).
    //
    // +skipfill=0 says the CPU was elaborated without DCACHE_SKIP_FILL
    // (-g/tb_ki_perfbench/cpu/DCACHE_SKIP_FILL=0), so the checks expect no SK
    // or AF anywhere.
    int     skipfill = 1;
    int     progress = 0;
    integer cen_walk [0:4] = '{default: 0};
    integer cen [0:3][0:4] = '{default: '{default: 0}};
    logic   cen_open [0:3] = '{default: 1'b0};
    longint cen_cycles [0:3] = '{default: 0};
    integer cen_marks = 0;
    logic [63:0] skp_sum_cached = 64'd0, skp_sum_sdram = 64'd0;
    logic        skp_seen = 1'b0;
    always @(posedge clk_93) if (!cpu_reset) begin
        logic ev [0:4];
        ev[0] = cpu.core.datacache_perf_wb_line;
        ev[1] = cpu.core.datacache_perf_fill_store;
        ev[2] = cpu.core.datacache_perf_fill_skip;
        ev[3] = cpu.core.datacache_perf_fill_absent;
        ev[4] = cpu.core.datacache_perf_miss;
        if (skipfill == 0 && (ev[2] || ev[3])) begin
            $error("DCACHE_SKIP_FILL is off, but a fill was skipped or an absent qword filled");
            $fatal(1);
        end
        if (ev[3] && !ev[4]) begin
            $error("an absent-qword fill that is not a miss");
            $fatal(1);
        end
        for (int j = 0; j < 5; j = j + 1)
            if (measuring && ev[j]) cen_walk[j] <= cen_walk[j] + 1;
        for (int w = 0; w < 4; w = w + 1) if (cen_open[w]) begin
            cen_cycles[w] <= cen_cycles[w] + 1;
            for (int j = 0; j < 5; j = j + 1)
                if (ev[j]) cen[w][j] <= cen[w][j] + 1;
        end
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            logic [31:0] opens  [0:3];
            opens = '{32'h140, 32'h148, 32'h150, 32'h160};
            for (int w = 0; w < 4; w = w + 1) begin
                if (cpu.core.mem4_address == (MARK_PHYS + opens[w])) begin
                    cen_open[w] <= 1'b1; cen_marks <= cen_marks + 1;
                end
                if (cpu.core.mem4_address == (MARK_PHYS + opens[w] + 4)) begin
                    cen_open[w] <= 1'b0; cen_marks <= cen_marks + 1;
                end
            end
        end
    end
    // The narrow uncached store phase: its two reports, the NS events inside
    // its window, and NS over the whole run.
    logic [63:0] ns_got [$];
    integer      ns_in_window = 0;
    integer      ns_run = 0;
    logic        ns_open = 1'b0;
    integer      ns_marks = 0;
    always @(posedge clk_1x) begin
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            (cpu_address == (MARK_PHYS + 32'h198) ||
             cpu_address == (MARK_PHYS + 32'h1A0)))
            ns_got.push_back(cpu_write_data);
    end
    // The framebuffer stress phase's reports, and the buffer traffic inside
    // its window: hits, demand fetches and read-aheads.
    logic [63:0] fbs_got [$];
    logic [63:0] pv_got [$];
    integer      fbs_marks = 0;
    logic        fbs_open = 1'b0;
    integer      fbs_hits = 0, fbs_fetch = 0, fbs_pf = 0, fbs_loads = 0;
    always @(posedge clk_1x) begin
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h1B0))
            fbs_got.push_back(cpu_write_data);
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h1B8))
            pv_got.push_back(cpu_write_data);
    end
    always @(posedge clk_93) if (!cpu_reset) begin
        if (fbs_open) begin
            if (cpu.core.perf_fb_hit) fbs_hits <= fbs_hits + 1;
            if (cpu.core.perf_fb_load) fbs_loads <= fbs_loads + 1;
            if (cpu.core.writefifo_wr_accept && cpu.core.writefifo_Din[117]) begin
                if (cpu.core.fbl_pf_busy) fbs_pf <= fbs_pf + 1;
                else                      fbs_fetch <= fbs_fetch + 1;
            end
        end
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h1A8)) begin
                fbs_open <= 1'b1; fbs_marks <= fbs_marks + 1;
            end
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h1AC)) begin
                fbs_open <= 1'b0; fbs_marks <= fbs_marks + 1;
            end
        end
    end
    always @(posedge clk_93) if (!cpu_reset) begin
        if (cpu.core.perf_uc_narrow) begin
            ns_run <= ns_run + 1;
            if (ns_open) ns_in_window <= ns_in_window + 1;
        end
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h190)) begin
                ns_open <= 1'b1; ns_marks <= ns_marks + 1;
            end
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h194)) begin
                ns_open <= 1'b0; ns_marks <= ns_marks + 1;
            end
        end
    end

    // Framebuffer load census, off cpu.vhd's taps: FL, FH, FR, FA, NS and UF
    // cycles, in the window 0x170 / 0x174, plus FL and FH over the whole run.
    integer fbc_cnt [0:5] = '{default: 0};
    logic   fbc_open = 1'b0;
    integer fbc_marks = 0;
    integer fbc_run_loads = 0, fbc_run_hits = 0;
    always @(posedge clk_93) if (!cpu_reset) begin
        logic ev [0:5];
        ev[0] = cpu.core.perf_fb_load;
        ev[1] = cpu.core.perf_fb_hit;
        ev[2] = cpu.core.perf_fb_recent;
        ev[3] = cpu.core.perf_fb_adj;
        ev[4] = cpu.core.perf_uc_narrow;
        ev[5] = cpu.core.perf_uc_fb;
        if (ev[0]) fbc_run_loads <= fbc_run_loads + 1;
        if (ev[1]) fbc_run_hits  <= fbc_run_hits + 1;
        if (fbc_open)
            for (int j = 0; j < 6; j = j + 1)
                if (ev[j]) fbc_cnt[j] <= fbc_cnt[j] + 1;
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h170)) begin
                fbc_open <= 1'b1; fbc_marks <= fbc_marks + 1;
            end
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h174)) begin
                fbc_open <= 1'b0; fbc_marks <= fbc_marks + 1;
            end
        end
    end

    // The stress phase: its reports in order, the fill traffic inside its
    // window, and how many line write-backs the bridge had to hold pending.
    logic [63:0] str_got [$];
    integer      str_cnt [0:3] = '{default: 0};   // SK, AF, WB, MC
    logic        str_open = 1'b0;
    integer      str_marks = 0;
    integer      line_writes_deferred = 0;
    always @(posedge clk_1x) begin
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            (cpu_address == (MARK_PHYS + 32'h180) || cpu_address == (MARK_PHYS + 32'h188)))
            str_got.push_back(cpu_write_data);
        if (cpu_request && cpu_line_write && bridge.video_request && !bridge.video_won_last)
            line_writes_deferred <= line_writes_deferred + 1;
    end
    logic [63:0] str_load_got      [$];
    logic [31:0] str_load_got_addr [$];
    int          str_trace_n = 0;
    always @(posedge clk_93) if (!cpu_reset) begin
        if (strtrace != 0 && str_open && str_trace_n < 3 * strtrace) begin
            if (cpu.core.datacache_writeena && cpu.core.icpu_datacache.debug_state == 4'd0) begin
                $display("  str cpu W %08h be %02h data %016h hit %b skip %b",
                         cpu.core.datacache_addr, cpu.core.executeMemWriteMask,
                         cpu.core.executeMemWriteData, cpu.core.icpu_datacache.read_hit,
                         cpu.core.icpu_datacache.skip_ok);
                str_trace_n <= str_trace_n + 1;
            end
            if (cpu.core.datacache_readdone) begin
                $display("  str cpu R %08h -> %016h", cpu.core.datacache_addr, cpu.core.datacache_data_out);
                str_trace_n <= str_trace_n + 1;
            end
        end
        if (str_open && cpu.core.datacache_readdone) begin
            str_load_got.push_back(cpu.core.datacache_data_out);
            str_load_got_addr.push_back(cpu.core.datacache_addr);
        end
        if (str_open) begin
            if (cpu.core.datacache_perf_fill_skip)   str_cnt[0] <= str_cnt[0] + 1;
            if (cpu.core.datacache_perf_fill_absent) str_cnt[1] <= str_cnt[1] + 1;
            if (cpu.core.datacache_perf_wb_line)     str_cnt[2] <= str_cnt[2] + 1;
            if (cpu.core.datacache_perf_miss)        str_cnt[3] <= str_cnt[3] + 1;
        end
        if (cpu.core.mem4_request && !cpu.core.mem4_rnw && cpu.core.writefifo_mem4_ready) begin
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h178)) begin
                str_open <= 1'b1; str_marks <= str_marks + 1;
            end
            if (cpu.core.mem4_address == (MARK_PHYS + 32'h17C)) begin
                str_open <= 1'b0; str_marks <= str_marks + 1;
            end
        end
    end

    always @(posedge clk_1x) begin
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h158))
            skp_sum_cached <= cpu_write_data;
        if (cpu_request && !cpu_request_d && !cpu_rnw &&
            cpu_address == (MARK_PHYS + 32'h168)) begin
            skp_sum_sdram <= cpu_write_data;
            skp_seen      <= 1'b1;
        end
    end

    integer misses = 0, stride_hits = 0, delta_hits = 0;
    always @(posedge clk_93) begin
        if (measuring && cpu.core.icpu_datacache.perf_miss) misses <= misses + 1;
        if (measuring && cpu.core.icpu_datacache.perf_stride_hit)
            stride_hits <= stride_hits + 1;
        if (measuring && cpu.core.icpu_datacache.perf_delta_hit)
            delta_hits <= delta_hits + 1;
    end

    // Writeback census: cycles in cpu_datacache's WRITEBACK states, and how
    // many victims went out. One rising edge each - a dirty miss goes
    // WRITEBACK -> FILL, so two writebacks are never adjacent.
    longint wb_cycles = 0;
    integer writebacks = 0;
    logic   wb_d = 1'b0;
    always @(posedge clk_93) begin
        wb_d <= cpu.core.icpu_datacache.perf_writeback;
        if (measuring && cpu.core.icpu_datacache.perf_writeback) begin
            wb_cycles <= wb_cycles + 1;
            if (!wb_d) writebacks <= writebacks + 1;
        end
    end

    // Where a writeback beat's time actually goes, counted in clk_1x (the
    // bridge/SDRAM domain, so one count is two CPU cycles). The controller
    // keeps rows open, so the four beats of one line are all row hits and
    // the ACT/tRCD cost applies only to the first. That makes it worth
    // knowing how much of a beat is the controller and how much is the
    // per-transaction handshake before widening any datapath.
    longint wr_txn = 0, wr_txn_cycles = 0, wr_ctrl_cycles = 0;
    logic   wr_active = 1'b0, ctrl_active = 1'b0;
    always @(posedge clk_1x) if (measuring) begin
        if (cpu_request && !cpu_rnw && !wr_active) begin
            wr_active <= 1'b1;
            wr_txn    <= wr_txn + 1;
        end else if (wr_active) begin
            wr_txn_cycles <= wr_txn_cycles + 1;
            if (cpu_done) wr_active <= 1'b0;
        end
        if (sdram_write && !ctrl_active) ctrl_active <= 1'b1;
        else if (ctrl_active) begin
            wr_ctrl_cycles <= wr_ctrl_cycles + 1;
            if (sdram_done) ctrl_active <= 1'b0;
        end
    end

    // Uncached census, straight off cpu.vhd's taps: UW, UF, UI, UB, UM.
    // Checked every cycle to be mutually exclusive and inside stall4-uncached,
    // with anything uncached that matches none of them counted as residual.
    wire uc      = cpu.core.perf_uc;
    wire uc_tap [0:4];
    assign uc_tap[0] = cpu.core.perf_uc_write;
    assign uc_tap[1] = cpu.core.perf_uc_fb;
    assign uc_tap[2] = cpu.core.perf_uc_io;
    assign uc_tap[3] = cpu.core.perf_uc_rom;
    assign uc_tap[4] = cpu.core.perf_uc_ram;
    longint uc_cycles [0:4] = '{default: 0};
    longint uc_snap [0:PHASES][0:4];
    longint uc_residual = 0;
    // FH, the framebuffer line buffer's hit count: one pulse per load it
    // answers. Counted and snapshotted with the census, and required to land
    // inside UF - a hit still holds stage 4 for its two cycles.
    wire    fn_tap = cpu.core.perf_fb_hit;
    longint fn_cycles = 0;
    longint fn_snap [0:PHASES];
    integer phases_seen = 0;
    always @(posedge clk_93) if (!cpu_reset) begin
        if ((uc_tap[0] + uc_tap[1] + uc_tap[2] + uc_tap[3] + uc_tap[4]) > 1) begin
            $error("uncached taps overlap: %b%b%b%b%b",
                   uc_tap[0], uc_tap[1], uc_tap[2], uc_tap[3], uc_tap[4]);
            $fatal(1);
        end
        if ((uc_tap[0] | uc_tap[1] | uc_tap[2] | uc_tap[3] | uc_tap[4]) && !uc) begin
            $error("an uncached tap fired outside stall4-uncached");
            $fatal(1);
        end
        for (int j = 0; j < 5; j = j + 1)
            if (uc_tap[j]) uc_cycles[j] <= uc_cycles[j] + 1;
        if (fn_tap && !uc_tap[1]) begin
            $error("FH fired outside UF - a buffered load still holds stage 4");
            $fatal(1);
        end
        if (fn_tap) fn_cycles <= fn_cycles + 1;
        if (uc && !(uc_tap[0] | uc_tap[1] | uc_tap[2] | uc_tap[3] | uc_tap[4]))
            uc_residual <= uc_residual + 1;
        // Snapshot when a marker is ACCEPTED, not merely offered. A marker the
        // write FIFO refuses is itself a blocked store and stalls stage 4 as
        // UW; those cycles - this one included, hence the +1 - belong before
        // the boundary. The first run caught exactly that: marker 0 follows
        // the walk's END marker, found the FIFO busy for one cycle, and leaked
        // it into the framebuffer phase.
        if (phases_seen <= PHASES && cpu.core.mem4_request && !cpu.core.mem4_rnw &&
            cpu.core.writefifo_mem4_ready &&
            (cpu.core.mem4_address == (PHASE_PHYS + 4 * phases_seen))) begin
            for (int j = 0; j < 5; j = j + 1)
                uc_snap[phases_seen][j] <= uc_cycles[j] + (uc_tap[j] ? 1 : 0);
            fn_snap[phases_seen] <= fn_cycles + (fn_tap ? 1 : 0);
            phases_seen <= phases_seen + 1;
        end
    end

    always @(posedge clk_1x) begin
        if (marks_seen == 1) measuring <= 1'b1;
        if (marks_seen >= 2) measuring <= 1'b0;
    end

    // ------------------------------------------------------------- report
    task automatic report_and_finish;
        real per_miss;
        begin
            $display("");
            $display("tb_ki_perfbench: pad=%0d stride=%0d dirty=%0d, %0d lines walked, %0d D-cache misses",
                     pad, stride, dirty, LINES, misses);
            $display("  loop took %0d CPU cycles, retired %0d instructions",
                     mark_end - mark_start,
                     retired_at_end - retired_at_start);
            if (misses > 0) begin
                per_miss = real'(mark_end - mark_start) / real'(misses);
                $display("  ---> %0.1f CPU cycles per D-cache miss", per_miss);
                $display("  ---> %0.1f CPU cycles per loop iteration",
                         real'(mark_end - mark_start) / real'(LINES));
                $display("  fill phases, cycles per miss:");
                $display("      F1 to first beat   %0.1f",
                         real'(f1_cycles) / real'(misses));
                $display("      F2 beats arriving  %0.1f",
                         real'(f2_cycles) / real'(misses));
                $display("      F3 waiting on done %0.1f",
                         real'(f3_cycles) / real'(misses));
                $display("      WB writeback states %0.1f",
                         real'(wb_cycles) / real'(misses));
                $display("      of F1: %0.1f queued write-back + %0.1f the fill itself",
                         real'(wbq_cycles) / real'(misses),
                         real'(f1_free_cycles) / real'(misses));
                $display("      write CDC: %0.1f cycles busy per miss, %0.2f crossings per miss",
                         real'(cdc_busy_cycles) / real'(misses),
                         real'(cdc_txns) / real'(misses));
                if (wbq_cycles + f1_free_cycles != f1_cycles) begin
                    $error("F1 split summed to %0d but F1 is %0d",
                           wbq_cycles + f1_free_cycles, f1_cycles);
                    $fatal(1);
                end
                $display("  dirty victims written back %0d of %0d",
                         writebacks, misses);
                if (wr_txn > 0) begin
                    $display("  write path: %0d write transactions, CPU cycles each:",
                             wr_txn);
                    $display("      bridge accept to cpu_done %0.1f",
                             2.0 * real'(wr_txn_cycles) / real'(wr_txn));
                    $display("      of which the controller   %0.1f",
                             2.0 * real'(wr_ctrl_cycles) / real'(wr_txn));
                end
                $display("  next-line misses %0d of %0d (%0.0f%%)",
                         stride_hits, misses,
                         100.0 * real'(stride_hits) / real'(misses));
                $display("  repeated-delta misses %0d of %0d (%0.0f%%)",
                         delta_hits, misses,
                         100.0 * real'(delta_hits) / real'(misses));
                if (f1_cycles + f2_cycles + f3_cycles != fill_cycles) begin
                    $error("fill phases summed to %0d but FILL lasted %0d",
                           f1_cycles + f2_cycles + f3_cycles, fill_cycles);
                    $fatal(1);
                end
            end

            // The miss timeline, sorted by mean arrival. "+gap" is the time
            // since the row above, so the gaps partition the miss up to the
            // release.
            if (an_misses > 0) begin
                real    mean [0:AN_N-1];
                int     order [$];
                real    prev;
                for (int k = 0; k < AN_N; k = k + 1)
                    mean[k] = (an_cnt[k] > 0) ? real'(an_sum[k]) / real'(an_cnt[k]) : -1.0;
                for (int k = 0; k < AN_N; k = k + 1) if (an_cnt[k] > 0) order.push_back(k);
                order.sort() with (mean[item]);
                $display("  anatomy of a miss, %0d misses, CPU cycles from the miss decision:", an_misses);
                $display("      %-44s %8s %7s %6s", "event", "mean at", "+gap", "seen");
                prev = 0.0;
                foreach (order[i]) begin
                    $display("      %-44s %8.1f %7.1f %6d", an_name[order[i]], mean[order[i]],
                             mean[order[i]] - prev, an_cnt[order[i]]);
                    prev = mean[order[i]];
                end
                $display("      %-44s %8.1f %7.1f %6d", "stage 4 released",
                         real'(an_release_sum) / real'(an_misses),
                         real'(an_release_sum) / real'(an_misses) - prev, an_misses);
            end

            // The detector must track the stride, not merely count misses.
            // A 32-byte walk is next-line for every miss after the first; any
            // wider stride is next-line for none of them.
            if (stride == 32 && stride_hits < misses - 2) begin
                $error("stride 32 should be next-line throughout, got %0d of %0d",
                       stride_hits, misses);
                $fatal(1);
            end
            if (stride > 32 && stride_hits != 0) begin
                $error("stride %0d is not next-line, but the detector saw %0d",
                       stride, stride_hits);
                $fatal(1);
            end
            // The point of DH: a CONSTANT stride repeats its delta whatever
            // the stride is, so this must be high even where SH reads zero.
            // A detector that just duplicated SH would fail here.
            if (delta_hits < misses - 3) begin
                $error("a constant stride repeats its delta, but DH saw %0d of %0d",
                       delta_hits, misses);
                $fatal(1);
            end

            // The pre-pass must really leave dirty victims, and the clean
            // walk must not - otherwise the comparison measures nothing.
            if (dirty != 0 && writebacks < misses - 2) begin
                $error("dirty=1 should write back a victim on every miss, got %0d of %0d",
                       writebacks, misses);
                $fatal(1);
            end
            if (dirty == 0 && writebacks != 0) begin
                $error("a clean walk wrote back %0d victims", writebacks);
                $fatal(1);
            end

            // Fill census. The walk only loads: its write-backs are the ones
            // the cache made, and nothing in it is a store-miss fill. Each
            // window's expected counts are worked through in build_program;
            // without DCACHE_SKIP_FILL every store miss fills (SF) and none is
            // skipped (SK) or leaves anything absent (AF).
            begin
                string names [0:3] = '{"write-back phase", "fill-need phase",
                                        "skipped-fill phase", "store stream"};
                //                        WB  SF  SK  AF  MC
                int want_on  [0:3][0:4] = '{'{ 3,  0,  0,  0, -1},
                                            '{ 4,  3,  1,  0, -1},
                                            '{ 7,  1,  7,  4, 13},
                                            '{64,  0, 64,  0, 64}};
                int want_off [0:3][0:4] = '{'{ 3,  0,  0,  0, -1},
                                            '{ 4,  4,  0,  0, -1},
                                            '{ 7,  7,  0,  0,  9},
                                            '{64, 64,  0,  0, 64}};
                $display("  fill census (DCACHE_SKIP_FILL %s):", (skipfill != 0) ? "on" : "off");
                $display("      %-20s %5s %5s %5s %5s %5s", "", "WB", "SF", "SK", "AF", "MC");
                $display("      %-20s %5d %5d %5d %5d %5d", "walk",
                         cen_walk[0], cen_walk[1], cen_walk[2], cen_walk[3], cen_walk[4]);
                if (cen_walk[0] != writebacks || cen_walk[1] != 0 || cen_walk[2] != 0 ||
                    cen_walk[3] != 0 || cen_walk[4] != misses) begin
                    $error("the walk counted WB %0d SF %0d SK %0d AF %0d MC %0d, expected WB %0d, no store-miss fill, MC %0d",
                           cen_walk[0], cen_walk[1], cen_walk[2], cen_walk[3], cen_walk[4],
                           writebacks, misses);
                    $fatal(1);
                end
                if (cen_marks != 8) begin
                    $error("the census windows saw %0d of 8 markers", cen_marks);
                    $fatal(1);
                end
                for (int w = 0; w < 4; w = w + 1) begin
                    $display("      %-20s %5d %5d %5d %5d %5d", names[w],
                             cen[w][0], cen[w][1], cen[w][2], cen[w][3], cen[w][4]);
                    for (int j = 0; j < 5; j = j + 1) begin
                        int want;
                        want = (skipfill != 0) ? want_on[w][j] : want_off[w][j];
                        if (want >= 0 && cen[w][j] != want) begin
                            $error("%s: counted WB %0d SF %0d SK %0d AF %0d MC %0d", names[w],
                                   cen[w][0], cen[w][1], cen[w][2], cen[w][3], cen[w][4]);
                            $fatal(1);
                        end
                    end
                end
                $display("  ---> store stream: %0.1f CPU cycles per line written whole, %0.1f per miss",
                         real'(cen_cycles[3]) / real'(STREAM_LINES),
                         real'(cen_cycles[3]) / real'(cen[3][4]));
                $display("  skipped-fill phase: loads summed %016h (expect %016h), SDRAM read back %016h (expect %016h)",
                         skp_sum_cached, skp_expect_cached, skp_sum_sdram, skp_expect_sdram);
                if (skp_sum_cached !== skp_expect_cached) begin
                    $error("a load in the skipped-fill phase returned the wrong data");
                    $fatal(1);
                end
                if (skp_sum_sdram !== skp_expect_sdram) begin
                    $error("after the skipped-fill phase SDRAM does not hold what the program wrote - a write-back wrote an absent qword or dropped a present one");
                    $fatal(1);
                end
            end

            // Framebuffer load census: the window's classes, worked through in
            // build_program, and FL and FH over the whole run against every
            // framebuffer load the program makes - census phase 0's 16, RMW,
            // MIXED, and this phase's 21 - and every hit the other windows saw.
            begin
                int want [0:4];
                int run_loads, run_hits;
                // The window's classes, from the buffer the CPU was built
                // with: FBLINE_WAYS lines replaced round-robin, and the same
                // number of thrown-away lines remembered for FR. The four-line
                // answer is asserted below, so a wrong model shows up there.
                fb_census_model(want);
                // Field 4 is NS now, and this window makes no uncached
                // narrow store, so it must stay empty here; the phase that
                // does make them is checked below.
                want[4] = 0;
                // The model has no read-ahead in it, and cannot have: whether
                // a read-ahead lands before the next load depends on timing,
                // and these loads are back to back. So the exact counts are
                // checked with read-ahead OFF - which is the configuration
                // that mutation-tested them - and with it on the phase checks
                // what must hold either way. The read-ahead's own exact test
                // is the RMW window below.
                if (fblbuf == 0) want = '{fbc_off.size(), 0, 0, 0, 0};
                else if (fbways == 4 &&
                         !(want[0] == 25 && want[1] == 6 && want[2] == 2 &&
                           want[3] == 4)) begin
                    $error("the four-line census model gives FL %0d FH %0d FR %0d FA %0d, not 25 6 2 4",
                           want[0], want[1], want[2], want[3]);
                    $fatal(1);
                end
                // The stress phase's framebuffer loads land on random lines, so
                // they count in FL and may or may not hit.
                run_loads = 16 + FBL_RMW_ITERS + fbl_mix_loads +
                            (fbc_off.size() + 1) + str_counts[9] +
                            fbs_counts[4] + fbs_counts[5] + fbs_counts[6] +
                            fbs_counts[7] + fbs_counts[8] +
                            PV_PASSES * 27;   // L, M, L+1 and 24 of L a pass
                run_hits  = (fn_snap[1] - fn_snap[0]) + fbl_hits[0] + fbl_hits[1] + fbc_cnt[1];
                $display("  framebuffer load census (buffer %s): FL %0d FH %0d FR %0d FA %0d NS %0d, %0d UF cycles; run FL %0d (expect %0d) FH %0d (expect %0d)",
                         (fblbuf != 0) ? "on" : "off", fbc_cnt[0], fbc_cnt[1], fbc_cnt[2],
                         fbc_cnt[3], fbc_cnt[4], fbc_cnt[5], fbc_run_loads, run_loads,
                         fbc_run_hits, run_hits);
                if (fbc_marks != 2) begin
                    $error("the framebuffer census window saw %0d of 2 markers", fbc_marks);
                    $fatal(1);
                end
                if (fbprefetch == 0) begin
                    for (int j = 0; j < 5; j = j + 1)
                        if (fbc_cnt[j] != want[j]) begin
                            $error("the framebuffer census counted FL %0d FH %0d FR %0d FA %0d NS %0d, expected %0d %0d %0d %0d %0d",
                                   fbc_cnt[0], fbc_cnt[1], fbc_cnt[2], fbc_cnt[3], fbc_cnt[4],
                                   want[0], want[1], want[2], want[3], want[4]);
                            $fatal(1);
                        end
                end else begin
                    // Read-ahead changes which lines are held when each load
                    // arrives, and by how much depends on timing. What cannot
                    // change: every load is counted, none of them is an
                    // uncached narrow store, at least as many hit as without
                    // read-ahead, and no class exceeds the loads.
                    if (fbc_cnt[0] != want[0] || fbc_cnt[4] != 0 ||
                        fbc_cnt[1] < want[1] || fbc_cnt[1] > fbc_cnt[0] ||
                        fbc_cnt[2] > fbc_cnt[0] || fbc_cnt[3] > fbc_cnt[0]) begin
                        $error("with read-ahead the census counted FL %0d FH %0d FR %0d FA %0d NS %0d, against %0d %0d %0d %0d 0 without it",
                               fbc_cnt[0], fbc_cnt[1], fbc_cnt[2], fbc_cnt[3], fbc_cnt[4],
                               want[0], want[1], want[2], want[3]);
                        $fatal(1);
                    end
                end
                if (fbc_run_loads != run_loads || fbc_run_hits < run_hits ||
                    fbc_run_hits > run_loads) begin
                    $error("FL or FH fired outside the framebuffer loads the program makes");
                    $fatal(1);
                end
            end

            // Narrow uncached stores. The same sh and sb sequence through the
            // cache and through SDRAM must leave the same qword: the cached
            // copy merges in the cache, the uncached one is read, merged and
            // written back by the bridge, and neither may depend on the
            // device masking a byte. NS must count the uncached ones.
            begin
                $display("  narrow uncached stores: NS %0d in the window (expect %0d), %0d in the run; cached %016h, uncached %016h",
                         ns_in_window, NS_STORES, ns_run,
                         (ns_got.size() > 0) ? ns_got[0] : 64'hx,
                         (ns_got.size() > 1) ? ns_got[1] : 64'hx);
                if (ns_marks != 2 || ns_got.size() != 2) begin
                    $error("the narrow-store phase saw %0d of 2 markers and %0d of 2 reports",
                           ns_marks, ns_got.size());
                    $fatal(1);
                end
                if (ns_got[0] !== ns_got[1]) begin
                    $error("an sh/sb sequence through SDRAM gives %016h where the cache gives %016h - the bridge is not merging the bytes it does not write",
                           ns_got[1], ns_got[0]);
                    $fatal(1);
                end
                if ($isunknown(ns_got[0])) begin
                    $error("the narrow-store phase read back unknown bits");
                    $fatal(1);
                end
                if (ns_in_window != NS_STORES) begin
                    $error("NS counted %0d narrow uncached stores in the window, expected %0d",
                           ns_in_window, NS_STORES);
                    $fatal(1);
                end
                // Nothing else in the program stores narrowly to uncached
                // SDRAM, so the run total is the window's.
                if (ns_run != ns_in_window) begin
                    $error("NS fired %0d times in the run but %0d inside the window",
                           ns_run, ns_in_window);
                    $fatal(1);
                end
            end

            // Framebuffer stress: every report against the byte model. This
            // is the check that sees a buffered line going stale - a wrong
            // pixel on the title screen was the hardware symptom.
            begin
                int bad;
                bad = -1;
                $display("  framebuffer stress (%0d accesses x %0d passes over %0d lines; SD %0d SW %0d SH %0d SB %0d LD %0d LW %0d LWU %0d LH %0d LB %0d): %0d loads, %0d hits, %0d fetches, %0d read-aheads",
                         FBS_OPS, FBS_PASSES, FBS_LINES, fbs_counts[0], fbs_counts[1], fbs_counts[2],
                         fbs_counts[3], fbs_counts[4], fbs_counts[5], fbs_counts[6],
                         fbs_counts[7], fbs_counts[8], fbs_loads, fbs_hits, fbs_fetch, fbs_pf);
                if (fbs_marks != 2 || fbs_got.size() != fbs_expect.size()) begin
                    $error("the framebuffer stress phase saw %0d of 2 markers and %0d of %0d reports",
                           fbs_marks, fbs_got.size(), fbs_expect.size());
                    $fatal(1);
                end
                foreach (fbs_expect[i])
                    if (bad < 0 && fbs_got[i] !== fbs_expect[i]) bad = i;
                if (bad >= 0) begin
                    $error("framebuffer stress: the loads went wrong in pass %0d (of %0d reports shown as its index) - sum %016h against %016h",
                           bad, bad, fbs_got[bad], fbs_expect[bad]);
                    $fatal(1);
                end
                if (fblbuf != 0 && fbs_hits == 0) begin
                    $error("framebuffer stress: the buffer never hit - not a test of it");
                    $fatal(1);
                end
                if (fblbuf != 0 && fbprefetch != 0 && fbs_pf == 0) begin
                    $error("framebuffer stress: no read-ahead was ever issued - not a test of it");
                    $fatal(1);
                end
                $display("  ---> framebuffer stress: all %0d reports match the model", fbs_expect.size());
            end

            // Pinned victim: every pass must sum L, and never the line that
            // landed on top of it.
            begin
                $display("  pinned victim: %0d of %0d passes reported", pv_got.size(), PV_PASSES);
                if (pv_got.size() != PV_PASSES) begin
                    $error("the pinned-victim phase reported %0d of %0d passes", pv_got.size(), PV_PASSES);
                    $fatal(1);
                end
                foreach (pv_expect[i])
                    if (pv_got[i] !== pv_expect[i]) begin
                        $error("pinned victim, pass %0d: summed %016h, expected %016h - a load was answered from a line a read-ahead had just replaced",
                               i, pv_got[i], pv_expect[i]);
                        $fatal(1);
                    end
                $display("  ---> pinned victim: all %0d passes read their own line", PV_PASSES);
            end

            // Data cache stress: every report against the model, the first
            // wrong one named, and enough of each kind of traffic to mean it.
            begin
                int bad;
                bad = -1;
                $display("  data cache stress (%0d accesses; SD %0d SW %0d SH %0d SB %0d LD %0d LW %0d LWU %0d LH %0d LB %0d FB %0d; video %s): SK %0d AF %0d WB %0d MC %0d, %0d cycles a line write-back waited on video",
                         STR_OPS, str_counts[0], str_counts[1], str_counts[2], str_counts[3],
                         str_counts[4], str_counts[5], str_counts[6], str_counts[7], str_counts[8],
                         str_counts[9], (video != 0) ? "on" : "off", str_cnt[0], str_cnt[1],
                         str_cnt[2], str_cnt[3], line_writes_deferred);
                if (str_marks != 2 || str_got.size() != str_expect.size()) begin
                    $error("the stress phase saw %0d of 2 markers and %0d of %0d reports",
                           str_marks, str_got.size(), str_expect.size());
                    $fatal(1);
                end
                // Load by load first: the data cache's own answer, which says
                // whether a wrong sum is the cache or what the CPU made of it.
                begin
                    int lbad, shown;
                    lbad = 0; shown = 0;
                    $display("      data cache answered %0d loads, %0d expected", str_load_got.size(), str_load_raw.size());
                    foreach (str_load_raw[i]) begin
                        if (i >= str_load_got.size()) break;
                        if (str_load_got[i] !== str_load_raw[i] ||
                            str_load_got_addr[i][28:0] !== str_load_addr[i][28:0]) begin
                            if (shown < 6)
                                $display("      load %0d (kind %0d) at %08h (cache saw %08h): got %016h, expected %016h",
                                         i, str_load_kind[i], str_load_addr[i], str_load_got_addr[i],
                                         str_load_got[i], str_load_raw[i]);
                            shown = shown + 1;
                            lbad = lbad + 1;
                        end
                    end
                    $display("      %0d of %0d loads differ from the model", lbad, str_load_raw.size());
                end
                foreach (str_expect[i])
                    if (bad < 0 && str_got[i] !== str_expect[i]) bad = i;
                if (bad >= 0) begin
                    if (bad == str_expect.size() - 1)
                        $error("stress: every load was right, but SDRAM read back %016h against %016h - a write-back is wrong",
                               str_got[bad], str_expect[bad]);
                    else
                        $error("stress: the loads went wrong between access %0d and %0d - sum %016h against %016h",
                               bad * STR_EVERY, (bad + 1) * STR_EVERY, str_got[bad], str_expect[bad]);
                    $fatal(1);
                end
                if (skipfill != 0 && (str_cnt[0] < 20 || str_cnt[1] < 5)) begin
                    $error("stress: only %0d skipped fills and %0d absent-qword fills - not a stress test",
                           str_cnt[0], str_cnt[1]);
                    $fatal(1);
                end
                if (video != 0 && line_writes_deferred == 0) begin
                    $error("stress: video was on, but no line write-back ever waited on it");
                    $fatal(1);
                end
                $display("  ---> data cache stress: all %0d reports match the model", str_expect.size());
            end

            // A dirty miss waits for its victim before the fill starts,
            // so that wait belongs in F1. It lands in F3 instead unless
            // cpu_datacache clears fill_beat_seen on WRITEBACKDONE ->
            // FILL: revert that clear and F1 here reads 0.
            if (dirty != 0) begin
                if (f1_cycles < misses * 20) begin
                    $error("dirty F1 averaged %0.1f - fill_beat_seen is not cleared on the writeback path",
                           real'(f1_cycles) / real'(misses));
                    $fatal(1);
                end
                if (f3_cycles > misses * 25) begin
                    $error("dirty F3 averaged %0.1f - the tail should be the mailbox round trip only",
                           real'(f3_cycles) / real'(misses));
                    $fatal(1);
                end
            end

            // The census: every phase in its own tap and no other.
            begin
                string names [0:4] = '{"UW store", "UF framebuffer", "UI I/O",
                                        "UB boot ROM", "UM RAM"};
                int    expect_tap [0:PHASES-1] = '{1, 2, 3, 4, 0};
                $display("  uncached census, CPU cycles per phase:");
                $display("      phase            UW      UF      UI      UB      UM");
                if (phases_seen != PHASES + 1) begin
                    $error("census saw %0d of %0d markers", phases_seen, PHASES + 1);
                    $fatal(1);
                end
                for (int k = 0; k < PHASES; k = k + 1) begin
                    longint d [0:4];
                    for (int j = 0; j < 5; j = j + 1)
                        d[j] = uc_snap[k + 1][j] - uc_snap[k][j];
                    $display("      %14s %6d  %6d  %6d  %6d  %6d",
                             names[expect_tap[k]], d[0], d[1], d[2], d[3], d[4]);
                    for (int j = 0; j < 5; j = j + 1) begin
                        if (j == expect_tap[k] && d[j] == 0) begin
                            $error("%s phase never fired its own tap", names[expect_tap[k]]);
                            $fatal(1);
                        end
                        if (j != expect_tap[k] && d[j] != 0) begin
                            $error("%s phase leaked %0d cycles into %s",
                                   names[expect_tap[k]], d[j], names[j]);
                            $fatal(1);
                        end
                    end
                end
                // FH in the framebuffer phase. Its 16 loads step 4 bytes from
                // 0x30000 across two lines, so the line buffer fetches for the
                // first load of each line and answers the other 14. With the
                // buffer off, none. Zero in every other phase either way.
                begin
                    longint fn_d, uf_d;
                    int     want;
                    fn_d = fn_snap[1] - fn_snap[0];
                    uf_d = uc_snap[1][1] - uc_snap[0][1];
                    want = (fblbuf != 0) ? 14 : 0;
                    $display("  FH, framebuffer loads the line buffer answered: %0d of 16 (expect %0d%s), %0d UF cycles",
                             fn_d, want, (fbprefetch != 0 && fblbuf != 0) ? " or 15" : "", uf_d);
                    // 16 loads four bytes apart over two lines: the first of
                    // each line fetches, the other 14 hit. With read-ahead the
                    // second line may have arrived before its first load, in
                    // which case 15 hit - whether it has is a matter of
                    // timing, so both are allowed here and the RMW window
                    // carries the exact read-ahead test.
                    if (fn_d != want &&
                        !(fbprefetch != 0 && fblbuf != 0 && fn_d == want + 1)) begin
                        $error("FH counted %0d buffered loads in the framebuffer phase, expected %0d",
                               fn_d, want);
                        $fatal(1);
                    end
                    for (int k = 1; k < PHASES; k = k + 1)
                        if (fn_snap[k + 1] != fn_snap[k]) begin
                            $error("FH counted %0d hits in a phase with no framebuffer loads",
                                   fn_snap[k + 1] - fn_snap[k]);
                            $fatal(1);
                        end
                end
                $display("  uncached residual (stall4-uncached, no tap) %0d", uc_residual);
                if (uc_residual != 0) begin
                    $error("%0d uncached stall cycles matched no tap", uc_residual);
                    $fatal(1);
                end
            end

            $display("  store-then-load hazard: load returned %016h, %0d READWAIT cycles in the run",
                     hazard_value, readwait_cycles);
            if (hazard_value[31:0] != 32'h1234_5678 && hazard_value[63:32] != 32'h1234_5678) begin
                $error("a load right after a store returned %016h, expected 12345678", hazard_value);
                $fatal(1);
            end
            $display("  same, independent instructions after the load: returned %016h, %0d READWAIT cycles",
                     hazard2_value, readwait_at_h2 - readwait_at_h1);
            if (readwait_at_h2 == readwait_at_h1) begin
                $error("the independent-consumer case never entered READWAIT, so it tested nothing");
                $fatal(1);
            end
            if (hazard2_value[31:0] != 32'h1234_5678 && hazard2_value[63:32] != 32'h1234_5678) begin
                $error("a load right after a store, not stalled by a use, returned %016h, expected 12345678",
                       hazard2_value);
                $fatal(1);
            end

            // Two lines, one set. Neither may evict the other; in the
            // alternating loop the first load of each line per iteration takes
            // one WAYFIX cycle and the second none, and in the predicted-right
            // loop no load does. The sums prove every load returned its own
            // line's data: 16 x (1111 + 0100 + 2222 + 0010) and
            // 16 x 2 x (1111 + 0100).
            begin
                string  names [0:1] = '{"alternating A,A+8,B,B+8", "predicted A,A+8,A,A+8"};
                logic [31:0] expect_sum [0:1] = '{TWOWAY_ITERS * 32'h3443, TWOWAY_ITERS * 32'h2422};
                int     expect_wf  [0:1] = '{2 * TWOWAY_ITERS, 0};
                for (int w = 0; w < 2; w = w + 1) begin
                    $display("  two lines in one set, %s x%0d: %0d misses, %0d WAYFIX, %0d cycles, sum %016h",
                             names[w], TWOWAY_ITERS, twoway_misses[w], twoway_wayfix[w],
                             twoway_cycles[w], twoway_sum[w]);
                    if (twoway_sum[w][31:0] != expect_sum[w] && twoway_sum[w][63:32] != expect_sum[w]) begin
                        $error("%s summed %016h, expected %08h - a load returned another line's data",
                               names[w], twoway_sum[w], expect_sum[w]);
                        $fatal(1);
                    end
                    if (twoway_misses[w] != 0) begin
                        $error("%s missed %0d times - two lines in one set are evicting each other",
                               names[w], twoway_misses[w]);
                        $fatal(1);
                    end
                    if (twoway_wayfix[w] != expect_wf[w]) begin
                        $error("%s took %0d WAYFIX cycles, expected %0d",
                               names[w], twoway_wayfix[w], expect_wf[w]);
                        $fatal(1);
                    end
                end
                $display("  ---> a load that hits the other way costs %0.2f CPU cycles more",
                         real'(twoway_cycles[0] - twoway_cycles[1]) / real'(2 * TWOWAY_ITERS));
                $display("  WAYFIX cycles in the whole run: %0d", wayfix_total);
                if (twoway_marks != 4) begin
                    $error("the two-way windows saw %0d of 4 markers", twoway_marks);
                    $fatal(1);
                end
            end

            // Framebuffer line buffer. RMW: 64 loads over 16 lines, one fetch
            // and three hits a line. MIXED: every load it emitted, answered.
            // With the buffer off, no hit and no fetch anywhere. The hash and
            // the sum are for tools/run_perfbench.ps1 to compare across the
            // two builds; here they only have to be known values.
            begin
                string names [0:1] = '{"RMW, 8-byte stride", "MIXED widths"};
                int    want_loads [0:1];
                want_loads[0] = FBL_RMW_ITERS;
                want_loads[1] = fbl_mix_loads;
                if (fbl_marks != 4) begin
                    $error("the line buffer windows saw %0d of 4 markers", fbl_marks);
                    $fatal(1);
                end
                for (int w = 0; w < 2; w = w + 1) begin
                    $display("  FB line buffer %s (buffer %s, read-ahead %s): %0d loads, %0d hits, %0d fetches, %0d read-aheads, %0d cycles, %0d UF",
                             names[w], (fblbuf != 0) ? "on" : "off",
                             (fbprefetch != 0) ? "on" : "off", fbl_loads[w], fbl_hits[w],
                             fbl_fetches[w], fbl_pf[w], fbl_cycles[w], fbl_uf[w]);
                    if (fbl_loads[w] != want_loads[w]) begin
                        $error("%s completed %0d framebuffer loads, expected %0d",
                               names[w], fbl_loads[w], want_loads[w]);
                        $fatal(1);
                    end
                    if (fblbuf == 0 && (fbl_hits[w] != 0 || fbl_fetches[w] != 0)) begin
                        $error("%s: buffer off, but %0d hits and %0d fetches",
                               names[w], fbl_hits[w], fbl_fetches[w]);
                        $fatal(1);
                    end
                    // Every buffered load is either a hit or the load that
                    // fetched its line - exactly one of the two.
                    if (fblbuf != 0 && fbl_hits[w] + fbl_fetches[w] != fbl_loads[w]) begin
                        $error("%s: %0d hits and %0d fetches for %0d loads",
                               names[w], fbl_hits[w], fbl_fetches[w], fbl_loads[w]);
                        $fatal(1);
                    end
                end
                // RMW walks 16 lines in order, four loads each. Without
                // read-ahead every line's first load fetches it: 48 hits, 16
                // fetches. With read-ahead only the FIRST line is fetched -
                // reaching each line asks for the next - so the other 15
                // arrive before they are wanted and every load but one hits.
                // The 16th read-ahead is for the line after the phase's last,
                // which is still inside the framebuffer page.
                if (fblbuf != 0 && fbprefetch == 0 &&
                    (fbl_hits[0] != 48 || fbl_fetches[0] != 16 || fbl_pf[0] != 0)) begin
                    $error("RMW took %0d hits, %0d fetches and %0d read-aheads, expected 48, 16 and 0",
                           fbl_hits[0], fbl_fetches[0], fbl_pf[0]);
                    $fatal(1);
                end
                if (fblbuf != 0 && fbprefetch != 0 &&
                    (fbl_hits[0] != 63 || fbl_fetches[0] != 1 || fbl_pf[0] != 16)) begin
                    $error("RMW with read-ahead took %0d hits, %0d fetches and %0d read-aheads, expected 63, 1 and 16",
                           fbl_hits[0], fbl_fetches[0], fbl_pf[0]);
                    $fatal(1);
                end
                $display("  ---> RMW: %0.1f CPU cycles per iteration, %0.1f UF cycles per load",
                         real'(fbl_cycles[0]) / real'(FBL_RMW_ITERS),
                         real'(fbl_uf[0]) / real'(FBL_RMW_ITERS));
                $display("  FB load hash %016h, MIXED sum %016h", fbl_hash, fbl_mix_sum);
                if (fbl_hash_unknown || $isunknown(fbl_mix_sum)) begin
                    $error("a framebuffer load in the windows returned unknown bits");
                    $fatal(1);
                end
            end

            if (misses < LINES / 2) begin
                $error("only %0d misses for %0d lines - the walk is hitting, not filling", misses, LINES);
                $fatal(1);
            end
            if (debug_errors != 6'd0) begin
                $error("CPU reported errors=%02x", debug_errors);
                $fatal(1);
            end
            $display("tb_ki_perfbench: PASS");
            $display("");
            $finish;
        end
    endtask

    // ---------------------------------------------------------- sequence
    task automatic sdram_poke(input logic [23:0] word_index,
                              input logic [15:0] value);
        begin memory.mem[{8'd0, word_index}] = value; end
    endtask

    localparam logic [27:0] STORE_BOOT = 28'h090_0000;

    initial begin
        void'($value$plusargs("pad=%d", pad));
        void'($value$plusargs("stride=%d", stride));
        void'($value$plusargs("dirty=%d", dirty));
        void'($value$plusargs("fblbuf=%d", fblbuf));
        fbways = cpu.FBLINE_WAYS;
        fbprefetch = cpu.FBLINE_PREFETCH;
        void'($value$plusargs("skipfill=%d", skipfill));
        void'($value$plusargs("progress=%d", progress));
        void'($value$plusargs("video=%d", video));
        void'($value$plusargs("strtrace=%d", strtrace));
        build_program();
        if (progress != 0)
            $display("  program: walk loop at %03h, park at %03h", loop_start, halt_pc);
        // The stress phase's lines, seeded straight into the device model:
        // main RAM at 0x08000000 is SDRAM storage 0x100000, two bytes a word.
        for (int tt = -3; tt <= 3; tt = tt + 1)
            for (int ss = 0; ss < 3; ss = ss + 1)
                for (int w = 0; w < 16; w = w + 1) begin
                    logic [31:0] phys;
                    phys = STR_PHYS + tt * 32'h2000 + ss * 32 + 2 * w;
                    sdram_poke(24'((32'h0010_0000 + phys - 32'h0800_0000) >> 1),
                               {str_seed[phys + 1], str_seed[phys]});
                end

        // The boot image reaches the CPU by the same two routes as hardware:
        // a copy in SDRAM and the bridge's boot line buffer.
        for (integer a = 0; a < BOOT_BYTES; a = a + 2)
            sdram_poke((STORE_BOOT + a) >> 1, {boot_rom[a + 1], boot_rom[a]});
        for (integer w = 0; w < (8 * 1024 / 8); w = w + 1)
            bridge.boot_cache[w] = {
                boot_rom[w*8 + 7], boot_rom[w*8 + 6],
                boot_rom[w*8 + 5], boot_rom[w*8 + 4],
                boot_rom[w*8 + 3], boot_rom[w*8 + 2],
                boot_rom[w*8 + 1], boot_rom[w*8 + 0]
            };

        repeat (8) @(posedge clk_1x);
        init = 1'b0;
        wait (sdram_ready);
        repeat (8) @(posedge clk_1x);
        reset     <= 1'b0;
        repeat (4) @(posedge clk_1x);
        cpu_reset <= 1'b0;

        wait (marks_seen >= 2);
        wait (phases_seen >= PHASES + 1);
        wait (hazard_seen);
        wait (hazard2_seen);
        wait (twoway_seen[1]);
        wait (fbl_mix_seen);
        wait (skp_seen);
        wait (cen_marks >= 8);
        wait (fbc_marks >= 2);
        wait (str_got.size() == str_expect.size());
        repeat (20) @(posedge clk_1x);
        report_and_finish();
    end

    initial begin
        #(64'd4000000000);
        $display("FAIL: timeout pc=%08x retired=%0d marks=%0d misses=%0d cycles=%0d dcache state=%0d stall=%b",
                 debug_pc, debug_retired, marks_seen, misses, cpu_cycles,
                 cpu.core.icpu_datacache.debug_state, cpu.core.stall);
        $fatal(1);
    end

    // The program runs in KSEG0 once the reset vector has jumped there, so a
    // fetch back in KSEG1 is an exception vector. Say which.
    logic in_kseg0 = 1'b0, left_kseg0 = 1'b0;
    always @(posedge clk_93) if (!cpu_reset) begin
        if (debug_pc[31:28] == 4'h9) in_kseg0 <= 1'b1;
        if (in_kseg0 && !left_kseg0 && debug_pc[31:28] == 4'hB) begin
            left_kseg0 <= 1'b1;
            $display("  EXCEPTION? fetch left KSEG0 at cycle %0d: pc=%08x cause=%08x epc=%08x (%08x) retired=%0d census marks %0d",
                     cpu_cycles, debug_pc, cpu.core.debug_cop0_cause_live,
                     cpu.core.debug_cop0_epc_live,
                     {boot_rom[(cpu.core.debug_cop0_epc_live & 32'hFFF) + 3],
                      boot_rom[(cpu.core.debug_cop0_epc_live & 32'hFFF) + 2],
                      boot_rom[(cpu.core.debug_cop0_epc_live & 32'hFFF) + 1],
                      boot_rom[(cpu.core.debug_cop0_epc_live & 32'hFFF)]},
                     debug_retired, cen_marks);
        end
    end

    // A hang and a slow run look the same at the timeout; +progress=1 tells
    // them apart.
    always @(posedge clk_93)
        if (progress != 0 && !cpu_reset && (cpu_cycles % 50000) == 0)
            $display("  progress: cycle %0d pc=%08x retired=%0d dcache state=%0d stall=%b census marks %0d, uncached phases %0d",
                     cpu_cycles, debug_pc, debug_retired, cpu.core.icpu_datacache.debug_state,
                     cpu.core.stall, cen_marks, phases_seen);

endmodule

`default_nettype wire
