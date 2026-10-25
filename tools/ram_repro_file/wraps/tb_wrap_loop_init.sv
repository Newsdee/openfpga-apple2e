// Wrapper: loop-init DUT (historical reference), zero expectations.
module tb_wrap_loop_init ();
    tb_ram_zero #(.VARIANT(1), .CHECK_LOAD(0), .IMG("")) top ();
endmodule
