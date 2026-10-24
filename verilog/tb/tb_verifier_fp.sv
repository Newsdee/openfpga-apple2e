// tb_verifier_fp.sv - disk_verifier image-fingerprint self-test (M1, 2026-10-23)
//
// Self-driving: a synchronous fake word-port serves a deterministic pattern
//   byte(i) = (i + i>>8 + i>>16) & 0xFF          (i = byte index in file)
//   word(w)  = { b(4w), b(4w+1), b(4w+2), b(4w+3) }  ([31:24] = first byte,
//   the bridge endianness the real loader uses).
//
// The TB only PRINTS the DUT's results; correctness is checked against the
// PC oracle tools/woz_fingerprint.py --pattern N (same byte formula, zlib
// CRC32). This is deliberate: a Verilog-side CRC reimplementation would only
// prove self-consistency, not that the fingerprint is a zlib-CRC32.
//
// Cases (chosen to exercise the 64 KB window boundaries + masking):
//   200000  all four windows non-empty, last partial
//   131072  exactly two full windows
//   65536   window boundary == EOF (W0 full, W1..3 empty)
//   65537   boundary + 1 byte (W1 = 1 byte)
//   100     single partial window
//   10      fp_first/fp_last masking (n < 16)
//   0       empty file
//
// Build (from verilog/):
//   export VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
//   <verilator> --binary --timing -j 4 --top tb_verifier_fp -Wno-fatal \
//     -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch \
//     --Mdir obj_dir_tb_verifier_fp \
//     ../src/fpga/core/apple2e/disk_verifier.v tb/tb_verifier_fp.sv
//   obj_dir_tb_verifier_fp/Vtb_verifier_fp.exe

`timescale 1ns/1ps
module tb_verifier_fp;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT under test ----
    reg  [31:0] n_bytes;
    reg         start;
    wire        start_done, busy, done, ok, stuck;
    wire [23:0] req_addr;
    wire        req;
    wire [31:0] crc32, first_word, last_word;
    wire [15:0] words_read, words_readout;
    wire [127:0] fp_first, fp_last;
    wire [31:0] fp_w0, fp_w1, fp_w2, fp_w3;

    disk_verifier #(.TIMEOUT_CYCLES(1000), .FP_EN(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .n_bytes(n_bytes), .start(start), .start_done(start_done),
        .req(req), .req_addr(req_addr),
        .rd_done(rd_done), .rd_data_ok(rd_data_ok), .rd_data(rd_data),
        .busy(busy), .done(done), .ok(ok), .stuck(stuck),
        .timeout_override(32'd0),
        .crc32(crc32), .first_word(first_word), .last_word(last_word),
        .words_read(words_read), .words_readout(words_readout),
        .fp_first(fp_first), .fp_last(fp_last),
        .fp_w0(fp_w0), .fp_w1(fp_w1), .fp_w2(fp_w2), .fp_w3(fp_w3)
    );

    // ---- fake word-port: serve the pattern one cycle after req rises ----
    reg [31:0] rd_data;
    reg        rd_done, rd_data_ok;

    function [7:0] pat_byte;
        input [31:0] i;
        begin
            pat_byte = (i + (i >> 8) + (i >> 16)) & 8'hFF;
        end
    endfunction
    function [31:0] pat_word;
        input [31:0] w;
        begin
            pat_word = { pat_byte(w*4 + 0), pat_byte(w*4 + 1),
                         pat_byte(w*4 + 2), pat_byte(w*4 + 3) };
        end
    endfunction

    always @(posedge clk) begin
        if (req && !rd_done) begin
            rd_data    <= pat_word(req_addr);
            rd_done    <= 1'b1;
            rd_data_ok <= 1'b1;
        end else begin
            rd_done    <= 1'b0;
            rd_data_ok <= 1'b0;
        end
    end

    // ---- run one verification pass and print the DUT's results ----
    task run_case;
        input [31:0] nb;
        begin
            @(negedge clk);
            n_bytes <= nb;
            start   <= 1'b1;
            while (!done) @(posedge clk);
            @(negedge clk);
            $display("CASE n=%0d ok=%b stuck=%b words=%0d crc32=%08X fw=%08X lw=%08X",
                     nb, ok, stuck, words_readout, crc32, first_word, last_word);
            $display("  FP_FIRST=%h", fp_first);
            $display("  FP_LAST =%h", fp_last);
            $display("  FP_W0=%08X FP_W1=%08X FP_W2=%08X FP_W3=%08X",
                     fp_w0, fp_w1, fp_w2, fp_w3);
            @(negedge clk);
            start <= 1'b0;
            while (start_done) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 1'b0; start = 1'b0; n_bytes = 32'd0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        run_case(32'd200000);
        run_case(32'd131072);
        run_case(32'd65536);
        run_case(32'd65537);
        run_case(32'd100);
        run_case(32'd10);
        run_case(32'd0);
        $display("TB: VERIFIER_FP: all cases printed");
        $finish;
    end

endmodule
