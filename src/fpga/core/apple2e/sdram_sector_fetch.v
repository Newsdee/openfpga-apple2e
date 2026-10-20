//
// sdram_sector_fetch.v - machine-domain WOZ sector service (M1 Unit 2/3)
//
// Serves the WOZ engine's 512-byte-block transport (Q1 pacing contract)
// from the M0 SDRAM-resident image:
//
//   machine domain (14.318 MHz)                ctrl domain (133.12 MHz)
//   fetch_req/fetch_lba (level, from the      2FF sync -> bounds check ->
//   WOZ engine) -> 512-byte readout port       sector transfer through the
//   (byte 0..511, <=1 byte/machine cycle)     word owner -> 512-byte
//   <- sector_ready/sector_done handshake     scratch -> ready publish
//
// Invariants (expert M1 review):
//   * LBA is a 512-BYTE SECTOR NUMBER: byte offset = LBA*512, word offset
//     = LBA*128. Widened arithmetic is validated against the live image
//     size before narrowing to the 24-bit word address.
//   * A sector wholly beyond EOF is a FAULT (no publish); a partial tail
//     sector delivers real bytes below EOF and deterministic 0x00 padding
//     above - never stale SDRAM (padded words are never fetched).
//   * Words unpack in file order: [31:24] first, then [23:16], [15:8],
//     [7:0] (matches the M0 store's write order).
//   * The scratch buffer is frozen between sector_ready and sector_done;
//     a new request is accepted only after the previous sector's done is
//     observed in this domain. One outstanding sector.
//   * Generation: the request is tagged with the image generation at
//     acceptance. If a new slot load is accepted while a transfer is in
//     flight (generation invalidates), the transfer runs to completion
//     (SDRAM ops are not aborted) but its result is DISCARDED - a stale
//     sector is never published to the new generation.
//   * This client is read-only: it can never drive a word-port write.
//
// Machine-domain ports are the emitter's (Unit 3) interface; the fetch
// request enters as a LEVEL (the engine holds its request until the
// transfer is acknowledged) so acceptance is lossless.
//
`timescale 1ns/10ps
module sdram_sector_fetch (
    input  wire        clk_mach,   // 14.318 MHz
    input  wire        rst_n_mach, // machine/core POR (async crossing)
    input  wire        clk_ctrl,   // 133.12 MHz
    input  wire        rst_n_ctrl, // core POR (async crossing)

    // ---- machine side (WOZ engine / emitter) ----
    input  wire        fetch_req,      // level: request pending (lba stable)
    input  wire [15:0] fetch_lba,      // 512-byte sector number
    output wire        fetch_busy,     // level: request accepted/in progress
    output wire        sector_ready,   // level: scratch holds the sector
    input  wire [8:0]  sector_byte_addr,
    output wire [7:0]  sector_byte_data, // combinational read (frozen window)
    input  wire        sector_done,    // level: emitter finished reading
    output wire        fetch_fault,    // level: request rejected (out of range)

    // ---- ctrl side (word owner + image size + generation) ----
    input  wire        init_done,      // SDRAM init complete
    input  wire [31:0] img_nbytes,     // live image size (synced to ctrl)
    input  wire [7:0]  img_gen,        // current image generation
    output wire        fc_req,         // level to the word owner (per word)
    output wire [23:0] fc_addr,        // word address of the word in flight
    input  wire        fc_active,
    input  wire        fc_word_valid,  // 1-cycle: a fetch-owned word landed
    input  wire        fc_done,        // level: word complete (owner, M0 shape)
    input  wire [31:0] fc_data,        // word just completed
    output wire [7:0]  fc_gen,         // sector-acceptance generation tag
    input  wire [7:0]  fc_done_gen     // generation tag of the completed word
);

    localparam [3:0] ST_IDLE  = 4'd0;
    localparam [3:0] ST_WAIT  = 4'd1;   // word transfer in flight (level held)
    localparam [3:0] ST_GAP   = 4'd2;   // 1-cycle level drop between words
    localparam [3:0] ST_HOLD  = 4'd3;   // sector published, awaiting sector_done
    localparam [3:0] ST_FAULT = 4'd4;

    // ==================================================================
    // machine -> ctrl request sync
    // ==================================================================
    reg [1:0]  req_s;
    reg [15:0] ctrl_lba_s1, ctrl_lba_s2;
    always @(posedge clk_ctrl) begin
        req_s  <= {req_s[0], fetch_req};
        ctrl_lba_s1 <= fetch_lba;
        ctrl_lba_s2 <= ctrl_lba_s1;
    end
    wire ctrl_req  = req_s[1];
    wire ctrl_lba_ok = (ctrl_lba_s1 == ctrl_lba_s2); // settled before use

    // ==================================================================
    // bounds / geometry (ctrl domain) - widened arithmetic
    // ==================================================================
    wire [31:0] sect_start  = {7'b000_0000, ctrl_lba_s2, 9'b000_000_000}; // lba*512
    wire [31:0] rem         = (img_nbytes > sect_start) ? (img_nbytes - sect_start)
                                                        : 32'd0;
    // Clamp rem to the sector's 512 bytes, then ceil-divide by 4.
    // (rem can be the whole image for early sectors; nrd is per-sector.)
    wire [10:0] remc        = (rem > 11'd511) ? 11'd511 : rem[10:0];
    wire [8:0]  nrd         = remc[10:2] + ((remc[1:0] != 2'b00) ? 9'd1 : 9'd0);
    wire        oor         = (rem == 32'd0);            // wholly beyond EOF
    // 24-bit word base via concatenation (a 16-bit shift would truncate)
    wire [23:0] word_base   = {1'b0, ctrl_lba_s2, 7'b000_0000}; // lba*128
                                   // (nbytes <= 4 MiB slot => word_base < 1 MiB)

    // ==================================================================
    // scratch: 512 x 8 (written in ctrl domain, read in machine domain -
    // frozen between ready and done; M10K simple dual-port in Quartus)
    // ==================================================================
    reg [31:0] sbuf [0:127];

    reg [3:0]  st;
    reg [15:0] lba_l;
    reg [8:0]  nrd_l;
    reg [7:0]  gen_l;
    reg [7:0]  wcnt;           // words written into sbuf (0..nrd_l)
    reg [1:0]  done_sync;      // sector_done: machine -> ctrl
    reg [1:0]  ready_m_s;      // sector_ready: ctrl -> machine
    reg        fault_m_s1;     // fault: ctrl -> machine

    // A completion is FRESH only if the owner's generation tag for the
    // just-completed word still matches the sector-acceptance generation
    // (a new slot load accepted mid-sector re-accepts subsequent words
    // with the new tag -> mismatch -> the whole sector is discarded).
    wire fresh_word = (fc_done_gen == gen_l);

    // One request = one sector: acceptance requires a fresh request EDGE
    // (the emitter holds the level through sector_done; a level-based
    // accept would re-fetch the same sector as soon as ST_HOLD releases,
    // re-publishing ready without a new request - measured hang).
    reg pend;
    always @(posedge clk_ctrl or negedge rst_n_ctrl) begin
        if (!rst_n_ctrl)
            pend <= 1'b0;
        else if (req_s[0] && !req_s[1])
            pend <= 1'b1;          // fresh request edge
        else if (!ctrl_req)
            pend <= 1'b0;          // released: cancel any unaccepted request
    end

    always @(posedge clk_ctrl or negedge rst_n_ctrl) begin
        if (!rst_n_ctrl) begin
            st         <= ST_IDLE;
            lba_l      <= 16'd0;
            nrd_l      <= 9'd0;
            gen_l      <= 8'd0;
            wcnt       <= 8'd0;
            done_sync  <= 2'b00;
            ready_m_s  <= 2'b00;
            fault_m_s1 <= 1'b0;
            // NOTE: sbuf is intentionally NOT reset (power-content irrelevant;
            // it is only read while sector_ready, which requires a fresh write)
        end else begin
            done_sync <= {done_sync[0], sector_done};

            case (st)
            ST_IDLE: begin
                fault_m_s1 <= 1'b0;
                if (pend && ctrl_lba_ok && init_done) begin
                    pend <= 1'b0;  // consumed by this accept
                    if (oor) begin
                        st         <= ST_FAULT;
                        fault_m_s1 <= 1'b1;
                    end else begin
                        lba_l  <= ctrl_lba_s2;
                        nrd_l  <= nrd;
                        gen_l  <= img_gen;
                        wcnt   <= 8'd0;
                        st     <= ST_WAIT;
                    end
                end else
                    st <= ST_IDLE;   // explicit hold (no implicit-hold cases)
            end

            // per-word read: hold the level until the owner's done level
            // is seen, then (unless this was the last word) drop it for
            // one cycle (ST_GAP) so the owner's done-pending clears and
            // the next word's request is accepted fresh
            ST_WAIT: begin
                if (fc_done) begin
                    // wcnt was already incremented on this word's
                    // fc_word_valid pulse: the sector is complete when
                    // wcnt has reached nrd_l (all words landed).
                    if ({1'b0, wcnt} >= nrd_l) begin
                        if (fresh_word) begin
                            // fresh: publish (words beyond nrd_l were never
                            // fetched - the read port pads them with 0x00)
                            ready_m_s <= 2'b11;
                            st        <= ST_HOLD;
                        end else begin
                            // generation invalidated mid-sector: discard
                            st <= ST_IDLE;
                        end
                    end else begin
                        st <= ST_GAP;
                    end
                end else
                    st <= ST_WAIT;   // explicit hold (no implicit-hold cases)
            end

            // 1 ctrl cycle with the level low, then re-arm with wcnt+1
            ST_GAP: begin
                st <= ST_WAIT;
            end

            ST_HOLD: begin
                if (done_sync[1]) begin
                    ready_m_s <= 2'b00;   // release + clear in one step
                    st        <= ST_IDLE;
                end else
                    st <= ST_HOLD;
            end

            ST_FAULT: begin
                // fault held until the emitter deasserts fetch_req
                if (!ctrl_req) begin
                    st         <= ST_IDLE;
                    fault_m_s1 <= 1'b0;
                end else begin
                    st <= ST_FAULT;
                end
            end

            default: st <= ST_IDLE;
            endcase

            // per-word scratch fill (one word at a time, M0 level protocol)
            if (st == ST_WAIT && fc_word_valid) begin
                sbuf[wcnt[6:0]] <= fc_data;
                wcnt            <= wcnt + 8'd1;
            end
        end
    end

    // ==================================================================
    // owner request drive (per-word level; held until the word completes)
    // ==================================================================
    assign fc_req  = (st == ST_WAIT);
    assign fc_addr = word_base + {16'b0000_0000_0000, wcnt};
    assign fc_gen  = gen_l;

    // ==================================================================
    // machine-side outputs (2FF crossings only)
    // ==================================================================
    reg [1:0] fault_m_s;
    reg [1:0] busy_m_s;
    always @(posedge clk_mach) begin
        fault_m_s <= {fault_m_s[0], fault_m_s1};
        busy_m_s  <= {busy_m_s[0], (st != ST_IDLE) && (st != ST_FAULT)};
    end
    assign fetch_fault  = fault_m_s[1];
    assign sector_ready = ready_m_s[1];
    assign fetch_busy   = busy_m_s[1];

    // byte readout: word index = addr[8:2] (addr is 9 bits: 0..511),
    // byte select = addr[1:0]. Words at/above nrd_l (partial tail)
    // read as 0x00 padding.
    wire [6:0] widx8 = sector_byte_addr[8:2];
    wire [1:0] bsel  = sector_byte_addr[1:0];
    // 10-bit compare: nrd_l can be 128 (truncating to 8 bits would read 0)
    wire        full_word = ({3'b000, widx8} < {1'b0, nrd_l});
    wire [31:0] wsel_eff  = full_word ? sbuf[widx8] : 32'd0;
    reg [7:0] byte_eff;
    always @(*) begin
        case (bsel)
            2'd0:    byte_eff = wsel_eff[31:24];
            2'd1:    byte_eff = wsel_eff[23:16];
            2'd2:    byte_eff = wsel_eff[15:8];
            default: byte_eff = wsel_eff[7:0];
        endcase
    end
    assign sector_byte_data = byte_eff;

endmodule
