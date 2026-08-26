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
    // real-ROM boot timing aligned with the 10 MHz ADSP-2105 modeled by MAME.
    parameter integer DCS_ENGINE_HZ = 35750000,
    parameter DCS_PMFILE = "pm.hex",
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
    output logic [13:0] dbg_pc,
    // Current audio timing and discontinuity metrics.
    output logic [31:0] dbg_pcm_health,
    output logic [31:0] dbg_pcm_level
);
    localparam integer DAC_DIV = CLK_HZ / 31250;
    localparam integer PCM_N = 1 << PCM_AW;

    logic [13:0] dcs_ppc;
    logic        dcs_valid;
    logic        dcs_unimpl;
    logic [15:0] dcs_sample;
    logic        dcs_sample_we;
    logic [13:0] dcs_wrap_pc;
    logic [7:0]  dcs_wrap_cnt;
    logic [13:0] dcs_src_pc;
    logic [13:0] dcs_src_addr;
    logic [7:0]  dcs_src_cnt;
    logic [7:0]  dcs_src_op;
    logic [7:0]  dcs_rom_unstable;
    logic [11:0] dcs_rom_bankdelta;
    logic [11:0] dcs_bank_writes;
    logic [7:0]  dcs_cmd_lost;
    logic        dcs_cmd_read;
    logic [15:0] dcs_status;

    // The physical ADSP-2105 is clocked at 10 MHz. This instruction-atomic HDL
    // engine needs about 3.05 fabric enables per emulated instruction. The
    // configured DCS_ENGINE_HZ cadence reproduces the DSP's approximately
    // 10 MIPS throughput from the core-wide 50 MHz clock.
    localparam integer DCS_PHASE_W = $clog2(CLK_HZ);
    localparam logic [DCS_PHASE_W:0] DCS_PHASE_STEP = DCS_ENGINE_HZ;
    localparam logic [DCS_PHASE_W:0] DCS_PHASE_MOD = CLK_HZ;
    logic [DCS_PHASE_W-1:0] dcs_phase;
    logic [DCS_PHASE_W:0] dcs_phase_sum;
    wire dcs_ce = (dcs_phase_sum >= DCS_PHASE_MOD);

    always_comb dcs_phase_sum = {1'b0, dcs_phase} + DCS_PHASE_STEP;
    always_ff @(posedge clk) begin
        if (rst)
            dcs_phase <= '0;
        else if (dcs_ce)
            dcs_phase <= dcs_phase_sum - DCS_PHASE_MOD;
        else
            dcs_phase <= dcs_phase_sum[DCS_PHASE_W-1:0];
    end

    // DCS Audio 2K feeds the mono DAC at 31.25 kHz.
    logic [$clog2(DAC_DIV)-1:0] dac_div_ctr;
    wire dac_slot_ce = (dac_div_ctr == DAC_DIV-1);
    always_ff @(posedge clk) begin
        if (rst)
            dac_div_ctr <= '0;
        else if (dac_slot_ce)
            dac_div_ctr <= '0;
        else
            dac_div_ctr <= dac_div_ctr + 1'b1;
    end

    // The ADSP samples dac_ce_in on every fabric clock, independently of
    // core_ce. Each physical DAC slot must therefore be exactly one fabric
    // clock wide; stretching it would advance the autobuffer once per cycle.
    wire dcs_dac_ce = dac_slot_ce;

    // The main board produces a one-clock command strobe. Retain it until one
    // ADSP enable slot, then expose exactly one aligned write to the mailbox.
    logic        cmd_pending;
    logic [15:0] cmd_pending_data;
    // The single-entry pending register matches the board mailbox semantics.
    // A new host write replaces an unconsumed command and increments the
    // saturating diagnostic counter.
    logic [7:0]  cmd_dropped;
    always_ff @(posedge clk) begin
        if (rst || host_reset) begin
            cmd_pending <= 1'b0;
            cmd_pending_data <= 16'h0000;
            cmd_dropped <= 8'h0;
        end else begin
            if (host_cmd_wr) begin
                if (cmd_pending && (cmd_dropped != 8'hFF))
                    cmd_dropped <= cmd_dropped + 8'd1;
                cmd_pending <= 1'b1;
                cmd_pending_data <= host_cmd_data;
            end else if (cmd_pending && dcs_ce) begin
                cmd_pending <= 1'b0;
            end
        end
    end

    // Time to first nonzero audio, in groups of 1024 DAC slots. This is exposed
    // through dbg_pcm_health and remains independent of CPU clock rate.
    logic [21:0] boot_ticks;
    wire  [11:0] boot_units = boot_ticks[21:10];
    logic [11:0] first_audio_t;
    logic        seen_audio, host_reset_d;
    logic        seen_cmdread;
    logic [7:0]  cmd_count, reset_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            boot_ticks    <= '0;
            first_audio_t <= '0;
            seen_audio    <= 1'b0;
            seen_cmdread    <= 1'b0;
            cmd_count     <= '0;
            reset_count   <= '0;
            // Preserve the asserted reset level so power-on is not counted as
            // a subsequent host-reset edge.
            host_reset_d  <= host_reset;
        end else begin
            if (dac_slot_ce && !(&boot_ticks)) boot_ticks <= boot_ticks + 1'b1;
            host_reset_d <= host_reset;
            if (host_reset && !host_reset_d && (reset_count != 8'hFF))
                reset_count <= reset_count + 8'd1;
            if (host_cmd_wr) begin
                if (cmd_count != 8'hFF) cmd_count <= cmd_count + 8'd1;
            end
            if (dcs_sample_we && (dcs_sample != 16'h0000) && !seen_audio) begin
                seen_audio    <= 1'b1;
                first_audio_t <= boot_units;
            end
            // Latch the first DSP command read for diagnostic status.
            if (dcs_cmd_read && !seen_cmdread) begin
                seen_cmdread <= 1'b1;
            end
        end
    end

    adsp2105 #(
        .PMFILE(DCS_PMFILE),
        .EXT_ROM(1),
        .KI_ROM_MAP(1),
        .CORE_CE_EN(1),
        .PCM_STREAM(1)
    ) u_adsp (
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
        .dbg_wrap_pc(dcs_wrap_pc),
        .dbg_wrap_cnt(dcs_wrap_cnt),
        .dbg_src_pc(dcs_src_pc),
        .dbg_src_addr(dcs_src_addr),
        .dbg_src_cnt(dcs_src_cnt),
        .dbg_src_op(dcs_src_op),
        .dbg_rom_unstable_o(dcs_rom_unstable),
        .dbg_rom_bankdelta_o(dcs_rom_bankdelta),
        .dbg_bank_writes_o(dcs_bank_writes),
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

    // Count source and output sample steps larger than half the signed PCM
    // range. Matching counts show that a discontinuity entered through the DSP
    // sample stream rather than being introduced by the FIFO. Current KI1
    // evidence shows the peak-volume crackle at the DSP output with no FIFO
    // drops or underruns.
    logic signed [15:0] au_src_prev;
    logic [15:0] au_src_discont;
    wire signed [16:0] au_src_step = $signed({dcs_sample[15], dcs_sample}) -
                                     $signed({au_src_prev[15], au_src_prev});
    wire [16:0] au_src_abs = au_src_step[16] ? (~au_src_step + 17'd1) : au_src_step;

    always_ff @(posedge clk) begin
        if (rst || host_reset) begin
            au_src_prev    <= '0;
            au_src_discont <= '0;
        end else if (dcs_sample_we) begin
            au_src_prev <= dcs_sample;
            if ((au_src_abs > 17'd32767) && (au_src_discont != 16'hFFFF))
                au_src_discont <= au_src_discont + 1'b1;
        end
    end

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

    // Health packs first-audio time in bits 19:8 and the saturating output
    // discontinuity count in bits 7:0. Bits 31:20 remain zero.
    wire [7:0] disc8 = (au_discont > 16'd255) ? 8'hFF : au_discont[7:0];
    assign dbg_pcm_health = {12'd0, first_audio_t, disc8};

    // Level packs the maximum output step in bits 19:8 and the same saturating
    // discontinuity count in bits 7:0. A full-range step saturates to 12'hFFF.
    wire [11:0] step_disp = au_max_step[16] ? 12'hFFF : au_max_step[15:4];
    assign dbg_pcm_level = {12'd0, step_disp, disc8};

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
                    audio <= startup_product >>> STARTUP_RAMP_BITS;
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
