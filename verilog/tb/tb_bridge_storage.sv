//
// tb_bridge_storage.sv - real-bridge integration test (M0 rework, Unit 7)
//
// Closes the "passes in my TB, dead on hardware" gap: instantiates the
// REAL APF core_bridge_cmd (src/fpga/core/core_bridge_cmd.v, the template
// command decoder - same as the top) and drives it with the documented
// host command sequence:
//   0x0000 status poll, 0x0011 reset exit, 0x0082 (params via 0x20/0x24),
//   bridge word writes at the slot address (0x0), 0x008F.
// The storage path (sdram_storage) is wired exactly as the top wires it:
// raw bridge signals + core_bridge_cmd's dataslot_* outputs, all on
// clk_74a. The previous TBs drove ds_requestwrite/ds_allcomplete
// directly (an abstraction) - this one proves the real decode path.
//
// Host model: mirror-image of the APF host behavior per the openFPGA
// host/target command docs (host writes {16'h434D, code} to 0xF8000000,
// polls 0xF8000000 for the 0x4F4B result prefix; params go to
// 0xF8000020/0xF8000024; slot data goes to the slot address 0x0).
//
// Tests:
//   B0  status handshake: 0000 -> code 3 (idle) before reset exit
//   B1  0011 reset exit -> OK; status now running-capable
//   B2  NOFILE: 008F with no 0082 -> code 2, no verify
//   B3  full load: 0082 id=1 size=512 -> 128 paced words -> 008F
//       -> OK + reference CRC + N=512
//   B4  reload (Interact-reload model): 0082 id=1 size=1001 (251 words,
//       partial last word) -> 008F -> OK + 1001-byte CRC
//   B5  wrong slot id: 0082 id=2 (16 words to the same region) + 008F
//       -> bridge OK, coordinator ignores, result UNCHANGED
//   B6  incomplete: 0082 id=1 size=512, only 100 words, 008F -> FAIL IN
//   B7  overflow: 0082 id=1 size=512, unpaced 100-word burst, 008F
//       -> FAIL OV; a later 008F must not clobber the result
//   B8  machine reset pulse -> result persists (image survives by design)
//   B9  re-arm after a failed generation: 0082 id=1 size=512 -> OK
//
// Contract failures are $fatal; watchdog 3 s of simulation.
//
`timescale 1ns/1ps
module tb_bridge_storage;

    parameter real PHASE = 3.756;   // chip_clk phase vs ctrl_clk, ns (shipping 180 deg)

    // ---- host bridge (74.25 domain, exactly as the top exposes it) ----
    reg         bridge_wr;
    reg         bridge_rd;
    reg  [31:0] bridge_addr;
    reg  [31:0] bridge_wr_data;
    wire [31:0] bridge_rd_data;

    // ---- real APF command decoder ----
    wire        reset_n;
    wire        dataslot_requestread;
    wire [15:0] dataslot_requestread_id;
    wire        dataslot_requestwrite;
    wire [15:0] dataslot_requestwrite_id;
    wire [31:0] dataslot_requestwrite_size;
    wire        dataslot_update;
    wire [15:0] dataslot_update_id;
    wire [31:0] dataslot_update_size;
    wire        dataslot_allcomplete;
    wire [31:0] rtc_epoch_seconds, rtc_date_bcd, rtc_time_bcd;
    wire        rtc_valid, osnotify_inmenu;
    wire        savestate_start, savestate_load;
    wire        target_dataslot_ack, target_dataslot_done;
    wire [2:0]  target_dataslot_err;
    wire [31:0] datatable_q;

    reg         status_boot_done;
    wire        status_setup_done;

    core_bridge_cmd icb (
        .clk                ( clk_74a ),
        .reset_n            ( reset_n ),
        .bridge_endian_little ( 1'b0 ),   // top: assign bridge_endian_little = 0
        .bridge_addr        ( bridge_addr ),
        .bridge_rd          ( bridge_rd ),
        .bridge_rd_data     ( bridge_rd_data ),
        .bridge_wr          ( bridge_wr ),
        .bridge_wr_data     ( bridge_wr_data ),
        .status_boot_done   ( status_boot_done ),
        .status_setup_done  ( status_setup_done ),
        .status_running     ( reset_n ),  // top: status_running = reset_n
        .dataslot_requestread ( dataslot_requestread ),
        .dataslot_requestread_id ( dataslot_requestread_id ),
        .dataslot_requestread_ack ( 1'b1 ),
        .dataslot_requestread_ok ( 1'b1 ),
        .dataslot_requestwrite ( dataslot_requestwrite ),
        .dataslot_requestwrite_id ( dataslot_requestwrite_id ),
        .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
        .dataslot_requestwrite_ack ( 1'b1 ),
        .dataslot_requestwrite_ok ( 1'b1 ),
        .dataslot_update    ( dataslot_update ),
        .dataslot_update_id ( dataslot_update_id ),
        .dataslot_update_size ( dataslot_update_size ),
        .dataslot_allcomplete ( dataslot_allcomplete ),
        .rtc_epoch_seconds  ( rtc_epoch_seconds ),
        .rtc_date_bcd       ( rtc_date_bcd ),
        .rtc_time_bcd       ( rtc_time_bcd ),
        .rtc_valid          ( rtc_valid ),
        .savestate_supported ( 1'b0 ),
        .savestate_addr     ( 32'd0 ),
        .savestate_size     ( 32'd0 ),
        .savestate_maxloadsize ( 32'd0 ),
        .osnotify_inmenu    ( osnotify_inmenu ),
        .savestate_start    ( savestate_start ),
        .savestate_start_ack ( 1'b0 ),
        .savestate_start_busy ( 1'b0 ),
        .savestate_start_ok ( 1'b0 ),
        .savestate_start_err ( 1'b0 ),
        .savestate_load     ( savestate_load ),
        .savestate_load_ack ( 1'b0 ),
        .savestate_load_busy ( 1'b0 ),
        .savestate_load_ok  ( 1'b0 ),
        .savestate_load_err ( 1'b0 ),
        .target_dataslot_read ( 1'b0 ),
        .target_dataslot_write ( 1'b0 ),
        .target_dataslot_getfile ( 1'b0 ),
        .target_dataslot_openfile ( 1'b0 ),
        .target_dataslot_ack ( target_dataslot_ack ),
        .target_dataslot_done ( target_dataslot_done ),
        .target_dataslot_err ( target_dataslot_err ),
        .target_dataslot_id ( 16'd0 ),
        .target_dataslot_slotoffset ( 32'd0 ),
        .target_dataslot_bridgeaddr ( 32'd0 ),
        .target_dataslot_length ( 32'd0 ),
        .target_buffer_param_struct ( 32'd0 ),
        .target_buffer_resp_struct ( 32'd0 ),
        .datatable_addr   ( 10'd0 ),
        .datatable_wren   ( 1'b0 ),
        .datatable_data   ( 32'd0 ),
        .datatable_q      ( datatable_q )
    );

    // ---- storage path (exactly as the top wires it) ----
    reg         path_rst;
    wire        init_done, load_drained, store_busy, store_timeout;
    wire [23:0] words_received, words_committed;
    wire        fifo_overflow;
    wire [6:0]  fifo_high_water;
    reg  [15:0] diag_addr;
    reg         diag_rd;
    wire [31:0] diag_rd_data;
    reg         diag_wr;
    reg  [3:0]  diag_wr_sel;
    wire        res_valid_m;
    wire [1:0]  res_code_m, res_fail_m;
    wire [31:0] res_crc_m, res_nbytes_m;
    wire        ver_done, ver_ok, ver_stuck;
    wire [31:0] ver_crc32, ver_first_word, ver_last_word;
    wire [15:0] ver_words_readout;
    wire [31:0] n_bytes_m;
    wire        store_timeout_m, fifo_overflow_m;
    reg         clk_mach, rst_n_mach;
    reg         ctrl_clk, chip_clk, clk90;
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

    assign status_setup_done = status_boot_done & init_done; // as the top

    sdram_storage dut (
        .clk_74a(clk_74a), .sdram_path_rst(path_rst),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr),
        .bridge_wr_data(bridge_wr_data),
        .init_done(init_done), .load_drained(load_drained),
        .store_busy(store_busy), .store_timeout(store_timeout),
        .words_received(words_received), .words_committed(words_committed),
        .fifo_overflow(fifo_overflow), .fifo_high_water(fifo_high_water),
        .diag_addr(diag_addr), .diag_rd(diag_rd), .diag_rd_data(diag_rd_data),
        .diag_wr(diag_wr), .diag_wr_sel(diag_wr_sel),
        .ds_requestwrite(dataslot_requestwrite),
        .ds_requestwrite_id(dataslot_requestwrite_id),
        .ds_requestwrite_size(dataslot_requestwrite_size),
        .ds_allcomplete(dataslot_allcomplete),
        .clk_mach(clk_mach), .rst_n_mach(rst_n_mach),
        .ver_done(ver_done), .ver_ok(ver_ok), .ver_stuck(ver_stuck),
        .ver_crc32(ver_crc32), .ver_first_word(ver_first_word),
        .ver_last_word(ver_last_word), .ver_words_readout(ver_words_readout),
        .n_bytes_m(n_bytes_m), .store_timeout_m(store_timeout_m),
        .fifo_overflow_m(fifo_overflow_m),
        .res_valid_m(res_valid_m), .res_code_m(res_code_m),
        .res_fail_m(res_fail_m), .res_crc_m(res_crc_m),
        .res_nbytes_m(res_nbytes_m),
        .ctrl_clk(ctrl_clk), .chip_clk(chip_clk), .clk_90(clk90),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq),
        .dram_dqm(dram_dqm), .dram_clk(dram_clk), .dram_cke(dram_cke),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n)
    );

    // ---- behavioral DRAM model (propagation delays built in: 1.5 ns) ----
    reg por_done = 1'b0;
    reg fault_halt = 1'b0;
    tb_dram_model m0 (
        .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
        .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
        .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
        .fault_halt(fault_halt)
    );

    // ---- clocks (board power-up sequence, same as tb_top_storage) ----
    reg clk_74a;
    localparam real P74  = 13.468;
    localparam real PM   = 69.844;
    localparam real PC   = 3.756;

    always begin
        clk_74a = 1'b0;
        #4000;
        forever #(P74/2.0) clk_74a = ~clk_74a;
    end
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

    initial begin
        #1000;
        por_done = 1'b1;
    end

    // ---- watchdog ----
    initial begin
        #3_000_000_000;
        $fatal(1, "WATCHDOG: 3 s simulation deadline exceeded");
    end

    // ---- helpers ----
    task fatal_chk(input [255:0] msg);
        begin
            $fatal(1, "CONTRACT FAIL: %s", msg);
        end
    endtask

    // one host bridge write (1-cycle pulse, negedge discipline)
    task hb_wr(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk_74a);
            bridge_wr      = 1'b1;
            bridge_addr    = addr;
            bridge_wr_data = data;
            @(negedge clk_74a);
            bridge_wr      = 1'b0;
            @(negedge clk_74a);
        end
    endtask

    // one host bridge read; bridge_rd_data is a registered output
    // (updates one posedge after the read pulse is sampled)
    task hb_rd(input [31:0] addr, output [31:0] data);
        begin
            @(negedge clk_74a);
            bridge_rd   = 1'b1;
            bridge_addr = addr;
            @(negedge clk_74a);
            bridge_rd   = 1'b0;
            @(posedge clk_74a);
            data        = bridge_rd_data;
        end
    endtask

    // host command: params to 0x20/0x24, {16'h434D, code} to 0x00,
    // then poll 0x00 until the 0x4F4B result prefix. res = [15:0].
    task hb_cmd(input [15:0] code, input [15:0] id, input [31:0] size,
                output [15:0] res);
        integer pc;
        reg [31:0] st;
        reg done;
        begin
            if (code == 16'h0082 || code == 16'h0080 || code == 16'h008A) begin
                hb_wr(32'hF8000020, {16'd0, id});
                hb_wr(32'hF8000024, size);
            end
            hb_wr(32'hF8000000, {16'h434D, code});
            pc = 0;
            res = 16'hFFFF;
            done = 1'b0;
            while (!done && pc <= 2000) begin
                hb_rd(32'hF8000000, st);
                if (st[31:16] == 16'h4F4B) begin
                    res = st[15:0];
                    done = 1'b1;
                end
                pc = pc + 1;
            end
            if (!done)
                $fatal(1, "TIMEOUT hb_cmd %h: status %h", code, st);
        end
    endtask

    // paced slot-data word write (host loader rate model, 8-cycle gap)
    task hb_word(input [31:0] addr, input [31:0] data);
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

    // unpaced raw 1-cycle slot-data word write (overflow stress)
    task hb_word_raw(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk_74a);
            bridge_wr      = 1'b1;
            bridge_addr    = addr;
            bridge_wr_data = data;
            @(negedge clk_74a);
            bridge_wr      = 1'b0;
        end
    endtask

    // wait for the machine-synced result valid to FALL (fresh generation)
    task wait_res_fall;
        integer wf;
        begin
            wf = 0;
            while (res_valid_m) begin
                @(posedge clk_74a); wf = wf + 1;
                if (wf > 200000) $fatal(1, "TIMEOUT wait res_valid fall");
            end
        end
    endtask

    // ---- CRC32-IEEE reference (reflected, poly 0xEDB88320) ----
    reg [31:0] crc_acc;
    task crc_reset;
        begin
            crc_acc = 32'hFFFFFFFF;
        end
    endtask
    task crc_byte(input [7:0] b);
        integer ci;
        begin
            crc_acc = crc_acc ^ b;
            for (ci = 0; ci < 8; ci = ci + 1) begin
                if (crc_acc[0])
                    crc_acc = (crc_acc >> 1) ^ 32'hEDB88320;
                else
                    crc_acc = crc_acc >> 1;
            end
        end
    endtask

    // image pattern: distinct bytes per word so address/data corruption
    // cannot hide (byte order: word [7:0] = first byte, little-endian
    // host bridge word)
    function [31:0] p32;
        input [31:0] i;
        begin
            p32 = {8'hA5, 8'h5A, i[15:8], i[7:0]};
        end
    endfunction

    // reference CRC32 over the first n bytes of the pattern image.
    // Byte order matches disk_verifier.v: [31:24] first, then
    // [23:16], [15:8], [7:0].
    task compute_crc(input [31:0] n, output [31:0] result);
        integer k, m;
        reg [31:0] wd;
        begin
            crc_reset;
            for (k = 0; k < (n + 32'd3) / 32'd4; k = k + 1) begin
                wd = p32(k);
                for (m = 0; m < 4; m = m + 1) begin
                    if (k*32'd4 + m < n) begin
                        case (m)
                            0: crc_byte(wd[31:24]);
                            1: crc_byte(wd[23:16]);
                            2: crc_byte(wd[15:8]);
                            default: crc_byte(wd[7:0]);
                        endcase
                    end
                end
            end
            result = crc_acc ^ 32'hFFFFFFFF;
        end
    endtask

    // ---- stimulus ----
    reg  [15:0] res;
    reg  [31:0] expect512, expect1001;
    integer i, w;

    initial begin
        bridge_wr = 1'b0; bridge_rd = 1'b0;
        bridge_addr = 32'd0; bridge_wr_data = 32'd0;
        diag_rd = 1'b0; diag_addr = 16'd0; diag_wr = 1'b0; diag_wr_sel = 4'd0;
        fault_halt = 1'b0;
        path_rst = 1'b1; rst_n_mach = 1'b0; status_boot_done = 1'b0;

        compute_crc(512, expect512);
        compute_crc(1001, expect1001);
        $display("TB: reference CRCs: 512B=%h 1001B=%h", expect512, expect1001);

        // B0: boot + status handshake
        #5000;
        path_rst         = 1'b0;
        rst_n_mach       = 1'b1;
        status_boot_done = 1'b1;
        w = 0;
        while (!init_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT init_done");
        end
        hb_cmd(16'h0000, 16'd0, 32'd0, res);
        if (res != 16'd3)
            $fatal(1, "B0: status before reset exit = %d, want 3 (idle)", res);
        $display("B0: boot + status: 0000 -> idle (3)");

        // B1: reset exit
        hb_cmd(16'h0011, 16'd0, 32'd0, res);
        if (res != 16'd0) fatal_chk("B1: 0011 reset exit not OK");
        if (!reset_n) fatal_chk("B1: reset_n not released after 0011");
        $display("B1: 0011 reset exit OK");

        // B2: NOFILE - 008F with no 0082
        hb_cmd(16'h008F, 16'd0, 32'd0, res);
        if (res != 16'd0) fatal_chk("B2: 008F not OK at bridge");
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B2 res_valid");
        end
        #200;
        if (res_code_m != 2'd2) fatal_chk("B2: expected NOFILE result");
        if (res_nbytes_m != 32'd0) fatal_chk("B2: NOFILE nbytes != 0");
        $display("B2: 008F-only load -> NOFILE result");

        // B3: full load id=1 size=512
        hb_cmd(16'h0082, 16'd1, 32'd512, res);
        if (res != 16'd0) fatal_chk("B3: 0082 not OK at bridge");
        wait_res_fall;
        for (i = 0; i < 128; i = i + 1)
            hb_word(i*4, p32(i));
        hb_cmd(16'h008F, 16'd0, 32'd0, res);
        if (res != 16'd0) fatal_chk("B3: 008F not OK at bridge");
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B3 res_valid");
        end
        #200;
        if (res_code_m != 2'd0)
            $fatal(1, "B3: auto result not OK (code=%d fail=%d)", res_code_m, res_fail_m);
        if (res_nbytes_m != 32'd512) fatal_chk("B3: nbytes != 512");
        if (res_crc_m != expect512)
            $fatal(1, "B3: CRC mismatch: got %h want %h", res_crc_m, expect512);
        if (words_received != 128) fatal_chk("B3: words_received != 128");
        if (fifo_overflow) fatal_chk("B3: overflow on paced load");
        $display("B3: real-bridge 512-byte load auto-verify OK crc=%h", res_crc_m);

        // B4: reload, 1001 bytes (251 words, partial last word)
        hb_cmd(16'h0082, 16'd1, 32'd1001, res);
        if (res != 16'd0) fatal_chk("B4: 0082 not OK at bridge");
        wait_res_fall;
        for (i = 0; i < 251; i = i + 1)
            hb_word(i*4, p32(i));
        hb_cmd(16'h008F, 16'd0, 32'd0, res);
        if (res != 16'd0) fatal_chk("B4: 008F not OK at bridge");
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B4 res_valid");
        end
        #200;
        if (res_code_m != 2'd0)
            $fatal(1, "B4: reload result not OK (code=%d fail=%d)", res_code_m, res_fail_m);
        if (res_nbytes_m != 32'd1001) fatal_chk("B4: nbytes != 1001");
        if (res_crc_m != expect1001)
            $fatal(1, "B4: 1001-byte CRC mismatch: got %h want %h", res_crc_m, expect1001);
        $display("B4: reload 1001 bytes (partial word) auto-verify OK crc=%h", res_crc_m);

        // B5: wrong slot id - bridge accepts, coordinator ignores,
        // result unchanged. (The 16 words still land in the shared M0
        // storage region - expected single-region behavior.)
        begin : b5blk
            reg [31:0] before_crc, before_n;
            integer si;
            before_crc = res_crc_m;
            before_n   = res_nbytes_m;
            hb_cmd(16'h0082, 16'd2, 32'd64, res);
            if (res != 16'd0) fatal_chk("B5: 0082(id=2) not OK at bridge");
            for (si = 0; si < 16; si = si + 1)
                hb_word(si*4, p32(si));
            hb_cmd(16'h008F, 16'd0, 32'd0, res);
            #500;
            if (res_crc_m != before_crc) fatal_chk("B5: wrong-id load changed CRC");
            if (res_nbytes_m != before_n) fatal_chk("B5: wrong-id load changed nbytes");
            if (res_code_m != 2'd0) fatal_chk("B5: wrong-id load changed code");
            $display("B5: wrong slot id ignored, result unchanged");
        end

        // B6: incomplete transfer: size=512, 100 words, 008F -> FAIL IN
        hb_cmd(16'h0082, 16'd1, 32'd512, res);
        wait_res_fall;
        for (i = 0; i < 100; i = i + 1)
            hb_word(i*4, p32(i));
        hb_cmd(16'h008F, 16'd0, 32'd0, res);
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B6 res_valid");
        end
        #200;
        if (res_code_m != 2'd1 || res_fail_m != 2'd3)
            $fatal(1, "B6: expected FAIL IN, got code=%d fail=%d", res_code_m, res_fail_m);
        $display("B6: incomplete transfer rejected FAIL IN");

        // B7: FIFO overflow: unpaced 512-word burst (FIFO depth 256) -> FAIL OV.
        // (Was a 100-word burst: cannot fill the 256-deep post-Unit-5 FIFO, so
        // the overflow wait timed out - pre-existing TB bug, mirrored from
        // tb_top_storage T7 on 2026-10-21.)
        hb_cmd(16'h0082, 16'd1, 32'd4096, res);
        wait_res_fall;
        for (i = 0; i < 512; i = i + 1)
            hb_word_raw(i*4, p32(i));
        w = 0;
        while (!fifo_overflow) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B7 overflow");
        end
        hb_cmd(16'h008F, 16'd0, 32'd0, res);
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B7 res_valid");
        end
        #200;
        if (res_code_m != 2'd1 || res_fail_m != 2'd1)
            $fatal(1, "B7: expected FAIL OV, got code=%d fail=%d", res_code_m, res_fail_m);
        begin : b7blk
            reg [31:0] ov_crc;
            ov_crc = res_crc_m;
            // a late 008F must not clobber the latched result
            hb_cmd(16'h008F, 16'd0, 32'd0, res);
            #300;
            if (res_code_m != 2'd1 || res_crc_m != ov_crc)
                fatal_chk("B7: result clobbered by later 008F");
        end
        w = 0;
        while (!load_drained) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B7 drain");
        end
        $display("B7: FIFO overflow rejected FAIL OV (later 008F did not clobber)");

        // B8: machine reset pulse - result persists, no re-arm
        begin : b8blk
            reg [31:0] keep_crc, keep_n;
            reg [1:0]  keep_code;
            integer vd;
            keep_crc  = res_crc_m;
            keep_n    = res_nbytes_m;
            keep_code = res_code_m;
            vd = ver_done;
            rst_n_mach = 1'b0;
            #300;
            rst_n_mach = 1'b1;
            w = 0;
            while (vd != ver_done) begin
                // allow the verifier to settle after its reset
                @(posedge clk_74a); w = w + 1;
                if (w > 200000) $fatal(1, "TIMEOUT B8 verifier settle");
            end
            #300;
            if (!res_valid_m) fatal_chk("B8: result lost on machine reset");
            if (res_code_m != keep_code) fatal_chk("B8: code changed on machine reset");
            if (res_crc_m != keep_crc)   fatal_chk("B8: crc changed on machine reset");
            if (res_nbytes_m != keep_n)  fatal_chk("B8: nbytes changed on machine reset");
            $display("B8: machine reset - result persists (code=%d crc=%h n=%0d)",
                     keep_code, keep_crc, keep_n);
        end

        // B9: re-arm after a failed generation: fresh 512-byte load -> OK
        hb_cmd(16'h0082, 16'd1, 32'd512, res);
        wait_res_fall;
        for (i = 0; i < 128; i = i + 1)
            hb_word(i*4, p32(i));
        hb_cmd(16'h008F, 16'd0, 32'd0, res);
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT B9 res_valid");
        end
        #200;
        if (res_code_m != 2'd0)
            $fatal(1, "B9: re-arm after fail not OK (code=%d fail=%d)", res_code_m, res_fail_m);
        if (res_crc_m != expect512)
            $fatal(1, "B9: CRC mismatch after re-arm: got %h want %h", res_crc_m, expect512);
        $display("B9: re-arm after failed generation -> OK crc=%h", res_crc_m);

        $display("BRIDGE STORAGE PASS: real core_bridge_cmd handshake (status, NOFILE, load, reload, wrong-id, incomplete, overflow, reset-persist, re-arm)");
        $finish;
    end

endmodule
