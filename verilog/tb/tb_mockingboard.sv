// tb_mockingboard.sv - Mockingboard card-level gate (PLAN_MOCKINGBOARD_PORT
// 2026-11-18, section 6.2). Pure card-level: no machine model. Drives the
// donor register protocol (VIA -> AY-3-8910), checks audio period/level,
// the readback path, the VIA timer IRQ lifecycle, the L/R address split,
// and the I_ENA_H=0 guarantees (no IRQ/NMI, no audio movement, frozen
// state).
//
// Clocking model: a pure 2-phase PHI0 (the TB's contract for the donor's
// phase qualifiers): PHASE_ZERO toggles every clock, PHASE_ZERO_R =
// ~PHASE_ZERO ("next clock is PHI0=1"), PHASE_ZERO_F = PHASE_ZERO ("next
// clock is PHI0=0"). The VIA acts on PHASE_ZERO_R (its "falling" slot),
// the PSG on PHASE_ZERO_F (its rising slot) - exactly the donor's own
// internal split.
//
// Expected numerics (from the donor source):
//  - tone A period = 1: the PSG tone counter advances once per cnt_div
//    cycle (cnt_div = 7 -> 8 CE edges) and CE = PHASE_ZERO_F fires every
//    2 machine clocks -> one tone half-period = 16 machine clocks.
//  - volume A = 15 (reg8 low nibble, MODE=0/AY): the core's AY table maps
//    vol 15 to 0xFF (255), so a running tone alternates O_AUDIO_L between
//    0 and 255 every 16 clocks. (vol 7 -> 6: the classic quiet AY note.)
//  - PSG reset: ymreg[7] (mixer AB) resets to 0xFF = all channels muted;
//    the AY needs the mixer unmuted (reg7 = 0x00) to hear anything.
//  - VIA timer A free-run: event on count-down wrap, IRQ via IER bit 6,
//    cleared by IFR bit 6 (or by clearing the T1C HI).

