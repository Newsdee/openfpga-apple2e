// tb_hdv_ab.sv - A/B differential: FF-array hdv_bridge (b5a3881) vs
// M10K-lane hdv_bridge (87e05b7) through the SHIPPING host read path.
//
// Per the 2026-11-21 expert instruction:
//   - compare b5a3881 vs 87e05b7 through the shipping HDV mux and the
//     REAL APF peripheral (io_bridge_peripheral, verbatim), identical
//     tagged data, identical host transactions, identical scoreboard:
//     129 reads, discard one, verify all 128 retained words, no tail
//     reads.
//   - do NOT insert the command-window register (core_bridge_cmd's
//     bridge_rd_data_out): the shipping 0x01F01xxx mux arm selects the
//     HDV word directly; only the 0xF8xxxxxx arm goes through the
//     command block. The HDV path's stages are its own prime stage
//     plus the PMP peripheral's sample-before-strobe buffer.
//   - find the FIRST WRONG WORD rather than assuming variable latency.
//
// Build A: this TB + hdv_bridge.sv extracted from b5a3881 (FF array).
// Build B: this TB + hdv_bridge.sv from the current tree (M10K lanes).
// hdd.v, io_bridge_peripheral, common.v (synch_3) and altsyncram_sim
// are byte-identical between the two trees (verified in the run script),
// so they come from the working tree in both builds.
//
// The DUT module name is `hdv_bridge` in both builds, hence two builds
// and a transcript diff, not one two-DUT bench.
//
// Host protocol (from the real io_bridge_peripheral, not a shortcut):
//   * one SS pulse starts each transaction (if(phy_spiss_s) -> ST_RESET
//     -> ST_ADDR_0); the host then clocks 4 address bytes (2 bits/edge,
//     MSB-first, spiclk rising);
//   * for a read, the peripheral delays 3 cycles (read_cnt), SAMPLES the
//     current pmp_rd_data, then asserts pmp_rd for one cycle (ST_READ_1)
//     and clocks the sampled word out over SPI (16 rising edges);
//   * so the word delivered for host read N is the value the core's port
//     held in the gap AFTER read N-1's strobe ("reads are buffered by 1
//     word", the framework-documented prime). The scoreboard models the
//     framework exactly: 129 reads at words 0..128, discard sample 0,
//     keep samples 1..128.
//
// Machine side: the REAL hdd.v + a fake 6502 (ported from
// tb_hdv_bridge.sv) performs C0F8 sector writes so the DUT's walk_out
// + 0x0184 arm run for real.
//
// Burst matrix (identical both trees): COLD-88 (first write after
// reset), WARM-88, WARM-32, WARM-16 - the last two tighten the host
// inter-transaction turnaround (the PMP needs ~30+ cycles between the
// end of a data TX and the next SS to be back in ST_ADDR_0; 16 tests
// the floor, 88 is the framework's documented worst case).
//
// Scoreboard per burst: retained word j must equal tag(j); report the
// FIRST wrong word (index, decoded tag index, offset k), the full k
// histogram, and the strobe count (must be exactly 129 - no tail
// reads).
//
// Build: pure self-driving TB (verilator --binary --timing), CWD = repo root.

