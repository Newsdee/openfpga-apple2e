// devkey_uart.v - Analogue Pocket dev-key UART tracer backend (74a domain).
//
// Part of the dev-key debug channel (see DEVKEY_UART_INTEGRATION_2026-11-14.md):
// the dev-key dongle plugs into the cart slot; debug_key.v maps its LED/UART
// onto the cart_tran pins; THIS module provides the 74a-domain UART engine
// and the savestate event tracer. It exists to observe live savestate
// save/load phases on hardware (the 2026-11-14/15 save#2 wedge cannot be
// traced from the host side: the host only sees busy/timeout).
//
// UART: 115200 nominal (74.25 MHz / 645 = 115,116 bps, -0.073% within 8N1
// tolerance), 8 data bits, no parity, 1 stop. TX FIFO 64 bytes; a full
// FIFO drops bytes (drop counter reported on the ID line).
//
// Line protocol (each line \r\n-terminated, ASCII):
//   APF2E DEVKEY v1 ...        boot banner (once after reset)
//   TEST MODE ...              test mode engaged (button held >=250 us
//                              within the first 1 ms after reset; LED then
//                              shows the debounced press flash, the plan's
//                              Stage A loopback check)
//   SS ST / SS LD              savestate save/load command seen (bridge pulse)
//   SS <8hex>                  live host_4C status word, 20 Hz while busy
//                              layout: [15:0]word [16]done [17]busy [18]stall
//                                    [19]rd_ovf [20]wr_ovf [24:21]retry
//                                    [28:25]rd_hw
//   SS OK / SS ERR             op finished (result captured on busy fall)
//   ID <8hex> d<2hex>          every IDLE_PERIOD 2 ms ticks while idle
//                              (default 5000 = 10 s; was 500 Hz): status
//                              word + TX drop counter
//   HB <2hex>                  same idle rate while the ID line is off
//   BTN                        button press
//   RX <2hex>                  received byte (LED blinks as well)
//
// RX commands: 'd'/'D' toggles the idle ID line (off -> HB lines only).
// No other commands; triggering save/load from the key would need a bridge
// injection path and is intentionally NOT done (observation-only).
//
// LED: normal mode = savestate busy (steady) or RX blink; test mode =
// debounced press flash. Registered output; raw button level never
// reaches the pad (A0 line floats when unpressed - 2026-11-16 fix).
// Optional LED_TX=1 (diagnostic, REVERT for shipping) mirrors the UART
// TX stream on the LED pin as well.
//
// Reset: active-high, synchronous (apf_stream_video_top passes ~reset_n).

