//
// tb_woz_mb_eng.sv - engine-level multi-block controller differential TB
// (PLAN_WOZ_GS_MULTIBLOCK step 4; adapted from the donor's
// tb_woz_multiblock.sv, no dependency on the donor scratch dir)
//
// DUT: woz_floppy_controller (ported multi-block, IS_35_INCH=0) with a
// fake host that answers sd_rd requests in three modes:
//   FULL   : sd_blk_cnt+1 blocks in ONE ack window (batched host)
//   SINGLE : exactly 1 block per request (0.4.4/converted-image host)
//   MIXED  : short answers of up to 5 blocks (host that returns less
//            than asked)
//
// Phases (one byte oracle: image arrays re-derived by the same pattern):
//   A  WOZ2 track 0 (13 blocks), FULL   -> 1 request (sd_blk_cnt=12)
//   B  WOZ2 track 0 (13 blocks), SINGLE -> 13 requests
//   C  WOZ2 track 0 (13 blocks), MIXED  -> 3 requests [3,8,13]
//   D  WOZ2 track 1 ( 1 block),  FULL   -> 1 request (sd_blk_cnt=0)
//   E  WOZ2 track 2 (32 blocks), FULL   -> 1 request (sd_blk_cnt=31)
//   F  WOZ2 track 3 (33 blocks), FULL   -> 2 requests [49,81] = 32+1 split
//   G  v1 track 0 (14 blocks, TRKS data at byte 256 -> nonzero
//      trks_byte_offset), FULL          -> 1 request (sd_blk_cnt=13),
//      BRAM[0..6655] exact, bit_count = v1_bit_count (0x1234)
//   H  v1 guard: track_id=160 -> no request, no valid, BRAM untouched;
//      return to track 0 -> still valid (cached, no request)
//
// Every phase: all BRAM bytes exact, request LBA sequence exact,
// no early track_data_valid (valid must stay 0 until the load completes),
// last byte and both sides of every block boundary covered by the walk.
//
`timescale 1ns/1ps
module tb_woz_mb_eng;

    localparam real PH = 69.844;   // 14.318 MHz machine clock
    reg clk = 1'b0;
    initial forever #(PH/2.0) clk = ~clk;

    reg reset = 1'b1;
    reg img_mounted = 1'b0;
    reg use_w1 = 1'b0;
    // host mode: 0=FULL, 1=SINGLE, 2=MIXED
    reg [1:0] host_mode = 2'd0;

    wire [31:0] sd_lba;
    wire        sd_rd, sd_wr;
    reg         sd_ack = 1'b0;
    reg  [13:0] sd_buff_addr = 14'd0;
    reg  [7:0]  sd_buff_dout = 8'h00;
    reg         sd_buff_wr   = 1'b0;
    wire [7:0]  sd_buff_din;
    wire [5:0]  sd_blk_cnt;

    reg  [7:0]  track_id = 8'd0;
    wire [31:0] bit_count;
    wire [7:0]  bit_data;
    reg  [15:0] bit_addr = 16'd0;

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
        .sd_buff_blk         ( sd_buff_addr[13:9] ),
        .sd_blk_cnt          ( sd_blk_cnt ),
        .sd_buff_dout        ( sd_buff_dout ),
        .sd_buff_din         ( sd_buff_din ),
        .sd_buff_wr          ( sd_buff_wr ),
        .img_mounted         ( img_mounted ),
        .img_readonly        ( 1'b1 ),
        .img_size            ( img_size_w ),
        .track_id            ( track_id ),
        .ready               ( ready ),
        .disk_mounted        ( disk_mounted ),
        .busy                ( busy ),
        .active              ( 1'b1 ),
        .bit_count           ( bit_count ),
        .bit_addr            ( bit_addr ),
        .stable_side         ( 1'b0 ),
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

    // ==================================================================
    // images (byte oracles)
    // ==================================================================
    localparam N2 = 41984;   // WOZ2: 82 blocks
    localparam N1 = 7168;    // v1: 14 blocks
    wire [63:0] img_size_w = use_w1 ? 64'd7168 : 64'd41984;

    reg [7:0] img2 [0:N2-1];
    reg [7:0] img1 [0:N1-1];
    initial $readmemh("mb_eng2.hex", img2);
    initial $readmemh("mb_eng_w1.hex", img1);

    // WOZ2 track byte oracle: BRAM byte i of track k == img2[base(k)+i]
    function [7:0] w2_oracle(input integer k, input integer i);
        integer b;
        begin
            b = (k == 0) ? 1536 :
                (k == 1) ? 8192 :
                (k == 2) ? 8704 : 25088;
            w2_oracle = img2[b + i];
        end
    endfunction
    function [7:0] w1_oracle(input integer i);
        begin
            if (i == 6648) w1_oracle = 8'h34;
            else if (i == 6649) w1_oracle = 8'h12;
            else w1_oracle = img1[256 + i];
        end
    endfunction

    // ==================================================================
    // fake host
    // ==================================================================
    integer bi, bk, nblk, req_lba;
    integer blocks_served, track_requests, req_cnt_last;
    integer req_lba_log [0:63];
    integer req_n;
    integer phase_blocks_left;   // track blocks still to deliver (phase gate)

    initial begin
        forever begin
            @(posedge clk);
            if (sd_rd && !sd_ack) begin
                req_lba = sd_lba;
                if (host_mode == 2'd1)
                    nblk = 1;
                else if (host_mode == 2'd2) begin
                    nblk = (sd_blk_cnt + 1) < 5 ? (sd_blk_cnt + 1) : 5;
                end else
                    nblk = sd_blk_cnt + 1;
                if (use_w1) begin
                    // v1: meta and track data share block 0; the meta
                    // request has sd_blk_cnt=0, the track request carries
                    // the burst width.
                    if (sd_blk_cnt > 0) begin
                        track_requests = track_requests + 1;
                        req_cnt_last = sd_blk_cnt;
                        req_lba_log[req_n] = req_lba;
                        req_n = req_n + 1;
                        phase_blocks_left = phase_blocks_left - nblk;
                    end
                end else if (req_lba >= 3) begin
                    track_requests = track_requests + 1;
                    req_cnt_last = sd_blk_cnt;
                    req_lba_log[req_n] = req_lba;
                    req_n = req_n + 1;
                    phase_blocks_left = phase_blocks_left - nblk;
                end
                @(negedge clk); sd_ack = 1'b1;
                for (bk = 0; bk < nblk; bk = bk + 1) begin
                    for (bi = 0; bi < 512; bi = bi + 1) begin
                        @(negedge clk);
                        if (use_w1)
                            sd_buff_dout = img1[(req_lba + bk) * 512 + bi];
                        else
                            sd_buff_dout = img2[(req_lba + bk) * 512 + bi];
                        sd_buff_addr = {bk[4:0], bi[8:0]};
                        sd_buff_wr   = 1'b1;
                        @(negedge clk);
                        sd_buff_wr   = 1'b0;
                    end
                end
                @(negedge clk); sd_ack = 1'b0;
                blocks_served = blocks_served + nblk;
            end
        end
    end

    // ==================================================================
    // checks
    // ==================================================================
    integer nfail = 0;
    integer i, errs, timeout;
    integer nexp;
    integer exp_seq [0:63];
    integer exp_cnt;
    integer p;

    task wait_load;
        begin
            timeout = 0;
            while (!track_load_complete && timeout < 300000) begin
                @(posedge clk); timeout = timeout + 1;
            end
            if (timeout >= 300000) begin
                $display("FAIL: track load never completed (mode=%0d)", host_mode);
                nfail = nfail + 1;
            end
        end
    endtask

    task check_data(input integer k, input integer nbyt, input integer w1);
        begin
            errs = 0;
            for (i = 0; i < nbyt; i = i + 1) begin
                @(negedge clk); bit_addr = i[15:0];
                repeat (3) @(posedge clk);
                if (w1) begin
                    if (bit_data !== w1_oracle(i)) begin
                        errs = errs + 1;
                        if (errs <= 4)
                            $display("FAIL v1: byte %0d = %02x (want %02x)", i, bit_data, w1_oracle(i));
                    end
                end else begin
                    if (bit_data !== w2_oracle(k, i)) begin
                        errs = errs + 1;
                        if (errs <= 4)
                            $display("FAIL k%0d: byte %0d = %02x (want %02x)", k, i, bit_data, w2_oracle(k, i));
                    end
                end
            end
            if (errs) nfail = nfail + 1;
            else $display("OK  data: %0d track bytes exact (track %0d, w1=%0d)", nbyt, k, w1);
        end
    endtask

    task check_lba_seq;
        begin
            // module-scope nexp / exp_seq are set by the caller first
            errs = 0;
            for (i = 0; i < nexp; i = i + 1)
                if (req_lba_log[i] !== exp_seq[i]) begin
                    errs = errs + 1;
                    if (errs <= 4)
                        $display("FAIL lba seq: req %0d = %0d (want %0d)", i, req_lba_log[i], exp_seq[i]);
                end
            if (track_requests !== nexp) begin
                $display("FAIL lba seq: %0d requests (want %0d)", track_requests, nexp);
                nfail = nfail + 1;
            end else if (errs) nfail = nfail + 1;
            else $display("OK  lba seq: %0d requests as expected", nexp);
        end
    endtask

    // no early valid: valid must be 0 until the phase's blocks are fully
    // delivered (phase_blocks_left reaches 0) - then allowed to rise
    always @(posedge clk) begin
        if (img_mounted && phase_live && phase_blocks_left > 0 && track_data_valid) begin
            $display("FAIL: early track_data_valid (blocks left=%0d)", phase_blocks_left);
            nfail = nfail + 1;
        end
    end
    reg phase_live = 1'b0;

    // sequencing
    // ==================================================================
    initial begin
        reset = 1'b1;
        img_mounted = 1'b0; use_w1 = 1'b0; host_mode = 2'd0;
        bit_addr = 16'd0;
        blocks_served = 0; track_requests = 0; req_n = 0;
        phase_blocks_left = 0; phase_live = 1'b0;
        repeat (20) @(posedge clk);
        reset = 1'b0;

        // ---- A: WOZ2 track 0 (13 blocks), FULL ----
        @(negedge clk); img_mounted <= 1'b1;
        track_requests = 0; req_n = 0; blocks_served = 0;
        phase_blocks_left = 13; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (bit_count !== 32'd51200) begin
            $display("FAIL A: bit_count=%0d (want 51200)", bit_count); nfail = nfail + 1;
        end else $display("OK  A: bit_count=51200");
        if (track_requests != 1) begin
            $display("FAIL A: %0d requests (want 1 multi-block)", track_requests); nfail = nfail + 1;
        end
        if (req_cnt_last != 6'd12) begin
            $display("FAIL A: request asked %0d+1 blocks (want 13)", req_cnt_last); nfail = nfail + 1;
        end else $display("OK  A: ONE request, sd_blk_cnt=12");
        check_data(0, 6656, 1'b0);
        if (blocks_served != 16) begin
            $display("FAIL A: blocks_served=%0d (want 16)", blocks_served); nfail = nfail + 1;
        end else $display("OK  A: 16 blocks served (3 meta + 13 track)");

        // ---- B: track 0, SINGLE (13 requests) ----
        @(negedge clk); img_mounted <= 1'b0;
        repeat (100) @(posedge clk);
        track_id = 8'd0;
        exp_cnt = 13;
        for (p = 0; p < 13; p = p + 1) exp_seq[p] = 3 + p;
        track_requests = 0; req_n = 0; blocks_served = 0;
        host_mode = 2'd1;
        @(negedge clk); img_mounted <= 1'b1;
        phase_blocks_left = 13; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (track_requests != 13) begin
            $display("FAIL B: %0d short-answer requests (want 13)", track_requests); nfail = nfail + 1;
        end else $display("OK  B: 13 single-block requests advanced correctly");
        nexp = 13; check_lba_seq;
        check_data(0, 6656, 1'b0);
        if (blocks_served != 16) begin
            $display("FAIL B: blocks_served=%0d (want 16)", blocks_served); nfail = nfail + 1;
        end else $display("OK  B: 16 blocks served");

        // ---- C: track 0, MIXED (5,5,3 -> 3 requests [3,8,13]) ----
        @(negedge clk); img_mounted <= 1'b0;
        repeat (100) @(posedge clk);
        track_requests = 0; req_n = 0; blocks_served = 0;
        host_mode = 2'd2;
        exp_cnt = 3; exp_seq[0] = 3; exp_seq[1] = 8; exp_seq[2] = 13;
        @(negedge clk); img_mounted <= 1'b1;
        phase_blocks_left = 13; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (track_requests != 3) begin
            $display("FAIL C: %0d mixed requests (want 3)", track_requests); nfail = nfail + 1;
        end else $display("OK  C: 3 mixed requests (5,5,3)");
        nexp = 3; check_lba_seq;
        check_data(0, 6656, 1'b0);
        if (blocks_served != 16) begin
            $display("FAIL C: blocks_served=%0d (want 16)", blocks_served); nfail = nfail + 1;
        end else $display("OK  C: 16 blocks served");
        host_mode = 2'd0;

        // ---- D: track 1 (1 block), FULL ----
        @(negedge clk); img_mounted <= 1'b0;
        repeat (100) @(posedge clk);
        track_requests = 0; req_n = 0; blocks_served = 0;
        @(negedge clk); img_mounted <= 1'b1;
        @(negedge clk); track_id <= 8'd1;
        phase_blocks_left = 1; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (bit_count !== 32'd4000) begin
            $display("FAIL D: bit_count=%0d (want 4000)", bit_count); nfail = nfail + 1;
        end
        if (track_requests != 1 || req_cnt_last != 6'd0) begin
            $display("FAIL D: %0d requests, last cnt=%0d (want 1, cnt=0)", track_requests, req_cnt_last);
            nfail = nfail + 1;
        end else $display("OK  D: 1-block track, ONE request (sd_blk_cnt=0)");
        check_data(1, 512, 1'b0);

        // ---- E: track 2 (32 blocks), FULL ----
        @(negedge clk); img_mounted <= 1'b0;
        repeat (100) @(posedge clk);
        track_requests = 0; req_n = 0; blocks_served = 0;
        @(negedge clk); img_mounted <= 1'b1;
        @(negedge clk); track_id <= 8'd2;
        phase_blocks_left = 32; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (bit_count !== 32'd409600) begin
            $display("FAIL E: bit_count=%0d (want 409600)", bit_count); nfail = nfail + 1;
        end
        if (track_requests != 1 || req_cnt_last != 6'd31) begin
            $display("FAIL E: %0d requests, last cnt=%0d (want 1, cnt=31)", track_requests, req_cnt_last);
            nfail = nfail + 1;
        end else $display("OK  E: 32-block track, ONE request (sd_blk_cnt=31)");
        check_data(2, 16384, 1'b0);

        // ---- F: track 3 (33 blocks), FULL -> 32+1 split ----
        $display("PHASE F start");
        @(negedge clk); img_mounted <= 1'b0;
        repeat (100) @(posedge clk);
        track_requests = 0; req_n = 0; blocks_served = 0;
        @(negedge clk); img_mounted <= 1'b1;
        @(negedge clk); track_id <= 8'd3;
        exp_cnt = 2; exp_seq[0] = 49; exp_seq[1] = 81;
        phase_blocks_left = 33; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (bit_count !== 32'd413696) begin
            $display("FAIL F: bit_count=%0d (want 413696)", bit_count); nfail = nfail + 1;
        end
        if (track_requests != 2) begin
            $display("FAIL F: %0d requests (want 2 = 32+1 split)", track_requests); nfail = nfail + 1;
        end else $display("OK  F: 33-block track split 32+1");
        nexp = 2; check_lba_seq;
        if (req_lba_log[0] !== 49 || req_lba_log[1] !== 81) begin
            $display("FAIL F: LBA seq %0d,%0d (want 49,81)", req_lba_log[0], req_lba_log[1]);
            nfail = nfail + 1;
        end
        check_data(3, 16896, 1'b0);

        // ---- G: v1 image, track 0 (14 blocks, nonzero TRKS offset) ----
        $display("PHASE G start");
        @(negedge clk); img_mounted <= 1'b0;
        repeat (100) @(posedge clk);
        track_id = 8'd0;
        use_w1 = 1'b1;
        track_requests = 0; req_n = 0; blocks_served = 0;
        @(negedge clk); img_mounted <= 1'b1;
        phase_blocks_left = 14; phase_live = 1'b1;
        wait_load;
        phase_live = 1'b0;
        repeat (10) @(posedge clk);
        if (bit_count !== 32'h0000_1234) begin
            $display("FAIL G: v1 bit_count=%0d (want 0x1234)", bit_count); nfail = nfail + 1;
        end else $display("OK  G: v1 bit_count=0x1234 (captured at raw 6648/6649)");
        if (track_requests != 1 || req_cnt_last != 6'd13) begin
            $display("FAIL G: %0d requests, last cnt=%0d (want 1, cnt=13)", track_requests, req_cnt_last);
            nfail = nfail + 1;
        end else $display("OK  G: 14-block v1 track, ONE request (sd_blk_cnt=13)");
        if (blocks_served != 15) begin
            $display("FAIL G: blocks_served=%0d (want 15 = 1 meta + 14 track)", blocks_served);
            nfail = nfail + 1;
        end else $display("OK  G: 15 blocks served");
        check_data(0, 6656, 1'b1);

        // ---- H: v1 guard: track_id=160 -> no request, no valid ----
        $display("PHASE H start");
        begin : h_guard
            track_requests = 0; req_n = 0;
            @(negedge clk); track_id <= 8'd160;
            repeat (2000) @(posedge clk);
            if (track_data_valid) begin
                $display("FAIL H: track_data_valid for out-of-range id 160"); nfail = nfail + 1;
            end
            if (track_requests != 0) begin
                $display("FAIL H: %0d requests for out-of-range id 160", track_requests); nfail = nfail + 1;
            end
            // restore: cached track 0 must re-validate with NO new request
            // (no request was issued for 160, so nothing could have moved)
            @(negedge clk); track_id <= 8'd0;
            repeat (200) @(posedge clk);
            if (!track_data_valid) begin
                $display("FAIL H: cached v1 track 0 not valid after restore"); nfail = nfail + 1;
            end
            if (track_requests != 0) begin
                $display("FAIL H: %0d requests after restore (want 0, cached)", track_requests);
                nfail = nfail + 1;
            end
            $display("OK  H: id=160 guard (no request/valid), cached restore");
        end

        if (nfail) begin
            $display("TB WOB MB ENG: FAIL nfail=%0d", nfail);
            $fatal(1);
        end
        $display("TB WOB MB ENG: ALL PASS (nfail=0)");
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
