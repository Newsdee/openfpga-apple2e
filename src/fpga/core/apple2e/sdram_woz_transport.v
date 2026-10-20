// sdram_woz_transport.v - machine-domain (14.318 MHz) WOZ block transport
// M1 Unit 3
//
// Paces the WOZ engine's per-byte block reads against the Unit-2 SDRAM
// sector service (sdram_sector_fetch). One request = one 512-byte sector.
//
//   WOZ engine (this clock)              Unit-2 sector service (same clock)
//   sd_rd/sd_lba --request------------->  fetch_req/fetch_lba
//   sd_ack       <--grant---------------  sector_ready
//   sd_buff_addr/sd_buff_dout <=====>    sector_byte_addr/sector_byte_data
//   (byte 511 sampled with ACK) --------  sector_done
//   sd_wr = invariant fault (read-only service)
//
// Pacing contract (M1 plan, Unit 3):
//  * Latch LBA while ACK low; the request may register before ACK rises.
//  * Raise ACK before delivering byte 0.
//  * Mirror the engine's sd_buff_addr (0..511) to the frozen-window readout;
//    at most one byte per machine rising edge; gaps with WR low are allowed.
//  * Byte 511 must be sampled with ACK high; lower ACK on a later edge.
//  * Retire the request before accepting another (one outstanding sector).
//  * drive_active low: ACK low, data outputs quiet (not driven).
//  * sd_wr from the engine = explicit invariant fault: no SDRAM write, no
//    fake successful ACK, latch a visible fault, cancel; the lifecycle
//    controller (Unit 4) consumes transport_fault to unmount. Never hang.
//  * An LBA whose high 16 bits are nonzero is out of range for a <=32 MiB
//    image (ours is <=4 MiB) and is rejected as a fault, not a request.

`timescale 1ns/1ps
module sdram_woz_transport (
    input  wire        clk,            // 14.318 MHz machine clock
    input  wire        rst_n,

    // ---- WOZ engine side (single drive, read-only service) ----
    input  wire        sd_rd,          // engine: read request (level, waits for ACK)
    input  wire [31:0] sd_lba,         // engine: 512-byte sector number
    output reg         sd_ack,         // host: grant (high for the whole block)
    input  wire        sd_wr,          // engine: write request = invariant fault
    input  wire [8:0]  sd_buff_addr,   // engine: byte address in block (0..511)
    input  wire        sd_buff_wr,     // engine: per-byte sample strobe
    output wire [7:0]  sd_buff_dout,   // host: byte read by engine (frozen window)

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
    localparam [2:0] S_DATA    = 3'd2;  // ACK high, bytes being delivered
    localparam [2:0] S_RELEASE = 3'd3;  // byte 511 sampled; lower ACK, release

    reg [2:0]  state;
    reg [15:0] lba_l;

    // Frozen-window byte readout is a zero-latency mirror: the engine walks
    // sd_buff_addr and samples sd_buff_dout; the window holds the sector
    // stable between sector_ready and sector_done.
    assign sector_byte_addr = sd_buff_addr;
    assign sd_buff_dout     = sector_byte_data;
    assign transport_fault  = wr_fault || oor_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sd_ack      <= 1'b0;
            fetch_req   <= 1'b0;
            fetch_lba   <= 16'd0;
            sector_done <= 1'b0;
            lba_l       <= 16'd0;
            wr_fault    <= 1'b0;
            oor_fault   <= 1'b0;
        end else begin
            // default: release the frozen-window read each cycle unless held
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
                    end else if (sector_ready) begin
                        // Raise ACK before delivering byte 0.
                        sd_ack <= 1'b1;
                        state  <= S_DATA;
                    end
                    // else: keep waiting, fetch_req stays high
                end
                S_DATA: begin
                    // ACK high; byte data mirrored combinationally. Hold ACK
                    // until byte 511 is sampled with ACK high, then retire
                    // on a later edge (S_RELEASE).
                    if (sd_buff_wr && (sd_buff_addr == 9'd511) && sd_ack) begin
                        state <= S_RELEASE;
                    end
                end
                S_RELEASE: begin
                    // Lower ACK on this (later) edge; release the window.
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
