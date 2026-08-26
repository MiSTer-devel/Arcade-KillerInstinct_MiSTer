// SPDX-License-Identifier: GPL-3.0-only
//
// Behavioral Micron MT48LC16M16A2 model for the KI SDRAM path, derived from the
// wolf-unit measurement model with two changes that matter for this core:
//
//  1. REAL ACCESS TIME. The donor model drives DQ registered on its own clock
//     edge, so read data is valid *going into* the controller's capture edge -
//     it models tAC = 0. That is precisely why every existing KI testbench
//     passes while hardware returns garbage: a read-capture window error is
//     invisible to a zero-access-time part. Here DQ is driven TAC_NS after the
//     device clock edge, which is what a real part does, so the SDRAM_CLK phase
//     shift becomes load-bearing in simulation too.
//
//  2. NO ADDRESS ALIASING. The donor folded the address into a 1M-word backing
//     store via {ba, row[7:0], col[9:0]}, which aliases heavily under the KI
//     address mapping (row = addr[13:1], col = addr[22:14]). A sparse
//     associative array stores the full 24-bit word address exactly, so a
//     read-back mismatch means a real data or timing fault rather than an
//     artifact of the model.
//
// Caveat: this models the DEVICE only. FPGA pad delay, board trace delay and
// input-register setup are not represented, so a passing margin here is
// necessary but not sufficient for silicon. Treat it as a directional
// predictor, not a substitute for the on-hardware BIST.
`timescale 1ns/1ps

module mt48lc16m16_ki #(
    parameter real TRCD_NS  = 18.0,
    parameter real TRP_NS   = 18.0,
    parameter real TRC_NS   = 60.0,
    parameter real TAC_NS   = 6.0,   // CL2 access time from clock edge
    parameter integer CAS   = 2,
    parameter integer ADDR_BITS = 13
)(
    input                  clk,
    inout      [15:0]      dq,
    input  [ADDR_BITS-1:0] addr,
    input       [1:0]      ba,
    input                  nCS,
    input                  nRAS,
    input                  nCAS,
    input                  nWE,
    input       [1:0]      dqm,
    input                  cke
);
    localparam [3:0] C_LOADMODE  = 4'b0000;
    localparam [3:0] C_REFRESH   = 4'b0001;
    localparam [3:0] C_PRECHARGE = 4'b0010;
    localparam [3:0] C_ACTIVE    = 4'b0011;
    localparam [3:0] C_WRITE     = 4'b0100;
    localparam [3:0] C_READ      = 4'b0101;
    localparam [3:0] C_NOP       = 4'b0111;

    wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};

    reg  [ADDR_BITS-1:0] open_row [0:3];
    reg                  row_active [0:3];
    real                 t_active   [0:3];
    real                 t_precharge[0:3];

    // Sparse exact backing store, keyed by {bank, row, col}.
    logic [15:0] mem [logic [31:0]];

    reg [15:0] read_pipe [0:CAS];
    reg        read_vld  [0:CAS];
    integer    p;

    reg [15:0] dq_drv;
    reg        dq_oe;
    assign dq = dq_oe ? dq_drv : 16'bZ;

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            row_active[i]  = 1'b0;
            t_active[i]    = -1e9;
            t_precharge[i] = -1e9;
        end
        for (p = 0; p <= CAS; p = p + 1) begin
            read_vld[p] = 1'b0;
            read_pipe[p] = 16'h0;
        end
        dq_oe = 1'b0;
        dq_drv = 16'h0;
    end

    // Column is 9 bits on this part; A[10] is auto-precharge, not address.
    function automatic [31:0] key(
        input [1:0] b,
        input [ADDR_BITS-1:0] r,
        input [ADDR_BITS-1:0] c
    );
        key = {8'd0, b, r, c[8:0]};
    endfunction

    always @(posedge clk) begin
        // Drive the just-loaded pipeline slot so DQ is valid TAC_NS after this
        // edge, matching a real CL2 part rather than one cycle later.
        if (read_vld[CAS]) begin
            dq_drv <= #(TAC_NS) read_pipe[CAS];
            dq_oe  <= #(TAC_NS) 1'b1;
        end else begin
            dq_oe  <= #(TAC_NS) 1'b0;
        end
        for (p = 0; p < CAS; p = p + 1) begin
            read_pipe[p] <= read_pipe[p+1];
            read_vld[p]  <= read_vld[p+1];
        end
        read_vld[CAS] <= 1'b0;

        if (cke) begin
            case (cmd)
                C_ACTIVE: begin
                    if ($realtime - t_precharge[ba] + 0.001 < TRP_NS)
                        $fatal(1, "[MT48] tRP VIOLATION bank%0d: ACTIVE only %.1fns after PRECHARGE (need %.1f) @%0t",
                               ba, $realtime - t_precharge[ba], TRP_NS, $realtime);
                    if ($realtime - t_active[ba] + 0.001 < TRC_NS)
                        $fatal(1, "[MT48] tRC VIOLATION bank%0d: %.1fns since last ACTIVE (need %.1f) @%0t",
                               ba, $realtime - t_active[ba], TRC_NS, $realtime);
                    open_row[ba]   <= addr;
                    row_active[ba] <= 1'b1;
                    t_active[ba]   <= $realtime;
                end
                C_READ: begin
                    if (!row_active[ba])
                        $fatal(1, "[MT48] READ to closed bank%0d @%0t", ba, $realtime);
                    if ($realtime - t_active[ba] + 0.001 < TRCD_NS)
                        $fatal(1, "[MT48] tRCD VIOLATION bank%0d: READ %.1fns after ACTIVE (need %.1f) @%0t",
                               ba, $realtime - t_active[ba], TRCD_NS, $realtime);
                    if (mem.exists(key(ba, open_row[ba], addr)))
                        read_pipe[CAS] <= mem[key(ba, open_row[ba], addr)];
                    else
                        read_pipe[CAS] <= 16'hdead;
                    read_vld[CAS] <= 1'b1;
                    if (addr[10]) begin
                        row_active[ba] <= 1'b0;
                        t_precharge[ba] <= $realtime;
                    end
                end
                C_WRITE: begin
                    if (!row_active[ba])
                        $fatal(1, "[MT48] WRITE to closed bank%0d @%0t", ba, $realtime);
                    if ($realtime - t_active[ba] + 0.001 < TRCD_NS)
                        $fatal(1, "[MT48] tRCD VIOLATION bank%0d: WRITE %.1fns after ACTIVE (need %.1f) @%0t",
                               ba, $realtime - t_active[ba], TRCD_NS, $realtime);
                    begin
                        logic [31:0] k;
                        logic [15:0] cur;
                        k = key(ba, open_row[ba], addr);
                        cur = mem.exists(k) ? mem[k] : 16'h0000;
                        if (!dqm[0]) cur[7:0]  = dq[7:0];
                        if (!dqm[1]) cur[15:8] = dq[15:8];
                        mem[k] = cur;
                    end
                    if (addr[10]) begin
                        row_active[ba] <= 1'b0;
                        t_precharge[ba] <= $realtime;
                    end
                end
                C_PRECHARGE: begin
                    if (addr[10]) begin
                        for (i = 0; i < 4; i = i + 1) begin
                            row_active[i] <= 1'b0;
                            t_precharge[i] <= $realtime;
                        end
                    end else begin
                        row_active[ba] <= 1'b0;
                        t_precharge[ba] <= $realtime;
                    end
                end
                C_REFRESH:  ;
                C_LOADMODE: ;
                C_NOP:      ;
                default:    ;
            endcase
        end
    end
endmodule
