// Wrapper: file-init DUT, canonical zero image (shipping semantics).
module tb_wrap_file_zero ();
    tb_ram_zero #(.VARIANT(0), .CHECK_LOAD(0), .IMG("../../src/fpga/rtl/roms/ram_zero_64k.hex")) top ();
endmodule