`timescale 1ns/1ps
module tb_hdv_ab;

    // ================= clocks (proven pattern) =================
    reg clk_74a = 1'b0, clk_14a = 1'b0;
    initial begin
        forever #6.733 clk_74a = ~clk_74a;
    end
    initial begin
        forever #34.921 clk_14a = ~clk_14a;
    end

    reg reset_n_r = 1'b0;
    always @(posedge clk_74a) begin
        if (reset_n_r == 1'b0 && clk_74a) reset_n_r <= 1'b1;
    end
    wire reset_n = reset_n_r;

    // ================= DUT: hdv_bridge (this build's tree) ============
    // Host-side control connects DIRECTLY from the PMP (shipping wiring,
    // apf_top_apple2.v lines 361-365: pmp_addr->bridge_addr,
    // pmp_rd->bridge_rd, pmp_wr->bridge_wr, pmp_wr_data->bridge_wr_data -
    // no intervening decode stage on the HDV path).
    wire [31:0] hdv_ram_word;
    wire        ds_read, ds_write;
    reg         ds_done = 1'b0;
    wire [15:0] ds_id;
    wire [31:0] ds_off, ds_addr, ds_len;
    wire        cpu_wait_hdd;
    wire [2:0]  hdv_state;
    wire        hdv_fault;
    wire [7:0]  hdv_fetch_cnt, hdv_wrcnt, hdv_oobcnt;
    wire        bridge_err;
    reg         hdv_mounted = 1'b0;
    reg         hdv_protect = 1'b1;

    hdv_bridge u_dut (
        .clk_74a            ( clk_74a ),
        .clk_14a            ( clk_14a ),
        .reset_n            ( reset_n ),
        .bridge_rd          ( pmp_rd ),
        .bridge_wr          ( pmp_wr ),
        .bridge_addr        ( pmp_addr ),
        .bridge_wr_data     ( pmp_wr_data ),
        .hdv_ram_word       ( hdv_ram_word ),
        .target_dataslot_read   ( ds_read ),
        .target_dataslot_write  ( ds_write ),
        .target_dataslot_done   ( ds_done ),
        .target_dataslot_err    ( 3'd0 ),
        .target_dataslot_id     ( ds_id ),
        .target_dataslot_slotoffset ( ds_off ),
        .target_dataslot_bridgeaddr ( ds_addr ),
        .target_dataslot_length     ( ds_len ),
        .hdv_mounted        ( hdv_mounted ),
        .hdv_protect        ( hdv_protect ),
        .hdd_ram_addr       ( hdd_ram_addr ),
        .hdd_ram_di         ( hdd_ram_di ),
        .hdd_ram_do         ( hdd_ram_do ),
        .hdd_ram_we         ( hdd_ram_we ),
        .hdd_read           ( hdd_read ),
        .hdd_write          ( hdd_write ),
        .hdd_sector         ( hdd_sector ),
        .cpu_wait_hdd       ( cpu_wait_hdd ),
        .hdv_state          ( hdv_state ),
        .hdv_fault          ( hdv_fault ),
        .hdv_fetch_cnt      ( hdv_fetch_cnt ),
        .hdv_wrcnt          ( hdv_wrcnt ),
        .hdv_oobcnt         ( hdv_oobcnt ),
        .bridge_err         ( bridge_err )
    );

    // ================= real hdd.v + fake 6502 (14a) ==================
    wire [8:0]  hdd_ram_addr;
    wire [7:0]  hdd_ram_di, hdd_ram_do;
    wire        hdd_ram_we;
    wire        hdd_read, hdd_write;
    wire [15:0] hdd_sector;
    wire        hdd_mnt = 1'b1;
    wire        hdd_prot_14;
    // hdd.v gates hdd_write on !hdd_protect; mirror the 74a option
    // (the existing TB drives both views of the one option).
    assign hdd_prot_14 = hdv_protect;

    hdd u_hdd (
        .CLK_14M        ( clk_14a ),
        .IO_SELECT      ( 1'b0 ),
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
        .hdd_protect    ( hdd_prot_14 ),
        .bridge_fault   ( bridge_err ),
        .ram_addr       ( hdd_ram_addr ),
        .ram_di         ( hdd_ram_di ),
        .ram_do         ( hdd_ram_do ),
        .ram_we         ( hdd_ram_we )
    );

    // PHASE-LOCKED bus protocol (ported from tb_hdv_bridge): bus changes
    // on clk_14a negedges only, so every DUT posedge samples a stable bus.
    reg         cpu_rst = 1'b1;
    reg         cpu_ds  = 1'b0;
    reg         cpu_rd  = 1'b0;
    reg  [15:0] cpu_a   = 16'd0;
    reg  [7:0]  cpu_din = 8'd0;
    wire [7:0]  cpu_dout;

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
            @(negedge clk_14a);
            d = cpu_dout;
            cpu_ds = 1'b0; cpu_rd = 1'b0;
        end
    endtask

    // ================= real PMP peripheral + shipping HDV mux ========
    // The physical SPI bus is one wire, one driver at a time (protocol
    // guarantee). io_bridge_peripheral's three phy ports are inout in the
    // shipping source; for two-state simulation they are split into
    // sample(in)/drive(out) pairs by the generated wrapper ibs_phy_split.v
    // (body verbatim from src/fpga/apf/io_bridge_peripheral.v - the run
    // script regenerates it and diff-checks the body). The physical line
    // = host drive when the host is clocking, else the core drive.
    wire        pmp_rd, pmp_wr, pmp_addr_valid;
    wire [31:0] pmp_addr, pmp_wr_data, pmp_rd_data;
    reg         h_ss = 1'b0;
    reg         h_active = 1'b0;
    reg         h_sclk = 1'b0, h_mosi = 1'b0, h_miso = 1'b0;
    wire        c_sclk, c_mosi, c_miso;

    // Shipping HDV mux arm, verbatim from apf_stream_video_top.v:
    //   32'h01F01xxx: bridge_rd_data <= hdv_ram_word;
    // (combinational always @(*); the other arms are never addressed by
    //  this TB, so the HDV arm selects the HDV word directly - NO command
    //  window register in this path, exactly as it ships.)
    assign pmp_rd_data = (pmp_addr[31:12] == 20'h01F01) ? hdv_ram_word
                                                        : 32'd0;

    io_bridge_peripheral_phy u_pmp (
        .clk            ( clk_74a ),
        .reset_n        ( reset_n ),
        .endian_little  ( 1'b0 ),
        .pmp_addr       ( pmp_addr ),
        .pmp_addr_valid ( pmp_addr_valid ),
        .pmp_rd         ( pmp_rd ),
        .pmp_rd_data    ( pmp_rd_data ),
        .pmp_wr         ( pmp_wr ),
        .pmp_wr_data    ( pmp_wr_data ),
        .phy_spiclk_in  ( muxclk_dbg ),
        .phy_spimosi_in ( muxmosi_dbg ),
        .phy_spimiso_in ( muxmiso_dbg ),
        .phy_spiss      ( h_ss ),
        .phy_spiclk_out ( c_sclk ),
        .phy_spimosi_out( c_mosi ),
        .phy_spimiso_out( c_miso )
    );

    // host inter-transaction turnaround (74a cycles between the end of a
    // data TX and the next SS pulse); the burst matrix varies it.
    integer host_gap = 88;

    // ================= host SPI engine (the APF chip model) ===========
    // Address phase: 2 bits per rising edge (miso = upper bit, per the
    // peripheral's rx_dat[7:6] <= {phy_spimosi, phy_spimiso}), 4 edges
    // per byte, bytes MSB-first: addr[31:24], [23:16], [15:8],
    // {addr[7:2], 2'b00, RW}. Host spiclk edge pair every 2 74a cycles -
    // comfortably above the peripheral's ~6-cycle per-byte rx pipeline.
    task host_tx_byte(input [7:0] by);
        integer k;
        begin
            repeat (2) @(negedge clk_74a);
            for (k = 3; k >= 0; k = k - 1) begin
                // PMP RX: rx_dat[7:6] <= {phy_spimosi, phy_spimiso} - the
                // spimosi line carries the UPPER bit of each pair.
                h_mosi = by[2*k+1];
                h_miso = by[2*k];
                @(negedge clk_74a);
                h_sclk = 1'b1;      // rising: the peripheral latches
                @(negedge clk_74a);
                h_sclk = 1'b0;
                @(negedge clk_74a);
            end
        end
    endtask

    // One read transaction: SS pulse, 4 address bytes, capture the core's
    // 16-edge data TX (the word the peripheral SAMPLED before strobing).
    task host_read(input [31:0] addr, output [31:0] cap);
        integer k;
        reg [7:0] ab;
        begin
            cap = 32'd0;
            // SS: the peripheral resets on phy_spiss high (if(phy_spiss_s)
            // -> ST_RESET -> ST_ADDR_0). 2-cycle pulse + settle.
            h_active = 1'b0;
            h_ss     = 1'b1;
            repeat (2) @(negedge clk_74a);
            h_ss     = 1'b0;
            repeat (10) @(negedge clk_74a);   // > synch_3 + ST_RESET->ADDR_0
            // address, MSB-first
            h_active = 1'b1;
            h_sclk   = 1'b0;
            ab = addr[31:24]; host_tx_byte(ab);
            ab = addr[23:16]; host_tx_byte(ab);
            ab = addr[15: 8]; host_tx_byte(ab);
            ab = {addr[7:2], 2'b00}; host_tx_byte(ab);  // bit0 = 0 = READ
            h_active = 1'b0;   // release the bus; the core now drives it
            // Wait for the core's data TX: line goes High (ST_SEND_N),
            // Low (ST_SEND_0, pair 0 loaded), then 16 rising edges.
            @(posedge c_sclk);          // ST_SEND_N: line 0->1
            @(negedge c_sclk);          // ST_SEND_0: line 1->0, pair 0 out
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge c_sclk);      // each ST_SEND_1 rising: one pair
                cap[31 - 2*k] = c_mosi;
                cap[30 - 2*k] = c_miso;
            end
            // ST_SEND_2/3 keep the line High until spis returns to idle
            // (ST_IDLE sets it Z->0); wait for the fall, then the gap.
            @(negedge c_sclk);
            repeat (host_gap) @(negedge clk_74a);
        end
    endtask

    // ================= scoreboard =====================================
    // The machine writes tagb(i) per BYTE (tagb below): C0/DE/value/value
    // with the value bytes holding the BYTE index. So window word j =
    // {byte 4j, 4j+1, 4j+2, 4j+3} = 0xC0DE (4j+2) (4j+3), byte 4j at the
    // MSB. tagw() must match that (it once used word index j for the
    // value bytes - wrong vs tagb() - which made every DUT read look
    // "off by 4 words"). C0DE catches cross-burst contamination.
    function [31:0] tagw(input [7:0] j);
        reg [8:0] b2, b3;
        begin
            b2 = 9'd4 * j + 9'd2;
            b3 = 9'd4 * j + 9'd3;
            tagw = {8'hC0, 8'hDE, b2[7:0], b3[7:0]};
        end
    endfunction

    // sector byte i = byte (i[1:0]) of tag word (i[8:2])
    function [7:0] tagb(input [8:0] i);
        case (i[1:0])
            2'd0:   tagb = 8'hC0;
            2'd1:   tagb = 8'hDE;
            2'd2:   tagb = i[7:0];
            2'd3:   tagb = i[7:0];
            default: tagb = 8'h00;
        endcase
    endfunction

    reg  [31:0] kept [0:127];
    integer bad_first;
    integer bad_n;
    integer strobes;
    integer khist [0:8];   // k = -4..+4
    integer k_other;

    task scoreboard(input string name, input [6:0] sector_id);
        integer j;
        integer kraw;
        integer kdelta;
        reg [31:0] w;
        begin
            $display("== %0s (sector %0d) ==", name, sector_id);
            bad_first = -1;
            bad_n     = 0;
            strobes   = 0;
            k_other   = 0;
            for (j = 0; j < 9; j = j + 1) khist[j] = 0;
            // 129 reads at words 0..128 (model B, the framework convention
            // confirmed on silicon 2026-11-08); sample 0 is discarded.
            for (j = 0; j <= 128; j = j + 1) begin
                host_read(32'h01F01000 + j*4, w);
                strobes = strobes + 1;
                if (j >= 1) kept[j-1] = w;
            end
            if (strobes != 129)
                $display("FAIL %0s: strobes = %0d (want exactly 129 - no tail reads)",
                         name, strobes);
            // verify the 128 retained words; find the FIRST wrong word
            for (j = 0; j < 128; j = j + 1) begin
                w      = kept[j];
                kraw   = -100;   // untagged sentinel
                // value bytes are (4t+2, 4t+3): decode the tag index t
                if (w[31:16] === 16'hC0DE &&
                    w[7:0] % 4'd4 == 3'd3 &&
                    w[15:8] === w[7:0] - 8'd1)
                    kraw = {24'b0, (w[7:0] - 8'd3) >> 2};
                if (w !== tagw(j[7:0])) begin
                    kdelta = kraw - j;
                    if (kraw >= 0 && kdelta >= -4 && kdelta <= 4)
                        khist[kdelta + 4] = khist[kdelta + 4] + 1;
                    else
                        k_other = k_other + 1;
                    if (bad_first < 0) begin
                        bad_first = j;
                        if (j == 0)
                            $display("  head kept word: 0x%08X (decodes to tag %0d)", w, kraw);
                        $display("  FIRST WRONG WORD j=%0d: got 0x%08X want 0x%08X (tag %0d, offset k=%0d)",
                                 j, w, tagw(j[7:0]), j[7:0], kdelta);
                    end
                    bad_n = bad_n + 1;
                    if (j == bad_first + 1)
                        $display("  word j=%0d is GOOD again (tag %0d, k=%0d) - k changed mid-burst",
                                 j, j[7:0], kdelta);
                end
            end
            if (bad_n == 0 && strobes == 129)
                $display("BURST %0s: PASS (128/128 retained words exact, 129 strobes, wrcnt=%0d oobcnt=%0d)",
                         name, hdv_wrcnt, hdv_oobcnt);
            else begin
                $display("  kept[0..7]  = %08X %08X %08X %08X %08X %08X %08X %08X",
                         kept[0], kept[1], kept[2], kept[3],
                         kept[4], kept[5], kept[6], kept[7]);
                $display("  kept[8..15] = %08X %08X %08X %08X %08X %08X %08X %08X",
                         kept[8], kept[9], kept[10], kept[11],
                         kept[12], kept[13], kept[14], kept[15]);
                $display("BURST %0s: FAIL bad=%0d first_bad=%0d khist(k-4..+4)=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d other=%0d wrcnt=%0d oobcnt=%0d",
                         name, bad_n, bad_first,
                         khist[0], khist[1], khist[2], khist[3], khist[4],
                         khist[5], khist[6], khist[7], khist[8],
                         k_other, hdv_wrcnt, hdv_oobcnt);
            end
        end
    endtask

    // ================= machine-side sector write ======================
    // One 0x0184 flow, machine half: set sector regs, C0F8 x512 (the full
    // tag byte stream), C0F2=2, C0F0 execute. hdd.v pulses hdd_write; the
    // DUT walks and arms 0x0184. The host waits for the arm (the real
    // framework does too - the 0.3.5 byte-exact silicon result proves the
    // first kept word is window(0), i.e. reads land after the arm). The
    // host data phase (scoreboard) runs while the DUT holds ST_WRITE; the
    // host sends done afterwards (host_done).
    task machine_write_sector(input [6:0] sector);
        integer i;
        reg [7:0] st;
        begin
            c0f_write(16'hC0F6, {1'b0, sector[6:0]});
            c0f_write(16'hC0F7, 8'd0);
            for (i = 0; i < 512; i = i + 1)
                c0f8_write(tagb(i[8:0]));
            c0f_write(16'hC0F2, 8'd2);          // command = WRITE
            c0f_read(16'hC0F0, st);
            if (st !== 8'd0)
                $display("NOTE: C0F0 WRITE status = %0d (want 0)", st);
            // wait for the 0x0184 arm pulse (the walk is ~1024 machine
            // cycles; the arm comes only after all 512 CDC writes commit)
            while (!ds_write) @(posedge clk_74a);
            $display("  (arm t=%0t: id=%0d off=%0d len=%0d)", $time, ds_id, ds_off, ds_len);
        end
    endtask

    // host: command done after the data phase; wait for the DUT to
    // return to IDLE.
    task host_done();
        begin
            ds_done = 1'b1;
            repeat (8) @(posedge clk_74a);
            ds_done = 1'b0;
            repeat (20) @(posedge clk_74a);
        end
    endtask

    // ================= sequence =======================================
    initial begin
        // ---- reset & mount ----
        @(posedge clk_74a);
        if (!reset_n) wait (reset_n);
        repeat (8) @(negedge clk_14a);
        cpu_rst     = 1'b0;
        c0f_write(16'hC0F3, 8'h70);        // unit number (hdd.v requires it)
        hdv_mounted = 1'b1;
        hdv_protect = 1'b0;
        repeat (20) @(posedge clk_74a);
        $display("HDV AB harness start");

        // ---- B0: COLD, worst-case 88-cycle turnaround ----
        host_gap = 88;
        machine_write_sector(7'd10);
        scoreboard("B0 COLD-88", 7'd10);
        host_done();

        // ---- B1: WARM, 88 ----
        host_gap = 88;
        machine_write_sector(7'd20);
        scoreboard("B1 WARM-88", 7'd20);
        host_done();

        // ---- B2: WARM, 32 ----
        host_gap = 32;
        machine_write_sector(7'd30);
        scoreboard("B2 WARM-32", 7'd30);
        host_done();

        // ---- B3: WARM, 16 (near the protocol floor) ----
        host_gap = 16;
        machine_write_sector(7'd40);
        scoreboard("B3 WARM-16", 7'd40);
        host_done();

        $display("HDV AB DONE");
        $finish;
    end

    // Faithful single-net model: the phy lines are ONE net on the real
    // chip; the RX input sees whoever is driving it (host during
    // address/write, the PMP itself during its data TX). The PMP's RX
    // therefore self-triggers on its own 16 TX edges (4 spurious bytes),
    // but the state machine sits in ST_READ_3 ("exited upon new
    // transaction") during the TX and ignores rx_byte_done there, and the
    // host's turnaround (>=16 clk) flushes the 3-stage synchronizer long
    // before the next SS - so the spurious pulses never reach ST_ADDR_0.
    // (Both builds see identical treatment; the host protocol and the
    // PMP are unchanged between them - only the hdv_bridge RAM backend
    // differs, which is the variable under test.)
    wire muxclk_dbg = h_active ? h_sclk  : c_sclk;
    wire muxmosi_dbg = h_active ? h_mosi  : c_mosi;
    wire muxmiso_dbg = h_active ? h_miso  : c_miso;

    // STAGE-PROBE (default OFF; set STAGE_PROBE=1 to re-measure the DUT's
    // host-facing output + address at every PMP sample/strobe - this is
    // how the root cause was found). Ports only - identical in both DUT
    // builds; internals differ.
    localparam STAGE_PROBE = 0;
    integer dbg_seq = 0;
    reg [31:0] dbg_addr;
    reg [31:0] dbg_word;
    reg [6:0]  dbg_rdw;
    always @(posedge clk_74a) begin
        dbg_addr = u_dut.bridge_addr;
        dbg_word = u_dut.hdv_ram_word;
        dbg_rdw  = dbg_addr[8:2];
        if (STAGE_PROBE) begin
            if (u_pmp.state == 5'd2 && u_pmp.read_cnt == 7'd3 && dbg_seq < 140) begin
                dbg_seq = dbg_seq + 1;
                $display("SP %03d t=%0t rdw=%0d pmp_rd=%b out=0x%08X",
                         dbg_seq, $time, dbg_rdw, u_pmp.pmp_rd, dbg_word);
            end
            if (u_dut.bridge_rd && dbg_seq <= 140)
                $display("  STROBE t=%0t rdw=%0d out=0x%08X", $time, dbg_rdw, dbg_word);
        end
    end
    initial begin
        #3_000_000;
        $display("FAIL: watchdog timeout");
        $finish;
    end

endmodule
