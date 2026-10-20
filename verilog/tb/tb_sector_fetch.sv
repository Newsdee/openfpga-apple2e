//
// tb_sector_fetch.sv - M1 Unit 2 stage-1: word owner + sector fetcher
// against the real io_sdram_pocket + behavioral DRAM model
//
// DUT stack (bypassing the sdram_storage wrapper - that integration is
// re-verified by re-running tb_top_storage):
//   tb_dram_model <- io_sdram_pocket <- sdram_word_owner
//                                                ^  ^
//                                          store  sector_fetch
//
// Coverage (expert M1 stage-1 ladder):
//   T0  boot: SDRAM init completes, owner ready
//   T1  load 2000 B (500 words) via the store client; verify client reads
//       words 0/249/499 back (M0 path through the owner: endianness +
//       per-word completion)
//   T2  fetch sector 0: all 512 bytes compared (first/last byte, word
//       unpack order [31:24] first)
//   T3  consecutive full sectors 1,2
//   T4  partial tail sector 3: 464 real bytes + 48 deterministic 0x00 pad
//   T5  sector 4 wholly beyond EOF -> fault, no ready
//   T6  huge LBA (0xFFFF) -> fault
//   T7  contention: store write issued mid-fetch - fetch runs to
//       completion (latched), store proceeds after; data intact
//   T8  generation invalidation mid-transfer: result discarded, no
//       stale sector published; fresh-generation fetch succeeds
//   T9  scoreboard: the fetch client NEVER drives a word-port write
//
// Build (MSYS2 UCRT64, from repo root):
//   see verilog/README.md pattern (--binary --timing)
//
`timescale 1ns/1ps
module tb_sector_fetch;

    parameter real PHASE = 3.756;   // 180 deg chip_clk phase (shipping)

    // ==================================================================
    // clocks
    // ==================================================================
    localparam real PM = 69.844;    // 14.318 MHz
    localparam real PC = 3.756;     // 133.12 MHz
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
        .word_busy        ( ov_word_busy ),
        .word_done        ( ov_word_done ),
        .word_rd_valid    ( ov_word_rd_valid ),
        .boot_done        ( sdram_init_done )
    );

    // ==================================================================
    // word owner + sector fetcher (the M1 Unit 2 DUTs)
    // ==================================================================
    // store client (stub of disk_store's protocol: 1-cycle req pulse
    // gated on busy, wait done)
    reg         st_req;
    reg  [23:0] st_addr;
    reg  [31:0] st_data;
    wire        st_busy, st_done;

    // verify client (stub of disk_verifier's word-port view)
    reg         vr_req;
    reg  [23:0] vr_addr;
    wire        vr_done;
    wire [31:0] vr_data;

    // fetch client
    wire        fc_req_w;
    wire [23:0] fc_addr_w;
    wire [7:0]  fc_gen_w;
    wire        fc_active_w, fc_word_valid_w, fc_done_w;
    wire [31:0] fc_data_w;
    wire [7:0]  fc_done_len_w, fc_done_gen_w;

    // sector service (machine domain)
    reg         fetch_req;
    reg  [15:0] fetch_lba;
    wire        fetch_busy, sector_ready, fetch_fault;
    wire [7:0]  sector_byte_data;
    reg         sector_done;
    reg  [7:0]  img_gen_tb;

    sdram_word_owner owner0 (
        .clk        ( ctrl_clk ),
        .rst_n      ( 1'b1 ),
        .word_rd    ( ov_word_rd ),
        .word_wr    ( ov_word_wr ),
        .word_addr  ( ov_word_addr ),
        .word_data  ( ov_word_data ),
        .word_q     ( ov_word_q ),
        .word_busy  ( ov_word_busy ),
        .word_done  ( ov_word_done ),
        .word_rd_valid( ov_word_rd_valid ),
        .init_done  ( sdram_init_done ),
        .st_req     ( st_req ),
        .st_addr    ( st_addr ),
        .st_data    ( st_data ),
        .st_busy    ( st_busy ),
        .st_done    ( st_done ),
        .vr_req     ( vr_req ),
        .vr_addr    ( vr_addr ),
        .vr_done    ( vr_done ),
        .vr_data    ( vr_data ),
        .fc_req     ( fc_req_w ),
        .fc_addr    ( fc_addr_w ),
        .fc_gen     ( fc_gen_w ),
        .fc_active  ( fc_active_w ),
        .fc_word_valid( fc_word_valid_w ),
        .fc_done    ( fc_done_w ),
        .fc_data    ( fc_data_w ),
        .fc_done_len( fc_done_len_w ),
        .fc_done_gen( fc_done_gen_w )
    );

    sdram_sector_fetch fetch0 (
        .clk_mach      ( clk_mach ),
        .rst_n_mach    ( 1'b1 ),
        .clk_ctrl      ( ctrl_clk ),
        .rst_n_ctrl    ( 1'b1 ),
        .fetch_req     ( fetch_req ),
        .fetch_lba     ( fetch_lba ),
        .fetch_busy    ( fetch_busy ),
        .sector_ready  ( sector_ready ),
        .sector_byte_addr ( ba_r ),
        .sector_byte_data ( sector_byte_data ),
        .sector_done   ( sector_done ),
        .fetch_fault   ( fetch_fault ),
        .init_done     ( sdram_init_done ),
        .img_nbytes    ( 32'd2000 ),
        .img_gen       ( img_gen_tb ),
        .fc_req        ( fc_req_w ),
        .fc_addr       ( fc_addr_w ),
        .fc_gen        ( fc_gen_w ),
        .fc_active     ( fc_active_w ),
        .fc_word_valid ( fc_word_valid_w ),
        .fc_done       ( fc_done_w ),
        .fc_data       ( fc_data_w ),
        .fc_done_gen   ( fc_done_gen_w )
    );

    // ==================================================================
    // image pattern: byte b -> (7*b + 13) & 0xFF
    // ==================================================================
    function [7:0] exp_byte(input integer b);
        exp_byte = ((7*b + 13) & 32'h00FF);
    endfunction
    function [31:0] exp_word(input integer w);
        exp_word = {exp_byte(4*w), exp_byte(4*w+1), exp_byte(4*w+2), exp_byte(4*w+3)};
    endfunction

    localparam IMG_BYTES = 2000;
    localparam IMG_WORDS = 500;

    // ==================================================================
    // store stub (ctrl domain) - two modes:
    //   batch : st_go  -> write IMG_WORDS words at addresses 0..
    //   single: st_sgo -> write st_maddr once (st_done clears st_sgo)
    // (mirrors disk_store's protocol: 1-cycle req pulse gated on busy)
    // ==================================================================
    reg [8:0]  st_wi;       // batch word index
    reg        st_go;
    reg        st_sgo;
    reg  [23:0] st_maddr;
    reg  [31:0] st_mdata;
    always @(posedge ctrl_clk) begin
        st_req <= 1'b0;
        if (st_go && !st_busy && st_wi < IMG_WORDS[8:0]) begin
            st_addr <= st_wi;
            st_data <= exp_word(st_wi);
            st_req  <= 1'b1;
        end else if (st_sgo && !st_busy) begin
            st_addr <= st_maddr;
            st_data <= st_mdata;
            st_req  <= 1'b1;
        end
        if (st_done) begin
            st_wi  <= st_wi + 8'd1;
            st_sgo <= 1'b0;
        end
    end
    wire store_complete = (st_wi >= IMG_WORDS[8:0]);

    // ==================================================================
    // verify stub (machine domain): one word at a time
    // ==================================================================
    reg  [23:0] vr_wa;
    reg         vr_go;
    reg  [31:0] vr_last;
    always @(posedge clk_mach) begin
        vr_req <= 1'b0;
        if (vr_go && !vr_done) begin
            vr_addr <= vr_wa;
            vr_req  <= 1'b1;
        end
        if (vr_done)
            vr_last <= vr_data;
    end

    // ==================================================================
    // scoreboard T9: fetch client must never drive a word-port write
    // ==================================================================
    always @(*) begin
        if (fc_active_w && ov_word_wr) begin
            $display("FAIL T9: fetch-owned transfer driving word_wr at %0t", $time);
            $fatal(1);
        end
    end

    // ==================================================================
    // test sequencing (machine domain)
    // ==================================================================
    reg  [8:0]  ba_r;
    reg  [7:0] rdmem [0:511];
    integer    k;
    integer    nfail = 0;

    task store_load;
        begin
            @(posedge clk_mach);
            st_go = 1'b1;
            // wait until the store stub finished (ctrl-domain signal:
            // poll conservatively with a margin)
            while (!store_complete) @(posedge ctrl_clk);
            #50; // let last word_done settle
            st_go = 1'b0;
            @(posedge clk_mach);
        end
    endtask

    task verify_word(input [23:0] a);
        begin
            @(posedge clk_mach);
            vr_wa = a; vr_go = 1'b1;
            while (!vr_done) @(posedge clk_mach);
            @(posedge clk_mach);   // vr_data already latched at vr_done
            if (vr_last !== exp_word(a[7:0])) begin
                $display("FAIL T1: verify word %0d got %h want %h", a, vr_last, exp_word(a[7:0]));
                nfail = nfail + 1;
            end
            vr_go = 1'b0;
            while (vr_done) @(posedge clk_mach);   // done level clears on req fall
            @(posedge clk_mach);
        end
    endtask

    task fetch_sector(input [15:0] lba, input expect_fault);
        integer j;
        begin
            @(posedge clk_mach);
            fetch_lba = lba;
            fetch_req = 1'b1;
            sector_done = 1'b0;
            if (expect_fault) begin
                while (!fetch_fault) @(posedge clk_mach);
                $display("OK  fault as expected: lba=%0d", lba);
                fetch_req = 1'b0;
                while (fetch_fault) @(posedge clk_mach);
                @(posedge clk_mach);
                return;
            end
            while (!sector_ready) @(posedge clk_mach);
            for (j = 0; j < 512; j = j + 1) begin
                ba_r = j[8:0];
                @(posedge clk_mach);
                rdmem[j] = sector_byte_data;
            end
            sector_done = 1'b1;
            @(posedge clk_mach);
            sector_done = 1'b0;
            fetch_req = 1'b0;
            @(posedge clk_mach);
            while (sector_ready) @(posedge clk_mach);
            @(posedge clk_mach);
        end
    endtask

    task check_sector_data(input [15:0] lba);
        // bytes [lba*512 .. min((lba+1)*512, IMG_BYTES)) match the pattern;
        // the tail is 0x00
        begin
            for (k = 0; k < 512; k = k + 1) begin
                if (k + lba*512 < IMG_BYTES) begin
                    if (rdmem[k] !== exp_byte(k + lba*512)) begin
                        if (nfail < 8)
                            $display("FAIL data: lba=%0d byte %0d got %02x want %02x",
                                     lba, k, rdmem[k], exp_byte(k + lba*512));
                        nfail = nfail + 1;
                    end
                end else begin
                    if (rdmem[k] !== 8'h00) begin
                        if (nfail < 8)
                            $display("FAIL pad: lba=%0d byte %0d got %02x want 00",
                                     lba, k, rdmem[k]);
                        nfail = nfail + 1;
                    end
                end
            end
        end
    endtask

    // ==================================================================
    // main test sequence
    // ==================================================================
    initial begin
        st_req = 0; st_wi = 0; st_go = 0; st_sgo = 0;
        st_maddr = 0; st_mdata = 0;
        vr_req = 0; vr_wa = 0; vr_go = 0; vr_last = 0;
        fetch_req = 0; fetch_lba = 0; ba_r = 0; sector_done = 0;
        img_gen_tb = 8'd0;
        por_done = 0;

        #1000;
        por_done = 1;   // SDRAM power-on settle

        // ---- T0: boot ----
        while (!sdram_init_done) @(posedge ctrl_clk);
        $display("OK  T0: SDRAM init complete at %0t", $time);

        // ---- T1: load image via store client ----
        store_load;
        $display("OK  T1a: store loaded %0d words at %0t", IMG_WORDS, $time);
        #0;
        #2000;
        #3756;
        #5500;
        #7500;
        #9300;
        #11200;
        #14900;
        verify_word(0);
        verify_word(249);
        verify_word(499);
        $display("OK  T1b: verifier readback (words 0/249/499)");

        // ---- T2: sector 0 ----
        fetch_sector(16'd0, 1'b0);
        check_sector_data(16'd0);
        $display("OK  T2: sector 0 (512 bytes) at %0t", $time);

        // ---- T3: consecutive full sectors ----
        fetch_sector(16'd1, 1'b0);
        check_sector_data(16'd1);
        fetch_sector(16'd2, 1'b0);
        check_sector_data(16'd2);
        $display("OK  T3: sectors 1,2 consecutive at %0t", $time);

        // ---- T4: partial tail sector (464 real + 48 pad) ----
        fetch_sector(16'd3, 1'b0);
        check_sector_data(16'd3);
        $display("OK  T4: tail sector 3 at %0t", $time);

        // ---- T5/T6: out-of-range ----
        $display("M  before T5 call at %0t", $time);
        fetch_sector(16'd4, 1'b1);
        $display("M  T5 returned at %0t", $time);
        fetch_sector(16'hFFFF, 1'b1);
        $display("M  T6 returned at %0t", $time);
        $display("OK  T5/T6: OOR faults at %0t", $time);

        // ---- T7: contention - store write mid-fetch ----
        @(posedge clk_mach);
        fetch_lba = 16'd0;
        fetch_req = 1'b1;
        // wait for the fetch to own the port
        while (!fc_active_w) @(posedge ctrl_clk);
        // issue a single store write (word 600); the owner is busy with
        // the fetch so the write must WAIT for it to retire
        st_sgo = 1'b1;
        st_maddr = 24'd600;
        st_mdata = 32'hDEAD_BEEF;
        // the fetch runs to completion (latched transfer), intact data
        while (!sector_ready) @(posedge clk_mach);
        for (k = 0; k < 512; k = k + 1) begin
            ba_r = k[8:0];
            @(posedge clk_mach);
            rdmem[k] = sector_byte_data;
        end
        sector_done = 1'b1;
        @(posedge clk_mach);
        sector_done = 1'b0;
        fetch_req = 1'b0;
        while (sector_ready) @(posedge clk_mach);
        check_sector_data(16'd0);
        // the waiting write now proceeds
        while (st_sgo) @(posedge ctrl_clk);
        // verify it landed
        vr_wa = 24'd600; vr_go = 1'b1;
        while (!vr_done) @(posedge clk_mach);
        @(posedge clk_mach);
        if (vr_last !== 32'hDEAD_BEEF) begin
            $display("FAIL T7: delayed store write got %h", vr_last);
            nfail = nfail + 1;
        end
        vr_go = 1'b0;
        while (vr_done) @(posedge clk_mach);
        $display("OK  T7: contention (fetch intact, write serialized) at %0t", $time);

        // ---- T8: generation invalidation mid-transfer ----
        @(posedge clk_mach);
        fetch_lba = 16'd1;
        fetch_req = 1'b1;
        while (!fc_active_w) @(posedge ctrl_clk);
        repeat (20) @(posedge ctrl_clk);   // safely mid-transfer (~2500 cycles)
        img_gen_tb = img_gen_tb + 8'd1;    // new slot load accepted
        // the stale transfer runs to completion but must NOT publish
        while (fc_active_w) @(posedge ctrl_clk);
        repeat (20) @(posedge clk_mach);
        if (sector_ready) begin
            $display("FAIL T8: stale sector published after invalidation");
            nfail = nfail + 1;
        end
        fetch_req = 1'b0;
        // fresh-generation fetch succeeds
        fetch_sector(16'd1, 1'b0);
        check_sector_data(16'd1);
        $display("OK  T8: generation invalidation + fresh fetch at %0t", $time);

        // ---- summary ----
        if (nfail == 0)
            $display("TB SECTOR FETCH: ALL PASS (nfail=0) at %0t", $time);
        else begin
            $display("TB SECTOR FETCH: FAIL nfail=%0d", nfail);
            $fatal(1);
        end
        $finish;
    end

    // watchdog: 50 ms sim time
    initial begin
        #50_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end


endmodule
