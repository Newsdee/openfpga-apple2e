// tb_disk_store.sv - Unit 3: storage-path test for disk_store +
// io_sdram_pocket + behavioral 4-bank DRAM model (M0 rework)
//
// Chain under test:
//   TB(74.25 domain) -> slot_fifo -> disk_store -> io_sdram_pocket -> DRAM
//
// Tests (contract failures are FATAL; the DRAM model $fatal's on any
// SDRAM protocol violation):
//  A. reset then boot: init_done rises after the full boot sequence
//  B. load 128 words through the whole path; load_drained; counters match;
//     no timeout; no FIFO overflow
//  C. read every word back through the word_rd port; all data matches
//  D. load a second block; first block still intact (no reset of the
//     storage path between loads - resident-image behavior); counters
//     accumulate; readback of both blocks correct
//  E. machine-reset analog: nothing in this path resets (verified by
//     D's intactness); explicit no-op here
//
// Watchdog: 2 ms (boot alone is ~226 us).

`timescale 1ns / 1ps

module tb_disk_store;  // parameter real PHASE: chip posedge offset vs ctrl posedge (ns)
  parameter real PHASE = 3.756;   // 180 deg - matches apple2e_sdram_pll outclk_1 (3756 ps)

  localparam WR_PERIOD  = 13.468;   // 74.25 MHz
  localparam N_WORDS    = 128;      // records per block (512-byte sector)

  // ---- watchdog ----
  initial begin
    #2_000_000;
    $fatal(1, "WATCHDOG: 2 ms deadline exceeded");
  end


  // ---- clocks (all delays in ns) ----
  // Phase matches the FPGA PLL (mp2): outclk_0 (ctrl) at 0 ps, outclk_1
  // (chip) at +6573 ps phase shift on a 7512.1 ps period => chip leads
  // ctrl by 939.1 ps. The controller's read-capture chain (e4 window)
  // is phase-sensitive; this is the phase it was designed for.
  // ctrl posedges: 3.75605 + k*7.5121 ns; chip posedges: 3.75605 + PHASE + k*7.5121
  // (FPGA mp2: outclk_1 at +6573 ps shift on 7512.1 ps period => chip leads
  //  ctrl by 939.1 ps => PHASE = -0.939)
  reg wr_clk   = 1'b0;
  reg clk      = 1'b1;    // controller_clk
  reg chip_clk = 1'b0;    // SDRAM chip clock
  always #(WR_PERIOD/2) wr_clk = ~wr_clk;
  always #3.75605 clk = ~clk;
  always begin
    #(3.75605 + PHASE); chip_clk = 1'b1;   // first posedge offset vs ctrl
    forever begin
      #3.75605 chip_clk = 1'b0;
      #3.75605 chip_clk = 1'b1;
    end
  end

  // ---- DUT chain wires ----
  reg        rst_n = 1'b0;        // core POR (async, stored path)
  reg        por_done = 1'b0;

  // FIFO (write side in 74.25 domain, read side in controller domain)
  reg        fifo_wr_en = 1'b0;
  reg  [23:0] fifo_wr_addr = 0;
  reg  [31:0] fifo_wr_data = 0;
  wire        fifo_full;
  wire [6:0]  fifo_high_water;
  wire        fifo_empty, fifo_rd_valid;
  wire        fifo_overflow_sticky;
  reg         fifo_rd_en;
  wire [23:0] fifo_rd_addr;
  wire [31:0] fifo_rd_data;

  slot_fifo #(.DEPTH(64)) fifo (
    .wr_clk(wr_clk), .rst(!rst_n),
    .wr_en(fifo_wr_en), .wr_addr(fifo_wr_addr), .wr_data(fifo_wr_data),
    .full(fifo_full), .overflow(fifo_overflow_sticky), .high_water(fifo_high_water),
    .rd_clk(clk), .empty(fifo_empty), .rd_en(fifo_rd_en),
    .rd_valid(fifo_rd_valid), .rd_addr(fifo_rd_addr), .rd_data(fifo_rd_data)
  );

  // store owner (controller domain)
  wire [15:0] words_received, words_committed;
  wire        store_busy, load_drained, store_timeout;
  wire        store_word_wr;
  wire [23:0] store_word_addr;
  wire [31:0] store_word_data;
  wire        word_busy, word_done, init_done;

  // TB readback source (controller domain) - the word port is shared:
  // the store owns it while active; the TB readback only issues when
  // !store_busy (protocol enforced by rd_back). word_wr is store-only.
  reg        word_rd = 1'b0;
  reg  [23:0] rd_back_addr = 0;

  wire word_wr = store_word_wr;
  wire [23:0] word_addr = store_busy ? store_word_addr : rd_back_addr;
  wire [31:0] word_data = store_busy ? store_word_data : 32'd0;

  disk_store #(.TIMEOUT_CYCLES(4096)) store (
    .clk(clk), .rst_n(rst_n),
    .fifo_empty(fifo_empty),
    .fifo_rd_en(fifo_rd_en),
    .fifo_rd_valid(fifo_rd_valid),
    .fifo_rd_addr(fifo_rd_addr),
    .fifo_rd_data(fifo_rd_data),
    .word_wr(store_word_wr),
    .word_addr(store_word_addr),
    .word_data(store_word_data),
    .word_busy(word_busy),
    .word_done(word_done),
    .init_done(init_done),
    .store_busy(store_busy),
    .load_drained(load_drained),
    .words_received(words_received),
    .words_committed(words_committed),
    .timeout(store_timeout)
  );

  // SDRAM controller (stock FSM, Pocket diff signals)
  wire        phy_cke, phy_cas, phy_ras, phy_we;
  wire [1:0]  phy_ba;
  wire [12:0] phy_a;
  wire [15:0] phy_dq;
  wire [1:0]  phy_dqm;
  wire [31:0] word_q;
  wire        word_rd_valid;

  io_sdram_pocket ctrl (
    .controller_clk(clk),
    .chip_clk(chip_clk),
    .clk_90(clk),          // unused by the controller body
    .reset_n(rst_n),
    .phy_cke(phy_cke),
    .phy_clk(),            // SDRAM clock pin = chip_clk (pass-through)
    .phy_cas(phy_cas),
    .phy_ras(phy_ras),
    .phy_we(phy_we),
    .phy_ba(phy_ba),
    .phy_a(phy_a),
    .phy_dq(phy_dq),
    .phy_dqm(phy_dqm),
    .burst_rd(1'b0),
    .burst_addr(25'd0),
    .burst_len(11'd0),
    .burst_32bit(1'b0),
    .burst_data(),
    .burst_data_valid(),
    .burst_data_done(),
    .burstwr(1'b0),
    .burstwr_addr(25'd0),
    .burstwr_ready(),
    .burstwr_strobe(1'b0),
    .burstwr_data(16'd0),
    .burstwr_done(1'b0),
    .word_rd(word_rd),
    .word_wr(word_wr),
    .word_addr(word_addr),
    .word_data(word_data),
    .word_q(word_q),
    .word_busy(word_busy),
    .word_done(word_done),
    .word_rd_valid(word_rd_valid),
    .boot_done(init_done)
  );

  // behavioral SDRAM
  tb_dram_model dram (
    .clk(chip_clk),
    .cke(phy_cke),
    .ras(phy_ras),
    .cas(phy_cas),
    .we(phy_we),
    .por_done(por_done),
    .ba(phy_ba),
    .a(phy_a),
    .dq(phy_dq),
    .dqm(phy_dqm)
  );

  // ---- expected pattern ----
  function [31:0] f32;
    input [31:0] i;
    begin
      f32 = i * 32'h9E3779B9 + (i >> 3) ^ 32'hAAAAAAAA;
    end
  endfunction

  task chk(input cond, input string msg);
    begin
      if (!cond) $fatal(1, "CONTRACT FAIL: %s", msg);
    end
  endtask

  // one FIFO write record (74.25 domain), waits for headroom
  task wr_rec(input [31:0] i);
    begin
      while (fifo_full) @(negedge wr_clk);
      @(negedge wr_clk);
      fifo_wr_en   <= 1'b1;
      fifo_wr_addr <= i[23:0];
      fifo_wr_data <= f32(i);
      @(negedge wr_clk);
      fifo_wr_en   <= 1'b0;
    end
  endtask

  // wait for load_drained with a deadline
  task wait_drained(input [31:0] deadline_cycles, input string ctx);
    integer c;
    begin
      c = 0;
      while (!load_drained) begin
        @(posedge clk);
        c = c + 1;
        if (c > deadline_cycles)
          $fatal(1, "CONTRACT FAIL: %s - load_drained never asserted (%0d cycles)", ctx, c);
      end
    end
  endtask

  // one word-port readback (controller domain), verified
  task rd_back(input [31:0] i);
    begin
      while (store_busy || word_busy) @(posedge clk);
      rd_back_addr = i[23:0];          // mux selects it while !store_busy
      @(negedge clk);
      word_rd <= 1'b1;                          // rise - HELD level (edge-latch queue needs the
      while (!word_rd_valid) @(negedge clk);    // level held until the op completes; a 1-cycle pulse
      word_rd <= 1'b0;                          // races the 3FF sync + auto-refresh and can be lost
      @(negedge clk);                           // (gap before the next word re-arms the queue)
      chk(word_q == f32(i), $sformatf("readback i=%0d got %h want %h", i, word_q, f32(i)));
    end
  endtask

  integer i;
  initial begin
    #15_000;                     // power-on settle for the DRAM model
    por_done = 1'b1;

    // ---------------- A. reset release + boot ----------------
    repeat (4) @(negedge wr_clk);
    rst_n = 1'b1;
    @(posedge clk);
    chk(!init_done, "A: init_done before boot");
    while (!init_done) @(posedge clk);   // boot ~30k cycles (~226 us)
    $display("A: boot complete, init_done");

    // ---------------- B. load block 1 (128 words) ----------------
    for (i = 0; i < N_WORDS; i = i + 1)
      wr_rec(i);
    wait_drained(50_000, "B: block 1");
    chk(words_received == N_WORDS[15:0],  $sformatf("B: received %0d != %0d", words_received, N_WORDS));
    chk(words_committed == N_WORDS[15:0], $sformatf("B: committed %0d != %0d", words_committed, N_WORDS));
    chk(!store_timeout,      "B: store timeout");
    chk(!fifo_overflow_sticky, "B: FIFO overflow");
    chk(!store_busy,         "B: store still busy");
    $display("B: block 1 stored, counters %0d/%0d", words_received, words_committed);

    // ---------------- C. read back block 1 ----------------
    for (i = 0; i < N_WORDS; i = i + 1)
      rd_back(i);
    $display("C: block 1 readback OK (all %0d words match)", N_WORDS);

    // ---------------- D. load block 2; block 1 intact ----------------
    for (i = 0; i < N_WORDS; i = i + 1)
      wr_rec(1000 + i);
    wait_drained(50_000, "D: block 2");
    chk(words_received == 2*N_WORDS[15:0],  "D: received short");
    chk(words_committed == 2*N_WORDS[15:0], "D: committed short");
    chk(!store_timeout, "D: store timeout");
    // block 1 must be untouched (no reset of the storage path between loads)
    for (i = 0; i < N_WORDS; i = i + 1)
      rd_back(i);
    // block 2
    for (i = 0; i < N_WORDS; i = i + 1)
      rd_back(1000 + i);
    $display("D: block 2 stored; block 1 intact; both readbacks OK");

    $display("DISK STORE PASS: boot, %0d-word store, counters, readback, reload, no-protocol-violations", N_WORDS);
    $finish;
  end

endmodule
