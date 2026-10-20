//
// disk_store.v - store-transaction owner for the image-slot load path
// (M0 rework, Unit 3)
//
// Sits between slot_fifo (record source) and the io_sdram_pocket word
// port. ALL signals are in the controller clock domain (133.12 MHz):
//  - the FIFO read port is synchronous (its read side runs on this clock)
//  - the word port is synchronous in this domain (expert M0 review,
//    finding 1: the controller's raw payload reads are safe here, and
//    the store owner additionally LATCHES the payload on acceptance,
//    so the word-port inputs never change mid-operation)
//
// Protocol:
//  - Waits for init_done (io_sdram_pocket.boot_done) before anything.
//  - Consumes FIFO records one at a time: 1-cycle fifo_rd_en pulse,
//    latches {addr,data} on fifo_rd_valid.
//  - Issues exactly ONE word_wr pulse per record and waits for
//    word_done. (io_sdram's request queue is a single bit - a second
//    write issued before completion would be silently lost.)
//  - Counters: words_received (from FIFO), words_committed (word_done).
//  - timeout: latches if any single word op exceeds TIMEOUT_CYCLES
//    (bounded observable failure; a normal op is ~20 cycles, and
//    auto-refresh insertion can add ~15 more).
//  - load_drained: init done, FIFO empty, no op in flight, and every
//    received word committed.
//
// Reset: rst_n is an async crossing signal (core power/PLL-lock POR in
// another domain); it is used async for the state clear and
// 2-stage-synchronized for the sequential logic, so reset release can
// never tear. Machine reset must NOT be routed here - the resident
// image survives it (only core power/PLL-lock resets this path).
//
`timescale 1ns/10ps
module disk_store #(parameter TIMEOUT_CYCLES = 4096) (
    input  wire             clk,        // sdram_ctrl_clk (133.12 MHz)
    input  wire             rst_n,      // core POR, async crossing

    // ---- FIFO read port (same domain) ----
    input  wire             fifo_empty,
    output reg              fifo_rd_en,
    input  wire             fifo_rd_valid,
    input  wire [23:0]      fifo_rd_addr,
    input  wire [31:0]      fifo_rd_data,

    // ---- word port (io_sdram_pocket, same domain) ----
    output reg              word_wr,
    output reg  [23:0]      word_addr,
    output reg  [31:0]      word_data,
    input  wire             word_busy,
    input  wire             word_done,
    input  wire             init_done,

    // ---- status / observability ----
    output wire             store_busy,      // op in flight or pending
    output wire             load_drained,    // store path fully quiescent
    output reg  [23:0]      words_received,  // records consumed from FIFO (24-bit: 4 MiB slot = 1 MiB words, no wrap)
    output reg  [23:0]      words_committed, // word_done pulses counted
    output reg              timeout,         // sticky: op exceeded deadline
    input  wire             timeout_clr      // level: clear sticky latch (new load generation)
);

    localparam ST_IDLE      = 2'd0;
    localparam ST_FETCH     = 2'd1;   // rd_en pulsed, waiting rd_valid
    localparam ST_READY     = 2'd2;   // record latched, waiting word port free
    localparam ST_WAIT_DONE = 2'd3;   // word_wr issued, waiting word_done

    reg [1:0] st;
    reg       rst_n_s1, rst_n_s2;
    reg [15:0] timeout_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st              <= ST_IDLE;
            rst_n_s1        <= 1'b0;
            rst_n_s2        <= 1'b0;
            fifo_rd_en      <= 1'b0;
            word_wr         <= 1'b0;
            word_addr       <= 24'd0;
            word_data       <= 32'd0;
            words_received  <= 24'd0;
            words_committed <= 24'd0;
            timeout_cnt     <= 16'd0;
            timeout         <= 1'b0;
        end else begin
            rst_n_s1 <= rst_n;
            rst_n_s2 <= rst_n_s1;

            // hold safe values while the synchronized reset clears
            if (!rst_n_s2) begin
                fifo_rd_en <= 1'b0;
                word_wr    <= 1'b0;
            end else begin
                fifo_rd_en <= 1'b0;   // defaults; overridden below
                word_wr    <= 1'b0;
                if (timeout_clr)
                    timeout <= 1'b0;  // gen-start clear; a same-cycle set wins (below)

                case (st)
                ST_IDLE: begin
                    if (init_done && !fifo_empty) begin
                        fifo_rd_en <= 1'b1;   // 1-cycle fetch pulse
                        st           <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    if (fifo_rd_valid) begin
                        // LATCH the payload here: the word port must never
                        // sample a bus that can change under it
                        word_addr      <= fifo_rd_addr;
                        word_data      <= fifo_rd_data;
                        words_received <= words_received + 24'd1;
                        if (!word_busy) begin
                            word_wr <= 1'b1;   // 1-cycle request pulse
                            st      <= ST_WAIT_DONE;
                        end else begin
                            st <= ST_READY;    // record latched; wait for port
                        end
                    end
                end

                ST_READY: begin
                    if (!word_busy) begin
                        word_wr <= 1'b1;
                        timeout_cnt <= 16'd0;
                        st      <= ST_WAIT_DONE;
                    end
                end

                ST_WAIT_DONE: begin
                    if (word_done) begin
                        words_committed <= words_committed + 24'd1;
                        timeout_cnt     <= 16'd0;
                        st              <= ST_IDLE;
                    end else begin
                        if (timeout_cnt < TIMEOUT_CYCLES[15:0])
                            timeout_cnt <= timeout_cnt + 16'd1;
                        else
                            timeout <= 1'b1;   // latch; keep waiting for done
                    end
                end

                default: st <= ST_IDLE;
                endcase
            end
        end
    end

    assign store_busy   = (st != ST_IDLE) || word_busy;
    assign load_drained = init_done && fifo_empty && !store_busy
                          && (words_received == words_committed);

endmodule
