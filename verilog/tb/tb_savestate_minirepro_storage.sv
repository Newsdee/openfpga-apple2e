//
// tb_savestate_minirepro.sv - wedge mechanism hunt (2026-11-15)
//
// EXPERT_BRIEF_SAVESTATE_MINIREPRO_TB_2026-11-15.md (approved spec, §7
// amendments A1-A4). Parent: EXPERT_BRIEF_SAVESTATE_READWEDGE_2026-11-15.md.
//
// DUT cut (all REAL, unmodified; no sdram_storage wrapper - its M0 engine is
// replaced by scripts, and it ties vr/fc internally which would kill the
// multi-client gate):
//   io_sdram_pocket  u_port  (word ports <- owner; raw burst ports tied OFF,
//                            exactly as sdram_storage v705-724 ships them)
//   sdram_word_owner u_owner (clients: st/vr/fc <- scripts; hr/hwr <-> bridge;
//                            ssrd/sswr <-> slot; port_wr_idle -> slot+bridge)
//   savestate_bridge u_bridge (host side <- scripted FIFO-paced host)
//   savestate_slot   u_slot  (includes the donor manager, u_slot.u_mgr)
//   apple2e_ram_bank u_ram   (the manager's fake RAM; 1-cycle m_ram_do)
//   tb_dram_model    m0      (same model/config as tb_savestate_integration)
//
// FINDING baked into the gate design (verified in sdram_storage.v): the raw
// burst ports are UNUSED in shipping (".burst_rd(1'b0) ... word port serves
// host load + verifier + M1 fetch"). So "disk bursts" (parent §6.1) are, in
// the shipping config, fc/st WORD-client traffic - G1a scripts fc sectors
// (M1 fetch shape) + st sectors (M0 store shape), not raw brdq/bwq ops.
//
// Gates (see brief §3/§7):
//   G0 : per-client sanity (each client alone, N=1000)
//   G1a: full replay (save, FIFO-paced 32,832-word host rd burst, FIFO-paced
//        transport write, load, save#2) WITH disk fc/st activity (phase knob)
//   G1b: same, disk OFF (control)
//   G2 : G1b shape + patterned vr (second read client)
//   G4 : fuzz (25 seeds: phase/period/cadence random)
//   G5 : hwr write-race class (FIFO-paced write burst under vr) + wcap ledger
//        + final memory compare (separate PASS/FAIL class, brief §7 Q5)
//
// A wedge is NOT a TB crash: the stuck detector (ss_ledger) reports it and
// the gate records WEDGE + the ledger file. With the current (unfixed) DUT
// the expectation is that G1a/G1b/G2 WEDGE like the integration TB's G5/G6 -
// the point of this run is the ledger data (fall-latch fingerprint,
// op-start/done attribution, hwr ledger), not a green line.
//
// Runtime knobs (plusargs): +GATE=n (0-5; 9 = full ladder, default),
// +NBLOB=n (host burst word count, default 32832; fast mode: 4096),
// +SEEDS=n (G4 seed count, default 25).
//
// Build + run: ../run_tb_savestate_minirepro.sh
//
`timescale 1ns/1ps
module tb_savestate_minirepro;

  // ======================================================================
  // clocks (exact shipping-ratio config from tb_savestate_integration -
  // do not change without re-validating the DRAM model: PC2=3.756 is a
  // HALF period; the bridge's 8-cycle ret-pulse window was sized for it)
  // ======================================================================
  reg clk_74a  = 1'b0;
  reg clk_mach = 1'b0;
  reg clk_ctrl = 1'b0;
  initial begin #5.113;  forever #6.734  clk_74a  = ~clk_74a; end // 74.25 MHz
  initial begin #21.407; forever #34.925 clk_mach = ~clk_mach; end // 14.318 MHz
  localparam real PC2    = 3.756;
  localparam real PHASE2 = 3.756;
  reg chip_clk = 1'b0, clk90 = 1'b0;
  initial begin #4000;                forever #(PC2/2.0) clk_ctrl = ~clk_ctrl; end
  initial begin #4000; #PHASE2;       forever #(PC2/2.0) chip_clk = ~chip_clk; end
  initial begin #4000; #(PHASE2 + PC2/2.0); forever #(PC2/2.0) clk90 = ~clk90; end

  // ======================================================================
  // resets (integration: rst_74a active-HIGH; rst_ctrl = ~rst_74a; the PORT
  // takes reset_n tied 1'b1 - its internal boot FSM owns power-on, exactly
  // as sdram_storage v700 wires it)
  // ======================================================================
  reg  rst_74a  = 1'b1;
  wire rst_ctrl = ~rst_74a;
  reg  rst_mach = 1'b1;

  // ======================================================================
  // host window (0x40xxxxxx) - scripted host below
  // ======================================================================
  reg         bridge_rd = 1'b0;
  reg         bridge_wr = 1'b0;
  reg  [31:0] bridge_addr = 32'd0;
  reg  [31:0] bridge_wr_data = 32'd0;

  // ======================================================================
  // W1 client nets (owner <-> bridge/slot)
  // ======================================================================
  wire        ssrd_req;      wire [23:0] ssrd_addr;
  wire        ssrd_done;     wire [31:0] ssrd_data;
  wire        sswr_req;      wire [23:0] sswr_addr;
  wire [31:0] sswr_data;     wire        sswr_done, sswr_busy;
  wire        hr_req;        wire [23:0] hr_addr;
  wire        hr_done;       wire [31:0] hr_data;
  wire        hwr_req;       wire [23:0] hwr_addr;
  wire [31:0] hwr_data;      wire        hwr_done, hwr_busy;
  wire        port_wr_idle;

  // scripted machine clients (owner st/vr/fc - replace the M0 engine)
  reg         st_req_s = 1'b0;  reg [23:0] st_addr_s = 24'd0;  reg [31:0] st_data_s = 32'd0;
  wire        st_busy;         wire        st_done;
  reg         vr_req_s = 1'b0;  reg [23:0] vr_addr_s = 24'd0;
  wire        vr_done;         wire [31:0] vr_data;
  reg         fc_req_s = 1'b0;  reg [23:0] fc_addr_s = 24'd0;  reg [7:0] fc_gen_s = 8'd0;
  wire        fc_active;       wire       fc_word_valid;
  wire [31:0] fc_data;         wire       fc_done;
  wire [7:0]  fc_done_len;     wire [7:0] fc_done_gen;

  // ======================================================================
  // fake machine side (verbatim from tb_savestate_integration)
  // ======================================================================
  wire        stall;
  reg  stall_d1 = 0, stall_d2 = 0;
  always @(posedge clk_mach) begin
    stall_d1 <= stall;
    stall_d2 <= stall_d1;
  end
  wire cpu_frozen = stall_d2;

  reg  [63:0] shadow_gold [0:10];
  reg  [63:0] shadow_live [0:10];
  wire [9:0]  ss_addr;
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
    if (ss_wren && ss_addr < 10'd8)
      shadow_live[ss_addr[3:0]] <= ss_wdata;
  end

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
  wire [31:0] br_rd_data;
  wire        preload_done_74a, wr_drained_74a, rd_overflow_74a, wr_overflow_74a;
  wire        ram_bank;
  wire [15:0] ram_addr;
  wire        ram_rd, ram_wr;
  wire [7:0]  ram_wdata, ram_rdata;
  reg         ss_start = 0, ss_load = 0;

  reg  por_done = 1'b0;
  wire [12:0] dram_a;
  wire [1:0]  dram_ba;
  wire [15:0] dram_dq;
  wire [1:0]  dram_dqm;
  wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

  tb_dram_model m0 (
    .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
    .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
    .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
    .fault_halt(1'b0), .trace_req(1'b1)
  );

  wire        port_boot_done;

  sdram_word_owner u_owner (
    .clk(clk_ctrl), .rst_n(rst_ctrl),
    .word_rd(word_rd_n), .word_wr(word_wr_n),
    .word_addr(word_addr_n), .word_data(word_data_n),
    .word_q(word_q_n), .word_busy(word_busy_n),
    .word_done(word_done_n), .word_rd_valid(word_rd_valid_n),
    .word_op_start(word_op_start_n),
    .init_done(port_boot_done),
    .st_req(st_req_s), .st_addr(st_addr_s), .st_data(st_data_s),
    .st_busy(st_busy), .st_done(st_done),
    .vr_req(vr_req_s), .vr_addr(vr_addr_s),
    .vr_done(vr_done), .vr_data(vr_data),
    .fc_req(fc_req_s), .fc_addr(fc_addr_s), .fc_gen(fc_gen_s),
    .fc_active(fc_active), .fc_word_valid(fc_word_valid),
    .fc_data(fc_data), .fc_done(fc_done),
    .fc_done_len(fc_done_len), .fc_done_gen(fc_done_gen),
    .hr_req(hr_req), .hr_addr(hr_addr),
    .hr_done(hr_done), .hr_data(hr_data),
    .ssrd_req(ssrd_req), .ssrd_addr(ssrd_addr),
    .ssrd_done(ssrd_done), .ssrd_data(ssrd_data),
    .sswr_req(sswr_req), .sswr_addr(sswr_addr), .sswr_data(sswr_data),
    .sswr_done(sswr_done), .sswr_busy(sswr_busy),
    .hwr_req(hwr_req), .hwr_addr(hwr_addr), .hwr_data(hwr_data),
    .hwr_done(hwr_done), .hwr_busy(hwr_busy),
    .port_wr_idle(port_wr_idle)
  );

  // owner<->port word nets (named _n to keep the ledger port names clean)
  wire        word_rd_n, word_wr_n, word_busy_n, word_done_n, word_rd_valid_n;
  wire        word_op_start_n;   // 2026-11-16: port op-start pulse -> owner attribution
  wire [23:0] word_addr_n;
  wire [31:0] word_data_n, word_q_n;

  io_sdram_pocket u_port (
    .controller_clk(clk_ctrl), .chip_clk(chip_clk), .clk_90(clk90),
    .reset_n(1'b1),            // internal boot FSM owns power-on (as in storage)
    .phy_cke(dram_cke), .phy_clk(dram_clk),
    .phy_cas(dram_cas_n), .phy_ras(dram_ras_n), .phy_we(dram_we_n),
    .phy_ba(dram_ba), .phy_a(dram_a), .phy_dq(dram_dq), .phy_dqm(dram_dqm),
    // raw burst ports UNUSED in shipping - tied exactly as sdram_storage v705-724
    .burst_rd(1'b0), .burst_addr(25'd0), .burst_len(11'd0), .burst_32bit(1'b0),
    .burst_data(), .burst_data_valid(), .burst_data_done(),
    .burstwr(1'b0), .burstwr_addr(15'd0), .burstwr_ready(),
    .burstwr_strobe(1'b0), .burstwr_data(16'd0), .burstwr_done(1'b0),
    .word_rd(word_rd_n), .word_wr(word_wr_n),
    .word_addr(word_addr_n), .word_data(word_data_n),
    .word_q(word_q_n), .word_busy(word_busy_n),
    .word_done(word_done_n), .word_rd_valid(word_rd_valid_n),
    .word_op_start(word_op_start_n),
    .boot_done(port_boot_done)
  );

  savestate_bridge u_bridge (
    .clk_74a(clk_74a), .rst_74a(rst_74a),
    .bridge_rd(bridge_rd), .bridge_wr(bridge_wr),
    .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
    .preload_req(preload_req),
    .rd_data(br_rd_data),
    .preload_done_74a(preload_done_74a),
    .wr_drained_74a(wr_drained_74a),
    .rd_overflow_74a(rd_overflow_74a),
    .wr_overflow_74a(wr_overflow_74a),
    .dbg_rd_hw(),
    .clk_ctrl(clk_ctrl), .rst_ctrl(rst_ctrl),
    .hr_req(hr_req), .hr_addr(hr_addr), .hr_done(hr_done), .hr_data(hr_data),
    .hwr_req(hwr_req), .hwr_addr(hwr_addr), .hwr_data(hwr_data),
    .hwr_done(hwr_done), .hwr_busy(hwr_busy),
    .port_wr_idle(port_wr_idle)
  );

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
    .blob_wr_drained_74a(wr_drained_74a),
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

  // ======================================================================
  // shared tap/ledger (A3/A4) - the code the instrumented integration TB
  // will include on the pre-decided pivot
  // ======================================================================
  reg  [3:0] gate_id = 4'd0;
  reg        gate_start = 1'b0;
  reg        stuck_clear = 1'b0;
  wire       stuck_seen;
  ss_ledger u_ledger (
    .clk_ctrl(clk_ctrl), .clk_74a(clk_74a), .rst(rst_ctrl),
    .gate_id(gate_id), .gate_start(gate_start), .stuck_clear(stuck_clear),
    .word_busy(word_busy_n), .word_rd(word_rd_n), .word_wr(word_wr_n),
    .word_done(word_done_n), .word_rd_valid(word_rd_valid_n),
    .word_addr(word_addr_n),
    .inflight(u_owner.inflight), .rd_grant(u_owner.rd_grant),
    .vr_req(vr_req_s), .fc_req(fc_req_s), .hr_req(hr_req), .ssrd_req(ssrd_req),
    .wcap_valid(u_owner.wcap_valid), .wcap_client(u_owner.wcap_client),
    .wcap_addr(u_owner.wcap_addr), .wcap_data(u_owner.wcap_data),
    .port_state(u_port.state),
    .word_rd_queue(u_port.word_rd_queue),
    .word_wr_queue(u_port.word_wr_queue),
    .burst_rd_queue(u_port.burst_rd_queue),
    .burstwr_queue(u_port.burstwr_queue),
    .refresh_count(u_port.refresh_count),
    .rd_wait(u_bridge.rd_wait),
    .rd_fifo_ne(u_bridge.rdf.wr_ptr != u_bridge.rdf.rd_ptr),
    .c_dret({16'd0, c_dret[15:0]})
  );

  // ======================================================================
  // TB counters (74a domain)
  // ======================================================================
  reg [23:0] c_dret = 24'd0;          // host read returns (dret_cross),
                                      // 24-bit: a full ladder far exceeds
                                      // 2^16 returns
  reg [31:0] rd_rets [0:32831];       // per-burst return data (FIFO order)
  reg [23:0] c_dret_base = 24'd0;     // burst baseline (set by host_rd_burst)
  always @(posedge clk_74a)
    if (u_bridge.dret_cross)
      c_dret <= c_dret + 24'd1;

  // hwr_done mirrored to 74a (1101 pattern, as the bridge's own dret_cross)
  // hwr retire count: any change of the 74a-domain WR FIFO read pointer
  // (free-running 5-bit pointer: one change == one retire; the 1-ctrl-cyc
  // hwr_done pulse is NOT directly 74a-samplable)
  reg  [4:0] wrf_rdp_p = 5'd0;
  reg [23:0] c_hwr74 = 24'd0;         // hwr retire count (74a mirror)
  always @(posedge clk_74a) begin
    if (u_bridge.wrf.rd_ptr !== wrf_rdp_p) begin
      wrf_rdp_p <= u_bridge.wrf.rd_ptr;
      c_hwr74 <= c_hwr74 + 24'd1;
    end
  end

  reg [15:0] c_pre = 16'd0;
  reg        pre_d1 = 1'b0;
  always @(posedge clk_74a) begin
    pre_d1 <= preload_req;
    if (preload_req && !pre_d1) c_pre <= c_pre + 16'd1;
  end

  // ctrl-domain done counters (gate checks)
  reg [15:0] c_hr_done = 16'd0;
  reg        hr_done_d1 = 1'b0;
  always @(posedge clk_ctrl) begin
    if (hr_done && !hr_done_d1) c_hr_done <= c_hr_done + 16'd1;
    hr_done_d1 <= hr_done;
  end
  reg [15:0] c_st_done = 16'd0;
  reg        st_done_d1 = 1'b0;
  always @(posedge clk_ctrl) begin
    if (st_done && !st_done_d1) c_st_done <= c_st_done + 16'd1;
    st_done_d1 <= st_done;
  end
  reg [15:0] c_vr_done = 16'd0;
  reg        vr_done_d1 = 1'b0;
  always @(posedge clk_ctrl) begin
    if (vr_done && !vr_done_d1) c_vr_done <= c_vr_done + 16'd1;
    vr_done_d1 <= vr_done;
  end

  // ======================================================================
  // periodic quiet-state dumper (TB-side diagnostics): when no word done/
  // valid for 512 ctrl cycles, dump port + owner + bridge + model state,
  // then pause 2048 quiet cycles between dumps (capped at 60 lines)
  // ======================================================================
  reg [31:0] quiet_cnt = 0;
  reg [31:0] dump_pause = 0;
  reg [31:0] dump_cnt = 0;
  always @(posedge clk_ctrl) begin
      if (word_done_n || word_rd_valid_n) begin
          quiet_cnt <= 0;
      end else if (quiet_cnt < 32'd4095) begin
          quiet_cnt <= quiet_cnt + 32'd1;
      end
      if (dump_pause != 0) begin
          dump_pause <= dump_pause - 1;
      end else if (quiet_cnt >= 512 && quiet_cnt < 4096
                   && ((quiet_cnt - 512) % 2048) == 0
                   && dump_cnt < 60) begin
          dump_cnt <= dump_cnt + 1;
          dump_pause <= 2048;
          $display("QUIET-DUMP @%0t: port st=%0d rdq=%b wrq=%b brdq=%b bwq=%b rd=%b wr=%b a=%0d len=%0d | owner infl=%0d busy=%b | brg rdw=%b rdptr=%0d rdwrptr=%0d wrq_rdptr=%0d wrinfl=%b | m0 act=%b ref=%0d rdpend=%b rd_fire=%0d rd_bank=%0d rd_row=%0d rd_col=%0d | c_dret=%0d c_hwr74=%0d",
            $time, u_port.state, u_port.word_rd_queue, u_port.word_wr_queue,
            u_port.burst_rd_queue, u_port.burstwr_queue, word_rd_n, word_wr_n,
            u_port.addr, u_port.length, u_owner.inflight, word_busy_n,
            u_bridge.rd_wait, u_bridge.rdf.rd_ptr, u_bridge.rdf.wr_ptr,
            u_bridge.wrf.rd_ptr, u_bridge.wr_inflight,
            m0.bank_active, m0.ref_cnt, {m0.rd_pend[1], m0.rd_pend[0]},
            m0.rd_fire[0], m0.rd_bank[0], m0.rd_row[0], m0.rd_col[0],
            c_dret, c_hwr74);
      end
  end

  // ======================================================================
  // word_busy transition probe (diagnostic: per-op pulse vs per-cycle
  // oscillation). Window summary every 1024 ctrl cycles; first 200 raw
  // transitions printed with context.
  // ======================================================================
  reg        wb_p = 1'b0;
  reg [15:0] wb_tog_cnt = 0;
  reg [15:0] wb_tog_win = 0;
  reg [15:0] wb_print = 0;
  always @(posedge clk_ctrl) begin
      wb_p <= word_busy_n;
      if (word_busy_n !== wb_p) begin
          wb_tog_cnt <= wb_tog_cnt + 16'd1;
          if (wb_print < 200) begin
              wb_print <= wb_print + 16'd1;
              $display("WB-TOG @%0t: busy %b->%b st=%0d rd=%b wr=%b rdq=%b wrq=%b infl=%0d busy_lvl=%b",
                $time, wb_p, word_busy_n, u_port.state, word_rd_n, word_wr_n,
                u_port.word_rd_queue, u_port.word_wr_queue, u_owner.inflight,
                u_owner.word_rd);
          end
      end
      if (wb_tog_win == 1024) begin
          if (wb_tog_cnt != 0 && wb_print < 2000)
            $display("WB-WIN @%0t: %0d word_busy transitions in 1024 ctrl cyc (st=%0d)",
              $time, wb_tog_cnt, u_port.state);
          wb_tog_cnt <= 16'd0;
          wb_tog_win <= 16'd0;
      end else begin
          wb_tog_win <= wb_tog_win + 16'd1;
      end
  end

  // ======================================================================
  // blob memory (SDRAM model) - same mapping as the integration TB:
  // blob word w (0..32831) at mem 0x800000 + 2w (hi16) / +2w+1 (lo16)
  // ======================================================================
  localparam [24:0] BLOB_MEM_BASE = 25'h800000;
  function [31:0] sdram_read(input [15:0] w);
    sdram_read = {m0.mem[BLOB_MEM_BASE + {w, 1'b0}],
                  m0.mem[BLOB_MEM_BASE + {w, 1'b0} + 1'b1]};
  endfunction
  task sdram_write(input [15:0] w, input [31:0] data);
    begin
      m0.mem[BLOB_MEM_BASE + {w, 1'b0}]        = data[31:16];
      m0.mem[BLOB_MEM_BASE + {w, 1'b0} + 1'b1] = data[15:0];
    end
  endtask

  // machine-bus tasks (verbatim from the integration TB)
  task mb_write(input [15:0] addr, input [7:0] data, input aux);
    begin
      @(negedge clk_mach);
      m_ram_we = 1'b1; m_ram_addr = {2'b00, addr}; m_ram_di = data;
      m_ram_aux = aux;
      @(negedge clk_mach);
      m_ram_we = 1'b0;
    end
  endtask
  task mb_read(output [7:0] data, input [15:0] addr, input aux);
    begin
      @(negedge clk_mach);
      m_ram_addr = {2'b00, addr}; m_ram_aux = aux;
      @(negedge clk_mach);
      data = aux ? m_ram_do[15:8] : m_ram_do[7:0];
    end
  endtask

  // ======================================================================
  // A1: FIFO-paced scripted host (the real host reads ahead and streams;
  // a wait-for-return host keeps the FIFO at depth 1 and never opens the
  // dip-collision window - that was the roundtrip-TB blind spot)
  // ======================================================================
  localparam [15:0] HST_PERIOD = 16'd14;   // 14 clk_74a ~ 188 ns (~190 ns)
  localparam [15:0] FIFO_BOUND = 16'd15;   // 16-deep FIFO, keep one free

  // issue n window reads starting at w0 at fixed cadence, FIFO-bounded;
  // returns are collected in FIFO order into rd_rets[w0..w0+n-1].
  // nmiss out = returns still missing at the retire timeout (0 = clean).
  task host_rd_burst(input [15:0] w0, input [15:0] n, output [15:0] nmiss);
    integer w, to, got;
    begin
      c_dret_base = c_dret;
      to = 0;
      got = 0;
      for (w = 0; w < n; w = w + 1) begin
        // outstanding = issued (w+1) - retired (c_dret - base);
        // retire pressure must RELIEVE the bound, not add to it
        while ((w + 1 - (c_dret - c_dret_base)) >= FIFO_BOUND) @(negedge clk_74a);
        bridge_rd = 1'b1;
        bridge_addr = 32'h40000000 + (w0 + w) * 32'd4;
        @(negedge clk_74a);
        bridge_rd = 1'b0;
        repeat (HST_PERIOD - 16'd1) @(negedge clk_74a);
      end
      while (got < n && to < 200000) begin
        @(negedge clk_74a);
        if (c_dret > c_dret_base + got) begin
          rd_rets[w0 + got] = br_rd_data;
          got = got + 1;
        end
        to = to + 1;
      end
      nmiss = n - got;
      if (nmiss !== 16'd0)
        $display("HOST-RD: %0d of %0d returns missing after %0d clk_74a (c_dret=%0d base=%0d)",
                 nmiss, n, to, c_dret, c_dret_base);
    end
  endtask

  // issue n window writes (data from src[]) at fixed cadence, FIFO-bounded
  // by the hwr retire count; then wait for full drain.
  task host_wr_burst(input [15:0] w0, input [15:0] n,
                     input [31:0] src [0:32832], output integer to_out);
    integer w, to;
    reg [23:0] base;
    begin
      base = c_hwr74;
      to = 0;
      for (w = 0; w < n; w = w + 1) begin
        while ((w + 1 - (c_hwr74 - base)) >= FIFO_BOUND) @(negedge clk_74a);
        bridge_wr = 1'b1;
        bridge_addr = 32'h40000000 + (w0 + w) * 32'd4;
        bridge_wr_data = src[w0 + w];
        @(negedge clk_74a);
        bridge_wr = 1'b0;
        repeat (HST_PERIOD - 16'd1) @(negedge clk_74a);
      end
      while (!wr_drained_74a && to < 400000) begin @(negedge clk_74a); to = to + 1; end
      to_out = to;
      if (to >= 400000)
        $display("HOST-WR: drain timeout after %0d words (wr_drained=%b, c_hwr74=%0d)",
                 w0 + n, wr_drained_74a, c_hwr74);
    end
  endtask

  // ======================================================================
  // A2-refined: scripted disk activity = fc sectors (M1 fetch shape) +
  // st sectors (M0 store shape) - the shipping config's real disk traffic
  // (raw burst ports are tied off in sdram_storage)
  // ======================================================================
  localparam [23:0] FC_BASE = 24'h040_2000;   // scratch: fetch region
  localparam [23:0] ST_BASE = 24'h040_3000;   // scratch: store region
  localparam [15:0] FC_SECT_WORDS = 16'd128;  // one 512-byte sector = 128 words
  reg disk_on = 1'b0;
  reg [11:0] disk_phase = 12'd0;              // phase knob (ctrl cycles)
  reg [15:0] disk_period = 16'd4096;          // sector period (ctrl cycles)
  reg [15:0] disk_sectors = 16'd64;           // sectors per gate
  reg [7:0]  fc_gen_cur = 8'd0;

  task fc_sector(input [23:0] base);
    integer w, to;
    reg [23:0] woff;
    begin
      for (w = 0; w < FC_SECT_WORDS; w = w + 1) begin
        woff = w[23:0];
        fc_req_s = 1'b1; fc_addr_s = base + woff; fc_gen_s = fc_gen_cur;
        @(negedge clk_ctrl);
        to = 0;
        while (!fc_done && to < 8000) begin @(negedge clk_ctrl); to = to + 1; end
        if (to >= 8000) begin
          $display("DISK-F: fc hang (word %0d, addr %h, to=%0d)", w, fc_addr_s, to);
          break;
        end
        fc_req_s = 1'b0;
        @(negedge clk_ctrl);
      end
    end
  endtask

  task st_sector(input [23:0] base);
    integer w, to;
    reg [23:0] woff;
    reg [31:0] wdata;
    reg done_seen;
    begin
      for (w = 0; w < FC_SECT_WORDS; w = w + 1) begin
        done_seen = 1'b0;
        woff = w[23:0];
        wdata = {base, 8'd0} ^ w[31:0];
        st_req_s = 1'b1; st_addr_s = base + woff; st_data_s = wdata;
        @(negedge clk_ctrl);
        st_req_s = 1'b0;
        // store protocol: a masked pulse (read_armed) is dropped with no
        // done - re-pulse until st_done (as disk_store does)
        to = 0;
        while (!done_seen && to < 8000) begin
          @(negedge clk_ctrl);
          if (st_done) done_seen = 1'b1;
          else if (to > 32) begin
            st_req_s = 1'b1; st_addr_s = base + woff; st_data_s = wdata;
            @(negedge clk_ctrl);
            st_req_s = 1'b0;
          end
          to = to + 1;
        end
        if (to >= 8000) begin
          $display("DISK-S: st hang (word %0d, addr %h, to=%0d)", w, st_addr_s, to);
          break;
        end
      end
    end
  endtask

  // background disk process (forked per gate)
  task disk_bg;
    integer k;
    reg [23:0] soff;
    begin
      repeat (disk_phase) @(negedge clk_ctrl);
      for (k = 0; k < disk_sectors; k = k + 1) begin
        fc_sector(FC_BASE + k);
        if ((k % 4) == 3) begin
          soff = k / 4;
          st_sector(ST_BASE + soff * FC_SECT_WORDS);
        end
        repeat (disk_period) @(negedge clk_ctrl);
      end
    end
  endtask

  // ======================================================================
  // G2: patterned vr (video-line shape: 16-word level reads, periodic)
  // ======================================================================
  reg vr_on = 1'b0;
  reg [15:0] vr_period = 16'd1024;
  reg [11:0] vr_lines = 12'd256;
  localparam [23:0] VR_BASE = 24'h040_4000;
  task vr_line;
    integer w, to;
    reg [23:0] woff;
    begin
      for (w = 0; w < 16; w = w + 1) begin
        woff = w[23:0];
        vr_req_s = 1'b1; vr_addr_s = VR_BASE + woff;
        @(negedge clk_ctrl);
        to = 0;
        while (!vr_done && to < 8000) begin @(negedge clk_ctrl); to = to + 1; end
        if (to >= 8000) begin
          $display("VR: hang (word %0d, to=%0d)", w, to);
          break;
        end
        vr_req_s = 1'b0;
        @(negedge clk_ctrl);
      end
    end
  endtask
  task vr_bg;
    integer k;
    begin
      for (k = 0; k < vr_lines; k = k + 1) begin
        vr_line();
        repeat (vr_period) @(negedge clk_ctrl);
      end
    end
  endtask

  // ======================================================================
  // gate bookkeeping
  // ======================================================================
  integer nfail = 0;
  integer n_stuck = 0;
  task gate_begin(input [3:0] gid);
    begin
      gate_id = gid;
      stuck_clear = 1'b1; @(negedge clk_74a); stuck_clear = 1'b0;
      gate_start = 1'b1;  @(negedge clk_74a); gate_start = 1'b0;
    end
  endtask

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

  localparam [31:0] OP_TIMEOUT = 32'd8000000;

  // save/load ops (verbatim from the integration TB; the STUCK dumps use
  // the bare-stack instance names)
  task save_op(input string tag);
    integer to;
    begin
      @(negedge clk_74a);
      ss_start = 1'b1;
      to = 0;
      while (!ss_start_ack && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      repeat (40) @(negedge clk_74a);
      ss_start = 1'b0;
      to = 0;
      while ((ss_start_ok | ss_start_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      to = 0;
      while (!(ss_start_ok | ss_start_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      if (to >= OP_TIMEOUT) begin
        nfail = nfail + 1;
        $display("FAIL: %s: save timed out (no ok/err) - STUCK family:", tag);
        $display("  STUCK @%0t: mgr st=%0d byte_index=%0d | sswr st=%0d lasta=%0d busy=%b port_idle=%b",
          $time, u_slot.u_mgr.state, u_slot.u_mgr.byte_index,
          u_slot.sswr_st, u_slot.sswr_last_a, sswr_busy, port_wr_idle);
        $display("  STUCK2 @%0t: owner: busy=%b infl=%b wcap_v=%b cl=%0d a=%h d=%h | port: busy=%b rd=%b wr=%b a=%h | bridge: rd_wait=%b rd_empty=%b wr_infl=%b rdf=%b/%b wrf=%b/%b | sswr_req=%b ssrd_lvl=%b hr=%b hwr=%b cnts: dret=%0d hrdone=%0d hwrdone=%0d",
          $time, word_busy_n, u_owner.inflight,
          u_owner.wcap_valid, u_owner.wcap_client,
          u_owner.wcap_addr, u_owner.wcap_data,
          word_busy_n, word_rd_n, word_wr_n, word_addr_n,
          u_bridge.rd_wait, u_bridge.rd_empty_c, u_bridge.wr_inflight,
          u_bridge.rdf.rd_ptr, u_bridge.rdf.wr_ptr,
          u_bridge.wrf.rd_ptr, u_bridge.wrf.wr_ptr,
          sswr_req, ssrd_req, hr_req, hwr_req,
          c_dret, c_hr_done, c_hwr74);
      end else if (ss_start_err) begin
        nfail = nfail + 1;
        $display("FAIL: %s: save reported err", tag);
      end
    end
  endtask

  task load_op(input string tag, input expect_err);
    integer to;
    begin
      @(negedge clk_74a);
      ss_load = 1'b1;
      to = 0;
      while (!ss_load_ack && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      repeat (40) @(negedge clk_74a);
      ss_load = 1'b0;
      to = 0;
      while ((ss_load_ok | ss_load_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      to = 0;
      while (!(ss_load_ok | ss_load_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      if (to >= OP_TIMEOUT) begin
        nfail = nfail + 1;
        $display("FAIL: %s: load timed out (no ok/err) - STUCK family:", tag);
        $display("  STUCK @%0t: mgr st=%0d byte_index=%0d | ssrd st=%0d lasta=%0d port_idle=%b",
          $time, u_slot.u_mgr.state, u_slot.u_mgr.byte_index,
          u_slot.ssrd_st, u_slot.ssrd_last_a, port_wr_idle);
      end else if (ss_load_err !== expect_err) begin
        nfail = nfail + 1;
        $display("FAIL: %s: load err=%b expect=%b", tag, ss_load_err, expect_err);
      end
    end
  endtask

  // ======================================================================
  // golden machine refill - the LOAD path rewrites the whole machine RAM
  // (shifted by the +1 host-transport offset), so every gate that runs a
  // replay (save -> transport -> load) must refill before its save, or
  // the golden-based blob verification sees stale machine state
  // ======================================================================
  task refill_machine();
    begin
      for (integer i = 0; i < 65536; i = i + 1) begin
        mb_write(i[15:0], golden_main[i], 1'b0);
        mb_write(i[15:0], golden_aux[i], 1'b1);
      end
      for (integer i = 0; i < 11; i = i + 1)
        shadow_live[i] = shadow_gold[i];
    end
  endtask

  // ======================================================================
  // golden machine fill (verbatim shape from the integration TB)
  // ======================================================================
  reg  [7:0] golden_main [0:65535];
  reg  [7:0] golden_aux  [0:65535];
  function [7:0] golden_byte(input [16:0] b);
    golden_byte = b[16] ? golden_aux[b[15:0]] : golden_main[b[15:0]];
  endfunction
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
  function [31:0] exp_sdram_word(input [15:0] w);
    reg [63:0] sw;
    sw = exp_slot_word(w >> 1);
    exp_sdram_word = w[0] ? sw[63:32] : sw[31:0];
  endfunction
  reg [31:0] counter_cur = 32'd1;
  reg [31:0] blob_save [0:32831];
  reg [31:0] wr_src [0:32832];   // host write-burst source (transport form)

  // ======================================================================
  // gates
  // ======================================================================
  reg [15:0] N_BLOB = 16'd32832;

  task g0();
    integer w, to, mism;
    reg [15:0] nmiss;
    reg [23:0] woff;
    begin
      gate_begin(4'd0);
      // 1) hr alone: 1000 reads of the zeroed blob (FIFO-paced)
      host_rd_burst(16'd0, 16'd1000, nmiss);
      check("G0 hr 1000 reads complete", nmiss === 16'd0);
      check("G0 hr word0 exact (blob zeroed)", rd_rets[0] === 32'd0);
      // 2) save (full 32,832-word blob)
      save_op("G0-save");
      check("G0 save ok", ss_start_err === 1'b0);
      repeat (500) @(negedge clk_74a);
      // 3) host rd burst over the saved image (FIFO-paced) - verify the
      //    saved data against the golden expectation
      host_rd_burst(16'd0, 16'd2000, nmiss);
      check("G0 post-save rd burst complete", nmiss === 16'd0);
      mism = 0;
      for (w = 0; w < 2000; w = w + 1)
        if (rd_rets[w] !== exp_sdram_word(w)) begin
          if (mism < 5)
            $display("FAIL: G0 saved word %0d = %h expect %h", w, rd_rets[w], exp_sdram_word(w));
          mism = mism + 1;
        end
      $display("     (G0 saved-word mismatches: %0d)", mism);
      check("G0 saved words exact", mism == 0);
      // diagnostic: direct model view vs HR view of the first window words
      for (w = 0; w < 8; w = w + 1)
        $display("G0-DBG w=%0d: model=%h hr=%h", w, sdram_read(w), rd_rets[w]);
      // diagnostic: where does 0x9F9E9D9C live in the model? decode idx -> geometry
      for (w = 0; w < 33554432; w = w + 1)
        if (m0.mem[w] === 16'h9F9E && m0.mem[w + 1'b1] === 16'h9D9C)
          $display("G0-DBG cell idx=%0d (ba=%0d row=%0d col=%0d word=%0d)", w, w[24:23], w[22:10], w[9:0], w >> 1);
      // 4) transport write (host one-word-behind form) - legal sequence for
      //    load: the load reads at BLOB_BASE+1, so the state must be shifted
      //    into place by the host transport first (a bare save->load is NOT
      //    a legal sequence - see ssrd_base_sum +1 note in savestate_slot)
      wr_src[0] = 32'd0;
      for (w = 1; w < 2001; w = w + 1) wr_src[w] = exp_sdram_word(w - 16'd1);
      host_wr_burst(16'd0, 16'd2001, wr_src, to);
      check("G0 transport write drained", to < 400000);
      // 5) load (expect ok - state now sits at B+1 as the load expects)
      load_op("G0-load", 1'b0);
      check("G0 load ok", ss_load_err === 1'b0);
      // 6) hwr alone: 1000 writes + drain + memory compare
      for (w = 0; w < 1001; w = w + 1) wr_src[w] = {16'h5A5A, 16'd0} ^ w[31:0];
      host_wr_burst(16'd500, 16'd1000, wr_src, to);
      check("G0 hwr 1000 writes drained", to < 400000);
      mism = 0;
      for (w = 0; w < 1000; w = w + 1)
        if (sdram_read(500 + w) !== wr_src[500 + w]) begin
          if (mism < 5)
            $display("FAIL: G0 mem word %0d = %h expect %h", 500 + w, sdram_read(500 + w), wr_src[500 + w]);
          mism = mism + 1;
        end
      $display("     (G0 hwr memory mismatches: %0d)", mism);
      check("G0 hwr 1000 words exact", mism == 0);
      // 7) vr / fc / st alone
      for (w = 0; w < 100; w = w + 1) begin
        woff = w[23:0];
        vr_req_s = 1'b1; vr_addr_s = VR_BASE + woff;
        @(negedge clk_ctrl);
        to = 0;
        while (!vr_done && to < 4000) begin @(negedge clk_ctrl); to = to + 1; end
        if (to >= 4000) begin nfail = nfail + 1; $display("FAIL: G0 vr hang at %0d", w); break; end
        vr_req_s = 1'b0;
        @(negedge clk_ctrl);
      end
      check("G0 vr 100 reads complete", to < 4000);
      fc_sector(FC_BASE);
      check("G0 fc sector complete", fc_req_s === 1'b0);
      st_sector(ST_BASE);
      check("G0 st sector complete", st_req_s === 1'b0);
      check("G0 no stuck", !stuck_seen);
      $display("G0: done (stuck=%b nfail=%0d)", stuck_seen, nfail);
    end
  endtask

  // one full replay (the G3/G5/G6 analog): save, FIFO-paced host rd burst,
  // transport write, load, save#2. disk/vr knobs set by the caller.
  task replay(input string tag, input [15:0] n);
    integer w, to, mism;
    reg [15:0] d;
    begin
      // save #1
      save_op({tag, "-save1"});
      check({tag, " save1 ok"}, ss_start_err === 1'b0);
      repeat (500) @(negedge clk_74a);
      // capture the saved blob
      for (w = 0; w < n; w = w + 1)
        blob_save[w] = sdram_read(w);
      // host read burst (FIFO-paced) + verify
      host_rd_burst(16'd0, n[15:0], d);
      check({tag, " host rd burst complete"}, d === 16'd0);
      mism = 0;
      for (w = 0; w < n; w = w + 1)
        if (rd_rets[w] !== exp_sdram_word(w)) begin
          if (mism < 5)
            $display("FAIL: %s rd word %0d = %h expect %h", tag, w, rd_rets[w], exp_sdram_word(w));
          mism = mism + 1;
        end
      $display("     (%s rd mismatches: %0d)", tag, mism);
      check({tag, " host rd words exact"}, mism == 0);
      // transport write (host form: window k <- stored[k], one-word-behind)
      wr_src[0] = 32'd0;
      for (w = 1; w < n; w = w + 1) wr_src[w] = blob_save[w-1];
      wr_src[n] = blob_save[n-1];
      host_wr_burst(16'd0, n[15:0] + 16'd1, wr_src, to);
      check({tag, " transport write drained"}, to < 400000);
      check({tag, " no rd overflow"}, rd_overflow_74a === 1'b0);
      check({tag, " no wr overflow"}, wr_overflow_74a === 1'b0);
      // load
      load_op({tag, "-load"}, 1'b0);
      check({tag, " load ok"}, ss_load_err === 1'b0);
      // save #2 (the hardware wedge scenario)
      save_op({tag, "-save2"});
      check({tag, " save2 ok"}, ss_start_err === 1'b0);
      check({tag, " no stuck"}, !stuck_seen);
      n_stuck = n_stuck + (stuck_seen ? 1 : 0);
      $display("%s: done (stuck=%b nfail=%0d)", tag, stuck_seen, nfail);
    end
  endtask

  task g1a();
    integer ph;
    begin
      disk_on = 1'b1; vr_on = 1'b0;
      for (ph = 0; ph < 6; ph = ph + 1) begin
        disk_phase = 12'(ph * 40);
        gate_begin(4'd1);
        $display("G1a: phase=%0d (disk fc/st ON)", ph * 40);
        fork
          disk_bg;
          begin replay("G1a", N_BLOB); end
        join
        if (stuck_seen) $display("G1a phase=%0d: WEDGE", ph * 40);
      end
    end
  endtask

  task g1b();
    begin
      disk_on = 1'b0; vr_on = 1'b0;
      gate_begin(4'd2);
      $display("G1b: disk OFF (control)");
      replay("G1b", N_BLOB);
      if (stuck_seen) $display("G1b: WEDGE");
    end
  endtask

  task g2();
    begin
      disk_on = 1'b0; vr_on = 1'b1;
      gate_begin(4'd3);
      $display("G2: multi-client (vr patterned)");
      fork
        vr_bg;
        begin replay("G2", N_BLOB); end
      join
      if (stuck_seen) $display("G2: WEDGE");
      vr_on = 1'b0;
    end
  endtask

  task g4(input integer nseeds);
    integer s;
    reg [31:0] seedv;
    begin
      disk_on = 1'b1; vr_on = 1'b1;
      for (s = 0; s < nseeds; s = s + 1) begin
        seedv = 32'h1234_5678 ^ (s * 32'h9E37_79B9);
        $random(seedv);
        disk_phase = 12'($random(seedv));
        $random(seedv);
        disk_period = 16'($random(seedv)) % 16'd8192 + 16'd1024;
        $random(seedv);
        vr_period = 16'($random(seedv)) % 16'd4096 + 16'd256;
        disk_sectors = 16'd512;   // span the whole gate (period is the knob)
        gate_begin(4'd4);
        $display("G4 seed=%0d: phase=%0d period=%0d vr_period=%0d sectors=%0d",
                 s, disk_phase, disk_period, vr_period, disk_sectors);
        fork
          disk_bg;
          vr_bg;
          begin replay("G4", N_BLOB); end
        join
        if (stuck_seen) $display("G4 seed=%0d: WEDGE", s);
      end
    end
  endtask

  task g5();
    integer w, to, bad;
    begin
      disk_on = 1'b0; vr_on = 1'b1;
      gate_begin(4'd5);
      $display("G5: hwr write-race class (FIFO-paced writes under vr)");
      // corrupt + write a patterned 4096-word window, then verify memory
      for (w = 0; w < 4097; w = w + 1) wr_src[w] = {16'h5A5A, 16'h0000} ^ w[31:0];
      host_wr_burst(16'd1000, 16'd4096, wr_src, to);
      check("G5 writes drained", to < 400000);
      bad = 0;
      for (w = 0; w < 4096; w = w + 1)
        if (sdram_read(1000 + w) !== wr_src[1000 + w]) begin
          if (bad < 5)
            $display("FAIL: G5 mem word %0d = %h expect %h (see wcap/wdone ledger rows)",
                     1000 + w, sdram_read(1000 + w), wr_src[1000 + w]);
          bad = bad + 1;
        end
      $display("     (G5 memory mismatches: %0d)", bad);
      check("G5 all 4096 write words exact", bad == 0);
      check("G5 no stuck", !stuck_seen);
      n_stuck = n_stuck + (stuck_seen ? 1 : 0);
      if (stuck_seen) $display("G5: WEDGE");
      // join vr_bg
      vr_on = 1'b0;
      #1;
    end
  endtask

  // ======================================================================
  // main
  // ======================================================================
  reg serdep = 1'b0;   // +SERDEP: G0 post-save burst in serialized pacing

  initial begin
    integer g;
    integer seeds;
    // plusargs - this Verilator build: $value$plusarg is an unknown PLI call
    // and $test$plusargs here is the classic 1-arg match form (no value
    // extraction). Boolean flags only:
    //   +FAST     N_BLOB=4096 (fast host-burst mode)
    //   +G0..+G5  run a single gate (default: full ladder)
    //   +FSEEDS   G4 seed count = 4 (default 25)
    if ($test$plusargs("FAST"))    N_BLOB = 16'd4096;
    seeds = 25;
    if ($test$plusargs("FSEEDS"))  seeds = 4;
    if ($test$plusargs("SERDEP"))  serdep = 1'b1;
    g = 9;
    if ($test$plusargs("G0")) g = 0;
    if ($test$plusargs("G1")) g = 1;
    if ($test$plusargs("G2")) g = 2;
    if ($test$plusargs("G3")) g = 3;
    if ($test$plusargs("G4")) g = 4;
    if ($test$plusargs("G5")) g = 5;

    // ---- init (integration shape) ----
    rst_74a = 1'b1; rst_mach = 1'b0;
    repeat (30) @(negedge clk_ctrl);
    rst_mach = 1'b1;
    rst_74a  = 1'b0;
    #1000;
    por_done = 1'b1;
    while (!u_port.boot_done) @(negedge clk_ctrl);
    repeat (50) @(negedge clk_74a);

    // golden machine fill (one-time: golden_main/golden_aux + shadows)
    for (integer i = 0; i < 65536; i = i + 1) begin
      golden_main[i] = 8'hA0 ^ 8'(i);
      golden_aux[i]  = 8'h5F ^ 8'(i) ^ 8'(i >> 12);
    end
    for (integer i = 0; i < 11; i = i + 1)
      shadow_gold[i] = 64'd0;
    shadow_gold[0]  = 64'hC0DE_0000_0000_0001;
    shadow_gold[1]  = 64'h1111_0000_0000_0011;
    shadow_gold[2]  = 64'h2222_0000_0000_0022;
    shadow_gold[3]  = {41'd0, 8'hFF, 8'h0F, 8'h5A};
    shadow_gold[4]  = {38'd0, 1'b1, 1'b1, 16'hBEEF, 8'h77};
    shadow_gold[5]  = 64'h1111_2222_3333_4444;
    shadow_gold[6]  = 64'h1111_2222_3333_4444;
    shadow_gold[7]  = 64'hAAAA_BBBB_CCCC_DDDD;
    shadow_gold[8]  = 64'h8888_0000_0000_0088;
    shadow_gold[9]  = 64'h9999_0000_0000_0099;
    shadow_gold[10] = 64'hAA00_0000_0000_00AA;
    for (integer i = 0; i < 11; i = i + 1)
      shadow_live[i] = shadow_gold[i];

    // zero the blob window
    for (integer w = 0; w < 32832; w = w + 1)
      sdram_write(w, 32'd0);

    // first machine fill (refill_machine for the later gates)
    refill_machine();

    // ---- gates ----
    if (g == 0 || g == 9) begin
      g0();
      // G0's PARTIAL transport (2001 of 32,832 words) leaves the machine RAM
      // word-shifted after its load - restore before the full-replay gates
      refill_machine();
    end
    if (g == 1 || g == 9) g1a();
    if (g == 2 || g == 9) g1b();
    if (g == 3 || g == 9) g2();
    if (g == 4 || g == 9) g4(seeds);
    if (g == 5 || g == 9) g5();

    // ---- verdict ----
    if (nfail == 0 && n_stuck == 0)
      $display("MINIREPRO TB: PASS (no failures, no wedges; ledger files written)");
    else if (nfail == 0)
      $display("MINIREPRO TB: WEDGES REPRODUCED (n_stuck=%0d, no other failures - data in ledger_g*.csv)", n_stuck);
    else
      $display("MINIREPRO TB: FAIL (%0d failures, %0d wedges)", nfail, n_stuck);
    $finish;
  end

  // global watchdog: 3 s sim time (full ladder ~ 800 ms sim; a stuck op
  // first burns its own OP_TIMEOUT ~ 108 ms sim, so keep the margin wide)
  initial begin
    #3_000_000_000;
    $display("MINIREPRO TB: FAIL (global watchdog timeout)");
    $finish;
  end

endmodule
