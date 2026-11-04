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
//   T8: full WRITE round-trip (0.3.3, WP2.1/2/3): C0F8 bytes -> walk_out
//       -> 0x0184 host capture (the never-exercised data leg, BE lane
//       order) -> deliberate-mismatch non-vacancy check -> 0x0180 re-read
//       of the same sector with the captured bytes DMA'd back -> C0F8
//       readout must match; plus a two-sector slotoffset check (40 then 42).
//   T9: mixed-direction back-to-back (WP2.4): READ 44, WRITE 44, READ 44
//       immediately in succession - the shared walk counters across
//       consecutive direction changes (a coverage gap from the ProDOS-
//       crash investigation).
//   T10: protect toggled between hdd_write and the bridge's arm decision
//        (WP2.5): the drop branch must consume the request cleanly and
//        the next unprotected write must work.
//   T11: write-leg host timeout (WP2.6): a 0x0184 that never completes
//        must release the CPU, latch the fault, and make C0F1 report 1
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
    reg         hdv_mounted    = 1'b0; // bridge (74a) view
    reg         hdd_mnt        = 1'b0; // hdd (14M) view (split for the T7 desync)
    // protect is split the same way (0.3.3): the top feeds the same
    // 74a-domain option word to the bridge raw and to hdd through a
    // synch_3 copy - the TB mirrors that so T10 can desync the two.
    reg         hdv_protect    = 1'b1; // hdd (14M) view
    reg         hdv_protect_74 = 1'b1; // bridge (74a) view

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
        .hdv_protect    ( hdv_protect_74 ),
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

    // 0x0184 capture store (0.3.3, WP2.1): the host reads the sector RAM
    // back word-by-word during a write transfer - the data leg the
    // shipping core had never exercised anywhere.
    reg [31:0] cap [0:127];
    // 0x0180 replay store: the host DMAs these words into the RAM for a
    // READ (normally the pattern is generated on the fly; T8/T9/T11
    // replay captured bytes instead).
    reg [31:0] rep [0:127];
    reg        use_rep = 1'b0;
    reg [31:0] rep_w;

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

    // 0.3.3 write pattern (WP2.2): 1..255, never 0x00 - a round-trip check
    // that passed against a dead 0x0184 returning zeros would be
    // worthless.
    function [7:0] patw;
        input [8:0]  i;
        reg  [31:0]  t;
        begin
            t = (i * 7) % 255;
            patw = t[7:0] + 8'd1;
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
                rep_w          <= 32'd0;        // host replay: reset the word index
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
            end else if (dma_busy && use_rep && !host_ignore) begin
                // host replay: DMA the rep[] words into the sector RAM,
                // one bridge word per cycle (the real host does the same,
                // paced by its own bridge reads/writes)
                bridge_wr      <= 1'b1;
                bridge_addr    <= 32'h01F01000 + rep_w*4;
                bridge_wr_data <= rep[rep_w[7:0]];
                if (rep_w == 32'd127) begin
                    dma_busy <= 1'b0;
                    target_dataslot_done <= 1'b1;
                end else
                    rep_w <= rep_w + 32'd1;
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
        hdv_protect    = 1'b0;
        hdv_protect_74 = 1'b0;
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

        // ---- T8: full WRITE round-trip via the 0x0184 data leg (WP2.1/2/3) ----
        // C0F8 bytes -> walk_out -> 0x0184 (the host READS the sector RAM -
        // the data leg never exercised anywhere) -> the host captures the BE
        // stream -> a 0x0180 re-read of the same sector DMAs the captured
        // bytes back -> walk_in -> C0F8 readout. Every byte the CPU wrote
        // must come back exact. Pattern is 1..255 (never 0x00).
        c0f_write(16'hC0F6, 8'd40);
        c0f_write(16'hC0F7, 8'd0);
        for (i = 0; i < 512; i = i + 1)
            c0f8_write(patw(i[8:0]));
        c0f_write(16'hC0F2, 8'd2);         // command = WRITE
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T8: C0F0 WRITE status = %0d (want 0)", st); failures = failures + 1; end
        // WP2.3 slotoffset, first of the pair: sector 40 -> 20480.
        wait (cmd_kind == 2'd2 && cmd_seen_offset == 32'd20480);
        if (cmd_seen_id !== 16'd2)    begin $display("FAIL T8: write cmd id %0d (want 2)", cmd_seen_id); failures = failures + 1; end
        if (cmd_seen_len !== 32'd512) begin $display("FAIL T8: write cmd len %0d (want 512)", cmd_seen_len); failures = failures + 1; end
        write_cmds = write_cmds + 1;
        // host: read the sector RAM back through the 0x0184 port, the way
        // the real host DMAs it: 0x01F01000+off in 4-byte steps, BE (first
        // file byte of the group in [31:24]). The RAM is static during
        // ST_WRITE (walker idle, machine stalled), so each word can be
        // captured combinationally after setting the address.
        bridge_wr = 1'b0;
        for (i = 0; i < 128; i = i + 1) begin
            bridge_addr = 32'h01F01000 + i*4;
            #1;
            cap[i] = hdv_ram_word;
        end
        // lane-order check: word i must be {patw(4i+3), patw(4i+2),
        // patw(4i+1), patw(4i)}
        for (i = 0; i < 128; i = i + 1) begin
            /* verilator lint_off WIDTHTRUNC */
            tmp16 = i*4;
            /* verilator lint_on WIDTHTRUNC */
            b0 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
            if (cap[i] !== {patw(b0), patw(b1), patw(b2), patw(b3)}) begin
                if (failures < 8) $display("FAIL T8: cap[%0d] = %h want %h", i, cap[i], {patw(b0), patw(b1), patw(b2), patw(b3)});
                failures = failures + 1;
            end
        end
        // WP2.2 non-vacancy: corrupt one captured word; the byte comparison
        // above MUST then see exactly one mismatch (a check that passes
        // against a dead 0x0184 returning zeros is worthless); restore it
        // and it must be clean again.
        cap[64] = cap[64] ^ 32'h0001_0000;
        begin : vac
            integer vm;
            vm = 0;
            for (i = 0; i < 128; i = i + 1) begin
                /* verilator lint_off WIDTHTRUNC */
                tmp16 = i*4;
                /* verilator lint_on WIDTHTRUNC */
                b0 = tmp16[8:0];
                tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
                tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
                tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
                if (cap[i] !== {patw(b0), patw(b1), patw(b2), patw(b3)})
                    vm = vm + 1;
            end
            if (vm !== 1) begin $display("FAIL T8: non-vacancy - %0d mismatches after corrupting 1 word (want 1)", vm); failures = failures + 1; end
        end
        cap[64] = {patw(9'd256), patw(9'd257), patw(9'd258), patw(9'd259)};   // restore ([31:24] = first file byte)
        dma_go = 1'b1;   // host accepts the 0x0184 (data already captured)
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        // the round trip: re-issue a 0x0180 READ of sector 40 and replay
        // the captured store into the RAM (the host's read DMA is the
        // 0x0184 stream in reverse)
        dma_go  = 1'b0;
        use_rep = 1'b1;
        for (i = 0; i < 128; i = i + 1)
            rep[i] = cap[i];
        c0f_write(16'hC0F2, 8'd1);         // command = READ
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T8: C0F0 READ status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd1 && cmd_seen_offset == 32'd20480);
        read_cmds = read_cmds + 1;
        // the host model replays rep[] automatically (use_rep); wait for
        // the stall to release (replay DMA + walk_in)
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        use_rep = 1'b0;
        for (i = 0; i < 512; i = i + 1) begin
            c0f8_read(d8);
            if (d8 !== patw(i[8:0])) begin
                if (failures < 8) $display("FAIL T8: round-trip C0F8[%0d] = %0d want %0d", i, d8, patw(i[8:0]));
                failures = failures + 1;
            end
        end
        if (failures == 0) $display("PASS T8a: WRITE round-trip via 0x0184 capture byte-exact");
        // WP2.3 slotoffset, second of the pair: the next write goes to
        // sector 42 - the walk must not have touched the sector registers
        // (the RTL comment says it does not; prove it)
        c0f_write(16'hC0F6, 8'd42);
        c0f_write(16'hC0F2, 8'd2);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T8: C0F0 WRITE status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd2 && cmd_seen_offset == 32'd21504);
        if (cmd_seen_offset !== 32'd21504) begin $display("FAIL T8: slotoffset %0d (want 21504)", cmd_seen_offset); failures = failures + 1; end
        write_cmds = write_cmds + 1;
        dma_go = 1'b1;   // host accepts the 0x0184
        while (cpu_wait_hdd) @(negedge clk_14a);
        #200;
        if (failures == 0) $display("PASS T8b: consecutive write slotoffsets 20480 / 21504");

        // ---- T9: mixed-direction back-to-back (WP2.4) ----
        // The harness never tested mixed N-consecutive-direction sequences
        // (shared walk counters cnt_i/cnt_o2 reset paths): READ 44, WRITE
        // 44, READ 44 - each immediately after the previous completed.
        // Phase A: READ 44 (replay a known pattern)
        dma_go  = 1'b0;
        use_rep = 1'b1;
        for (i = 0; i < 128; i = i + 1) begin
            /* verilator lint_off WIDTHTRUNC */
            tmp16 = i*4;
            /* verilator lint_on WIDTHTRUNC */
            b0 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
            rep[i] = {pat2(b0, 8'd44), pat2(b1, 8'd44), pat2(b2, 8'd44), pat2(b3, 8'd44)};
        end
        c0f_write(16'hC0F6, 8'd44);
        c0f_write(16'hC0F2, 8'd1);         // command = READ
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T9: C0F0 READ status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd1 && cmd_seen_offset == 32'd22528);   // 44*512
        read_cmds = read_cmds + 1;
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        for (i = 0; i < 512; i = i + 1) begin
            c0f8_read(d8);
            if (d8 !== pat2(i[8:0], 8'd44)) begin
                if (failures < 8) $display("FAIL T9: A C0F8[%0d] = %0d want %0d", i, d8, pat2(i[8:0], 8'd44));
                failures = failures + 1;
            end
        end
        // Phase B: WRITE 44 immediately after the read completed
        use_rep = 1'b0;
        c0f_write(16'hC0F6, 8'd44);
        c0f_write(16'hC0F2, 8'd2);         // command = WRITE
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T9: C0F0 WRITE status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd2 && cmd_seen_offset == 32'd22528);
        write_cmds = write_cmds + 1;
        // capture the 0x0184 stream again (the write leg must be exact too).
        // The sector buffer still holds Phase A's pat2(44) data (phase B
        // issues no C0F8 writes), so the stream is that pattern.
        bridge_wr = 1'b0;
        for (i = 0; i < 128; i = i + 1) begin
            bridge_addr = 32'h01F01000 + i*4;
            #1;
            cap[i] = hdv_ram_word;
        end
        for (i = 0; i < 128; i = i + 1) begin
            /* verilator lint_off WIDTHTRUNC */
            tmp16 = i*4;
            /* verilator lint_on WIDTHTRUNC */
            b0 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b1 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b2 = tmp16[8:0];
            tmp16 = tmp16 + 16'd1; b3 = tmp16[8:0];
            if (cap[i] !== {pat2(b0, 8'd44), pat2(b1, 8'd44), pat2(b2, 8'd44), pat2(b3, 8'd44)}) begin
                if (failures < 8) $display("FAIL T9: B cap[%0d] = %h want %h", i, cap[i], {pat2(b0, 8'd44), pat2(b1, 8'd44), pat2(b2, 8'd44), pat2(b3, 8'd44)});
                failures = failures + 1;
            end
        end
        dma_go = 1'b1;   // host accepts the 0x0184
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        // Phase C: READ 44 immediately after the write completed - the
        // replayed captured bytes must come back exactly
        dma_go  = 1'b0;
        use_rep = 1'b1;
        for (i = 0; i < 128; i = i + 1)
            rep[i] = cap[i];
        c0f_write(16'hC0F6, 8'd44);
        c0f_write(16'hC0F2, 8'd1);         // command = READ
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T9: C0F0 READ status = %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd1 && cmd_seen_offset == 32'd22528);
        read_cmds = read_cmds + 1;
        while (cpu_wait_hdd) @(negedge clk_14a);
        #100;
        use_rep = 1'b0;
        for (i = 0; i < 512; i = i + 1) begin
            c0f8_read(d8);
            if (d8 !== pat2(i[8:0], 8'd44)) begin
                if (failures < 8) $display("FAIL T9: C C0F8[%0d] = %0d want %0d", i, d8, pat2(i[8:0], 8'd44));
                failures = failures + 1;
            end
        end
        if (failures == 0) $display("PASS T9: READ/WRITE/READ back-to-back exact");

        // ---- T10: protect toggled between hdd_write and the arm ----
        // (WP2.5) hdd (14M) sees protect=0 and pulses hdd_write; the bridge
        // (74a) sees protect=1 and must drop the request via the
        // `else if (write_pend)` branch - no 0x0184, no walk, no stall,
        // no stale pend. The next unprotected write must work.
        hdv_protect_74 = 1'b1;   // bridge view only; hdd still sees 0
        c0f_write(16'hC0F6, 8'd46);
        for (i = 0; i < 512; i = i + 1)
            c0f8_write(patw(i[8:0]));
        c0f_write(16'hC0F2, 8'd2);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T10: C0F0 status %0d (want 0, optimistic)", st); failures = failures + 1; end
        #1000;   // the wr_rise -> pend -> drop window is ~10 machine clocks
        if (hdv_state !== 3'd0) begin $display("FAIL T10: state=%0d after protected drop (want 0=IDLE)", hdv_state); failures = failures + 1; end
        if (cpu_wait_hdd) begin $display("FAIL T10: cpu_wait asserted on a dropped write"); failures = failures + 1; end
        if (write_cmds !== 4) begin $display("FAIL T10: write_cmds=%0d (want 4: T4 + T8x2 + T9; the drop issues no 0x0184)", write_cmds); failures = failures + 1; end
        // no stale pend: the next unprotected write must arm normally
        hdv_protect_74 = 1'b0;
        c0f_write(16'hC0F6, 8'd46);
        c0f_write(16'hC0F2, 8'd2);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T10: C0F0 status %0d (want 0)", st); failures = failures + 1; end
        wait (cmd_kind == 2'd2 && cmd_seen_offset == 32'd23552);   // 46*512
        write_cmds = write_cmds + 1;
        dma_go = 1'b1;
        while (cpu_wait_hdd) @(negedge clk_14a);
        #200;
        if (failures == 0) $display("PASS T10: protected drop consumes cleanly, next write works");

        // ---- T11: write-leg host timeout (WP2.6) ----
        // A 0x0184 the host never completes must release the CPU (the 6502
        // cannot stall forever), latch the fault, and make C0F1 report 1
        // through the bridge_err override (hdd.v:338) - not the stale
        // optimistic 00 the execute committed.
        host_ignore = 1'b1;
        use_rep     = 1'b0;
        c0f_write(16'hC0F6, 8'd48);
        c0f_write(16'hC0F2, 8'd2);
        c0f_read(16'hC0F0, st);
        if (st !== 8'd0) begin $display("FAIL T11: C0F0 status %0d (want 0, write in flight)", st); failures = failures + 1; end
        // the walk_out precedes the 0x0184 arm (~36us); wait for the
        // state to reach WRITE, then confirm it is in flight
        begin : t11arm
            integer w;
            for (w = 0; w < 2000 && hdv_state !== 3'd5; w = w + 1)
                @(negedge clk_14a);
        end
        if (hdv_state !== 3'd5) begin $display("FAIL T11: state=%0d (want 5=WRITE, in flight before timeout)", hdv_state); failures = failures + 1; end
        if (!cpu_wait_hdd) begin $display("FAIL T11: cpu_wait not held during in-flight write"); failures = failures + 1; end
        begin : t11wait
            integer w;
            for (w = 0; w < 3000 && cpu_wait_hdd; w = w + 1)
                @(negedge clk_14a);
        end
        if (cpu_wait_hdd) begin $display("FAIL T11: cpu_wait still held after the timeout bound"); failures = failures + 1; end
        if (hdv_state !== 3'd0) begin $display("FAIL T11: state=%0d after timeout (want 0=IDLE)", hdv_state); failures = failures + 1; end
        if (!hdv_fault) begin $display("FAIL T11: hdv_fault not latched on a write-leg timeout"); failures = failures + 1; end
        #1000;   // bridge_err hold (15 x 74a) + 2FF sync reaches hdd
        c0f_read(16'hC0F1, st);
        if (st !== 8'h01) begin $display("FAIL T11: C0F1 after write timeout = %0d (want 1, not stale 00)", st); failures = failures + 1; end
        if (write_cmds !== 5) begin $display("FAIL T11: write_cmds=%0d (want 5: T4 + T8x2 + T9 + T10; the timeout is issued but not completed)", write_cmds); failures = failures + 1; end
        // recovery: the host answers again -> the next write completes
        // clean. The write arms the 0x0184 only AFTER its walk_out (~36us),
        // so wait for the state to reach WRITE first, then for completion.
        host_ignore = 1'b0;
        dma_go      = 1'b1;
        c0f_write(16'hC0F2, 8'd2);
        c0f_read(16'hC0F0, st);
        begin : t11rec
            integer w;
            for (w = 0; w < 2000 && hdv_state !== 3'd5; w = w + 1)
                @(negedge clk_14a);
        end
        if (hdv_state !== 3'd5) begin $display("FAIL T11: recovery write never reached the 0x0184 arm (state=%0d)", hdv_state); failures = failures + 1; end
        while (cpu_wait_hdd) @(negedge clk_14a);
        #500;
        if (hdv_fault) begin $display("FAIL T11: fault not cleared by a clean write"); failures = failures + 1; end
        if (failures == 0) $display("PASS T11: write-leg timeout releases the CPU, fault latches, clean write recovers");

        // ---- T5: host fetch never completes -> timeout releases the CPU ----
        // (the 2026-10-30 hardware hang: HDV mounted, ROM commits to the HD,
        // first C0F0 read, and the stall never ends. The timeout must bound
        // that: IDLE + fault latch + a later clean fetch clears the fault.)
        hdv_protect    = 1'b1;
        hdv_protect_74 = 1'b1;
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
        // a timed-out fetch does NOT count as completed (T1 + T6x2 + T8
        // round-trip read + T9's two reads)
        if (hdv_fetch_cnt !== 8'd6) begin $display("FAIL T5: hdv_fetch_cnt=%0d after timeout (want 6, timeout is not a completion)", hdv_fetch_cnt); failures = failures + 1; end
        // recovery: host responds again -> the next fetch completes clean
        host_ignore = 1'b0;
        dma_go      = 1'b1;
        c0f_write(16'hC0F2, 8'd1);
        c0f_read(16'hC0F0, st);
        while (cpu_wait_hdd) @(negedge clk_14a);
        #500;
        if (hdv_fault) begin $display("FAIL T5: fault not cleared by a clean fetch"); failures = failures + 1; end
        if (hdv_fetch_cnt !== 8'd7) begin $display("FAIL T5: fetch_cnt=%0d (want 7: T1 + T6x2 + T8 + T9x2 + recovery; timeout not counted)", hdv_fetch_cnt); failures = failures + 1; end
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
