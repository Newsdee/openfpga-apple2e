// HDV bridge transfer (PLAN_HDV_READONLY §4c): hardwired sector mover.
//
// Owns the 512-byte sector RAM at bridge address 0x01F01000 and the
// bridge-domain command FSM that moves whole sectors between that RAM and
// the deferload HDV data slot (id 2) via the existing 0x0180/0x0184 target
// commands. No soft CPU - a small FSM, exactly as MiSTer does it
// (Apple-II.sv:887-919).
//
// READ (6502 executes C0F0 with command=READ):
//   hdd.hdd_read pulse (14M, 1 machine clk) -> 2FF -> read_pend (74a)
//   FSM: arm 0x0180 (id=2, slotoffset=sector*512, bridgeaddr, len=512),
//   cpu_wait_hdd asserted (the top syncs it to 14M as CPU_WAIT - the 6502
//   stays stalled for the whole transfer), host DMAs 512 bytes into the
//   RAM, done edge -> 14M walker copies RAM -> hdd sector buffer (512
//   machine cycles) -> cpu_wait released.
//
// WRITE (command=WRITE): mirror image - the 14M walker first copies the
// hdd sector buffer into the RAM (hdd.ram_do is registered: 1 machine
// clock latency), then 0x0184 streams the RAM to the slot. With
// hdd_protect=1 (the read-only milestone) hdd never pulses hdd_write, so
// this path is inert but present for the write-back milestone.
//
// RAM write protocol (never concurrent, by construction):
//   - host DMA writes (74a) happen only while cpu_wait is asserted, i.e.
//     while the machine is stalled and no walker is running;
//   - the walker's writes (14M) run only between host commands, and they
//     cross into the 74a domain as (strobe, addr, data) - the RAM itself
//     has a SINGLE write clock (74a), so the array is driven by one
//     always block (Verilog forbids two drivers on one array; the
//     "always @(posedge a or posedge b)" + level-check idiom is unsafe
//     for asynchronous clocks).
//   - the FSM waits a 2-bridge-clock guard (ST_WRITE_ARM) after the
//     walk_out strobes end before arming 0x0184, so the last CDC write
//     has settled by the time the host DMA may read the RAM.
// Reads of the RAM are combinational from either domain (the contents
// are only read after the relevant write burst has completed).
//
// CDC notes: 14M->74a pulses are fine (a 1-machine-clk pulse is ~5 bridge
// clocks). The 74a->14M walk requests are therefore LEVELS, held for the
// whole walk (a 1-bridge-clk pulse is shorter than one machine clock and
// would be lost by a 2FF synchronizer ~80% of the time).
//
// The host read port (bridge reads of 0x01F01xxx, used by the 0x0184 DMA)
// is exposed as hdv_ram_word for the top-level bridge_rd mux.

