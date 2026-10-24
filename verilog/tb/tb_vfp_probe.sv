// tb_vfp_probe.sv - instrumented probe of disk_verifier fingerprint state
`timescale 1ns/1ps
module tb_vfp_probe;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

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

    integer wcap;
    always @(posedge clk) begin
        // capture on the ST_REQ acceptance cycle
        if (req && rd_done && rd_data_ok) begin
            wcap <= wcap + 1;
            if (wcap < 6 || dut.widx == 32'd16384)
                $display("CAP widx=%0d rd=%08X | fp_raw=%h fp_tail=%h wcrc=%08X wbase=%0d",
                         dut.widx, rd_data, dut.fp_raw, dut.fp_tail, dut.wcrc, dut.wbase_idx);
        end
    end

    initial begin
        rst_n = 1'b0; start = 1'b0; n_bytes = 32'd70000; wcap = 0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        n_bytes <= 32'd70000; start <= 1'b1;
        while (!done) @(posedge clk);
        @(negedge clk);
        $display("DONE ok=%b crc=%08X", ok, crc32);
        $display("FP_FIRST=%h", fp_first);
        $display("FP_LAST =%h", fp_last);
        $display("FP_W0=%08X W1=%08X W2=%08X W3=%08X", fp_w0, fp_w1, fp_w2, fp_w3);
        $finish;
    end

endmodule
