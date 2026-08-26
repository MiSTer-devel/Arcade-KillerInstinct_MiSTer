// SPDX-License-Identifier: GPL-3.0-only
//
// Replay REAL ALU operands captured from MAME through this core's ALU.
//
// Companion to tb_ki_dcs_macvec. The MAC came back bit-exact on 8,824 real
// operand sets from the decoder - MR0 and MR1 agree everywhere - so the
// multiplier is not the crackle. The other arithmetic in that path is the ALU:
// the FFT/IFFT butterfly runs 23,040 each of
//
//     AR = AX0 + AY0, DM(I0,M1) = AR
//     AR = AY0 - AX0, MX0 = DM(I1,M1)
//     AR = MR1 + AY1, DM(I0,M1) = AR
//     AR = AY1 - MR1, DM(I2,M1) = AR
//
// per 200 ms of loud audio, and AR is stored straight to memory.
//
// alu_eval takes operand VALUES rather than register indices, so the extractor
// resolves the registers and this only has to supply astat (the carry input,
// and the AV_LATCH clear mask) and mstat (AR saturation).
//
// +VEC=<path>, one vector per line, all hex:
//   sub xval yval astat_in mstat_in ar_exp astat_exp
//
// Both the result and the resulting flags are checked. Flags matter as much as
// the value here: AR saturation is gated on AV, so a flag divergence turns into
// a data divergence on the very next instruction.

`default_nettype none
`timescale 1ns/1ps

module tb_ki_dcs_aluvec;

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

    // Present only to host the ALU; never booted, held in reset throughout.
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

    logic [15:0] f_astat, f_mstat;

    string  vec_path;
    integer vfd, rc, nvec;
    integer bad_val, bad_flag, first_val, first_flag;
    integer v_sub, v_x, v_y, v_astat, v_mstat, v_are, v_astate;
    logic [31:0] got;

    initial begin
        nvec = 0; bad_val = 0; bad_flag = 0; first_val = -1; first_flag = -1;
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

        rc = $fscanf(vfd, "%h %h %h %h %h %h %h\n",
                     v_sub, v_x, v_y, v_astat, v_mstat, v_are, v_astate);
        while (rc == 7) begin
            f_astat = v_astat[15:0];
            f_mstat = v_mstat[15:0];
            force dut.u_adsp.astat = f_astat;
            force dut.u_adsp.mstat = f_mstat;
            #1;

            got = dut.u_adsp.alu_eval(v_sub[3:0], v_x[15:0], v_y[15:0]);

            // The stored result. With AR saturation enabled the writeback can
            // clamp, so compare the raw ALU result here and let the flags carry
            // the overflow information.
            if (got[15:0] !== v_are[15:0]) begin
                bad_val = bad_val + 1;
                if (first_val < 0) begin
                    first_val = nvec;
                    $display("");
                    $display("FIRST RESULT MISMATCH at vector %0d", nvec);
                    $display("  sub=%1h  X=%04h  Y=%04h  astat_in=%04h mstat=%04h",
                             v_sub, v_x[15:0], v_y[15:0], v_astat[15:0], v_mstat[15:0]);
                    $display("  MAME AR=%04h   ours AR=%04h", v_are[15:0], got[15:0]);
                end
            end
            if (got[31:16] !== v_astate[15:0]) begin
                bad_flag = bad_flag + 1;
                if (first_flag < 0) begin
                    first_flag = nvec;
                    $display("");
                    $display("FIRST FLAG MISMATCH at vector %0d", nvec);
                    $display("  sub=%1h  X=%04h  Y=%04h  astat_in=%04h",
                             v_sub, v_x[15:0], v_y[15:0], v_astat[15:0]);
                    $display("  MAME astat=%04h   ours astat=%04h", v_astate[15:0], got[31:16]);
                end
            end

            release dut.u_adsp.astat;
            release dut.u_adsp.mstat;

            nvec = nvec + 1;
            rc = $fscanf(vfd, "%h %h %h %h %h %h %h\n",
                         v_sub, v_x, v_y, v_astat, v_mstat, v_are, v_astate);
        end
        $fclose(vfd);

        $display("");
        $display("=== ALU vector replay ===");
        $display("  vectors        : %0d", nvec);
        $display("  result differs : %0d", bad_val);
        $display("  flags differ   : %0d", bad_flag);
        $display("=========================");
        if (nvec == 0)
            $fatal(1, "no vectors were read from %s", vec_path);
        if (bad_val != 0)
            $fatal(1, "ALU produces different results than MAME on %0d of %0d real operand sets",
                   bad_val, nvec);
        if (bad_flag != 0)
            $fatal(1, "ALU flags differ from MAME on %0d of %0d real operand sets",
                   bad_flag, nvec);
        $display("PASS: ALU matches MAME on %0d real operand sets from the decoder", nvec);
        $finish;
    end

endmodule

`default_nettype wire
