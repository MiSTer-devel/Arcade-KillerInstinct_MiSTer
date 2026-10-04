// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_debug_screen (
  input  wire         clk,
  input  wire         frame_start,
  input  wire   [9:0] h_count,
  input  wire   [9:0] v_count,
  input  wire         display_enable,

  input  wire         cpu_reset,
  input  wire         boot_loaded,
  input  wire         pll_locked,
  input  wire         image_present,
  input  wire   [5:0] cpu_errors,
  input  wire  [31:0] cpu_pc,
  input  wire  [31:0] cpu_retired,
  input  wire  [31:0] cpu_irq_count,
  // Sticky first-failure read ownership scoreboard. RT packs mismatch causes,
  // expected/actual class and sequence tags; RA/RE are returned/expected
  // physical addresses. All remain zero when every response owns its request.
  input  wire  [31:0] cpu_response_status,
  input  wire  [31:0] reset_info,
  input  wire  [31:0] reset_first,
  input  wire  [31:0] cpu_prev_op,
  // Flags for the EE/EX/ET group on the status page:
  //   31:16  eret count, saturating
  //   3      Status.ERL at the eret - 1 means the target came from ErrorEPC
  //   2      EXL   1  BEV   0  IE
  input  wire  [31:0] cpu_eret_flags,
  input  wire  [31:0] cpu_ret_prev,
  input  wire  [31:0] cpu_ret_count,
  input  wire  [31:0] cpu_ret_pc,
  // AU/AF: PCM FIFO health. See ki_dcs_audio.sv and the row 11/14 renderers.
  input  wire  [31:0] pcm_health,
  input  wire  [31:0] pcm_level,
  input  wire  [31:0] ata_info,
  input  wire  [31:0] cpu_t2_reload_count,
  input  wire   [9:0] video_max_v_count,
  input  wire         video_vblank_seen,
  input  wire         cpu_vblank_seen,
  input  wire  [31:0] vblank_count,
  input  wire   [2:0] ata_state,
  input  wire   [7:0] ata_status,
  input  wire   [7:0] ata_error,

  // ---------------------------------------------------------------------
  // Page 1: the frozen pre-event execution trace.
  //
  // Selected by the OSD, and deliberately a SEPARATE page rather than more
  // rows. There are only fifteen 20-column rows on a 320x240 screen and the
  // status page already fills them; the trace needs eight of its own before
  // any of the COP0 or store fields, so the two cannot coexist.
  //
  // trace_bus is passed whole and sliced by row rather than unpacked into
  // sixteen named ports. That is one 8:1 mux over 64 bits instead of sixteen
  // hex renderers, and it makes the row order structural: row 1 is always the
  // oldest decode and row 8 always the landing.
  //
  // trace_valid is the clk_core side saying it has latched a frozen capture.
  // Zero means the trace never froze, which is itself the answer if a restart
  // ever happens WITHOUT a RAM -> boot ROM transition.
  // 0 status, 1 trace, 2 performance census.
  input  wire   [1:0] page,
  // Per-frame stall census from ki_cpu_core; ten 16-bit fields, each counting
  // units of 256 CPU cycles. See debug_perf_bus there for the field order.
  input  wire [223:0] perf,
  // The worst frame since the last clear, same ten fields. Gameplay slowdowns
  // are occasional, so the live row usually shows a good frame.
  input  wire [223:0] perf_worst,
  input  wire [271:0] perf_prof,
  // Which coarse bucket F0..F7 cover. Latched with perf_prof in the CPU, so
  // the header digit always describes the frame the numbers came from.
  input  wire   [2:0] prof_fine_base,
  input  wire [895:0] trace_bus,
  input  wire         trace_valid,

  // Physical SDRAM self-test result. Kept in its own snapshot vector because
  // the main one has hardcoded bit indices elsewhere in this file.
  input  wire         bist_done,
  input  wire         bist_pass,
  input  wire  [15:0] bist_error_count,
  input  wire  [15:0] bist_first_bad_expected,
  input  wire  [15:0] bist_first_bad_actual,

  output logic  [7:0] red,
  output logic  [7:0] green,
  output logic  [7:0] blue
);
  localparam int SNAPSHOT_BITS = $bits({
        cpu_reset,
        boot_loaded,
        pll_locked,
        image_present,
        cpu_errors,
        cpu_pc,
        cpu_retired,
        cpu_irq_count,
        cpu_response_status,
        reset_info,
        reset_first,
        cpu_prev_op,
        cpu_ret_prev,
        cpu_eret_flags,
        cpu_ret_count,
        cpu_ret_pc,
        pcm_health,
        pcm_level,
        ata_info,
        cpu_t2_reload_count,
        video_max_v_count,
        video_vblank_seen,
        cpu_vblank_seen,
        vblank_count,
        ata_state,
        ata_status,
        ata_error
  });
  logic [SNAPSHOT_BITS-1:0] diagnostic_snapshot = '0;
  logic [54:0] bist_snapshot = 55'd0;
  logic [5:0] errors_snapshot = 6'd0;

  always_ff @(posedge clk) begin
    if (frame_start)
      diagnostic_snapshot <= {
        cpu_reset,
        boot_loaded,
        pll_locked,
        image_present,
        cpu_errors,
        cpu_pc,
        cpu_retired,
        cpu_irq_count,
        cpu_response_status,
        reset_info,
        reset_first,
        cpu_prev_op,
        cpu_ret_prev,
        cpu_eret_flags,
        cpu_ret_count,
        cpu_ret_pc,
        pcm_health,
        pcm_level,
        ata_info,
        cpu_t2_reload_count,
        video_max_v_count,
        video_vblank_seen,
        cpu_vblank_seen,
        vblank_count,
        ata_state,
        ata_status,
        ata_error
      };
      errors_snapshot <= cpu_errors;
      bist_snapshot <= {
        5'd0, bist_done, bist_pass, bist_error_count,
        bist_first_bad_expected,
        bist_first_bad_actual
      };
  end

  function automatic [7:0] hex_ascii(input logic [3:0] value);
    hex_ascii = (value < 10) ? (8'h30 + {4'd0, value})
                             : (8'h41 + {4'd0, value} - 8'd10);
  endfunction

  function automatic [7:0] hex32_ascii(
    input logic [31:0] value,
    input logic  [3:0] digit
  );
    logic [31:0] shifted;
    begin
      shifted = value >> ((7 - digit) * 4);
      hex32_ascii = hex_ascii(shifted[3:0]);
    end
  endfunction

  // "XX:hhhh" at a fixed column, so the perf page reads as two columns of
  // labelled counters rather than a wall of hex.
  function automatic [7:0] perf_field(
    input logic  [4:0] column,
    input logic  [4:0] base,
    input logic  [7:0] c0,
    input logic  [7:0] c1,
    input logic [15:0] value
  );
    logic [15:0] shifted;
    begin
      perf_field = " ";
      if (column == base) begin
        perf_field = c0;
      end else if (column == base + 5'd1) begin
        perf_field = c1;
      end else if (column == base + 5'd2) begin
        perf_field = ":";
      end else if (column >= base + 5'd3 && column <= base + 5'd6) begin
        shifted = value >> ((base + 5'd6 - column) * 4);
        perf_field = hex_ascii(shifted[3:0]);
      end
    end
  endfunction

  // WHERE the frame's instructions retired - the profile page.
  //
  // Every other counter in this core says how much time went somewhere. This
  // one says which CODE ran. Nothing on the other pages could show that,
  // because spinning RETIRES instructions and so reads as healthy work.
  //
  // TWO maps of the same frame. B0..B7/OT are eight 32 KB buckets over
  // 0x88000000 plus one for everything else; F0..F7 are eight 4 KB buckets
  // inside the hottest coarse bucket, because 32 KB is too wide to name a
  // loop.
  //
  // This is the SAME frame as the Perf page's worst block - the one that lost
  // the most cycles outside stage 4 since the last Clear - so SUM(B)/CY is a
  // real check. It is the worst frame of ANY scene since Clear: on KI2 that
  // is the FMV player if a video played, so Clear during the scene you want.
  function automatic [7:0] prof_char(
    input logic  [3:0] row,
    input logic  [4:0] column,
    input logic [271:0] p,
    input logic   [2:0] fb
  );
    logic [15:0] f [0:16];
    integer i;
    begin
      for (i = 0; i < 17; i = i + 1)
        f[i] = p[i*16 +: 16];
      prof_char = " ";
      case (row)
        0: case (column)
          0: prof_char="K"; 1: prof_char="I"; 3: prof_char="P";
          4: prof_char="R"; 5: prof_char="O"; 6: prof_char="F";
          default: prof_char=" ";
        endcase
        1: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "B", "0", f[0])
                                       : perf_field(column, 5'd8, "B", "1", f[1]);
        2: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "B", "2", f[2])
                                       : perf_field(column, 5'd8, "B", "3", f[3]);
        3: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "B", "4", f[4])
                                       : perf_field(column, 5'd8, "B", "5", f[5]);
        4: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "B", "6", f[6])
                                       : perf_field(column, 5'd8, "B", "7", f[7]);
        5: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "O", "T", f[8])
                                       : " ";
        // The fine map, 4 KB a bucket, of whichever coarse bucket was hottest
        // in the frame these counts came from.
        6: case (column)
          0: prof_char="B"; 1: prof_char=hex_ascii({1'b0, fb});
          3: prof_char="4"; 4: prof_char="K";
          default: prof_char=" ";
        endcase
        7: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "F", "0", f[9])
                                       : perf_field(column, 5'd8, "F", "1", f[10]);
        8: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "F", "2", f[11])
                                       : perf_field(column, 5'd8, "F", "3", f[12]);
        9: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "F", "4", f[13])
                                       : perf_field(column, 5'd8, "F", "5", f[14]);
        10: prof_char = (column < 5'd8) ? perf_field(column, 5'd0, "F", "6", f[15])
                                        : perf_field(column, 5'd8, "F", "7", f[16]);
        default: prof_char = " ";
      endcase
    end
  endfunction

  // Where the CPU's cycles went in the frame just finished. Effective speed is
  // clock x IPC, and this is the IPC half. CY is the frame length, so every
  // other field is read against it - a full 100 MHz frame is about 1970 hex
  // units of 256 cycles.
  function automatic [7:0] perf_char(
    input logic  [3:0] row,
    input logic  [4:0] column,
    input logic [223:0] p,
    input logic [223:0] w
  );
    logic [15:0] f [0:13];
    logic  [3:0] r;
    integer i;
    begin
      // Rows 8-13 repeat the same six rows for the worst frame, so one
      // renderer serves both blocks and they cannot drift apart.
      r = (row >= 4'd8) ? (row - 4'd7) : row;
      for (i = 0; i < 14; i = i + 1)
        f[i] = (row >= 4'd8) ? w[i*16 +: 16] : p[i*16 +: 16];
      perf_char = " ";
      case (r)
        0: case (column)
          0: perf_char="K"; 1: perf_char="I"; 3: perf_char="P";
          4: perf_char="E"; 5: perf_char="R"; 6: perf_char="F";
          default: perf_char=" ";
        endcase
        // Frame length and instructions retired: CY/RT is IPC in 256-cycle
        // units, and the single number that says whether the clock is even
        // the limit.
        1: perf_char = (column < 5'd8) ? perf_field(column, 5'd0, "C", "Y", f[0])
                                       : perf_field(column, 5'd8, "R", "T", f[1]);
        // THE LOST-CYCLE CENSUS: every cycle retires (RT) or is lost to one
        // cause, so CY - RT = S4 + MD + S3 + S1 + LB, give or take
        // rounding. S4 is stage 4 waiting on memory; DC is its cached part.
        2: perf_char = (column < 5'd8) ? perf_field(column, 5'd0, "S", "4", f[4])
                                       : perf_field(column, 5'd8, "D", "C", f[7]);
        // UW is a store the full write FIFO will not take yet. UF is an
        // uncached load from the framebuffer pages. UO (row 6) is the rest:
        // S4 = DC + UW + UF + UO.
        3: perf_char = (column < 5'd8) ? perf_field(column, 5'd0, "U", "W", f[3])
                                       : perf_field(column, 5'd8, "U", "F", f[5]);
        // Stage 3 frozen on a multiply or divide (MD).
        //
        // LM: of MC's misses, the ones that landed BELOW 0x0008_0000 - the
        // 512 KiB the board builds from 20ns SRAM, which this core serves
        // from SDRAM like everything else. MC - LM is the DRAM region's
        // share. A count, not cycles, like MC.
        //
        // S3 has no field here; row 14 shows it for both frames. Its bit
        // still feeds nm_cnt and the CY - RT identity.
        4: perf_char = (column < 5'd8) ? perf_field(column, 5'd0, "M", "D", f[8])
                                       : perf_field(column, 5'd8, "L", "M", f[12]);
        // S1: stage 1 waiting for an instruction (an instruction cache miss).
        // LB: a load's stage-3 hold, and the empty slot it leaves.
        5: perf_char = (column < 5'd8) ? perf_field(column, 5'd0, "S", "1", f[10])
                                       : perf_field(column, 5'd8, "L", "B", f[11]);
        // UO: every other uncached load - I/O (the disk's data port), boot
        // ROM, RAM through KSEG1.
        //
        // MC: a COUNT of D-cache misses, not a cycle count. MC and LM are the
        // two fields on the page NOT scaled by 256 - they carry the count
        // itself, because scaling by 256 would round a light frame to zero;
        // DI, on row 7, is cycles and IS scaled. Every other field here is
        // units of 256 cycles.
        //
        // DC / MC is CYCLES A MISS, which nothing else on any page could give:
        // the two self-checks below are about where cycles GO, and cannot say
        // whether a frame is bound by the number of misses or by the cost of
        // each.
        6: perf_char = (column < 5'd8) ? perf_field(column, 5'd0, "U", "O", f[6])
                                       : perf_field(column, 5'd8, "M", "C", f[2]);
        default: perf_char = " ";
      endcase
      // Row 7 labels the second block, and the field its frame was chosen by;
      // row 0 keeps the page title.
      // Columns 0-7 of row 7 are the only free field on a page whose every
      // other row is full (rows 1-6 and 8-13 carry two fields each, row 14
      // carries S3, and there is no third column because H_VISIBLE 320 shows
      // only columns 0-19). The field goes at the LEFT so it lines up with the
      // live block's own first column directly above it, and the header sits
      // to its right rather than the field sitting under the word WORST and
      // being read as part of it.
      //
      // DI - the LIVE frame's recoverable load bubbles, in units of 256 cycles
      // like LB beside it, so DI/LB is the share of the load bubble that an
      // interlock paying only on a real dependency would give back. The real
      // R4600 does exactly that: 1.03 cycles for an independent cached load,
      // 2.01 in a dependent chain, measured on the board; LOAD_INTERLOCK
      // (cpu.vhd) gives this core the same behavior. DI counts only a bubble
      // taken that need not have been, and should read about zero. It is the
      // LIVE frame on purpose: the worst-NM frame can be an outlier (an FMV
      // frame, an idle frame), and the question is what a TYPICAL fight frame
      // would gain. DI <= LB always.
      if (row == 4'd7) begin
        if (column < 5'd8) begin
          perf_char = perf_field(column, 5'd0, "D", "I", f[13]);
        end else begin
          case (column)
            8: perf_char="W"; 9: perf_char="O"; 10: perf_char="R";
            11: perf_char="S"; 12: perf_char="T";
            14: perf_char="N"; 15: perf_char="M";
            default: perf_char=" ";
          endcase
        end
      end
      // Row 14 - v_count 224-239, the LAST row inside V_VISIBLE 240. There is
      // no row 15 and no third column (H_VISIBLE 320 shows columns 0-19), so
      // this is the only slot left on the page.
      //
      // S3 is stage 3 frozen on something other than a multiply or divide:
      // the FPU, a TLB probe. It is a term of the CY - RT = S4 + MD + S3 + S1
      // + LB identity.
      //
      // It is FRAME-DEPENDENT: do not conclude anything here from a single
      // frame.
      //
      // It shows BOTH frames rather than following the block layout, because
      // nm_cnt - which picks the worst frame - is MD or S3 or S1 or LB, so
      // the worst block is where an S3 spike would appear first and the
      // comparison against the live frame is the point. 3L is live, 3W worst.
      // It is the one row reading p and w at once, hence the direct indexing
      // instead of f[].
      if (row == 4'd14) begin
        perf_char = (column < 5'd8)
                  ? perf_field(column, 5'd0, "3", "L", p[9*16 +: 16])
                  : perf_field(column, 5'd8, "3", "W", w[9*16 +: 16]);
      end
    end
  endfunction

  function automatic [7:0] screen_char(
    input logic [3:0] row,
    input logic [4:0] column,
    input logic [SNAPSHOT_BITS-1:0] data,
    input logic [54:0] bist
  );
    logic        d_bist_done;
    logic        d_bist_pass;
    logic [15:0] d_bist_error_count;
    logic [15:0] d_bist_first_bad_expected;
    logic [15:0] d_bist_first_bad_actual;
    logic  [4:0] d_bist_unused;
    logic        d_cpu_reset;
    logic        d_boot_loaded;
    logic        d_pll_locked;
    logic        d_image_present;
    logic  [5:0] d_cpu_errors;
    logic [31:0] d_cpu_pc;
    logic [31:0] d_cpu_retired;
    logic [31:0] d_cpu_irq_count;
    logic [31:0] d_cpu_response_status;
    logic [31:0] d_reset_info;
    logic [31:0] d_reset_first;
    logic [31:0] d_cpu_prev_op;
    logic [31:0] d_cpu_ret_prev;
    logic [31:0] d_cpu_eret_flags;
    logic [31:0] d_cpu_ret_count;
    logic [31:0] d_cpu_ret_pc;
    logic [31:0] d_pcm_health;
    logic [31:0] d_pcm_level;
    logic [31:0] d_ata_info;
    logic [31:0] d_cpu_t2_reload_count;
    logic  [9:0] d_video_max_v_count;
    logic        d_video_vblank_seen;
    logic        d_cpu_vblank_seen;
    logic [31:0] d_vblank_count;
    logic  [2:0] d_ata_state;
    logic  [7:0] d_ata_status;
    logic  [7:0] d_ata_error;
    begin
      {
        d_cpu_reset,
        d_boot_loaded,
        d_pll_locked,
        d_image_present,
        d_cpu_errors,
        d_cpu_pc,
        d_cpu_retired,
        d_cpu_irq_count,
        d_cpu_response_status,
        d_reset_info,
        d_reset_first,
        d_cpu_prev_op,
        d_cpu_ret_prev,
        d_cpu_eret_flags,
        d_cpu_ret_count,
        d_cpu_ret_pc,
        d_pcm_health,
        d_pcm_level,
        d_ata_info,
        d_cpu_t2_reload_count,
        d_video_max_v_count,
        d_video_vblank_seen,
        d_cpu_vblank_seen,
        d_vblank_count,
        d_ata_state,
        d_ata_status,
        d_ata_error
      } = data;
      {
        d_bist_unused, d_bist_done, d_bist_pass, d_bist_error_count,
        d_bist_first_bad_expected,
        d_bist_first_bad_actual
      } = bist;
      screen_char = " ";
      case (row)
        0: case (column)
          0: screen_char="K"; 1: screen_char="I"; 3: screen_char="D";
          4: screen_char="E"; 5: screen_char="B"; 6: screen_char="U";
          7: screen_char="G"; 9: screen_char="V";
          10: screen_char="1"; 11: screen_char="5"; 12: screen_char="8";
          default: screen_char=" ";
        endcase
        1: case (column)
          0: screen_char="R"; 1: screen_char="S"; 2: screen_char="T";
          3: screen_char=":"; 4: screen_char=8'h30+d_cpu_reset;
          6: screen_char="B"; 7: screen_char="O"; 8: screen_char="O";
          9: screen_char="T"; 10: screen_char=":";
          11: screen_char=8'h30+d_boot_loaded;
          13: screen_char="V"; 14: screen_char="M"; 15: screen_char=":";
          16: screen_char=hex_ascii({2'b00, d_video_max_v_count[9:8]});
          17: screen_char=hex_ascii(d_video_max_v_count[7:4]);
          18: screen_char=hex_ascii(d_video_max_v_count[3:0]);
          20: screen_char="V"; 21: screen_char="S"; 22: screen_char=":";
          23: screen_char=8'h30+d_video_vblank_seen;
          default: screen_char=" ";
        endcase
        2: case (column)
          0: screen_char="P"; 1: screen_char="L"; 2: screen_char="L";
          3: screen_char=":"; 4: screen_char=8'h30+d_pll_locked;
          6: screen_char="H"; 7: screen_char="D"; 8: screen_char="D";
          9: screen_char=":"; 10: screen_char=8'h30+d_image_present;
          12: screen_char="V"; 13: screen_char="B"; 14: screen_char=":";
          default: begin
            if (column >= 15 && column <= 19)
              screen_char=hex32_ascii(d_vblank_count, column-12);
          end
        endcase
        3: case (column)
          0: screen_char="E"; 1: screen_char="R"; 2: screen_char="R";
          3: screen_char=":"; 4: screen_char=hex_ascii({2'b00,d_cpu_errors[5:4]});
          5: screen_char=hex_ascii(d_cpu_errors[3:0]);
          7: screen_char="I"; 8: screen_char=":";
          default: begin
            if (column >= 9 && column <= 16)
              screen_char=hex32_ascii(d_cpu_irq_count, column-9);
            else if (column == 17)
              screen_char="V";
            else if (column == 18)
              screen_char=":";
            else if (column == 19)
              screen_char=8'h30+d_cpu_vblank_seen;
          end
        endcase
        4: begin
          if (column == 0) screen_char="P";
          else if (column == 1) screen_char="C";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_cpu_pc, column-3);
          // TR counts decodes of 9FC00728, the top of a pass. Frozen while
          // PC sits in the pass body means the loop is not being re-entered.
          else if (column == 12) screen_char="T";
          else if (column == 13) screen_char="R";
          else if (column == 14) screen_char=":";
          else if (column >= 15 && column <= 19)
            screen_char=hex32_ascii(d_cpu_t2_reload_count, column-12);
        end
        5: begin
          if (column == 0) screen_char="D";
          else if (column == 1) screen_char="S";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_cpu_ret_pc, column-3);
        end
        // EP/AC are the BIST stall decode and only mean anything when the
        // self test FAILED. While it passes, this row carries the retired
        // instruction count instead.
        //
        // Columns 16-19 carry the SDRAM verdict in BOTH branches: a failed
        // self test makes every other field on this screen noise, and it must
        // never be possible to read the screen and not notice.
        6: begin
          if (column == 16) screen_char="S";
          else if (column == 17) screen_char="D";
          else if (column == 18) screen_char=":";
          else if (column == 19)
            screen_char = !d_bist_done ? "R" : (d_bist_pass ? "P" : "F");
          else if (!d_bist_pass) begin
            if (column == 0) screen_char="E";
            else if (column == 1) screen_char="P";
            else if (column == 2) screen_char=":";
            else if (column >= 3 && column <= 6)
              screen_char=hex32_ascii({16'd0, d_bist_first_bad_expected},
                                      column+1);
            else if (column == 8) screen_char="A";
            else if (column == 9) screen_char="C";
            else if (column == 10) screen_char=":";
            else if (column >= 11 && column <= 14)
              screen_char=hex32_ascii({16'd0, d_bist_first_bad_actual},
                                      column-7);
          end else begin
            if (column == 0) screen_char="N";
            else if (column == 1) screen_char=":";
            else if (column >= 2 && column <= 9)
              screen_char=hex32_ascii(d_cpu_retired, column-2);
            else if (column == 11) screen_char="E";
            else if (column == 12) screen_char="C";
            else if (column == 13) screen_char=":";
            // error_count is {burst_errors, single_errors}, and the burst half
            // is the one that goes non-zero first when the path is marginal: a
            // marginal phase fails the burst read first, and showing only the
            // single byte would display that as a clean PASS. Burst reads are
            // the scanout-shaped access the low-RAM sweep exists to ask about.
            // Only two columns are free - 16-19 are taken by SD:P earlier in
            // this chain and 19 is the last visible column - so encode
            // PRESENCE of each half, which fits and keeps both:
            //
            //   00 clean   10 burst only   01 single only   11 both
            //
            // first_bad_address still names the region and the exact word.
            else if (column == 14)
              screen_char = (|d_bist_error_count[15:8]) ? "1" : "0";
            else if (column == 15)
              screen_char = (|d_bist_error_count[7:0]) ? "1" : "0";
          end
        end
        7: begin
          if (column == 0) screen_char="E";
          else if (column == 1) screen_char="E";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_cpu_response_status, column-3);
          else if (column == 12) screen_char="L";
          else if (column == 13) screen_char=":";
          else if (column == 14) screen_char=8'h30+{7'd0, d_cpu_eret_flags[3]};
          else if (column == 16) screen_char="N";
          else if (column == 17) screen_char=":";
          // The count lives in bits 31:16, so its low two digits are hex
          // digits 2 and 3 of the word - column-16, not column-12.
          else if (column >= 18 && column <= 19)
            screen_char=hex32_ascii(d_cpu_eret_flags, column-16);
        end
        8: begin
          if (column == 0) screen_char="R";
          else if (column == 1) screen_char="S";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_reset_info, column-3);
        end
        // RP: the last address executed in RAM before control left it.
        // DO: the opcode fetched at the DEPARTURE address in RL, which is the
        // instruction that sends control to the boot ROM.
        //
        // DO names that instruction: a jr/j is the game rebooting itself
        // deliberately, which is what an error or watchdog path looks like.
        //
        // RF isolates the first reset the operator did NOT cause, which the
        // sticky mask in RS cannot do - every test run contains one deliberate
        // OSD reset and RS ORs it in permanently.
        //
        //   digits 0-3 cause mask of that first spontaneous reset alone
        //   digits 4-5 PLL unlock count, taken in the 50 MHz reference domain
        //              so it survives the PLL it is watching
        //   digit  6   spontaneous late resets, saturating at F
        //   digit  7   ROM/ioctl downloads, which also reset everything
        //
        // RF:00000001 means nothing reset the core except the operator and the
        // ROM load - and then the restart is NOT a reset after all.
        9: begin
          if (column == 0) screen_char="R";
          else if (column == 1) screen_char="F";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_reset_first, column-3);
        end
        10: begin
          if (column == 0) screen_char="D";
          else if (column == 1) screen_char="P";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_cpu_prev_op, column-3);
        end
        // ET: the address eret actually jumped to, selected from EPC or
        // ErrorEPC the same way cpu_cop0 selects eretPC. Captured rather than
        // inferred so ERL does not have to be trusted to reconstruct it.
        //
        // AU shows first-audio time and the saturating discontinuity count.
        11: begin
          if (column == 0) screen_char="E";
          else if (column == 1) screen_char="T";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_cpu_ret_prev, column-3);
          else if (column == 11) screen_char=" ";
          else if (column == 12) screen_char="A";
          else if (column == 13) screen_char="U";
          else if (column == 14) screen_char=":";
          else if (column >= 15 && column <= 19)
            screen_char=hex32_ascii(d_pcm_health, column-12);
        end
        // RC carries BOTH restart shapes, because they are mutually
        // exclusive explanations of the same symptom:
        //
        //   digits 0-1  executions of 0x88000000, the address the boot ROM
        //               hands control to. Boot is exactly 1; 2 or more is the
        //               game restarting ITSELF, which leaves no reset and no
        //               boot-ROM transition.
        //   digits 2-3  ATA INITIALIZE DEVICE PARAMETERS commands. Only the
        //               disk-init routine issues one and only startup calls
        //               it, so this is the same question asked a second way -
        //               and it does not depend on guessing an address.
        //   digits 4-7  RAM -> boot ROM transitions, the departure count.
        //
        // With RS and RF that is a complete decision table for a restart:
        // reset, jump to ROM, software re-entry, or none of the three.
        12: begin
          if (column == 0) screen_char="R";
          else if (column == 1) screen_char="C";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_cpu_ret_count, column-3);
        end
        // The disk.
        //
        // AT is the ATA state machine, SR the status register, ER the error
        // register - note ER reads 01 out of RESET (ki_ata.sv:287), so 01 is
        // the idle value and not a fault.
        13: case (column)
          0: screen_char="A"; 1: screen_char="T"; 2: screen_char=":";
          3: screen_char=hex_ascii({1'b0, d_ata_state});
          5: screen_char="S"; 6: screen_char="R"; 7: screen_char=":";
          8: screen_char=hex_ascii(d_ata_status[7:4]);
          9: screen_char=hex_ascii(d_ata_status[3:0]);
          11: screen_char="E"; 12: screen_char="R"; 13: screen_char=":";
          14: screen_char=hex_ascii(d_ata_error[7:4]);
          15: screen_char=hex_ascii(d_ata_error[3:0]);
          default: screen_char=" ";
        endcase
        // AC packs, left to right:
        //
        //   digits 0-1   the LAST COMMAND byte the game wrote. EC is
        //                IDENTIFY, 20/21/C4 read sectors, 30/31/C5 write.
        //   digit  2     bit 3 irq line now, bit 2 irq_pending, bit 1 nIEN
        //                (interrupts DISABLED when set), bit 0 unused
        //   digits 3-4   the live sector-buffer index
        //   digits 5-7   data-port writes accepted, the write-path counter
        // AF shows the worst output step and the same discontinuity count.
        14: begin
          if (column == 0) screen_char="A";
          else if (column == 1) screen_char="C";
          else if (column == 2) screen_char=":";
          else if (column >= 3 && column <= 10)
            screen_char=hex32_ascii(d_ata_info, column-3);
          else if (column == 11) screen_char=" ";
          else if (column == 12) screen_char="A";
          else if (column == 13) screen_char="F";
          else if (column == 14) screen_char=":";
          else if (column >= 15 && column <= 19)
            screen_char=hex32_ascii(d_pcm_level, column-12);
        end
        default: screen_char = " ";
      endcase
    end
  endfunction

  function automatic [7:0] trace_char(
    input logic  [3:0] row,
    input logic  [4:0] column,
    input logic [895:0] trace,
    input logic        valid
  );
    logic [63:0] entry;
    logic  [3:0] source;
    logic  [2:0] entry_index;
    begin
      trace_char = " ";
      // Rows 1 to 8 map to entries 0 to 7. Taking the low three bits keeps the
      // part-selects in range for every row value, including the ones that do
      // not use them, so no row can index past the end of the vector.
      entry_index = row[2:0] - 3'd1;
      entry  = trace[{entry_index, 6'd0} +: 64];
      source = trace[512 + {entry_index, 2'd0} +: 4];
      case (row)
        0: case (column)
          0: trace_char="K"; 1: trace_char="I";
          3: trace_char="T"; 4: trace_char="R"; 5: trace_char="A";
          6: trace_char="C"; 7: trace_char="E";
          9: trace_char="V"; 10: trace_char="1"; 11: trace_char="5";
          12: trace_char="8";
          default: trace_char=" ";
        endcase
        1, 2, 3, 4, 5, 6, 7, 8: begin
          if (column == 0) trace_char=hex_ascii(source);
          else if (column >= 2 && column <= 9)
            trace_char=hex32_ascii(entry[63:32], column-2);
          else if (column >= 11 && column <= 18)
            trace_char=hex32_ascii(entry[31:0], column-11);
        end
        9: begin
          if (column == 0) trace_char="C";
          else if (column == 1) trace_char="S";
          else if (column == 2) trace_char=":";
          else if (column >= 3 && column <= 10)
            trace_char=hex32_ascii(trace[575:544], column-3);
          else if (column == 12) trace_char="F";
          else if (column == 13) trace_char="R";
          else if (column == 14) trace_char=":";
          else if (column == 15) trace_char=8'h30+{7'd0, valid};
          else if (column == 17) trace_char="T";
          else if (column == 18) trace_char=":";
          else if (column == 19) trace_char=hex_ascii({1'b0, trace[738:736]});
        end
        10: begin
          if (column == 0) trace_char="E";
          else if (column == 1) trace_char="P";
          else if (column == 2) trace_char=":";
          else if (column >= 3 && column <= 10)
            trace_char=hex32_ascii(trace[607:576], column-3);
          else if (column == 13) trace_char="G";
          else if (column == 14) trace_char=":";
          else if (column == 15) trace_char=8'h30+{7'd0, trace[739]};
        end
        11: begin
          if (column == 0) trace_char="B";
          else if (column == 1) trace_char="V";
          else if (column == 2) trace_char=":";
          else if (column >= 3 && column <= 10)
            trace_char=hex32_ascii(trace[799:768], column-3);
        end
        12: begin
          if (column == 0) trace_char="S";
          else if (column == 1) trace_char="1";
          else if (column == 2) trace_char=":";
          else if (column >= 3 && column <= 10)
            trace_char=hex32_ascii(trace[831:800], column-3);
        end
        13: begin
          if (column == 0) trace_char="S";
          else if (column == 1) trace_char="2";
          else if (column == 2) trace_char=":";
          else if (column >= 3 && column <= 10)
            trace_char=hex32_ascii(trace[863:832], column-3);
        end
        // TX: the translation-exception census, so "this was the first TLB
        // exception the game ever took" can be checked rather than assumed.
        //
        //   digits 0-2  data-read TLB exceptions
        //   digits 3-4  data-write
        //   digits 5-6  instruction fetch
        //   digit  7    1 = the first data exception was a refill MISS
        //               (no matching entry) rather than an invalid-entry hit
        //
        // Counts saturate instead of wrapping: a wrapped count would read as a
        // small number and be indistinguishable from a healthy one.
        14: begin
          if (column == 0) trace_char="T";
          else if (column == 1) trace_char="X";
          else if (column == 2) trace_char=":";
          else if (column >= 3 && column <= 10)
            trace_char=hex32_ascii(trace[895:864], column-3);
        end
        // Row 15 is below the visible 240 lines. Anything placed there is
        // invisible on hardware; see the status page's note.
        default: trace_char = " ";
      endcase
    end
  endfunction

  function automatic [34:0] glyph_bits(input logic [7:0] character);
    begin
      case (character)
        "0": glyph_bits={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
        "1": glyph_bits={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
        "2": glyph_bits={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
        "3": glyph_bits={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
        "4": glyph_bits={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
        "5": glyph_bits={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
        "6": glyph_bits={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
        "7": glyph_bits={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
        "8": glyph_bits={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
        "9": glyph_bits={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
        "A": glyph_bits={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
        "B": glyph_bits={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
        "C": glyph_bits={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
        "D": glyph_bits={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
        "E": glyph_bits={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
        "F": glyph_bits={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
        "G": glyph_bits={5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
        "H": glyph_bits={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
        "I": glyph_bits={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
        "K": glyph_bits={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
        "L": glyph_bits={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
        "M": glyph_bits={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
        "N": glyph_bits={5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
        "O": glyph_bits={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
        "P": glyph_bits={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
        "Q": glyph_bits={5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
        "R": glyph_bits={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
        "S": glyph_bits={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
        "T": glyph_bits={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
        "U": glyph_bits={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
        "V": glyph_bits={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
        "X": glyph_bits={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
        "W": glyph_bits={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
        ":": glyph_bits={5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
        default: glyph_bits=35'd0;
      endcase
    end
  endfunction

  logic [7:0] character;
  logic [34:0] glyph;
  logic [34:0] shifted_glyph;
  logic [4:0] glyph_row;
  logic glyph_pixel;
  logic [2:0] font_x;
  logic [2:0] font_y;

  always_comb begin
    // The trace page is not re-snapshotted at frame_start. Its source freezes
    // once and never changes again, and KillerInstinct.sv latches it on the
    // clk_core side only after that freeze has been observed, so it is already
    // a stable capture rather than a live value being sampled.
    case (page)
      2'd1: character = trace_char(v_count[7:4], h_count[8:4],
                                   trace_bus, trace_valid);
      2'd2: character = perf_char(v_count[7:4], h_count[8:4], perf, perf_worst);
      2'd3: character = prof_char(v_count[7:4], h_count[8:4], perf_prof, prof_fine_base);
      default: character = screen_char(v_count[7:4], h_count[8:4],
                                       diagnostic_snapshot, bist_snapshot);
    endcase
    glyph = glyph_bits(character);
    font_x = h_count[3:1];
    font_y = v_count[3:1];
    shifted_glyph = glyph >> ((6-font_y)*5);
    glyph_row = (font_y < 7) ? shifted_glyph[4:0] : 5'd0;
    glyph_pixel = (font_x < 5) ? glyph_row[4-font_x] : 1'b0;

    red = 8'h08;
    green = 8'h0c;
    blue = 8'h14;
    if (!display_enable) begin
      red = 8'h00;
      green = 8'h00;
      blue = 8'h00;
    end else if (glyph_pixel) begin
      if (v_count[7:4] == 0) begin
        red = 8'h40;
        green = 8'he0;
        blue = 8'hff;
      // Row 3 is the CPU error row on the status page only. On the trace page
      // it is an ordinary decode, and colouring it red would read as a fault
      // marker on whichever instruction happened to land there.
      end else if ((page == 2'd0) && (v_count[7:4] == 3) && (errors_snapshot != 0)) begin
        red = 8'hff;
        green = 8'h40;
        blue = 8'h40;
      end else begin
        red = 8'he8;
        green = 8'he8;
        blue = 8'he8;
      end
    end
  end
endmodule

`default_nettype wire
