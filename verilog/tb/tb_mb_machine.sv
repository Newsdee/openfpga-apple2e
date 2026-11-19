// tb_mb_machine.sv - Mockingboard machine-level integration gate
// (PLAN_MOCKINGBOARD_PORT_2026-11-18, section 6.3 "Integration smoke").
//
// Instantiates the REAL apple2 machine (machine/apple2.v) with its RAM and
// the MOCKINGBOARD card in slot 4, wired exactly as apf_stream_video_top.v
// does (mb_inslot machine-domain bit, I_IOSEL_L = ~m_io_sel[4] | ~inslot,
// m_pd_mux sel4_live, IRQ_n/NMI_n straight into the machine). The 6502
// runs a real program at $0300 (the ROM boot vector) that programs the
// card the way software does ($C400/$C401 VIA writes), stores a $C403
// (DDRA) readback in RAM, and loops.
//
// Phases:
//   A  mb_inslot=0 (OFF): program runs; $C403 reads 0x00 (empty slot);
//       card audio pins silent; IRQ/NMI lines inactive high.
//   B  machine reset, mb_inslot=1 (ON): program re-runs; $C403 reads
//       0xA5 (single-write-per-access + read mux through the real CPU);
//       O_AUDIO_L toggles 0<->255 (period-1 tone, vol 15, YM2149 table);
//       O_AUDIO_R silent.
//
// The option word's bridge(74a)->machine(14M) CDC is the proven synch_3
// pattern used by every existing option (tested in the video-option TBs);
// this TB drives the machine-domain mb_inslot bit directly.
//
// Run CWD must be verilog/mbm/ so rtl/roms/{apple2e,video2}.hex resolve
// (the machine hardcodes rtl/roms/... for $readmemh).

