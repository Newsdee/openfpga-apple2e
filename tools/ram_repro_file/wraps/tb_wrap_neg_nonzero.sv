// Wrapper: zero-expectation DUT vs all-nonzero image - EXPECT sim FAIL.
module tb_wrap_neg_nonzero ();
    tb_ram_zero #(.VARIANT(0), .CHECK_LOAD(0), .IMG("img_neg/nonzero.hex")) top ();
endmodule
