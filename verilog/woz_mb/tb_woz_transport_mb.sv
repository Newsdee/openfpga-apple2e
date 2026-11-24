//
// tb_woz_transport_mb.sv - multi-block burst WOZ transport (PLAN_WOZ_GS_
// MULTIBLOCK step 3) against the Unit-2 sector service + real
// io_sdram_pocket + DRAM model.
//
// DUT: sdram_woz_transport_mb (14.318 MHz). One engine request
// (sd_rd + sd_lba + sd_blk_cnt) is answered with up to 32 consecutive
// 512-byte blocks in ONE sd_ack window: ACK rises before byte 0 of
// block 0, stays high through every intra-burst gap (sd_buff_wr low,
// fresh LBA re-arm between blocks), and falls once after the final
// block's hold.
//
// Coverage:
//   T0  boot: SDRAM init, store a 3072-byte (6-sector) image
//   T1  4-block burst (LBA 0..3): 2048 bytes exact, {blk,byte} walk
//       exact, one ACK rise before byte 0, one ACK fall at the end,
//       no strobe ever with ACK low, no ACK fall between blocks
//   T2  32-block burst (LBA 2..33): max-width request, all sectors
//       real; 31 intra-burst gaps, single ACK pair
//   T3  1-block burst (cnt=0): parity with the 0.4.4 single-block
//       service behavior
//   T4  mid-burst EOF fault: LBA 39 + 3 blocks -> block 39 (last real)
//       delivers 512 bytes, block 40 (starts exactly at EOF) fetches
//       a fault, burst ends as a short answer (ACK falls after the last
//       delivered byte, no stale bytes), oor_fault latches; service
//       recovers after fault_clr
//   T5  OOR LBA at acceptance (high 16 bits set): oor_fault, no ACK
//   T6  drive_active dropped mid-burst: burst aborts, no stale
//       strobes, ACK falls; remount restores service
//   T7  DUT + fetcher (machine side) reset mid-burst: held window
//       self-releases, no stale bytes, service recovers
//
// Global invariants (checked every cycle):
//   * sd_buff_wr never asserts while sd_ack is low
//   * ACK has exactly one rising and one falling edge per burst
//
`timescale 1ns/1ps
module tb_woz_transport_mb;

    parameter real PHASE = 3.756;   // 180 deg chip_clk phase (shipping)

    localparam real PM = 69.844;    // 14.318 MHz machine
    localparam real PC = 3.756;     // 133.12 MHz ctrl
    reg ctrl_clk, chip_clk, clk90, clk_mach;

    always begin
        ctrl_clk = 1'b0;
        #4000;
        forever #(PC/2.0) ctrl_clk = ~ctrl_clk;
    end
    always begin
        chip_clk = 1'b0;
        #4000;
        #PHASE;
        forever #(PC/2.0) chip_clk = ~chip_clk;
    end
    always begin
        clk90 = 1'b0;
        #4000;
        #(PHASE + PC/2.0);
        forever #(PC/2.0) clk90 = ~clk90;
    end
    always begin
        clk_mach = 1'b0;
        #4000;
        forever #(PM/2.0) clk_mach = ~clk_mach;
    end

    // ==================================================================
    // DRAM model + SDRAM controller
    // ==================================================================
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    reg por_done = 1'b0;
    reg fault_halt = 1'b0;

    tb_dram_model m0 (
        .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
        .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
        .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
        .fault_halt(fault_halt)
    );

    wire        sdram_init_done;
    wire        ov_word_rd, ov_word_wr, ov_word_busy, ov_word_done, ov_word_rd_valid;
    wire        ov_word_op_start;
    wire [23:0] ov_word_addr;
    wire [31:0] ov_word_data, ov_word_q;

    io_sdram_pocket isr0 (
        .controller_clk   ( ctrl_clk ),
        .chip_clk         ( chip_clk ),
        .clk_90           ( clk90 ),
        .reset_n          ( 1'b1 ),
        .phy_cke          ( dram_cke ),
        .phy_clk          ( dram_clk ),
        .phy_cas          ( dram_cas_n ),
        .phy_ras          ( dram_ras_n ),
        .phy_we           ( dram_we_n ),
        .phy_ba           ( dram_ba ),
        .phy_a            ( dram_a ),
        .phy_dq           ( dram_dq ),
        .phy_dqm          ( dram_dqm ),
        .burst_rd         ( 1'b0 ),
        .burst_addr       ( 25'd0 ),
        .burst_len        ( 11'd0 ),
        .burst_32bit      ( 1'b0 ),
        .burst_data       ( ),
        .burst_data_valid ( ),
        .burst_data_done  ( ),
        .burstwr          ( 1'b0 ),
        .burstwr_addr     ( 15'd0 ),
        .burstwr_ready    ( ),
        .burstwr_strobe   ( 1'b0 ),
        .burstwr_data     ( 16'd0 ),
        .burstwr_done     ( 1'b0 ),
        .word_rd          ( ov_word_rd ),
        .word_wr          ( ov_word_wr ),
        .word_addr        ( ov_word_addr ),
        .word_data        ( ov_word_data ),
        .word_q           ( ov_word_q ),
        .word_busy        ( ov_word_busy),
        .word_done        ( ov_word_done ),
        .word_rd_valid    ( ov_word_rd_valid ),
        .word_op_start    ( ov_word_op_start ),
        .boot_done        ( sdram_init_done )
    );

    // ==================================================================
    // word owner + sector fetcher (Unit 2)
    // ==================================================================
    reg         st_req;
    reg  [23:0] st_addr;
    reg  [31:0] st_data;
    wire        st_busy, st_done;

    reg         vr_req;
    reg  [23:0] vr_addr;
    wire        vr_done;
    wire [31:0] vr_data;

    wire        fc_req_w;
    wire [23:0] fc_addr_w;
    wire [7:0]  fc_gen_w;
    wire        fc_active_w, fc_word_valid_w, fc_done_w;
    wire [31:0] fc_data_w;
    wire [7:0]  fc_done_len_w, fc_done_gen_w;

    wire        fetch_busy, sector_ready, fetch_fault;
    wire [15:0] sector_lba;
    wire [7:0]  sector_byte_data;
    wire        fetch_req;
    wire [15:0] fetch_lba;
    wire [8:0]  sector_byte_addr;
    wire        sector_done;
    reg         img_gen_tb;
    reg         rst_n_mach_tb;   // fetcher machine-side reset (T7)

    sdram_word_owner owner0 (
        .clk        ( ctrl_clk ),
        .rst_n      ( 1'b1 ),
        .word_rd    ( ov_word_rd ),
        .word_wr    ( ov_word_wr ),
        .word_addr  ( ov_word_addr ),
        .word_data  ( ov_word_data ),
        .word_q     ( ov_word_q ),
        .word_busy  ( ov_word_busy),
        .word_done  ( ov_word_done ),
        .word_rd_valid( ov_word_rd_valid ),
        .word_op_start( ov_word_op_start ),
        .init_done  ( sdram_init_done ),
        .st_req     ( st_req ),
        .st_addr    ( st_addr ),
        .st_data    ( st_data ),
        .st_busy    ( st_busy),
        .st_done    ( st_done ),
        .vr_req     ( vr_req ),
        .vr_addr    ( vr_addr ),
        .vr_done    ( vr_done),
        .vr_data    ( vr_data ),
        .fc_req     ( fc_req_w ),
        .fc_addr    ( fc_addr_w ),
        .fc_gen     ( fc_gen_w ),
        .fc_active  ( fc_active_w),
        .fc_word_valid( fc_word_valid_w),
        .fc_done    ( fc_done_w ),
        .fc_data    ( fc_data_w ),
        .fc_done_len( fc_done_len_w ),
        .fc_done_gen( fc_done_gen_w)
    );

    sdram_sector_fetch fetch0 (
        .clk_mach      ( clk_mach ),
        .rst_n_mach    ( rst_n_mach_tb ),
        .clk_ctrl      ( ctrl_clk ),
        .rst_n_ctrl    ( 1'b1 ),
        .fetch_req     ( fetch_req ),
        .fetch_lba     ( fetch_lba ),
        .fetch_busy    ( fetch_busy),
        .sector_ready  ( sector_ready),
        .sector_lba    ( sector_lba),
        .sector_byte_addr ( sector_byte_addr),
        .sector_byte_data ( sector_byte_data),
        .sector_done   ( sector_done),
        .fetch_fault   ( fetch_fault),
        .init_done     ( sdram_init_done),
        .img_nbytes    ( 32'd20480 ),
        .img_gen       ( img_gen_tb ),
        .fc_req        ( fc_req_w ),
        .fc_addr       ( fc_addr_w ),
        .fc_gen        ( fc_gen_w ),
        .fc_active     ( fc_active_w ),
        .fc_word_valid ( fc_word_valid_w),
        .fc_done       ( fc_done_w ),
        .fc_data       ( fc_data_w ),
        .fc_done_gen   ( fc_done_gen_w )
    );

    // ==================================================================
    // DUT: multi-block burst transport
    // ==================================================================
    reg         e_sd_rd;
    reg  [31:0] e_sd_lba;
    reg  [5:0]  e_sd_blkcnt;
    wire        e_sd_ack;
    reg         e_sd_wr;
    wire [13:0] e_sd_buff_addr;
    wire        e_sd_buff_wr;
    wire [7:0]  e_sd_buff_dout;
    reg         e_drive_active;
    reg         e_fault_clr;
    reg         e_rst_n;
    wire        e_wr_fault, e_oor_fault, e_transport_fault;

    sdram_woz_transport_mb dut (
        .clk            ( clk_mach ),
        .rst_n          ( e_rst_n ),
        .sd_rd          ( e_sd_rd ),
        .sd_lba         ( e_sd_lba ),
        .sd_blk_cnt_in  ( e_sd_blkcnt ),
        .sd_ack         ( e_sd_ack ),
        .sd_wr          ( e_sd_wr ),
        .sd_buff_addr   ( e_sd_buff_addr),
        .sd_buff_din    ( 8'h00 ),
        .sd_buff_wr     ( e_sd_buff_wr),
        .sd_buff_dout   ( e_sd_buff_dout),
        .fetch_req      ( fetch_req),
        .fetch_lba      ( fetch_lba),
        .fetch_busy     ( fetch_busy),
        .sector_ready   ( sector_ready),
        .sector_lba     ( sector_lba),
        .sector_byte_data ( sector_byte_data),
        .fetch_fault    ( fetch_fault),
        .sector_byte_addr ( sector_byte_addr),
        .sector_done    ( sector_done),
        .drive_active   ( e_drive_active),
        .fault_clr      ( e_fault_clr),
        .wr_fault       ( e_wr_fault),
        .oor_fault      ( e_oor_fault),
        .transport_fault( e_transport_fault)
    );

    // ==================================================================
    // image: 20480 bytes = 40 sectors; byte b -> (7*b + 13) & 0xFF
    // ==================================================================
    localparam IMG_BYTES = 20480;
    localparam IMG_WORDS = 5120;

    function [7:0] exp_byte(input integer b);
        exp_byte = ((7*b + 13) & 32'h00FF);
    endfunction
    function [31:0] exp_word(input integer w);
        exp_word = {exp_byte(4*w), exp_byte(4*w+1), exp_byte(4*w+2), exp_byte(4*w+3)};
    endfunction
    function [7:0] exp_abspath(input integer b);
        exp_abspath = (b < IMG_BYTES) ? exp_byte(b) : 8'h00;
    endfunction

    // store stub (ctrl domain)
    reg [12:0] st_wi;
    reg       st_go;
    always @(posedge ctrl_clk) begin
        st_req <= 1'b0;
        if (st_go && !st_busy && st_wi < IMG_WORDS) begin
            st_addr <= st_wi;
            st_data <= exp_word(st_wi);
            st_req  <= 1'b1;
        end
        if (st_done)
            st_wi <= st_wi + 13'd1;
    end
    wire store_complete = (st_wi >= IMG_WORDS[12:0]);

    // ==================================================================
    // global invariants (machine domain)
    // ==================================================================
    integer nfail = 0;
    always @(posedge clk_mach) begin
        if (e_sd_buff_wr && !e_sd_ack) begin
            $display("FAIL INV: strobe with ACK low at %0t", $time);
            nfail = nfail + 1;
        end
    end

    // ==================================================================
    // engine stub: request a burst, consume the stream, check the walk
    // ==================================================================
    reg        prev_ack;
    integer    burst_rises, burst_falls;

    // consumes a burst; returns the number of bytes delivered in n_bytes;
    // checks the {blk,byte} walk, every value, and the single-ACK-pair
    // edge discipline. If short_expect > 0, the burst is expected to
    // deliver exactly short_expect bytes and end via a fault.
    task automatic burst_read(input [15:0] base_lba, input [5:0] cnt_m1,
                              input integer short_expect,
                              output integer n_bytes);
        integer n, t;
        reg [7:0] got;
        reg [13:0] want_addr;
        reg [4:0] want_blk;
        reg [8:0] want_byt;
        begin
            prev_ack   = 1'b0;
            burst_rises = 0;
            burst_falls = 0;
            n_bytes    = 0;
            n          = 0;
            e_sd_wr    = 1'b0;
            e_sd_lba   = {16'd0, base_lba};
            e_sd_blkcnt= cnt_m1;
            e_sd_rd    = 1'b1;

            while (1) begin
                @(posedge clk_mach);
                if (!e_rst_n) begin
                    // reset happened mid-burst: stop consuming
                    e_sd_rd = 1'b0;
                    n_bytes = n;
                    return;
                end
                if (e_sd_ack && !prev_ack) burst_rises = burst_rises + 1;
                if (prev_ack && !e_sd_ack) begin
                    if (burst_rises == 0) begin
                        $display("FAIL B%d: ACK fell without a rise (lba=%0d)", base_lba, base_lba);
                        nfail = nfail + 1;
                    end
                    burst_falls = burst_falls + 1;
                    e_sd_rd = 1'b0;
                    n_bytes = n;
                    return;
                end
                prev_ack = e_sd_ack;
                if (e_sd_buff_wr) begin
                    n = n + 1;
                    want_blk = (n - 1) >> 9;
                    want_byt = (n - 1) & 511;
                    want_addr = {want_blk, want_byt};
                    if (e_sd_buff_addr !== want_addr) begin
                        $display("FAIL B%0d: addr walk at byte %0d: got=%0d want=%0d", base_lba, n - 1, e_sd_buff_addr, want_addr);
                        nfail = nfail + 1;
                    end
                    got = e_sd_buff_dout;
                    if (got !== exp_abspath(base_lba*512 + (n - 1))) begin
                        if ((n - 1) < 8 || ((n - 1) % 512) == 511) begin
                            $display("FAIL B%0d: byte %0d got=%02x want=%02x", base_lba, n - 1, got, exp_abspath(base_lba*512 + (n - 1)));
                        end else if (nfail < 64) begin
                            $display("FAIL B%0d: byte %0d got=%02x want=%02x (suppressed)", base_lba, n - 1, got, exp_abspath(base_lba*512 + (n - 1)));
                        end
                        nfail = nfail + 1;
                    end
                end
                if (n > 40000) begin
                    $display("FAIL B%0d: burst timeout after %0d bytes", base_lba, n);
                    nfail = nfail + 1;
                    e_sd_rd = 1'b0;
                    n_bytes = n;
                    return;
                end
            end
            n_bytes = n;
        end
    endtask

    // ==================================================================
    // test sequencing
    // ==================================================================
    integer got_bytes;
    initial begin
        e_sd_rd = 1'b0; e_sd_wr = 1'b0; e_sd_lba = 32'd0; e_sd_blkcnt = 6'd0;
        e_drive_active = 1'b0; e_fault_clr = 1'b0; e_rst_n = 1'b1;
        rst_n_mach_tb = 1'b1;
        st_go = 1'b0; st_wi = 13'd0;
        vr_req = 1'b0; vr_addr = 24'd0;
        img_gen_tb = 8'd0;

        #1000;
        por_done = 1;

        while (!sdram_init_done) @(posedge ctrl_clk);
        $display("OK  T0: SDRAM init at %0t", $time);

        st_go = 1'b1;
        while (!store_complete) @(posedge ctrl_clk);
        st_go = 1'b0;
        $display("OK  T0: stored %0d words (st_wi=%0d) at %0t", st_wi, st_wi, $time);

        // T0b: probe the SDRAM stack directly via the owner's read client
        // (isolates store/SDRAM from the fetcher path)
        begin : t0b_probe
            integer pw;
            reg [23:0] pwlist [0:5];
            reg [31:0] pwdata;
            reg [23:0] pwaddr;
            reg [31:0] pwexp;
            pwlist[0] = 24'd0;
            pwlist[1] = 24'd1023;
            pwlist[2] = 24'd1024;
            pwlist[3] = 24'd2048;
            pwlist[4] = 24'd4096;
            pwlist[5] = 24'd5119;
            for (pw = 0; pw < 6; pw = pw + 1) begin
                pwaddr = pwlist[pw];
                pwexp  = exp_word(pwaddr);
                vr_req = 1'b1;
                vr_addr = pwaddr;
                while (!vr_done) @(posedge ctrl_clk);
                vr_req = 1'b0;
                pwdata = vr_data;
                $display("T0b: word %0d got=%08x want=%08x %s",
                    pwaddr, pwdata, pwexp,
                    (pwdata === pwexp) ? "OK" : "MISMATCH");
                if (pwdata !== pwexp) nfail = nfail + 1;
                repeat (4) @(posedge ctrl_clk);
            end
        end

        e_drive_active = 1'b1;
        repeat (4) @(posedge clk_mach);

        // T1: 4-block burst from LBA 0
        burst_read(16'd0, 6'd3, 0, got_bytes);
        if (got_bytes != 2048) begin
            $display("FAIL T1: expected 2048 bytes, got %0d", got_bytes);
            nfail = nfail + 1;
        end
        if (burst_rises != 1 || burst_falls != 1) begin
            $display("FAIL T1: ACK edges rise=%0d fall=%0d (want 1/1)", burst_rises, burst_falls);
            nfail = nfail + 1;
        end
        $display("OK  T1: 4-block burst, %0d bytes, ACK 1/1 at %0t", got_bytes, $time);

        // T2: 32-block burst from LBA 2 (max width; all 32 sectors real)
        burst_read(16'd2, 6'd31, 0, got_bytes);
        if (got_bytes != 16384) begin
            $display("FAIL T2: expected 16384 bytes, got %0d", got_bytes);
            nfail = nfail + 1;
        end
        if (burst_rises != 1 || burst_falls != 1) begin
            $display("FAIL T2: ACK edges rise=%0d fall=%0d (want 1/1)", burst_rises, burst_falls);
            nfail = nfail + 1;
        end
        $display("OK  T2: 32-block burst, %0d bytes at %0t", got_bytes, $time);

        // T3: 1-block burst (parity with 0.4.4 service)
        burst_read(16'd3, 6'd0, 0, got_bytes);
        if (got_bytes != 512) begin
            $display("FAIL T3: expected 512 bytes, got %0d", got_bytes);
            nfail = nfail + 1;
        end
        if (burst_rises != 1 || burst_falls != 1) begin
            $display("FAIL T3: ACK edges rise=%0d fall=%0d (want 1/1)", burst_rises, burst_falls);
            nfail = nfail + 1;
        end
        $display("OK  T3: 1-block burst, %0d bytes at %0t", got_bytes, $time);

        // T4: mid-burst EOF fault (LBA 39 + 3 blocks; block 39 real,
        // block 40 starts exactly at EOF -> fetch fault, short answer)
        burst_read(16'd39, 6'd2, 512, got_bytes);
        if (got_bytes != 512) begin
            $display("FAIL T4: expected short answer of 512 bytes, got %0d", got_bytes);
            nfail = nfail + 1;
        end
        if (burst_rises != 1 || burst_falls != 1) begin
            $display("FAIL T4: ACK edges rise=%0d fall=%0d (want 1/1)", burst_rises, burst_falls);
            nfail = nfail + 1;
        end
        if (!e_oor_fault) begin
            $display("FAIL T4: oor_fault not latched on mid-burst fault");
            nfail = nfail + 1;
        end
        $display("OK  T4: mid-burst fault -> short answer, oor_fault at %0t", $time);
        // recovery
        e_sd_rd = 1'b0;
        e_fault_clr = 1'b1;
        repeat (8) @(posedge clk_mach);
        e_fault_clr = 1'b0;
        repeat (8) @(posedge clk_mach);   // let the fetcher leave ST_FAULT
        if (e_oor_fault) begin
            $display("FAIL T4: oor_fault not cleared");
            nfail = nfail + 1;
        end
        burst_read(16'd0, 6'd0, 0, got_bytes);
        if (got_bytes != 512) begin
            $display("FAIL T4: recovery read failed (%0d bytes)", got_bytes);
            nfail = nfail + 1;
        end
        $display("OK  T4: service recovered, LBA 0 read at %0t", $time);

        // T5: OOR LBA at acceptance
        e_sd_rd = 1'b1; e_sd_lba = 32'h0001_0000; e_sd_blkcnt = 6'd0;
        @(posedge clk_mach);
        begin : t5_wait
            integer t5c;
            reg t5_ok;
            t5c = 0; t5_ok = 1'b0;
            while (!e_oor_fault && !t5_ok) begin
                @(posedge clk_mach);
                if (e_sd_ack) begin
                    $display("FAIL T5: sd_ack raised for OOR LBA");
                    nfail = nfail + 1;
                    t5_ok = 1'b1;
                end else if (t5c > 100) begin
                    $display("FAIL T5: OOR fault timeout");
                    nfail = nfail + 1;
                    t5_ok = 1'b1;
                end
                t5c = t5c + 1;
            end
        end
        e_sd_rd = 1'b0;
        if (!e_oor_fault) begin
            $display("FAIL T5: oor_fault not latched");
            nfail = nfail + 1;
        end
        $display("OK  T5: OOR LBA fault, no ACK at %0t", $time);
        e_fault_clr = 1'b1;
        repeat (8) @(posedge clk_mach);
        e_fault_clr = 1'b0;

        // T6: drive_active dropped mid-burst
        e_sd_wr    = 1'b0;
        e_sd_lba   = 32'd0;
        e_sd_blkcnt= 6'd31;
        e_sd_rd    = 1'b1;
        // consume ~1000 bytes, then eject
        begin : t6_eject
            integer t6n, t6t;
            t6n = 0; t6t = 0;
            while (t6n < 1000) begin
                @(posedge clk_mach);
                if (e_sd_buff_wr) t6n = t6n + 1;
                if (t6t > 4000) begin
                    $display("FAIL T6: no bytes flowing before eject");
                    nfail = nfail + 1;
                    break;
                end
                t6t = t6t + 1;
            end
            e_drive_active = 1'b0;
            // wait for the ACK to fall (abort)
            t6t = 0;
            while (e_sd_ack && t6t < 200) begin
                @(posedge clk_mach);
                t6t = t6t + 1;
            end
            if (e_sd_ack) begin
                $display("FAIL T6: ACK still high after eject");
                nfail = nfail + 1;
            end
            if (e_sd_buff_wr) begin
                $display("FAIL T6: strobe still active after eject");
                nfail = nfail + 1;
            end
            e_sd_rd = 1'b0;
        end
        repeat (10) @(posedge clk_mach);
        e_drive_active = 1'b1;
        repeat (10) @(posedge clk_mach);
        burst_read(16'd3, 6'd1, 0, got_bytes);
        if (got_bytes != 1024) begin
            $display("FAIL T6: post-eject burst failed (%0d bytes)", got_bytes);
            nfail = nfail + 1;
        end
        $display("OK  T6: mid-burst eject + remount recovery at %0t", $time);

        // T7: DUT + fetcher machine-side reset mid-burst
        e_sd_wr    = 1'b0;
        e_sd_lba   = 32'd0;
        e_sd_blkcnt= 6'd31;
        e_sd_rd    = 1'b1;
        begin : t7_reset
            integer t7n, t7t;
            t7n = 0; t7t = 0;
            while (t7n < 1024) begin
                @(posedge clk_mach);
                if (e_sd_buff_wr) t7n = t7n + 1;
                if (t7t > 4000) begin
                    $display("FAIL T7: no bytes flowing before reset");
                    nfail = nfail + 1;
                    break;
                end
                t7t = t7t + 1;
            end
            e_rst_n       = 1'b0;
            rst_n_mach_tb = 1'b0;
            repeat (5) @(posedge clk_mach);
            e_rst_n       = 1'b1;
            rst_n_mach_tb = 1'b1;
            e_sd_rd = 1'b0;
        end
        // after reset: no ACK, no strobe
        repeat (10) @(posedge clk_mach);
        if (e_sd_ack || e_sd_buff_wr) begin
            $display("FAIL T7: ACK/strobe active after reset");
            nfail = nfail + 1;
        end
        // wait for the fetcher's held-window self-release (~440 mach cyc)
        repeat (800) @(posedge clk_mach);
        burst_read(16'd0, 6'd0, 0, got_bytes);
        if (got_bytes != 512) begin
            $display("FAIL T7: post-reset burst failed (%0d bytes)", got_bytes);
            nfail = nfail + 1;
        end
        $display("OK  T7: mid-burst reset + recovery at %0t", $time);

        if (nfail) begin
            $display("TB WOX TRANSPORT MB: FAIL nfail=%0d", nfail);
            $fatal(1);
        end
        $display("TB WOX TRANSPORT MB: ALL PASS (nfail=0) at %0t", $time);
        $finish;
    end

    // watchdog: 100k machine cycles (~7 ms sim)
    initial begin
        repeat (100000) @(posedge clk_mach);
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
