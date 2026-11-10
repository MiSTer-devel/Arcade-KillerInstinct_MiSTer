// SPDX-License-Identifier: GPL-3.0-only
// Killer Instinct Midway DCS Audio 2K board wrapper.
//
// Commands are written as complete 16-bit words. Eight 512 KiB ROMs occupy
// alternating 1 MiB windows in the ADSP's sparse 16 MiB data-bank space.
// Hardware is the default build. Testbenches must explicitly define
// KI_DCS_SIMULATION to enable behavioral memories and simulation checks.
`ifndef KI_DCS_SIMULATION
`ifndef SYNTHESIS
`define SYNTHESIS 1
`endif
`endif
`default_nettype none
module ki_dcs_audio #(
    parameter integer CLK_HZ = 50000000,
    // dcs_ce advances the multi-state HDL engine; it is not the ADSP clock.
    // A 35.75 MHz enable cadence provides approximately 10 MIPS and keeps the
    // real-ROM boot timing aligned with the 10 MHz ADSP-2105.
    parameter integer DCS_ENGINE_HZ = 35750000,
    // The 2048-sample FIFO holds a complete autobuffer half-burst plus samples
    // that remain queued while the 31.25 kHz output drains.
    parameter integer PCM_AW = 11,
    // Begin playback after 256 queued samples; underruns hold the last sample
    // and require the FIFO to refill to this level before playback resumes.
    parameter integer PCM_START_LEVEL = 256,
    parameter integer STARTUP_RAMP_BITS = 10
) (
    input  wire logic        clk,
    input  wire logic        rst,
    // While high, the board stands still: the DSP takes no step and the DAC
    // takes no slot, so the program and its sample clock stop together and
    // resume where they were. The output holds its last sample.
    input  wire logic        pause,
    input  wire logic        host_reset,
    input  wire logic        host_cmd_wr,
    input  wire logic [15:0] host_cmd_data,
    output logic [15:0] host_status,

    output logic        rom_req,
    output logic [18:0] rom_addr,
    input  wire logic        rom_rdy,
    input  wire logic [63:0] rom_q,

    output logic signed [15:0] audio,
    output logic        dbg_valid,
    output logic        dbg_unimpl,
    output logic        dbg_pcm_push,
    output logic [13:0] dbg_pc
);
    localparam integer DAC_DIV = CLK_HZ / 31250;
    localparam integer PCM_N = 1 << PCM_AW;

    logic [13:0] dcs_ppc;
    logic        dcs_valid;
    logic        dcs_unimpl;
    logic [15:0] dcs_sample;
    logic        dcs_sample_we;
    logic [7:0]  dcs_cmd_lost;
    logic        dcs_cmd_read;
    logic [15:0] dcs_status;

    // The physical ADSP-2105 is clocked at 10 MHz. This instruction-atomic HDL
    // engine needs several fabric enables per emulated instruction, so the
    // configured DCS_ENGINE_HZ cadence is what reproduces the DSP's
    // approximately 10 MIPS throughput from the core-wide 50 MHz clock.
    localparam integer DCS_PHASE_W = $clog2(CLK_HZ);
    localparam logic [DCS_PHASE_W:0] DCS_PHASE_STEP = DCS_ENGINE_HZ[DCS_PHASE_W:0];
    localparam logic [DCS_PHASE_W:0] DCS_PHASE_MOD = CLK_HZ[DCS_PHASE_W:0];
    logic [DCS_PHASE_W-1:0] dcs_phase;
    logic [DCS_PHASE_W:0] dcs_phase_sum;
    logic [DCS_PHASE_W:0] dcs_phase_wrap;
    wire dcs_ce = !pause && (dcs_phase_sum >= DCS_PHASE_MOD);

    // Both cadences hold their phase through a pause, so the DSP and the DAC
    // pick up exactly where they stopped relative to each other.
    always_comb dcs_phase_sum = {1'b0, dcs_phase} + DCS_PHASE_STEP;
    always_comb dcs_phase_wrap = dcs_phase_sum - DCS_PHASE_MOD;
    always_ff @(posedge clk) begin
        if (rst)
            dcs_phase <= '0;
        else if (pause)
            dcs_phase <= dcs_phase;
        else if (dcs_ce)
            dcs_phase <= dcs_phase_wrap[DCS_PHASE_W-1:0];
        else
            dcs_phase <= dcs_phase_sum[DCS_PHASE_W-1:0];
    end

    // DCS Audio 2K feeds the mono DAC at 31.25 kHz.
    logic [$clog2(DAC_DIV)-1:0] dac_div_ctr;
    wire dac_slot_ce = !pause && (dac_div_ctr == DAC_DIV-1);
    always_ff @(posedge clk) begin
        if (rst)
            dac_div_ctr <= '0;
        else if (pause)
            dac_div_ctr <= dac_div_ctr;
        else if (dac_slot_ce)
            dac_div_ctr <= '0;
        else
            dac_div_ctr <= dac_div_ctr + 1'b1;
    end

    // Each physical DAC slot is exactly one fabric clock wide.
    wire dcs_dac_ce = dac_slot_ce;

    // The main board produces a one-clock command strobe. Retain it until one
    // ADSP enable slot, then expose exactly one aligned write to the mailbox.
    logic        cmd_pending;
    logic [15:0] cmd_pending_data;
    // The single-entry pending register matches the board mailbox semantics:
    // a new host write replaces an unconsumed command.
    always_ff @(posedge clk) begin
        if (rst || host_reset) begin
            cmd_pending <= 1'b0;
            cmd_pending_data <= 16'h0000;
        end else begin
            if (host_cmd_wr) begin
                cmd_pending <= 1'b1;
                cmd_pending_data <= host_cmd_data;
            end else if (cmd_pending && dcs_ce) begin
                cmd_pending <= 1'b0;
            end
        end
    end

    // Host command writes, and whether the DSP has read one from the mailbox.
    logic        seen_cmdread;
    logic [7:0]  cmd_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            seen_cmdread <= 1'b0;
            cmd_count    <= '0;
        end else begin
            if (host_cmd_wr) begin
                if (cmd_count != 8'hFF) cmd_count <= cmd_count + 8'd1;
            end
            if (dcs_cmd_read && !seen_cmdread) begin
                seen_cmdread <= 1'b1;
            end
        end
    end

    adsp2105 u_adsp (
        .clk(clk),
        .rst(rst),
        .core_ce(dcs_ce),
        .host_rst(host_reset),
        .host_cmd_w(cmd_pending && dcs_ce),
        .host_cmd_data(cmd_pending_data),
        .host_status_r(dcs_status),
        .host_response_r(),
        .host_resp_rd(1'b0),
        .rom_ddr_req(rom_req),
        .rom_ddr_addr(rom_addr),
        .rom_ddr_rdy(rom_rdy),
        .rom_ddr_q(rom_q),
        .dac_ce_in(dcs_dac_ce),
        .o_ppc(dcs_ppc),
        .o_valid(dcs_valid),
        .o_unimpl(dcs_unimpl),
        .dac_sample(dcs_sample),
        .dac_ce(dcs_sample_we),
        .dbg_cmd_lost(dcs_cmd_lost),
        .dbg_cmd_read(dcs_cmd_read)
    );

    assign host_status = dcs_status;
    assign dbg_valid = dcs_valid;
    assign dbg_unimpl = dcs_unimpl;
    assign dbg_pcm_push = dcs_sample_we;
    assign dbg_pc = dcs_ppc;

    // The core can emit a complete autobuffer half in a burst. Queue that burst
    // and publish one sample at each external DAC slot.
    logic [15:0] pcm_fifo [0:PCM_N-1];
    logic [PCM_AW-1:0] pcm_wp;
    logic [PCM_AW-1:0] pcm_rp;
    logic [PCM_AW:0] pcm_used;
    logic pcm_running;
    wire pcm_pop = dac_slot_ce && pcm_running && (pcm_used != 0);
    // A pop frees the current read slot on this edge, so a simultaneous push
    // is legal even when the FIFO entered the cycle full.
    wire pcm_push = dcs_sample_we && ((pcm_used != PCM_N) || pcm_pop);
    wire pcm_start = !pcm_running && pcm_push &&
                     (pcm_used >= (PCM_START_LEVEL - 1));
    wire pcm_underflow = dac_slot_ce && pcm_running && (pcm_used == 0);

    localparam logic [STARTUP_RAMP_BITS:0] STARTUP_GAIN_FULL =
        {1'b1, {STARTUP_RAMP_BITS{1'b0}}};
    logic [STARTUP_RAMP_BITS:0] startup_gain;
    wire signed [15:0] pcm_head = $signed(pcm_fifo[pcm_rp]);
    wire signed [STARTUP_RAMP_BITS+1:0] startup_gain_signed =
        $signed({1'b0, startup_gain});
    wire signed [STARTUP_RAMP_BITS+17:0] startup_product =
        pcm_head * startup_gain_signed;

    logic au_popped;

    always_ff @(posedge clk) begin
        if (rst || host_reset) begin
            au_popped    <= 1'b0;
        end else begin
            if (pcm_pop) begin
                au_popped <= 1'b1;
            end
        end
    end

    // Count output sample steps larger than half the signed PCM range, and
    // track the largest step.
    logic signed [15:0] au_prev_sample;
    logic [15:0] au_discont;
    logic [16:0] au_max_step;
    wire signed [16:0] au_step = $signed({audio[15], audio}) -
                                 $signed({au_prev_sample[15], au_prev_sample});
    wire [16:0] au_step_abs = au_step[16] ? (~au_step + 17'd1) : au_step;
    wire au_step_big = au_popped && (au_step_abs > 17'd32767);

    always_ff @(posedge clk) begin
        if (rst || host_reset) begin
            au_prev_sample <= '0;
            au_discont     <= '0;
            au_max_step    <= '0;
        end else if (pcm_pop) begin
            au_prev_sample <= audio;
            if (au_step_big && au_discont != 16'hFFFF)
                au_discont <= au_discont + 1'b1;
            if (au_step_abs > au_max_step) begin
                au_max_step   <= au_step_abs;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst || host_reset) begin
            pcm_wp <= '0;
            pcm_rp <= '0;
            pcm_used <= '0;
            pcm_running <= 1'b0;
            audio <= '0;
            startup_gain <= '0;
        end else begin
            if (pcm_push) begin
                pcm_fifo[pcm_wp] <= dcs_sample;
                pcm_wp <= pcm_wp + 1'b1;
            end
            if (pcm_pop) begin
                if (startup_gain != STARTUP_GAIN_FULL) begin
                    // Ramp from silence without changing the full-scale
                    // steady-state PCM path.
                    audio <= startup_product[STARTUP_RAMP_BITS+15:STARTUP_RAMP_BITS];
                    if (pcm_head != 16'sh0000)
                        startup_gain <= startup_gain + 1'b1;
                end else begin
                    audio <= pcm_head;
                end
                pcm_rp <= pcm_rp + 1'b1;
            end
            if (pcm_start)
                pcm_running <= 1'b1;
            else if (pcm_underflow) begin
                // An empty FIFO causes no pop, so the output holds its last
                // sample. The ramp applies only to a genuine cold start.
                pcm_running <= 1'b0;
            end
            unique case ({pcm_push, pcm_pop})
                2'b10: pcm_used <= pcm_used + 1'b1;
                2'b01: pcm_used <= pcm_used - 1'b1;
                default: ;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((CLK_HZ % 31250) != 0)
            $error("ki_dcs_audio CLK_HZ must divide exactly to 31.25 kHz");
        if (DCS_ENGINE_HZ > CLK_HZ)
            $error("ki_dcs_audio DCS_ENGINE_HZ must not exceed CLK_HZ");
        if ((PCM_START_LEVEL <= 0) || (PCM_START_LEVEL > PCM_N))
            $error("ki_dcs_audio PCM_START_LEVEL must be between 1 and PCM_N");
    end
`endif
endmodule
`default_nettype wire
