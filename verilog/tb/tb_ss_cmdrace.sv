// tb_ss_cmdrace.sv
// ============================================================================
// Step-1 sim repro of the L0 stale-ack command race
// (EXPERT_BRIEF_SAVESTATE_WEDGE_MACH_SIDE_2026-11-16.md §9 Step 1;
//  EXPERT_BRIEF_SAVESTATE_WEDGE_MACH_SIDE_2026-11-16_REVISION.md §D).
//
// DUT: REAL core_bridge_cmd (host command FSM, incl. the 0x00A0 handler) +
// REAL savestate_slot (command front-end: synch_3 pulse catch, pender, ack,
// 74a inflight/ok/err, manager, walkers). The SDRAM word side (sswr/ssrd)
// is served by a TB auto-responder; the host's dataslot/RTC/target traffic
// is tied off.
//
// clk_mach is a period-6 grid on clk_74a (81 ns = 12.35 MHz, slower than
// 74a as in the real design). The RELATIVE PHASE between the host command
// timing and the mach grid is swept by +PH0..+PH5, which set a 0..5-cycle
// delay before issueing command #2 (the real host's poll period is software
// timing - effectively a phase offset against the mach grid). A fixed clock
// phase shift instead would be degenerate (everything derives from clk_74a,
// so the level window stays locked to the grid).
//
// One run = one sweep value = one cold power-up followed by two sequential
// save commands, exactly the field sequence (save #1 OK, save #2 wedges).
//
// Verdict lines (stdout):
//   PHASE=<p> cmd1=<OK|ERR|TIMEOUT> cmd2=<OK|NOOK|LOST> inflight=<b> busy=<b> mgr_st=<d>
//   CMDRACE RUN DONE
//
// Expectations:
//   UNFIXED RTL: cmd1 OK in all phases; cmd2 accepted phase-dependently
//   (stale-ack race releases the level after ~27 ns < one mach cycle).
//   FIXED RTL (Step 2+3): cmd1+cmd2 OK in ALL phases.
// ============================================================================

