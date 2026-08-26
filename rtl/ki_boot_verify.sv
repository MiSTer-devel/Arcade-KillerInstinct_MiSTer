// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

module ki_boot_verify #(
  parameter logic [31:0] BOOT_BASE  = 32'h1fc0_0000,
  parameter integer      BOOT_BYTES = 524288
) (
  input  wire         clk,
  input  wire         reset,
  // Rises once the ROM is present and the SDRAM self test has finished with
  // the memory port.
  input  wire         start,

  output logic        active = 1'b0,
  output logic        done = 1'b0,
  output logic [31:0] checksum = 32'd0,

  output logic        cpu_request = 1'b0,
  output logic [31:0] cpu_address = 32'd0,
  input  wire  [63:0] cpu_data_read,
  input  wire         cpu_done
);
  localparam logic [31:0] BOOT_LAST = BOOT_BASE + BOOT_BYTES - 4;

  typedef enum logic [1:0] {
    VERIFY_IDLE,
    VERIFY_ISSUE,
    VERIFY_WAIT,
    VERIFY_FINISHED
  } state_t;

  state_t state = VERIFY_IDLE;
  logic [31:0] sum = 32'd0;

  always_ff @(posedge clk) begin
    cpu_request <= 1'b0;

    if (reset) begin
      state <= VERIFY_IDLE;
      active <= 1'b0;
      done <= 1'b0;
      sum <= 32'd0;
      checksum <= 32'd0;
      cpu_address <= BOOT_BASE;
    end else begin
      case (state)
        VERIFY_IDLE: begin
          if (start && !done) begin
            active <= 1'b1;
            sum <= 32'd0;
            cpu_address <= BOOT_BASE;
            state <= VERIFY_ISSUE;
          end
        end

        // One 32-bit read per address, which is the shape the boot
        // decompressor's byte loads turn into at this port.
        VERIFY_ISSUE: begin
          cpu_request <= 1'b1;
          state <= VERIFY_WAIT;
        end

        VERIFY_WAIT: begin
          if (cpu_done) begin
            sum <= sum + {16'd0, cpu_data_read[15:0]}
                       + {16'd0, cpu_data_read[31:16]};
            if (cpu_address >= BOOT_LAST) begin
              checksum <= sum + {16'd0, cpu_data_read[15:0]}
                              + {16'd0, cpu_data_read[31:16]};
              done <= 1'b1;
              active <= 1'b0;
              state <= VERIFY_FINISHED;
            end else begin
              cpu_address <= cpu_address + 32'd4;
              state <= VERIFY_ISSUE;
            end
          end
        end

        VERIFY_FINISHED: state <= VERIFY_FINISHED;
      endcase
    end
  end
endmodule

`default_nettype wire
