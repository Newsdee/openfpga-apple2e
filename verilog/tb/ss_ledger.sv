//
// ss_ledger.sv - shared tap/ledger for the savestate wedge hunt (2026-11-15)
//
// EXPERT_BRIEF_SAVESTATE_MINIREPRO_TB_2026-11-15.md §7 (A3/A4) + the
// pre-registered stuck-snapshot fields. Instantiated by
// tb_savestate_minirepro.sv and (on the pre-decided pivot) by the
// instrumented integration TB - the tap/ledger code is THIS file, so the
// pivot costs an include, not a rewrite.
//
// Taps (all sampled in the ctrl domain unless noted):
//  A3 fall-latch: every falling edge of a read-client level records
//     {cycle, port_state, rdq}. Fingerprint = fall while rdq==1 &&
//     state != ST_IDLE (the mechanism, fires long before the stuck timeout).
//  A4.1 op-start: word_busy rising -> {cycle, word_addr, inflight, rd_grant,
//     rd/wr kind}.
//  A4.2 completion: every word_rd_valid / word_done -> {cycle, inflight at
//     pulse, routed client, req of that client at that cycle}. The req
//     sample is the datum that catches `done_lvl & req` dropping a done.
//  hwr ledger: every write-client arm (wcap capture) and every word_done
//     attributed to a write client -> per-word {cycle, client, addr, data}.
//     G5's corruption class compares this against a start/done pairing.
//  Stuck detector: (any client level high | rd_wait) && port ST_IDLE &&
//     all four queues 0 && no completion for 4096 ctrl cycles -> STUCK
//     dump with the pre-registered equivalence fields.
//
// 5.050 $fwrite rule (workspace AGENTS.md): the number of
// specifiers must EXACTLY match the number of arguments (space-padding is
// trimmed by the runner; a mismatch corrupts the line).

