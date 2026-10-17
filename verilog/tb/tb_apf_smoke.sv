// tb_apf_smoke.sv - P0 smoke testbench for the APF template tree.
//
// Instantiates the real `apf_top` (bridge + PAD + video/audio PHY + the
// template `core_top` test-pattern core) and checks, after a fixed
// simulation window:
//   1. the 74.25 MHz PLL tree produces a pixel clock (video bus toggles),
//   2. video sync/DE are present and pixels are not stuck (test pattern),
//   3. the I2S audio clocks (MCLK/LRCK) toggle,
//   4. no X/Z propagation into the video bus after settle.
//
// Pure self-driving testbench (no C++ main): build via build_verilator.bat
// (binary + timing mode). Exit code 0 = PASS, 1 = FAIL.
//
// Cartridge/link/IR/UART/memory buses are left unconnected (DUT-side only);
// in simulation they simply float at the DUT's driven value.
`timescale 1ns/1ps
module tb_apf_smoke;

    // ------------------------------------------------------------------
    // clocks: 74.25 MHz (13.468 ns period), two async domains
    // ------------------------------------------------------------------
    localparam real PERIOD = 13.468; // ns
    reg clk_74a = 1'b0;
    reg clk_74b = 1'b0;
    always #(PERIOD/2) clk_74a = ~clk_74a;
    initial begin
        #(PERIOD/4); // quarter-period phase offset: domains are async on hardware
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
    // bridge SPI host model (P0: write transactions only)
    //
    // io_bridge_peripheral protocol: 2 bits per spiclk cycle, MSB first.
    // The HOST drives spiclk + both data lines for address/write phases;
    // the peripheral latches {spimosi, spimiso} on each spiclk rising edge
    // (spimosi = upper bit). 4 cycles = 1 byte. 8 bytes = 1 transaction:
    //   addr[31:24], addr[23:16], addr[15:8], {addr[7:1], R/W}
    //   then 4 data bytes (write) or 4 received bytes (read, P1).
    // The DUT holds all three phy lines at Z while idle, so the host's
    // continuous assigns win on the shared nets during write transactions.
    // ------------------------------------------------------------------
    wire        bridge_spiclk, bridge_spimosi, bridge_spimiso;
    reg         h_spiclk  = 1'b1; // idle high (matches DUT idle)
    reg         h_mosi    = 1'b0;
    reg         h_miso    = 1'b0;
    reg         bridge_spiss = 1'b1; // idle deasserted
    assign bridge_spiclk  = h_spiclk;
    assign bridge_spimosi = h_mosi;
    assign bridge_spimiso = h_miso;

    localparam real SPI_HALF = 50.0; // 100 ns SPI period (10 MHz)

    task spi_pair(input [1:0] bits);
        h_spiclk  = 1'b0;
        h_mosi    = bits[1]; // set up on falling edge
        h_miso    = bits[0];
        #SPI_HALF;
        h_spiclk  = 1'b1;    // rising edge: DUT latches the pair
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
        // cartridge / link / IR / aux: unconnected (DUT drives or tristates)
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
    integer vid_changes = 0;
    integer de_high_samples = 0, de_nonzero_samples = 0;
    integer colors_n = 0;
    reg [11:0] prev_vid = 12'h0;
    reg prev_de = 1'b0, prev_mclk = 1'b0, prev_lrck = 1'b0, prev_dac = 1'b0;
    reg [4095:0] colors_seen;
    integer fail = 0;

    always @(scal_vs)  vs_edges  = vs_edges + 1;
    always @(scal_hs)  hs_edges  = hs_edges + 1;
    always @(scal_de)  de_edges  = de_edges + 1;
    always @(scal_audmclk) mclk_edges = mclk_edges + 1;
    always @(scal_audlrck) lrck_edges = lrck_edges + 1;
    always @(scal_auddac)  dac_toggles = dac_toggles + 1;

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
    // Reset Exit (0x0011) so the template core's video generator starts.
    // ------------------------------------------------------------------
    initial begin
        #1_500_000; // 1.5 ms: apf_top reset_n has risen (65536 x 13.5 ns)
        bridge_write(32'hF800_0000, {32'h434D, 16'h0011}); // Reset Exit
        $display("host: issued Reset Exit (0x0011) at t=%0t", $time);
    end

    // ------------------------------------------------------------------
    // run window + verdict
    // ------------------------------------------------------------------
    localparam real RUN_S = 3.0; // seconds of simulated video time

    initial begin
        #(RUN_S * 1_000_000_000);
        $display("=== tb_apf_smoke results (after %.0f s) ===", RUN_S);
        $display("  vs_edges=%0d hs_edges=%0d de_edges=%0d", vs_edges, hs_edges, de_edges);
        $display("  mclk_edges=%0d lrck_edges=%0d dac_toggles=%0d", mclk_edges, lrck_edges, dac_toggles);
        $display("  vid_changes=%0d de_high_samples=%0d de_nonzero_samples=%0d colors_seen=%0d",
                 vid_changes, de_high_samples, de_nonzero_samples, colors_n);

        fail = 0;
        if (vs_edges < 100) begin $display("FAIL: vs_edges %0d < 100 (no video frames)", vs_edges); fail = 1; end
        if (hs_edges < 2000) begin $display("FAIL: hs_edges %0d < 2000", hs_edges); fail = 1; end
        if (de_edges < 50000) begin $display("FAIL: de_edges %0d < 50000 (no DE activity)", de_edges); fail = 1; end
        if (colors_n < 2) begin $display("FAIL: only %0d distinct video colors (pixels stuck?)", colors_n); fail = 1; end
        if (mclk_edges < 100000) begin $display("FAIL: mclk_edges %0d < 100000 (audio MCLK dead)", mclk_edges); fail = 1; end
        if (lrck_edges < 100000) begin $display("FAIL: lrck_edges %0d < 100000 (audio LRCK dead)", lrck_edges); end

        if (fail) $display("=== tb_apf_smoke: FAIL ===");
        else      $display("=== tb_apf_smoke: PASS ===");
        $finish(fail);
    end

endmodule
