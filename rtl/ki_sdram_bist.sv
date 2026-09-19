// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// Built-in self test for the physical SDRAM path.
//
// Why this exists: the behavioral SDRAM model in simulation drives DQ so that
// read data is valid going *into* the capture edge, i.e. it models zero access
// time. Real silicon presents data tAC after the device's own clock edge, which
// is what the SDRAM_CLK phase shift compensates for. A read-window error is
// therefore invisible to every existing testbench and only appears on hardware.
// This block answers "does the SDRAM path actually store and return data on
// this board, at this clock and phase" without needing the CPU to boot.
//
// It runs once after SDRAM startup, over a region no other block uses, so a
// re-run after a menu reset cannot corrupt live data. The bridge owns the
// SDRAM port again as soon as `done` rises.
//
// Each pass reads the region back TWICE: once word by word, then again as
// BURST_WORDS-word bursts. Those are different timing cases and only the
// second one exercises what the core actually relies on. A single-word read
// has an idle DQ bus either side of it; a burst captures one word per clock
// out of a bus the device drives continuously, with no turnaround between
// words. A phase that is marginal will fail the burst read first, and without
// the burst pass that shows up as a PASS here and a corrupt screen - which is
// the ambiguous failure this core has repeatedly got stuck in.
//
// `error_count` therefore reports the two separately:
//
//   error_count = {burst_errors[7:0], single_errors[7:0]}
//
// so EC:0000 is clean, EC:00xx is single-word only, EC:xx00 is burst only, and
// EC:FFFF remains the watchdog timeout (each byte saturates at 0xFE so a data
// mismatch can never produce it).
// TWO REGIONS, and the second one is the point.
//
// KI's own CPU Board Test reports an SRAM error on hardware. On the real board
// the 512 KiB at physical 0x00000000 is the SRAM and the 8 MB at 0x08000000 is
// the DRAM, so that names LOW RAM - which the bridge maps to STORE_LOW, i.e.
// SDRAM byte 0. This self test has never touched it: BASE_WORD sits at word
// 0x500000 (byte 0xA00000), deliberately clear of everything the core uses. So
// `SDRAM:PASS EC:0000` has never said anything about the memory the game's own
// diagnostic is failing on.
//
// The low sweep covers WORDS words from byte 0, which is the bottom 8 KiB of
// the 512 KiB region. That is a first answer to "does low RAM work at all",
// not full coverage of it - a fault that only appears at particular high
// address bits would not be caught, and widening the sweep is the next step if
// this one comes back clean.
//
// It stays below byte 0x30000 on purpose: the framebuffer pages live at
// 0x30000 and 0x58000, so the test cannot leave its pattern anywhere the
// screen will show it before the boot ROM clears the buffer.
//
// A failure identifies its own region without a new report field, because
// `first_bad_address` carries the full 25-bit word address: below 0x40000 is
// low RAM, around 0x500000 is the original region.
module ki_sdram_bist #(
  parameter logic [24:0] BASE_WORD = 25'h0800000,
  // Low RAM as the bridge stores it: STORE_LOW is 0, so the CPU physical
  // address and the storage address are the same here.
  parameter logic [24:0] LOW_BASE_WORD = 25'h0000000,
  // Framebuffer page 0, byte 0x30000 = word 0x18000. This is inside low RAM
  // too, but it is the part the scanout reader is walking CONTINUOUSLY while
  // this test runs, and byte 0 is not. Sweeping both makes the result
  // discriminating rather than merely present: low clean + framebuffer dirty
  // isolates the fault to contention with scanout, which is the one thing the
  // video-only reset and the SRAM error have in common.
  parameter logic [24:0] FB_BASE_WORD = 25'h0018000,
  parameter integer WORDS = 4096,
  // Must divide WORDS, and must not exceed the controller's 16-word maximum.
  // BASE_WORD is 512-word aligned and the burst base is a multiple of this, so
  // no burst crosses the 512-word row ki_sdram_burst opens.
  parameter integer BURST_WORDS = 16,
  // Boot ROM size in 16-bit words. Only a testbench should shrink this.
  parameter integer ROM_WORDS = 262144
) (
  input  wire         clk,
  input  wire         reset,
  input  wire         sdram_ready,
  // Held low until the ROM download has drained. The checksum pass must not
  // run before there is a ROM to check.
  input  wire         boot_loaded,

  output logic [24:0] request_address,
  // The self test is single-word, so it uses only the low word of the
  // controller's 4-word write payload and the enable pair that goes with it.
  output logic [63:0] request_write_data,
  output logic  [7:0] request_byte_enable,
  output logic  [4:0] request_burst,
  output logic        request_read,
  output logic        request_write,
  input  wire  [15:0] request_read_data,
  input  wire         request_data_valid,
  input  wire         request_done,

  // Running 32-bit sum of every 16-bit word of the boot ROM as it is stored
  // in SDRAM. Compare against the value computed from ki-l15d.u98 offline:
  // 0x47571D1B. A mismatch means the CPU is being fed wrong bytes, which is
  // the one explanation that fits "executes continuously, no CPU errors, never
  // completes" - a decompressor scanning for a terminator it never finds.
  output logic [31:0] rom_checksum = 32'd0,
  output logic        busy,
  output logic        done = 1'b0,
  output logic        pass = 1'b0,
  output wire  [15:0] error_count,
  output logic [24:0] first_bad_address = 25'd0,
  output logic [15:0] first_bad_expected = 16'd0,
  output logic [15:0] first_bad_actual = 16'd0
);
  localparam integer INDEX_BITS = $clog2(WORDS);

  // Comparisons below use `!=`, not `!==`, because `!==` is not synthesisable.
  // On hardware that is the right operator: the DQ pins always carry real
  // levels, so a bad capture returns wrong data and compares unequal. In
  // SIMULATION, though, capturing an undriven tri-state bus yields 16'hzzzz,
  // and `!=` against an X/Z operand evaluates to X, which `if` treats as
  // false - so a simulated capture of a floating bus is silently NOT counted.
  // tb_ki_sdram_bist checks separately that no returned beat contains X/Z,
  // which is what covers that case. Do not "fix" this by switching to `!==`.

  // Address-correlated pattern with an inverted second pass, so a stuck data
  // bit, a swapped address bit and a wired-together lane all produce
  // mismatches rather than aliasing to a value that happens to read back.
  function automatic logic [15:0] pattern(
    input logic [INDEX_BITS-1:0] index,
    input logic                  invert
  );
    logic [15:0] base;
    base = {{(16 - INDEX_BITS){1'b0}}, index} ^ 16'hA5A5;
    return invert ? ~base : base;
  endfunction

  typedef enum logic [3:0] {
    BIST_WAIT_READY,
    BIST_WRITE,
    BIST_WRITE_ACK,
    BIST_READ,
    BIST_READ_ACK,
    BIST_BURST_READ,
    BIST_BURST_ACK,
    BIST_NEXT_PASS,
    BIST_WAIT_BOOT,
    BIST_SUM_READ,
    BIST_SUM_ACK,
    BIST_DONE,
    BIST_DQM_ISSUE,
    BIST_DQM_ACK
  } state_t;

  // DQM: does a write with some bytes disabled leave those bytes alone? The
  // pattern passes write every word with both enables set, so they cannot
  // tell. The data cache's write-back used to rely on it - a line whose
  // store-miss fill was skipped went back with its unread qwords masked - and
  // on hardware that corrupted game data while every simulation passed,
  // because every SDRAM model honours DQM. Hardware then failed this test:
  // SD:F, EP 2222, AC AAAA.
  //
  // Four sub-tests, each harder than the last, so the FIRST failure says how
  // far masking works on this board. Each has its own fill and write pattern,
  // so the expected/actual pair on the page names the sub-test by itself:
  //
  //   0  one word, whole word masked        fill 1111, write AAAA -> 1111
  //   1  one word, high byte masked         fill 2222, write BBBB -> 22BB
  //   2  four words, same byte masked       fill 3333, write CCCC -> 33CC
  //   3  four words, mask changing per word fill 1111 2222 3333 4444,
  //                                         write AAAA -> AAAA 2222 33AA AA44
  //
  // Sub-test 3 is what the skipped fill's write-back did. Sub-tests 0-2 are
  // what an uncached 8- or 16-bit store to SDRAM still does today. Each has
  // its own four words at the end of the base region's last row, clear of the
  // pattern sweep.
  //
  // A failure clears `pass` without touching error_count, so the page shows
  // SD:F with EC:00 - which no pattern failure can - and the first wrong
  // word's expected and actual values.
  localparam logic [24:0] DQM_BASE_WORD = BASE_WORD + 25'h1C0;
  localparam logic [63:0] DQM_FILL      = {16'h4444, 16'h3333, 16'h2222, 16'h1111};
  localparam logic [63:0] DQM_WRITE     = {16'hAAAA, 16'hAAAA, 16'hAAAA, 16'hAAAA};
  localparam logic  [7:0] DQM_ENABLES   = 8'b10_01_00_11;
  localparam logic [63:0] DQM_EXPECT    = {16'hAA44, 16'h33AA, 16'h2222, 16'hAAAA};
  logic [1:0] dqm_case = 2'd0;
  logic [1:0] dqm_step = 2'd0;
  logic       dqm_bad  = 1'b0;

  // The active sub-test. A case statement rather than parameter arrays: this
  // has to elaborate under Quartus 17.0.2 as well as the simulator.
  // always_comb, not always @*: dqm_case starts at 0 and stays there until
  // the first sub-test finishes, and an @* block that never sees an event
  // never runs, which left every constant below X and hung the first write.
  logic [24:0] dqm_addr;
  logic  [4:0] dqm_words;
  logic [63:0] dqm_fill;
  logic [63:0] dqm_write;
  logic  [7:0] dqm_enables;
  logic [63:0] dqm_expect;
  always_comb begin
    case (dqm_case)
      2'd0: begin
        dqm_addr    = DQM_BASE_WORD;
        dqm_words   = 5'd1;
        dqm_fill    = {48'd0, 16'h1111};
        dqm_write   = {48'd0, 16'hAAAA};
        dqm_enables = 8'b0000_0000;
        dqm_expect  = {48'd0, 16'h1111};
      end
      2'd1: begin
        dqm_addr    = DQM_BASE_WORD + 25'd8;
        dqm_words   = 5'd1;
        dqm_fill    = {48'd0, 16'h2222};
        dqm_write   = {48'd0, 16'hBBBB};
        dqm_enables = 8'b0000_0001;
        dqm_expect  = {48'd0, 16'h22BB};
      end
      2'd2: begin
        dqm_addr    = DQM_BASE_WORD + 25'd16;
        dqm_words   = 5'd4;
        dqm_fill    = {16'h3333, 16'h3333, 16'h3333, 16'h3333};
        dqm_write   = {16'hCCCC, 16'hCCCC, 16'hCCCC, 16'hCCCC};
        dqm_enables = 8'b01_01_01_01;
        dqm_expect  = {16'h33CC, 16'h33CC, 16'h33CC, 16'h33CC};
      end
      default: begin
        dqm_addr    = DQM_BASE_WORD + 25'd24;
        dqm_words   = 5'd4;
        dqm_fill    = DQM_FILL;
        dqm_write   = DQM_WRITE;
        dqm_enables = DQM_ENABLES;
        dqm_expect  = DQM_EXPECT;
      end
    endcase
  end

  state_t state = BIST_WAIT_READY;
  logic [INDEX_BITS-1:0] index = '0;
  logic invert_pass = 1'b0;

  logic [1:0] region = 2'd0;
  wire [24:0] active_base = (region == 2'd0) ? LOW_BASE_WORD :
                            (region == 2'd1) ? FB_BASE_WORD  :
                                               BASE_WORD;

  // Beat position inside the burst currently in flight.
  logic [4:0] beat = '0;

  // Counted separately so the debug page can say WHICH read shape failed.
  // Each saturates below 0xFF so their concatenation can never collide with
  // the 0xFFFF watchdog marker.
  logic [7:0] single_errors = 8'd0;
  logic [7:0] burst_errors = 8'd0;

  // Boot ROM as the bridge stores it: 512 KiB at STORE_BOOT (byte 0x900000),
  // i.e. 0x40000 words from word address 0x480000.
  localparam logic [24:0] ROM_BASE_WORD = 25'h0480000;
  logic [18:0] sum_index = 19'd0;
  logic [31:0] rom_sum = 32'd0;

  // Watchdog. This block gates CPU reset, so it must not be able to wedge the
  // core if a transaction never completes. On timeout it abandons the test and
  // reports a distinguishable result rather than hanging.
  localparam integer TIMEOUT_CYCLES = 100_000;
  logic [16:0] watchdog = '0;
  logic timed_out = 1'b0;
  logic [15:0] completed = 16'd0;

  assign busy = (state != BIST_WAIT_READY) && (state != BIST_DONE);

  assign error_count = timed_out ? 16'hFFFF : {burst_errors, single_errors};

  always_ff @(posedge clk) begin
    request_read <= 1'b0;
    request_write <= 1'b0;

    if (reset) begin
      // Deliberately do NOT clear `done`/`pass`/`error_count`. A menu reset
      // must not erase the result the operator is reading off the debug page,
      // and the test must not re-run and re-report on every reset.
      if (!done) begin
        state <= BIST_WAIT_READY;
        index <= '0;
        invert_pass <= 1'b0;
      end
    end else if (timed_out) begin
      // Latched failure: report and stay out of the way permanently.
      state <= BIST_DONE;
    end else begin
      // Any completed transaction refreshes the watchdog.
      if (request_done)
        watchdog <= '0;
      else if (busy)
        watchdog <= watchdog + 1'b1;

      if (request_done)
        completed <= completed + 1'b1;

      if (busy && (state != BIST_WAIT_BOOT) &&
          (watchdog >= TIMEOUT_CYCLES[16:0])) begin
        timed_out <= 1'b1;
        pass <= 1'b0;
        // `error_count` reads back 0xFFFF while timed_out is set, which is
        // distinguishable from any data mismatch.
        // Report WHERE it stalled. EC:FFFF alone says only "a transaction did
        // not complete", which is not enough to tell a stalled first request
        // from a stall after thousands, or a read stall from a write stall.
        //   EP = {state[3:0], invert_pass, index[10:0]}   (exactly 16 bits)
        //   AC = transactions completed before the stall
        // The state field grew to 4 bits when the burst pass was added, so the
        // index field lost one; INDEX_BITS must stay <= 11.
        first_bad_expected <= {state, invert_pass,
                               {(11 - INDEX_BITS){1'b0}}, index};
        first_bad_actual <= completed;
        first_bad_address <= active_base + index;
        done <= 1'b1;
        state <= BIST_DONE;
      end

      case (state)
        BIST_WAIT_READY: begin
          if (sdram_ready) begin
            index <= '0;
            beat <= '0;
            invert_pass <= 1'b0;
            region <= 2'd0;
            single_errors <= 8'd0;
            burst_errors <= 8'd0;
            watchdog <= '0;
            state <= BIST_WRITE;
          end
        end

        BIST_WRITE: begin
          request_address <= active_base + index;
          request_write_data <= {48'd0, pattern(index, invert_pass)};
          request_byte_enable <= 8'b0000_0011;
          request_burst <= 5'd1;
          request_write <= 1'b1;
          state <= BIST_WRITE_ACK;
        end

        BIST_WRITE_ACK: begin
          if (request_done) begin
            if (index == INDEX_BITS'(WORDS - 1)) begin
              index <= '0;
              state <= BIST_READ;
            end else begin
              index <= index + 1'b1;
              state <= BIST_WRITE;
            end
          end
        end

        BIST_READ: begin
          request_address <= active_base + index;
          request_burst <= 5'd1;
          request_read <= 1'b1;
          state <= BIST_READ_ACK;
        end

        BIST_READ_ACK: begin
          if (request_done) begin
            if (request_read_data != pattern(index, invert_pass)) begin
              if (error_count == 16'd0) begin
                first_bad_address <= active_base + index;
                first_bad_expected <= pattern(index, invert_pass);
                first_bad_actual <= request_read_data;
              end
              if (single_errors != 8'hfe)
                single_errors <= single_errors + 1'b1;
            end
            if (index == INDEX_BITS'(WORDS - 1)) begin
              index <= '0;
              beat <= '0;
              state <= BIST_BURST_READ;
            end else begin
              index <= index + 1'b1;
              state <= BIST_READ;
            end
          end
        end

        // Same data, read back as bursts. This is the pass that actually
        // covers what the bridge does on every cache fill and every scanout
        // fetch, and the one a marginal capture phase fails first.
        BIST_BURST_READ: begin
          request_address <= active_base + index;
          request_burst <= BURST_WORDS[4:0];
          request_read <= 1'b1;
          beat <= '0;
          state <= BIST_BURST_ACK;
        end

        BIST_BURST_ACK: begin
          // Beats stream back one per clock ahead of request_done, so they are
          // checked as they arrive rather than at completion.
          if (request_data_valid) begin
            beat <= beat + 1'b1;
            if (request_read_data !=
                pattern(index + INDEX_BITS'(beat), invert_pass)) begin
              if (error_count == 16'd0) begin
                first_bad_address <= active_base + index + beat;
                first_bad_expected <=
                    pattern(index + INDEX_BITS'(beat), invert_pass);
                first_bad_actual <= request_read_data;
              end
              if (burst_errors != 8'hfe)
                burst_errors <= burst_errors + 1'b1;
            end
          end

          if (request_done) begin
            // A burst that returned the wrong NUMBER of beats is as much a
            // failure as one that returned wrong data, and would otherwise
            // pass silently.
            if ((beat + (request_data_valid ? 5'd1 : 5'd0)) !=
                BURST_WORDS[4:0]) begin
              if (burst_errors != 8'hfe)
                burst_errors <= burst_errors + 1'b1;
            end
            if (index >= INDEX_BITS'(WORDS - BURST_WORDS)) begin
              index <= '0;
              state <= BIST_NEXT_PASS;
            end else begin
              index <= index + INDEX_BITS'(BURST_WORDS);
              state <= BIST_BURST_READ;
            end
          end
        end

        // Both passes of a region, then the next region, then the checksum.
        // The error counters are NOT cleared between regions - they are
        // cumulative and `pass` is the AND of everything - so a clean low-RAM
        // sweep cannot mask a dirty one or vice versa. `first_bad_address`
        // names whichever failed first.
        BIST_NEXT_PASS: begin
          if (invert_pass) begin
            if (region != 2'd2) begin
              region <= region + 1'b1;
              invert_pass <= 1'b0;
              index <= '0;
              beat <= '0;
              watchdog <= '0;
              state <= BIST_WRITE;
            end else begin
              dqm_case <= 2'd0;
              dqm_step <= 2'd0;
              dqm_bad <= 1'b0;
              watchdog <= '0;
              state <= BIST_DQM_ISSUE;
            end
          end else begin
            invert_pass <= 1'b1;
            state <= BIST_WRITE;
          end
        end

        // Fill, masked write, read back, once per sub-test; see DQM_BASE_WORD.
        BIST_DQM_ISSUE: begin
          request_address <= dqm_addr;
          request_burst <= dqm_words;
          beat <= '0;
          case (dqm_step)
            2'd0: begin
              request_write_data <= dqm_fill;
              request_byte_enable <= 8'hFF;
              request_write <= 1'b1;
            end
            2'd1: begin
              request_write_data <= dqm_write;
              request_byte_enable <= dqm_enables;
              request_write <= 1'b1;
            end
            default: request_read <= 1'b1;
          endcase
          state <= BIST_DQM_ACK;
        end

        BIST_DQM_ACK: begin
          if (dqm_step == 2'd2 && request_data_valid) begin
            beat <= beat + 1'b1;
            if (request_read_data != dqm_expect[{beat[1:0], 4'd0} +: 16]) begin
              // The first sub-test to fail is the one that says how far
              // masking works, so only the first mismatch is kept.
              if (!dqm_bad && error_count == 16'd0) begin
                first_bad_address <= dqm_addr + beat;
                first_bad_expected <= dqm_expect[{beat[1:0], 4'd0} +: 16];
                first_bad_actual <= request_read_data;
              end
              dqm_bad <= 1'b1;
            end
          end
          if (request_done) begin
            if (dqm_step != 2'd2) begin
              dqm_step <= dqm_step + 2'd1;
              state <= BIST_DQM_ISSUE;
            end else if ((beat + (request_data_valid ? 5'd1 : 5'd0)) != dqm_words) begin
              // The read did not return the words it asked for, which no
              // count of mismatches would show.
              pass <= 1'b0;
              state <= BIST_WAIT_BOOT;
            end else if (dqm_case != 2'd3) begin
              dqm_case <= dqm_case + 2'd1;
              dqm_step <= 2'd0;
              state <= BIST_DQM_ISSUE;
            end else begin
              pass <= (error_count == 16'd0) && !dqm_bad;
              state <= BIST_WAIT_BOOT;
            end
          end
        end

        // The pattern test is finished; now verify what the CPU will
        // actually be fed. Holding `busy` here keeps the CPU in reset for the
        // ~11 ms this takes, which is harmless and deliberate.
        BIST_WAIT_BOOT: begin
          if (boot_loaded) begin
            sum_index <= 19'd0;
            rom_sum <= 32'd0;
            watchdog <= '0;
            state <= BIST_SUM_READ;
          end
        end

        BIST_SUM_READ: begin
          request_address <= ROM_BASE_WORD + {6'd0, sum_index};
          request_burst <= BURST_WORDS[4:0];
          request_read <= 1'b1;
          state <= BIST_SUM_ACK;
        end

        BIST_SUM_ACK: begin
          if (request_data_valid)
            rom_sum <= rom_sum + {16'd0, request_read_data};
          if (request_done) begin
            if (sum_index >= (ROM_WORDS - BURST_WORDS)) begin
              rom_checksum <= rom_sum;
              done <= 1'b1;
              state <= BIST_DONE;
            end else begin
              sum_index <= sum_index + BURST_WORDS[18:0];
              state <= BIST_SUM_READ;
            end
          end
        end

        BIST_DONE: begin
          state <= BIST_DONE;
        end
      endcase
    end
  end
endmodule

`default_nettype wire
