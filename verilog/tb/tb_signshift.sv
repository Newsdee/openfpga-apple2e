// tb_signshift.sv - does Verilator honor signed >> as arithmetic shift?
// -20164 in 17-bit two's complement = 131072-20164 = 110908
// IEEE arithmetic >> 7  -> -157 = 131072-157 = 130915
// logical >> 7 (wrong)  -> 110908>>7 = 866
module tb_signshift;
    reg signed [16:0] v;
    wire signed [16:0] s = v >> 7;
    initial begin
        v = 17'd110908;   // -20164
        #1;
        if (s === 17'd130915) $display("PROBE PASS (arithmetic)");
        else if (s === 17'd866) $display("PROBE FAIL: logical shift (%0d)", $unsigned(s));
        else $display("PROBE OTHER: %0d (unsigned %0d)", $signed(s), $unsigned(s));
        $finish;
    end
endmodule
