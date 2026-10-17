// altsyncram_sim.v - behavioral stand-in for the Quartus altsyncram IP used by
// apf/mf_datatable.v (build-ID table, 256 x 32-bit, bidir dual-port).
//
// Matches the exact port list of the `altsyncram` instance in mf_datatable.v.
// Outputs are registered (outdata_reg_a = CLOCK0, outdata_reg_b = CLOCK1).
// Init: all zeros in simulation (the build-ID table content is cosmetic;
// zeroing it does not affect any boot/video/audio behavior).
module altsyncram (
    input  wire [7:0]  address_a,
    input  wire [7:0]  address_b,
    input  wire        clock0,
    input  wire        clock1,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    input  wire        wren_a,
    input  wire        wren_b,
    output wire [31:0] q_a,
    output wire [31:0] q_b,
    input  wire        aclr0,
    input  wire        aclr1,
    input  wire        addressstall_a,
    input  wire        addressstall_b,
    input  wire        byteena_a,
    input  wire        byteena_b,
    input  wire        clocken0,
    input  wire        clocken1,
    input  wire        clocken2,
    input  wire        clocken3,
    output wire [2:0]  eccstatus,
    input  wire        rden_a,
    input  wire        rden_b
);
    // configuration parameters set by mf_datatable.v's defparam block
    // (values are irrelevant to the behavioral model; declared so the
    // defparam references resolve)
    parameter string address_reg_b          = "CLOCK1";
    parameter string clock_enable_input_a   = "BYPASS";
    parameter string clock_enable_input_b   = "BYPASS";
    parameter string clock_enable_output_a  = "BYPASS";
    parameter string clock_enable_output_b  = "BYPASS";
    parameter string indata_reg_b           = "CLOCK1";
    parameter string init_file              = "./apf/build_id.mif";
    parameter string intended_device_family = "Cyclone V";
    parameter string lpm_type               = "altsyncram";
    parameter int    numwords_a             = 256;
    parameter int    numwords_b             = 256;
    parameter string operation_mode         = "BIDIR_DUAL_PORT";
    parameter string outdata_aclr_a         = "NONE";
    parameter string outdata_aclr_b         = "NONE";
    parameter string outdata_reg_a          = "CLOCK0";
    parameter string outdata_reg_b          = "CLOCK1";
    parameter string power_up_uninitialized = "FALSE";
    parameter string read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ";
    parameter string read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ";
    parameter int    widthad_a              = 8;
    parameter int    widthad_b              = 8;
    parameter int    width_a                = 32;
    parameter int    width_b                = 32;
    parameter int    width_byteena_a        = 1;
    parameter int    width_byteena_b        = 1;
    parameter string wrcontrol_wraddress_reg_b = "CLOCK1";

    reg [31:0] mem [0:255];

    reg [31:0] qa_r, qb_r;
    always @(posedge clock0 or posedge aclr0) begin
        if (aclr0)      qa_r <= 32'd0;
        else if (clocken0) qa_r <= mem[address_a];
    end
    always @(posedge clock1 or posedge aclr1) begin
        if (aclr1)      qb_r <= 32'd0;
        else if (clocken1) qb_r <= mem[address_b];
    end
    always @(posedge clock0) if (wren_a && clocken0) mem[address_a] <= data_a;
    always @(posedge clock1) if (wren_b && clocken1) mem[address_b] <= data_b;

    assign q_a = qa_r;
    assign q_b = qb_r;
    assign eccstatus = 3'b0;
endmodule
