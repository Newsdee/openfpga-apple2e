//
// ram_repro.v - isolated Quartus A&S reproducer for the machine-RAM clear
// question raised by the external expert review (2026-10-24).
//
// Four independent 64K x 8 inferred RAMs, each with the SAME normal
// read/write behavior as the streaming top's ram_main/ram_aux, differing
// only in how (or whether) the "clear both banks" operation is described:
//
//   v_plain  - the M1 structure: clocked always, single write, no clear.
//              (Known good: the green M1 build.)
//   v_init   - plain + initial zero-fill (the power-on state block).
//   v_async  - the FAILED structure (commit 9085041 era): `or posedge
//              ram_clear` in the sensitivity list + nested 256x256
//              whole-array clear + initial. This is the code Quartus
//              accepted in A&S (reaching TDS) after which the full-core
//              clean A&S went abnormally slow, and which the expert
//              review says maps to an unsupported M10K content clear.
//   v_sweep  - the NEW structure (this commit): clock-only always, a 16-bit
//              counter walking 0..65535 writing zero one address per
//              cycle while ram_clear is high, + initial zero-fill.
//
// `ram_clear` is a top INPUT so Quartus cannot constant-fold the clear
// branches away; the variants must show up in the map report as-is.
//
// What to look for (quartus_map only - no fit needed):
//   * A&S wall time (the full core clean A&S went >10 min silent in TDS;
//     this design is ~1/40th the scale, so a healthy A&S should finish in
//     well under a minute).
//   * Per-hierarchy map summary: registers and block-memory bits per
//     variant. v_plain/v_init/v_sweep should show ~512K block-memory bits
//     and a handful of registers each. If v_async shows ~524,288 logic
//     registers (inference demoted) or its own clear-controller logic,
//     that is the smoking gun; if it shows a clean M10K, the async idiom
//     IS inferred and the TDS grind has a different cause.
//   * "uninferred RAM" warnings in the map log per hierarchy.

`timescale 1ns/1ps

// ------------------------------------------------------------------
// v_plain: the M1 structure (known good)
// ------------------------------------------------------------------
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

// ------------------------------------------------------------------
// v_init: plain + initial zero-fill (power-on state block only)
// ------------------------------------------------------------------
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

// ------------------------------------------------------------------
// v_async: the failed whole-array async clear (the disputed idiom).
// Structure mirrors the top's commit-9085041 RAM block exactly
// (sensitivity-list clear + nested 256x256 + initial).
// ------------------------------------------------------------------
module ram_v_async (
    input  wire       clk,
    input  wire       ram_clear,
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
    always @(posedge clk or posedge ram_clear) begin
        if (ram_clear) begin
            for (ra = 0; ra < 256; ra = ra + 1) begin
                for (rb = 0; rb < 256; rb = rb + 1)
                    ram[{ra[7:0], rb[7:0]}] <= 8'd0;
            end
        end else begin
            if (we) begin
                ram[waddr] <= wdata;
                rdata      <= wdata;
            end else
                rdata      <= ram[waddr];
        end
    end
endmodule

// ------------------------------------------------------------------
// v_sweep: the new sequential write-sweep (the shipping design)
// ------------------------------------------------------------------
module ram_v_sweep (
    input  wire       clk,
    input  wire       ram_clear,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    output reg        clear_done
);
    reg [7:0] ram [0:65535];
    reg [15:0] clr_addr;
    integer ra;
    integer rb;
    initial begin
        for (ra = 0; ra < 256; ra = ra + 1) begin
            for (rb = 0; rb < 256; rb = rb + 1)
                ram[{ra[7:0], rb[7:0]}] = 8'd0;
        end
    end
    always @(posedge clk) begin
        if (ram_clear) begin
            clr_addr   <= clr_addr + 16'd1;
            ram[clr_addr] <= 8'd0;
            clear_done <= (clr_addr == 16'hFFFF);
        end else begin
            clr_addr   <= 16'd0;
            clear_done <= 1'b0;
            if (we) begin
                ram[waddr] <= wdata;
                rdata      <= wdata;
            end else
                rdata      <= ram[waddr];
        end
    end
endmodule

// ------------------------------------------------------------------
// top: all four variants, driven from shared ports. `ram_clear` and
// `we` are inputs so the clear/write branches survive optimization.
// ------------------------------------------------------------------
module ram_repro (
    input  wire       clk,
    input  wire       ram_clear,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata_plain,
    output wire [7:0] rdata_init,
    output wire [7:0] rdata_async,
    output wire [7:0] rdata_sweep,
    output wire       clear_done
);
    ram_v_plain u_plain (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .rdata(rdata_plain)
    );
    ram_v_init u_init (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .rdata(rdata_init)
    );
    ram_v_async u_async (
        .clk(clk), .ram_clear(ram_clear), .we(we),
        .waddr(waddr), .wdata(wdata),
        .rdata(rdata_async)
    );
    ram_v_sweep u_sweep (
        .clk(clk), .ram_clear(ram_clear), .we(we),
        .waddr(waddr), .wdata(wdata),
        .rdata(rdata_sweep), .clear_done(clear_done)
    );
endmodule
