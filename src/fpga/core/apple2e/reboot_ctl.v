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
// Behaviour (machine domain, 14.318 MHz):
//   * The FIRST mount after a `rst` is a power-on load, not a change -
//     it only sets `ever` and does not reboot.
//   * Every LATER mount_rise (new disk image mounted; the same pulse the
//     top feeds the transport's fault_clr) with the option ON runs a
//     cold reboot of the machine:
//       CLR phase : `ram_clear` high for CLR_CYCLES clocks - the top
//                  applies this as a synchronous clear of ram_main/
//                  ram_aux inside their RAM always block (the 6502 is
//                  held in reset the whole time, so no m_ram_we can race
//                  the clear; the clear must finish before the CPU is
//                  released, which the HOLD phase guarantees).
//       HOLD phase: `cold_reset` (the machine-reset contribution) stays
//                  high for HOLD_CYCLES more clocks, then falls - the
//                  6502 comes out of reset onto clean RAM.
//     Total ~357 us at 14.318 MHz: an invisible power cycle between disk
//     images. With the option OFF, mounts never touch the machine.
//
// Reset discipline: the FSM is async-reset by `rst` = the BASE machine
// reset (~rst_sync | ~lock_sync | osk_cmd_reset), NEVER by its own
// `cold_reset` output, so a cold pulse cannot re-trigger or extend
// itself. `mount_rise` edges that occur while the FSM is active are
// ignored (a mid-reboot remount cannot restart the window).
//
`timescale 1ns/10ps
module reboot_ctl #(
    parameter CLR_CYCLES  = 4096,   // ram clear window (~286 us)
    parameter HOLD_CYCLES = 1024    // reset hold after the clear (~72 us)
) (
    input  wire clk,          // machine clock, 14.318 MHz
    input  wire rst,          // BASE machine reset (without cold_reset itself)
    input  wire reboot_opt,   // synchronized option bit: 1 = reboot on change
    input  wire mount_rise,   // rising edge of the mount controller's img_mounted
    output wire cold_reset,   // 1 = must be ORed into machine_reset
    output wire ram_clear     // 1 = synchronously clear both machine RAMs
);

    localparam [11:0] CLR_MAX  = CLR_CYCLES  - 1'b1;
    localparam [11:0] HOLD_MAX = HOLD_CYCLES - 1'b1;

    reg        active;      // inside CLR or HOLD
    reg        in_clr;      // inside the CLR phase
    reg [11:0] cnt;
    reg        ever;        // seen at least one mount since rst

    assign cold_reset = active;
    assign ram_clear  = active && in_clr;

    wire first_rise = mount_rise && !ever;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 1'b0;
            in_clr <= 1'b0;
            cnt    <= 12'd0;
            ever   <= 1'b0;
        end else begin
            if (mount_rise)
                ever <= 1'b1;

            if (!active && mount_rise && !first_rise && reboot_opt) begin
                // a later mount with the option ON: start the cold reboot
                active <= 1'b1;
                in_clr <= 1'b1;
                cnt    <= 12'd0;
            end else if (active) begin
                if (in_clr) begin
                    if (cnt == CLR_MAX) begin
                        in_clr <= 1'b0;   // clear done: keep the CPU reset
                        cnt    <= 12'd0;
                    end else
                        cnt <= cnt + 12'd1;
                end else begin
                    if (cnt == HOLD_MAX) begin
                        active <= 1'b0;   // release the machine
                        cnt    <= 12'd0;
                    end else
                        cnt <= cnt + 12'd1;
                end
            end
        end
    end

endmodule
