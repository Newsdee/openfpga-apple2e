//-------------------------------------------------------------------------------
// HDD firmware ROM (C600-C6FF), 256 x 8
//
// Verilog port of Apple-II_MiSTer/rtl/hdd_rom.vhd. Byte-exact: the ROM contents
// are $readmemh'd from src/fpga/rtl/roms/hddrom.hex, which was extracted 1:1
// from the VHDL constant (see verilog/hdd_equivalence/hdd_rom.hex, md5
// f41ec2dbcba586c565bfe073e051675e). The golden differential harness compares
// every one of the 256 bytes against the GHDL original.
//
// The VHDL is a registered read: dout <= ROM(addr) on the rising clock edge.
// The port preserves that (one cycle of read latency), so the equivalence TB
// observes identical D_OUT timing for firmware-ROM reads (IO_SELECT path).
//-------------------------------------------------------------------------------
module hdd_rom (
    input  [7:0] addr,
    input        clk,
    output reg [7:0] dout
);
    reg [7:0] rom [0:255];

    initial
        $readmemh("rtl/roms/hddrom.hex", rom);

    always @(posedge clk)
        dout <= rom[addr];
endmodule
