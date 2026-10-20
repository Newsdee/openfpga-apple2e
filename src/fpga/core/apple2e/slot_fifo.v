//
// slot_fifo.v - dual-clock record FIFO for the image-slot load path (M0 rework)
//
// Write side:  clk_74a (74.25 MHz) - one record per bridge word write
// Read side:   sdram_ctrl_clk (133.12 MHz) - store owner consumes records
//
// Entry: {wr_addr[23:0], wr_data[31:0]} - a complete {address, data} record.
// This FIFO is the ONLY CDC boundary in the storage path: the store owner
// (controller domain) latches the payload on acceptance, so the SDRAM
// controller never samples a source-domain bus (expert M0 review, finding 1).
//
// Contract:
//  - wr side: pulse wr_en for exactly one wr_clk period per record.
//    A write is accepted iff !full at the sampling posedge; otherwise the
//    record is DROPPED and `overflow` latches sticky (observable, never
//    silent). In practice the host load is gated on SDRAM init
//    (setup_done), so the FIFO never has to absorb the boot window.
//  - rd side: `empty` is combinational; pulse rd_en (one rd_clk) when !empty;
//    the record appears on rd_addr/rd_data with rd_valid pulsed.
//  - rst: async, write domain (core power/PLL-lock POR). The read domain is
//    reset through a 2-stage synchronizer (rd_rst_s2); while asserted it
//    holds the read pointer and read path, so reset release can never leave
//    the pointers desynchronized. A machine reset must NOT be applied here
//    - the resident image survives it.
//  - high_water: maximum occupancy ever reached (for the hardware capture).
//
// Structure: classic Clifford async FIFO (binary pointers, Gray sync of the
// CURRENT pointers), 64 x 56-bit entries in block RAM.
//   full  = wr_gray == {~rd_gray_s[MSB], ~rd_gray_s[MSB-1], rd_gray_s[rest]}
//   empty = rd_gray == wr_gray_s
//
`timescale 1ns/10ps
module slot_fifo #(parameter DEPTH = 64) (
    // ---- write side (clk_74a) ----
    input  wire             wr_clk,
    input  wire             rst,          // async reset, write domain
    input  wire             wr_en,
    input  wire [23:0]      wr_addr,
    input  wire [31:0]      wr_data,
    input  wire             overflow_clr,   // level: clear sticky flag (new load generation)
    output wire             full,
    output reg              overflow,     // sticky: wr_en asserted while full
    output reg  [6:0]       high_water,   // max occupancy seen (0..64)

    // ---- read side (sdram_ctrl_clk) ----
    input  wire             rd_clk,
    output wire             empty,
    input  wire             rd_en,
    output wire             rd_valid,     // record present on rd_addr/rd_data
    output reg  [23:0]      rd_addr,
    output reg  [31:0]      rd_data
);

    localparam AW = 6;                    // log2(DEPTH)
    localparam PW = AW + 1;               // pointer width (wrap bit)

    // ---- storage: one write / one read port (inferred dual-port M10K) ----
    reg [55:0] mem [0:DEPTH-1];
    reg        rd_pend;

    always @(posedge wr_clk) begin
        if (wr_en && !full)
            mem[wr_ptr[AW-1:0]] <= {wr_addr, wr_data};
    end

    always @(posedge rd_clk) begin
        if (rd_rst_s2) begin
            rd_addr <= 24'd0;
            rd_data <= 32'd0;
            rd_pend <= 1'b0;
        end else if (rd_en && !empty) begin
            rd_addr <= mem[rd_ptr[AW-1:0]][55:32];
            rd_data <= mem[rd_ptr[AW-1:0]][31:0];
            rd_pend <= 1'b1;
        end else begin
            rd_pend <= 1'b0;
        end
    end
    assign rd_valid = rd_pend;

    // ---- write pointer: publish gray of the CURRENT registered pointer ----
    reg  [PW-1:0] wr_ptr;
    wire [PW-1:0] wr_ptr_next = wr_ptr + 1'b1;
    wire [PW-1:0] wr_gray     = wr_ptr ^ (wr_ptr >> 1);

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= {PW{1'b0}};
            high_water <= 7'd0;
        end else if (wr_en && !full) begin
            wr_ptr <= wr_ptr_next;
            // high-water: occupancy as seen at write acceptance
            // (wr_ptr_next vs synced read pointer; same-cycle, no NBA lag)
            if (wr_ptr_next - rd_bin_s > high_water)
                high_water <= wr_ptr_next - rd_bin_s;
        end
    end

    // ---- read pointer (synchronized reset; no async reset on this clock) ----
    reg [PW-1:0] rd_ptr;
    wire [PW-1:0] rd_ptr_next = rd_ptr + 1'b1;
    wire [PW-1:0] rd_gray     = rd_ptr ^ (rd_ptr >> 1);

    reg rd_rst_s1, rd_rst_s2;
    always @(posedge rd_clk) begin
        rd_rst_s1 <= rst;
        rd_rst_s2 <= rd_rst_s1;
    end

    always @(posedge rd_clk) begin
        if (rd_rst_s2)
            rd_ptr <= {PW{1'b0}};
        else if (rd_en && !empty)
            rd_ptr <= rd_ptr_next;
    end

    // ---- Gray sync (2FF each direction) ----
    reg [PW-1:0] wr_gray_s1, wr_gray_s2;   // wr_gray in rd domain
    reg [PW-1:0] rd_gray_s1, rd_gray_s2;   // rd_gray in wr domain

    always @(posedge rd_clk) begin
        wr_gray_s1 <= wr_gray;
        wr_gray_s2 <= wr_gray_s1;
    end
    always @(posedge wr_clk) begin
        rd_gray_s1 <= rd_gray;
        rd_gray_s2 <= rd_gray_s1;
    end

    // ---- full / empty (textbook: current pointers) ----
    assign full  = (wr_gray == {~rd_gray_s2[PW-1], ~rd_gray_s2[PW-2],
                                rd_gray_s2[PW-3:0]});
    assign empty = (rd_gray == wr_gray_s2);

    // ---- overflow (sticky, write domain; set wins over same-cycle clear) ----
    always @(posedge wr_clk or posedge rst) begin
        if (rst)
            overflow <= 1'b0;
        else if (wr_en && full)
            overflow <= 1'b1;
        else if (overflow_clr)
            overflow <= 1'b0;
    end

    // ---- high-water mark (write domain) ----
    function [PW-1:0] gray2bin;
        input [PW-1:0] g;
        integer i;
        begin
            gray2bin[PW-1] = g[PW-1];
            for (i = PW-2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [PW-1:0] rd_bin_s = gray2bin(rd_gray_s2);

endmodule
