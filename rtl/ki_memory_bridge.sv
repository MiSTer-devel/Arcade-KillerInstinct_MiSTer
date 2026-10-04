// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_memory_bridge (
  input  wire         clk,
  input  wire         ddr_clk,
  input  wire         reset,

  input  wire         cpu_request,
  input  wire         cpu_rnw,
  input  wire  [31:0] cpu_address,
  input  wire         cpu_req64,
  input  wire   [2:0] cpu_size,
  input  wire   [7:0] cpu_write_mask,
  input  wire  [63:0] cpu_data_write,
  // A whole dirty cache line in ONE request: 32 bytes, valid with cpu_request
  // while cpu_line_write is high, and always 32-byte aligned. It goes out as
  // the same single 16-word burst the write gather below produces, so the two
  // share the holding registers. cpu_write_mask[3:0] says which of its four
  // qwords to write, bit i for offset 8i: all four is one 16-word burst, and
  // anything less is one 4-word burst per qword written - never a burst with
  // masked words in it (see wb_split). See cpu.vhd's mem_line_write.
  input  wire         cpu_line_write,
  input  wire [255:0] cpu_line_data,
  // The line's bytes, bit 8i+j for byte j of qword i, ANDed with the qword
  // mask. Only FB_LINE_WRITE uses them - the framebuffer RAM has real byte
  // enables - and every CPU line into SDRAM has whole qwords. Tie to all ones
  // where nothing drives it.
  input  wire  [31:0] cpu_line_bytes,
  output logic [63:0] cpu_data_read,
  output logic        cpu_done,
  output logic        cpu_grant,
  output logic [63:0] cpu_cache_data,
  output logic        cpu_cache_data_ready,

  output logic        io_request,
  output logic        io_write,
  output logic [31:0] io_address,
  output logic [31:0] io_write_data,
  output logic  [3:0] io_byte_enable,
  input  wire  [31:0] io_read_data,
  input  wire         io_done,

  input  wire         ioctl_download,
  input  wire         ioctl_wr,
  input  wire  [15:0] ioctl_index,
  input  wire  [26:0] ioctl_addr,
  input  wire  [15:0] ioctl_dout,
  output logic        ioctl_wait,
  output logic        boot_loaded = 1'b0,

  input  wire         video_request,
  input  wire  [27:0] video_address,
  // 64-bit words this request asks for, 1..4; zero is taken as four. Every
  // request lies inside one of the two framebuffer pages - the only bases
  // ki_board_io can select - and is served from the framebuffer RAM's own
  // port, never from SDRAM.
  input  wire   [2:0] video_words,
  output logic [63:0] video_data,
  // One pulse per assembled 64-bit word, in address order, each strictly
  // before video_done. A single-word requester can ignore it and keep reading
  // video_data at video_done as before.
  output logic        video_data_valid,
  output logic        video_done,

  // DCS sound ROM read port, from KillerInstinct_MiSTer-audio. The ADSP-2105
  // fetches its program and sample data out of the DCS banks the loader put in
  // DDR3 at STORE_DCS, so this is a third requester on the DDR service state
  // machine alongside the CPU's write and read. It crosses to ddr_clk through
  // the same mailbox-and-toggle pattern the CPU read already uses rather than
  // a second mechanism.
  input  wire         dcs_rom_request,
  input  wire  [18:0] dcs_rom_address,
  output logic        dcs_rom_ready,
  output logic [63:0] dcs_rom_data,

  output logic [24:0] sdram_address,
  // Up to four words, low word first, with one byte-enable pair per word.
  // Up to 16 words - one 32-byte cache line. A dirty line is gathered here
  // and written as a single burst; see the gather block below.
  output logic [255:0] sdram_write_data,
  output logic  [31:0] sdram_byte_enable,
  // Words to transfer: reads 1..SDRAM_MAX_BURST, writes 1..4.
  output logic  [4:0] sdram_burst,
  output logic        sdram_read,
  output logic        sdram_write,
  // TWO 16-bit words per beat, low word first. ki_sdram_x2 packs them so the
  // bridge still sees one beat per clk_core cycle when the controller runs at
  // twice this clock. Every
  // burst this bridge issues is an even number of words (2, 4, 8, 12 or 16),
  // so sdram_read_be is always 2'b11 here; the odd-tail case exists for the
  // BIST's single-word probe and is checked below rather than assumed.
  input  wire  [31:0] sdram_read_data,
  input  wire   [1:0] sdram_read_be,
  // One pulse per returned word of a burst read, in address order. The final
  // pulse always precedes sdram_done.
  input  wire         sdram_data_valid,
  input  wire         sdram_done,
  input  wire         sdram_ready,

  input  wire         ddram_busy,
  output logic  [7:0] ddram_burstcnt,
  output logic [28:0] ddram_addr,
  input  wire  [63:0] ddram_dout,
  input  wire         ddram_dout_ready,
  output logic        ddram_rd,
  output logic [63:0] ddram_din,
  output logic  [7:0] ddram_be,
  output logic        ddram_we,

  // One-cycle strobes on each CPU access ACCEPTED inside the framebuffer
  // window, counted per frame at the top level. They show whether the game
  // reads the framebuffer at all: if the blit does read-modify-write, a fault
  // in the read path does not just return bad data to the CPU, it makes the
  // CPU write CORRUPTED pixels back.
  output logic        fb_read_accept,
  output logic        fb_write_accept,
  // Per-frame census of how long CPU requests spend in this bridge, for the
  // Perf debug page. The CPU counts ITS cycles per D-cache line fill; this
  // says how much of that is spent here.
  //
  // NOTE THE UNITS. This module runs on clk_core at 50 MHz while the CPU runs
  // at 100, so one count here is TWO CPU cycles. BO x 2 against the CPU's
  // DC/MC is the whole point: if they match, the latency is inside this
  // bridge; if BO x 2 is much smaller, it is being lost outside it.
  //
  //   perf_cpu_outstanding  a CPU request is in flight here (have_cpu)
  //   perf_cpu_burst        that request is in its SDRAM read
  //
  // Both are units of 256 clk_core cycles, saturating, latched on perf_frame
  // and held for the following frame - which is what makes them safe to
  // sample from the CPU domain.
  input  wire         perf_frame,
  output logic [15:0] perf_cpu_outstanding = 16'd0,
  output logic [15:0] perf_cpu_burst = 16'd0,
  output logic [31:0] debug_write_count = 32'h0000_0000,
  output logic [31:0] debug_low_write_count = 32'h0000_0000,
  output logic [31:0] debug_main_write_count = 32'h0000_0000
);
  import ki_board_pkg::*;

  localparam logic [27:0] STORE_LOW  = 28'h000_0000;
  localparam logic [27:0] STORE_MAIN = 28'h010_0000;
  localparam logic [27:0] STORE_BOOT = 28'h090_0000;
  localparam logic [27:0] STORE_DCS  = 28'h0a0_0000;

  localparam integer BOOT_CACHE_BYTES = 8 * 1024;
  localparam integer BOOT_CACHE_WORDS = BOOT_CACHE_BYTES / 8;
  localparam integer BOOT_CACHE_ADDR_WIDTH = $clog2(BOOT_CACHE_WORDS);

  localparam integer DOWNLOAD_FIFO_DEPTH = 16;
  localparam logic [4:0] DOWNLOAD_FIFO_HIGH_WATER = 5'd8;

  // Longest burst ki_sdram_burst / ki_sdram_adapter accept, and the number of
  // 16-bit words that share one SDRAM row under that controller's
  // decomposition (col = byte_addr[9:1], so 512 words per row). A burst walks
  // consecutive columns without re-ACTIVATEing, so it must not cross a row
  // boundary; a request that would is split into two bursts here.
  localparam logic [4:0] SDRAM_MAX_BURST = 5'd16;
  localparam integer SDRAM_ROW_WORDS = 512;

  // The real CPU board does not return its EPROM at FPGA-memory speed. Every
  // 32-bit EPROM access carries 64 CPU clocks of RdRdy delay. The CPU runs at
  // 100 MHz while this bridge runs at 50 MHz, so each 16-bit bridge word owes
  // 16 clk cycles:
  //
  //   2 words * 16 clk = 32 clk = 64 CPU clocks.
  //
  // Scaling by active_read_words preserves the same board-visible delay for
  // 64-bit fetches and 32-byte cache-line fills, regardless of whether the
  // data itself comes from the boot M10K, the line buffer, or SDRAM.
  localparam integer BOOT_ROM_WAIT_SHIFT = 4;

  // 22 states, so five bits.
  typedef enum logic [4:0] {
    IDLE,
    BOOT_CACHE_READ_WAIT,
    BOOT_CACHE_READ_RETURN,
    SDRAM_READ_ISSUE,
    SDRAM_READ_WAIT,
    SDRAM_WRITE_ISSUE,
    SDRAM_WRITE_WAIT,
    SDRAM_WRITE_RMW_WAIT,
    SDRAM_WRITE_RMW_ISSUE,
    SDRAM_WB_FLUSH_ISSUE,
    SDRAM_WB_FLUSH_WAIT,
    IO_WAIT,
    FB_READ_ISSUE,
    FB_READ_WAIT,
    FB_WRITE,
    FB_LINE_WRITE,
    DOWNLOAD_SDRAM_WRITE_ISSUE,
    DOWNLOAD_SDRAM_WRITE_WAIT,
    ROM_LINE_FILL_ISSUE,
    ROM_LINE_FILL_WAIT,
    ROM_LINE_RETURN,
    BOOT_ROM_ACCESS_WAIT
  } state_t;

  state_t state = IDLE;
  state_t boot_rom_return_state = IDLE;
  logic [8:0] boot_rom_wait_cycles = 9'd0;

  logic cpu_pending = 1'b0;
  logic pending_rnw = 1'b1;
  logic [31:0] pending_address = 32'd0;
  logic pending_req64 = 1'b0;
  logic [2:0] pending_size = 3'd1;
  logic [7:0] pending_write_mask = 8'd0;
  logic [63:0] pending_data_write = 64'd0;
  logic        pending_line_write = 1'b0;
  logic [255:0] pending_line_data = 256'd0;
  logic  [31:0] pending_line_bytes = 32'hFFFF_FFFF;

  logic [31:0] operation_address = 32'd0;
  logic operation_req64 = 1'b0;
  logic [7:0] operation_write_mask = 8'd0;
  logic [63:0] operation_write_data = 64'd0;

  logic [24:0] memory_word_address = 25'd0;
  logic [2:0] memory_word_count = 3'd0;
  logic [2:0] read_beats_remaining = 3'd0;
  logic [63:0] read_buffer = 64'd0;
  logic [63:0] read_buffer_next;
  // 64-bit beats of the current SDRAM read handed to the CPU, counted on the
  // edge each is handed over, so it reads the NEXT beat's index; the fourth
  // wraps it to 0. Only simulation reads it, so synthesis prunes it.
  logic [1:0] fill_beat = 2'd0;

  // ---- narrow stores, without DQM ----------------------------------------
  // A store that does not write every byte of every word in its burst cannot
  // go out with the missing bytes masked off by DQM. The board ignores DQM (a
  // fully masked word is written anyway), so those bytes would land on live
  // memory carrying whatever the store's data register holds in their lanes.
  // `sw` and `sd` fill every byte and take the direct path; `sh`, `sb` and a
  // partial `sdl`/`sdr` become read-modify-write here: read the burst's words,
  // merge the enabled bytes, write them all back with every enable set.
  wire wr_mask_full = operation_req64 ? (operation_write_mask == 8'hff)
                                      : (operation_write_mask[3:0] == 4'hf);
  logic [63:0] rmw_read = 64'd0;
  logic  [1:0] rmw_index = 2'd0;
  logic [63:0] rmw_merged;
  always_comb begin
    for (int b = 0; b < 8; b++)
      rmw_merged[b*8 +: 8] = operation_write_mask[b] ?
          operation_write_data[b*8 +: 8] : rmw_read[b*8 +: 8];
  end

  // Burst read bookkeeping. `read_word_index` is the position inside the
  // 64-bit word being assembled; `read_words_remaining` is how much of the
  // whole operation is still outstanding, across however many bursts it takes.
  logic  [1:0] read_word_index = 2'd0;
  logic  [4:0] read_words_remaining = 5'd0;

  // Boot-ROM line buffer.
  //
  // The boot ROM addresses itself through 0xBFC0xxxx (KSEG1), which MIPS
  // defines as UNCACHED - `lui s4,0xBFC0` at 9FC007AC and `lui a1,0xBFC0` at
  // 9FC006A8 - so the CPU's data cache correctly refuses to cache it. The boot
  // decompressor at 9FC00DEC then walks the ROM ONE BYTE at a time, and a byte
  // load makes this bridge fetch the enclosing 32-bit word, so four
  // consecutive byte reads re-fetch the same two SDRAM words.
  //
  // Caching it HERE is architecturally invisible: the boot ROM is immutable
  // once downloaded, so there is nothing for the CPU's uncached semantics to
  // go stale against. One 16-word burst fill replaces up to 32 separate
  // transactions.
  localparam integer ROM_LINE_WORDS = 16;
  (* ramstyle = "logic" *)
  logic [15:0] rom_line [0:ROM_LINE_WORDS-1];
  logic [20:0] rom_line_tag = 21'h1fffff;
  logic rom_line_valid = 1'b0;
  logic [3:0] rom_fill_index = 4'd0;
  logic [20:0] rom_pending_tag = 21'd0;
  logic [3:0] rom_line_offset = 4'd0;

  // Reset execution reaches the first KI hardware register after very few
  // retired instructions. Keep that early path in a true on-chip dual-port
  // ROM cache so reset fetches do not depend on external-memory latency.
  (* ramstyle = "M10K, no_rw_check" *)
  logic [63:0] boot_cache [0:BOOT_CACHE_WORDS-1];
  logic [BOOT_CACHE_ADDR_WIDTH-1:0] boot_cache_read_address = '0;
  logic [63:0] boot_cache_read_data = 64'd0;

  logic [27:0] download_address [0:DOWNLOAD_FIFO_DEPTH-1];
  logic [63:0] download_data [0:DOWNLOAD_FIFO_DEPTH-1];
  logic download_is_boot [0:DOWNLOAD_FIFO_DEPTH-1];
  logic [47:0] download_assembly_data = 48'd0;
  logic [3:0] download_write_pointer = 4'd0;
  logic [3:0] download_read_pointer = 4'd0;
  logic [4:0] download_count = 5'd0;
  logic boot_seen = 1'b0;
  logic download_inflight = 1'b0;

  // Stable command mailboxes cross between the 50 MHz bridge and the
  // 100 MHz MiSTer DDR service domain. A command remains unchanged until
  // its acknowledgement returns.
  logic [28:0] ddr_write_mailbox_address = 29'd0;
  logic [63:0] ddr_write_mailbox_data = 64'd0;
  logic [7:0] ddr_write_mailbox_be = 8'd0;
  logic ddr_write_request_toggle = 1'b0;
  logic ddr_write_ack_toggle = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_write_ack_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_write_ack_sync2 = 1'b0;
  logic ddr_write_ack_seen = 1'b0;

  (* ASYNC_REG = "TRUE" *) logic ddr_write_request_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_write_request_sync2 = 1'b0;
  logic ddr_write_request_seen = 1'b0;

  // DCS sound ROM mailbox.
  // dcs_rom_request is a LEVEL held by ki_dcs_audio until ready, not a pulse,
  // so dcs_rom_request_seen_level latches that one request has already been
  // taken and blocks re-issue until the level drops.
  logic [18:0] dcs_rom_mailbox_address = 19'd0;
  logic [63:0] dcs_rom_mailbox_data = 64'd0;
  logic dcs_rom_request_toggle = 1'b0;
  logic dcs_rom_done_toggle = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic dcs_rom_done_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic dcs_rom_done_sync2 = 1'b0;
  logic dcs_rom_done_seen = 1'b0;
  logic dcs_rom_inflight = 1'b0;
  logic dcs_rom_request_seen_level = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic dcs_rom_request_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic dcs_rom_request_sync2 = 1'b0;
  logic dcs_rom_request_seen = 1'b0;

  typedef enum logic [1:0] {
    DDR_SERVICE_IDLE,
    DDR_SERVICE_WRITE,
    DDR_SERVICE_DCS_ISSUE,
    DDR_SERVICE_DCS_READ
  } ddr_service_state_t;
  ddr_service_state_t ddr_service_state = DDR_SERVICE_IDLE;

  // Combined MRA ROM image:
  //
  //   000000-07FFFF  R4600 boot ROM
  //   080000-0FFFFF  U10
  //   100000-17FFFF  U11
  //   180000-1FFFFF  U12
  //   200000-27FFFF  U13
  //   280000-2FFFFF  U33
  //   300000-37FFFF  U34
  //   380000-3FFFFF  U35
  //   400000-47FFFF  U36
  //
  // Index 1 is therefore one 0x480000-byte ROM image.

  localparam logic [26:0] BOOT_DOWNLOAD_BYTES = 27'h0080000;
  localparam logic [26:0] ROM_DOWNLOAD_BYTES  = 27'h0480000;

  wire rom_download =
      ioctl_download &&
      (ioctl_index == 16'h0001) &&
      (ioctl_addr < ROM_DOWNLOAD_BYTES);

  wire boot_download =
      rom_download &&
      (ioctl_addr < BOOT_DOWNLOAD_BYTES);

  // There is deliberately no sound_download wire: incoming_download_address
  // selects on boot_download, so "not boot" IS the sound case.
  wire [26:0] sound_download_address =
      ioctl_addr - BOOT_DOWNLOAD_BYTES;

  wire [27:0] incoming_download_address =
      boot_download ?
          (STORE_BOOT + ioctl_addr) :
          (STORE_DCS + sound_download_address);

  wire download_accept = rom_download && ioctl_wr && !ioctl_wait;
  wire download_push =
      download_accept && (incoming_download_address[2:1] == 2'd3);
  wire download_ddr_pop =
      download_inflight &&
      !download_is_boot[download_read_pointer] &&
      (ddr_write_ack_sync2 != ddr_write_ack_seen);
  // One burst covers the whole 64-bit word, so completion is simply done.
  wire download_sdram_pop =
      download_inflight &&
      download_is_boot[download_read_pointer] &&
      (state == DOWNLOAD_SDRAM_WRITE_WAIT) &&
      sdram_done;
  wire download_pop = download_ddr_pop || download_sdram_pop;

  wire have_cpu = cpu_pending || cpu_request;

  // See the perf_* ports. perf_frame is already in this clock domain, so the
  // edge detect is only to tolerate a multi-cycle strobe.
  logic [23:0] perf_out_cnt   = 24'd0;
  logic [23:0] perf_burst_cnt = 24'd0;
  logic  [1:0] perf_frame_d   = 2'd0;
  always_ff @(posedge clk) begin
    perf_frame_d <= {perf_frame_d[0], perf_frame};
    if (reset) begin
      perf_out_cnt         <= 24'd0;
      perf_burst_cnt       <= 24'd0;
      perf_cpu_outstanding <= 16'd0;
      perf_cpu_burst       <= 16'd0;
    end else if (perf_frame_d[0] && !perf_frame_d[1]) begin
      perf_cpu_outstanding <= perf_out_cnt[23:8];
      perf_cpu_burst       <= perf_burst_cnt[23:8];
      perf_out_cnt         <= 24'd0;
      perf_burst_cnt       <= 24'd0;
    end else begin
      if (have_cpu && perf_out_cnt != 24'hFFFFFF)
        perf_out_cnt <= perf_out_cnt + 24'd1;
      if ((state == SDRAM_READ_ISSUE || state == SDRAM_READ_WAIT) &&
          perf_burst_cnt != 24'hFFFFFF)
        perf_burst_cnt <= perf_burst_cnt + 24'd1;
    end
  end
  wire active_rnw = cpu_pending ? pending_rnw : cpu_rnw;
  wire [31:0] active_address =
      cpu_pending ? pending_address : cpu_address;
  wire active_req64 = cpu_pending ? pending_req64 : cpu_req64;
  wire [2:0] active_size = cpu_pending ? pending_size : cpu_size;
  wire [7:0] active_write_mask =
      cpu_pending ? pending_write_mask : cpu_write_mask;
  wire [63:0] active_data_write =
      cpu_pending ? pending_data_write : cpu_data_write;
  wire active_line_write = cpu_pending ? pending_line_write : cpu_line_write;
  wire [255:0] active_line_data =
      cpu_pending ? pending_line_data : cpu_line_data;
  wire  [31:0] active_line_bytes =
      cpu_pending ? pending_line_bytes : cpu_line_bytes;

  wire io_selected =
      ((active_address >= KI_IO_BASE) &&
       (active_address <= KI_IO_LAST)) ||
      ((active_address >= KI_ATA_CS0_BASE) &&
       (active_address <= KI_ATA_CS0_LAST)) ||
      ((active_address >= KI_ATA_CS1_ADDR) &&
       (active_address <= (KI_ATA_CS1_ADDR + 3)));

  wire [27:0] active_storage_address =
      storage_address(active_address);

  // ---- dirty-line write gather -------------------------------------------
  // A 32-byte dirty line reaches the bridge as four consecutive full-mask
  // 64-bit writes. Issued separately they cost four lots of the
  // per-transaction overhead. Gathering them into one 16-word burst pays it
  // once.
  //
  // Writes are acknowledged as soon as they are absorbed, so correctness
  // rests on one rule: every OTHER requester flushes the buffer before it is
  // served, reads included. The one path that does not go through here is the
  // BIST, which drives the adapter's aux port directly - it runs as a
  // diagnostic, never alongside CPU traffic.
  //
  // Set to 0 to disable gathering without removing it (the eligibility test
  // folds to a constant), which is the first thing to try if hardware
  // misbehaves.
  localparam logic WB_GATHER = 1'b1;

  logic   [2:0] wb_count = 3'd0;     // 64-bit chunks held, 0..4
  logic  [24:0] wb_addr = 25'd0;     // word address of the first chunk
  logic [255:0] wb_data = 256'd0;
  logic  [31:0] wb_be = 32'd0;
  // Cycles since the last chunk landed. A lone store is not part of a line,
  // so it must not sit here indefinitely: bit 5 flushes it after 32 cycles,
  // which is far longer than the gap between a writeback's beats.
  logic   [5:0] wb_idle = 6'd0;
  // A line write with some qwords left out goes out as one full-enable 4-word
  // burst per qword it holds, never as a 16-word burst with words masked off.
  // The board ignores DQM, so masked words inside a write burst would be
  // written anyway, while every simulation model honours it. ki_sdram_bist
  // checks DQM on the board; this path does not depend on the answer.
  logic         wb_split = 1'b0;
  logic   [3:0] wb_qmask = 4'd0;     // qwords still to write in split mode

  wire [2:0] active_read_beats =
      (active_size == 3'd0) ? 3'd1 : active_size;
  wire active_boot_cache_read =
      active_rnw && is_boot_address(active_address) &&
      (active_address[18:13] == 6'b000000) &&
      (!active_req64 || (active_address[12:0] <= 13'h1fe0));

  // 16-bit words a CPU read owes in total: four per 64-bit beat, so a 32-byte
  // cache line (four beats) is sixteen words issued as one burst instead of
  // sixteen round trips. mem_size is only ever 1 or 4 (rtl/cpu/cpu.vhd); the
  // clamp makes a wider size degrade to a short read rather than an
  // out-of-range burst.
  wire [4:0] active_read_words =
      !active_req64                ? 5'd2 :
      (active_read_beats >= 3'd4)  ? SDRAM_MAX_BURST :
                                     {1'b0, active_read_beats[1:0], 2'b00};

  // The word address this operation would start at, matching what IDLE loads
  // into memory_word_address.
  wire [24:0] active_word_address = active_req64 ?
      {active_storage_address[25:3], 2'b00} :
      {active_storage_address[25:2], 1'b0};


  // Only short boot-ROM reads use the line buffer. A 32-bit read is two words
  // on a 2-word boundary and a 64-bit read is four on a 4-word boundary, so
  // both sit wholly inside one 16-word line. A 32-byte cache-line fill is only
  // 4-word aligned and could straddle two lines, so it keeps the direct path -
  // and it is already one burst, so it has nothing to gain here.
  wire active_rom_line_eligible =
      active_rnw && is_boot_address(active_address) &&
      !active_boot_cache_read &&
      (active_read_words <= 5'd4) &&
      (({1'b0, active_word_address[3:0]} + active_read_words) <= 6'd16);
  wire rom_line_hit =
      rom_line_valid && (active_word_address[24:4] == rom_line_tag);

  // Words this operation still owes after the beat currently on the wire.
  wire [4:0] read_words_left_next = sdram_data_valid ?
      (read_words_remaining - 5'd2) : read_words_remaining;

  // Longest burst that starts at memory_word_address, stays inside its row and
  // does not overrun what the operation still needs.
  wire [9:0] row_words_left =
      SDRAM_ROW_WORDS[9:0] - {1'b0, memory_word_address[8:0]};
  wire [4:0] burst_cap = (row_words_left >= {5'd0, SDRAM_MAX_BURST}) ?
      SDRAM_MAX_BURST : row_words_left[4:0];
  wire [4:0] next_burst = (read_words_remaining > burst_cap) ?
      burst_cap : read_words_remaining;


  // ------------------------------------------------------------------
  // Authoritative framebuffer pages in on-chip memory.
  //
  // Scanout and the CPU would otherwise share one SDRAM port. There is no need
  // to share, so scanout gets its own port.
  //
  // Both framebuffer pages live in low RAM, page 0 at 0x30000 and page 1 at
  // 0x58000, 320x240x2 = 150 KiB each. They are compacted into 38400 64-bit
  // words. The holes 0x55800-0x57fff and 0x7d800-0x7ffff remain SDRAM.
  //
  // This memory is authoritative for those exact pages. CPU reads, CPU writes
  // and scanout are all served from here, so there is exactly one copy and no
  // coherency question. The CPU-visible memory map does not change.
  //
  // A write-through mirror would only remove scanout READS from SDRAM. It
  // would leave the heavier traffic - the 153,600-byte blit the game runs every
  // frame - still paying a full SDRAM activate/write/precharge per store.
  // Owning the window outright makes each of those stores a single cycle.
  //
  // Nothing else writes this range: the ioctl download only touches the boot
  // and DCS regions, and the CPU is the sole writer of low RAM.
  // Two exact 320x240x16 buffers. The two 10 KiB holes remain low SDRAM.
  localparam integer FB_BUFFER_WORDS = 19200;
  localparam integer FB_WORDS = 38400;
  localparam logic [31:0] FB0_LOW  = 32'h0003_0000;
  localparam logic [31:0] FB0_HIGH = 32'h0005_5800;
  localparam logic [31:0] FB1_LOW  = 32'h0005_8000;
  localparam logic [31:0] FB1_HIGH = 32'h0007_d800;

  wire  [63:0] fb_q;
  wire  [63:0] fb_vq;
  logic [15:0] fb_addr = 16'd0;                 // port A address, read or write
  logic [63:0] fb_wdata;
  logic  [7:0] fb_wbe;
  logic        fb_we;

  localparam logic [1:0] VID_IDLE  = 2'd0;
  localparam logic [1:0] VID_ISSUE = 2'd1;
  localparam logic [1:0] VID_WAIT  = 2'd2;
  localparam logic [1:0] VID_DONE  = 2'd3;
  logic  [1:0] vid_state = VID_IDLE;
  logic [15:0] fb_vaddr = 16'd0;
  logic  [2:0] vid_left = 3'd0;

  // Storage byte address to compact framebuffer word index. Low RAM maps 1:1
  // (STORE_LOW is zero), so the CPU physical address is the storage address.
  function automatic logic [15:0] fb_index(input logic [31:0] byte_address);
    if (byte_address >= FB1_LOW)
      return FB_BUFFER_WORDS + ((byte_address - FB1_LOW) >> 3);
    return (byte_address - FB0_LOW) >> 3;
  endfunction

  // A read serves one 64-bit word per two cycles. A 32-byte cache-line fill is
  // four of them; a 64-bit or 32-bit access is one.
  logic [2:0] fb_qwords_left = 3'd0;

  // A WHOLE-LINE write into the framebuffer: a dirty data-cache line written
  // back. KI2 draws its framebuffer through a WRITE-BACK cache on the board -
  // Config K0 = 3, every framebuffer pointer built in KSEG0, the whole D-cache
  // flushed with Index_WB_Invalid_D every frame - so with the framebuffer
  // cached, every one of its dirty lines comes back through here.
  //
  // Latched on acceptance, not read from active_*: the request is acknowledged
  // then, the CPU's next one can land in pending_* while these four writes are
  // still going, and active_* follows pending_*. One qword a cycle into the
  // 64-bit RAM, gated per qword by the line's mask, because a line whose
  // store-miss fill was skipped holds nothing for the qwords it never stored.
  logic [255:0] fb_line_data  = 256'd0;
  logic  [15:0] fb_line_base  = 16'd0;
  logic   [3:0] fb_line_qmask = 4'd0;
  logic  [31:0] fb_line_bytes = 32'd0;
  logic   [1:0] fb_line_k     = 2'd0;

  // Keep both framebuffer pages and scanout on a true dual-port block RAM.
  // A same-word mixed-port collision is retried below; the scanout port never
  // consumes device-specific collision data.
  wire cpu_hits_fb = ((active_address >= FB0_LOW) &&
                      (active_address < FB0_HIGH)) ||
                     ((active_address >= FB1_LOW) &&
                      (active_address < FB1_HIGH));

  // synthesis translate_off
  // Scanout reads only the framebuffer pages, and a request stays inside one:
  // its last qword is in the same page as its first. See video_words.
  wire [31:0] video_first = {4'd0, video_address};
  wire [31:0] video_last  = video_first +
      {26'd0, ((video_words == 3'd0) ? 3'd4 : video_words) - 3'd1, 3'd0};
  always @(posedge clk)
    if (!reset && video_request && !video_done)
      assert (((video_first >= FB0_LOW) && (video_last < FB0_HIGH)) ||
              ((video_first >= FB1_LOW) && (video_first < FB1_HIGH) &&
               (video_last < FB1_HIGH)))
        else $error("scanout request at %h for %0d qwords is not inside one framebuffer page",
                    video_address, (video_words == 3'd0) ? 4 : video_words);
  // synthesis translate_on

  // Explicitly instantiated, not inferred. Quartus 17.0 does not infer this
  // memory and fails silently; see the note at the top of rtl/ki_fb_ram.sv.
  ki_fb_ram #(.WORDS(FB_WORDS)) fb_ram (
    .clock(clk),
    .cpu_address(fb_addr),
    .cpu_data(fb_wdata),
    .cpu_byteena(fb_wbe),
    .cpu_wren(fb_we),
    .cpu_q(fb_q),
    .vid_address(fb_vaddr),
    .vid_q(fb_vq)
  );


  function automatic logic is_memory_address(
    input logic [31:0] address
  );
    return ((address >= KI_LOW_RAM_BASE) &&
            (address <= KI_LOW_RAM_LAST)) ||
           ((address >= KI_MAIN_RAM_BASE) &&
            (address <= KI_MAIN_RAM_LAST)) ||
           ((address >= KI_MAIN_RAM_ALIAS_BASE) &&
            (address <= KI_MAIN_RAM_ALIAS_LAST)) ||
           ((address >= KI_BOOT_BASE) &&
            (address <= KI_BOOT_LAST));
  endfunction

  function automatic logic is_boot_address(
    input logic [31:0] address
  );
    return (address >= KI_BOOT_BASE) &&
           (address <= KI_BOOT_LAST);
  endfunction

  function automatic logic [27:0] storage_address(
    input logic [31:0] address
  );
    if (address <= KI_LOW_RAM_LAST)
      return STORE_LOW + address[27:0];
    if ((address >= KI_MAIN_RAM_BASE) &&
        (address <= KI_MAIN_RAM_LAST))
      return STORE_MAIN +
          (address[27:0] - KI_MAIN_RAM_BASE[27:0]);
    // Main RAM is physically 8 MiB.  The ROM proves that A23 selects no DRAM
    // pin for the following 1 MiB, which aliases the array's first 1 MiB.
    if ((address >= KI_MAIN_RAM_ALIAS_BASE) &&
        (address <= KI_MAIN_RAM_ALIAS_LAST))
      return STORE_MAIN +
          (address[27:0] - KI_MAIN_RAM_ALIAS_BASE[27:0]);
    return STORE_BOOT +
        (address[27:0] - KI_BOOT_BASE[27:0]);
  endfunction

  always_comb begin
    read_buffer_next = read_buffer;
    // read_word_index counts 16-BIT WORDS and steps by two, so it names the
    // position in the 64-bit word, and everything counted in words -
    // read_words_remaining, memory_word_address - is unaffected.
    case (read_word_index[1])
      1'b0: read_buffer_next[31:0]  = sdram_read_data;
      1'b1: read_buffer_next[63:32] = sdram_read_data;
    endcase

    ioctl_wait = rom_download &&
        (download_count >= DOWNLOAD_FIFO_HIGH_WATER);
  end

  // Absorbable: a full-mask 64-bit write to ordinary memory that either
  // starts a line (32-byte aligned, so the burst cannot cross a DRAM row) or
  // continues the one being held. The boot-table window is excluded so the
  // snoop in SDRAM_WRITE_WAIT still sees every store there.
  wire wb_gather_ok =
      WB_GATHER && have_cpu && !active_rnw && !active_line_write &&
      active_req64 && (active_write_mask == 8'hff) &&
      !io_selected && !cpu_hits_fb &&
      is_memory_address(active_address) &&
      !is_boot_address(active_address) &&
      !((active_address >= 32'h087f_f000) &&
        (active_address <= 32'h087f_ffff)) &&
      ((wb_count == 3'd0)
           ? (active_word_address[3:0] == 4'd0)
           : ((wb_count < 3'd4) &&
              (active_word_address ==
               (wb_addr + {20'd0, wb_count, 2'b00}))));

  // A whole line handed over in one request. Anything held from gathering
  // goes out first - wb_flush_needed below covers that, because a line write
  // is not wb_gather_ok.
  wire line_req =
      have_cpu && !active_rnw && active_line_write &&
      !io_selected && !cpu_hits_fb &&
      is_memory_address(active_address) &&
      !is_boot_address(active_address);

  // The same, into the framebuffer. line_req refuses it (!cpu_hits_fb) because
  // the burst path is SDRAM's; this is the on-chip RAM's own path.
  wire fb_line_req =
      have_cpu && !active_rnw && active_line_write &&
      cpu_hits_fb;

  // Anything else that needs the bus, a full line, or a line left sitting
  // too long, forces the held chunks out first.
  wire wb_flush_needed =
      (wb_count == 3'd4) ||
      ((wb_count != 3'd0) &&
       ((download_count != 0) || wb_idle[5] ||
        (have_cpu && !wb_gather_ok)));

  always_ff @(posedge clk) begin
    boot_cache_read_data <= boot_cache[boot_cache_read_address];
  end

`ifndef SYNTHESIS
  // A line write to an address the burst path cannot take would fall through
  // to the ordinary single-write path and go out as 64 bits, losing 24 of its
  // 32 bytes. The data cache only ever writes back cached memory, so this
  // cannot happen - but it would be silent if it did.
  //
  // Address-only, and deliberately NOT the active_* signals line_req uses:
  // those follow whichever request is PENDING, so an earlier framebuffer or
  // I/O request in flight would make this fire on a perfectly good
  // write-back. line_req's other terms - video's turn, a request already
  // pending - are deferrals, not errors.
  //
  // The framebuffer is not on this list: FB_LINE_WRITE takes a line written
  // back into it, which a cached framebuffer produces on every dirty line.
  always_ff @(posedge clk) begin
    if (!reset && cpu_request && cpu_line_write &&
        (cpu_rnw || !is_memory_address(cpu_address) ||
         is_boot_address(cpu_address))) begin
      $error("bridge: line write to %08h that the burst path cannot take", cpu_address);
      $fatal(1);
    end
  end

  // Every burst this bridge issues is an even number of words, so a beat with
  // only its low half valid would mean the word accounting has gone wrong -
  // read_words_remaining steps by two and would run past zero. The odd tail
  // ki_sdram_x2 can produce belongs to the BIST's single-word probe alone.
  always_ff @(posedge clk) begin
    if (!reset && sdram_data_valid && (sdram_read_be !== 2'b11)) begin
      $error("bridge: half-width SDRAM beat (be=%b) - the burst was odd",
             sdram_read_be);
      $fatal(1);
    end
  end
`endif

  always_ff @(posedge clk) begin
    cpu_done <= 1'b0;
    cpu_grant <= 1'b0;
    cpu_cache_data_ready <= 1'b0;
    video_data_valid <= 1'b0;
    video_done <= 1'b0;
    io_request <= 1'b0;
    fb_we <= 1'b0;
    fb_read_accept <= 1'b0;
    fb_write_accept <= 1'b0;
    sdram_read <= 1'b0;
    sdram_write <= 1'b0;

    if ((wb_count != 3'd0) && !wb_idle[5]) wb_idle <= wb_idle + 1'b1;

    // Line-fill beats land straight in the buffer, one per clock, exactly as
    // the CPU read path assembles its own beats below.
    if (sdram_data_valid && (state == ROM_LINE_FILL_WAIT)) begin
      rom_line[rom_fill_index] <= sdram_read_data[15:0];
      rom_line[rom_fill_index + 4'd1] <= sdram_read_data[31:16];
      rom_fill_index <= rom_fill_index + 4'd2;
    end

    // Burst beats arrive independently of the state machine's own progress:
    // the adapter streams them out of the controller's CAS pipeline, one per
    // clock, and only afterwards raises sdram_done. Assembling them here keeps
    // the read states responsible for issuing and completing, nothing else.
    if (sdram_data_valid && (state == SDRAM_READ_WAIT)) begin
      read_buffer <= read_buffer_next;
      read_word_index <= read_word_index + 2'd2;
      read_words_remaining <= read_words_remaining - 5'd2;
      memory_word_address <= memory_word_address + 25'd2;

      if (!operation_req64) begin
        // A 32-bit read is two words, so it is complete on the FIRST beat.
        if (read_word_index == 2'd0)
          cpu_data_read <= {32'd0, read_buffer_next[31:0]};
      end else if (read_word_index == 2'd2) begin
        cpu_cache_data <= read_buffer_next;
        cpu_cache_data_ready <= 1'b1;
        cpu_data_read <= read_buffer_next;
        read_buffer <= 64'd0;
        fill_beat <= fill_beat + 1'b1;
      end
    end

    ddr_write_ack_sync1 <= ddr_write_ack_toggle;
    ddr_write_ack_sync2 <= ddr_write_ack_sync1;
    dcs_rom_done_sync1 <= dcs_rom_done_toggle;
    dcs_rom_done_sync2 <= dcs_rom_done_sync1;

    // DCS sound ROM, clk side. ready is a single-cycle pulse, so it is cleared
    // unconditionally here and set only on completion below.
    dcs_rom_ready <= 1'b0;
    if (!dcs_rom_request)
      dcs_rom_request_seen_level <= 1'b0;
    if (dcs_rom_request && !dcs_rom_inflight && !dcs_rom_request_seen_level) begin
      dcs_rom_mailbox_address <= dcs_rom_address;
      dcs_rom_request_toggle <= ~dcs_rom_request_toggle;
      dcs_rom_inflight <= 1'b1;
      dcs_rom_request_seen_level <= 1'b1;
    end
    if (dcs_rom_inflight && (dcs_rom_done_sync2 != dcs_rom_done_seen)) begin
      dcs_rom_done_seen <= dcs_rom_done_sync2;
      dcs_rom_data <= dcs_rom_mailbox_data;
      dcs_rom_ready <= 1'b1;
      dcs_rom_inflight <= 1'b0;
    end

    if (download_accept) begin
      case (incoming_download_address[2:1])
        2'd0: download_assembly_data[15:0] <= ioctl_dout;
        2'd1: download_assembly_data[31:16] <= ioctl_dout;
        2'd2: download_assembly_data[47:32] <= ioctl_dout;
        default: begin
          download_address[download_write_pointer] <=
              {incoming_download_address[27:3], 3'b000};
          download_data[download_write_pointer] <=
              {ioctl_dout, download_assembly_data};
          download_is_boot[download_write_pointer] <= boot_download;
          download_write_pointer <= download_write_pointer + 1'b1;
          if (boot_download && (ioctl_addr < BOOT_CACHE_BYTES))
            boot_cache[ioctl_addr[12:3]] <=
                {ioctl_dout, download_assembly_data};
        end
      endcase
      if (boot_download) begin
        boot_seen <= 1'b1;
        boot_loaded <= 1'b0;
      end
    end

    if (download_pop) begin
      download_read_pointer <= download_read_pointer + 1'b1;
      download_inflight <= 1'b0;
      if (download_ddr_pop)
        ddr_write_ack_seen <= ddr_write_ack_sync2;
    end

    case ({download_push, download_pop})
      2'b10: download_count <= download_count + 1'b1;
      2'b01: download_count <= download_count - 1'b1;
      default: download_count <= download_count;
    endcase

    if (boot_seen && !ioctl_download &&
        (download_count == 0) && !download_inflight &&
        (state == IDLE))
      boot_loaded <= 1'b1;

    if (cpu_request && !cpu_pending && !reset) begin
      cpu_pending <= 1'b1;
      pending_rnw <= cpu_rnw;
      pending_address <= cpu_address;
      pending_req64 <= cpu_req64;
      pending_size <= cpu_size;
      pending_write_mask <= cpu_write_mask;
      pending_data_write <= cpu_data_write;
      pending_line_write <= cpu_line_write;
      pending_line_data <= cpu_line_data;
      pending_line_bytes <= cpu_line_bytes;
    end

    if (reset && (download_count == 0) && !ioctl_download) begin
      state <= IDLE;
      cpu_pending <= 1'b0;
      cpu_data_read <= 64'hffff_ffff_ffff_ffff;
      cpu_cache_data <= 64'd0;
      video_data <= 64'd0;
      io_write <= 1'b0;
      io_address <= 32'd0;
      io_write_data <= 32'd0;
      io_byte_enable <= 4'd0;
      memory_word_address <= 25'd0;
      memory_word_count <= 3'd0;
      read_beats_remaining <= 3'd0;
      read_word_index <= 2'd0;
      read_words_remaining <= 5'd0;
      sdram_burst <= 5'd1;
      wb_count <= 3'd0;
      wb_idle <= 6'd0;
      rom_line_valid <= 1'b0;
      rom_fill_index <= 4'd0;
      boot_rom_return_state <= IDLE;
      boot_rom_wait_cycles <= 9'd0;
      dcs_rom_inflight <= 1'b0;
      dcs_rom_request_seen_level <= 1'b0;
      dcs_rom_done_seen <= dcs_rom_done_sync2;
      dcs_rom_data <= 64'd0;
      read_buffer <= 64'd0;
      vid_state <= VID_IDLE;
      vid_left <= 3'd0;
    end else begin
      // Scanout, on its own port. Runs concurrently with the state machine
      // below and shares nothing with it.
      case (vid_state)
        VID_IDLE: begin
          // A Port-A write asserted on the previous cycle completes at this
          // edge. Let it retire before starting the next scanout request.
          if (video_request && !video_done && !fb_we) begin
            fb_vaddr <= fb_index({4'd0, video_address});
            vid_left <= (video_words == 3'd0) ? 3'd4 : video_words;
            vid_state <= VID_ISSUE;
          end
        end

        // ISSUE, not WAIT: fb_vaddr is registered here, so the memory does not
        // see it until the next edge and vid_q is not valid until the one
        // after. Going straight to the capture state would take the PREVIOUS
        // request's last word - four wrong pixels at the start of a line.
        VID_ISSUE: begin
          // Port A performs the write one cycle after FB_WRITE asserts fb_we.
          // If scanout is issuing that same qword now, hold the address for a
          // clean cycle instead of accepting undefined mixed-port read data.
          if (fb_we && (fb_addr == fb_vaddr))
            vid_state <= VID_ISSUE;
          else
            vid_state <= VID_WAIT;
        end

        VID_WAIT: begin
          video_data <= fb_vq;
          video_data_valid <= 1'b1;
          fb_vaddr <= fb_vaddr + 16'd1;
          if (vid_left <= 3'd1) begin
            vid_state <= VID_DONE;
          end else begin
            vid_left <= vid_left - 3'd1;
            vid_state <= VID_ISSUE;
          end
        end

        default: begin
          video_done <= 1'b1;
          vid_state <= VID_IDLE;
        end
      endcase

      case (state)
        IDLE: begin
          if (wb_flush_needed) begin
            state <= SDRAM_WB_FLUSH_ISSUE;
          end else if (line_req) begin
            // Load the holding registers with the whole line and send it as
            // one 16-word burst. Acknowledged here, like an absorbed chunk:
            // nothing can read past it, because every other requester
            // flushes first.
            wb_addr <= active_word_address;
            wb_data <= active_line_data;
            // Per qword: a data-cache line whose store-miss fill was skipped
            // holds nothing for the qwords it never stored, and SDRAM does.
            // A whole line is one burst; anything less is split, see wb_split.
            wb_be <= {32{1'b1}};
            wb_split <= (active_write_mask[3:0] != 4'b1111);
            wb_qmask <= active_write_mask[3:0];
            wb_count <= 3'd4;
            wb_idle <= 6'd0;
            cpu_pending <= 1'b0;
            cpu_done <= 1'b1;
            state <= SDRAM_WB_FLUSH_ISSUE;
            // Four 64-bit writes' worth, so the counters count the same as
            // four separate transactions.
            debug_write_count <= debug_write_count + 32'd4;
            if ((active_address >= KI_LOW_RAM_BASE) &&
                (active_address <= KI_LOW_RAM_LAST))
              debug_low_write_count <= debug_low_write_count + 32'd4;
            else
              debug_main_write_count <= debug_main_write_count + 32'd4;
          end else if (fb_line_req) begin
            // Acknowledged here, as the SDRAM line path above is, and safe for
            // the same reason: the state machine is serial, so no CPU read of
            // this line can be served before FB_LINE_WRITE has finished.
            fb_line_data    <= active_line_data;
            fb_line_base    <= fb_index(active_address);
            fb_line_qmask   <= active_write_mask[3:0];
            fb_line_bytes   <= active_line_bytes;
            fb_line_k       <= 2'd0;
            fb_write_accept <= 1'b1;
            cpu_pending     <= 1'b0;
            cpu_done        <= 1'b1;
            state           <= FB_LINE_WRITE;
            debug_write_count     <= debug_write_count + 32'd4;
            debug_low_write_count <= debug_low_write_count + 32'd4;
          end else if (wb_gather_ok) begin
            // Absorb and acknowledge in the same cycle. Nothing can read
            // past this data because every other requester flushes first.
            if (wb_count == 3'd0) wb_addr <= active_word_address;
            wb_data[{wb_count[1:0], 6'd0} +: 64] <= active_data_write;
            wb_be[{wb_count[1:0], 3'd0} +: 8] <= active_write_mask;
            wb_count <= wb_count + 1'b1;
            wb_idle <= 6'd0;
            cpu_pending <= 1'b0;
            cpu_done <= 1'b1;
            // The write counters must not notice the difference.
            debug_write_count <= debug_write_count + 1'b1;
            if ((active_address >= KI_LOW_RAM_BASE) &&
                (active_address <= KI_LOW_RAM_LAST))
              debug_low_write_count <= debug_low_write_count + 1'b1;
            else
              debug_main_write_count <= debug_main_write_count + 1'b1;
          end else if (download_count != 0) begin
            if (!download_inflight) begin
              if (download_is_boot[download_read_pointer]) begin
                memory_word_address <= {
                  download_address[download_read_pointer][25:3],
                  2'b00
                };
                download_inflight <= 1'b1;
                state <= DOWNLOAD_SDRAM_WRITE_ISSUE;
              end else begin
                ddr_write_mailbox_address <= {
                  4'b0011,
                  download_address[download_read_pointer][27:3]
                };
                ddr_write_mailbox_data <=
                    download_data[download_read_pointer];
                ddr_write_mailbox_be <= 8'hff;
                ddr_write_request_toggle <=
                    ~ddr_write_request_toggle;
                download_inflight <= 1'b1;
              end
            end
          end else if (have_cpu && !active_line_write) begin
            // !active_line_write: a whole-line write belongs to the burst path
            // above and nowhere else. Without this it could be served here as
            // an ordinary 64-bit write - storing 8 of its 32 bytes and
            // acknowledging - if line_req ever refused it. It cannot: the data
            // cache only writes back cached memory. But the failure mode
            // matters, so make it a stall the assertion below names rather
            // than silent corruption.
            //
            // In simulation, every condition that could reach this branch with
            // a line write - an address line_req refuses - trips that
            // assertion first. The term earns its place in hardware, where
            // there is no assertion and a stall is diagnosable where lost bytes
            // are not.
            operation_address <= active_address;
            operation_req64 <= active_req64;
            operation_write_mask <= active_write_mask;
            operation_write_data <= active_data_write;

            if (io_selected) begin
              io_request <= 1'b1;
              io_write <= !active_rnw;
              io_address <= active_address;
              io_write_data <= active_data_write[31:0];
              io_byte_enable <= active_write_mask[3:0];
              state <= IO_WAIT;
            end else if (is_memory_address(active_address)) begin
              read_buffer <= 64'd0;
              read_word_index <= 2'd0;
              read_words_remaining <= active_read_words;
              fill_beat <= 2'd0;
              // The framebuffer window is served entirely from on-chip memory,
              // so it is checked before every SDRAM path below.
              if (cpu_hits_fb) begin
                fb_read_accept  <= active_rnw;
                fb_write_accept <= !active_rnw;
                fb_addr <= fb_index(active_address);
                fb_qwords_left <=
                    (active_read_words < 5'd4) ? 3'd1 : active_read_words[4:2];
                if (active_rnw) begin
                  cpu_grant <= 1'b1;
                  state <= FB_READ_ISSUE;
                end else begin
                  state <= FB_WRITE;
                end
              end else if (active_boot_cache_read) begin
                boot_cache_read_address <= active_address[12:3];
                read_beats_remaining <= active_req64 ?
                    active_read_beats : 3'd1;
                cpu_grant <= 1'b1;
                boot_rom_return_state <= BOOT_CACHE_READ_WAIT;
                boot_rom_wait_cycles <=
                    {active_read_words, {BOOT_ROM_WAIT_SHIFT{1'b0}}};
                state <= BOOT_ROM_ACCESS_WAIT;
              end else if (active_req64) begin
                memory_word_address <=
                    {active_storage_address[25:3], 2'b00};
                memory_word_count <= 3'd4;
              end else begin
                memory_word_address <=
                    {active_storage_address[25:2], 1'b0};
                memory_word_count <= 3'd2;
              end

              rom_line_offset <= active_word_address[3:0];
              rom_pending_tag <= active_word_address[24:4];

              if (cpu_hits_fb) begin
                // The framebuffer branch above already selected its state.
                // This second chain runs in the same cycle, so without the
                // guard it overwrites that choice and the access falls through
                // to SDRAM.
              end else if (active_boot_cache_read) begin
                // The cache-read branch above already selected its state.
              end else if (active_rom_line_eligible) begin
                // A hit answers straight out of the line buffer; a miss pulls
                // the whole 16-word line in one burst and then answers from
                // it, so the next 31 byte reads of that line cost nothing on
                // the SDRAM bus.
                cpu_grant <= 1'b1;
                boot_rom_return_state <=
                    rom_line_hit ? ROM_LINE_RETURN : ROM_LINE_FILL_ISSUE;
                boot_rom_wait_cycles <=
                    {active_read_words, {BOOT_ROM_WAIT_SHIFT{1'b0}}};
                state <= BOOT_ROM_ACCESS_WAIT;
              end else if (active_rnw) begin
                // read_words_remaining, not read_beats_remaining: the burst
                // covers every beat of the request in one or two requests.
                cpu_grant <= 1'b1;
                if (is_boot_address(active_address)) begin
                  boot_rom_return_state <= SDRAM_READ_ISSUE;
                  boot_rom_wait_cycles <=
                      {active_read_words, {BOOT_ROM_WAIT_SHIFT{1'b0}}};
                  state <= BOOT_ROM_ACCESS_WAIT;
                end else begin
                  state <= SDRAM_READ_ISSUE;
                end
              end else if (is_boot_address(active_address)) begin
                cpu_pending <= 1'b0;
                cpu_done <= 1'b1;
              end else begin
                state <= SDRAM_WRITE_ISSUE;
              end
            end else begin
              cpu_pending <= 1'b0;
              cpu_data_read <= 64'hffff_ffff_ffff_ffff;
              cpu_done <= 1'b1;
            end
          end
        end

        BOOT_CACHE_READ_WAIT: begin
          state <= BOOT_CACHE_READ_RETURN;
        end

        BOOT_ROM_ACCESS_WAIT: begin
          if (boot_rom_wait_cycles <= 9'd1) begin
            boot_rom_wait_cycles <= 9'd0;
            state <= boot_rom_return_state;
          end else begin
            boot_rom_wait_cycles <= boot_rom_wait_cycles - 1'b1;
          end
        end

        BOOT_CACHE_READ_RETURN: begin
          if (operation_req64) begin
            cpu_cache_data <= boot_cache_read_data;
            cpu_cache_data_ready <= 1'b1;
            cpu_data_read <= boot_cache_read_data;
          end else begin
            cpu_data_read <= operation_address[2] ?
                {32'd0, boot_cache_read_data[63:32]} :
                {32'd0, boot_cache_read_data[31:0]};
          end

          if (read_beats_remaining <= 1) begin
            read_beats_remaining <= 3'd0;
            cpu_done <= 1'b1;
            cpu_pending <= 1'b0;
            state <= IDLE;
          end else begin
            read_beats_remaining <= read_beats_remaining - 1'b1;
            boot_cache_read_address <= boot_cache_read_address + 1'b1;
            state <= BOOT_CACHE_READ_WAIT;
          end
        end

        // One 4-word burst per downloaded 64-bit word instead of four
        // transactions, which matters across a boot ROM of ~256K words.
        DOWNLOAD_SDRAM_WRITE_ISSUE: begin
          if (sdram_ready) begin
            // The ROM is only immutable AFTER it is loaded, so any download
            // write drops the line buffer. Without this a core reload could
            // serve a previous ROM's bytes.
            rom_line_valid <= 1'b0;
            sdram_address <= memory_word_address;
            sdram_write_data <= {192'd0, download_data[download_read_pointer]};
            sdram_byte_enable <= 32'h0000_00ff;
            sdram_burst <= 5'd4;
            sdram_write <= 1'b1;
            state <= DOWNLOAD_SDRAM_WRITE_WAIT;
          end
        end

        DOWNLOAD_SDRAM_WRITE_WAIT: begin
          if (sdram_done)
            state <= IDLE;
        end

        // Pull one naturally aligned 16-word line. 16-word alignment also
        // guarantees the burst cannot cross the controller's 512-word row.
        ROM_LINE_FILL_ISSUE: begin
          if (sdram_ready) begin
            sdram_address <= {rom_pending_tag, 4'b0000};
            sdram_burst <= 5'd16;
            sdram_read <= 1'b1;
            rom_fill_index <= 4'd0;
            state <= ROM_LINE_FILL_WAIT;
          end
        end

        ROM_LINE_FILL_WAIT: begin
          if (sdram_done) begin
            rom_line_tag <= rom_pending_tag;
            rom_line_valid <= 1'b1;
            state <= ROM_LINE_RETURN;
          end
        end

        ROM_LINE_RETURN: begin
          if (operation_req64) begin
            cpu_cache_data <= {
              rom_line[rom_line_offset + 4'd3],
              rom_line[rom_line_offset + 4'd2],
              rom_line[rom_line_offset + 4'd1],
              rom_line[rom_line_offset]
            };
            cpu_cache_data_ready <= 1'b1;
            cpu_data_read <= {
              rom_line[rom_line_offset + 4'd3],
              rom_line[rom_line_offset + 4'd2],
              rom_line[rom_line_offset + 4'd1],
              rom_line[rom_line_offset]
            };
          end else begin
            cpu_data_read <= {
              32'd0,
              rom_line[rom_line_offset + 4'd1],
              rom_line[rom_line_offset]
            };
          end
          cpu_done <= 1'b1;
          cpu_pending <= 1'b0;
          state <= IDLE;
        end

        SDRAM_READ_ISSUE: begin
          if (sdram_ready) begin
            sdram_address <= memory_word_address;
            sdram_burst <= next_burst;
            sdram_read <= 1'b1;
            state <= SDRAM_READ_WAIT;
          end
        end

        // Beats are assembled by the sdram_data_valid block above. All this
        // has to decide, at sdram_done, is whether the operation still owes
        // words - which happens only when a row boundary split the request.
        SDRAM_READ_WAIT: begin
          if (sdram_done) begin
            if (read_words_left_next == 0) begin
              cpu_done <= 1'b1;
              cpu_pending <= 1'b0;
              state <= IDLE;
            end else begin
              state <= SDRAM_READ_ISSUE;
            end
          end
        end

        // Everything held goes out as one burst: wb_count chunks is
        // wb_count * 4 words, and the line is 32-byte aligned so it cannot
        // cross a row.
        SDRAM_WB_FLUSH_ISSUE: begin
          if (wb_split && wb_qmask == 4'd0) begin
            // A line with no qword to write: nothing goes out.
            wb_count <= 3'd0;
            wb_idle <= 6'd0;
            wb_split <= 1'b0;
            state <= IDLE;
          end else if (sdram_ready) begin
            if (!wb_split) begin
              sdram_address <= wb_addr;
              sdram_write_data <= wb_data;
              sdram_byte_enable <= wb_be;
              sdram_burst <= {wb_count, 2'b00};
            end else begin : wb_split_issue
              // The lowest qword still to write, as its own full burst.
              logic [1:0] k;
              casez (wb_qmask)
                4'b???1: k = 2'd0;
                4'b??10: k = 2'd1;
                4'b?100: k = 2'd2;
                default: k = 2'd3;
              endcase
              sdram_address <= wb_addr + {20'd0, k, 2'b00};
              sdram_write_data <= {192'd0, wb_data[{k, 6'd0} +: 64]};
              sdram_byte_enable <= 32'h0000_00ff;
              sdram_burst <= 5'd4;
              wb_qmask[k] <= 1'b0;
            end
            sdram_write <= 1'b1;
            state <= SDRAM_WB_FLUSH_WAIT;
          end
        end

        SDRAM_WB_FLUSH_WAIT: begin
          if (sdram_done) begin
            if (wb_split && wb_qmask != 4'd0) begin
              state <= SDRAM_WB_FLUSH_ISSUE;
            end else begin
              wb_count <= 3'd0;
              wb_idle <= 6'd0;
              wb_split <= 1'b0;
              state <= IDLE;
            end
          end
        end

        // One burst per store when it writes every byte it covers. Anything
        // narrower reads first: see wr_mask_full.
        SDRAM_WRITE_ISSUE: begin
          if (sdram_ready) begin
            if (!wr_mask_full) begin
              sdram_address <= memory_word_address;
              sdram_burst <= {2'd0, memory_word_count};
              sdram_read <= 1'b1;
              rmw_index <= 2'd0;
              rmw_read <= 64'd0;
              state <= SDRAM_WRITE_RMW_WAIT;
            end else begin
              sdram_address <= memory_word_address;
              sdram_write_data <= {192'd0, operation_write_data};
              // Every byte of every word in the burst, which is what
              // wr_mask_full just established. Spelled as a constant rather
              // than passed through so that NO write this bridge issues ever
              // asks the device to mask a byte - a thing this board does not
              // do.
              sdram_byte_enable <= operation_req64 ? 32'h0000_00ff : 32'h0000_000f;
              sdram_burst <= {2'd0, memory_word_count};
              sdram_write <= 1'b1;
              state <= SDRAM_WRITE_WAIT;
            end
          end
        end

        // The read half. Its beats are captured here rather than in the
        // sdram_data_valid block above, which assembles CPU reads: this data
        // never reaches the CPU, it only fills in the bytes the store does
        // not write.
        SDRAM_WRITE_RMW_WAIT: begin
          if (sdram_data_valid) begin
            rmw_read[{rmw_index[1], 5'd0} +: 32] <= sdram_read_data;
            rmw_index <= rmw_index + 2'd2;
          end
          if (sdram_done) state <= SDRAM_WRITE_RMW_ISSUE;
        end

        // The write half: every byte of every word, so nothing depends on the
        // mask reaching the device.
        SDRAM_WRITE_RMW_ISSUE: begin
          if (sdram_ready) begin
            sdram_address <= memory_word_address;
            sdram_write_data <= {192'd0, rmw_merged};
            sdram_byte_enable <= operation_req64 ? 32'h0000_00ff : 32'h0000_000f;
            sdram_burst <= {2'd0, memory_word_count};
            sdram_write <= 1'b1;
            state <= SDRAM_WRITE_WAIT;
          end
        end

        SDRAM_WRITE_WAIT: begin
          if (sdram_done) begin
            cpu_pending <= 1'b0;
            cpu_done <= 1'b1;
            debug_write_count <= debug_write_count + 1'b1;
            if ((operation_address >= KI_LOW_RAM_BASE) &&
                (operation_address <= KI_LOW_RAM_LAST))
              debug_low_write_count <=
                  debug_low_write_count + 1'b1;
            if (((operation_address >= KI_MAIN_RAM_BASE) &&
                 (operation_address <= KI_MAIN_RAM_LAST)) ||
                ((operation_address >= KI_MAIN_RAM_ALIAS_BASE) &&
                 (operation_address <= KI_MAIN_RAM_ALIAS_LAST)))
              debug_main_write_count <=
                  debug_main_write_count + 1'b1;
            state <= IDLE;
          end
        end

        IO_WAIT: begin
          if (io_done) begin
            cpu_data_read <= {32'hffff_ffff, io_read_data};
            cpu_done <= 1'b1;
            cpu_pending <= 1'b0;
            state <= IDLE;
          end else begin
            io_request <= 1'b1;
          end
        end

        // One 64-bit word per two cycles on port A: present the address, then
        // take the registered output. No SDRAM is involved.
        FB_READ_ISSUE: begin
          state <= FB_READ_WAIT;
        end

        FB_READ_WAIT: begin
          if (operation_req64) begin
            cpu_cache_data <= fb_q;
            cpu_cache_data_ready <= 1'b1;
            cpu_data_read <= fb_q;
          end else begin
            // A 32-bit access takes the half its address selects, matching
            // what the SDRAM path assembles from two 16-bit words.
            cpu_data_read <= operation_address[2] ?
                {32'd0, fb_q[63:32]} : {32'd0, fb_q[31:0]};
          end
          if (fb_qwords_left <= 3'd1) begin
            cpu_done <= 1'b1;
            cpu_pending <= 1'b0;
            state <= IDLE;
          end else begin
            fb_qwords_left <= fb_qwords_left - 3'd1;
            fb_addr <= fb_addr + 16'd1;
            state <= FB_READ_ISSUE;
          end
        end

        // One block-RAM cycle. This is the store the game's per-frame blit
        // repeats 19,200 times.
        FB_WRITE: begin
          fb_we <= 1'b1;
          fb_addr <= fb_index(operation_address);
          // A sub-64-bit store arrives with its data in [31:0] and its mask in
          // [3:0], and the HALF it belongs to encoded in address bit 2 - a
          // 32-bit store to 0x08000004 lands at byte offset 4 in SDRAM. The
          // SDRAM path carries that bit in the
          // word address it issues ({storage[25:2], 1'b0}); this store cannot,
          // because fb_index is 8-byte granular (bits 18:3), so the selection
          // has to move into the data and the byte enables instead.
          if (operation_req64) begin
            fb_wdata <= operation_write_data;
            fb_wbe <= operation_write_mask;
          end else if (operation_address[2]) begin
            fb_wdata <= {operation_write_data[31:0], 32'd0};
            fb_wbe <= {operation_write_mask[3:0], 4'd0};
          end else begin
            fb_wdata <= {32'd0, operation_write_data[31:0]};
            fb_wbe <= {4'd0, operation_write_mask[3:0]};
          end
          cpu_done <= 1'b1;
          cpu_pending <= 1'b0;
          debug_write_count <= debug_write_count + 1'b1;
          state <= IDLE;
        end

        // Four block-RAM cycles, one qword each. A qword the line does not
        // hold is written with no byte enables, which the RAM ignores; that
        // keeps the timing fixed rather than data-dependent. Scanout's port
        // already waits out a cycle with fb_we set and retries a same-word
        // collision, so four in a row need nothing new on that side.
        FB_LINE_WRITE: begin
          fb_we    <= 1'b1;
          fb_addr  <= fb_line_base + {14'd0, fb_line_k};
          fb_wdata <= fb_line_data[{fb_line_k, 6'd0} +: 64];
          fb_wbe   <= {8{fb_line_qmask[fb_line_k]}} & fb_line_bytes[{fb_line_k, 3'd0} +: 8];
          fb_line_k <= fb_line_k + 2'd1;
          if (fb_line_k == 2'd3)
            state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  // MiSTer's DDR interface is serviced at 100 MHz, matching the proven
  // Aleck64/N64 arrangement. Complete read bursts are captured here before
  // they are exposed to the 50 MHz CPU cache domain. Commands remain asserted
  // with stable payloads until BUSY is low on a following clock edge; this is
  // the acceptance contract used by MiSTer's DDR frontend.
  always_ff @(posedge ddr_clk) begin
    ddr_write_request_sync1 <= ddr_write_request_toggle;
    ddr_write_request_sync2 <= ddr_write_request_sync1;
    dcs_rom_request_sync1 <= dcs_rom_request_toggle;
    dcs_rom_request_sync2 <= dcs_rom_request_sync1;

    case (ddr_service_state)
      DDR_SERVICE_IDLE: begin
        ddram_rd <= 1'b0;
        ddram_we <= 1'b0;
        if (ddr_write_request_sync2 != ddr_write_request_seen) begin
          ddram_addr <= ddr_write_mailbox_address;
          ddram_din <= ddr_write_mailbox_data;
          ddram_be <= ddr_write_mailbox_be;
          ddram_burstcnt <= 8'd1;
          ddram_we <= 1'b1;
          ddr_service_state <= DDR_SERVICE_WRITE;
        end else if (dcs_rom_request_sync2 != dcs_rom_request_seen) begin
          // The DCS banks sit at STORE_DCS. dcs_rom_address is a 64-bit WORD
          // index into them, and ddram_addr is also a qword address, so the
          // base is STORE_DCS[27:3] and the index adds directly.
          ddram_addr <= {4'b0011, STORE_DCS[27:3]} +
              {{10{1'b0}}, dcs_rom_mailbox_address};
          ddram_burstcnt <= 8'd1;
          ddram_be <= 8'hff;
          ddram_rd <= 1'b1;
          ddr_service_state <= DDR_SERVICE_DCS_ISSUE;
        end
      end

      DDR_SERVICE_WRITE: begin
        ddram_we <= 1'b1;
        if (!ddram_busy) begin
          ddram_we <= 1'b0;
          ddr_write_request_seen <= ddr_write_request_sync2;
          ddr_write_ack_toggle <= ~ddr_write_ack_toggle;
          ddr_service_state <= DDR_SERVICE_IDLE;
        end
      end

      DDR_SERVICE_DCS_ISSUE: begin
        ddram_rd <= 1'b1;
        if (!ddram_busy) begin
          ddram_rd <= 1'b0;
          dcs_rom_request_seen <= dcs_rom_request_sync2;
          ddr_service_state <= DDR_SERVICE_DCS_READ;
        end
      end

      DDR_SERVICE_DCS_READ: begin
        if (ddram_dout_ready) begin
          dcs_rom_mailbox_data <= ddram_dout;
          dcs_rom_done_toggle <= ~dcs_rom_done_toggle;
          ddr_service_state <= DDR_SERVICE_IDLE;
        end
      end

    endcase
  end

  // M10K carries the early reset path and both exact framebuffer pages. SDRAM
  // carries the complete boot ROM and all other mutable CPU RAM. DDR3 carries
  // immutable DCS ROM.
endmodule

`default_nettype wire
