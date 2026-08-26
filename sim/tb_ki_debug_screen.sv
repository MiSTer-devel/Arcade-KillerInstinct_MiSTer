`timescale 1ns/1ps
`default_nettype none

module tb_ki_debug_screen;
  logic clk = 0;
  logic frame_start = 0;
  logic [9:0] h_count = 0;
  logic [9:0] v_count = 0;
  logic display_enable = 1;
  logic cpu_reset = 0;
  logic boot_loaded = 1;
  logic pll_locked = 1;
  logic image_present = 1;
  logic [5:0] cpu_errors = 6'h08;
  logic [31:0] cpu_pc = 32'hbfc0_1234;
  logic [31:0] cpu_retired = 32'hab00_4567;
  logic [31:0] cpu_irq_count = 32'h0000_0012;
  logic [31:0] cpu_gpr_s1 = 32'hbfc1_dc07;
  logic [31:0] cpu_response_status = 32'h8803_2288;
  // EF: 5 erets, ERL clear, EXL set, BEV clear, IE clear -> low nibble 4.
  logic [31:0] cpu_eret_flags = 32'h0005_0004;
  // RS: 1 verify rise, 2 cpu_reset rises, 3 late resets, sticky mask 0248 -
  // shell_reset clear, so bits 3 (~sdram_ready), 6 (~pll_locked) and 9
  // (buttons[1]) - a core resetting ITSELF, which is the reading that matters.
  logic [31:0] reset_info = 32'h1203_0248;
  // RF: the first SPONTANEOUS reset had bits 0 and 6 - shell_reset driven by
  // ~pll_locked, and no operator bit - which is the exact reading that would
  // convict the PLL. 2 unlocks counted in the reference domain, 3 spontaneous
  // resets, 1 ROM download.
  logic [31:0] reset_first = 32'h0041_0231;
  // A RAM pc and its opcode, and a return to the RESET VECTOR - the reading
  // that would mean the decompressed code faulted rather than ran.
  // not read-only, 5 sectors offered, 5 completed
  // COP0 EPC: a plausible faulting address in RAM.
  // Framebuffer census: 0x1000 reads over 0x4B00 writes.
  logic [31:0] hist1_op = 32'h1000_4b00;
  // The store side of the same word. Real KI has 0A00006E at 0x88000000 with
  // a nop behind it, written by one sd - so mask FF - landing on the
  // doubleword base, after a handful of stores.
  // The three decode words and the address of the first, all distinct so a
  // field wired to the wrong source fails here rather than rendering
  // something plausible on hardware.
  // address low byte 00, mask FF, three stores, one fill.
  // be=F, max index FF, 0 refused, address 00
  // COP0 Cause: ExcCode 5 (AdES, address error on store) with the
  // branch-delay bit set - bit 31 plus 5 << 2 = 8000_0014.
  logic [31:0] hist1_pc = 32'h8000_0014;
  // The stall capture: distinct values so a field wired to the wrong source
  // fails here rather than rendering something plausible on hardware.
  // A healthy frame: 19200 beats, 4800 requests.
  // DP: the first EPC the delay-slot suppression changed. A genuine delay-slot
  // address here convicts the predicate and names where it misfired.
  logic [31:0] cpu_prev_op = 32'h2003_8000;
  // DL: the last window saw 0x0140 line fills and 0x0138 writebacks - nearly
  // one writeback per fill, which is the thrashing signature the field exists
  // to show.
  // ET: the target eret actually used. Equal to EPC here, which is the
  // ERL-clear case.
  logic [31:0] cpu_ret_prev = 32'h8803_2288;
  // RC: 2 executions of the entry point (boot is 1, so the game restarted
  // once), 3 ATA INITIALIZE DEVICE PARAMETERS commands, 4 RAM -> boot ROM
  // transitions. All three distinct so a swapped pack renders visibly wrong
  // rather than plausibly.
  logic [31:0] cpu_ret_count = 32'h0203_0004;
  // DF: the worst window of the run, distinct from DL so a field wired to the
  // wrong source fails here rather than reading plausibly.
  // DS: how many exceptions had their EPC changed by the suppression.
  // Deliberately unlike every other stimulus so a mis-wired row is visible.
  logic [31:0] cpu_ret_pc = 32'hA400_1234;
  // 64-bit address probe. 0002_0000 is the healthy shape: captures happened,
  // none violated. Only bits 19:0 are displayed. See cpu_cop0.vhd.
  logic [31:0] cpu_b64 = 32'h0002_0000;
  // Mapped-region probe. 0000_FFFF is the healthy shape: nothing mapped, and
  // the unmapped positive control saturated. See cpu.vhd.
  logic [31:0] cpu_ks = 32'h0000_FFFF;
  // Wide multiply probe. 0004_0000 is the healthy shape: narrow multiplies
  // seen, no wide ones. See cpu.vhd.
  logic [31:0] cpu_dm = 32'h0004_0000;
  // Trap probe. 0004_0000 is the healthy shape: control set, no traps.
  logic [31:0] cpu_tp = 32'h0004_0000;
  // FPU probe. 0002_0000 is the healthy shape: control set, no FPU use.
  logic [31:0] cpu_fp = 32'h0002_0000;
  // PCM FIFO health. 0002_0000 = popped, no underruns; level = min 3FF/max 3FF.
  logic [31:0] pcm_health = 32'h0002_0000;
  logic [31:0] pcm_level  = 32'h000F_FFFF;
  logic [31:0] cpu_loop_counts = 32'h2442_0008;
  logic [31:0] cpu_rom_return_prev = 32'h8800_0abc;
  logic [31:0] cpu_t2_reload_count = 32'h0000_0012;
  logic [31:0] cpu_wait_cycles = 32'h8800_01b8;
  logic [31:0] cpu_verify_checksum = 32'h3c1d_8808;
  logic [9:0] video_max_v_count = 10'h104;
  logic video_vblank_seen = 1;
  logic cpu_vblank_seen = 1;
  logic [31:0] vblank_count = 32'h0000_0258;
  logic [2:0] ata_state = 3'h3;
  logic [7:0] ata_status = 8'h58;
  logic [7:0] ata_error = 8'h04;
  // last command EC (IDENTIFY), irq line up, irq_pending set, nIEN clear,
  // and three raises so far.
  // last command EC, irq up, pending set, nIEN clear, data_index 0x12,
  // 0x003 data-register writes.
  logic [31:0] ata_info = 32'hecc1_2003;
  logic [31:0] framebuffer_count = 32'h0000_4444;
  logic page = 0;
  logic trace_valid = 1;
  logic [895:0] trace_bus = {
    32'h0030_2011,  // [895:864] TX census: 3 read, 2 write, 1 instr, first=MISS
    32'hffff_fff9,  // [863:832] $s2 at the fault
    32'h8803_2290,  // [831:800] $s1 at the fault
    32'h0810_0000,  // [799:768] BadVAddr
    28'd0, 1'b1, 3'b010,  // [767:736] gate armed, trigger 2 = entry re-entry
    32'h0812_3456,  // [735:704] previous store address
    32'h8801_0e38,  // [703:672] pc that issued the last store
    32'h0000_00a5,  // [671:640] last store data
    32'h1000_0098,  // [639:608] last store address
    32'h8801_0e40,  // [607:576] COP0 EPC
    32'h1234_5678,  // [575:544] COP0 Cause/Status pack
    // [543:512] source tags, entry 7 (landing) in the TOP nibble
    4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    32'hbfc0_0004, 32'h0000_0000,  // entry 7, the landing
    32'h8802_0c58, 32'h3c01_8804,  // entry 6, the departure
    32'h8802_0c54, 32'h5555_5555,
    32'h8802_0c50, 32'h4444_4444,
    32'h8802_0c4c, 32'h3333_3333,
    32'h8802_0c48, 32'h2222_2222,
    32'h8802_0c44, 32'h1111_1111,
    32'h8802_0c40, 32'h9999_9999   // entry 0, the oldest
  };
  logic bist_done = 1;
  logic bist_pass = 1;
  logic [15:0] bist_error_count = 16'h0000;
  logic [24:0] bist_first_bad_address = 25'h0000000;
  logic [15:0] bist_first_bad_expected = 16'h0000;
  logic [15:0] bist_first_bad_actual = 16'h0000;
  wire [7:0] red;
  wire [7:0] green;
  wire [7:0] blue;

  always #5 clk = !clk;

  ki_debug_screen dut (.*);

  task automatic assert_cell_has_ink(input int row, input int column);
    logic found;
    begin
      found = 0;
      for (int y = 0; y < 14; y++) begin
        for (int x = 0; x < 10; x++) begin
          h_count = column * 16 + x * 2;
          v_count = row * 16 + y;
          #1;
          if ({red, green, blue} != 24'h080c14)
            found = 1;
        end
      end
      if (!found) $fatal(1, "No glyph pixels in row %0d column %0d", row, column);
    end
  endtask

  initial begin
    @(negedge clk);
    frame_start = 1;
    @(negedge clk);
    frame_start = 0;

    assert_cell_has_ink(0, 0);  // K in title
    assert_cell_has_ink(4, 3);  // first PC digit
    assert_cell_has_ink(6, 0);  // N label
    assert_cell_has_ink(6, 3);  // first retired-count digit
    assert_cell_has_ink(10, 3); // first stall-pc digit
    assert_cell_has_ink(12, 3); // first stall-status digit
    assert_cell_has_ink(11, 3); // first stall-address digit

    // Verify the packed snapshot reaches the character renderer intact.
    // Ink-only checks cannot distinguish a live counter from eight zeroes.
    if (dut.screen_char(2, 15, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(2, 17, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(2, 18, dut.diagnostic_snapshot, dut.bist_snapshot) != "5" ||
        dut.screen_char(2, 19, dut.diagnostic_snapshot, dut.bist_snapshot) != "8")
      $fatal(1, "VBlank counter snapshot was rendered incorrectly");
    if (dut.screen_char(1, 16, dut.diagnostic_snapshot, dut.bist_snapshot) != "1" ||
        dut.screen_char(1, 17, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(1, 18, dut.diagnostic_snapshot, dut.bist_snapshot) != "4")
      $fatal(1, "Maximum vertical count snapshot was rendered incorrectly");
    if (dut.screen_char(1, 23, dut.diagnostic_snapshot, dut.bist_snapshot) != "1")
      $fatal(1, "VBlank-seen snapshot was rendered incorrectly");
    if (dut.screen_char(3, 19, dut.diagnostic_snapshot, dut.bist_snapshot) != "1")
      $fatal(1, "CPU-domain vblank snapshot was rendered incorrectly");

    // The profiling rows exist to be read as NUMBERS off a photograph, so an
    // ink-only check is not enough - a field wired to the wrong source would
    // still light up and would send the next investigation the wrong way.
    // Rows 8 to 11 are the handoff word followed in causal order:
    // IL (stored) -> WB (written back) -> FD (filled) -> O0 (decoded).
    // Each is checked against a DISTINCT stimulus value, so a field wired to
    // the wrong source fails here instead of reading plausibly on hardware.
    //
    // IL on row 8, cpu_img_lo = 32'h0a00_006e.







    // TR shares row 4 with PC, cpu_t2_reload_count = 32'h0000_0012.
    if (dut.screen_char(4, 12, dut.diagnostic_snapshot, dut.bist_snapshot) != "T" ||
        dut.screen_char(4, 13, dut.diagnostic_snapshot, dut.bist_snapshot) != "R" ||
        dut.screen_char(4, 18, dut.diagnostic_snapshot, dut.bist_snapshot) != "1" ||
        dut.screen_char(4, 19, dut.diagnostic_snapshot, dut.bist_snapshot) != "2")
      $fatal(1, "TR field did not render the gate-crossing count");


    // O0, the opcode there: cpu_ram_op0 = 32'h3c1d_8808.

    // RP on row 11, the last RAM pc before the return: 32'h8800_0abc.




    // RD on row 7 and WL on row 8: the last read and write LBAs, then
    // RR/RL/RC on rows 10 to 12, each against a distinct value.
    // RT/RA/RE are the frozen response-ownership failure and its returned and
    // expected physical addresses. Distinct values make snapshot misalignment
    // or a swapped address immediately visible.
    // EE, and the L and N sub-fields sharing its row. Every digit of the EPC
    // is checked: this row exists to say whether eret's EPC really was the
    // delay slot 88032288, and one wrong digit changes that answer.
    if (dut.screen_char(7, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "E" ||
        dut.screen_char(7, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "E" ||
        dut.screen_char(7, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(7, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(7, 5, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(7, 6, dut.diagnostic_snapshot, dut.bist_snapshot) != "3" ||
        dut.screen_char(7, 7, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(7, 8, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(7, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(7, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "8")
      $fatal(1, "EE row did not render EPC at the eret");
    // L is Status.ERL: 0 here, meaning the target came from EPC not ErrorEPC.
    // N is the eret count's low two digits, 05.
    if (dut.screen_char(7, 12, dut.diagnostic_snapshot, dut.bist_snapshot) != "L" ||
        dut.screen_char(7, 14, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(7, 16, dut.diagnostic_snapshot, dut.bist_snapshot) != "N" ||
        dut.screen_char(7, 18, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(7, 19, dut.diagnostic_snapshot, dut.bist_snapshot) != "5")
      $fatal(1, "L/N did not render the ERL flag and eret count");
    if (dut.screen_char(8, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "R" ||
        dut.screen_char(8, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "S" ||
        dut.screen_char(8, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "1" ||
        dut.screen_char(8, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(8, 5, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(8, 6, dut.diagnostic_snapshot, dut.bist_snapshot) != "3" ||
        dut.screen_char(8, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "4" ||
        dut.screen_char(8, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "8")
      $fatal(1, "RS row did not render the reset census and sticky cause mask");
    if (dut.screen_char(9, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "R" ||
        dut.screen_char(9, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "F" ||
        dut.screen_char(9, 5, dut.diagnostic_snapshot, dut.bist_snapshot) != "4" ||
        dut.screen_char(9, 6, dut.diagnostic_snapshot, dut.bist_snapshot) != "1" ||
        dut.screen_char(9, 8, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(9, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "3" ||
        dut.screen_char(9, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "1")
      $fatal(1, "RF row did not render the spontaneous-reset mask and counts");
    // RC's two halves. The high half is the software self-restart count and
    // the low half the boot-ROM transition count; they answer different
    // questions and a pack that swaps them would read as a plausible number.
    if (dut.screen_char(12, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "R" ||
        dut.screen_char(12, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "C" ||
        dut.screen_char(12, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(12, 6, dut.diagnostic_snapshot, dut.bist_snapshot) != "3" ||
        dut.screen_char(12, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "4")
      $fatal(1, "RC row did not render entry, disk-init and transition counts");
    // VC on row 10: the scanout beat census, driven with a HEALTHY frame -
    // 4B00 beats over 12C0 requests - so a rendering fault cannot be mistaken
    // for dropped beats. Both halves are checked at their boundaries, because
    // the whole diagnostic is the comparison of two counts against known
    // constants.
    if (dut.screen_char(10, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "D" ||
        dut.screen_char(10, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "P" ||
        dut.screen_char(10, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "2" ||
        dut.screen_char(10, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "0" ||
        dut.screen_char(10, 6, dut.diagnostic_snapshot, dut.bist_snapshot) != "3" ||
        dut.screen_char(10, 7, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(10, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "0")
      $fatal(1, "DP row did not render the first suppressed EPC");

    // AT/SR/ER on row 13 and the packed AC on row 14.
    if (dut.screen_char(13, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "A" ||
        dut.screen_char(13, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "T" ||
        dut.screen_char(13, 5, dut.diagnostic_snapshot, dut.bist_snapshot) != "S" ||
        dut.screen_char(13, 11, dut.diagnostic_snapshot, dut.bist_snapshot) != "E")
      $fatal(1, "ATA row did not render its labels");
    if (dut.screen_char(14, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "A" ||
        dut.screen_char(14, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "C" ||
        dut.screen_char(14, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "E" ||
        dut.screen_char(14, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "C" ||
        dut.screen_char(14, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "3")
      $fatal(1, "AC row did not render the packed ATA info");

    // RR on row 5: the ROM address control landed on, driven with BFC0_0380 -
    // the general exception vector - so the field must distinguish that from
    // the reset vector BFC0_0000, which is the whole point of restoring it.
    // DF and DL, the D-cache pressure census. Both halves of both fields are
    // checked: the whole diagnostic is the comparison of writebacks against
    // fills, so a field that renders one half correctly is still useless.
    // EX carries a value deliberately unlike EE, so a row wired to the wrong
    // source renders visibly wrong instead of plausibly.
    if (dut.screen_char(5, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "D" ||
        dut.screen_char(5, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "S" ||
        dut.screen_char(5, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "A" ||
        dut.screen_char(5, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "4" ||
        dut.screen_char(5, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "3" ||
        dut.screen_char(5, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "4")
      $fatal(1, "DS row did not render the suppression count");
    if (dut.screen_char(11, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "E" ||
        dut.screen_char(11, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "T" ||
        dut.screen_char(11, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(11, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(11, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "8" ||
        dut.screen_char(11, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "8")
      $fatal(1, "ET row did not render the address eret actually used");



    if (dut.screen_char(1, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "0")
      $fatal(1, "RST did not render cpu_reset");
    if (dut.screen_char(1, 11, dut.diagnostic_snapshot, dut.bist_snapshot) != "1")
      $fatal(1, "BOOT did not render boot_loaded");
    if (dut.screen_char(2, 4, dut.diagnostic_snapshot, dut.bist_snapshot) != "1")
      $fatal(1, "PLL did not render pll_locked");
    if (dut.screen_char(2, 10, dut.diagnostic_snapshot, dut.bist_snapshot) != "1")
      $fatal(1, "HDD did not render image_present");

    for (int c = 0; c < 20; c = c + 1)
      if (dut.screen_char(15, c[4:0], dut.diagnostic_snapshot, dut.bist_snapshot) != " ")
        $fatal(1, "row 15 is below the visible area but renders '%c' at column %0d",
               dut.screen_char(15, c[4:0], dut.diagnostic_snapshot, dut.bist_snapshot), c);

    // The SDRAM verdict moved to row 6 columns 16-19 when row 5 became IC.
    // A failed self test makes every other field noise, so it must stay
    // visible no matter which branch row 6 takes.
    if (dut.screen_char(6, 16, dut.diagnostic_snapshot, dut.bist_snapshot) != "S" ||
        dut.screen_char(6, 17, dut.diagnostic_snapshot, dut.bist_snapshot) != "D" ||
        dut.screen_char(6, 18, dut.diagnostic_snapshot, dut.bist_snapshot) != ":" ||
        dut.screen_char(6, 19, dut.diagnostic_snapshot, dut.bist_snapshot) != "P")
      $fatal(1, "row 6 did not render the SDRAM verdict");


    if (dut.screen_char(6, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "N" ||
        dut.screen_char(6, 2, dut.diagnostic_snapshot, dut.bist_snapshot) != "A" ||
        dut.screen_char(6, 3, dut.diagnostic_snapshot, dut.bist_snapshot) != "B" ||
        dut.screen_char(6, 8, dut.diagnostic_snapshot, dut.bist_snapshot) != "6" ||
        dut.screen_char(6, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "7")
      $fatal(1, "N row did not render the full 32-bit retired count");

    // CV is the same checksum taken through the CPU's read path

    // ...and reverts to the BIST stall decode when it fails, because that is
    // the only time EP/AC mean anything and losing them would be worse.
    bist_pass = 0;
    @(negedge clk);
    frame_start = 1;
    @(negedge clk);
    frame_start = 0;
    #1;
    if (dut.screen_char(6, 0, dut.diagnostic_snapshot, dut.bist_snapshot) != "E" ||
        dut.screen_char(6, 1, dut.diagnostic_snapshot, dut.bist_snapshot) != "P" ||
        dut.screen_char(6, 8, dut.diagnostic_snapshot, dut.bist_snapshot) != "A" ||
        dut.screen_char(6, 9, dut.diagnostic_snapshot, dut.bist_snapshot) != "C")
      $fatal(1, "row 6 did not revert to the BIST stall decode on failure");
    bist_pass = 1;
    @(negedge clk);
    frame_start = 1;
    @(negedge clk);
    frame_start = 0;
    #1;

    h_count = 0;
    v_count = 3 * 16;
    #1;
    if (red <= green) $fatal(1, "CPU error row was not rendered red");

    display_enable = 0;
    #1;
    if ({red, green, blue} != 24'h000000)
      $fatal(1, "Blanking did not force black");
    display_enable = 1;

    // -----------------------------------------------------------------
    // PAGE 1: the frozen pre-event trace.
    //
    // The whole page exists to be read off one photograph, so every field is
    // checked against a DISTINCT stimulus value. A row wired to the wrong
    // entry, a slice off by one word, or an entry order reversed all render
    // something that looks like a plausible instruction stream, and only a
    // value check separates those from a correct page.
    // -----------------------------------------------------------------
    page = 1;
    #1;

    // Row 8 is the LANDING. This is the row the investigation turns on: the
    // address control reached, the opcode there, and the mux arm that sent it.
    if (dut.trace_char(8, 0, trace_bus, trace_valid) != "5")
      $fatal(1, "landing row did not render the jr/jalr fetch source");
    if (dut.trace_char(8, 2, trace_bus, trace_valid) != "B" ||
        dut.trace_char(8, 3, trace_bus, trace_valid) != "F" ||
        dut.trace_char(8, 4, trace_bus, trace_valid) != "C" ||
        dut.trace_char(8, 5, trace_bus, trace_valid) != "0" ||
        dut.trace_char(8, 9, trace_bus, trace_valid) != "4")
      $fatal(1, "landing row did not render the reset-vector landing address");

    if (dut.trace_char(7, 2, trace_bus, trace_valid) != "8" ||
        dut.trace_char(7, 8, trace_bus, trace_valid) != "5" ||
        dut.trace_char(7, 9, trace_bus, trace_valid) != "8")
      $fatal(1, "departure row did not render the departure address");
    if (dut.trace_char(7, 11, trace_bus, trace_valid) != "3" ||
        dut.trace_char(7, 12, trace_bus, trace_valid) != "C" ||
        dut.trace_char(7, 13, trace_bus, trace_valid) != "0" ||
        dut.trace_char(7, 14, trace_bus, trace_valid) != "1" ||
        dut.trace_char(7, 17, trace_bus, trace_valid) != "0" ||
        dut.trace_char(7, 18, trace_bus, trace_valid) != "4")
      $fatal(1, "departure row did not render the decoded departure opcode");
    if (dut.trace_char(7, 0, trace_bus, trace_valid) != "0")
      $fatal(1, "departure row did not render a sequential fetch source");

    // Oldest first. If the entry order were reversed this would render the
    // landing, which is exactly the misreading the fixed order exists to stop.
    if (dut.trace_char(1, 2, trace_bus, trace_valid) != "8" ||
        dut.trace_char(1, 9, trace_bus, trace_valid) != "0" ||
        dut.trace_char(1, 11, trace_bus, trace_valid) != "9" ||
        dut.trace_char(1, 18, trace_bus, trace_valid) != "9")
      $fatal(1, "row 1 is not the oldest trace entry");
    if (dut.trace_char(2, 9, trace_bus, trace_valid) != "4" ||
        dut.trace_char(6, 9, trace_bus, trace_valid) != "4")
      $fatal(1, "trace entries are not in program order");

    // COP0 and store provenance.
    if (dut.trace_char(9, 0, trace_bus, trace_valid) != "C" ||
        dut.trace_char(9, 1, trace_bus, trace_valid) != "S" ||
        dut.trace_char(9, 3, trace_bus, trace_valid) != "1" ||
        dut.trace_char(9, 10, trace_bus, trace_valid) != "8")
      $fatal(1, "CS row did not render the COP0 pack");
    if (dut.trace_char(9, 12, trace_bus, trace_valid) != "F" ||
        dut.trace_char(9, 13, trace_bus, trace_valid) != "R" ||
        dut.trace_char(9, 15, trace_bus, trace_valid) != "1")
      $fatal(1, "FR did not render the capture-valid flag");
    if (dut.trace_char(10, 0, trace_bus, trace_valid) != "E" ||
        dut.trace_char(10, 3, trace_bus, trace_valid) != "8" ||
        dut.trace_char(10, 9, trace_bus, trace_valid) != "4" ||
        dut.trace_char(10, 10, trace_bus, trace_valid) != "0")
      $fatal(1, "EP row did not render COP0 EPC");
    if (dut.trace_char(11, 0, trace_bus, trace_valid) != "B" ||
        dut.trace_char(11, 1, trace_bus, trace_valid) != "V" ||
        dut.trace_char(11, 3, trace_bus, trace_valid) != "0" ||
        dut.trace_char(11, 4, trace_bus, trace_valid) != "8" ||
        dut.trace_char(11, 5, trace_bus, trace_valid) != "1" ||
        dut.trace_char(11, 6, trace_bus, trace_valid) != "0" ||
        dut.trace_char(11, 10, trace_bus, trace_valid) != "0")
      $fatal(1, "BV row did not render BadVAddr");
    if (dut.trace_char(12, 0, trace_bus, trace_valid) != "S" ||
        dut.trace_char(12, 1, trace_bus, trace_valid) != "1" ||
        dut.trace_char(12, 3, trace_bus, trace_valid) != "8" ||
        dut.trace_char(12, 10, trace_bus, trace_valid) != "0")
      $fatal(1, "S1 row did not render the stream pointer");
    // 0xFFFFFFF9 is -7: a plausible bit counter. The failing case this row
    // exists to catch is a LARGE POSITIVE value here.
    if (dut.trace_char(13, 0, trace_bus, trace_valid) != "S" ||
        dut.trace_char(13, 1, trace_bus, trace_valid) != "2" ||
        dut.trace_char(13, 3, trace_bus, trace_valid) != "F" ||
        dut.trace_char(13, 10, trace_bus, trace_valid) != "9")
      $fatal(1, "S2 row did not render the bit counter");
    if (dut.trace_char(14, 0, trace_bus, trace_valid) != "T" ||
        dut.trace_char(14, 1, trace_bus, trace_valid) != "X" ||
        dut.trace_char(14, 3, trace_bus, trace_valid) != "0" ||
        dut.trace_char(14, 5, trace_bus, trace_valid) != "3" ||
        dut.trace_char(14, 10, trace_bus, trace_valid) != "1")
      $fatal(1, "TX row did not render the translation-exception census");

    // FR:0 must be reachable. A trace that never froze is a real result - it
    // would mean the restart happened without a RAM -> boot ROM transition -
    // and the page has to be able to say so.
    trace_valid = 0;
    #1;
    if (dut.trace_char(9, 15, trace_bus, trace_valid) != "0")
      $fatal(1, "FR did not render an unfrozen capture");
    trace_valid = 1;

    if (dut.trace_char(9, 17, trace_bus, trace_valid) != "T" ||
        dut.trace_char(9, 19, trace_bus, trace_valid) != "2")
      $fatal(1, "T did not render the trigger that froze the capture");
    if (dut.trace_char(10, 13, trace_bus, trace_valid) != "G" ||
        dut.trace_char(10, 15, trace_bus, trace_valid) != "1")
      $fatal(1, "G did not render the end-of-boot gate");

    begin
      logic [895:0] fault_bus;
      fault_bus = trace_bus;
      fault_bus[739:736] = {1'b1, 3'b100};
      if (dut.trace_char(9, 19, fault_bus, trace_valid) != "4")
        $fatal(1, "T did not render the TLB-fault trigger");
      if (dut.trace_char(10, 15, fault_bus, trace_valid) != "1")
        $fatal(1, "G moved but did not follow the widened trigger field");
    end

    // Same visible-area rule as the status page. Row 15 is below 240 lines.
    for (int c = 0; c < 20; c = c + 1)
      if (dut.trace_char(15, c[4:0], trace_bus, trace_valid) != " ")
        $fatal(1, "trace page row 15 is below the visible area but renders '%c'",
               dut.trace_char(15, c[4:0], trace_bus, trace_valid));

    // The page really is selected by `page`, not merely renderable. Row 12
    // column 1 is "D" on the trace page and blank on the status page, so this
    // fails if the mux is stuck either way.
    assert_cell_has_ink(0, 0);   // title still present on page 1
    assert_cell_has_ink(8, 2);   // landing address renders as pixels
    if (dut.screen_char(12, 1, dut.diagnostic_snapshot, dut.bist_snapshot) ==
        dut.trace_char(12, 1, trace_bus, trace_valid))
      $fatal(1, "the two pages render the same character where they must differ");
    page = 0;
    #1;

    $display("tb_ki_debug_screen: PASS");
    $finish;
  end
endmodule

`default_nettype wire
