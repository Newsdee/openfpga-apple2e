// =============================================================================
// tb_woz_mount_race.sv -- M1 no-boot repro (targeted, per external review).
//
// Real mount controller (woz_mount_ctl) + UNCHANGED WOZ engine (disk_ii_woz) +
// a simple sector-service model (replaces transport/fetcher/SDRAM). Reproduces
// the reset-release collision and verifies the recovery, on a FRESH engine
// (media_present starts 0 -- it is NOT cleared by DD_RESET, so the corner case
// must be tested first, before anything latches it).
//
//   Part 1 (the corner case): the img_mounted 0->1 edge coincides EXACTLY with
//           the engine's first sampled reset-release cycle (dd_reset_d=1).
//           PREDICTED: internal `mount` stays LOW (media_present latches 1, but
//           remount_pending samples the OLD 0; the direct mount-edge branch is
//           shadowed by the dd_reset_d branch).
//   Part 2 (recovery): a second machine reset (no reload). media_present is now
//           1, so the release edge sets remount_pending=1 -> `mount` recovers
//           and the engine's scan issues its first read.
//
// Observes the engine's INTERNAL mount/media_present/remount_pending via
// hierarchical references (the pinned source is NOT edited) + the engine's SD
// read requests (the real "did the scan start" evidence). Every wait watchdoged.
// =============================================================================

