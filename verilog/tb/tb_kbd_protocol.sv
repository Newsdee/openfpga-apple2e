// tb_kbd_protocol.sv — deterministic keyboard-protocol regression (Phase C).
//
// Per recommendation.md section 6 and the expert review: this test asserts the
// IIe keyboard CONTRACT, not an "exactly one read" requirement:
//   T1  one virtual press        -> key_ready (K[7]) set, code latched
//   T2  two $C000-class reads     -> the pending key is RETAINED (polling does
//                                     not clear it; `reads` is not pulsed)
//   T3  a proper $C010-class ack  -> key_ready clears (a single `reads` pulse)
//   T4  poll after ack            -> key_ready stays low until a new event
//   T5  unrelated I/O, pending key-> the key is preserved (no `reads`)
//   T6  next press                -> a second key is accepted and can be acked
//   T7  OSK close, pending key    -> cleared, no stale/fabricated press
//   T8  reset                     -> clean state
//
// Every failed requirement raises $fatal (nonzero exit). The machine's $C000/
// $C010 address decode (which `reads` corresponds to) is verified separately in
// the P2a sim; this bench drives `reads` directly to test the key-latch
// behaviour that the contract is about.
//
// Pure self-driving TB -> build with `verilator --binary --timing`.
`timescale 1ns/1ps

module tb_kbd_protocol;

    reg         clk = 1'b0;
    reg         reset = 1'b1;
    // virtual-key inputs (OSK controller side)
    reg         virtual_active   = 1'b0;
    reg         virtual_event    = 1'b0;
    reg         virtual_pressed  = 1'b0;
    reg  [6:0]  virtual_code     = 7'd0;
    reg         virtual_control  = 1'b0;
    reg         virtual_open_apple  = 1'b0;
    reg         virtual_closed_apple= 1'b0;
    reg         reads = 1'b0;      // the machine's READ_KEY ack strobe
    // keyboard outputs
    wire        akd;
    wire [7:0]  K;
    wire        open_apple, closed_apple, soft_reset, video_toggle, palette_toggle;

    keyboard dut (
        .CLK_14M(clk),
        .PS2_Key(11'b0),
        .virtual_active(virtual_active),
        .virtual_event(virtual_event),
        .virtual_pressed(virtual_pressed),
        .virtual_code(virtual_code),
        .virtual_control(virtual_control),
        .virtual_open_apple(virtual_open_apple),
        .virtual_closed_apple(virtual_closed_apple),
        .reads(reads),
        .reset(reset),
        .akd(akd),
        .K(K),
        .open_apple(open_apple),
        .closed_apple(closed_apple),
        .soft_reset(soft_reset),
        .video_toggle(video_toggle),
        .palette_toggle(palette_toggle)
    );

    always #5 clk = ~clk;   // 100 ns period (arbitrary; only edge relationships matter)

    integer fails = 0;
    task check(input [8*64-1:0] name, input cond);
        begin
            if (!cond) begin
                $display("FAIL: %0s  (K=%h akd=%b reads=%b)", name, K, akd, reads);
                fails = fails + 1;
            end else
                $display("ok  : %0s  (K=%h akd=%b)", name, K, akd);
        end
    endtask

    task nclk(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    // a virtual press: toggle the event with pressed=1, then release
    task press_key(input [6:0] code);
        begin
            @(posedge clk); virtual_event = 1'b1; virtual_pressed = 1'b1; virtual_code = code;
            @(posedge clk); virtual_event = 1'b0; virtual_pressed = 1'b0;   // release
        end
    endtask

    // a single `reads` pulse = one machine acknowledgement
    task ack;
        begin
            @(posedge clk); reads = 1'b1;
            @(posedge clk); reads = 1'b0;
        end
    endtask

    task main;
        begin
            // T0: reset
            reset = 1'b1; virtual_active = 1'b0; nclk(4);
            reset = 1'b0; nclk(4);
            check("T0 reset: key_ready clear", K[7] === 1'b0);

            // open the OSK
            @(posedge clk) virtual_active = 1'b1; nclk(4);

            // T1: one press latches ready + code
            press_key(7'h51);            // 'Q'
            nclk(3);
            check("T1 press sets key_ready + code Q", (K === 8'hD1));

            // T2: two $C000-class reads (reads stays 0) RETAIN the pending key
            nclk(6);
            check("T2a first $C000 read retains key", (K === 8'hD1));
            nclk(6);
            check("T2b second $C000 read retains key", (K === 8'hD1));

            // T3: a proper $C010-class ack (one reads pulse) clears ready
            ack;
            nclk(3);
            check("T3 ack clears key_ready (code retained)", (K === 8'h51));

            // T4: polling after the ack leaves ready low
            nclk(8);
            check("T4 poll after ack keeps ready low", (K[7] === 1'b0));

            // T5: a new pending key survives unrelated I/O (no reads)
            press_key(7'h41);            // 'A'
            nclk(3);
            check("T5a second press sets ready + code A", (K === 8'hC1));
            nclk(10);                    // unrelated I/O: reads stays 0
            check("T5b unrelated I/O preserves pending key", (K === 8'hC1));

            // T6: the next key can be acked and another accepted
            ack;
            nclk(3);
            check("T6a second key acked", (K === 8'h41 && K[7] === 1'b0));
            press_key(7'h20);            // space
            nclk(3);
            check("T6b third press accepted", (K === 8'hA0));

            // T7: OSK close with a pending key clears it (no stale press)
            @(posedge clk) virtual_active = 1'b0;
            nclk(4);
            check("T7 OSK close clears pending key", (K[7] === 1'b0));
            press_key(7'h51);            // a press while OSK closed must NOT latch
            nclk(4);
            check("T7b press while closed is not fabricated", (K[7] === 1'b0));

            // T8: reset returns to a clean state
            reset = 1'b1; nclk(4);
            check("T8 reset clears ready", (K[7] === 1'b0));

            if (fails == 0)
                $display("=== tb_kbd_protocol: PASS (all 16 checks) ===");
            else
                $fatal(1, "tb_kbd_protocol: %0d check(s) FAILED", fails);
            $finish;
        end
    endtask

    initial main;

endmodule
