// tb_wrapper_kbd.sv - wrapper-level keyboard/reset integration test.
//
// Instantiates the REAL apf_top wrapper (core_top ic inside), issues Reset
// Exit over the real bridge SPI, and drives cont1_key (a sim-only override of
// the controller net - the APF auto-poll button protocol is not modeled).
//
// Verifies, through the actual wrapper (finding 7):
//   K1  key-ack: one OSK fire -> exactly one key-press event AND the machine
//       acknowledges it (READ_KEY pulses) - the $C000 read-ack flood fix.
//   A1  Apple-button wiring: OSK Open-Apple  -> machine GAMEPORT[1]
//   A2  Apple-button wiring: OSK Closed-Apple -> machine GAMEPORT[2]
//   R1  reset separation: osk_reset == host reset only (~rst_sync|~lock_sync),
//       it does NOT include osk_cmd_reset (the OSK survives its own command
//       reset); machine_reset == osk_reset | osk_cmd_reset.
//   R2  host reset: a host Reset asserts BOTH machine_reset and osk_reset.
//
// A deliberate reset-wiring regression (osk_reset fed from machine_reset)
// fails R1. Stale/wrong Apple-bit wiring fails A1/A2. A regression that
// stops $C000 reads from acknowledging fails K1.
//
// Build via verilate_wrapper.sh (uses the LOCAL machine/ + machine/osk/
// sources, the self-contained Pocket build - finding 7).
`timescale 1ns/1ps
module tb_wrapper_kbd;

    // ------------------------------------------------------------------
    // clocks: 74.25 MHz (13.468 ns period), two async domains
    // ------------------------------------------------------------------
    localparam real PERIOD = 13.468;
    reg clk_74a = 1'b0;
    reg clk_74b = 1'b0;
    always #(PERIOD/2) clk_74a = ~clk_74a;
    initial begin
        #(PERIOD/4);
        forever #(PERIOD/2) clk_74b = ~clk_74b;
    end

    // tied-off apf_top inputs
    reg vblank=0, port_ir_rx=0, dbg_rx=0, user2=0, cram0_wait=0, cram1_wait=0, scal_audadc=0;

    // ------------------------------------------------------------------
    // bridge SPI host model (write transactions)
    // ------------------------------------------------------------------
    wire bridge_spiclk, bridge_spimosi, bridge_spimiso;
    reg  h_spiclk = 1'b1;
    reg  h_mosi   = 1'b0;
    reg  h_miso   = 1'b0;
    reg  bridge_spiss = 1'b1;
    assign bridge_spiclk  = h_spiclk;
    assign bridge_spimosi = h_mosi;
    assign bridge_spimiso = h_miso;
    localparam real SPI_HALF = 50.0;
    task spi_pair(input [1:0] bits);
        h_spiclk = 1'b0; h_mosi = bits[1]; h_miso = bits[0]; #SPI_HALF;
        h_spiclk = 1'b1; #SPI_HALF;
    endtask
    task spi_tx_byte(input [7:0] b);
        spi_pair(b[7:6]); spi_pair(b[5:4]); spi_pair(b[3:2]); spi_pair(b[1:0]);
    endtask
    task bridge_write(input [31:0] addr, input [31:0] data);
        reg [63:0] tx; integer i;
        tx = {addr[31:8], addr[7:1], 1'b1, data};
        bridge_spiss = 1'b0; #200;
        for (i = 0; i < 8; i = i + 1) spi_tx_byte(tx[63 - 8*i -: 8]);
        #400; bridge_spiss = 1'b1;
    endtask

    // DUT-driven buses we sample but never drive
    wire [11:0] scal_vid;
    wire scal_clk, scal_de, scal_skip, scal_vs, scal_hs, scal_audmclk, scal_audlrck, scal_auddac;

    // ------------------------------------------------------------------
    // DUT: the real wrapper
    // ------------------------------------------------------------------
    apf_top dut (
        .clk_74a (clk_74a), .clk_74b (clk_74b),
        .port_ir_rx (port_ir_rx), .port_ir_tx (), .port_ir_rx_disable (),
        .vblank (vblank), .dbg_tx (), .dbg_rx (dbg_rx),
        .user1 (), .user2 (user2),
        .cram0_wait (cram0_wait), .cram1_wait (cram1_wait),
        .scal_vid (scal_vid), .scal_clk (scal_clk), .scal_de (scal_de),
        .scal_skip (scal_skip), .scal_vs (scal_vs), .scal_hs (scal_hs),
        .scal_audmclk (scal_audmclk), .scal_audadc (scal_audadc),
        .scal_auddac (scal_auddac), .scal_audlrck (scal_audlrck),
        .bridge_spiclk (bridge_spiclk), .bridge_spimosi (bridge_spimosi),
        .bridge_spimiso (bridge_spimiso), .bridge_spiss (bridge_spiss),
        .bridge_1wire ()
    );

    // ------------------------------------------------------------------
    // cont1_key driving (sim-only override of the controller net)
    //   APF bits: [0]up [1]down [2]left [3]right [4]fire [15]start
    // ------------------------------------------------------------------
    localparam [31:0] BTN_UP    = 32'd1 << 0;
    localparam [31:0] BTN_DOWN  = 32'd1 << 1;
    localparam [31:0] BTN_LEFT  = 32'd1 << 2;
    localparam [31:0] BTN_RIGHT = 32'd1 << 3;
    localparam [31:0] BTN_FIRE  = 32'd1 << 4;
    localparam [31:0] BTN_START = 32'd1 << 15;
    localparam longint PRESS_NS  = 30_000_000;   // 30 ms (past ~1.4 ms debounce)
    localparam longint RELEASE_NS = 30_000_000;  // 30 ms (release confirmation)

    task press(input [31:0] bits);
        force dut.cont1_key = bits;
        #PRESS_NS;
        force dut.cont1_key = 32'd0;
        #RELEASE_NS;
        release dut.cont1_key;
    endtask

    // ------------------------------------------------------------------
    // monitors (machine / OSK, via the real wrapper hierarchy)
    // ------------------------------------------------------------------
    // LEGACY ready-based consume counter (Phase A baseline only). Counts how
    // many times a latched key_ready (OSK K[7]) falls 1->0 and stays low for
    // 4 machine cycles. This is NOT a CPU-transaction definition: per the
    // recommendation (section 2) a ready-bit falling edge does not prove the
    // 6502 sampled/consumed the key, and the earlier `kp_low` filter could not
    // even start (fresh 1->0 reset it to 0, increment required >0). Phase B/C
    // replaces this with an actual-CPU-sampling-edge + pre-edge-data check.
    integer rk_cnt = 0;
    reg [1:0] kp_d = 2'b0;
    integer kp_low = 0;
    always @(posedge dut.ic.clk_core_14318) begin
        kp_d <= {kp_d[0], dut.ic.osk.K[7]};
        if (dut.ic.osk.K[7] === 1'b0 && kp_d[1] === 1'b1) kp_low = 1;  // fresh 1->0
        else if (kp_low > 0 && dut.ic.osk.K[7] === 1'b0) kp_low = kp_low + 1;
        else if (dut.ic.osk.K[7] === 1'b1) kp_low = 0;  // re-asserted: cancel
        if (kp_low == 4) begin  // still low 4 cycles after a 1->0 = a real consume
            rk_cnt = rk_cnt + 1;
            kp_low = 0;
        end
    end

    // R1: reset-separation invariant, sampled every machine cycle
    integer rst_feedback_viol = 0;   // osk_reset high while osk_cmd_reset high & no host reset
    always @(posedge dut.ic.clk_core_14318) begin
        // osk_reset must be exactly the host/POC reset: it must NOT assert
        // from osk_cmd_reset alone. If osk_reset is high, either the host
        // reset (~rst_sync[1]) or PLL-not-locked (~lock_sync[1]) must be high.
        if (dut.ic.osk_reset && !dut.ic.osk_cmd_reset &&
            dut.ic.rst_sync[1] && dut.ic.lock_sync[1])
            rst_feedback_viol = rst_feedback_viol + 1;
    end
    // R1b: machine_reset == osk_reset | osk_cmd_reset (structural)
    integer rst_xor_viol = 0;
    always @(posedge dut.ic.clk_core_14318) begin
        if (dut.ic.machine_reset !== (dut.ic.osk_reset | dut.ic.osk_cmd_reset))
            rst_xor_viol = rst_xor_viol + 1;
    end
    // REASSERTION TRACE (Phase D): log every key_ready 0->1 (the re-assertion)
    // with the platform + OSK button state, to find what re-fires the key.
    // cont1_key[4]=fire (platform), btn_raw/stable/latched[4]=the OSK debounce
    // chain, kb_v_event/pressed=the controller virtual key, key_press_cnt.
    reg      rp_d = 1'b0;
    integer  reassert_cnt = 0;
    always @(posedge dut.ic.clk_core_14318) begin
        if (dut.ic.osk.K[7] === 1'b1 && rp_d === 1'b0) begin
            reassert_cnt = reassert_cnt + 1;
            if (reassert_cnt <= 12)
                $display("RASET t=%0t #%0d cont1[4]=%b raw[4]=%b stab[4]=%b latch[4]=%b vev=%b pressed=%b code=%h cnt=%0d",
                    $time, reassert_cnt,
                    dut.cont1_key[4], dut.ic.osk.btn_raw[4], dut.ic.osk.btn_stable[4],
                    dut.ic.osk.btn_latched[4], dut.ic.osk.kb_v_event, dut.ic.osk.kb_v_pressed,
                    dut.ic.osk.kb_v_code, dut.ic.osk.key_press_cnt);
        end
        rp_d <= dut.ic.osk.K[7];
    end
    // A-wiring: GAMEPORT[1] must equal the OSK open_apple port and
    // GAMEPORT[2] the OSK closed_apple port, every machine cycle. This is
    // the wiring the fix added (core_top -> machine GAMEPORT bits).
    integer apple_wiring_viol = 0;
    always @(posedge dut.ic.clk_core_14318) begin
        if (dut.ic.d1.GAMEPORT[1] !== dut.ic.osk.open_apple ||
            dut.ic.d1.GAMEPORT[2] !== dut.ic.osk.closed_apple)
            apple_wiring_viol = apple_wiring_viol + 1;
    end
    // R1c: force osk_cmd_reset high -> machine_reset must assert but
    // osk_reset must NOT (the OSK survives its own command reset).
    integer rst_sep_viol = 0;
    reg cmd_rst_forced = 1'b0;
    always @(posedge dut.ic.clk_core_14318) begin
        if (cmd_rst_forced && dut.ic.rst_sync[1] && dut.ic.lock_sync[1]) begin
            if (!dut.ic.machine_reset || dut.ic.osk_reset)
                rst_sep_viol = rst_sep_viol + 1;
        end
    end

    integer fail = 0;

    // ------------------------------------------------------------------
    // test sequence
    // ------------------------------------------------------------------
    initial begin
        #1_500_000; // apf_top reset_n has risen
        bridge_write(32'hF800_0000, {32'h434D, 16'h0011}); // Reset Exit
        $display("host: Reset Exit at t=%0t", $time);

        #200_000_000; // let the machine boot (CPU + BIOS + video)

        // ---- open the OSK (START) ----
        press(BTN_START);
        #100_000_000;
        if (!dut.ic.osk.kb_active) begin
            $display("FAIL: OSK did not open (kb_active=%b)", dut.ic.osk.kb_active);
            fail = 1;
        end else
            $display("OSK opened (kb_active=1) at t=%0t", $time);

        // ---- K1: fire the default key (cursor starts at row1,col1 = Q) ----
        //     one fire -> one key-press event, and the machine acks it.
        @(posedge dut.ic.clk_core_14318);
        rk_cnt = 0; // clear the counter for the fire window
        press(BTN_FIRE);
        #300_000_000; // let the CPU poll $C000 and read the key
        if (dut.ic.osk.key_press_cnt !== 8'd1) begin
            $display("FAIL K1: key_press_cnt=%0d (expected 1 after one fire)", dut.ic.osk.key_press_cnt);
            fail = 1;
        end else
            $display("K1: key_press_cnt=1 (one fire = one event)");
        if (rk_cnt < 1) begin
            $display("FAIL K1: key_ready never cleared in the fire window (consumes=%0d) - key not acknowledged (flood regression)", rk_cnt);
            fail = 1;
        end else
            $display("K1: machine consumed the key (key_ready cleared %0d x in window) - one-shot ack OK", rk_cnt);

        // ---- A1/A2: Apple-button GAMEPORT wiring (forced, deterministic) ----
        // The fix wires the OSK open_apple/closed_apple ports to the machine's
        // GAMEPORT[1]/[2] (MiSTer bit map). Force each OSK Apple port and
        // verify the machine GAMEPORT bit follows.
        force dut.ic.osk.open_apple = 1'b1;
        #200_000;
        if (dut.ic.d1.GAMEPORT[1] !== 1'b1) begin
            $display("FAIL A1: OSK open_apple did not reach GAMEPORT[1] (GAMEPORT=%h)", dut.ic.d1.GAMEPORT);
            fail = 1;
        end else
            $display("A1: OSK open_apple -> GAMEPORT[1]=1 (GAMEPORT=%h)", dut.ic.d1.GAMEPORT);
        release dut.ic.osk.open_apple;
        #200_000;
        force dut.ic.osk.closed_apple = 1'b1;
        #200_000;
        if (dut.ic.d1.GAMEPORT[2] !== 1'b1) begin
            $display("FAIL A2: OSK closed_apple did not reach GAMEPORT[2] (GAMEPORT=%h)", dut.ic.d1.GAMEPORT);
            fail = 1;
        end else
            $display("A2: OSK closed_apple -> GAMEPORT[2]=1 (GAMEPORT=%h)", dut.ic.d1.GAMEPORT);
        release dut.ic.osk.closed_apple;
        #200_000;

        // ---- R2: host Reset asserts BOTH machine_reset and osk_reset ----
        //     (a host Reset is a real 0x0010 over the bridge)
        bridge_write(32'hF800_0000, {32'h434D, 16'h0010}); // Reset
        #50_000_000;
        if (!dut.ic.machine_reset || !dut.ic.osk_reset) begin
            $display("FAIL R2: host Reset did not assert both resets (m=%b osk=%b)", dut.ic.machine_reset, dut.ic.osk_reset);
            fail = 1;
        end else
            $display("R2: host Reset asserted machine_reset AND osk_reset");
        // exit the reset
        bridge_write(32'hF800_0000, {32'h434D, 16'h0011}); // Reset Exit
        #200_000_000;

        // ---- R3: force the OSK command reset -> machine resets, OSK survives ----
        cmd_rst_forced = 1'b1;
        force dut.ic.osk_cmd_reset = 1'b1;
        #50_000_000;
        release dut.ic.osk_cmd_reset;
        cmd_rst_forced = 1'b0;
        #200_000;

        // ---- R1 verdict: reset-separation invariants over the whole run ----
        if (rst_feedback_viol != 0) begin
            $display("FAIL R1: osk_reset asserted %0d x without a host/PLL reset (reset-feedback regression)", rst_feedback_viol);
            fail = 1;
        end else
            $display("R1: osk_reset never asserted from osk_cmd_reset alone (reset separation OK)");
        if (rst_xor_viol != 0) begin
            $display("FAIL R1b: machine_reset != (osk_reset|osk_cmd_reset) for %0d cycles", rst_xor_viol);
            fail = 1;
        end else
            $display("R1b: machine_reset == osk_reset|osk_cmd_reset (structural OK)");
        if (apple_wiring_viol != 0) begin
            $display("FAIL A0: GAMEPORT[1:2] mismatched the OSK Apple ports for %0d cycles (Apple-wiring regression)", apple_wiring_viol);
            fail = 1;
        end else
            $display("A0: GAMEPORT[1]/[2] tracked the OSK Apple ports every cycle (wiring OK)");
        if (rst_sep_viol != 0) begin
            $display("FAIL R3: during forced osk_cmd_reset, osk_reset asserted or machine_reset did not (%0d cycles)", rst_sep_viol);
            fail = 1;
        end else
            $display("R3: forced osk_cmd_reset reset the machine but not the OSK (reset separation OK)");

        $display("=== tb_wrapper_kbd: %s ===", fail ? "FAIL" : "PASS");
        $finish(fail);
    end

endmodule
