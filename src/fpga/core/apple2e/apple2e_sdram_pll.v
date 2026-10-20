//
// apple2e_sdram_pll.v - second PLL: SDRAM clocks for the image-storage path
//
// Derives the three SDRAM clocks from the Pocket's 74.25 MHz main clock:
//   outclk_0 = 133.12 MHz  io_sdram controller clock
//   outclk_1 = 133.12 MHz  SDRAM chip clock
//   outclk_2 = 133.12 MHz  SDRAM chip clock, DDR capture phase (clk_90)
//
// Frequencies/phase shifts are the EXACT grid-legal values from the
// open-fpga core-example-basicassets reference (commit e5f9c0a, same
// 5CEBA4F23C8 device; pinned copy in refs/basicassets/), where this
// configuration is fit- and hardware-verified with the AS4C32M16MSA-6BIN
// (32Mx16, CAS3 at 166 MHz max). The io_sdram controller expects a
// chip clock in this range; do not "clean up" the values.
//
// EXCEPTION (M0 rework 2026-10-20): outclk_1 phase is 3756 ps (180 deg)
// instead of the reference's 6573 ps. Verilator sweep (tb_disk_store +
// tb_dram_model, 2 ns propagation both ways) shows the io_sdram read
// capture chain (enable_dq_read e4 window) only aligns when the chip-
// ctrl phase delta sits in a ~4.5 ns window of the 7.51 ns period;
// 180 deg is its center, robust to realistic command/DQ delays.
// (Reference actual phase was 225 deg per mf_pllbase.v gui info; our
// requested 6573 ps compiled to 315 deg on this device/grid.)
//
// The streaming core's existing apple2e_pll (mp1) has all four of its
// outputs in use; the 5CEBA4F23C8 has three PLLs, this is the second.
//
`timescale 1ns/10ps
module apple2e_sdram_pll (

    // interface 'refclk'
    input  wire refclk,     // 74.25 MHz (clk_74a)

    // interface 'reset'
    input  wire rst,

    // interface 'outclk0' - 133.12 MHz (io_sdram controller)
    output wire outclk_0,

    // interface 'outclk1' - 133.12 MHz (SDRAM chip clock)
    output wire outclk_1,

    // interface 'outclk2' - 133.12 MHz, DDR capture phase (clk_90)
    output wire outclk_2,

    // interface 'locked'
    output wire locked
);

    wire [4:0] outclk;

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(3),

        // outclk_0: io_sdram controller clock (basicassets outclk_2)
        .output_clock_frequency0("133.119993 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),

        // outclk_1: SDRAM chip clock (basicassets outclk_3)
        .output_clock_frequency1("133.119992 MHz"),
        .phase_shift1("3756 ps"),   // 180 deg: read-capture window center (see header)
        .duty_cycle1(50),

        // outclk_2: DDR capture clock (basicassets outclk_4)
        .output_clock_frequency2("133.119990 MHz"),
        .phase_shift2("5634 ps"),
        .duty_cycle2(50),

        // unused taps held at 0
        .output_clock_frequency3("0 MHz"),  .phase_shift3("0 ps"),  .duty_cycle3(50),
        .output_clock_frequency4("0 MHz"),  .phase_shift4("0 ps"),  .duty_cycle4(50),
        .output_clock_frequency5("0 MHz"),  .phase_shift5("0 ps"),  .duty_cycle5(50),
        .output_clock_frequency6("0 MHz"),  .phase_shift6("0 ps"),  .duty_cycle6(50),
        .output_clock_frequency7("0 MHz"),  .phase_shift7("0 ps"),  .duty_cycle7(50),
        .output_clock_frequency8("0 MHz"),  .phase_shift8("0 ps"),  .duty_cycle8(50),
        .output_clock_frequency9("0 MHz"),  .phase_shift9("0 ps"),  .duty_cycle9(50),
        .output_clock_frequency10("0 MHz"), .phase_shift10("0 ps"), .duty_cycle10(50),
        .output_clock_frequency11("0 MHz"), .phase_shift11("0 ps"), .duty_cycle11(50),
        .output_clock_frequency12("0 MHz"), .phase_shift12("0 ps"), .duty_cycle12(50),
        .output_clock_frequency13("0 MHz"), .phase_shift13("0 ps"), .duty_cycle13(50),
        .output_clock_frequency14("0 MHz"), .phase_shift14("0 ps"), .duty_cycle14(50),
        .output_clock_frequency15("0 MHz"), .phase_shift15("0 ps"), .duty_cycle15(50),
        .output_clock_frequency16("0 MHz"), .phase_shift16("0 ps"), .duty_cycle16(50),
        .output_clock_frequency17("0 MHz"), .phase_shift17("0 ps"), .duty_cycle17(50),

        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst        (rst),
        .outclk     (outclk),
        .locked     (locked),
        .fboutclk   ( ),
        .fbclk      (1'b0),
        .refclk     (refclk)
    );

    assign outclk_0 = outclk[0]; // 133.12 MHz (controller)
    assign outclk_1 = outclk[1]; // 133.12 MHz (chip)
    assign outclk_2 = outclk[2]; // 133.12 MHz (capture)

endmodule
