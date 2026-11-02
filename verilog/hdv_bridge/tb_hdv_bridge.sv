// HDV bridge harness: hdv_bridge.sv + real hdd.v, fake host bridge, fake 6502.
//
// Proves the H2 transfer path end-to-end at the block level (the 6502 and
// the host are models; the hdd controller and the bridge mover are the
// real shipping RTL):
//   T1: mounted, C0F0 READ -> 0x0180 armed with the right parameters,
//       cpu_wait across the transfer, host DMA pattern -> 512 C0F8 reads
//       return the exact pattern (full-byte integrity gate).
//   T2: C0F0 WRITE with protect -> 0x2B, no hdd_write pulse, no 0x0184.
//   T3: unmounted, C0F0 READ -> 0x28 NO_DEVICE.
//   T4: protect=0, 512 C0F8 writes + C0F0 WRITE -> 0x0184 armed, and the
//       host sees the C0F8 bytes in the sector RAM (write direction).
//   T5: host never completes a fetch -> FETCH_TO timeout releases the CPU,
//       latches hdv_fault, and C0F1 reports the failure (not stale 00);
//       a later clean fetch recovers and clears the fault.
//   T6: two CONSECUTIVE 0x0180 fetches (the ProDOS-load shape) both arrive
//       byte-exact with distinct per-sector patterns.
//   T7: mounted desync (hdd sees mounted, bridge does not) -> the execute
//       commits success, the bridge drops the request, and C0F1 later
//       reports the error (the silent-corruption path, closed by
//       bridge_err -> hdd reg_status).
//
// Build/run: run_hdv_bridge.sh (MSYS2 ucrt64) - Verilator --binary.

