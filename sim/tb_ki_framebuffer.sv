// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`default_nettype none

module tb_ki_framebuffer;
  localparam int unsigned LINE_WORDS = 80;
  localparam int unsigned WORDS_PER_REQUEST = 4;
  localparam int unsigned REQUESTS_PER_LINE = LINE_WORDS / WORDS_PER_REQUEST;

  // The core-generated framebuffer pattern is off for every test
  // here: these benches check the GAME's data path.
  logic fb_test_pattern = 1'b0;
  logic fb_read_accept;
  logic fb_write_accept;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic ce_pixel = 1'b0;
  logic [9:0] h_count = 10'd0;
  logic [9:0] v_count = 10'd0;
  logic [18:0] framebuffer_base = 19'h3_0000;
  wire memory_request;
  wire [27:0] memory_address;
  wire [2:0] memory_words;
  logic [63:0] memory_data = 64'd0;
  logic memory_data_valid = 1'b0;
  logic memory_done = 1'b0;
  wire [7:0] red;
  wire [7:0] green;
  wire [7:0] blue;
  wire pixel_valid;

  always #5 clk = !clk;

  ki_framebuffer dut (.*);

  // One request, served the way ki_memory_bridge does: `memory_words` beats
  // with memory_data_valid, each STRICTLY before memory_done. Raising done
  // alongside the last beat would let the framebuffer start the next fetch
  // with a word still in flight.
  task automatic service_request(
    input [27:0] expected_address,
    input [63:0] word0,
    input [63:0] word1,
    input [63:0] word2,
    input [63:0] word3
  );
    logic [63:0] words [0:3];
    begin
      words[0] = word0;
      words[1] = word1;
      words[2] = word2;
      words[3] = word3;
      while (!memory_request) @(negedge clk);
      if (memory_address != expected_address)
        $fatal(1, "framebuffer address %07h, expected %07h",
               memory_address, expected_address);
      if (memory_words != WORDS_PER_REQUEST[2:0])
        $fatal(1, "framebuffer asked for %0d words, expected %0d",
               memory_words, WORDS_PER_REQUEST);

      memory_data_valid = 1'b1;
      for (int beat = 0; beat < WORDS_PER_REQUEST; beat++) begin
        memory_data = words[beat];
        @(posedge clk);
        #1;
        @(negedge clk);
      end
      memory_data_valid = 1'b0;

      memory_done = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      memory_done = 1'b0;
      while (memory_request) @(negedge clk);
    end
  endtask

  // Word 0 carries the caller's pattern; every later word alternates red and
  // green so a line that is shifted by one word - the shape a duplicated or
  // dropped request produces - shows up as a colour swap rather than passing.
  function automatic [63:0] filler(input integer word);
    filler = word[0] ? {4{16'h03e0}} : {4{16'h001f}};
  endfunction

  task automatic service_line(
    input [18:0] page,
    input [7:0] line,
    input [63:0] first_word
  );
    logic [27:0] base_address;
    logic [63:0] words [0:3];
    integer word;
    begin
      base_address = {9'd0, page} + (line * 28'd640);
      for (int request = 0; request < REQUESTS_PER_LINE; request++) begin
        for (int k = 0; k < WORDS_PER_REQUEST; k++) begin
          word = request * WORDS_PER_REQUEST + k;
          words[k] = (word == 0) ? first_word : filler(word);
        end
        service_request(base_address + request * WORDS_PER_REQUEST * 8,
                        words[0], words[1], words[2], words[3]);
      end
      repeat (2) @(posedge clk);
    end
  endtask

  // The raster has just ENTERED `line`: ki_video_timing advances h_count,
  // v_count and ce_pixel on the same edge, so h_count == 0 with ce_pixel high
  // is the first pixel of the line v_count already names. That is where
  // ki_framebuffer queues the following line, giving its fetch a whole
  // scanline. Keep this in step with ki_framebuffer's line_boundary.
  task automatic start_line(input [9:0] line);
    begin
      @(negedge clk);
      h_count = 10'd0;
      v_count = line;
      ce_pixel = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      ce_pixel = 1'b0;
    end
  endtask

  task automatic check_pixel(
    input [8:0] x,
    input [7:0] expected_red,
    input [7:0] expected_green,
    input [7:0] expected_blue
  );
    begin
      // The line RAM captures the next pixel address on the edge that advances
      // h_count. Model that transition explicitly when sampling a static pixel.
      h_count = (x == 0) ? 10'd319 : ({1'b0, x} - 1'b1);
      @(posedge clk);
      h_count = {1'b0, x};
      #1;
      if (!pixel_valid || red != expected_red || green != expected_green ||
          blue != expected_blue)
        $fatal(1, "pixel %0d = %02h/%02h/%02h valid=%0d",
               x, red, green, blue, pixel_valid);
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    reset = 1'b0;

    // Four pixels: red, green, blue, white in KI's xBBBBBGGGGGRRRRR order.
    service_line(19'h3_0000, 8'd0,
                 {16'h7fff, 16'h7c00, 16'h03e0, 16'h001f});
    v_count = 10'd0;
    check_pixel(9'd0, 8'hff, 8'h00, 8'h00);
    check_pixel(9'd1, 8'h00, 8'hff, 8'h00);
    check_pixel(9'd2, 8'h00, 8'h00, 8'hff);
    check_pixel(9'd3, 8'hff, 8'hff, 8'hff);
    // Words 4 and 5, i.e. the second and third request of the line. A line
    // that lost or repeated a request lands the wrong filler here.
    check_pixel(9'd16, 8'hff, 8'h00, 8'h00);
    check_pixel(9'd20, 8'h00, 8'hff, 8'h00);

    start_line(10'd0);
    service_line(19'h3_0000, 8'd1,
                 {16'h0000, 16'h0000, 16'h0000, 16'h7c1f});
    v_count = 10'd1;
    check_pixel(9'd0, 8'hff, 8'h00, 8'hff);

    // A page change during vblank must refetch line zero from the new page.
    @(negedge clk);
    v_count = 10'd240;
    framebuffer_base = 19'h5_8000;
    service_line(19'h5_8000, 8'd0,
                 {16'h0000, 16'h0000, 16'h0000, 16'h03ff});
    v_count = 10'd0;
    check_pixel(9'd0, 8'hff, 8'hff, 8'h00);

    h_count = 10'd320;
    #1;
    if (pixel_valid) $fatal(1, "pixel remained valid outside active width");

    $display("tb_ki_framebuffer: PASS");
    $finish;
  end

  // Three line fetches are ~60 requests of a handful of cycles each. Anything
  // near this is a handshake that stopped advancing, and without the watchdog
  // it spins until the suite's own wall-clock limit with no clue where.
  initial begin
    #200000;
    $fatal(1, "tb_ki_framebuffer timeout: request=%0d address=%07h words=%0d",
           memory_request, memory_address, memory_words);
  end
endmodule

`default_nettype wire
