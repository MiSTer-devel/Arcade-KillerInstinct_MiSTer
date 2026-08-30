// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_memory_bridge;
  logic clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic reset = 1'b1;

  logic cpu_request = 1'b0;
  logic cpu_rnw = 1'b1;
  logic [31:0] cpu_address = 32'd0;
  logic fb_read_accept;
  logic fb_write_accept;
  logic cpu_req64 = 1'b0;
  logic [2:0] cpu_size = 3'd1;
  logic [7:0] cpu_write_mask = 8'd0;
  logic [63:0] cpu_data_write = 64'd0;
  logic [63:0] cpu_data_read;
  logic cpu_done;
  logic cpu_grant;
  logic [63:0] cpu_cache_data;
  logic cpu_cache_data_ready;

  logic io_request;
  logic io_write;
  logic [31:0] io_address;
  logic [31:0] io_write_data;
  logic [3:0] io_byte_enable;
  logic [31:0] io_read_data = 32'h1234_5678;
  logic io_done;

  logic ioctl_download = 1'b0;
  logic ioctl_wr = 1'b0;
  logic [15:0] ioctl_index = 16'd0;
  logic [26:0] ioctl_addr = 27'd0;
  logic [15:0] ioctl_dout = 16'd0;
  logic ioctl_wait;
  logic boot_loaded;

  logic video_request = 1'b0;
  logic [27:0] video_address = 28'd0;
  logic [2:0] video_words = 3'd1;
  logic [63:0] video_data;
  logic video_data_valid;
  logic video_done;

  // The DCS sound ROM port. This bench connects with `.*`, so these must exist
  // by name even though it does not exercise them: the request is tied low and
  // the port stays idle. tb_ki_dcs_audio covers the port itself.
  logic dcs_rom_request = 1'b0;
  logic [18:0] dcs_rom_address = 19'd0;
  logic dcs_rom_ready;
  logic [63:0] dcs_rom_data;

  logic [24:0] sdram_address;
  logic [63:0] sdram_write_data;
  logic [7:0] sdram_byte_enable;
  logic [4:0] sdram_burst;
  logic sdram_read;
  logic sdram_write;
  logic [15:0] sdram_read_data = 16'd0;
  logic sdram_data_valid = 1'b0;
  logic sdram_done = 1'b0;
  logic sdram_ready = 1'b0;

  logic ddram_busy = 1'b0;
  logic [7:0] ddram_burstcnt;
  logic [28:0] ddram_addr;
  logic [63:0] ddram_dout = 64'd0;
  logic ddram_dout_ready = 1'b0;
  logic ddram_rd;
  logic [63:0] ddram_din;
  logic [7:0] ddram_be;
  logic ddram_we;

  logic [2:0] debug_state;
  logic debug_cpu_pending;
  logic [31:0] debug_last_write_address;
  logic [63:0] debug_last_write_data;
  logic [31:0] debug_last_write_info;
  logic [31:0] debug_write_count;
  logic [31:0] debug_low_write_count;
  logic [31:0] debug_main_write_count;
  logic [31:0] debug_main_write0;
  logic [31:0] debug_main_write1;
  logic [31:0] debug_main_write2;
  // Boot-table write snoop.
  logic [31:0] debug_table_write_count;
  logic [31:0] debug_table_write_address;
  logic [31:0] debug_table_write_data;

  logic [15:0] sdram_memory [logic [24:0]];
  logic [63:0] ddram_memory [logic [28:0]];
  logic memory_pending = 1'b0;
  logic memory_pending_write = 1'b0;
  logic [24:0] memory_pending_address = 25'd0;
  logic [63:0] memory_pending_data = 64'd0;
  logic [7:0] memory_pending_enable = 8'd0;
  logic [4:0] memory_pending_burst = 5'd1;
  integer written;
  logic memory_read_active = 1'b0;
  logic memory_done_pending = 1'b0;
  logic [24:0] memory_beat_address = 25'd0;
  logic [4:0] memory_beats_left = 5'd0;
  integer sdram_write_request_count = 0;
  integer sdram_read_request_count = 0;
  integer fb_read_accept_count = 0;
  integer fb_write_accept_count = 0;
  integer fb_collision_retry_count = 0;
  integer sdram_longest_burst = 0;
  integer line_requests_before = 0;
  integer store_requests_before = 0;
  integer low_writes_before = 0;
  integer video_requests_before = 0;
  integer cache_ready_seen = 0;
  integer cache_ready_before = 0;
  logic [63:0] cache_ready_data = 64'd0;
  logic [63:0] cache_beats [0:7];
  integer cache_beat_count = 0;

  logic ddram_read_pending = 1'b0;
  logic [28:0] ddram_read_address = 29'd0;
  logic [7:0] ddram_read_remaining = 8'd0;
  integer ddram_write_count = 0;
  integer sdram_write_count = 0;
  integer sdram_read_count = 0;
  integer io_request_cycle_count = 0;
  logic [28:0] last_dcs_address = 29'd0;
  logic [63:0] last_dcs_data = 64'd0;
  logic [7:0] last_dcs_be = 8'd0;

  always #5 clk = !clk;
  always #2.5 ddr_clk = !ddr_clk;
  assign io_done = io_request;

  // Fill-beat capture ports, unused here but required by the .* connection.
  wire [63:0] debug_fill_b0;
  wire [63:0] debug_fill_b1;

  ki_memory_bridge dut (.*);

  always @(posedge clk) begin
    if (io_request)
      io_request_cycle_count <= io_request_cycle_count + 1;
    if (fb_read_accept)
      fb_read_accept_count <= fb_read_accept_count + 1;
    if (fb_write_accept)
      fb_write_accept_count <= fb_write_accept_count + 1;
    if (dut.fb_we && (dut.fb_addr == dut.fb_vaddr) &&
        (dut.vid_state == 2'd1))
      fb_collision_retry_count <= fb_collision_retry_count + 1;
    if (cpu_cache_data_ready) begin
      cache_ready_seen <= cache_ready_seen + 1;
      cache_ready_data <= cpu_cache_data;
      // Every beat in order, so a line fill can be checked word by word
      // rather than only by its last word.
      if (cache_beat_count < 8) begin
        cache_beats[cache_beat_count] <= cpu_cache_data;
        cache_beat_count <= cache_beat_count + 1;
      end
    end
  end

  // Behavioral model of the bridge-facing SDRAM port, matching what
  // ki_sdram_adapter + ki_sdram_burst deliver: a read request returns `burst`
  // words as consecutive sdram_data_valid beats in address order, and
  // sdram_done follows strictly after the last beat. A write burst stores up
  // to four words with one byte-enable pair each and completes at done.
  always @(posedge clk) begin
    sdram_done <= 1'b0;
    sdram_data_valid <= 1'b0;

    if (memory_pending) begin
      memory_pending <= 1'b0;
      if (memory_pending_write) begin
        // A write burst stores `burst` consecutive words, each with its own
        // byte-enable pair. A word with no enabled bytes still occupies its
        // slot - the controller masks it with DQM - so it must not shift the
        // ones after it.
        written = 0;
        for (int w = 0; w < 4; w++) begin
          if (w < memory_pending_burst) begin
            if (memory_pending_enable[w * 2])
              sdram_memory[memory_pending_address + w][7:0] =
                  memory_pending_data[(w * 16) +: 8];
            if (memory_pending_enable[(w * 2) + 1])
              sdram_memory[memory_pending_address + w][15:8] =
                  memory_pending_data[(w * 16) + 8 +: 8];
            written = written + 1;
          end
        end
        sdram_write_count <= sdram_write_count + written;
        sdram_done <= 1'b1;
      end else begin
        memory_read_active <= 1'b1;
        memory_beat_address <= memory_pending_address;
        memory_beats_left <= memory_pending_burst;
      end
    end else if (memory_read_active) begin
      sdram_read_count <= sdram_read_count + 1;
      sdram_read_data <= sdram_memory.exists(memory_beat_address) ?
          sdram_memory[memory_beat_address] : 16'd0;
      sdram_data_valid <= 1'b1;
      memory_beat_address <= memory_beat_address + 1'b1;
      if (memory_beats_left <= 1) begin
        memory_read_active <= 1'b0;
        memory_done_pending <= 1'b1;
      end else begin
        memory_beats_left <= memory_beats_left - 1'b1;
      end
    end else if (memory_done_pending) begin
      memory_done_pending <= 1'b0;
      sdram_done <= 1'b1;
    end

    if (sdram_read || sdram_write) begin
      assert (!memory_pending && !memory_read_active && !memory_done_pending)
        else $fatal(1, "overlapping SDRAM bridge requests");
      memory_pending <= 1'b1;
      memory_pending_write <= sdram_write;
      memory_pending_address <= sdram_address;
      memory_pending_data <= sdram_write_data;
      memory_pending_enable <= sdram_byte_enable;
      memory_pending_burst <= sdram_burst;
      if (sdram_write) begin
        sdram_write_request_count <= sdram_write_request_count + 1;
        assert (sdram_burst >= 1 && sdram_burst <= 4)
          else $fatal(1, "write burst %0d is outside the controller's 1..4 range",
                      sdram_burst);
        assert ((({1'b0, sdram_address[8:0]} + {5'd0, sdram_burst}) <= 10'd512))
          else $fatal(1,
              "write burst of %0d from word 0x%h crosses a 512-word SDRAM row",
              sdram_burst, sdram_address);
      end
      if (sdram_read) begin
        sdram_read_request_count <= sdram_read_request_count + 1;
        if (sdram_burst > sdram_longest_burst)
          sdram_longest_burst <= sdram_burst;
        assert (sdram_burst >= 1 && sdram_burst <= 16)
          else $fatal(1, "burst %0d is outside the controller's 1..16 range",
                      sdram_burst);
        // ki_sdram_burst walks consecutive columns inside one open row and
        // never re-ACTIVATEs, so a burst that ran past the 512-word row would
        // silently wrap back to the start of the same row.
        assert (({1'b0, sdram_address[8:0]} + {5'd0, sdram_burst}) <= 10'd512)
          else $fatal(1,
              "burst of %0d from word 0x%h crosses a 512-word SDRAM row",
              sdram_burst, sdram_address);
      end
    end

  end

  // DDR model runs at twice the bridge clock, as it does on MiSTer.
  always @(posedge ddr_clk) begin
    ddram_dout_ready <= 1'b0;

    if (ddram_we && !ddram_busy) begin
      ddram_write_count <= ddram_write_count + 1;
      last_dcs_address <= ddram_addr;
      last_dcs_data <= ddram_din;
      last_dcs_be <= ddram_be;
      for (int byte_index = 0; byte_index < 8; byte_index++) begin
        if (ddram_be[byte_index])
          ddram_memory[ddram_addr][byte_index * 8 +: 8] =
              ddram_din[byte_index * 8 +: 8];
      end
    end

    if (ddram_rd && !ddram_busy) begin
      assert (!ddram_read_pending)
        else $fatal(1, "overlapping DDR read requests");
      ddram_read_pending <= 1'b1;
      ddram_read_address <= ddram_addr;
      ddram_read_remaining <= ddram_burstcnt;
    end else if (ddram_read_pending) begin
      ddram_dout <= ddram_memory.exists(ddram_read_address) ?
          ddram_memory[ddram_read_address] : 64'd0;
      ddram_dout_ready <= 1'b1;
      if (ddram_read_remaining <= 1) begin
        ddram_read_pending <= 1'b0;
        ddram_read_remaining <= 8'd0;
      end else begin
        ddram_read_address <= ddram_read_address + 1'b1;
        ddram_read_remaining <= ddram_read_remaining - 1'b1;
      end
    end
  end

  task automatic send_download_word(
    input logic [15:0] index,
    input logic [26:0] address,
    input logic [15:0] data
  );
    integer timeout;
    begin
      timeout = 0;
      while (ioctl_wait) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 100)
          $fatal(1, "download remained stalled");
      end
      ioctl_index = index;
      ioctl_addr = address;
      ioctl_dout = data;
      ioctl_wr = 1'b1;
      @(posedge clk);
      #1;
      ioctl_wr = 1'b0;
    end
  endtask

  task automatic issue_cpu_request;
    begin
      cpu_request = 1'b1;
      @(posedge clk);
      #1;
      cpu_request = 1'b0;
    end
  endtask

  task automatic wait_cpu_done;
    integer timeout;
    begin
      timeout = 0;
      while (!cpu_done) begin
        @(posedge clk);
        #1;
        timeout = timeout + 1;
        if (timeout > 800)
          $fatal(1, "CPU transaction timed out");
      end
    end
  endtask

  // Count only the explicit EPROM-ready stall, excluding the memory path's
  // ordinary return latency. No SDRAM request may escape before that original
  // board timing has elapsed.
  task automatic wait_boot_rom_delay(input integer expected_cycles);
    integer delay_cycles;
    integer reads_before;
    begin
      delay_cycles = 0;
      reads_before = sdram_read_request_count;
      while (dut.boot_rom_wait_cycles != 0) begin
        @(posedge clk);
        #1;
        delay_cycles = delay_cycles + 1;
        if (delay_cycles > 600)
          $fatal(1, "boot-ROM ready delay did not finish");
      end
      assert (delay_cycles == expected_cycles)
        else $fatal(1,
            "boot-ROM ready delay was %0d clocks, expected %0d",
            delay_cycles, expected_cycles);
      assert (sdram_read_request_count == reads_before)
        else $fatal(1, "boot-ROM memory request escaped during ready delay");
    end
  endtask

  task automatic wait_video_done;
    integer timeout;
    begin
      timeout = 0;
      while (!video_done) begin
        @(posedge clk);
        #1;
        timeout = timeout + 1;
        if (timeout > 100)
          $fatal(1, "video transaction timed out");
      end
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);

    // Boot ROM is written to SDRAM and its first 8 KiB is cached in M10K for
    // reset fetches.
    // DCS ROM remains on DDR3.
    sdram_ready = 1'b1;
    repeat (2) @(posedge clk);
    ioctl_download = 1'b1;
    ioctl_index = 16'h0001;
    ioctl_addr = 27'h0000000;
    ioctl_dout = 16'h00e2;
    ioctl_wr = 1'b1;
    @(posedge clk);
    #1;
    ioctl_wr = 1'b0;

    // These are the real first eight bytes of KI's ki-l15d.u98 boot ROM.
    send_download_word(16'h0001, 27'h0000002, 16'h0bf0);
    send_download_word(16'h0001, 27'h0000004, 16'h0000);
    send_download_word(16'h0001, 27'h0000006, 16'h0000);
    for (int boot_beat = 1; boot_beat < 4; boot_beat++) begin
      for (int boot_word = 0; boot_word < 4; boot_word++)
        send_download_word(
            16'h0001,
            (boot_beat * 8) + (boot_word * 2),
            16'h1111 * boot_beat
        );
    end
    ioctl_download = 1'b0;

    repeat (100) begin
      @(posedge clk);
      #1;
      if (boot_loaded)
        break;
    end
    assert (boot_loaded)
      else $fatal(1, "boot_loaded did not wait for the SDRAM drain");
    assert (sdram_memory[25'h0480000] == 16'h00e2);
    assert (sdram_memory[25'h0480001] == 16'h0bf0);
    assert (sdram_memory[25'h0480002] == 16'h0000);
    assert (sdram_memory[25'h0480003] == 16'h0000)
      else $fatal(1, "real boot reset words were reordered");
    assert (sdram_write_count == 16)
      else $fatal(1, "boot ROM used %0d SDRAM words instead of sixteen",
                  sdram_write_count);
    // Sixteen words, but only four requests: one 4-word burst per downloaded
    // 64-bit word instead of four separate transactions.
    assert (sdram_write_request_count == 4)
      else $fatal(1, "boot ROM used %0d SDRAM write requests instead of four",
                  sdram_write_request_count);
    assert (ddram_write_count == 0)
      else $fatal(1, "boot loader incorrectly consumed DDR3");

    // MAME's 32-bit EPROM read owes 128 R4600 execution cycles. Its scheduler
    // runs two cycles per 100 MHz CPU clock, so this is 32 clocks in the
    // 50 MHz bridge before even the on-chip boot cache answers.
    reset = 1'b0;
    cpu_rnw = 1'b1;
    cpu_address = 32'h1fc0_0000;
    cpu_req64 = 1'b0;
    cpu_size = 3'd1;
    issue_cpu_request();
    wait_boot_rom_delay(32);
    wait_cpu_done();
    assert (cpu_data_read[31:0] == 32'h0bf0_00e2)
      else $fatal(1, "32-bit boot cache read returned incorrect data");

    // A real 64-bit boot fetch must return the MIPS jump 0x0bf000e2 first and
    // owes twice the 32-bit delay.
    cpu_req64 = 1'b1;
    cpu_size = 3'd1;
    issue_cpu_request();
    wait_boot_rom_delay(64);
    wait_cpu_done();
    assert (cpu_cache_data == 64'h0000_0000_0bf0_00e2)
      else $fatal(1, "boot cache beat is not little-endian U98 data");
    assert (sdram_read_count == 0)
      else $fatal(1, "reset fetch incorrectly used external SDRAM");

    // A boot cache line must return four ordered 64-bit on-chip beats.
    cpu_size = 3'd4;
    issue_cpu_request();
    wait_boot_rom_delay(256);
    begin
      integer boot_beat_count;
      integer boot_timeout;
      boot_beat_count = 0;
      boot_timeout = 0;
      while (!cpu_done) begin
        @(posedge clk);
        #1;
        if (cpu_cache_data_ready) begin
          case (boot_beat_count)
            0: assert (cpu_cache_data ==
                       64'h0000_0000_0bf0_00e2);
            1: assert (cpu_cache_data ==
                       64'h1111_1111_1111_1111);
            2: assert (cpu_cache_data ==
                       64'h2222_2222_2222_2222);
            3: assert (cpu_cache_data ==
                       64'h3333_3333_3333_3333);
            default: $fatal(1, "too many boot cache beats");
          endcase
          boot_beat_count = boot_beat_count + 1;
        end
        boot_timeout = boot_timeout + 1;
        if (boot_timeout > 100)
          $fatal(1, "boot cache fill timed out");
      end
      assert (boot_beat_count == 4)
        else $fatal(1, "boot cache fill returned %0d beats",
                    boot_beat_count);
    end
    cpu_size = 3'd1;
    assert (sdram_read_count == 0)
      else $fatal(1, "boot cache line incorrectly used external SDRAM");

    // The complete U98 image remains available through SDRAM after the 8 KiB
    // reset window.
    for (int boot_word = 0; boot_word < 4; boot_word++)
      sdram_memory[25'h0481000 + boot_word] = 16'h5000 + boot_word;
    cpu_address = 32'h1fc0_2000;
    issue_cpu_request();
    wait_cpu_done();
    assert (cpu_cache_data == 64'h5003_5002_5001_5000)
      else $fatal(1, "boot SDRAM fallback returned incorrect data");
    // A boot-ROM read past the 8 KiB M10K cache now pulls a whole 16-word
    // line, because the ROM is read through uncached KSEG1 one byte at a time
    // and the bridge caches it instead. Sixteen words, ONE request.
    assert (sdram_read_count == 16)
      else $fatal(1, "boot SDRAM fallback used %0d words", sdram_read_count);
    assert (sdram_read_request_count == 1)
      else $fatal(1, "boot line fill issued %0d SDRAM requests instead of one",
                  sdram_read_request_count);
    assert (sdram_longest_burst == 16)
      else $fatal(1, "boot line fill requested a burst of %0d instead of 16",
                  sdram_longest_burst);

    // ...and a second read inside that line must cost NOTHING.
    line_requests_before = sdram_read_request_count;
    cpu_address = 32'h1fc0_2010;
    issue_cpu_request();
    wait_cpu_done();
    assert (sdram_read_request_count == line_requests_before)
      else $fatal(1, "a second read inside the resident boot line issued %0d requests",
                  sdram_read_request_count - line_requests_before);

    // CPU framebuffer traffic is served by the dual-port M10K store and must
    // consume no SDRAM bandwidth.
    begin
      integer fb_read_before;
      integer fb_write_before;
      integer fb_sdram_reads_before;
      integer fb_sdram_writes_before;

      cpu_rnw = 1'b0;
      cpu_address = 32'h0003_0000;
      cpu_req64 = 1'b1;
      cpu_size = 3'd1;
      cpu_write_mask = 8'hff;
      cpu_data_write = 64'ha003_a002_a001_a000;
      fb_write_before = fb_write_accept_count;
      fb_sdram_reads_before = sdram_read_request_count;
      fb_sdram_writes_before = sdram_write_request_count;
      issue_cpu_request();
      wait_cpu_done();
      assert (fb_write_accept_count - fb_write_before == 1)
        else $fatal(1, "framebuffer store was not accepted by M10K");
      assert (sdram_read_request_count == fb_sdram_reads_before &&
              sdram_write_request_count == fb_sdram_writes_before)
        else $fatal(1, "framebuffer store touched SDRAM");

      cpu_rnw = 1'b1;
      fb_read_before = fb_read_accept_count;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'ha003_a002_a001_a000)
        else $fatal(1, "framebuffer read returned %016x", cpu_data_read);
      assert (fb_read_accept_count - fb_read_before == 1)
        else $fatal(1, "framebuffer read was not accepted by M10K");
      assert (sdram_read_request_count == fb_sdram_reads_before &&
              sdram_write_request_count == fb_sdram_writes_before)
        else $fatal(1, "framebuffer read touched SDRAM");

      // KI's renderer updates individual BGR555 pixels with 16-bit masks.
      // Every pixel lane must retain the other three pixels in the qword.
      cpu_rnw = 1'b0;
      cpu_write_mask = 8'h03;
      cpu_data_write = 64'h0000_0000_0000_1100;
      issue_cpu_request();
      wait_cpu_done();
      cpu_rnw = 1'b1;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'ha003_a002_a001_1100)
        else $fatal(1, "framebuffer pixel 0 mask returned %016x", cpu_data_read);

      cpu_rnw = 1'b0;
      cpu_write_mask = 8'h0c;
      cpu_data_write = 64'h0000_0000_2211_0000;
      issue_cpu_request();
      wait_cpu_done();
      cpu_rnw = 1'b1;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'ha003_a002_2211_1100)
        else $fatal(1, "framebuffer pixel 1 mask returned %016x", cpu_data_read);

      cpu_rnw = 1'b0;
      cpu_write_mask = 8'h30;
      cpu_data_write = 64'h0000_3322_0000_0000;
      issue_cpu_request();
      wait_cpu_done();
      cpu_rnw = 1'b1;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'ha003_3322_2211_1100)
        else $fatal(1, "framebuffer pixel 2 mask returned %016x", cpu_data_read);

      cpu_rnw = 1'b0;
      cpu_write_mask = 8'hc0;
      cpu_data_write = 64'h4433_0000_0000_0000;
      issue_cpu_request();
      wait_cpu_done();
      cpu_rnw = 1'b1;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'h4433_3322_2211_1100)
        else $fatal(1, "framebuffer pixel 3 mask returned %016x", cpu_data_read);

      // Restore the scanout fixture used below.
      cpu_rnw = 1'b0;
      cpu_write_mask = 8'hff;
      cpu_data_write = 64'ha003_a002_a001_a000;
      issue_cpu_request();
      wait_cpu_done();
      cpu_rnw = 1'b1;
      cpu_write_mask = 8'hff;
    end

    // The second framebuffer page is packed immediately after page 0 in
    // M10K, even though the CPU-visible map retains the 10 KiB gap.
    begin
      integer fb_read_before;
      integer fb_write_before;
      integer fb_sdram_reads_before;
      integer fb_sdram_writes_before;

      cpu_rnw = 1'b0;
      cpu_address = 32'h0005_8000;
      cpu_req64 = 1'b1;
      cpu_size = 3'd1;
      cpu_write_mask = 8'hff;
      cpu_data_write = 64'hc003_c002_c001_c000;
      fb_write_before = fb_write_accept_count;
      fb_sdram_reads_before = sdram_read_request_count;
      fb_sdram_writes_before = sdram_write_request_count;
      issue_cpu_request();
      wait_cpu_done();
      assert (fb_write_accept_count - fb_write_before == 1)
        else $fatal(1, "second framebuffer page store missed M10K");
      assert (sdram_read_request_count == fb_sdram_reads_before &&
              sdram_write_request_count == fb_sdram_writes_before)
        else $fatal(1, "second framebuffer page store touched SDRAM");

      cpu_rnw = 1'b1;
      fb_read_before = fb_read_accept_count;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'hc003_c002_c001_c000)
        else $fatal(1, "second framebuffer page read returned %016x",
                    cpu_data_read);
      assert (fb_read_accept_count - fb_read_before == 1)
        else $fatal(1, "second framebuffer page read missed M10K");
      assert (sdram_read_request_count == fb_sdram_reads_before &&
              sdram_write_request_count == fb_sdram_writes_before)
        else $fatal(1, "second framebuffer page read touched SDRAM");
    end

    // Addresses outside the two exact 150 KiB pages must remain ordinary low
    // SDRAM. These are the first qwords after page 0 and page 1 respectively.
    begin
      integer gap_fb_reads_before;
      integer gap_fb_writes_before;
      integer gap_sdram_reads_before;
      integer gap_sdram_writes_before;

      gap_fb_reads_before = fb_read_accept_count;
      gap_fb_writes_before = fb_write_accept_count;
      gap_sdram_reads_before = sdram_read_request_count;
      gap_sdram_writes_before = sdram_write_request_count;

      cpu_rnw = 1'b0;
      cpu_address = 32'h0005_5800;
      cpu_req64 = 1'b1;
      cpu_size = 3'd1;
      cpu_write_mask = 8'hff;
      cpu_data_write = 64'hd003_d002_d001_d000;
      issue_cpu_request();
      wait_cpu_done();
      assert (sdram_write_request_count - gap_sdram_writes_before == 1)
        else $fatal(1, "page 0 gap store did not use SDRAM");

      cpu_rnw = 1'b1;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'hd003_d002_d001_d000)
        else $fatal(1, "page 0 gap read returned %016x", cpu_data_read);
      assert (sdram_read_request_count - gap_sdram_reads_before == 1)
        else $fatal(1, "page 0 gap read did not use SDRAM");

      gap_sdram_reads_before = sdram_read_request_count;
      gap_sdram_writes_before = sdram_write_request_count;
      cpu_rnw = 1'b0;
      cpu_address = 32'h0007_d800;
      cpu_data_write = 64'he003_e002_e001_e000;
      issue_cpu_request();
      wait_cpu_done();
      assert (sdram_write_request_count - gap_sdram_writes_before == 1)
        else $fatal(1, "page 1 boundary store did not use SDRAM");

      cpu_rnw = 1'b1;
      issue_cpu_request();
      wait_cpu_done();
      assert (cpu_data_read == 64'he003_e002_e001_e000)
        else $fatal(1, "page 1 boundary read returned %016x", cpu_data_read);
      assert (sdram_read_request_count - gap_sdram_reads_before == 1)
        else $fatal(1, "page 1 boundary read did not use SDRAM");

      assert (fb_read_accept_count == gap_fb_reads_before &&
              fb_write_accept_count == gap_fb_writes_before)
        else $fatal(1, "an SDRAM gap aliased into framebuffer M10K");
    end

    // A 64-bit CPU store is split into four little-endian SDRAM words.
    cpu_rnw = 1'b0;
    cpu_address = 32'h0000_0020;
    cpu_req64 = 1'b1;
    cpu_write_mask = 8'hff;
    cpu_data_write = 64'h1122_3344_5566_7788;
    store_requests_before = sdram_write_request_count;
    low_writes_before = debug_low_write_count;
    issue_cpu_request();
    wait_cpu_done();
    assert (sdram_memory[25'h0000010] == 16'h7788);
    assert (sdram_memory[25'h0000011] == 16'h5566);
    assert (sdram_memory[25'h0000012] == 16'h3344);
    assert (sdram_memory[25'h0000013] == 16'h1122);
    assert (debug_low_write_count - low_writes_before == 1);
    // A 64-bit store is now ONE request, not four.
    assert (sdram_write_request_count - store_requests_before == 1)
      else $fatal(1, "64-bit store issued %0d SDRAM requests instead of one",
                  sdram_write_request_count - store_requests_before);

    // The same location must return coherently through the cache-fill port.
    // cpu_cache_data_ready is a pulse on the last word of the beat and now
    // lands strictly BEFORE cpu_done, which is the DDR3 burst contract the
    // instruction cache already counts beats against (cpu_instrcache.vhd),
    // so it has to be latched rather than sampled at completion.
    cpu_rnw = 1'b1;
    cpu_size = 3'd1;
    cache_ready_before = cache_ready_seen;
    issue_cpu_request();
    wait_cpu_done();
    assert (cpu_data_read == 64'h1122_3344_5566_7788);
    assert (cache_ready_seen - cache_ready_before == 1)
      else $fatal(1, "64-bit read pulsed cache_data_ready %0d times",
                  cache_ready_seen - cache_ready_before);
    assert (cache_ready_data == 64'h1122_3344_5566_7788)
      else $fatal(1, "cache-fill port returned %h", cache_ready_data);

    // Main RAM is packed at byte offset 0x0100000 in physical SDRAM.
    cpu_rnw = 1'b0;
    cpu_address = 32'h0800_0004;
    cpu_req64 = 1'b0;
    cpu_write_mask = 8'h0f;
    cpu_data_write = 64'h0000_0000_dead_beef;
    issue_cpu_request();
    wait_cpu_done();
    assert (sdram_memory[25'h0080002] == 16'hbeef);
    assert (sdram_memory[25'h0080003] == 16'hdead);
    assert (debug_main_write_count == 1);

    cpu_rnw = 1'b1;
    issue_cpu_request();
    wait_cpu_done();
    assert (cpu_data_read[31:0] == 32'hdead_beef);

    // The real board has 8 MiB (sixteen 1M x 4 DRAMs), so A23 is not connected
    // to the memory array. The ROM proves the following 1 MiB is still selected.
    // KI1 and KI2's CPU Board/Burn In diagnostic deliberately continues from
    // 0x08800000 through 0x088fffff and expects this mirror to answer.
    cpu_rnw = 1'b0;
    cpu_address = 32'h0880_0004;
    cpu_data_write = 64'h0000_0000_cafe_babe;
    issue_cpu_request();
    wait_cpu_done();
    assert (sdram_memory[25'h0080002] == 16'hbabe);
    assert (sdram_memory[25'h0080003] == 16'hcafe)
      else $fatal(1, "main-RAM diagnostic mirror did not discard A23");

    cpu_rnw = 1'b1;
    cpu_address = 32'h0800_0004;
    issue_cpu_request();
    wait_cpu_done();
    assert (cpu_data_read[31:0] == 32'hcafe_babe)
      else $fatal(1, "lower main RAM did not observe its A23 mirror write");

    // Exercise the diagnostic's exact final qword as well as its first mirrored
    // word; 0x088ffff8 aliases physical 0x080ffff8.
    cpu_rnw = 1'b0;
    cpu_address = 32'h088f_fff8;
    cpu_req64 = 1'b1;
    cpu_write_mask = 8'hff;
    cpu_data_write = 64'h2468_ace0_1357_9bdf;
    issue_cpu_request();
    wait_cpu_done();
    cpu_rnw = 1'b1;
    cpu_address = 32'h080f_fff8;
    issue_cpu_request();
    wait_cpu_done();
    assert (cpu_data_read == 64'h2468_ace0_1357_9bdf)
      else $fatal(1, "last diagnostic mirror qword did not alias main RAM");

    // Do not silently turn the rest of 0x08xxxxxx into RAM: the service ROM
    // only establishes the one-MiB mirror above.
    cpu_address = 32'h0890_0000;
    issue_cpu_request();
    wait_cpu_done();
    assert (cpu_data_read == 64'hffff_ffff_ffff_ffff)
      else $fatal(1, "address past the proven diagnostic mirror was mapped");

    // Four cache beats must be returned in address order with one completion.
    for (int word_index = 0; word_index < 16; word_index++)
      sdram_memory[25'h0000040 + word_index] =
          16'h1000 + word_index;
    cpu_address = 32'h0000_0080;
    cpu_req64 = 1'b1;
    cpu_size = 3'd4;
    line_requests_before = sdram_read_request_count;
    issue_cpu_request();
    begin
      integer beat_count;
      integer timeout;
      beat_count = 0;
      timeout = 0;
      while (!cpu_done) begin
        @(posedge clk);
        #1;
        if (cpu_cache_data_ready) begin
          case (beat_count)
            0: assert (cpu_cache_data == 64'h1003_1002_1001_1000);
            1: assert (cpu_cache_data == 64'h1007_1006_1005_1004);
            2: assert (cpu_cache_data == 64'h100b_100a_1009_1008);
            3: assert (cpu_cache_data == 64'h100f_100e_100d_100c);
            default: $fatal(1, "too many cache beats");
          endcase
          beat_count = beat_count + 1;
        end
        timeout = timeout + 1;
        if (timeout > 300)
          $fatal(1, "cache fill timed out");
      end
      assert (beat_count == 4)
        else $fatal(1, "cache fill returned %0d beats", beat_count);
    end
    cpu_size = 3'd1;
    // A 32-byte line is sixteen words. Before bursting this cost sixteen
    // round trips; it must now cost one.
    assert (sdram_read_request_count - line_requests_before == 1)
      else $fatal(1, "cache line fill issued %0d SDRAM requests instead of one",
                  sdram_read_request_count - line_requests_before);
    assert (sdram_longest_burst == 16)
      else $fatal(1, "cache line fill requested a burst of %0d instead of 16",
                  sdram_longest_burst);

    // Scanout reads the framebuffer's second M10K port and consumes no SDRAM.
    video_address = 28'h003_0000;
    video_requests_before = sdram_read_request_count;
    video_request = 1'b1;
    wait_video_done();
    assert (video_data == 64'ha003_a002_a001_a000)
      else $fatal(1, "scanout returned %016x", video_data);
    video_request = 1'b0;
    assert (sdram_read_request_count == video_requests_before)
      else $fatal(1, "scanout issued %0d unexpected SDRAM requests",
                  sdram_read_request_count - video_requests_before);

    // A cache line is only 4-word aligned, so one can start at word 500 of a
    // 512-word row and run off its end. ki_sdram_burst does not re-ACTIVATE
    // mid-burst, so the bridge must split this into 12 + 4 words. Byte 0x3E8
    // gives word address 500; the model $fatals on an unsplit burst.
    for (int split_word = 0; split_word < 16; split_word++)
      sdram_memory[25'd500 + split_word] = 16'h7000 + split_word;
    cpu_rnw = 1'b1;
    cpu_address = 32'h0000_03e8;
    cpu_req64 = 1'b1;
    cpu_size = 3'd4;
    line_requests_before = sdram_read_request_count;
    issue_cpu_request();
    begin
      integer split_beats;
      integer split_timeout;
      split_beats = 0;
      split_timeout = 0;
      while (!cpu_done) begin
        @(posedge clk);
        #1;
        if (cpu_cache_data_ready) begin
          case (split_beats)
            0: assert (cpu_cache_data == 64'h7003_7002_7001_7000);
            1: assert (cpu_cache_data == 64'h7007_7006_7005_7004);
            2: assert (cpu_cache_data == 64'h700b_700a_7009_7008);
            3: assert (cpu_cache_data == 64'h700f_700e_700d_700c);
            default: $fatal(1, "too many split-line beats");
          endcase
          split_beats = split_beats + 1;
        end
        split_timeout = split_timeout + 1;
        if (split_timeout > 300)
          $fatal(1, "row-crossing cache fill timed out");
      end
      assert (split_beats == 4)
        else $fatal(1, "row-crossing cache fill returned %0d beats",
                    split_beats);
    end
    assert (sdram_read_request_count - line_requests_before == 2)
      else $fatal(1,
          "row-crossing cache fill used %0d requests, expected two",
          sdram_read_request_count - line_requests_before);
    cpu_size = 3'd1;

    // DCS banks remain on DDR3 and never consume SDRAM capacity/bandwidth.
    ioctl_download = 1'b1;
    send_download_word(16'h0002, 27'h0000000, 16'h1122);
    send_download_word(16'h0002, 27'h0000002, 16'h3344);
    send_download_word(16'h0002, 27'h0000004, 16'h5566);
    send_download_word(16'h0002, 27'h0000006, 16'h7788);
    ioctl_download = 1'b0;
    repeat (4) @(posedge clk);
    assert (ddram_write_count == 1);
    assert (last_dcs_address == 29'h0614_0000);
    assert (last_dcs_data == 64'h7788_5566_3344_1122);
    assert (last_dcs_be == 8'hff);

    // An immediately completing board access must strobe the peripheral once.
    begin
      integer io_count_before;
      io_count_before = io_request_cycle_count;
      cpu_rnw = 1'b1;
      cpu_address = 32'h1000_0080;
      cpu_req64 = 1'b0;
      cpu_size = 3'd1;
      issue_cpu_request();
      wait_cpu_done();
      @(posedge clk);
      #1;
      assert (cpu_data_read[31:0] == 32'h1234_5678)
        else $fatal(1, "board I/O read data was not returned");
      assert (io_request_cycle_count - io_count_before == 1)
        else $fatal(1, "one CPU I/O access strobed the peripheral %0d times",
                    io_request_cycle_count - io_count_before);
    end

    $display("tb_ki_memory_bridge: %0d SDRAM words read in %0d requests, longest burst %0d",
             sdram_read_count, sdram_read_request_count, sdram_longest_burst);
    $display("tb_ki_memory_bridge: %0d SDRAM words written in %0d requests",
             sdram_write_count, sdram_write_request_count);
    $display("tb_ki_memory_bridge: PASS");
    $finish;
  end
endmodule

`default_nettype wire
