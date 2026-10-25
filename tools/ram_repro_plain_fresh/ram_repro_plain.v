//
// ram_repro_plain.v - the "revert to the previous version" test, made cheap.
//
// Contains ONLY ram_v_plain: the exact RAM structure of the last fully-green
// M1 build (plain inferred 64K x 8 M10K, write-first, no clear, no initial).
// If even this single-RAM clean A&S grinds for 20+ minutes on this host,
// the slow-clean-A&S behavior is host/tool-level and independent of every
// closeout RTL change (sweep, async idiom, initial, reboot logic all absent).
// If it finishes in seconds, the grind correlates with the other variants in
// ram_repro.v and we re-focus there.

`timescale 1ns/1ps

module ram_v_plain (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata
);
    reg [7:0] ram [0:65535];
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;      // write-first, as in the top
        end else
            rdata      <= ram[waddr];
    end
endmodule

module ram_repro_plain (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata
);
    ram_v_plain u_plain (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .rdata(rdata)
    );
endmodule
