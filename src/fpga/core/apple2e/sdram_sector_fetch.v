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
    output wire [15:0] sector_lba,     // machine-synced: lba of the published window
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
    // bounds / geometry (ctrl domain) - widened arithmetic, pipelined
    // (M1 timing fix, 2026-10-21: the single-cycle chain
    //      img_nbytes -> 32-bit subtract -> 512-byte clamp -> ceil-div add
    // was the only STA setup violation in the build (all 20 worst paths on
    // the 133.12 MHz ctrl clock, worst -0.889 ns Slow 1100 mV 0C). The
    // results only have to be valid at sector accept (once per 512-byte
    // sector, ~400 ctrl cycles), so the chain is split into one operation
    // per cycle. A (lba, gen) tag travels in lockstep with the values:
    // in this domain img_nbytes changes only together with img_gen (both
    // latched on the same 0082 pulse in the 74a domain, then the same
    // 2FF sync - see sdram_storage.v), so a tag match against the current
    // settled lba + gen proves every pipelined value was computed from the
    // live (lba, size, gen) tuple. Accept waits for the tag to match: at
    // most 2 extra ctrl cycles (~15 ns) per sector, invisible to the
    // level-held request protocol.
    // ==================================================================
    wire [31:0] sect_start  = {7'b000_0000, ctrl_lba_s2, 9'b000_000_000}; // lba*512
    wire [31:0] rem_c       = (img_nbytes > sect_start) ? (img_nbytes - sect_start)
                                                        : 32'd0;
    // 24-bit word base via concatenation (a 16-bit shift would truncate)
    wire [23:0] word_base   = {1'b0, ctrl_lba_s2, 7'b000_0000}; // lba*128
                                   // (nbytes <= 4 MiB slot => word_base < 1 MiB)

    // stage 1: bounds remainder (the 32-bit subtract) + tag capture
    reg [31:0] rem_p1;
    reg [15:0] g_lba_p1;
    reg [7:0]  g_gen_p1;
    // stage 2: clamp to the sector's 512 bytes
    // (rem can be the whole image for early sectors; nrd is per-sector)
    reg [10:0] remc_p2;
    reg [15:0] g_lba_p2;
    reg [7:0]  g_gen_p2;
    // stage 3: ceil-divide by 4 -> word count, plus the coherent tag
    reg [8:0]  nrd_p3;
    reg        oor_p3;
    reg [15:0] g_lba_p3;
    reg [7:0]  g_gen_p3;

    always @(posedge clk_ctrl or negedge rst_n_ctrl) begin
        if (!rst_n_ctrl) begin
            rem_p1    <= 32'd0;
            g_lba_p1  <= 16'd0;
            g_gen_p1  <= 8'd0;
            remc_p2   <= 11'd0;
            g_lba_p2  <= 16'd0;
            g_gen_p2  <= 8'd0;
            nrd_p3    <= 9'd0;
            oor_p3    <= 1'b0;
            g_lba_p3  <= 16'd0;
            g_gen_p3  <= 8'd0;
        end else begin
            rem_p1   <= rem_c;
            g_lba_p1 <= ctrl_lba_s2;
            g_gen_p1 <= img_gen;
            remc_p2  <= (rem_p1 > 11'd511) ? 11'd511 : rem_p1[10:0];
            g_lba_p2 <= g_lba_p1;
            g_gen_p2 <= g_gen_p1;
            nrd_p3   <= remc_p2[10:2] + ((remc_p2[1:0] != 2'b00) ? 9'd1 : 9'd0);
            oor_p3   <= (remc_p2 == 11'd0);   // rem==0 iff clamp(rem)==0
            g_lba_p3 <= g_lba_p2;
            g_gen_p3 <= g_gen_p2;
        end
    end

    // pipeline output is usable only when it was computed for the current
    // settled lba AND current image generation (true 2 ctrl cycles after
    // either changes; true permanently while both are stable)
    wire geom_fresh = (g_lba_p3 == ctrl_lba_s2) && (g_gen_p3 == img_gen);

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
    reg [13:0] hold_cnt;       // ST_HOLD self-release timeout
    reg [1:0]  ready_m_s;   // sector_ready: machine-domain 2FF (2026-10-22 CDC fix)
    reg        ready_c;     // ctrl-domain ready level (1FF stage before the 2FF)
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
    // ST_IDLE accept condition, shared by the pending-flag clear and the
    // state machine. Consolidating the clear HERE (one always block drives
    // `pend`) fixes the multiple-constant-driver synthesis error: `pend` was
    // assigned in both this block and the ST_IDLE case - Quartus rejects a
    // reg driven by two blocks (Verilator tolerates it, so it was latent).
    wire pend_accept = (st == ST_IDLE) && pend && ctrl_lba_ok && init_done
                        && geom_fresh;

    reg pend;
    always @(posedge clk_ctrl or negedge rst_n_ctrl) begin
        if (!rst_n_ctrl)
            pend <= 1'b0;
        else if (req_s[0] && !req_s[1])
            pend <= 1'b1;              // fresh request edge
        else if (!ctrl_req || pend_accept)
            pend <= 1'b0;              // released, or consumed by the ST_IDLE accept
    end

    // Early generation invalidation (M1 Unit-5 fix): a new 0082 bumps the
    // image generation; an in-flight fetch of the OLD generation must stop
    // (not run to sector end). The bounded tail otherwise keeps the port
    // busy while the new generation's load streams, throttling the store
    // below the host's supply rate and overflowing the load FIFO.
    // The abort must happen only when no read op is in flight (ST_GAP,
    // where the per-word level is low by construction): dropping the level
    // mid-op would violate the port's read protocol (word_rd must be held
    // as a level through the in-flight read op's data window) and dead
    // the port. Bounded tail: at most one word completes after the bump.
    // (The sector-end stale-discard branch is kept as a defensive corner:
    // gen bumps exactly on the final word.)
    wire gen_stale = (img_gen !== gen_l);

    always @(posedge clk_ctrl or negedge rst_n_ctrl) begin
        if (!rst_n_ctrl) begin
            st         <= ST_IDLE;
            lba_l      <= 16'd0;
            nrd_l      <= 9'd0;
            gen_l      <= 8'd0;
            wcnt       <= 8'd0;
            done_sync  <= 2'b00;
            ready_c    <= 1'b0;
            fault_m_s1 <= 1'b0;
            // NOTE: sbuf is intentionally NOT reset (power-content irrelevant;
            // it is only read while sector_ready, which requires a fresh write)
        end else begin
            done_sync <= {done_sync[0], sector_done};

            case (st)
            ST_IDLE: begin
                fault_m_s1 <= 1'b0;
                if (pend_accept) begin
                    // (pend is cleared by the dedicated block above via pend_accept)
                    if (oor_p3) begin
                        st         <= ST_FAULT;
                        fault_m_s1 <= 1'b1;
                    end else begin
                        lba_l  <= ctrl_lba_s2;
                        nrd_l  <= nrd_p3;
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
                            ready_c <= 1'b1;
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

            // per-word GAP: abort if the generation moved while in the gap
            ST_GAP: begin
                if (gen_stale)
                    st <= ST_IDLE;
                else
                    st <= ST_WAIT;
            end

            ST_HOLD: begin
                // Self-release timeout: if the requester retired without
                // consuming the window (generation bump / engine eject
                // racing the publish), the transport's sector_done never
                // comes and the fetch service wedges for the next
                // generation. A legitimate stream takes <= ~36 us
                // (512 machine cycles); 8192 controller cycles (~61.5 us)
                // is safely longer, so a timed release can never drop a
                // window mid-stream.
                hold_cnt <= hold_cnt + 1'b1;
                if (done_sync[1] || (hold_cnt == 14'd8191)) begin
                    ready_c   <= 1'b0;   // release + clear in one step
                    hold_cnt  <= 14'd0;
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
        // 2026-10-22 CDC fix (review finding): ready_m_s was clocked by
        // clk_ctrl - a 2-cycle delay in the CTRL domain, not a
        // synchronizer. Now a proper 2FF on clk_mach, mirroring
        // fault_m_s/busy_m_s above. Adds 2 machine cycles to the
        // ready-assert/release latency (invisible at sector granularity;
        // the transport paces on the level).
        ready_m_s <= {ready_m_s[0], ready_c};
        busy_m_s  <= {busy_m_s[0], (st != ST_IDLE) && (st != ST_FAULT)};
    end

    // 2026-10-22: publish the lba of the window in sbuf (lba_l is
    // ctrl-domain; stable between sector_ready and sector_done by
    // contract, so a plain 2FF is safe - the transport only compares
    // it while sector_ready is high). Lets the transport verify it is
    // streaming the sector it actually requested (stale-window race).
    reg [15:0] sector_lba_m1, sector_lba_m2;
    always @(posedge clk_mach) begin
        sector_lba_m1 <= lba_l;
        sector_lba_m2 <= sector_lba_m1;
    end
    assign sector_lba = sector_lba_m2;
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
