//
// tb_woz_scanwin.sv - scan-window flux check for woz_floppy_controller
// (ADDENDUM_WOZ_LOAD_IOERR_SCAN_WINDOW_2026-11-22)
//
// Narrow repro: instantiates ONLY the real woz_floppy_controller (+ its
// woz_bram memories) with a fake host walker - no SDRAM stack, no CPU.
//
// The hole (pre-fix): between img_mounted rising and woz_valid (metadata
// scan in flight), disk_mounted is already 1 (media present, deliberate -
// the ROM may be reading) but bit_count was 0 -> flux_drive never advances
// -> total flux silence -> RWTS sync timeout -> "I/O ERROR" on hardware.
//
// The fix: during the scan window the controller must present a non-zero
// bit_count (SCAN_BIT_COUNT) and a transition-rich bit_data pattern
// (SCAN_FLUX_BYTE = 0x96). This TB FAILS on the pre-fix RTL (bit_count=0
// samples observed) and PASSES on the fixed RTL.
//
// Build+run: verilog/run_t5_scanwin.bat (from repo root CWD).
//
`timescale 1ns/1ps
module tb_woz_scanwin;

    // 14.318 MHz machine clock
    localparam real PH = 34.922;
    reg clk = 1'b0;
    initial forever #PH clk = ~clk;

    reg reset = 1'b1;
    reg img_mounted = 1'b0;

    // fake host <-> engine block interface
    wire [31:0] sd_lba;
    wire        sd_rd, sd_wr;
    reg         sd_ack = 1'b0;
    reg  [8:0]  sd_buff_addr = 9'd0;
    reg  [7:0]  sd_buff_dout = 8'h00;
    reg         sd_buff_wr = 1'b0;
    wire [7:0]  sd_buff_din;

    // IWM side (stubbed)
    wire [31:0] bit_count;
    wire [7:0]  bit_data;
    reg  [15:0] bit_addr = 16'h1234;   // arbitrary read address
    reg         stable_side = 1'b0;

    wire        ready, disk_mounted, busy, track_load_complete;
    wire        is_flux_track, track_data_valid, disk_type_mismatch, disk_write_protected;
    wire [31:0] flux_data_size, flux_total_ticks;
    wire [7:0]  optimal_bit_timing;
    wire [15:0] dbg_load_sum;
    wire [13:0] dbg_load_bytes;
    wire [7:0]  dbg_load_blocks;

    woz_floppy_controller #(.IS_35_INCH(0)) dut (
        .clk                 ( clk ),
        .reset               ( reset ),
        .sd_lba              ( sd_lba ),
        .sd_rd               ( sd_rd ),
        .sd_wr               ( sd_wr ),
        .sd_ack              ( sd_ack ),
        .sd_buff_addr        ( sd_buff_addr ),
        .sd_buff_dout        ( sd_buff_dout ),
        .sd_buff_din         ( sd_buff_din ),
        .sd_buff_wr          ( sd_buff_wr ),
        .img_mounted         ( img_mounted ),
        .img_readonly        ( 1'b1 ),
        .img_size            ( 64'd16777216 ),   // 16 MB: scan never hits EOF
        .track_id            ( 8'd0 ),
        .ready               ( ready ),
        .disk_mounted        ( disk_mounted ),
        .busy                ( busy ),
        .active              ( 1'b1 ),
        .bit_count           ( bit_count ),
        .bit_addr            ( bit_addr ),
        .stable_side         ( stable_side ),
        .bit_data            ( bit_data ),
        .bit_data_in         ( 8'd0 ),
        .bit_we              ( 1'b0 ),
        .bit_wr_addr         ( 16'd0 ),
        .track_load_complete ( track_load_complete ),
        .is_flux_track       ( is_flux_track ),
        .flux_data_size      ( flux_data_size ),
        .flux_total_ticks    ( flux_total_ticks ),
        .track_data_valid    ( track_data_valid ),
        .disk_type_mismatch  ( disk_type_mismatch ),
        .disk_write_protected( disk_write_protected ),
        .optimal_bit_timing  ( optimal_bit_timing ),
        .dbg_load_sum        ( dbg_load_sum ),
        .dbg_load_bytes      ( dbg_load_bytes ),
        .dbg_load_blocks     ( dbg_load_blocks )
    );

    // --------------------------------------------------------------
    // fake host: on each sd_rd, ACK and stream one 512-byte block of
    // 0x55 pattern bytes (never forms a valid WOZ chunk, so the header
    // scan keeps walking blocks and the scan window stays open).
    // --------------------------------------------------------------
    integer bi;
    integer blocks_served = 0;
    initial begin
        forever begin
            @(posedge clk);
            if (sd_rd && !sd_ack) begin
                @(negedge clk); sd_ack <= 1'b1;      // raise ACK before byte 0
                for (bi = 0; bi < 512; bi = bi + 1) begin
                    @(negedge clk);
                    sd_buff_addr <= bi[8:0];
                    sd_buff_dout <= 8'h55;
                    sd_buff_wr   <= 1'b1;
                    @(negedge clk);
                    sd_buff_wr   <= 1'b0;            // 1 strobe cycle per byte
                end
                @(negedge clk); sd_ack <= 1'b0;      // retire the block
                blocks_served = blocks_served + 1;
            end
        end
    end

    // --------------------------------------------------------------
    // scan-window monitor: while media is present and the scan is in
    // flight (engine not yet valid, no scan failure), the flux outputs
    // must NOT be silent.
    // --------------------------------------------------------------
    wire        woz_valid_h  = dut.woz_valid;
    wire        scan_failed_h = dut.scan_failed;
    wire        in_window = img_mounted && !woz_valid_h && !scan_failed_h;

    integer nfail = 0;
    integer win_samples = 0;
    integer silent_bc = 0;
    integer bad_data = 0;
    always @(posedge clk) begin
        if (in_window) begin
            win_samples = win_samples + 1;
            if (bit_count == 32'd0) begin
                silent_bc = silent_bc + 1;
                if (silent_bc <= 4)
                    $display("FAIL: scan-window silence: bit_count=0 at %0t (lba=%0d)", $time, sd_lba);
            end else if (bit_data !== 8'h96) begin
                bad_data = bad_data + 1;
                if (bad_data <= 4)
                    $display("FAIL: scan-window bit_data=%02x (want 96) at %0t", bit_data, $time);
            end
        end
    end

    // --------------------------------------------------------------
    // sequencing
    // --------------------------------------------------------------
    localparam integer RUN_CYCLES = 60000;   // ~4.2 ms machine time, ~80+ blocks
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    initial begin
        // phase 0: no media -> bit_count must be 0 (unchanged behavior)
        repeat (20) @(posedge clk);
        if (bit_count !== 32'd0) begin
            $display("FAIL: bit_count=%0d with no media (want 0)", bit_count);
            nfail = nfail + 1;
        end else
            $display("OK  P0: no media -> bit_count=0");

        // phase 1: mount; engine starts the header scan; window opens
        @(negedge clk);
        reset <= 1'b0;
        img_mounted <= 1'b1;
        $display("OK  P1: mounted at %0t - scan window opens", $time);

        // run through the scan window
        while (cyc < RUN_CYCLES) @(posedge clk);

        // verdict
        if (silent_bc > 0) nfail = nfail + 1;
        if (bad_data  > 0) nfail = nfail + 1;
        if (!disk_mounted) begin
            $display("FAIL: disk_mounted low during scan window");
            nfail = nfail + 1;
        end
        if (win_samples < 1000) begin
            $display("FAIL: coverage gate: only %0d scan-window samples", win_samples);
            nfail = nfail + 1;
        end
        if (blocks_served < 10) begin
            $display("FAIL: coverage gate: fake host served only %0d blocks", blocks_served);
            nfail = nfail + 1;
        end
        if (woz_valid_h) begin
            $display("FAIL: scan completed on 0x55 pattern - image data would be a valid WOZ?!");
            nfail = nfail + 1;
        end

        if (nfail) begin
            $display("TB WOZ SCANWIN: FAIL nfail=%0d (samples=%0d silent_bc=%0d bad_data=%0d blocks=%0d)",
                     nfail, win_samples, silent_bc, bad_data, blocks_served);
            $fatal(1);
        end
        $display("OK  P2: scan window non-silent throughout (%0d samples, %0d blocks served)",
                 win_samples, blocks_served);
        $display("TB WOZ SCANWIN: ALL PASS (nfail=0) at %0t", $time);
        $finish;
    end

    // watchdog
    initial begin
        #200_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
