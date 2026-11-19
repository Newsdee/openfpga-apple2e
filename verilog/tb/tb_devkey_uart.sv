// Physical-rate gate: no timing constants are taken from the UART DUT.
`timescale 1ps/1ps

module tb_devkey_uart;
    localparam time HOST_BIT_PS = 8_680_556; // 115200 baud, independent PC clock
    reg clk = 1'b0;
    initial begin
        forever #6734 clk = ~clk; // 74.25 MHz within integer-ps rounding
    end

    reg rst = 1'b1;
    reg ss_start = 0, ss_load = 0, ss_busy = 0, ss_ok = 0, ss_err = 0;
    reg [31:0] ss_status = 32'h00000102;
    // 2026-11-16: SSD/SSX snapshot word (the top-level toggle-handshake latch
    // input). Layout: {8 spare, 8 cmd-while-busy, 20 wr_req, 20 wr_done,
    // 20 rd_req, 20 rd_done, 16 storage state, 16 slot state}.
    reg [127:0] ssd_snap = 128'h0;
    // 2026-11-19 SSY: WOZ feed tap snapshot (machine-domain word crossed to
    // 74a at the top). Layout: {3 mstate, 1 mounted, 1 sd_ack, 1 tfault,
    // 1 sd_buff_wr, 1 woz_sd_rd, 1 D1_MOTOR_ON, 1 D1_ACTIVE, 16 reads[15:0],
    // 6 spare}.
    reg [31:0] ssy_snap = 32'h0;
    // 2026-11-17 SS HD: source of the load-header dump snapshot
    reg [63:0] ss_hd0 = 0;
    reg [63:0] ss_hd1 = 0;
    reg [1:0]  ss_hd_err = 0;
    reg button = 0;
    reg host_tx = 1;
    wire uart_tx, uart_rx, led;
    tri [7:4] cart0;
    tri [7:0] cart3;
    tri cart31;
    wire dir0, dir3, dir31, key_button;
    assign cart3[0] = ~button;
    assign cart31 = host_tx;
    assign cart0[4] = 1'b1;
    assign cart0[7] = 1'b1;

    debug_key key (
        .clk(clk), .cart_tran_bank0_dir(dir0), .cart_tran_bank0(cart0),
        .cart_tran_bank3_dir(dir3), .cart_tran_bank3(cart3),
        .cart_tran_pin31_dir(dir31), .cart_tran_pin31(cart31),
        .led(led), .button(key_button), .uart_tx(uart_tx), .uart_rx(uart_rx)
    );
    devkey_uart #(.IDLE_PERIOD(1)) dut (
        .clk(clk), .rst(rst), .ss_start(ss_start), .ss_load(ss_load),
        .ss_busy(ss_busy), .ss_ok(ss_ok), .ss_err(ss_err), .ss_status(ss_status),
        .ssd_snap(ssd_snap),
        .ssy_snap(ssy_snap),
        .ss_hd0(ss_hd0), .ss_hd1(ss_hd1), .ss_hd_err(ss_hd_err),
        .button(key_button), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led)
    );

    // Exercise the diagnostic mux with busy/button/RX/discovery LED sources.
    wire mirror_tx, mirror_led;
    devkey_uart #(.LED_TX(1), .DISCOVERY(1), .IDLE_PERIOD(1)) mirror (
        .clk(clk), .rst(rst), .ss_start(ss_start), .ss_load(ss_load),
        .ss_busy(ss_busy), .ss_ok(ss_ok), .ss_err(ss_err), .ss_status(ss_status),
        .ssd_snap(ssd_snap),
        .ssy_snap(ssy_snap),
        .ss_hd0(ss_hd0), .ss_hd1(ss_hd1), .ss_hd_err(ss_hd_err),
        .button(key_button), .uart_rx(uart_rx), .uart_tx(mirror_tx),
        .led(mirror_led)
    );
    reg expected_led;
    integer mirror_checks = 0;
    always @(posedge clk) begin
        expected_led = rst ? 1'b1 : mirror_tx;
        #1;
        if (mirror_led !== expected_led)
            $fatal(1, "LED_TX was masked by another LED source");
        if (!rst) mirror_checks++;
    end

    string lines [0:2047];
    integer line_count = 0;
    integer rx_lines = 0;
    integer decoded_bytes = 0;
    string partial = "";
    reg [7:0] decoded;
    integer reset_epoch = 0;
    integer frame_epoch;
    always @(posedge rst) reset_epoch++;

    // Ordinary 8N1 PC receiver, with an independent nominal bit period.
    initial begin
        forever begin
            @(negedge cart0[6]);
            if (!rst) begin
                frame_epoch = reset_epoch;
                #(HOST_BIT_PS / 2);
                if (cart0[6] !== 1'b0) $fatal(1, "TX start bit too short");
                for (integer bit_i = 0; bit_i < 8; bit_i++) begin
                    #(HOST_BIT_PS);
                    decoded[bit_i] = cart0[6];
                end
                #(HOST_BIT_PS);
                if (reset_epoch != frame_epoch) begin
                    partial = "";
                end else begin
                  if (cart0[6] !== 1'b1) $fatal(1, "TX stop bit invalid");
                  decoded_bytes++;
                  if (decoded == 8'h0A) begin
                    if (partial.len() == 0 || partial[partial.len()-1] != 8'h0D)
                        $fatal(1, "Output line is not CRLF terminated");
                    if (line_count == 2048) $fatal(1, "TB line buffer full");
                    lines[line_count] = partial.substr(0, partial.len()-2);
                    if (lines[line_count].substr(0, 2) == "RX ") rx_lines++;
                    line_count++;
                    partial = "";
                  end else begin
                    partial = {partial, decoded};
                    if (partial.len() > 80) $fatal(1, "Malformed/overlong UART line");
                  end
                end
            end
        end
    end

    time start_edge, bit_width;
    initial begin
        wait (!rst);
        // Banner begins with 'A', whose data bit 0 is high.
        @(negedge cart0[6]);
        start_edge = $time;
        @(posedge cart0[6]);
        bit_width = $time - start_edge;
        if (bit_width < 8_500_000 || bit_width > 8_850_000)
            $fatal(1, "Not 115200 baud: start bit = %0t", bit_width);
        $display("PASS TX measured bit width: %0t (ps)", bit_width);
    end

    task automatic expect_line(input string expected, input integer first);
        bit found;
        begin
            found = 0;
            for (integer cycles = 0; cycles < 6_000_000 && !found; cycles++) begin
                @(negedge clk);
                for (integer i = first; i < line_count; i++)
                    if (lines[i] == expected) found = 1;
            end
            if (!found) begin
                for (integer i = first; i < line_count; i++)
                    $display("  received: %s", lines[i]);
                $fatal(1, "Missing line: %s", expected);
            end
        end
    endtask

    task automatic host_bit(input integer skew);
        case (skew)
            -1: #(HOST_BIT_PS - 80_000);
             0: #(HOST_BIT_PS);
             1: #(HOST_BIT_PS + 80_000);
            default: $fatal(1, "Invalid host baud variation");
        endcase
    endtask

    task automatic send_byte(input byte value, input bit good_stop,
                              input integer skew);
        begin
            host_tx = 0;
            host_bit(skew);
            for (integer i = 0; i < 8; i++) begin
                host_tx = value[i];
                host_bit(skew);
            end
            host_tx = good_stop;
            host_bit(skew);
        end
    endtask

    function automatic string echo_line(input byte value);
        string text;
        begin
            text = $sformatf("RX %02x", value);
            echo_line = text.toupper();
        end
    endfunction

    task automatic pulse_command(input bit save_op);
        begin
            @(negedge clk);
            ss_start = save_op;
            ss_load = !save_op;
            @(negedge clk);
            ss_start = 0;
            ss_load = 0;
        end
    endtask

    integer mark, before_rx;
    initial begin
        repeat (100) @(negedge clk);
        rst = 0;
        if (dir0 !== 1 || dir3 !== 0 || dir31 !== 0)
            $fatal(1, "Debug-key pad directions incorrect");
        expect_line("APF2E DEVKEY v1 uart=115200 8N1", 0);
        expect_line("ID 00000102 d00", 0);
        $display("PASS boot banner and ID through debug-key TX pad at 115200");

        // 2026-11-19 SSY: WOZ feed tap line, one per 20 Hz tick while idle.
        // The first tick lands ~50 ms after reset; scan a 108 ms window so
        // at least one tick (and its full line) is covered. Expect decodes
        // the fixed ssy_snap word: s=1 m=1 a=0 q=1 k=0 f=1 b=0 d=ABCD.
        begin : ssy_check
            bit found;
            ssy_snap = {3'b001, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0,
                        16'hABCD, 6'd0};
            found = 0;
            for (integer c = 0; c < 8_000_000 && !found; c++) begin
                @(negedge clk);
                for (integer i = 0; i < line_count; i++)
                    if (lines[i] == "SSY s1 m1 a0 q1 k0 f1 b0 dABCD") found = 1;
            end
            ssy_snap = 32'd0;
            if (!found) $fatal(1, "SSY tap line missing");
            $display("PASS SSY WOZ feed tap line");
        end

        mark = line_count;
        ss_status = 32'h12345678;
        ss_busy = 1;
        pulse_command(1);
        expect_line("SS ST", mark);
        // 2026-11-19: the 20 Hz busy poll emits SSP on only 2 of its 4
        // phase ticks, and the SSY scan above shifted the phase alignment -
        // the fixed 80 ms expect_line window can now legitimately land
        // between two SSP ticks. Scan 215 ms (>= 4 ticks) instead.
        begin : ssp_wait
            bit found;
            found = 0;
            for (integer c = 0; c < 16_000_000 && !found; c++) begin
                @(negedge clk);
                for (integer i = mark; i < line_count; i++)
                    if (lines[i] == "SS 12345678") found = 1;
            end
            if (!found) $fatal(1, "Missing line: SS 12345678");
        end
        ss_ok = 1;
        repeat (10) @(negedge clk);
        ss_busy = 0;
        expect_line("SS OK", mark);
        mark = line_count;
        ss_ok = 0;
        ss_busy = 1;
        pulse_command(0);
        expect_line("SS LD", mark);
        ss_err = 1;
        repeat (10) @(negedge clk);
        ss_busy = 0;
        expect_line("SS ERR", mark);
        // 2026-11-17 SS HD: a failed load also emits the load-header dump
        // line one scan after SS ERR (snapshot taken at the ss_busy fall
        // while ss_err is high; error_code 2 = invalid/empty).
        ss_hd0    = 64'h00008040_00000002;
        ss_hd1    = 64'h41324C31_01000001;
        ss_hd_err = 2'b10;
        ss_busy = 1;
        pulse_command(0);
        ss_err = 1;
        repeat (10) @(negedge clk);
        ss_busy = 0;
        expect_line("SS ERR", mark);
        expect_line("SS HD 00008040 41324C31 E2", mark);
        ss_err = 0;
        ss_hd0 = 0; ss_hd1 = 0; ss_hd_err = 0;
        $display("PASS save/load event and completion lines");

        // 2026-11-16: SSD/SSX progress/state lines + mid-build event latch.
        // SSP stays 20 Hz; SSD/SSX are 10 Hz each (phase round-robin). Hold
        // busy ~300 ms (>= 6 ticks) so all three line types fire, drop a
        // 1-cycle ss_start pulse mid-window (it must survive the generator
        // being mid-line-build - the latch fix), then release busy (the SS
        // OK at the busy fall must also survive).
        ssd_snap = {8'h00, 8'h00, 20'h08038, 20'h08036, 20'h0801C, 20'h0801A,
                    16'h1234, 16'hABCD};
        mark = line_count;
        ss_status = 32'hAAAA5555;
        ss_busy = 1;
        repeat (22_222_000) @(negedge clk);   // ~300 ms
        ss_start = 1;                          // 1-cycle, mid-window
        @(negedge clk);
        ss_start = 0;
        repeat (2_000_000) @(negedge clk);     // ~27 ms: next tick emits
        ss_busy = 0;
        repeat (2_000_000) @(negedge clk);     // let SS OK land
        begin : ssd_check
            integer n_ssp, n_ssd, n_ssx;
            bit saw_st, saw_ok;
            n_ssp = 0; n_ssd = 0; n_ssx = 0; saw_st = 0; saw_ok = 0;
            for (integer i = mark; i < line_count; i++) begin
                if (lines[i] == "SS AAAA5555")                        n_ssp = n_ssp + 1;
                else if (lines[i] == "SSD 08036:08038 0801A:0801C")    n_ssd = n_ssd + 1;
                else if (lines[i] == "SSX 1234 ABCD")                  n_ssx = n_ssx + 1;
                else if (lines[i] == "SS ST")                          saw_st = 1;
                else if (lines[i] == "SS OK")                          saw_ok = 1;
            end
            if (n_ssp < 2)        $fatal(1, "SSD/SSX: SSP under (n=%0d)", n_ssp);
            if (n_ssd < 1 || n_ssd > 3) $fatal(1, "SSD/SSX: SSD count n=%0d", n_ssd);
            if (n_ssx < 1 || n_ssx > 2) $fatal(1, "SSD/SSX: SSX count n=%0d", n_ssx);
            if (!saw_st)         $fatal(1, "SSD/SSX: mid-build ss_start pulse lost");
            if (!saw_ok)         $fatal(1, "SSD/SSX: SS OK lost at busy fall");
            $display("PASS SSD/SSX progress/state lines and mid-build event latch (ssp=%0d ssd=%0d ssx=%0d)",
                     n_ssp, n_ssd, n_ssx);
        end

        mark = line_count;
        #4217; // asynchronous start, including the debug-key RX synchronizer
        send_byte(8'h64, 1, 0);
        expect_line("RX 64", mark);
        // 'd' disabled ID; heartbeat now replaces it.
        begin : heartbeat
            bit found;
            found = 0;
            repeat (250_000) @(negedge clk);
            for (integer i = mark; i < line_count; i++)
                if (lines[i].substr(0, 2) == "HB ") found = 1;
            if (!found) $fatal(1, "RX command did not switch ID to heartbeat");
        end
        ss_busy = 1; // suppress idle lines during receive coverage
        repeat (3) @(negedge clk);
        if (!led) $fatal(1, "Normal LED does not show busy");

        // All 256 values, at phase offsets and baud errors independent of the DUT.
        for (integer b = 0; b < 256; b++) begin
            mark = line_count;
            case (b % 3)
                0: #1009;
                1: #2018;
                2: #3027;
            endcase
            send_byte(8'(b), 1, b % 3 - 1);
            expect_line(echo_line(8'(b)), mark);
        end
        $display("PASS RX all 256 byte values, +/-0.92%% host baud and async phase");

        mark = line_count;
        send_byte(8'h00, 1, 0);
        send_byte(8'h55, 1, 0);
        send_byte(8'hAA, 1, 0);
        send_byte(8'h80, 1, 0);
        send_byte(8'hFF, 1, 0);
        expect_line("RX FF", mark);
        if (lines[mark] != "RX 00" || lines[mark+1] != "RX 55" ||
            lines[mark+2] != "RX AA" || lines[mark+3] != "RX 80" ||
            lines[mark+4] != "RX FF")
            $fatal(1, "Back-to-back RX reordered/lost bytes");
        $display("PASS back-to-back RX");

        before_rx = rx_lines;
        host_tx = 0;
        #(HOST_BIT_PS / 4); // false start
        host_tx = 1;
        #(HOST_BIT_PS * 12);
        send_byte(8'h00, 0, 0); // bad stop, then sustained break
        #(HOST_BIT_PS * 12);
        host_tx = 1;
        #(HOST_BIT_PS * 3);
        repeat (200_000) @(negedge clk);
        if (rx_lines != before_rx) $fatal(1, "Invalid UART frame was accepted");
        mark = line_count;
        send_byte(8'hA5, 1, 0);
        expect_line("RX A5", mark);
        $display("PASS false-start/bad-stop/break rejection and recovery");

        ss_busy = 0;
        #(HOST_BIT_PS * 120); // RX LED must last longer than the old 200 us
        if (!led) $fatal(1, "RX blink too short to be visible");
        // LED diagnostic must remain a TX mirror throughout busy and button flash.
        button = 1;
        repeat (80_000) @(negedge clk);
        button = 0;
        ss_busy = 0;
        mark = line_count;
        send_byte(8'h78, 1, 0);
        if (!led) $fatal(1, "RX/button activity did not light normal LED");
        expect_line("RX 78", mark);
        $display("PASS LED_TX exclusive mirror (%0d clock checks)", mirror_checks);

        // Reset during an RX frame: no partial byte may survive reset.
        host_tx = 0;
        #(HOST_BIT_PS * 3);
        @(negedge clk);
        rst = 1;
        host_tx = 1;
        #(HOST_BIT_PS * 12); // let the PC receiver discard an interrupted frame
        mark = line_count;
        @(negedge clk);
        rst = 0;
        expect_line("APF2E DEVKEY v1 uart=115200 8N1", mark);
        mark = line_count;
        send_byte(8'h81, 1, 0);
        expect_line("RX 81", mark);
        if (bit_width == 0 || decoded_bytes < 100 || rx_lines < 264)
            $fatal(1, "Coverage incomplete");
        $display("DEVKEY_UART ALL CHECKS PASSED: bytes=%0d rx=%0d lines=%0d",
                 decoded_bytes, rx_lines, line_count);
        $finish;
    end

    initial begin
        #1_000_000_000_000;
        $fatal(1, "Global timeout: lines=%0d", line_count);
    end
endmodule
