// RAM-clear sweep reproducer - v5 (the shipping structure, 2026-10-24).
//
// v1-v4 history (all FAILED inference - Error 276003 + 276007
// "uninferred due to asynchronous read logic" -> ~500K logic registers):
//   v1: if/else, two writes at different addresses in exclusive branches
//   v2: one muxed write port, read in a separate always block
//   v3: one muxed write port + unconditional bypass read, one block
//   v4: plain if/else shape with muxed write address
// Inference matrix (tools/ram_repro_matrix) isolated the poison:
//   PASS  plain / plain+counter-block / muxed write DATA / OR'd write ENABLE
//   FAIL  muxed write ADDRESS (alone or with the others)
// => v5 = the shipping design itself: the RAM block stays byte-identical
//    to the proven M1 shape (plain single-port, per-bank enable,
//    write-first bypass); the sweep walks the bus (we/addr/aux) through
//    a combinational overlay OUTSIDE the RAM block, driven by the real
//    ram_sweep_ctl module. Two banks (main + aux), one 65,536-address
//    pass each = 131,072 write cycles.
//
// Expect: Analysis & Synthesis Successful, ~1,048,576 block memory bits
// (2 x M10K), a few dozen registers, no 276003/276007.

`timescale 1ns/1ps
module ram_repro_sweep (
    input  wire        clk,
    input  wire        start,     // sweep start (reboot_ctl ram_clear equivalent)
    input  wire        we,        // machine write
    input  wire        aux,       // machine bank select
    input  wire [15:0] waddr,     // machine address
    input  wire [7:0]  wdata,     // machine data
    output reg [15:0]  rdata,
    output wire        done       // sweep complete (level while start high)
);
    // ---- bus overlay (exactly the streaming top's wiring) ----
    wire        swp_we, swp_aux, swp_done;
    wire [15:0] swp_addr;
    wire [15:0] waddr_f = swp_we ? swp_addr : waddr;
    wire [7:0]  wdata_f = swp_we ? 8'd0 : wdata;
    wire        we_f    = swp_we | we;
    wire        aux_f   = swp_we ? swp_aux : aux;

    // ---- RAM block: the proven M1 shape (plain single-port per bank,
    //      write-first bypass) - never sees a conditional write address
    reg [7:0] ram_main [0:65535];
    reg [7:0] ram_aux  [0:65535];
    always @(posedge clk) begin
        if (we_f & ~aux_f) begin
            ram_main[waddr_f] <= wdata_f;
            rdata[7:0]        <= wdata_f;
        end else rdata[7:0]  <= ram_main[waddr_f];
        if (we_f & aux_f) begin
            ram_aux[waddr_f] <= wdata_f;
            rdata[15:8]      <= wdata_f;
        end else rdata[15:8]  <= ram_aux[waddr_f];
    end

    // ---- the real shipping sweep controller ----
    ram_sweep_ctl u_ctl (
        .clk(clk), .start(start),
        .we(swp_we), .addr(swp_addr), .aux(swp_aux), .done(swp_done)
    );
    assign done = swp_done;
endmodule
