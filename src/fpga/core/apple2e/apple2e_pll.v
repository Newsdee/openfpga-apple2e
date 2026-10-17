//
// apple2e_pll.v - static PLL tree for the Apple IIe Pocket core
//
// Derives the four core clocks from the Pocket's 74.25 MHz main clock:
//   outclk_0 = 14.318 MHz   Apple IIe CPU clock (6502/65C02, NTSC)
//   outclk_1 = 12.288 MHz   video pixel clock (240p @ 60 Hz), 0 deg
//   outclk_2 = 12.288 MHz   video pixel clock, 90 deg (DDR video bus)
//   outclk_3 = 3.072 MHz    audio clock
//
// All three are non-integer divisions of 74.25 MHz, so a fractional PLL is
// required (fractional_vco_multiplier = "true"), exactly as the template's
// mf_pllbase does for 12.288 MHz. The frequencies are given as strings;
// Quartus infers the fractional PLL configuration from them at compile time.
//
// The instance mirrors the template's mf_pllbase_0002.v altera_pll usage so
// the same Quartus megafunction resolution path is taken (verified in P0:
// altera_pll resolves from quartus/libraries/megafunctions/altera_pll.v).
//
// Static only (no dynamic reconfiguration) per KB-015 - v1 has a single
// fixed clock set.
//
`timescale 1ns/10ps
module apple2e_pll (

    // interface 'refclk'
    input  wire refclk,     // 74.25 MHz

    // interface 'reset'
    input  wire rst,

    // interface 'outclk0' - 14.318 MHz (CPU)
    output wire outclk_0,

    // interface 'outclk1' - 12.288 MHz (video pixel + audio MCLK base)
    output wire outclk_1,

    // interface 'outclk2' - 12.288 MHz, 90 deg (DDR video bus)
    output wire outclk_2,

    // interface 'outclk3' - 3.072 MHz (audio)
    output wire outclk_3,

    // interface 'locked'
    output wire locked
);

    wire [4:0] outclk;

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(4),

        // outclk_0: Apple IIe CPU clock.
        // NOTE: "14.318 MHz" is not on the PLL output-frequency grid; the
        // Fitter rejects it and reports 14311905 Hz as the legal value
        // (0.04% lower -> CPU runs at 1.02228 MHz instead of 1.02271 MHz,
        // imperceptible; all video/audio timing is on the other outputs).
        .output_clock_frequency0("14311905 Hz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),

        // outclk_1: video pixel clock (240p @ 60 Hz), 0 deg
        .output_clock_frequency1("12.288 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),

        // outclk_2: video pixel clock, 90 deg (DDR video bus).
        // Phase is quantized to a 207.75 ps grid; 20345 ps is the legal value
        // nearest quarter-period (81408/4 = 20352 ps) - same as the template.
        .output_clock_frequency2("12.288 MHz"),
        .phase_shift2("20345 ps"),
        .duty_cycle2(50),

        // outclk_3: audio clock
        .output_clock_frequency3("3.072 MHz"),
        .phase_shift3("0 ps"),
        .duty_cycle3(50),

        // unused taps held at 0
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

    assign outclk_0 = outclk[0]; // 14.318 MHz (CPU)
    assign outclk_1 = outclk[1]; // 12.288 MHz (video pixel, 0 deg)
    assign outclk_2 = outclk[2]; // 12.288 MHz (video pixel, 90 deg)
    assign outclk_3 = outclk[3]; // 3.072 MHz (audio)

endmodule