`timescale 1ns/1ps
module ss_ledger (
    input  wire        clk_ctrl,
    input  wire        clk_74a,        // for the c_dret mirror edge clock
    input  wire        rst,               // active-LOW (wire rst_ctrl)
                                         // - the !rst branches are reset holds            // active-high reset (clear latches)
    input  wire [3:0]  gate_id,        // ledger file selector

    // ---- owner taps ----
    input  wire        word_busy,
    input  wire        word_rd,
    input  wire        word_wr,
    input  wire        word_done,
    input  wire        word_rd_valid,
    input  wire [23:0] word_addr,
    input  wire [2:0]  inflight,
    input  wire [2:0]  rd_grant,
    input  wire        vr_req,
    input  wire        fc_req,
    input  wire        hr_req,
    input  wire        ssrd_req,
    input  wire        wcap_valid,
    input  wire [2:0]  wcap_client,
    input  wire [23:0] wcap_addr,
    input  wire [31:0] wcap_data,

    // ---- port taps ----
    input  wire [5:0]  port_state,
    input  wire        word_rd_queue,
    input  wire        word_wr_queue,
    input  wire        burst_rd_queue,
    input  wire        burstwr_queue,
    input  wire [9:0]  refresh_count,

    // ---- bridge / TB counters ----
    input  wire        rd_wait,
    input  wire        rd_fifo_ne,        // rd FIFO non-empty (74a-domain
                                           // pointer compare done in TB)
    input  wire [31:0] c_dret,          // 74a-domain; sampled here for the
                                        // frozen-counter check only
    input  wire        gate_start,      // pulse: open a fresh ledger file
    input  wire        stuck_clear      // pulse: clear stuck_seen (new gate)
);

    // client id encoding = the owner's (0 none, 1 st, 2 vr, 3 fc, 4 hr,
    // 5 ssrd, 6 sswr, 7 hwr)
    localparam [5:0] ST_IDLE_P = 6'd7;  // port FSM ST_IDLE (io_sdram_pocket)
    localparam [31:0] STUCK_WIN = 32'd4096;

    // =====================================================================
    // A4.1 op-start taps
    // =====================================================================
    reg        busy_d = 1'b0;
    wire       op_start = word_busy && !busy_d;
    always @(posedge clk_ctrl)
        if (!rst) busy_d <= 1'b0;
        else       busy_d <= word_busy;

    // =====================================================================
    // A3 fall-latch: one slot per client (vr/fc/hr/ssrd)
    // =====================================================================
    reg        vr_f = 1'b0, fc_f = 1'b0, hr_f = 1'b0, ss_f = 1'b0;
    reg [31:0] fall_cycle   = 32'd0;
    reg [5:0]  fall_state   = 6'd0;
    reg        fall_rdq     = 1'b0;
    reg [3:0]  fall_client  = 4'd0;
    reg [31:0] fall_fp_cnt  = 32'd0;    // fingerprint count (fall while queued)
    always @(posedge clk_ctrl) begin
        if (!rst) begin
            vr_f <= 1'b0; fc_f <= 1'b0; hr_f <= 1'b0; ss_f <= 1'b0;
        end else begin
            vr_f <= vr_req; fc_f <= fc_req; hr_f <= hr_req; ss_f <= ssrd_req;
            // record the most recent fall (any client); the fingerprint is
            // combinational at the fall edge
            if (vr_f && !vr_req) begin
                fall_cycle <= $time; fall_state <= port_state;
                fall_rdq <= word_rd_queue; fall_client <= 4'd2;
                if (word_rd_queue && port_state != ST_IDLE_P)
                    fall_fp_cnt <= fall_fp_cnt + 32'd1;
            end else if (fc_f && !fc_req) begin
                fall_cycle <= $time; fall_state <= port_state;
                fall_rdq <= word_rd_queue; fall_client <= 4'd3;
                if (word_rd_queue && port_state != ST_IDLE_P)
                    fall_fp_cnt <= fall_fp_cnt + 32'd1;
            end else if (hr_f && !hr_req) begin
                fall_cycle <= $time; fall_state <= port_state;
                fall_rdq <= word_rd_queue; fall_client <= 4'd4;
                if (word_rd_queue && port_state != ST_IDLE_P)
                    fall_fp_cnt <= fall_fp_cnt + 32'd1;
            end else if (ss_f && !ssrd_req) begin
                fall_cycle <= $time; fall_state <= port_state;
                fall_rdq <= word_rd_queue; fall_client <= 4'd5;
                if (word_rd_queue && port_state != ST_IDLE_P)
                    fall_fp_cnt <= fall_fp_cnt + 32'd1;
            end
        end
    end
    wire level_high = vr_req || fc_req || ssrd_req || hr_req;

    // level-high PERSISTENCE counter: the wedge signature requires the
    // pending level to hold for the WHOLE window (a level that just armed
    // and starts its op 6 cycles later is not a wedge)
    reg [31:0] lev_cnt = 32'd0;
    always @(posedge clk_ctrl) begin
        if (!rst)         lev_cnt <= 32'd0;
        else if (level_high) lev_cnt <= (lev_cnt < STUCK_WIN) ? lev_cnt + 32'd1 : STUCK_WIN;
        else                 lev_cnt <= 32'd0;
    end

    // =====================================================================
    // completion tap bookkeeping (for the stuck detector's "no completion"
    // window) + A4.2 routed/req sample
    // =====================================================================
    wire any_done = word_done | word_rd_valid;
    reg [31:0] no_done_cnt = 32'd0;
    always @(posedge clk_ctrl) begin
        if (!rst)            no_done_cnt <= 32'd0;
        else if (any_done)   no_done_cnt <= 32'd0;
        else if (no_done_cnt < STUCK_WIN)
            no_done_cnt <= no_done_cnt + 32'd1;
    end

    // =====================================================================
    // stuck detector + pre-registered equivalence dump
    // =====================================================================
    reg        stuck_seen = 1'b0;
    wire        port_idle  = (port_state == ST_IDLE_P);
    wire        queues_0   = !(word_rd_queue | word_wr_queue
                               | burst_rd_queue | burstwr_queue);
    wire        stuck_now  = level_high && port_idle && queues_0
                             && (no_done_cnt >= STUCK_WIN)
                             && (lev_cnt >= STUCK_WIN)
                             && !stuck_seen;
    always @(posedge clk_ctrl) begin
        if (!rst || stuck_clear) begin
            stuck_seen <= 1'b0;
        end else if (stuck_now) begin
            stuck_seen <= 1'b1;
            $display("LEDGER-STUCK @%0t gate=%0d | FINGERPRINT fall-fp-count=%0d (last fall: cl=%0d st=%0d rdq=%b @%0t)",
                     $time, gate_id, fall_fp_cnt, fall_client,
                     fall_state, fall_rdq, fall_cycle);
            $display("  STUCK-MR pre-reg: port.state=%0d(IDLE=%0d) rdq=%b wrq=%b brdq=%b bwq=%b word_rd=%b rd_wait=%b c_dret=%0d frozen=%b | owner: infl=%0d grant=%0d wcap_v=%b cl=%0d a=%h d=%h | refresh_count=%0d",
                     port_state, port_idle, word_rd_queue, word_wr_queue,
                     burst_rd_queue, burstwr_queue, word_rd, rd_wait,
                     c_dret, (no_done_cnt >= STUCK_WIN),
                     inflight, rd_grant, wcap_valid, wcap_client,
                     wcap_addr, wcap_data, refresh_count);
        end
    end

    // =====================================================================
    // $fwrite ledgers (one file per gate) - Verilator 5.050: specifier
    // count == argument count, always.
    // =====================================================================
    integer lf;
    reg [1:0] gs_d = 2'd0;
    always @(posedge clk_ctrl) begin
        gs_d <= {gs_d[0], gate_start};
        if (gate_start && !gs_d[0] && lf == 0) begin
            lf = $fopen($sformatf("ledger_g%0d.csv", gate_id));
            if (lf)
                $fwrite(lf, "kind,clk_t,client,addr,data,inflight,grant,rd,wr,state,rdq,wrq,brdq,bwq,req_v,req_f,req_h,req_s,ref,rdwait,cdret\n");
        end
    end

    // A4.1 op-start rows
    always @(posedge clk_ctrl) begin
        if (lf && op_start)
            $fwrite(lf, "start,%0d,%0d,%0d,0,%0d,%0d,%b,%b,%0d,%b,%b,%b,%b,0,0,0,0,%0d,0,%0d\n",
                     $time, 4'd0, word_addr, inflight, rd_grant,
                     word_rd, word_wr, port_state, word_rd_queue,
                     word_wr_queue, burst_rd_queue, burstwr_queue,
                     refresh_count, c_dret);
    end

    // A4.2 completion rows: routed client + its req at that cycle
    always @(posedge clk_ctrl) begin
        reg [3:0] routed; reg [3:0] rreq;
        if (lf && any_done) begin
            case (inflight)
                3'd2:    begin routed = 4'd2; rreq = vr_req;  end
                3'd3:    begin routed = 4'd3; rreq = fc_req;  end
                3'd4:    begin routed = 4'd4; rreq = hr_req;  end
                3'd5:    begin routed = 4'd5; rreq = ssrd_req; end
                3'd6:    begin routed = 4'd6; rreq = 1'b0;    end
                3'd7:    begin routed = 4'd7; rreq = 1'b0;    end
                default: begin routed = 4'd0; rreq = 1'b0;    end
            endcase
            $fwrite(lf, "done,%0d,%0d,0,0,%0d,0,%b,%b,%0d,%b,%b,%b,%b,%b,%b,%b,%b,%0d,%b,%0d\n",
                     $time, routed, inflight, word_rd, word_wr, port_state,
                     word_rd_queue, word_wr_queue, burst_rd_queue,
                     burstwr_queue, vr_req, fc_req, hr_req, ssrd_req,
                     refresh_count, rd_wait, c_dret);
        end
    end

    // A3 fall-latch rows (every read-level fall, with the fingerprint bit)
    wire fall_edge = (vr_f && !vr_req) || (fc_f && !fc_req)
                   || (hr_f && !hr_req) || (ss_f && !ssrd_req);
    always @(posedge clk_ctrl) begin
        if (lf && fall_edge)
            $fwrite(lf, "fall,%0d,%0d,0,0,0,0,0,0,%0d,%b,0,0,0,0,0,0,0,%0d,0,0\n",
                     $time, fall_client, port_state, word_rd_queue,
                     refresh_count);
    end

    // hwr / wcap ledger rows (G5 corruption class): arm (wcap capture) and
    // write-done, per word
    reg wcap_d = 1'b0;
    always @(posedge clk_ctrl) begin
        if (!rst) wcap_d <= 1'b0;
        else      wcap_d <= wcap_valid;
        if (lf) begin
            if (wcap_valid && !wcap_d)
                $fwrite(lf, "wcap,%0d,%0d,%0d,%0d,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n",
                         $time, wcap_client, wcap_addr, wcap_data);
            if (word_done && (inflight == 3'd6 || inflight == 3'd7))
                $fwrite(lf, "wdone,%0d,%0d,%0d,%0d,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n",
                         $time, inflight, word_addr, wcap_data);
        end
    end

endmodule
