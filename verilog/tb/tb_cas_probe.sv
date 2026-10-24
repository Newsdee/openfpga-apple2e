// tb_cas_probe.sv - one write + one read through io_sdram_pocket +
// tb_dram_model, with exact tick logging to pin the DQ alignment.
// Build/run per run_m0m1_regress recipe (verilator --binary --timing).
`timescale 1ns/1ps
module tb_cas_probe;

    localparam real PC = 3.756;   // 133.12 MHz half period

    reg  clk_74a;
    reg  path_rst;
    reg  ctrl_clk, chip_clk, clk90;
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire [15:0] dram_dq;
    wire [1:0]  dram_dqm;
    wire dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

    reg  [31:0] word_data;
    reg  [23:0] word_addr;
    reg         word_rd, word_wr;
    wire [31:0] word_q;
    wire        word_busy, word_done, word_rd_valid;
    wire        boot_done;

    io_sdram_pocket #(.BOOT_CYCLES(300)) isr0 (
        .controller_clk  ( ctrl_clk ),
        .chip_clk        ( chip_clk ),
        .clk_90          ( clk90 ),
        .reset_n         ( 1'b1 ),
        .phy_cke         ( dram_cke ),
        .phy_clk         ( dram_clk ),
        .phy_cas         ( dram_cas_n ),
        .phy_ras         ( dram_ras_n ),
        .phy_we          ( dram_we_n ),
        .phy_ba          ( dram_ba ),
        .phy_a           ( dram_a ),
        .phy_dq          ( dram_dq ),
        .phy_dqm         ( dram_dqm ),
        .burst_rd        ( 1'b0 ),
        .burst_addr      ( 25'd0 ),
        .burst_len       ( 11'd0 ),
        .burst_32bit     ( 1'b0 ),
        .burst_data      ( ),
        .burst_data_valid( ),
        .burst_data_done ( ),
        .burstwr         ( 1'b0 ),
        .burstwr_addr    ( 15'd0 ),
        .burstwr_ready   ( ),
        .burstwr_strobe  ( 1'b0 ),
        .burstwr_data    ( 16'd0 ),
        .burstwr_done    ( 1'b0 ),
        .word_rd         ( word_rd ),
        .word_wr         ( word_wr ),
        .word_addr       ( word_addr ),
        .word_data       ( word_data ),
        .word_q          ( word_q ),
        .word_busy       ( word_busy ),
        .word_done       ( word_done ),
        .word_rd_valid   ( word_rd_valid ),
        .boot_done       ( boot_done )
    );

    reg por_done = 1'b0;
    reg fault_halt = 1'b0;
    tb_dram_model m0 (
        .clk(dram_clk), .cke(dram_cke), .ras(dram_ras_n),
        .cas(dram_cas_n), .we(dram_we_n), .por_done(por_done),
        .ba(dram_ba), .a(dram_a), .dq(dram_dq), .dqm(dram_dqm),
        .fault_halt(fault_halt),
        .trace_req(1'b0)
    );

    always begin
        clk_74a = 1'b0;
        #4000;
        forever #(13.468/2.0) clk_74a = ~clk_74a;
    end
    always begin
        ctrl_clk = 1'b0;
        #4000;
        forever #(PC/2.0) ctrl_clk = ~ctrl_clk;
    end
    // coincident chip grid (probe only: alignment is measured, not assumed)
    always begin
        chip_clk = 1'b0;
        #4000;
        forever #(PC/2.0) chip_clk = ~chip_clk;
    end
    assign clk90 = chip_clk;

    initial begin
        path_rst = 1'b1;
        por_done = 1'b0;
        word_rd = 0; word_wr = 0; word_addr = 0; word_data = 0;
        repeat (20) @(posedge ctrl_clk);
        por_done = 1'b1;
        repeat (40) @(posedge ctrl_clk);
        path_rst = 1'b0;
        $display("PROBE: waiting for boot_done (state=%0d cke=%b)", isr0.state, isr0.phy_cke);
        $fflush();
        wait (boot_done);
        $display("PROBE: boot_done");

        // ---- write word 0 = AABB_CCDD (high != low) ----
        @(posedge ctrl_clk);
        word_addr = 24'd0;
        word_data = 32'hAABB_CCDD;
        word_wr = 1'b1;
        @(posedge ctrl_clk);
        word_wr = 1'b0;
        wait (word_done);
        $display("PROBE: write done");
        repeat (20) @(posedge ctrl_clk);

        // ---- read word 0 back ----
        word_addr = 24'd0;
        word_rd = 1'b1;
        @(posedge ctrl_clk);
        word_rd = 1'b0;
        wait (word_rd_valid);
        $display("PROBE: word_q = %08h (expect AABCCCCD... = AABBCCDD)", word_q);
        if (word_q === 32'hAABB_CCDD)
            $display("PROBE: PASS (readback exact)");
        else
            $display("PROBE: MISMATCH");
        #500;
        $finish;
    end

    // watchdog: heartbeat + forced stop so a stuck sim cannot hang the run
    integer hb;
    reg hb_done;
    initial begin
        hb_done = 1'b0;
        for (hb = 0; hb < 40 && !hb_done; hb = hb + 1) begin
            #20_000; // 20 us machine
            if (boot_done) begin
                $display("PROBE-HB: boot_done at t=%0t", $time);
                hb_done = 1'b1;
            end else
                $display("PROBE-HB t=%0t state=%0d dc=%0d cke=%b refcnt=%0d por=%b", $time, isr0.state, isr0.dc, isr0.phy_cke, m0.ref_cnt[0], por_done);
                $fflush();
        end
        if (!hb_done) begin
            $display("PROBE: WATCHDOG TIMEOUT");
            $finish;
        end
    end

endmodule
