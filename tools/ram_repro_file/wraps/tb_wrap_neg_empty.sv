// Wrapper: zero-expectation DUT vs EMPTY image - the documented FALSE
// POSITIVE trap: sim PASSES (default-zero memory) while the FPGA would
// have uninitialised M10Ks. The preflight validator is the real gate.
module tb_wrap_neg_empty ();
    tb_ram_zero #(.VARIANT(0), .CHECK_LOAD(0), .IMG("img_neg/empty.hex")) top ();
endmodule
