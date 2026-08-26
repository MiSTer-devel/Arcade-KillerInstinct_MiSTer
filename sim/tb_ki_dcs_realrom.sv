// SPDX-License-Identifier: GPL-3.0-only
//
// Boot the DCS from KI's REAL sound ROM.
//
// Every other bench here feeds the core a synthetic boot page whose executable
// bytes are all zero - ADSP NOPs - which exercises the memory shim and the
// mailbox but never runs a line of KI's actual DSP program. That is the gap
// this closes, and it is the gap that matters: the DSP was verified bit-exact
// against F19, a Wolf-unit title, and never against KI's code.
//
// It exists to answer one question first. KI1's boot chime sounds 2.823 s
// after reset in MAME, and measurement on hardware shows the first host
// command does not arrive until 6.523 s - the sound registers are not touched
// at all before 6.459 s. So the chime is produced by the DCS on its own, out
// of ROM, with no host involvement whatsoever. That makes it reproducible here
// with nothing but a ROM image and time: no CPU, no command replay, no disk.
//
// The ROM is passed in with +ROM=<path> rather than committed. It is a 4 MiB
// packed image: the eight 512 KiB DCS devices concatenated in the order MAME's
// region offsets give (u10, u11, u12, u13, u33, u34, u35, u36). dcs_mem does
// the sparse-map arithmetic itself, so this only has to serve packed bytes.
//
// +RUNMS=<n> bounds the run. Reaching the chime needs about 2823 ms of
// simulated time, which is hours of wall time, so the default is a short smoke
// test: enough to see whether the program boots and starts executing at all.

`default_nettype none
`timescale 1ns/1ps

