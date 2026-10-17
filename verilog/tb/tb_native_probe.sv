// ============================================================================
// tb/tb_native_probe.sv — P2a step 1: measure the apple2 native video geometry
//
// Purpose: the Pocket video adapter (apf_video) must be designed to MEASURED
// facts, not assumptions. This harness instantiates the unmodified machine
// core (Apple-II_MiSTer/rtl/apple2.v + timing_generator + video_generator +
// rom + both CPUs) with level-1-style TB RAM and tie-offs, boots the real
// BIOS, and measures the native video interface:
//
//   - line length (master cycles per line, histogram)
//   - active (HBL-low) sample count per line
//   - frame structure: lines/frame, VBL lines/frame
//   - white-pixel count per line (content sanity: logo appears)
//   - VIDEO transition density per active line (pixel rate: full in text,
//     half in hires — the timing HAL's VID7M behavior)
//   - TEXT_MODE / HGR_MODE flags at frame boundaries
//
// Phases: TEXT (boot to logo, 90 frames) -> poke $C010=$80 -> HGR (30 frames).
// The poke goes through the TB-owned RAM (single-writer: this sampler block),
// mirroring how level_1's TB pokes the machine.
//
// DUT wiring reference: unit_tests/level_1/tb_l1.sv (reset chain mirrors
// apple2_top.v; here there is no reset_cold, so the machine just powers on).
// Keyboard is NOT instantiated: K=0, AKD=1, READ_KEY observed.
//
// Build: verilate_probe.sh  (verilator --binary --timing, pure TB)
// Run:   the exe must run with CWD = Apple-II_MiSTer/ repo root (the DUT's
//        $readmemh paths "rtl/roms/*.hex" are CWD-relative).
//        +cpu=0 -> nmos6502, +cpu=1 -> wdc65c02 (default)
// ============================================================================

