//
// disk_verifier.v - machine-domain readback client for the SDRAM image
// path (M0 rework, Unit 4)
//
// DOMAIN: machine clock (clk_core_14318). Every port is in this domain.
// The top provides two level handshakes to the SDRAM controller domain:
//   - request: `req`/`req_addr` levels; the top syncs them to the
//     controller domain, io_sdram_pocket consumes word_rd when idle.
//   - result:  `rd_done` level (held by the top until the request
//     deassert is observed in the controller domain) and `rd_data`,
//     stable for the whole rd_done-high window (the word port is
//     serialized: no new operation can start until the request
//     deasserts), latched by the top into a 2FF register that is
//     flagged good with `rd_data_ok`.
//
// PROTOCOL (host-driven, M0):
//   1. host loads the image through the bridge data-slot window
//      (FIFO -> disk_store -> SDRAM);
//   2. host writes n_bytes (0xF9000004) then start (0xF9000024);
//   3. verifier reads every word of the file back, CRC32s the exact
//      n_bytes (final partial word masked by the byte count), latches
//      first/last word, and reports done/ok + result words through the
//      0xF9xxxxxx debug-read block.
//
// ok = full readback without transport errors. The host compares
// crc32/first_word/last_word against PC-computed fixture values (the
// endianness check: bridge word [31:24] is the FIRST file byte of the
// 4-byte group, as written by the host loader).
//
// Bounded failures: a request that does not complete within
// TIMEOUT_WORDS machine cycles latches `stuck` and stops (busy falls,
// ok=0) - observable, never silent. Machine reset does NOT touch this
// module or its SDRAM contents (resident image survives).
//
`timescale 1ns/10ps
module disk_verifier #(
    parameter TIMEOUT_CYCLES = 20000,    // ~1.4 ms per word (op is ~4 us)
    // Image-fingerprint diagnostics (M1 hardware-load): 0 = shipping build
    // (fp registers/accumulators trimmed, outputs constant 0); 1 = build
    // with the always-computed 4x64 KB window CRCs + head/tail latches
    // (tools/woz_fingerprint.py is the PC oracle). No extra SDRAM traffic
    // either way - the fingerprint rides on the existing verify readback.
    parameter FP_EN = 1'b0
) (
    input  wire        clk,              // machine, 14.318 MHz
    input  wire        rst_n,            // core POR, async crossing (74.25)

    // ---- configuration (machine domain; top synced from 74.25) ----
    input  wire [31:0] n_bytes,          // file length in bytes
    input  wire        start,            // level: start pending (host)
    output reg          start_done,      // level: ack, held until start falls

    // ---- word-port handshake (machine domain; top does the CDC) ----
    output reg          req,             // level: read request
    output reg  [23:0]  req_addr,        // word address (stable while req)
    input  wire        rd_done,          // level (top)
    input  wire        rd_data_ok,       // level (top): rd_data latched good
    input  wire [31:0] rd_data,          // latched word (top 2FF)

    // ---- status / results (machine domain; top syncs to 74.25) ----
    output wire        busy,
    output wire        done,
    output wire        ok,
    output reg          stuck,           // readback halted on timeout

    // ---- fault-injection hook (test only; top ties 32'd0) ----
    // Nonzero: replace TIMEOUT_CYCLES for the per-word read timeout, so
    // a testbench can drive the real timeout path (the controller times
    // word operations itself, so a dead SDRAM model alone cannot stall
    // rd_done). Zero: normal TIMEOUT_CYCLES.
    input  wire [31:0] timeout_override,

    output reg  [31:0]  crc32,
    output reg  [31:0]  first_word,
    output reg  [31:0]  last_word,
    output reg  [15:0]  words_read,
    output reg  [15:0]  words_readout,

    // ---- image fingerprint (M1 hardware-load diagnostics, 2026-10-23) ----
    // Latched at the end of each verification pass (ok or stuck; zeroed on
    // every start). All in this (machine) domain; the top passes them to the
    // status overlay as-is (no CDC - the overlay is machine-domain too).
    //   fp_first: file bytes [0:15]      (MSB = byte 0; bytes >= n_bytes = 0)
    //   fp_last : file bytes [n-16:n-1]  (MSB = the older byte; same zeroing)
    //   fp_w0..3: independent zlib-style CRC32s of byte windows
    //             [0:64K), [64K:128K), [128K:192K), [192K:n) - each window
    //             is a FRESH crc32 (init 0xFFFFFFFF, final XOR), so on the
    //             PC: zlib.crc32(data[a:b]) per window; empty window = 0.
    // A healthy hardware load must match a PC-computed fingerprint of the
    // same card file (tools/woz_fingerprint.py); a mismatch localizes the
    // corruption to a 64 KB region (and F/L give exact head/tail bytes).
    output reg  [127:0] fp_first,
    output reg  [127:0] fp_last,
    output reg  [31:0]  fp_w0,
    output reg  [31:0]  fp_w1,
    output reg  [31:0]  fp_w2,
    output reg  [31:0]  fp_w3
);

    localparam ST_IDLE = 3'd0;
    localparam ST_REQ  = 3'd1;   // request issued, waiting rd_done
    localparam ST_CRC  = 3'd2;   // CRC the latched word
    localparam ST_END  = 3'd3;   // results latched

    reg [2:0]  st;
    reg [1:0]  rst_n_s1, rst_n_s2;

    reg [31:0] crc_w;              // running CRC
    reg [31:0] wq;                 // word under CRC
    wire [31:0] tmo = (timeout_override != 32'd0) ? timeout_override
                                                : TIMEOUT_CYCLES[31:0];
    reg [31:0] widx;               // word index
    reg [31:0] n_words;            // ceil(n_bytes/4)
    reg [2:0]  nbytes_w;           // valid bytes in current word
    reg [3:0]  bidx;               // byte index within word
    reg [3:0]  bitc;               // bit position within byte
    reg [7:0]  byte_val;
    reg [31:0] timeout_cnt;
    integer bi;

    // ---- fingerprint state ----
    reg [127:0] fp_raw;            // first four words (bytes 0..15)
    reg [127:0] fp_tail;           // rolling last-four-words shift register
    reg [31:0]  wcrc;              // window CRC state (parallel to crc_w)
    reg [1:0]   wbase_idx;         // index of the window being accumulated
    wire [4:0]  nb5 = (n_bytes >= 32'd16) ? 5'd16 : n_bytes[4:0];
    // n' = word-aligned file size; nrem_p = pad bytes inside the last word
    // (the SDRAM garbage region). fp_last slot i holds file byte (n'-16+i):
    //   valid <=> i >= max(0, 16-n')  AND  i + nrem_p < 16
    wire [31:0] nprime = (n_bytes + 32'd3) & 32'hFFFFFFFC;
    wire [1:0]  nrem_p = (4'd4 - n_bytes[1:0]) & 2'b11;

    wire [31:0] last_byte_addr = (n_bytes == 32'd0) ? 32'd0 : (n_bytes - 32'd1);
    wire [23:0] last_waddr = last_byte_addr[25:2];

    // ---- byte order: [31:24] = first file byte of the group ----
    always @(*) begin
        case (bidx)
            4'd0:    byte_val = wq[31:24];
            4'd1:    byte_val = wq[23:16];
            4'd2:    byte_val = wq[15:8];
            default: byte_val = wq[7:0];
        endcase
    end

    // reflected (IEEE) CRC32 step; the byte is merged into the top 8
    // bits on the FIRST bit step of its 8-step sequence (bitc==0)
    // Reflected (IEEE/LSB-first) CRC32: the byte merges into the LOW byte
    // of the accumulator; the high-byte variant is a different (broken)
    // hybrid against the reflected shift below.
    wire [31:0] crc_in = (bitc == 4'd0) ? (crc_w ^ {24'h0, byte_val}) : crc_w;
    wire [31:0] crc_step = (crc_in >> 1) ^ (crc_in[0] ? 32'hEDB88320 : 32'd0);
    // Window CRC: identical step, separate accumulator (restarted at each
    // 64 KB boundary; latched finalized at the boundary / run end).
    wire [31:0] wcrc_in  = (bitc == 4'd0) ? (wcrc ^ {24'h0, byte_val}) : wcrc;
    wire [31:0] wcrc_step = (wcrc_in >> 1) ^ (wcrc_in[0] ? 32'hEDB88320 : 32'd0);
    wire        wboundary = (widx == 32'd16384) || (widx == 32'd32768) ||
                            (widx == 32'd49152);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= ST_IDLE;
            rst_n_s1    <= 1'b0;
            rst_n_s2    <= 1'b0;
            start_done  <= 1'b0;
            req         <= 1'b0;
            req_addr    <= 24'd0;
            stuck       <= 1'b0;
            crc32       <= 32'd0;
            first_word  <= 32'd0;
            last_word   <= 32'd0;
            words_read  <= 16'd0;
            words_readout <= 16'd0;
            fp_first    <= 128'd0;
            fp_last     <= 128'd0;
            fp_w0       <= 32'd0;
            fp_w1       <= 32'd0;
            fp_w2       <= 32'd0;
            fp_w3       <= 32'd0;
        end else begin
            rst_n_s1 <= rst_n;
            rst_n_s2 <= rst_n_s1;

            if (!rst_n_s2) begin
                req <= 1'b0;
            end else begin
                req <= 1'b0;   // default; ST_REQ sets it

                case (st)
                ST_IDLE: begin
                    start_done <= 1'b0;
                    if (start) begin
                        start_done  <= 1'b1;
                        crc_w       <= 32'hFFFFFFFF;
                        if (FP_EN) begin
                            wcrc        <= 32'hFFFFFFFF;
                            wbase_idx   <= 2'd0;
                            fp_raw      <= 128'd0;
                            fp_tail     <= 128'd0;
                        end
                        widx        <= 32'd0;
                        stuck       <= 1'b0;
                        words_read  <= 16'd0;
                        // zero the displayed fingerprint immediately (a
                        // stuck run must not keep showing the old image)
                        fp_first    <= 128'd0;
                        fp_last     <= 128'd0;
                        fp_w0       <= 32'd0;
                        fp_w1       <= 32'd0;
                        fp_w2       <= 32'd0;
                        fp_w3       <= 32'd0;
                        if (n_bytes == 32'd0) begin
                            // empty file: CRC32 of zero bytes
                            crc32     <= 32'h00000000;
                            words_readout <= 16'd0;
                            st        <= ST_END;
                        end else begin
                            st <= ST_REQ;
                        end
                    end
                end

                ST_REQ: begin
                    start_done <= 1'b1;   // hold until start falls
                    req        <= 1'b1;   // level request
                    req_addr   <= widx[23:0];
                    if (rd_done && rd_data_ok) begin
                        wq          <= rd_data;
                        if (widx == 32'd0)
                            first_word <= rd_data;
                        if (widx == last_waddr)
                            last_word  <= rd_data;
                        // fingerprint: capture head/tail words; restart the
                        // window CRC when this word starts a new 64 KB window
                        // (finalizing the previous window first).
                        // head: fill from the top (word 0 -> bits [127:96]),
                        // tail: true 32-bit left shift (word K-1 ends in
                        // [31:0]); note {reg[127:32],x} would discard the
                        // low word on every shift.
                        if (FP_EN) begin
                            if (widx < 32'd4) begin
                                // slot k fills when widx==k; slots below k are
                                // still zero (never written). Every RHS must be
                                // exactly 128 bits or Verilog zero-extends the
                                // concatenation and the top slot silently dies.
                                case (widx)
                                    32'd0: fp_raw <= {rd_data, 96'd0};
                                    32'd1: fp_raw <= {fp_raw[127:96], rd_data,
                                                      64'd0};
                                    32'd2: fp_raw <= {fp_raw[127:96], fp_raw[95:64],
                                                      rd_data, 32'd0};
                                    default: fp_raw <= {fp_raw[127:96], fp_raw[95:64],
                                                        fp_raw[63:32], rd_data};
                                endcase
                            end
                            fp_tail     <= {fp_tail[95:0], rd_data};
                            if (wboundary) begin
                                case (wbase_idx)
                                    2'd0: fp_w0 <= wcrc ^ 32'hFFFFFFFF;
                                    2'd1: fp_w1 <= wcrc ^ 32'hFFFFFFFF;
                                    2'd2: fp_w2 <= wcrc ^ 32'hFFFFFFFF;
                                    default: fp_w3 <= wcrc ^ 32'hFFFFFFFF;
                                endcase
                                wcrc      <= 32'hFFFFFFFF;
                                // boundary words are 16384/32768/49152 = 2^14*k
                                wbase_idx <= widx[16:14];
                            end
                        end
                        words_read   <= words_read + 16'd1;
                        nbytes_w     <= (widx + 32'd1 == (n_bytes + 32'd3) >> 2)
                                        ? ((n_bytes & 32'd3) == 32'd0 ? 3'd4 : {1'b0, n_bytes[1:0]})
                                        : 3'd4;
                        bidx         <= 4'd0;
                        bitc         <= 4'd0;
                        timeout_cnt  <= 32'd0;
                        st           <= ST_CRC;
                    end else begin
                        if (timeout_cnt < tmo)
                            timeout_cnt <= timeout_cnt + 32'd1;
                        else begin
                            // bounded observable failure: stop, report
                            stuck <= 1'b1;
                            crc32 <= crc_w;
                            words_readout <= words_read;
                            start_done <= 1'b0;
                            st   <= ST_IDLE;
                        end
                    end
                end

                ST_CRC: begin
                    // 8 machine cycles per byte: reflected (IEEE) CRC32 step
                    crc_w <= crc_step;
                    if (FP_EN) wcrc <= wcrc_step;
                    if (bitc == 4'd7) begin
                        bitc <= 4'd0;
                        if (bidx + 4'd1 == {1'b0, nbytes_w}) begin
                            // word complete
                            if (widx + 32'd1 == (n_bytes + 32'd3) >> 2) begin
                                // final word: capture the POST-step value
                                // (the crc_w update above is an NBA - the
                                // old value would be one step short)
                                crc32         <= crc_step ^ 32'hFFFFFFFF;
                                words_readout <= words_read;
                                // finalize the last (partial or full) window
                                if (FP_EN) begin
                                    case (wbase_idx)
                                        2'd0: fp_w0 <= wcrc_step ^ 32'hFFFFFFFF;
                                        2'd1: fp_w1 <= wcrc_step ^ 32'hFFFFFFFF;
                                        2'd2: fp_w2 <= wcrc_step ^ 32'hFFFFFFFF;
                                        default: fp_w3 <= wcrc_step ^ 32'hFFFFFFFF;
                                    endcase
                                end
                                // head/tail bytes, zeroing bytes beyond EOF.
                                // fp_first slot i = file byte i      (valid i < n)
                                // fp_last  slot i = file byte n'-16+i (valid per
                                //   the nprime/nrem_p rule in the header)
                                for (bi = 0; bi < 16; bi = bi + 1) begin
                                    if (FP_EN) begin
                                        if (bi < nb5)
                                            fp_first[127 - bi*8 -: 8] <= fp_raw[127 - bi*8 -: 8];
                                        else
                                            fp_first[127 - bi*8 -: 8] <= 8'd0;
                                        if (((nprime >= 32'd16) ? 1'b1 :
                                             (bi[4:0] >= (16 - nprime[4:0]))) &&
                                            ({2'b00, bi[4:0]} + {3'd0, nrem_p}) < 5'd16)
                                            fp_last[127 - bi*8 -: 8] <= fp_tail[127 - bi*8 -: 8];
                                        else
                                            fp_last[127 - bi*8 -: 8] <= 8'd0;
                                    end
                                end
                                st            <= ST_END;
                            end else begin
                                widx <= widx + 32'd1;
                                st   <= ST_REQ;
                            end
                        end else begin
                            bidx <= bidx + 4'd1;
                            bitc <= 4'd0;
                        end
                    end else begin
                        bitc <= bitc + 4'd1;
                    end
                end

                ST_END: begin
                    // results held; host clears start, then sets it again
                    // to re-arm (start falls -> ST_IDLE -> ST_REQ on rise)
                    if (!start) begin
                        start_done <= 1'b0;
                        st <= ST_IDLE;
                    end
                end

                default: st <= ST_IDLE;
                endcase
            end
        end
    end

    assign busy = (st != ST_IDLE) && (st != ST_END);
    assign done = (st == ST_END);
    assign ok   = (st == ST_END) && !stuck;

endmodule
