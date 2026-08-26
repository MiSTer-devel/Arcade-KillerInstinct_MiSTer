// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_dcs_audio;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic host_reset = 1'b1;
    logic host_cmd_wr = 1'b0;
    logic [15:0] host_cmd_data = 16'h0000;
    wire [15:0] host_status;

    wire rom_req;
    wire [18:0] rom_addr;
    logic rom_rdy = 1'b0;
    logic [63:0] rom_q = 64'h0000_0000_0000_0000;

    wire signed [15:0] audio;
    wire dbg_valid;
    wire dbg_unimpl;
    wire dbg_pcm_push;
    wire [13:0] dbg_pc;

    integer rom_reads = 0;
    integer response_delay = 0;
    integer timeout;
    logic request_armed = 1'b1;
    logic response_pending = 1'b0;
    logic [18:0] response_address = '0;
    logic [18:0] first_response_address = '0;
    logic previous_dac_slot = 1'b0;
    integer dac_slot_pulses = 0;
    logic [15:0] injected_sample = 16'h0000;
    logic [15:0] forced_mstat = 16'h0000;
    // ModelSim rejects automatic (task-local) variables as force operands, so
    // the AV_LATCH cases drive these module-level signals instead.
    logic [15:0] forced_astat = 16'h0000;
    logic [31:0] dbg_pcm_health;
    logic [31:0] dbg_pcm_level;
    logic [31:0] forced_alu_res = 32'h0000_0000;

    always #10 clk = !clk;

    ki_dcs_audio #(
        .CLK_HZ(50000000),
        .DCS_ENGINE_HZ(32000000),
        .PCM_AW(4),
        .PCM_START_LEVEL(4),
        .STARTUP_RAMP_BITS(2)
    ) dut (
        .clk(clk),
        .rst(rst),
        .host_reset(host_reset),
        .host_cmd_wr(host_cmd_wr),
        .host_cmd_data(host_cmd_data),
        .host_status(host_status),
        .rom_req(rom_req),
        .rom_addr(rom_addr),
        .rom_rdy(rom_rdy),
        .rom_q(rom_q),
        .audio(audio),
        .dbg_valid(dbg_valid),
        .dbg_unimpl(dbg_unimpl),
        .dbg_pcm_push(dbg_pcm_push),
        .dbg_pc(dbg_pc),
        .dbg_pcm_health(dbg_pcm_health),
        .dbg_pcm_level(dbg_pcm_level)
    );

    // Return each ROM beat on an ordinary 50 MHz clock, deliberately without
    // aligning it to the ADSP architectural enable. Beat zero contains a 0x0f
    // boot header in byte lane three, selecting 128 words; all executable bytes
    // remain zero (ADSP NOP). The DCS memory shim must latch this one-cycle
    // response until the core can consume it.
    always_ff @(posedge clk) begin
        rom_rdy <= 1'b0;
        if (!rom_req)
            request_armed <= 1'b1;

        if (rom_req && request_armed && !response_pending) begin
            request_armed <= 1'b0;
            response_pending <= 1'b1;
            response_delay <= 3;
            response_address <= rom_addr;
            if (rom_reads == 0)
                first_response_address <= rom_addr;
            rom_reads <= rom_reads + 1;
        end else if (response_pending && response_delay != 0) begin
            response_delay <= response_delay - 1;
        end else if (response_pending) begin
            response_pending <= 1'b0;
            rom_q <= (response_address == 19'h00000)
                   ? 64'h0000_0000_0f00_0000
                   : 64'h0000_0000_0000_0000;
            rom_rdy <= 1'b1;
        end
    end

    // dac_ce_in is observed by the ADSP on every fabric clock, not just on a
    // core_ce cycle. A stretched slot would make one 31.25 kHz event count as
    // multiple autobuffer periods and eventually produce an audio discontinuity.
    always_ff @(posedge clk) begin
        if (rst) begin
            previous_dac_slot <= 1'b0;
            dac_slot_pulses <= 0;
        end else begin
            if (dut.dcs_dac_ce !== dut.dac_slot_ce)
                $fatal(1, "DCS DAC slot was stretched beyond its physical pulse");
            if (dut.dcs_dac_ce && previous_dac_slot)
                $fatal(1, "DCS DAC slot remained asserted for consecutive clocks");
            if (dut.dcs_dac_ce)
                dac_slot_pulses <= dac_slot_pulses + 1;
            previous_dac_slot <= dut.dcs_dac_ce;
        end
    end

    task automatic wait_for_boot;
        begin
            timeout = 0;
            while (!dbg_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 5000)
                    $fatal(1, "DCS boot did not reach instruction execution");
            end
        end
    endtask

    task automatic inject_sample(input logic [15:0] sample);
        begin
            @(negedge clk);
            injected_sample = sample;
            force dut.dcs_sample = injected_sample;
            force dut.dcs_sample_we = 1'b1;
            @(posedge clk);
            #1;
            release dut.dcs_sample;
            release dut.dcs_sample_we;
        end
    endtask

    task automatic wait_for_dac_slot;
        begin
            @(posedge clk);
            while (!dut.dac_slot_ce)
                @(posedge clk);
            #1;
        end
    endtask

    task automatic check_alu_writeback(
        input logic dst_af,
        input logic saturation,
        input logic carry,
        input logic [15:0] raw_result,
        input logic [15:0] expected,
        input integer test_id
    );
        begin
            @(negedge clk);
            forced_mstat = saturation ? 16'h0008 : 16'h0000;
            forced_alu_res = {
                carry ? 16'h000c : 16'h0004,
                raw_result
            };
            force dut.u_adsp.mstat = forced_mstat;
            force dut.u_adsp.alu_res = forced_alu_res;
            dut.u_adsp.alu_wb(dst_af);
            #1;
            if (dst_af) begin
                if (dut.u_adsp.afb[0] !== expected)
                    $fatal(1, "ADSP ALU writeback case %0d: AF=%04h expected %04h",
                           test_id, dut.u_adsp.afb[0], expected);
            end else if (dut.u_adsp.gr[10] !== expected) begin
                $fatal(1, "ADSP ALU writeback case %0d: AR=%04h expected %04h",
                       test_id, dut.u_adsp.gr[10], expected);
            end
            release dut.u_adsp.alu_res;
            release dut.u_adsp.mstat;
        end
    endtask

    // AV_LATCH (MSTAT bit 2). With the mode off, an ALU op clears the AV
    // overflow bit like every other arithmetic flag. With it on, AV is STICKY:
    // it survives the operation and only a direct ASTAT write clears it. The
    // bit was decoded by the mode-control instruction and then ignored, so
    // every ALU op cleared AV regardless - code that accumulates across
    // several ops and tests AV once at the end would miss the overflow, skip
    // its clamp, and let the sum wrap to the opposite rail.
    task automatic check_av_latch(input logic latch, input logic expect_av,
                                  input integer test_id);
        logic [31:0] r;
        begin
            @(negedge clk);
            forced_astat = 16'h0004;             // AV left set by an earlier op
            forced_mstat = latch ? 16'h0004 : 16'h0000;
            force dut.u_adsp.astat = forced_astat;
            force dut.u_adsp.mstat = forced_mstat;
            #1;
            // X+Y with 1+1: cannot overflow, so AV can only survive by latching.
            r = dut.u_adsp.alu_eval(4'h3, 16'h0001, 16'h0001);
            if (r[18] !== expect_av)
                $fatal(1, "AV_LATCH case %0d: AV=%b expected %b (astat_next=%04h)",
                       test_id, r[18], expect_av, r[31:16]);
            if (r[15:0] !== 16'h0002)
                $fatal(1, "AV_LATCH case %0d disturbed the ALU result: %04h",
                       test_id, r[15:0]);
            release dut.u_adsp.astat;
            release dut.u_adsp.mstat;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);
        host_reset = 1'b0;

        wait_for_boot();
        if (rom_reads == 0)
            $fatal(1, "DCS boot completed without an external ROM read");
        if (first_response_address !== 19'h00000)
            $fatal(1, "first DCS boot beat was %05h, expected 00000", first_response_address);
        if (host_status !== 16'h0c00)
            $fatal(1, "idle DCS host status was %04h, expected 0c00", host_status);
        if (dbg_unimpl)
            $fatal(1, "zero/NOP boot image reached an unimplemented instruction");
        if (audio !== 16'sh0000)
            $fatal(1, "silent DCS image produced audio sample %04h", audio);

        // MSTAT.SATURATE clamps overflowing AR results only. AF and disabled
        // saturation must retain the raw 16-bit ALU result.
        check_alu_writeback(1'b0, 1'b1, 1'b0, 16'h8000, 16'h7fff, 1);
        check_alu_writeback(1'b0, 1'b1, 1'b1, 16'h7fff, 16'h8000, 2);
        check_alu_writeback(1'b0, 1'b0, 1'b0, 16'h8123, 16'h8123, 3);
        check_alu_writeback(1'b1, 1'b1, 1'b0, 16'h5678, 16'h5678, 4);

        check_av_latch(1'b0, 1'b0, 1);   // mode off: AV clears as usual
        check_av_latch(1'b1, 1'b1, 2);   // mode on:  AV sticks

        // A complete KI host word must cross the 50-to-32 MHz enable boundary
        // exactly once and set INPUT_FULL (bit 11 clear).
        @(negedge clk);
        host_cmd_data = 16'ha55a;
        host_cmd_wr = 1'b1;
        @(negedge clk);
        host_cmd_wr = 1'b0;

        timeout = 0;
        while (host_status[11] != 1'b0) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 100)
                $fatal(1, "DCS host command did not set INPUT_FULL");
        end

        // Board reset must clear the mailbox and restart the boot stream.
        host_reset = 1'b1;
        repeat (8) @(posedge clk);
        if (host_status !== 16'h0c00)
            $fatal(1, "DCS reset status was %04h, expected 0c00", host_status);
        timeout = 0;
        while (dbg_valid) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 100)
                $fatal(1, "DCS reset did not leave instruction execution");
        end
        host_reset = 1'b0;
        wait_for_boot();

        repeat (3500) @(posedge clk);
        if (dbg_unimpl)
            $fatal(1, "DCS NOP stream raised the unimplemented flag");
        if (audio !== 16'sh0000)
            $fatal(1, "DCS output did not remain silent after reset");
        if (dac_slot_pulses < 2)
            $fatal(1, "DCS DAC timing test observed only %0d slots", dac_slot_pulses);

        // Playback must wait for a reserve, preserve full-scale signed PCM, and
        // re-arm the reserve after a genuine underrun -- holding the last
        // sample across the gap rather than slamming the DAC to zero.
        wait_for_dac_slot();
        force dut.startup_gain = 3'b100;
        inject_sample(16'h7fff);
        inject_sample(16'h8000);
        inject_sample(16'h1234);
        if (dut.pcm_running || audio !== 16'sh0000)
            $fatal(1, "DCS playback started before the PCM reserve was ready");
        inject_sample(16'hedcc);
        if (!dut.pcm_running)
            $fatal(1, "DCS playback did not start at the PCM reserve level");

        wait_for_dac_slot();
        if (audio !== 16'sh7fff)
            $fatal(1, "DCS positive full-scale PCM result wrong: %h", audio);
        wait_for_dac_slot();
        if (audio !== 16'sh8000)
            $fatal(1, "DCS negative full-scale PCM result wrong: %h", audio);
        wait_for_dac_slot();
        if (audio !== 16'sh1234)
            $fatal(1, "DCS positive PCM result wrong: %h", audio);
        wait_for_dac_slot();
        if (audio !== 16'shedcc)
            $fatal(1, "DCS negative PCM result wrong: %h", audio);
        release dut.startup_gain;

        // An underrun must hold the last delivered sample. Zeroing the output
        // here is a full-amplitude step -- at a loud passage that is exactly
        // the click we were chasing on hardware, and the wolf-unit reference
        // has no underflow path at all: an empty FIFO simply is not popped.
        wait_for_dac_slot();
        if (audio !== 16'shedcc)
            $fatal(1, "DCS underrun did not hold the last sample: %h", audio);
        if (dut.pcm_running)
            $fatal(1, "DCS underrun did not re-arm the PCM reserve");
        inject_sample(16'h1111);
        inject_sample(16'h2222);
        inject_sample(16'h3333);
        if (dut.pcm_running)
            $fatal(1, "DCS playback restarted before refilling its reserve");
        inject_sample(16'h4444);
        if (!dut.pcm_running)
            $fatal(1, "DCS playback did not restart after refilling its reserve");

        // The debug word is a measuring instrument, so it gets checked like
        // one. Two separate faults have already come from packing rather than
        // from logic: a field placed where the renderer never read it, and a
        // count sliced instead of saturated so a full FIFO displayed as empty.
        // Both produced confident, wrong readings on hardware.
        //
        // Only bits 19:0 reach the screen - the AU renderer shows five hex
        // digits - so anything above bit 19 must be zero or it is invisible.
        if (dbg_pcm_health[31:20] !== 12'd0)
            $fatal(1, "AU packs data above bit 19, where the screen cannot show it: %h",
                   dbg_pcm_health);
        if (dbg_pcm_level[31:20] !== 12'd0)
            $fatal(1, "AF packs data above bit 19, where the screen cannot show it: %h",
                   dbg_pcm_level);
        // The detectors moved off the debug word when it was repacked to carry
        // the origin PC, so they are checked at the source. Both taps must have
        // seen the injected 7fff -> 8000 step.
        if (dut.au_discont === 16'd0)
            $fatal(1, "output discontinuity detector counted nothing across a full-scale step");
        if (dut.au_src_discont === 16'd0)
            $fatal(1, "source discontinuity detector counted nothing while samples were injected");
        if (dut.au_max_step < 17'd65535)
            $fatal(1, "worst step should span the full range after 7fff->8000: %0d",
                   dut.au_max_step);
        // The origin probe watches DSP stores into the live autobuffer. The
        // bench injects past the DSP, so it must NOT have fired - a non-zero
        // count here would mean the window filter is catching scratch traffic.
        if (dut.dcs_wrap_cnt !== 8'h00)
            $fatal(1, "origin probe fired without any DSP store: cnt=%0d pc=%04h",
                   dut.dcs_wrap_cnt, dut.dcs_wrap_pc);
        // The boot timeline must have recorded the injected samples as the
        // first non-zero audio, and no board reset happened in this bench.
        if (!dut.seen_audio)
            $fatal(1, "boot timeline never saw a non-zero sample despite injection");
        // Exactly one: the deliberate host_reset pulse this bench performs.
        // Power-on must NOT count, or every boot would appear to reset the
        // sound hardware once and the field would be useless for the question
        // it exists to answer.
        if (dut.reset_count !== 8'h01)
            $fatal(1, "boot timeline reset count should be 1 (the bench's own pulse), got %0d",
                   dut.reset_count);

        // The boot image is all NOPs, so the DSP never reads the input latch.
        // A pulse here would mean dbg_cmd_read is stuck or wired to the wrong
        // event - the one mis-wiring that would make the mailbox timestamp
        // read plausibly and be worthless.
        if (dut.seen_cmdread)
            $fatal(1, "mailbox read pulsed under a NOP boot image");

        // The ROM fetch probe is a zero-false-positive check, so a clean boot
        // and a run of injected samples must leave it at zero. If this ever
        // trips in the bench the probe is mis-wired, not the DUT.
        if (dut.dcs_rom_unstable !== 8'h00)
            $fatal(1, "ROM fetch address moved mid-flight during the bench: cnt=%0d delta=%03h",
                   dut.dcs_rom_unstable, dut.dcs_rom_bankdelta);
        if (dut.dcs_src_op !== 8'h00)
            $fatal(1, "upstream probe latched an opcode without any DSP store: %02h",
                   dut.dcs_src_op);
        if (dut.dcs_src_cnt !== 8'h00)
            $fatal(1, "upstream probe fired without any DSP store: cnt=%0d pc=%04h addr=%04h",
                   dut.dcs_src_cnt, dut.dcs_src_pc, dut.dcs_src_addr);
        // Both display words must stay inside the 20 bits the screen renders.
        if (dbg_pcm_health[31:20] !== 12'd0)
            $fatal(1, "AU packs data above bit 19: %h", dbg_pcm_health);
        if (dbg_pcm_level[31:20] !== 12'd0)
            $fatal(1, "AF packs data above bit 19: %h", dbg_pcm_level);

        $display("PASS: KI DCS wrapper boot, DDR response, mailbox, DAC timing, PCM reserve, and AU/AF packing");
        $finish;
    end
endmodule

`default_nettype wire
