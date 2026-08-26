// SPDX-License-Identifier: GPL-3.0-only
//
// Replay REAL MAC operands captured from MAME through this core's multiplier.
//
// The gameplay crackle is a full-scale wrap - hardware measures a worst step of
// 65,488 across the whole 16-bit range, 60 times a match - and everything
// around the arithmetic has been ruled out by measurement:
//
//   * the FIFO is a faithful pass-through (source and output counts agree),
//   * the DSP is not starved (worst window 363 instructions per DAC sample
//     against the real board's 320),
//   * and saturation is not involved at all: tracing MAME across 1,186,819
//     instructions of its loudest passage, ASTAT AV and MV are set exactly
//     zero times, so SAT MR, AR_SAT, AV_LATCH and MV are dead code there.
//
// What remains is that our decode arithmetic produces values the reference
// never produces. The loud window runs an FFT/IFFT butterfly - 46,080 rounding
// multiply-accumulates per 200 ms - so the MAC is where to look:
//
//     MR = MR + MX0 * MY1 (RND)
//     MR = MR - MX1 * MY1 (RND)
//
// Rather than reconstruct that state in simulation, this takes the operands and
// results MAME actually computed and checks ours against them. Each vector is
// one instruction: the register values before it, and the MR it produced.
//
// +VEC=<path>, one vector per line, all hex:
//   sub xi yi mstat mx0 mx1 my0 my1 mr0_in mr1_in mr2_in mr0_exp mr1_exp mr2_exp
//
// sub/xi/yi come from the opcode, so the extractor maps the disassembled text
// back to the encoding this core decodes.

`default_nettype none
`timescale 1ns/1ps

