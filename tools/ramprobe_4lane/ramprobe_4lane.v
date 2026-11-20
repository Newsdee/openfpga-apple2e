// ramprobe_4lane - A&S legality probe for the hdv_ram 4-lane altsyncram
// (PLAN_HDV_M10K_2026-11-20, expert amendment 3: port-A write-path params)
//
// Two 128x8 BIDIR_DUAL_PORT instances, identical common param set,
// differing only in how the PORT A write path is specified:
//
//   u_omit - indata_reg_a / wrcontrol_wraddress_reg_a OMITTED.
//            Precedent: hdd.v u_sector_ram omits the same params and is
//            A&S-clean + fit-verified (its comment: "probe X resolved
//            defaults" -> port A same-cycle writes). Dual-clock here
//            (74a / 14a) unlike hdd.v's single clock - the clock
//            assignment does not change param legality, but the dual
//            clocking exercises the real topology.
//
//   u_none - explicit indata_reg_a = "NONE", wrcontrol_wraddress_reg_a =
//            "NONE" (INDATA_REG_* value space includes NONE per the
//            2026-10-29 ramprobe findings). Never A&S-tested in this
//            project; the param space produced Error 272006 cascades
//            before, so this is the thing being probed.
//
// Common set (the shipping candidate for the four lane RAMs):
//   BIDIR_DUAL_PORT, 128 words x 8 bits, widthad 7, byteena 1,
//   outdata_reg_a/b = "UNREGISTERED" (1-cycle reads: registered address
//   + combinational output - probe-verified in hdd.v at 512x8),
//   address_reg_b = "CLOCK1" (port B read address explicit; port A
//   address_reg_a omitted -> registered by default per ramprobe),
//   read_during_write_mode_port_a/b = "NEW_DATA_NO_NBE_READ" (the
//   bidir-legal value; OLD_DATA is Error 14000).

module ramprobe_4lane (
    input clk_74a,      // port A clock (host + walk_out domain)
    input clk_14a,      // port B clock (walk_in domain)
    input [7:0] din_a,
    input [7:0] din_b,
    input              wren_a,
    input              wren_b,
    input [6:0] addr_a,
    input [6:0] addr_b,
    output [7:0] q_a_omit,
    output [7:0] q_b_omit,
    output [7:0] q_a_none,
    output [7:0] q_b_none
);

    // ---- u_omit: port A write params omitted (hdd.v precedent) ----
    altsyncram u_omit (
        .address_a        (addr_a),
        .address_b        (addr_b),
        .clock0           (clk_74a),
        .clock1           (clk_14a),
        .data_a           (din_a),
        .data_b           (din_b),
        .wren_a           (wren_a),
        .wren_b           (wren_b),
        .q_a              (q_a_omit),
        .q_b              (q_b_omit),
        .aclr0            (1'b0),
        .aclr1            (1'b0),
        .addressstall_a   (1'b0),
        .addressstall_b   (1'b0),
        .byteena_a        (1'b1),
        .byteena_b        (1'b1),
        .clocken0         (1'b1),
        .clocken1         (1'b1),
        .clocken2         (1'b1),
        .clocken3         (1'b1),
        .eccstatus        (),
        .rden_a           (1'b1),
        .rden_b           (1'b1)
    );
    defparam
        u_omit.operation_mode              = "BIDIR_DUAL_PORT",
        u_omit.numwords_a                   = 128,
        u_omit.numwords_b                   = 128,
        u_omit.widthad_a                    = 7,
        u_omit.widthad_b                    = 7,
        u_omit.width_a                      = 8,
        u_omit.width_b                      = 8,
        u_omit.width_byteena_a              = 1,
        u_omit.width_byteena_b              = 1,
        u_omit.outdata_reg_a                = "UNREGISTERED",
        u_omit.outdata_reg_b                = "UNREGISTERED",
        u_omit.address_reg_b                = "CLOCK1",
        // port A: address_reg_a + write-path params omitted -> same-cycle
        // writes (hdd.v precedent, probe X); port B write path: bidir
        // resolved default (registered) - read-only usage anyway.
        u_omit.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_omit.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_omit.clock_enable_input_a         = "BYPASS",
        u_omit.clock_enable_input_b         = "BYPASS",
        u_omit.clock_enable_output_a        = "BYPASS",
        u_omit.clock_enable_output_b        = "BYPASS",
        u_omit.outdata_aclr_a               = "NONE",
        u_omit.outdata_aclr_b               = "NONE",
        u_omit.power_up_uninitialized       = "TRUE",
        u_omit.intended_device_family       = "Cyclone V",
        u_omit.lpm_type                     = "altsyncram";

    // ---- u_none: explicit "NONE" for the port A write path ----
    altsyncram u_none (
        .address_a        (addr_a),
        .address_b        (addr_b),
        .clock0           (clk_74a),
        .clock1           (clk_14a),
        .data_a           (din_a),
        .data_b           (din_b),
        .wren_a           (wren_a),
        .wren_b           (wren_b),
        .q_a              (q_a_none),
        .q_b              (q_b_none),
        .aclr0            (1'b0),
        .aclr1            (1'b0),
        .addressstall_a   (1'b0),
        .addressstall_b   (1'b0),
        .byteena_a        (1'b1),
        .byteena_b        (1'b1),
        .clocken0         (1'b1),
        .clocken1         (1'b1),
        .clocken2         (1'b1),
        .clocken3         (1'b1),
        .eccstatus        (),
        .rden_a           (1'b1),
        .rden_b           (1'b1)
    );
    defparam
        u_none.operation_mode              = "BIDIR_DUAL_PORT",
        u_none.numwords_a                   = 128,
        u_none.numwords_b                   = 128,
        u_none.widthad_a                    = 7,
        u_none.widthad_b                    = 7,
        u_none.width_a                      = 8,
        u_none.width_b                      = 8,
        u_none.width_byteena_a              = 1,
        u_none.width_byteena_b              = 1,
        u_none.outdata_reg_a                = "UNREGISTERED",
        u_none.outdata_reg_b                = "UNREGISTERED",
        u_none.address_reg_b                = "CLOCK1",
        // the probed spelling: explicit NONE for the port A write path
        // (same resolved behavior as omitted, if legal)
        u_none.indata_reg_a                 = "NONE",
        u_none.wrcontrol_wraddress_reg_a    = "NONE",
        u_none.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_none.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_none.clock_enable_input_a         = "BYPASS",
        u_none.clock_enable_input_b         = "BYPASS",
        u_none.clock_enable_output_a        = "BYPASS",
        u_none.clock_enable_output_b        = "BYPASS",
        u_none.outdata_aclr_a               = "NONE",
        u_none.outdata_aclr_b               = "NONE",
        u_none.power_up_uninitialized       = "TRUE",
        u_none.intended_device_family       = "Cyclone V",
        u_none.lpm_type                     = "altsyncram";

endmodule
