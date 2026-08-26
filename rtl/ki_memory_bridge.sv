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
  // 64-bit words this request asks for, 1..4. Four is SDRAM_MAX_BURST worth of
  // 16-bit words, so a full request is a single controller burst and scanout
  // pays one round trip per four qwords instead of one per qword.
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
  output logic [63:0] sdram_write_data,
  output logic  [7:0] sdram_byte_enable,
  // Words to transfer: reads 1..SDRAM_MAX_BURST, writes 1..4.
  output logic  [4:0] sdram_burst,
  output logic        sdram_read,
  output logic        sdram_write,
  input  wire  [15:0] sdram_read_data,
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
  // window, counted per frame at the top level. FB_READ is code this
  // rework added, and it has never been audited against the game's real
  // usage: if the blit does read-modify-write, a fault there does not just
  // return bad data to the CPU, it makes the CPU write CORRUPTED pixels
  // back. That would look like 4-pixel blocks of plausible neighbouring
  // content, intermittent, tied to CPU activity, with every scanout beat
  // arriving perfectly and VC reading clean - which is exactly what the
  // hardware shows.
  //
  // If the read count is zero the theory dies in one reading.
  output logic        fb_read_accept,
  output logic        fb_write_accept,
  output wire   [2:0] debug_state,
  // The four 64-bit beats of the cache-line fill for the line the hardware
  // fails in, captured as the bridge delivers them.
  //
  // The line base is 0x08028DC0 (CPU 0x88028DC0), which holds the video blit
  // loop. Hardware shows beat 0 delivered CORRECTLY - QO read DC650000, the
  // real ld at 88028DC4 - while the instruction at 88028DCC, in beat 1, came
  // back 0BF000E2 instead of 24420008. So one 64-bit beat of a four-beat fill
  // is wrong and its neighbour is right.
  //
  // Every path from the SDRAM device up to the instruction cache has been
  // checked by inspection and is clean, so this stops inferring and captures
  // what the bridge actually hands over. If the bad beat holds framebuffer
  // pixels, that names the source outright.
  output logic [63:0] debug_fill_b0 = 64'd0,
  output logic [63:0] debug_fill_b1 = 64'd0,
  output wire         debug_cpu_pending,
  output logic [31:0] debug_last_write_address = 32'h0000_0000,
  output logic [63:0] debug_last_write_data = 64'h0000_0000_0000_0000,
  output logic [31:0] debug_last_write_info = 32'h0000_0000,
  output logic [31:0] debug_write_count = 32'h0000_0000,
  output logic [31:0] debug_low_write_count = 32'h0000_0000,
  output logic [31:0] debug_main_write_count = 32'h0000_0000,
  output logic [31:0] debug_main_write0 = 32'h0000_0000,
  output logic [31:0] debug_main_write1 = 32'h0000_0000,
  output logic [31:0] debug_main_write2 = 32'h0000_0000,

  // Passive snoop of CPU stores landing in the top 4 KiB of main RAM, where
  // the boot ROM builds its permutation tables. Real KI uses 0x087FFF10 and
  // 0x087FFF30, but the base comes from t3 so ours could differ - hence the
  // wider window. Snooping the existing write path means no bus conflict with
  // the running CPU, unlike ki_boot_verify's mux which is only safe while the
  // CPU is held in reset.
  //
  // TW is the running count. TA is the address of the FIRST non-zero store
  // into the window, and TD packs the first four non-zero bytes, newest in the
  // low byte. The initialiser writes 31 to base+0 then base+32, then 30 to
  // base+1 and base+33, so a healthy build must show:
  //
  //   TA = the table base, TD = 1F1F1E1E
  //
  // Anything else is the defect, and TA also pins down where our table
  // actually lives - the base comes from t3 and need not match real KI's
  // 0x087FFF10.
  output logic [31:0] debug_table_write_count = 32'h0000_0000,
  output logic [31:0] debug_table_write_address = 32'h0000_0000,
  output logic [31:0] debug_table_write_data = 32'h0000_0000
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

  // 17 states, so five bits. debug_state still exports the low three, which is
  // what the debug screen has always shown.
  typedef enum logic [4:0] {
    IDLE,
    BOOT_CACHE_READ_WAIT,
    BOOT_CACHE_READ_RETURN,
    SDRAM_READ_ISSUE,
    SDRAM_READ_WAIT,
    SDRAM_WRITE_ISSUE,
    SDRAM_WRITE_WAIT,
    IO_WAIT,
    VIDEO_READ_ISSUE,
    FB_READ_ISSUE,
    FB_READ_WAIT,
    FB_WRITE,
    VIDEO_READ_WAIT,
    DDR_READ_WAIT,
    DDR_READ_RETURN,
    DOWNLOAD_SDRAM_WRITE_ISSUE,
    DOWNLOAD_SDRAM_WRITE_WAIT,
    ROM_LINE_FILL_ISSUE,
    ROM_LINE_FILL_WAIT,
    ROM_LINE_RETURN
  } state_t;

  state_t state = IDLE;

  logic cpu_pending = 1'b0;
  logic pending_rnw = 1'b1;
  logic [31:0] pending_address = 32'd0;
  logic pending_req64 = 1'b0;
  logic [2:0] pending_size = 3'd1;
  logic [7:0] pending_write_mask = 8'd0;
  logic [63:0] pending_data_write = 64'd0;

  logic [31:0] operation_address = 32'd0;
  logic operation_req64 = 1'b0;
  logic [7:0] operation_write_mask = 8'd0;
  logic [63:0] operation_write_data = 64'd0;

  logic [24:0] memory_word_address = 25'd0;
  logic [2:0] memory_word_count = 3'd0;
  logic [2:0] read_beats_remaining = 3'd0;
  logic [63:0] read_buffer = 64'd0;
  logic [63:0] read_buffer_next;
  // Which 64-bit beat of the current fill is being delivered, and whether
  // this operation is the line under investigation.
  logic [1:0] dbg_fill_beat = 2'd0;
  logic       dbg_fill_match = 1'b0;
  logic video_won_last = 1'b0;

  // Burst read bookkeeping. `read_word_index` is the position inside the
  // 64-bit word being assembled; `read_words_remaining` is how much of the
  // whole operation is still outstanding, across however many bursts it takes.
  // The byte a store carries, picked out by its enables. `sb` sets exactly one.
  logic [7:0] store_byte;
  always_comb begin
    store_byte = 8'h00;
    for (int b = 0; b < 8; b++)
      if (operation_write_mask[b]) store_byte = operation_write_data[b*8 +: 8];
  end

  // How many of the first non-zero table-region writes have been captured.
  logic [2:0] table_capture_index = 3'd0;

  logic  [1:0] read_word_index = 2'd0;
  logic  [4:0] read_words_remaining = 5'd0;

  // Boot-ROM line buffer.
  //
  // The boot ROM addresses itself through 0xBFC0xxxx (KSEG1), which MIPS
  // defines as UNCACHED - `lui s4,0xBFC0` at 9FC007AC and `lui a1,0xBFC0` at
  // 9FC006A8 - so the CPU's data cache correctly refuses to cache it, and
  // hardware measured only 0.38% of transactions as line fills. The boot
  // decompressor at 9FC00DEC then walks the ROM ONE BYTE at a time, and a byte
  // load makes this bridge fetch the enclosing 32-bit word, so four
  // consecutive byte reads re-fetch the same two SDRAM words.
  //
  // Caching it HERE is architecturally invisible: the boot ROM is immutable
  // once downloaded, so there is nothing for the CPU's uncached semantics to
  // go stale against. One 16-word burst fill replaces up to 32 separate
  // ~293 ns transactions.
  localparam integer ROM_LINE_WORDS = 16;
  (* ramstyle = "logic" *)
  logic [15:0] rom_line [0:ROM_LINE_WORDS-1];
  logic [20:0] rom_line_tag = 21'h1fffff;
  logic rom_line_valid = 1'b0;
  logic [3:0] rom_fill_index = 4'd0;
  logic [20:0] rom_pending_tag = 21'd0;
  logic [3:0] rom_line_offset = 4'd0;

  // Reset execution reaches the first KI hardware register after only 589
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

  logic [28:0] ddr_read_mailbox_address = 29'd0;
  logic [2:0] ddr_read_mailbox_beats = 3'd1;
  logic ddr_read_request_toggle = 1'b0;
  logic ddr_read_done_toggle = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_read_done_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_read_done_sync2 = 1'b0;
  logic ddr_read_done_seen = 1'b0;
  logic [1:0] ddr_return_index = 2'd0;

  (* ASYNC_REG = "TRUE" *) logic ddr_write_request_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_write_request_sync2 = 1'b0;
  logic ddr_write_request_seen = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_read_request_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic ddr_read_request_sync2 = 1'b0;
  logic ddr_read_request_seen = 1'b0;

  // DCS sound ROM mailbox. Same shape as the CPU read mailbox above.
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
  logic [2:0] ddr_service_beats_remaining = 3'd0;
  logic [1:0] ddr_service_beat_index = 2'd0;
  logic [63:0] ddr_read_mailbox_data0 = 64'd0;
  logic [63:0] ddr_read_mailbox_data1 = 64'd0;
  logic [63:0] ddr_read_mailbox_data2 = 64'd0;
  logic [63:0] ddr_read_mailbox_data3 = 64'd0;

  // Three bits, not two: the DCS pair takes this to six members.
  typedef enum logic [2:0] {
    DDR_SERVICE_IDLE,
    DDR_SERVICE_WRITE,
    DDR_SERVICE_DCS_ISSUE,
    DDR_SERVICE_DCS_READ,
    DDR_SERVICE_READ_ISSUE,
    DDR_SERVICE_READ
  } ddr_service_state_t;
  ddr_service_state_t ddr_service_state = DDR_SERVICE_IDLE;

  wire boot_download = ioctl_download && (ioctl_index == 16'h0001);
  wire sound_download = ioctl_download &&
      (ioctl_index >= 16'h0002) && (ioctl_index <= 16'h0009);
  wire rom_download = boot_download || sound_download;
  wire [27:0] sound_bank_offset =
      (({12'h000, ioctl_index} - 28'd2) << 19);
  wire [27:0] incoming_download_address = boot_download ?
      (STORE_BOOT + ioctl_addr) :
      (STORE_DCS + sound_bank_offset + ioctl_addr);
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
  wire active_rnw = cpu_pending ? pending_rnw : cpu_rnw;
  wire [31:0] active_address =
      cpu_pending ? pending_address : cpu_address;
  wire active_req64 = cpu_pending ? pending_req64 : cpu_req64;
  wire [2:0] active_size = cpu_pending ? pending_size : cpu_size;
  wire [7:0] active_write_mask =
      cpu_pending ? pending_write_mask : cpu_write_mask;
  wire [63:0] active_data_write =
      cpu_pending ? pending_data_write : cpu_data_write;

  wire io_selected =
      ((active_address >= KI_IO_BASE) &&
       (active_address <= KI_IO_LAST)) ||
      ((active_address >= KI_ATA_CS0_BASE) &&
       (active_address <= KI_ATA_CS0_LAST)) ||
      ((active_address >= KI_ATA_CS1_ADDR) &&
       (active_address <= (KI_ATA_CS1_ADDR + 3)));

  wire [27:0] active_storage_address =
      storage_address(active_address);
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

  // 16-bit words a scanout request covers: four per 64-bit word. Zero is
  // treated as one qword so an unconnected port cannot issue an empty burst
  // and hang the video port waiting for beats that never come.
  wire [4:0] video_read_words =
      (video_words >= 3'd4) ? SDRAM_MAX_BURST :
      (video_words == 3'd0) ? 5'd4 :
                              ({2'd0, video_words} << 2);

  // Words this operation still owes after the beat currently on the wire.
  wire [4:0] read_words_left_next = sdram_data_valid ?
      (read_words_remaining - 1'b1) : read_words_remaining;

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
  // Scanout and the CPU shared one SDRAM port, and that sharing is what the
  // intro-video corruption correlates with: the failure only ever appears while
  // the full-frame blit, continuous scanout and disk streaming are all in
  // flight together. There is no need to share, so scanout gets its own port.
  //
  // Both framebuffer pages live in low RAM, page 0 at 0x30000 and page 1 at
  // 0x58000, 320x240x2 = 150 KiB each. They are compacted into 38400 64-bit
  // words. The holes 0x55800-0x57fff and 0x7d800-0x7ffff remain SDRAM.
  //
  // This memory is authoritative for those exact pages. CPU reads, CPU writes
  // and scanout are all served from here, so there is exactly one copy and no
  // coherency question. The CPU-visible memory map does not change.
  //
  // A write-through mirror was tried first and only removed scanout READS from
  // SDRAM, about 9 MB/s. It left the heavier traffic - the 153,600-byte blit
  // the game runs every frame - still paying a full SDRAM activate/write/
  // precharge per store. Owning the window outright makes each of those stores
  // a single cycle, which is the point of the change.
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

  // Keep both framebuffer pages and scanout on a true dual-port block RAM.
  // A same-word mixed-port collision is retried below; the scanout port never
  // consumes device-specific collision data.
  wire cpu_hits_fb = ((active_address >= FB0_LOW) &&
                      (active_address < FB0_HIGH)) ||
                     ((active_address >= FB1_LOW) &&
                      (active_address < FB1_HIGH));
  wire video_hits_fb = (({4'd0, video_address} >= FB0_LOW) &&
                        ({4'd0, video_address} < FB0_HIGH)) ||
                       (({4'd0, video_address} >= FB1_LOW) &&
                        ({4'd0, video_address} < FB1_HIGH));

  // Explicitly instantiated, not inferred. Quartus 17.0 refused to infer this
  // memory in three different forms and failed silently each time; see the
  // note at the top of rtl/ki_fb_ram.sv for the evidence and the cost.
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

  assign debug_state = state[2:0];
  assign debug_cpu_pending = cpu_pending;

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
    case (read_word_index)
      2'd0: read_buffer_next[15:0] = sdram_read_data;
      2'd1: read_buffer_next[31:16] = sdram_read_data;
      2'd2: read_buffer_next[47:32] = sdram_read_data;
      2'd3: read_buffer_next[63:48] = sdram_read_data;
    endcase

    ioctl_wait = rom_download &&
        (download_count >= DOWNLOAD_FIFO_HIGH_WATER);
  end

  always_ff @(posedge clk) begin
    boot_cache_read_data <= boot_cache[boot_cache_read_address];
  end

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

    // Line-fill beats land straight in the buffer, one per clock, exactly as
    // the CPU read path assembles its own beats below.
    if (sdram_data_valid && (state == ROM_LINE_FILL_WAIT)) begin
      rom_line[rom_fill_index] <= sdram_read_data;
      rom_fill_index <= rom_fill_index + 1'b1;
    end

    // Burst beats arrive independently of the state machine's own progress:
    // the adapter streams them out of the controller's CAS pipeline, one per
    // clock, and only afterwards raises sdram_done. Assembling them here keeps
    // the read states responsible for issuing and completing, nothing else.
    if (sdram_data_valid &&
        ((state == SDRAM_READ_WAIT) || (state == VIDEO_READ_WAIT))) begin
      read_buffer <= read_buffer_next;
      read_word_index <= read_word_index + 1'b1;
      read_words_remaining <= read_words_remaining - 1'b1;
      memory_word_address <= memory_word_address + 1'b1;

      if (state == SDRAM_READ_WAIT) begin
        if (!operation_req64) begin
          if (read_word_index == 2'd1)
            cpu_data_read <= {32'd0, read_buffer_next[31:0]};
        end else if (read_word_index == 2'd3) begin
          cpu_cache_data <= read_buffer_next;
          cpu_cache_data_ready <= 1'b1;
          cpu_data_read <= read_buffer_next;
          read_buffer <= 64'd0;
          // Only the first two beats are captured: the corruption is in
          // beat 1 and beat 0 is the anchor that proves the capture is
          // aligned with the right line.
          if (dbg_fill_match) begin
            if (dbg_fill_beat == 2'd0) debug_fill_b0 <= read_buffer_next;
            if (dbg_fill_beat == 2'd1) debug_fill_b1 <= read_buffer_next;
          end
          dbg_fill_beat <= dbg_fill_beat + 1'b1;
        end
      end else begin
        // Scanout: hand over each 64-bit word as it completes rather than
        // only the last one at sdram_done, so one request can carry several.
        if (read_word_index == 2'd3) begin
          video_data <= read_buffer_next;
          video_data_valid <= 1'b1;
          read_buffer <= 64'd0;
        end
      end
    end

    ddr_write_ack_sync1 <= ddr_write_ack_toggle;
    ddr_write_ack_sync2 <= ddr_write_ack_sync1;
    ddr_read_done_sync1 <= ddr_read_done_toggle;
    ddr_read_done_sync2 <= ddr_read_done_sync1;
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
      table_capture_index <= 3'd0;
      sdram_burst <= 5'd1;
      rom_line_valid <= 1'b0;
      rom_fill_index <= 4'd0;
      ddr_read_done_seen <= ddr_read_done_sync2;
      dcs_rom_inflight <= 1'b0;
      dcs_rom_request_seen_level <= 1'b0;
      dcs_rom_done_seen <= dcs_rom_done_sync2;
      dcs_rom_data <= 64'd0;
      ddr_return_index <= 2'd0;
      read_buffer <= 64'd0;
      video_won_last <= 1'b0;
      vid_state <= VID_IDLE;
      vid_left <= 3'd0;
    end else begin
      // Scanout, on its own port. Runs concurrently with the state machine
      // below and shares nothing with it.
      case (vid_state)
        VID_IDLE: begin
          // A Port-A write asserted on the previous cycle completes at this
          // edge. Let it retire before starting the next scanout request.
          if (video_request && !video_done && video_hits_fb && !fb_we) begin
            fb_vaddr <= fb_index({4'd0, video_address});
            vid_left <= (video_words == 3'd0) ? 3'd4 : video_words;
            vid_state <= VID_ISSUE;
          end
        end

        // ISSUE, not WAIT: fb_vaddr is registered here, so the memory does not
        // see it until the next edge and vid_q is not valid until the one
        // after. Going straight to the capture state took the PREVIOUS
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
          if (download_count != 0) begin
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
          end else if (have_cpu &&
                       (!video_request || video_won_last)) begin
            video_won_last <= 1'b0;
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
              dbg_fill_beat <= 2'd0;
              dbg_fill_match <=
                  active_req64 && (active_address == 32'h0802_8dc0);
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
                state <= BOOT_CACHE_READ_WAIT;
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
                // to SDRAM - which is exactly what it did.
              end else if (active_boot_cache_read) begin
                // The cache-read branch above already selected its state.
              end else if (active_rom_line_eligible) begin
                // A hit answers straight out of the line buffer; a miss pulls
                // the whole 16-word line in one burst and then answers from
                // it, so the next 31 byte reads of that line cost nothing on
                // the SDRAM bus.
                cpu_grant <= 1'b1;
                state <= rom_line_hit ? ROM_LINE_RETURN : ROM_LINE_FILL_ISSUE;
              end else if (active_rnw) begin
                // read_words_remaining, not read_beats_remaining: the burst
                // covers every beat of the request in one or two requests.
                cpu_grant <= 1'b1;
                state <= SDRAM_READ_ISSUE;
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
          end else if (video_request && !video_done && !video_hits_fb) begin
            // !video_done: video_done and the return to IDLE land on the same
            // edge, so on that one cycle a requester that drops its request on
            // completion still has it asserted here, and launching on it
            // re-reads the address just finished.
            //
            // Measured with the guard removed (tb_ki_framebuffer_fetch): the
            // round-trip COUNT is unchanged - the stale burst is consumed as
            // the answer to the requester's next request - but 2128 of 3840
            // pixels come out wrong, because ki_framebuffer stores every beat
            // that arrives while a fetch is active and so writes the stale
            // burst's words into the line buffer. Harmless for a single-word
            // requester, which is why no bench saw it until scanout burst.
            video_won_last <= 1'b1;
            memory_word_address <=
                {video_address[25:3], 2'b00};
            memory_word_count <= 3'd4;
            read_word_index <= 2'd0;
            read_words_remaining <= video_read_words;
            read_buffer <= 64'd0;
            // Straight out of the framebuffer M10K when the request is inside
            // either real page. The SDRAM path remains available for addresses
            // outside those exact pages.
            state <= VIDEO_READ_ISSUE;
          end
        end

        BOOT_CACHE_READ_WAIT: begin
          state <= BOOT_CACHE_READ_RETURN;
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
        // transactions. The boot ROM is ~256K words, so this is also what
        // takes the ROM download from ~80 ms back down to ~25 ms.
        DOWNLOAD_SDRAM_WRITE_ISSUE: begin
          if (sdram_ready) begin
            // The ROM is only immutable AFTER it is loaded, so any download
            // write drops the line buffer. Without this a core reload could
            // serve a previous ROM's bytes.
            rom_line_valid <= 1'b0;
            sdram_address <= memory_word_address;
            sdram_write_data <= download_data[download_read_pointer];
            sdram_byte_enable <= 8'hff;
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

        // One burst per store. Words whose byte enables are clear are still
        // part of the burst and are masked off by DQM in the controller, which
        // is why the old "skip this word entirely" branch is gone.
        SDRAM_WRITE_ISSUE: begin
          if (sdram_ready) begin
            sdram_address <= memory_word_address;
            sdram_write_data <= operation_write_data;
            sdram_byte_enable <= operation_write_mask;
            sdram_burst <= {2'd0, memory_word_count};
            sdram_write <= 1'b1;
            state <= SDRAM_WRITE_WAIT;
          end
        end

        SDRAM_WRITE_WAIT: begin
          if (sdram_done) begin
            cpu_pending <= 1'b0;
            cpu_done <= 1'b1;
            debug_last_write_address <= operation_address;
            debug_last_write_data <= operation_write_data;
            debug_last_write_info <=
                {23'd0, operation_req64,
                 operation_write_mask};
            debug_write_count <= debug_write_count + 1'b1;
            // Boot-table snoop; see the port comment. Capture the FIRST
            // writes, not the last: the initialiser runs once in a burst of 64
            // stores and is then buried under thousands of unrelated ones, so
            // a last-write latch shows whatever happened to be most recent.
            // Zero-data stores are skipped so an early RAM clear cannot
            // consume the capture slots before the initialiser runs.
            if ((operation_address >= 32'h087f_f000) &&
                (operation_address <= 32'h087f_ffff)) begin
              debug_table_write_count <=
                  debug_table_write_count + 1'b1;
              if ((store_byte != 8'h00) && (table_capture_index < 3'd4)) begin
                if (table_capture_index == 3'd0)
                  debug_table_write_address <= operation_address;
                debug_table_write_data <=
                    {debug_table_write_data[23:0], store_byte};
                table_capture_index <= table_capture_index + 1'b1;
              end
            end
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
            if (operation_address == 32'h0800_0000) begin
              if (|operation_write_mask[3:0])
                debug_main_write0 <=
                    operation_write_data[31:0];
              if (|operation_write_mask[7:4])
                debug_main_write1 <=
                    operation_write_data[63:32];
            end else if (operation_address == 32'h0800_0004) begin
              if (|operation_write_mask[3:0])
                debug_main_write1 <=
                    operation_write_data[31:0];
            end else if (operation_address == 32'h0800_0008) begin
              if (|operation_write_mask[3:0])
                debug_main_write2 <=
                    operation_write_data[31:0];
            end
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
          // [3:0], and the HALF it belongs to encoded in address bit 2 - see
          // the 32-bit store to 0x08000004 in tb_ki_memory_bridge, which lands
          // at byte offset 4 in SDRAM. The SDRAM path carries that bit in the
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
          debug_last_write_address <= operation_address;
          debug_last_write_data <= operation_write_data;
          debug_write_count <= debug_write_count + 1'b1;
          state <= IDLE;
        end

        VIDEO_READ_ISSUE: begin
          if (sdram_ready) begin
            sdram_address <= memory_word_address;
            sdram_burst <= next_burst;
            sdram_read <= 1'b1;
            state <= VIDEO_READ_WAIT;
          end
        end

        // Scanout requests are naturally aligned (the framebuffer's lines are
        // 640 bytes, so every 4-qword group is 32-byte aligned), which keeps a
        // 16-word burst inside one 512-word row. The split path exists for a
        // caller that does not honour that.
        //
        // The data itself is handed over by the sdram_data_valid block above,
        // one pulse per assembled qword; all this decides is completion.
        VIDEO_READ_WAIT: begin
          if (sdram_done) begin
            if (read_words_left_next == 0) begin
              video_done <= 1'b1;
              state <= IDLE;
            end else begin
              state <= VIDEO_READ_ISSUE;
            end
          end
        end

        DDR_READ_WAIT: begin
          if (ddr_read_done_sync2 != ddr_read_done_seen) begin
            ddr_read_done_seen <= ddr_read_done_sync2;
            ddr_return_index <= 2'd0;
            state <= DDR_READ_RETURN;
          end
        end

        DDR_READ_RETURN: begin
          case (ddr_return_index)
            2'd0: cpu_data_read <= operation_req64 ?
                ddr_read_mailbox_data0 :
                (operation_address[2] ?
                 {32'd0, ddr_read_mailbox_data0[63:32]} :
                 {32'd0, ddr_read_mailbox_data0[31:0]});
            2'd1: cpu_data_read <= ddr_read_mailbox_data1;
            2'd2: cpu_data_read <= ddr_read_mailbox_data2;
            default: cpu_data_read <= ddr_read_mailbox_data3;
          endcase
            if (operation_req64) begin
              case (ddr_return_index)
                2'd0: cpu_cache_data <= ddr_read_mailbox_data0;
                2'd1: cpu_cache_data <= ddr_read_mailbox_data1;
                2'd2: cpu_cache_data <= ddr_read_mailbox_data2;
                default: cpu_cache_data <= ddr_read_mailbox_data3;
              endcase
              cpu_cache_data_ready <= 1'b1;
            end
            if (read_beats_remaining <= 1) begin
              read_beats_remaining <= 3'd0;
              cpu_done <= 1'b1;
              cpu_pending <= 1'b0;
              state <= IDLE;
            end else begin
              read_beats_remaining <= read_beats_remaining - 1'b1;
              ddr_return_index <= ddr_return_index + 1'b1;
            end
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
    ddr_read_request_sync1 <= ddr_read_request_toggle;
    ddr_read_request_sync2 <= ddr_read_request_sync1;
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
          // base is STORE_DCS[27:3] and the index adds directly. Ahead of the
          // CPU read because the ADSP-2105 stalls on every fetch and a single
          // qword costs one DDR transaction.
          ddram_addr <= {4'b0011, STORE_DCS[27:3]} +
              {{10{1'b0}}, dcs_rom_mailbox_address};
          ddram_burstcnt <= 8'd1;
          ddram_be <= 8'hff;
          ddram_rd <= 1'b1;
          ddr_service_state <= DDR_SERVICE_DCS_ISSUE;
        end else if (ddr_read_request_sync2 != ddr_read_request_seen) begin
          ddram_addr <= ddr_read_mailbox_address;
          ddram_burstcnt <= {5'd0, ddr_read_mailbox_beats};
          ddram_be <= 8'hff;
          ddram_rd <= 1'b1;
          ddr_service_beats_remaining <= ddr_read_mailbox_beats;
          ddr_service_beat_index <= 2'd0;
          ddr_service_state <= DDR_SERVICE_READ_ISSUE;
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

      DDR_SERVICE_READ_ISSUE: begin
        ddram_rd <= 1'b1;
        if (!ddram_busy) begin
          ddram_rd <= 1'b0;
          ddr_read_request_seen <= ddr_read_request_sync2;
          ddr_service_state <= DDR_SERVICE_READ;
        end
      end

      DDR_SERVICE_READ: begin
        if (ddram_dout_ready) begin
          case (ddr_service_beat_index)
            2'd0: ddr_read_mailbox_data0 <= ddram_dout;
            2'd1: ddr_read_mailbox_data1 <= ddram_dout;
            2'd2: ddr_read_mailbox_data2 <= ddram_dout;
            default: ddr_read_mailbox_data3 <= ddram_dout;
          endcase
          if (ddr_service_beats_remaining <= 1) begin
            ddr_service_beats_remaining <= 3'd0;
            ddr_read_done_toggle <= ~ddr_read_done_toggle;
            ddr_service_state <= DDR_SERVICE_IDLE;
          end else begin
            ddr_service_beats_remaining <=
                ddr_service_beats_remaining - 1'b1;
            ddr_service_beat_index <= ddr_service_beat_index + 1'b1;
          end
        end
      end
    endcase
  end

  // M10K carries the early reset path and both exact framebuffer pages. SDRAM
  // carries the complete boot ROM and all other mutable CPU RAM. DDR3 carries
  // immutable DCS ROM.
endmodule

`default_nettype wire
