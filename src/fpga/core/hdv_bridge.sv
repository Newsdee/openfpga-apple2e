// HDV bridge transfer (PLAN_HDV_READONLY §4c): hardwired sector mover.
//
// Owns the 512-byte sector RAM at bridge address 0x01F01000 and the
// bridge-domain command FSM that moves whole sectors between that RAM and
// the deferload HDV data slot (id 2) via the existing 0x0180/0x0184 target
// commands. No soft CPU - a small FSM, exactly as MiSTer does it
// (Apple-II.sv:887-919).
//
// READ (6502 executes C0F0 with command=READ):
//   hdd.hdd_read pulse (14M, 1 machine clk) -> 2FF -> read_pend (74a)
//   FSM: arm 0x0180 (id=2, slotoffset=sector*512, bridgeaddr, len=512),
//   cpu_wait_hdd asserted (the top syncs it to 14M as CPU_WAIT - the 6502
//   stays stalled for the whole transfer), host DMAs 512 bytes into the
//   RAM, done edge -> 14M walker copies RAM -> hdd sector buffer (512
//   machine cycles) -> cpu_wait released.
//
// WRITE (command=WRITE): mirror image - the 14M walker first copies the
// hdd sector buffer into the RAM (hdd.ram_do is registered: 1 machine
// clock latency), then 0x0184 streams the RAM to the slot. With
// hdd_protect=1 (the read-only milestone) hdd never pulses hdd_write, so
// this path is inert but present for the write-back milestone.
//
// RAM write protocol (never concurrent, by construction):
//   - host DMA writes (74a) happen only while cpu_wait is asserted, i.e.
//     while the machine is stalled and no walker is running;
//   - the walker's writes (14M) run only between host commands, and they
//     cross into the 74a domain as (strobe, addr, data) - the RAM itself
//     has a SINGLE write clock (74a), so the array is driven by one
//     always block (Verilog forbids two drivers on one array; the
//     "always @(posedge a or posedge b)" + level-check idiom is unsafe
//     for asynchronous clocks).
//   - the FSM waits a 2-bridge-clock guard (ST_WRITE_ARM) after the
//     walk_out strobes end before arming 0x0184, so the last CDC write
//     has settled by the time the host DMA may read the RAM.
// Reads of the RAM are one-clock-late (the lane altsyncrams' registered
// read addresses; PLAN_HDV_M10K) - the contents are only read after the
// relevant write burst has completed.
//
// CDC notes: 14M->74a pulses are fine (a 1-machine-clk pulse is ~5 bridge
// clocks). The 74a->14M walk requests are therefore LEVELS, held for the
// whole walk (a 1-bridge-clk pulse is shorter than one machine clock and
// would be lost by a 2FF synchronizer ~80% of the time).
//
// The host read port (bridge reads of 0x01F01xxx, used by the 0x0184 DMA)
// is exposed as hdv_ram_word for the top-level bridge_rd mux.