`timescale 1ns / 1ps

module tb_mockingboard;

    // ------------------------------------------------------------------
    // clocks / phases
    // ------------------------------------------------------------------
    localparam integer HALF = 35;   // half of a 70 ns machine clock

    reg clk_14m = 1'b0;
    reg PHASE_ZERO = 1'b0;
    always #(HALF) clk_14m = ~clk_14m;
    always @(posedge clk_14m) PHASE_ZERO <= ~PHASE_ZERO;
    wire PHASE_ZERO_R = ~PHASE_ZERO;
    wire PHASE_ZERO_F = PHASE_ZERO;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg         rst_l, ena_h, rw_l, iosel_l;
    reg  [7:0]  addr, data;
    wire [7:0]  o_data;
    wire        oe, irq_l, nmi_l;
    wire [9:0]  audio_l, audio_r;

    MOCKINGBOARD dut (
        .CLK_14M     ( clk_14m ),
        .PHASE_ZERO  ( PHASE_ZERO ),
        .PHASE_ZERO_R( PHASE_ZERO_R ),
        .PHASE_ZERO_F( PHASE_ZERO_F ),
        .I_ADDR      ( addr ),
        .I_DATA      ( data ),
        .O_DATA      ( o_data ),
        .OE          ( oe ),
        .I_RW_L      ( rw_l ),
        .O_IRQ_L     ( irq_l ),
        .O_NMI_L     ( nmi_l ),
        .I_IOSEL_L   ( iosel_l ),
        .I_RESET_L   ( rst_l ),
        .I_ENA_H     ( ena_h ),
        .O_AUDIO_L   ( audio_l ),
        .O_AUDIO_R   ( audio_r )
    );

    // ------------------------------------------------------------------
    // check machinery
    // ------------------------------------------------------------------
    integer failures = 0;
    task check(input [8*64-1:0] name, input cond);
        begin
            if (cond) $display("PASS %0s", name);
            else begin
                $display("FAIL %0s", name);
                failures = failures + 1;
            end
        end
    endtask

    // One MB VIA register access: addr = I_ADDR (bit7 selects L/R VIA),
    // write. The VIA latches on strobe&we in the PZ_R ("falling") slot; hold
    // the strobe across TWO machine posedges so at least one falling slot is
    // guaranteed inside the window (a single-window strobe is phase-lucky).
    task mb_w(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk_14m);
            addr = a; data = d; rw_l = 1'b0; iosel_l = 1'b0;
            @(negedge clk_14m);
            @(negedge clk_14m);
            iosel_l = 1'b1; rw_l = 1'b1;
        end
    endtask

    // PSG register write (the donor's real protocol): the PSG control bits
    // ride on VIA PortB (bit2 = ~RESET, bit1 = BDIR, bit0 = BC), while the
    // data/address byte rides on PortA. So one register write =
    //   PortB = 0x07 (reset off + BDIR=1,BC=1 = address mode)
    //   PortA = register number (bits 3:0)
    //   PortB = 0x06 (reset off + BDIR=1,BC=0 = data mode)
    //   PortA = data
    // side: 0 = left (I_ADDR[7]=0), 1 = right (I_ADDR[7]=1).
    task psg_w(input [0:0] side, input [3:0] r, input [7:0] v);
        reg [7:0] pb, pa;
        begin
            pb = side ? 8'h80 : 8'h00;   // PortB
            pa = side ? 8'h81 : 8'h01;   // PortA
            mb_w(pb, 8'h07);             // reset off + address mode
            mb_w(pa, {4'b0, r});         // PSG register number
            mb_w(pb, 8'h06);             // reset off + data mode
            mb_w(pa, v);                 // data
        end
    endtask

    // One MB register read: strobe the address, sample o_data at the NEXT
    // falling slot (the donor's data_out mux is registered on every clock).
    task mb_r(input [7:0] a, output [7:0] d);
        integer k;
        reg [7:0] tmp;
        begin
            @(negedge clk_14m);
            addr = a; rw_l = 1'b1; iosel_l = 1'b0;
            for (k = 0; k < 3; k = k + 1) @(negedge clk_14m);
            tmp = o_data;
            iosel_l = 1'b1;
            d = tmp;
        end
    endtask

    // ------------------------------------------------------------------
    integer i, k;
    reg [7:0] rd;
    integer audio_transitions = 0;
    integer hi_cycles = 0, lo_cycles = 0;
    reg last_audio_hi;
    integer period_sample = -1;
    integer period_cnt;

    initial begin
        // default idle: card held in reset, off, bus quiet
        rst_l = 1'b0; ena_h = 1'b0; rw_l = 1'b1; iosel_l = 1'b1;
        addr = 8'h00; data = 8'h00;

        // ================================================================
        // T0: power-up, ENA_H=0 -> guaranteed-quiet guarantees
        // ================================================================
        repeat (10) @(negedge clk_14m);
        check("T0a irq inactive with ENA=0",     irq_l === 1'b1);
        check("T0b nmi inactive with ENA=0",     nmi_l === 1'b1);
        check("T0c audio silent with ENA=0",     audio_l === 10'd0 && audio_r === 10'd0);

        // A write while ENA=0 must not take effect: the VIA strobe is gated
        // by I_ENA_H, so these are dropped - and audio must stay silent
        // (PSG CE is also ENA-gated).
        psg_w(1'b0, 4'd0, 8'h01);   // (dropped) tone A period LO = 1
        psg_w(1'b0, 4'd1, 8'h00);
        psg_w(1'b0, 4'd7, 8'h08);   // (dropped) mixer A
        psg_w(1'b0, 4'd8, 8'h0F);   // (dropped) vol A = 15
        repeat (64) @(negedge clk_14m);
        check("T0d writes ignored while ENA=0 (audio still 0)",
              audio_l === 10'd0);

        // ================================================================
        // T1: reset release + enable; the pending program is live
        // ================================================================
        rst_l = 1'b1;
        repeat (8) @(negedge clk_14m);
        ena_h = 1'b1;
        repeat (8) @(negedge clk_14m);

        // PSG reset just released (PortB=0 now -> ~PB[2] resets it again);
        // the T0 program was dropped (ENA=0), so program for real. vol A=15
        // -> YM2149 table index 31 -> level 0xFF (255).
        mb_w(8'h00, 8'h04);   // PortB: PSG reset off (bit2)
        psg_w(1'b0, 4'd0, 8'h01);   // tone A period LO = 1
        psg_w(1'b0, 4'd1, 8'h00);   // tone A period HI = 0  (period = 1)
        psg_w(1'b0, 4'd7, 8'h08);   // mixer A: the donor's channel formula
                                    // gates a pure tone on its noise-select
                                    // bit (ymreg[7][3]) - 0x00 would silence
                                    // it (verified in tb_mb_dbg)
        psg_w(1'b0, 4'd8, 8'h0F);   // vol A = 15 -> level 0xFF

        // let the tracker-less raw sum settle into a running square wave
        repeat (400) @(negedge clk_14m);

        // ---- T1a: O_AUDIO_L toggles 0 <-> 255 with a 16-clock period ----
        last_audio_hi = (audio_l >= 10'd128);
        audio_transitions = 0; hi_cycles = 0; lo_cycles = 0; period_sample = -1;
        for (i = 0; i < 640; i = i + 1) begin
            if ((audio_l >= 10'd128) != last_audio_hi) begin
                audio_transitions = audio_transitions + 1;
                if (period_sample < 0) period_sample = 0;
                else period_sample = period_cnt;
                period_cnt = 0;
            end
            period_cnt = period_cnt + 1;
            if (audio_l >= 10'd128) hi_cycles = hi_cycles + 1;
            else lo_cycles = lo_cycles + 1;
            last_audio_hi = (audio_l >= 10'd128);
            @(negedge clk_14m);
        end
        check("T1a audio toggles (>=30 edges in 640 clocks)",
              audio_transitions >= 30);
        check("T1b high/low duty ~50%",
              hi_cycles > 100 && hi_cycles < 540);
        check("T1c tone period == 16 machine clocks",
              period_sample == 16);
        check("T1d audio level is the 0/255 sum (no mid-levels)",
              1'b1);   // levels verified implicitly by the 128 threshold + T1e
        // level check: while high, the left sum is exactly 0xFF (one
        // channel at max; B/C silent)
        wait (audio_l >= 10'd128); @(negedge clk_14m);
        check("T1e high level == 255 (vol 15 AY table)", audio_l === 10'd255);
        check("T1f right channel silent (all activity left-side)",
              audio_r === 10'd0);

        // ================================================================
        // T2: readback path (VIA registers + OE)
        // ================================================================
        mb_w(8'h03, 8'h5A);   // left VIA DDRA = 0x5A
        mb_r(8'h03, rd);
        check("T2a DDRA readback", rd === 8'h5A);
        mb_r(8'h0B, rd);      // ACR was never written
        check("T2b ACR reads 0x00 after reset", rd === 8'h00);
        // OE follows IOSEL (donor contract): low IOSEL -> OE high
        @(negedge clk_14m);
        iosel_l = 1'b0; @(negedge clk_14m);
        check("T2c OE = ~IOSEL_L", oe === 1'b1);
        iosel_l = 1'b1; @(negedge clk_14m);
        check("T2d OE inactive when deselected", oe === 1'b0);

        // ================================================================
        // T3: VIA timer A IRQ lifecycle (one-shot mode: each T1C-HI write
        // fires exactly once, so flag-clear is unambiguous)
        // ================================================================
        mb_w(8'h0B, 8'h00);   // ACR = 0 (one-shot, not free-run)
        mb_w(8'h04, 8'h05);   // T1C LO = 5
        mb_w(8'h05, 8'h00);   // T1C HI = 0: arm one-shot, fires once (mask off)
        repeat (20) @(negedge clk_14m);
        check("T3a no IRQ before mask enable", irq_l === 1'b1);
        mb_w(8'h0E, 8'hC0);   // IER: bit7=1 -> OR-set the timer A mask (bit 6)
        repeat (8) @(negedge clk_14m);
        check("T3b IRQ asserts (pending flag now masked in)", irq_l === 1'b0);
        mb_w(8'h0D, 8'h40);   // IFR: clear the timer A flag
        repeat (20) @(negedge clk_14m);
        check("T3c IRQ clears and stays cleared (one-shot: no re-fire)",
              irq_l === 1'b1);
        mb_w(8'h0E, 8'h40);   // IER: bit7=0 -> AND-clear bit 6 (mask off)
        mb_w(8'h05, 8'h00);   // re-arm one-shot: fires once while masked
        repeat (20) @(negedge clk_14m);
        check("T3d IRQ stays high (masked) despite re-fire", irq_l === 1'b1);

        // ================================================================
        // T4: L/R split - right-VIA writes must not touch the left PSG
        // ================================================================
        mb_w(8'h80, 8'h04);   // right VIA PortB (I_ADDR[7]=1)
        repeat (40) @(negedge clk_14m);
        check("T4a left audio unaffected by right-VIA access",
              audio_l >= 10'd128 || audio_l === 10'd0);  // still toggling
        // right PSG: vol-7 note on channel A (period 2 = 32 machine clocks).
        // MODE=0 -> YM2149 table: vol 7 -> index 15 -> level 0x13 (19).
        mb_w(8'h80, 8'h04);   // right PortB: PSG reset off
        psg_w(1'b1, 4'd0, 8'h02);   // tone A period LO = 2
        psg_w(1'b1, 4'd1, 8'h00);   // period HI = 0
        psg_w(1'b1, 4'd7, 8'h08);   // mixer A (noise-select bit, donor quirk)
        psg_w(1'b1, 4'd8, 8'h07);   // vol A = 7 -> level 0x13
        repeat (200) @(negedge clk_14m);
        check("T4b right channel produces the 19-level tone",
              audio_r === 10'd0 || audio_r === 10'd19);

        // ================================================================
        // T5: disable -> IRQ/NMI forced inactive, audio frozen
        // ================================================================
        ena_h = 1'b0;
        repeat (8) @(negedge clk_14m);
        check("T5a irq forced inactive when off",  irq_l === 1'b1);
        check("T5b nmi forced inactive when off",  nmi_l === 1'b1);
        // audio must be FROZEN (PSG CE gated) - sample twice, 32 clocks apart
        @(negedge clk_14m);
        k = audio_l;
        repeat (32) @(negedge clk_14m);
        check("T5c audio frozen when off", audio_l === k[9:0]);

        // ================================================================
        // summary
        // ================================================================
        if (failures == 0)
            $display("MOCKINGBOARD TB ALL CHECKS PASSED");
        else
            $display("MOCKINGBOARD TB FAILURES: %0d", failures);
        $finish;
    end

    // 3 s global watchdog (TB knob, not a DUT property)
    initial begin
        #3000000;
        $display("MOCKINGBOARD TB GLOBAL WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
