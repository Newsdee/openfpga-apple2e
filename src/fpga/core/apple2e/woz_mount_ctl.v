// woz_mount_ctl.v - M1 Unit 4: WOZ mount/lifecycle controller
//
// Machine domain (14.318 MHz). Turns the M0 storage coordinator's result
// (load + drain + readback-verify) into the WOZ engine's mount interface,
// and unmounts on transport faults.
//
// Engine mount semantics (verified in woz/disk_ii_woz.sv:190-258 +
// woz_floppy_controller.sv:325-331,547,597):
//  * The drive-level `mount` is a HELD level (not a pulse): it rises on the
//    IMG_MOUNTED rising edge (when IMG_SIZE != 0) and is only cleared by
//    DD_RESET or by a new IMG_MOUNTED rising edge while already high
//    (the "unmount first so the controller re-parses" dance).
//  * disk_mounted (drive visible) = mount && !scan_failed.
//  * Falling IMG_MOUNTED alone does NOT unmount (media_present survives);
//    a zero-size rising edge while mounted clears the mount level.
//  * DD_RESET (machine reset) wipes the parse and re-pulses the mount from
//    the engine's own media_present latch, so the IMG_MOUNTED/IMG_SIZE
//    levels must stay stable across machine reset (this controller is
//    reset by power-on only, ~sdram_path_rst, like the SDRAM image region).
//
// Consequences:
//  * Mount  = IMG_MOUNTED 0->1 with IMG_SIZE = image bytes (rising edge
//             with nonzero size) -> engine latches media_present and scans
//             (the engine's own scan validates the WOZ format; M0 OK only
//             proves readback, not WOZ validity).
//  * Eject  = explicit zero-size mount event: fall -> rise(IMG_SIZE=0) ->
//             fall. The zero-size rise while mounted is what clears the
//             engine's mount level.
//  * Remount (new generation while mounted) = eject, then mount with the
//             new size (a fresh rising edge forces a re-parse).
//  * Failed / no-file generations stay unmounted. A transport fault
//             (Unit 3: SD_WR invariant / OOR LBA) unmounts.
//
// A new load result while mounted always ejects first: the new 0082
// generation overwrites the resident image, so the old mount must not
// keep serving torn data.

