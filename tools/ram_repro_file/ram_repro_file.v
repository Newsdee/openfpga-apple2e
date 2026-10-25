// ram_repro_file.v - candidate for the RAM zero-init experiment
// (TASK_RAM_FILE_INITIALIZATION_2026-10-25, Phase A).
//
// Same one-bank 64Kx8 RAM as ram_repro_init.v (ram_v_init): plain inferred
// single-port, write-first bypass, device 5CEBA4F23C8. The ONLY meaningful
// difference is the initialization representation: a $readmemh from the
// canonical zero image instead of the nested 256x256 procedural loop.
`timescale 1ns/1ps
module ram_v_file #(
    // Path relative to the run CWD. The canonical image is
    // src/fpga/rtl/roms/ram_zero_64k.hex; from this directory that is
    // ../../src/fpga/rtl/roms/. (Quartus runs from the project directory;
    // the TB runner uses the same CWD, so one path serves both.)
    // Untyped parameter defaulting to a string literal - the Verilog-2001
    // idiom (parameter string is rejected in .v files by Quartus 17, err
    // 10161; machine/rom.v uses the same idiom for FN).
    parameter HEX = "../../src/fpga/rtl/roms/ram_zero_64k.hex"
) (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata
);
    reg [7:0] ram [0:65535];
    initial $readmemh(HEX, ram);
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;      // write-first, as in the top
        end else
            rdata      <= ram[waddr];
    end
endmodule

module ram_repro_file (
    input  wire       clk,
    input  wire       we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output wire [7:0] rdata
);
    ram_v_file u_file (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                      .rdata(rdata));   // #() is rejected by Quartus 17 (10170)
endmodule
