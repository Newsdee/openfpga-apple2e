// tb_apple2e_smoke.sv - P1 smoke testbench for the Apple IIe Pocket core.
//
// Instantiates the real `apf_top` with the apple2e `core_top` (module name
// "core_top", bound by apf_top's `core_top ic`), which uses the apple2e_PLL
// tree (14.318 / 12.288 / 12.288-90 / 3.072 MHz). Checks, after a fixed
// window:
//   1. the host issues Reset Exit (0x0011) over the real bridge SPI,
//   2. the video test pattern runs (VS/HS/DE present, pixels not stuck),
//   3. the video bus clock is in the 12.288 MHz family (not the 74.25 MHz
//      reference - a frequency sanity check on the PLL video tap),
//   4. the I2S audio clocks (MCLK/LRCK) toggle.
//
// Pure self-driving testbench: build via build_apple2e_verilator.bat.
// Exit code 0 = PASS, 1 = FAIL.
`timescale 1ns/1ps
module tb_apple2e_smoke;

    // ------------------------------------------------------------------
    // clocks: 74.25 MHz (13.468 ns period), two async domains
    // ------------------------------------------------------------------
    localparam real PERIOD = 13.468; // ns
    reg clk_74a = 1'b0;
    reg clk_74b = 1'b0;
    always #(PERIOD/2) clk_74a = ~clk_74a;
    initial begin
        #(PERIOD/4);
        forever #(PERIOD/2) clk_74b = ~clk_74b;
    end

    // ------------------------------------------------------------------
    // tied-off inputs
    // ------------------------------------------------------------------
    reg         vblank       = 1'b0;
    reg         port_ir_rx   = 1'b0;
    reg         dbg_rx       = 1'b0;
    reg         user2        = 1'b0;
    reg         cram0_wait   = 1'b0;
    reg         cram1_wait   = 1'b0;
    reg         scal_audadc  = 1'b0;

    // ------------------------------------------------------------------
    // bridge SPI host model (write transactions; see tb_apf_smoke for the
    // 2-bits-per-clock protocol description)
    // ------------------------------------------------------------------
    wire        bridge_spiclk, bridge_spimosi, bridge_spimiso;
    reg         h_spiclk  = 1'b1;
    reg         h_mosi    = 1'b0;
    reg         h_miso    = 1'b0;
    reg         bridge_spiss = 1'b1;
    assign bridge_spiclk  = h_spiclk;
    assign bridge_spimosi = h_mosi;
    assign bridge_spimiso = h_miso;

    localparam real SPI_HALF = 50.0; // 100 ns SPI period (10 MHz)

    task spi_pair(input [1:0] bits);
        h_spiclk  = 1'b0;
        h_mosi    = bits[1];
        h_miso    = bits[0];
        #SPI_HALF;
        h_spiclk  = 1'b1;
        #SPI_HALF;
    endtask

    task spi_tx_byte(input [7:0] b);
        spi_pair(b[7:6]);
        spi_pair(b[5:4]);
        spi_pair(b[3:2]);
        spi_pair(b[1:0]);
    endtask

    task bridge_write(input [31:0] addr, input [31:0] data);
        reg [63:0] tx;
        integer i;
        tx = {addr[31:8], addr[7:1], 1'b1, data}; // bit0 = write
        bridge_spiss = 1'b0;
        #200;
        for (i = 0; i < 8; i = i + 1) spi_tx_byte(tx[63 - 8*i -: 8]);
        #400;
        bridge_spiss = 1'b1;
    endtask

    // DUT-driven buses we sample but never drive
    wire [11:0] scal_vid;
    wire        scal_clk, scal_de, scal_skip, scal_vs, scal_hs;
    wire        scal_audmclk, scal_auddac, scal_audlrck;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    apf_top dut (
        .clk_74a (clk_74a),
        .clk_74b (clk_74b),
        .port_ir_rx (port_ir_rx),
        .port_ir_tx (),
        .port_ir_rx_disable (),
        .vblank (vblank),
        .dbg_tx (),
        .dbg_rx (dbg_rx),
        .user1 (),
        .user2 (user2),
        .cram0_wait (cram0_wait),
        .cram1_wait (cram1_wait),
        .scal_vid (scal_vid),
        .scal_clk (scal_clk),
        .scal_de (scal_de),
        .scal_skip (scal_skip),
        .scal_vs (scal_vs),
        .scal_hs (scal_hs),
        .scal_audmclk (scal_audmclk),
        .scal_audadc (scal_audadc),
        .scal_auddac (scal_auddac),
        .scal_audlrck (scal_audlrck),
        .bridge_spiclk (bridge_spiclk),
        .bridge_spimosi (bridge_spimosi),
        .bridge_spimiso (bridge_spimiso),
        .bridge_spiss (bridge_spiss),
        .bridge_1wire ()
    );

    // ------------------------------------------------------------------
    // monitors
    // ------------------------------------------------------------------
    integer vs_edges = 0, hs_edges = 0, de_edges = 0;
    integer mclk_edges = 0, lrck_edges = 0, dac_toggles = 0;
    integer scal_clk_edges = 0;
    integer vid_changes = 0;
    integer de_high_samples = 0, de_nonzero_samples = 0;
    integer colors_n = 0;
    reg [11:0] prev_vid = 12'h0;
    reg [4095:0] colors_seen;
    integer fail = 0;
    real scal_clk_mhz = 0.0;

    always @(scal_vs)         vs_edges  = vs_edges + 1;
    always @(scal_hs)         hs_edges  = hs_edges + 1;
    always @(scal_de)         de_edges  = de_edges + 1;
    always @(scal_audmclk)    mclk_edges = mclk_edges + 1;
    always @(scal_audlrck)    lrck_edges = lrck_edges + 1;
    always @(scal_clk)        scal_clk_edges = scal_clk_edges + 1;
    always @(scal_auddac)     dac_toggles = dac_toggles + 1;

    // sample the 12-bit DDR video bus every time it changes
    always @(scal_vid) begin
        if (scal_vid !== prev_vid) vid_changes = vid_changes + 1;
        prev_vid = scal_vid;
        if (scal_vid != 12'h000 && scal_vid != 12'hFFF && !colors_seen[scal_vid]) begin
            colors_seen[scal_vid] = 1'b1;
            colors_n = colors_n + 1;
        end
        if (scal_de) begin
            de_high_samples = de_high_samples + 1;
            if (scal_vid != 12'h000) de_nonzero_samples = de_nonzero_samples + 1;
        end
    end

    // ------------------------------------------------------------------
    // host boot sequence: wait for DUT reset (~0.9 ms), then issue
    // Reset Exit (0x0011) so the apple2e core's video generator starts.
    // ------------------------------------------------------------------
    initial begin
        #1_500_000; // 1.5 ms: apf_top reset_n has risen (65536 x 13.5 ns)
        bridge_write(32'hF800_0000, {32'h434D, 16'h0011}); // Reset Exit
        $display("host: issued Reset Exit (0x0011) at t=%0t", $time);
    end

    // ------------------------------------------------------------------
    // run window + verdict
    // ------------------------------------------------------------------
    localparam real RUN_S = 3.0; // seconds of simulated time

    initial begin
        #(RUN_S * 1_000_000_000);

        // scal_clk frequency: edges over the run window. The video bus clock
        // is in the 12.288 MHz family (DDR -> up to 2x). Reject the 74.25
        // MHz reference (a sign the PLL video tap is not actually dividing).
        scal_clk_mhz = (scal_clk_edges / 2.0) / (RUN_S * 1_000_000);

        $display("=== tb_apple2e_smoke results (after %.0f s) ===", RUN_S);
        $display("  vs_edges=%0d hs_edges=%0d de_edges=%0d", vs_edges, hs_edges, de_edges);
        $display("  scal_clk_edges=%0d  (freq ~ %.2f MHz)", scal_clk_edges, scal_clk_mhz);
        $display("  mclk_edges=%0d lrck_edges=%0d dac_toggles=%0d", mclk_edges, lrck_edges, dac_toggles);
        $display("  vid_changes=%0d de_high_samples=%0d de_nonzero_samples=%0d colors_seen=%0d",
                 vid_changes, de_high_samples, de_nonzero_samples, colors_n);

        fail = 0;
        if (vs_edges < 100)   begin $display("FAIL: vs_edges %0d < 100 (no video frames)", vs_edges); fail = 1; end
        if (hs_edges < 2000)  begin $display("FAIL: hs_edges %0d < 2000", hs_edges); fail = 1; end
        // de_edges scales with the video clock rate: ~43k over 3 s at the
        // correct 12.288 MHz (the template build ran ~6x faster at 74.25 MHz).
        if (de_edges < 10000) begin $display("FAIL: de_edges %0d < 10000 (no DE activity)", de_edges); fail = 1; end
        // The apple2e video is 1-bit (black/white): the DDR bus carries
        // 0x000 (2 black pixels) and 0xFFF (2 white pixels) plus mixed
        // values at pixel-pair boundaries. "Not stuck" = both levels seen
        // on DE samples (the old test-pattern check required >=2 non-black/
        // white colors, which a 1-bit core can never produce).
        if (de_nonzero_samples < 1000 || (de_high_samples - de_nonzero_samples) < 1000)
            begin $display("FAIL: video stuck: de_nonzero=%0d de_zero=%0d (need both levels)", de_nonzero_samples, de_high_samples - de_nonzero_samples); fail = 1; end
        if (mclk_edges < 100000) begin $display("FAIL: mclk_edges %0d < 100000 (audio MCLK dead)", mclk_edges); fail = 1; end
        if (lrck_edges < 100000) begin $display("FAIL: lrck_edges %0d < 100000 (audio LRCK dead)", lrck_edges); fail = 1; end
        // video bus clock must be in the 12.288 MHz family. The DDR video bus
        // carries 2 pixels per clock, so the on-bus clock is 12.288/2 = 6.144
        // MHz (or a multiple). The 74.25 MHz reference family (37.125 MHz and
        // up) would indicate the PLL video tap is not actually dividing, so we
        // reject anything >= 33 MHz. Accept the 12.288 family (3-33 MHz).
        if (scal_clk_mhz < 3.0 || scal_clk_mhz > 33.0) begin
            $display("FAIL: scal_clk freq %.2f MHz outside 3-33 MHz (12.288 family; 74.25 ref family >= 37)", scal_clk_mhz);
            fail = 1;
        end

        if (fail) $display("=== tb_apple2e_smoke: FAIL ===");
        else      $display("=== tb_apple2e_smoke: PASS ===");
        $finish(fail);
    end

endmodule
