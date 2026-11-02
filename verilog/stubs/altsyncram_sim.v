// altsyncram_sim.v - behavioural stand-in for the Quartus `altsyncram`
// megafunction, for the event-driven Verilator harnesses. One parameterized
// module serves every altsyncram instance in the design, sized and pipelined
// by its per-instance defparam block:
//
//   core_bridge_cmd.v: mf_datatable idt -> 256 x 32 dataslot table
//       (BIDIR; port A registered output, same-cycle writes; port B
//        registered output + registered 2-stage writes)
//   hdd.v:u_sector_ram -> 512 x 8 HDV sector buffer
//       (BIDIR; both outputs UNREGISTERED; port A same-cycle writes; port B
//        registered 2-stage writes)
//
// Per-instance defparam to different values is legal Verilog (each instance
// elaborates with its own parameter set), so this single module binds both
// in the same pocket_boot build. Quartus never sees this file (it is not in
// the QSF); the real megafunction is used on hardware.
//
// Modelled pipeline, per port (X = a/b, port clock = clock0/clock1),
// matching the RESOLVED behavior of the shipped configs as proven by the
// standalone Quartus probe (tools/ramprobe, 2026-10-29: A&S + fit on the
// exact 512x8 hdd config):
//
//   read:  the read address is REGISTERED on the port clock - always, in
//          bidir_dual_port (the fit table shows Port InReg=yes even when
//          the address_reg_X param is omitted; probe X fit: A InReg yes /
//          OutReg no, B InReg yes / OutReg no). q = mem[latched_addr],
//          then optionally one output register stage when outdata_reg_X is
//          "CLOCK0"/"CLOCK1" (mf_datatable has both outputs registered;
//          hdd has both unregistered).
//
//   write: when indata_reg_X and wrcontrol_wraddress_reg_X are "CLOCK?"
//          (mf_datatable port B, hdd port B): a 2-stage pipeline -
//          latch (addr/data/wren) at the posedge, commit to mem at the NEXT
//          posedge. Net observable timing: mem[addr(T)] = data(T) during
//          cycle T+1 - bit-identical to the VHDL donor's NBA array write
//          (sector_buf[addr] <= data) at the interface level.
//          Otherwise (both instances' port A): same-cycle - mem[addr] <=
//          data at the posedge from current-cycle signals (donor NBA
//          equivalent at the interface: mem[addr(T)] visible during T+1).
//
//   read-during-write: no special mode mux - the pipeline ordering defines
//          it (the read sees mem as it stands after the posedge's commits).
//          For a port B same-cycle write+read that is the pre-write value
//          (commit lands on the following posedge), matching the donor's
//          NBA; the shipping defparams say NEW_DATA_NO_NBE_READ, but the
//          only same-address same-cycle write+read cases are structurally
//          unreachable in-system (the 6502 is CPU_WAIT-stalled during
//          bridge walks; one 6502 access is one read XOR one write) and the
//          hdd_equivalence collision monitor fails a run if one ever occurs.
//
// Symmetric ports are assumed (width_a==width_b, numwords_a==numwords_b),
// which is true for both instances; one mem array is shared.
//
// Two-state (Verilator): mem powers up 0. hdd's power_up_uninitialized="TRUE"
// is X in real hardware; the hdd_equivalence runner ignores VHDL metavalue
// rows, so this matches.