`timescale 1ns / 1ps

module tb_mb_machine;

    // ==================================================================
    // clock (machine domain only - the machine generates its own phases
    // from CLK_14M via its internal timing_generator, exactly like the
    // streaming top)
    // ==================================================================
    localparam real PM = 69.844;   // 14.318 MHz
    reg clk_mach = 1'b0;
    always begin #4000; forever #(PM/2.0) clk_mach = ~clk_mach; end

    // ==================================================================
    // machine RAM (64K main + 64K aux, mirrors the streaming top)
    // ==================================================================
    reg  [7:0]  ram_main [0:65535];
    reg  [7:0]  ram_aux  [0:65535];
    reg  [15:0] m_ram_do;
    wire [15:0] m_addr;
    wire [17:0] m_ram_addr;
    wire [7:0]  m_ram_di;
    wire        m_ram_aux, m_ram_we;
    always @(posedge clk_mach) begin
        if (m_ram_we & ~m_ram_aux) begin
            ram_main[m_ram_addr[15:0]] <= m_ram_di;
            m_ram_do[7:0]              <= m_ram_di;
        end else m_ram_do[7:0]  <= ram_main[m_ram_addr[15:0]];
        if (m_ram_we & m_ram_aux) begin
            ram_aux[m_ram_addr[15:0]] <= m_ram_di;
            m_ram_do[15:8]           <= m_ram_di;
        end else m_ram_do[15:8] <= ram_aux[m_ram_addr[15:0]];
    end

    // ==================================================================
    // machine signals
    // ==================================================================
    reg         machine_reset_base = 1'b1;
    wire        machine_reset = machine_reset_base;

    wire        m_clk2m;
    wire        m_pz, m_pzr, m_pzf;
    wire        m_video, m_hbl, m_vbl;
    wire        m_text_mode, m_hgr_mode, m_early_video, m_run_fill_ok;
    wire        m_col_line, m_hgr80_mode, m_gr2, m_dhires;
    wire        m_read_key, m_spk;
    assign m_K   = 8'h00;
    assign m_akd = 1'b0;
    wire [7:0]  m_io_sel, m_dev_sel;
    wire        m_io_str, m_pdl, m_stb;
    wire [3:0]  m_an;
    wire [63:0] m_t65;
    wire [15:0] m_pc = m_t65[63:48];

    reg [19:0] blink_cnt;
    always @(posedge clk_mach) blink_cnt <= blink_cnt + 1'b1;
    wire flash_clk = blink_cnt[19];

    // ==================================================================
    // Mockingboard in slot 4 - wired exactly as apf_stream_video_top.v
    // (2026-11-18): inslot is the machine-domain option bit; the PD mux
    // has MB after the (absent-here) HDD slot, before the (absent-here)
    // WOZ slot; IRQ/NMI go straight to the machine inputs (the donor
    // forces both inactive high when I_ENA_H=0).
    // ==================================================================
    reg         mb_inslot_m = 1'b0;
    wire [7:0]  mb_data;
    wire        mb_oe;
    wire        mb_irq_n, mb_nmi_n;
    wire [9:0]  mb_audio_l, mb_audio_r;
    wire        sel4_live = m_io_sel[4] & mb_inslot_m;
    wire [7:0]  m_pd_mux  = sel4_live ? mb_data : 8'h00;

    wire        m_cpu_we;

    MOCKINGBOARD mb_4 (
        .CLK_14M     ( clk_mach ),
        .PHASE_ZERO  ( m_pz ),
        .PHASE_ZERO_R( m_pzr ),
        .PHASE_ZERO_F( m_pzf ),
        .I_ADDR      ( m_addr[7:0] ),
        .I_DATA      ( m_ram_di ),
        .O_DATA      ( mb_data ),
        .OE          ( mb_oe ),
        .I_RW_L      ( ~m_cpu_we ),
        .O_IRQ_L     ( mb_irq_n ),
        .O_NMI_L     ( mb_nmi_n ),
        .I_IOSEL_L   ( ~m_io_sel[4] | ~mb_inslot_m ),
        .I_RESET_L   ( ~machine_reset ),
        .I_ENA_H     ( mb_inslot_m ),
        .O_AUDIO_L   ( mb_audio_l ),
        .O_AUDIO_R   ( mb_audio_r )
    );

    apple2 m1 (
        .CLK_14M(clk_mach), .CLK_2M(m_clk2m),
        .PALMODE(1'b0), .ROMSWITCH(1'b0), .CPU_WAIT(1'b0),
        .PHASE_ZERO(m_pz), .PHASE_ZERO_R(m_pzr), .PHASE_ZERO_F(m_pzf),
        .FLASH_CLK(flash_clk),
        .reset(machine_reset), .cpu(1'b1),
        .STALL(1'b0),
        .ADDR(m_addr), .ram_addr(m_ram_addr), .D(m_ram_di), .ram_do(m_ram_do),
        .aux(m_ram_aux), .PD(m_pd_mux), .CPU_WE(m_cpu_we),
        .IRQ_n(mb_irq_n), .NMI_n(mb_nmi_n & ~nmi_inject), .ram_we(m_ram_we),
        .VIDEO(m_video), .COLOR_LINE(m_col_line), .RUN_FILL_OK(m_run_fill_ok),
        .TEXT_MODE(m_text_mode), .EARLY_VIDEO(m_early_video), .HGR_MODE(m_hgr_mode),
        .HGR80_MODE(m_hgr80_mode), .GR2(m_gr2), .COL80(), .DHIRES_MODE(m_dhires),
        .HBL(m_hbl), .VBL(m_vbl),
        .K(m_K), .READ_KEY(m_read_key), .AKD(m_akd), .AN(m_an),
        .GAMEPORT(8'b0),
        .PDL_STROBE(m_pdl), .STB(m_stb),
        .IO_SELECT(m_io_sel), .DEVICE_SELECT(m_dev_sel), .IO_STROBE(m_io_str),
        .ioctl_addr(25'b0), .ioctl_data(8'b0), .ioctl_index(8'b0),
        .ioctl_download(1'b0), .ioctl_wr(1'b0), .saturn_5_inslot(1'b0),
        .speaker(m_spk),
        .DBG_T65_REGS(m_t65), .DBG_DI(m_dbg_di), .DBG_ROM_ADDR(), .DBG_ROM_OUT(),
        .ss_addr(ss_addr_t), .ss_wdata(ss_wdata_t), .ss_wren(ss_wren_t), .ss_rdata(),
        .machine_ce(1'b1), .cpu_frozen(),
        .Z80_EN(1'b0), .Z80_A(16'b0), .Z80_DO(8'b0), .Z80_WE(1'b0), .CPU_DI()
    );

    // ==================================================================
    // the test program. Planted in main RAM at $03FB (both banks) and
    // run by NMI: this ROM's NMI vector ($FFFA/$FFFB, ROM-resident and
    // unredirectable) points at $03FB - main RAM. So: plant the
    // program at $03FB, set the RAMRD softswitch (page-$03 read bank)
    // via the ss port, assert the machine NMI (unmaskable on the 6502)
    // -> the CPU takes the NMI and runs the program. Protocol (per the
    // card unit TB): direct VIA register access via $C400+reg (reg 3 =
    // DDRA), PSG writes via PortB mode switching (0x07 = address,
    // 0x06 = data) with the register/value on PortA. Donor YM2149 map:
    // reg 0 = period A LO, reg 1 = period A HI, reg 7 = mixer A (the
    // donor gates the tone on the noise-select bit), reg 8 = volume A.
    // ==================================================================
    localparam [7:0] P [0:101] = '{
        // --- VIA DDRA = 0xA5 (direct register write) ---
        8'hA9, 8'hA5,            // LDA #$A5
        8'h8D, 8'h03, 8'hC4,     // STA $C403    (DDRA)
        // --- PSG reg 0 = 1 (period A LO) ---
        8'hA9, 8'h07,            // LDA #$07
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (PortB: address mode)
        8'hA9, 8'h00,            // LDA #$00
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (PSG reg 0)
        8'hA9, 8'h06,            // LDA #$06
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (PortB: data mode)
        8'hA9, 8'h01,            // LDA #$01
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (period LO = 1)
        // --- PSG reg 1 = 0 (period A HI) ---
        8'hA9, 8'h07,            // LDA #$07
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (address mode)
        8'hA9, 8'h01,            // LDA #$01
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (PSG reg 1)
        8'hA9, 8'h06,            // LDA #$06
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (data mode)
        8'hA9, 8'h00,            // LDA #$00
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (period HI = 0)
        // --- PSG reg 7 = 0x08 (mixer A: noise-select bit, donor) ---
        8'hA9, 8'h07,            // LDA #$07
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (address mode)
        8'hA9, 8'h07,            // LDA #$07
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (PSG reg 7)
        8'hA9, 8'h06,            // LDA #$06
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (data mode)
        8'hA9, 8'h08,            // LDA #$08
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (mixer A = 0x08)
        // --- PSG reg 8 = 0x0F (volume A = 15 -> level 0xFF) ---
        8'hA9, 8'h07,            // LDA #$07
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (address mode)
        8'hA9, 8'h08,            // LDA #$08
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (PSG reg 8)
        8'hA9, 8'h06,            // LDA #$06
        8'h8D, 8'h00, 8'hC4,     // STA $C400    (data mode)
        8'hA9, 8'h0F,            // LDA #$0F
        8'h8D, 8'h01, 8'hC4,     // STA $C401    (vol A = 15)
        // --- results ---
        8'hAD, 8'h03, 8'hC4,     // LDA $C403    (DDRA readback)
        8'h8D, 8'h50, 8'h03,     // STA $0350
        8'hA9, 8'h55,            // LDA #$55
        8'h8D, 8'h51, 8'h03,     // STA $0351    (liveness marker)
        8'hCE, 8'h52, 8'h03,      // $045B INC $0352 (loop counter) - CE = INC abs
        8'h4C, 8'h5B, 8'h04      // $045E JMP $045B (loop) - relative to $03FB
    };

    localparam integer PLEN = 102;

    // ==================================================================
    // checks
    // ==================================================================
    integer nfail = 0;
    task check(input [8*64-1:0] name, input cond);
        begin
            if (cond) $display("PASS %0s", name);
            else begin
                $display("FAIL %0s", name);
                nfail = nfail + 1;
            end
        end
    endtask

    // wait until the liveness marker ($0351) is written by the program
    integer t;
    task wait_marker(input integer timeout);
        begin
            for (t = 0; t < timeout; t = t + 1) begin
                if (mk_seen()) return;
                @(posedge clk_mach);
            end
        end
    endtask

    // the loop counter must still be climbing (CPU running, not wedged)
    task check_running(input [8*64-1:0] name);
        reg [7:0] c1, c2;
        begin
            c1 = res_word(16'h0352);
            repeat (200) @(posedge clk_mach);
            c2 = res_word(16'h0352);
            check(name, c2 != c1);
        end
    endtask

    // ==================================================================
    // audio window analysis (machine domain)
    // ==================================================================
    integer trans = 0;
    integer hi_cnt = 0, lo_cnt = 0;
    integer prev_edge_w = 0;
    integer period_sample = -1;
    integer w;
    reg last_hi;
    task audio_window(input integer n);
        begin
            trans = 0; hi_cnt = 0; lo_cnt = 0; period_sample = -1;
            last_hi = (mb_audio_l >= 10'd128);
            for (w = 0; w < n; w = w + 1) begin
                if ((mb_audio_l >= 10'd128) !== last_hi) begin
                    trans = trans + 1;
                    if (period_sample < 0) period_sample = 0;
                    else period_sample = w - prev_edge_w;
                    prev_edge_w = w;
                end
                if (mb_audio_l >= 10'd128) hi_cnt = hi_cnt + 1;
                else lo_cnt = lo_cnt + 1;
                last_hi = (mb_audio_l >= 10'd128);
                @(posedge clk_mach);
            end
        end
    endtask

    integer k;

    // the program runs in whichever RAM bank the softswitch bank select
    // points to at execution time (main or aux) - checks must accept
    // either bank
    function mk_seen;
        begin
            mk_seen = (ram_main[16'h0351] === 8'h55) ||
                          (ram_aux[16'h0351]  === 8'h55);
        end
    endfunction

    // the result word in the bank that holds the marker (main if neither)
    function [7:0] res_word(input [15:0] a);
        begin
            if (ram_aux[16'h0351] === 8'h55) res_word = ram_aux[a];
            else res_word = ram_main[a];
        end
    endfunction

    // clear the result words (both banks)
    task clear_results;
        begin
            ram_main[16'h0350] = 8'h00; ram_aux[16'h0350] = 8'h00;
            ram_main[16'h0351] = 8'h00; ram_aux[16'h0351] = 8'h00;
            ram_main[16'h0352] = 8'h00; ram_aux[16'h0352] = 8'h00;
        end
    endtask

// ==================================================================
    // sequence
    // ==================================================================
    initial begin
        machine_reset_base = 1'b1;
        mb_inslot_m = 1'b0;
        clear_results;

        repeat (40) @(posedge clk_mach);
        machine_reset_base = 1'b0;   // boot

        // ================= PHASE A: card OFF =================
        // let the ROM power-on settle into its idle loop (no disk: the
        // ROM ends in a $C030 speaker-read blink loop with CXROM=0 -
        // slots live, but the ROM never executes slot/RAM code)
        repeat (30_000) @(posedge clk_mach);
        // plant the program, pin the RAM bank, then NMI: the 6502
        // (unmasked) follows the ROM's NMI vector ($03FB, main RAM) and
        // runs it. With the card out, the $C4xx writes hit air and the
        // $C403 readback is the empty-slot 0x00.
        plant_all;
        set_banks;
        fire_nmi;
        wait_marker(200_000);
        check("A1 program ran to completion (inslot=0)", mk_seen());
        check("A2 $C403 readback = 0x00 (empty slot)", res_word(16'h0350) === 8'h00);
        check("A3 card IRQ line inactive (off)",        mb_irq_n  === 1'b1);
        check("A4 card NMI line inactive (off)",        mb_nmi_n  === 1'b1);
        // audio pins: sample 64 clocks - must stay 0
        begin : acheck
            integer j;
            reg bad = 1'b0;
            for (j = 0; j < 64; j = j + 1) begin
                if (mb_audio_l !== 10'd0 || mb_audio_r !== 10'd0)
                    bad = 1'b1;
                @(posedge clk_mach);
            end
            check("A5 audio pins silent (off)", bad === 1'b0);
        end
        check_running("A6 cpu still running (loop counter climbs)");

        // ================= PHASE B: card ON =================
        // reset the machine (reboots the CPU; the ROM re-writes the NMI
        // vector during power-on), then enable the card
        machine_reset_base = 1'b1;
        clear_results;
        repeat (40) @(posedge clk_mach);
        mb_inslot_m = 1'b1;
        repeat (40) @(posedge clk_mach);
        machine_reset_base = 1'b0;

        // ROM power-on again -> settle -> re-plant + pin banks + NMI
        // (the NMI vector is ROM-fixed at $03FB; the card is now
        // in-slot so the $C4xx writes reach it)
        repeat (30_000) @(posedge clk_mach);
        plant_all;
        set_banks;
        fire_nmi;
        wait_marker(200_000);
        check("B1 program re-ran (inslot=1)", mk_seen());
        check("B2 $C403 readback = 0xA5 (real CPU writes/reads)",
              res_word(16'h0350) === 8'hA5);
        // let the tone run, then analyze
        repeat (64) @(posedge clk_mach);
        audio_window(2048);
        check("B3 O_AUDIO_L toggles (tone running in the machine PSG clocking)", trans >= 16);
        check("B3b tone half-period ~112 machine clocks (16 x 7; PZ = 14 mach clk)",
              period_sample >= 90 && period_sample <= 135);
        check("B4 duty ~50%", hi_cnt > 300 && hi_cnt < 1750);
        // high level = exactly the vol-15 YM2149 level (255)
        wait (mb_audio_l >= 10'd128);
        @(posedge clk_mach);
        check("B5 high level = 255 (vol 15)", mb_audio_l === 10'd255);
        check("B6 right channel silent", mb_audio_r === 10'd0);
        // machine still alive after all of it
        check_running("B7 cpu still running (not wedged by the card)");

        if (nfail == 0) $display("MB MACHINE TB ALL CHECKS PASSED");
        else            $display("MB MACHINE TB FAILURES: %0d", nfail);
        $finish;
    end


        wire [7:0]  m_dbg_di;
    // NMI injection: the machine NMI input is the MB card NMI ORed with
    // this TB pulse (NMI is unmaskable on the 6502)
    reg         nmi_inject = 1'b0;

    task fire_nmi;
        begin
            nmi_inject = 1'b1;
            repeat (1000) @(posedge clk_mach);
            nmi_inject = 1'b0;
        end
    endtask

    // ss softswitch-load port: ss_addr=3 loads the 8 softswitches from
    // ss_wdata[17:8] (bit8=RAMRD, bit9=RAMWRT, bit10=CXROM, bit11=STORE80)
    reg         ss_wren_t = 1'b0;
    reg [9:0]   ss_addr_t = 10'd0;
    reg [63:0]  ss_wdata_t = 64'd0;

    // page-$03 reads (incl. the $03FB program fetch) bank on the RAMRD
    // softswitch - pin it to bank 0 (main); pages $04-$07 also key on
    // RAMRD for reads, so the whole program stays in one bank
    task set_banks;
        begin
            ss_wdata_t = 64'h0000_0800;   // RAMRD=0, RAMWRT=0, CXROM=0, STORE80=1
            ss_addr_t  = 10'd3;
            ss_wren_t  = 1'b1;
            @(posedge clk_mach);
            ss_wren_t  = 1'b0;
            ss_addr_t  = 10'd0;
        end
    endtask

    // plant the program at $03FB in both RAM banks
    task plant_all;
        begin
            for (k = 0; k < PLEN; k = k + 1) begin
                ram_main[16'h03FB + k] = P[k];
                ram_aux[16'h03FB + k]  = P[k];
            end
        end
    endtask

    // watchdog
    initial begin
        #5_000_000_000;
        $display("MB MACHINE TB GLOBAL WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
