// Wrapper: pattern-expectation DUT vs truncated pattern (65,535 of
// 65,536 lines) - EXPECT sim FAIL (last address unwritten by the file).
module tb_wrap_neg_shortpat ();
    tb_ram_zero #(.VARIANT(0), .CHECK_LOAD(1), .IMG("img_neg/short_pattern.hex")) top ();
endmodule