module hdv_bridge #(
    // 74a-clock timeout for an in-flight host command (0x0180/0x0184).
    // If the host never completes, the FSM aborts to IDLE after this many
    // clocks (default 2^28-1 ~ 3.6 s at 74.25 MHz), releases the CPU stall,
    // and latches hdv_fault. Without this, a fetch that never completes
    // holds cpu_wait_hdd high FOREVER - a frozen machine with no recovery
    // (observed on hardware 2026-10-30: HDV mounted -> ROM commits to the
    // HD -> first C0F0 read -> stall that never ends).
    // NOTE: 28 bits max = 0x0FFFFFFF; 0x1000_0000 itself needs 29 bits.
    parameter [27:0] FETCH_TO = 28'h0FFFFFFF
) (
    input  wire        clk_74a,        // bridge clock
    input  wire        clk_14a,        // machine clock (14.318)
    input  wire        reset_n,        // bridge reset, active low (74a)

    // host bridge (74a domain)
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] hdv_ram_word,   // 0x01F01xxx read port (BE word)

    // core_bridge_cmd dataslot interface (74a) - driven here
    output reg         target_dataslot_read,
    output reg         target_dataslot_write,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,

    // slot presence (74a domain, from the top's datatable poller + 008A)
    input  wire        hdv_mounted,    // hdv slot size != 0
    input  wire        hdv_protect,    // 1 = read-only (no hdd_write expected)

    // hdd sector-buffer interface (14M domain) - to hdd.v
    output wire [8:0]  hdd_ram_addr,
    output wire [7:0]  hdd_ram_di,
    input  wire [7:0]  hdd_ram_do,
    output wire        hdd_ram_we,

    // hdd request pulses (14M domain, 1 machine clock wide)
    input  wire        hdd_read,
    input  wire        hdd_write,
    input  wire [15:0] hdd_sector,

    // machine stall request (74a domain; the top syncs to 14M for CPU_WAIT)
    output wire        cpu_wait_hdd,

    // diagnostics (74a domain; the top syncs them to the machine domain
    // for the on-screen debug line)
    output wire [2:0]  hdv_state,      // command FSM state (0 idle .. 5 write)
    output wire        hdv_fault,      // a host command timed out (until reset or a clean completion)
    output wire [7:0]  hdv_fetch_cnt,  // completed 0x0180 fetches (saturates at 255)

    // media-fault pulse to hdd.v (74a domain; the top 2FF-syncs it to 14M
    // and hdd uses it to force reg_status, so C0F1 reports a dropped or
    // timed-out fetch instead of the stale optimistic 00 from execute)
    output wire        bridge_err
);

    localparam BRIDGE_HDV_ADDR = 32'h01F01000; // RAM base (512-byte window)

    // ------------------------------------------------------------------
    // Sector RAM: 512 x 8. Single write clock (74a); async reads from
    // either domain (contents only read after the write burst completes).
    // ------------------------------------------------------------------
    reg [7:0] hdv_ram [0:511];

    // host DMA write port: a 32-bit BE word = 4 consecutive bytes (first file
    // byte in [31:24]; the core drives bridge_endian_little = 0)
    wire        host_wr_en = bridge_wr && (bridge_addr[31:12] == 20'h01F01);
    wire [6:0]  host_word  = bridge_addr[8:2];   // 0..127
    wire [8:0]  host_byte0 = {host_word, 2'b00};

    // walk_out write port (CDC'd from 14M; see below)
    reg         wo_wen;
    reg  [8:0]  wo_addr;
    reg  [7:0]  wo_data;

    always @(posedge clk_74a) begin
        if (host_wr_en) begin
            // BIG-ENDIAN: the core drives bridge_endian_little = 0, so the
            // real host writes each 32-bit word with the first file byte in
            // [31:24] and the last in [7:0]. Unpack in that order (a
            // little-endian unpack here byte-reverses every 4-byte group -
            // the "intertwined" block-0 corruption seen on hardware 2026-11-02
            // while the sim, whose emulated host hardcodes LE, masked it).
            hdv_ram[host_byte0        ] <= bridge_wr_data[31:24];
            hdv_ram[host_byte0 + 9'd1] <= bridge_wr_data[23:16];
            hdv_ram[host_byte0 + 9'd2] <= bridge_wr_data[15:8];
            hdv_ram[host_byte0 + 9'd3] <= bridge_wr_data[7:0];
        end
        if (wo_wen)
            hdv_ram[wo_addr] <= wo_data;
    end

    // host read port (74a, combinational): BE word for 0x0184 DMA reads
    wire [6:0] rd_word  = bridge_addr[8:2];
    wire [8:0] rd_byte0 = {rd_word, 2'b00};
    // BIG-ENDIAN readout, matching the write path above (bridge_endian_little
    // = 0): word[31:24] = first file byte of the group (hdv_ram[rd_byte0]),
    // word[7:0] = last (hdv_ram[rd_byte0+3]).
    assign hdv_ram_word = {hdv_ram[rd_byte0],
                           hdv_ram[rd_byte0 + 9'd1],
                           hdv_ram[rd_byte0 + 9'd2],
                           hdv_ram[rd_byte0 + 9'd3]};

    // ------------------------------------------------------------------
    // CDC: 14M -> 74a (request pulses, walk_done pulse, walk_out bytes)
    //
    // Plain 2FF pulse synchronizers saturate at 11 after the first pulse
    // (nothing clears them), which would swallow every later pulse - and
    // the walks are exactly that: one done per walk, forever. So each
    // pulse is captured into a self-clearing edge latch: the *_rise
    // output stays high ~5 bridge clocks per captured edge, which the
    // 74a FSM (sampling every bridge clock) always sees.
    // ------------------------------------------------------------------
    // self-clearing edge capture: 2FF sync + latch held 5 bridge clocks
    // (instantiated three times below via macro-style manual expansion)
    reg [1:0] rd_sync;
    reg       rd_latch;
    reg  [3:0] rd_clr;
    wire      rd_rise;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            rd_sync <= 2'b00; rd_latch <= 1'b0; rd_clr <= 4'd0;
        end else begin
            rd_sync <= {rd_sync[0], hdd_read};
            if (rd_latch) begin
                rd_clr <= rd_clr + 4'd1;
                if (rd_clr == 4'd5) begin
                    rd_latch <= 1'b0;
                    rd_clr   <= 4'd0;
                end
            end else if (rd_sync[0] && !rd_sync[1]) begin
                rd_latch <= 1'b1;
                rd_clr   <= 4'd0;
            end
        end
    end
    assign rd_rise = rd_latch;

    reg [1:0] wr_sync;
    reg       wr_latch;
    reg  [3:0] wr_clr;
    wire      wr_rise;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wr_sync <= 2'b00; wr_latch <= 1'b0; wr_clr <= 4'd0;
        end else begin
            wr_sync <= {wr_sync[0], hdd_write};
            if (wr_latch) begin
                wr_clr <= wr_clr + 4'd1;
                if (wr_clr == 4'd5) begin
                    wr_latch <= 1'b0;
                    wr_clr   <= 4'd0;
                end
            end else if (wr_sync[0] && !wr_sync[1]) begin
                wr_latch <= 1'b1;
                wr_clr   <= 4'd0;
            end
        end
    end
    assign wr_rise = wr_latch;

    reg [1:0] wd_sync;
    reg       wd_latch;
    reg  [3:0] wd_clr;
    wire      wd_rise;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wd_sync <= 2'b00; wd_latch <= 1'b0; wd_clr <= 4'd0;
        end else begin
            wd_sync <= {wd_sync[0], walk_done_14};
            if (wd_latch) begin
                wd_clr <= wd_clr + 4'd1;
                if (wd_clr == 4'd5) begin
                    wd_latch <= 1'b0;
                    wd_clr   <= 4'd0;
                end
            end else if (wd_sync[0] && !wd_sync[1]) begin
                wd_latch <= 1'b1;
                wd_clr   <= 4'd0;
            end
        end
    end
    assign wd_rise = wd_latch;

    // walk_out strobe (a full machine clock wide = ~5 bridge clocks)
    wire        wo_st_valid;
    wire [8:0]  wo_st_addr;   // 14M domain (stable for the whole strobe)
    wire [7:0]  wo_st_data;   // = hdd_ram_do, stable for the whole strobe
    reg  [1:0]  wo_st_sync;
    wire        wo_st_rise = wo_st_sync[0] & ~wo_st_sync[1];

    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wo_st_sync <= 2'b00;
            wo_wen <= 1'b0;
        end else begin
            wo_st_sync <= {wo_st_sync[0], wo_st_valid};

            // latch the byte on the strobe's rising edge (addr/data are
            // held by the 14M side for the whole machine-clock strobe)
            if (wo_st_rise) begin
                wo_wen  <= 1'b1;
                wo_addr <= wo_st_addr;
                wo_data <= wo_st_data;
            end else begin
                wo_wen <= 1'b0;
            end
        end
    end

    // CDC: 74a -> 14M (walk-request LEVELS, bridge reset)
    // Sync-only reset synchronizer: rs_sync pins to 00 while reset_n=0 and
    // walks to 11 two cycles after reset_n rises. (An async-reset clause
    // whose clear condition tests rs_sync[1] would deadlock at 00.)
    reg [1:0] qi_sync, qo_sync, rs_sync;
    wire      qi_rise = qi_sync[0] & ~qi_sync[1];
    wire      qo_rise = qo_sync[0] & ~qo_sync[1];
    wire      rst_14a = rs_sync[1];

    always @(posedge clk_14a) begin
        qi_sync <= {qi_sync[0], walk_in_req_74};
        qo_sync <= {qo_sync[0], walk_out_req_74};
        rs_sync <= {rs_sync[0], reset_n};
    end

    // ------------------------------------------------------------------
    // 14M domain: sector-buffer walkers (512 machine cycles each)
    // ------------------------------------------------------------------
    // walk_in:  RAM -> hdd sector buffer. hdd latches (ram_we, ram_addr,
    // ram_di) on its posedge: with we high and addr=cnt_i during cycle P,
    // hdd writes sector_buf[cnt_i] <= ram[cnt_i] at P. Bytes 0..511 are
    // latched at the first 512 posedges of the walk.
    // walk_out: hdd sector buffer -> RAM. 2-phase per byte: phase 0
    // presents addr=k to hdd (ram_do becomes buf[k] one clock later),
    // phase 1 (the gap) strobes (k, buf[k]) to the 74a side. One strobe
    // pulse per byte with a full machine-clock gap between pulses, so
    // the 74a 2FF can clear between bytes (a continuous level across the
    // whole walk would give a single rising edge and one byte).
    reg  [9:0] cnt_i;   // 0..512
    reg  [10:0] cnt_o2;  // 0..1024 (512 bytes x 2 phases; 11 bits - 1024
                         // does not fit in 10 bits, and 10'd1024 truncates
                         // to 0, killing the counter)

    always @(posedge clk_14a or negedge rst_14a) begin
        if (!rst_14a) begin
            cnt_i  <= 10'd0;
            cnt_o2 <= 11'd0;
        end else begin
            // gated by the request level: no free-running from reset (a
            // phantom walk would saturate wd_sync and swallow the real
            // walk's done pulse)
            if (qi_rise)
                cnt_i <= 10'd0;
            else if (qi_sync[1] && cnt_i < 10'd512)
                cnt_i <= cnt_i + 10'd1;

            if (qo_rise)
                cnt_o2 <= 11'd0;
            else if (qo_sync[1] && cnt_o2 < 11'd1024)
                cnt_o2 <= cnt_o2 + 11'd1;
        end
    end

    // Request-QUALIFIED active flag: cnt_i parks at 0 between walks, so an
    // unqualified (cnt_i < 512) would hold hdd_ram_we HIGH at idle, clobbering
    // sector_buf[0] with hdv_ram[0] every 14M cycle. The counter only runs
    // while the request level is present, and the flag must too.
    wire walk_in_active = qi_sync[1] && (cnt_i < 10'd512);
    wire [9:0] wo_byte  = cnt_o2[10:1];   // byte index 0..511

    // walk_out strobe: the gap phase, once per byte, data valid (byte 0's
    // gap is cnt_o2=1: hdd latched ram_do=buf[0] at the end of the
    // cnt_o2=0 present phase)
    assign wo_st_valid = cnt_o2[0] & (cnt_o2 < 11'd1024);
    assign wo_st_addr  = wo_byte[8:0];
    assign wo_st_data  = hdd_ram_do;

    // one 14M-clock done pulse per completed walk: walk_in fires on the
    // last increment (511 -> 512); walk_out fires on the last gap (1023).
    // Not while the counters park (a parked level would hold wd_sync
    // saturated and swallow later walks' done edges - the FSM serializes
    // walks, so an edge within two bridge clocks is unreachable)
    reg walk_done_14;
    always @(posedge clk_14a or negedge rst_14a) begin
        if (!rst_14a)
            walk_done_14 <= 1'b0;
        else
            walk_done_14 <= (cnt_i == 10'd511) || (cnt_o2 == 11'd1023);
    end
    // hdd port drives (walk_in owns the buffer ports; walk_out presents
    // its read address during both phases of each byte)
    assign hdd_ram_addr = walk_in_active ? cnt_i[8:0] : wo_byte[8:0];
    assign hdd_ram_we   = walk_in_active;
    assign hdd_ram_di   = hdv_ram[cnt_i[8:0]];

    // ------------------------------------------------------------------
    // 74a domain: command FSM
    // ------------------------------------------------------------------
    localparam ST_IDLE     = 3'd0;
    localparam ST_FETCH    = 3'd1;   // 0x0180 in flight
    localparam ST_WALK_IN  = 3'd2;   // RAM -> hdd walk in progress
    localparam ST_WALK_OUT = 3'd3;   // hdd -> RAM walk in progress
    localparam ST_ARM_WRITE= 3'd4;   // guard: last walk_out CDC writes settle
    localparam ST_WRITE    = 3'd5;   // 0x0184 in flight

    reg  [2:0] state;
    reg        read_pend, write_pend;
    reg  [31:0] offset_q;
    reg        walk_in_req_74, walk_out_req_74;   // levels (see CDC note)
    reg        done_d;
    wire       done_rise = target_dataslot_done & ~done_d;

    // command timeout + fault + fetch count (see FETCH_TO parameter)
    reg  [27:0] to_cnt;
    reg        fault;
    reg [7:0]  fetch_cnt;
    wire       in_host_cmd = (state == ST_FETCH) || (state == ST_WRITE);
    wire       to_fire = in_host_cmd && (to_cnt == FETCH_TO - 28'd1);

    // bridge_err hold: a drop or timeout sets the hold to 15 x 74a cycles
    // (~202 ns = ~3 machine clocks, so the 2FF in the top always samples a
    // full high window - a bare 1-cycle 74a pulse would be missed by the
    // 14M sampler most of the time). bridge_err is the level while held.
    reg  [3:0] err_hold_74;
    wire       drop_evt = (state == ST_IDLE) && read_pend && !hdv_mounted;
    assign bridge_err = (err_hold_74 != 4'd0);

    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            state <= ST_IDLE;
            read_pend <= 1'b0;
            write_pend <= 1'b0;
            target_dataslot_read <= 1'b0;
            target_dataslot_write <= 1'b0;
            walk_in_req_74 <= 1'b0;
            walk_out_req_74 <= 1'b0;
            done_d <= 1'b0;
            to_cnt <= 28'd0;
            fault <= 1'b0;
            fetch_cnt <= 8'd0;
            err_hold_74 <= 4'd0;
            target_dataslot_id <= 16'd0;
            target_dataslot_slotoffset <= 32'd0;
            target_dataslot_bridgeaddr <= 32'd0;
            target_dataslot_length <= 32'd0;
        end else begin
            done_d <= target_dataslot_done;

            // one-clock command pulses
            target_dataslot_read  <= 1'b0;
            target_dataslot_write <= 1'b0;

            // walk requests are levels, held for the whole walk
            walk_in_req_74  <= (state == ST_WALK_IN);
            walk_out_req_74 <= (state == ST_WALK_OUT);

            // timeout counter: runs only while a host command is in flight;
            // saturates at the bound so to_fire stays a clean one-shot per
            // entry (the fire branch drops the state to IDLE next cycle).
            if (in_host_cmd)
                to_cnt <= (to_cnt == FETCH_TO - 28'd1) ? to_cnt : to_cnt + 28'd1;
            else
                to_cnt <= 28'd0;

            if (to_fire || drop_evt)
                err_hold_74 <= 4'd15;
            else if (err_hold_74 != 4'd0)
                err_hold_74 <= err_hold_74 - 4'd1;

            if (to_fire) begin
                state <= ST_IDLE;      // release the CPU; the fault is reported
                fault <= 1'b1;
            end else begin
            case (state)
                ST_IDLE: begin
                    // capture requests only here: the 6502 is stalled by
                    // cpu_wait during any transfer, so no C0F0 (and no
                    // hdd_read/hdd_write pulse) can arrive mid-transfer.
                    // Capturing in other states would let the ~5-clock
                    // self-clearing latch re-set the pending bit after the
                    // first transfer consumed it (phantom re-arm).
                    if (rd_rise) read_pend  <= 1'b1;
                    if (wr_rise) write_pend <= 1'b1;

                    if (read_pend && hdv_mounted) begin
                        read_pend <= 1'b0;
                        // parameters are latched at arm time (the host
                        // samples them when the command starts)
                        target_dataslot_id         <= 16'd2;   // HDV slot
                        target_dataslot_slotoffset <= {16'd0, hdd_sector} << 9;
                        target_dataslot_bridgeaddr <= BRIDGE_HDV_ADDR;
                        target_dataslot_length     <= 32'd512;
                        target_dataslot_read       <= 1'b1;
                        state <= ST_FETCH;
                    end else if (read_pend) begin
                        read_pend <= 1'b0;          // not mounted: drop
                    end else if (write_pend && hdv_mounted && !hdv_protect) begin
                        write_pend <= 1'b0;
                        target_dataslot_id         <= 16'd2;
                        target_dataslot_bridgeaddr <= BRIDGE_HDV_ADDR;
                        target_dataslot_length     <= 32'd512;
                        // slotoffset latched after the walk (the walk does
                        // not change the sector registers)
                        offset_q <= {16'd0, hdd_sector} << 9;
                        state <= ST_WALK_OUT;
                    end else if (write_pend) begin
                        write_pend <= 1'b0;         // protected/not mounted
                    end
                end

                ST_FETCH: begin
                    if (done_rise) begin
                        if (target_dataslot_err == 3'd0) begin
                            state <= ST_WALK_IN;    // req level auto-asserts
                            fault <= 1'b0;          // channel is healthy again
                            if (fetch_cnt != 8'd255)
                                fetch_cnt <= fetch_cnt + 8'd1;
                        end else
                            state <= ST_IDLE;       // abort: err stays readable
                    end
                end

                ST_WALK_IN: begin
                    if (wd_rise)
                        state <= ST_IDLE;           // req level auto-drops
                end

                ST_WALK_OUT: begin
                    if (wd_rise)
                        state <= ST_ARM_WRITE;
                end

                ST_ARM_WRITE: begin
                    // two-bridge-clock guard: the last walk_out bytes are
                    // still landing through the CDC when wd_rise fires
                    state <= ST_WRITE;
                    target_dataslot_slotoffset <= offset_q;
                    target_dataslot_write <= 1'b1;
                end

                ST_WRITE: begin
                    if (done_rise) begin
                        if (target_dataslot_err == 3'd0)
                            fault <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
            end   // to_fire else
        end
    end

    // stall the 6502 across the whole transfer (both directions)
    assign cpu_wait_hdd = (state != ST_IDLE);

    assign hdv_state     = state;
    assign hdv_fault     = fault;
    assign hdv_fetch_cnt = fetch_cnt;

endmodule
