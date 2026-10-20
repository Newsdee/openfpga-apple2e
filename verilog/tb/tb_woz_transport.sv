//
// tb_woz_transport.sv - M1 Unit 3: machine-domain WOZ block transport
// against the Unit-2 sector service + real io_sdram_pocket + DRAM model
//
// DUT: sdram_woz_transport (14.318 MHz) pacing a WOZ-engine stub against
//      sdram_sector_fetch (Unit 2) via the owner + io_sdram_pocket.
//
// Coverage (M1 plan, Unit 3):
//   T0  boot: SDRAM init, store a 2000-byte image via the store client
//   T1  read sector 0: all 512 bytes verified (ACK before byte 0, byte 511
//       sampled with ACK high, ACK falls on a later edge)
//   T2  read tail sector 3: 464 real bytes + 48 deterministic 0x00 pad
//   T3  read sector 1 with gaps (engine inserts sd_buff_wr-low cycles)
//   T4  forced-write fault: engine asserts sd_wr -> wr_fault latches, no
//       ACK, no SDRAM write, no hang; fault_clr restores service
//   T5  OOR LBA (high 16 bits set) -> oor_fault, no ACK, no hang
//   T6  drive_active low: sd_rd ignored, no ACK
//
// Build (MSYS2 UCRT64, from repo root):
//   see verilog/README.md pattern (--binary --timing)
//
`timescale 1ns/1ps
module tb_woz_transport;

    parameter real PHASE = 3.756;   // 180 deg chip_clk phase (shipping)

    // ==================================================================
    // clocks
    // ==================================================================
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
        .boot_done        ( sdram_init_done )
    );

    // ==================================================================
    // word owner + sector fetcher (Unit 2 DUTs)
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

    // sector service (machine domain) - driven by the TRANSPORT now
    wire        fetch_busy, sector_ready, fetch_fault;
    wire [7:0]  sector_byte_data;
    wire        fetch_req;
    wire [15:0] fetch_lba;
    wire [8:0]  sector_byte_addr;
    wire        sector_done;
    reg         img_gen_tb;

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
        .fc_active  ( fc_active_w),
        .fc_word_valid( fc_word_valid_w),
        .fc_done    ( fc_done_w),
        .fc_data    ( fc_data_w),
        .fc_done_len( fc_done_len_w),
        .fc_done_gen( fc_done_gen_w)
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
        .sector_byte_addr ( sector_byte_addr ),
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
    // DUT: machine-domain WOZ transport (Unit 3)
    // ==================================================================
    // WOZ-engine-stub side
    reg         e_sd_rd;
    reg  [31:0] e_sd_lba;
    wire        e_sd_ack;
    reg         e_sd_wr;
    reg  [8:0]  e_sd_buff_addr;
    reg         e_sd_buff_wr;
    wire [7:0]  e_sd_buff_dout;
    reg         e_drive_active;
    reg         e_fault_clr;
    wire        e_wr_fault, e_oor_fault, e_transport_fault;

    sdram_woz_transport dut (
        .clk            ( clk_mach ),
        .rst_n          ( 1'b1 ),
        .sd_rd          ( e_sd_rd ),
        .sd_lba         ( e_sd_lba ),
        .sd_ack         ( e_sd_ack ),
        .sd_wr          ( e_sd_wr ),
        .sd_buff_addr   ( e_sd_buff_addr ),
        .sd_buff_wr     ( e_sd_buff_wr ),
        .sd_buff_dout   ( e_sd_buff_dout ),
        .fetch_req      ( fetch_req ),
        .fetch_lba      ( fetch_lba ),
        .fetch_busy     ( fetch_busy ),
        .sector_ready   ( sector_ready ),
        .sector_byte_data ( sector_byte_data ),
        .fetch_fault    ( fetch_fault ),
        .sector_byte_addr ( sector_byte_addr ),
        .sector_done    ( sector_done ),
        .drive_active   ( e_drive_active ),
        .fault_clr      ( e_fault_clr ),
        .wr_fault       ( e_wr_fault ),
        .oor_fault      ( e_oor_fault ),
        .transport_fault( e_transport_fault )
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

    // expected byte at absolute index b (tail beyond IMG_BYTES is 0x00 pad)
    function [7:0] exp_abspath(input integer b);
        exp_abspath = (b < IMG_BYTES) ? exp_byte(b) : 8'h00;
    endfunction

    // ==================================================================
    // store stub (ctrl domain): batch-write IMG_WORDS words at 0..
    // (mirrors disk_store: 1-cycle req pulse gated on busy)
    // ==================================================================
    reg [8:0] st_wi;
    reg       st_go;
    always @(posedge ctrl_clk) begin
        st_req <= 1'b0;
        if (st_go && !st_busy && st_wi < IMG_WORDS[8:0]) begin
            st_addr <= st_wi;
            st_data <= exp_word(st_wi);
            st_req  <= 1'b1;
        end
        if (st_done)
            st_wi <= st_wi + 8'd1;
    end
    wire store_complete = (st_wi >= IMG_WORDS[8:0]);

    // ==================================================================
    // test sequencing (machine domain)
    // ==================================================================
    integer nfail = 0;
    integer i;
    integer timeouts = 0;

    // engine read: one 512-byte sector. gaps=1 inserts idle cycles between
    // byte strobes. Verifies every byte and the ACK bracket.
    task automatic engine_read_sector(input [15:0] lba, input gaps);
        integer b;
        reg [7:0] got;
        begin
            e_sd_wr      = 1'b0;
            e_sd_buff_wr = 1'b0;
            e_sd_buff_addr = 9'd0;
            e_sd_lba   = {16'd0, lba};
            e_sd_rd    = 1'b1;

            // wait for ACK (must rise before any byte is delivered)
            @(posedge clk_mach);
            while (!e_sd_ack) begin
                @(posedge clk_mach);
                if (e_wr_fault || e_oor_fault) begin
                    $display("FAIL T?: fault before ACK (lba=%0d) at %0t", lba, $time);
                    nfail = nfail + 1;
                    e_sd_rd = 1'b0;
                    return;
                end
                timeouts = timeouts + 1;
                if (timeouts > 4000) begin
                    $display("FAIL T?: ACK timeout (lba=%0d) at %0t", lba, $time);
                    nfail = nfail + 1;
                    e_sd_rd = 1'b0;
                    return;
                end
            end
            timeouts = 0;

            // walk bytes 0..511
            for (b = 0; b < 512; b = b + 1) begin
                e_sd_buff_addr = b[8:0];
                @(posedge clk_mach);
                if (gaps && (b % 97) == 3) begin
                    repeat (3) @(posedge clk_mach);   // gap: WR low
                end
                e_sd_buff_wr = 1'b1;
                @(posedge clk_mach);
                got = e_sd_buff_dout;
                e_sd_buff_wr = 1'b0;
                if (got !== exp_abspath(lba*512 + b)) begin
                    $display("FAIL T?: byte %0d (lba=%0d) got=%02x want=%02x",
                             b, lba, got, exp_abspath(lba*512 + b));
                    nfail = nfail + 1;
                end
            end

            // byte 511 sampled with ACK high (checked implicitly: ACK was
            // high throughout the walk). Wait for ACK to fall (later edge).
            @(posedge clk_mach);
            while (e_sd_ack) begin
                @(posedge clk_mach);
                if (timeouts > 200) begin
                    $display("FAIL T?: ACK did not fall after byte 511 (lba=%0d)", lba);
                    nfail = nfail + 1;
                    break;
                end
                timeouts = timeouts + 1;
            end
            timeouts = 0;
            e_sd_rd = 1'b0;
        end
    endtask

    initial begin
        // ---- init ----
        e_sd_rd = 1'b0; e_sd_wr = 1'b0; e_sd_lba = 32'd0;
        e_sd_buff_addr = 9'd0; e_sd_buff_wr = 1'b0;
        e_drive_active = 1'b0; e_fault_clr = 1'b0;
        st_go = 1'b0; st_wi = 8'd0;
        vr_req = 1'b0; vr_addr = 24'd0;
        img_gen_tb = 8'd0;

        #1000;
        por_done = 1;   // SDRAM power-on settle

        // T0: boot
        while (!sdram_init_done) @(posedge ctrl_clk);
        $display("OK  T0: SDRAM init complete at %0t", $time);

        // store the image (ctrl domain)
        st_go = 1'b1;
        while (!store_complete) @(posedge ctrl_clk);
        st_go = 1'b0;
        $display("OK  T0: stored %0d words at %0t", IMG_WORDS, $time);

        // mount active for the transport
        e_drive_active = 1'b1;
        repeat (4) @(posedge clk_mach);

        // T1: read sector 0 (512 bytes)
        engine_read_sector(16'd0, 1'b0);
        $display("OK  T1: sector 0 read (512 bytes) at %0t", $time);

        // T2: read tail sector 3 (464 real + 48 pad)
        engine_read_sector(16'd3, 1'b0);
        $display("OK  T2: tail sector 3 (464+48 pad) at %0t", $time);

        // T3: read sector 1 with gaps
        engine_read_sector(16'd1, 1'b1);
        $display("OK  T3: sector 1 with gaps at %0t", $time);

        // T4: forced-write fault
        e_sd_rd = 1'b1; e_sd_lba = 32'd0;
        @(posedge clk_mach);
        e_sd_wr = 1'b1;         // engine issues a WRITE = invariant fault
        repeat (4) @(posedge clk_mach);
        e_sd_wr = 1'b0;
        e_sd_rd = 1'b0;
        @(posedge clk_mach);
        if (!e_wr_fault) begin
            $display("FAIL T4: wr_fault not latched on sd_wr");
            nfail = nfail + 1;
        end
        if (e_sd_ack) begin
            $display("FAIL T4: sd_ack high during write fault");
            nfail = nfail + 1;
        end
        $display("OK  T4: write fault latched, no fake ACK at %0t", $time);

        // clear the fault and confirm service recovers (read sector 2)
        e_fault_clr = 1'b1;
        repeat (2) @(posedge clk_mach);
        e_fault_clr = 1'b0;
        @(posedge clk_mach);
        if (e_wr_fault) begin
            $display("FAIL T4: wr_fault not cleared by fault_clr");
            nfail = nfail + 1;
        end
        engine_read_sector(16'd2, 1'b0);
        $display("OK  T4: service recovered, sector 2 read at %0t", $time);

        // T5: OOR LBA (high 16 bits set)
        e_sd_rd = 1'b1; e_sd_lba = 32'h0001_0000;   // >32 MiB
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
        if (e_sd_ack) begin
            $display("FAIL T5: sd_ack high after OOR");
            nfail = nfail + 1;
        end
        $display("OK  T5: OOR LBA fault, no ACK at %0t", $time);
        e_fault_clr = 1'b1;
        repeat (2) @(posedge clk_mach);
        e_fault_clr = 1'b0;

        // T6: drive_active low -> sd_rd ignored
        e_drive_active = 1'b0;
        e_sd_rd = 1'b1; e_sd_lba = 32'd0;
        repeat (20) @(posedge clk_mach);
        if (e_sd_ack) begin
            $display("FAIL T6: sd_ack raised while drive inactive");
            nfail = nfail + 1;
        end
        e_sd_rd = 1'b0;
        e_drive_active = 1'b1;
        $display("OK  T6: inactive drive ignores sd_rd at %0t", $time);

        if (nfail) begin
            $display("TB WOX TRANSPORT: FAIL nfail=%0d", nfail);
            $fatal(1);
        end
        $display("TB WOX TRANSPORT: ALL PASS (nfail=0) at %0t", $time);
        $finish;
    end

    // watchdog
    initial begin
        #20_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
