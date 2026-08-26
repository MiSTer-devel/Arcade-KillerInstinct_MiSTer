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
  // The bitstream reader's ROM source pointer. Its sawtooth - walk the ROM,
  // drop back, walk again - is the restart signature.
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
  input  wire         page,
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
            // ALL FOUR digits. This rendered `column-8`, i.e. nibbles 6 and 7 -
            // the LOW BYTE of a 16-bit error_count, which is `single_errors`.
            // error_count is {burst_errors, single_errors}, so the burst half
            // was discarded and a burst-only failure displayed as EC:00 and
            // looked clean. That is the exact case ki_sdram_bist's own header
            // warns about - "EC:xx00 is burst only ... a phase that is marginal
            // will fail the burst read first, and without the burst pass that
            // shows up as a PASS here" - and burst reads are the
            // scanout-shaped access the low-RAM sweep exists to ask about.
            // TWO columns is all there is: 16-19 are taken by SD:P earlier in
            // this chain and 19 is the last visible column, so the previous
            // attempt to widen this to four digits could never render and the
            // field still showed only single_errors.
            //
            // error_count is {burst_errors, single_errors} and the burst half
            // is the one that goes non-zero first when the path is marginal -
            // tb_ki_sdram_bist measures single=0 burst=254 at a bad phase - so
            // showing the single byte was showing the wrong one. Encode
            // PRESENCE of each half instead, which fits and keeps both:
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
        // OP is retired because it was answering the wrong question. It read
        // 0BF000E2 every time, and that value is at boot ROM offset 0 - it is
        // `j BFC00388`, the stub at the reset vector - so OP was showing the
        // instruction at the LANDING site, one stage later than intended.
        // h1_op is the value that pairs with the departure pc.
        //
        // RL has read 8800C61C and 8800C610 on successive builds, twelve bytes
        // apart, so the restart always leaves from the same routine. DO names
        // the instruction: a jr/j is the game rebooting itself deliberately,
        // which is what an error or watchdog path looks like.
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
        // If ET is 88032288 (KI1) or 8802F028 (KI2) then eret really did
        // resume on the delay slot and EE says which register supplied it. If
        // ET is something else, the trace's eret source tag was misleading.
        //
        // DL is retired with DF above.
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
        // RC now carries BOTH restart shapes, because they are mutually
        // exclusive explanations of the same symptom:
        //
        //   digits 0-1  executions of 0x88000000, the address the boot ROM
        //               hands control to. Boot is exactly 1; 2 or more is the
        //               game restarting ITSELF, which leaves no reset and no
        //               boot-ROM transition and was invisible before.
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
        // The disk, on the two rows the retired probes freed.
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
        //   digits 4-7   how many times the interrupt has been RAISED
        //
        // The raise count is the field that matters. A status-register read
        // clears irq_pending - correct ATA - so the live line alone cannot
        // distinguish "never asserted" from "asserted and consumed". If the
        // count is non-zero the drive did its part and the loss is downstream
        // in Cause; if it is zero the command never completed.
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
        // exception the game ever took" is measured rather than assumed.
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
    character = page
      ? trace_char(v_count[7:4], h_count[8:4], trace_bus, trace_valid)
      : screen_char(v_count[7:4], h_count[8:4], diagnostic_snapshot,
                    bist_snapshot);
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
      end else if (!page && (v_count[7:4] == 3) && (errors_snapshot != 0)) begin
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
