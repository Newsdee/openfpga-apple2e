//
// apple2e_ram_bank.v - 64K main + 64K aux machine RAM (inferred M10K) with
// the cold-reset write-sweep overlay and the W1 savestate-manager access.
//
// Extracted VERBATIM from apf_stream_video_top.v on 2026-11-12 (W1,
// PLAN_SAVESTATES_2026-11-09 phase 3) so the savestate round-trip TB
// (verilog/tb/tb_savestate_roundtrip.sv) instantiates the SHIPPING glue,
// not a copy: the manager's ram_* ports time-multiplex onto these banks
// exactly as in the top.
//
// Inference history (kept from the top - read before touching this):
// ram_clear (reboot_ctl, "Reboot on disk change" option): sequential
// WRITE-SWEEP clear. Cyclone V M10Ks have no runtime content-clear pin
// (only output/address clear - expert review 2026-10-24, verified against
// the installed cyclonev_ram_block model). The inference matrix
// (tools/ram_repro_matrix) isolated the poison precisely (rule corrected
// 2026-11-14 per expert review of the failing m_mux_addr case): the poison
// is WRITE and READ using DIFFERENT address expressions on the same array
// (Error 276003 + 276007 "uninferred due to asynchronous read logic" ->
// ~500K logic registers per bank -> Fitter 170011 / multi-hour TDS grind).
// A MUXED address used by BOTH write and read (the _f overlay below) is the
// PROVEN shape; muxed write DATA or an OR'd write ENABLE are also fine.
//
// So the RAM block below stays byte-identical to the proven M1 shape
// (plain single-port, per-bank enable, write-first bypass) and the sweep
// walks the BUS instead: ram_sweep_ctl drives we/addr/aux through a
// combinational overlay on the _f nets (one 65,536-address pass per
// bank = 131,072 cycles, ~0.92 ms at 143.18 MHz, data hardwired to 0).
// The machine (CPU + Disk II) is in cold reset for the whole sweep
// (reboot_ctl holds cold_reset until done + HOLD), so hijacking the RAM
// write port is safe: apple2 and disk_ii_woz are reset-gated. The
// initial block is the power-on state only (file zero-fill).
//
// W1 (PLAN_SAVESTATES_2026-11-09 phase 3): the savestate manager walks
// main+aux byte-by-byte (one byte per machine cycle) while the machine is
// FROZEN (machine_ce=0 from the manager's SETTLE), so the RAM ports are
// exclusively its. Writes inject onto the _f-style overlay nets (the
// proven sweep-overlay pattern, write-only address select). The manager
// READ uses its own address (ss_ram_addr) with PER-BANK PRIVATE output
// registers (the matrix u_k shape - see below); the bank mux sits in the
// fabric on those registers, and the manager's ram_rd-on-T / data-on-T+1
// protocol is preserved (q2 registers at T+1, combinational bank mux).
// Both the manager's read AND write take the manager's own
// ss_ram_addr/ss_ram_bank (LOAD_RAM_WRITE writes byte_index to RAM; the
// machine bus address is stale during the freeze).
//
// 2026-11-14 inference resolution (three same-day failures root-caused,
// expert-reviewed, tools/ram_repro_matrix u_g..u_k extended to settle it):
//  (1) manager read at a DISTINCT address expression with a destination
//      SHARED across both banks via a bank mux (the V0 shape) -> Quartus
//      DUPLICATED each bank (4 x 64KiB) -> fitter 11802;
//  (2) same shared-destination bank-mux read with unified address
//      expressions (the V2 shape, matrix u_i/u_j) -> both banks "uninferred
//      due to asynchronous read logic" (276007) -> A&S 276003;
//  (3) THE FIX (matrix u_k, verified inferring as 2 x 64KiB dual-clock
//      M10Ks, A&S clean): per-bank PRIVATE 2nd-read registers at the
//      manager's own address (u_h TDP template, one per bank) + the bank
//      mux OUTSIDE the RAM templates. The address mux also drops its
//      ss_ram_rd term (write-only select, the proven October sweep
//      pattern) so the write address never changes on a read-only cycle.
//  Verdicts: u_g/u_h/u_k infer (276027 dual-clock, RDW caveat is a
//  non-issue here - port A's read is bypassed on writes and the manager
//  never reads while anything writes, machine frozen); u_i/u_j do not.
`timescale 1ns/10ps
module apple2e_ram_bank (
    input  wire        clk,           // machine clock (clk_core_14318)
    // ---- machine bus (pre-overlay) ----
    input  wire        m_ram_we,
    input  wire [17:0] m_ram_addr,
    input  wire [7:0]  m_ram_di,
    input  wire        m_ram_aux,
    output reg [15:0] m_ram_do,
    // ---- cold-reset clearing sweep (reboot_ctl) ----
    input  wire        sweep_start,   // ram_clear_m
    output wire        sweep_done,
    // ---- W1 savestate manager access ----
    input  wire        ss_ram_bank,
    input  wire [15:0] ss_ram_addr,
    input  wire        ss_ram_rd,
    input  wire        ss_ram_wr,
    input  wire [7:0]  ss_ram_wdata,
    output wire [7:0] mgr_ram_rdata   // combinational bank mux over the
                                       // per-bank registered reads (T+1)
);

    reg  [7:0]  ram_main [0:65535];
    reg  [7:0]  ram_aux  [0:65535];

    // ---- sweep bus overlay (inference-safe; the RAM block never sees a
    //      conditional write address) ----
    wire        swp_we, swp_aux;
    wire [15:0] swp_addr;
    wire [17:0] m_ram_addr_f = swp_we ? {2'b00, swp_addr} : m_ram_addr;
    wire [7:0]  m_ram_di_f   = swp_we ? 8'd0 : m_ram_di;
    wire        m_ram_aux_f  = swp_we ? swp_aux : m_ram_aux;
    wire        m_ram_we_f   = swp_we | m_ram_we;
    ram_sweep_ctl woz_sweep (
        .clk(clk),
        .start(sweep_start),
        .we(swp_we), .addr(swp_addr), .aux(swp_aux), .done(sweep_done)
    );

    // power-on RAM state (file zero-fill, 2026-10-25 Phase B): the nested
    // 256x256 procedural loop cost ~19 min of single-threaded A&S CPU on
    // the full core (probe evidence: tools/ram_repro_init 19:13 vs
    // tools/ram_repro_file 1:28 for the identical one-bank RAM - the file
    // form is ~13x faster). Canonical image: src/fpga/rtl/roms/
    // ram_zero_64k.hex (65,536 x "00", LF, git-tracked, *.hex text eol=lf).
    // Path is CWD-relative: Quartus runs from src/fpga; the sim runner
    // stages the same file under its rtl/roms/ (verilog/pocket_boot/
    // build.sh, with preflight). Configuration-time initialization only -
    // a machine reset is NOT a reload of this file: the runtime clearing
    // sweep (ram_sweep_ctl below) still clears both banks after every
    // cold reset before the CPU is released.
    initial begin
        $readmemh("rtl/roms/ram_zero_64k.hex", ram_main);
        $readmemh("rtl/roms/ram_zero_64k.hex", ram_aux);
    end

    // ---- the proven M1 RAM shape: plain per bank, write-first bypass -
//      consumes the overlayed _s nets only. W1: the address mux is
// WRITE-ONLY-select (the proven October sweep pattern: select high only
// on write cycles); the manager READ uses its own address (below), so a
// read never sees a muxed address. ----
    wire        m_ram_we_s   = ss_ram_wr | m_ram_we_f;
    wire        m_ram_aux_s  = ss_ram_wr ? ss_ram_bank : m_ram_aux_f;
    wire [17:0] m_ram_addr_s = ss_ram_wr ? {2'b00, ss_ram_addr} : m_ram_addr_f;
    wire [7:0]  m_ram_di_s   = ss_ram_wr ? ss_ram_wdata : m_ram_di_f;
    always @(posedge clk) begin
        if (m_ram_we_s & ~m_ram_aux_s) begin
            ram_main[m_ram_addr_s[15:0]] <= m_ram_di_s;
            m_ram_do[7:0]              <= m_ram_di_s;
        end else m_ram_do[7:0]  <= ram_main[m_ram_addr_s[15:0]];
        if (m_ram_we_s & m_ram_aux_s) begin
            ram_aux[m_ram_addr_s[15:0]] <= m_ram_di_s;
            m_ram_do[15:8]            <= m_ram_di_s;
        end else m_ram_do[15:8]  <= ram_aux[m_ram_addr_s[15:0]];
    end
    // Manager read (matrix u_k shape): per-bank PRIVATE registers at the
    // manager's OWN address; each RAM gets one plain write-first read port
    // (machine) plus one plain private read port (manager) -> 17.0.2
    // infers each bank as a dual-clock M10K (276027 caveat is a non-issue:
    // port-A reads are write-bypassed, and the manager never reads while
    // anything writes - the machine is frozen). The bank mux is fabric,
    // outside the templates. Latency: address at T (ss_ram_rd) -> q2
    // registers at T+1 -> mux -> mgr_ram_rdata valid T+1 (the manager's
    // ram_rd-on-T / data-on-T+1 protocol; ram_bank/ram_addr are stable
    // across that window in savestate_manager - byte_index only advances
    // AFTER the capture).
    reg [7:0] mgr_rd_main_q, mgr_rd_aux_q;
    always @(posedge clk)
        if (ss_ram_rd) begin
            mgr_rd_main_q <= ram_main[ss_ram_addr];
            mgr_rd_aux_q  <= ram_aux[ss_ram_addr];
        end
    assign mgr_ram_rdata = ss_ram_bank ? mgr_rd_aux_q : mgr_rd_main_q;

endmodule
