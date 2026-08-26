`timescale 1ps/1ps

module tb_ki_cpu_bridge_boot;

    localparam int BOOT_BYTES = 524288;
    localparam int BOOT_CACHE_BYTES = 8 * 1024;
    localparam logic [27:0] STORE_BOOT = 28'h090_0000;

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

    logic [24:0] sdram_address;
    // 64 bits and eight byte enables, one pair per word of a write burst - the
    // bridge has driven this width since stores became bursts. This was [15:0]
    // and [1:0], which silently truncated every store.
    logic [63:0] sdram_write_data;
    logic  [7:0] sdram_byte_enable;
    logic  [4:0] sdram_burst;
    logic [15:0] sdram_read_data;
    logic        sdram_data_valid;
    logic        sdram_read;
    logic        sdram_write;
    logic        sdram_done;
    logic        sdram_ready;

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
    wire         cpu_reset = reset | ioctl_download | ~boot_loaded | ~sdram_ready;
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

    logic        video_request;
    logic [27:0] video_address;
    logic  [2:0] video_words;
    logic [63:0] video_data;
    logic        video_data_valid;
    logic        video_done;

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
        .debug_ram_pc0(),
        .debug_ram_op0(),
        .debug_ram_pc1(),
        .debug_ram_op1(),
        .debug_ram_pc2(),
        .debug_ram_op2(),
        .debug_rom_return_pc(),
        .debug_rom_return_prev(),
        .debug_stall_pc(),
        .debug_stall_status(),
        .debug_retire_pc(),
        .debug_retire_opcode()
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

    localparam int unsigned SDRAM_MODEL_LATENCY = 6;

    logic [15:0] sdram_memory [logic [24:0]];

    logic        sdr_busy     = 1'b0;
    logic        sdr_is_write = 1'b0;
    logic  [3:0] sdr_latency  = 4'd0;
    logic [24:0] sdr_addr     = 25'd0;
    logic  [4:0] sdr_words    = 5'd0;
    logic [63:0] sdr_data     = 64'd0;
    logic  [7:0] sdr_enables  = 8'd0;
    logic        sdr_finish   = 1'b0;
    integer      sdr_word;
    logic [24:0] sdr_target;

    always @(posedge clk_1x) begin
        sdram_done       <= 1'b0;
        sdram_data_valid <= 1'b0;

        // Raised the cycle AFTER the burst's last beat, never alongside it.
        if (sdr_finish) begin
            sdr_finish <= 1'b0;
            sdram_done <= 1'b1;
        end

        if (sdr_busy) begin
            if (sdr_latency != 0) begin
                sdr_latency <= sdr_latency - 1'b1;
            end else if (sdr_is_write) begin
                for (sdr_word = 0; sdr_word < 4; sdr_word = sdr_word + 1) begin
                    if (sdr_word < sdr_words) begin
                        sdr_target = sdr_addr + sdr_word[24:0];
                        // Seed a missing location before a partial write, so a
                        // byte store cannot leave the other half X.
                        if (!sdram_memory.exists(sdr_target))
                            sdram_memory[sdr_target] = 16'h0000;
                        if (sdr_enables[sdr_word * 2])
                            sdram_memory[sdr_target][7:0] =
                                sdr_data[sdr_word * 16 +: 8];
                        if (sdr_enables[(sdr_word * 2) + 1])
                            sdram_memory[sdr_target][15:8] =
                                sdr_data[(sdr_word * 16) + 8 +: 8];
                    end
                end
                sdr_busy   <= 1'b0;
                sdram_done <= 1'b1;
            end else begin
                sdram_read_data  <= sdram_memory.exists(sdr_addr) ?
                                    sdram_memory[sdr_addr] : 16'h0000;
                sdram_data_valid <= 1'b1;
                sdr_addr         <= sdr_addr + 1'b1;
                if (sdr_words <= 5'd1) begin
                    sdr_busy   <= 1'b0;
                    sdr_finish <= 1'b1;
                end else begin
                    sdr_words <= sdr_words - 1'b1;
                end
            end
        end else if (sdram_read || sdram_write) begin
            sdr_busy     <= 1'b1;
            sdr_is_write <= sdram_write;
            sdr_latency  <= SDRAM_MODEL_LATENCY[3:0];
            sdr_addr     <= sdram_address;
            sdr_words    <= (sdram_burst == 5'd0) ? 5'd1 : sdram_burst;
            sdr_data     <= sdram_write_data;
            sdr_enables  <= sdram_byte_enable;
        end
    end

    assign io_read_data = 32'hffff_ffff;
    assign io_done = io_request;

    byte boot_rom [0:BOOT_BYTES-1];
    integer trace_file;
    integer bus_file;
    logic [31:0] last_debug_retired;
    integer io_count;
    integer cache_word;
    logic [63:0] expected_cache_data;

    task automatic send_boot_halfword(input integer byte_address);
        begin
            // Present each transfer away from the active edge and hold it until
            // the bridge accepts it, matching the MiSTer ioctl ready/valid contract.
            @(negedge clk_1x);
            ioctl_addr = byte_address[26:0];
            ioctl_dout = {boot_rom[byte_address + 1], boot_rom[byte_address]};
            ioctl_wr = 1'b1;
            do begin
                @(posedge clk_1x);
            end while (ioctl_wait);
            @(negedge clk_1x);
            ioctl_wr = 1'b0;
        end
    endtask

    always @(posedge clk_1x) begin
        if (!cpu_reset && cpu_request)
            $fwrite(bus_file, "%0t req=%0d rnw=%0d size=%x addr=%08x data=%016x mask=%02x\n",
                $time, cpu_request, cpu_rnw, cpu_size, cpu_address,
                cpu_write_data, cpu_write_mask);

        if (!cpu_reset && io_request) begin
            io_count <= io_count + 1;
            $display("FIRST IO: write=%0d addr=%08x data=%08x retired=%0d",
                io_write, io_address, io_write_data, debug_retired);
            if (io_count == 0) begin
                if (io_address !== 32'h1000_0080) begin
                    $display("FAIL: expected first KI board access at 10000080");
                    $fatal(1);
                end
                $display("PASS: production CPU/bridge path reached KI board I/O");
                $fclose(trace_file);
                $fclose(bus_file);
                $finish;
            end
        end
    end

    always @(posedge clk_93) begin
        if (!cpu_reset && (debug_retired != last_debug_retired)) begin
            last_debug_retired <= debug_retired;
            $fwrite(trace_file,
                "%0d pc=%08x v0=%08x v1=%08x a0=%08x a1=%08x t2=%08x a3=%08x s5=%08x s6=%08x ra=%08x errors=%02x\n",
                debug_retired, debug_pc, debug_v0,
                debug_v1, debug_a0, debug_a1, debug_t2, debug_a3,
                debug_s5, debug_s6, debug_ra, debug_errors);
        end
    end

    initial begin
        ioctl_download = 1'b0;
        ioctl_index = 16'd1;
        ioctl_wr = 1'b0;
        ioctl_addr = '0;
        ioctl_dout = '0;
        sdram_read_data = '0;
        sdram_data_valid = 1'b0;
        sdram_done = 1'b0;
        sdram_ready = 1'b1;
        ddram_busy = 1'b0;
        ddram_dout = '0;
        ddram_dout_ready = 1'b0;
        video_request = 1'b0;
        video_address = '0;
        video_words = 3'd1;
        last_debug_retired = 0;
        io_count = 0;
        irq = 2'b00;

        $readmemh("sim/media/kinst_boot.hex", boot_rom);
        trace_file = $fopen("sim/cpu_bridge_trace.log", "w");
        bus_file = $fopen("sim/cpu_bridge_bus_trace.log", "w");

        repeat (8) @(posedge clk_1x);
        reset <= 1'b0;
        repeat (4) @(posedge clk_1x);

        ioctl_download <= 1'b1;
        for (integer address = 0; address < BOOT_BYTES;
             address = address + 2) begin
            send_boot_halfword(address);
            if ((address % 65536) == 65534)
                $display("DOWNLOAD: %0d KiB of %0d at t=%0t",
                         (address + 2) / 1024, BOOT_BYTES / 1024, $time);
        end
        ioctl_download <= 1'b0;

        while (!boot_loaded)
            @(posedge clk_1x);

        for (cache_word = 0; cache_word < BOOT_CACHE_BYTES / 8;
             cache_word = cache_word + 1) begin
            expected_cache_data = {
                boot_rom[(cache_word * 8) + 7],
                boot_rom[(cache_word * 8) + 6],
                boot_rom[(cache_word * 8) + 5],
                boot_rom[(cache_word * 8) + 4],
                boot_rom[(cache_word * 8) + 3],
                boot_rom[(cache_word * 8) + 2],
                boot_rom[(cache_word * 8) + 1],
                boot_rom[(cache_word * 8) + 0]
            };
            if (bridge.boot_cache[cache_word] !== expected_cache_data) begin
                $display(
                    "FAIL: boot cache mismatch at %08x expected=%016x actual=%016x",
                    cache_word * 8, expected_cache_data,
                    bridge.boot_cache[cache_word]
                );
                $fatal(1);
            end
        end

        for (integer address = BOOT_CACHE_BYTES;
             address < BOOT_BYTES; address = address + 2) begin
            if (!sdram_memory.exists((STORE_BOOT + address) >> 1)) begin
                $display("FAIL: missing boot SDRAM word at %08x", address);
                $fatal(1);
            end
            if (sdram_memory[(STORE_BOOT + address) >> 1] !== {
                boot_rom[address + 1], boot_rom[address]
            }) begin
                $display(
                    "FAIL: boot SDRAM mismatch at %08x expected=%04x actual=%04x",
                    address, {boot_rom[address + 1], boot_rom[address]},
                    sdram_memory[(STORE_BOOT + address) >> 1]
                );
                $fatal(1);
            end
        end

        $display("PASS: complete 512 KiB boot ROM loaded and verified");
    end

    localparam longint STALL_LIMIT_PS   = 64'd200_000_000;      // 200 us
    // Comfortably past the ~14.4 ms download plus the short boot to board I/O,
    // and only reachable by a failure that keeps making progress - anything
    // that stops is caught by the two progress watchdogs first.
    localparam longint OVERALL_LIMIT_PS = 64'd40_000_000_000;   //  40 ms

    task automatic dump_state(input string reason);
        begin
            $display("STALL: %0s at t=%0t", reason, $time);
            $display("  CPU  pc=%08x retired=%0d writes=%0d io=%0d errors=%02x reset=%0d",
                debug_pc, debug_retired, debug_write_count, io_count,
                debug_errors, cpu_reset);
            $display("  BR   state=%0d cpu_pending=%0d words_left=%0d",
                bridge.state, bridge.cpu_pending, bridge.read_words_remaining);
            $display("  REQ  addr=%07x burst=%0d rd=%0d wr=%0d",
                sdram_address, sdram_burst, sdram_read, sdram_write);
            $display("  SDR  busy=%0d write=%0d latency=%0d words_left=%0d valid=%0d done=%0d ready=%0d",
                sdr_busy, sdr_is_write, sdr_latency, sdr_words,
                sdram_data_valid, sdram_done, sdram_ready);
        end
    endtask

    // Heartbeat once the CPU is running, for the same reason as the download
    // report: without it the only two outcomes visible from outside are "PASS"
    // and "still going", and they look the same for as long as you care to wait.
    // Half the stall limit, so a wedge always shows at least one heartbeat
    // before the dump - the last good state is worth having next to it.
    always begin
        #(STALL_LIMIT_PS / 2);
        if (!cpu_reset)
            $display("HEARTBEAT: t=%0t retired=%0d pc=%08x writes=%0d state=%0d",
                     $time, debug_retired, debug_pc, debug_write_count,
                     bridge.state);
    end

    // Progress watchdog. Only armed once the CPU is out of reset - the ROM
    // download runs with cpu_reset asserted and retires nothing by design.
    longint last_progress_time = 0;
    integer watchdog_retired = -1;

    always @(posedge clk_1x) begin
        if (cpu_reset) begin
            last_progress_time <= $time;
        end else if (debug_retired !== watchdog_retired) begin
            watchdog_retired   <= debug_retired;
            last_progress_time <= $time;
        end else if (($time - last_progress_time) > STALL_LIMIT_PS) begin
            dump_state($sformatf("no instruction retired for %0d us",
                                 STALL_LIMIT_PS / 1000000));
            $fatal(1, "FAIL: CPU or bridge stalled");
        end
    end

    // The download phase runs with cpu_reset asserted, so the retire watchdog
    // above is disarmed for all ~20 ms of it. Watch its own progress instead:
    // a wedged download FIFO parks ioctl_wait high and stops ioctl_addr dead.
    longint last_ioctl_time = 0;
    logic [26:0] watchdog_ioctl_addr = '1;

    always @(posedge clk_1x) begin
        if (!ioctl_download) begin
            last_ioctl_time <= $time;
        end else if (ioctl_addr !== watchdog_ioctl_addr) begin
            watchdog_ioctl_addr <= ioctl_addr;
            last_ioctl_time     <= $time;
        end else if (($time - last_ioctl_time) > STALL_LIMIT_PS) begin
            dump_state($sformatf("ROM download stopped at ioctl_addr=%06x, wait=%0d",
                                 ioctl_addr, ioctl_wait));
            $fatal(1, "FAIL: ROM download stalled");
        end
    end

    // Backstop for a failure that keeps making progress but never arrives.
    initial begin
        #(OVERALL_LIMIT_PS);
        dump_state("overall time limit reached");
        $fatal(1, "FAIL: did not reach KI board I/O within %0d ms",
               OVERALL_LIMIT_PS / 1000000000);
    end

endmodule
