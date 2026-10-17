`timescale 1ns/10ps
// ramtest.v - minimal replica of the apf_video pix_ram access pattern
// (dual-clock, 16-bit addr, 8-bit data, MUX on the read) to bisect the
// Quartus 17 RAM-inference failure (276007 "asynchronous read logic").
module ramtest (
    input  wire        clk_a,      // write clock (14.318 domain)
    input  wire        rst_a,
    input  wire        clk_b,      // read clock (12.288 domain)
    input  wire        rst_b,
    input  wire        video_in,
    input  wire        hbl,
    input  wire        frame_flip,
    input  wire [1:0]  dbuf_in,    // display buffer select (read addr bit)
    input  wire [9:0]  nline_in,   // latched native line (read addr)
    input  wire [9:0]  x_in,       // output pixel x
    input  wire        scr_in,
    input  wire [9:0]  capl_in,
    output reg  [7:0]  pxw_out
);

    localparam PIX_WORDS = 70;
    reg [7:0] pix_ram [0:2*256*PIX_WORDS-1];

    // --- write side (clk_a) ---
    reg [1:0] wbuf;
    reg [8:0] vline;
    reg [6:0] px_word;
    reg [2:0] px_bit;
    reg [7:0] px_acc;
    reg hbl_r;
    wire line_start = hbl_r & ~hbl;
    wire line_end   = ~hbl_r & hbl;
    wire [15:0] pix_wr_addr = {wbuf[0], vline[7:0], px_word[6:0]};

    always @(posedge clk_a or posedge rst_a) begin
        if (rst_a) begin
            wbuf <= 2'd0; vline <= 9'd0; px_word <= 7'd0;
            px_bit <= 3'd0; px_acc <= 8'd0; hbl_r <= 1'b0;
        end else begin
            hbl_r <= hbl;
            if (line_start) begin
                px_word <= 7'd0; px_bit <= 3'd0; px_acc <= 8'd0;
            end else if (!hbl) begin
                if (px_bit == 3'd7) begin
                    pix_ram[pix_wr_addr] <= {video_in, px_acc[7:1]};
                    px_acc  <= video_in;
                    px_word <= px_word + 7'd1;
                    px_bit  <= 3'd0;
                end else begin
                    px_acc <= {video_in, px_acc[7:1]};
                    px_bit <= px_bit + 3'd1;
                end
            end
            if (line_end && vline < 9'd191) vline <= vline + 9'd1;
            if (frame_flip) wbuf <= ~wbuf;
        end
    end

    // --- read side (clk_b): MUX + constant-division-derived address ---
    wire [19:0] px_prod  = x_in * capl_in;
    wire [9:0]  pidx_c   = scr_in ? px_prod / 20'd320 : 10'd0;
    always @(posedge clk_b or posedge rst_b) begin
        if (rst_b)
            pxw_out <= 8'd0;
        else
            pxw_out <= pix_ram[{dbuf_in[0], nline_in[7:0], pidx_c[9:3]}];
    end

endmodule