`timescale 1ns/10ps

module devkey_uart #(
    parameter DISCOVERY = 0,  // 1 = /RD 31 Hz blink + A0-edge LED flash —
                              // wire-probe fingerprint fingers (see
                              // docs/EXPERT_BRIEF_DEVKEY_UART_AB_RESULTS_
                              // 2026-11-15.md §5). TBs use the default 0,
                              // which is the pre-discovery golden behavior.
    parameter LED_TX    = 0,   // 1 = exclusively mirror uart_tx on the LED
                              // pin (/RD, bank0[5]) — diagnostic for a dongle
                              // whose CP210x RXD sits on the /RD net instead
                              // of /WR (2026-11-16 discovery). NOTE: the LED
                              // is then SOLID ON at idle (UART is idle-high
                              // and the LED shares the /RD net - there is no
                              // dim setting); if the CP210x does not sit on
                              // /RD, keep LED_TX=0. REVERT for shipping.
    parameter IDLE_PERIOD = 5000  // 2026-11-16 verbosity: idle ID/HB lines
                              // every IDLE_PERIOD 2 ms ticks (default 5000
                              // = 10 s; was every tick = 2 ms = 500 lines/
                              // sec). 16-bit range 1..65535 (1 = legacy 2 ms
                              // rate, used by the sim TB). The 20 Hz BUSY
                              // poll (the wedge-observation stream) is
                              // unaffected.
) (
    input  wire        clk,        // clk_74a (74.25 MHz)
    input  wire        rst,        // active-high (~reset_n)
    // ---- savestate taps (74a domain, apf_stream_video_top level) ----
    input  wire        ss_start,   // 1-cycle pulse (core_bridge_cmd)
    input  wire        ss_load,    // 1-cycle pulse
    input  wire        ss_busy,    // start_busy | load_busy
    input  wire        ss_ok,      // start_ok | load_ok
    input  wire        ss_err,     // start_err | load_err
    input  wire [31:0] ss_status,  // the host_4C live word
    // 2026-11-16 savestate SSD/SSX serial debug (REVERT for shipping):
    // ctrl-domain snapshot (counters + state words) already crossed to 74a
    // via the toggle handshake in apf_stream_video_top.
    input  wire [127:0] ssd_snap,
    // ---- dev key (debug_key.v outputs; uart_rx already 3FF-synced) ----
    input  wire        button,
    input  wire        uart_rx,
    // ---- UART / LED (to debug_key.v) ----
    output reg         uart_tx,
    output wire        led
);

    localparam [9:0] BAUD_DIV = 10'd645;
    localparam [9:0] BIT_LAST = BAUD_DIV - 10'd1;
    localparam [9:0] HALF_BIT_LAST = (BAUD_DIV / 10'd2) - 10'd1;
    // Tick periods in clk_74a cycles (74.25 MHz). 2026-11-15: the originals
    // were 1000x too small (3713 = 50 us "20 Hz", 74250 = 1 ms "1 Hz"), so
    // both line rates exceeded the 115,200-baud UART capacity (20 kHz polls
    // = 260 kbps; 1 kHz ID lines = 170 kbps > the 11.52 bytes/ms the port
    // drains): the 64-byte TX FIFO overflowed and lines desynced. The busy
    // poll is now the documented 20 Hz; the idle tick is 2 ms (500 Hz), not
    // 1 Hz, so the sim gate's wait windows stay small (a true 1 Hz would
    // need a 27-bit counter and a 1 s sim budget). The ID-line drop counter
    // still reports any TX loss.
    localparam [21:0]  CYC_1HZ   = 22'd148500;   // 2 ms idle tick (ID/HB)
    localparam [21:0]  CYC_20HZ  = 22'd3713000;  // 50 ms (20 Hz busy poll)
    localparam [22:0]  CYC_RXBL  = 23'd7425000; // 100 ms visible RX blink
    localparam [14:0]  CYC_250MS = 15'd18562;   // NOTE: 250 US at 74.25 MHz
                                                 // (name kept; test-mode entry is
                                                 // boot-window-only, see below)
    localparam [16:0]  CYC_1MS   = 17'd74250;   // button debounce (1 ms)
    localparam [22:0]  CYC_BTNFL = 23'd7425000; // button LED flash (~100 ms)
    localparam [5:0]   LINE_MAX  = 6'd36;

    // =====================================================================
    // Validate start, sample eight data bits, then validate stop at bit centres.
    // =====================================================================
    reg        rx_s_d1;
    reg        rx_active;
    reg        rx_start;
    reg [9:0]  rx_cnt;
    reg [3:0]  rx_bit;
    reg [7:0]  rx_data;
    wire       rx_fall = rx_s_d1 && !uart_rx;
    reg        rx_valid;
    reg [7:0]  rx_byte;
    always @(posedge clk) begin
        if (rst) begin
            rx_s_d1   <= 1'b1;
            rx_active <= 1'b0;
            rx_start  <= 1'b0;
            rx_cnt    <= 10'd0;
            rx_bit    <= 4'd0;
            rx_data   <= 8'd0;
            rx_valid  <= 1'b0;
            rx_byte   <= 8'd0;
        end else begin
            rx_s_d1  <= uart_rx;
            rx_valid <= 1'b0;
            if (rx_active) begin
                if (rx_cnt == 10'd0) begin
                    rx_cnt <= BIT_LAST;
                    if (rx_start) begin
                        rx_start <= 1'b0;
                        if (uart_rx)
                            rx_active <= 1'b0;    // false start
                    end else if (rx_bit < 4'd8) begin
                        rx_data[rx_bit[2:0]] <= uart_rx;
                        rx_bit <= rx_bit + 4'd1;
                    end else begin
                        rx_active <= 1'b0;
                        if (uart_rx) begin
                            rx_valid <= 1'b1;
                            rx_byte  <= rx_data;
                        end
                    end
                end else
                    rx_cnt <= rx_cnt - 10'd1;
            end else if (rx_fall) begin
                rx_active <= 1'b1;
                rx_start  <= 1'b1;
                rx_cnt    <= HALF_BIT_LAST;
                rx_bit    <= 4'd0;
                rx_data   <= 8'd0;
            end
        end
    end

    // =====================================================================
    // TX FIFO (64 x 8, register file); overflow drops + counts
    // =====================================================================
    reg [7:0] txfifo [0:63];
    reg [5:0] tx_wr, tx_rd;
    reg [6:0] tx_n;            // byte count (0..64)
    reg [7:0] tx_drop;         // saturated drop counter
    wire      txf_full  = (tx_n == 7'd64);
    wire      txf_empty = (tx_n == 7'd0);
    // the bit engine pops exactly when it loads a byte (one consumer;
    // a same-cycle push+pop nets zero on the count)
    wire      tx_load   = !tx_busy && !txf_empty;
    always @(posedge clk) begin
        if (rst) begin
            tx_n    <= 7'd0;
            tx_drop <= 8'd0;
            tx_wr   <= 6'd0;
            tx_rd   <= 6'd0;
        end else begin
            if (line_push && !txf_full) begin
                txfifo[tx_wr] <= line_char_r;
                tx_wr         <= tx_wr + 1'b1;
            end else if (line_push && txf_full) begin
                if (tx_drop != 8'd255) tx_drop <= tx_drop + 1'b1;
            end
            case ({line_push && !txf_full, tx_load})
                2'b10:   tx_n <= tx_n + 1'b1;
                2'b01:   tx_n <= tx_n - 1'b1;
                2'b11:   ;    // push+pop same cycle: count unchanged
                default: ;
            endcase
            if (tx_load)
                tx_rd <= tx_rd + 1'b1;
        end
    end

    // =====================================================================
    // TX bit engine: start + 8 data (LSB first) + stop, BAUD_DIV/bit
    // =====================================================================
    reg        tx_busy;
    reg [7:0]  tx_shift;
    reg [3:0]  tx_bit;           // 0=start, 1..8=data, 9=stop
    reg [9:0]  tx_bcnt;
    // one combinational value per (current, next) bit index - a single
    // uart_tx assignment per branch (no double NBA in one always block)
    wire [3:0] tx_bit_n   = tx_bit + 4'd1;
    wire [2:0] tx_data_bit = tx_bit[2:0] - 3'd1;
    wire [2:0] tx_data_bit_n = tx_bit_n[2:0] - 3'd1;
    wire       tx_bitval  = (tx_bit     == 4'd0) ? 1'b0
                         : (tx_bit     == 4'd9) ? 1'b1
                         : tx_shift[tx_data_bit];
    wire       tx_bitval_n = (tx_bit_n   == 4'd0) ? 1'b0
                          : (tx_bit_n   == 4'd9) ? 1'b1
                          : tx_shift[tx_data_bit_n];
    always @(posedge clk) begin
        if (rst) begin
            uart_tx <= 1'b1;
            tx_busy <= 1'b0;
            tx_shift <= 8'd0;
            tx_bit <= 4'd0;
            tx_bcnt <= 10'd0;
        end else if (!tx_busy) begin
            uart_tx <= 1'b1;
            if (!txf_empty) begin
                tx_shift <= txfifo[tx_rd];
                tx_busy  <= 1'b1;
                uart_tx  <= 1'b0;
                tx_bit   <= 4'd0;
                tx_bcnt  <= 10'd0;
            end
        end else if (tx_bcnt == BIT_LAST) begin
            tx_bcnt <= 10'd0;
            if (tx_bit == 4'd9) begin
                tx_busy <= 1'b0;
                uart_tx <= 1'b1;
            end else begin
                tx_bit  <= tx_bit_n;
                uart_tx <= tx_bitval_n;   // next bit starts on the boundary
            end
        end else begin
            tx_bcnt <= tx_bcnt + 1'b1;
            uart_tx <= tx_bitval;         // hold the current bit
        end
    end

    // =====================================================================
    // Event sources: 1 Hz / 20 Hz ticks, button, savestate edges
    // =====================================================================
    reg [21:0] t1hz_c;
    reg [21:0] t20hz_c;
    wire       t1hz  = (t1hz_c  == CYC_1HZ  - 22'd1);
    wire       t20hz = (t20hz_c == CYC_20HZ - 22'd1);
    always @(posedge clk) begin
        if (rst) begin
            t1hz_c  <= 22'd0;
            t20hz_c <= 22'd0;
        end else begin
            if (t1hz)  t1hz_c  <= 22'd0; else t1hz_c  <= t1hz_c  + 1'b1;
            if (t20hz) t20hz_c <= 22'd0; else t20hz_c <= t20hz_c + 1'b1;
        end
    end

    // 2026-11-16 verbosity: idle-line divider. ID/HB used to emit on EVERY
    // 2 ms tick (500 lines/sec of idle chatter); now one line per
    // IDLE_PERIOD ticks (default 10 s). The 20 Hz busy poll (t20hz/EV_SSP)
    // is the wedge-observation stream and is unchanged.
    localparam [15:0] IDLE_PERIOD_M1 = IDLE_PERIOD - 1;
    reg [15:0] idle_cnt;
    wire idle_due = (idle_cnt == IDLE_PERIOD_M1);
    initial
        // elaboration guard (sim-only; synthesis drops initial blocks):
        // IDLE_PERIOD=0 would make IDLE_PERIOD_M1 wrap to 65535 silently.
        if (IDLE_PERIOD < 1 || IDLE_PERIOD > 65535)
            $display("devkey_uart WARNING: IDLE_PERIOD=%0d outside 1..65535",
                     IDLE_PERIOD);
    always @(posedge clk) begin
        if (rst)            idle_cnt <= 16'd0;
        else if (t1hz) idle_cnt <= idle_due ? 16'd0 : idle_cnt + 16'd1;
    end

    reg btn_s1, btn_s2, btn_s1_d;
    wire btn_rise;
    always @(posedge clk) begin
        if (rst) begin
            btn_s1   <= 1'b0;
            btn_s2   <= 1'b0;
            btn_s1_d <= 1'b0;
        end else begin
            btn_s1   <= button;
            btn_s2   <= btn_s1;
            btn_s1_d <= btn_s2;
        end
    end
    assign btn_rise = btn_s2 && !btn_s1_d;

    // =====================================================================
    // 2026-11-16: A0 button-line debounce + registered LED (hardware bug).
    // With bank3_dir=0 the FPGA never drives A0, and on the dongle the
    // button is an open switch - the line FLOATS when unpressed and picks
    // up crosstalk (proven: the discovery build's a0_flash saturated, i.e.
    // A0 edge-storms continuously once a core runs). The old combinational
    // `assign led = ... | btn_s2` re-radiated that storm onto the /RD pad
    // (bank0[5]) - a constant ~5.76 kHz waveform, which is exactly what the
    // CP210x decoded on every build (EXPERT_BRIEF_DEVKEY_UART_AB_RESULTS
    // F3/F4: core-gated, bit-identical, no ID text). Fix: (1) all LED
    // sources are registered - no combinational path to any pad; (2) the
    // raw btn_s2 level is replaced by a debounced ~100 ms flash (storm
    // saturates to steady-on = DC = silent on the wire); (3) the BTN TX
    // event requires a 1 ms solid press so crosstalk cannot spam the
    // stream. btn_rise/btn_fall are kept for the DISCOVERY a0_flash diag.
    reg [16:0] btn_db;
    reg        btn_db_fired;
    wire       btn_press_db = (btn_db == CYC_1MS) && !btn_db_fired;
    reg [22:0] btn_flash;
    always @(posedge clk) begin
        if (rst) begin
            btn_db       <= 17'd0;
            btn_db_fired <= 1'b0;
            btn_flash    <= 23'd0;
        end else begin
            if (!btn_s2) begin
                btn_db       <= 17'd0;
                btn_db_fired <= 1'b0;
            end else if (btn_db != CYC_1MS)
                btn_db <= btn_db + 17'd1;
            else
                btn_db_fired <= 1'b1;
            if (btn_press_db)
                btn_flash <= CYC_BTNFL;
            else if (btn_flash != 23'd0)
                btn_flash <= btn_flash - 23'd1;
        end
    end

    reg        ss_busy_d1;
    wire       ss_busy_fall = ss_busy_d1 && !ss_busy;

    // 2026-11-16: 4-phase round-robin on the 20 Hz busy tick: phases 0/3 ->
    // SSP (20 Hz), phase 1 -> SSD, phase 2 -> SSX (10 Hz each). Total busy
    // line volume stays 20 lines/sec.
    reg [1:0] t20hz_phase;
    always @(posedge clk) begin
        if (rst)            t20hz_phase <= 2'd0;
        else if (t20hz) t20hz_phase <= t20hz_phase + 2'd1;
    end

    // 2026-11-16: critical events LATCH-UNTIL-EMITTED. The generator only
    // samples sources while idle: a 1-cycle command pulse or a busy-fall
    // edge arriving mid-line-build was silently dropped - exactly the
    // events a wedge tracer cannot lose. (ss_err/ss_ok are stable at the
    // busy-fall posedge per the hardware contract above, so sampling at
    // the fall edge is valid.)
    reg ev_start_l, ev_load_l, ev_ok_l, ev_err_l;
    // edge-detected command set: the host HOLDS savestate_start until ack
    // (the 2026-11-16 width fix makes that window long), so a level-based
    // set would re-arm the latch mid-emit and print SS ST twice per op.
    reg ss_start_d1, ss_load_d1;
    wire ss_start_rise = ss_start & ~ss_start_d1;
    wire ss_load_rise  = ss_load  & ~ss_load_d1;
    wire sel_start = (gen_state == 2'b00) && ev_start_l;
    wire sel_load  = (gen_state == 2'b00) && !ev_start_l && ev_load_l;
    wire sel_err   = (gen_state == 2'b00) && !ev_start_l && !ev_load_l
                     && ev_err_l;
    wire sel_ok    = (gen_state == 2'b00) && !ev_start_l && !ev_load_l
                     && !ev_err_l && ev_ok_l;
    always @(posedge clk) begin
        if (rst) begin
            ev_start_l <= 1'b0; ev_load_l <= 1'b0;
            ev_ok_l    <= 1'b0; ev_err_l  <= 1'b0;
            ss_start_d1 <= 1'b0; ss_load_d1 <= 1'b0;
        end else begin
            ss_start_d1 <= ss_start;
            ss_load_d1  <= ss_load;
            ev_start_l <= ss_start_rise | (ev_start_l & ~sel_start);
            ev_load_l  <= ss_load_rise  | (ev_load_l  & ~sel_load);
            ev_err_l   <= (ss_busy_fall && ss_err)  | (ev_err_l & ~sel_err);
            ev_ok_l    <= (ss_busy_fall && !ss_err) | (ev_ok_l  & ~sel_ok);
        end
    end
    // (The earlier done_err/done_ok latches were one fall late: they were
    // written at the fall posedge while the event branches read the OLD
    // value, so each completion reported the PREVIOUS op's result. The
    // hardware contract (savestate_slot: ok/err latched at mgr_done+1,
    // busy falling two cycles later) guarantees ss_err/ss_ok are stable at
    // the fall posedge, so sample the live inputs there.)
    always @(posedge clk) begin
        if (rst) begin
            ss_busy_d1 <= 1'b0;
        end else begin
            ss_busy_d1 <= ss_busy;
        end
    end

    // test mode: button held >250 ms within the first second
    reg        test_mode;
    reg        test_pulse;
    reg [17:0] boot_win;
    reg [14:0] btn_hold;
    always @(posedge clk) begin
        if (rst) begin
            test_mode  <= 1'b0;
            test_pulse <= 1'b0;
            boot_win   <= 18'd0;
            btn_hold   <= 15'd0;
        end else begin
            test_pulse <= 1'b0;
            if (boot_win != 18'd74250)      // 1 ms at 74.25 MHz (boot window)
                boot_win <= boot_win + 1'b1;
            else if (!test_mode && btn_s2 && btn_hold >= CYC_250MS) begin
                test_mode  <= 1'b1;
                test_pulse <= 1'b1;
            end
            btn_hold <= (btn_s2 && boot_win != 18'd74250)
                      ? btn_hold + 1'b1 : 15'd0;
        end
    end
    // 2026-11-15: button lights the LED in the normal branch too - dongle
    // self-test: press button -> LED. Proves cart power + button/LED pin
    // mapping + FPGA cart-pod drive with no UART/PC involvement.
    //
    // DISCOVERY=1 additions (2026-11-15, diagnostic-only, REVERT before
    // shipping): the LED finger (/RD) blinks at ~31 Hz so the wire probe has
    // a SECOND unique frequency to fingerprint (if the CP210x RXD sits on
    // /RD it sees 31 Hz, not the core-gated 5.76 kHz mainboard signal), and
    // any A0 (button finger) edge flashes the LED (if the CP210x TXD shares
    // A0, a typed 115200-bps burst holds the LED on).
    reg [21:0] blink31_c;
    reg [13:0] a0_flash;
    wire btn_fall = btn_s1_d && !btn_s2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            blink31_c <= 22'd0;
            a0_flash  <= 14'd0;
        end else begin
            blink31_c <= (blink31_c == 22'd1197580) ? 22'd0 : blink31_c + 22'd1;
            if (btn_rise | btn_fall)
                a0_flash <= 14'd16380;
            else if (a0_flash != 14'd0)
                a0_flash <= a0_flash - 14'd1;
        end
    end
    wire led_blink31 = (blink31_c > 22'd598790);   // ~31.0 Hz, 50% duty
    wire disc_led = DISCOVERY ? (led_blink31 | a0_flash[13]) : 1'b0;
    // Registered LED (2026-11-16): every source is a register in this clock
    // domain; the raw btn_s2 level (a floating-line noise antenna) no longer
    // reaches the pad in ANY mode. test_mode now also shows the debounced
    // flash instead of following the raw level. Each OR term is explicitly
    // 1-bit: `rx_blink`/`btn_flash` are counters, and a bare OR into a 1-bit
    // net truncates to bit 0 (rx_blink[0] would re-radiate a 74 MHz edge
    // storm on the pad - the very failure this register fixes).
    reg led_r;
    always @(posedge clk) begin
        if (rst)
            led_r <= (LED_TX != 0);
        else if (LED_TX != 0)
            led_r <= uart_tx;
        else
            led_r <= disc_led | ss_busy | (rx_blink != 23'd0)
                   | (btn_flash != 23'd0);
    end
    assign led = led_r;

    reg [22:0] rx_blink;
    always @(posedge clk) begin
        if (rst)      rx_blink <= 23'd0;
        else if (rx_valid) rx_blink <= CYC_RXBL;
        else if (rx_blink != 23'd0) rx_blink <= rx_blink - 23'd1;
    end

    // RX command 'd'/'D': toggle the idle ID line
    reg dump_en;
    always @(posedge clk) begin
        if (rst) dump_en <= 1'b1;
        else if (rx_valid && (rx_byte == 8'd100 || rx_byte == 8'd68))
            dump_en <= ~dump_en;
    end

    // =====================================================================
    // Line generator: build a line into `line[]` (1 char/cycle), then emit
    // (1 char/cycle to the TX FIFO). One line in flight at a time.
    // =====================================================================
    localparam EV_NONE = 4'd0,
               EV_BOOT = 4'd1,
               EV_TEST = 4'd2,
               EV_SSST = 4'd3,
               EV_SSLD = 4'd4,
               EV_SSP  = 4'd5,
               EV_OK   = 4'd6,
               EV_ERR  = 4'd7,
               EV_ID   = 4'd8,
               EV_HB   = 4'd9,
               EV_BTN  = 4'd10,
               EV_RXB  = 4'd11,
               EV_SSD  = 4'd12,   // 2026-11-16: save/load progress counters
               EV_SSX  = 4'd13;   // 2026-11-16: port/owner/mgr state word

    reg [7:0]  line [0:35];
    reg [3:0]  ev_r;
    reg [5:0]  len_r;
    reg [5:0]  idx_r;
    reg [1:0]  gen_state;      // 0=idle 1=build 2=emit
    reg [7:0]  line_char_r;    // current char (to the TX FIFO)
    reg        booted;
    wire       line_push = (gen_state == 2'b10);

    function [7:0] hexc;
        input [3:0] n;
        begin
            case (n)
                4'd0:    hexc = 8'h30;
                4'd1:    hexc = 8'h31;
                4'd2:    hexc = 8'h32;
                4'd3:    hexc = 8'h33;
                4'd4:    hexc = 8'h34;
                4'd5:    hexc = 8'h35;
                4'd6:    hexc = 8'h36;
                4'd7:    hexc = 8'h37;
                4'd8:    hexc = 8'h38;
                4'd9:    hexc = 8'h39;
                4'd10:   hexc = 8'h41;
                4'd11:   hexc = 8'h42;
                4'd12:   hexc = 8'h43;
                4'd13:   hexc = 8'h44;
                4'd14:   hexc = 8'h45;
                default: hexc = 8'h46;
            endcase
        end
    endfunction

    // The line's character at index i for the active event. i must be 6
    // bits: the EV_BOOT banner is 33 chars (index 32 = the LF) and a 5-bit
    // index truncated 32 to 0, making the banner's LF come out as 'A' and
    // merging the first ID line into the banner (learned 2026-11-15).
    function [7:0] char_for;
        input [3:0] ev;
        input [5:0] i;
        begin
            case (ev)
            EV_BOOT: begin
                // "APF2E DEVKEY v1 uart=115200 8N1" + CRLF
                case (i)
                    5'd0:  char_for = 8'h41;  // A
                    5'd1:  char_for = 8'h50;  // P
                    5'd2:  char_for = 8'h46;  // F
                    5'd3:  char_for = 8'h32;  // 2
                    5'd4:  char_for = 8'h45;  // E
                    5'd5:  char_for = 8'h20;
                    5'd6:  char_for = 8'h44;  // D
                    5'd7:  char_for = 8'h45;  // E
                    5'd8:  char_for = 8'h56;  // V
                    5'd9:  char_for = 8'h4B;  // K
                    5'd10: char_for = 8'h45;  // E (2nd of DEVKEY)
                    5'd11: char_for = 8'h59;  // Y
                    5'd12: char_for = 8'h20;
                    5'd13: char_for = 8'h76;  // v
                    5'd14: char_for = 8'h31;  // 1
                    5'd15: char_for = 8'h20;
                    5'd16: char_for = 8'h75;  // u
                    5'd17: char_for = 8'h61;  // a
                    5'd18: char_for = 8'h72;  // r
                    5'd19: char_for = 8'h74;  // t
                    5'd20: char_for = 8'h3D;  // =
                    5'd22: char_for = 8'h31;  // 1
                    5'd21: char_for = 8'h31;  // 1
                    5'd23: char_for = 8'h35;  // 5
                    5'd24: char_for = 8'h32;  // 2
                    5'd26: char_for = 8'h30;  // 0
                    5'd25: char_for = 8'h30;  // 0
                    5'd27: char_for = 8'h20;
                    5'd28: char_for = 8'h38;  // 8
                    5'd29: char_for = 8'h4E;  // N
                    5'd30: char_for = 8'h31;  // 1
                    6'd31: char_for = 8'h0D;
                    6'd32: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_TEST: begin
                // "TEST MODE led=button" + CRLF
                case (i)
                    5'd0:  char_for = 8'h54;  // T
                    5'd1:  char_for = 8'h45;  // E
                    5'd2:  char_for = 8'h53;  // S
                    5'd3:  char_for = 8'h54;  // T
                    5'd4:  char_for = 8'h20;
                    5'd5:  char_for = 8'h4D;  // M
                    5'd6:  char_for = 8'h4F;  // O
                    5'd7:  char_for = 8'h44;  // D
                    5'd8:  char_for = 8'h45;  // E
                    5'd9:  char_for = 8'h20;
                    5'd10: char_for = 8'h6C;  // l
                    5'd11: char_for = 8'h65;  // e
                    5'd12: char_for = 8'h64;  // d
                    5'd13: char_for = 8'h3D;  // =
                    5'd14: char_for = 8'h62;  // b
                    5'd15: char_for = 8'h75;  // u
                    5'd16: char_for = 8'h74;  // t
                    5'd17: char_for = 8'h74;  // t
                    5'd18: char_for = 8'h6F;  // o
                    5'd19: char_for = 8'h6E;  // n
                    5'd20: char_for = 8'h0D;
                    5'd21: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_SSST: begin
                // "SS ST" + CRLF
                case (i)
                    5'd0: char_for = 8'h53;   // S
                    5'd1: char_for = 8'h53;   // S
                    5'd2: char_for = 8'h20;
                    5'd3: char_for = 8'h53;   // S
                    5'd4: char_for = 8'h54;   // T
                    5'd5: char_for = 8'h0D;
                    5'd6: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_SSLD: begin
                // "SS LD" + CRLF
                case (i)
                    5'd0: char_for = 8'h53;   // S
                    5'd1: char_for = 8'h53;   // S
                    5'd2: char_for = 8'h20;
                    5'd3: char_for = 8'h4C;   // L
                    5'd4: char_for = 8'h44;   // D
                    5'd5: char_for = 8'h0D;
                    5'd6: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_SSP: begin
                // "SS " + hex8(ss_status) + CRLF
                case (i)
                    5'd0: char_for = 8'h53;   // S
                    5'd1: char_for = 8'h53;   // S
                    5'd2: char_for = 8'h20;
                    5'd3:  char_for = hexc(ss_status[31:28]);
                    5'd4:  char_for = hexc(ss_status[27:24]);
                    5'd5:  char_for = hexc(ss_status[23:20]);
                    5'd6:  char_for = hexc(ss_status[19:16]);
                    5'd7:  char_for = hexc(ss_status[15:12]);
                    5'd8:  char_for = hexc(ss_status[11:8]);
                    5'd9:  char_for = hexc(ss_status[7:4]);
                    5'd10: char_for = hexc(ss_status[3:0]);
                    5'd11: char_for = 8'h0D;
                    5'd12: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_SSD: begin
                // "SSD " + wr_done(5) + ":" + wr_req(5) + " "
                //        + rd_done(5) + ":" + rd_req(5) + CRLF  (29 chars)
                // Per-word save/load progress (done:req). req counts
                // ATTEMPTS (retry re-pulses inflate it); expected totals
                // (128 KB RAM): save 0x8036, load 0x801A.
                case (i)
                    5'd0:  char_for = 8'h53;   // S
                    5'd1:  char_for = 8'h53;   // S
                    5'd2:  char_for = 8'h44;   // D
                    5'd3:  char_for = 8'h20;   // sp
                    5'd4:  char_for = hexc(ssd_snap[91:88]);
                    5'd5:  char_for = hexc(ssd_snap[87:84]);
                    5'd6:  char_for = hexc(ssd_snap[83:80]);
                    5'd7:  char_for = hexc(ssd_snap[79:76]);
                    5'd8:  char_for = hexc(ssd_snap[75:72]);
                    5'd9:  char_for = 8'h3A;   // :
                    5'd10: char_for = hexc(ssd_snap[111:108]);
                    5'd11: char_for = hexc(ssd_snap[107:104]);
                    5'd12: char_for = hexc(ssd_snap[103:100]);
                    5'd13: char_for = hexc(ssd_snap[99:96]);
                    5'd14: char_for = hexc(ssd_snap[95:92]);
                    5'd15: char_for = 8'h20;   // sp
                    5'd16: char_for = hexc(ssd_snap[51:48]);
                    5'd17: char_for = hexc(ssd_snap[47:44]);
                    5'd18: char_for = hexc(ssd_snap[43:40]);
                    5'd19: char_for = hexc(ssd_snap[39:36]);
                    5'd20: char_for = hexc(ssd_snap[35:32]);
                    5'd21: char_for = 8'h3A;   // :
                    5'd22: char_for = hexc(ssd_snap[71:68]);
                    5'd23: char_for = hexc(ssd_snap[67:64]);
                    5'd24: char_for = hexc(ssd_snap[63:60]);
                    5'd25: char_for = hexc(ssd_snap[59:56]);
                    5'd26: char_for = hexc(ssd_snap[55:52]);
                    5'd27: char_for = 8'h0D;
                    5'd28: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_SSX: begin
                // "SSX " + storage_state(4 hex) + " " + slot_state(4 hex) + CRLF
                // (15 chars). storage [31:16]: [5:0] port FSM state, [6] wr
                // queue, [7] rd queue, [10:8] inflight client, [11] port_wr_
                // idle, [12] owner word_wr, [13] owner word_rd.
                // slot [15:0]: [4:0] mgr FSM state, [5] sswr inflight,
                // [6] sswr stall, [10:7] retry, [11:10] ssrd st, [13:12] sswr st.
                case (i)
                    5'd0:  char_for = 8'h53;   // S
                    5'd1:  char_for = 8'h53;   // S
                    5'd2:  char_for = 8'h58;   // X
                    5'd3:  char_for = 8'h20;   // sp
                    5'd4:  char_for = hexc(ssd_snap[31:28]);
                    5'd5:  char_for = hexc(ssd_snap[27:24]);
                    5'd6:  char_for = hexc(ssd_snap[23:20]);
                    5'd7:  char_for = hexc(ssd_snap[19:16]);
                    5'd8:  char_for = 8'h20;   // sp
                    5'd9:  char_for = hexc(ssd_snap[15:12]);
                    5'd10: char_for = hexc(ssd_snap[11:8]);
                    5'd11: char_for = hexc(ssd_snap[7:4]);
                    5'd12: char_for = hexc(ssd_snap[3:0]);
                    5'd13: char_for = 8'h0D;
                    5'd14: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_OK: begin
                // "SS OK" + CRLF
                case (i)
                    5'd0: char_for = 8'h53;   // S
                    5'd1: char_for = 8'h53;   // S
                    5'd2: char_for = 8'h20;
                    5'd3: char_for = 8'h4F;   // O
                    5'd4: char_for = 8'h4B;   // K
                    5'd5: char_for = 8'h0D;
                    5'd6: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_ERR: begin
                // "SS ERR" + CRLF
                case (i)
                    5'd0: char_for = 8'h53;   // S
                    5'd1: char_for = 8'h53;   // S
                    5'd2: char_for = 8'h20;
                    5'd3: char_for = 8'h45;   // E
                    5'd4: char_for = 8'h52;   // R
                    5'd5: char_for = 8'h52;   // R
                    5'd6: char_for = 8'h0D;
                    5'd7: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_ID: begin
                // "ID " + hex8(ss_status) + " d" + hex2(tx_drop) + CRLF
                case (i)
                    5'd0:  char_for = 8'h49;  // I
                    5'd1:  char_for = 8'h44;  // D
                    5'd2:  char_for = 8'h20;
                    5'd3:  char_for = hexc(ss_status[31:28]);
                    5'd4:  char_for = hexc(ss_status[27:24]);
                    5'd5:  char_for = hexc(ss_status[23:20]);
                    5'd6:  char_for = hexc(ss_status[19:16]);
                    5'd7:  char_for = hexc(ss_status[15:12]);
                    5'd8:  char_for = hexc(ss_status[11:8]);
                    5'd9:  char_for = hexc(ss_status[7:4]);
                    5'd10: char_for = hexc(ss_status[3:0]);
                    5'd11: char_for = 8'h20;
                    5'd12: char_for = 8'h64;  // d
                    5'd13: char_for = hexc(tx_drop[7:4]);
                    5'd14: char_for = hexc(tx_drop[3:0]);
                    5'd15: char_for = 8'h0D;
                    5'd16: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_HB: begin
                // "HB " + hex2(t1hz tick counter) + CRLF
                case (i)
                    5'd0: char_for = 8'h48;   // H
                    5'd1: char_for = 8'h42;   // B
                    5'd2: char_for = 8'h20;
                    5'd3: char_for = hexc(hb_n[3:0]);
                    5'd4: char_for = 8'h0D;
                    5'd5: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_BTN: begin
                // "BTN" + CRLF
                case (i)
                    5'd0: char_for = 8'h42;   // B
                    5'd1: char_for = 8'h54;   // T
                    5'd2: char_for = 8'h4E;   // N
                    5'd3: char_for = 8'h0D;
                    5'd4: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            EV_RXB: begin
                // "RX " + hex2(rx_byte) + CRLF
                case (i)
                    5'd0: char_for = 8'h52;   // R
                    5'd1: char_for = 8'h58;   // X
                    5'd2: char_for = 8'h20;
                    5'd3: char_for = hexc(rx_byte[7:4]);
                    5'd4: char_for = hexc(rx_byte[3:0]);
                    5'd5: char_for = 8'h0D;
                    5'd6: char_for = 8'h0A;
                    default: char_for = 8'h0A;
                endcase
            end
            default: char_for = 8'h0A;
            endcase
        end
    endfunction

    reg [3:0] hb_n;              // 1 Hz tick counter (for HB lines)
    always @(posedge clk) begin
        if (rst)      hb_n <= 4'd0;
        else if (t1hz) hb_n <= hb_n + 1'b1;
    end

    always @(posedge clk) begin
        if (rst) begin
            gen_state   <= 2'b00;
            ev_r        <= EV_NONE;
            booted      <= 1'b0;
            line_char_r <= 8'h0A;
        end else case (gen_state)
        2'b00: begin
            // pick the highest-priority pending event
            if (!booted) begin
                gen_state <= 2'b01; ev_r <= EV_BOOT; booted <= 1'b1;
                len_r <= 6'd33; idx_r <= 6'd0;
            end else if (test_pulse) begin
                gen_state <= 2'b01; ev_r <= EV_TEST;
                len_r <= 6'd22; idx_r <= 6'd0;
            end else if (rx_valid) begin
                gen_state <= 2'b01; ev_r <= EV_RXB;
                len_r <= 6'd7; idx_r <= 6'd0;
            end else if (btn_press_db) begin   // 2026-11-16: debounced (A0 floats)
                gen_state <= 2'b01; ev_r <= EV_BTN;
                len_r <= 6'd5; idx_r <= 6'd0;
            end else if (sel_start) begin
                gen_state <= 2'b01; ev_r <= EV_SSST;
                len_r <= 6'd7; idx_r <= 6'd0;
            end else if (sel_load) begin
                gen_state <= 2'b01; ev_r <= EV_SSLD;
                len_r <= 6'd7; idx_r <= 6'd0;
            end else if (ss_busy && t20hz && (t20hz_phase == 2'd0 || t20hz_phase == 2'd3)) begin
                gen_state <= 2'b01; ev_r <= EV_SSP;
                len_r <= 6'd13; idx_r <= 6'd0;
            end else if (ss_busy && t20hz && t20hz_phase == 2'd1) begin
                gen_state <= 2'b01; ev_r <= EV_SSD;
                len_r <= 6'd29; idx_r <= 6'd0;
            end else if (ss_busy && t20hz && t20hz_phase == 2'd2) begin
                gen_state <= 2'b01; ev_r <= EV_SSX;
                len_r <= 6'd15; idx_r <= 6'd0;
            end else if (sel_err) begin
                gen_state <= 2'b01; ev_r <= EV_ERR;
                len_r <= 6'd8; idx_r <= 6'd0;
            end else if (sel_ok) begin
                gen_state <= 2'b01; ev_r <= EV_OK;
                len_r <= 6'd7; idx_r <= 6'd0;
            end else if (!ss_busy && dump_en && t1hz && idle_due) begin
                gen_state <= 2'b01; ev_r <= EV_ID;
                len_r <= 6'd17; idx_r <= 6'd0;
            end else if (!ss_busy && !dump_en && t1hz && idle_due) begin
                gen_state <= 2'b01; ev_r <= EV_HB;
                len_r <= 6'd6; idx_r <= 6'd0;
            end
        end
        2'b01: begin
            // build phase: snapshot one char per cycle
            line[idx_r]   <= char_for(ev_r, idx_r);
            line_char_r   <= char_for(ev_r, idx_r);
            if (idx_r == len_r - 6'd1) begin
                gen_state   <= 2'b10;
                idx_r       <= 5'd0;
                line_char_r <= char_for(ev_r, 5'd0);  // first emit char
            end else
                idx_r <= idx_r + 1'b1;
        end
        2'b10: begin
            // emit phase: line_push is high, the FIFO takes line_char_r
            if (idx_r == len_r - 6'd1) begin
                gen_state <= 2'b00;
            end else begin
                idx_r       <= idx_r + 1'b1;
                line_char_r <= line[idx_r + 1'b1];    // pre-load next char
            end
        end
        endcase
    end

endmodule
