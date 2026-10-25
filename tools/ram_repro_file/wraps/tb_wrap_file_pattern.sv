// Wrapper: file-init DUT, nonzero pattern image (LOAD PROOF - cannot pass
// on default-zero memory).
module tb_wrap_file_pattern ();
    tb_ram_zero #(.VARIANT(0), .CHECK_LOAD(1), .IMG("img/pattern.hex")) top ();
endmodule
