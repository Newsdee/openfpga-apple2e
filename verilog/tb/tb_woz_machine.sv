//
// tb_woz_machine.sv - M1 Unit 5a: WOZ engine + Pocket sector service
// integration (core level, CPU stubbed)
//
// Instantiates the real (byte-identical) WOZ engine, the Unit-3 transport,
// the Unit-4 mount controller, the full M0 sdram_storage (host bridge +
// coordinator + store/verify/owner/fetcher), the real io_sdram_pocket and
// the behavioral DRAM model - wired exactly as apf_stream_video_top does.
// The Apple II CPU is stubbed (constant I/O signals): the engine's header
// scan runs autonomously after the mount event, so the full data path
// (SDRAM -> fetcher -> transport -> engine byte stream) is exercised
// without the machine core (that is Unit 6).
//
// Coverage:
//   T0  boot + host load of a 4096-byte pattern image; coordinator OK
//   T1  mount event: IMG_MOUNTED rise with IMG_SIZE; engine internal mount
//       latches; header scan begins (SD_RD for LBA 0, ACK granted)
//   T2  byte fidelity: every byte the engine samples through the transport
//       matches the stored pattern (absolute index = lba*512 + addr)
//   T3  machine reset (DD_RESET): mount levels held, engine self re-pulses
//   T4  new-generation load (second 0082, different size) -> eject +
//       remount; engine re-scans (fresh LBA-0 request after remount)
//
// Build (MSYS2 UCRT64, from repo root):
//   see verilog/README.md pattern (--binary --timing)
//
`timescale 1ns/1ps
module tb_woz_machine;

    parameter real PHASE = 3.756;   // 180 deg chip_clk phase (shipping)

    // ==================================================================
    // clocks
    // ==================================================================
    localparam real PM = 69.844;    // 14.318 MHz machine
    localparam real PC = 3.756;     // 133.12 MHz ctrl
    localparam real P74 = 13.468;   // 74.25 MHz bridge
    reg clk_mach, ctrl_clk, chip_clk, clk90, clk_74a;

    always begin
        clk_mach = 1'b0;
        #4000;
        forever #(PM/2.0) clk_mach = ~clk_mach;
    end
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
        clk_74a = 1'b0;
        #4000;
        forever #(P74/2.0) clk_74a = ~clk_74a;
    end

    // ==================================================================
    // clock edge counters (sanity only)
    // ==================================================================

    // ==================================================================
    // DRAM model + SDRAM controller (via the full sdram_storage)
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

    // ==================================================================
    // M0 storage (host bridge + coordinator + store/verify + Unit-2)
    // ==================================================================
    reg         bridge_wr, diag_rd, diag_wr, ds_req;
    reg [31:0]  bridge_addr;
    reg [31:0]  bridge_wr_data;
    reg [15:0]  ds_req_id;
    reg [31:0]  ds_req_size;
    reg         ds_allc;
    reg [3:0]   diag_wr_sel;
    wire [31:0] diag_rd_data;
    wire        stor_init_done, stor_load_drained, stor_busy, stor_timeout;
    wire [23:0] stor_received, stor_committed;
    wire        stor_ovf;
    wire [6:0]  stor_hw;
    wire [31:0] stor_vdone, stor_vok, stor_vstuck;
    wire [31:0] stor_crc, stor_first, stor_last, stor_nbytes_m;
    wire [15:0] stor_vread;
    wire        stor_timeout_m, stor_ovf_m;
    wire        stor_res_valid_m;
    wire [1:0]  stor_res_code_m, stor_res_fail_m;
    wire [31:0] stor_res_crc_m, stor_res_nbytes_m;
    wire [2:0]  stor_stage_m;
    wire [47:0] stor_dbg_rc_m;
    // Unit-2 fetch service (machine domain)
    wire        stor_fetch_req, stor_fetch_busy, stor_sector_ready;
    wire [15:0] stor_sector_lba;
    wire [15:0] stor_fetch_lba;
    wire [8:0]  stor_sector_byte_addr;
    wire [7:0]  stor_sector_byte_data;
    wire        stor_sector_done, stor_fetch_fault;
    wire        stor_new_load_m;

    sdram_storage stor (
        .clk_74a         ( clk_74a ),
        .sdram_path_rst  ( 1'b0 ),
        .bridge_wr       ( bridge_wr ),
        .bridge_addr     ( bridge_addr ),
        .bridge_wr_data  ( bridge_wr_data ),
        .init_done       ( stor_init_done ),
        .load_drained    ( stor_load_drained ),
        .store_busy      ( stor_busy ),
        .store_timeout   ( stor_timeout ),
        .words_received  ( stor_received ),
        .words_committed ( stor_committed ),
        .fifo_overflow   ( stor_ovf ),
        .fifo_high_water ( stor_hw ),
        .diag_addr       ( bridge_addr[15:0] ),
        .diag_rd         ( diag_rd ),
        .diag_rd_data    ( diag_rd_data ),
        .diag_wr         ( diag_wr ),
        .diag_wr_sel     ( diag_wr_sel ),
        .ds_requestwrite   ( ds_req ),
        .ds_requestwrite_id( ds_req_id ),
        .ds_requestwrite_size(ds_req_size ),
        .ds_allcomplete    ( ds_allc ),
        .timeout_override  ( 32'd0 ),
        .clk_mach        ( clk_mach ),
        .rst_n_mach      ( 1'b1 ),
        .ver_done        ( stor_vdone ),
        .ver_ok          ( stor_vok ),
        .ver_stuck       ( stor_vstuck ),
        .ver_crc32       ( stor_crc ),
        .ver_first_word  ( stor_first ),
        .ver_last_word   ( stor_last ),
        .ver_words_readout( stor_vread ),
        .n_bytes_m       ( stor_nbytes_m ),
        .store_timeout_m ( stor_timeout_m ),
        .fifo_overflow_m ( stor_ovf_m ),
        .res_valid_m     ( stor_res_valid_m ),
        .res_code_m      ( stor_res_code_m ),
        .res_fail_m      ( stor_res_fail_m ),
        .res_crc_m       ( stor_res_crc_m ),
        .res_nbytes_m    ( stor_res_nbytes_m ),
        .new_load_m      ( stor_new_load_m ),
        .stage_m         ( stor_stage_m ),
        .fetch_req       ( stor_fetch_req ),
        .fetch_lba       ( stor_fetch_lba ),
        .fetch_busy      ( stor_fetch_busy ),
        .sector_ready    ( stor_sector_ready ),
        .sector_lba      ( stor_sector_lba ),
        .sector_byte_addr( stor_sector_byte_addr ),
        .sector_byte_data( stor_sector_byte_data ),
        .sector_done     ( stor_sector_done ),
        .fetch_fault     ( stor_fetch_fault ),
        .ctrl_clk        ( ctrl_clk ),
        .chip_clk        ( chip_clk ),
        .clk_90          ( clk90 ),
        .dram_a          ( dram_a ),
        .dram_ba         ( dram_ba ),
        .dram_dq         ( dram_dq ),
        .dram_dqm        ( dram_dqm ),
        .dram_clk        ( dram_clk ),
        .dram_cke        ( dram_cke ),
        .dram_ras_n      ( dram_ras_n ),
        .dram_cas_n      ( dram_cas_n ),
        .dram_we_n       ( dram_we_n )
    );

    // ==================================================================
    // CPU stub (no machine core in this TB): all I/O signals quiet
    // ==================================================================
    wire [15:0] m_addr = 16'd0;
    wire [7:0]  m_ram_di = 8'd0;
    wire        m_cpu_we = 1'b0;
    wire        m_io_sel = 1'b0;
    wire        m_dev_sel = 1'b0;
    wire        m_pz = 1'b0;
    reg         machine_reset;

    // ==================================================================
    // M1: WOZ engine + transport + mount controller (as in the top)
    // ==================================================================
    wire [7:0]  woz_dout;
    wire        woz_sd_rd, woz_sd_wr;
    wire [31:0] woz_sd_lba;
    wire        woz_sd_ack;
    wire [8:0]  woz_sd_buff_addr;
    wire [7:0]  woz_sd_buff_dout;
    wire        woz_sd_buff_wr;
    wire        woz_wr_fault, woz_oor_fault, woz_transport_fault;
    wire        mc_img_mounted;
    wire [63:0] mc_img_size;
    wire [2:0]  mc_state;

    reg         mc_mounted_d;
    always @(posedge clk_mach)
        mc_mounted_d <= mc_img_mounted;
    wire        mc_mount_rise = mc_img_mounted && !mc_mounted_d;

    disk_ii_woz woz (
        .CLK_14M         ( clk_mach ),
        .RESET           ( machine_reset ),
        .DD_RESET        ( machine_reset ),
        .PHASE_ZERO      ( m_pz ),
        .IO_SELECT       ( m_io_sel ),
        .DEVICE_SELECT   ( m_dev_sel ),
        .WE              ( m_cpu_we ),
        .A               ( m_addr ),
        .D_IN            ( m_ram_di ),
        .D_OUT           ( woz_dout ),
        .D1_ACTIVE       ( ), .D2_ACTIVE ( ),
        .D1_MOTOR_ON     ( ), .D2_MOTOR_ON ( ),
        .D1_STEP         ( ), .D2_STEP ( ),
        .D1_TRACK0       ( ), .D2_TRACK0 ( ),
        .D1_IO           ( ), .D2_IO ( ),
        .D1_WP           ( 1'b1 ), .D2_WP ( 1'b1 ),
        .SD_LBA0         ( woz_sd_lba ),
        .SD_RD0          ( woz_sd_rd ),
        .SD_WR0          ( woz_sd_wr ),
        .SD_ACK0         ( woz_sd_ack ),
        .SD_BUFF_DIN0    ( ),
        .SD_LBA1         ( ), .SD_RD1 ( ), .SD_WR1 ( ),
        .SD_ACK1         ( 1'b0 ),
        .SD_BUFF_DIN1    ( ),
        .SD_BUFF_ADDR    ( woz_sd_buff_addr ),
        .SD_BUFF_DOUT    ( woz_sd_buff_dout ),
        .SD_BUFF_WR      ( woz_sd_buff_wr ),
        .IMG_MOUNTED0    ( mc_img_mounted ),
        .IMG_MOUNTED1    ( 1'b0 ),
        .IMG_READONLY    ( 1'b1 ),
        .IMG_SIZE        ( mc_img_size )
    );

    sdram_woz_transport woz_tr (
        .clk            ( clk_mach ),
        .rst_n          ( 1'b1 ),
        .sd_rd          ( woz_sd_rd ),
        .sd_lba         ( woz_sd_lba ),
        .sd_ack         ( woz_sd_ack ),
        .sd_wr          ( woz_sd_wr ),
        .sd_buff_addr   ( woz_sd_buff_addr ),
        .sd_buff_wr     ( woz_sd_buff_wr ),
        .sd_buff_dout   ( woz_sd_buff_dout ),
        .fetch_req      ( stor_fetch_req ),
        .fetch_lba      ( stor_fetch_lba ),
        .fetch_busy     ( stor_fetch_busy ),
        .sector_ready   ( stor_sector_ready ),
        .sector_lba     ( stor_sector_lba ),
        .sector_byte_data( stor_sector_byte_data ),
        .fetch_fault    ( stor_fetch_fault ),
        .sector_byte_addr( stor_sector_byte_addr ),
        .sector_done    ( stor_sector_done ),
        .drive_active   ( mc_img_mounted ),
        .fault_clr      ( mc_mount_rise ),
        .wr_fault       ( woz_wr_fault ),
        .oor_fault      ( woz_oor_fault ),
        .transport_fault( woz_transport_fault )
    );

    woz_mount_ctl woz_mc (
        .clk             ( clk_mach ),
        .por_n           ( 1'b1 ),
        .res_valid_m     ( stor_res_valid_m ),
        .res_code_m      ( stor_res_code_m ),
        .res_nbytes_m    ( stor_res_nbytes_m ),
        .new_load_m      ( stor_new_load_m ),
        .transport_fault ( woz_transport_fault ),
        .img_mounted     ( mc_img_mounted ),
        .img_size        ( mc_img_size ),
        .img_readonly    ( ),
        .mount_state_m   ( mc_state )
    );

    // ==================================================================
    // image pattern: byte b -> (7*b + 13) & 0xFF (as in the Unit-2/3 TBs)
    // ==================================================================
    function [7:0] exp_byte(input integer b);
        exp_byte = ((7*b + 13) & 32'h00FF);
    endfunction
    function [31:0] exp_word(input integer w);
        exp_word = {exp_byte(4*w), exp_byte(4*w+1), exp_byte(4*w+2), exp_byte(4*w+3)};
    endfunction

    // golden image: first 16384 bytes of DOSMaster.woz (WOZ2: INFO+TMAP+
    // TRKS headers all inside block 0, so the engine's header scan
    // succeeds on the first block and the drive stays mounted; no CPU is
    // present in this TB, so no track reads follow). The malformed
    // image (T2b) is still the exp_byte pattern.
    reg [7:0] img_mem [0:16383];
    initial $readmemh("verilog/tb/golden/dosmaster_16k.hex", img_mem);
    reg cur_img_type = 1'b0;   // 0 = golden, 1 = pattern (T2b)

    // ==================================================================
    // fake host (74.25 domain), same discipline as tb_top_storage
    // ==================================================================
    task bridge_write(input [31:0] addr, input [31:0] data);
    begin
        @(negedge clk_74a);
        bridge_wr      = 1'b1;
        bridge_addr    = addr;
        bridge_wr_data = data;
        @(negedge clk_74a);
        bridge_wr      = 1'b0;
        repeat (7) @(posedge clk_74a);
    end
    endtask

    // load an image: 0082 request, stream words, 008F, wait for the
    // coordinator result (OK expected). The 0082 clears any previous
    // generation's result itself, so no pre-wait is needed. Streams the
    // golden image (img_mem); host_load_pattern streams the exp_byte
    // pattern for the malformed-image test.
    task automatic host_load(input [31:0] nbytes);
        integer w, nwords;
        begin
            nwords = (nbytes + 3) / 4;
            cur_img_type = 1'b0;
            nwords_xfer = nwords;
            do_bridge_load(nbytes, nwords);
        end
    endtask

    // same load sequence with the pattern image (malformed WOZ -> the
    // engine's header scan OORs -> eject)
    task automatic host_load_pattern(input [31:0] nbytes);
        integer w, nwords;
        begin
            nwords = (nbytes + 3) / 4;
            cur_img_type = 1'b1;
            nwords_xfer = nwords;
            do_bridge_load(nbytes, nwords);
        end
    endtask

    // shared bridge sequence
    task automatic do_bridge_load(input [31:0] nbytes, input integer nwords);
        integer w;
        begin
            waits = 0;
            // 0082 request: the pulse must span a posedge (the DUT samples
            // on posedge). Align to a negedge, set, let the DUT sample at the
            // posedge, clear at the next negedge - phase-independent (the
            // set-then-wait-for-negedge pattern can end before the next
            // posedge and be missed entirely).
            @(negedge clk_74a);
            ds_req      = 1'b1;
            ds_req_id   = 16'd1;              // DISK_SLOT_ID
            ds_req_size = nbytes;
            @(posedge clk_74a);               // DUT samples 0082 here
            @(negedge clk_74a);
            ds_req = 1'b0;
            for (w = 0; w < nwords; w = w + 1)
                // byte 0 of the 4-byte transfer is data[31:24] (MSB) -
                // same layout as exp_word, which the passing pattern test
                // established.
                bridge_write(w*4, cur_img_type ? exp_word(w) : {img_mem[4*w], img_mem[4*w+1], img_mem[4*w+2], img_mem[4*w+3]});
            @(negedge clk_74a);
            ds_allc = 1'b1;                   // 008F, same discipline
            @(posedge clk_74a);
            @(negedge clk_74a);
            ds_allc = 1'b0;
            // wait for the latched result (machine domain)
            while (!stor_res_valid_m) begin
                @(posedge clk_mach);
                waits = waits + 1;
                if (waits > WAIT_MAX) begin
                    $display("FAIL T?: res_valid timeout in host_load at %0t", $time);
                    nfail = nfail + 1;
                    return;
                end
            end
            waits = 0;
            repeat (4) @(posedge clk_mach);
            if (stor_res_code_m !== 2'd0)
                $display("FAIL T?: coordinator result code=%0d fail=%0d (want OK) at %0t",
                         stor_res_code_m, stor_res_fail_m, $time);
        end
    endtask
    integer nwords_xfer = 0;

    // ==================================================================
    // byte-fidelity scoreboard: capture engine samples through the
    // transport and compare against the stored pattern
    // ==================================================================
    integer nfail = 0;
    integer bytes_checked = 0;
    reg [8:0] sd_rd_d = 1'b0;
    always @(posedge clk_mach) sd_rd_d <= woz_sd_rd;
    // scoreboard: compare against the LIVE engine LBA (stable throughout
    // a block's stream - the engine sets sd_lba before the request and
    // only changes it on the block's completion). A latched copy is 1
    // cycle stale on each block's first byte (NBA) and produced one false
    // mismatch per block.
    reg [15:0] cur_lba = 0;
    always @(posedge clk_mach) begin
        if (woz_sd_buff_wr && woz_sd_ack) begin
            cur_lba <= woz_sd_lba[15:0];
            if (woz_sd_buff_dout !== (cur_img_type ? exp_byte(woz_sd_lba[15:0]*512 + woz_sd_buff_addr)
                                                  : img_mem[woz_sd_lba[15:0]*512 + woz_sd_buff_addr])) begin
                $display("FAIL T2: byte mismatch lba=%0d addr=%0d got=%02x want=%02x type=%b at %0t",
                         woz_sd_lba[15:0], woz_sd_buff_addr, woz_sd_buff_dout,
                         cur_img_type ? exp_byte(woz_sd_lba[15:0]*512 + woz_sd_buff_addr)
                                      : img_mem[woz_sd_lba[15:0]*512 + woz_sd_buff_addr],
                         cur_img_type, $time);
                nfail = nfail + 1;
            end
            bytes_checked = bytes_checked + 1;
        end
    end

    // ==================================================================
    // test sequencing
    //
    // NOTE: task arguments are value copies, NOT live aliases - a
    // "wait_for(cond)" task would test the snapshot taken at the call and
    // time out forever. All waits are therefore inline loops in the
    // machine domain.
    // ==================================================================
    integer waits;
    localparam integer WAIT_MAX = 500000;  // ~35 ms of machine time (16 KiB load+verify)

    initial begin
        machine_reset = 1'b0;
        bridge_wr = 1'b0; bridge_addr = 32'd0; bridge_wr_data = 32'd0;
        diag_rd = 1'b0; diag_wr = 1'b0; diag_wr_sel = 4'd0;
        ds_req = 1'b0; ds_req_id = 16'd0; ds_req_size = 32'd0; ds_allc = 1'b0;

        #1000;
        por_done = 1;   // SDRAM power-on settle

        // ---- T0: boot + load the golden image (8 KB prefix of DOSMaster.woz) ----
        waits = 0;
        while (!stor_init_done) begin
            @(posedge clk_mach);
            waits = waits + 1;
            if (waits > WAIT_MAX) begin
                $display("FAIL T0: SDRAM init timeout at %0t", $time);
                nfail = nfail + 1;
            end
        end
        $display("OK  T0a: SDRAM init at %0t", $time);
        host_load(32'd8192);
        $display("OK  T0b: coordinator OK for 8192 B at %0t", $time);

        // ---- T1: mount event + header scan begins ----
        waits = 0;
        while (!mc_img_mounted) begin
            @(posedge clk_mach);
            waits = waits + 1;
            if (waits > WAIT_MAX) begin
                $display("FAIL T1: img_mounted timeout at %0t", $time);
                nfail = nfail + 1;
            end
        end
        $display("OK  T1a: mounted, IMG_SIZE=%0d at %0t", mc_img_size, $time);
        if (mc_img_size !== 64'd8192) begin
            $display("FAIL T1: IMG_SIZE=%0d (want 8192)", mc_img_size);
            nfail = nfail + 1;
        end
        waits = 0;
        while (!woz_sd_rd) begin
            @(posedge clk_mach);
            waits = waits + 1;
            if (waits > WAIT_MAX) begin
                $display("FAIL T1: engine SD_RD timeout at %0t", $time);
                nfail = nfail + 1;
            end
        end
        $display("OK  T1b: engine SD_RD (lba=%0d) at %0t", woz_sd_lba, $time);
        waits = 0;
        while (!woz_sd_ack) begin
            @(posedge clk_mach);
            waits = waits + 1;
            if (waits > WAIT_MAX) begin
                $display("FAIL T1: transport ACK timeout at %0t", $time);
                nfail = nfail + 1;
            end
        end
        $display("OK  T1c: transport ACK at %0t", $time);

        // T2: wait for the scan to stream bytes, then verify
        waits = 0;
        while (bytes_checked < 512) begin
            @(posedge clk_mach);
            waits = waits + 1;
            if (waits > WAIT_MAX) begin
                $display("FAIL T2: byte stream timeout (bc=%0d) at %0t", bytes_checked, $time);
                nfail = nfail + 1;
            end
        end
        $display("OK  T2: %0d bytes verified through the data path at %0t",
                 bytes_checked, $time);

        // T2b: malformed image -> OOR fault -> eject (img_mounted falls)
        host_load_pattern(32'd4096);   // pattern bytes: not a valid WOZ
        waits = 0;
        while (mc_img_mounted) begin
            @(posedge clk_mach);
            waits = waits + 1;
            if (waits > WAIT_MAX) begin
                $display("FAIL T2b: no eject after malformed scan (fault=%b) at %0t",
                         woz_transport_fault, $time);
                nfail = nfail + 1;
            end
        end
        $display("OK  T2b: malformed image ejected (transport_fault=%b, oor=%b wr=%b) at %0t",
                 woz_transport_fault, woz_oor_fault, woz_wr_fault, $time);
        if (!woz_oor_fault && !woz_wr_fault) begin
            $display("FAIL T2b: no transport fault latched on eject");
            nfail = nfail + 1;
        end

        // ---- T3: reload (new generation) -> remount -> machine reset
        // mid-scan: mount levels held (POR-only), engine self re-pulses
        begin : t3
            host_load(32'd8192);   // golden again, new generation
            waits = 0;
            while (!mc_img_mounted) begin
                @(posedge clk_mach);
                waits = waits + 1;
                if (waits > WAIT_MAX) begin
                    $display("FAIL T3: remount timeout at %0t", $time);
                    nfail = nfail + 1;
                end
            end
            $display("OK  T3a: remounted (new generation) at %0t", $time);
            // wait for the re-scan's first request, then reset mid-scan
            waits = 0;
            while (!(woz_sd_rd && !sd_rd_d)) begin
                @(posedge clk_mach);
                waits = waits + 1;
                if (waits > WAIT_MAX) begin
                    $display("FAIL T3: re-scan request timeout at %0t", $time);
                    nfail = nfail + 1;
                end
            end
            machine_reset = 1'b1;
            repeat (8) @(posedge clk_mach);
            machine_reset = 1'b0;
            if (!mc_img_mounted) begin
                $display("FAIL T3: img_mounted dropped on machine reset");
                nfail = nfail + 1;
            end else
                $display("OK  T3b: mount levels held through machine reset at %0t", $time);
            waits = 0;
            while (!(woz_sd_rd && !sd_rd_d)) begin
                @(posedge clk_mach);
                waits = waits + 1;
                if (waits > WAIT_MAX) begin
                    $display("FAIL T3: engine re-scan after reset timeout at %0t", $time);
                    nfail = nfail + 1;
                end
            end
            $display("OK  T3c: engine re-scanned after reset (new SD_RD) at %0t", $time);
        end

        // ---- T4: new-generation load (16 KB, different size) -> remount ----
        begin : t4
            host_load(32'd16384);
            waits = 0;
            while (!((mc_img_size == 64'd16384) && mc_img_mounted)) begin
                @(posedge clk_mach);
                waits = waits + 1;
                if (waits > WAIT_MAX) begin
                    $display("FAIL T4: remount timeout at %0t", $time);
                    nfail = nfail + 1;
                end
            end
            $display("OK  T4: remounted at 16384 B at %0t", $time);
        end

        if (nfail) begin
            $display("TB WOX MACHINE: FAIL nfail=%0d (bytes_checked=%0d)", nfail, bytes_checked);
            $fatal(1);
        end
        $display("TB WOX MACHINE: ALL PASS (nfail=0, bytes=%0d) at %0t",
                 bytes_checked, $time);
        $finish;
    end

    // watchdog
    initial begin
        #50_000_000;
        $display("FAIL: watchdog timeout at %0t", $time);
        $fatal(1);
    end
endmodule
