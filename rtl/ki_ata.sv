// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_ata (
  input  wire         clk,
  input  wire         reset,
  input  wire         game_ki2,

  input  wire         bus_request,
  input  wire         bus_write,
  input  wire  [31:0] bus_address,
  input  wire  [31:0] bus_write_data,
  input  wire   [3:0] bus_byte_enable,
  output logic [31:0] bus_read_data,
  output logic        bus_done,
  output logic        irq,

  input  wire         img_mounted,
  input  wire         img_readonly,
  input  wire  [63:0] img_size,
  output logic [31:0] sd_lba,
  // Blocks-1 for the request being issued. hps_io reads this while sd_rd is
  // up, so it is registered alongside sd_lba and held for the transfer.
  output logic  [5:0] sd_blk_cnt,
  output logic        sd_rd,
  output logic        sd_wr,
  input  wire         sd_ack,
  // Wide enough for a whole batch, not one sector. hps_io declares this
  // [12:0] under WIDE(1) and counts 16-bit words across the entire multi-block
  // transfer; the core previously took only the low 8 bits because it only
  // ever asked for one 512-byte block.
  input  wire  [12:0] sd_buff_addr,
  input  wire  [15:0] sd_buff_dout,
  output logic [15:0] sd_buff_din,
  input  wire         sd_buff_wr,

  output wire   [2:0] debug_state,
  output wire   [7:0] debug_status,
  output wire   [7:0] debug_error,
  output wire         debug_image_ready,
  // The last command byte the host wrote, whether the interrupt line is
  // up right now, and how many times it has been RAISED. The count is what
  // separates "never asserted" from "asserted and already consumed": a
  // status-register read clears irq_pending, which is correct ATA and also
  // means a live sample of irq alone cannot tell those two apart.
  output wire  [31:0] debug_info,
  // The START LBA of the last READ SECTORS and the last WRITE SECTORS.
  // The game's verify at 8802DB18 compares a sector against memory; that
  // fails either because the DATA is wrong or because the SECTOR is, and
  // only these two distinguish them. selected_lba() has to get CHS right
  // (13 heads, 47 sectors for KI1) as well as LBA mode, so a translation
  // error would read back a different sector than was written.
  output wire  [31:0] debug_read_lba,
  output wire  [31:0] debug_write_lba,
  output wire  [31:0] debug_write_info,
  output wire  [31:0] debug_dataport_info
);
  import ki_board_pkg::*;

  localparam logic [7:0] ATA_READY = 8'h50;
  localparam logic [7:0] ATA_BUSY  = 8'h80;
  localparam logic [7:0] ATA_DRQ   = 8'h58;
  localparam logic [7:0] ATA_ERROR = 8'h51;

  typedef enum logic [2:0] {
    ATA_IDLE,
    ATA_READ_SETUP,
    ATA_SD_READ_WAIT,
    ATA_PIO_READ,
    ATA_WRITE_SETUP,
    ATA_PIO_WRITE,
    ATA_SD_WRITE_WAIT
  } ata_state_t;

  // Sector streaming.
  localparam integer BATCH_SECTORS = 8;
  localparam integer SECTOR_WORDS  = 256;
  localparam integer BANK_WORDS    = BATCH_SECTORS * SECTOR_WORDS; // 2048
  localparam integer BUF_WORDS     = 2 * BANK_WORDS;               // 4096
  localparam integer BANK_AW       = $clog2(BANK_WORDS);           // 11
  localparam integer BUF_AW        = $clog2(BUF_WORDS);            // 12
  localparam integer SECT_AW       = $clog2(BATCH_SECTORS);        // 3

  ata_state_t state = ATA_IDLE;
  logic [7:0]  data_index;
  logic [7:0]  geom_sectors;
  logic [7:0]  geom_heads;
  logic [8:0]  sectors_remaining;
  logic [7:0]  error_reg;
  logic [7:0]  sector_count;
  logic [7:0]  sector_number;
  logic [7:0]  cylinder_low;
  logic [7:0]  cylinder_high;
  logic [7:0]  device_head;
  logic [7:0]  status;
  logic [7:0]  device_control;
  logic        irq_pending;
  logic  [7:0] last_command;
  logic [15:0] irq_raise_count;
  logic [11:0] data_writes;
  logic [31:0] last_read_lba;
  logic [31:0] last_write_lba;
  logic [11:0] sd_wr_issued;
  logic [11:0] sd_wr_acked;
  logic        sd_wr_d;
  logic  [3:0] last_wr_be;
  logic  [7:0] last_wr_addr;
  logic [11:0] write_cmds;
  logic  [7:0] max_write_index;
  logic        irq_pending_d;
  logic        image_ready;
  logic        image_readonly;
  logic [31:0] image_sectors;
  logic        sd_ack_d;
  logic        identify_transfer;

  // Read streaming state. read_active gates the fetch engine so it can never
  // touch sd_rd while a write command owns the HPS handshake.
  logic                 read_active;
  logic                 fill_bank;    // bank the HPS is filling
  logic                 drain_bank;   // bank the CPU is reading
  logic           [1:0] bank_valid;
  logic [SECT_AW:0]     bank_count [0:1]; // sectors actually held, 1..BATCH
  logic [SECT_AW-1:0]   drain_sector;     // sector within the drain bank
  logic           [8:0] fetch_remaining;  // sectors not yet asked of the HPS
  logic           [8:0] deliver_remaining;// sectors not yet given to the CPU
  logic [SECT_AW:0]     fetch_batch;      // sectors in the request in flight
  logic                 fetch_busy;

  // How many sectors the next request may cover: whatever is left of the
  // command, capped at a batch, and capped again so a batch can never run off
  // the end of the image. The single-sector path re-checked the bound on every
  // sector because it re-entered ATA_READ_SETUP each time; batching has to
  // carry that check into the request size instead.
  wire [31:0] sectors_to_end = image_sectors - sd_lba;
  wire  [8:0] fetch_avail    = (sectors_to_end > 32'd256)
                                 ? 9'd256 : sectors_to_end[8:0];
  wire  [8:0] fetch_cap      = (fetch_remaining > BATCH_SECTORS[8:0])
                                 ? BATCH_SECTORS[8:0] : fetch_remaining;
  wire  [8:0] fetch_want     = (fetch_cap > fetch_avail) ? fetch_avail
                                                        : fetch_cap;

  assign debug_state = state;
  assign debug_status = status;
  assign debug_error = error_reg;
  assign debug_image_ready = image_ready;
  assign debug_read_lba  = last_read_lba;
  assign debug_write_lba = last_write_lba;
  // img_readonly | sectors we asked the HPS to write | handshakes it completed
  assign debug_write_info = {image_readonly, 7'd0, sd_wr_issued, sd_wr_acked};
  assign debug_dataport_info = {last_wr_be, max_write_index, write_cmds,
                                last_wr_addr};
  assign debug_info = {last_command, irq, irq_pending, device_control[1],
                       1'b0, data_index, data_writes};

  wire cs0_selected = (bus_address >= KI_ATA_CS0_BASE) &&
                      (bus_address <= KI_ATA_CS0_LAST);
  wire cs1_selected = (bus_address >= KI_ATA_CS1_ADDR) &&
                      (bus_address <= (KI_ATA_CS1_ADDR + 3));
  wire [2:0] cs0_register = bus_address[5:3];
  wire bus_access = bus_request && (cs0_selected || cs1_selected);
  wire cpu_buffer_write = bus_access && bus_write && cs0_selected &&
                          (cs0_register == 3'd0) &&
                          (state == ATA_PIO_WRITE) && |bus_byte_enable[1:0];
  wire [15:0] cpu_buffer_data;

  assign bus_done = bus_access;
  assign irq = irq_pending && !device_control[1];

  // Buffer addressing.
  //
  // Writes are untouched by the streaming work: they remain one sector at a
  // time and use the first sector of bank 0, so both ports address the same
  // 256 words the single-sector implementation used. Only reads see the banks.
  wire hps_write_mode = (state == ATA_PIO_WRITE) || (state == ATA_SD_WRITE_WAIT);

  wire [BUF_AW-1:0] buf_cpu_addr =
      (state == ATA_PIO_WRITE)
        ? {{(BUF_AW-8){1'b0}}, data_index}
        : {drain_bank, drain_sector, data_index};

  wire [BUF_AW-1:0] buf_hps_addr =
      hps_write_mode
        ? {{(BUF_AW-8){1'b0}}, sd_buff_addr[7:0]}
        : {fill_bank, sd_buff_addr[BANK_AW-1:0]};

`ifdef ALTERA_RESERVED_QIS
  altsyncram sector_buffer (
    .clock0(clk),
    .address_a(buf_cpu_addr),
    .data_a(bus_write_data[15:0]),
    .wren_a(cpu_buffer_write),
    .byteena_a(bus_byte_enable[1:0]),
    .q_a(cpu_buffer_data),

    .clock1(clk),
    .address_b(buf_hps_addr),
    .data_b(sd_buff_dout),
    .wren_b(sd_ack && sd_buff_wr),
    .byteena_b(1'b1),
    .q_b(sd_buff_din),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
  );
  defparam
    sector_buffer.numwords_a = BUF_WORDS,
    sector_buffer.widthad_a = BUF_AW,
    sector_buffer.width_a = 16,
    sector_buffer.width_byteena_a = 2,
    sector_buffer.numwords_b = BUF_WORDS,
    sector_buffer.widthad_b = BUF_AW,
    sector_buffer.width_b = 16,
    sector_buffer.width_byteena_b = 1,
    sector_buffer.address_reg_b = "CLOCK1",
    sector_buffer.clock_enable_input_a = "BYPASS",
    sector_buffer.clock_enable_input_b = "BYPASS",
    sector_buffer.clock_enable_output_a = "BYPASS",
    sector_buffer.clock_enable_output_b = "BYPASS",
    sector_buffer.indata_reg_b = "CLOCK1",
    sector_buffer.intended_device_family = "Cyclone V",
    sector_buffer.lpm_type = "altsyncram",
    sector_buffer.operation_mode = "BIDIR_DUAL_PORT",
    sector_buffer.outdata_aclr_a = "NONE",
    sector_buffer.outdata_aclr_b = "NONE",
    sector_buffer.outdata_reg_a = "UNREGISTERED",
    sector_buffer.outdata_reg_b = "UNREGISTERED",
    sector_buffer.power_up_uninitialized = "FALSE",
    sector_buffer.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    sector_buffer.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    sector_buffer.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
  logic [15:0] simulation_sector_buffer [0:BUF_WORDS-1];

  logic [BUF_AW-1:0] sim_cpu_addr_q;
  logic [BUF_AW-1:0] sim_hps_addr_q;

  always_ff @(posedge clk) begin
    sim_cpu_addr_q <= buf_cpu_addr;
    sim_hps_addr_q <= buf_hps_addr;
  end

  assign cpu_buffer_data = simulation_sector_buffer[sim_cpu_addr_q];
  assign sd_buff_din = simulation_sector_buffer[sim_hps_addr_q];

  always_ff @(posedge clk) begin
    if (cpu_buffer_write) begin
      if (bus_byte_enable[0])
        simulation_sector_buffer[buf_cpu_addr][7:0] <= bus_write_data[7:0];
      if (bus_byte_enable[1])
        simulation_sector_buffer[buf_cpu_addr][15:8] <= bus_write_data[15:8];
    end
    if (sd_ack && sd_buff_wr)
      simulation_sector_buffer[buf_hps_addr] <= sd_buff_dout;
  end
`endif

  function automatic [31:0] selected_lba;
    logic [27:0] lba28;
    logic [15:0] cylinder;
    logic [7:0] heads;
    logic [7:0] sectors;
    begin
      lba28 = {device_head[3:0], cylinder_high, cylinder_low, sector_number};
      cylinder = {cylinder_high, cylinder_low};
      // Whatever the host last programmed with 0x91, or the drive's physical
      // geometry if it never did. The game's forward translation at 8802DB58
      // is the exact inverse:
      //
      //   sector   = (LBA % sectors) + 1
      //   cylinder = (LBA / sectors) / heads
      //   head     = (LBA / sectors) % heads
      //
      // so LBA = (cylinder * heads + head) * sectors + sector - 1.
      heads = geom_heads;
      sectors = geom_sectors;
      if (device_head[6])
        selected_lba = {4'h0, lba28};
      else if (sector_number == 0)
        selected_lba = 32'hffff_ffff;
      else
        selected_lba = ((cylinder * heads) + device_head[3:0]) * sectors +
                       sector_number - 1'b1;
    end
  endfunction

  function automatic [15:0] identify_word(input logic [7:0] index);
    logic [31:0] capacity;
    logic [15:0] cylinders;
    logic [15:0] heads;
    logic [15:0] sectors;
    begin
      // Physical geometry, straight out of the CHD headers:
      //   kinst.chd   CYLS:419,  HEADS:13, SECS:47  -> 419*13*47  = 256009
      //   kinst2.chd  CYLS:1463, HEADS:13, SECS:47  -> 1463*13*47 = 893893
      // KI2 previously read 988 cylinders and 822016 sectors, matching neither
      // its image nor anything else.
      capacity = game_ki2 ? 32'd893893 : 32'd256009;
      cylinders = game_ki2 ? 16'd1463 : 16'd419;
      heads = 16'd13;
      sectors = 16'd47;
      identify_word = 16'h0000;
      case (index)
        8'd0:  identify_word = 16'h0040;
        8'd1:  identify_word = cylinders;
        8'd3:  identify_word = heads;
        8'd6:  identify_word = sectors;
        8'd10, 8'd15, 8'd16, 8'd17, 8'd18, 8'd19:
          identify_word = 16'h3030;
        8'd11: identify_word = game_ki2 ? 16'h5354 : 16'h3030;
        8'd12: identify_word = game_ki2 ? 16'h3931 : 16'h3030;
        8'd13: identify_word = game_ki2 ? 16'h3530 : 16'h3030;
        8'd14: identify_word = game_ki2 ? 16'h4147 : 16'h3030;
        8'd23: identify_word = 16'h312e;
        8'd24: identify_word = 16'h3020;
        8'd27: identify_word = game_ki2 ? 16'h2020 : 16'h5354;
        8'd28: identify_word = game_ki2 ? 16'h2020 : 16'h3931;
        8'd29: identify_word = game_ki2 ? 16'h2020 : 16'h3530;
        8'd30: identify_word = game_ki2 ? 16'h2020 : 16'h4147;
        8'd31, 8'd32, 8'd33, 8'd34, 8'd35, 8'd36, 8'd37, 8'd38,
        8'd39, 8'd40, 8'd41, 8'd42, 8'd43, 8'd44, 8'd45, 8'd46:
          identify_word = 16'h2020;
        8'd47: identify_word = 16'h8001;
        8'd49: identify_word = 16'h0200;
        8'd53: identify_word = 16'h0001;
        // 1/3/6 are the default (physical) geometry above; 54/55/56 are the
        // CURRENT logical one, which 0x91 changes. Word 54 stays physical: the
        // current cylinder count would need capacity/(heads*sectors), and a
        // divider is not worth the logic for a field this game never reads -
        // it programs its geometry and uses its own constants.
        8'd54: identify_word = cylinders;
        8'd55: identify_word = {8'd0, geom_heads};
        8'd56: identify_word = {8'd0, geom_sectors};
        8'd57: identify_word = capacity[15:0];
        8'd58: identify_word = capacity[31:16];
        8'd60: identify_word = capacity[15:0];
        8'd61: identify_word = capacity[31:16];
        default: identify_word = 16'h0000;
      endcase
    end
  endfunction

  always_comb begin
    bus_read_data = 32'hffff_ffff;
    if (cs1_selected) begin
      bus_read_data = {24'hff_ffff, status};
    end else if (cs0_selected) begin
      case (cs0_register)
        3'd0: bus_read_data = {16'hffff,
                               (state == ATA_PIO_READ) ?
                                 (identify_transfer ? identify_word(data_index) :
                                                      cpu_buffer_data) :
                                 16'hffff};
        3'd1: bus_read_data = {24'hff_ffff, error_reg};
        3'd2: bus_read_data = {24'hff_ffff, sector_count};
        3'd3: bus_read_data = {24'hff_ffff, sector_number};
        3'd4: bus_read_data = {24'hff_ffff, cylinder_low};
        3'd5: bus_read_data = {24'hff_ffff, cylinder_high};
        3'd6: bus_read_data = {24'hff_ffff, device_head};
        3'd7: bus_read_data = {24'hff_ffff, status};
      endcase
    end
  end

  task automatic command_complete;
    begin
      status <= ATA_READY;
      error_reg <= 8'h00;
      irq_pending <= 1'b1;
      state <= ATA_IDLE;
    end
  endtask

  task automatic command_abort;
    begin
      status <= ATA_ERROR;
      error_reg <= 8'h04;
      irq_pending <= 1'b1;
      state <= ATA_IDLE;
      sd_rd <= 1'b0;
      sd_wr <= 1'b0;
      fetch_busy <= 1'b0;
      bank_valid <= 2'b00;
      fetch_remaining <= 9'd0;
      deliver_remaining <= 9'd0;
    end
  endtask

  always_ff @(posedge clk) begin
    sd_ack_d <= sd_ack;

    if (reset) begin
      state             <= ATA_IDLE;
      data_index        <= 8'h00;
      geom_sectors      <= 8'd47;
      geom_heads        <= 8'd13;
      sectors_remaining <= 9'd0;
      error_reg         <= 8'h01;
      sector_count      <= 8'h01;
      sector_number     <= 8'h01;
      cylinder_low      <= 8'h00;
      cylinder_high     <= 8'h00;
      device_head       <= 8'ha0;
      status            <= ATA_READY;
      device_control    <= 8'h00;
      last_command      <= 8'h00;
      irq_raise_count   <= 16'd0;
      data_writes       <= 12'd0;
      last_read_lba     <= 32'h0;
      last_write_lba    <= 32'h0;
      sd_wr_issued      <= 12'd0;
      sd_wr_acked       <= 12'd0;
      sd_wr_d           <= 1'b0;
      last_wr_be        <= 4'd0;
      last_wr_addr      <= 8'd0;
      write_cmds        <= 12'd0;
      max_write_index   <= 8'd0;
      irq_pending_d     <= 1'b0;
      irq_pending       <= 1'b0;
      image_ready       <= 1'b0;
      image_readonly    <= 1'b1;
      image_sectors     <= 32'h0000_0000;
      identify_transfer <= 1'b0;
      sd_lba            <= 32'h0000_0000;
      sd_blk_cnt        <= 6'd0;
      sd_rd             <= 1'b0;
      sd_wr             <= 1'b0;
      sd_ack_d          <= 1'b0;
      read_active       <= 1'b0;
      fill_bank         <= 1'b0;
      drain_bank        <= 1'b0;
      bank_valid        <= 2'b00;
      bank_count[0]     <= '0;
      bank_count[1]     <= '0;
      drain_sector      <= '0;
      fetch_remaining   <= 9'd0;
      deliver_remaining <= 9'd0;
      fetch_batch       <= '0;
      fetch_busy        <= 1'b0;
    end else begin
      // Count the write handshake from both ends: every sector this core asks
      // the HPS to commit, and every one the HPS acknowledges. If issued
      // climbs while acked does not, the request never completes and the write
      // is lost on the HPS side; if both climb together the core did its part
      // and the image itself is not taking the data.
      // How far the block ever got, and what the host is actually presenting.
      //
      // cpu_buffer_write demands |bus_byte_enable[1:0] and advances
      // data_index by exactly ONE HALFWORD per accepted access. A host writing
      // 32-bit words, or writing the upper halfword at offset +2, would have
      // half its transfer silently refused - the block would then stop short
      // of 0xFF and sd_wr would never fire, which is exactly what WH shows.
      if (state == ATA_PIO_WRITE && data_index > max_write_index)
        max_write_index <= data_index;
      if (bus_access && bus_write && cs0_selected && cs0_register == 3'd0) begin
        last_wr_be   <= bus_byte_enable;
        last_wr_addr <= bus_address[7:0];
      end

      sd_wr_d <= sd_wr;
      if (sd_wr && !sd_wr_d && sd_wr_issued != 12'hfff)
        sd_wr_issued <= sd_wr_issued + 1'b1;
      if (state == ATA_SD_WRITE_WAIT && !sd_ack && sd_ack_d &&
          sd_wr_acked != 12'hfff)
        sd_wr_acked <= sd_wr_acked + 1'b1;

      // Count RISING edges of irq_pending. A status-register read clears it -
      // correct ATA behaviour - so a live sample of the irq line cannot tell
      // "never asserted" from "asserted and already consumed", and those are
      // very different faults. The count can only go up.
      irq_pending_d <= irq_pending;
      if (irq_pending && !irq_pending_d && irq_raise_count != 16'hffff)
        irq_raise_count <= irq_raise_count + 1'b1;

      // img_mounted is a pulse. The image properties remain valid across a
      // menu reset, so sample them continuously instead of losing the disk
      // after the CPU is reset following a successful mount.
      image_ready    <= (img_size >= 512);
      image_readonly <= img_readonly;
      image_sectors  <= img_size[40:9];

      // READ SECTORS no longer issues the transfer itself. It validates the
      // request and hands off to the fetch engine below, which owns sd_rd for
      // the whole command and runs ahead of the host.
      if (state == ATA_READ_SETUP) begin
        if (!image_ready || sd_lba >= image_sectors) begin
          command_abort();
          read_active <= 1'b0;
        end else begin
          state <= ATA_SD_READ_WAIT;
        end
      end

      // ---- fetch engine -------------------------------------------------
      // Fills whichever bank is free, independently of what the host is
      // draining. This is the prefetch: while ATA_PIO_READ hands one bank to
      // the CPU 260 ns at a time, the HPS round trip for the next batch is
      // already in flight against the other.
      if (read_active && !fetch_busy && fetch_remaining != 9'd0 &&
          !bank_valid[fill_bank]) begin
        if (!image_ready || sd_lba >= image_sectors || fetch_want == 9'd0) begin
          command_abort();
          read_active <= 1'b0;
        end else begin
          sd_blk_cnt  <= fetch_want[5:0] - 6'd1;
          fetch_batch <= fetch_want[SECT_AW:0];
          sd_rd       <= 1'b1;
          fetch_busy  <= 1'b1;
        end
      end

      if (fetch_busy && sd_ack && !sd_ack_d)
        sd_rd <= 1'b0;

      if (fetch_busy && !sd_ack && sd_ack_d) begin
        bank_valid[fill_bank] <= 1'b1;
        bank_count[fill_bank] <= fetch_batch;
        fetch_remaining       <= fetch_remaining - {5'd0, fetch_batch};
        sd_lba                <= sd_lba + {28'd0, fetch_batch};
        fill_bank             <= ~fill_bank;
        fetch_busy            <= 1'b0;
      end

      // ---- drain start ---------------------------------------------------
      // ATA_SD_READ_WAIT now means "the host is waiting for its bank", not
      // "a request is in flight". When the prefetch has already landed this
      // fires the cycle after the previous bank was released.
      if (read_active && state == ATA_SD_READ_WAIT && bank_valid[drain_bank]) begin
        data_index  <= 8'h00;
        status      <= ATA_DRQ;
        irq_pending <= 1'b1;
        state       <= ATA_PIO_READ;
      end

      if (state == ATA_WRITE_SETUP) begin
        if (!image_ready || image_readonly || sd_lba >= image_sectors) begin
          command_abort();
        end else begin
          data_index  <= 8'h00;
          status      <= ATA_DRQ;
          state       <= ATA_PIO_WRITE;
        end
      end

      if (state == ATA_SD_WRITE_WAIT && sd_ack && !sd_ack_d)
        sd_wr <= 1'b0;

      if (state == ATA_SD_WRITE_WAIT && !sd_ack && sd_ack_d) begin
        if (sectors_remaining > 1) begin
          sectors_remaining <= sectors_remaining - 1'b1;
          sd_lba            <= sd_lba + 1'b1;
          data_index        <= 8'h00;
          status            <= ATA_DRQ;
          irq_pending       <= 1'b1;
          state             <= ATA_PIO_WRITE;
        end else begin
          command_complete();
        end
      end

      if (bus_access && !bus_write) begin
        if (cs0_selected && cs0_register == 3'd7)
          irq_pending <= 1'b0;

        if (cs0_selected && cs0_register == 3'd0 && state == ATA_PIO_READ) begin
          if (data_index == 8'hff) begin
            if (identify_transfer) begin
              // IDENTIFY is answered from identify_word(), never the buffer,
              // and is always exactly one sector.
              status            <= ATA_READY;
              state             <= ATA_IDLE;
              identify_transfer <= 1'b0;
            end else if (deliver_remaining <= 9'd1) begin
              // Last sector of the command.
              bank_valid[drain_bank] <= 1'b0;
              deliver_remaining      <= 9'd0;
              read_active            <= 1'b0;
              status                 <= ATA_READY;
              state                  <= ATA_IDLE;
            end else begin
              deliver_remaining <= deliver_remaining - 1'b1;
              data_index        <= 8'h00;
              if ({1'b0, drain_sector} + 1'b1 < bank_count[drain_bank]) begin
                // Another sector is already sitting in this bank. No HPS
                // round trip, no BUSY gap - straight on to the next DRQ.
                drain_sector <= drain_sector + 1'b1;
                status       <= ATA_DRQ;
                irq_pending  <= 1'b1;
              end else begin
                // Bank exhausted. Release it so the fetch engine can refill
                // it, and switch to the one the prefetch has been filling.
                bank_valid[drain_bank] <= 1'b0;
                drain_bank             <= ~drain_bank;
                drain_sector           <= '0;
                status                 <= ATA_BUSY;
                irq_pending            <= 1'b0;
                state                  <= ATA_SD_READ_WAIT;
              end
            end
          end else begin
            data_index <= data_index + 1'b1;
          end
        end
      end

      if (bus_access && bus_write) begin
        if (cs1_selected && bus_byte_enable[0]) begin
          device_control <= bus_write_data[7:0];
          if (bus_write_data[2]) begin
            state             <= ATA_IDLE;
            status            <= ATA_READY;
            error_reg         <= 8'h01;
            irq_pending       <= 1'b0;
            sd_rd             <= 1'b0;
            sd_wr             <= 1'b0;
            read_active       <= 1'b0;
            fetch_busy        <= 1'b0;
            bank_valid        <= 2'b00;
            fill_bank         <= 1'b0;
            drain_bank        <= 1'b0;
            drain_sector      <= '0;
            fetch_remaining   <= 9'd0;
            deliver_remaining <= 9'd0;
            data_index        <= 8'h00;
            sectors_remaining <= 9'd0;
          end
        end else if (cs0_selected) begin
          case (cs0_register)
            3'd0: if (state == ATA_PIO_WRITE && |bus_byte_enable[1:0]) begin
              if (data_writes != 12'hfff) data_writes <= data_writes + 1'b1;
              if (data_index == 8'hff) begin
                status      <= ATA_BUSY;
                irq_pending <= 1'b0;
                sd_wr       <= 1'b1;
                state       <= ATA_SD_WRITE_WAIT;
              end else begin
                data_index <= data_index + 1'b1;
              end
            end
            3'd1: begin end
            3'd2: if (bus_byte_enable[0]) sector_count  <= bus_write_data[7:0];
            3'd3: if (bus_byte_enable[0]) sector_number <= bus_write_data[7:0];
            3'd4: if (bus_byte_enable[0]) cylinder_low  <= bus_write_data[7:0];
            3'd5: if (bus_byte_enable[0]) cylinder_high <= bus_write_data[7:0];
            3'd6: if (bus_byte_enable[0]) device_head   <= bus_write_data[7:0];
            3'd7: if (bus_byte_enable[0]) begin
              irq_pending <= 1'b0;
              last_command <= bus_write_data[7:0];
              case (bus_write_data[7:0])
                8'hec: begin
                  data_index        <= 8'h00;
                  sectors_remaining <= 9'd1;
                  read_active       <= 1'b0;
                  fetch_busy        <= 1'b0;
                  bank_valid        <= 2'b00;
                  sd_rd             <= 1'b0;
                  identify_transfer <= 1'b1;
                  status            <= ATA_DRQ;
                  error_reg         <= 8'h00;
                  irq_pending       <= 1'b1;
                  state             <= ATA_PIO_READ;
                end
                8'h20, 8'h21, 8'hc4: begin
                  identify_transfer <= 1'b0;
                  sd_lba            <= selected_lba();
                  last_read_lba     <= selected_lba();
                  fetch_remaining   <= (sector_count == 0) ? 9'd256 : {1'b0, sector_count};
                  deliver_remaining <= (sector_count == 0) ? 9'd256 : {1'b0, sector_count};
                  read_active       <= 1'b1;
                  sd_rd             <= 1'b0;
                  fill_bank         <= 1'b0;
                  drain_bank        <= 1'b0;
                  drain_sector      <= '0;
                  bank_valid        <= 2'b00;
                  fetch_busy        <= 1'b0;
                  data_index        <= 8'h00;
                  status            <= ATA_BUSY;
                  error_reg         <= 8'h00;
                  state             <= ATA_READ_SETUP;
                end
                8'h30, 8'h31, 8'hc5: begin
                  identify_transfer <= 1'b0;
                  read_active       <= 1'b0;
                  fetch_busy        <= 1'b0;
                  bank_valid        <= 2'b00;
                  sd_rd             <= 1'b0;
                  sd_blk_cnt        <= 6'd0;
                  sd_lba            <= selected_lba();
                  last_write_lba    <= selected_lba();
                  if (write_cmds != 12'hfff) write_cmds <= write_cmds + 1'b1;
                  sectors_remaining <= (sector_count == 0) ? 9'd256 : {1'b0, sector_count};
                  status            <= ATA_BUSY;
                  error_reg         <= 8'h00;
                  state             <= ATA_WRITE_SETUP;
                end
                // INITIALIZE DEVICE PARAMETERS: sector count is sectors per
                // track, and device/head[3:0] is the MAXIMUM head number, so
                // the head count is that plus one. A sector count of zero is
                // invalid and leaves the geometry alone rather than producing
                // a translation that divides by nothing.
                8'h91: begin
                  if (sector_count != 8'd0) geom_sectors <= sector_count;
                  geom_heads <= {4'd0, device_head[3:0]} + 8'd1;
                  command_complete();
                end
                8'h10, 8'h70, 8'he7, 8'hef, 8'hc6: command_complete();
                default: command_abort();
              endcase
            end
          endcase
        end
      end
    end
  end
endmodule

`default_nettype wire
