// ============================================================================
// ramprobe.v - standalone altsyncram config probe (REVIEW_BRIEF_HDD_2CYCLE Q1)
//
// Purpose: prove, with the cheapest possible Quartus A&S run, which
// BIDIR_DUAL_PORT altsyncram configurations compile on this toolchain
// (Quartus 17.0.2 Lite, Cyclone V 5CSEBA4F23C8) at the hdd's real size
// (512 x 8). Two candidate top entities:
//
//   ramprobe_x - closest-to-donor target:
//     unregistered outputs on both ports (1-cycle reads if the address
//     register defaults on, 0-cycle if it doesn't), NEW_DATA_NO_NBE_READ,
//     port A fully at defaults, port B address registered, port B write
//     registers (indata/wrcontrol) at defaults.
//
//   ramprobe_y - exact mirror of the shipping, known-legal MiSTer dpram.vhd
//     config (same family/device/toolchain): unregistered outputs,
//     NEW_DATA_NO_NBE_READ, port B address/indata/wrcontrol = CLOCK1.
//
// All RAM ports are exposed at the top level so the fitter cannot prune the
// data path (the hdd_dout 1-bit truncation bug is exactly the failure mode
// this probe must not repeat).
//
// Run (from this directory):
//   quartus_map ramprobe_x --read_settings_files=on --write_settings_files=off
//   quartus_map ramprobe_y --read_settings_files=on --write_settings_files=off
// Each is a seconds-long A&S on a single megafunction instance.
// ============================================================================

`timescale 1 ns / 1 ps

// ----------------------------------------------------------------------------
// Common instance macro body: one altsyncram, 512x8, BIDIR_DUAL_PORT, both
// clocks on the same net (like the hdd's 14M/14M), tie-offs per mf_datatable.
// The defparams below each module select the configuration under test.
// ----------------------------------------------------------------------------

module ramprobe_x (
    input         clk,
    input  [8:0]  address_a,
    input  [8:0]  address_b,
    input  [7:0]  data_a,
    input  [7:0]  data_b,
    input         wren_a,
    input         wren_b,
    output [7:0]  q_a,
    output [7:0]  q_b
);
    altsyncram u_ram (
        .address_a        (address_a),
        .address_b        (address_b),
        .clock0           (clk),
        .clock1           (clk),
        .data_a           (data_a),
        .data_b           (data_b),
        .wren_a           (wren_a),
        .wren_b           (wren_b),
        .q_a              (q_a),
        .q_b              (q_b),
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
        .rden_a           (1'b1),
        .rden_b           (1'b1),
        .eccstatus        ()
    );
    defparam u_ram.operation_mode               = "BIDIR_DUAL_PORT";
    defparam u_ram.numwords_a                   = 512;
    defparam u_ram.numwords_b                   = 512;
    defparam u_ram.widthad_a                    = 9;
    defparam u_ram.widthad_b                    = 9;
    defparam u_ram.width_a                      = 8;
    defparam u_ram.width_b                      = 8;
    defparam u_ram.width_byteena_a              = 1;
    defparam u_ram.width_byteena_b              = 1;
    // ---- config X: closest-to-donor -------------------------------------
    defparam u_ram.outdata_reg_a                = "UNREGISTERED";
    defparam u_ram.outdata_reg_b                = "UNREGISTERED";
    defparam u_ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ";
    defparam u_ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ";
    defparam u_ram.address_reg_b                = "CLOCK1";
    // port A: address_reg_a / indata_reg_a / wrcontrol_wraddress_reg_a
    //         OMITTED (probe the default)
    // port B: indata_reg_b / wrcontrol_wraddress_reg_b OMITTED (probe the
    //         default - a same-cycle port B write is the donor semantics)
    defparam u_ram.clock_enable_input_a         = "BYPASS";
    defparam u_ram.clock_enable_input_b         = "BYPASS";
    defparam u_ram.clock_enable_output_a        = "BYPASS";
    defparam u_ram.clock_enable_output_b        = "BYPASS";
    defparam u_ram.outdata_aclr_a               = "NONE";
    defparam u_ram.outdata_aclr_b               = "NONE";
    defparam u_ram.power_up_uninitialized       = "TRUE";
    defparam u_ram.intended_device_family       = "Cyclone V";
    defparam u_ram.lpm_type                     = "altsyncram";
endmodule

module ramprobe_y (
    input         clk,
    input  [8:0]  address_a,
    input  [8:0]  address_b,
    input  [7:0]  data_a,
    input  [7:0]  data_b,
    input         wren_a,
    input         wren_b,
    output [7:0]  q_a,
    output [7:0]  q_b
);
    altsyncram u_ram (
        .address_a        (address_a),
        .address_b        (address_b),
        .clock0           (clk),
        .clock1           (clk),
        .data_a           (data_a),
        .data_b           (data_b),
        .wren_a           (wren_a),
        .wren_b           (wren_b),
        .q_a              (q_a),
        .q_b              (q_b),
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
        .rden_a           (1'b1),
        .rden_b           (1'b1),
        .eccstatus        ()
    );
    defparam u_ram.operation_mode               = "BIDIR_DUAL_PORT";
    defparam u_ram.numwords_a                   = 512;
    defparam u_ram.numwords_b                   = 512;
    defparam u_ram.widthad_a                    = 9;
    defparam u_ram.widthad_b                    = 9;
    defparam u_ram.width_a                      = 8;
    defparam u_ram.width_b                      = 8;
    defparam u_ram.width_byteena_a              = 1;
    defparam u_ram.width_byteena_b              = 1;
    // ---- config Y: exact MiSTer dpram.vhd mirror (known-legal control) ---
    defparam u_ram.outdata_reg_a                = "UNREGISTERED";
    defparam u_ram.outdata_reg_b                = "UNREGISTERED";
    defparam u_ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ";
    defparam u_ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ";
    defparam u_ram.address_reg_b                = "CLOCK1";
    defparam u_ram.indata_reg_b                 = "CLOCK1";
    defparam u_ram.wrcontrol_wraddress_reg_b    = "CLOCK1";
    defparam u_ram.clock_enable_input_a         = "BYPASS";
    defparam u_ram.clock_enable_input_b         = "BYPASS";
    defparam u_ram.clock_enable_output_a        = "BYPASS";
    defparam u_ram.clock_enable_output_b        = "BYPASS";
    defparam u_ram.outdata_aclr_a               = "NONE";
    defparam u_ram.outdata_aclr_b               = "NONE";
    defparam u_ram.power_up_uninitialized       = "TRUE";
    defparam u_ram.intended_device_family       = "Cyclone V";
    defparam u_ram.lpm_type                     = "altsyncram";
endmodule
