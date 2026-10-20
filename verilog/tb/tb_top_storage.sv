//
// tb_top_storage.sv - full storage-path integration test
// (M0 rework, Unit 4: "full-top integration TB")
//
// Instantiates the shipped storage module (sdram_storage.v - FIFO + store +
// io_sdram_pocket + verifier + all CDC shims + 0xF9 diagnostics) against the
// behavioral DRAM model, exactly as the top wires it:
//   host writes (74.25) -> FIFO -> store -> SDRAM model
//   verifier (machine) reads back via the word-port shim
//   0xF9 diagnostic reads observed in the host domain
//
// Tests:
//   A  boot: init_done rises after SDRAM init
//   B  store 128 words (512 B, all-0xAA) via bridge word writes;
//      counters + flags via 0xF9 reads
//   C  verify: n_bytes=512, start -> done/ok, CRC32/first/last match the
//      PC-computed reference
//   D  verifier-only reset (rst_n_mach) does not destroy the image:
//      re-verify still passes
//   E  size tails: n_bytes=511 and n_bytes=1 verify with their own
//      reference CRCs (verifier handles any nonzero byte length)
//
// Contract failures are $fatal (no counting mode); watchdog 2 ms.
//
// Build (MSYS2 UCRT64): see the verilog/ README pattern for --binary
// --timing; default chip-vs-ctrl phase is the shipping 180 deg
// (PHASE=3.756 ns) - see tb_disk_store.sv for the phase sweep evidence.
//
`timescale 1ns/1ps
module tb_top_storage;

    parameter real PHASE = 3.756;   // chip_clk phase vs ctrl_clk, ns

    // ---- DUT ----
    reg         clk_74a;
    reg         path_rst;
    reg         bridge_wr;
    reg  [31:0] bridge_addr;
    reg  [31:0] bridge_wr_data;
    wire        init_done, load_drained, store_busy, store_timeout;
    wire [23:0] words_received, words_committed;
    wire        fifo_overflow;
    wire [6:0]  fifo_high_water;
    reg  [15:0] diag_addr;
    reg         diag_rd;
    wire [31:0] diag_rd_data;
    reg         diag_wr;
    reg  [3:0]  diag_wr_sel;
    // APF data-slot handshake (as the top wires it from core_bridge_cmd)
    reg         ds_req;
    reg  [15:0] ds_req_id;
    reg  [31:0] ds_req_size;
    reg         ds_allc;
    reg         clk_mach;
    reg         rst_n_mach;
    wire        ver_done, ver_ok, ver_stuck;
    wire [31:0] ver_crc32, ver_first_word, ver_last_word;
    wire [15:0] ver_words_readout;
    wire [31:0] n_bytes_m;
    wire        store_timeout_m, fifo_overflow_m;
    // coordinator result (machine domain)
    wire        res_valid_m;
    wire [1:0]  res_code_m, res_fail_m;
    wire [31:0] res_crc_m, res_nbytes_m;
    reg         ctrl_clk, chip_clk, clk90;
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

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
        .ds_requestwrite(ds_req), .ds_requestwrite_id(ds_req_id),
        .ds_requestwrite_size(ds_req_size), .ds_allcomplete(ds_allc),
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

    // ---- clocks (ns periods; board-power-up sequence) ----
    // t=1 us : SDRAM power-on settle complete (por_done)
    // t=4 us : PLLs "lock" - all clocks start (boot FSM starts here)
    // t=5 us : storage-path reset released
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

    // power-on settle for the DRAM model
    initial begin
        #1000;
        por_done = 1'b1;
    end


    // ---- watchdog ----
    initial begin
        #(100_000_000);
        $fatal(1, "WATCHDOG: 100 ms deadline exceeded");
    end

    // ---- helpers ----
    task fatal_chk(input [255:0] msg);
    begin
        $fatal(1, "CONTRACT FAIL: %s", msg);
    end
    endtask

    // one bridge word write, paced like the real APF host loader:
    // the host reads the slot file from the SD card (~10-25 MB/s) and
    // pushes it through the bridge, so one word per 8 bridge cycles
    // (9.3 M words/s = 37 MB/s) is a conservative upper bound; the
    // word port absorbs ~13.3 M words/s (53 MB/s), so the FIFO never
    // fills under a real load. (A max-rate stream would overflow the
    // 64-deep FIFO - the sticky overflow flag makes that observable.)
    //
    // Pulse discipline: wr is raised at a negedge and cleared at the
    // next negedge, so it is sampled by exactly one write-clock edge.
    // (An NBA-assigned pulse from a posedge context is 8 cycles wide -
    // that bug produced phantom duplicate records in the first runs.)
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

    // one 0xF9 diagnostic read (74.25 domain).
    // diag_rd_data is a registered output: it updates one posedge after
    // (rd, addr) are sampled, so the value is read two negedges in.
    task diag_read(input [15:0] off, output [31:0] data);
    begin
        @(negedge clk_74a);
        diag_rd   = 1'b1;
        diag_addr = off;
        @(negedge clk_74a);
        diag_rd   = 1'b0;
        @(negedge clk_74a);
        data      = diag_rd_data;
    end
    endtask

    task diag_write(input [15:0] off, input [3:0] sel, input [31:0] data);
    begin
        @(negedge clk_74a);
        diag_wr   = 1'b1;
        diag_addr = off;
        diag_wr_sel = sel;
        bridge_wr_data = data;
        @(negedge clk_74a);
        diag_wr   = 1'b0;
    end
    endtask

    // ---- APF host data-slot event model ----
    // Mirrors core_bridge_cmd behavior: 0082 = 1-2-cycle request pulse with
    // id/size, and it clears allcomplete; 008F = allcomplete level.
    task ds_request(input [15:0] id, input [31:0] size);
    begin
        @(negedge clk_74a);
        ds_req      = 1'b1;
        ds_req_id   = id;
        ds_req_size = size;
        ds_allc     = 1'b0;     // handler clears allcomplete on 0082
        @(negedge clk_74a);
        ds_req      = 1'b0;     // handler back in IDLE: request deasserted
    end
    endtask

    task ds_complete;
    begin
        @(negedge clk_74a);
        ds_allc = 1'b1;
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

    // unpaced raw 1-cycle bridge write (FIFO overflow stress)
    task bridge_write_raw(input [31:0] addr, input [31:0] data);
    begin
        @(negedge clk_74a);
        bridge_wr      = 1'b1;
        bridge_addr    = addr;
        bridge_wr_data = data;
        @(negedge clk_74a);
        bridge_wr      = 1'b0;
    end
    endtask

    // CRC32-IEEE reference (reflected, poly 0xEDB88320, init/final XOR)
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
    // cannot hide (a uniform pattern would be invisible to address bugs)
    function [31:0] p32;
        input [31:0] i;
        begin
            p32 = {8'hA5, 8'h5A, i[15:0]};
        end
    endfunction

    // reference CRC32 over the first n bytes of the pattern image
    // (byte order: word [31:24] first - the contract documented in
    // disk_verifier.v)
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
    reg  [31:0] expect_crc;
    reg  [31:0] expect511, expect1;
    reg  [31:0] expect513;
    reg  [31:0] expect_zero512, expect512crc;
    reg  [31:0] rw;
    integer i, w, z;

    initial begin
        bridge_wr = 1'b0; bridge_addr = 32'd0; bridge_wr_data = 32'd0;
        diag_rd = 1'b0; diag_addr = 16'd0; diag_wr = 1'b0; diag_wr_sel = 4'd0;
        ds_req = 1'b0; ds_req_id = 16'd0; ds_req_size = 32'd0; ds_allc = 1'b0;
        fault_halt = 1'b0;
        path_rst = 1'b1; rst_n_mach = 1'b0;

        compute_crc(512, expect_crc);
        $display("TB: reference CRC of 512-byte pattern image = %h", expect_crc);

        // A: boot (clocks start at 4 us; reset released at 5 us)
        #5000;
        path_rst   = 1'b0;
        rst_n_mach = 1'b1;
        w = 0;
        while (!init_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT init_done");
        end
        $display("A: boot complete, init_done");

        // B: store 128 words (512 B) at word address 0
        for (i = 0; i < 128; i = i + 1)
            bridge_write(i*4, p32(i));
        w = 0;
        while (!(load_drained && (words_received == 128))) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT load_drained");
        end
        if (words_received != 128) fatal_chk("words_received != 128");
        if (words_committed != 128) fatal_chk("words_committed != 128");
        if (fifo_overflow) fatal_chk("fifo_overflow after 128-word load");
        if (fifo_high_water > 7'd32) fatal_chk("high_water > 32 under paced load");
        $display("B: 128 words stored, drained; high_water=%0d", fifo_high_water);

        // 0xF9 read checks
        diag_read(16'h0008, rw);
        if (rw != 128) fatal_chk("0xF9000008 words_received != 128");
        diag_read(16'h000C, rw);
        if (rw != 128) fatal_chk("0xF900000C words_committed != 128");

        // C: verify 512 bytes
        diag_write(16'h0004, 4'd4, 32'd512);
        #500;   // >3 machine sync stages (worst 210 ns)                       // let the machine sync settle
        diag_write(16'h0024, 4'd9, 32'd1);
        w = 0;
        while (!ver_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT ver_done");
        end
        if (!ver_ok) fatal_chk("verifier !ok on 512-byte image");

        // C2: per-address readback spot-check (beyond first/last): an
        // n_bytes=(W+1)*4 run reads words 0..W, so its last_word is word W.
        // Catches address-mux corruption that first/last would miss.
        begin : scanblk
            integer W, si;
            reg [7:0] scanw [0:11];
            reg [31:0] lb;
            scanw[0]=0; scanw[1]=1; scanw[2]=2; scanw[3]=3; scanw[4]=4;
            scanw[5]=5; scanw[6]=10; scanw[7]=20; scanw[8]=50;
            scanw[9]=80; scanw[10]=100; scanw[11]=127;
            for (si = 0; si < 12; si = si + 1) begin
                W = scanw[si];
                diag_write(16'h0024, 4'd9, 32'd0);   // clear start first
                w = 0;
                while (ver_done) begin               // wait done to fall
                    @(posedge clk_74a); w = w + 1;
                    if (w > 200000) $fatal(1, "TIMEOUT scan done-fall");
                end
                diag_write(16'h0004, 4'd4, (W + 1) * 32'd4);
                #500;   // >3 machine sync stages (worst 210 ns)
                diag_write(16'h0024, 4'd9, 32'd1);
                w = 0;
                while (!ver_done) begin
                    @(posedge clk_74a); w = w + 1;
                    if (w > 200000) $fatal(1, "TIMEOUT scan ver_done");
                end
                #500;   // settle
                lb = ver_last_word;
                if (lb != p32(W))
                    fatal_chk("C2: spot word mismatch");
            end
            $display("C2: 12 per-address readback spot-checks OK");
        end

        // Store-side white-box check: the model's memory must hold exactly
        // what was written (row 0, bank 0: word w = 16-bit columns 2w, 2w+1)
        if ({m0.mem[0],   m0.mem[1]}   != p32(0))   fatal_chk("mem word0");
        if ({m0.mem[2],   m0.mem[3]}   != p32(1))   fatal_chk("mem word1");
        if ({m0.mem[252], m0.mem[253]} != p32(126)) fatal_chk("mem word126");
        if ({m0.mem[254], m0.mem[255]} != p32(127)) fatal_chk("mem word127");
        $display("C: first=%h last=%h crc=%h", ver_first_word, ver_last_word, ver_crc32);
        if (ver_crc32 != expect_crc)
            $fatal(1, "CRC mismatch: got %h want %h", ver_crc32, expect_crc);
        if (ver_first_word != p32(0))   fatal_chk("first word mismatch");
        if (ver_last_word  != p32(127)) fatal_chk("last word mismatch");
        if (ver_words_readout != 128) fatal_chk("words_readout != 128");
        $display("C: verify OK crc=%h first=%h last=%h", ver_crc32,
                 ver_first_word, ver_last_word);

        // D: verifier-only reset does not destroy the image
        rst_n_mach = 1'b0;
        #300;
        rst_n_mach = 1'b1;
        w = 0;
        while (ver_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT ver_done fall");
        end
        diag_write(16'h0024, 4'd9, 32'd0);
        #500;   // >3 machine sync stages (worst 210 ns)
        diag_write(16'h0024, 4'd9, 32'd1);   // edge: 0 -> 1 restarts
        w = 0;
        while (!ver_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT ver_done re-verify");
        end
        if (!ver_ok || ver_crc32 != expect_crc)
            fatal_chk("re-verify after verifier reset failed");
        $display("D: image survived verifier-only reset; re-verify OK");

        // E1: 511-byte tail verifies with its own reference CRC
        diag_write(16'h0004, 4'd4, 32'd511);
        compute_crc(511, expect511);
        #500;   // >3 machine sync stages (worst 210 ns)
        diag_write(16'h0024, 4'd9, 32'd0);
        #500;   // >3 machine sync stages (worst 210 ns)
        diag_write(16'h0024, 4'd9, 32'd1);
        w = 0;
        while (!ver_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT ver_done 511");
        end
        if (!ver_ok) fatal_chk("511-byte image should verify in M0");
        if (ver_crc32 != expect511)
            $fatal(1, "511-byte CRC mismatch: got %h want %h", ver_crc32, expect511);
        $display("E1: 511-byte tail verify OK crc=%h", ver_crc32);

        // E2: 1-byte tail verifies with its own reference CRC
        diag_write(16'h0004, 4'd4, 32'd1);
        compute_crc(1, expect1);
        #500;   // >3 machine sync stages (worst 210 ns)
        diag_write(16'h0024, 4'd9, 32'd0);
        #500;   // >3 machine sync stages (worst 210 ns)
        diag_write(16'h0024, 4'd9, 32'd1);
        w = 0;
        while (!ver_done) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT ver_done 1");
        end
        if (!ver_ok) fatal_chk("1-byte image should verify in M0");
        if (ver_crc32 != expect1)
            $fatal(1, "1-byte CRC mismatch: got %h want %h", ver_crc32, expect1);
        $display("E2: 1-byte tail verify OK crc=%h", ver_crc32);

        // T5: absent media - 008F with no 0082 -> NOFILE result, no verify
        ds_complete;
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T5 res_valid");
        end
        #200;
        if (res_code_m != 2'd2) fatal_chk("T5: expected NOFILE result");
        if (res_nbytes_m != 32'd0) fatal_chk("T5: NOFILE nbytes != 0");
        $display("T5: no-file load -> NOFILE result, no verify");

        // T1: full auto path: 0082(size=512) -> 64 words, LONG PAUSE, 64
        // words, 008F (before final commits drain) -> auto-verify OK.
        // Content is the same pattern as test B, so the CRC reference holds.
        ds_request(16'd1, 32'd512);
        wait_res_fall;
        for (i = 0; i < 64; i = i + 1)
            bridge_write(i*4, p32(i));
        #350;   // long mid-stream host pause (~26 clk cycles)
        for (i = 64; i < 128; i = i + 1)
            bridge_write(i*4, p32(i));
        ds_complete;   // immediately: final commits still in flight
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T1 res_valid");
        end
        #200;   // let the result fields settle after the valid sync
        if (res_code_m != 2'd0)
            $fatal(1, "T1: auto result not OK (code=%d fail=%d)", res_code_m, res_fail_m);
        if (res_nbytes_m != 32'd512) fatal_chk("T1: nbytes != 512");
        if (res_crc_m != expect_crc)
            $fatal(1, "T1: auto CRC mismatch: got %h want %h", res_crc_m, expect_crc);
        $display("T1: auto-verify OK after pause + delayed commit crc=%h", res_crc_m);

        // T2: reload with a 513-byte file (129 words, partial last word):
        // proves per-load re-arming + exact-size (non-4-aligned) CRC.
        ds_request(16'd1, 32'd513);
        wait_res_fall;
        for (i = 0; i < 128; i = i + 1)
            bridge_write(i*4, p32(i));
        bridge_write(128*4, p32(128));
        ds_complete;
        compute_crc(513, expect513);
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T2 res_valid");
        end
        #200;
        if (res_code_m != 2'd0) fatal_chk("T2: auto result not OK");
        if (res_nbytes_m != 32'd513) fatal_chk("T2: nbytes != 513");
        if (res_crc_m != expect513)
            $fatal(1, "T2: 513-byte CRC mismatch: got %h want %h", res_crc_m, expect513);
        $display("T2: reload 513 bytes (partial word) auto-verify OK crc=%h", res_crc_m);

        // T3: 1-byte file
        ds_request(16'd1, 32'd1);
        wait_res_fall;
        bridge_write(0, p32(0));
        ds_complete;
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T3 res_valid");
        end
        #200;
        if (res_code_m != 2'd0) fatal_chk("T3: auto result not OK");
        if (res_nbytes_m != 32'd1) fatal_chk("T3: nbytes != 1");
        if (res_crc_m != expect1)
            $fatal(1, "T3: 1-byte CRC mismatch: got %h want %h", res_crc_m, expect1);
        $display("T3: 1-byte file auto-verify OK crc=%h", res_crc_m);

        // T4: 511-byte file
        ds_request(16'd1, 32'd511);
        wait_res_fall;
        for (i = 0; i < 128; i = i + 1)
            bridge_write(i*4, p32(i));
        ds_complete;
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T4 res_valid");
        end
        #200;
        if (res_code_m != 2'd0) fatal_chk("T4: auto result not OK");
        if (res_nbytes_m != 32'd511) fatal_chk("T4: nbytes != 511");
        if (res_crc_m != expect511)
            $fatal(1, "T4: 511-byte CRC mismatch: got %h want %h", res_crc_m, expect511);
        $display("T4: 511-byte file auto-verify OK crc=%h", res_crc_m);

        // T6: incomplete transfer: 0082 size=512 but only 100 words sent
        // -> REJECT as FAIL IN (incomplete), no verify, no success.
        ds_request(16'd1, 32'd512);
        wait_res_fall;
        for (i = 0; i < 100; i = i + 1)
            bridge_write(i*4, p32(i));
        ds_complete;
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T6 res_valid");
        end
        #200;
        if (res_code_m != 2'd1 || res_fail_m != 2'd3)
            $fatal(1, "T6: expected FAIL IN, got code=%d fail=%d", res_code_m, res_fail_m);
        if (res_nbytes_m != 32'd512) fatal_chk("T6: nbytes != 512");
        $display("T6: incomplete transfer rejected FAIL IN");

        // T7: FIFO overflow: unpaced 100-word burst (FIFO depth 64) ->
        // FAIL OV; the later 008F must not overwrite the result.
        ds_request(16'd1, 32'd512);
        wait_res_fall;
        for (i = 0; i < 100; i = i + 1)
            bridge_write_raw(i*4, p32(i));
        w = 0;
        while (!fifo_overflow) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T7 overflow");
        end
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T7 res_valid");
        end
        #200;
        if (res_code_m != 2'd1 || res_fail_m != 2'd1)
            $fatal(1, "T7: expected FAIL OV, got code=%d fail=%d", res_code_m, res_fail_m);
        ds_complete;   // host finishes anyway; result must not change
        #300;
        if (res_code_m != 2'd1 || res_fail_m != 2'd1)
            fatal_chk("T7: result clobbered by later 008F");
        // let the store drain the surviving tail words before the next gen
        w = 0;
        while (!load_drained) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T7 drain");
        end
        $display("T7: FIFO overflow rejected FAIL OV (008F did not clobber)");

        // T8: chip fault during load: with the chip ignoring all commands,
        // the (controller-timed) word ops still "complete", so the store
        // commits silently; the READBACK is the detector: the verifier
        // captures all-zero DQ (model drives Z -> 0 in two-state) and the
        // returned CRC must differ from the written pattern. Expect:
        // readback-complete (code=OK, fail=0) with a corrupted CRC.
        fault_halt = 1'b1;   // DRAM model ignores all commands now
        ds_request(16'd1, 32'd512);
        wait_res_fall;
        for (i = 0; i < 128; i = i + 1)
            bridge_write(i*4, p32(i));
        ds_complete;
        // exact expectation: readback saw 512 bytes of 0x00 (Z -> 0)
        crc_reset;
        for (z = 0; z < 512; z = z + 1)
            crc_byte(8'h00);
        expect_zero512 = crc_acc ^ 32'hFFFFFFFF;
        // and the pattern reference (what a live chip would have returned)
        compute_crc(512, expect512crc);
        w = 0;
        while (!res_valid_m) begin
            @(posedge clk_74a); w = w + 1;
            if (w > 200000) $fatal(1, "TIMEOUT T8 res_valid");
        end
        #200;
        fault_halt = 1'b0;
        if (res_code_m != 2'd0)
            $fatal(1, "T8: expected readback-complete OK, got code=%d fail=%d", res_code_m, res_fail_m);
        if (res_fail_m != 2'd0)
            $fatal(1, "T8: stale fail subcode on OK result: %d", res_fail_m);
        if (res_crc_m == expect512crc)
            $fatal(1, "T8: corrupted readback matched pattern CRC (fault not injected?)");
        if (res_crc_m != expect_zero512)
            $fatal(1, "T8: readback CRC %h != expected zeros CRC %h", res_crc_m, expect_zero512);
        $display("T8: chip fault caught by readback (crc=%h, not pattern %h)", res_crc_m, expect512crc);

        $display("TOP STORAGE PASS: boot, store, CRC verify, reset-preservation, tails, auto-verify (no-file, pause, reload, tails, incomplete, overflow, chip-fault)");
        $finish;
    end

endmodule
