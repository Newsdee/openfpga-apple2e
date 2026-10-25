// tb_ram_zero.sv - focused behavior test for the RAM zero-init experiment
// (TASK_RAM_FILE_INITIALIZATION_2026-10-25, Phase A2).
//
// VARIANT = 0: ram_v_file   ($readmemh file init; IMG selects the image)
// VARIANT = 1: ram_v_init   (nested 256x256 loop init, the historical reference)
//
// CHECK_LOAD = 1: initial contents must equal the deterministic PATTERN
//   byte(a) = (a + (a >> 8)) & 0xFF (65,535 nonzero values). This cannot
//   pass on an uninitialised / default-zero memory, so a PASS proves the
//   $readmemh path really read file contents (a pure zero image cannot
//   self-prove it was loaded - review finding 3).
// CHECK_LOAD = 0: initial contents must be all zero.
//
// Phases (after the initial read):
//   - write-first + stored readback at 0x0000, 0x00FF, 0x0100, 0x7FFF, 0xFFFF
//   - full deterministic write sweep + full readback sweep (all 65,536)
//   - hold: stored nonzero values must not spontaneously revert to zero
//   - mid-cycle stability: input changes between clock edges must not
//     change the registered output
//
// Verdict: "TB: RAM-ZERO PASS" + exit 0 iff every check passed; any
// failure prints details and $fatal (exit 1). Coverage: checks counter.
//
// NOTE on tooling: comment lines in this file must not begin with the
// word that names the lint/simulation tool, or the build dies with a
// pragma parse error (host tooling trap documented in the 2026-10-25 review).
`timescale 1ns/1ps

module tb_ram_zero #(
    parameter int    VARIANT    = 0,
    parameter string IMG        = "img/pattern.hex",
    parameter bit    CHECK_LOAD = 1
) ();

    logic clk = 1'b0;
    logic        we;
    logic [15:0] waddr;
    logic [7:0]  wdata;
    logic [7:0]  rdata;

    if (VARIANT == 0) begin : g_file
        ram_v_file #(.HEX(IMG)) dut (
            .clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .rdata(rdata)
        );
    end else begin : g_loop
        ram_v_init dut (
            .clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .rdata(rdata)
        );
    end

    always #5 clk = ~clk;

    int checks = 0;
    int fails  = 0;
    logic [7:0] exp_mid;

    function automatic logic [7:0] exp_init(input int a);
        logic [7:0]  v;
        logic [31:0] t;
        t = a + (a >> 8);
        v = CHECK_LOAD ? t[7:0] : 8'h00;
        return v;
    endfunction

    function automatic logic [7:0] sweep_pat(input int a);
        logic [7:0]  v;
        logic [31:0] t;
        t = a * 7 + 3;
        v = t[7:0];
        return v;
    endfunction

    task automatic do_fail(input string ctx, input logic [15:0] a,
                           input logic [7:0] got, input logic [7:0] exp);
        fails++;
        if (fails < 12)
            $display("FAIL %0s: addr=%0h got=%0h exp=%0h", ctx, a, got, exp);
    endtask

    // Read ram[a] through the normal synchronous interface (we low).
    task automatic rd(input logic [15:0] a, input logic [7:0] exp,
                      input string ctx);
        logic [7:0] got;
        @(negedge clk); we = 1'b0; waddr = a; wdata = 8'h00;
        @(negedge clk); got = rdata;
        checks++;
        if (got !== exp) do_fail(ctx, a, got, exp);
    endtask

    // Write ram[a] = d and verify the write-first bypass on rdata,
    // then verify the stored value reads back.
    task automatic wr_first(input logic [15:0] a, input logic [7:0] d,
                            input string ctx);
        @(negedge clk); we = 1'b1; waddr = a; wdata = d;
        @(negedge clk);
        checks++;
        if (rdata !== d) do_fail(ctx, a, rdata, d);   // write-first bypass
        @(negedge clk); we = 1'b0; waddr = a;
        @(negedge clk);
        checks++;
        if (rdata !== d) do_fail(ctx, a, rdata, d);   // stored readback
    endtask

    initial begin
        we = 1'b0; waddr = 16'h0000; wdata = 8'h00;
        #20;

        $display("TB: RAM-ZERO start variant=%0s check_load=%0d img=%0s",
                 (VARIANT == 0) ? "file" : "loop-init", CHECK_LOAD, IMG);

        // Phase 1: initial contents, every address (load proof when CHECK_LOAD).
        for (int a = 0; a < 65536; a++)
            rd(a[15:0], exp_init(a), "init-read");

        // Phase 2: write-first + stored readback at the five key addresses.
        wr_first(16'h0000, 8'hC1, "wf");
        wr_first(16'h00FF, 8'hC2, "wf");
        wr_first(16'h0100, 8'hC3, "wf");
        wr_first(16'h7FFF, 8'hC4, "wf");
        wr_first(16'hFFFF, 8'hC5, "wf");

        // Phase 3: full deterministic write sweep, then full readback sweep.
        for (int a = 0; a < 65536; a++) begin
            @(negedge clk); we = 1'b1; waddr = a[15:0]; wdata = sweep_pat(a);
        end
        for (int a = 0; a < 65536; a++)
            rd(a[15:0], sweep_pat(a), "sweep");

        // Phase 4: hold - stored nonzero values must not revert to zero.
        wr_first(16'h0000, 8'hA5, "hold-wr");
        wr_first(16'h00FF, 8'h5A, "hold-wr");
        wr_first(16'h0100, 8'hA5, "hold-wr");
        wr_first(16'h7FFF, 8'h5A, "hold-wr");
        wr_first(16'hFFFF, 8'hFF, "hold-wr");
        repeat (10000) @(negedge clk);
        rd(16'h0000, 8'hA5, "hold");
        rd(16'h00FF, 8'h5A, "hold");
        rd(16'h0100, 8'hA5, "hold");
        rd(16'h7FFF, 8'h5A, "hold");
        rd(16'hFFFF, 8'hFF, "hold");

        // Phase 5: mid-cycle stability - registered output must not change
        // until the next posedge, even though the inputs move mid-cycle.
        exp_mid = sweep_pat(4660);   // 0x1234 decimal
        @(negedge clk); we = 1'b0; waddr = 16'h1234; wdata = 8'h00;
        @(negedge clk);
        checks++;
        if (rdata !== exp_mid) do_fail("pre-midcycle", 16'h1234, rdata, exp_mid);
        we    = 1'b1;
        waddr = 16'hABCD;
        wdata = 8'h5A;
        #100;                                   // still before the next posedge
        checks++;
        if (rdata !== exp_mid) do_fail("midcycle-stable", 16'h1234, rdata, exp_mid);
        @(negedge clk);                         // posedge has now applied the write

        $display("TB: RAM-ZERO variant=%0s check_load=%0d checks=%0d fails=%0d",
                 (VARIANT == 0) ? "file" : "loop-init", CHECK_LOAD, checks, fails);
        if (fails == 0)
            $display("TB: RAM-ZERO PASS");
        else
            $fatal(1, "TB: RAM-ZERO FAIL: %0d failed check(s)", fails);
    end
endmodule
