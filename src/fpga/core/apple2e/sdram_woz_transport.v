// sdram_woz_transport.v - machine-domain (14.318 MHz) WOZ block transport
// M1 Unit 3 (rewritten 2026-10-21 after Unit-5 integration exposed a
// protocol-direction error in the first revision)
//
// The WOZ engine's block interface is HOST-PACED (same protocol as the
// MiSTer hps_io host side - verified against woz_floppy_controller.sv):
//
//   sd_rd/sd_lba (engine -> host): level request, held while ACK low.
//   sd_ack (host -> engine): grant; rising edge starts the transfer,
//       falling edge ends it (the engine's transfer_active logic).
//   sd_buff_addr/sd_buff_dout/sd_buff_wr (host -> engine): the HOST walks
//       addr 0..511, presents each byte on dout, and strobes wr one
//       cycle per byte. The engine consumes one byte per strobe while
//       ACK is high (its streaming parser / BRAM load path).
//   sd_buff_din (engine -> host): write direction (track save) - not
//       used by this read-only service.
//   sd_wr (engine -> host): write request = invariant fault here.
//
// One request = one 512-byte sector through the Unit-2 sector service
// (sdram_sector_fetch): fetch_req/fetch_lba out, sector_ready/fetch_fault
// in; the sector stays frozen in the fetcher's window between
// sector_ready and sector_done; this transport paces the byte stream
// from that window (one byte per machine cycle).
//
//   * Latch LBA while ACK low; the request may register before ACK rises.
//   * Raise ACK before delivering byte 0.
//   * Stream 512 bytes (addr 0..511, one strobe per byte, ACK high
//     throughout - byte 511 is therefore sampled with ACK high).
//   * Hold ACK a few cycles after byte 511, then lower it and release
//     the frozen window (sector_done); retire before accepting another
//     request (one outstanding sector).
//   * drive_active low: no new requests, ACK low, outputs quiet.
//   * sd_wr from the engine = explicit invariant fault: no SDRAM write,
//     no fake successful ACK, latch a visible fault, cancel; the
//     lifecycle controller (Unit 4) consumes transport_fault to unmount.
//   * An LBA whose high 16 bits are nonzero is out of range for a
//     <=32 MiB image (ours is <=4 MiB) and is rejected as a fault.

