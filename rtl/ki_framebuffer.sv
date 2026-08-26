// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_line_buffer (
  input  wire         clk,
  input  wire   [8:0] read_address,
  output wire  [15:0] read_data,
  input  wire         write_enable,
  input  wire   [6:0] write_address,
  input  wire  [63:0] write_data
);
`ifdef ALTERA_RESERVED_QIS
  altsyncram line_ram (
    .clock0(clk),
    .address_a(write_address),
    .data_a(write_data),
    .wren_a(write_enable),
    .byteena_a(1'b1),
    .q_a(),

    .clock1(clk),
    .address_b(read_address),
    .data_b(16'h0000),
    .wren_b(1'b0),
    .byteena_b(1'b1),
    .q_b(read_data),

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
    line_ram.numwords_a = 80,
    line_ram.widthad_a = 7,
    line_ram.width_a = 64,
    line_ram.width_byteena_a = 1,
    line_ram.numwords_b = 320,
    line_ram.widthad_b = 9,
    line_ram.width_b = 16,
    line_ram.width_byteena_b = 1,
    line_ram.address_reg_b = "CLOCK1",
    line_ram.clock_enable_input_a = "BYPASS",
    line_ram.clock_enable_input_b = "BYPASS",
    line_ram.clock_enable_output_a = "BYPASS",
    line_ram.clock_enable_output_b = "BYPASS",
    line_ram.indata_reg_b = "CLOCK1",
    line_ram.intended_device_family = "Cyclone V",
    line_ram.lpm_type = "altsyncram",
    line_ram.operation_mode = "DUAL_PORT",
    line_ram.outdata_aclr_a = "NONE",
    line_ram.outdata_aclr_b = "NONE",
    line_ram.outdata_reg_a = "UNREGISTERED",
    line_ram.outdata_reg_b = "UNREGISTERED",
    line_ram.power_up_uninitialized = "FALSE",
    line_ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    line_ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
  logic [15:0] simulation_ram [0:319];
  logic [8:0] simulation_read_address;
  assign read_data = simulation_ram[simulation_read_address];

  always_ff @(posedge clk) begin
    simulation_read_address <= read_address;
    if (write_enable) begin
      simulation_ram[{write_address, 2'b00} + 0] <= write_data[15:0];
      simulation_ram[{write_address, 2'b00} + 1] <= write_data[31:16];
      simulation_ram[{write_address, 2'b00} + 2] <= write_data[47:32];
      simulation_ram[{write_address, 2'b00} + 3] <= write_data[63:48];
    end
  end
`endif
endmodule

