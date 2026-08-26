`timescale 1ps/1ps

module tb_ki_cpu_system_boot;

    localparam int BOOT_BYTES = 524288;
    localparam int BOOT_CACHE_BYTES = 8 * 1024;
    localparam logic [27:0] STORE_BOOT = 28'h090_0000;
    localparam logic [63:0] KI_IMAGE_BYTES = 64'd131076608;

    logic clk_1x = 1'b0;
    logic clk_93 = 1'b0;
    logic clk_2x = 1'b0;
    logic reset = 1'b1;

    always #10000 clk_1x = ~clk_1x;
    always #6667  clk_93 = ~clk_93;
    always #5000  clk_2x = ~clk_2x;

    logic        cpu_request;
    logic [2:0]  cpu_size;
    logic        cpu_rnw;
    logic [31:0] cpu_address;
    logic        cpu_req64;
    logic [63:0] cpu_write_data;
    logic [7:0]  cpu_write_mask;
    logic [63:0] cpu_read_data;
    logic        cpu_done;
    logic        cpu_cache_grant;
    logic [63:0] cpu_cache_data;
    logic        cpu_cache_data_ready;

    logic [1:0]  irq;
    logic [31:0] debug_pc;
    logic [31:0] debug_retired;
    logic [31:0] debug_retire_pc;
    logic [31:0] debug_retire_opcode;
    logic [31:0] debug_irq_count;
    logic [31:0] debug_v0;
    logic [31:0] debug_v1;
    logic [31:0] debug_a0;
    logic [31:0] debug_a1;
    logic [31:0] debug_t2;
    logic [31:0] debug_a3;
    logic [31:0] debug_s5;
    logic [31:0] debug_s6;
    logic [31:0] debug_ra;
    logic [5:0]  debug_errors;
    logic [31:0] debug_ram_pc0;
    logic [31:0] debug_ram_op0;
    logic [31:0] debug_ram_pc1;
    logic [31:0] debug_ram_op1;
    logic [31:0] debug_ram_pc2;
    logic [31:0] debug_ram_op2;

    logic        ioctl_download;
    logic [15:0] ioctl_index;
    logic        ioctl_wr;
    logic [26:0] ioctl_addr;
    logic [15:0] ioctl_dout;
    logic        ioctl_wait;

    logic        io_request;
    logic        io_write;
    logic [31:0] io_address;
    logic [31:0] io_write_data;
    logic [3:0]  io_byte_enable;
    logic [31:0] io_read_data;
    logic        io_done;

    logic [31:0] board_read_data;
    logic        board_done;
    logic [31:0] ata_read_data;
    logic        ata_done;
    logic        ata_irq;

    logic [24:0] sdram_address;
    logic [63:0] sdram_write_data;
    wire  [15:0] sdram_read_data;
    logic  [4:0] sdram_burst;
    logic        sdram_read;
    logic        sdram_write;
    logic  [7:0] sdram_byte_enable;
    wire         sdram_data_valid;
    wire         sdram_done;
    wire         sdram_ready;

    logic [28:0] ddram_addr;
    logic [7:0]  ddram_burstcnt;
    logic [63:0] ddram_din;
    logic [7:0]  ddram_be;
    logic        ddram_rd;
    logic        ddram_we;
    logic        ddram_busy;
    logic [63:0] ddram_dout;
    logic        ddram_dout_ready;

    logic        boot_loaded;
    logic        boot_ready;
    wire         cpu_reset = reset | ioctl_download | ~boot_ready |
                             ~sdram_ready;
    logic [2:0]  debug_state;
    logic        debug_cpu_pending;
    logic [31:0] debug_last_write_address;
    logic [63:0] debug_last_write_data;
    logic [31:0] debug_last_write_info;
    logic [31:0] debug_write_count;
    logic [31:0] debug_low_write_count;
    logic [31:0] debug_main_write_count;
    logic [31:0] debug_main_write0;
    logic [31:0] debug_main_write1;
    logic [31:0] debug_main_write2;

    wire         video_request;
    wire  [27:0] video_address;
    wire   [2:0] video_words;
    logic [63:0] video_data;
    logic        video_data_valid;
    logic        video_done;

    logic        ce_pixel;
    logic [9:0]  h_count;
    logic [9:0]  v_count;
    logic        display_enable;
    logic        hsync_n;
    logic        vsync_n;
    logic        vblank;
    logic        frame_start;
    logic [31:0] vblank_count;
    logic        vblank_seen;
    logic [9:0]  max_v_count;

    logic [18:0] framebuffer_base;
    logic        sound_reset;
    logic [31:0] sound_data;
    logic        sound_data_strobe;
    logic [31:0] coin_control;

    logic        img_mounted;
    logic [31:0] sd_lba;
    logic        sd_rd;
    logic        sd_wr;
    logic        sd_ack;
    logic [7:0]  sd_buff_addr;
    logic [15:0] sd_buff_dout;
    logic [15:0] sd_buff_din;
    logic        sd_buff_wr;
    logic [2:0]  ata_debug_state;
    logic [7:0]  ata_debug_status;
    logic [7:0]  ata_debug_error;
    logic        ata_image_ready;

    ki_cpu_core cpu (
        .clk1x(clk_1x),
        .clk93(clk_93),
        .clk2x(clk_2x),
        .reset(cpu_reset),
        .irq(irq),
        .mem_request(cpu_request),
        .mem_rnw(cpu_rnw),
        .mem_address(cpu_address),
        .mem_req64(cpu_req64),
        .mem_size(cpu_size),
        .mem_writeMask(cpu_write_mask),
        .mem_dataWrite(cpu_write_data),
        .mem_dataRead(cpu_read_data),
        .mem_done(cpu_done),
        .cache_grant(cpu_cache_grant),
        .cache_data(cpu_cache_data),
        .cache_data_ready(cpu_cache_data_ready),
        .errors(debug_errors),
        .debug_fetch_pc(debug_pc),
        .debug_retired(debug_retired),
        .debug_irq_count(debug_irq_count),
        .debug_gpr_s5(debug_s5),
        .debug_gpr_t2(debug_t2),
        .debug_gpr_v1(debug_v1),
        .debug_gpr_a0(debug_a0),
        .debug_gpr_a1(debug_a1),
        .debug_t2_reload_count(),
        .debug_s5_dec_count(),
        .debug_s5_init_count(),
        .debug_s5_write_count(),
        .debug_s5_branch_count(),
        .debug_s5_branch_taken(),
        .debug_s5_branch_value(),
        .debug_gpr_v0(debug_v0),
        .debug_gpr_a3(debug_a3),
        .debug_gpr_s6(debug_s6),
        .debug_gpr_ra(debug_ra),
        .debug_ram_pc0(debug_ram_pc0),
        .debug_ram_op0(debug_ram_op0),
        .debug_ram_pc1(debug_ram_pc1),
        .debug_ram_op1(debug_ram_op1),
        .debug_ram_pc2(debug_ram_pc2),
        .debug_ram_op2(debug_ram_op2),
        .debug_rom_return_pc(),
        .debug_rom_return_prev(),
        .debug_stall_pc(),
        .debug_stall_status(),
        .debug_retire_pc(debug_retire_pc),
        .debug_retire_opcode(debug_retire_opcode)
    );

    ki_memory_bridge bridge (
        .clk(clk_1x),
        .ddr_clk(clk_2x),
        .reset(reset),
        .cpu_request(cpu_request),
        .cpu_rnw(cpu_rnw),
        .cpu_address(cpu_address),
        .cpu_req64(cpu_req64),
        .cpu_size(cpu_size),
        .cpu_write_mask(cpu_write_mask),
        .cpu_data_write(cpu_write_data),
        .cpu_data_read(cpu_read_data),
        .cpu_done(cpu_done),
        .cpu_grant(cpu_cache_grant),
        .cpu_cache_data(cpu_cache_data),
        .cpu_cache_data_ready(cpu_cache_data_ready),
        .io_request(io_request),
        .io_write(io_write),
        .io_address(io_address),
        .io_write_data(io_write_data),
        .io_byte_enable(io_byte_enable),
        .io_read_data(io_read_data),
        .io_done(io_done),
        .ioctl_download(ioctl_download),
        .ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),
        .boot_loaded(boot_loaded),
        .video_request(video_request),
        .video_address(video_address),
        .video_words(video_words),
        .video_data(video_data),
        .video_data_valid(video_data_valid),
        .video_done(video_done),
        .sdram_address(sdram_address),
        .sdram_write_data(sdram_write_data),
        .sdram_byte_enable(sdram_byte_enable),
        .sdram_burst(sdram_burst),
        .sdram_read(sdram_read),
        .sdram_write(sdram_write),
        .sdram_read_data(sdram_read_data),
        .sdram_data_valid(sdram_data_valid),
        .sdram_done(sdram_done),
        .sdram_ready(sdram_ready),
        .ddram_busy(ddram_busy),
        .ddram_burstcnt(ddram_burstcnt),
        .ddram_addr(ddram_addr),
        .ddram_dout(ddram_dout),
        .ddram_dout_ready(ddram_dout_ready),
        .ddram_rd(ddram_rd),
        .ddram_din(ddram_din),
        .ddram_be(ddram_be),
        .ddram_we(ddram_we),
        .debug_state(debug_state),
        .debug_cpu_pending(debug_cpu_pending),
        .debug_last_write_address(debug_last_write_address),
        .debug_last_write_data(debug_last_write_data),
        .debug_last_write_info(debug_last_write_info),
        .debug_write_count(debug_write_count),
        .debug_low_write_count(debug_low_write_count),
        .debug_main_write_count(debug_main_write_count),
        .debug_main_write0(debug_main_write0),
        .debug_main_write1(debug_main_write1),
        .debug_main_write2(debug_main_write2)
    );

    ki_board_io board_io (
        .clk(clk_1x),
        .reset(reset),
        .game_ki2(1'b0),
        .bus_request(io_request),
        .bus_write(io_write),
        .bus_address(io_address),
        .bus_write_data(io_write_data),
        .bus_byte_enable(io_byte_enable),
        .bus_read_data(board_read_data),
        .bus_done(board_done),
        .input_p1(32'hffff_ffff),
        .input_p2(32'hffff_ffff),
        .input_volume(32'hffff_ffff),
        .input_dip(32'hffff_ffff),
        .input_unused(32'hffff_ffff),
        .irq_vblank(vblank),
        .irq_ata(ata_irq),
        .cpu_irq(irq),
        .framebuffer_base(framebuffer_base),
        .sound_reset(sound_reset),
        .sound_data(sound_data),
        .sound_data_strobe(sound_data_strobe),
        .coin_control(coin_control)
    );

    ki_ata ata (
        .clk(clk_1x),
        .reset(reset),
        .game_ki2(1'b0),
        .bus_request(io_request),
        .bus_write(io_write),
        .bus_address(io_address),
        .bus_write_data(io_write_data),
        .bus_byte_enable(io_byte_enable),
        .bus_read_data(ata_read_data),
        .bus_done(ata_done),
        .irq(ata_irq),
        .img_mounted(img_mounted),
        .img_readonly(1'b1),
        .img_size(KI_IMAGE_BYTES),
        .sd_lba(sd_lba),
        .sd_rd(sd_rd),
        .sd_wr(sd_wr),
        .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr),
        .debug_state(ata_debug_state),
        .debug_status(ata_debug_status),
        .debug_error(ata_debug_error),
        .debug_image_ready(ata_image_ready)
    );

    ki_video_timing #(.CLOCK_DIVIDE(8)) video_timing (
        .clk(clk_1x),
        .reset(reset),
        .ce_pixel(ce_pixel),
        .h_count(h_count),
        .v_count(v_count),
        .display_enable(display_enable),
        .hsync_n(hsync_n),
        .vsync_n(vsync_n),
        .vblank(vblank),
        .frame_start(frame_start),
        .vblank_count(vblank_count),
        .vblank_seen(vblank_seen),
        .max_v_count(max_v_count)
    );

    assign io_read_data = ata_done ? ata_read_data : board_read_data;
    assign io_done = board_done | ata_done;

    // Burst-accurate SDRAM responder.
    //
    // The previous model here answered one 16-bit word per request and pulsed
    // sdram_done - the pre-burst contract. Since the bridge was converted to
    // issue one burst per 64-bit word (4) and per cache line (16), that model
    // silently wedged every read: the bridge streams `sdram_burst` words in on
    // sdram_data_valid and only then looks at sdram_done, so it sat in
    // SDRAM_READ_WAIT forever owing 15 words. The bench also left sdram_burst
    // and sdram_data_valid unconnected and declared sdram_write_data 16 bits
    // wide against the bridge's 64. That is what hung boot at instruction 597,
    // in the cache-init routine's first line fill - a stale test double, not a
    // core defect.
    //
    // Contract (rtl/ki_memory_bridge.sv SDRAM_READ_ISSUE / SDRAM_WRITE_ISSUE):
    //   read : address = first word, burst = N 16-bit words. Reply with N
    //          sdram_data_valid pulses carrying one word each, THEN sdram_done.
    //   write: address = first word, burst = N words, payload is the 64-bit
    //          sdram_write_data with per-byte enables. Reply with sdram_done.
    // ---- video scanout ----------------------------------------------------
    // The real framebuffer reader. Exact framebuffer pages now use the second
    // M10K port, while requests outside those pages still exercise the bridge's
    // SDRAM video path. Previously video_request was tied off entirely.
    logic no_video = 1'b0;
    ki_framebuffer framebuffer (
        .clk(clk_1x),
        .reset(reset | no_video),
        .ce_pixel(ce_pixel),
        .h_count(h_count),
        .v_count(v_count),
        .framebuffer_base(framebuffer_base),
        // +no_video holds the scanout reader in reset so the identical run
        // can be made with an uncontended bus. If the retire PC stream is the
        // same in both and only the reported opcode differs, the zero is a
        // debug-export artifact; if the PC streams diverge, it is real.
        .memory_request(video_request),
        .memory_address(video_address),
        .memory_words(video_words),
        .memory_data(video_data),
        .memory_data_valid(video_data_valid),
        .memory_done(video_done),
        .red(), .green(), .blue(), .pixel_valid()
    );

    // Scanout pressure, so a run that silently lost contention is visible.
    integer video_reads = 0;
    always @(posedge clk_1x)
        if (video_request && video_done)
            video_reads <= video_reads + 1;

    // ---- real SDRAM path -------------------------------------------------
    // ki_memory_bridge -> ki_sdram_adapter -> ki_sdram_burst -> device model,
    // the same chain as hardware and as tb_ki_memory_bridge_sdram. The
    // behavioural responder this replaces could not show timing-dependent
    // faults, which is the whole remaining suspect list: capture phase, CAS
    // latency, refresh and CPU/scanout contention.
    //
    // Address spaces: the bridge drives a 16-bit WORD index; the adapter
    // converts it for the controller with {addr[23:0],1'b0}; the controller
    // decomposes that byte address as col=[9:1], row=[22:10], bank=[24:23].
    // Composing those, word index w lands at device key {8'd0, w[23:0]} - see
    // sdram_poke below.
    logic clk_dev = 1'b0;
    logic init = 1'b1;

    // Phase-shifted pin clock, 16.75 ns - the value validated on hardware.
    // Bench timescale is 1ps, hence 16750.
    task automatic emit_dev_edge(input logic value, input integer delay_ps);
        #(delay_ps) clk_dev = value;
    endtask
    always @(clk_1x) fork emit_dev_edge(clk_1x, 16750); join_none

    wire [24:0] controller_address;
    wire [63:0] controller_write_data;
    wire  [7:0] controller_byte_enable;
    wire  [4:0] controller_burst;
    wire        controller_read, controller_write;
    wire [15:0] controller_read_data;
    wire        controller_dout_valid, controller_ready;

    wire [15:0] SDRAM_DQ;
    wire [12:0] SDRAM_A;
    wire        SDRAM_DQML, SDRAM_DQMH;
    wire  [1:0] SDRAM_BA;
    wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

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

    // Seed the device the way a word index reaches it. Reads of locations
    // never written return 16'hdead by design, which is a feature: it makes a
    // dependency on zeroed RAM visible instead of silently reading 0.
    task automatic sdram_poke(input logic [23:0] word_index,
                              input logic [15:0] value);
        begin
            memory.mem[{8'd0, word_index}] = value;
        end
    endtask

    byte boot_rom [0:BOOT_BYTES-1];
    logic        boot_fetch_active;
    logic [31:0] boot_fetch_base;
    integer      boot_fetch_beat;
    integer      boot_fetch_offset;
    logic [63:0] boot_fetch_expected;
    integer      fill_trace_count = 0;
    byte disk_bytes [0:511];
    integer disk_file;
    integer disk_seek_result;
    integer disk_character;
    integer disk_byte;
    integer disk_word;
    integer disk_phase;
    integer disk_read_count;
    integer disk_write_count;
    integer disk_complete_count;
    logic   disk_active;
    logic   disk_is_write;

    // Patches boot_rom before it is copied into sdram_memory and before
    // bridge.boot_cache is filled from expected_boot_qword, so the ROM image,
    // the SDRAM copy, the line buffer and the retire-opcode checker all stay
    // consistent with one another.
    task automatic patch_boot_word(input integer offset,
                                   input logic [31:0] value);
        begin
            boot_rom[offset + 0] = value[7:0];
            boot_rom[offset + 1] = value[15:8];
            boot_rom[offset + 2] = value[23:16];
            boot_rom[offset + 3] = value[31:24];
        end
    endtask

    function automatic logic [63:0] expected_boot_qword(
        input integer byte_offset
    );
        expected_boot_qword = {
            boot_rom[byte_offset + 7],
            boot_rom[byte_offset + 6],
            boot_rom[byte_offset + 5],
            boot_rom[byte_offset + 4],
            boot_rom[byte_offset + 3],
            boot_rom[byte_offset + 2],
            boot_rom[byte_offset + 1],
            boot_rom[byte_offset]
        };
    endfunction

    function automatic logic [31:0] expected_boot_opcode(
        input integer byte_offset
    );
        expected_boot_opcode = {
            boot_rom[byte_offset + 3],
            boot_rom[byte_offset + 2],
            boot_rom[byte_offset + 1],
            boot_rom[byte_offset]
        };
    endfunction

    // ---- retire ring buffer -----------------------------------------------
    // Distinguishes real instruction corruption from a debug-export artifact.
    // If debug_retire_opcode reports squashed/bubble slots as 00000000 while
    // the retire PC still advances, the zero is cosmetic. Real corruption
    // instead shows a contiguous retire-PC sequence with one wrong opcode, and
    // execution that diverges afterwards.
    localparam int RETIRE_LOG = 28;
    logic [31:0] retire_log_n  [0:RETIRE_LOG-1];
    logic [31:0] retire_log_pc [0:RETIRE_LOG-1];
    logic [31:0] retire_log_op [0:RETIRE_LOG-1];
    integer      retire_log_ptr = 0;
    integer      opcode_mismatches = 0;

    function automatic logic in_boot(input logic [31:0] pc);
        in_boot = ((pc & 32'hdff8_0000) == 32'h9fc0_0000);
    endfunction

    task automatic dump_retire_log;
        integer i, k;
        logic [31:0] want;
        begin
            $display("  last %0d retires (oldest first), errors=%02x:",
                RETIRE_LOG, debug_errors);
            for (i = 0; i < RETIRE_LOG; i = i + 1) begin
                k = (retire_log_ptr + i) % RETIRE_LOG;
                if (retire_log_n[k] != 0) begin
                    if (in_boot(retire_log_pc[k])) begin
                        want = expected_boot_opcode(retire_log_pc[k][18:0]);
                        $display("    retired=%0d pc=%08x op=%08x want=%08x%0s",
                            retire_log_n[k], retire_log_pc[k],
                            retire_log_op[k], want,
                            (retire_log_op[k] !== want) ? "   <-- MISMATCH"
                                                        : "");
                    end else
                        $display("    retired=%0d pc=%08x op=%08x (non-boot)",
                            retire_log_n[k], retire_log_pc[k],
                            retire_log_op[k]);
                end
            end
        end
    endtask

    always @(posedge clk_1x) begin
        if (cpu_reset) begin
            boot_fetch_active <= 1'b0;
            boot_fetch_base <= 32'd0;
            boot_fetch_beat <= 0;
        end else begin
            if (cpu_cache_grant || cpu_cache_data_ready) begin
                if (fill_trace_count < 24) begin
                    fill_trace_count <= fill_trace_count + 1;
                    $display("FILL: t=%0t grant=%0b ready=%0b active=%0b beat=%0d state=%0d addr=%08x",
                        $time, cpu_cache_grant, cpu_cache_data_ready,
                        boot_fetch_active, boot_fetch_beat, bridge.state,
                        bridge.operation_address);
                end
            end

            if (cpu_cache_grant) begin
                boot_fetch_active <= 1'b1;
                boot_fetch_beat <= 0;
            end

            if (cpu_cache_data_ready) begin
                if (!boot_fetch_active && !cpu_cache_grant) begin
                    $display("FAIL: cache data without monitored fill address=%08x state=%0d",
                        bridge.operation_address, bridge.state);
                    $fatal(1);
                end

                // Align to the DOUBLEWORD, not the 32-byte line. Beats are 8
                // bytes and a cache line already starts 32-byte aligned, so
                // this is right for a 4-beat fill; forcing [31:5] is wrong for
                // the single-beat 64-bit uncached reads that LDL/LDR issue,
                // and would report a mismatch against correct data.
                boot_fetch_base =
                    {bridge.operation_address[31:3], 3'b000};
                if ((boot_fetch_base >= 32'h1fc0_0000) &&
                    (boot_fetch_base < 32'h1fc8_0000)) begin
                    boot_fetch_offset =
                        (boot_fetch_base - 32'h1fc0_0000) +
                        (boot_fetch_beat * 8);
                    boot_fetch_expected =
                        expected_boot_qword(boot_fetch_offset);

                    if (cpu_cache_data !== boot_fetch_expected) begin
                        $display("FAIL: boot fetch mismatch base=%08x beat=%0d offset=%05x actual=%016x expected=%016x bridge_addr=%08x read_addr=%04x read_data=%016x state=%0d retired=%0d pc=%08x",
                            boot_fetch_base, boot_fetch_beat,
                            boot_fetch_offset, cpu_cache_data,
                            boot_fetch_expected, bridge.operation_address,
                            bridge.boot_cache_read_address,
                            bridge.boot_cache_read_data, bridge.state,
                            debug_retired, debug_pc);
                        $fatal(1);
                    end

                    if ((boot_fetch_offset >= 32'h0000_7fc0) &&
                        (boot_fetch_offset <= 32'h0000_8040))
                        $display("BOOT FETCH OK: base=%08x beat=%0d offset=%05x data=%016x retired=%0d pc=%08x",
                            boot_fetch_base, boot_fetch_beat,
                            boot_fetch_offset, cpu_cache_data,
                            debug_retired, debug_pc);
                end

                if (boot_fetch_beat == 3)
                    boot_fetch_active <= 1'b0;
                else
                    boot_fetch_beat <= boot_fetch_beat + 1;
            end
        end
    end

    task automatic read_disk_sector(input logic [31:0] lba);
        begin
            disk_seek_result = $fseek(disk_file, lba * 512, 0);
            if (disk_seek_result != 0) begin
                $display("FAIL: could not seek KI disk to LBA %0d", lba);
                $fatal(1);
            end
            for (disk_byte = 0; disk_byte < 512;
                 disk_byte = disk_byte + 1) begin
                disk_character = $fgetc(disk_file);
                if (disk_character < 0) begin
                    $display("FAIL: short KI disk read at LBA %0d byte %0d",
                        lba, disk_byte);
                    $fatal(1);
                end
                disk_bytes[disk_byte] = disk_character[7:0];
            end
        end
    endtask

    always @(posedge clk_1x) begin
        sd_buff_wr <= 1'b0;

        if (!disk_active && (sd_rd || sd_wr)) begin
            disk_active <= 1'b1;
            disk_is_write <= sd_wr;
            disk_phase <= 0;
            sd_ack <= 1'b1;

            if (sd_rd) begin
                read_disk_sector(sd_lba);
                disk_read_count <= disk_read_count + 1;
                $display("DISK READ %0d: LBA=%0d retired=%0d pc=%08x",
                    disk_read_count + 1, sd_lba, debug_retired, debug_pc);
            end else begin
                disk_write_count <= disk_write_count + 1;
                $display("DISK WRITE %0d: LBA=%0d retired=%0d pc=%08x",
                    disk_write_count + 1, sd_lba, debug_retired, debug_pc);
            end
        end else if (disk_active) begin
            if (disk_phase < 256) begin
                sd_buff_addr <= disk_phase[7:0];
                if (!disk_is_write) begin
                    disk_word = disk_phase * 2;
                    sd_buff_dout <= {
                        disk_bytes[disk_word + 1],
                        disk_bytes[disk_word]
                    };
                    sd_buff_wr <= 1'b1;
                end
                disk_phase <= disk_phase + 1;
            end else if (disk_phase == 256) begin
                disk_phase <= disk_phase + 1;
            end else begin
                sd_ack <= 1'b0;
                disk_active <= 1'b0;
                disk_complete_count <= disk_complete_count + 1;
                $display("DISK COMPLETE %0d: read=%0d write=%0d",
                    disk_complete_count + 1, !disk_is_write,
                    disk_is_write);
            end
        end
    end

    integer board_access_count;
    integer ata_command_count;
    integer ata_data_read_count;
    integer reported_write;
    logic [31:0] last_debug_retired;
    logic [31:0] last_compared_retired;
    logic        reported_error_instr;

    always @(posedge clk_1x) begin
        if (!cpu_reset && io_request && board_done) begin
            board_access_count <= board_access_count + 1;
            if (board_access_count < 8)
                $display("BOARD IO %0d: write=%0d addr=%08x data=%08x",
                    board_access_count + 1, io_write, io_address,
                    io_write_data);
        end

        if (!cpu_reset && io_request && ata_done && io_write &&
            (io_address[5:3] == 3'd7) &&
            (io_address >= 32'h1000_0100) &&
            (io_address <= 32'h1000_013f)) begin
            ata_command_count <= ata_command_count + 1;
            $display("ATA COMMAND %0d: command=%02x retired=%0d pc=%08x",
                ata_command_count + 1, io_write_data[7:0],
                debug_retired, debug_pc);
        end

        if (!cpu_reset && io_request && ata_done && !io_write &&
            (io_address[5:3] == 3'd0) &&
            (io_address >= 32'h1000_0100) &&
            (io_address <= 32'h1000_013f))
            ata_data_read_count <= ata_data_read_count + 1;

        if (!cpu_reset && (debug_write_count != 0) && !reported_write) begin
            reported_write <= 1;
            $display("FIRST RAM WRITE: addr=%08x data=%016x count=%0d retired=%0d",
                debug_last_write_address, debug_last_write_data,
                debug_write_count, debug_retired);
        end

        if (!cpu_reset && debug_errors[0] && !reported_error_instr) begin
            reported_error_instr <= 1'b1;
            $display("ERROR_INSTR: fetch=%08x retired=%0d", debug_pc,
                debug_retired);
            $display("  history0 pc=%08x op=%08x cacheop=%02x",
                debug_ram_pc0, debug_ram_op0, debug_ram_op0[20:16]);
            $display("  history1 pc=%08x op=%08x cacheop=%02x",
                debug_ram_pc1, debug_ram_op1, debug_ram_op1[20:16]);
            $display("  history2 pc=%08x op=%08x cacheop=%02x",
                debug_ram_pc2, debug_ram_op2, debug_ram_op2[20:16]);
            $fatal(1, "illegal CACHE operation reached");
        end

        if ((disk_complete_count != 0) &&
            (ata_data_read_count >= 256) &&
            (debug_write_count != 0)) begin
            $display("PASS: KI boot consumed a real disk sector and wrote RAM");
            $display("SUMMARY: retired=%0d pc=%08x writes=%0d low=%0d main=%0d board=%0d commands=%0d pio=%0d lba=%0d fb=%05x irq=%0d errors=%02x",
                debug_retired, debug_pc, debug_write_count,
                debug_low_write_count, debug_main_write_count,
                board_access_count, ata_command_count, ata_data_read_count,
                sd_lba, framebuffer_base, debug_irq_count, debug_errors);
            $fclose(disk_file);
            $finish;
        end
    end

    always @(posedge clk_93) begin
        if (!cpu_reset && (debug_retired != last_compared_retired)) begin
            last_compared_retired <= debug_retired;

            if (debug_retired == 32'd2555) begin
                $display("PCDUMP: retire window at 2555 (video=%0d)", !no_video);
                dump_retire_log();
            end
            retire_log_n[retire_log_ptr]  <= debug_retired;
            retire_log_pc[retire_log_ptr] <= debug_retire_pc;
            retire_log_op[retire_log_ptr] <= debug_retire_opcode;
            retire_log_ptr <= (retire_log_ptr + 1) % RETIRE_LOG;

            if (debug_retired <= 16)
                $display("RETIRE %0d: pc=%08x opcode=%08x expected=%08x",
                    debug_retired, debug_retire_pc,
                    debug_retire_opcode,
                    expected_boot_opcode(debug_retire_pc[18:0]));

            if (((debug_retire_pc & 32'hdff8_0000) ==
                 32'h9fc0_0000) &&
                (debug_retire_opcode !==
                 expected_boot_opcode(debug_retire_pc[18:0]))) begin
                $display("FAIL: boot opcode mismatch retired=%0d pc=%08x actual=%08x expected=%08x video_reads=%0d",
                    debug_retired, debug_retire_pc,
                    debug_retire_opcode,
                    expected_boot_opcode(debug_retire_pc[18:0]),
                    video_reads);
                opcode_mismatches <= opcode_mismatches + 1;
                if (opcode_mismatches == 0) begin
                    dump_retire_log();
                    dump_fill_log();
                end
                // Deliberately NOT fatal: whether execution diverges after
                // this is what separates real instruction corruption from a
                // debug-export artifact. A cosmetic zero changes nothing
                // downstream; a real one derails control flow.
                if (opcode_mismatches >= 12)
                    $fatal(1, "%0d opcode mismatches - execution has diverged",
                        opcode_mismatches + 1);
            end
        end

        if (!cpu_reset &&
            (debug_retired != last_debug_retired) &&
            ((debug_retired % 10000) == 0)) begin
            last_debug_retired <= debug_retired;
            $display("PROGRESS: retired=%0d pc=%08x writes=%0d board=%0d ata=%0d state=%0d status=%02x vblank=%0d",
                debug_retired, debug_pc, debug_write_count,
                board_access_count, ata_command_count, ata_debug_state,
                ata_debug_status, vblank_count);
        end
    end

    // Time-based heartbeat. The retire-count PROGRESS message only fires
    // every 10000 instructions, so a run that is merely slow and a run that
    // hung at instruction 17 look identical for hours. This distinguishes
    // them and gives a retires-per-second rate to plan against.
    integer probe_heartbeat;
    logic [31:0] probe_hb_last;
    integer probe_hb_same;
    initial begin
        probe_heartbeat = 0;
        probe_hb_last = 32'hffffffff;
        probe_hb_same = 0;
    end
    always @(posedge clk_1x) begin
        if (!cpu_reset) begin
            probe_heartbeat <= probe_heartbeat + 1;
            if ((probe_heartbeat % 5000) == 0) begin
                $display("HEARTBEAT: t=%0t retired=%0d pc=%08x writes=%0d video=%0d",
                    $time, debug_retired, debug_pc, debug_write_count,
                    video_reads);
                // Two consecutive quiet heartbeats with a non-zero retire
                // count means the pipeline is wedged, not merely slow. Dump
                // the bus once and stop, instead of grinding to the 25 ms
                // timeout with nothing to show for it.
                if ((debug_retired == probe_hb_last) && (debug_retired != 0))
                    probe_hb_same <= probe_hb_same + 1;
                else
                    probe_hb_same <= 0;
                probe_hb_last <= debug_retired;

                if (probe_hb_same >= 1) begin
                    $display("");
                    $display("STALL: retired=%0d pc=%08x", debug_retired,
                        debug_pc);
                    $display("  CPU  req=%0b rnw=%0b addr=%08x req64=%0b size=%0d",
                        cpu_request, cpu_rnw, cpu_address, cpu_req64,
                        cpu_size);
                    $display("  CPU  done=%0b grant=%0b cache_ready=%0b cache_data=%016x",
                        cpu_done, cpu_cache_grant, cpu_cache_data_ready,
                        cpu_cache_data);
                    $display("  BR   state=%0d cpu_pending=%0b cpu_grant=%0b cpu_done=%0b",
                        bridge.state, bridge.cpu_pending, bridge.cpu_grant,
                        bridge.cpu_done);
                    $display("  BR   op_addr=%08x op_req64=%0b beats_left=%0d words_left=%0d",
                        bridge.operation_address, bridge.operation_req64,
                        bridge.read_beats_remaining,
                        bridge.read_words_remaining);
                    $display("  SDR  read=%0b write=%0b addr=%07x ready=%0b done=%0b",
                        sdram_read, sdram_write, sdram_address, sdram_ready,
                        sdram_done);
                    $display("  errors=%02x", debug_errors);
                    $finish;
                end
            end
        end
    end

    // ---- cache-fill ring buffer -------------------------------------------
    // Records what the bridge actually delivered for the last few fills, with
    // the state that served them, so a corrupt fetch can be traced to a path
    // rather than guessed at. bridge.state names (rtl/ki_memory_bridge.sv):
    //   0 IDLE  1 BOOT_CACHE_READ_WAIT  2 BOOT_CACHE_READ_RETURN
    //   3 SDRAM_READ_ISSUE  4 SDRAM_READ_WAIT  ...
    //   14 ROM_LINE_FILL_ISSUE  15 ROM_LINE_FILL_WAIT  16 ROM_LINE_RETURN
    localparam int FILL_LOG = 24;
    logic [63:0] fill_log_time  [0:FILL_LOG-1];
    logic [31:0] fill_log_addr  [0:FILL_LOG-1];
    logic [63:0] fill_log_data  [0:FILL_LOG-1];
    logic  [4:0] fill_log_state [0:FILL_LOG-1];
    logic        fill_log_video [0:FILL_LOG-1];
    integer      fill_log_ptr = 0;
    integer      fill_log_seen = 0;

    always @(posedge clk_1x) begin
        if (!cpu_reset && cpu_cache_data_ready) begin
            fill_log_time[fill_log_ptr]  <= $time;
            fill_log_addr[fill_log_ptr]  <= bridge.operation_address;
            fill_log_data[fill_log_ptr]  <= cpu_cache_data;
            fill_log_state[fill_log_ptr] <= bridge.state;
            fill_log_video[fill_log_ptr] <= video_request;
            fill_log_ptr  <= (fill_log_ptr + 1) % FILL_LOG;
            fill_log_seen <= fill_log_seen + 1;
        end
    end

    task automatic dump_fill_log;
        integer i, k;
        begin
            $display("  last %0d cache fills (oldest first), total seen=%0d:",
                FILL_LOG, fill_log_seen);
            for (i = 0; i < FILL_LOG; i = i + 1) begin
                k = (fill_log_ptr + i) % FILL_LOG;
                if (fill_log_time[k] != 0)
                    $display("    t=%0t addr=%08x state=%0d video=%0b data=%016x",
                        fill_log_time[k], fill_log_addr[k], fill_log_state[k],
                        fill_log_video[k], fill_log_data[k]);
            end
        end
    endtask

    logic [31:0] probe_last_retired;
    logic        probe_gate_seen;
    logic        probe_init_seen;
    logic        probe_scan_seen;
    logic [31:0] probe_finish_at;
    logic        probe_gate_only;
    integer      probe_reader_calls;
    integer      probe_scan_hits;

    // Early boot runs UNCACHED, out of KSEG1 (bfc0xxxx); the addresses MAME
    // reports are the KSEG0 aliases (9fc0xxxx). They differ only in bit 29,
    // so match on the alias-independent address or the probe sees nothing.
    // The opcode check above already does this with its 32'hdff8_0000 mask.
    wire [31:0] probe_pc = debug_retire_pc & 32'hdfff_ffff;

    initial begin
        probe_last_retired = 32'd0;
        probe_gate_seen    = 1'b0;
        probe_init_seen    = 1'b0;
        probe_scan_seen    = 1'b0;
        probe_finish_at    = 32'd0;
        probe_reader_calls = 0;
        probe_scan_hits    = 0;
        // Reaching the disk-boot milestone takes hours of wall clock. When
        // only the gate is in question, stop shortly after it resolves.
        probe_gate_only    = $test$plusargs("gate_only");
        no_video           = $test$plusargs("no_video");
    end

    always @(posedge clk_93) begin
        if (!cpu_reset && (debug_retired != probe_last_retired)) begin
            probe_last_retired <= debug_retired;

            if (probe_gate_only && (probe_finish_at != 0) &&
                (debug_retired >= probe_finish_at)) begin
                $display("GATE: done. initialiser_ran=%0d scan_entered=%0d scan_hits=%0d reader_calls=%0d video_reads=%0d opcode_mismatches=%0d",
                    probe_init_seen, probe_scan_seen, probe_scan_hits,
                    probe_reader_calls, video_reads, opcode_mismatches);
                $finish;
            end

            case (probe_pc)
                32'h9fc0_0d48: begin
                    probe_reader_calls <= probe_reader_calls + 1;
                    $display("GATE: reader entered call=%0d retired=%0d",
                        probe_reader_calls + 1, debug_retired);
                end
                32'h9fc0_0724:
                    $display("GATE: jal reader retired=%0d", debug_retired);
                32'h9fc0_073c: begin
                    probe_gate_seen <= 1'b1;
                    // Golden model over the real ROM (tools/bitreader_model.py)
                    // says this must be 88000000.
                    $display("GATE: beq t2,zero  t2=%08x v0=%08x retired=%0d expected=88000000 -> %0s",
                        debug_t2, debug_v0, debug_retired,
                        (debug_t2 == 32'd0) ? "SKIP initialiser (BAD)"
                                            : "RUN initialiser (GOOD)");
                    probe_finish_at <= debug_retired + 32'd4000;
                end
                32'h9fc0_0cb8: if (!probe_init_seen) begin
                    probe_init_seen <= 1'b1;
                    $display("GATE: initialiser running retired=%0d v1=%08x a1=%08x",
                        debug_retired, debug_v1, debug_a1);
                end
                32'h9fc0_0cd8: begin
                    probe_scan_hits <= probe_scan_hits + 1;
                    if (!probe_scan_seen) begin
                        probe_scan_seen <= 1'b1;
                        $display("GATE: scan loop entered retired=%0d a1=%08x",
                            debug_retired, debug_a1);
                    end
                end
                default: ;
            endcase
        end
    end

    initial begin
        ioctl_download = 1'b0;
        ioctl_index = 16'd1;
        ioctl_wr = 1'b0;
        ioctl_addr = '0;
        ioctl_dout = '0;
        ddram_busy = 1'b0;
        ddram_dout = '0;
        ddram_dout_ready = 1'b0;
        img_mounted = 1'b0;
        sd_ack = 1'b0;
        sd_buff_addr = '0;
        sd_buff_dout = '0;
        sd_buff_wr = 1'b0;
        disk_active = 1'b0;
        disk_is_write = 1'b0;
        disk_phase = 0;
        disk_read_count = 0;
        disk_write_count = 0;
        disk_complete_count = 0;
        boot_ready = 1'b0;
        boot_fetch_active = 1'b0;
        boot_fetch_base = 32'd0;
        boot_fetch_beat = 0;
        boot_fetch_offset = 0;
        boot_fetch_expected = 64'd0;
        board_access_count = 0;
        ata_command_count = 0;
        ata_data_read_count = 0;
        reported_write = 0;
        reported_error_instr = 0;
        last_debug_retired = 0;
        last_compared_retired = 0;

        $readmemh("sim/media/kinst_boot.hex", boot_rom);

        // In gate-only mode, shorten the deterministic init sweeps exactly the
        // way tb_ki_cpu_boot's FAST_BOOT does. Every one of these is a loop
        // COUNT, so control flow is preserved:
        //   03ec  dcache init   255 -> 3 iterations
        //   0438  icache init   255 -> 3
        //   0484  RAM clear     lui a1,0x8008 -> addiu a1,a0,32  (40960 -> 4)
        //   04a0  read sweep   8192 -> 4
        //   04c8  cop0 sweep     47 -> 3
        // None touches the gate at 073c or the reader at 0d14, and the cleared
        // range (00030000..00080000) does not cover the reader's context block
        // at 087fff00 or the table at 087fff10. The light bench reaches the
        // correct gate value with exactly these applied.
        if ($test$plusargs("gate_only")) begin
            patch_boot_word('h03ec, 32'h2403_0003);
            patch_boot_word('h0438, 32'h2403_0003);
            patch_boot_word('h0484, 32'h2485_0020);
            patch_boot_word('h04a0, 32'h2403_0004);
            patch_boot_word('h04c8, 32'h2403_0003);
            $display("GATE: init sweeps shortened (gate_only)");
        end
        disk_file = $fopen("../games/kinst/kinst.img", "rb");
        if (disk_file == 0) begin
            $display("FAIL: could not open ../games/kinst/kinst.img");
            $fatal(1);
        end

        for (integer address = 0;
             address < BOOT_BYTES; address = address + 2)
            sdram_poke((STORE_BOOT + address) >> 1,
                       {boot_rom[address + 1], boot_rom[address]});

        for (integer word = 0; word < (BOOT_CACHE_BYTES / 8);
             word = word + 1)
            bridge.boot_cache[word] = expected_boot_qword(word * 8);

        repeat (8) @(posedge clk_1x);
        init = 1'b0;
        wait (sdram_ready);
        $display("SDRAM: controller initialised at t=%0t", $time);
        repeat (8) @(posedge clk_1x);
        boot_ready <= 1'b1;
        reset <= 1'b0;
        @(negedge clk_1x);
        img_mounted <= 1'b1;
        @(negedge clk_1x);
        img_mounted <= 1'b0;

        $display("Boot image preloaded, image ready=%0d", ata_image_ready);
    end

    initial begin
        #(64'd25000000000);
        $display("FAIL: system timeout pc=%08x retired=%0d writes=%0d low=%0d main=%0d board=%0d commands=%0d disk=%0d pio=%0d ata_state=%0d status=%02x error=%02x vblank=%0d cpu_errors=%02x",
            debug_pc, debug_retired, debug_write_count,
            debug_low_write_count, debug_main_write_count,
            board_access_count, ata_command_count, disk_complete_count,
            ata_data_read_count, ata_debug_state, ata_debug_status,
            ata_debug_error, vblank_count, debug_errors);
        $fatal(1);
    end

endmodule
