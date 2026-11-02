//-------------------------------------------------------------------------------
// HDD interface (ProDOS HDD controller, C0F0-C0F8 + C600-C6FF firmware ROM)
//
// Verilog port of Apple-II_MiSTer/rtl/hdd.vhd (Steven A. Wilson's AppleWin-based
// interface). Cycle-exact transcription; proven against the VHDL original with
// the differential harness in verilog/hdd_equivalence/ (GHDL golden vs
// the verilator-built candidate).
//
// Registers (per AppleWin source/Harddisk.cpp):
//   C0F0 (r)   EXECUTE AND RETURN STATUS  - reading C0F0 runs the pending
//            command (reg_command) and returns its status
//   C0F1 (r)   STATUS (or ERROR)
//   C0F2 (r/w) COMMAND   (writing 02 also resets the sector-buffer offset)
//   C0F3 (r/w) UNIT NUMBER (0x70 = 'p' = ProDOS)
//   C0F4 (r/w) LOW BYTE OF MEMORY BUFFER
//   C0F5 (r/w) HIGH BYTE OF MEMORY BUFFER
//   C0F6 (r/w) LOW BYTE OF BLOCK NUMBER
//   C0F7 (r/w) HIGH BYTE OF BLOCK NUMBER
//   C0F8 (r/w) NEXT BYTE (sector-buffer byte, auto-incrementing offset)
//
// Ported 2026-10-27 for the Apple2e Pocket core (HDV read-only, H1).
//
// DONOR SUBTLETIES PRESERVED (see the equivalence TB for coverage of each):
//  - sec_addr is NOT incremented in the access cycle. C0F8 access sets
//    increment_sec_addr, and the increment is applied on the NEXT clock, and
//    only in the "not device-selected" branch (which is also where the
//    increment flag is cleared). If DEVICE_SELECT stays high over consecutive
//    C0F8 accesses, the flag latches until the selection drops.
//  - hdd_read/hdd_write are one-machine-clock pulses, asserted by reading
//    C0F0 with the command armed, and only in the mounted/unit/protect
//    passing cases.
//  - sector is combinational ({reg_block_h, reg_block_l}).
//
// SECTOR BUFFER (512 x 8, dual-port): port A = CPU via sec_addr (C0F8),
// port B = bridge walk via ram_addr/ram_di/ram_do/ram_we. One always block,
// with port B (ram_we) taking priority on a same-cycle same-address collision
// - a collision cannot occur in the system: the H2 transfer FSM stalls the
// machine (cpu_wait_hdd technique) for the whole walk, exactly as MiSTer does
// (Apple-II.sv:887-919). The equivalence TB carries a monitor that fails the
// run if both ports are ever driven to the same address in the same cycle.
//-------------------------------------------------------------------------------
module hdd (
    input         CLK_14M,
    input         IO_SELECT,        // C600-C6FF ROM select
    input         DEVICE_SELECT,    // C0F0-C0FF I/O select
    input         RESET,            // synchronous
    input  [15:0] A,
    input         RD,               // 6502 RD (1) / WR (0)
    input  [7:0]  D_IN,
    output reg [7:0] D_OUT,
    output wire [15:0] sector,      // block number to read/write (combinational)
    output reg  hdd_read,
    output reg  hdd_write,
    input         hdd_mounted,
    input         hdd_protect,
    input         bridge_fault,     // 14M pulse: media fetch failed (drop or
                                    // timeout) after execute committed success
    input  [8:0]  ram_addr,         // sector-buffer address (bridge port)
    input  [7:0]  ram_di,
    output wire [7:0] ram_do,
    input         ram_we
);

    // Interface registers (VHDL reset values; the two helper flags below
    // start at 0, which is behaviour-identical to the VHDL's 'U' start
    // because neither can read as 1 before it is assigned).
    reg [7:0] reg_status   = 8'h00;
    reg [7:0] reg_command  = 8'h00;
    reg [7:0] reg_unit     = 8'h00;
    reg [7:0] reg_mem_l    = 8'h00;
    reg [7:0] reg_mem_h    = 8'h00;
    reg [7:0] reg_block_l  = 8'h00;
    reg [7:0] reg_block_h  = 8'h00;

    // Internal sector-buffer offset: reset by reading C0F0 (execute) and by
    // writing command=02; advanced one per C0F8 access with one-cycle delay.
    reg [8:0] sec_addr           = 9'd0;
    reg       increment_sec_addr = 1'b0;
    reg       select_d           = 1'b0;   // DEVICE_SELECT, one clock late

    // Sector buffer: explicit altsyncram (one M10K, true dual port, single
    // clock). NOT an inferred array: Quartus 17.0.2 does not infer this
    // 4-port pattern (2 writes + 2 REGISTERED reads in two processes) into
    // block RAM, and its fitter then SILENTLY DROPS the distributed array
    // from the bitstream (verified 2026-10-28: A&S shows it as 4,096 LEs,
    // the fit places zero of them - the C0F8 data path and the bridge
    // ram_* port read back constants). The explicit megafunction pins the
    // storage. Timing is cycle-identical to the array it replaces:
    // readdata_X is one clock after the address (same as `reg <=
    // array[addr]`), and a same-address same-cycle write/read returns the
    // OLD data - exactly the NBA semantics the donor's array had. Port A =
    // CPU (C0F8), port B = bridge (ram_*). A same-address same-cycle
    // write/write collision is unreachable in-system (the machine is
    // stalled by cpu_wait_hdd during the bridge walk); the equivalence TB
    // monitor fails a run if it ever happens.
    wire [7:0] sector_read_a;   // port A readout -> C0F8 D_OUT
    wire [7:0] sector_read_b;   // port B readout -> ram_do
    wire       c0f8_we = DEVICE_SELECT && !RD && (A[3:0] == 4'h8);

    // Port A address: the M10K read is registered (readdata during cycle m
    // reflects the address of cycle m-1). The DUT read case fires in cycle C
    // and samples sector_read_a(C) = mem[addr_a(C-1)]; the golden
    // (combinational array) samples buf[sec_addr(C)]. For this machine
    // (one-bus-access-per-cycle 6502 - one DS-high 14M cycle per access,
    // machine/apple2.v) and the equivalence TB's single-cycle read stimulus,
    // read stimulus, sec_addr(C) == sec_addr(C-1) + [increment branch fires
    // during C-1] - the branch that commits the advance is exactly
    // `!DEVICE_SELECT && select_d && increment_sec_addr`. Adding it
    // combinationally (NOT via a latch - a latch is one edge too late for
    // the TB stimulus, and wrong in the HOLD test where DS is held so the
    // increment never fires and sec_addr stays frozen) makes the M10K
    // address track the golden address cycle-for-cycle:
    //   - read gap cycle: sec_addr + 1 (the in-flight increment) = next byte
    //   - C0F8 write cycle: DS=1 -> +0 -> live sec_addr (write path unchanged)
    //   - DS-held: branch dead -> +0 -> frozen sec_addr (matches golden)
    // Content note: the M10K readout is one edge younger than the golden's
    // sample window; no port write can land on that edge (port A needs a
    // C0F8 write stimulus in that cycle, port B needs a bridge walk while
    // the machine is CPU_WAIT-stalled - the same unreachability the donor
    // collision comment relies on).
    // NOTE: an earlier "2-CYCLE read-ahead" variant (ra_bit/ds_prev) existed
    // here for a compile where outdata_reg_a was CLOCK0 - a legal but
    // 2-cycle config. Superseded by the probe-verified 1-cycle config below
    // (docs/REVIEW_RESULTS_HDD_2CYCLE_2026-10-29.md).
    wire        inc_branch_fire = !DEVICE_SELECT && select_d && increment_sec_addr;
    wire [8:0]  addr_a          = sec_addr + (inc_branch_fire ? 9'd1 : 9'd0);

    // Port B (bridge): 1-cycle read (address register + unregistered output),
    // so q_b(m+1) = mem[ram_addr(m)] - bit-identical to the golden's
    // `ram_do <= sector_buf[ram_addr]` NBA. Present the RAW ram_addr (no
    // read-ahead): the real bridge's 2-phase walk (present k on phase 0,
    // sample on phase 1) sees q_b = mem[k] on the sample phase. The port B
    // write path is registered (defparam below): a byte lands one cycle after
    // presentation - invisible in-system (walks are sequential, the 6502 is
    // CPU_WAIT-stalled, the C0F8 phase starts after the done handshake) and
    // in the equivalence TB (write walk sequential; read regions separate).

    // Real Cyclone V altsyncram megafunction port names (see mf_datatable.v
    // for the working template): .clock0/.clock1, .q_a/.q_b, plus the
    // tie-off ports. Configured by defparam below. Port A = CPU (C0F8),
    // port B = bridge (ram_*).
    altsyncram u_sector_ram (
        .address_a        (addr_a),
        .address_b        (ram_addr),
        .clock0           (CLK_14M),
        .clock1           (CLK_14M),
        .data_a           (D_IN),
        .data_b           (ram_di),
        .wren_a           (c0f8_we),
        .wren_b           (ram_we),
        .q_a              (sector_read_a),
        .q_b              (sector_read_b),
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
        // one M10K, 512 x 8, both ports bidirectional (port B must write)
        u_sector_ram.operation_mode              = "BIDIR_DUAL_PORT",
        u_sector_ram.numwords_a                   = 512,
        u_sector_ram.numwords_b                   = 512,
        u_sector_ram.widthad_a                    = 9,
        u_sector_ram.widthad_b                    = 9,
        u_sector_ram.width_a                      = 8,
        u_sector_ram.width_b                      = 8,
        u_sector_ram.width_byteena_a              = 1,
        u_sector_ram.width_byteena_b              = 1,
        // BOTH ports are 1-CYCLE reads: the address register (always on in
        // bidir_dual_port - resolves registered even when omitted) plus an
        // UNREGISTERED output. Proven at this exact 512x8 size by the
        // standalone Quartus probe (tools/ramprobe, 2026-10-29): A&S clean,
        // fit table = True Dual Port, A InReg yes/OutReg no, B InReg yes/
        // OutReg no, 4096 bits implemented. The earlier "2-cycle floor" came
        // from a compile with outdata_reg_a=CLOCK0 after Error 14000 was
        // misattributed: the unsupported combination is OLD_DATA +
        // unregistered output; NEW_DATA_NO_NBE_READ + UNREGISTERED outputs is
        // legal (dpram.vhd ships it).
        u_sector_ram.outdata_reg_a                = "UNREGISTERED",
        u_sector_ram.outdata_reg_b                = "UNREGISTERED",
        u_sector_ram.address_reg_b                = "CLOCK1",
        // port A: address_reg_a and the write-path params omitted -> resolve
        // unregistered (same-cycle writes; probe X resolved defaults).
        // port B write path: registered, 1 cycle late - the bidir port-B
        // resolved default, made explicit (identical to dpram's shipping set).
        u_sector_ram.indata_reg_b                 = "CLOCK1",
        u_sector_ram.wrcontrol_wraddress_reg_b    = "CLOCK1",
        // Do NOT write "UNREGISTERED" for write-path params - Quartus 17
        // rejects it (Error 272006: WRCONTROL_WRADDRESS_REG_* only accept
        // CLOCK0|CLOCK1; only OUTDATA_REG_* uses the name "UNREGISTERED").
        // Read-during-write mode: set to the bidir_dual_port-legal value
        // ("OLD_DATA" is rejected at the WYSIWYG ram_block level in
        // bidir_dual_port - Error 14000; "NEW_DATA_NO_NBE_READ" is what
        // mf_datatable uses and synthesizes clean). The mode is functionally
        // irrelevant on hardware: the only same-address same-cycle write+read
        // (port B during the walk-in) is not consumed by the bridge (it
        // samples ram_do only in walk-out, when ram_we=0), and the C0F8 port
        // never writes+reads in the same cycle. The sim model returns the
        // donor's pre-write (NBA) value regardless of this param, so the
        // equivalence stays bit-exact.
        u_sector_ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_sector_ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_sector_ram.clock_enable_input_a         = "BYPASS",
        u_sector_ram.clock_enable_input_b         = "BYPASS",
        u_sector_ram.clock_enable_output_a        = "BYPASS",
        u_sector_ram.clock_enable_output_b        = "BYPASS",
        u_sector_ram.outdata_aclr_a               = "NONE",
        u_sector_ram.outdata_aclr_b               = "NONE",
        // Donor sector_buf is X at power-on in GHDL / 0 in Verilator;
        // the equivalence runner already ignores VHDL metavalue rows.
        u_sector_ram.power_up_uninitialized       = "TRUE",
        u_sector_ram.intended_device_family       = "Cyclone V",
        u_sector_ram.lpm_type                     = "altsyncram";

    wire [7:0] rom_dout;
    hdd_rom u_rom (.addr(A[7:0]), .clk(CLK_14M), .dout(rom_dout));

    assign sector = {reg_block_h, reg_block_l};

    // 6502-side interface (VHDL cpu_interface process).
    always @(posedge CLK_14M) begin
        D_OUT     <= 8'hFF;
        hdd_read  <= 1'b0;
        hdd_write <= 1'b0;
        if (RESET) begin
            reg_status  <= 8'h00;
            reg_command <= 8'h00;
            reg_unit    <= 8'h00;
            reg_mem_l   <= 8'h00;
            reg_mem_h   <= 8'h00;
            reg_block_l <= 8'h00;
            reg_block_h <= 8'h00;
        end else begin
            select_d <= DEVICE_SELECT;
            if (DEVICE_SELECT) begin
                if (RD) begin
                    case (A[3:0])
                        4'h0: begin
                            // EXECUTE AND RETURN STATUS
                            sec_addr <= 9'd0;
                            case (reg_command)
                                8'h00: begin  // STATUS
                                    if (hdd_mounted && (reg_unit == 8'h70)) begin
                                        reg_status <= 8'h00;
                                        D_OUT <= 8'h00;
                                    end else begin
                                        reg_status <= 8'h01;
                                        D_OUT <= 8'h28;   // NO_DEVICE
                                    end
                                end
                                8'h01: begin  // READ
                                    if (hdd_mounted && (reg_unit == 8'h70)) begin
                                        hdd_read <= 1'b1;
                                        reg_status <= 8'h00;
                                        D_OUT <= 8'h00;
                                    end else begin
                                        reg_status <= 8'h01;
                                        D_OUT <= 8'h28;
                                    end
                                end
                                8'h02: begin  // WRITE
                                    if (!hdd_mounted || (reg_unit != 8'h70)) begin
                                        D_OUT <= 8'h28;   // NO_DEVICE
                                        reg_status <= 8'h01;
                                    end else if (hdd_protect) begin
                                        D_OUT <= 8'h2B;   // PROTECT
                                    end else begin
                                        D_OUT <= 8'h00;
                                        reg_status <= 8'h00;
                                        hdd_write <= 1'b1;
                                    end
                                end
                                default: ;    // null: D_OUT stays FF
                            endcase
                        end
                        4'h1: D_OUT <= reg_status;
                        4'h2: D_OUT <= reg_command;
                        4'h3: D_OUT <= reg_unit;
                        4'h4: D_OUT <= reg_mem_l;
                        4'h5: D_OUT <= reg_mem_h;
                        4'h6: D_OUT <= reg_block_l;
                        4'h7: D_OUT <= reg_block_h;
                        4'h8: begin
                            D_OUT <= sector_read_a;
                            increment_sec_addr <= 1'b1;
                        end
                        default: ;
                    endcase
                end else begin  // 6502 writing
                    case (A[3:0])
                        4'h2: begin
                            if (D_IN == 8'h02)   // WRITE command arms offset reset
                                sec_addr <= 9'd0;
                            reg_command <= D_IN;
                        end
                        4'h3: reg_unit    <= D_IN;
                        4'h4: reg_mem_l   <= D_IN;
                        4'h5: reg_mem_h   <= D_IN;
                        4'h6: reg_block_l <= D_IN;
                        4'h7: reg_block_h <= D_IN;
                        4'h8: begin
                            // The C0F8 WRITE itself is in the sector_buf
                            // writer block below (Verilog allows one driver
                            // per array; see the note there).
                            increment_sec_addr <= 1'b1;
                        end
                        default: ;
                    endcase
                end
            end else if (!DEVICE_SELECT && select_d) begin
                // One-clock-late increment, only while the port is not selected
                // (VHDL: "elsif DEVICE_SELECT = '0' and select_d = '1'").
                if (increment_sec_addr) begin
                    sec_addr <= sec_addr + 9'd1;
                    increment_sec_addr <= 1'b0;
                end
            end else if (IO_SELECT) begin  // firmware ROM read
                if (RD)
                    D_OUT <= rom_dout;
            end
            // Bridge fault (14M-domain pulse, 2FF-synced from the bridge's
            // 74a drop/timeout): the 0x0180 fetch failed AFTER the C0F0
            // execute optimistically committed success (real-chip behaviour
            // - the execute byte reflects status at execute time). Forcing
            // reg_status here makes C0F1 (read after the transfer) report
            // the failure instead of a stale 00. Last statement in the block
            // so this NBA overrides the execute's own reg_status write on
            // the same cycle.
            if (bridge_fault)
                reg_status <= 8'h01;
        end
    end

    // Port B readout goes straight to ram_do (no extra register stage):
    // the M10K's own output register IS the donor's `ram_do <=
    // sector_buf[ram_addr]` stage. ram_do(cycle k) = mem[ram_addr(k-1)]
    // with contents committed through edge k-1 - bit-identical to the
    // array's NBA read, including the byte written one cycle earlier.
    assign ram_do = sector_read_b;
endmodule
