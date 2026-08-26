`timescale 1ns/1ps

module tb_dcs_pm_ram_primitive;
    localparam integer ADDR_WIDTH = 6;
    localparam integer DEPTH = 1 << ADDR_WIDTH;

    reg                   clk = 1'b0;
    reg                   cpu_ce = 1'b0;
    reg  [ADDR_WIDTH-1:0] fetch_addr = {ADDR_WIDTH{1'b0}};
    reg  [ADDR_WIDTH-1:0] pmb_addr = {ADDR_WIDTH{1'b0}};
    reg                   pm_we = 1'b0;
    reg  [2:0]            pm_be = 3'b000;
    reg  [ADDR_WIDTH-1:0] pm_wa = {ADDR_WIDTH{1'b0}};
    reg  [23:0]           pm_wd = 24'h000000;
    wire [23:0]           dut_fetch_q;
    wire [23:0]           dut_pmb_q;

    reg [23:0] ref_pm [0:DEPTH-1];
    reg [23:0] ref_fetch_q;
    reg [23:0] ref_pmb_q;
    reg [23:0] ref_write_word;
    reg [7:0]  alias_old_low;
    integer errors = 0;
    integer i;

    always #5 clk = ~clk;

    always @* begin
        ref_write_word = ref_pm[pm_wa];
        if (pm_be[2]) ref_write_word[23:16] = pm_wd[23:16];
        if (pm_be[1]) ref_write_word[15:8] = pm_wd[15:8];
        if (pm_be[0]) ref_write_word[7:0] = pm_wd[7:0];
    end

    // This is the cycle contract of the original two-copy program store.
    always @(posedge clk) begin
        if (cpu_ce) begin
            ref_fetch_q <= ref_pm[fetch_addr];
            if (pm_we) begin
                ref_pmb_q <= ref_write_word;
                ref_pm[pm_wa] <= ref_write_word;
            end else begin
                ref_pmb_q <= ref_pm[pmb_addr];
            end
        end
    end

    // Candidate consolidated topology. Port A is the immediate data-side
    // read/write port; the ADSP already stages alias reads one instruction
    // state before committing a write. Read-only Port B registers its address
    // to reproduce the instruction-fetch latency. Quartus requires the complete
    // bidirectional Port B input group to use the same physical clock port.
    altsyncram #(
        .address_reg_b("CLOCK1"),
        .byteena_reg_b("CLOCK1"),
        .clock_enable_input_a("NORMAL"),
        .clock_enable_input_b("NORMAL"),
        .clock_enable_output_a("BYPASS"),
        .clock_enable_output_b("BYPASS"),
        .indata_reg_b("CLOCK1"),
        .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"),
        .numwords_a(DEPTH),
        .numwords_b(DEPTH),
        .operation_mode("BIDIR_DUAL_PORT"),
        .outdata_aclr_a("NONE"),
        .outdata_aclr_b("NONE"),
        .outdata_reg_a("UNREGISTERED"),
        .outdata_reg_b("UNREGISTERED"),
        .power_up_uninitialized("FALSE"),
        .ram_block_type("M10K"),
        .rdcontrol_reg_b("CLOCK1"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .wrcontrol_wraddress_reg_b("CLOCK1"),
        .widthad_a(ADDR_WIDTH),
        .widthad_b(ADDR_WIDTH),
        .width_a(24),
        .width_b(24),
        .width_byteena_a(3),
        .width_byteena_b(1)
    ) dut (
        .clock0(clk),
        .address_a(pm_we ? pm_wa : pmb_addr),
        .data_a(pm_wd),
        .byteena_a(pm_be),
        .wren_a(pm_we),
        .q_a(dut_pmb_q),
        .address_b(fetch_addr),
        .data_b(24'h000000),
        .byteena_b(1'b1),
        .wren_b(1'b0),
        .q_b(dut_fetch_q),
        .aclr0(1'b0),
        .aclr1(1'b0),
        .addressstall_a(1'b0),
        .addressstall_b(1'b0),
        .clock1(clk),
        .clocken0(cpu_ce),
        .clocken1(cpu_ce),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .eccstatus(),
        .rden_a(1'b1),
        .rden_b(1'b1)
    );

    task automatic drive_cycle;
        input                    ce;
        input [ADDR_WIDTH-1:0]  fa;
        input [ADDR_WIDTH-1:0]  ba;
        input                    we;
        input [2:0]              be;
        input [ADDR_WIDTH-1:0]  wa;
        input [23:0]            wd;
        begin
            @(negedge clk);
            cpu_ce = ce;
            fetch_addr = fa;
            pmb_addr = ba;
            pm_we = we;
            pm_be = be;
            pm_wa = wa;
            pm_wd = wd;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check_outputs;
        input [255:0] label;
        begin
            if (dut_fetch_q !== ref_fetch_q) begin
                $display("ERROR %0s fetch: dut=%06x ref=%06x", label,
                         dut_fetch_q, ref_fetch_q);
                errors = errors + 1;
            end
            if (dut_pmb_q !== ref_pmb_q) begin
                $display("ERROR %0s pmb: dut=%06x ref=%06x", label,
                         dut_pmb_q, ref_pmb_q);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Initialize every location through the same program-write port used by
        // the ADSP bootstrap. Read outputs are intentionally ignored here.
        for (i = 0; i < DEPTH; i = i + 1)
            drive_cycle(1'b1, 6'd0, 6'd0, 1'b1, 3'b111, i[ADDR_WIDTH-1:0],
                        24'h400000 + i);

        drive_cycle(1'b1, 6'd3, 6'd17, 1'b0, 3'b000, 6'd0, 24'h0);
        check_outputs("initial read");

        drive_cycle(1'b1, 6'd42, 6'd9, 1'b0, 3'b000, 6'd0, 24'h0);
        check_outputs("second read");

        // A disabled ADSP cycle must hold both outputs and suppress a write.
        drive_cycle(1'b0, 6'd1, 6'd2, 1'b1, 3'b111, 6'd9, 24'habcdef);
        check_outputs("clock-enable stall");
        drive_cycle(1'b1, 6'd9, 6'd9, 1'b0, 3'b000, 6'd0, 24'h0);
        check_outputs("stalled write suppressed");

        // Reproduce the DCS alias partial-write sequence using native byte
        // enables, then verify that the old low byte persists in RAM.
        drive_cycle(1'b1, 6'd31, 6'd23, 1'b0, 3'b000, 6'd0, 24'h0);
        check_outputs("prime alias source");
        alias_old_low = dut_pmb_q[7:0];
        drive_cycle(1'b1, 6'd23, 6'd7, 1'b1, 3'b110, 6'd23,
                    {16'h55aa, 8'h00});
        drive_cycle(1'b1, 6'd23, 6'd23, 1'b0, 3'b000, 6'd0, 24'h0);
        check_outputs("alias partial-write persists");
        if (dut_pmb_q !== {16'h55aa, alias_old_low}) begin
            $display("FAIL alias partial-write expected=%h got=%h",
                     {16'h55aa, alias_old_low}, dut_pmb_q);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "DCS program RAM primitive equivalence failed: %0d errors", errors);

        $display("DCS program RAM primitive equivalence: PASS");
        $finish;
    end
endmodule
