// tb_slot_fifo.sv - CDC + integrity test for slot_fifo (M0 rework, Unit 2)
//
// Two real asynchronous clocks:
//   wr_clk = 13.468 ns (74.25 MHz), rd_clk = 7.512 ns (133.12 MHz)
//
// Stimulus rule: every write/read is issued as exactly ONE clock pulse
// (negedge set, following negedge clear) via wr_rec()/rd_rec() - the
// enable waveform corresponds 1:1 to the intended transactions.
//
// Test order (contract failures are FATAL - $fatal, no counting mode):
//  A. reset: empty=1, full=0, overflow=0, high_water=0
//  B. single write -> single read (fundamental contract, before scale-up)
//  C. fill to 63 (not full), 64th (full), 65th raw write dropped
//     -> overflow latches; drain 64 records in order
//  R. mid-test core reset: pointers/overflow/high_water clear, empty=1
//  D. back-to-back refill of 64 at full wr rate -> high_water == 64
//  F. 4096 records with CONCURRENT writer/reader (the writer blocks on
//     full, so the reader must drain concurrently - a sequential
//     write-burst/read-burst pattern self-deadlocks on the 64-deep FIFO);
//     random pacing, no overflow, perfect order + integrity
//  G. overflow: stop reading, keep writing -> overflow latches sticky,
//     exactly the FIRST 64 records captured in order
//
// Data pattern: f32(i) (bijective), addr = i[23:0].
// Watchdog: 1 ms real-time deadline (test F alone is ~60 us).

