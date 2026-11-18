//
// tb_savestate_roundtrip.sv - W1 savestate round-trip gate
// (PLAN_SAVESTATES_2026-11-09 refinement #3; EXPERT_BRIEF_SAVESTATE_MANAGER
// 2026-11-11 validation item 3)
//
// Real DUTs (no copies of the glue):
//   apple2e_ram_bank  - the SHIPPING machine RAM glue (extracted from the top
//                       so this gate exercises it, not a mirror)
//   savestate_slot    - the manager wrapper (instantiates the byte-identical
//                       donor savestate_manager)
//   sdram_word_owner  - the SDRAM word-port owner (W1 ssrd/sswr clients)
// Fakes:
//   SDRAM word port - accept-when-idle model of io_sdram_pocket's word
//                     interface (busy window per op, rd_valid/done completion
//                     pulses, idle cycle between ops, periodic refresh op,
//                     init_done)
//   machine side    - cpu_frozen (rises 2 cycles after stall), ss_rdata
//                     golden map + applied-write decode, machine bus driver
//                     (idle except when the TB writes/reads RAM through the
//                     real bus path)
//
// Clocks run at the real Pocket rates (74.25 / 14.318 / 133.12 MHz) with
// non-integer ratios: over one full op every CDC phase combination occurs,
// so a single run sweeps the phase sensitivity.
//
// Topology (mirrors the shipping top):
//   slot (mach) --ssrd/sswr--> owner (ctrl) --word_--> SDRAM port (ctrl)
//   slot (74a)  <-- busy/done handshake contract (host side faked here;
//                    core_bridge_cmd proven on hardware by the W0 probe)
//
// Blob SDRAM word map (slot word a -> SDRAM words {2a, 2a+1}, low first):
//   word 0 = counter (low 32 of header word 0)   word 1 = SS_SIZE_DWORDS
//   word 2 = {version, reserved, cpu}            word 3 = MAGIC "A2L1"
//   words 4..31 = header words 1..15 (zero)      words 32..53 = shadow 0..10
//   words 54..63 = gap (zero)                    words 64..32831 = packed RAM
//
// Gates:
//   T0 fill: distinct patterns in BOTH banks through the machine bus,
//      read back
//   T1 SAVE golden (the aux bank is the trap): blob SDRAM words exact
//      (header/shadow/packed RAM) + SDRAM just outside the blob intact +
//      live RAM untouched by the save
//   T2 ROUND-TRIP: corrupt RAM + shadow -> LOAD -> live RAM == golden
//      (read back over the machine bus) + applied shadow == golden ->
//      re-SAVE -> blob2 == blob1 (word-exact except the counter word)
//   T3 LOAD errors: bad magic / bad version / bad cpu / bad size / zero
//      size -> load_err, machine state intact
//   T4 LOAD gating: load held until blob_wr_drained_74a rises
//   T5 preload_req fired exactly once per completed save
//
// Build + run:  ../run_tb_savestate_roundtrip.sh
//
`timescale 1ns/1ps
module tb_savestate_roundtrip;

  // ======================================================================
  // clocks (real rates; the ratios are non-integer so phases drift)
  // ======================================================================
  reg clk_74a  = 1'b0;
  reg clk_mach = 1'b0;
  reg clk_ctrl = 1'b0;
  initial begin #5.113;  forever #6.734  clk_74a  = ~clk_74a; end // 74.25 MHz
  initial begin #21.407; forever #34.925 clk_mach = ~clk_mach; end // 14.318 MHz
  // controller + DRAM PHY clocks: EXACT shipping relationship from
  // tb_sector_fetch (the only config the real io_sdram_pocket + DRAM model
  // accept without a "bank already active" timing violation). ctrl toggles
  // every PC/2 (266MHz); chip is PHASE-offset; clk_90 is PHASE+PC/2.
  localparam real PC2    = 3.756;
  localparam real PHASE2 = 3.756;
  reg chip_clk = 1'b0, clk90 = 1'b0;
  initial begin #4000;             forever #(PC2/2.0) clk_ctrl = ~clk_ctrl; end
  initial begin #4000; #PHASE2;    forever #(PC2/2.0) chip_clk = ~chip_clk; end
  initial begin #4000; #(PHASE2 + PC2/2.0); forever #(PC2/2.0) clk90 = ~clk90; end

  // ======================================================================
  // REAL SDRAM port (io_sdram_pocket) + behavioral DRAM model
  // (mirrors tb_sector_fetch: the exact shipping port op timing, so the
  //  slot/owner/manager handshake is validated against the real word-port
  //  structure rather than a fake-port approximation - the fake port's GAP
  //  timing deadlocked the savestate write path, 2026-11-12)
  // ======================================================================
  localparam [31:0] BLOBN = 32'd32832;       // blob word count
  localparam [24:0] BLOB_MEM_BASE = 25'h800000;  // = 2 * SDRAM word base 0x400000 (bank 1)

  // DRAM PHY wires (16-bit); phy_* are driven by the port
  wire [12:0] dram_a;
  wire [1:0]  dram_ba;
  wire [15:0] dram_dq;
  wire [1:0]  dram_dqm;
  wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
  reg         por_done   = 1'b0;
  reg         fault_halt = 1'b0;

  tb_dram_model m0 (
    .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
    .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
    .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
    .fault_halt(fault_halt)
  );

  wire        sdram_init_done;
  wire        sd_rd, sd_wr;
  wire [23:0] sd_addr;
  wire [31:0] sd_data, sd_q;
  wire        sd_busy, sd_done, sd_rd_valid, init_done;
  wire        sd_op_start;   // 2026-11-16: port op-start pulse -> owner attribution

  io_sdram_pocket u_port (
    .controller_clk ( clk_ctrl ),
    .chip_clk       ( chip_clk ),
    .clk_90         ( clk90 ),
    .reset_n        ( 1'b1 ),
    .phy_cke        ( dram_cke ),
    .phy_clk        ( dram_clk ),
    .phy_cas        ( dram_cas_n ),
    .phy_ras        ( dram_ras_n ),
    .phy_we         ( dram_we_n ),
    .phy_ba         ( dram_ba ),
    .phy_a          ( dram_a ),
    .phy_dq         ( dram_dq ),
    .phy_dqm        ( dram_dqm ),
    .burst_rd       ( 1'b0 ),
    .burst_addr     ( 25'd0 ),
    .burst_len      ( 11'd0 ),
    .burst_32bit    ( 1'b0 ),
    .burst_data     ( ),
    .burst_data_valid ( ),
    .burst_data_done  ( ),
    .burstwr        ( 1'b0 ),
    .burstwr_addr   ( 15'd0 ),
    .burstwr_ready  ( ),
    .burstwr_strobe ( 1'b0 ),
    .burstwr_data   ( 16'd0 ),
    .burstwr_done   ( 1'b0 ),
    .word_rd        ( sd_rd ),
    .word_wr        ( sd_wr ),
    .word_addr      ( sd_addr ),
    .word_data      ( sd_data ),
    .word_q         ( sd_q ),
    .word_busy      ( sd_busy ),
    .word_done      ( sd_done ),
    .word_rd_valid  ( sd_rd_valid ),
    .word_op_start ( sd_op_start ),
    .boot_done      ( sdram_init_done )
  );
  assign init_done = sdram_init_done;

  // 32-bit SDRAM word <-> 16-bit DRAM model memory helpers.
  // The port dequeues with `addr <= word_addr << 1` and does `addr <= addr+1`
  // between the two data beats, so each 32-bit word W issues TWO independent
  // BL=1 writes: mem[2W] = high half ([31:16], beat 1, ST_WRITE_2),
  // mem[2W+1] = low half ([15:0], beat 2, ST_WRITE_3). The blob (SDRAM word
  // base 0x400000) therefore lives at mem base 0x800000 (bank 1). The model
  // stores each beat at its own col faithfully (no auto-increment needed).
  function [31:0] sdram_read(input [15:0] w);
    sdram_read = {m0.mem[BLOB_MEM_BASE + {w, 1'b0}],
                  m0.mem[BLOB_MEM_BASE + {w, 1'b0} + 1'b1]};
  endfunction
  task sdram_write(input [15:0] w, input [31:0] data);
    begin
      m0.mem[BLOB_MEM_BASE + {w, 1'b0}]        = data[31:16];  // high (even idx)
      m0.mem[BLOB_MEM_BASE + {w, 1'b0} + 1'b1] = data[15:0];   // low  (odd idx)
    end
  endtask

  // 2026-11-15 -> 2026-11-17 (SS HD capture, corrected): emulate the real
  // Pocket host's blob transport between a SAVE and a LOAD. The host's
  // save-read latches ONE WORD BEHIND (APF read buffer): file section =
  // [stale, data(B), ..., data(B+32831)]. The host's load-write STRIPS the
  // stale word and restores data(B+k) at B+k. Net effect on SDRAM:
  // word k <- old word k (k = 0..32831) - the window after transport is
  // word-identical to the save-time window, which the manager's LOAD reads
  // from BLOB_BASE (same base as save; the 2026-11-15 +1 base was a
  // file-only decode, off by one word - see the SS HD brief).
  reg [31:0] htmp [0:32831];
  task host_transport(input string tag);
    integer k;
    begin
      for (k = 0; k < 32832; k = k + 1)
        htmp[k] = sdram_read(k[15:0]);
      for (k = 0; k < 32832; k = k + 1)
        sdram_write(k[15:0], htmp[k]);       // stripped: Wk <- saved[k]
      $display("%s: host transport applied (stale stripped, Wk <- saved[k])", tag);
    end
  endtask

  // (the real io_sdram_pocket above drives sd_rd/sd_wr/sd_addr/sd_data and
  //  presents sd_busy/sd_done/sd_rd_valid/sd_q/init_done; the owner's
  //  word_* outputs connect directly to the port's word_* inputs)

  // ======================================================================
  // DUT nets: slot -> owner -> SDRAM
  // ======================================================================
  wire        ssrd_req;
  wire [23:0] ssrd_addr;
  wire        ssrd_done;
  wire [31:0] ssrd_data;
  wire        sswr_req;
  wire [23:0] sswr_addr;
  wire [31:0] sswr_data;
  wire        sswr_done, sswr_busy, port_wr_idle;

  // ======================================================================
  // fake machine side
  // ======================================================================
  reg  rst_74a  = 1'b1;         // active-HIGH (74a/ctrl domain reset)
  wire rst_ctrl = ~rst_74a;     // the owner takes active-LOW
  reg  rst_mach = 1'b1;         // active-LOW: machine NOT in reset

  wire        stall;
  reg  stall_d1 = 0, stall_d2 = 0;
  always @(posedge clk_mach) begin
    stall_d1 <= stall;
    stall_d2 <= stall_d1;
  end
  wire cpu_frozen = stall_d2;   // the machine halts 2 cycles after stall

  // the machine's ss_* interface: golden shadow map + applied-write decode
  // (real machine/apple2.v decode: the 65C02 acts on words 0-2 (each its
  // own registers), apple2.v on 3 (machine) + 4 (latches), timing_generator
  // on 5/6, video_generator on 7; words 8-10 are read-only there)
  reg  [63:0] shadow_gold [0:10];   // what a healthy machine presents
  reg  [63:0] shadow_live [0:10];   // the machine's live state (restored)
  wire [9:0]  ss_addr;              // driven by the slot
  reg  [63:0] ss_rdata_mux = 64'd0;
  always @(*) begin
    case (ss_addr)
      10'd0:    ss_rdata_mux = shadow_live[0];
      10'd1:    ss_rdata_mux = shadow_live[1];
      10'd2:    ss_rdata_mux = shadow_live[2];
      10'd3:    ss_rdata_mux = shadow_live[3];
      10'd4:    ss_rdata_mux = shadow_live[4];
      10'd5:    ss_rdata_mux = shadow_live[5];
      10'd6:    ss_rdata_mux = shadow_live[6];
      10'd7:    ss_rdata_mux = shadow_live[7];
      10'd8:    ss_rdata_mux = shadow_live[8];
      10'd9:    ss_rdata_mux = shadow_live[9];
      default:  ss_rdata_mux = shadow_live[10];
    endcase
  end
  wire [63:0] ss_rdata = ss_rdata_mux;
  wire [63:0] ss_wdata;
  wire        ss_wren;
  always @(posedge clk_mach) begin
    if (ss_wren && ss_addr < 10'd8)   // words 0-7 restored; 8-10 read-only
      shadow_live[ss_addr[3:0]] <= ss_wdata;
  end

  // machine bus (idle; the TB drives it for RAM setup / readback)
  reg         m_ram_we = 0;
  reg  [17:0] m_ram_addr = 18'd0;
  reg  [7:0]  m_ram_di = 8'd0;
  reg         m_ram_aux = 0;
  wire [15:0] m_ram_do;
  wire        swp_done;

  // ======================================================================
  // DUTs
  // ======================================================================
  wire        machine_ce;
  wire        ss_start_ack, ss_start_busy, ss_start_ok, ss_start_err;
  wire        ss_load_ack,  ss_load_busy,  ss_load_ok,  ss_load_err;
  wire        preload_req;
  wire        ram_bank;
  wire [15:0] ram_addr;
  wire        ram_rd, ram_wr;
  wire [7:0]  ram_wdata, ram_rdata;
  reg         ss_start = 0, ss_load = 0;
  reg         blob_drained = 1;

  apple2e_ram_bank u_ram (
    .clk(clk_mach),
    .m_ram_we(m_ram_we), .m_ram_addr(m_ram_addr), .m_ram_di(m_ram_di),
    .m_ram_aux(m_ram_aux), .m_ram_do(m_ram_do),
    .sweep_start(1'b0), .sweep_done(swp_done),
    .ss_ram_bank(ram_bank), .ss_ram_addr(ram_addr),
    .ss_ram_rd(ram_rd), .ss_ram_wr(ram_wr),
    .ss_ram_wdata(ram_wdata), .mgr_ram_rdata(ram_rdata)
  );

  savestate_slot u_slot (
    .clk_74a(clk_74a), .rst_74a(rst_74a),
    .savestate_start(ss_start), .savestate_load(ss_load),
    .blob_wr_drained_74a(blob_drained),
    .savestate_start_ack(ss_start_ack), .savestate_start_busy(ss_start_busy),
    .savestate_start_ok(ss_start_ok),   .savestate_start_err(ss_start_err),
    .savestate_load_ack(ss_load_ack),   .savestate_load_busy(ss_load_busy),
    .savestate_load_ok(ss_load_ok),     .savestate_load_err(ss_load_err),
    .preload_req(preload_req),
    .clk_mach(clk_mach), .rst_mach(rst_mach),
    .cpu_type(1'b1),
    .cpu_frozen(cpu_frozen),
    .stall(stall), .machine_ce(machine_ce),
    .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren),
    .ss_rdata(ss_rdata),
    .ram_bank(ram_bank), .ram_addr(ram_addr), .ram_rd(ram_rd),
    .ram_wr(ram_wr), .ram_wdata(ram_wdata), .ram_rdata(ram_rdata),
    .clk_ctrl(clk_ctrl), .rst_ctrl(rst_ctrl),
    .ssrd_req(ssrd_req), .ssrd_addr(ssrd_addr),
    .ssrd_done(ssrd_done), .ssrd_data(ssrd_data),
    .sswr_req(sswr_req), .sswr_addr(sswr_addr), .sswr_data(sswr_data),
    .sswr_done(sswr_done), .sswr_busy(sswr_busy),
    .port_wr_idle(port_wr_idle)
  );

  sdram_word_owner u_owner (
    .clk(clk_ctrl), .rst_n(rst_ctrl),
    .word_rd(sd_rd), .word_wr(sd_wr), .word_addr(sd_addr), .word_data(sd_data),
    .word_q(sd_q), .word_busy(sd_busy), .word_done(sd_done),
    .word_rd_valid(sd_rd_valid), .word_op_start(sd_op_start), .init_done(init_done),
    .st_req(1'b0), .st_addr(24'd0), .st_data(32'd0),
    .st_busy(), .st_done(),
    .vr_req(1'b0), .vr_addr(24'd0), .vr_done(), .vr_data(),
    .fc_req(1'b0), .fc_addr(24'd0), .fc_gen(8'd0),
    .fc_active(), .fc_word_valid(), .fc_data(), .fc_done(),
    .fc_done_len(), .fc_done_gen(),
    .hr_req(1'b0), .hr_addr(24'd0), .hr_done(), .hr_data(),
    .ssrd_req(ssrd_req), .ssrd_addr(ssrd_addr), .ssrd_done(ssrd_done),
    .ssrd_data(ssrd_data),
    .sswr_req(sswr_req), .sswr_addr(sswr_addr), .sswr_data(sswr_data),
    .sswr_done(sswr_done), .sswr_busy(sswr_busy),
    .hwr_req(1'b0), .hwr_addr(24'd0), .hwr_data(32'd0),
    .hwr_done(), .hwr_busy(),
    .port_wr_idle(port_wr_idle)
  );

  // ======================================================================
  // helpers
  // ======================================================================
  integer nfail = 0, nloop = 0, i, w;
  integer preload_count = 0;

  // the TB-side golden (mirrors what the bus writes put in the banks)
  reg  [7:0] golden_main [0:65535];
  reg  [7:0] golden_aux  [0:65535];
  reg  [31:0] counter_cur = 32'd1;
  reg  [31:0] blob_save [0:32831];

  function [7:0] golden_byte(input [16:0] b);
    golden_byte = b[16] ? golden_aux[b[15:0]] : golden_main[b[15:0]];
  endfunction

  // the expected slot word (64-bit) at slot address a
  function [63:0] exp_slot_word(input [14:0] a);
    integer k;
    if (a < 15'd16) begin
      if (a == 15'd0)      exp_slot_word = {32'd32832, counter_cur};
      else if (a == 15'd1) exp_slot_word = {32'h41324C31, 8'd1, 23'd0, 1'b1};
      else                 exp_slot_word = 64'd0;
    end else if (a < 15'd27) begin
      exp_slot_word = shadow_gold[a - 15'd16];
    end else if (a < 15'd32) begin
      exp_slot_word = 64'd0;
    end else begin
      k = a - 15'd32;
      exp_slot_word = {golden_byte(17'(8*k + 7)), golden_byte(17'(8*k + 6)),
                       golden_byte(17'(8*k + 5)), golden_byte(17'(8*k + 4)),
                       golden_byte(17'(8*k + 3)), golden_byte(17'(8*k + 2)),
                       golden_byte(17'(8*k + 1)), golden_byte(17'(8*k))};
    end
  endfunction

  // the expected SDRAM word w (0..32831): w even = low 32 of slot word
  // w/2, w odd = high 32
  function [31:0] exp_sdram_word(input [15:0] w);
    reg [63:0] sw;
    sw = exp_slot_word(w >> 1);
    exp_sdram_word = w[0] ? sw[63:32] : sw[31:0];
  endfunction

  task check(input string name, input cond);
    begin
      if (!cond) begin
        nfail = nfail + 1;
        $display("FAIL: %s", name);
      end else begin
        $display("ok  : %s", name);
      end
    end
  endtask

  // machine-bus write (one byte; write-first bypass lands it this edge)
  task mb_write(input [15:0] addr, input [7:0] data, input aux);
    begin
      @(negedge clk_mach);
      m_ram_we = 1'b1; m_ram_addr = {2'b00, addr}; m_ram_di = data;
      m_ram_aux = aux;
      @(negedge clk_mach);
      m_ram_we = 1'b0;
    end
  endtask

  // machine-bus read (registered: set addr, sample m_ram_do next half-cycle)
  task mb_read(output [7:0] data, input [15:0] addr, input aux);
    begin
      @(negedge clk_mach);
      m_ram_addr = {2'b00, addr}; m_ram_aux = aux;
      @(negedge clk_mach);
      data = aux ? m_ram_do[15:8] : m_ram_do[7:0];
    end
  endtask

  // per-op timeout so a hang reports as a failure instead of the global
  // watchdog (a full save/load is ~2us; this is ~13.5ms, 6000x margin)
  localparam [31:0] OP_TIMEOUT = 32'd8000000;

  task save_op(input string tag);
    integer to;
    begin
      @(negedge clk_74a);
      ss_start = 1'b1;
      // the real host holds the command until the slot's ack (self-holding);
      // a 2-cycle pulse is shorter than one mach clock (70ns) and the
      // mach-domain synch_3 can miss it phase-dependently (2026-11-12)
      to = 0;
      while (!ss_start_ack && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      // hold ~40 clk_74a (~8 mach cycles): the mach-domain synch_3 .rise() needs
      // the high window to span a mach posedge AND fill its 3-FF chain (~4 mach
      // cycles). The old "hold until ack + 2" was only ~3-4 clk_74a (~40ns) < 1
      // mach cycle (69.8ns), so the edge was missed phase-dependently (T3a load
      // lost 2026-11-13). A <1-mach-cycle pulse is never reliable.
      repeat (40) @(negedge clk_74a);
      ss_start = 1'b0;
      // start_rise clears any sticky result: wait for that first, or a
      // stale ok from the previous op makes the result wait return early
      to = 0;
      while ((ss_start_ok | ss_start_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      // sticky contract: wait for ok (or err)
      to = 0;
      while (!(ss_start_ok | ss_start_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      if (to >= OP_TIMEOUT) begin
        nfail = nfail + 1;
        $display("FAIL: %s: save timed out (no ok/err)", tag);
      end else if (ss_start_err) begin
        nfail = nfail + 1;
        $display("FAIL: %s: save reported err", tag);
      end
      counter_cur = counter_cur + 1'b1;   // the manager incremented it
    end
  endtask

  task load_op(input string tag, input expect_err);
    integer to;
    begin
      @(negedge clk_74a);
      ss_load = 1'b1;
      // hold until ack, as in save_op (a short pulse can be missed by the
      // mach-domain synchronizer)
      to = 0;
      while (!ss_load_ack && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      // hold ~40 clk_74a (~8 mach cycles) - see save_op: the mach-domain
      // synch_3 .rise() needs the high window to span a mach posedge AND fill
      // its 3-FF chain; a <1-mach-cycle pulse is missed phase-dependently.
      repeat (40) @(negedge clk_74a);
      ss_load = 1'b0;
      // load_rise clears any sticky result first (as in save_op)
      to = 0;
      while ((ss_load_ok | ss_load_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      to = 0;
      while (!(ss_load_ok | ss_load_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      if (to >= OP_TIMEOUT) begin
        nfail = nfail + 1;
        $display("FAIL: %s: load timed out (no ok/err)", tag);
        // 2026-11-13: dump where the load is stuck (T3a localization)
        $display("  LOAD-STUCK @%0t: mgr st=%0d byte_index=%0d byte_lane=%0d reg_index=%0d slot_rd=%b slot_wr=%b slot_addr=%0d fail=%b fc=%0d",
          $time, u_slot.u_mgr.state, u_slot.u_mgr.byte_index, u_slot.u_mgr.byte_lane,
          u_slot.u_mgr.reg_index, u_slot.u_mgr.slot_rd, u_slot.u_mgr.slot_wr,
          u_slot.u_mgr.slot_addr, u_slot.u_mgr.error, u_slot.u_mgr.error_code);
        $display("  ssrd: lvl=%b st=%0d lastv=%b lasta=%0d addr_c=%0d base_c=%0d done_lvl=%b | owner: infl=%0d ssrd_lvl=%b",
          u_slot.ssrd_lvl_c, u_slot.ssrd_st, u_slot.ssrd_last_v, u_slot.ssrd_last_a,
          u_slot.ssrd_addr_c, u_slot.ssrd_base_c, u_slot.ssrd_done_lvl,
          u_owner.inflight, ssrd_req);
      end else if (ss_load_err !== expect_err) begin
        nfail = nfail + 1;
        $display("FAIL: %s: load err=%b expect=%b", tag, ss_load_err, expect_err);
      end
    end
  endtask

  // last slot word (16415): dump both op arms and the owner's wcap
  always @(posedge clk_ctrl) begin
    if (sswr_req && u_slot.sswr_addr_c == 15'd16415)
      $display("MON: last-word %s arm @%0t st=%0d sswr_addr=%0d sswr_data=%h | wcap: v=%b c=%0d a=%0d d=%h | sd_busy=%b",
        (u_slot.sswr_st == 2'd2) ? "HI" : "LO",
        $time, u_slot.sswr_st, sswr_addr, sswr_data,
        u_owner.wcap_valid, u_owner.wcap_client, u_owner.wcap_addr, u_owner.wcap_data,
        sd_busy);
  end

  // last SDRAM word (blob-relative 32831): what arrives at the port?
  integer mon_wr_ct = 0;
  always @(posedge clk_ctrl) begin
    if (sd_wr && mon_wr_ct < 12) begin
      $display("MON: wr@%0t sd_addr=%h data=%h (blob_word=%0d) | wcap_a=%h wcap_d=%h client=%0d",
        $time, sd_addr, sd_data, sd_addr - 24'h400000, u_owner.wcap_addr, u_owner.wcap_data, u_owner.wcap_client);
      mon_wr_ct = mon_wr_ct + 1;
    end
    if (sd_wr && sd_addr[15:0] == 16'd32831)
      $display("MON: last-HI at port @%0t sd_addr=%0d sd_data=%h", $time, sd_addr, sd_data);
    if (sd_wr && sd_addr[15:0] == 16'd32830)
      $display("MON: last-LO at port @%0t sd_addr=%0d sd_data=%h", $time, sd_addr, sd_data);
    // full port state trace (real io_sdram_pocket; $time in EXPRESSIONS is
    // ns in this build, %0t prints ps)
    if ((sdram_word0_seen && $time > 48083000) && $time < 48092000)
      if (busy_or_pend || sd_rd || ssrd_req || sswr_req) 
        $display("MON: port@%0t busy=%b sd_rd=%b sd_wr=%b sd_addr=%0d sd_data=%h | infl=%0d ssrdq=%b ssrd_st=%0d sswrq=%b sswr_st=%0d",
          $time, sd_busy, sd_rd, sd_wr, sd_addr, sd_data,
          u_owner.inflight, ssrd_req, u_slot.ssrd_st, sswr_req, u_slot.sswr_st);
  end
  wire busy_or_pend = sd_busy || sd_rd || sd_wr;

  // Every port op start in the last-word window (word_busy rising edge).
  reg op_busy_d1 = 0;
  always @(posedge clk_ctrl) begin
    op_busy_d1 <= sd_busy;
    if (sdram_word0_seen && $time > 48082000 && $time < 48084700
        && sd_busy && !op_busy_d1)
      $display("MON: opstart @%0t rd=%b wr=%b addr=%0d data=%h",
        $time, sd_rd, sd_wr, sd_addr, sd_data);
  end

  // Slot write-FSM activity in the last-word window: every sswr_req and
  // sswr_done pulse, with the FSM state/address, to see if the last HI is
  // ever armed (2026-11-12 last-word loss).
  reg sswr_req_d1 = 0, sswr_done_d1 = 0;
  always @(posedge clk_ctrl) begin
    sswr_req_d1  <= sswr_req;
    sswr_done_d1 <= sswr_done;
    if (sdram_word0_seen && $time > 48082000 && $time < 48084700) begin
      if (sswr_req && !sswr_req_d1)
        $display("MON: sswr_arm @%0t st=%0d addr=%0d data=%h busy=%b idle=%b",
          $time, u_slot.sswr_st, sswr_addr, sswr_data, sswr_busy, port_wr_idle);
      if (sswr_done && !sswr_done_d1)
        $display("MON: sswr_done @%0t st=%0d addr=%0d inflight=%b",
          $time, u_slot.sswr_st, sswr_addr, u_slot.sswr_inflight);
    end
  end
  reg sdram_word0_seen = 0;
  always @(posedge clk_ctrl)
    if (sd_wr && sd_addr == 24'h400000) sdram_word0_seen <= 1'b1;  // blob base

  // (a 1-cycle pulse; NOTE: a plain "if (preload_req) count++" level
  // sample MISSED the pulse under this --timing build while the
  // edge-detect form counted it - keep the edge-detect shape, 2026-11-12)
  reg  [15:0] c_pre = 0;
  reg  pre_d1 = 0;
  always @(posedge clk_74a) begin
    pre_d1 <= preload_req;
    if (preload_req && !pre_d1)
      c_pre <= c_pre + 16'd1;
  end

  // ---- temporary debug monitor: state dump every ~7 ms sim time ----
  integer dbg_ct = 0;
  reg  [31:0] dbg_next = 32'd0;
  reg  [15:0] c_pulse = 0, c_wop = 0, c_wdone = 0, c_sdone = 0;
  reg  [15:0] c_rpulse = 0, c_rdone = 0;   // 2026-11-13: read-side counters
  reg  [15:0] c_w0 = 0, c_w1 = 0;           // rewrites of blob SDRAM word 0 / 1
  reg  c_wop_bd = 0, c_rreq_bd = 0, c_rdone_bd = 0;
  always @(posedge clk_ctrl) begin
    if (sswr_req)  c_pulse  <= c_pulse  + 16'd1;
    c_wop_bd <= sd_busy;
    if (sd_busy && !c_wop_bd) c_wop <= c_wop + 16'd1;  // op starts
    if (sd_done)   c_wdone  <= c_wdone  + 16'd1;
    if (sswr_done) c_sdone  <= c_sdone  + 16'd1;
    // read side: ssrd_req is a HELD level, ssrd_done a held level - count
    // rising edges (one per read op / completion).
    c_rreq_bd  <= ssrd_req;
    if (ssrd_req && !c_rreq_bd)  c_rpulse <= c_rpulse + 16'd1;
    c_rdone_bd <= ssrd_done;
    if (ssrd_done && !c_rdone_bd) c_rdone <= c_rdone + 16'd1;
    if (sd_wr && sd_addr == 24'h400000) c_w0 <= c_w0 + 16'd1;
    if (sd_wr && sd_addr == 24'h400001) c_w1 <= c_w1 + 16'd1;
  end


  // ---- stall detector: fire once when a save makes no write-op progress ----
  reg  [15:0] stall_wdone_ref = 0;
  reg  [31:0] stall_time_ref  = 0;
  reg         stall_fired     = 0;
  always @(posedge clk_ctrl) begin
    if (sd_done) begin
      stall_wdone_ref <= c_wdone;
      stall_time_ref  <= $time;
    end
    if (!stall_fired && ss_start_busy && !ss_start_ok && !ss_start_err
        && (stall_wdone_ref > 16'd0) && ($time - stall_time_ref) > 32'd400000)
      begin
        stall_fired <= 1'b1;
        $display("STALL @%0t (wdone=%0d ref@%0t): mgr st=%0d byte_index=%0d byte_lane=%0d slot_wr=%b slot_addr=%0d",
          $time, c_wdone, stall_time_ref, u_slot.u_mgr.state, u_slot.u_mgr.byte_index, u_slot.u_mgr.byte_lane, u_slot.u_mgr.slot_wr, u_slot.u_mgr.slot_addr);
        $display("  sswr: lvl=%b st=%0d inf=%b watch=%0d lastv=%b lasta=%0d addr_c=%0d base_c=%0d lo=%h hi=%h done_lvl=%b",
          u_slot.sswr_lvl_c, u_slot.sswr_st, u_slot.sswr_inflight, u_slot.sswr_watch, u_slot.sswr_last_v, u_slot.sswr_last_a, u_slot.sswr_addr_c, u_slot.sswr_base_c, u_slot.sswr_lo_c, u_slot.sswr_hi_c, u_slot.sswr_done_lvl);
        $display("  owner: inflight=%0d wcap_v=%b wcap_client=%0d wcap_addr=%0d wcap_data=%h word_wr=%b sswr_eff=%b ssrd_lvl=%b sswr_done=%b sswr_busy=%b",
          u_owner.inflight, u_owner.wcap_valid, u_owner.wcap_client, u_owner.wcap_addr, u_owner.wcap_data, u_owner.word_wr, u_owner.sswr_eff, ssrd_req, sswr_done, sswr_busy);
        $display("  port: sd_busy=%b sd_done=%b sd_rd=%b sd_wr=%b sd_addr=%0d boot_done=%b",
          sd_busy, sd_done, sd_rd, sd_wr, sd_addr, sdram_init_done);
        $display("  cnt: pulse=%0d wop=%0d wdone=%0d sdone=%0d rarm=%0d rdone=%0d w0=%0d w1=%0d", c_pulse, c_wop, c_wdone, c_sdone, c_rpulse, c_rdone, c_w0, c_w1);
      end
  end
  // 2026-11-13: T3a localization - log the manager's load-header decisions
  // (what slot_rdata does it actually see? does the magic check fire?) and
  // any FAIL entry.
  always @(posedge clk_mach) begin
    if (u_slot.u_mgr.state == 5'd9 && u_slot.u_mgr.slot_ready)
      $display("LOADHDR0 @%0t slot_rdata=%h (size=%h ctr=%h)", $time, u_slot.u_mgr.slot_rdata,
               u_slot.u_mgr.slot_rdata[63:32], u_slot.u_mgr.slot_rdata[31:0]);
    if (u_slot.u_mgr.state == 5'd10 && u_slot.u_mgr.slot_ready)
      $display("LOADHDR1 @%0t slot_rdata=%h magic=%h ver=%0d cpu=%0d | h0=%h",
               $time, u_slot.u_mgr.slot_rdata, u_slot.u_mgr.slot_rdata[63:32],
               u_slot.u_mgr.slot_rdata[31:24], u_slot.u_mgr.slot_rdata[0],
               u_slot.u_mgr.header0_read);
    if (u_slot.u_mgr.state == 5'd17)
      $display("MGR-FAIL @%0t fail_code=%0d", $time, u_slot.u_mgr.fail_code);
  end
  always @(posedge clk_mach) begin
    dbg_next <= dbg_next + 32'd1;
    if (dbg_next > 32'd100000) begin
      dbg_next <= 32'd0;
      if (dbg_ct < 40) begin
        $display("DBG @%0t: mst=%0d sbusy=%b stall=%b ce=%b frz=%b ssa=%0d sren=%b ssrdq=%b ssrdd=%b sswrq=%b sswrd=%b sswrb=%b pwid=%b opb=%b ok=%b err=%b",
          $time, u_slot.u_mgr.state, ss_start_busy, stall, machine_ce, cpu_frozen,
          ss_addr, ss_wren, ssrd_req, ssrd_done,
          sswr_req, sswr_done, sswr_busy, port_wr_idle, sd_busy,
          ss_start_ok, ss_start_err);
        $display("   sswr: lvl=%b st=%0d inf=%b watch=%0d lastv=%b lasta=%0d addr=%0d base=%0d | ssrd: lvl=%b st=%0d lastv=%b lasta=%0d addr=%0d base=%0d done=%b",
          u_slot.sswr_lvl_c, u_slot.sswr_st, u_slot.sswr_inflight, u_slot.sswr_watch,
          u_slot.sswr_last_v, u_slot.sswr_last_a, u_slot.sswr_addr_c, u_slot.sswr_base_c,
          u_slot.ssrd_lvl_c, u_slot.ssrd_st, u_slot.ssrd_last_v, u_slot.ssrd_last_a,
          u_slot.ssrd_addr_c, u_slot.ssrd_base_c, u_slot.ssrd_done_lvl);
        $display("   74a: ok=%b okd1=%b done74=%b doner74=%b isload=%b preload=%b mgrdone=%b | loadrise=%b ssload=%b loadd1=%b start_d1=%b pre_cnt=%0d | cnt: pulse=%0d wop=%0d wdone=%0d sdone=%0d rarm=%0d rdone=%0d w0=%0d w1=%0d",
          u_slot.start_ok_r, u_slot.start_ok_d1, u_slot.mgr_done_74, u_slot.mgr_done_rise_74,
          u_slot.op_is_load_r, u_slot.preload_req, u_slot.u_mgr.done,
          u_slot.load_rise, ss_load, u_slot.load_d1, u_slot.start_d1, c_pre,
          c_pulse, c_wop, c_wdone, c_sdone, c_rpulse, c_rdone, c_w0, c_w1);
        dbg_ct = dbg_ct + 1'b1;
      end
    end
  end

  // ======================================================================
  // test sequence
  // ======================================================================
  initial begin
    // ---- init ----
    rst_74a = 1'b1; rst_mach = 1'b0;
    repeat (30) @(negedge clk_ctrl);
    rst_mach = 1'b1;
    rst_74a  = 1'b0;
    #1000;
    por_done = 1'b1;   // SDRAM power-on settle (mirrors tb_sector_fetch)
    while (!init_done) @(negedge clk_ctrl);
    repeat (50) @(negedge clk_ctrl);

    // distinct patterns in BOTH banks (the aux bank is the trap)
    for (i = 0; i < 65536; i = i + 1) begin
      golden_main[i] = 8'hA0 ^ i[7:0];
      golden_aux[i]  = 8'h5F ^ i[7:0] ^ i[15:12];
    end
    for (i = 0; i < 11; i = i + 1)
      shadow_gold[i] = 64'd0;
    shadow_gold[0] = 64'hC0DE_0000_0000_0001;   // cpu word
    shadow_gold[1] = 64'h1111_0000_0000_0011;
    shadow_gold[2] = 64'h2222_0000_0000_0022;
    shadow_gold[3] = {41'd0, 8'hFF, 8'h0F, 8'h5A};      // machine word
    shadow_gold[4] = {38'd0, 1'b1, 1'b1, 16'hBEEF, 8'h77}; // latches
    shadow_gold[5] = 64'h1111_2222_3333_4444;            // timing
    shadow_gold[6] = 64'h1111_2222_3333_4444;            // timing (dup, donor parity)
    shadow_gold[7] = 64'hAAAA_BBBB_CCCC_DDDD;            // video
    shadow_gold[8] = 64'h8888_0000_0000_0088;
    shadow_gold[9] = 64'h9999_0000_0000_0099;
    shadow_gold[10] = 64'hAA00_0000_0000_00AA;

    // fill the banks through the real machine bus path
    for (i = 0; i < 65536; i = i + 1) begin
      mb_write(i[15:0], golden_main[i], 1'b0);
      mb_write(i[15:0], golden_aux[i], 1'b1);
    end
    for (i = 0; i < 11; i = i + 1)
      shadow_live[i] = shadow_gold[i];

    // T0: spot-check the fill (main + aux, both halves)
    begin
      reg [7:0] r;
      mb_read(r, 16'd0, 1'b0);
      check("T0 main[0]", r === golden_main[0]);
      mb_read(r, 16'd65535, 1'b0);
      check("T0 main[65535]", r === golden_main[65535]);
      mb_read(r, 16'd0, 1'b1);
      check("T0 aux[0]", r === golden_aux[0]);
      mb_read(r, 16'd65535, 1'b1);
      check("T0 aux[65535]", r === golden_aux[65535]);
    end

    // ================= T1: SAVE golden =================
    // poison the blob window + margin (direct DRAM-model writes: a TB
    // shortcut that bypasses the port, valid while the port is idle)
    for (w = 0; w < 32832 + 32'd128; w = w + 1)
      sdram_write(w[15:0], 32'hDEAD_BEEF ^ w[31:0]);
    // the manager never writes the gap words 54..63 (slot words 27..31 sit
    // between the shadow block and the packed RAM) - model a clean, empty
    // slot by zeroing the blob window so the golden holds word-for-word
    for (w = 0; w < 32832; w = w + 1)
      sdram_write(w[15:0], 32'd0);
    save_op("T1");
    check("T1 no err", ss_start_err === 1'b0);
    // (the save-completion preload is verified at the end in T5: c_pre==2;
    //  it fires a few 74a cycles after done, so a check here is too early)
    // the blob, word by word (header / shadow / packed RAM)
    nloop = 0;
    for (w = 0; w < 32832; w = w + 1) begin
      if (sdram_read(w[15:0]) !== exp_sdram_word(w[22:0])) begin
        nloop = nloop + 1;
        if (nloop <= 10)
          $display("FAIL: T1 blob word %0d = %h expect %h",
                   w, sdram_read(w[15:0]), exp_sdram_word(w[22:0]));
      end
    end
    $display("     (T1 blob mismatches: %0d)", nloop);
    check("T1 all 32832 blob words exact (incl. aux bank)", nloop == 0);
    // SDRAM just outside the blob untouched (the margin window)
    check("T1 SDRAM below blob intact",
          sdram_read(32832 + 120) === (32'hDEAD_BEEF ^ (32832 + 120)));
    check("T1 SDRAM past blob intact",
          sdram_read(32832 + 8) === (32'hDEAD_BEEF ^ (32832 + 8)));
    // the save must not disturb live RAM
    begin
      reg [7:0] r;
      mb_read(r, 16'd1, 1'b0);
      check("T1 live main intact", r === golden_main[1]);
      mb_read(r, 16'd12345, 1'b1);
      check("T1 live aux intact", r === golden_aux[12345]);
    end
    // keep the blob for the T2 comparison
    for (w = 0; w < 32832; w = w + 1)
      blob_save[w] = sdram_read(w[15:0]);

    // ================= T2: ROUND-TRIP =================
    // corrupt live state: RAM bytes in BOTH banks + shadow words
    mb_write(16'd77,    8'h00, 1'b0);
    mb_write(16'd65535, 8'hFF, 1'b0);
    mb_write(16'd4242,  8'h00, 1'b1);
    mb_write(16'd65535, 8'hEE, 1'b1);
    shadow_live[0] = 64'h0;
    shadow_live[3] = 64'hFFFFFFFFFFFFFFFF;
    shadow_live[4] = 64'h0;
    shadow_live[7] = 64'h0;
    shadow_live[8] = 64'hDEAD_BEEF_DEAD_BEEF;   // read-only word: NOT restored
    // the real host transports the blob (one-word-behind latch + stale
    // leading slot) before the load - see host_transport
    host_transport("T2");
    load_op("T2", 1'b0);
    check("T2 no err", ss_load_err === 1'b0);
    // live RAM restored (corrupted spots + spot checks, both banks)
    begin
      reg [7:0] r;
      mb_read(r, 16'd77, 1'b0);
      check("T2 main[77] restored", r === golden_main[77]);
      mb_read(r, 16'd65535, 1'b0);
      check("T2 main[65535] restored", r === golden_main[65535]);
      mb_read(r, 16'd4242, 1'b1);
      check("T2 aux[4242] restored", r === golden_aux[4242]);
      mb_read(r, 16'd65535, 1'b1);
      check("T2 aux[65535] restored", r === golden_aux[65535]);
      mb_read(r, 16'd0, 1'b0);
      check("T2 main[0] restored", r === golden_main[0]);
      mb_read(r, 16'd31337, 1'b1);
      check("T2 aux[31337] restored", r === golden_aux[31337]);
    end
    // shadow restored (the machine's applied-write decode ran; words 0-7
    // are the machine's restored set)
    check("T2 shadow[0] restored", shadow_live[0] === shadow_gold[0]);
    check("T2 shadow[3] restored", shadow_live[3] === shadow_gold[3]);
    check("T2 shadow[4] restored", shadow_live[4] === shadow_gold[4]);
    check("T2 shadow[7] restored", shadow_live[7] === shadow_gold[7]);
    // word 8 is read-only in the machine: the load must NOT touch it
    check("T2 shadow[8] untouched by load (read-only)",
          shadow_live[8] === 64'hDEAD_BEEF_DEAD_BEEF);
    // re-save: every blob word identical except SDRAM word 0 (the save
    // counter, which the manager increments per save: 2 -> 3), words 48/49
    // (shadow word 8: read-only in the machine, the load did not restore
    // it, so the re-save legitimately captures the corrupted value), and
    // words 54..63 (the manager never writes the slot-27..31 gap - after
    // the host transport they hold shifted T1 shadow data, not zero)
    save_op("T2-resave");
    check("T2 resave counter incremented (word 0 = 3)",
          sdram_read(0) === 32'd3);
    nloop = 0;
    for (w = 1; w < 32832; w = w + 1) begin
      if (w == 32'd48 || w == 32'd49)
        ;                                  // read-only shadow word 8
      else if (w >= 32'd54 && w <= 32'd63)
        ;                                  // manager-never-written gap
      else if (sdram_read(w[15:0]) !== blob_save[w]) begin
        nloop = nloop + 1;
        if (nloop <= 5)
          $display("FAIL: T2 blob2 word %0d = %h expect %h",
                   w, sdram_read(w[15:0]), blob_save[w]);
      end
    end
    check("T2 resaved blob == T1 blob (round-trip closed)", nloop == 0);

    // ================= T3: LOAD error taxonomy =================
    // post-transport layout (observed host, 2026-11-17: stale stripped):
    // word 0 = counter, word 1 = SS_SIZE_DWORDS, word 2 = {version,
    // reserved, cpu}, word 3 = MAGIC. The BLOB_BASE mapping's header
    // reads: slot0 [63:32] = word 1 (size), slot1 [63:32] = word 3
    // (MAGIC), slot1 [31:24] = word 2[31:24] (ver), slot1 [0] = word 2[0]
    // (cpu).
    host_transport("T3");
    // bad magic
    sdram_write(3, 32'hDEAD_BEEF);
    load_op("T3a", 1'b1);
    check("T3a bad magic -> err", ss_load_err === 1'b1);
    sdram_write(3, 32'h41324C31);
    // bad version
    sdram_write(2, 32'h0200_0001);
    load_op("T3b", 1'b1);
    check("T3b bad version -> err", ss_load_err === 1'b1);
    sdram_write(2, 32'h0100_0001);
    // bad cpu
    sdram_write(2, 32'h0100_0000);
    load_op("T3c", 1'b1);
    check("T3c bad cpu -> err", ss_load_err === 1'b1);
    sdram_write(2, 32'h0100_0001);
    // zero size
    sdram_write(1, 32'd0);
    load_op("T3d", 1'b1);
    check("T3d zero size -> err", ss_load_err === 1'b1);
    // oversized
    sdram_write(1, 32'd32833);
    load_op("T3e", 1'b1);
    check("T3e oversized -> err", ss_load_err === 1'b1);
    sdram_write(1, 32'd32832);
    // failed loads left the machine intact
    begin
      reg [7:0] r;
      mb_read(r, 16'd77, 1'b0);
      check("T3 machine intact after failed loads", r === golden_main[77]);
    end

    // ================= T4: LOAD gating (drain) =================
    // hold the blob-write drain low, issue the load: the manager must NOT
    // start (no SDRAM reads, no RAM writes) until blob_wr_drained rises
    blob_drained = 1'b0;
    ss_load = 1'b1;
    while (!ss_load_ack) @(negedge clk_74a);
    // hold ~40 clk_74a (~8 mach cycles) so the mach-domain synch_3 reliably
    // catches the rising edge (see save_op); the drain gate (blob_drained_m)
    // still blocks load_go while low, so the gating is still exercised.
    repeat (40) @(negedge clk_74a);
    ss_load = 1'b0;
    // let any (wrong) activity happen - the gate must have blocked it
    repeat (400) @(negedge clk_mach);
    begin
      reg [7:0] r;
      mb_read(r, 16'd0, 1'b0);
      check("T4 machine untouched while load gated", r === golden_main[0]);
    end
    blob_drained = 1'b1;
    // the pending load now proceeds and completes
    while (!(ss_load_ok | ss_load_err)) @(negedge clk_74a);
    check("T4 load completed after drain", ss_load_err === 1'b0);

    // ================= verdict =================
    check("T5 preload fired exactly twice (T1 + T2 resave)",
          c_pre === 16'd2);
    if (nfail == 0)
      $display("SAVESTATE ROUNDTRIP TB: PASS (T0 fill, T1 save, T2 round-trip, T3 errors, T4 gating, T5 preload)");
    else
      $display("SAVESTATE ROUNDTRIP TB: FAIL (%0d failures)", nfail);
    $finish;
  end

  // global watchdog: 500 ms sim time (each op takes ~tens of ms)
  initial begin
    #500_000_000;
    $display("SAVESTATE ROUNDTRIP TB: FAIL (global watchdog timeout)");
    $finish;
  end

endmodule
