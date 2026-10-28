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
    input  [8:0]  ram_addr,         // sector-buffer address (bridge port)
    input  [7:0]  ram_di,
    output reg [7:0] ram_do,
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

    // Sector buffer (inferred RAM: 512 x 8 dual-port, one M10K).
    reg [7:0] sector_buf [0:511];

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
                            D_OUT <= sector_buf[sec_addr];
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
        end
    end

    // Sector buffer: the ONLY writer block for sector_buf (Verilog allows
    // one driver per array - Quartus Error 10028 on the donor's two
    // same-clock processes writing this array; VHDL allowed it, which is
    // why the differential golden had to merge them too, see
    // verilog/hdd_equivalence/golden/hdd.vhd change #2). Port A = CPU
    // (C0F8, from the donor's cpu_interface), port B = bridge (ram_*).
    // Same clock, nonblocking, same-cycle as the donor; a same-address
    // same-cycle collision is unreachable in-system (the machine is
    // stalled by cpu_wait_hdd during the bridge walk), and in this block
    // ram_we wins by code order. The C0F8 READ above samples the pre-write
    // value in either layout (NBA read semantics).
    always @(posedge CLK_14M) begin
        if (DEVICE_SELECT && !RD && (A[3:0] == 4'h8))
            sector_buf[sec_addr] <= D_IN;
        if (ram_we)
            sector_buf[ram_addr] <= ram_di;
        ram_do <= sector_buf[ram_addr];
    end
endmodule
