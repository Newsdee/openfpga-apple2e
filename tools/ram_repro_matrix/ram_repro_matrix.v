// Inference matrix: which single change to the known-good PLAIN shape
// (ram_repro_plain: 3 regs / 524,288 bits, infers fine) breaks Quartus
// 17.0.2 M10K inference? One project, six independent RAMs; the per-
// instance 276007 warnings in the map log name the culprits.
//
//  u_a  exact plain (baseline)
//  u_b  plain + separate counter block (counter output used at top)
//  u_c  plain + muxed WRITE ADDRESS only
//  u_d  plain + muxed WRITE DATA only
//  u_e  plain + OR'd WRITE ENABLE only
//  u_f  plain + all three muxed + separate counter (the full v4 shape)
`timescale 1ns/1ps

module m_plain (
    input  wire        clk,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_plain_ctr (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata,
    output reg        cdone
);
    reg [7:0] ram [0:65535];
    reg [15:0] c;
    always @(posedge clk) begin
        if (sel) begin
            c     <= c + 16'd1;
            cdone <= (c == 16'hFFFF);
        end else begin
            c     <= 16'd0;
            cdone <= 1'b0;
        end
    end
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_mux_addr (
    input  wire        clk,
    input  wire        sel,
    input  wire [15:0] c,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    wire [15:0] wr_addr = sel ? c : waddr;
    always @(posedge clk) begin
        if (we) begin
            ram[wr_addr] <= wdata;
            rdata        <= wdata;
        end else
            rdata        <= ram[waddr];
    end
endmodule

module m_mux_data (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    wire [7:0] wr_data = sel ? 8'd0 : wdata;
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wr_data;
            rdata      <= wr_data;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_mux_en (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    wire wr_en = we | sel;
    always @(posedge clk) begin
        if (wr_en) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_full_v4 (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata,
    output reg        cdone
);
    reg [7:0] ram [0:65535];
    reg [15:0] c;
    always @(posedge clk) begin
        if (sel) begin
            c     <= c + 16'd1;
            cdone <= (c == 16'hFFFF);
        end else begin
            c     <= 16'd0;
            cdone <= 1'b0;
        end
    end
    wire [15:0] wr_addr = sel ? c : waddr;
    wire [7:0]  wr_data = sel ? 8'd0 : wdata;
    wire        wr_en   = sel | we;
    always @(posedge clk) begin
        if (wr_en) begin
            ram[wr_addr] <= wr_data;
            rdata        <= wr_data;
        end else
            rdata        <= ram[waddr];
    end
endmodule

module ram_repro_matrix (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output wire [7:0] r_a, output wire [7:0] r_b,
    output wire [7:0] r_c, output wire [7:0] r_d,
    output wire [7:0] r_e, output wire [7:0] r_f,
    output wire        cdone_b, output wire cdone_f
);
    // counter-value feed for u_c / u_f (register so it survives)
    reg [15:0] c_ext;
    always @(posedge clk) begin
        if (sel) c_ext <= c_ext + 16'd1; else c_ext <= 16'd0;
    end
    m_plain     u_a (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_a));
    m_plain_ctr u_b (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata),
                     .rdata(r_b), .cdone(cdone_b));
    m_mux_addr  u_c (.clk(clk), .sel(sel), .c(c_ext), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_c));
    m_mux_data  u_d (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_d));
    m_mux_en    u_e (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_e));
    m_full_v4   u_f (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata),
                     .rdata(r_f), .cdone(cdone_f));
endmodule
