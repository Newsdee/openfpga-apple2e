// sdram_woz_transport_mb.v - machine-domain WOZ block transport, MULTI-BLOCK
// burst service (PLAN_WOZ_GS_MULTIBLOCK step 3)
//
// Companion to sdram_woz_transport.v (0.4.4 single-block service; unchanged).
// This module plays the same host role the MiSTer hps_io plays for the
// ported woz_floppy_controller: one engine request (sd_rd + sd_lba +
// sd_blk_cnt) is answered with up to 32 consecutive 512-byte blocks inside
// ONE sd_ack window.
//
// Protocol (vs the single-block service):
//   * Accept: latch base LBA + blocks-minus-one (sd_blk_cnt) while ACK low.
//   * Block 0: fetch via sdram_sector_fetch (edge-triggered, one
//     outstanding), raise ACK before delivering byte 0.
//   * Stream 512 bytes/block: sd_buff_wr strobe per byte,
//     sd_buff_addr = {block_in_request[4:0], byte_in_sector[8:0]}.
//   * Between blocks (S_GAP): ACK stays HIGH, sd_buff_wr LOW. Release the
//     frozen window (sector_done), wait for the fetcher to drain
//     (fetch_busy low), then re-arm fetch_req with the next LBA (fresh
//     0->1 edge - the fetcher's acceptance is EDGE-based).
//   * Last block: S_HOLD (3 cycles, same as single-block) then S_RELEASE -
//     ACK falls ONCE per burst (the engine's transfer-complete).
//   * sd_rd dropping after grant is NORMAL (the engine re-asserts only while
//     ACK low) - never an abort. Only drive_active falling aborts.
//
// Mid-burst faults (service rejects block N>0, i.e. a whole sector beyond
// EOF): the burst ends deterministically as a short answer - no window is
// published on a fault, so no stale bytes can be delivered; ACK falls after
// the last delivered block, oor_fault latches (transport_fault -> lifecycle
// unmount invalidates the engine before the partial transfer can become a
// usable track). A fault on the FIRST block never ACKs (same as 0.4.4).
// Partial-EOF tail sectors are zero-padded BY THE FETCHER (not a fault) and
// complete the burst normally.
//
// OOR at acceptance: sd_lba[31:16] != 0, or base+blocks exceeding 16-bit
// sector space (widened 17-bit sum before narrowing) -> oor_fault, no ACK.
//
// No HDV, APF target-command, SDRAM-arbitration, or second-buffer changes
// (plan step 3 scope).
//
`timescale 1ns/1ps
module sdram_woz_transport_mb (
    input  wire        clk,            // 14.318 MHz machine clock
    input  wire        rst_n,

    // ---- WOZ engine side (single drive, read-only service) ----
    input  wire        sd_rd,          // engine: read request (level, waits for ACK)
    input  wire [31:0] sd_lba,         // engine: first 512-byte sector of the burst
    input  wire [5:0]  sd_blk_cnt_in,  // engine: blocks-1 for this request (level)
    output reg         sd_ack,         // host: grant (high for the whole burst)
    input  wire        sd_wr,          // engine: write request = invariant fault
    output wire [13:0] sd_buff_addr,   // host: {block_in_request[4:0], byte[8:0]}
    input  wire [7:0]  sd_buff_din,    // engine: save data (unused, read-only)
    output wire [7:0]  sd_buff_dout,   // host: byte read by engine (frozen window)
    output wire        sd_buff_wr,     // host: per-byte strobe (1 cycle/byte, low in gaps)

    // ---- Unit-2 sector service (same clock domain) ----
    output reg         fetch_req,
    output reg  [15:0] fetch_lba,
    input  wire        fetch_busy,
    input  wire        sector_ready,
    input  wire [15:0] sector_lba,     // lba of the published window (fetcher)
    input  wire [7:0]  sector_byte_data,
    input  wire        fetch_fault,
    output wire [8:0]  sector_byte_addr,
    output reg         sector_done,

    // ---- mount gating + fault status ----
    input  wire        drive_active,   // mount active (Unit 4 / IMG_MOUNTED)
    input  wire        fault_clr,      // lifecycle clear for latched faults
    output reg         wr_fault,       // SD_WR invariant fault (latched)
    output reg         oor_fault,      // out-of-range LBA / mid-burst fault (latched)
    output wire        transport_fault // any latched fault, for Unit 4
);

    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_REQ     = 3'd1;  // fetch_req asserted for expected_lba
    localparam [2:0] S_DATA    = 3'd2;  // ACK high, streaming bytes 0..511 of blk_idx
    localparam [2:0] S_GAP     = 3'd3;  // between blocks: ACK high, no strobe
    localparam [2:0] S_HOLD    = 3'd4;  // last byte delivered; ACK held 3 cycles
    localparam [2:0] S_RELEASE = 3'd5;  // lower ACK once, release the final window

    reg [2:0]  state;
    reg [15:0] base_lba;      // burst start (latched at acceptance)
    reg [5:0]  blk_cnt_m1;    // blocks-1 for the burst (from sd_blk_cnt)
    reg [4:0]  blk_idx;       // block in request (0..blk_cnt_m1)
    reg [9:0]  byte_cnt;      // byte position within the current block
    reg [2:0]  hold_cnt;
    reg [15:0] expected_lba;  // LBA the current S_REQ is waiting for
    reg        gap_drain;     // one extra margin cycle after fetch_busy falls

    // Widened before narrowing (plan step 3): 17-bit sum catches a burst
    // that would wrap past 16-bit sector space.
    wire [16:0] burst_sum = {1'b0, base_lba} + {11'b0, blk_cnt_m1};

    assign sector_byte_addr = byte_cnt[8:0];
    assign sd_buff_dout     = sector_byte_data;
    assign sd_buff_addr     = {blk_idx, byte_cnt[8:0]};
    assign sd_buff_wr       = (state == S_DATA);
    assign transport_fault  = wr_fault || oor_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sd_ack      <= 1'b0;
            fetch_req   <= 1'b0;
            fetch_lba   <= 16'd0;
            sector_done <= 1'b0;
            base_lba    <= 16'd0;
            blk_cnt_m1  <= 6'd0;
            blk_idx     <= 5'd0;
            byte_cnt    <= 10'd0;
            hold_cnt    <= 3'd0;
            expected_lba<= 16'd0;
            gap_drain   <= 1'b0;
            wr_fault    <= 1'b0;
            oor_fault   <= 1'b0;
        end else begin
            // default: release the frozen window each cycle unless re-asserted
            sector_done <= 1'b0;

            // Explicit fault clear from the lifecycle controller (Unit 4).
            if (fault_clr) begin
                wr_fault  <= 1'b0;
                oor_fault <= 1'b0;
            end

            // SD_WR from the engine = invariant fault for the read-only
            // service: cancel any in-flight burst, latch the fault, never
            // ACK a no-op, never write SDRAM.
            if (drive_active && sd_wr && !wr_fault) begin
                wr_fault    <= 1'b1;
                fetch_req   <= 1'b0;
                sd_ack      <= 1'b0;
                sector_done <= 1'b1;   // release any held frozen window
                state       <= S_IDLE;
            end else begin
                case (state)
                S_IDLE: begin
                    sd_ack    <= 1'b0;
                    fetch_req <= 1'b0;
                    gap_drain <= 1'b0;
                    if (drive_active && sd_rd && !wr_fault && !oor_fault) begin
                        if (sd_lba[31:16] != 16'd0) begin
                            // High 16 bits set: beyond a 32 MiB image.
                            // Reject as a fault - do not request, do not ACK.
                            oor_fault <= 1'b1;
                        end else if (burst_sum[16]) begin
                            // Burst extends past 16-bit sector space.
                            oor_fault <= 1'b1;
                        end else begin
                            base_lba     <= sd_lba[15:0];
                            blk_cnt_m1   <= sd_blk_cnt_in;
                            blk_idx      <= 5'd0;
                            expected_lba <= sd_lba[15:0];
                            fetch_lba    <= sd_lba[15:0];
                            fetch_req    <= 1'b1;
                            state        <= S_REQ;
                        end
                    end
                end
                S_REQ: begin
                    // Hold fetch_req; wait for the service ready or fault.
                    if (fetch_fault) begin
                        // Service rejected (OOR/EOF-whole): fault on the
                        // FIRST block -> never ACK, latch, quiet outputs.
                        // Mid-burst (ACK already high): fall ACK so the burst
                        // ends as a short answer; the engine advances by the
                        // blocks actually received.
                        fetch_req <= 1'b0;
                        sd_ack    <= 1'b0;   // no-op if not yet raised
                        oor_fault <= 1'b1;
                        state     <= S_IDLE;
                    end else if (!drive_active || (sd_rd == 1'b0 && blk_idx == 5'd0 && !sd_ack)) begin
                        // Engine dropped the first request before we ACKed
                        // (unmount is handled below via drive_active):
                        // release without ACKing. If the service already
                        // published the window, release it (the fetcher waits
                        // in ST_HOLD for sector_done - leaking it wedges the
                        // fetch service for the next generation).
                        fetch_req <= 1'b0;
                        if (sector_ready)
                            sector_done <= 1'b1;
                        state     <= S_IDLE;
                    end else if (sector_ready && (sector_lba == expected_lba)) begin
                        // Window matches: raise ACK before delivering byte 0
                        // (first block only - later blocks arrive here with
                        // ACK already high).
                        sd_ack   <= 1'b1;
                        byte_cnt <= 10'd0;
                        state    <= S_DATA;
                    end else begin
                        // Stale-window guard (pattern: 0.4.4 service): the
                        // published window belongs to a superseded request.
                        // Release it, then re-arm: the fetcher's acceptance
                        // is EDGE-based, so hold fetch_req LOW while the
                        // service is busy and re-assert while idle.
                        if (sector_ready)
                            sector_done <= 1'b1;
                        if (!fetch_busy)
                            fetch_req <= 1'b1;
                        else
                            fetch_req <= 1'b0;
                    end
                end
                S_DATA: begin
                    // Stream one byte per cycle; ACK high; strobe on every
                    // S_DATA cycle (combinational). Byte 511 strobed with ACK
                    // high.
                    if (!drive_active) begin
                        // Eject/unmount: abort the burst, no stale data.
                        sd_ack      <= 1'b0;
                        fetch_req   <= 1'b0;
                        sector_done <= 1'b1;
                        state       <= S_IDLE;
                    end else if (byte_cnt == 10'd511) begin
                        if (blk_idx == blk_cnt_m1) begin
                            // Final block: hold ACK a few cycles, then one
                            // falling edge (the engine's transfer-complete).
                            hold_cnt <= 3'd0;
                            state    <= S_HOLD;
                        end else begin
                            // Next block: release this window, re-arm the
                            // fetcher with the next LBA (blocks are contiguous).
                            blk_idx      <= blk_idx + 5'd1;
                            expected_lba <= expected_lba + 16'd1;
                            sector_done  <= 1'b1;
                            fetch_req    <= 1'b0;   // edge will re-arm in S_GAP
                            gap_drain    <= 1'b0;
                            state        <= S_GAP;
                        end
                    end else begin
                        byte_cnt <= byte_cnt + 10'd1;
                    end
                end
                S_GAP: begin
                    // ACK stays high, sd_buff_wr low (combinational).
                    // The fetcher must observe the sector_done (2FF-synced in
                    // the ctrl domain) before it can accept the next request,
                    // so wait for fetch_busy to fall + one margin cycle,
                    // then pulse fetch_req HIGH with the next LBA (fresh
                    // 0->1 edge).
                    if (!drive_active) begin
                        sd_ack      <= 1'b0;
                        fetch_req   <= 1'b0;
                        sector_done <= 1'b1;
                        state       <= S_IDLE;
                    end else if (fetch_fault) begin
                        // Mid-burst rejection: NO window is published on a
                        // fault, so nothing stale can be delivered. End the
                        // burst as a short answer: fall ACK (engine advances
                        // by the blocks actually received), latch the fault
                        // (lifecycle unmounts; the partial transfer never
                        // becomes a usable track).
                        fetch_req <= 1'b0;
                        sd_ack    <= 1'b0;
                        oor_fault <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        if (!fetch_busy) begin
                            if (gap_drain) begin
                                // margin elapsed: re-arm with the next LBA
                                fetch_lba <= expected_lba;
                                fetch_req <= 1'b1;
                                state     <= S_REQ;
                            end else begin
                                gap_drain <= 1'b1;
                            end
                        end else begin
                            gap_drain <= 1'b0;
                        end
                    end
                end
                S_HOLD: begin
                    // ACK high after the final byte 511; the engine sees the
                    // falling edge only at release.
                    if (!drive_active) begin
                        sd_ack      <= 1'b0;
                        fetch_req   <= 1'b0;
                        sector_done <= 1'b1;
                        state       <= S_IDLE;
                    end else if (hold_cnt == 3'd2) begin
                        state <= S_RELEASE;
                    end else begin
                        hold_cnt <= hold_cnt + 3'd1;
                    end
                end
                S_RELEASE: begin
                    sd_ack      <= 1'b0;
                    fetch_req   <= 1'b0;
                    sector_done <= 1'b1;   // release the final window
                    state       <= S_IDLE;
                end
                default: begin
                    // Unreachable encoding: recover safely, no ACK.
                    sd_ack      <= 1'b0;
                    fetch_req   <= 1'b0;
                    sector_done <= 1'b1;
                    state       <= S_IDLE;
                end
                endcase
            end
        end
    end
endmodule
