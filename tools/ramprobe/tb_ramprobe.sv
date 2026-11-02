// ============================================================================
// tb_ramprobe.sv - measure the ACTUAL cycle behavior of the Probe X altsyncram
// config using Quartus's own vendor megafunction model (altera_mf.v), per the
// 2nd expert review: "treat the vendor model as the reference."
//
// Measured (cycle = posedge index, outputs sampled mid-cycle after posedge):
//   RA  port A read latency:  cycles from addr_a presentation to q_a = mem
//   RB  port B read latency:   same for port B
//   WA  port A write latency:  cycles from wren_a pulse to mem visible
//   WB  port B write latency:  same for port B
//   RWA port A read-during-write: OLD or NEW data on q_a
//   RWB port B read-during-write: OLD or NEW data on q_b
// ============================================================================

`timescale 1 ns / 1 ps

module altsyncram_probe_x_inst (
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
    defparam u_ram.outdata_reg_a                = "UNREGISTERED";
    defparam u_ram.outdata_reg_b                = "UNREGISTERED";
    defparam u_ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ";
    defparam u_ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ";
    defparam u_ram.address_reg_b                = "CLOCK1";
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

module tb;
    reg         clk = 1'b0;
    reg  [8:0]  address_a = 9'd0, address_b = 9'd0;
    reg  [7:0]  data_a = 8'h00, data_b = 8'h00;
    reg         wren_a = 1'b0, wren_b = 1'b0;
    wire [7:0]  q_a, q_b;

    altsyncram_probe_x_inst dut (
        .clk(clk), .address_a(address_a), .address_b(address_b),
        .data_a(data_a), .data_b(data_b), .wren_a(wren_a), .wren_b(wren_b),
        .q_a(q_a), .q_b(q_b)
    );

    always #5 clk = ~clk;

    integer t;
    initial begin
        $dumpfile("ramprobe.vcd"); $dumpvars(0, tb);

        // ---------------- RA: port A read latency -------------------------
        // present addr 0x10 with known pattern pre-written via port B
        @(posedge clk); address_b = 9'h10; data_b = 8'hAA;
        // port B write is registered (map table: indata/wrcontrol reg CLOCK1)
        // give it 4 cycles
        repeat (4) @(posedge clk);
        wren_b = 1'b0;
        @(posedge clk);
        address_a = 9'h10;
        // observe q_a for 4 cycles after presentation
        $display("RA: q_a over 4 cycles after presenting addr_a=0x10:");
        for (t = 0; t < 4; t++) begin
            @(posedge clk);
            $display("RA  cycle+%0d q_a=%h (want AA)", t + 1, q_a);
        end

        // ---------------- RB: port B read latency --------------------------
        $display("RB: q_b over 4 cycles after presenting addr_b=0x10 (addr_a held):");
        address_b = 9'h10;
        for (t = 0; t < 4; t++) begin
            @(posedge clk);
            $display("RB  cycle+%0d q_b=%h (want AA)", t + 1, q_b);
        end

        // ---------------- WA: port A write latency -------------------------
        @(posedge clk);
        wren_a = 1'b1; address_a = 9'h20; data_a = 8'h55;
        @(posedge clk); wren_a = 1'b0;
        $display("WA: q_a over 4 cycles after wren_a pulse @0x20 (want 55):");
        for (t = 0; t < 4; t++) begin
            @(posedge clk);
            $display("WA  cycle+%0d q_a=%h", t + 1, q_a);
        end

        // ---------------- WB: port B write latency -------------------------
        wren_b = 1'b1; address_b = 9'h30; data_b = 8'h77;
        @(posedge clk); wren_b = 1'b0;
        $display("WB: q_b over 4 cycles after wren_b pulse @0x30 (want 77):");
        for (t = 0; t < 4; t++) begin
            @(posedge clk);
            $display("WB  cycle+%0d q_b=%h", t + 1, q_b);
        end

        // ---------------- RWA: read-during-write port A ---------------------
        // write 0x40=0xCC via A while reading 0x40 via A (old value was 00/uninit)
        address_a = 9'h40;
        wren_a = 1'b1; data_a = 8'hCC;
        @(posedge clk);
        $display("RWA: q_a DURING wren_a cycle = %h (OLD=?? NEW=CC)", q_a);
        wren_a = 1'b0;
        repeat (2) @(posedge clk);
        $display("RWA: q_a after = %h (want CC)", q_a);

        // ---------------- RWB: read-during-write port B ---------------------
        address_b = 9'h50;
        wren_b = 1'b1; data_b = 8'hDD;
        @(posedge clk);
        $display("RWB: q_b DURING wren_b cycle = %h (NEW_DATA_NO_NBE_READ => expect DD or held)", q_b);
        wren_b = 1'b0;
        repeat (2) @(posedge clk);
        $display("RWB: q_b after = %h (want DD)", q_b);

        $display("RAMPROBE TB DONE");
        $finish;
    end
endmodule