`timescale 1ns / 1ps

module tb_native_probe;

  // ------------------------------------------------------------------
  // CPU selection (default: wdc 65C02 — the IIe CPU)
  // ------------------------------------------------------------------
  reg cpu_sel = 1'b1;
  initial begin
    integer plus_cpu;
    if ($value$plusargs("cpu=%d", plus_cpu))
      cpu_sel = (plus_cpu != 0);
  end

  // ------------------------------------------------------------------
  // 14.3 MHz master clock (35 ns half period; edge-count based like level_1)
  // ------------------------------------------------------------------
  reg clk_14m = 1'b0;
  always #35_000 clk_14m = ~clk_14m;

  // ------------------------------------------------------------------
  // DUT wires
  // ------------------------------------------------------------------
  wire [15:0] w_addr;
  wire [17:0] w_ram_addr;
  wire [7:0]  w_ram_di;
  wire [15:0] ram_do;
  wire        w_ram_aux;
  wire        w_ram_we;
  wire        w_cpu_we;
  wire        w_video, w_hbl, w_vbl;
  wire        w_col_line, w_text_mode, w_early_video, w_run_fill_ok;
  wire        w_hgr_mode, w_hgr80_mode, w_gr2, w_col80, w_dhires;
  wire        read_key;
  wire [3:0]  w_an;
  wire        w_pdl, w_stb;
  wire [7:0]  w_io_sel, w_dev_sel;
  wire        w_io_str, w_spk;
  wire        w_pz, w_pzr, w_pzf, w_clk2m;

  // ------------------------------------------------------------------
  // Reset chain (level_1 pattern; no reset_cold -> plain power-on)
  // ------------------------------------------------------------------
  reg power_on_reset = 1'b1;
  reg reset_sync     = 1'b1;
  reg [22:0] flash_div = 23'b0;
  always @(posedge clk_14m) begin
    reset_sync <= power_on_reset;
    if (flash_div[22] == 1'b1)
      power_on_reset <= 1'b0;
    flash_div <= flash_div + 1'b1;
  end

  // ------------------------------------------------------------------
  // TB RAM: 64K main + 64K aux, 1-cycle CE-latch (level_1 pattern)
  // ------------------------------------------------------------------
  reg [7:0] ram0 [0:65535];
  reg [7:0] ram1 [0:65535];
  always @(posedge clk_14m) begin: tb_ram
    if (w_ram_we & ~w_ram_aux) begin
      ram0[w_ram_addr[15:0]] <= w_ram_di;
      ram_do[7:0]            <= w_ram_di;
    end else begin
      ram_do[7:0]            <= ram0[w_ram_addr[15:0]];
    end
    if (w_ram_we & w_ram_aux) begin
      ram1[w_ram_addr[15:0]] <= w_ram_di;
      ram_do[15:8]           <= w_ram_di;
    end else begin
      ram_do[15:8]           <= ram1[w_ram_addr[15:0]];
    end
  end

  // ------------------------------------------------------------------
  // apple2: the machine core (unmodified, Apple-II_MiSTer/rtl)
  // ------------------------------------------------------------------
  apple2 d1 (
    .CLK_14M     (clk_14m),
    .CLK_2M      (w_clk2m),
    .PALMODE     (1'b0),
    .ROMSWITCH   (1'b0),
    .CPU_WAIT    (1'b0),
    .PHASE_ZERO  (w_pz),
    .PHASE_ZERO_R(w_pzr),
    .PHASE_ZERO_F(w_pzf),
    .FLASH_CLK   (flash_div[22]),
    .reset       (reset_sync),
    .cpu         (cpu_sel),
    .STALL       (1'b0),
    .ADDR        (w_addr),
    .ram_addr    (w_ram_addr),
    .D           (w_ram_di),
    .ram_do      (ram_do),
    .aux         (w_ram_aux),
    .PD          (8'h00),
    .CPU_WE      (w_cpu_we),
    .IRQ_n       (1'b1),
    .NMI_n       (1'b1),
    .ram_we      (w_ram_we),
    .VIDEO       (w_video),
    .COLOR_LINE  (w_col_line),
    .RUN_FILL_OK (w_run_fill_ok),
    .TEXT_MODE   (w_text_mode),
    .EARLY_VIDEO (w_early_video),
    .HGR_MODE    (w_hgr_mode),
    .HGR80_MODE  (w_hgr80_mode),
    .GR2         (w_gr2),
    .COL80       (w_col80),
    .DHIRES_MODE (w_dhires),
    .HBL         (w_hbl),
    .VBL         (w_vbl),
    .K           (8'h00),
    .READ_KEY    (read_key),
    .AKD         (1'b1),
    .AN          (w_an),
    .GAMEPORT    (8'h00),
    .PDL_STROBE  (w_pdl),
    .STB         (w_stb),
    .IO_SELECT   (w_io_sel),
    .DEVICE_SELECT(w_dev_sel),
    .IO_STROBE   (w_io_str),
    .ioctl_addr  (25'b0),
    .ioctl_data  (8'b0),
    .ioctl_index (8'b0),
    .ioctl_download(1'b0),
    .ioctl_wr    (1'b0),
    .saturn_5_inslot(1'b0),
    .speaker     (w_spk),
    .DBG_T65_REGS(),
    .DBG_DI(),
    .DBG_ROM_ADDR(),
    .DBG_ROM_OUT(),
    .ss_addr     (10'b0),
    .ss_wdata    (64'b0),
    .ss_wren     (1'b0),
    .ss_rdata    (),
    .machine_ce  (1'b1),
    .cpu_frozen  (),
    .Z80_EN      (1'b0),
    .Z80_A       (16'b0),
    .Z80_DO      (8'b0),
    .Z80_WE      (1'b0),
    .CPU_DI      ()
  );

  // ------------------------------------------------------------------
  // Video geometry sampler: 1 sample per master cycle (negedge).
  // Per line: total length, active length, white count, transition count.
  // Per frame (VBL rising): line count, VBL-line count, mode flags.
  // ------------------------------------------------------------------
  localparam TEXT_FRAMES = 90;   // ~1.5 s of video: BIOS boots to logo
  localparam HGR_FRAMES  = 30;

  integer phase = 0;             // 0=TEXT, 1=HGR
  integer frames_done = 0;
  integer frame_lines = 0;
  integer frame_vbl = 0;
  integer frame_white = 0;
  integer frame_trans = 0;

  reg  hbl_s = 1'b0, hbl_p = 1'b0;
  reg  vbl_s = 1'b0, vbl_p = 1'b0;
  reg  video_p = 1'b0;
  reg [13:0] smp = 14'd0;
  reg [13:0] act = 14'd0;
  reg [13:0] white = 14'd0;
  reg [13:0] trans = 14'd0;
  reg [13:0] white_hist [0:1023];
  reg [13:0] len_hist [0:1023];
  reg [13:0] act_hist [0:1023];
  reg [13:0] last_white [0:511];   // white/line of the final frame

  always @(negedge clk_14m) begin: sampler
    // frame boundary: VBL rising
    if (vbl_s && !vbl_p) begin
      if (frames_done > 0)
        $display("F%0d[%s] lines=%0d vbl=%0d white=%0d trans=%0d text=%b hgr=%b dhires=%b",
                 frames_done, phase ? "HGR" : "TXT",
                 frame_lines, frame_vbl, frame_white, frame_trans,
                 w_text_mode, w_hgr_mode, w_dhires);
      frame_lines <= 0; frame_vbl <= 0; frame_white <= 0; frame_trans <= 0;
      frames_done <= frames_done + 1;
      if (!phase && frames_done == TEXT_FRAMES) begin
        // poke $C010 = $80 (HGR) through TB RAM; single writer = this block
        ram0[16'hC010] <= 8'h80;
        phase <= 1;
        $display("--- phase 1: poked C010=80 (HGR) ---");
      end
    end
    vbl_p <= vbl_s; vbl_s <= w_vbl;

    // line boundaries on HBL edges
    if (hbl_p && !hbl_s) begin
      // line start (HBL falling)
      smp <= 14'd0; act <= 14'd0; white <= 14'd0; trans <= 14'd0;
    end else if (!hbl_p && hbl_s) begin
      // line end (HBL rising): commit stats
      if (smp <= 14'd1023) begin
        len_hist[smp] <= len_hist[smp] + 14'd1;
        act_hist[act] <= act_hist[act] + 14'd1;
        white_hist[white] <= white_hist[white] + 14'd1;
        last_white[frame_lines & 511] <= white;
      end
      frame_lines <= frame_lines + 1;
      if (vbl_s) frame_vbl <= frame_vbl + 1;
      frame_white <= frame_white + white;
      frame_trans <= frame_trans + trans;
      smp <= 14'd0;
    end else if (!hbl_s) begin
      if (w_video !== video_p) trans <= trans + 14'd1;
      video_p <= w_video;
      if (w_video) white <= white + 14'd1;
      smp <= smp + 14'd1;
      act <= act + 14'd1;
    end
    hbl_p <= hbl_s; hbl_s <= w_hbl;
  end

  // ------------------------------------------------------------------
  // Report + finish
  // ------------------------------------------------------------------
  task report(string name);
    integer i;
    begin
      $display("=== %s: line-length histogram (nonzero bins) ===", name);
      for (i = 0; i <= 1023; i = i + 1)
        if (len_hist[i] != 0) $display("  len=%4d  x%0d", i, len_hist[i]);
      $display("=== %s: active-length histogram (nonzero bins) ===", name);
      for (i = 0; i <= 1023; i = i + 1)
        if (act_hist[i] != 0) $display("  act=%4d  x%0d", i, act_hist[i]);
      $display("=== %s: white-per-line histogram (nonzero bins, top 25) ===", name);
      begin : topw
        integer shown = 0;
        for (i = 1; i <= 1023 && shown < 25; i = i + 1)
          if (white_hist[i] != 0) begin
            $display("  white=%4d  x%0d", i, white_hist[i]);
            shown = shown + 1;
          end
      end
      $display("=== %s: last frame white/line (lines with content) ===", name);
      for (i = 0; i <= 511; i = i + 1)
        if (last_white[i] != 0) $display("  line=%3d white=%4d", i, last_white[i]);
      // clear for the next phase
      for (i = 0; i <= 1023; i = i + 1) begin
        len_hist[i] = 0; act_hist[i] = 0; white_hist[i] = 0;
      end
      for (i = 0; i <= 511; i = i + 1) last_white[i] = 0;
    end
  endtask

  initial begin
    // TEXT phase ends (phase flips at TEXT_FRAMES completed frames) ->
    // report the TEXT histograms before HGR lines mix in; then let the HGR
    // phase run and report it.
    wait (phase == 1);
    #1;
    report("TEXT");
    wait (frames_done >= TEXT_FRAMES + HGR_FRAMES);
    report("HGR");
    $display("PROBE DONE (cpu=%b)", cpu_sel);
    #10_000 $finish;
  end

endmodule
