//
// tb_woz_mount_ctl.sv - M1 Unit 4: WOZ mount/lifecycle controller
//
// DUT: woz_mount_ctl (machine domain).
// Reference: a cycle-accurate model of the engine's drive-level mount
// logic (woz/disk_ii_woz.sv:205-232) so the IMG_MOUNTED/IMG_SIZE waveforms
// produced by the DUT are checked against the engine's real semantics
// (held `mount` level, media_present latch, DD_RESET re-pulse).
//
// Coverage:
//   T1  OK result -> mount event (media_present + mount pulse, scan re-run)
//   T2  new OK while mounted -> eject (fall/zero-rise/fall) + remount,
//       engine re-parse pulse observed, media_present preserved
//   T3  FAIL while mounted -> eject -> unmounted (engine mount level clears)
//   T4  NOFILE while unmounted -> stays unmounted
//   T5  transport fault while mounted -> eject -> unmounted
//   T6  transport fault while unmounted -> no-op (no spurious eject)
//   T7  machine reset (DD_RESET) while mounted: DUT levels held (power-on
//       reset only), engine self re-pulses from media_present
//   T8  new OK result landing mid-eject -> newest wins (remount)
//   T9  power-on: NOFILE then OK -> mount
//
// Build (MSYS2 UCRT64, from repo root):
//   see verilog/README.md pattern (--binary --timing)
//
`timescale 1ns/1ps
module tb_woz_mount_ctl;

    localparam real PM = 69.844;   // 14.318 MHz
    reg clk;
    initial begin
        clk = 1'b0;
        forever #(PM/2.0) clk = ~clk;
    end

    // ==================================================================
    // DUT
    // ==================================================================
    reg         por_n;
    reg         res_valid_m;
    reg  [1:0]  res_code_m;
    reg  [31:0] res_nbytes_m;
    reg         transport_fault;
    wire        img_mounted;
    wire [63:0] img_size;
    wire        img_readonly;
    wire [2:0]  mount_state_m;

    woz_mount_ctl dut (
        .clk             ( clk ),
        .por_n           ( por_n ),
        .res_valid_m     ( res_valid_m ),
        .res_code_m      ( res_code_m ),
        .res_nbytes_m    ( res_nbytes_m ),
        .transport_fault ( transport_fault ),
        .img_mounted     ( img_mounted ),
        .img_size        ( img_size ),
        .img_readonly    ( img_readonly ),
        .mount_state_m   ( mount_state_m )
    );

    // ==================================================================
    // Engine drive-level mount model (semantics copied from
    // woz/disk_ii_woz.sv:205-232; scan forced OK unless flagged)
    // ==================================================================
    reg        dd_reset_tb;
    reg        scan_failed_tb;
    reg        e_mounted_d, e_dd_reset_d;
    reg        e_mount, e_remount_pend, e_media_present;
    reg [32:0] e_pulse_cnt;

    always @(posedge clk) begin
        e_mounted_d  <= img_mounted;
        e_dd_reset_d <= dd_reset_tb;

        if (!e_mounted_d && img_mounted)
            e_media_present <= (img_size != 64'd0);

        if (dd_reset_tb) begin
            e_mount         <= 1'b0;
            e_remount_pend  <= 1'b0;
        end else if (e_dd_reset_d) begin
            e_remount_pend  <= e_media_present;
        end else if (!e_mounted_d && img_mounted) begin
            if (e_mount) begin
                e_mount        <= 1'b0;
                e_remount_pend <= (img_size != 64'd0);
            end else
                e_mount <= (img_size != 64'd0);
        end else if (e_remount_pend) begin
            e_mount        <= 1'b1;
            e_remount_pend <= 1'b0;
        end
    end
    reg e_mount_d;
    always @(posedge clk) begin
        e_mount_d <= e_mount;
        if (e_mount && !e_mount_d)
            e_pulse_cnt <= e_pulse_cnt + 1'b1;
    end

    wire e_disk_mounted = e_mount && !scan_failed_tb;

    initial begin
        e_mounted_d = 0; e_dd_reset_d = 0; e_mount = 0;
        e_remount_pend = 0; e_media_present = 0; e_pulse_cnt = 0;
        e_mount_d = 0;
    end

    // ==================================================================
    // result driver: models the coordinator (0082 clears, then latched)
    // ==================================================================
    task automatic give_result(input [1:0] code, input [31:0] size);
        begin
            res_valid_m = 1'b0;                 // 0082: generation clears
            res_code_m  = code;
            res_nbytes_m = size;
            @(posedge clk);
            res_valid_m = 1'b1;                // result latched (rising edge)
        end
    endtask

    // ==================================================================
    // checks
    // ==================================================================
    integer nfail = 0;
    task automatic chk(input string what, input cond);
        begin
            if (cond)
                $display("OK   %s at %0t", what, $time);
            else begin
                $display("FAIL %s at %0t", what, $time);
                nfail = nfail + 1;
            end
        end
    endtask

    initial begin
        por_n = 1'b0;
        res_valid_m = 1'b0; res_code_m = 2'd0; res_nbytes_m = 32'd0;
        transport_fault = 1'b0;
        dd_reset_tb = 1'b0; scan_failed_tb = 1'b0;

        // ---- T9 (at power-on): NOFILE, then OK ----
        por_n = 1'b1;
        repeat (3) @(posedge clk);
        give_result(2'd2, 32'd0);               // NOFILE at boot
        repeat (8) @(posedge clk);
        chk("T9a NOFILE at boot: unmounted",
               (img_mounted == 1'b0) && (img_size == 64'd0) &&
               (e_mount == 1'b0) && (e_media_present == 1'b0));
        give_result(2'd0, 32'd100000);
        repeat (8) @(posedge clk);
        chk("T9b OK at boot: mounted 100000",
               (img_mounted == 1'b1) && (img_size == 64'd100000) &&
               (e_mount == 1'b1) && (e_media_present == 1'b1) &&
               (e_pulse_cnt == 1'd1) && e_disk_mounted);

        // ---- T1: remount path already covered; steady state ----
        repeat (8) @(posedge clk);
        chk("T1 steady: levels stable, one parse",
               (img_mounted == 1'b1) && (img_size == 64'd100000) &&
               (e_pulse_cnt == 1'd1) && (e_remount_pend == 1'b0));

        // ---- T2: new OK while mounted -> eject + remount ----
        give_result(2'd0, 32'd200000);
        repeat (12) @(posedge clk);
        chk("T2 remounted at new size 200000",
               (img_mounted == 1'b1) && (img_size == 64'd200000) &&
               (e_mount == 1'b1) && e_disk_mounted);
        chk("T2 engine re-parsed (2 pulses), media preserved",
               (e_pulse_cnt == 2'd2) && (e_media_present == 1'b1));

        // ---- T3: FAIL while mounted -> eject -> unmounted ----
        give_result(2'd1, 32'd50000);
        repeat (12) @(posedge clk);
        chk("T3 unmounted after FAIL (zero-rise clears media_present)",
               (img_mounted == 1'b0) && (img_size == 64'd0) &&
               (e_mount == 1'b0) && (!e_disk_mounted) &&
               (e_media_present == 1'b0));

        // ---- T4: NOFILE while unmounted -> stays unmounted ----
        give_result(2'd2, 32'd0);
        repeat (8) @(posedge clk);
        chk("T4 NOFILE unmounted: quiescent",
               (img_mounted == 1'b0) && (e_mount == 1'b0) &&
               (e_pulse_cnt == 2'd2));

        // mount again for the fault tests
        give_result(2'd0, 32'd300000);
        repeat (8) @(posedge clk);
        chk("T5a re-mounted 300000",
               (img_mounted == 1'b1) && (img_size == 64'd300000) &&
               (e_pulse_cnt == 3'd3));

        // ---- T5: transport fault while mounted -> eject ----
        transport_fault = 1'b1;
        repeat (3) @(posedge clk);
        transport_fault = 1'b0;
        repeat (12) @(posedge clk);
        chk("T5 unmounted after transport fault",
               (img_mounted == 1'b0) && (img_size == 64'd0) &&
               (e_mount == 1'b0) && (!e_disk_mounted));

        // ---- T6: transport fault while unmounted -> no-op ----
        begin : t6
            reg [32:0] pc_before;
            pc_before = e_pulse_cnt;
            transport_fault = 1'b1;
            repeat (3) @(posedge clk);
            transport_fault = 1'b0;
            repeat (12) @(posedge clk);
            chk("T6 fault while unmounted: no spurious eject",
                   (img_mounted == 1'b0) && (e_mount == 1'b0) &&
                   (e_pulse_cnt == pc_before));
        end

        // remount for the reset test
        give_result(2'd0, 32'd400000);
        repeat (8) @(posedge clk);
        chk("T7a re-mounted 400000",
               (img_mounted == 1'b1) && (img_size == 64'd400000) &&
               (e_pulse_cnt == 3'd4));

        // ---- T7: machine reset (DD_RESET) while mounted ----
        // DUT is power-on-reset only: levels must hold.
        begin : t7
            reg [32:0] pc_before;
            pc_before = e_pulse_cnt;
            dd_reset_tb = 1'b1;
            repeat (4) @(posedge clk);
            dd_reset_tb = 1'b0;
            repeat (8) @(posedge clk);
            chk("T7 DUT levels held through machine reset",
                   (img_mounted == 1'b1) && (img_size == 64'd400000));
            chk("T7 engine self re-pulsed (DD_RESET dance)",
                   (e_pulse_cnt == pc_before + 1'd1) &&
                   (e_mount == 1'b1) && e_disk_mounted &&
                   (e_media_present == 1'b1));
        end

        // ---- T8: new OK landing mid-eject -> newest wins ----
        give_result(2'd1, 32'd10);              // FAIL: starts eject
        repeat (2) @(posedge clk);              // mid-eject (ST_EJ1/2)
        give_result(2'd0, 32'd500000);          // newest: OK
        repeat (14) @(posedge clk);
        chk("T8 newest (OK) wins mid-eject: remounted 500000",
               (img_mounted == 1'b1) && (img_size == 64'd500000) &&
               (e_mount == 1'b1) && e_disk_mounted);

        // ---- final ----
        if (nfail) begin
            $display("TB WOX MOUNT CTL: FAIL nfail=%0d", nfail);
            $fatal(1);
        end
        $display("TB WOX MOUNT CTL: ALL PASS (nfail=0) at %0t", $time);
        $finish;
    end

    // watchdog
    initial begin
        #2_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
