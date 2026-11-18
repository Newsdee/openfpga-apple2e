//
// tb_savestate_integration.sv - W1 topological gate (2026-11-13)
//
// The round-trip TB instantiates a bare owner + port and wires the slot
// straight into them. That topology masked an integration gap in the
// shipping top: the storage owner's W1 clients (ssrd/sswr/hr/hwr +
// port_wr_idle) were left dangling inside sdram_storage, so savestate
// save/load would hang on the compiled core (manager waits for a
// slot_ready that never comes). Quartus A&S flagged the dangling owner0
// ports; this TB closes the loop so that class of wiring bug fails in
// simulation, not on hardware.
//
// DUT topology (mirrors apf_stream_video_top.v exactly):
//
//   savestate_slot --ssrd/sswr--> sdram_storage --owner0--> io_sdram_pocket
//   savestate_bridge --hr/hwr--> sdram_storage --owner0--> io_sdram_pocket
//   sdram_storage.port_wr_idle --> slot.port_wr_idle + bridge.port_wr_idle
//   raw bridge signals (fake host, 0x40xxxxxx window) -> bridge + storage
//
// Gates:
//   T0 fill: fake machine RAM + shadow
//   G1 SAVE: save via storage (sswr), blob word-for-word in the DRAM model
//   G2 HOST READ: 16 blob words read through the 0x40xxxxxx window (hr)
//   G3 HOST WRITE + LOAD: host writes the G1 blob through the window (hwr),
//      load (ssrd) restores the corrupted machine state
//   G4 preload fired exactly once (after the G1 save)
//
// Build + run: ../run_tb_savestate_integration.sh
//
`timescale 1ns/1ps
module tb_savestate_integration;

  // ======================================================================
  // clocks (real rates; the ctrl/chip/clk90 relationship is the exact
  // shipping one from tb_sector_fetch - the only config the real port +
  // DRAM model accept without a bank timing violation)
  //
  // 2026-11-13 note (learned the hard way): the tb_sector_fetch lineage
  // runs clk_ctrl at 266 MHz, NOT the shipping 133.12 MHz - its
  // PC=3.756 is a HALF period and `forever #(PC/2.0)` toggles at
  // 1.878 ns. The real PLL (apple2e_sdram_pll) outputs 133.12 MHz
  // (7.504 ns). Any ctrl->74a pulse crossing in DUT code must therefore
  // be sized for >= 2 clk_74a periods at the SIM rate (>= 8 ctrl cycles),
  // which also covers the real rate (60 ns = 4.5x). Do not "fix" the
  // clock rate here without re-validating the DRAM model config.
  // ======================================================================
  reg clk_74a  = 1'b0;
  reg clk_mach = 1'b0;
  reg clk_ctrl = 1'b0;
  initial begin #5.113;  forever #6.734  clk_74a  = ~clk_74a; end // 74.25 MHz
  initial begin #21.407; forever #34.925 clk_mach = ~clk_mach; end // 14.318 MHz
  localparam real PC2    = 3.756;
  localparam real PHASE2 = 3.756;
  reg chip_clk = 1'b0, clk90 = 1'b0;
  initial begin #4000;             forever #(PC2/2.0) clk_ctrl = ~clk_ctrl; end
  initial begin #4000; #PHASE2;    forever #(PC2/2.0) chip_clk = ~chip_clk; end
  initial begin #4000; #(PHASE2 + PC2/2.0); forever #(PC2/2.0) clk90 = ~clk90; end

  // ======================================================================
  // resets
  // ======================================================================
  reg  rst_74a  = 1'b1;         // active-HIGH (74a/ctrl domain reset)
  wire rst_ctrl = ~rst_74a;     // the owner/slot take active-LOW
  reg  rst_mach = 1'b1;         // active-LOW: machine NOT in reset

  // ======================================================================
  // raw APF bridge signals (fake host; shared by storage + bridge, as in
  // the top). Only the 0x40xxxxxx savestate window is exercised; storage's
  // M0 image window is bridge_addr[31:26]==0 and stays untouched.
  // ======================================================================
  reg         bridge_rd = 1'b0;
  reg         bridge_wr = 1'b0;
  reg  [31:0] bridge_addr = 32'd0;
  reg  [31:0] bridge_wr_data = 32'd0;

  // ======================================================================
  // W1 client nets (slot/bridge <-> storage, exactly as the top routes them)
  // ======================================================================
  wire        ssrd_req;
  wire [23:0] ssrd_addr;
  wire        ssrd_done;
  wire [31:0] ssrd_data;
  wire        sswr_req;
  wire [23:0] sswr_addr;
  wire [31:0] sswr_data;
  wire        sswr_done, sswr_busy;
  wire        hr_req;
  wire [23:0] hr_addr;
  wire        hr_done;
  wire [31:0] hr_data;
  wire        hwr_req;
  wire [23:0] hwr_addr;
  wire [31:0] hwr_data;
  wire        hwr_done, hwr_busy;
  wire        port_wr_idle;

  // ======================================================================
  // M0 storage status (all connected, unused by this test)
  // ======================================================================
  wire        stor_init_done, stor_load_drained, stor_busy, stor_timeout;
  wire [23:0] stor_received, stor_committed;
  wire        stor_ovf;
  wire [8:0]  stor_hw;
  wire [31:0] stor_diag_rd;
  wire        stor_vdone, stor_vok, stor_vstuck;
  wire [31:0] stor_crc, stor_first, stor_last;
  wire [15:0] stor_vread;
  wire [127:0] stor_fp_first_m, stor_fp_last_m, stor_fp_w_m;
  wire [31:0] stor_nbytes_m;
  wire        stor_timeout_m, stor_ovf_m;
  wire        stor_res_valid_m;
  wire [1:0]  stor_res_code_m, stor_res_fail_m;
  wire [31:0] stor_res_crc_m, stor_res_nbytes_m;
  wire        stor_new_load_m;
  wire [2:0]  stor_stage_m;
  wire        stor_fetch_busy, stor_sector_ready, stor_sector_done, stor_fetch_fault;
  wire [15:0] stor_sector_lba;
  wire [8:0]  stor_sector_byte_addr;
  wire [7:0]  stor_sector_byte_data;

  // ======================================================================
  // fake machine side (same decode as the round-trip TB: words 0-7
  // writable, 8-10 read-only; RAM through the shipping apple2e_ram_bank)
  // ======================================================================
  wire        stall;
  reg  stall_d1 = 0, stall_d2 = 0;
  always @(posedge clk_mach) begin
    stall_d1 <= stall;
    stall_d2 <= stall_d1;
  end
  wire cpu_frozen = stall_d2;

  reg  [63:0] shadow_gold [0:10];   // what a healthy machine presents
  reg  [63:0] shadow_live [0:10];   // the machine's live state (restored)
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
    if (ss_wren && ss_addr < 10'd8)   // words 0-7 restored; 8-10 read-only
      shadow_live[ss_addr[3:0]] <= ss_wdata;
  end

  reg         m_ram_we = 0;
  reg  [17:0] m_ram_addr = 18'd0;
  reg  [7:0]  m_ram_di = 8'd0;
  reg         m_ram_aux = 0;
  wire [15:0] m_ram_do;
  wire        swp_done;

  // ======================================================================
  // DUTs: DRAM model + storage (with owner + port) + bridge + slot
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

  // DRAM pads (storage <-> model)
  reg  por_done = 1'b0;
  reg  fault_halt = 1'b0;
  wire [12:0] dram_a;
  wire [1:0]  dram_ba;
  wire [15:0] dram_dq;
  wire [1:0]  dram_dqm;
  wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

  tb_dram_model m0 (
    .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
    .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
    .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
    .fault_halt(fault_halt)
  );

  sdram_storage u_stor (
    .clk_74a(clk_74a), .sdram_path_rst(rst_74a),
    .bridge_wr(bridge_wr), .bridge_addr(bridge_addr),
    .bridge_wr_data(bridge_wr_data),
    .init_done(stor_init_done), .load_drained(stor_load_drained),
    .store_busy(stor_busy), .store_timeout(stor_timeout),
    .words_received(stor_received), .words_committed(stor_committed),
    .fifo_overflow(stor_ovf), .fifo_high_water(stor_hw),
    .diag_addr(16'd0), .diag_rd(1'b0), .diag_rd_data(stor_diag_rd),
    .diag_wr(1'b0), .diag_wr_sel(4'd0),
    .ds_requestwrite(1'b0), .ds_requestwrite_id(16'd0),
    .ds_requestwrite_size(32'd0), .ds_allcomplete(1'b0),
    .timeout_override(32'd0),
    .clk_mach(clk_mach), .rst_n_mach(~rst_74a),
    .ver_done(stor_vdone), .ver_ok(stor_vok), .ver_stuck(stor_vstuck),
    .ver_crc32(stor_crc), .ver_first_word(stor_first),
    .ver_last_word(stor_last), .ver_words_readout(stor_vread),
    .fp_first_m(stor_fp_first_m), .fp_last_m(stor_fp_last_m),
    .fp_w_m(stor_fp_w_m),
    .n_bytes_m(stor_nbytes_m), .store_timeout_m(stor_timeout_m),
    .fifo_overflow_m(stor_ovf_m),
    .res_valid_m(stor_res_valid_m), .res_code_m(stor_res_code_m),
    .res_fail_m(stor_res_fail_m), .res_crc_m(stor_res_crc_m),
    .res_nbytes_m(stor_res_nbytes_m),
    .new_load_m(stor_new_load_m), .stage_m(stor_stage_m),
    .fetch_req(1'b0), .fetch_lba(16'd0), .fetch_busy(stor_fetch_busy),
    .sector_ready(stor_sector_ready), .sector_lba(stor_sector_lba),
    .sector_byte_addr(stor_sector_byte_addr),
    .sector_byte_data(stor_sector_byte_data),
    .sector_done(stor_sector_done), .fetch_fault(stor_fetch_fault),
    .ctrl_clk(clk_ctrl), .chip_clk(chip_clk), .clk_90(clk90),
    .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq),
    .dram_dqm(dram_dqm), .dram_clk(dram_clk), .dram_cke(dram_cke),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
    // W1 savestate clients (the 2026-11-13 wiring under test)
    .ssrd_req(ssrd_req), .ssrd_addr(ssrd_addr),
    .ssrd_done(ssrd_done), .ssrd_data(ssrd_data),
    .sswr_req(sswr_req), .sswr_addr(sswr_addr), .sswr_data(sswr_data),
    .sswr_done(sswr_done), .sswr_busy(sswr_busy),
    .hr_req(hr_req), .hr_addr(hr_addr), .hr_done(hr_done), .hr_data(hr_data),
    .hwr_req(hwr_req), .hwr_addr(hwr_addr), .hwr_data(hwr_data),
    .hwr_done(hwr_done), .hwr_busy(hwr_busy),
    .port_wr_idle(port_wr_idle)
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
    .blob_wr_drained_74a(wr_drained_74a),   // from the bridge, as in the top
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
  // helpers
  // ======================================================================
  integer nfail = 0, i, w;

  // +H5DBG raw DRAM probe: model mem index for a 25-bit physical address.
  // The port drives addr = word_addr<<1 (io_sdram_pocket) and the model
  // indexes mem[{ba[1:0], row[12:0], col[9:0]}]; a 32-bit word lives at
  // HI16 = mem[idx(addr)], LO16 = mem[idx(addr+1)] (ST_WRITE_2/3 order).
  function automatic [24:0] m_idx(input [24:0] a);
    begin
      m_idx = {a[24:23], a[22:10], a[9:0]};
    end
  endfunction
  task automatic raw_word(input [23:0] waddr, output [31:0] d);
    reg [24:0] a25;
    begin
      a25 = waddr << 1;
      // ST_WRITE_2 puts wr_data[31:16] at a25 (lower phys addr), ST_WRITE_3
      // puts wr_data[15:0] at a25+1 - so the 32-bit word reads back as
      // { mem[a25], mem[a25+1] }.
      d = { m0.mem[m_idx(a25)], m0.mem[m_idx(a25 + 1'b1)] };
    end
  endtask

  // ---- CDC + hang diagnostics (2026-11-13: first bridge exercise) ----
  reg [15:0] c_dret = 0;                 // dret_cross events (host rd returns)
  always @(posedge clk_74a)
    if (u_bridge.dret_cross) c_dret <= c_dret + 1;

  reg [15:0] c_hr_done = 0;              // hr_done rising edges (ctrl ops done)
  reg        hr_done_d1 = 0;
  always @(posedge clk_ctrl)
    if (hr_done && !hr_done_d1) c_hr_done <= c_hr_done + 1;
  always @(posedge clk_ctrl)
    hr_done_d1 <= hr_done;

  // ---- R2 op tap (2026-11-17): per-op addr/data pipeline for +UNPACED ----
  // Off unless +UPTAP. Prints the bridge hwr pulse (FIFO head) and each
  // write-op start (owner->port word_addr/word_data at the port op-start
  // pulse) for the first 32 write ops. Uses port-level signals only
  // (internal regs can freeze under --binary --timing).
  reg         up_tap_en = 1'b0;
  reg [5:0]   up_tap_n  = 6'd0;
  reg         up_hwr_req_d = 1'b0;
  always @(posedge clk_ctrl) begin
    up_hwr_req_d <= hwr_req;
    if (up_tap_en && up_tap_n < 32) begin
      if (hwr_req && !up_hwr_req_d)
        $display("UPTAP HR-PULSE #0%0d @%0t hwr_addr=%06h hwr_data=%08h", up_tap_n,
                 $time, hwr_addr, hwr_data);
      if (u_stor.isr0.word_op_start && u_stor.owner0.word_wr)
        $display("UPTAP OPSTART  #0%0d @%0t word_addr=%06h word_data=%08h", up_tap_n,
                 $time, u_stor.owner0.word_addr, u_stor.owner0.word_data);
      if (hwr_req && !up_hwr_req_d || (u_stor.isr0.word_op_start && u_stor.owner0.word_wr))
        up_tap_n <= up_tap_n + 6'd1;
    end
  end
  initial if ($test$plusargs("UPTAP")) up_tap_en = 1'b1;

  // 2026-11-17: host load-write model selector (see the G5/UNPACED notes).
  // Default (0) = OBSERVED hardware host (SS HD capture): strips the file's
  // stale leading word, window k <- stored[k+1]. +CONTRACT = the old
  // documented (wrong) model: window k <- stored[k] with the stale at W0.
  reg contract = 1'b0;
  initial if ($test$plusargs("CONTRACT")) contract = 1'b1;

  reg [15:0] c_hwr_done = 0;             // hwr_done rising edges
  reg        hwr_done_d1 = 0;
  always @(posedge clk_ctrl)
    if (hwr_done && !hwr_done_d1) c_hwr_done <= c_hwr_done + 1;
  always @(posedge clk_ctrl)
    hwr_done_d1 <= hwr_done;

  // per-event ret diagnostics (kept slim: counters + hang dump; the
  // cycle-by-cycle RET-TR trace and CLK-PROBE were debug aids for the
  // 2026-11-13 bridge fixes and are removed)
  integer n_hr_evt;
  reg [15:0] c_retp_74 = 0;              // 74a samples of rd_ret_p==1
  always @(posedge clk_74a)
    if (u_bridge.rd_ret_p) c_retp_74 <= c_retp_74 + 1;
  always @(posedge clk_ctrl) begin
    if (hr_done && !hr_done_d1 && n_hr_evt < 1) begin
      n_hr_evt = n_hr_evt + 1;
      $display("HREVT0 @%0t: rd_wait=%b retp_r=%b rd_addr=%0d hr_addr=%0d",
        $time, u_bridge.rd_wait, u_bridge.rd_ret_p_r,
        u_bridge.rd_fifo_addr_c, hr_addr);
    end
  end

  reg        hang_seen = 0;
  reg        wr_started = 0;
  reg [31:0] hang_cnt = 0;
  always @(posedge clk_74a)
    if (bridge_wr & u_bridge.in_window) wr_started <= 1'b1;
  always @(posedge clk_74a) begin
    if (!hang_seen) begin
      if (wr_started && !wr_drained_74a) hang_cnt <= hang_cnt + 1;
      if (hang_cnt == 32'd200000) begin
        hang_seen <= 1'b1;
        $display("HANG-DUMP @%0t: rd_empty_c=%b wr_empty_c=%b rd_wait=%b | wr_infl=%b wr_watch=%0d hwr_busy=%b port_wr_idle=%b | hr_req=%b hr_done=%b | owner: init=%b busy=%b inflight=%b wcap_v=%b | c_dret=%0d c_hr_done=%0d c_hwr_done=%0d | rdf ptrs: rd=%b wr=%b | wrf ptrs: rd=%b wr=%b",
          $time, u_bridge.rd_empty_c, u_bridge.wr_empty_c, u_bridge.rd_wait,
          u_bridge.wr_inflight, u_bridge.wr_watch,
          hwr_busy, port_wr_idle, hr_req, hr_done,
          u_stor.owner0.init_done, u_stor.owner0.word_busy, u_stor.owner0.inflight,
          u_stor.owner0.wcap_valid, c_dret, c_hr_done, c_hwr_done,
          u_bridge.rdf.rd_ptr, u_bridge.rdf.wr_ptr, u_bridge.wrf.rd_ptr, u_bridge.wrf.wr_ptr);
      end
    end
  end
  reg [31:0] counter_cur = 32'd1;

  // +H5DBG cycle trace: bridge/owner/port/DRAM-bus/model, printed on change.
  reg        h5tr_en = 1'b0;
  reg [63:0] h5tr_prev = 64'd0;
  integer    h5tr_n = 0;
  wire [63:0] h5tr_pack = {
      22'd0,
      u_stor.isr0.state, u_stor.isr0.cmd, u_stor.isr0.phy_dq_oe,
      u_stor.isr0.phy_ba, dram_ras_n, dram_cas_n, dram_we_n, dram_cke,
      m0.c_cmd, m0.c_ba,
      u_stor.owner0.rd_grant, u_stor.owner0.inflight,
      u_stor.owner0.wcap_valid, u_stor.owner0.wcap_client,
      u_stor.ov_word_rd, u_stor.ov_word_wr, u_stor.ov_word_busy,
      u_stor.ov_word_done, u_stor.ov_word_rd_valid,
      u_stor.isr0.word_rd_queue, u_stor.isr0.word_wr_queue,
      hwr_req, hr_req,
      u_bridge.rd_wait, u_bridge.wr_inflight
  };
  always @(posedge clk_ctrl) begin
    if (h5tr_en) begin
      if (h5tr_pack !== h5tr_prev || h5tr_n == 0) begin
        h5tr_prev <= h5tr_pack;
        h5tr_n = h5tr_n + 1;
        $display("H5TR %0d @%0t: st=%0d cmd=%03b oe=%b pba=%02d pa=%05h dq=%04h | bus r/c/w=%b/%b/%b cke=%b | m0 ccmd=%03b cba=%02d ca=%03h dqm=%02b ref=%0d act0=%0d | grant=%0d infl=%0d wcap=%b/%0d waddr=%06h wdata=%08h | o:wr/rd/busy/done/rdv=%b/%b/%b/%b/%b | p:rdq/wrq=%b/%b hr/hwr=%b/%b brg:rdwait/wrinfl=%b/%b",
          h5tr_n, $time,
          u_stor.isr0.state, u_stor.isr0.cmd, u_stor.isr0.phy_dq_oe,
          u_stor.isr0.phy_ba, u_stor.isr0.phy_a, u_stor.isr0.phy_dq_out,
          dram_ras_n, dram_cas_n, dram_we_n, dram_cke,
          m0.c_cmd, m0.c_ba, m0.c_a, m0.c_dqm, m0.ref_cnt, m0.act_cnt[0],
          u_stor.owner0.rd_grant, u_stor.owner0.inflight,
          u_stor.owner0.wcap_valid, u_stor.owner0.wcap_client,
          u_stor.owner0.wcap_addr, u_stor.owner0.wcap_data,
          u_stor.ov_word_wr, u_stor.ov_word_rd, u_stor.ov_word_busy,
          u_stor.ov_word_done, u_stor.ov_word_rd_valid,
          u_stor.isr0.word_rd_queue, u_stor.isr0.word_wr_queue,
          hr_req, hwr_req,
          u_bridge.rd_wait, u_bridge.wr_inflight);
        if (h5tr_n >= 500) h5tr_en <= 1'b0;
      end
    end
  end
  reg [31:0] blob_save [0:32831];
  // G5: the REAL save from the Pocket SD (20261115_115718, diagnostic
  // bitstream). Blob bytes = file offset 592..592+131331 of the .sta
  // (592-byte SPA1 host header; the blob section is w1+4 = 32,833 words
  // incl. the host's stale leading word - 2026-11-15 offset correction:
  // the section starts at 592, NOT 600). The real file layout is
  // [stale][counter][size][{ver,cpu}][MAGIC][RAM...] - a VALID save; the
  // earlier "poisoned" reading was the 600-vs-592 parse error. Staged as
  // verilog/real_1157_blob.hex (one byte per line, $readmemh format)
  reg [7:0] real_blob [0:131331];
  // H6 reproduction (2026-11-17): real 592-byte SPA1 host header (file offset
  // 0..591, staged as verilog/real_hdr_592.hex). If the host firmware streams
  // the .sta from file offset 0 instead of the 592-byte-aligned blob section,
  // the window receives this header first and the blob lands shifted +148
  // words. Hardware 2026-11-17 11:34 build: loads fail fast with wr_ovf
  // CLEAR - consistent with this shape.
  reg [7:0] real_hdr [0:591];
  reg [15:0] c_pre = 0;
  reg        pre_d1 = 0;
  always @(posedge clk_74a) begin
    pre_d1 <= preload_req;
    if (preload_req && !pre_d1) c_pre <= c_pre + 16'd1;
  end

  // blob SDRAM word w (0..32831) lives at DRAM-model mem indices
  // 0x800000 + 2w (high 16) and + 2w+1 (low 16): the port dequeues with
  // word_addr<<1 and +1 between beats (io_sdram_pocket), the model is
  // faithful - do NOT "fix" this mapping.
  localparam [24:0] BLOB_MEM_BASE = 25'h800000;
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

  // the TB-side golden (mirrors what the bus writes put in the banks)
  reg  [7:0] golden_main [0:65535];
  reg  [7:0] golden_aux  [0:65535];

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

  // host window access (0x40xxxxxx): word w of the blob ->
  // bridge_addr = 0x40000000 + 4*w (win_word = bridge_addr[25:2] = w)
  task host_wr(input [15:0] w, input [31:0] data);
    begin
      @(negedge clk_74a);
      bridge_wr = 1'b1;
      bridge_addr = 32'h40000000 + 32'(w) * 32'd4;
      bridge_wr_data = data;
      @(negedge clk_74a);
      bridge_wr = 1'b0;
      // wait for the full drain (FIFO empty + no hwr op in flight) -
      // serializes each word; the FIFO is only 16 deep
      while (!wr_drained_74a) @(negedge clk_74a);
    end
  endtask

  // R2 (2026-11-17): UNPACED host write - the hardware-faithful shape. The
  // real APF bridge POSTS each word (no backpressure the core can assert)
  // at a documented worst case of one write per 88 clk_74a (~1.18 us,
  // ~844k words/s; io_bridge_peripheral.v:49). Unlike host_wr above this
  // does NOT wait for drain: at gap=88 the 16-deep host-write FIFO fills in
  // ~19 us, so a single LOST write request (H2: port write queue clears on
  // level fall / bridge FSM issues hwr_req with no port reservation) makes
  // the hwr client wait out its 30.8 us watchdog, during which the FIFO
  // overflows (wr_overflow_74a). Deterministic sim reproduction of the
  // hardware load wr_ovf; gap=1 (via +UNPACED_FAST) is the overload test.
  task host_wr_unpaced(input [15:0] w, input [31:0] data, input [15:0] gap);
    integer g;
    begin
      @(negedge clk_74a);
      bridge_wr = 1'b1;
      bridge_addr = 32'h40000000 + 32'(w) * 32'd4;
      bridge_wr_data = data;
      @(negedge clk_74a);
      bridge_wr = 1'b0;
      for (g = 0; g < gap - 16'd1; g = g + 1) @(negedge clk_74a);
    end
  endtask

  task host_rd(input [15:0] w, output [31:0] data);
    integer to;
    begin
      @(negedge clk_74a);
      bridge_rd = 1'b1;
      bridge_addr = 32'h40000000 + 32'(w) * 32'd4;
      @(negedge clk_74a);
      bridge_rd = 1'b0;
      // the hr op is ~25 ctrl cycles (~190 ns) + 3FF return; 1000 clk_74a
      // (~13.5 us) is ~70x margin
      to = 0;
      while (to < 1000) begin @(negedge clk_74a); to = to + 1; end
      data = br_rd_data;
    end
  endtask

  // G2b: fast host read - wait for this op's dret return edge instead of a
  // fixed 1000-cycle window (models "host samples when the data is back").
  // Validates the bridge/port path at FULL BURST scale (32,832 reads) - the
  // only way to exercise rd-FIFO depth/overflow and the return-pulse chain
  // across a whole save. The real host's FIXED latch window (if shorter than
  // the ~190 ns op + return time) is a host-side question, see
  // EXPERT_BRIEF_SAVESTATE_HARDWARE_SAVEFAIL_2026-11-14.md question 1.
  task host_rd_fast(input [15:0] w, output [31:0] data);
    integer to; reg [15:0] dret_prev;
    begin
      dret_prev = c_dret;
      @(negedge clk_74a);
      bridge_rd = 1'b1;
      bridge_addr = 32'h40000000 + 32'(w) * 32'd4;
      @(negedge clk_74a);
      bridge_rd = 1'b0;
      to = 0;
      while (c_dret <= dret_prev && to < 4000) begin @(negedge clk_74a); to = to + 1; end
      data = br_rd_data;
      if (to >= 4000) begin
        nfail = nfail + 1;
        $display("FAIL: G2b host-read %0d timed out (no dret; c_dret=%0d)", w, c_dret);
      end
    end
  endtask

  // per-op timeout (a full save/load is ~tens of ms of sim time)
  localparam [31:0] OP_TIMEOUT = 32'd8000000;

  task save_op(input string tag);
    integer to;
    begin
      @(negedge clk_74a);
      ss_start = 1'b1;
      to = 0;
      while (!ss_start_ack && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      // hold ~40 clk_74a (~8 mach cycles) - the mach-domain synch_3 .rise()
      // needs the high window to span a mach posedge AND fill its 3-FF chain
      repeat (40) @(negedge clk_74a);
      ss_start = 1'b0;
      to = 0;
      while ((ss_start_ok | ss_start_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      to = 0;
      while (!(ss_start_ok | ss_start_err) && to < OP_TIMEOUT) begin @(negedge clk_74a); to = to + 1; end
      if (to >= OP_TIMEOUT) begin
        nfail = nfail + 1;
        $display("FAIL: %s: save timed out (no ok/err)", tag);
        $display("  STUCK @%0t: mgr st=%0d byte_index=%0d | sswr st=%0d lasta=%0d busy=%b port_idle=%b",
          $time, u_slot.u_mgr.state, u_slot.u_mgr.byte_index,
          u_slot.sswr_st, u_slot.sswr_last_a, sswr_busy, port_wr_idle);
        $display("  STUCK2 @%0t: owner: busy=%b infl=%b wcap_v=%b cl=%0d a=%h d=%h | port: busy=%b rd=%b wr=%b a=%h | bridge: rd_wait=%b rd_empty=%b wr_infl=%b rdf=%b/%b wrf=%b/%b | sswr_req=%b ssrd_lvl=%b hr=%b hwr=%b cnts: dret=%0d hrdone=%0d hwrdone=%0d",
          $time, u_stor.owner0.word_busy, u_stor.owner0.inflight,
          u_stor.owner0.wcap_valid, u_stor.owner0.wcap_client,
          u_stor.owner0.wcap_addr, u_stor.owner0.wcap_data,
          u_stor.isr0.word_busy, u_stor.isr0.word_rd, u_stor.isr0.word_wr,
          u_stor.isr0.word_addr,
          u_bridge.rd_wait, u_bridge.rd_empty_c, u_bridge.wr_inflight,
          u_bridge.rdf.rd_ptr, u_bridge.rdf.wr_ptr,
          u_bridge.wrf.rd_ptr, u_bridge.wrf.wr_ptr,
          sswr_req, ssrd_req, hr_req, hwr_req,
          c_dret, c_hr_done, c_hwr_done);
        $display("  STUCK3 @%0t: port: state=%0d rdq=%b wrq=%b brdq=%b bwq=%b ref=%b a=%h len=%0d | owner: st=%b vr=%b fc=%b st_done=%b | bridge: rd_wait=%b wr_infl=%b",
          $time, u_stor.isr0.state, u_stor.isr0.word_rd_queue, u_stor.isr0.word_wr_queue,
          u_stor.isr0.burst_rd_queue, u_stor.isr0.burstwr_queue,
          u_stor.isr0.issue_autorefresh, u_stor.isr0.addr, u_stor.isr0.length,
          u_stor.owner0.st_req, u_stor.owner0.vr_req, u_stor.owner0.fc_req,
          u_stor.owner0.st_done, u_bridge.rd_wait, u_bridge.wr_inflight);
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
        $display("FAIL: %s: load timed out (no ok/err)", tag);
        $display("  STUCK @%0t: mgr st=%0d byte_index=%0d | ssrd st=%0d lasta=%0d port_idle=%b",
          $time, u_slot.u_mgr.state, u_slot.u_mgr.byte_index,
          u_slot.ssrd_st, u_slot.ssrd_last_a, port_wr_idle);
        $display("  STUCK2 @%0t: owner: busy=%b infl=%b wcap_v=%b cl=%0d a=%h d=%h | port: busy=%b rd=%b wr=%b a=%h | bridge: rd_wait=%b rd_empty=%b wr_infl=%b rdf=%b/%b wrf=%b/%b | sswr_req=%b ssrd_lvl=%b hr=%b hwr=%b cnts: dret=%0d hrdone=%0d hwrdone=%0d",
          $time, u_stor.owner0.word_busy, u_stor.owner0.inflight,
          u_stor.owner0.wcap_valid, u_stor.owner0.wcap_client,
          u_stor.owner0.wcap_addr, u_stor.owner0.wcap_data,
          u_stor.isr0.word_busy, u_stor.isr0.word_rd, u_stor.isr0.word_wr,
          u_stor.isr0.word_addr,
          u_bridge.rd_wait, u_bridge.rd_empty_c, u_bridge.wr_inflight,
          u_bridge.rdf.rd_ptr, u_bridge.rdf.wr_ptr,
          u_bridge.wrf.rd_ptr, u_bridge.wrf.wr_ptr,
          sswr_req, ssrd_req, hr_req, hwr_req,
          c_dret, c_hr_done, c_hwr_done);
        $display("  STUCK3 @%0t: port: state=%0d rdq=%b wrq=%b brdq=%b bwq=%b ref=%b a=%h len=%0d | owner: st=%b vr=%b fc=%b st_done=%b | bridge: rd_wait=%b wr_infl=%b",
          $time, u_stor.isr0.state, u_stor.isr0.word_rd_queue, u_stor.isr0.word_wr_queue,
          u_stor.isr0.burst_rd_queue, u_stor.isr0.burstwr_queue,
          u_stor.isr0.issue_autorefresh, u_stor.isr0.addr, u_stor.isr0.length,
          u_stor.owner0.st_req, u_stor.owner0.vr_req, u_stor.owner0.fc_req,
          u_stor.owner0.st_done, u_bridge.rd_wait, u_bridge.wr_inflight);
      end else if (ss_load_err !== expect_err) begin
        nfail = nfail + 1;
        $display("FAIL: %s: load err=%b expect=%b", tag, ss_load_err, expect_err);
      end
    end
  endtask

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
    $readmemh("real_1157_blob.hex", real_blob);
    $readmemh("real_hdr_592.hex", real_hdr);
    while (!stor_init_done) @(negedge clk_74a);
    repeat (50) @(negedge clk_74a);

    // ---- R2 (2026-11-17): +UNPACED - hardware-faithful load write-in ----
    // Writes the real 32,833-word blob at the documented worst-case host
    // rate (one posted write per <gap> clk_74a; default 88 = ~1.18 us,
    // ~844k words/s; +UNPACED_FAST => gap=1 overload test). At gap=88 the
    // 16-deep FIFO fills in ~19 us; a single lost write request (H2) makes
    // the hwr client wait out its 30.8 us watchdog, so the FIFO overflows.
    // REPRODUCTION mode: reports whether wr_ovf fires and whether the load
    // then accepts/rejects - early exit, does not gate the main suite.
    if ($test$plusargs("UNPACED")) begin
      integer k, to;
      reg [31:0] d;
      reg [15:0] gap;
      integer hshift, widx;
      gap = $test$plusargs("UNPACED_FAST") ? 16'd1 : 16'd88;
      hshift = $test$plusargs("HDRSHIFT") ? 1 : 0;
      if (hshift)
      if (hshift)
        $display("UNPACED+HDRSHIFT: writing 148 hdr words + 32833 blob words at gap=%0d (firmware offset-0 copy hypothesis)...", gap);
      else if (contract)
        $display("UNPACED+CONTRACT: writing 32833-word blob window k <- stored[k] (stale@W0, old documented model) at gap=%0d...", gap);
      else
        $display("UNPACED: writing 32832-word stripped blob window k <- stored[k+1] (observed host, 2026-11-17 SS HD) at gap=%0d (posted, no backpressure)...", gap);
      if (hshift)
        for (k = 0; k < 148; k = k + 1)
          host_wr_unpaced(k[15:0], {real_hdr[4*k], real_hdr[4*k+1],
                                    real_hdr[4*k+2], real_hdr[4*k+3]}, gap);
      for (k = contract ? 0 : 1; k < 32833; k = k + 1) begin
        widx = k - (contract ? 0 : 1) + (hshift ? 148 : 0);
        host_wr_unpaced(widx[15:0], {real_blob[4*k], real_blob[4*k+1],
                                  real_blob[4*k+2], real_blob[4*k+3]}, gap);
      end
      to = 0;
      while (!wr_drained_74a && to < 4000000) begin @(negedge clk_74a); to = to + 1; end
      $display("UNPACED: drain to=%0d drained=%b wr_ovf=%b", to, wr_drained_74a, wr_overflow_74a);
      host_rd(contract ? 16'd4 : 16'd3, d);
      $display("UNPACED: window word %0d (MAGIC) = %08h expect 41324c31", contract ? 4 : 3, d);
      // localize the landing: scan the window for the MAGIC word and the
      // size word (real readback path, not the artifact-prone model probe)
      begin
        integer s, hits;
        reg [31:0] sv;
        hits = 0;
        for (s = -256; s < 3072; s = s + 1) begin
          if (s >= 0) begin
            host_rd(s[15:0], sv);
            if (sv === 32'h41324C31) begin $display("UNPACED-scan MAGIC at window word %0d", s); hits = hits + 1; end
            else if (sv === 32'h00008040) begin $display("UNPACED-scan SIZE  at window word %0d", s); hits = hits + 1; end
          end
        end
        $display("UNPACED-scan done hits=%0d (0 = blob not in window 0..3071)", hits);
      end
      ss_load = 1'b1;
      to = 0;
      while (!ss_load_ack && to < 400000) begin @(negedge clk_74a); to = to + 1; end
      repeat (40) @(negedge clk_74a);
      ss_load = 1'b0;
      to = 0;
      while (!(ss_load_ok | ss_load_err) && to < 8000000) begin @(negedge clk_74a); to = to + 1; end
      $display("UNPACED: load done to=%0d ok=%b err=%b mgr_state=%0d",
               to, ss_load_ok, ss_load_err, u_slot.u_mgr.state);
      $display("UNPACED-VERDICT gap=%0d wr_ovf=%b load_ok=%b load_err=%b magic_ok=%b",
               gap, wr_overflow_74a, ss_load_ok, ss_load_err, (d === 32'h41324C31));
      if (hshift) begin
        // H6 reproduction: hardware shows SS LD -> immediate SS ERR with
        // wr_ovf CLEAR. Offset-0 streaming puts the SPA1 header in window
        // words 0..147 (word 4 = 0x672575BE, not MAGIC); the manager's size
        // check then reads header word 2 (0x54030200 > SS_SIZE_DWORDS) and
        // fails before the walk - no overflow possible (only ~33k words).
        $display("HDRSHIFT-VERDICT wr_ovf=%b load_ok=%b load_err=%b w4=%08h (hdr word 4 expect 0a000000)",
                 wr_overflow_74a, ss_load_ok, ss_load_err, d);
        if (wr_overflow_74a === 1'b0 && ss_load_ok === 1'b0 && ss_load_err === 1'b1)
          $display("HDRSHIFT-RESULT REPRODUCED");
        else
          $display("HDRSHIFT-RESULT UNEXPECTED");
      end
      else if (wr_overflow_74a === 1'b0 && ss_load_ok === 1'b1 && ss_load_err === 1'b0)
        $display("UNPACED-RESULT PASS");
      else
        $display("UNPACED-RESULT FAIL");
      $finish;
    end

    // ---- H5DBG: tagged host-window write probe (early exit) ----
    // Does an hwr word physically reach the DRAM model? Compare the host
    // readback against the raw model memory at the mapped physical address
    // and scan +-64 window words for the tag landing elsewhere.
    if ($test$plusargs("H5DBG")) begin
      begin
        reg [31:0] d, rd, tag;
        integer k, delta, hit;
        reg [15:0] win, winx;
        reg [23:0] waddr;

        // ---- clean cycle FIRST (system still fresh): one write, a real
        // idle gap, one read through the real paths. If readback == tag,
        // the write path lands fine when the attribution edge exists -
        // proving the write data path is sound and isolating the bug to
        // the back-to-back attribution deadlock the tag loop below trips.
        host_wr(16'h0300, 32'h1122_3344);
        repeat (200) @(negedge clk_ctrl);   // force a real idle gap
        host_rd(16'h0300, d);
        raw_word(24'h004_0000 + 16'h0300, rd);
        $display("H5DBG clean: expect=11223344 rdback=%08h raw=%08h", d, rd);

        for (k = 0; k < 3; k = k + 1) begin
          win = (k == 0) ? 16'd0 : ((k == 1) ? 16'h2000 : 16'h7FFF);
          tag = 32'hDEAD_BEEF;
          tag = tag + k;
          waddr = 24'h004_0000 + win;
          if (k == 0) h5tr_en = 1'b1;
          host_wr(win, tag);
          host_rd(win, d);
          raw_word(waddr, rd);
          $display("H5DBG tag%0d win=%05h: expect=%08h rdback=%08h raw=%08h wr_ovf=%b drained=%b",
            k, win, tag, d, rd, wr_overflow_74a, wr_drained_74a);
          hit = -1;
          for (delta = -64; delta <= 64; delta = delta + 1) begin
            if (hit == -1) begin
              winx = win + delta[15:0];
              raw_word(24'h004_0000 + winx, rd);
              if (rd === tag) hit = delta;
            end
          end
          if (hit == -1)
            $display("H5DBG tag%0d: tag NOT found in +-64 window words", k);
          else if (hit != 0)
            $display("H5DBG tag%0d: tag found at OFFSET %0d window words", k, hit);
        end
        $display("H5DBG probe done (wr_ovf=%b)", wr_overflow_74a);
        $finish;
      end
    end

    // distinct patterns in BOTH banks (the aux bank is the trap)
    for (i = 0; i < 65536; i = i + 1) begin
      golden_main[i] = 8'hA0 ^ i[7:0];
      golden_aux[i]  = 8'h5F ^ i[7:0] ^ i[15:12];
    end
    for (i = 0; i < 11; i = i + 1)
      shadow_gold[i] = 64'd0;
    shadow_gold[0] = 64'hC0DE_0000_0000_0001;
    shadow_gold[1] = 64'h1111_0000_0000_0011;
    shadow_gold[2] = 64'h2222_0000_0000_0022;
    shadow_gold[3] = {41'd0, 8'hFF, 8'h0F, 8'h5A};
    shadow_gold[4] = {38'd0, 1'b1, 1'b1, 16'hBEEF, 8'h77};
    shadow_gold[5] = 64'h1111_2222_3333_4444;
    shadow_gold[6] = 64'h1111_2222_3333_4444;
    shadow_gold[7] = 64'hAAAA_BBBB_CCCC_DDDD;
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

    // ---- T0: spot-check the fill ----
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

    // ================= G1: SAVE through storage =================
    // zero the blob window first (model a clean, empty slot: the manager
    // never writes the gap words 54..63)
    for (w = 0; w < 32832; w = w + 1)
      sdram_write(w[15:0], 32'd0);
    save_op("G1");
    check("G1 no err", ss_start_err === 1'b0);

    // the save-completion preload takes a few cycles; let it retire before
    // any host window read
    repeat (500) @(negedge clk_74a);
    check("G1 preload fired once", c_pre === 16'd1);
    $display("G1-SETTLE: c_dret=%0d c_retp_74=%0d rd_empty_c=%b rd_wait=%b rd_resp=%h | wr_empty_c=%b wr_drained=%b c_hr_done=%0d | rdf ptrs: rd=%b wr=%b",
      c_dret, c_retp_74, u_bridge.rd_empty_c, u_bridge.rd_wait, br_rd_data,
      u_bridge.wr_empty_c, wr_drained_74a, c_hr_done,
      u_bridge.rdf.rd_ptr, u_bridge.rdf.wr_ptr);

    begin
      integer mism;
      mism = 0;
      for (w = 0; w < 32832; w = w + 1) begin
        blob_save[w] = sdram_read(w[15:0]);
        if (blob_save[w] !== exp_sdram_word(w[15:0])) begin
          if (mism < 5)
            $display("FAIL: G1 blob word %0d = %h expect %h",
                     w, blob_save[w], exp_sdram_word(w[15:0]));
          mism = mism + 1;
        end
      end
      $display("     (G1 blob mismatches: %0d)", mism);
      check("G1 all 32832 blob words exact (sswr via storage)", mism == 0);
    end

    // ================= G2: HOST READ through the window =================
    // 16 window reads cover headers (0-3), shadow (32-35), RAM (64-67),
    // and the tail (32831)
    begin
      reg [31:0] d;
      host_rd(16'd0, d);
      $display("G2DBG rd(0): got %h exp %h dret=%0d rd_wait=%b", d, exp_sdram_word(16'd0), c_dret, u_bridge.rd_wait);
      check("G2 host-read word 0 (counter/size)", d === exp_sdram_word(16'd0));
      host_rd(16'd3, d);
      check("G2 host-read word 3 (MAGIC)", d === exp_sdram_word(16'd3));
      host_rd(16'd32, d);
      check("G2 host-read word 32 (shadow 0)", d === exp_sdram_word(16'd32));
      host_rd(16'd64, d);
      check("G2 host-read word 64 (RAM lo)", d === exp_sdram_word(16'd64));
      host_rd(16'd1000, d);
      check("G2 host-read word 1000", d === exp_sdram_word(16'd1000));
      host_rd(16'd16384, d);
      check("G2 host-read word 16384 (aux start)", d === exp_sdram_word(16'd16384));
      host_rd(16'd32831, d);
      check("G2 host-read word 32831 (tail)", d === exp_sdram_word(16'd32831));
      check("G2 no rd overflow", rd_overflow_74a === 1'b0);
    end

    // ================= G2b: FULL host read burst (32,832 words) =========
    // the real host reads the entire blob after each save; verify the bridge
    // services every op without overflow and returns exact data
    begin
      integer mism;
      reg [31:0] d;
      mism = 0;
      for (w = 0; w < 32832; w = w + 1) begin
        host_rd_fast(w[15:0], d);
        if (d !== exp_sdram_word(w[15:0])) begin
          if (mism < 5)
            $display("FAIL: G2b word %0d = %h expect %h", w, d, exp_sdram_word(w[15:0]));
          mism = mism + 1;
        end
      end
      $display("     (G2b full-burst mismatches: %0d)", mism);
      check("G2b all 32832 host-read words exact", mism == 0);
      check("G2b no rd overflow", rd_overflow_74a === 1'b0);
    end

    // ================= G3: HOST WRITE + LOAD through storage ============
    // corrupt the machine state
    mb_write(16'd77, 8'hDE, 1'b0);
    mb_write(16'd65535, 8'hAD, 1'b0);
    mb_write(16'd4242, 8'hBE, 1'b1);
    mb_write(16'd65535, 8'hEF, 1'b1);
    mb_write(16'd0, 8'h00, 1'b0);
    mb_write(16'd31337, 8'h55, 1'b1);
    shadow_live[0] = 64'hFFFF_FFFF_FFFF_FFFF;
    shadow_live[3] = 64'hFFFF_FFFF_FFFF_FFFF;

    // host writes the G1 blob back through the window in the OBSERVED
    // transport form (2026-11-17 SS HD capture): the host's load-write
    // strips the file's stale leading word, window k <- saved[k]. The
    // window becomes word-identical to the save-time window, which the
    // manager's load reads from BLOB_BASE (same base as save).
    $display("G3: writing 32832-word blob through the host window (stripped transport form)...");
    for (w = 0; w < 32832; w = w + 1)
      host_wr(w[15:0], blob_save[w]);
    check("G3 no wr overflow", wr_overflow_74a === 1'b0);

    load_op("G3", 1'b0);
    check("G3 no err", ss_load_err === 1'b0);
    begin
      reg [7:0] r;
      mb_read(r, 16'd77, 1'b0);
      check("G3 main[77] restored", r === golden_main[77]);
      mb_read(r, 16'd65535, 1'b0);
      check("G3 main[65535] restored", r === golden_main[65535]);
      mb_read(r, 16'd4242, 1'b1);
      check("G3 aux[4242] restored", r === golden_aux[4242]);
      mb_read(r, 16'd65535, 1'b1);
      check("G3 aux[65535] restored", r === golden_aux[65535]);
      mb_read(r, 16'd0, 1'b0);
      check("G3 main[0] restored", r === golden_main[0]);
      mb_read(r, 16'd31337, 1'b1);
      check("G3 aux[31337] restored", r === golden_aux[31337]);
      check("G3 shadow[0] restored", shadow_live[0] === shadow_gold[0]);
      check("G3 shadow[3] restored", shadow_live[3] === shadow_gold[3]);
    end

    // ================= G4: preload count =================
    check("G4 preload fired exactly once (save only)", c_pre === 16'd1);

    // ================= G5: the REAL Pocket SD save now LOADS =============
    // Feed the 32,832 words of the 11:57 .sta blob (STALE WORD STRIPPED -
    // the observed hardware host behavior, 2026-11-17 SS HD capture)
    // through the host window (hwr), then load. File layout is
    // [stale][counter][size][{ver,cpu}][MAGIC][RAM...]; the host's
    // load-write strips the stale word, so the window becomes
    // [counter][size][{ver,cpu}][MAGIC][RAM...] at W0.. - exactly the
    // save-time window, which the manager's load now reads from BLOB_BASE
    // (the 2026-11-15 +1 base was a file-only decode, off by one word;
    // it made hardware loads fail with fail_code 2 - see the SS HD brief).
    // +CONTRACT restores the old documented model (stale at W0), which the
    // corrected load base now REJECTS (header reads {counter,stale}/
    // {vercpu,size}).
    begin
      integer k;
      integer widx;
      reg [31:0] d;
      reg [7:0] r;
      $display("G5: writing the real 115718 blob (%0d words, %s) through the host window...",
               contract ? 32833 : 32832, contract ? "contract model" : "stripped (observed host)");
      for (k = contract ? 0 : 1; k < 32833; k = k + 1) begin
        widx = k - (contract ? 0 : 1);
        host_wr(widx[15:0], {real_blob[4*k], real_blob[4*k+1],
                          real_blob[4*k+2], real_blob[4*k+3]});
      end
      check("G5 no wr overflow", wr_overflow_74a === 1'b0);
      // sanity: the window now holds the host-transported layout
      host_rd(16'd0, d);
      check("G5 window word 0 = counter (2) / stale (0)",
            (contract && d === 32'd0) || (!contract && d === 32'd2));
      host_rd(contract ? 16'd2 : 16'd1, d);
      check("G5 window word (contract?2:1) = size (0x8040)", d === 32'h00008040);
      host_rd(contract ? 16'd4 : 16'd3, d);
      check("G5 window word (contract?4:3) = MAGIC", d === 32'h41324C31);
      load_op("G5-real", contract ? 1'b1 : 1'b0);   // contract model: expect REJECT now
      if (contract)
        check("G5 real-file load rejected (contract model)", ss_load_err === 1'b1);
      else
        check("G5 real-file load ok", ss_load_err === 1'b0);
      // machine RAM must match the file's RAM contents (spot checks).
      // Stripped window: Wk = save word k (window == save-time window).
      // main 64-bit word r: LO = save word 64+2r (bytes 8r..8r+3),
      // HI = 65+2r (bytes 8r+4..8r+7). main[77] = 8*9+5 -> HI of r=9 ->
      // save word 83 -> W83, byte 1 -> [23:16].
      host_rd(16'd83, d);
      mb_read(r, 16'd77, 1'b0);
      check("G5 main[77] == real-file byte", r === d[23:16]);
      // aux 64-bit word r: LO = save word 32832+2r. aux[4242] = 8*530+2 ->
      // LO of r=530 -> save word 33892 -> W33892, byte 2 -> [15:8].
      host_rd(16'd33892, d);
      mb_read(r, 16'd4242, 1'b1);
      check("G5 aux[4242] == real-file byte", r === d[15:8]);
      check("G5 manager busy released", u_slot.u_mgr.busy === 1'b0);
    end

    // ================= G6: SECOND-save protocol cycle ====================
    // The hardware save #2 wedge (20261115 screenshot: W=0000 B1 S0 after
    // a good save #1 + host burst) is reproduced here: refill the machine,
    // save AGAIN (save #2 - the wedge scenario), host-transport write, load,
    // verify restore. If the bridge rd path keeps any stale state from
    // cycle 1, save #2 or the load hangs/fails here.
    for (i = 0; i < 65536; i = i + 1) begin
      mb_write(i[15:0], golden_main[i], 1'b0);
      mb_write(i[15:0], golden_aux[i], 1'b1);
    end
    for (i = 0; i < 11; i = i + 1)
      shadow_live[i] = shadow_gold[i];
    for (w = 0; w < 32832; w = w + 1)
      sdram_write(w[15:0], 32'd0);
    save_op("G6-save2");
    check("G6 save2 no err", ss_start_err === 1'b0);
    begin
      integer k;
      reg [31:0] d;
      reg [7:0] r;
      host_rd(16'd0, d);
      check("G6 save2 counter = 3 (word 0)", d === 32'd3);
      // corrupt the live state (so the load is observable)
      mb_write(16'd77, 8'h00, 1'b0);
      mb_write(16'd4242, 8'h00, 1'b1);
      // host transport write (observed form, 2026-11-17: stripped - Wk <-
      // saved[k]; the blob differs from G1's only in the counter word - the
      // RAM/shadow refilled identically)
      host_wr(16'd0, d);                    // W0 = save2's counter (live word 0)
      for (k = 1; k < 32832; k = k + 1)
        host_wr(k[15:0], blob_save[k]);
      check("G6 no wr overflow", wr_overflow_74a === 1'b0);
      load_op("G6", 1'b0);
      check("G6 no err", ss_load_err === 1'b0);
      mb_read(r, 16'd77, 1'b0);
      check("G6 main[77] restored", r === golden_main[77]);
      mb_read(r, 16'd4242, 1'b1);
      check("G6 aux[4242] restored", r === golden_aux[4242]);
    end

    // ---- verdict ----
    if (nfail == 0)
      $display("SAVESTATE INTEGRATION TB: PASS (T0 fill, G1 save, G2+G2b host read (8+32832), G3 host-transport write+load, G4 preload, G5 real-file load, G6 second-save cycle)");
    else
      $display("SAVESTATE INTEGRATION TB: FAIL (%0d failures)", nfail);
    $finish;
  end

  // global watchdog: 400 ms sim time
  initial begin
    #400_000_000;
    $display("SAVESTATE INTEGRATION TB: FAIL (global watchdog timeout)");
    $finish;
  end

endmodule