`timescale 1ns/1ps

module tb_hdv_bridge;

    // clocks: realistic ratios (74.25 MHz bridge, 14.318 MHz machine).
    // initial+forever+blocking is the proven Verilator --timing pattern
    // (an `always #d clk <= ~clk` generator makes posedge processes
    // re-fire many times per edge in this build).
    reg clk_74a = 0, clk_14a = 0;
    initial begin
        forever #6.733 clk_74a = ~clk_74a;
    end
    initial begin
        forever #34.921 clk_14a = ~clk_14a;
    end

    wire reset_n;
    reg  reset_n_r = 1'b0;
    always @(posedge clk_74a) begin
        if (reset_n_r == 1'b0 && clk_74a) reset_n_r <= 1'b1;
    end
    assign reset_n = reset_n_r;

    // ---- host bridge (74a domain) ----
    reg         bridge_wr = 1'b0;
    reg  [31:0] bridge_addr = 32'd0;
    reg  [31:0] bridge_wr_data = 32'd0;
    wire [31:0] hdv_ram_word;

    // ---- core_bridge_cmd dataslot interface (driven by the DUT) ----
    wire        target_dataslot_read, target_dataslot_write;
    reg         target_dataslot_done = 1'b0;
    wire [2:0]  target_dataslot_err = 3'd0;
    wire [15:0] target_dataslot_id;
    wire [31:0] target_dataslot_slotoffset;
    wire [31:0] target_dataslot_bridgeaddr;
    wire [31:0] target_dataslot_length;

    // ---- slot presence ----
    reg         hdv_mounted = 1'b0;   // bridge (74a) view
    reg         hdd_mnt     = 1'b0;   // hdd (14M) view (split for the T7 desync)
    reg         hdv_protect = 1'b1;

    // ---- hdd sector-buffer interface ----
    wire [8:0]  hdd_ram_addr;
    wire [7:0]  hdd_ram_di, hdd_ram_do;
    wire        hdd_ram_we;

    // ---- hdd request pulses ----
    wire        hdd_read, hdd_write;
    wire [15:0] hdd_sector;
    wire        cpu_wait_hdd;
    wire [2:0]  hdv_state;
    wire        hdv_fault;
    wire [7:0]  hdv_fetch_cnt;
    wire        bridge_err;

    // 74a -> 14a sync for the bridge fault pulse (mirrors the top's
    // synch_3 first stage pair; the 15 x 74a hold window guarantees the
    // sampler sees a full high period)
    reg  [1:0]  berr_sync;
    always @(posedge clk_14a) berr_sync <= {berr_sync[0], bridge_err};
    wire bridge_err_m = berr_sync[1];

    // host-model control: 1 = the host never completes a command (T5)
    reg         host_ignore = 1'b0;

    // ================= DUT =================
    // FETCH_TO shrunk for T5 (timeout test): 1024 bridge clocks ~ 14 us.
    hdv_bridge #(.FETCH_TO(28'd1024)) dut (
        .clk_74a        ( clk_74a ),
        .clk_14a        ( clk_14a ),
        .reset_n        ( reset_n ),
        .bridge_wr      ( bridge_wr ),
        .bridge_addr    ( bridge_addr ),
        .bridge_wr_data ( bridge_wr_data ),
        .hdv_ram_word   ( hdv_ram_word ),
        .target_dataslot_read   ( target_dataslot_read ),
        .target_dataslot_write  ( target_dataslot_write ),
        .target_dataslot_done   ( target_dataslot_done ),
        .target_dataslot_err    ( target_dataslot_err ),
        .target_dataslot_id         ( target_dataslot_id ),
        .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
        .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
        .target_dataslot_length     ( target_dataslot_length ),
        .hdv_mounted    ( hdv_mounted ),
        .hdv_protect    ( hdv_protect ),
        .hdd_ram_addr   ( hdd_ram_addr ),
        .hdd_ram_di     ( hdd_ram_di ),
        .hdd_ram_do     ( hdd_ram_do ),
        .hdd_ram_we     ( hdd_ram_we ),
        .hdd_read       ( hdd_read ),
        .hdd_write      ( hdd_write ),
        .hdd_sector     ( hdd_sector ),
        .cpu_wait_hdd   ( cpu_wait_hdd ),
        .hdv_state      ( hdv_state ),
        .hdv_fault      ( hdv_fault ),
        .hdv_fetch_cnt  ( hdv_fetch_cnt ),
        .bridge_err     ( bridge_err )
    );

    hdd u_hdd (
        .CLK_14M        ( clk_14a ),
        .IO_SELECT      ( 1'b0 ),      // ROM not exercised here
        .DEVICE_SELECT  ( cpu_ds ),
        .RESET          ( cpu_rst ),
        .A              ( cpu_a ),
        .RD             ( cpu_rd ),
        .D_IN           ( cpu_din ),
        .D_OUT          ( cpu_dout ),
        .sector         ( hdd_sector ),
        .hdd_read       ( hdd_read ),
        .hdd_write      ( hdd_write ),
        .hdd_mounted    ( hdd_mnt ),
        .hdd_protect    ( hdv_protect ),
        .bridge_fault   ( bridge_err_m ),
        .ram_addr       ( hdd_ram_addr ),
        .ram_di         ( hdd_ram_di ),
        .ram_do         ( hdd_ram_do ),
        .ram_we         ( hdd_ram_we )
    );

    // ================= fake 6502 (14a domain) =================
    // PHASE-LOCKED PROTOCOL: the bus changes only on clk_14a negedges, so
    // every DUT posedge samples a stable bus (task/@(posedge) waits race
    // the DUT's edge sampling in Verilator --timing builds). One full
    // period per access; the idle cycle after an access is what lets the
    // hdd increment sec_addr.
    reg         cpu_rst = 1'b1;
    reg         cpu_ds  = 1'b0;
    reg         cpu_rd  = 1'b0;
    reg  [15:0] cpu_a   = 16'd0;
    reg  [7:0]  cpu_din = 8'd0;
    wire [7:0]  cpu_dout;

    task c0f8_read(output [7:0] d);
        begin
            @(negedge clk_14a);
            cpu_ds = 1'b1; cpu_rd = 1'b1; cpu_a = 16'hC0F8;
            @(negedge clk_14a);   // posedge in between: D_OUT latched
            d = cpu_dout;
            cpu_ds = 1'b0; cpu_rd = 1'b0;
        end
    endtask

    task c0f8_write(input [7:0] b);
        begin
            @(negedge clk_14a);
            cpu_ds = 1'b1; cpu_rd = 1'b0; cpu_a = 16'hC0F8; cpu_din = b;
            @(negedge clk_14a);
            cpu_ds = 1'b0; cpu_rd = 1'b0;
        end
    endtask

    task c0f_write(input [15:0] addr, input [7:0] b);
        begin
            @(negedge clk_14a);
            cpu_ds = 1'b1; cpu_rd = 1'b0; cpu_a = addr; cpu_din = b;
            @(negedge clk_14a);
            cpu_ds = 1'b0; cpu_rd = 1'b0;
        end
    endtask

    task c0f_read(input [15:0] addr, output [7:0] d);
        begin
            @(negedge clk_14a);
            cpu_ds = 1'b1; cpu_rd = 1'b1; cpu_a = addr;
            @(negedge clk_14a);   // D_OUT latched by the posedge between
            d = cpu_dout;
            cpu_ds = 1'b0; cpu_rd = 1'b0;
        end
    endtask

    // ================= host model (74a domain) =================
    // Mirrors core_bridge_cmd: a 2FF edge detector, parameters latched ONE
    // CYCLE AFTER the command pulse (when the queue bit pops) - not in the
    // pulse cycle (that would sample the DUT's pre-edge register values).
    reg  [1:0] tr_sync, tw_sync;
    wire      tr_rise = tr_sync[1] & ~tr_sync[0];
    wire      tw_rise = tw_sync[1] & ~tw_sync[0];
    reg  [15:0] cmd_seen_id;
    reg  [31:0] cmd_seen_offset, cmd_seen_addr, cmd_seen_len;
    reg  [1:0]  cmd_kind;   // 0 none, 1 read, 2 write
    integer     read_cmds, write_cmds;
    reg         dma_busy;
    reg         dma_go = 1'b0;   // sequence: pattern DMA finished -> done

    // pattern: byte i of a sector
    function [7:0] pat;
        input [8:0] i;
        reg [31:0] t;
        begin
            t = (i * 7 + 13) % 256;
            pat = t[7:0];
        end
    endfunction

    // per-sector pattern (T6): distinguishes consecutive fetches
    function [7:0] pat2;
        input [8:0]  i;
        input [7:0]  s;
        reg [31:0]   t;
        begin
            t = (i * 7 + 13 + s * 101) % 256;
            pat2 = t[7:0];
        end
    endfunction

    always @(posedge clk_74a) begin
        if (!reset_n) begin
            tr_sync <= 2'b00; tw_sync <= 2'b00;
            cmd_kind <= 2'd0; dma_busy <= 1'b0;
            target_dataslot_done <= 1'b0;
        end else begin
            tr_sync <= {tr_sync[0], target_dataslot_read};
            tw_sync <= {tw_sync[0], target_dataslot_write};

            if (tr_rise) begin
                cmd_kind        <= 2'd1;
                cmd_seen_id     <= target_dataslot_id;
                cmd_seen_offset <= target_dataslot_slotoffset;
                cmd_seen_addr   <= target_dataslot_bridgeaddr;
                cmd_seen_len    <= target_dataslot_length;
                target_dataslot_done <= 1'b0;   // host: done until command start
                dma_busy       <= 1'b1;
            end else if (tw_rise) begin
                cmd_kind        <= 2'd2;
                cmd_seen_id     <= target_dataslot_id;
                cmd_seen_offset <= target_dataslot_slotoffset;
                cmd_seen_addr   <= target_dataslot_bridgeaddr;
                cmd_seen_len    <= target_dataslot_length;
                target_dataslot_done <= 1'b0;
                dma_busy       <= 1'b1;
            end else if (dma_go && dma_busy && !host_ignore) begin
                target_dataslot_done <= 1'b1;
                dma_busy             <= 1'b0;
            end
        end
    end

    integer failures;
    integer i;
    reg  [31:0] t;
    reg  [7:0]  st;
    reg  [8:0]  b0, b1, b2, b3;
    reg  [15:0] tmp16;
    reg  [7:0]  d8;

    // ================= sequence =================
    initial begin
        failures = 0;
        read_cmds = 0; write_cmds = 0;

        // ---- reset & mount ----
        #200;
        cpu_rst = 1'b0;
        hdv_mounted = 1'b1;
        hdd_mnt     = 1'b1;
        hdv_protect = 1'b1;
        repeat (50) @(negedge clk_14a);

        // ---- T1: READ sector 10 ----
        // ---- T1: READ sector 10 ----
        c0f_write(16'hC0F3, 8'h70);        // unit number (required!)
        c0f_write(16'hC0F6, 8'd10);        // block low
        c0f_write(16'hC0F7, 8'd0);         // block high
        c0f_write(16'hC0F2, 8'd1);         // command = READ
        c0f_read(16'hC0F0, st);            // execute
        if (st !== 8'd0) begin
            $display("FAIL T1: C0F0 READ status = %0d (want 0)", st);
            failures = failures + 1;
        end

        // wait for the host read command
        wait (cmd_kind == 2'd1);
        if (cmd_seen_id !== 16'd2)            begin $display("FAIL T1: cmd id %0d (want 2)", cmd_seen_id); failures = failures + 1; end
        if (cmd_seen_offset !== 32'd5120)     begin $display("FAIL T1: offset %0d (want 5120)", cmd_seen_offset); failures = failures + 1; end
        if (cmd_seen_addr !== 32'h01F01000)   begin $display("FAIL T1: addr %h (want 01F01000)", cmd_seen_addr); failures = failures + 1; end
        if (cmd_seen_len !== 32'd512)        begin $display("FAIL T1: len %0d (want 512)", cmd_seen_len); failures = failures + 1; end
        if (!cpu_wait_hdd) begin $display("FAIL T1: cpu_wait not asserted"); failures = failures + 1; end
        read_cmds = read_cmds + 1;

        // host DMA: 128 BE words of the pattern (first file byte in [31:24],
        // matching the real host's big-endian DMA: bridge_endian_little = 0).
        // Phase-align to a negedge first: a write window that starts on a
        // posedge is only half a cycle long and misses the DUT's posedge
        // sampling.
        @(negedge clk_74a);
        for (i = 0; i < 128; i = i + 1) begin
            /* verilator lint_off WIDTHTRUNC */
            tmp16 = i*4;   // i < 128: product < 512, fits
            /* verilator lint_on WIDTHTRUNC */
            b0 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
            bridge_wr      = 1'b1;
            bridge_addr    = 32'h01F01000 + i*4;
            bridge_wr_data = {pat(b0), pat(b1), pat(b2), pat(b3)};
            @(negedge clk_74a);
            bridge_wr = 1'b0;
        end
        dma_go = 1'b1;   // host model asserts done after the DMA

        // wait for the stall to release
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;

        // 512 C0F8 reads must return the pattern exactly
        for (i = 0; i < 512; i = i + 1) begin
            c0f8_read(d8);
            if (d8 !== pat(i[8:0])) begin
                if (failures < 8) $display("FAIL T1: C0F8[%0d] = %0d want %0d", i, d8, pat(i[8:0]));
                failures = failures + 1;
            end
        end
        if (failures == 0) $display("PASS T1: 512-byte READ transfer exact");
        // fetch_cnt (the overlay N= source) must count completions:
        if (hdv_fetch_cnt !== 8'd1) begin $display("FAIL T1: hdv_fetch_cnt=%0d (want 1)", hdv_fetch_cnt); failures = failures + 1; end

        // ---- T6: two CONSECUTIVE fetches (the real HD-boot shape) ----
        // The harness previously exercised at most one 0x0180 per run; a
        // ProDOS load issues dozens in a row. Both sectors must arrive
        // byte-exact with distinct patterns, back to back.
        dma_go = 1'b0;
        c0f_write(16'hC0F6, 8'd21);
        c0f_write(16'hC0F2, 8'd1);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T6a: C0F0 status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd1 && cmd_seen_offset == 32'd10752);
        read_cmds = read_cmds + 1;
        @(negedge clk_74a);
        for (i = 0; i < 128; i = i + 1) begin
            /* verilator lint_off WIDTHTRUNC */
            tmp16 = i*4;
            /* verilator lint_on WIDTHTRUNC */
            b0 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
            bridge_wr      = 1'b1;
            bridge_addr    = 32'h01F01000 + i*4;
            bridge_wr_data = {pat2(b0, 8'd21), pat2(b1, 8'd21), pat2(b2, 8'd21), pat2(b3, 8'd21)};
            @(negedge clk_74a);
            bridge_wr = 1'b0;
        end
        dma_go = 1'b1;
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        for (i = 0; i < 512; i = i + 1) begin
            c0f8_read(d8);
            if (d8 !== pat2(i[8:0], 8'd21)) begin
                if (failures < 8) $display("FAIL T6a: C0F8[%0d] = %0d want %0d", i, d8, pat2(i[8:0], 8'd21));
                failures = failures + 1;
            end
        end
        // fetch #2 of T6: sector 22, immediately after
        dma_go = 1'b0;
        c0f_write(16'hC0F6, 8'd22);
        c0f_write(16'hC0F2, 8'd1);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T6b: C0F0 status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd1 && cmd_seen_offset == 32'd11264);
        read_cmds = read_cmds + 1;
        @(negedge clk_74a);
        for (i = 0; i < 128; i = i + 1) begin
            /* verilator lint_off WIDTHTRUNC */
            tmp16 = i*4;
            /* verilator lint_on WIDTHTRUNC */
            b0 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
            bridge_wr      = 1'b1;
            bridge_addr    = 32'h01F01000 + i*4;
            bridge_wr_data = {pat2(b0, 8'd22), pat2(b1, 8'd22), pat2(b2, 8'd22), pat2(b3, 8'd22)};
            @(negedge clk_74a);
            bridge_wr = 1'b0;
        end
        dma_go = 1'b1;
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        for (i = 0; i < 512; i = i + 1) begin
            c0f8_read(d8);
            if (d8 !== pat2(i[8:0], 8'd22)) begin
                if (failures < 8) $display("FAIL T6b: C0F8[%0d] = %0d want %0d", i, d8, pat2(i[8:0], 8'd22));
                failures = failures + 1;
            end
        end
        if (failures == 0) $display("PASS T6: two consecutive fetches byte-exact");
        // overlay N= counter: T1 + T6's two fetches completed so far
        if (hdv_fetch_cnt !== 8'd3) begin $display("FAIL T6: hdv_fetch_cnt=%0d (want 3)", hdv_fetch_cnt); failures = failures + 1; end

        // ---- T2: WRITE is protected ----
        c0f_write(16'hC0F2, 8'd2);         // command = WRITE
        c0f_read(16'hC0F0, st);            // execute
        if (st !== 8'h2B) begin
            $display("FAIL T2: C0F0 WRITE status = %0d (want 43/0x2B PROTECT)", st);
            failures = failures + 1;
        end
        #500;
        if (cmd_kind == 2'd2) begin $display("FAIL T2: 0x0184 was issued"); failures = failures + 1; end
        if (failures == 0) $display("PASS T2: WRITE refused (PROTECT), no 0x0184");

        // ---- T3: unmounted ----
        hdv_mounted = 1'b0;
        hdd_mnt     = 1'b0;   // both views: hdd rejects the command itself
        c0f_write(16'hC0F2, 8'd1);
        c0f_read(16'hC0F0, st);
        if (st !== 8'h28) begin
            $display("FAIL T3: C0F0 READ status = %0d (want 40/0x28 NO_DEVICE)", st);
            failures = failures + 1;
        end
        hdv_mounted = 1'b1;
        hdd_mnt     = 1'b1;
        if (failures == 0) $display("PASS T3: NO_DEVICE when unmounted");

        // ---- T7: desync drop -> C0F1 reports the failure ----
        // hdd (14M) believes the HDV is mounted, the bridge (74a) does not:
        // the C0F0 execute commits success and pulses hdd_read, but the
        // bridge drops the request (no 0x0180, no stall). bridge_err must
        // reach hdd through the 2FF and force reg_status, so a C0F1 read
        // after the transfer reports the error - the silent-corruption path
        // the expert review flagged (stale sector RAM + status 00).
        hdv_mounted = 1'b0;     // bridge view only; hdd_mnt stays 1
        c0f_write(16'hC0F6, 8'd30);
        c0f_write(16'hC0F2, 8'd1);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T7: C0F0 execute status = %0d (want 0, optimistic)", st); failures = failures + 1; end
        if (cpu_wait_hdd) begin $display("FAIL T7: cpu_wait asserted on a dropped fetch"); failures = failures + 1; end
        #2000;   // bridge_err hold (15 x 74a) + 2FF sync reaches hdd
        c0f_read(16'hC0F1, st);
        if (st !== 8'h01) begin $display("FAIL T7: C0F1 after drop = %0d (want 1)", st); failures = failures + 1; end
        hdv_mounted = 1'b1;     // remount both views
        if (read_cmds !== 3) begin $display("FAIL T7: read_cmds=%0d (want 3, drop issues no 0x0180)", read_cmds); failures = failures + 1; end
        c0f_write(16'hC0F6, 8'd10);   // restore T1's block: T4 inherits the
        c0f_write(16'hC0F7, 8'd0);   // sector registers from here
        if (failures == 0) $display("PASS T7: dropped fetch reports error via C0F1");

        // ---- T4: WRITE with protect=0 ----
        hdv_protect = 1'b0;
        for (i = 0; i < 512; i = i + 1) begin
            t = (i * 3 + 1) % 256;
            c0f8_write(t[7:0]);
        end
        c0f_write(16'hC0F2, 8'd2);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin
            $display("FAIL T4: C0F0 WRITE status = %0d (want 0)", st);
            failures = failures + 1;
        end
        // the hdd_write pulse arms the walk within a few machine clocks;
        // at +8us we are mid-walk (the walk is 1024 machine cycles ~ 72us)
        #8000;
        if (!cpu_wait_hdd) begin $display("FAIL T4: cpu_wait not held across walk_out"); failures = failures + 1; end
        wait (cmd_kind == 2'd2);   // the 0x0184 pulse comes only after the walk
        if (cmd_seen_id !== 16'd2)          begin $display("FAIL T4: cmd id %0d (want 2)", cmd_seen_id); failures = failures + 1; end
        if (cmd_seen_offset !== 32'd5120)   begin $display("FAIL T4: offset %0d (want 5120)", cmd_seen_offset); failures = failures + 1; end
        if (cmd_seen_len !== 32'd512)       begin $display("FAIL T4: len %0d (want 512)", cmd_seen_len); failures = failures + 1; end
        write_cmds = write_cmds + 1;
        while (cpu_wait_hdd) @(negedge clk_14a);
        #5000;   // last walk_out CDC writes settle within ~3 bridge clocks
        for (i = 0; i < 512; i = i + 1) begin
            t = (i * 3 + 1) % 256;
            if (dut.hdv_ram[i] !== t[7:0]) begin
                if (failures < 8) $display("FAIL T4: ram[%0d] = %0d want %0d", i, dut.hdv_ram[i], t[7:0]);
                failures = failures + 1;
            end
        end
        dma_go = 1'b1;   // host: 0x0184 streams from the RAM (content checked above)
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        if (failures == 0) $display("PASS T4: 512-byte WRITE walk exact (0x0184 armed)");

        // ---- T5: host fetch never completes -> timeout releases the CPU ----
        // (the 2026-10-30 hardware hang: HDV mounted, ROM commits to the HD,
        // first C0F0 read, and the stall never ends. The timeout must bound
        // that: IDLE + fault latch + a later clean fetch clears the fault.)
        hdv_protect = 1'b1;
        host_ignore = 1'b1;
        dma_go      = 1'b0;
        c0f_write(16'hC0F6, 8'd20);
        c0f_write(16'hC0F2, 8'd1);         // READ
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T5: C0F0 status %0d (want 0, fetch in flight)", st); failures = failures + 1; end
        repeat (20) @(negedge clk_14a);
        if (!cpu_wait_hdd) begin $display("FAIL T5: cpu_wait not asserted during in-flight fetch"); failures = failures + 1; end
        if (hdv_state !== 3'd1) begin $display("FAIL T5: state=%0d (want 1=FETCH)", hdv_state); failures = failures + 1; end
        if (hdv_fault) begin $display("FAIL T5: fault set before any timeout"); failures = failures + 1; end
        // bounded wait for the timeout release (1024 x 13.47 ns ~ 14 us)
        begin : t5wait
            integer w;
            for (w = 0; w < 3000 && cpu_wait_hdd; w = w + 1)
                @(negedge clk_14a);
        end
        if (cpu_wait_hdd) begin $display("FAIL T5: cpu_wait still held after the timeout bound"); failures = failures + 1; end
        if (hdv_state !== 3'd0) begin $display("FAIL T5: state=%0d after timeout (want 0=IDLE)", hdv_state); failures = failures + 1; end
        if (!hdv_fault) begin $display("FAIL T5: hdv_fault not latched on timeout"); failures = failures + 1; end
        #1000;   // bridge_err hold (15 x 74a) + 2FF sync reaches hdd
        c0f_read(16'hC0F1, st);
        if (st !== 8'h01) begin $display("FAIL T5: C0F1 after timeout = %0d (want 1, not stale 00)", st); failures = failures + 1; end
        // a timed-out fetch does NOT count as completed (T1 + T6's two)
        if (hdv_fetch_cnt !== 8'd3) begin $display("FAIL T5: hdv_fetch_cnt=%0d after timeout (want 3, timeout is not a completion)", hdv_fetch_cnt); failures = failures + 1; end
        // recovery: host responds again -> the next fetch completes clean
        host_ignore = 1'b0;
        dma_go      = 1'b1;
        c0f_write(16'hC0F2, 8'd1);
        c0f_read(16'hC0F0, st);
        while (cpu_wait_hdd) @(negedge clk_14a);
        #500;
        if (hdv_fault) begin $display("FAIL T5: fault not cleared by a clean fetch"); failures = failures + 1; end
        if (hdv_fetch_cnt !== 8'd4) begin $display("FAIL T5: fetch_cnt=%0d (want 4: T1 + T6x2 + recovery; timeout not counted)", hdv_fetch_cnt); failures = failures + 1; end
        if (failures == 0) $display("PASS T5: fetch timeout releases the CPU, fault latches, clean fetch recovers");

        // ---- summary ----
        $display("hdv_bridge: read_cmds=%0d write_cmds=%0d failures=%0d",
                 read_cmds, write_cmds, failures);
        if (failures == 0)
            $display("HDV BRIDGE ALL CHECKS PASSED");
        else
            $display("HDV BRIDGE FAIL");
        $finish;
    end

    // watchdog
    initial begin
        #20_000_000;
        $display("FAIL: watchdog timeout");
        $finish;
    end

endmodule