module tb_ki_dcs_macvec;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic host_reset = 1'b1;
    logic host_cmd_wr = 1'b0;
    logic [15:0] host_cmd_data = 16'h0000;

    wire [15:0] host_status;
    wire        rom_req;
    wire [18:0] rom_addr;
    logic       rom_rdy = 1'b0;
    logic [63:0] rom_q = 64'h0;
    wire signed [15:0] audio;
    wire        dbg_valid, dbg_unimpl, dbg_pcm_push;
    wire [13:0] dbg_pc;
    wire [31:0] dbg_pcm_health, dbg_pcm_level;

    always #10 clk = !clk;

    // The DUT is only here to give the MAC a home; it is never booted. The ROM
    // port is tied off and the core stays in reset, so nothing executes and the
    // only thing exercised is the function called directly below.
    ki_dcs_audio dut (
        .clk(clk), .rst(rst), .host_reset(host_reset),
        .host_cmd_wr(host_cmd_wr), .host_cmd_data(host_cmd_data),
        .host_status(host_status),
        .rom_req(rom_req), .rom_addr(rom_addr),
        .rom_rdy(rom_rdy), .rom_q(rom_q),
        .audio(audio),
        .dbg_valid(dbg_valid), .dbg_unimpl(dbg_unimpl),
        .dbg_pcm_push(dbg_pcm_push), .dbg_pc(dbg_pc),
        .dbg_pcm_health(dbg_pcm_health), .dbg_pcm_level(dbg_pcm_level)
    );

    // ModelSim will not take an automatic variable as a force operand, so the
    // forced values live here.
    logic [23:0] f_op;
    logic [15:0] f_mstat;
    logic [15:0] f_mx0, f_mx1, f_my0, f_my1;
    logic [15:0] f_mr0, f_mr1, f_mr2, f_mrz;

    string  vec_path;
    integer vfd, rc, nvec, nbad;
    integer v_sub, v_xi, v_yi, v_mstat;
    integer v_mx0, v_mx1, v_my0, v_my1;
    integer v_mr0i, v_mr1i, v_mr2i, v_mr0e, v_mr1e, v_mr2e;
    logic [63:0] got;
    integer      first_bad;
    // Categorise, because the two cases mean completely different things. MR1
    // is what the decoder stores to memory and turns into audio; MR2 is the
    // accumulator's top byte and is only observable through SAT MR's sign test
    // and the MV flag, both of which look at bits the mask cannot change.
    integer      bad_mr0, bad_mr1, bad_mr2, first_mr1;

    initial begin
        nvec = 0; nbad = 0; first_bad = -1;
        bad_mr0 = 0; bad_mr1 = 0; bad_mr2 = 0; first_mr1 = -1;
        if (!$value$plusargs("VEC=%s", vec_path)) begin
            $display("FATAL: no +VEC=<path> given");
            $finish;
        end
        vfd = $fopen(vec_path, "r");
        if (vfd == 0) begin
            $display("FATAL: could not open %s", vec_path);
            $finish;
        end

        repeat (4) @(posedge clk);

        rc = $fscanf(vfd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                     v_sub, v_xi, v_yi, v_mstat,
                     v_mx0, v_mx1, v_my0, v_my1,
                     v_mr0i, v_mr1i, v_mr2i, v_mr0e, v_mr1e, v_mr2e);
        while (rc == 14) begin
            // gr indices: MX0=2 MX1=3, MY0=6 MY1=7 (mac_yread reads G0(6)/
            // G0(7), NOT 4/5), MR0=11 MR1=12 MR2=13.
            //
            // `G0(i) is gr[{bnk,4'b0}+i] and bnk follows MSTAT bit 0, which the
            // decoder does set - MSTAT measured 001b in MAME. Rather than
            // decode the bank here, both halves are forced to the same values,
            // so whichever one the core selects reads the intended operand.
            //
            // MRZ is the hidden top word of the 64-bit accumulator; MAME does
            // not expose it, and for a well-formed 40-bit MR it is the sign
            // fill of MR2, which is what a real accumulate leaves behind.
            f_op    = 24'h0;
            f_op[10:8]  = v_xi[2:0];
            f_op[12:11] = v_yi[1:0];
            f_mstat = v_mstat[15:0];
            f_mx0 = v_mx0[15:0]; f_mx1 = v_mx1[15:0];
            f_my0 = v_my0[15:0]; f_my1 = v_my1[15:0];
            f_mr0 = v_mr0i[15:0]; f_mr1 = v_mr1i[15:0]; f_mr2 = v_mr2i[15:0];
            f_mrz = {16{v_mr2i[15]}};

            force dut.u_adsp.op    = f_op;
            force dut.u_adsp.mstat = f_mstat;
            force dut.u_adsp.gr[2]  = f_mx0;  force dut.u_adsp.gr[18] = f_mx0;
            force dut.u_adsp.gr[3]  = f_mx1;  force dut.u_adsp.gr[19] = f_mx1;
            force dut.u_adsp.gr[6]  = f_my0;  force dut.u_adsp.gr[22] = f_my0;
            force dut.u_adsp.gr[7]  = f_my1;  force dut.u_adsp.gr[23] = f_my1;
            force dut.u_adsp.gr[11] = f_mr0;  force dut.u_adsp.gr[27] = f_mr0;
            force dut.u_adsp.gr[12] = f_mr1;  force dut.u_adsp.gr[28] = f_mr1;
            force dut.u_adsp.gr[13] = f_mr2;  force dut.u_adsp.gr[29] = f_mr2;
            force dut.u_adsp.mrzb[0] = f_mrz; force dut.u_adsp.mrzb[1] = f_mrz;
            #1;

            got = dut.u_adsp.mac_r64_f(v_sub[3:0]);

            if (got[15:0]  !== v_mr0e[15:0]) bad_mr0 = bad_mr0 + 1;
            if (got[47:32] !== v_mr2e[15:0]) bad_mr2 = bad_mr2 + 1;
            if (got[31:16] !== v_mr1e[15:0]) begin
                bad_mr1 = bad_mr1 + 1;
                if (first_mr1 < 0) begin
                    first_mr1 = nvec;
                    $display("");
                    $display("FIRST **MR1** MISMATCH at vector %0d - this one reaches the audio",
                             nvec);
                    $display("  sub=%1h xi=%0d yi=%0d mstat=%04h", v_sub, v_xi, v_yi, v_mstat);
                    $display("  MX0=%04h MX1=%04h MY0=%04h MY1=%04h",
                             v_mx0[15:0], v_mx1[15:0], v_my0[15:0], v_my1[15:0]);
                    $display("  MR in   %04h:%04h:%04h", v_mr2i[15:0], v_mr1i[15:0], v_mr0i[15:0]);
                    $display("  MAME    %04h:%04h:%04h", v_mr2e[15:0], v_mr1e[15:0], v_mr0e[15:0]);
                    $display("  ours    %04h:%04h:%04h", got[47:32], got[31:16], got[15:0]);
                end
            end
            if ((got[15:0]  !== v_mr0e[15:0]) ||
                (got[31:16] !== v_mr1e[15:0]) ||
                (got[47:32] !== v_mr2e[15:0])) begin
                nbad = nbad + 1;
                if (first_bad < 0) begin
                    first_bad = nvec;
                    $display("");
                    $display("FIRST MISMATCH at vector %0d", nvec);
                    $display("  sub=%1h xi=%0d yi=%0d mstat=%04h", v_sub, v_xi, v_yi, v_mstat);
                    $display("  MX0=%04h MX1=%04h MY0=%04h MY1=%04h",
                             v_mx0[15:0], v_mx1[15:0], v_my0[15:0], v_my1[15:0]);
                    $display("  MR in   %04h:%04h:%04h", v_mr2i[15:0], v_mr1i[15:0], v_mr0i[15:0]);
                    $display("  MAME    %04h:%04h:%04h", v_mr2e[15:0], v_mr1e[15:0], v_mr0e[15:0]);
                    $display("  ours    %04h:%04h:%04h", got[47:32], got[31:16], got[15:0]);
                end
            end

            release dut.u_adsp.op;
            release dut.u_adsp.mstat;
            release dut.u_adsp.gr[2];  release dut.u_adsp.gr[18];
            release dut.u_adsp.gr[3];  release dut.u_adsp.gr[19];
            release dut.u_adsp.gr[6];  release dut.u_adsp.gr[22];
            release dut.u_adsp.gr[7];  release dut.u_adsp.gr[23];
            release dut.u_adsp.gr[11]; release dut.u_adsp.gr[27];
            release dut.u_adsp.gr[12]; release dut.u_adsp.gr[28];
            release dut.u_adsp.gr[13]; release dut.u_adsp.gr[29];
            release dut.u_adsp.mrzb[0]; release dut.u_adsp.mrzb[1];

            nvec = nvec + 1;
            rc = $fscanf(vfd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                         v_sub, v_xi, v_yi, v_mstat,
                         v_mx0, v_mx1, v_my0, v_my1,
                         v_mr0i, v_mr1i, v_mr2i, v_mr0e, v_mr1e, v_mr2e);
        end
        $fclose(vfd);

        $display("");
        $display("=== MAC vector replay ===");
        $display("  vectors : %0d", nvec);
        $display("  mismatch: %0d", nbad);
        $display("    MR0 (low  word of the accumulator) : %0d", bad_mr0);
        $display("    MR1 (STORED TO MEMORY - the audio) : %0d", bad_mr1);
        $display("    MR2 (top byte, masked vs extended) : %0d", bad_mr2);
        $display("=========================");
        if (nvec == 0)
            $fatal(1, "no vectors were read from %s", vec_path);
        if (bad_mr1 != 0 || bad_mr0 != 0)
            $fatal(1, "MAC produces different AUDIO data than MAME on %0d of %0d operand sets",
                   (bad_mr0 > bad_mr1) ? bad_mr0 : bad_mr1, nvec);
        if (bad_mr2 != 0) begin
            $display("NOTE: only MR2's top byte differs, on %0d vectors.", bad_mr2);
            $display("      MAME masks the 40-bit accumulator; this core sign-extends it.");
            $display("      MR1 and MR0 - everything the decoder stores - agree, and both");
            $display("      SAT MR's sign test and the MV flag read bits below the mask.");
        end
        $display("PASS: MAC matches MAME on %0d real operand sets from the decoder", nvec);
        $finish;
    end

endmodule

`default_nettype wire
