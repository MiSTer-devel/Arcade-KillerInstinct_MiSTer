`timescale 1ns/1ps

module tb_ki_ata;
  logic clk = 0;
  logic reset = 1;
  logic game_ki2 = 0;
  logic bus_request = 0;
  logic bus_write = 0;
  logic [31:0] bus_address = 0;
  logic [31:0] bus_write_data = 0;
  logic [3:0] bus_byte_enable = 0;
  wire [31:0] bus_read_data;
  wire bus_done;
  wire irq;
  // Packed by ki_ata: last command | irq | irq_pending | nIEN | 0 | raise count.
  wire [31:0] debug_info;
  // Start LBA of the last READ SECTORS and WRITE SECTORS.
  wire [31:0] debug_read_lba;
  wire [31:0] debug_write_lba;
  wire [31:0] debug_write_info;
  wire [31:0] debug_dataport_info;
  logic img_mounted = 0;
  logic img_readonly = 0;
  logic [63:0] img_size = 0;
  wire [31:0] sd_lba;
  wire sd_rd;
  wire sd_wr;
  logic sd_ack = 0;
  logic [7:0] sd_buff_addr = 0;
  logic [15:0] sd_buff_dout = 0;
  wire [15:0] sd_buff_din;
  logic sd_buff_wr = 0;
  wire [2:0] debug_state;
  wire [7:0] debug_status;
  wire [7:0] debug_error;
  wire debug_image_ready;
  logic [31:0] value;

  always #5 clk = ~clk;

  ki_ata dut (.*);

  task automatic write_reg(input [31:0] address, input [15:0] data);
    begin
      @(negedge clk);
      bus_address = address;
      bus_write_data = {16'h0000, data};
      bus_byte_enable = 4'b0011;
      bus_write = 1;
      bus_request = 1;
      @(posedge clk);
      #1;
      if (!bus_done) $fatal(1, "ATA write did not complete at %08h", address);
      @(negedge clk);
      bus_request = 0;
      bus_write = 0;
      bus_byte_enable = 0;
    end
  endtask

  task automatic read_reg(input [31:0] address, output [31:0] data);
    begin
      @(negedge clk);
      bus_address = address;
      bus_write = 0;
      bus_request = 1;
      #1 data = bus_read_data;
      @(posedge clk);
      #1;
      if (!bus_done) $fatal(1, "ATA read did not complete at %08h", address);
      @(negedge clk);
      bus_request = 0;
    end
  endtask

  task automatic fill_sector(input [15:0] base);
    begin
      @(negedge clk);
      sd_ack = 1;
      @(posedge clk);
      #1;
      if (sd_rd)
        $fatal(1, "READ request remained asserted after HPS accepted it");
      if (debug_state != 3'd2 || debug_status != 8'h80 || irq)
        $fatal(1, "READ completed before HPS finished the sector transfer");

      for (int word = 0; word < 256; word++) begin
        @(negedge clk);
        sd_buff_addr = word[7:0];
        sd_buff_dout = base + word[15:0];
        sd_buff_wr = 1;
      end
      @(negedge clk);
      sd_buff_wr = 0;
      if (debug_state != 3'd2 || debug_status != 8'h80 || irq)
        $fatal(1, "READ left BUSY while HPS ACK was still asserted");
      @(negedge clk);
      sd_ack = 0;
      @(posedge clk);
      #1;
      if (debug_state != 3'd3 || debug_status != 8'h58 || !irq)
        $fatal(1, "READ did not enter PIO mode after HPS completed transfer");
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    reset = 0;

    @(negedge clk);
    img_size = 64'd131076608;
    img_mounted = 1;
    @(negedge clk);
    img_mounted = 0;

    write_reg(32'h1000_0138, 16'h00ec);
    read_reg(32'h1000_0138, value);
    if (value[7:0] != 8'h58 || irq) $fatal(1, "IDENTIFY status/IRQ clear failed");
    read_reg(32'h1000_0100, value);
    if (value[15:0] != 16'h0040) $fatal(1, "IDENTIFY word 0 mismatch");
    for (int word = 1; word < 27; word++) read_reg(32'h1000_0100, value);
    read_reg(32'h1000_0100, value);
    if (value[15:0] != 16'h5354) $fatal(1, "KI1 model word 27 mismatch");
    read_reg(32'h1000_0100, value);
    if (value[15:0] != 16'h3931) $fatal(1, "KI1 model word 28 mismatch");
    for (int word = 29; word < 256; word++) read_reg(32'h1000_0100, value);
    read_reg(32'h1000_0138, value);
    if (value[7:0] != 8'h50) $fatal(1, "IDENTIFY did not finish");

    // Geometry comes from INITIALIZE DEVICE PARAMETERS (0x91), not from
    // constants. Before the host programs it the drive must use its PHYSICAL
    // geometry - both CHDs are HEADS:13 SECS:47 - and after, whatever was
    // programmed. KI1 programs 40 sectors and max head 13 (so 14 heads) at
    // 8802D8D0 before any access, which is why it addresses in 14/40 while its
    // disk is physically 13/47.
    //
    // Native geometry first: CHS 0/1/1 is LBA 47 with 47 sectors per track.
    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0001);   // sector 1
    write_reg(32'h1000_0120, 16'h0000);   // cylinder 0
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h0001);   // head 1
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (sd_lba != 32'd47)
      $fatal(1, "native CHS 0/1/1 -> LBA %0d, expected 47", sd_lba);

    // Now program 40 sectors / 14 heads exactly as the game does.
    write_reg(32'h1000_0110, 16'h0028);   // 40 sectors per track
    write_reg(32'h1000_0130, 16'h000d);   // max head 13 -> 14 heads
    write_reg(32'h1000_0138, 16'h0091);   // INITIALIZE DEVICE PARAMETERS
    @(posedge clk);
    #1;

    // The same CHS now means something different, and these are the cases the
    // old hardcoded 13/47 got wrong: cylinder 0 head 0 is the only place the
    // two agree, and every disk WRITE lands there because the game refuses to
    // write past sector 20 - so RD = WL = 12 matching proved nothing.
    //
    // The device/head register carries the BARE head number, as the game
    // writes it. It must not carry 0xE0: bit 6 is the LBA-mode flag and
    // setting it bypasses the CHS translation these checks exist to cover.
    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0001);   // sector 1
    write_reg(32'h1000_0120, 16'h0000);   // cylinder 0
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h0001);   // head 1
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (sd_lba != 32'd40)
      $fatal(1, "CHS 0/1/1 -> LBA %0d, expected 40 after 0x91", sd_lba);

    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0001);
    write_reg(32'h1000_0120, 16'h0001);   // cylinder 1
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h0000);   // head 0
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (sd_lba != 32'd560)
      $fatal(1, "CHS 1/0/1 -> LBA %0d, expected 560 (14*40)", sd_lba);

    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0028);   // sector 40, last of a track
    write_reg(32'h1000_0120, 16'h0002);   // cylinder 2
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h0003);   // head 3
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    // (2*14 + 3) * 40 + 39 = 1279
    if (sd_lba != 32'd1279)
      $fatal(1, "CHS 2/3/40 -> LBA %0d, expected 1279", sd_lba);

    // LBA mode still bypasses all of it.
    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0005);
    write_reg(32'h1000_0120, 16'h0000);
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h00e0);   // bit 6 set: LBA mode
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (sd_lba != 32'd5)
      $fatal(1, "LBA mode -> %0d, expected 5", sd_lba);

    // A zero sector count is invalid and must leave the geometry alone.
    write_reg(32'h1000_0110, 16'h0000);
    write_reg(32'h1000_0130, 16'h0005);
    write_reg(32'h1000_0138, 16'h0091);
    @(posedge clk);
    #1;
    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0001);
    write_reg(32'h1000_0120, 16'h0000);
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h0001);   // head 1, of the 6 just programmed
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (sd_lba != 32'd40)
      $fatal(1, "zero sector count changed the geometry: LBA %0d, expected 40",
             sd_lba);

    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0005);
    write_reg(32'h1000_0120, 16'h0000);
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h00e0);
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (!sd_rd || sd_lba != 5) $fatal(1, "READ SECTORS request mismatch");
    if (debug_read_lba != 32'd5)
      $fatal(1, "last read LBA = %0d, expected 5", debug_read_lba);
    fill_sector(16'h6000);
    read_reg(32'h1000_013c, value);
    if (value[7:0] != 8'h58 || irq) $fatal(1, "READ status/IRQ clear failed");
    read_reg(32'h1000_0104, value);
    if (value[15:0] != 16'h6000) $fatal(1, "READ word 0 mismatch");
    read_reg(32'h1000_0100, value);
    if (value[15:0] != 16'h6001) $fatal(1, "READ word 1 mismatch");
    for (int word = 2; word < 256; word++) begin
      read_reg(32'h1000_0100, value);
      if (value[15:0] != (16'h6000 + word[15:0]))
        $fatal(1, "READ word %0d mismatch: got %04h want %04h", word,
               value[15:0], 16'h6000 + word[15:0]);
    end
    if (sd_rd) $fatal(1, "READ request remained asserted");

    // A MiSTer menu reset follows the mount pulse in the normal workflow.
    // The persistent image size must make the drive immediately usable when
    // the CPU comes back, without requiring a second mount event.
    reset = 1;
    repeat (2) @(posedge clk);
    reset = 0;
    repeat (2) @(posedge clk);
    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0005);
    write_reg(32'h1000_0120, 16'h0000);
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h00e0);
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (!sd_rd || sd_lba != 5) $fatal(1, "Mounted image was lost after reset");
    fill_sector(16'h6100);
    for (int word = 0; word < 256; word++) read_reg(32'h1000_0100, value);

    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'h0007);
    write_reg(32'h1000_0120, 16'h0000);
    write_reg(32'h1000_0128, 16'h0000);
    write_reg(32'h1000_0130, 16'h00e0);
    write_reg(32'h1000_0138, 16'h0030);
    @(posedge clk);
    #1;
    if (debug_state != 3'd5 || debug_status != 8'h58)
      $fatal(1, "WRITE did not enter PIO mode");
    if (irq) $fatal(1, "WRITE asserted INTRQ before the first data block");
    read_reg(32'h1000_0138, value);
    for (int word = 0; word < 256; word++)
      write_reg(32'h1000_0100, 16'ha000 + word[15:0]);
    if (debug_write_lba != 32'd7)
      $fatal(1, "last write LBA = %0d, expected 7", debug_write_lba);
    if (!sd_wr || sd_lba != 7 || debug_state != 3'd6 ||
        debug_status != 8'h80 || irq)
      $fatal(1, "WRITE did not request the completed sector");

    @(negedge clk);
    sd_ack = 1;
    @(posedge clk);
    #1;
    if (sd_wr)
      $fatal(1, "WRITE request remained asserted after HPS accepted it");
    if (debug_state != 3'd6 || debug_status != 8'h80 || irq)
      $fatal(1, "WRITE completed before HPS consumed the sector");
    for (int word = 0; word < 256; word++) begin
      @(negedge clk);
      sd_buff_addr = word[7:0];
      @(posedge clk);
      #1;
      if (sd_buff_din != (16'ha000 + word[15:0]))
        $fatal(1, "WRITE sector word %0d mismatch: %04h", word,
               sd_buff_din);
    end
    if (debug_state != 3'd6 || debug_status != 8'h80 || irq)
      $fatal(1, "WRITE left BUSY while HPS ACK was still asserted");
    @(negedge clk);
    sd_ack = 0;
    @(posedge clk);
    #1;
    if (debug_state != 3'd0 || debug_status != 8'h50 || !irq)
      $fatal(1, "WRITE did not complete after HPS released ACK");
    read_reg(32'h1000_0138, value);
    if (irq) $fatal(1, "WRITE completion IRQ did not clear");

    write_reg(32'h1000_0170, 16'h0002);
    write_reg(32'h1000_0138, 16'h00ef);
    if (irq) $fatal(1, "nIEN did not suppress IRQ");
    read_reg(32'h1000_0170, value);
    if (value[7:0] != 8'h50) $fatal(1, "alternate status mismatch");

    write_reg(32'h1000_0170, 16'h0000);
    write_reg(32'h1000_0138, 16'h0099);
    read_reg(32'h1000_0170, value);
    if (value[7:0] != 8'h51 || !irq) $fatal(1, "unknown command did not abort");
    read_reg(32'h1000_0138, value);
    if (irq) $fatal(1, "status read did not clear IRQ");

    // ---- the game's own drive-init sequence, by name ----
    //
    // At 8802D8DC..8802D8FC the driver writes device control 0x08, then
    // sector count, then device/head, then command 0x91, and immediately
    // calls the wait-for-INTERRUPT routine at 8802DBC0 which polls COP0 Cause
    // bit 0x0800. At 8802D920 it issues command 0xF9 and waits the same way.
    //
    // 0xF9 is not implemented here and falls to command_abort(). That is
    // correct - a real drive aborts it too - but it MUST still assert INTRQ,
    // because the host is already committed to waiting for one. If it did not,
    // the driver would spin 0x02460000 times and take the timeout unwind at
    // 8802DC38, which real KI never does (mame_timeout_probe: 12,752 waits,
    // zero timeouts).
    //
    // Device control 0x08 sets bit 3, a reserved bit that is conventionally
    // written as 1, and leaves nIEN (bit 1) CLEAR - so interrupts stay
    // enabled. A bench that wrote 0x00 here would pass without ever proving
    // the driver's actual value keeps them on.
    write_reg(32'h1000_0170, 16'h0008);
    write_reg(32'h1000_0110, 16'h0028);   // 40 sectors per track
    write_reg(32'h1000_0130, 16'h000d);   // max head 13 -> 14 heads
    write_reg(32'h1000_0138, 16'h0091);   // INITIALIZE DEVICE PARAMETERS
    if (!irq) $fatal(1, "command 0x91 did not assert INTRQ - the driver waits for one at 8802D8FC");
    read_reg(32'h1000_0138, value);
    if (irq) $fatal(1, "status read did not clear IRQ after 0x91");

    write_reg(32'h1000_0138, 16'h00f9);   // the driver's next command
    if (!irq) $fatal(1, "command 0xF9 aborted without INTRQ - the driver waits for one at 8802D924 and would time out");
    read_reg(32'h1000_0138, value);
    if (value[7:0] != 8'h51)
      $fatal(1, "0xF9 should abort with ERR set, got %02h", value[7:0]);
    if (irq) $fatal(1, "status read did not clear IRQ after 0xF9");

    // 0x91 above is not a read-only probe - it reprograms the LOGICAL
    // geometry, and that persists across img_mounted. Put the physical 13/47
    // back or the KI2 IDENTIFY check below reads 14 heads and fails.
    write_reg(32'h1000_0110, 16'h002f);   // 47 sectors per track
    write_reg(32'h1000_0130, 16'h000c);   // max head 12 -> 13 heads
    write_reg(32'h1000_0138, 16'h0091);
    read_reg(32'h1000_0138, value);

    game_ki2 = 1;
    @(negedge clk);
    img_size = 64'd457673216;
    img_mounted = 1;
    @(negedge clk);
    img_mounted = 0;

    write_reg(32'h1000_0138, 16'h00ec);
    for (int word = 0; word < 256; word++) begin
      read_reg(32'h1000_0100, value);
      case (word)
        // From kinst2.chd's own header: CYLS:1463,HEADS:13,SECS:47, so
        // 1463*13*47 = 893893 sectors. The previous 988/16/52 and a capacity
        // of 822016 matched neither the image nor each other. Words 54-56
        // report the CURRENT logical geometry, which equals the physical one
        // here because nothing has issued 0x91 in this pass.
        1, 54: if (value[15:0] != 16'd1463)
          $fatal(1, "KI2 IDENTIFY cylinder count mismatch at word %0d", word);
        3, 55: if (value[15:0] != 16'd13)
          $fatal(1, "KI2 IDENTIFY head count mismatch at word %0d", word);
        6, 56: if (value[15:0] != 16'd47)
          $fatal(1, "KI2 IDENTIFY sector count mismatch at word %0d", word);
        11: if (value[15:0] != 16'h5354)
          $fatal(1, "KI2 serial word 11 mismatch");
        12: if (value[15:0] != 16'h3931)
          $fatal(1, "KI2 serial word 12 mismatch");
        13: if (value[15:0] != 16'h3530)
          $fatal(1, "KI2 serial word 13 mismatch");
        14: if (value[15:0] != 16'h4147)
          $fatal(1, "KI2 serial word 14 mismatch");
        57, 60: if (value[15:0] != 16'ha3c5)
          $fatal(1, "KI2 IDENTIFY capacity low word mismatch at word %0d", word);
        58, 61: if (value[15:0] != 16'h000d)
          $fatal(1, "KI2 IDENTIFY capacity high word mismatch at word %0d", word);
      endcase
    end

    // The LAST sector of kinst2.img under its native 13/47 geometry:
    // cylinder 1462, head 12, sector 47 -> (1462*13 + 12)*47 + 46 = 893892,
    // one below the 893893 the image holds. This previously used 16/52 and
    // addressed 822015, which is not the end of this image.
    write_reg(32'h1000_0110, 16'h0001);
    write_reg(32'h1000_0118, 16'd47);     // sector 47
    write_reg(32'h1000_0120, 16'h00b6);   // cylinder 1462 low
    write_reg(32'h1000_0128, 16'h0005);   // cylinder 1462 high
    write_reg(32'h1000_0130, 16'h000c);   // head 12, LBA-mode bit clear
    write_reg(32'h1000_0138, 16'h0020);
    @(posedge clk);
    #1;
    if (!sd_rd || sd_lba != 32'd893892)
      $fatal(1, "KI2 final CHS translation -> %0d, expected 893892", sd_lba);

    $display("tb_ki_ata: PASS");
    $finish;
  end
endmodule