module tb_ki_dcs_realrom;

    parameter integer ENGINE_HZ = 35750000;

    // Cycles this bench takes to answer a ROM beat, overridable with
    // vsim -gROM_LATENCY=<n>. THREE IS NOT REALISTIC. On silicon a DCS ROM read
    // goes to DDR through the memory bridge and contends with the CPU and
    // video; here it is instant by comparison. Time stalled on ROM retires no
    // instructions, so if the real latency is high the DSP's effective rate
    // collapses no matter what DCS_ENGINE_HZ says - which would explain why
    // raising it fixed the chime in simulation and changed nothing on hardware.
    parameter integer ROM_LATENCY = 3;

    localparam int ROM_BYTES = 4 * 1024 * 1024;

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

    // 50 MHz, matching CLK_HZ.
    always #10 clk = !clk;

    ki_dcs_audio #(.DCS_ENGINE_HZ(ENGINE_HZ)) dut (
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

    // ---- ROM backing -------------------------------------------------------
    reg [7:0] rom [0:ROM_BYTES-1];
    string    rom_path;
    integer   romfd, got, i;

    initial begin
        for (i = 0; i < ROM_BYTES; i = i + 1) rom[i] = 8'h00;
        if (!$value$plusargs("ROM=%s", rom_path)) begin
            $display("FATAL: no +ROM=<path> given; this bench needs KI's packed DCS image");
            $finish;
        end
        romfd = $fopen(rom_path, "rb");
        if (romfd == 0) begin
            $display("FATAL: could not open ROM image '%s'", rom_path);
            $finish;
        end
        got = $fread(rom, romfd);
        $fclose(romfd);
        $display("ROM: loaded %0d bytes from %s", got, rom_path);
        if (got != ROM_BYTES)
            $display("WARNING: expected %0d bytes, got %0d", ROM_BYTES, got);
        // ROM 0 opens with a boot header followed by the ASCII title, so this
        // doubles as a check that the packing order is right side up.
        $display("ROM: first 8 bytes %02x %02x %02x %02x %02x %02x %02x %02x  ascii '%c%c%c%c'",
                 rom[0], rom[1], rom[2], rom[3], rom[4], rom[5], rom[6], rom[7],
                 rom[4], rom[5], rom[6], rom[7]);
    end

    // ---- external ROM port -------------------------------------------------
    // rom_addr is a BEAT index: eight packed bytes per beat, little-endian, so
    // byte lane 3 of beat 0 is the boot page-length header the core reads
    // first. The handshake mirrors the synthetic responder in tb_ki_dcs_audio:
    // one-cycle rom_rdy after a short delay, deliberately not aligned to the
    // ADSP enable, so the memory shim still has to latch it.
    logic        request_armed = 1'b1;
    logic        response_pending = 1'b0;
    logic [15:0] response_delay = 16'd0;
    logic [18:0] response_address = 19'h0;
    longint      rom_beats = 0;

    function automatic [63:0] beat_at(input [18:0] beat);
        integer b, k;
        begin
            b = beat * 8;
            beat_at = 64'h0;
            for (k = 0; k < 8; k = k + 1)
                if ((b + k) < ROM_BYTES)
                    beat_at[8*k +: 8] = rom[b + k];
        end
    endfunction

    always_ff @(posedge clk) begin
        rom_rdy <= 1'b0;
        if (!rom_req)
            request_armed <= 1'b1;

        if (rom_req && request_armed && !response_pending) begin
            request_armed    <= 1'b0;
            response_pending <= 1'b1;
            response_delay   <= ROM_LATENCY[15:0];
            response_address <= rom_addr;
            rom_beats        <= rom_beats + 1;
        end else if (response_pending && response_delay != 0) begin
            response_delay <= response_delay - 16'd1;
        end else if (response_pending) begin
            response_pending <= 1'b0;
            rom_q            <= beat_at(response_address);
            rom_rdy          <= 1'b1;
        end
    end

    // ---- observation -------------------------------------------------------
    // A PC bucket histogram, not a trace: MAME's DCS spends ~78% of its time in
    // 0x0100-0x01FF during play, so seeing where OUR core actually executes is
    // the quickest read on whether the real program is running or the core is
    // stuck. A full instruction-stream diff is the next step, not this one.
    longint retired = 0;
    longint pc_hist [0:63];
    logic   saw_unimpl = 1'b0;
    longint first_audio_ns = -1;
    longint audio_peak = 0;
    longint pushes = 0;

    // ---- instruction trace (+TRACE=<n>) ------------------------------------
    // One retired PC per line, to diff against MAME's own DCS trace and find
    // the first place the two diverge. Bounded, because the DSP retires ~14M
    // instructions per simulated second.
    integer trace_max = 0;
    integer tfd = 0;
    integer traced = 0;
    initial begin
        if ($value$plusargs("TRACE=%d", trace_max)) begin
            tfd = $fopen("ourtrace.txt", "w");
            $display("TRACE: writing the first %0d retired PCs to ourtrace.txt", trace_max);
        end
    end

    // Plain always, not always_ff: the initial block zeroes pc_hist, and
    // always_ff forbids a second driver.
    // dbg_valid is produced in the ADSP's enable domain, so at 50 MHz it can
    // stay asserted for more than one clock. Count the RISING EDGE or every
    // such instruction is retired twice - which it was, inflating the measured
    // rate and putting duplicate PCs in the trace.
    logic dbg_valid_d = 1'b0;
    wire  retire_now = dbg_valid && !dbg_valid_d;

    always @(posedge clk) begin
        dbg_valid_d <= dbg_valid;
        if (!rst) begin
            if (retire_now) begin
                retired <= retired + 1;
                pc_hist[dbg_pc[13:8]] <= pc_hist[dbg_pc[13:8]] + 1;
                if ((tfd != 0) && (traced < trace_max)) begin
                    // PC *and* the accumulators. The PC stream alone proved
                    // control flow matches MAME for 2.6M instructions, but the
                    // crackle is a DATA fault: at maximum volume MAME reaches
                    // the rail and stops, so its DSP saturates where ours
                    // produces a value big enough to wrap. Two cores can walk
                    // identical control flow while computing different values
                    // right up until one of them affects a branch, so a PC diff
                    // is blind to exactly this. AR and MR are where the mixer's
                    // arithmetic lands.
                    //
                    // gr is the banked register file: `G0(i) is
                    // gr[{bnk,4'b0} + i], with AR at 10 and MR0/MR1/MR2 at
                    // 11/12/13. bnk follows MSTAT bit 0, so read it live rather
                    // than assuming bank zero.
                    $fwrite(tfd, "%04x %04x %04x %04x %04x
", dbg_pc,
                            dut.u_adsp.gr[{dut.u_adsp.mstat[0], 4'd10}],
                            dut.u_adsp.gr[{dut.u_adsp.mstat[0], 4'd11}],
                            dut.u_adsp.gr[{dut.u_adsp.mstat[0], 4'd12}],
                            dut.u_adsp.gr[{dut.u_adsp.mstat[0], 4'd13}]);
                    traced = traced + 1;
                    if (traced == trace_max) begin
                        $fclose(tfd);
                        tfd = 0;
                        $display("TRACE: captured %0d PCs", trace_max);
                    end
                end
            end
            if (dbg_unimpl) saw_unimpl <= 1'b1;
            if (dbg_pcm_push) pushes <= pushes + 1;
            if (audio !== 16'sh0000) begin
                if (first_audio_ns < 0) first_audio_ns = $time;
                if ((audio > 0 ? audio : -audio) > audio_peak)
                    audio_peak <= (audio > 0 ? audio : -audio);
            end
        end
    end

    logic ack_resp;
    initial begin
        ack_resp = $test$plusargs("ACKRESP");
        if (ack_resp) begin
            $display("ACK: forcing host_resp_rd from OUTPUT_FULL (bit 10 clear)");
            force dut.u_adsp.host_resp_rd = ~host_status[10];
        end
    end

    // ---- command injection -------------------------------------------------
    // Trigger a specific sound so the mixer runs at full scale. Correlating
    // MAME's max-volume gameplay audio against its host command stream, the
    // loudest moment in 320 s - peak 32768, exactly the rail - is preceded by
    // the pair 000d 007d, and the second loudest by the same pair. That is the
    // amplitude at which hardware crackles, and MAME reaches it with a max step
    // of 11023 and NO step above 32767: it saturates where we are suspected of
    // wrapping.
    //
    // The heartbeat first, because the game sends 0055 00aa 00ff 0000 every
    // frame and the DSP may expect to be talked to before it will act.
    task automatic send_cmd(input [15:0] v);
        begin
            @(negedge clk);
            host_cmd_data = v;
            host_cmd_wr   = 1'b1;
            @(negedge clk);
            host_cmd_wr   = 1'b0;
            #100000;   // 100 us, roughly the spacing the game uses
        end
    endtask

    integer cmd_a, cmd_b, cmd_at_ms, hb;
    string  cmd_list_path;
    integer clf, ncmd, rc, cval;
    initial begin
        if (!$value$plusargs("CMDA=%h", cmd_a)) cmd_a = 0;
        if (!$value$plusargs("CMDB=%h", cmd_b)) cmd_b = 0;
        if (!$value$plusargs("CMDMS=%d", cmd_at_ms)) cmd_at_ms = 300;
    end

    // Replay a captured sequence rather than a guessed one. The first attempt
    // sent 0055 00aa 00ff 0000 as a handshake, which is the pattern the game
    // sends every frame DURING PLAY - not what it says to a freshly reset
    // board. The real initialisation is 0055 00aa 00aa 0055, then
    // 0055 00aa 00a9 0056, then 0000 0023, and only an initialised DSP is
    // going to act on a sound trigger. +CMDLIST takes one 16-bit hex value per
    // line, so the exact captured bytes can be fed in without transcription.
    task automatic replay_list(input string path);
        begin
            clf = $fopen(path, "r");
            if (clf == 0) begin
                $display("CMDLIST: could not open %s", path);
                $finish;
            end
            ncmd = 0;
            rc = $fscanf(clf, "%h
", cval);
            while (rc == 1) begin
                send_cmd(cval[15:0]);
                ncmd = ncmd + 1;
                rc = $fscanf(clf, "%h
", cval);
            end
            $fclose(clf);
            $display("CMDLIST: replayed %0d commands from %s", ncmd, path);
        end
    endtask

    integer run_ms;
    initial begin
        for (i = 0; i < 64; i = i + 1) pc_hist[i] = 0;
        if (!$value$plusargs("RUNMS=%d", run_ms)) run_ms = 5;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);
        host_reset = 1'b0;

        $display("RUN: simulating %0d ms of DCS time", run_ms);

        if ($value$plusargs("CMDLIST=%s", cmd_list_path)) begin
            #(cmd_at_ms * 1000000);
            $display("CMD: replaying %s at %0d ms", cmd_list_path, cmd_at_ms);
            replay_list(cmd_list_path);
            #((run_ms - cmd_at_ms) * 1000000);
        end else if (cmd_a != 0 || cmd_b != 0) begin
            #(cmd_at_ms * 1000000);
            $display("CMD: heartbeat, then %04h %04h at %0d ms", cmd_a[15:0], cmd_b[15:0], cmd_at_ms);
            for (hb = 0; hb < 4; hb = hb + 1) begin
                send_cmd(16'h0055); send_cmd(16'h00aa);
                send_cmd(16'h00ff); send_cmd(16'h0000);
            end
            if (cmd_a != 0) send_cmd(cmd_a[15:0]);
            if (cmd_b != 0) send_cmd(cmd_b[15:0]);
            #((run_ms - cmd_at_ms) * 1000000);
        end else begin
            #(run_ms * 1000000);
        end

        $display("");
        $display("=== real-ROM boot summary ===");
        $display("  ROM beats served      : %0d", rom_beats);
        $display("  instructions retired  : %0d", retired);
        $display("  unimplemented opcode  : %s", saw_unimpl ? "YES <-- core cannot run this program" : "no");
        $display("  host_status           : %04h", host_status);
        $display("  PCM pushes            : %0d", pushes);
        $display("  ROM latency modelled  : %0d cycles", ROM_LATENCY);
        // The crackle signature. MAME at this amplitude peaks at the rail with
        // a worst step of 11023 and never exceeds 32767.
        $display("  worst |step|          : %0d   [MAME at full scale: 11023]",
                 dut.au_max_step);
        $display("  output discontinuities: %0d   [MAME: 0]", dut.au_discont);
        // Did the DSP actually TAKE the commands? Without this, a silent run
        // cannot be told apart from a run where the injection never reached the
        // core at all - and those need completely different next steps.
        $display("  commands sent         : %0d", dut.cmd_count);
        $display("  commands COLLECTED    : %s",
                 dut.seen_cmdread ? "yes" : "NO - the DSP never read the mailbox");
        $display("  commands lost unread  : %0d", dut.dcs_cmd_lost);
        if (first_audio_ns < 0)
            $display("  audio                 : silent");
        else
            $display("  audio                 : first non-zero at %0d ns, peak %0d",
                     first_audio_ns, audio_peak);
        $display("  PC buckets (pc[13:8] -> retired count, non-empty only):");
        for (i = 0; i < 64; i = i + 1)
            if (pc_hist[i] != 0)
                $display("      %02x00-%02xff : %0d", i, i, pc_hist[i]);
        $display("=============================");

        if (retired == 0)
            $fatal(1, "the core retired no instructions at all from the real ROM");
        if (saw_unimpl)
            $fatal(1, "the real DCS program reached an opcode this core does not implement");
        $display("PASS: KI DCS booted from the real sound ROM and is executing");
        $finish;
    end

endmodule

`default_nettype wire
