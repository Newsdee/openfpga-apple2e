//
// ram_sweep_ctl.v - sequential RAM-clear sweep controller (Apple IIe Pocket)
//
// Drives the machine-RAM bus (we / addr / aux) to write zeros through BOTH
// banks via the normal bus write path: pass 1 = main bank (aux=0),
// pass 2 = aux bank (aux=1), 65,536 addresses each = 131,072 machine
// cycles (~0.92 ms at 143.18 MHz). The write DATA is hardwired to 0 at the
// overlay site (the controller emits no data output).
//
// WHY A BUS OVERLAY (and not direct array writes):
// Quartus 17.0.2 will not infer a single-port M10K when the write ADDRESS
// is conditional - both the if/else two-write form and the muxed-address
// form fail with Error 276003 + Info 276007 ("uninferred due to
// asynchronous read logic"), leaving ~500K logic registers per 64Kx8 bank
// (the Fitter 170011 node explosion and the multi-hour TDS grind). An
// inference matrix (tools/ram_repro_matrix, 2026-10-24) isolated the poison
// precisely: muxing the write DATA or the write ENABLE is fine; only the
// conditional write ADDRESS breaks inference. Keeping the RAM block
// byte-identical to the proven M1 shape (plain single-port, per-bank
// enable, write-first bypass) and routing the sweep through the bus
// preserves block-RAM inference. The machine (CPU + Disk II) is in cold
// reset for the whole sweep, so hijacking the RAM write port is safe:
// apple2 and disk_ii_woz are reset-gated (disk_ii_woz.RESET = the
// composite machine_reset that includes the cold-reset window).
//
// Handshake (mirrors the reboot_ctl contract):
//   start (reboot_ctl ram_clear, the CLR phase) rising ->
//   we high for 131,072 cycles walking both passes ->
//   done asserted (level) while start is still high -> start falls ->
//   done deasserted, back to IDLE.
//
// No reset input by design: the controller is pure machine-clock logic and
// only acts while start is high; reboot_ctl asserts start only after its
// own reset has been serviced (it is async-reset by the base machine
// reset), so a stale sweep cannot survive a reset.

`timescale 1ns/1ps
module ram_sweep_ctl (
    input  wire        clk,      // clk_core_14318
    input  wire        start,    // reboot_ctl ram_clear (CLR phase)
    output reg         we,       // sweep write enable (bus overlay)
    output reg  [15:0] addr,     // sweep address
    output reg         aux,      // 0 = main pass, 1 = aux pass
    output reg         done      // level: both passes complete (start high)
);
    localparam [1:0] ST_IDLE = 2'd0,
                     ST_MAIN = 2'd1,
                     ST_AUX  = 2'd2,
                     ST_DONE = 2'd3;
    reg [1:0] state;

    always @(posedge clk) begin
        case (state)
            ST_IDLE: begin
                we   <= 1'b0;
                done <= 1'b0;
                if (start) begin
                    state <= ST_MAIN;
                    we    <= 1'b1;
                    addr  <= 16'd0;
                    aux   <= 1'b0;
                end
            end
            ST_MAIN: begin
                we <= 1'b1;
                if (addr == 16'hFFFF) begin
                    state <= ST_AUX;   // main pass complete (write @FFFF done)
                    addr  <= 16'd0;
                    aux   <= 1'b1;
                end else
                    addr <= addr + 16'd1;
            end
            ST_AUX: begin
                we <= 1'b1;
                if (addr == 16'hFFFF) begin
                    state <= ST_DONE;  // aux pass complete
                    we    <= 1'b0;
                end else
                    addr <= addr + 16'd1;
            end
            ST_DONE: begin
                we   <= 1'b0;
                done <= 1'b1;
                if (!start)
                    state <= ST_IDLE;
            end
            default: state <= ST_IDLE;
        endcase
    end
endmodule
