// SPDX-License-Identifier: GPL-3.0-only
// Hardware is the default build. Testbenches must explicitly define
// KI_DCS_SIMULATION to enable behavioral memories and simulation checks.
`ifndef KI_DCS_SIMULATION
`ifndef SYNTHESIS
`define SYNTHESIS 1
`endif
`endif
// DCS sound-ROM service with a direct-mapped prefetch cache.
//
// The requester holds rom_req and rom_addr stable until rom_rdy. A cache miss
// fetches one aligned 64-bit beat from external memory, fills the selected line,
// and returns the requested byte. Completed fills remain valid if an interrupt
// or other control transfer abandons the original request.
//
// KI's eight 512 KiB sound ROMs sit in a sparse data space: rom_addr[22:20]
// selects one of eight 1 MiB windows, a ROM fills the lower half of its window,
// and the upper half (rom_addr[19] set) reads as 0xFF with no external access.
// The external port serves the ROMs packed back to back as a 4 MiB image. ADSP
// program and data memories are local to adsp2105.sv.
module dcs_mem #(
    parameter PF_LINES = 512            // 8-byte cache lines; must be a power of two
) (
    input  wire        clk,
    input  wire        rst,         // invalidate cache on board/core reset
    input  wire        core_ce,     // the cache FSM advances on core_ce only
    // ---- Sound-ROM byte port -------------------------------------------------
    // Level protocol: requester holds rom_req=1 with rom_addr stable; rom_rdy
    // goes (and stays) 1 with rom_q valid once the byte is available, for as
    // long as rom_req is held at that same address. Changing rom_addr (or
    // dropping rom_req) restarts/releases the port.
    input  wire        rom_req,
    input  wire [22:0] rom_addr,
    output wire        rom_rdy,
    output wire [7:0]  rom_q,
    // Packed 4 MiB backing. Address is a 64-bit beat offset within the 4 MB
    // image. Hold ext_req until ext_rdy; ext_q is consumed on that cycle.
    output wire        ext_req,
    output wire [18:0] ext_addr,
    input  wire        ext_rdy,
    input  wire [63:0] ext_q
);
    // ======================================================================
    // Prefetch cache and external-memory round trip
    // ----------------------------------------------------------------------
    // Direct-mapped, 8-byte lines (= one DDR3 beat). Index =
    // addr[3 +: IDXW] (the offset within a 4 KB bank page when PF_LINES=512),
    // tag = the remaining high bits, so bank switches are handled by tag
    // mismatch -- no flush needed, and boot pages / data pages share the
    // cache correctly. Storage is BRAM-shaped: one clocked read (the lookup
    // cycle) and one write (the fill) per clock.
    // ======================================================================
    localparam IDXW = $clog2(PF_LINES);
    localparam TAGW = 20 - IDXW;              // 23-bit logical addr - 3 offset - IDXW index

    // Registered reads and the explicit RAM style map the cache data and tags
    // into M10K blocks instead of combinational register-array muxes.
    (* ramstyle = "no_rw_check, M10K" *) reg [63:0]     pf_data [0:PF_LINES-1]; // line data (byte i at [8*i +: 8])
    (* ramstyle = "no_rw_check, M10K" *) reg [TAGW-1:0] pf_tag  [0:PF_LINES-1];
    reg                                  pf_valid[0:PF_LINES-1]; // 512x1: keep as regs (M10K wasteful)

    localparam [2:0] R_IDLE=3'd0, R_ADDR=3'd1, R_LOOK=3'd2, R_FILL=3'd3, R_SERVE=3'd4;
    reg [2:0]  rstate = R_IDLE;
    reg [22:0] srv_addr;         // logical address being served (latched at lookup)
    reg [7:0]  srv_byte;         // the served byte (rom_q)
    // Registered cache reads are addressed by srv_idx. R_ADDR accounts for the
    // M10K read latency before R_LOOK consumes the data, tag, and valid bit.
    reg [63:0]     pfd_q;        // registered pf_data [srv_idx]
    reg [TAGW-1:0] pft_q;        // registered pf_tag  [srv_idx]
    reg            pfv_q;        // registered pf_valid[srv_idx]
    // External DDR responses are one clk pulse. When the ADSP itself advances
    // on a slower clock-enable, retain that pulse until the cache FSM consumes
    // it; otherwise an accepted Avalon response could be lost between CE slots.
    reg            ext_rsp_valid;
    reg [63:0]     ext_rsp_q;

    wire [IDXW-1:0] srv_idx = srv_addr[3 +: IDXW];
    wire [TAGW-1:0] srv_tag = srv_addr[22 -: TAGW];
    // Packed byte address: window select with the gap bit removed.
    wire [21:0] srv_packed_addr = {srv_addr[22:20], srv_addr[18:0]};
    wire        srv_ki_gap = srv_addr[19];
    // The beat that fills the selected line: all ones in the empty half of a
    // window, otherwise the captured external response.
    wire [63:0] fill_beat = srv_ki_gap ? 64'hffff_ffff_ffff_ffff : ext_rsp_q;

    assign rom_rdy = (rstate == R_SERVE) && rom_req && (rom_addr == srv_addr);
    assign rom_q   = srv_byte;
    // Drop the request as soon as a response is captured, not only when the
    // slowed FSM reaches its next CE edge. This prevents the one-outstanding
    // Avalon adapter from issuing a duplicate beat request.
    assign ext_req  = (rstate == R_FILL) && !srv_ki_gap && !ext_rsp_valid;
    assign ext_addr = srv_packed_addr[21:3];

    // Unconditional registered read of the cache stores (M10K read port). Reads
    // srv_idx every clock; the value is valid one clock later (consumed in R_LOOK,
    // which R_ADDR delays to). Write side is the R_FILL fill in the FSM below ->
    // simple dual-port (1 write / 1 read) per store -> maps to M10K, not a mux.
    always @(posedge clk) begin
        if (core_ce) begin
            pfd_q <= pf_data [srv_idx];
            pft_q <= pf_tag  [srv_idx];
            pfv_q <= pf_valid[srv_idx];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            ext_rsp_valid <= 1'b0;
            ext_rsp_q     <= 64'd0;
        end else begin
            if (ext_rdy && (rstate == R_FILL) && !ext_rsp_valid) begin
                ext_rsp_valid <= 1'b1;
                ext_rsp_q     <= ext_q;
            end else if (core_ce && (rstate == R_FILL) && ext_rsp_valid) begin
                ext_rsp_valid <= 1'b0;
            end
        end
    end

    integer ri;
    always @(posedge clk) begin
        if (rst) begin
            rstate   <= R_IDLE;
            srv_addr <= '0;
            srv_byte <= 8'h00;
            for (ri = 0; ri < PF_LINES; ri = ri + 1)
                pf_valid[ri] <= 1'b0;
        end else if (core_ce) case (rstate)
          R_IDLE: if (rom_req) begin
              // latch the request; R_ADDR waits one clock for the registered
              // (M10K) read of srv_idx to land in pfd_q/pft_q/pfv_q.
              srv_addr <= rom_addr;
              rstate   <= R_ADDR;
          end
          R_ADDR: rstate <= R_LOOK;   // pfd_q/pft_q/pfv_q now = *[srv_idx]
          R_LOOK: begin
              if (pfv_q && (pft_q == srv_tag)) begin
                  srv_byte <= pfd_q[8*srv_addr[2:0] +: 8];
                  rstate <= R_SERVE;
              end else begin
                  // A miss raises ext_req in R_FILL and waits for ext_rdy.
                  rstate  <= R_FILL;
              end
          end
          R_FILL: begin
              if (srv_ki_gap || ext_rsp_valid) begin
                  // DDR3 beat valid: fill the cache line + serve the byte.
                  // The fill completes even if the requester was preempted --
                  // ROM is constant and a later request can reuse the line.
                  pf_data[srv_idx]  <= fill_beat;
                  pf_tag[srv_idx]   <= srv_tag;
                  pf_valid[srv_idx] <= 1'b1;
                  srv_byte          <= fill_beat[8*srv_addr[2:0] +: 8];
                  rstate            <= R_SERVE;
              end
          end
          R_SERVE: begin
              if (!rom_req)
                  rstate <= R_IDLE;
              else if (rom_addr != srv_addr) begin
                  // requester moved on (next boot byte / re-issued after an
                  // IRQ preemption): restart the lookup via R_ADDR (registered read)
                  srv_addr <= rom_addr;
                  rstate   <= R_ADDR;
              end
          end
        endcase
    end

    // ---- Simulation initialization -------------------------------------------
    // Invalidate all cache lines at time zero.
    integer k;
`ifndef SYNTHESIS
    initial begin
        for (k=0;k<PF_LINES;k=k+1) pf_valid[k]=1'b0;
    end
`endif
endmodule
