// altddio_bidir_sim.v - behavioral stand-in for the Quartus altddio_bidir IP
// used by apf/mf_ddio_bidir_12.v (12-bit DDR bidirectional pad bus).
//
// Output phase semantics (as used by apf_top, oe=1):
//   rising outclock edge -> drive datain_l (low-phase data)
//   falling outclock edge -> drive datain_h (high-phase data)
// Input capture (unused by apf_top, modeled for completeness):
//   rising inclock edge -> dataout_l, falling -> dataout_h.
//
// Configuration parameters are declared so mf_ddio_bidir_12.v's defparam
// references resolve; values are irrelevant to the behavioral model.
module altddio_bidir (
    input  wire [11:0] datain_h,
    input  wire [11:0] datain_l,
    input  wire        inclock,
    input  wire        oe,
    input  wire        outclock,
    inout wire [11:0]  padio,
    output wire [11:0] dataout_h,
    output wire [11:0] dataout_l,
    input  wire        aclr,
    input  wire        aset,
    output wire        combout,
    output wire        dqsundelayedout,
    input  wire        inclocken,
    output wire        oe_out,
    input  wire        outclocken,
    input  wire        sclr,
    input  wire        sset
);
    // configuration parameters set by mf_ddio_bidir_12.v's defparam block
    parameter string extend_oe_disable      = "OFF";
    parameter string implement_input_in_lcell = "OFF";
    parameter string intended_device_family = "Cyclone V";
    parameter string invert_output          = "OFF";
    parameter string lpm_hint               = "UNUSED";
    parameter string lpm_type               = "altddio_bidir";
    parameter string oe_reg                 = "UNREGISTERED";
    parameter string power_up_high          = "OFF";
    parameter int    width                  = 12;

    reg [11:0] pad_r;
    reg [11:0] dout_h_r, dout_l_r;

    always @(posedge outclock) if (oe && outclocken) pad_r <= datain_l;
    always @(negedge outclock) if (oe && outclocken) pad_r <= datain_h;
    assign padio = oe ? pad_r : 12'bz;

    always @(posedge inclock) if (inclocken) dout_l_r <= padio;
    always @(negedge inclock) if (inclocken) dout_h_r <= padio;
    assign dataout_l = dout_l_r;
    assign dataout_h = dout_h_r;

    assign combout        = 1'b0;
    assign dqsundelayedout = 1'b0;
    assign oe_out         = oe;
endmodule
