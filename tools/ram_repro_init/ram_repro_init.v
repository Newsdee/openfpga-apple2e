// Single-variant bisect: plain RAM + initial zero-fill only (power-on state).
`timescale 1ns/1ps
module ram_v_init (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata
);
    reg [7:0] ram [0:65535];
    integer ra;
    integer rb;
    initial begin
        for (ra = 0; ra < 256; ra = ra + 1) begin
            for (rb = 0; rb < 256; rb = rb + 1)
                ram[{ra[7:0], rb[7:0]}] = 8'd0;
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
module ram_repro_init (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata
);
    ram_v_init u_init (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                       .rdata(rdata));
endmodule