`timescale 1ns / 1ps

module tb_slot_fifo;

  localparam WR_PERIOD = 13.468;
  localparam RD_PERIOD = 7.512;
  localparam DEPTH     = 64;
  localparam TOTAL_F   = 4096;   // records in test F
  localparam LIMIT_F   = 2000;   // record index base for test F

  // ---- watchdog: bounded simulation ----
  initial begin
    #1_000_000;
    $fatal(1, "WATCHDOG: 1 ms deadline exceeded (deadlock?)");
  end

  // ---- clocks ----
  reg wr_clk = 1'b0;
  reg rd_clk = 1'b0;
  always #(WR_PERIOD/2) wr_clk = ~wr_clk;
  always #(RD_PERIOD/2) rd_clk = ~rd_clk;

  // ---- DUT ----
  reg         rst        = 1'b1;
  reg         wr_en      = 1'b0;
  reg  [23:0] wr_addr    = 0;
  reg  [31:0] wr_data    = 0;
  wire        full, empty, overflow, rd_valid;
  wire [6:0]  high_water;
  reg         rd_en      = 1'b0;
  wire [23:0] rd_addr;
  wire [31:0] rd_data;

  slot_fifo #(.DEPTH(DEPTH)) dut (
    .wr_clk(wr_clk), .rst(rst),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .full(full), .overflow(overflow), .high_water(high_water),
    .rd_clk(rd_clk), .empty(empty), .rd_en(rd_en), .rd_valid(rd_valid),
    .rd_addr(rd_addr), .rd_data(rd_data)
  );

  // ---- expected pattern (bijective over the test ranges) ----
  function [31:0] f32;
    input [31:0] i;
    begin
      f32 = i * 32'h9E3779B9 + (i >> 3) ^ 32'hAAAAAAAA;
    end
  endfunction

  // contract check: first failure is fatal
  task chk(input cond, input string msg);
    begin
      if (!cond) $fatal(1, "CONTRACT FAIL: %s", msg);
    end
  endtask

  // exactly one write transaction (waits for headroom), 1:1 enable pulse
  task wr_rec(input [31:0] i);
    begin
      while (full) @(negedge wr_clk);
      @(negedge wr_clk);
      wr_en   <= 1'b1;
      wr_addr <= i[23:0];
      wr_data <= f32(i);
      @(negedge wr_clk);
      wr_en   <= 1'b0;
    end
  endtask

  // raw write, NO backpressure wait: accepted iff !full at the sampling
  // posedge, otherwise dropped (overflow latches). For overflow tests.
  task wr_rec_nw(input [31:0] i);
    begin
      @(negedge wr_clk);
      wr_en   <= 1'b1;
      wr_addr <= i[23:0];
      wr_data <= f32(i);
      @(negedge wr_clk);
      wr_en   <= 1'b0;
    end
  endtask

  // exactly one read transaction, verified against expected record i
  task rd_rec(input [31:0] i);
    begin
      while (empty) @(posedge rd_clk);
      @(negedge rd_clk); rd_en <= 1'b1;
      @(negedge rd_clk); rd_en <= 1'b0;
      while (!rd_valid) @(negedge rd_clk);
      chk(rd_addr == i[23:0], $sformatf("order: addr got %0d want %0d", rd_addr, i[23:0]));
      chk(rd_data == f32(i),   $sformatf("data: i=%0d got %h want %h", i, rd_data, f32(i)));
    end
  endtask

  integer i, k;
  integer next_i, rd_i;
  reg write_done, read_done;
  reg [31:0] seed_w, seed_r;
  function [31:0] lcg_w;
    begin
      seed_w = seed_w * 32'd1664525 + 32'd1013904223;
      lcg_w = seed_w;
    end
  endfunction
  function [31:0] lcg_r;
    begin
      seed_r = seed_r * 32'd22695477 + 32'd1013904223;
      lcg_r = seed_r;
    end
  endfunction

  initial begin
    // ---------------- A. reset state ----------------
    repeat (4) @(negedge wr_clk);
    repeat (4) @(negedge rd_clk);
    chk(empty,            "A: not empty after reset");
    chk(!full,           "A: full after reset");
    chk(!overflow,       "A: overflow after reset");
    chk(high_water == 0, "A: high_water not 0 after reset");

    rst = 1'b0;
    repeat (6) @(negedge rd_clk);   // let the read-side reset synchronizer clear

    // ---------------- B. single write -> single read ----------------
    wr_rec(0);
    rd_rec(0);
    @(negedge rd_clk); @(negedge rd_clk);
    chk(empty, "B: not empty after single round-trip");
    $display("B: single write/read contract OK");

    // ---------------- C. fill to full, overflow on drop ----------------
    // after test B, wr=1 rd=1 (record 0 was read). So:
    //   62 writes -> 62 stored; 63rd -> 63 stored; 64th -> 64 stored = full;
    //   65th (raw) -> dropped, overflow latches.
    for (i = 1; i <= 62; i = i + 1) wr_rec(i);    // 62 stored
    repeat (4) @(negedge wr_clk);
    chk(!full,     "C: full at 62 stored");
    chk(!overflow, "C: overflow before any dropped write");
    wr_rec(63);                                   // 63 stored
    repeat (4) @(negedge wr_clk);
    chk(!full, "C: full at 63 stored");
    wr_rec(64);                                   // 64 stored -> full
    repeat (4) @(negedge wr_clk);                 // Gray sync settle
    chk(full, "C: not full at 64 stored");
    wr_rec_nw(65);                                // 65th -> DROPPED, no wait
    repeat (4) @(negedge wr_clk);
    chk(overflow, "C: overflow must latch on dropped write");
    // drain the 64 legal records (1..64), in order (record 0 was read in B)
    for (i = 1; i <= DEPTH; i = i + 1) rd_rec(i);
    @(negedge rd_clk); @(negedge rd_clk);
    chk(empty, "C: not empty after drain");

    // ---------------- R. mid-test core reset ----------------
    // a core reset clears pointers, overflow, high_water (SDRAM contents
    // are out of scope - this is the FIFO, not the memory).
    rst = 1'b1;
    repeat (6) @(negedge wr_clk);
    repeat (6) @(negedge rd_clk);
    rst = 1'b0;
    repeat (8) @(negedge rd_clk);                 // read-side reset sync settle
    chk(empty,            "R: not empty after mid-test reset");
    chk(!full,           "R: full after mid-test reset");
    chk(!overflow,       "R: overflow not cleared by reset");
    chk(high_water == 0, "R: high_water not cleared by reset");
    $display("R: mid-test reset behavior OK");

    // ---------------- D. back-to-back refill -> high_water 64 ----------------
    for (i = 1000; i < 1000+DEPTH; i = i + 1) wr_rec(i);
    chk(high_water == 7'd64, $sformatf("D: high_water %0d != 64", high_water));
    for (i = 1000; i < 1000+DEPTH; i = i + 1) rd_rec(i);
    $display("D: back-to-back refill, high_water=64 OK");

    // ---------------- F. concurrent mixed traffic (4096 records) --------
    // writer and reader run concurrently: the writer blocks on full, so
    // the reader MUST drain concurrently (sequential write-burst then
    // read-burst self-deadlocks once the net burst growth fills the
    // 64-deep FIFO). Reader is clock-fast, so it always keeps up: no
    // overflow expected.
    seed_w = 12345; seed_r = 98765;
    next_i = LIMIT_F; rd_i = LIMIT_F;
    write_done = 1'b0; read_done = 1'b0;
    chk(!overflow, "F0: overflow not 0 at start of mixed traffic");
    fork
      begin : writer
        while (next_i < LIMIT_F + TOTAL_F) begin
          wr_rec(next_i);
          next_i = next_i + 1;
          if (lcg_w() % 5 == 0) @(negedge wr_clk);   // random write pacing
        end
        write_done = 1'b1;
      end
      begin : reader
        while (rd_i < LIMIT_F + TOTAL_F) begin
          if (rd_i < next_i) begin
            rd_rec(rd_i);
            rd_i = rd_i + 1;
          end else
            @(posedge rd_clk);
          if (lcg_r() % 3 == 0) @(posedge rd_clk);   // random read pacing
        end
        read_done = 1'b1;
      end
    join
    chk(write_done, "F: writer did not finish");
    chk(read_done,  "F: reader did not finish");
    chk(next_i == LIMIT_F + TOTAL_F, "F: writer count short");
    chk(rd_i == LIMIT_F + TOTAL_F, "F: not all records read");
    chk(!overflow, "F: overflow during normal (non-overflowing) traffic");
    $display("F: 4096-record concurrent mixed traffic OK (order + integrity, no overflow)");

    // ---------------- G. overflow: stop reading, keep writing ----------------
    // fifo is empty; write DEPTH+50 with NO waiting - the overflow attempts
    // must latch the flag, and the captured records must be the FIRST 64.
    for (i = 5000; i < 5000+DEPTH+50; i = i + 1) wr_rec_nw(i);
    repeat (6) @(negedge wr_clk);
    chk(overflow, "G: overflow not latched");
    for (i = 5000; i < 5000+DEPTH; i = i + 1) rd_rec(i);
    @(negedge rd_clk); @(negedge rd_clk);
    chk(empty, "G: not empty after overflow drain (only first 64 captured)");
    $display("G: overflow sticky + first-64-captured OK");

    $display("SLOT FIFO PASS: reset, single op, full/empty, high-water, 4096 mixed, overflow");
    $finish;
  end

endmodule
