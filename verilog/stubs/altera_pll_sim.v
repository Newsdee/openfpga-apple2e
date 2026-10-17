// altera_pll_sim.v - behavioral stand-in for the Quartus altera_pll IP used by
// the apple2e core (core/apple2e/apple2e_pll.v): 74.25 MHz -> 14.318 (CPU) /
// 12.288 (video 0deg) / 12.288 (video 90deg) / 3.072 (audio) MHz.
//
// The vendor simulation model (quartus/eda/sim_lib) pulls in a long chain of
// family-specific modules that Verilator cannot resolve, so this stub
// reproduces the interface and the four clocks the apple2e core uses:
//   outclk[0] = 14.318 MHz (CPU)
//   outclk[1] = 12.288 MHz (video pixel, 0 deg)
//   outclk[2] = 12.288 MHz (video pixel, 90 deg - quarter-period phase offset)
//   outclk[3] = 3.072 MHz  (audio)
//   outclk[4] = tied low (unused)
//
// Frequency method: 24-bit NCO per output. Each 74.25 MHz refclk cycle adds the
// frequency step K; the clock toggles on carry out of the phase. Average output
// = 74.25 MHz * K / 2^24, so the frequencies are accurate to <0.01%.
//
// All configuration parameters are declared so the instance's parameter
// assignments resolve; values are irrelevant to the behavioral model.
module altera_pll (
    input  wire        refclk,
    input  wire        rst,
    output reg  [4:0]  outclk,
    output reg         locked,
    output wire        fboutclk,
    input  wire        fbclk
);
    // ---- configuration parameters (set by mf_pllbase_0002.v) ----
    parameter string fractional_vco_multiplier = "true";
    parameter string reference_clock_frequency = "74.25 MHz";
    parameter string operation_mode            = "normal";
    parameter int    number_of_clocks         = 5;
    parameter string output_clock_frequency0  = "12.287999 MHz";
    parameter string phase_shift0             = "0 ps";
    parameter int    duty_cycle0              = 50;
    parameter string output_clock_frequency1  = "12.287999 MHz";
    parameter string phase_shift1             = "20345 ps";
    parameter int    duty_cycle1              = 50;
    parameter string output_clock_frequency2  = "133.119993 MHz";
    parameter string phase_shift2             = "0 ps";
    parameter int    duty_cycle2              = 50;
    parameter string output_clock_frequency3  = "133.119992 MHz";
    parameter string phase_shift3             = "6573 ps";
    parameter int    duty_cycle3              = 50;
    parameter string output_clock_frequency4  = "133.119990 MHz";
    parameter string phase_shift4             = "5634 ps";
    parameter int    duty_cycle4              = 50;
    parameter string output_clock_frequency5  = "0 MHz";
    parameter string phase_shift5             = "0 ps";
    parameter int    duty_cycle5              = 50;
    parameter string output_clock_frequency6  = "0 MHz";
    parameter string phase_shift6             = "0 ps";
    parameter int    duty_cycle6              = 50;
    parameter string output_clock_frequency7  = "0 MHz";
    parameter string phase_shift7             = "0 ps";
    parameter int    duty_cycle7              = 50;
    parameter string output_clock_frequency8  = "0 MHz";
    parameter string phase_shift8             = "0 ps";
    parameter int    duty_cycle8              = 50;
    parameter string output_clock_frequency9  = "0 MHz";
    parameter string phase_shift9             = "0 ps";
    parameter int    duty_cycle9              = 50;
    parameter string output_clock_frequency10 = "0 MHz";
    parameter string phase_shift10            = "0 ps";
    parameter int    duty_cycle10             = 50;
    parameter string output_clock_frequency11 = "0 MHz";
    parameter string phase_shift11            = "0 ps";
    parameter int    duty_cycle11             = 50;
    parameter string output_clock_frequency12 = "0 MHz";
    parameter string phase_shift12            = "0 ps";
    parameter int    duty_cycle12             = 50;
    parameter string output_clock_frequency13 = "0 MHz";
    parameter string phase_shift13            = "0 ps";
    parameter int    duty_cycle13             = 50;
    parameter string output_clock_frequency14 = "0 MHz";
    parameter string phase_shift14            = "0 ps";
    parameter int    duty_cycle14             = 50;
    parameter string output_clock_frequency15 = "0 MHz";
    parameter string phase_shift15            = "0 ps";
    parameter int    duty_cycle15             = 50;
    parameter string output_clock_frequency16 = "0 MHz";
    parameter string phase_shift16            = "0 ps";
    parameter int    duty_cycle16             = 50;
    parameter string output_clock_frequency17 = "0 MHz";
    parameter string phase_shift17            = "0 ps";
    parameter int    duty_cycle17             = 50;
    parameter string pll_type                 = "General";
    parameter string pll_subtype              = "General";
;


    // NCO (numerically controlled oscillator) per output. 24-bit phase
    // accumulator; each 74.25 MHz refclk cycle adds the frequency step K;
    // the clock toggles on carry out of the phase (bit 24). Average output
    // frequency = 74.25 MHz * K / 2^24.
    //
    //   outclk[0] = 14.318 MHz (CPU)    K0 = round(2^24 * 14.318/74.25)
    //   outclk[1] = 12.288 MHz (video)  K1 = round(2^24 * 12.288/74.25)
    //   outclk[2] = 12.288 MHz (90 deg) K1, phase offset 2^22 (quarter)
    //   outclk[3] = 3.072 MHz  (audio)  K3 = round(2^24 * 3.072/74.25)
    localparam [23:0] K0      = 24'd3235340; // 14.318 MHz
    localparam [23:0] K1      = 24'd2776414; // 12.288 MHz
    localparam [23:0] K3      = 24'd694098;  // 3.072 MHz
    localparam [23:0] PHASE_Q = 24'd4194304; // 2^22 = quarter period (90 deg)

    reg [23:0] acc0, acc1, acc2, acc3;
    reg [12:0] lock_cnt;

    wire [24:0] sum0 = {1'b0, acc0} + K0;
    wire [24:0] sum1 = {1'b0, acc1} + K1;
    wire [24:0] sum2 = {1'b0, acc2} + K1;
    wire [24:0] sum3 = {1'b0, acc3} + K3;

    always @(posedge refclk or posedge rst) begin
        if (rst) begin
            acc0     <= 24'd0;
            acc1     <= 24'd0;
            acc2     <= PHASE_Q; // 90 deg phase offset vs outclk[1]
            acc3     <= 24'd0;
            outclk   <= 5'b0;
            locked   <= 1'b0;
            lock_cnt <= 13'd0;
        end else begin
            acc0 <= sum0[23:0];
            acc1 <= sum1[23:0];
            acc2 <= sum2[23:0];
            acc3 <= sum3[23:0];
            if (sum0[24]) outclk[0] <= ~outclk[0];
            if (sum1[24]) outclk[1] <= ~outclk[1];
            if (sum2[24]) outclk[2] <= ~outclk[2];
            if (sum3[24]) outclk[3] <= ~outclk[3];
            if (lock_cnt != 13'd4095) lock_cnt <= lock_cnt + 13'd1;
            else                       locked   <= 1'b1;
        end
    end

    // outclk[4] stays 0: not modeled, unused by the apple2e core
    assign fboutclk    = 1'b0;

endmodule