module hdv_bridge #(
    // 74a-clock timeout for an in-flight host command (0x0180/0x0184).
    // If the host never completes, the FSM aborts to IDLE after this many
    // clocks (default 2^28-1 ~ 3.6 s at 74.25 MHz), releases the CPU stall,
    // and latches hdv_fault. Without this, a fetch that never completes
    // holds cpu_wait_hdd high FOREVER - a frozen machine with no recovery
    // (observed on hardware 2026-10-30: HDV mounted -> ROM commits to the
    // HD -> first C0F0 read -> stall that never ends).
    // NOTE: 28 bits max = 0x0FFFFFFF; 0x1000_0000 itself needs 29 bits.
    parameter [27:0] FETCH_TO = 28'h0FFFFFFF
    , parameter OOB_ENCODE = 1'b0
    // 2026-11-07 diagnostic (framework ticket refinement): 1 => out-of-window
    // reads return {16'hA5A5, addr[9:2], 8'h00} -- the WORD INDEX of the
    // out-of-window address -- instead of 0. In a corrupted HDV the tail
    // words of each shifted sector then record the host's actual read
    // addresses in order: k per transfer, monotonicity, skips -- all
    // recoverable from the file, no on-screen readout needed. Shipping = 0
    // (plain 0 return; the A/B evidence in the ticket uses this).
    // 2026-11-07 (expert Problem 2, model B proven in sim by T8e): the
    // framework's 0x0184 DMA PRIMES one beat against the documented read
    // convention ("data may arrive up to the next read strobe later") and
    // DISCARDS the first sampled value. The port must present ONE more
    // stage than the top-level bridge_rd_data alone, so that the primed
    // (discarded) sample is stale and the kept 128 align to 0..127
    // (0.3.3/0.3.4 lacked that stage: the prime discarded a VALID word
    // and the kept 128 landed shifted by k - the hardware corruption;
    // T8e reproduces it exactly in sim). Kept LOCAL to hdv_ram_word: the
    // global bridge_rd_data mux (apf_stream_video_top.v) is untouched -
    // a read-back-mux change once broke disk loading on silicon.
    //
    // STAGE ACCOUNTING BY RAM GENERATION:
    //   pre-M10K (combinational array): the +1 stage came from THIS prime
    //   register -> RD_PRIME_STAGE=1 shipping (0.3.5, confirmed byte-exact
    //   on silicon). The prime delayed every sample - in-window AND OOR -
    //   by one read; that OOR delay is what kept the model-B flow's final
    //   OOR sample (the 129th read at word 128) out of the kept stream.
    //   M10K lane RAMs (2026-11-20, PLAN_HDV_M10K): first shipped with
    //   RD_PRIME_STAGE=0, assuming the RAM's registered read address IS the
    //   +1 stage. 2026-11-20 HW ROLLS 1-2 REFUTED THAT: with the M10K
    //   output host-facing (prime off), the Pocket host's sampling window
    //   lands EARLIER in the 74a cycle than the ALM-FF window the 0.3.5-0.4.1
    //   silicon alignment was built on - the M10K registered-read output is
    //   effectively transparent in the host's eyes and the kept 128 land
    //   2 words early (roll 2: SmartportHD_test.HDV sector 2 written with
    //   file[x] = C[x+8], 502/512 bytes; roll 1: a different corruption
    //   shape, plus a hang mid folder-create). The sim cannot see this:
    //   the TB's rd_pipe models the host's registered read stage at a fixed
    //   74a phase (T8e passes byte-exact with prime=0 in sim), while the
    //   real host samples on its own clock at a placement-dependent phase.
    //   SHIPPING CONFIG (2026-11-20, post-roll-2): RD_PRIME_STAGE=1 - the
    //   prime FF is the host-facing stage again (exactly the 0.3.5-0.4.1
    //   silicon-proven form: plain ALM register presenting to the host,
    //   which the framework's prime+discard aligns to), with the M10K
    //   registered read providing the upstream data. In the TB's fixed
    //   phase model that is one word further from alignment than prime=0
    //   (T8e re-baselined to an offset-agnostic integrity/contiguity check
    //   - absolute kept-stream alignment is host-phase-dependent and
    //   hardware-only; re-verified on silicon by the roll-3 HDV-write test).
    //   OOR reads with prime on present the registered gather
    //   (hdv_ram_word_ww_q): the 129th (OOR) read's sample is word 126 in
    //   the TB model, and the gather (word 127) latched at the OOR read
    //   surfaces at the non-existent read 130 - no OOR value ever enters
    //   the kept 128, matching the 0.3.5 OOR behavior.
    , parameter RD_PRIME_STAGE = 1'b1
) (
    input  wire        clk_74a,        // bridge clock
    input  wire        clk_14a,        // machine clock (14.318)
    input  wire        reset_n,        // bridge reset, active low (74a)

    // host bridge (74a domain)
    input  wire        bridge_rd,      // host read strobe (diagnostic: 0x0184 read count)
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] hdv_ram_word,   // 0x01F01xxx read port (BE word)

    // core_bridge_cmd dataslot interface (74a) - driven here
    output reg         target_dataslot_read,
    output reg         target_dataslot_write,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,

    // slot presence (74a domain, from the top's datatable poller + 008A)
    input  wire        hdv_mounted,    // hdv slot size != 0
    input  wire        hdv_protect,    // 1 = read-only (no hdd_write expected)

    // hdd sector-buffer interface (14M domain) - to hdd.v
    output wire [8:0]  hdd_ram_addr,
    output wire [7:0]  hdd_ram_di,
    input  wire [7:0]  hdd_ram_do,
    output wire        hdd_ram_we,

    // hdd request pulses (14M domain, 1 machine clock wide)
    input  wire        hdd_read,
    input  wire        hdd_write,
    input  wire [15:0] hdd_sector,

    // machine stall request (74a domain; the top syncs to 14M for CPU_WAIT)
    output wire        cpu_wait_hdd,

    // diagnostics (74a domain; the top syncs them to the machine domain
    // for the on-screen debug line)
    output wire [2:0]  hdv_state,      // command FSM state (0 idle .. 5 write)
    output wire        hdv_fault,      // a host command timed out (until reset or a clean completion)
    output wire [7:0]  hdv_fetch_cnt,  // completed 0x0180 fetches (saturates at 255)
    output wire [7:0]  hdv_wrcnt,      // host 0x0184 read words of the LAST write (want 128)
    output wire [7:0]  hdv_oobcnt,     // out-of-window (0x01F01200+) reads of the LAST write (= host start offset k)

    // media-fault pulse to hdd.v (74a domain; the top 2FF-syncs it to 14M
    // and hdd uses it to force reg_status, so C0F1 reports a dropped or
    // timed-out fetch instead of the stale optimistic 00 from execute)
    output wire        bridge_err
);

    localparam BRIDGE_HDV_ADDR = 32'h01F01000; // RAM base (512-byte window)

    // ------------------------------------------------------------------
    // Sector RAM: 512 x 8 as four 128x8 LANE altsyncrams (four 1-Kbit
    // blocks; the fitter packs them - PLAN_HDV_M10K_2026-11-20).
    // Lane L holds the old hdv_ram[4*word + L], so the host's
    // 4-bytes-per-clock DMA word is four parallel single-byte lane writes
    // (lane address = word index), and the 14M walk_in reads one lane per
    // byte (lane select = byte[1:0]).
    //
    // Port A (CLOCK0 = clk_74a): host DMA read/write + walk_out byte
    // write. Writes are SAME-CYCLE (indata/wrcontrol wraddress regs =
    // "NONE" - probe-verified 2026-11-20 in tools/ramprobe_4lane: the
    // resolved megafunction is identical to the omitted spelling, and
    // port A resolves unregistered per the hdd.v probe-X finding: a byte
    // is visible one 74a cycle after presentation, exactly like the old
    // NBA array; wo_landed needs no change for this reason). Reads are
    // 1-cycle (registered address + UNREGISTERED output): q_a is one
    // clock behind the presented address. SHIPPING (2026-11-20, post HW
    // rolls 1-2): RD_PRIME_STAGE=1 - this 1-cycle read is the UPSTREAM
    // stage and the prime FF (hdv_ram_word_q) is the host-facing stage
    // (the 0.3.5-0.4.1 silicon-proven form). The first M10K shipping
    // attempt put this M10K output directly host-facing (prime=0) and it
    // corrupted HDV writes on hardware (2-word-early kept stream - the
    // host's early-in-cycle sampling window does not see the M10K output
    // as a stage; see the header STAGE ACCOUNTING comment and
    // docs/PLAN_HDV_M10K_2026-11-20.md §11). OOR reads present the
    // registered gather (last latched in-window word, one read delayed -
    // readout comment).
    // Port B (CLOCK1 = clk_14a): walk_in reads only (wren_b tied off),
    // same 1-cycle read; the walk_in (we, addr) pair is delayed one 14M
    // cycle (wi_we_d/wi_addr_d below) so hdd latches the IDENTICAL
    // (we, addr, di) tuple it latched with the old combinational array,
    // one cycle later (walk_in now runs 513 cycles; the final byte's
    // commit lands one cycle after the walk-done pulse, absorbed by the
    // wd_sync 2FF + 5-clock latch before the 74a FSM consumes done).
    // Phases remain mutually exclusive (host write / host read / walk_in
    // / walk_out) - same read-during-write unreachability as before the
    // conversion; NEW_DATA_NO_NBE_READ as in hdd.v (OLD_DATA is the
    // bidir-rejected Error-14000 value).
    // ------------------------------------------------------------------
    // host DMA write port: a 32-bit BE word = 4 consecutive bytes (first file
    // byte in [31:24]; the core drives bridge_endian_little = 0)
    wire        host_wr_en = bridge_wr && (bridge_addr[31:12] == 20'h01F01);
    wire [6:0]  host_word  = bridge_addr[8:2];   // 0..127

    // walk_out write port (CDC'd from 14M; see below)
    reg         wo_wen;
    reg  [8:0]  wo_addr;
    reg  [7:0]  wo_data;

    // Port A write: the host word burst and the walk_out byte never
    // overlap (phase-separated above); the walk_out byte selects its
    // lane, the host burst writes all four lanes at the same word index.
    wire        wo_lane0 = wo_wen & (wo_addr[1:0] == 2'd0);
    wire        wo_lane1 = wo_wen & (wo_addr[1:0] == 2'd1);
    wire        wo_lane2 = wo_wen & (wo_addr[1:0] == 2'd2);
    wire        wo_lane3 = wo_wen & (wo_addr[1:0] == 2'd3);

    // Port A address/data (read + write share the one port-A address in
    // bidir_dual_port; the three phases never overlap):
    //   walk_out byte > host word write > host word read.
    // BIG-ENDIAN host write: the first file byte of the group is in
    // [31:24] and goes to byte 4*word (lane 0) - the "intertwined"
    // corruption seen on hardware 2026-11-02 came from an LE unpack here.
    wire [6:0]  lane_addr_a = wo_wen ? wo_addr[8:2] :
                              host_wr_en ? host_word : rd_word;
    wire [7:0]  lane0_data  = wo_lane0 ? wo_data : bridge_wr_data[31:24];
    wire [7:0]  lane1_data  = wo_lane1 ? wo_data : bridge_wr_data[23:16];
    wire [7:0]  lane2_data  = wo_lane2 ? wo_data : bridge_wr_data[15: 8];
    wire [7:0]  lane3_data  = wo_lane3 ? wo_data : bridge_wr_data[ 7: 0];

    wire [7:0] lane0_qa, lane1_qa, lane2_qa, lane3_qa;   // 74a readout
    wire [7:0] lane0_qb, lane1_qb, lane2_qb, lane3_qb;   // 14M walk_in

    altsyncram u_hdv_lane0 (
        .address_a (lane_addr_a), .address_b (cnt_i[8:2]),
        .clock0 (clk_74a),        .clock1 (clk_14a),
        .data_a (lane0_data),     .data_b (8'h00),
        .wren_a (host_wr_en | wo_lane0), .wren_b (1'b0),
        .q_a (lane0_qa),          .q_b (lane0_qb),
        .aclr0 (1'b0), .aclr1 (1'b0),
        .addressstall_a (1'b0),   .addressstall_b (1'b0),
        .byteena_a (1'b1),        .byteena_b (1'b1),
        .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
        .eccstatus (),
        .rden_a (1'b1), .rden_b (1'b1)
    );
    defparam
        u_hdv_lane0.operation_mode               = "BIDIR_DUAL_PORT",
        u_hdv_lane0.numwords_a                     = 128,
        u_hdv_lane0.numwords_b                     = 128,
        u_hdv_lane0.widthad_a                      = 7,
        u_hdv_lane0.widthad_b                      = 7,
        u_hdv_lane0.width_a                        = 8,
        u_hdv_lane0.width_b                        = 8,
        u_hdv_lane0.width_byteena_a                = 1,
        u_hdv_lane0.width_byteena_b                = 1,
        u_hdv_lane0.outdata_reg_a                  = "UNREGISTERED",
        u_hdv_lane0.outdata_reg_b                  = "UNREGISTERED",
        u_hdv_lane0.address_reg_b                  = "CLOCK1",
        // port A same-cycle writes (probe-verified: identical resolved
        // entity to the omitted spelling; see tools/ramprobe_4lane)
        u_hdv_lane0.indata_reg_a                   = "NONE",
        u_hdv_lane0.wrcontrol_wraddress_reg_a      = "NONE",
        u_hdv_lane0.read_during_write_mode_port_a  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane0.read_during_write_mode_port_b  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane0.clock_enable_input_a           = "BYPASS",
        u_hdv_lane0.clock_enable_input_b           = "BYPASS",
        u_hdv_lane0.clock_enable_output_a          = "BYPASS",
        u_hdv_lane0.clock_enable_output_b          = "BYPASS",
        u_hdv_lane0.outdata_aclr_a                 = "NONE",
        u_hdv_lane0.outdata_aclr_b                 = "NONE",
        u_hdv_lane0.power_up_uninitialized         = "TRUE",
        u_hdv_lane0.intended_device_family         = "Cyclone V",
        u_hdv_lane0.lpm_type                       = "altsyncram";

    altsyncram u_hdv_lane1 (
        .address_a (lane_addr_a), .address_b (cnt_i[8:2]),
        .clock0 (clk_74a),        .clock1 (clk_14a),
        .data_a (lane1_data),     .data_b (8'h00),
        .wren_a (host_wr_en | wo_lane1), .wren_b (1'b0),
        .q_a (lane1_qa),          .q_b (lane1_qb),
        .aclr0 (1'b0), .aclr1 (1'b0),
        .addressstall_a (1'b0),   .addressstall_b (1'b0),
        .byteena_a (1'b1),        .byteena_b (1'b1),
        .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
        .eccstatus (),
        .rden_a (1'b1), .rden_b (1'b1)
    );
    defparam
        u_hdv_lane1.operation_mode               = "BIDIR_DUAL_PORT",
        u_hdv_lane1.numwords_a                     = 128,
        u_hdv_lane1.numwords_b                     = 128,
        u_hdv_lane1.widthad_a                      = 7,
        u_hdv_lane1.widthad_b                      = 7,
        u_hdv_lane1.width_a                        = 8,
        u_hdv_lane1.width_b                        = 8,
        u_hdv_lane1.width_byteena_a                = 1,
        u_hdv_lane1.width_byteena_b                = 1,
        u_hdv_lane1.outdata_reg_a                  = "UNREGISTERED",
        u_hdv_lane1.outdata_reg_b                  = "UNREGISTERED",
        u_hdv_lane1.address_reg_b                  = "CLOCK1",
        u_hdv_lane1.indata_reg_a                   = "NONE",
        u_hdv_lane1.wrcontrol_wraddress_reg_a      = "NONE",
        u_hdv_lane1.read_during_write_mode_port_a  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane1.read_during_write_mode_port_b  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane1.clock_enable_input_a           = "BYPASS",
        u_hdv_lane1.clock_enable_input_b           = "BYPASS",
        u_hdv_lane1.clock_enable_output_a          = "BYPASS",
        u_hdv_lane1.clock_enable_output_b          = "BYPASS",
        u_hdv_lane1.outdata_aclr_a                 = "NONE",
        u_hdv_lane1.outdata_aclr_b                 = "NONE",
        u_hdv_lane1.power_up_uninitialized         = "TRUE",
        u_hdv_lane1.intended_device_family         = "Cyclone V",
        u_hdv_lane1.lpm_type                       = "altsyncram";

    altsyncram u_hdv_lane2 (
        .address_a (lane_addr_a), .address_b (cnt_i[8:2]),
        .clock0 (clk_74a),        .clock1 (clk_14a),
        .data_a (lane2_data),     .data_b (8'h00),
        .wren_a (host_wr_en | wo_lane2), .wren_b (1'b0),
        .q_a (lane2_qa),          .q_b (lane2_qb),
        .aclr0 (1'b0), .aclr1 (1'b0),
        .addressstall_a (1'b0),   .addressstall_b (1'b0),
        .byteena_a (1'b1),        .byteena_b (1'b1),
        .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
        .eccstatus (),
        .rden_a (1'b1), .rden_b (1'b1)
    );
    defparam
        u_hdv_lane2.operation_mode               = "BIDIR_DUAL_PORT",
        u_hdv_lane2.numwords_a                     = 128,
        u_hdv_lane2.numwords_b                     = 128,
        u_hdv_lane2.widthad_a                      = 7,
        u_hdv_lane2.widthad_b                      = 7,
        u_hdv_lane2.width_a                        = 8,
        u_hdv_lane2.width_b                        = 8,
        u_hdv_lane2.width_byteena_a                = 1,
        u_hdv_lane2.width_byteena_b                = 1,
        u_hdv_lane2.outdata_reg_a                  = "UNREGISTERED",
        u_hdv_lane2.outdata_reg_b                  = "UNREGISTERED",
        u_hdv_lane2.address_reg_b                  = "CLOCK1",
        u_hdv_lane2.indata_reg_a                   = "NONE",
        u_hdv_lane2.wrcontrol_wraddress_reg_a      = "NONE",
        u_hdv_lane2.read_during_write_mode_port_a  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane2.read_during_write_mode_port_b  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane2.clock_enable_input_a           = "BYPASS",
        u_hdv_lane2.clock_enable_input_b           = "BYPASS",
        u_hdv_lane2.clock_enable_output_a          = "BYPASS",
        u_hdv_lane2.clock_enable_output_b          = "BYPASS",
        u_hdv_lane2.outdata_aclr_a                 = "NONE",
        u_hdv_lane2.outdata_aclr_b                 = "NONE",
        u_hdv_lane2.power_up_uninitialized         = "TRUE",
        u_hdv_lane2.intended_device_family         = "Cyclone V",
        u_hdv_lane2.lpm_type                       = "altsyncram";

    altsyncram u_hdv_lane3 (
        .address_a (lane_addr_a), .address_b (cnt_i[8:2]),
        .clock0 (clk_74a),        .clock1 (clk_14a),
        .data_a (lane3_data),     .data_b (8'h00),
        .wren_a (host_wr_en | wo_lane3), .wren_b (1'b0),
        .q_a (lane3_qa),          .q_b (lane3_qb),
        .aclr0 (1'b0), .aclr1 (1'b0),
        .addressstall_a (1'b0),   .addressstall_b (1'b0),
        .byteena_a (1'b1),        .byteena_b (1'b1),
        .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
        .eccstatus (),
        .rden_a (1'b1), .rden_b (1'b1)
    );
    defparam
        u_hdv_lane3.operation_mode               = "BIDIR_DUAL_PORT",
        u_hdv_lane3.numwords_a                     = 128,
        u_hdv_lane3.numwords_b                     = 128,
        u_hdv_lane3.widthad_a                      = 7,
        u_hdv_lane3.widthad_b                      = 7,
        u_hdv_lane3.width_a                        = 8,
        u_hdv_lane3.width_b                        = 8,
        u_hdv_lane3.width_byteena_a                = 1,
        u_hdv_lane3.width_byteena_b                = 1,
        u_hdv_lane3.outdata_reg_a                  = "UNREGISTERED",
        u_hdv_lane3.outdata_reg_b                  = "UNREGISTERED",
        u_hdv_lane3.address_reg_b                  = "CLOCK1",
        u_hdv_lane3.indata_reg_a                   = "NONE",
        u_hdv_lane3.wrcontrol_wraddress_reg_a      = "NONE",
        u_hdv_lane3.read_during_write_mode_port_a  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane3.read_during_write_mode_port_b  = "NEW_DATA_NO_NBE_READ",
        u_hdv_lane3.clock_enable_input_a           = "BYPASS",
        u_hdv_lane3.clock_enable_input_b           = "BYPASS",
        u_hdv_lane3.clock_enable_output_a          = "BYPASS",
        u_hdv_lane3.clock_enable_output_b          = "BYPASS",
        u_hdv_lane3.outdata_aclr_a                 = "NONE",
        u_hdv_lane3.outdata_aclr_b                 = "NONE",
        u_hdv_lane3.power_up_uninitialized         = "TRUE",
        u_hdv_lane3.intended_device_family         = "Cyclone V",
        u_hdv_lane3.lpm_type                       = "altsyncram";


    // host read port (74a, combinational): BE word for the 0x0184 DMA reads.
    // 2026-11-06 (expert review of the SmartportHD corruption): the RAM is
    // 512 bytes but the top-level decode arm is 0x01F01xxx (4 KB), and the
    // word select below is only 7 bits - reads at 0x01F01200+ SILENTLY WRAPPED
    // to word 0, so a host 0x0184 DMA that starts k words into the window
    // (the framework's registered read port adds a 1-2 word pipeline offset
    // to a bulk sequential read) received the sector cyclically rotated by
    // 4k bytes (the 0.3.3/0.3.4 corruption: +8B/+4B sector rotations).
    // Out-of-range reads now return the default 0 arm instead of wrapping.
    wire [6:0] rd_word  = bridge_addr[8:2];
    wire       rd_oob   = (bridge_addr[11:9] != 3'b000);   // beyond the 512-B window
    // BIG-ENDIAN readout, matching the write path above (bridge_endian_little
    // = 0): word[31:24] = first file byte of the group (lane 0, byte 4*word),
    // word[7:0] = last (lane 3, byte 4*word+3). In-window reads come from
    // the lane RAMs' port A 1-cycle read (one clock behind the presented
    // address). SHIPPING CONFIG (2026-11-20, post HW rolls 1-2):
    // RD_PRIME_STAGE=1 - the prime FF is the host-facing stage (the
    // 0.3.5-0.4.1 silicon-proven form); the M10K's registered read provides
    // the upstream data. The M10K output MUST NOT be host-facing directly:
    // with RD_PRIME_STAGE=0 the Pocket host's sampling window (early in the
    // 74a cycle, placement-dependent) saw the M10K registered output as
    // effectively transparent and the kept 128 landed 2 words early (roll 2:
    // SmartportHD_test.HDV sector 2, file[x]=C[x+8] over 502/512 bytes;
    // roll 1: different corruption shape + a hang). The sim cannot detect
    // this - the TB samples at a fixed 74a phase (see the header comment).
    //
    // OOR-READ VALUE: an out-of-window read presents the GATHER (in-window
    // words: hdv_ram_word_ww with prime off; the registered gather
    // hdv_ram_word_ww_q with prime on - the SHIPPING case). With prime on,
    // the 129th (OOR) read's sample is the word latched one read earlier
    // (word 126 in the TB model) and the gather latched at the OOR read
    // (word 127) surfaces at the non-existent read 130 - no OOR value ever
    // enters the kept 128, exactly the 0.3.5 OOR behavior. (OOB_ENCODE=1
    // diagnostic mode presents the A5A5 tag at the OOR read position -
    // one read earlier than the old port's OOR sample, acceptable in an
    // instrumented build by definition.)
    // Out-of-window value: the gather (shipping) or the address's
    // word index tagged with A5A5 (diagnostic build; see OOB_ENCODE).
    wire [31:0] oob_val = OOB_ENCODE ? {16'hA5A5, bridge_addr[9:2], 8'h00}
                                     : 32'h0000_0000;
    wire [31:0] hdv_ram_word_ww = {lane0_qa, lane1_qa, lane2_qa, lane3_qa};
    reg  [31:0] hdv_ram_word_ww_q;
    always @(posedge clk_74a)
        if (bridge_rd)
            hdv_ram_word_ww_q <= hdv_ram_word_ww;
    wire [31:0] hdv_ram_word_c = (rd_oob && OOB_ENCODE) ? oob_val
                                        : (RD_PRIME_STAGE ? hdv_ram_word_ww_q
                                                          : hdv_ram_word_ww);

    // 2026-11-07 (expert Problem 2, model B proven in sim by T8e): the
    // framework's 0x0184 DMA PRIMES one beat against the documented read
    // convention ("data may arrive up to the next read strobe later") and
    // DISCARDS the first sampled value. With only the top-level
    // bridge_rd_data stage of latency, that first sample is already valid
    // (word 0), so the prime discards a valid word and the kept 128 land
    // shifted by k (the 0.3.3/0.3.4 hardware corruption; T8e reproduces it
    // exactly in sim). Presenting one more clk_74a stage makes the primed
    // (discarded) sample the stale one, so the kept 128 align to 0..127.
    // Kept LOCAL to hdv_ram_word: the global bridge_rd_data mux
    // (apf_stream_video_top.v) is untouched - a read-back-mux change once
    // broke disk loading on silicon (see its comment at ~line 1024).
    // RD_PRIME_STAGE=1 (SHIPPING with the M10K lane RAMs, 2026-11-20
    // post HW rolls 1-2): the prime FF re-becomes the host-facing stage -
    // the exact 0.3.5-0.4.1 silicon-proven form (plain ALM register that
    // the framework's prime+discard aligns to), with the M10K's registered
    // read upstream. RD_PRIME_STAGE=0 (M10K output host-facing) was the
    // first M10K shipping attempt and CORRUPTED HDV writes on hardware
    // (2-word-early kept stream; see the header STAGE ACCOUNTING comment):
    // the host's early-in-cycle sampling window does not see the M10K
    // registered output as a stage. Legacy (pre-M10K combinational
    // array): 1 = the 0.3.5 shipping stage.
    reg [31:0] hdv_ram_word_q;
    always @(posedge clk_74a)
        if (bridge_rd)
            hdv_ram_word_q <= hdv_ram_word_c;
    assign hdv_ram_word = RD_PRIME_STAGE ? hdv_ram_word_q : hdv_ram_word_c;

    // ------------------------------------------------------------------
    // CDC: 14M -> 74a (request pulses, walk_done pulse, walk_out bytes)
    //
    // Plain 2FF pulse synchronizers saturate at 11 after the first pulse
    // (nothing clears them), which would swallow every later pulse - and
    // the walks are exactly that: one done per walk, forever. So each
    // pulse is captured into a self-clearing edge latch: the *_rise
    // output stays high ~5 bridge clocks per captured edge, which the
    // 74a FSM (sampling every bridge clock) always sees.
    // ------------------------------------------------------------------
    // self-clearing edge capture: 2FF sync + latch held 5 bridge clocks
    // (instantiated three times below via macro-style manual expansion)
    reg [1:0] rd_sync;
    reg       rd_latch;
    reg  [3:0] rd_clr;
    wire      rd_rise;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            rd_sync <= 2'b00; rd_latch <= 1'b0; rd_clr <= 4'd0;
        end else begin
            rd_sync <= {rd_sync[0], hdd_read};
            if (rd_latch) begin
                rd_clr <= rd_clr + 4'd1;
                if (rd_clr == 4'd5) begin
                    rd_latch <= 1'b0;
                    rd_clr   <= 4'd0;
                end
            end else if (rd_sync[0] && !rd_sync[1]) begin
                rd_latch <= 1'b1;
                rd_clr   <= 4'd0;
            end
        end
    end
    assign rd_rise = rd_latch;

    reg [1:0] wr_sync;
    reg       wr_latch;
    reg  [3:0] wr_clr;
    wire      wr_rise;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wr_sync <= 2'b00; wr_latch <= 1'b0; wr_clr <= 4'd0;
        end else begin
            wr_sync <= {wr_sync[0], hdd_write};
            if (wr_latch) begin
                wr_clr <= wr_clr + 4'd1;
                if (wr_clr == 4'd5) begin
                    wr_latch <= 1'b0;
                    wr_clr   <= 4'd0;
                end
            end else if (wr_sync[0] && !wr_sync[1]) begin
                wr_latch <= 1'b1;
                wr_clr   <= 4'd0;
            end
        end
    end
    assign wr_rise = wr_latch;

    reg [1:0] wd_sync;
    reg       wd_latch;
    reg  [3:0] wd_clr;
    wire      wd_rise;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wd_sync <= 2'b00; wd_latch <= 1'b0; wd_clr <= 4'd0;
        end else begin
            wd_sync <= {wd_sync[0], walk_done_14};
            if (wd_latch) begin
                wd_clr <= wd_clr + 4'd1;
                if (wd_clr == 4'd5) begin
                    wd_latch <= 1'b0;
                    wd_clr   <= 4'd0;
                end
            end else if (wd_sync[0] && !wd_sync[1]) begin
                wd_latch <= 1'b1;
                wd_clr   <= 4'd0;
            end
        end
    end
    assign wd_rise = wd_latch;

    // walk_out strobe (a full machine clock wide = ~5 bridge clocks)
    wire        wo_st_valid;
    wire [8:0]  wo_st_addr;   // 14M domain (stable for the whole strobe)
    wire [7:0]  wo_st_data;   // = hdd_ram_do, stable for the whole strobe
    reg  [1:0]  wo_st_sync;
    wire        wo_st_rise = wo_st_sync[0] & ~wo_st_sync[1];

    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wo_st_sync <= 2'b00;
            wo_wen <= 1'b0;
        end else begin
            wo_st_sync <= {wo_st_sync[0], wo_st_valid};

            // latch the byte on the strobe's rising edge (addr/data are
            // held by the 14M side for the whole machine-clock strobe)
            if (wo_st_rise) begin
                wo_wen  <= 1'b1;
                wo_addr <= wo_st_addr;
                wo_data <= wo_st_data;
            end else begin
                wo_wen <= 1'b0;
            end
        end
    end

    // walk_out commit count (2026-11-05, HDV write-corruption fix):
    // how many of the 512 walked bytes have committed into hdv_ram.
    // The 0x0184 arm used to wait a FIXED one-bridge-clock guard after
    // the walk-done edge (ST_ARM_WRITE) - but the last CDC byte write
    // (byte 511) lands within the same bridge-clock window as the done
    // edge, so on the real 14.318->74.25 async clocks the arm could beat
    // the final commit (sim phases always lined up). The arm now waits
    // for this count: a data handshake, not a timing guess. (Declared
    // after qo_sync below - qo_rise must be declared before use.)
    reg  [9:0] wo_landed;            // 0..512 (512 needs 10 bits)
    // The arm fires only when the counter has reached 512 AND the write
    // pulse is not in flight AND the walk has been running for at least
    // one cycle (walk_out_req_d): the req_d term kills a same-cycle race
    // at WALK_OUT entry - the reset pulse for this walk lands via NBA on
    // the entry posedge, so the combinational done must NOT be allowed to
    // sample the stale 512 from the previous walk on that same cycle
    // (that is exactly the 2026-11-04/05 failure: 0x0184 armed with an
    // unwritten sector buffer, host flush overwrote the HDV with stale
    // data).
    wire walk_out_done = (wo_landed == 10'd512) && !wo_wen && walk_out_req_74 && walk_out_req_d;

    // CDC: 74a -> 14M (walk-request LEVELS, bridge reset)
    // Sync-only reset synchronizer: rs_sync pins to 00 while reset_n=0 and
    // walks to 11 two cycles after reset_n rises. (An async-reset clause
    // whose clear condition tests rs_sync[1] would deadlock at 00.)
    reg [1:0] qi_sync, qo_sync, rs_sync;
    wire      qi_rise = qi_sync[0] & ~qi_sync[1];
    wire      qo_rise = qo_sync[0] & ~qo_sync[1];
    wire      rst_14a = rs_sync[1];

    always @(posedge clk_14a) begin
        qi_sync <= {qi_sync[0], walk_in_req_74};
        qo_sync <= {qo_sync[0], walk_out_req_74};
        rs_sync <= {rs_sync[0], reset_n};
    end

    // walk_out commit count (definition; see the declaration above):
    // increments on each CDC byte write (wo_wen), resets when the walk
    // request LEVEL is rising. The reset must NOT use the qo_rise edge:
    // that edge is the 2FF-synchronized view of the level and can land
    // AFTER the first walk strobe (the level itself reaches the 74a side
    // one cycle earlier) - a late reset would clear bytes already
    // committed, or (worse) a missed edge would leave the stale 512 from
    // the previous walk and arm 0x0184 before this walk has filled the
    // RAM (the 2026-11-05 T8 failure). Resetting on the raw level rising
    // edge is exact: it fires the same cycle the level appears, which is
    // always before the first strobe (the 14M walker needs the level to
    // propagate 2 machine clocks before it even starts counting).
    reg walk_out_req_d;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            wo_landed <= 10'd0;
        end else if (walk_out_req_74 && !walk_out_req_d)
            wo_landed <= 10'd0;      // walk (re)start
        else if (wo_wen)
            wo_landed <= wo_landed + 10'd1;
    end
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n)
            walk_out_req_d <= 1'b0;
        else
            walk_out_req_d <= walk_out_req_74;
    end
    // ------------------------------------------------------------------
    // 14M domain: sector-buffer walkers (512 machine cycles each)
    // ------------------------------------------------------------------
    // walk_in:  RAM -> hdd sector buffer. The lane RAMs' port B read is
    // 1-cycle (registered address + UNREGISTERED output): q_b(m+1) =
    // mem[addr(m)]. So the (we, addr) pair is delayed ONE 14M cycle
    // (wi_we_d/wi_addr_d): at the consuming cycle di == mem[wi_addr_d],
    // and hdd latches (ram_we, ram_addr, ram_di) on its posedge - the
    // IDENTICAL tuple hdd latched with the old combinational array, one
    // cycle later (walk_in runs 513 cycles; the final byte's commit lands
    // one cycle after the walk-done pulse, absorbed by the wd_sync 2FF +
    // 5-clock latch before the 74a FSM consumes done). Zero hdd.v changes.
    // walk_out: hdd sector buffer -> RAM. 2-phase per byte: phase 0
    // presents addr=k to hdd (ram_do becomes buf[k] one clock later),
    // phase 1 (the gap) strobes (k, buf[k]) to the 74a side. One strobe
    // pulse per byte with a full machine-clock gap between pulses, so
    // the 74a 2FF can clear between bytes (a continuous level across the
    // whole walk would give a single rising edge and one byte).
    reg  [9:0] cnt_i;   // 0..512
    reg  [10:0] cnt_o2;  // 0..1024 (512 bytes x 2 phases; 11 bits - 1024
                         // does not fit in 10 bits, and 10'd1024 truncates
                         // to 0, killing the counter)

    always @(posedge clk_14a or negedge rst_14a) begin
        if (!rst_14a) begin
            cnt_i  <= 10'd0;
            cnt_o2 <= 11'd0;
        end else begin
            // gated by the request level: no free-running from reset (a
            // phantom walk would saturate wd_sync and swallow the real
            // walk's done pulse)
            if (qi_rise)
                cnt_i <= 10'd0;
            else if (qi_sync[1] && cnt_i < 10'd512)
                cnt_i <= cnt_i + 10'd1;

            if (qo_rise)
                cnt_o2 <= 11'd0;
            else if (qo_sync[1] && cnt_o2 < 11'd1024)
                cnt_o2 <= cnt_o2 + 11'd1;
        end
    end

    // Request-QUALIFIED active flag: cnt_i parks at 0 between walks, so an
    // unqualified (cnt_i < 512) would hold hdd_ram_we HIGH at idle, clobbering
    // sector_buf[0] with hdv_ram[0] every 14M cycle. The counter only runs
    // while the request level is present, and the flag must too.
    wire walk_in_active = qi_sync[1] && (cnt_i < 10'd512);
    wire [9:0] wo_byte  = cnt_o2[10:1];   // byte index 0..511

    // walk_in delay pair (option (d), PLAN_HDV_M10K): the 14M walk_in read
    // of the lane RAMs is 1-cycle, so (we, addr) is registered once to keep
    // hdd's latched (we, addr, di) tuple identical to the old combinational
    // array. di selects the lane of the DELAYED byte index (q_b(m+1) =
    // mem[addr(m)], so at the consuming cycle the byte for wi_addr_d is in
    // lane wi_addr_d[1:0]).
    reg         wi_we_d;
    reg  [8:0]  wi_addr_d;
    always @(posedge clk_14a or negedge rst_14a) begin
        if (!rst_14a) begin
            wi_we_d   <= 1'b0;
            wi_addr_d <= 9'd0;
        end else begin
            wi_we_d   <= walk_in_active;
            wi_addr_d <= walk_in_active ? cnt_i[8:0] : wi_addr_d;
        end
    end
    wire [7:0] wi_lane01  = wi_addr_d[0] ? lane1_qb : lane0_qb;
    wire [7:0] wi_lane23  = wi_addr_d[0] ? lane3_qb : lane2_qb;
    wire [7:0] hdv_ram_di_c = wi_addr_d[1] ? wi_lane23 : wi_lane01;

    // walk_out strobe: the gap phase, once per byte, data valid (byte 0's
    // gap is cnt_o2=1: hdd latched ram_do=buf[0] at the end of the
    // cnt_o2=0 present phase)
    assign wo_st_valid = cnt_o2[0] & (cnt_o2 < 11'd1024);
    assign wo_st_addr  = wo_byte[8:0];
    assign wo_st_data  = hdd_ram_do;

    // one 14M-clock done pulse per completed walk: walk_in fires on the
    // last increment (511 -> 512); walk_out fires on the last gap (1023).
    // Not while the counters park (a parked level would hold wd_sync
    // saturated and swallow later walks' done edges - the FSM serializes
    // walks, so an edge within two bridge clocks is unreachable)
    reg walk_done_14;
    always @(posedge clk_14a or negedge rst_14a) begin
        if (!rst_14a)
            walk_done_14 <= 1'b0;
        else
            walk_done_14 <= (cnt_i == 10'd511) || (cnt_o2 == 11'd1023);
    end
    // hdd port drives (walk_in owns the buffer write port via the delayed
    // tuple; walk_out presents its read address during both phases of each
    // byte). While wi_we_d is low but walk_in is active (the entry cycle)
    // the address is harmless: hdd_ram_we=0, port B is read-only there.
    assign hdd_ram_addr = wi_we_d ? wi_addr_d
                                  : (walk_in_active ? cnt_i[8:0] : wo_byte[8:0]);
    assign hdd_ram_we   = wi_we_d;
    assign hdd_ram_di   = hdv_ram_di_c;

    // ------------------------------------------------------------------
    // 74a domain: command FSM
    // ------------------------------------------------------------------
    localparam ST_IDLE     = 3'd0;
    localparam ST_FETCH    = 3'd1;   // 0x0180 in flight
    localparam ST_WALK_IN  = 3'd2;   // RAM -> hdd walk in progress
    localparam ST_WALK_OUT = 3'd3;   // hdd -> RAM walk in progress
    localparam ST_ARM_WRITE= 3'd4;   // guard: last walk_out CDC writes settle
    localparam ST_WRITE    = 3'd5;   // 0x0184 in flight

    reg  [2:0] state;
    reg        read_pend, write_pend;
    reg  [31:0] offset_q;
    reg        walk_in_req_74, walk_out_req_74;   // levels (see CDC note)
    reg        done_d;
    wire       done_rise = target_dataslot_done & ~done_d;

    // command timeout + fault + fetch count (see FETCH_TO parameter)
    reg  [27:0] to_cnt;
    reg        fault;
    reg [7:0]  fetch_cnt;
    // Every non-IDLE state is bounded by the timeout (2026-11-05): the
    // walk states were previously unbounded - a lost walk-done edge hung
    // cpu_wait_hdd FOREVER. Normal transfers are ~1 ms; the bound is 3.6 s.
    wire       in_xfer = (state != ST_IDLE);
    wire       to_fire = in_xfer && (to_cnt == FETCH_TO - 28'd1);

    // host read-word count around ST_WRITE (2026-11-05 diagnostic): the
    // framework must pull exactly 128 words per 0x0184. If a transfer
    // times out (hdv_fault) with W<128, the host gave up mid-DMA and the
    // file corruption is on the framework's interrupted-transfer side
    // (the 2026-11-05 SmartportHD test: the write "never finished").
    // The window spans ST_ARM_WRITE through ST_WRITE: the RAM is fully
    // committed at the arm (that is the point of the commit-count fix),
    // so early host reads during the arm cycle(s) are valid words and
    // must count - the real framework's DMA latency is not guaranteed to
    // be >=2 cycles. The clear is the ARM entry cycle (transition, not
    // level) so an early read can never race it.
    reg        [2:0] wr_state_d;
    reg        [7:0] wr_read_cnt;
    // out-of-range read counter (2026-11-06 diagnostic, expert review): a
    // 0x0184 DMA that starts k words into the window performs exactly k
    // out-of-range reads (addresses 0x01F01200+). Counting them MEASURES
    // the host's start offset k on silicon (it varied 1-2 words between
    // sectors in the corrupted images) - no framework source needed. The
    // real fix (register-align or pre-shift by k) comes after measurement.
    reg        [7:0] wr_oob_cnt;
    wire         host_rd_ram = bridge_rd && (bridge_addr[31:12] == 20'h01F01);
    wire         host_rd_oob = host_rd_ram && (bridge_addr[11:9] != 3'b000);
    always @(posedge clk_74a)
        wr_state_d <= state;
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n)
            wr_read_cnt <= 8'd0;
        else if (state == ST_ARM_WRITE && wr_state_d != ST_ARM_WRITE)
            wr_read_cnt <= 8'd0;         // arm entry = start of a new 0x0184
        else if (host_rd_ram && (state == ST_ARM_WRITE || state == ST_WRITE)
                 && wr_read_cnt != 8'd255)
            wr_read_cnt <= wr_read_cnt + 8'd1;
    end
    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n)
            wr_oob_cnt <= 8'd0;
        else if (state == ST_ARM_WRITE && wr_state_d != ST_ARM_WRITE)
            wr_oob_cnt <= 8'd0;          // arm entry = start of a new 0x0184
        else if (host_rd_oob && (state == ST_ARM_WRITE || state == ST_WRITE)
                 && wr_oob_cnt != 8'd255)
            wr_oob_cnt <= wr_oob_cnt + 8'd1;
    end

    // bridge_err hold: a drop or timeout sets the hold to 15 x 74a cycles
    // (~202 ns = ~3 machine clocks, so the 2FF in the top always samples a
    // full high window - a bare 1-cycle 74a pulse would be missed by the
    // 14M sampler most of the time). bridge_err is the level while held.
    reg  [3:0] err_hold_74;
    wire       drop_evt = (state == ST_IDLE) && read_pend && !hdv_mounted;
    assign bridge_err = (err_hold_74 != 4'd0);

    always @(posedge clk_74a or negedge reset_n) begin
        if (!reset_n) begin
            state <= ST_IDLE;
            read_pend <= 1'b0;
            write_pend <= 1'b0;
            target_dataslot_read <= 1'b0;
            target_dataslot_write <= 1'b0;
            walk_in_req_74 <= 1'b0;
            walk_out_req_74 <= 1'b0;
            done_d <= 1'b0;
            to_cnt <= 28'd0;
            fault <= 1'b0;
            fetch_cnt <= 8'd0;
            err_hold_74 <= 4'd0;
            target_dataslot_id <= 16'd0;
            target_dataslot_slotoffset <= 32'd0;
            target_dataslot_bridgeaddr <= 32'd0;
            target_dataslot_length <= 32'd0;
        end else begin
            done_d <= target_dataslot_done;

            // one-clock command pulses
            target_dataslot_read  <= 1'b0;
            target_dataslot_write <= 1'b0;

            // walk requests are levels, held for the whole walk
            walk_in_req_74  <= (state == ST_WALK_IN);
            walk_out_req_74 <= (state == ST_WALK_OUT);

            // timeout counter: runs in every in-transfer state; saturates
            // at the bound so to_fire stays a clean one-shot per entry (the
            // fire branch drops the state to IDLE next cycle).
            if (in_xfer)
                to_cnt <= (to_cnt == FETCH_TO - 28'd1) ? to_cnt : to_cnt + 28'd1;
            else
                to_cnt <= 28'd0;

            if (to_fire || drop_evt)
                err_hold_74 <= 4'd15;
            else if (err_hold_74 != 4'd0)
                err_hold_74 <= err_hold_74 - 4'd1;

            if (to_fire) begin
                state <= ST_IDLE;      // release the CPU; the fault is reported
                fault <= 1'b1;
            end else begin
            case (state)
                ST_IDLE: begin
                    // capture requests only here: the 6502 is stalled by
                    // cpu_wait during any transfer, so no C0F0 (and no
                    // hdd_read/hdd_write pulse) can arrive mid-transfer.
                    // Capturing in other states would let the ~5-clock
                    // self-clearing latch re-set the pending bit after the
                    // first transfer consumed it (phantom re-arm).
                    if (rd_rise) read_pend  <= 1'b1;
                    if (wr_rise) write_pend <= 1'b1;

                    if (read_pend && hdv_mounted) begin
                        read_pend <= 1'b0;
                        // parameters are latched at arm time (the host
                        // samples them when the command starts)
                        target_dataslot_id         <= 16'd2;   // HDV slot
                        target_dataslot_slotoffset <= {16'd0, hdd_sector} << 9;
                        target_dataslot_bridgeaddr <= BRIDGE_HDV_ADDR;
                        target_dataslot_length     <= 32'd512;
                        target_dataslot_read       <= 1'b1;
                        state <= ST_FETCH;
                    end else if (read_pend) begin
                        read_pend <= 1'b0;          // not mounted: drop
                    end else if (write_pend && hdv_mounted && !hdv_protect) begin
                        write_pend <= 1'b0;
                        target_dataslot_id         <= 16'd2;
                        target_dataslot_bridgeaddr <= BRIDGE_HDV_ADDR;
                        target_dataslot_length     <= 32'd512;
                        // slotoffset latched after the walk (the walk does
                        // not change the sector registers)
                        offset_q <= {16'd0, hdd_sector} << 9;
                        state <= ST_WALK_OUT;
                    end else if (write_pend) begin
                        write_pend <= 1'b0;         // protected/not mounted
                    end
                end

                ST_FETCH: begin
                    if (done_rise) begin
                        if (target_dataslot_err == 3'd0) begin
                            state <= ST_WALK_IN;    // req level auto-asserts
                            fault <= 1'b0;          // channel is healthy again
                            if (fetch_cnt != 8'd255)
                                fetch_cnt <= fetch_cnt + 8'd1;
                        end else
                            state <= ST_IDLE;       // abort: err stays readable
                    end
                end

                ST_WALK_IN: begin
                    if (wd_rise)
                        state <= ST_IDLE;           // req level auto-drops
                end

                ST_WALK_OUT: begin
                    // wait for the commit count (NOT the walk-done edge):
                    // the 512th CDC write lands inside the same window as
                    // the done-edge latch, so the edge could beat the data
                    // (the 2026-11-05 corruption; see wo_landed above).
                    if (walk_out_done)
                        state <= ST_ARM_WRITE;
                end

                ST_ARM_WRITE: begin
                    // one-bridge-clock settle before the arm pulse (all
                    // 512 bytes are committed by walk_out_done; the guard
                    // is pipeline margin, not a data dependency).
                    state <= ST_WRITE;
                    target_dataslot_slotoffset <= offset_q;
                    target_dataslot_write <= 1'b1;
                end

                ST_WRITE: begin
                    if (done_rise) begin
                        if (target_dataslot_err == 3'd0)
                            fault <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
            end   // to_fire else
        end
    end

    // stall the 6502 across the whole transfer (both directions)
    assign cpu_wait_hdd = (state != ST_IDLE);

    assign hdv_state     = state;
    assign hdv_fault     = fault;
    assign hdv_fetch_cnt = fetch_cnt;
    assign hdv_wrcnt     = wr_read_cnt;
    assign hdv_oobcnt    = wr_oob_cnt;

endmodule
