// Wrapper: DUT vs a MISSING image file - EXPECT build failure (the
// $readmemh processing dies before any run). If the tool instead warns
// and runs, that is a finding: the sim path cannot see the missing file.
module tb_wrap_neg_missing ();
    tb_ram_zero #(.VARIANT(0), .CHECK_LOAD(0), .IMG("img_neg/missing.hex")) top ();
endmodule
