//
// apf_stream_proto_pll.v - Phase 1 streaming-prototype PLL
//
// A separately-selectable PLL for the streaming-pattern prototype build.
// Derives the prototype's clocks from the Pocket's 74.25 MHz main clock:
//   outclk_0 = 14.318 MHz   native Apple II video pixel clock, 0 deg
//   outclk_1 = 14.318 MHz   same, 90 deg (APF DDR video bus clock pad)
//   outclk_2 = 3.072 MHz    audio SCLK base (kept so the audio generator
//                           in the prototype top still works)
//
// The 90-degree phase shift is quantized to the PLL's legal grid; the
// quarter-period of 14.318 MHz is ~17,460 ps, and 17,468 ps is the legal
// grid value nearest to it (7 ps off, per the Fitter's legal-value list).
// Mirrors the template's treatment of the 12.288 MHz 90-degree tap.
//
// EXPERIMENTAL: only used by the Phase 1 prototype build (apf_stream_proto.qsf).
//
`timescale 1ns/10ps

module apf_stream_proto_pll (
    input  wire refclk,   // 74.25 MHz
    input  wire rst,
    output wire outclk_0, // 14.318 MHz, 0 deg (APF pixel clock)
    output wire outclk_1, // 14.318 MHz, 90 deg (APF DDR clock pad)
    output wire outclk_2, // 3.072 MHz (audio base)
    output wire locked
);

    wire [4:0] outclk;

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(3),

        .output_clock_frequency0("14311905 Hz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),

        .output_clock_frequency1("14311905 Hz"),
        .phase_shift1("17468 ps"),
        .duty_cycle1(50),

        .output_clock_frequency2("3.072 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),

        .output_clock_frequency3("0 MHz"), .phase_shift3("0 ps"), .duty_cycle3(50),
        .output_clock_frequency4("0 MHz"), .phase_shift4("0 ps"), .duty_cycle4(50),
        .output_clock_frequency5("0 MHz"), .phase_shift5("0 ps"), .duty_cycle5(50),
        .output_clock_frequency6("0 MHz"), .phase_shift6("0 ps"), .duty_cycle6(50),
        .output_clock_frequency7("0 MHz"), .phase_shift7("0 ps"), .duty_cycle7(50),
        .output_clock_frequency8("0 MHz"), .phase_shift8("0 ps"), .duty_cycle8(50),
        .output_clock_frequency9("0 MHz"), .phase_shift9("0 ps"), .duty_cycle9(50),
        .output_clock_frequency10("0 MHz"),.phase_shift10("0 ps"),.duty_cycle10(50),
        .output_clock_frequency11("0 MHz"),.phase_shift11("0 ps"),.duty_cycle11(50),
        .output_clock_frequency12("0 MHz"),.phase_shift12("0 ps"),.duty_cycle12(50),
        .output_clock_frequency13("0 MHz"),.phase_shift13("0 ps"),.duty_cycle13(50),
        .output_clock_frequency14("0 MHz"),.phase_shift14("0 ps"),.duty_cycle14(50),
        .output_clock_frequency15("0 MHz"),.phase_shift15("0 ps"),.duty_cycle15(50),
        .output_clock_frequency16("0 MHz"),.phase_shift16("0 ps"),.duty_cycle16(50),
        .output_clock_frequency17("0 MHz"),.phase_shift17("0 ps"),.duty_cycle17(50),

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

    assign outclk_0 = outclk[0];
    assign outclk_1 = outclk[1];
    assign outclk_2 = outclk[2];

endmodule
