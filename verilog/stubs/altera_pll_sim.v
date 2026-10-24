// altera_pll_sim.v - behavioral stand-in for the Quartus altera_pll IP used
// by the apple2e core. Two instances (2026-10-22):
//   machine PLL (apf_stream_proto_pll, freq0="14311905 Hz"):
//     outclk[0] = 14.318 MHz (machine), outclk[1] = 14.318 MHz 90 deg (DDR),
//     outclk[2] = 3.072 MHz (audio), outclk[3] = 0
//   SDRAM PLL (apple2e_sdram_pll, freq0="133.119993 MHz"):
//     outclk[0..2] = 133.12 MHz on the coincident rising edge grid
//     (M0 reference geometry - see the SD_MODE comment below)
// Mode select is by the requested outclk0 frequency string (both wrappers
// declare number_of_clocks(3) - that value cannot discriminate them; the
// old check ran the machine clock at 133.12 MHz and broke the WOZ sector
// boundary - see the SD_MODE comment).
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
    // (The historical 24-bit NCO implementation is retired 2026-10-22:
    //  free-running delay clocks replaced it in both modes - see below.)

    // ---- SDRAM-PLL mode (M1 sim fix 2026-10-21, grid fixed 2026-10-22) --
    // The SDRAM instance (freq0="133.119993 MHz") needs THREE 133.12 MHz
    // clocks, above the 74.25 MHz refclk, so this mode uses free-running
    // real-time-delay clocks.
    // 2026-10-22: the original two-phase (180-deg chip) grid made
    // the pinned io_sdram_pocket read-capture window sample one chip tick
    // late ({16'h0, low16} words -> +2-byte WOZ stream shift -> scan
    // mis-parse -> OOR eject -> no-boot in sim). The proven M0 reference
    // geometry (tb_top_storage.sv) runs all three clocks on one coincident
    // 133.12 MHz edge grid; that is what this mode now generates (see the
    // SD_MODE output blocks below).
    // ---- mode select (2026-10-22 fix) ---------------------------------
    // BOTH PLL wrappers (apf_stream_proto_pll machine PLL and
    // apple2e_sdram_pll) declare number_of_clocks(3), so that value CANNOT
    // discriminate them - the old check routed the MACHINE PLL into SDRAM
    // mode and ran clk_core_14318 at 133.12 MHz (9.3x fast), which collapsed
    // the machine:ctrl ratio and let the WOZ transport's S_REQ re-check race
    // the stale sector_ready release (streamed lba=1 from lba=0's sbuf).
    // Discriminate by the requested outclk0 frequency string (full-string
    // equality; Verilator does not allow bit-selects of string types):
    //   SDRAM PLL: "133.119993 MHz"   (apple2e_sdram_pll)
    //   machine   : "14311905 Hz"     (apf_stream_proto_pll) -> not SD
    localparam SD_MODE = (output_clock_frequency0 == "133.119993 MHz");
    localparam real SD_Q    = 1.878;   // quarter period (ns): 133.12 MHz
    localparam real MACH_Q  = 17.461;  // quarter period (ns): 14.318 MHz
    localparam real AUD_Q   = 81.380;  // quarter period (ns): 3.072 MHz

    // ---- machine-PLL mode outputs: 14.318 / 14.318(90 deg) / 3.072 MHz -
    // outclk[0] = 14.318 MHz (machine: CPU + WOZ + video + transport)
    // outclk[1] = 14.318 MHz, quarter-period (90 deg) phase - DDR video copy
    // outclk[2] = 3.072 MHz  (audio)
    // outclk[3] = 0 (disabled in the wrapper spec)
    // The 14.318:133.12 ratio (~9.3:1) is load-bearing: the WOZ transport's
    // sector boundary (stale sector_ready release via 2FF done sync) relies
    // on the machine cycle (69.8 ns) being longer than the ctrl-side release
    // latency (~3-4 ctrl cycles); at equal rates the race corrupts the
    // sector after the first (2026-10-22).
    always begin
        if (!SD_MODE) begin
            outclk[0] = 1'b0;
            wait (!rst);
            #(MACH_Q * 1.0);
            forever #(MACH_Q * 2.0) outclk[0] = ~outclk[0];
        end
    end
    always begin
        if (!SD_MODE) begin
            outclk[1] = 1'b0;
            wait (!rst);
            #(MACH_Q * 2.0);   // quarter-period offset vs outclk[0] (90 deg)
            forever #(MACH_Q * 2.0) outclk[1] = ~outclk[1];
        end
    end
    always begin
        if (!SD_MODE) begin
            outclk[2] = 1'b0;
            wait (!rst);
            #(AUD_Q * 2.0);
            forever #(AUD_Q * 2.0) outclk[2] = ~outclk[2];
        end
    end
    // outclk[3] = 0 in machine mode (disabled in the wrapper spec).
    // NOTE (2026-10-22): one-shot logic must be `initial`, never a bare
    // `always` - Verilator wraps an eventless `always` block in an
    // infinite while(!gotFinish()) re-execution loop, so a one-shot body
    // (wait + delay + assign) ping-pongs forever (measured: pll_core_locked
    // became a 0%-duty 200 ms square wave -> machine stuck in reset;
    // a wait+display variant spammed 168M lines in 2.4 us).
    initial begin
        if (!SD_MODE)
            outclk[3] = 1'b0;
    end
    initial begin
        if (!SD_MODE) begin
            locked = 1'b0;
            wait (!rst);
            #200000;   // 200 us settle
            locked = 1'b1;
        end
    end
    // One-shot probes (2026-10-22): initial-coroutine form - a bare
    // `always` block containing only `wait(!rst)` + $display gets
    // re-executed on every eval by Verilator once rst is released
    // (168M lines of spam in 2.4 us of sim time, 8.7 GB log).
    reg sd_probe_done;
    reg mach_lock_probe_done;
    initial begin
        sd_probe_done = 1'b0;
        wait (!rst);
        if (SD_MODE && !sd_probe_done) begin
            sd_probe_done = 1'b1;
            $display("TBPLL: SD-mode rst released t=%t freq0=%s", $time, output_clock_frequency0);
        end
    end
    initial begin
        mach_lock_probe_done = 1'b0;
        wait (locked);
        if (!SD_MODE && !mach_lock_probe_done) begin
            mach_lock_probe_done = 1'b1;
            $display("TBPLL: MACH-mode locked=1 t=%t", $time);
        end
    end

    // outclk[4] stays 0: not modeled, unused by the apple2e core
    assign fboutclk    = 1'b0;

    // ---- SDRAM-PLL mode outputs: 133.12 MHz, COINCIDENT rising grids ---
    // Q = quarter period (1.878 ns); a 133.12 MHz clock toggles every 2Q
    // (period 4Q = 7.512 ns). outclk[0] (ctrl) and outclk[1] (chip) rise on
    // the SAME edge times (first rising edge 2Q after rst, then every 4Q);
    // outclk[2] (clk90, unused by the storage path) is half-period offset.
    //
    // The coincident rising grid is load-bearing and was the M1 sim bug
    // (2026-10-22): the pinned io_sdram_pocket read-capture window
    // (enable_dq_read -> _4 chain, TD_CMD/TD_DQ = 1.5 ns) is calibrated
    // against the M0 reference geometry (tb_top_storage.sv: chip_clk first
    // edge offset by PHASE = one FULL period = coincident rising grid).
    // With a half-period (180 deg) offset, no controller capture edge ever
    // lands inside the 1.5-ns physical DQ phase windows, and every read
    // word comes back {16'h0, low16} (measured: sbuf0 = 5A32_0000 for file
    // word 574F5A32) -> +2-byte WOZ stream shift -> scan mis-parse ->
    // 459th read OOR -> eject -> no-boot in sim. TB-only; the pinned
    // controller and the real PLL (M0 hardware proven) are untouched.
    always begin
        if (SD_MODE) begin
            outclk[0] = 1'b0;
            wait (!rst);
            locked = 1'b1;
            #(SD_Q * 2.0);
            forever #(SD_Q * 2.0) outclk[0] = ~outclk[0];
        end
    end
    always begin
        if (SD_MODE) begin
            outclk[1] = 1'b0;
            wait (!rst);
            #(SD_Q * 2.0);   // SAME rising grid as outclk[0] (coincident)
            forever #(SD_Q * 2.0) outclk[1] = ~outclk[1];
        end
    end
    always begin
        if (SD_MODE) begin
            outclk[2] = 1'b0;
            wait (!rst);
            #(SD_Q * 3.0);   // half-period offset (M0 clk90 shape); unused
            forever #(SD_Q * 2.0) outclk[2] = ~outclk[2];
        end
    end

endmodule