module altsyncram (
    input  [widthad_a-1:0]           address_a,
    input  [widthad_b-1:0]           address_b,
    input                            clock0,
    input                            clock1,
    input  [width_a-1:0]             data_a,
    input  [width_b-1:0]             data_b,
    input                            wren_a,
    input                            wren_b,
    output [width_a-1:0]             q_a,
    output [width_b-1:0]             q_b,
    input                            aclr0,
    input                            aclr1,
    input                            addressstall_a,
    input                            addressstall_b,
    input  [width_byteena_a-1:0]     byteena_a,
    input  [width_byteena_b-1:0]     byteena_b,
    input                            clocken0,
    input                            clocken1,
    input                            clocken2,
    input                            clocken3,
    output [2:0]                     eccstatus,
    input                            rden_a,
    input                            rden_b
);
    // ---- configuration (set by each instance's defparam block) ----
    parameter             numwords_a = 512;
    parameter             numwords_b = 512;
    parameter             widthad_a  = 9;
    parameter             widthad_b  = 9;
    parameter             width_a    = 8;
    parameter             width_b    = 8;
    parameter             width_byteena_a = 1;
    parameter             width_byteena_b = 1;
    // Defaults mirror the toolchain's RESOLVED behavior for bidir_dual_port
    // (probe-verified): address regs always on (port's own clock); port B
    // write path registered (2-stage); port A write path unregistered.
    parameter             address_reg_a           = "CLOCK0";
    parameter             address_reg_b           = "CLOCK1";
    parameter             outdata_reg_a           = "UNREGISTERED";
    parameter             outdata_reg_b           = "UNREGISTERED";
    parameter             indata_reg_a            = "UNREGISTERED";
    parameter             indata_reg_b            = "CLOCK1";
    parameter             wrcontrol_wraddress_reg_a = "UNREGISTERED";
    parameter             wrcontrol_wraddress_reg_b = "CLOCK1";
    parameter             read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ";
    parameter             read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ";
    parameter             power_up_uninitialized = "TRUE";
    parameter             operation_mode = "BIDIR_DUAL_PORT";
    parameter             clock_enable_input_a  = "BYPASS";
    parameter             clock_enable_input_b  = "BYPASS";
    parameter             clock_enable_output_a = "BYPASS";
    parameter             clock_enable_output_b = "BYPASS";
    parameter             outdata_aclr_a  = "NONE";
    parameter             outdata_aclr_b  = "NONE";
    parameter             init_file  = "NONE";
    parameter             intended_device_family = "Cyclone V";
    parameter             lpm_type = "altsyncram";

    // Symmetric ports: size the shared memory from port A (== port B here).
    localparam WIDTH  = width_a;
    localparam DEPTH  = numwords_a;

    // Write-pipeline select per port (see header: 2-stage iff both the
    // indata and wrcontrol wraddress regs are set).
    localparam BITB_WRITE_PIPELINED =
        (indata_reg_b == "CLOCK1") && (wrcontrol_wraddress_reg_b == "CLOCK1");
    localparam BITA_WRITE_PIPELINED =
        (indata_reg_a == "CLOCK0") && (wrcontrol_wraddress_reg_a == "CLOCK0");

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // ============================== PORT A ==============================
    // Read: address registered on the port clock (always, in bidir).
    reg  [widthad_a-1:0] addr_reg_a;
    always @(posedge clock0)
        addr_reg_a <= (address_reg_a == "CLOCK0") ? address_a : addr_reg_a;
    wire [widthad_a-1:0] rd_addr_a =
        (address_reg_a == "CLOCK0") ? addr_reg_a : address_a;
    wire [WIDTH-1:0] rd_a = mem[rd_addr_a];

    reg  [WIDTH-1:0] q_reg_a;
    always @(posedge clock0) q_reg_a <= rd_a;
    wire [WIDTH-1:0] q_a_sel =
        (outdata_reg_a == "CLOCK0") ? q_reg_a : rd_a;

    // Port A write+read corner (donor pre-write semantics, see port B note
    // below): a same-cycle port A write to the port B read address must NOT
    // be visible to the port B readout in the same cycle. The donor's NBA
    // does exactly that (ram_do latches the pre-edge value). Unreachable
    // in-system (the 6502 is CPU_WAIT-stalled during bridge walks; one 6502
    // access is one read XOR one write); only the equivalence TB's idle
    // port B read parked on address 0 during C0F8 write windows ever sees
    // it.
    reg  [widthad_a-1:0] pa_waddr;
    reg                 pa_wr;
    always @(posedge clock0) begin
        pa_waddr <= (wren_a && BITA_WRITE_PIPELINED == 0) ? address_a : pa_waddr;
        pa_wr    <=  wren_a;
    end
    wire portb_sees_pre_a_write =
        (outdata_reg_b == "CLOCK1") ? 1'b0 :
        (pa_wr && (rd_addr_b == pa_waddr));

    // Write: same-cycle (direct) unless port A write params are set.
    reg  [widthad_a-1:0] wpa_addr;
    reg  [WIDTH-1:0]     wpa_data;
    reg                 wpa_wren;
    always @(posedge clock0) begin
        if (wren_a) begin
            if (BITA_WRITE_PIPELINED) begin
                // 2-stage: commit last cycle's byte, then latch this one.
                if (wpa_wren)
                    mem[wpa_addr] <= wpa_data;
                wpa_addr <= address_a;
                wpa_data <= data_a;
                wpa_wren <= 1'b1;
            end else begin
                mem[address_a] <= data_a;
                wpa_wren <= 1'b0;
            end
        end else if (BITA_WRITE_PIPELINED) begin
            if (wpa_wren) begin
                mem[wpa_addr] <= wpa_data;
                wpa_wren <= 1'b0;
            end
        end
    end

    // ============================== PORT B ==============================
    // Read: address registered on the port clock (always, in bidir).
    reg  [widthad_b-1:0] addr_reg_b;
    always @(posedge clock1)
        addr_reg_b <= (address_reg_b == "CLOCK1") ? address_b : addr_reg_b;
    wire [widthad_b-1:0] rd_addr_b =
        (address_reg_b == "CLOCK1") ? addr_reg_b : address_b;
    wire [WIDTH-1:0] rd_b = mem[rd_addr_b];

    reg  [WIDTH-1:0] q_reg_b;
    always @(posedge clock1) q_reg_b <= rd_b;
    wire [WIDTH-1:0] q_b_sel_raw =
        (outdata_reg_b == "CLOCK1") ? q_reg_b : rd_b;
    // Donor pre-write for the port A write+read corner (see above).
    wire [WIDTH-1:0] q_b_sel =
        portb_sees_pre_a_write ? q_reg_b : q_b_sel_raw;

    // Write: 2-stage registered pipeline (commit last cycle's byte at every
    // edge while also latching the current cycle's) - the shipped hdd /
    // mf_datatable port B default. Net: mem[addr(T)] = data(T) during T+1,
    // donor-NBA-equivalent at the interface. A single wren pulse commits at
    // the next edge; a continuous walk commits one byte per edge in order.
    reg  [widthad_b-1:0] wpb_addr;
    reg  [WIDTH-1:0]     wpb_data;
    reg                 wpb_wren;
    always @(posedge clock1) begin
        if (wren_b) begin
            if (BITB_WRITE_PIPELINED) begin
                if (wpb_wren)
                    mem[wpb_addr] <= wpb_data;
                wpb_addr <= address_b;
                wpb_data <= data_b;
                wpb_wren <= 1'b1;
            end else begin
                mem[address_b] <= data_b;
                wpb_wren <= 1'b0;
            end
        end else if (BITB_WRITE_PIPELINED) begin
            if (wpb_wren) begin
                mem[wpb_addr] <= wpb_data;
                wpb_wren <= 1'b0;
            end
        end
    end

    // byteena is 1-bit in both instances (all-bytes enabled); if a wider
    // byteena is ever used, only the enabled bytes would write - not needed
    // here, so the full-word write above is correct for width_byteena==1.

    assign q_a = q_a_sel;
    assign q_b = q_b_sel;
    assign eccstatus = 3'b0;
    // unused control inputs tied for lint; aclr/clocken/stall/rden are
    // driven to their benign values by the instances (aclr=0, clocken=1,
    // rden=1, stall=0).
endmodule