`timescale 1ns / 1ps

module tb_woz_mount_race;

    // 14.318 MHz clock shared by the mount controller + the engine (as in the top:
    // both run on clk_core_14318). ~28.6 ns period.
    reg clk = 1'b0;
    always #35 clk <= ~clk;

    reg  machine_reset = 1'b1;          // engine RESET + DD_RESET
    reg  por_n         = 1'b0;          // mount-controller power-on (~sdram_path_rst)

    // mount-controller inputs (I drive these; in the top they come from storage)
    reg        res_valid_m  = 1'b0;
    reg  [1:0] res_code_m   = 2'd0;
    reg  [31:0] res_nbytes_m = 32'd0;
    reg        new_load_m   = 1'b0;

    wire        img_mounted;
    wire [63:0] img_size;
    wire        img_readonly;
    wire [2:0]  mc_state;

    woz_mount_ctl mc (
        .clk            ( clk        ),
        .por_n          ( por_n      ),
        .res_valid_m    ( res_valid_m ),
        .res_code_m     ( res_code_m  ),
        .res_nbytes_m   ( res_nbytes_m),
        .new_load_m     ( new_load_m ),
        .transport_fault( 1'b0       ),
        .img_mounted    ( img_mounted ),
        .img_size       ( img_size    ),
        .img_readonly   ( img_readonly ),
        .mount_state_m  ( mc_state    )
    );

    // engine CPU side tied off (we only exercise the scan); SDRAM side driven below
    wire [7:0]  woz_dout;
    wire        d1_active, d1_motor, d1_step, d1_track0, d1_io;
    wire [31:0] sd_lba;
    wire        sd_rd, sd_wr;
    reg         sd_ack;
    reg  [7:0]  sd_din;
    reg  [8:0]  sd_buff_addr;
    reg  [7:0]  sd_buff_dout;
    reg         sd_buff_wr;

    disk_ii_woz woz (
        .CLK_14M        ( clk        ),
        .RESET          ( machine_reset ),
        .DD_RESET       ( machine_reset ),
        .PHASE_ZERO     ( 1'b0       ),
        .IO_SELECT      ( 1'b0       ),
        .DEVICE_SELECT  ( 1'b0       ),
        .WE             ( 1'b0       ),
        .A              ( 16'd0      ),
        .D_IN           ( 8'd0       ),
        .D_OUT          ( woz_dout   ),
        .D1_ACTIVE      ( d1_active ),
        .D2_ACTIVE      (           ),
        .D1_MOTOR_ON    ( d1_motor  ),
        .D2_MOTOR_ON    (           ),
        .D1_STEP        ( d1_step   ),
        .D2_STEP        (           ),
        .D1_TRACK0      ( d1_track0 ),
        .D2_TRACK0      (           ),
        .D1_IO          ( d1_io     ),
        .D2_IO          (           ),
        .D1_WP          ( 1'b1       ),
        .D2_WP          ( 1'b1       ),
        .SD_LBA0        ( sd_lba     ),
        .SD_RD0         ( sd_rd      ),
        .SD_WR0         ( sd_wr      ),
        .SD_ACK0        ( sd_ack     ),
        .SD_BUFF_DIN0   ( sd_din     ),
        .SD_LBA1        (            ),
        .SD_RD1         (            ),
        .SD_WR1         (            ),
        .SD_ACK1        ( 1'b0       ),
        .SD_BUFF_DIN1   (            ),
        .SD_BUFF_ADDR   ( sd_buff_addr ),
        .SD_BUFF_DOUT   ( sd_buff_dout ),
        .SD_BUFF_WR     ( sd_buff_wr   ),
        .IMG_MOUNTED0   ( img_mounted ),
        .IMG_MOUNTED1   ( 1'b0       ),
        .IMG_READONLY   ( 1'b1       ),
        .IMG_SIZE       ( img_size    )
    );

    // engine internals (hierarchical; the pinned source is NOT edited)
    wire e_mount      = woz.drive_g[0].mount;
    wire e_media      = woz.drive_g[0].media_present;
    wire e_remount    = woz.drive_g[0].remount_pending;
    wire e_dd_reset_d = woz.drive_g[0].dd_reset_d;
    wire e_mounted_d  = woz.drive_g[0].mounted_d;

    // ---- simple sector-service model (replaces transport+fetcher+SDRAM) ----
    // On sd_rd: latch "request seen", ACK after one cycle, stream 512 bytes so the
    // engine's scan can progress. Proves "requests complete", not just "appear".
    reg req_seen = 1'b0;
    integer req_count = 0;
    reg [8:0]  svc_addr;
    reg        svc_go;
    reg [7:0]  sector [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) sector[i] = i[7:0];

    always @(posedge clk) begin
        if (machine_reset) begin
            sd_ack <= 1'b0; sd_buff_wr <= 1'b0; sd_buff_dout <= 8'd0;
            sd_buff_addr <= 9'd0; svc_go <= 1'b0;
        end else begin
            if (sd_rd && !req_seen) req_seen <= 1'b1;
            if (svc_go) begin
                if (svc_addr == 9'd511) begin
                    sd_ack <= 1'b0; sd_buff_wr <= 1'b0; sd_buff_dout <= 8'd0;
                    svc_go <= 1'b0; svc_addr <= 9'd0;
                end else begin
                    sd_buff_wr   <= 1'b1;
                    sd_buff_dout <= sector[svc_addr];
                    sd_buff_addr <= svc_addr;
                    svc_addr     <= svc_addr + 9'd1;
                end
            end else if (sd_rd) begin
                sd_ack <= 1'b1; sd_buff_wr <= 1'b0; sd_buff_dout <= 8'd0;
                sd_buff_addr <= 9'd0; svc_addr <= 9'd0; svc_go <= 1'b1;
                req_count <= req_count + 1;
            end else begin
                sd_ack <= 1'b0;
            end
        end
    end

    integer fails = 0, passes = 0, w;

    initial begin
        $display("TB WozMountRace: start");
        por_n = 1'b0;
        repeat (6) @(posedge clk);
        por_n = 1'b1;                 // MC out of power-on (ST_UNMOUNTED, img_mounted=0)
        repeat (4) @(posedge clk);
        $display("TB: fresh engine media=%b mount=%b mounted_in=%b mc=%d",
                 e_media, e_mount, img_mounted, mc_state);

        // =====================================================================
        // PART 1 -- the corner case. Hold machine_reset; land the img_mounted
        // 0->1 edge on the engine's first sampled reset-release posedge.
        //   The MC takes 2 clk from res_valid to img_mounted (do_mount then
        //   ST_MOUNTED). So: raise res_valid, then 1 posedge later lower
        //   machine_reset -> at that posedge the reset has just released AND
        //   img_mounted has just risen.
        // =====================================================================
        machine_reset = 1'b1;
        repeat (4) @(posedge clk);
        // NONZERO image (a zero-size image would -- correctly -- never mount).
        res_nbytes_m = 234496;
        res_code_m   = 2'd0;
        // MC timing: res_valid rise -> pend_valid (P+1) -> do_mount/ST_MOUNTED
        // (P+2) -> img_mounted scheduled (P+2) -> engine sees mounted_in=1 (P+3).
        // To make that engine mount edge coincide with the reset-release edge
        // (dd_reset_d=1), machine_reset must fall at P+3.
        @(negedge clk);  res_valid_m = 1'b1;   // res_valid=1 at P_a
        @(posedge clk);                        // P_a
        @(posedge clk);                        // P_a+1: do_mount -> ST_MOUNTED
        @(posedge clk);                        // P_a+2: img_mounted/img_size scheduled
        @(negedge clk);  machine_reset = 1'b0; // machine_reset=0 at P_a+3
        // --- at the next posedge (P_a+3): COINCIDENCE (dd_reset_d=1 AND mount edge) ---
        @(posedge clk);
        $display("PART 1 coincidence: dd_reset_d=%b mounted_d=%b mounted_in=%b media=%b remount=%b mount=%b img_size=%0h",
                 e_dd_reset_d, e_mounted_d, img_mounted, e_media, e_remount, e_mount, img_size);
        if (!img_mounted || img_size == 64'd0) begin
            fails = fails + 1;
            $display("PART 1: TIMING OFF -- coincidence did not land (mounted_in=%b size=%0h); retime, not a corner-case result",
                     img_mounted, img_size);
            $finish;
        end
        // let it settle; the corner case means `mount` stays 0
        for (w = 0; w < 200; w = w + 1) @(posedge clk);
        if (!e_mount) begin
            passes = passes + 1;
            $display("PART 1: CONFIRMED corner case -- internal mount stayed LOW (media=%b remount=%b)",
                     e_media, e_remount);
        end else begin
            fails = fails + 1;
            $display("PART 1: mount re-pulsed (coincidence NOT reproduced -- retime)");
        end
        if (req_seen) begin
            fails = fails + 1;
            $display("PART 1: UNEXPECTED engine read while mount is low");
        end

        // =====================================================================
        // PART 2 -- recovery. media_present is now 1. A second machine reset
        // (no reload) -> release edge sets remount_pending=1 -> mount recovers
        // and the engine's scan issues its first read.
        // =====================================================================
        machine_reset = 1'b1;
        repeat (4) @(posedge clk);
        machine_reset = 1'b0;
        for (w = 0; !e_mount && w < 200; w = w + 1) @(posedge clk);
        if (e_mount) begin
            passes = passes + 1;
            $display("PART 2: PASS second reset recovered the mount (media=%b)", e_media);
        end else begin
            fails = fails + 1;
            $display("PART 2: FAIL second reset did NOT recover (media=%b remount=%b)",
                     e_media, e_remount);
        end
        for (w = 0; !req_seen && w < 3000; w = w + 1) @(posedge clk);
        if (req_seen) begin
            passes = passes + 1;
            $display("PART 2: PASS engine issued a read after recovery (req_count=%d)", req_count);
        end else begin
            fails = fails + 1;
            $display("PART 2: FAIL no engine read after recovery");
        end

        if (fails == 0) begin
            $display("TB WozMountRace: ALL PASS (corner case lost mount; second reset recovered) req_count=%d",
                     req_count);
            $finish;
        end else begin
            $display("TB WozMountRace: %d PASS %d FAIL", passes, fails);
            $fatal(1, "TB WozMountRace: FAILURES");
        end
    end

    // global watchdog (~2.9 ms machine time)
    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "TB WozMountRace: global watchdog");
    end

endmodule
