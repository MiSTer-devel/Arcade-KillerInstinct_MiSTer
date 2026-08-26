// SPDX-License-Identifier: GPL-3.0-only
//
// Replay REAL shifter operands captured from MAME through this core's shifter.
//
// Third of the datapath replays. The MAC matched MAME on 8,824 real operand
// sets and the ALU on 11,149 including flags, so neither is the crackle. The
// shifter is what is left, and it is the unit that fits the symptom.
//
// The crackle is amplitude-triggered: the same sound is clean with the volume
// multiplier at 0x2000 and crackles at 0x8000, and that multiplier was measured
// on hardware as exactly 0x8000 - identical to MAME - so the final scaling is
// not it. Inside the decoder, though, the shifter unpacks variable-length
// coefficients out of the compressed bitstream:
//
//     SR = SR OR LSHIFT SI (LO),  SE = MR1
//     SR = LSHIFT SI (HI),        SI = DM(I0,M1)
//     SR = LSHIFT SR0 BY n (LO)
//
// The shift AMOUNT tracks how many bits a coefficient needs, which is how
// magnitude reaches the control path. A shifter defect at particular shift
// counts would therefore fire only on loud content - clean below a volume
// threshold, wrong above it.
//
// +VEC=<path>, one vector per line, all hex:
//   mode xi sc si ar sr0 sr1 sb mstat sr0_exp sr1_exp
//
// sc is the shift count already resolved by the extractor - SE for the register
// forms, the literal for "BY n" - and is a SIGNED 8-bit quantity.

`default_nettype none
`timescale 1ns/1ps

module tb_ki_dcs_shvec;

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

    // Present only to host the shifter; never booted, held in reset throughout.
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

    logic [15:0] f_mstat, f_si, f_ar, f_sr0, f_sr1, f_sb;

    string  vec_path;
    integer vfd, rc, nvec, bad, first_bad;
    integer v_mode, v_xi, v_sc, v_si, v_ar, v_sr0, v_sr1, v_sb, v_mstat;
    integer v_sr0e, v_sr1e;
    logic [31:0] o_res;
    logic [15:0] o_se, o_sbr;
    logic        o_ss, o_se_we, o_ss_we, o_sbr_we;

    initial begin
        nvec = 0; bad = 0; first_bad = -1;
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

        rc = $fscanf(vfd, "%h %h %h %h %h %h %h %h %h %h %h\n",
                     v_mode, v_xi, v_sc, v_si, v_ar, v_sr0, v_sr1, v_sb,
                     v_mstat, v_sr0e, v_sr1e);
        while (rc == 11) begin
            // shift_xreg: 0,1 = SI (G0 8), 2 = AR (10), 3..5 = MR0..MR2,
            // 6 = SR0 (14), 7 = SR1 (15).
            //
            // The OR variants read the CURRENT SR out of the register file, so
            // SR0/SR1 must be present even when they are not the source. Both
            // banks are forced because G0 is bank-relative and SEC_REG is set
            // in this code - the same trap that would have silently fed the MAC
            // replay the wrong operands.
            f_mstat = v_mstat[15:0];
            f_si = v_si[15:0]; f_ar = v_ar[15:0];
            f_sr0 = v_sr0[15:0]; f_sr1 = v_sr1[15:0]; f_sb = v_sb[15:0];

            force dut.u_adsp.mstat  = f_mstat;
            force dut.u_adsp.gr[8]  = f_si;  force dut.u_adsp.gr[24] = f_si;
            force dut.u_adsp.gr[10] = f_ar;  force dut.u_adsp.gr[26] = f_ar;
            force dut.u_adsp.gr[14] = f_sr0; force dut.u_adsp.gr[30] = f_sr0;
            force dut.u_adsp.gr[15] = f_sr1; force dut.u_adsp.gr[31] = f_sr1;
            force dut.u_adsp.sbb[0] = f_sb;  force dut.u_adsp.sbb[1] = f_sb;
            #1;

            dut.u_adsp.shift_eval(v_mode[3:0], v_xi[2:0], v_sc[7:0],
                                  o_res, o_se, o_ss, o_sbr,
                                  o_se_we, o_ss_we, o_sbr_we);

            if ((o_res[15:0] !== v_sr0e[15:0]) || (o_res[31:16] !== v_sr1e[15:0])) begin
                bad = bad + 1;
                if (first_bad < 0) begin
                    first_bad = nvec;
                    $display("");
                    $display("FIRST SHIFTER MISMATCH at vector %0d", nvec);
                    $display("  mode=%1h xi=%0d sc=%0d (%02h)", v_mode, v_xi,
                             $signed(v_sc[7:0]), v_sc[7:0]);
                    $display("  SI=%04h AR=%04h  SR in %04h:%04h",
                             v_si[15:0], v_ar[15:0], v_sr1[15:0], v_sr0[15:0]);
                    $display("  MAME SR=%04h:%04h", v_sr1e[15:0], v_sr0e[15:0]);
                    $display("  ours SR=%04h:%04h", o_res[31:16], o_res[15:0]);
                end
            end

            release dut.u_adsp.mstat;
            release dut.u_adsp.gr[8];  release dut.u_adsp.gr[24];
            release dut.u_adsp.gr[10]; release dut.u_adsp.gr[26];
            release dut.u_adsp.gr[14]; release dut.u_adsp.gr[30];
            release dut.u_adsp.gr[15]; release dut.u_adsp.gr[31];
            release dut.u_adsp.sbb[0]; release dut.u_adsp.sbb[1];

            nvec = nvec + 1;
            rc = $fscanf(vfd, "%h %h %h %h %h %h %h %h %h %h %h\n",
                         v_mode, v_xi, v_sc, v_si, v_ar, v_sr0, v_sr1, v_sb,
                         v_mstat, v_sr0e, v_sr1e);
        end
        $fclose(vfd);

        $display("");
        $display("=== shifter vector replay ===");
        $display("  vectors  : %0d", nvec);
        $display("  mismatch : %0d", bad);
        $display("=============================");
        if (nvec == 0)
            $fatal(1, "no vectors were read from %s", vec_path);
        if (bad != 0)
            $fatal(1, "shifter disagrees with MAME on %0d of %0d real operand sets",
                   bad, nvec);
        $display("PASS: shifter matches MAME on %0d real operand sets", nvec);
        $finish;
    end

endmodule

`default_nettype wire