module ki_framebuffer (
  input  wire         clk,
  input  wire         reset,
  input  wire         ce_pixel,
  input  wire   [9:0] h_count,
  input  wire   [9:0] v_count,
  input  wire  [18:0] framebuffer_base,

  output logic        memory_request,
  output logic [27:0] memory_address,
  output wire   [2:0] memory_words,
  input  wire  [63:0] memory_data,
  input  wire         memory_data_valid,
  input  wire         memory_done,

  output logic  [7:0] red,
  output logic  [7:0] green,
  output logic  [7:0] blue,
  output logic        pixel_valid
);
  import ki_board_pkg::*;

  // 320 pixels x 16 bpp = 640 bytes = 80 64-bit words per visible line.
  localparam int unsigned LINE_WORDS = 80;
  // 64-bit words per memory request. Four is the widest burst the bridge and
  // ki_sdram_burst accept (16 x 16-bit), so a line costs 20 round trips
  // instead of 80. The round trip - arbitration against the CPU, then
  // ACTIVE/CAS/precharge - dominates, so this is close to a 3x cut in line
  // fetch time and is what keeps the fetch inside its scanline under load.
  localparam int unsigned WORDS_PER_REQUEST = 4;

  logic        fetch_active;
  logic        issue_next;
  logic  [7:0] fetch_line;
  logic        fetch_bank;
  logic  [6:0] fetch_word;
  logic  [6:0] fetch_issue_word;
  logic [27:0] fetch_line_address;
  logic [18:0] fetch_page;

  logic        pending_valid;
  logic  [7:0] pending_line;
  logic [18:0] pending_page;
  logic [18:0] framebuffer_base_d;

  logic  [7:0] line_tag [0:1];
  logic [18:0] page_tag [0:1];
  logic  [1:0] line_ready;

  wire line_boundary = ce_pixel && (h_count == 10'd0);
  wire write_line = fetch_active && memory_data_valid;
  assign memory_words = WORDS_PER_REQUEST[2:0];
  wire [8:0] line_read_address = (h_count < 319) ?
                                 (h_count[8:0] + 1'b1) : 9'd0;
  wire [15:0] bank0_pixel;
  wire [15:0] bank1_pixel;
  wire [15:0] pixel = v_count[0] ? bank1_pixel : bank0_pixel;

  function automatic [27:0] first_word_address(
    input logic [18:0] page,
    input logic  [7:0] line
  );
    logic [27:0] line_value;
    begin
      line_value = {20'd0, line};
      first_word_address = {9'd0, page} +
                           (line_value << 9) + (line_value << 7);
    end
  endfunction

  ki_line_buffer line_buffer_0 (
    .clk(clk),
    .read_address(line_read_address),
    .read_data(bank0_pixel),
    .write_enable(write_line && !fetch_bank),
    .write_address(fetch_word),
    .write_data(memory_data)
  );

  ki_line_buffer line_buffer_1 (
    .clk(clk),
    .read_address(line_read_address),
    .read_data(bank1_pixel),
    .write_enable(write_line && fetch_bank),
    .write_address(fetch_word),
    .write_data(memory_data)
  );

  always_comb begin
    memory_address = fetch_line_address + {18'd0, fetch_issue_word, 3'b000};
    pixel_valid = (h_count < 320) && (v_count < 240) &&
                  line_ready[v_count[0]] &&
                  (line_tag[v_count[0]] == v_count[7:0]) &&
                  (page_tag[v_count[0]] == framebuffer_base);
    red   = 8'h00;
    green = 8'h00;
    blue  = 8'h00;
    if (pixel_valid) begin
      red   = {pixel[4:0], pixel[4:2]};
      green = {pixel[9:5], pixel[9:7]};
      blue  = {pixel[14:10], pixel[14:12]};
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      memory_request    <= 1'b0;
      fetch_active      <= 1'b0;
      issue_next        <= 1'b0;
      fetch_line        <= 8'd0;
      fetch_bank        <= 1'b0;
      fetch_word        <= 7'd0;
      fetch_issue_word  <= 7'd0;
      fetch_line_address <= 28'd0;
      fetch_page        <= KI_FB_PAGE0;
      pending_valid     <= 1'b1;
      pending_line      <= 8'd0;
      pending_page      <= KI_FB_PAGE0;
      framebuffer_base_d <= KI_FB_PAGE0;
      line_tag[0]       <= 8'd0;
      line_tag[1]       <= 8'd0;
      page_tag[0]       <= KI_FB_PAGE0;
      page_tag[1]       <= KI_FB_PAGE0;
      line_ready        <= 2'b00;
    end else begin
      framebuffer_base_d <= framebuffer_base;

      if (line_boundary && (v_count < 240)) begin
        if (v_count == 239) begin
          pending_line <= 8'd0;
          pending_page <= framebuffer_base;
        end else begin
          pending_line <= v_count[7:0] + 1'b1;
          pending_page <= framebuffer_base;
        end
        pending_valid <= 1'b1;
      end

      if ((framebuffer_base != framebuffer_base_d) && (v_count >= 240)) begin
        pending_line  <= 8'd0;
        pending_page  <= framebuffer_base;
        pending_valid <= 1'b1;
      end

      // Words arrive one per beat of the burst, independently of the request
      // handshake below, so the line-buffer write pointer advances here. The
      // bridge guarantees every beat strictly precedes memory_done, so this
      // can never collide with the start of the following fetch.
      if (write_line)
        fetch_word <= fetch_word + 1'b1;

      if (memory_done && memory_request) begin
        memory_request <= 1'b0;
        if (fetch_issue_word >= (LINE_WORDS - WORDS_PER_REQUEST)) begin
          fetch_active <= 1'b0;
          line_ready[fetch_bank] <= 1'b1;
          line_tag[fetch_bank] <= fetch_line;
          page_tag[fetch_bank] <= fetch_page;
        end else begin
          fetch_issue_word <= fetch_issue_word + WORDS_PER_REQUEST[6:0];
          issue_next <= 1'b1;
        end
      end else if (issue_next) begin
        memory_request <= 1'b1;
        issue_next <= 1'b0;
      end else if (!fetch_active && pending_valid) begin
        fetch_active <= 1'b1;
        fetch_line <= pending_line;
        fetch_bank <= pending_line[0];
        fetch_word <= 7'd0;
        fetch_issue_word <= 7'd0;
        fetch_page <= pending_page;
        fetch_line_address <= first_word_address(pending_page, pending_line);
        memory_request <= 1'b1;
        pending_valid <= 1'b0;
        line_ready[pending_line[0]] <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
