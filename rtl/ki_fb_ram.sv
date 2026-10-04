`default_nettype none

// The framebuffer store: two compact 19200 x 64-bit pages with byte enables.
//
// This is an EXPLICIT altsyncram instantiation rather than an inferred array,
// because Quartus 17.0 does not infer this memory in any form - not as one
// 64-bit array written by byte part-selects, nor as eight byte-wide arrays,
// with or without (* ramstyle = "M10K, no_rw_check" *). It builds registers
// instead, and silently: synthesis reports nothing about this file, and the
// ramstyle attribute is accepted without changing the outcome. A memory this
// size in flip-flops can never fit.
//
// Every other memory in this design is explicit for the same reason -
// rtl/cpu/RamMLAB.vhd and rtl/cpu/dpram.vhd both instantiate the primitive
// directly. This follows them.
//
// NUMWORDS is 38400, not 65536: the address is 16 bits because 38400 needs 16
// bits. The bridge compacts the board's two framebuffer ranges and leaves the
// intervening 10 KiB holes in external SDRAM.
//
// Both outputs are UNREGISTERED, which in altsyncram still means the address is
// registered and q appears one clock later - the same one-cycle read latency
// both read paths were written against.
//
// TRUE dual port, one port per requester. The bridge retries scanout when a
// CPU write targets the same qword, so mixed-port collision data is discarded.
//
// Port A belongs to the CPU and does both its reads and its writes. Port B
// belongs to scanout and only ever reads. Neither waits for the other.
//
// Scanout has its own port rather than going through the bridge's single state
// machine. Sharing one path would make it take its turn against the CPU through
// the same video_won_last arbitration that exists only because SDRAM has one
// port. An M10K does not have that constraint, so giving scanout its own port
// deletes the arbitration rather than adding to it.
//
// Keep every 16-bit pixel in a separate physical memory. Killer Instinct's
// shadow and translucency paths issue many masked pixel updates, and a physical
// word wider than one pixel would couple adjacent pixels. Four banks isolate
// every pixel update while retaining the same capacity, addresses, and
// one-cycle read latency.
//
// Each bank contains one quarter of the framebuffer bits. The expected
// aggregate cost is 320 M10Ks.
module ki_fb_ram #(
  parameter integer WORDS = 38400
) (
  input  wire        clock,

  // Port A: the CPU. Reads and writes, byte enables on the write.
  input  wire [15:0] cpu_address,
  input  wire [63:0] cpu_data,
  input  wire  [7:0] cpu_byteena,
  input  wire        cpu_wren,
  output wire [63:0] cpu_q,

  // Port B: scanout. Read only, never blocked.
  input  wire [15:0] vid_address,
  output wire [63:0] vid_q
);

  wire [15:0] cpu_q0;
  wire [15:0] cpu_q1;
  wire [15:0] cpu_q2;
  wire [15:0] cpu_q3;
  wire [15:0] vid_q0;
  wire [15:0] vid_q1;
  wire [15:0] vid_q2;
  wire [15:0] vid_q3;

  assign cpu_q = {cpu_q3, cpu_q2, cpu_q1, cpu_q0};
  assign vid_q = {vid_q3, vid_q2, vid_q1, vid_q0};

  ki_fb_ram_bank #(.WORDS(WORDS)) pixel0_bank (
    .clock       (clock),
    .cpu_address (cpu_address),
    .cpu_data    (cpu_data[15:0]),
    .cpu_byteena (cpu_byteena[1:0]),
    .cpu_wren    (cpu_wren && (|cpu_byteena[1:0])),
    .cpu_q       (cpu_q0),
    .vid_address (vid_address),
    .vid_q       (vid_q0)
  );

  ki_fb_ram_bank #(.WORDS(WORDS)) pixel1_bank (
    .clock       (clock),
    .cpu_address (cpu_address),
    .cpu_data    (cpu_data[31:16]),
    .cpu_byteena (cpu_byteena[3:2]),
    .cpu_wren    (cpu_wren && (|cpu_byteena[3:2])),
    .cpu_q       (cpu_q1),
    .vid_address (vid_address),
    .vid_q       (vid_q1)
  );

  ki_fb_ram_bank #(.WORDS(WORDS)) pixel2_bank (
    .clock       (clock),
    .cpu_address (cpu_address),
    .cpu_data    (cpu_data[47:32]),
    .cpu_byteena (cpu_byteena[5:4]),
    .cpu_wren    (cpu_wren && (|cpu_byteena[5:4])),
    .cpu_q       (cpu_q2),
    .vid_address (vid_address),
    .vid_q       (vid_q2)
  );

  ki_fb_ram_bank #(.WORDS(WORDS)) pixel3_bank (
    .clock       (clock),
    .cpu_address (cpu_address),
    .cpu_data    (cpu_data[63:48]),
    .cpu_byteena (cpu_byteena[7:6]),
    .cpu_wren    (cpu_wren && (|cpu_byteena[7:6])),
    .cpu_q       (cpu_q3),
    .vid_address (vid_address),
    .vid_q       (vid_q3)
  );

endmodule

module ki_fb_ram_bank #(
  parameter integer WORDS = 38400
) (
  input  wire        clock,
  input  wire [15:0] cpu_address,
  input  wire [15:0] cpu_data,
  input  wire  [1:0] cpu_byteena,
  input  wire        cpu_wren,
  output wire [15:0] cpu_q,
  input  wire [15:0] vid_address,
  output wire [15:0] vid_q
);

  // Parameters are passed inline rather than through defparam. This binds to
  // both the Verilog and VHDL altera_mf models used by the test benches.
  altsyncram #(
    .address_reg_b                      ("CLOCK0"),
    .byte_size                          (8),
    .clock_enable_input_a               ("BYPASS"),
    .clock_enable_input_b               ("BYPASS"),
    .clock_enable_output_a              ("BYPASS"),
    .clock_enable_output_b              ("BYPASS"),
    .indata_reg_b                       ("CLOCK0"),
    .intended_device_family             ("Cyclone V"),
    .lpm_type                           ("altsyncram"),
    .numwords_a                         (WORDS),
    .numwords_b                         (WORDS),
    .operation_mode                     ("BIDIR_DUAL_PORT"),
    .outdata_aclr_a                     ("NONE"),
    .outdata_aclr_b                     ("NONE"),
    .outdata_reg_a                      ("UNREGISTERED"),
    .outdata_reg_b                      ("UNREGISTERED"),
    .power_up_uninitialized             ("FALSE"),
    .ram_block_type                     ("M10K"),
    // OLD_DATA, not DONT_CARE. This is the contract SDRAM gave implicitly and
    // an M10K does not.
    //
    // With SDRAM a read and a write to the same location are serialised by the
    // controller, so scanout always got a coherent word - the value before the
    // write or the value after it, never anything else. Two independent RAM
    // ports have no such ordering, and under DONT_CARE a port B read of the
    // address port A is writing in the SAME cycle returns UNDEFINED data.
    //
    // OLD_DATA makes the read deterministic. Cyclone V M10K supports it for
    // mixed ports when both are on one clock, which is the case here.
    .read_during_write_mode_mixed_ports ("OLD_DATA"),
    .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
    .widthad_a                          (16),
    .widthad_b                          (16),
    .width_a                            (16),
    .width_b                            (16),
    .width_byteena_a                    (2),
    .width_byteena_b                    (1),
    .wrcontrol_wraddress_reg_b          ("CLOCK0")
  ) altsyncram_component (
    .clock0     (clock),

    .address_a  (cpu_address),
    .data_a     (cpu_data),
    .byteena_a  (cpu_byteena),
    .wren_a     (cpu_wren),
    .q_a        (cpu_q),

    .address_b  (vid_address),
    .data_b     ({16{1'b1}}),
    .byteena_b  (1'b1),
    .wren_b     (1'b0),
    .q_b        (vid_q),

    .aclr0      (1'b0),
    .aclr1      (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .clock1     (1'b1),
    .clocken0   (1'b1),
    .clocken1   (1'b1),
    .clocken2   (1'b1),
    .clocken3   (1'b1),
    .eccstatus  (),
    .rden_a     (1'b1),
    .rden_b     (1'b1)
  );

endmodule

`default_nettype wire