`timescale 1ns/1ps
module sdram_woz_transport (
    input  wire        clk,            // 14.318 MHz machine clock
    input  wire        rst_n,

    // ---- WOZ engine side (single drive, read-only service) ----
    input  wire        sd_rd,          // engine: read request (level, waits for ACK)
    input  wire [31:0] sd_lba,         // engine: 512-byte sector number
    output reg         sd_ack,         // host: grant (high for the whole block)
    input  wire        sd_wr,          // engine: write request = invariant fault
    output wire [8:0]  sd_buff_addr,   // host: byte address in block (0..511)
    input  wire [7:0]  sd_buff_din,    // engine: save data (unused, read-only)
    output wire [7:0]  sd_buff_dout,   // host: byte read by engine (frozen window)
    output wire        sd_buff_wr,     // host: per-byte strobe (1 cycle per byte)

    // ---- Unit-2 sector service (same clock domain) ----
    output reg         fetch_req,
    output reg  [15:0] fetch_lba,
    input  wire        fetch_busy,
    input  wire        sector_ready,
    input  wire [7:0]  sector_byte_data,
    input  wire        fetch_fault,
    output wire [8:0]  sector_byte_addr,
    output reg         sector_done,

    // ---- mount gating + fault status ----
    input  wire        drive_active,   // mount active (Unit 4 / IMG_MOUNTED)
    input  wire        fault_clr,      // lifecycle clear for latched faults
    output reg         wr_fault,       // SD_WR invariant fault (latched)
    output reg         oor_fault,      // out-of-range LBA (latched)
    output wire        transport_fault // any latched fault, for Unit 4
);

    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_REQ     = 3'd1;  // fetch_req asserted, awaiting ready/fault
    localparam [2:0] S_DATA    = 3'd2;  // ACK high, streaming bytes 0..511
    localparam [2:0] S_HOLD    = 3'd3;  // byte 511 delivered; ACK held
    localparam [2:0] S_RELEASE = 3'd4;  // lower ACK, release the window

    reg [2:0]  state;
    reg [15:0] lba_l;
    reg [9:0]  byte_cnt;   // byte position within the block (0..511)
    reg [2:0]  hold_cnt;

    // Host-paced readout from the fetcher's frozen window.
    assign sector_byte_addr = byte_cnt[8:0];
    assign sd_buff_dout     = sector_byte_data;
    assign sd_buff_addr     = byte_cnt[8:0];
    assign sd_buff_wr       = (state == S_DATA);
    assign transport_fault  = wr_fault || oor_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sd_ack      <= 1'b0;
            fetch_req   <= 1'b0;
            fetch_lba   <= 16'd0;
            sector_done <= 1'b0;
            lba_l       <= 16'd0;
            byte_cnt    <= 10'd0;
            hold_cnt    <= 3'd0;
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
            // service: cancel any in-flight transaction, latch the fault,
            // never ACK a no-op, never write SDRAM.
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
                    if (drive_active && sd_rd && !wr_fault && !oor_fault) begin
                        if (sd_lba[31:16] != 16'd0) begin
                            // High 16 bits set: beyond a 32 MiB image.
                            // Reject as a fault - do not request, do not ACK.
                            oor_fault <= 1'b1;
                        end else begin
                            lba_l     <= sd_lba[15:0];
                            fetch_lba <= sd_lba[15:0];
                            fetch_req <= 1'b1;
                            state     <= S_REQ;
                        end
                    end
                end
                S_REQ: begin
                    // Hold fetch_req; wait for the service ready or fault.
                    if (fetch_fault) begin
                        // Service rejected (OOR): cancel, visible fault.
                        fetch_req <= 1'b0;
                        oor_fault <= 1'b1;
                        state     <= S_IDLE;
                    end else if (!drive_active || !sd_rd) begin
                        // Engine dropped the request (unmount / new
                        // generation): release without ACKing. If the
                        // service already published the window, release
                        // it (the fetcher waits in ST_HOLD for
                        // sector_done - leaking it wedges the fetch
                        // service for the next generation).
                        fetch_req   <= 1'b0;
                        if (sector_ready)
                            sector_done <= 1'b1;
                        state     <= S_IDLE;
                    end else if (sector_ready) begin
                        // Raise ACK before delivering byte 0.
                        sd_ack   <= 1'b1;
                        byte_cnt <= 10'd0;
                        state    <= S_DATA;
                    end
                    // else: keep waiting, fetch_req stays high
                end
                S_DATA: begin
                    // Stream one byte per cycle: sd_buff_wr is high for
                    // every S_DATA cycle (combinational), addr/data mirror
                    // byte_cnt / the frozen window. Byte 511 is strobed
                    // with ACK high; then hold ACK a few cycles.
                    //
                    // Abort ONLY on !drive_active (the generation was
                    // ejected / unmounted). Do NOT abort on !sd_rd: the
                    // engine legitimately drops sd_rd ~2 cycles after the
                    // ACK rises during its live WOZ scan (it re-asserts
                    // only while sd_ack is low), so !sd_rd is a normal
                    // mid-scan state, not a dead generation. Aborting on
                    // it truncated every block to ~2 bytes and broke the
                    // engine's header scan (measured). A dead generation
                    // is detected by drive_active falling, which frees the
                    // port promptly for a concurrent store load.
                    if (!drive_active) begin
                        sd_ack      <= 1'b0;
                        fetch_req   <= 1'b0;
                        sector_done <= 1'b1;
                        state       <= S_IDLE;
                    end else if (byte_cnt == 10'd511) begin
                        hold_cnt <= 3'd0;
                        state    <= S_HOLD;
                    end else begin
                        byte_cnt <= byte_cnt + 10'd1;
                    end
                end
                S_HOLD: begin
                    // ACK stays high after byte 511; the engine sees the
                    // falling edge only at release (its transfer-complete).
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
                    sector_done <= 1'b1;
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