module tb_ss_cmdrace;

  // ------------------------------------------------------------------ clocks
  // 74a domain: 74.25 MHz (13.5 ns). mach domain: period-6 derivative of 74a
  // (6 x 13.5 = 81 ns = 12.35 MHz), phase = index into the shift register.
  reg clk_74a  = 1'b0;
  wire clk_mach;   // generated below (phase-shifted)
  localparam T74 = 13.5;   // ns per 74a cycle

  reg [2:0] mcnt = 3'd0;   // free-running 0..5
  reg [5:0] msh  = 6'b0;   // phase shift register of the base mach edge
  reg [2:0] ph   = 3'd0;   // pre-cmd2 issue delay (relative phase sweep)

  initial begin
    if ($test$plusargs("PH1")) ph = 3'd1;
    if ($test$plusargs("PH2")) ph = 3'd2;
    if ($test$plusargs("PH3")) ph = 3'd3;
    if ($test$plusargs("PH4")) ph = 3'd4;
    if ($test$plusargs("PH5")) ph = 3'd5;
  end

  initial forever #(T74/2) clk_74a = ~clk_74a;

  always @(posedge clk_74a) begin
    mcnt <= (mcnt == 3'd5) ? 3'd0 : mcnt + 3'd1;
    msh  <= {msh[4:0], (mcnt < 3'd3)};   // base mach edge every 6 cycles
  end
  assign clk_mach = msh[3'd0];

  // ctrl domain = 74a domain (ratio irrelevant to this mechanism)
  wire clk_ctrl = clk_74a;

  // ------------------------------------------------------------------ resets
  reg rst_74a  = 1'b1;   // active-high
  reg rst_mach = 1'b0;   // active-LOW: 0 = IN reset
  reg rst_ctrl = 1'b0;   // active-LOW: 0 = IN reset

  // ------------------------------------------------------------------ wires
  wire        host_reset_n;
  wire [31:0] host_bridge_rd_data;
  wire        savestate_start, savestate_load;
  wire        savestate_start_ack, savestate_load_ack;
  wire        savestate_start_busy, savestate_load_busy;
  wire        savestate_start_ok, savestate_load_ok;
  wire        savestate_start_err, savestate_load_err;
  wire        preload_req;
  wire        ssdbg_stall;
  wire [3:0]  ssdbg_retry;
  wire [15:0] ssdbg_word;
  wire [15:0] ssdbg_state;
  wire        stall, machine_ce;
  wire [9:0]  ss_addr;
  wire [63:0] ss_wdata;
  wire        ss_wren;
  wire        ram_bank, ram_rd, ram_wr;
  wire [15:0] ram_addr;
  wire [7:0]  ram_wdata;
  wire        ssrd_req;
  wire [23:0] ssrd_addr;
  wire        sswr_req;
  wire [23:0] sswr_addr;
  wire [31:0] sswr_data;
  reg         sswr_done = 1'b0;
  reg         ssrd_done = 1'b0;

  // host bridge-drive regs
  reg         bridge_wr = 1'b0;
  reg  [31:0] bridge_addr = 32'd0;
  reg  [31:0] bridge_wr_data = 32'd0;

  // tied-off host-side inputs
  wire ds_rr, ds_rw, ds_upd, ds_allc;
  wire [15:0] ds_rr_id, ds_rw_id, ds_upd_id;
  wire [31:0] ds_rw_size, ds_upd_size;
  wire target_ack, target_done;
  wire [2:0] target_err;
  wire [31:0] dt_q;
  wire osnotify;

  // ================================================================== DUTs
  core_bridge_cmd u_host (
    .clk                   ( clk_74a ),
    .reset_n               ( host_reset_n ),
    .bridge_endian_little  ( 1'b0 ),   // TB: raw word order (no byte swap)
    .bridge_addr           ( bridge_addr ),
    .bridge_rd             ( 1'b0 ),
    .bridge_rd_data        ( host_bridge_rd_data ),
    .bridge_wr             ( bridge_wr ),
    .bridge_wr_data        ( bridge_wr_data ),
    .status_boot_done      ( 1'b1 ),
    .status_setup_done     ( 1'b1 ),
    .status_running        ( 1'b1 ),
    .dataslot_requestread  ( ds_rr ),
    .dataslot_requestread_id ( ds_rr_id ),
    .dataslot_requestread_ack ( 1'b1 ),
    .dataslot_requestread_ok  ( 1'b1 ),
    .dataslot_requestwrite ( ds_rw ),
    .dataslot_requestwrite_id ( ds_rw_id ),
    .dataslot_requestwrite_size ( ds_rw_size ),
    .dataslot_requestwrite_ack ( 1'b1 ),
    .dataslot_requestwrite_ok  ( 1'b1 ),
    .dataslot_update       ( ds_upd ),
    .dataslot_update_id    ( ds_upd_id ),
    .dataslot_update_size  ( ds_upd_size ),
    .dataslot_allcomplete  ( ds_allc ),
    .rtc_epoch_seconds     ( ),
    .rtc_date_bcd          ( ),
    .rtc_time_bcd          ( ),
    .rtc_valid             ( ),
    .savestate_supported   ( 1'b1 ),
    .savestate_addr        ( 32'h040_0000 ),
    .savestate_size        ( 32'd32832 ),
    .savestate_maxloadsize ( 32'd32832 ),
    .savestate_status      ( 32'd0 ),
    .osnotify_inmenu       ( osnotify ),
    .savestate_start       ( savestate_start ),
    .savestate_start_ack   ( savestate_start_ack ),
    .savestate_start_busy  ( savestate_start_busy ),
    .savestate_start_ok    ( savestate_start_ok ),
    .savestate_start_err   ( savestate_start_err ),
    .savestate_load        ( savestate_load ),
    .savestate_load_ack    ( savestate_load_ack ),
    .savestate_load_busy   ( savestate_load_busy ),
    .savestate_load_ok     ( savestate_load_ok ),
    .savestate_load_err    ( savestate_load_err ),
    .target_dataslot_read  ( 1'b0 ),
    .target_dataslot_write ( 1'b0 ),
    .target_dataslot_getfile ( 1'b0 ),
    .target_dataslot_openfile ( 1'b0 ),
    .target_dataslot_ack   ( target_ack ),
    .target_dataslot_done  ( target_done ),
    .target_dataslot_err   ( target_err ),
    .target_dataslot_id    ( 16'd0 ),
    .target_dataslot_slotoffset ( 32'd0 ),
    .target_dataslot_bridgeaddr ( 32'd0 ),
    .target_dataslot_length ( 32'd0 ),
    .target_buffer_param_struct ( 32'd0 ),
    .target_buffer_resp_struct ( 32'd0 ),
    .datatable_addr        ( 10'd0 ),
    .datatable_wren        ( 1'b0 ),
    .datatable_data        ( 32'd0 ),
    .datatable_q           ( dt_q )
  );

  savestate_slot u_slot (
    .clk_74a               ( clk_74a ),
    .rst_74a               ( rst_74a ),
    .savestate_start       ( savestate_start ),
    .savestate_load        ( savestate_load ),
    .blob_wr_drained_74a   ( 1'b1 ),
    .savestate_start_ack   ( savestate_start_ack ),
    .savestate_start_busy  ( savestate_start_busy ),
    .savestate_start_ok    ( savestate_start_ok ),
    .savestate_start_err   ( savestate_start_err ),
    .savestate_load_ack    ( savestate_load_ack ),
    .savestate_load_busy   ( savestate_load_busy ),
    .savestate_load_ok     ( savestate_load_ok ),
    .savestate_load_err    ( savestate_load_err ),
    .preload_req           ( preload_req ),
    .dbg_sswr_stall        ( ssdbg_stall ),
    .dbg_sswr_retry        ( ssdbg_retry ),
    .dbg_word_idx          ( ssdbg_word ),
    .dbg_ss_state          ( ssdbg_state ),
    .clk_mach              ( clk_mach ),
    .rst_mach              ( rst_mach ),
    .cpu_type              ( 1'b0 ),
    .cpu_frozen            ( 1'b1 ),
    .stall                 ( stall ),
    .machine_ce            ( machine_ce ),
    .ss_addr               ( ss_addr ),
    .ss_wdata              ( ss_wdata ),
    .ss_wren               ( ss_wren ),
    .ss_rdata              ( 64'd0 ),
    .ram_bank              ( ram_bank ),
    .ram_addr              ( ram_addr ),
    .ram_rd                ( ram_rd ),
    .ram_wr                ( ram_wr ),
    .ram_wdata             ( ram_wdata ),
    .ram_rdata             ( 8'hA5 ),
    .clk_ctrl              ( clk_ctrl ),
    .rst_ctrl              ( rst_ctrl ),
    .ssrd_req              ( ssrd_req ),
    .ssrd_addr             ( ssrd_addr ),
    .ssrd_done             ( ssrd_done ),
    .ssrd_data             ( 32'hDEAD_BEEF ),
    .sswr_req              ( sswr_req ),
    .sswr_addr             ( sswr_addr ),
    .sswr_data             ( sswr_data ),
    .sswr_done             ( sswr_done ),
    .sswr_busy             ( 1'b0 ),
    .port_wr_idle          ( 1'b1 )
  );

  // ------------------------------------------------------------------ TB
  // SDRAM word auto-responder (services the manager walk so ops complete):
  // sswr: one done pulse one cycle after each req pulse (slot waits in
  // inflight for it). ssrd: level held while the request is held.
  always @(posedge clk_74a) begin
    sswr_done <= sswr_req;
    ssrd_done <= ssrd_req;
  end

  // ------------------------------------------------------------------ tasks
  task host_wr(input [31:0] a, input [31:0] d);
    begin
      @(negedge clk_74a);
      bridge_wr = 1'b1; bridge_addr = a; bridge_wr_data = d;
      @(negedge clk_74a);
      bridge_wr = 1'b0; bridge_addr = 32'd0; bridge_wr_data = 32'd0;
    end
  endtask

  // host save request: param(0x20)=request bit, then command (0x00)
  task issue_save;
    begin
      host_wr(32'hF800_0020, 32'h0000_0001);
      host_wr(32'hF800_0000, 32'h434D_00A0);
    end
  endtask

  // wait for the start op to finish (ok / err / timeout)
  task wait_save_done(output reg ok, output reg to, input integer lim);
    integer i;
    begin
      ok = 1'b0; to = 1'b0;
      for (i = 0; i < lim; i = i + 1) begin
        if (savestate_start_ok) begin ok = 1'b1; return; end
        if (savestate_start_err) return;
        @(negedge clk_74a);
      end
      to = 1'b1;
    end
  endtask

  // cmd2 level-window log: track savestate_start, mach chain, pend, mgr
  // around the second command's level window (+WLOG only).
  // w2mode is set by the main thread after issue_save #2 returns.
  reg wlog;
  reg w2mode = 1'b0;
  reg [1:0] w2st = 2'd0;   // 0=idle 1=wait-for-start 2=in-window 3=tail
  integer wtail;
  initial if ($test$plusargs("WLOG")) wlog = 1'b1; else wlog = 1'b0;
  always @(posedge clk_74a) begin
    if (wlog && w2mode) begin
      case (w2st)
        2'd1: begin
          if (savestate_start) w2st = 2'd2;
        end
        2'd2: begin
          if (!savestate_start) begin wtail = 8; w2st = 2'd3; end
        end
        2'd3: begin
          if (wtail == 0) w2mode = 1'b0;
          else wtail = wtail - 1;
        end
        default: ;
      endcase
      if (savestate_start || w2st == 2'd3) begin
        $display("W2 t=%0t mcnt=%0d start=%b s1=%b o=%b s3=%b rise=%b pend=%b go=%b mgr=%0d",
          $time, mcnt, savestate_start, u_slot.s_start.stage_1,
          u_slot.s_start.o, u_slot.s_start.stage_3, u_slot.start_rise_m,
          u_slot.start_pend, u_slot.start_go, u_slot.u_mgr.state);
      end
    end else if (w2mode) begin
      // +WLOG not set: arm the state machine anyway (harmless)
      w2st = 2'd1;
    end
  end
  always @(posedge clk_74a) if (w2mode && w2st == 2'd0) w2st = 2'd1;

  // replay regression (EXPERT_BRIEF §10): count manager IDLE->active
  // transitions. Two commands + two full op completions must produce
  // EXACTLY two acceptances - a stale-pend ghost save would add a third.
  integer acc_count;
  reg [4:0] mgr_prev;
  always @(posedge clk_74a) begin
    mgr_prev <= u_slot.u_mgr.state;
    if (mgr_prev == 5'd0 && u_slot.u_mgr.state != 5'd0)
      acc_count = acc_count + 1;
  end
  initial acc_count = 0;

  // ================================================================== main
  integer i;
  reg ok1, to1, ok2, to2;
  reg acc2;
  reg cmd1_err;
  reg dbg;
  integer mach_edges;
  integer sswr_cnt;
  reg [1:0] c1 = 2'd0;
  reg [1:0] c2 = 2'd3;
  reg replay_ok;

  initial if ($test$plusargs("DBG")) dbg = 1'b1; else dbg = 1'b0;

  // mach-edge counter (debug)
  initial begin
    mach_edges = 0; sswr_cnt = 0;
    forever begin
      @(posedge clk_mach); mach_edges = mach_edges + 1;
    end
  end
  always @(posedge clk_74a) if (sswr_req) sswr_cnt = sswr_cnt + 1;

  // debug poll: first ~2.7 ms, every 1000 74a cycles (+DBG only)
  initial begin
    integer d;
    if (!dbg) #1;
    else begin
      for (d = 0; d < 200; d = d + 1) begin
        #13500;   // 1000 74a cycles
        $display("DBG t=%0t start=%b s1=%b o=%b s3=%b rise_m=%b pend=%b go=%b mgr=%0d ack=%b inf=%b rsm=%b mach_e=%0d sswr=%0d",
          $time, savestate_start,
          u_slot.s_start.stage_1, u_slot.s_start.o, u_slot.s_start.stage_3,
          u_slot.start_rise_m, u_slot.start_pend, u_slot.start_go, u_slot.u_mgr.state,
          savestate_start_ack, u_slot.start_inflight_r, rst_mach,
          mach_edges, sswr_cnt);
      end
    end
  end

  initial begin
    // cold power-up (rst_mach is active-LOW: 0 = in reset)
    rst_74a = 1'b1; rst_mach = 1'b0; rst_ctrl = 1'b0;
    repeat (50)  @(negedge clk_74a);
    rst_74a = 1'b0;
    repeat (30)  @(negedge clk_74a);
    rst_ctrl = 1'b1;
    repeat (120) @(negedge clk_74a);
    rst_mach = 1'b1;
    repeat (300) @(negedge clk_74a);

    // ---------- command 1 (cold: start_ack_r = 0 at power-up) ----------
    issue_save;
    wait_save_done(ok1, to1, 9000000);   // ~120 ms sim: full bit-serial walk + margin
    cmd1_err = savestate_start_err;
    repeat (100) @(negedge clk_74a);    // let busy fall / ack self-hold settle

    // ---------- command 2 (stale-ack condition) ----------
    // relative-phase sweep: delay the issue by ph 74a cycles (real host
    // poll timing vs the mach grid)
    if (ph != 0) repeat (ph) @(negedge clk_74a);
    acc2 = 1'b0;
    issue_save;
    w2mode = 1'b1;
    ok2 = 1'b0; to2 = 1'b0;
    for (i = 0; i < 100000; i = i + 1) begin
      @(negedge clk_74a);
      if (u_slot.u_mgr.state != 5'd0) begin
        acc2 = 1'b1;
        break;
      end
    end
    if (acc2)
      wait_save_done(ok2, to2, 9000000);

    // verdict codes: 00=OK 01=ERR 10=TIMEOUT 11=LOST
    // (string %s gets width-padded by this Verilator build - codes are robust)
    if (ok1 && !to1)      c1 = 2'd0;
    else if (cmd1_err)    c1 = 2'd1;
    else                  c1 = 2'd2;
    if (acc2 && ok2)      c2 = 2'd0;
    else if (acc2)        c2 = 2'd1;   // accepted but op did not complete
    // else c2 = 2'd3 (LOST)
    replay_ok = (acc_count == 2);

    $display("PHASE=%0d c1=%b c2=%b acc=%0d replay_ok=%b inflight=%b busy=%b mgr_st=%0d",
             ph, c1, c2, acc_count, replay_ok,
             u_slot.start_inflight_r, savestate_start_busy,
             u_slot.u_mgr.state);
    $display("CMDRACE RUN DONE");
    #2000;
    $finish;
  end

  // global watchdog: never trust an unreported run
  initial begin
    #400_000_000;   // 400 ms sim
    $display("CMDRACE TB: FAIL (global watchdog)");
    $finish;
  end

endmodule
