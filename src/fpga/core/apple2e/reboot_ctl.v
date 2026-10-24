//
// reboot_ctl.v - "Reboot on disk change" core option (2026-10-24)
//
// The Pocket Core Settings menu exposes an interact.json `check`
// ("Reboot on disk change", persisted, default ON). The framework writes
// the selected value to bridge address 0x01F00000 at boot (immediately
// before Reset Exit) and reads the word back at shutdown (after Reset
// Enter); the top latches it in the 74.25 MHz bridge domain and syncs
// bit0 to the machine domain (synch_3), feeding it here as `reboot_opt`.
//
// Behaviour (machine domain, 143.18 MHz):
//   * The FIRST mount after a `rst` is a power-on load, not a change -
//     it only sets `ever` and does not reboot.
//   * Every LATER mount_rise (new disk image mounted; the same pulse the
//     top feeds the transport's fault_clr) with the option ON runs a
//     cold reboot of the machine:
//       CLR phase : `ram_clear` high until `clr_done` - the top's RAM
//                  block walks a 16-bit address counter, writing zero
//                  to BOTH banks one address per machine cycle
//                  (65,536 cycles = ~458 us at 143.18 MHz; Cyclone V
//                  M10Ks have no runtime content-clear pin, so a
//                  sequential write-sweep is the block-RAM-compatible
//                  idiom). A safety timeout bounds the phase in case
//                  clr_done is ever late.
//       HOLD phase: `cold_reset` (the machine-reset contribution) stays
//                  high for HOLD_CYCLES more clocks, then falls - the
//                  6502 comes out of reset onto clean RAM.
//
// Reset discipline: the FSM is async-reset by `rst` = the BASE machine
// reset (~rst_sync | ~lock_sync | osk_cmd_reset), NEVER by its own
// `cold_reset` output, so a cold pulse cannot re-trigger or extend
// itself. `mount_rise` edges that occur while the FSM is active are
// ignored (a mid-reboot remount cannot restart the window).
//
`timescale 1ns/10ps
module reboot_ctl #(
    parameter CLR_TIMEOUT = 131072, // safety bound on the sweep (2x 65536)
    parameter HOLD_CYCLES = 1024    // reset hold after the clear (~7.2 us)
) (
    input  wire clk,          // machine clock, 143.18 MHz
    input  wire rst,          // BASE machine reset (without cold_reset itself)
    input  wire reboot_opt,   // synchronized option bit: 1 = reboot on change
    input  wire mount_rise,   // rising edge of the mount controller's img_mounted
    input  wire clr_done,     // RAM sweep finished (all 65,536 addresses written)
    output wire cold_reset,   // 1 = must be ORed into machine_reset
    output wire ram_clear     // 1 = RAM sweep in progress
);

    localparam [17:0] CLR_MAX  = CLR_TIMEOUT - 1'b1;
    localparam [11:0] HOLD_MAX = HOLD_CYCLES - 1'b1;

    reg        active;      // inside CLR or HOLD
    reg        in_clr;      // inside the CLR phase
    reg [17:0] cnt;
    reg        ever;        // seen at least one mount since rst

    assign cold_reset = active;
    assign ram_clear  = active && in_clr;

    wire first_rise = mount_rise && !ever;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 1'b0;
            in_clr <= 1'b0;
            cnt    <= 18'd0;
            ever   <= 1'b0;
        end else begin
            if (mount_rise)
                ever <= 1'b1;

            if (!active && mount_rise && !first_rise && reboot_opt) begin
                // a later mount with the option ON: start the cold reboot
                active <= 1'b1;
                in_clr <= 1'b1;
                cnt    <= 18'd0;
            end else if (active) begin
                if (in_clr) begin
                    // wait for the RAM sweep to report done (bounded)
                    if (clr_done || cnt == CLR_MAX) begin
                        in_clr <= 1'b0;   // clear done: keep the CPU reset
                        cnt    <= 18'd0;
                    end else
                        cnt <= cnt + 18'd1;
                end else begin
                    if (cnt == HOLD_MAX) begin
                        active <= 1'b0;   // release the machine
                        cnt    <= 18'd0;
                    end else
                        cnt <= cnt + 18'd1;
                end
            end
        end
    end

endmodule