`timescale 1ns/1ps
module woz_mount_ctl (
    input  wire        clk,          // 14.318 MHz machine clock
    input  wire        por_n,        // power-on only (~sdram_path_rst)

    // ---- M0 coordinator result (machine domain) ----
    input  wire        res_valid_m,  // level; rising edge = new result
    input  wire [1:0]  res_code_m,   // 0=OK, 1=FAIL, 2=NOFILE
    input  wire [31:0] res_nbytes_m, // exact image bytes (stable w/ result)

    // ---- proactive unmount: a new 0082 generation started (machine-domain
    //      1-cycle pulse). The old image is about to be overwritten, so the
    //      mounted drive must be ejected NOW (not when the new result
    //      arrives ~100 us later) - otherwise the engine keeps scanning and
    //      fetching the old image for the whole new load, and its port
    //      reads (which beat the store's writes) starve the store FIFO into
    //      an overflow / timeout.
    input  wire        new_load_m,

    // ---- Unit-3 transport fault (latched in the transport) ----
    input  wire        transport_fault,

    // ---- WOZ engine mount interface ----
    output reg         img_mounted,
    output reg  [63:0] img_size,
    output wire        img_readonly,
    output reg  [2:0]  mount_state_m   // diagnostic (bridge word)
);

    localparam [2:0] ST_UNMOUNTED = 3'd0;
    localparam [2:0] ST_MOUNTED   = 3'd1;
    localparam [2:0] ST_EJ1       = 3'd2;  // fall
    localparam [2:0] ST_EJ2       = 3'd3;  // zero-size rise
    localparam [2:0] ST_EJ3       = 3'd4;  // fall, then resolve

    reg [2:0]  state;
    reg [31:0] size_l;          // mounted generation size
    reg        res_v_d;
    reg        tf_d;
    reg        newload_d;
    reg [1:0]  pend_code;
    reg [31:0] pend_size;
    reg        pend_valid;      // a result is waiting for the mount decision
    reg        fault_pend;      // a transport fault is waiting for eject

    wire res_rise  = res_valid_m && !res_v_d;
    wire fault_rise = transport_fault && !tf_d;
    wire newload_rise = new_load_m && !newload_d;

    // Resolve points (pre-NBA): the pending result/fault is consumed when
    // the mount decision is made. A capture (res_rise / fault_rise) on the
    // SAME cycle wins over the consume (newest generation is authoritative).
    wire do_mount  = (state == ST_UNMOUNTED) && pend_valid && (pend_code == 2'd0);
    wire resolve   = do_mount || (state == ST_EJ3);

    assign img_readonly  = 1'b1;   // read-only service (parser ignores; WP via D1_WP/D2_WP)

    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            state      <= ST_UNMOUNTED;
            img_mounted<= 1'b0;
            img_size   <= 64'd0;
            size_l     <= 32'd0;
            res_v_d    <= 1'b0;
            tf_d       <= 1'b0;
            newload_d  <= 1'b0;
            pend_code  <= 2'd0;
            pend_size  <= 32'd0;
            pend_valid <= 1'b0;
            fault_pend <= 1'b0;
            mount_state_m <= 3'd0;
        end else begin
            res_v_d <= res_valid_m;
            tf_d    <= transport_fault;
            newload_d <= new_load_m;

            // Capture the newest result / fault (edge); else consume at the
            // resolve point. Capture wins on a same-cycle collision.
            if (res_rise) begin
                pend_code  <= res_code_m;
                pend_size  <= res_nbytes_m;
                pend_valid <= 1'b1;
            end else if (resolve)
                pend_valid <= 1'b0;

            if (fault_rise)
                fault_pend <= 1'b1;
            else if (resolve)
                fault_pend <= 1'b0;

            case (state)
            ST_UNMOUNTED: begin
                img_mounted <= 1'b0;
                img_size    <= 64'd0;
                if (do_mount) begin
                    // OK result: mount (next cycle is the rising edge).
                    size_l <= pend_size;
                    state  <= ST_MOUNTED;
                end
            end
            ST_MOUNTED: begin
                img_mounted <= 1'b1;
                img_size    <= {32'd0, size_l};
                if (pend_valid || fault_pend || newload_rise) begin
                    // Any new generation (overwrites the image) or a
                    // transport fault: eject first (re-parse dance).
                    // newload_rise fires at the start of the new load
                    // (0082), so the engine stops fetching the old image
                    // before the store streams the new one.
                    state <= ST_EJ1;
                end
            end
            ST_EJ1: begin
                img_mounted <= 1'b0;            // fall
                img_size    <= 64'd0;
                state       <= ST_EJ2;
            end
            ST_EJ2: begin
                img_mounted <= 1'b1;            // zero-size rise: clears the
                img_size    <= 64'd0;           // engine's held mount level
                state       <= ST_EJ3;
            end
            ST_EJ3: begin
                img_mounted <= 1'b0;            // fall
                img_size    <= 64'd0;
                if (pend_valid && pend_code == 2'd0) begin
                    // Fresh OK generation: remount (next cycle's rise).
                    size_l <= pend_size;
                    state  <= ST_MOUNTED;
                end else begin
                    // Failed / no-file / fault-only: stay unmounted.
                    state <= ST_UNMOUNTED;
                end
            end
            default: begin
                // Unreachable: recover safely.
                img_mounted <= 1'b0;
                img_size    <= 64'd0;
                state       <= ST_UNMOUNTED;
            end
            endcase

            mount_state_m <= state;
        end
    end
endmodule
