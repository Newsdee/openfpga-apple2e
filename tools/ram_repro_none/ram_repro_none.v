// ram_repro_none.v - "no initialization" probe (2026-10-25 review add-on).
//
// Same one-bank 64Kx8 RAM as ram_repro_plain.v (ram_v_plain) - the only
// difference is that the PLAIN probe is also the no-initialization probe;
// this file exists to make the experiment set self-documenting:
//
//   ram_repro_plain  : RAM, no initial block        (A&S ~10 s, 10-24)
//   ram_repro_none   : RAM, no initial block        (this file; fresh run
//                      to confirm the 10-24 plain number still holds)
//   ram_repro_init   : RAM + nested 256x256 zero loop (A&S 19:12, 10-24)
//   ram_repro_file   : RAM + $readmemh zero image   (candidate)
//
// If none ~ plain and both are ~10x faster than init, the A&S cost is in
// processing the initialization representation itself (procedural loop or
// file merge), and the owner's follow-up question - M10K power-up contents
// + the runtime clearing sweep making build-time init unnecessary - becomes
// a data-backed hardware-verified decision, NOT a number manufactured by
// deleting initialization from the shipping core.
`timescale 1ns/1ps
module ram_v_none (
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

module ram_repro_none (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata
);
    ram_v_none u_none (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                       .rdata(rdata));
endmodule
