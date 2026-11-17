//
// tb_savestate_manager.sv - unit gate for the imported savestate_manager FSM
// (PLAN_SAVESTATES_2026-11-09 phase 3; EXPERT_BRIEF_SAVESTATE_MANAGER_2026-11-11)
//
// Self-contained: fake slot (64-bit register array, 1-cycle request /
// 2-cycle op / slot_ready pulse - the donor savestate_ddr contract), fake
// machine ss_* port (the 11-word golden map), fake RAM (1-cycle read
// latency), fake cpu_frozen (rises 3 cycles after the DUT's stall).
//
// Gates:
//   T1 save:   blob == {headers, golden shadow, packed golden RAM}; machine
//              untouched; machine_ce deasserted outside the freeze window
//   T2 load:   corrupted live RAM + machine state restored exactly;
//              ss_wren applied to shadow words 0/1/2/3/4
//   T3 errors: rejected(1), empty/bad-magic/bad-size(2), bad-version/
//              bad-cpu(3)
//   T4 freeze: no slot/machine access before cpu_frozen rose
//   T5 counter: save#2 header word0 counter == 2
//
// Build:  ../run_tb_savestate_manager.sh   (verilator --binary --timing)
//
`timescale 1ns/1ps
module tb_savestate_manager;

  // ---- clocks / controls ------------------------------------------------
  reg clk = 1'b0;
  initial forever #35 clk = ~clk;      // ~14.3 MHz

  reg         reset          = 1'b0;
  reg         request_save   = 1'b0;
  reg         request_load   = 1'b0;
  reg         allow_save_state = 1'b1;
  reg         cpu_type       = 1'b1;   // 65C02 (the pinned top's selection)

  wire        stall, machine_ce;
  reg         busy = 0, done = 0, error = 0;
  reg  [1:0]  error_code = 2'd0;
  reg         locked_cpu_type = 0;

  wire  [9:0]  ss_addr;
  wire  [63:0] ss_wdata;
  wire         ss_wren;
  wire  [63:0] ss_rdata;

  wire         ram_bank;
  wire  [15:0] ram_addr;
  wire         ram_rd, ram_wr;
  wire  [7:0]  ram_wdata;
  wire  [7:0]  ram_rdata;

  wire  [14:0] slot_addr;
  wire         slot_rd, slot_wr;
  wire  [63:0] slot_wdata;
  wire  [63:0] slot_rdata;
  wire         slot_ready;
  reg          slot_ready_r = 1'b0;
  assign slot_ready = slot_ready_r;

  // ---- DUT --------------------------------------------------------------
  savestate_manager dut (
    .clk(clk), .reset(reset),
    .request_save(request_save), .request_load(request_load),
    .allow_save_state(allow_save_state),
    .cpu_type(cpu_type),
    .cpu_frozen(cpu_frozen),
    .stall(stall), .machine_ce(machine_ce),
    .busy(busy), .done(done), .error(error),
    .error_code(error_code), .locked_cpu_type(locked_cpu_type),
    .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren),
    .ss_rdata(ss_rdata),
    .ram_bank(ram_bank), .ram_addr(ram_addr),
    .ram_rd(ram_rd), .ram_wr(ram_wr), .ram_wdata(ram_wdata), .ram_rdata(ram_rdata),
    .slot_addr(slot_addr), .slot_rd(slot_rd), .slot_wr(slot_wr),
    .slot_wdata(slot_wdata), .slot_rdata(slot_rdata), .slot_ready(slot_ready)
  );

  // ---- fake slot (donor savestate_ddr contract) -------------------------
  // Mirrors the donor ddr's state discipline: IDLE samples the request
  // LEVEL, the op runs 2 cycles, slot_ready pulses on completion, and a
  // 1-cycle COOLDOWN elapses before IDLE re-samples. The cooldown is what
  // makes held levels (the manager keeps slot_wr/slot_rd high across
  // consecutive same-state words) re-arm exactly once per word, and lets
  // slot_addr settle after the manager advances on the ready cycle.
  reg  [63:0] blob [0:16415];
  reg  [1:0]  sl_state = 0;      // 0=IDLE 1=OP 2=COOLDOWN
  reg  [1:0]  sl_cnt = 0;
  reg         sl_is_rd;
  reg  [14:0] sl_addr;
  reg  [63:0] slot_rdata_r = 64'd0;
  always @(posedge clk) begin
    slot_ready_r <= 1'b0;
    if (reset) begin
      sl_state <= 2'd0; sl_cnt <= 2'd0;
    end else begin
      case (sl_state)
        2'd0: begin   // IDLE: sample level
          if (slot_rd || slot_wr) begin
            sl_is_rd  <= slot_rd;
            sl_addr   <= slot_addr;
            sl_cnt    <= 2'd0;
            sl_state  <= 2'd1;
          end
        end
        2'd1: begin   // OP: 2 cycles
          if (sl_cnt == 2'd2) begin
            slot_ready_r <= 1'b1;
            if (sl_is_rd)
              slot_rdata_r <= blob[sl_addr];
            else
              blob[sl_addr] <= slot_wdata;
            sl_state <= 2'd2;
          end else begin
            sl_cnt <= sl_cnt + 2'd1;
          end
        end
        default: sl_state <= 2'd0;   // COOLDOWN: 1 cycle
      endcase
    end
  end
  assign slot_rdata = slot_rdata_r;

  // ---- fake machine ss_* (golden 11-word map) ----------------------------
  localparam [63:0] GOLD_MACH   = {41'd0, 8'hFF, 8'h0F, 8'h5A};
  localparam [63:0] GOLD_LATCH  = {38'd0, 1'b1, 1'b1, 16'hBEEF, 8'h77};
  localparam [63:0] GOLD_TIMING = 64'h1111_2222_3333_4444;
  localparam [63:0] GOLD_VIDEO  = 64'hAAAABBBBCCCCDDDD;
  localparam [63:0] GOLD_CPU    = 64'hC0DE_ADDE_1234_5678;

  reg [63:0] ss_rdata_r = 64'd0;
  always @(*) begin
    case (ss_addr)
      10'd3:      ss_rdata_r = GOLD_MACH;
      10'd4:      ss_rdata_r = GOLD_LATCH;
      10'd5,
      10'd6:      ss_rdata_r = GOLD_TIMING;
      10'd7:      ss_rdata_r = GOLD_VIDEO;
      default:    ss_rdata_r = GOLD_CPU;    // ss_addr 0-2, 8-10 (and gaps)
    endcase
  end
  assign ss_rdata = ss_rdata_r;

  // applied-write tracker (machine restore verification)
  reg [10:0] applied_seen = 11'd0;
  reg [63:0] applied_w [0:10];
  integer ai;
  always @(posedge clk) begin
    if (ss_wren && (ss_addr < 11'd11)) begin
      applied_seen[ss_addr] <= 1'b1;
      applied_w[ss_addr]    <= ss_wdata;
    end
  end

  // ---- fake RAM (1-cycle read latency) ----------------------------------
  // 2 banks x 64 KB: the DUT addresses {ram_bank, ram_addr} (byte_index[16:0]).
  // The aux bank is the classic trap (PLAN refinement #3): a bank-blind
  // model here would silently mis-restore 80-column text.
  reg  [7:0] ram [0:131071];
  reg  [7:0] ram_rdata_r = 8'd0;
  always @(posedge clk) begin
    if (ram_rd)
      ram_rdata_r <= ram[{ram_bank, ram_addr}];
    else if (ram_wr)
      ram[{ram_bank, ram_addr}] <= ram_wdata;
  end
  assign ram_rdata = ram_rdata_r;

  // ---- fake cpu_frozen (rises 3 cycles after stall) ---------------------
  reg stall_d = 0;
  reg [3:0] frz_cnt = 0;
  always @(posedge clk) begin
    stall_d <= stall;
    if (stall && !stall_d)
      frz_cnt <= 4'd4;
    else if (stall && frz_cnt != 0)
      frz_cnt <= frz_cnt - 4'd1;
  end
  wire cpu_frozen = stall && (frz_cnt == 0);

  // ---- monitors -----------------------------------------------------------
  reg  freeze_seen_early = 0;   // slot/machine access before cpu_frozen rose
  reg  frozen_rise_seen  = 0;
  always @(posedge clk) begin
    if (cpu_frozen && !frozen_rise_seen && stall)
      frozen_rise_seen <= 1'b1;
    if (!cpu_frozen && !stall)
      frozen_rise_seen <= 1'b0;
    if (!frozen_rise_seen && stall && busy &&
        (slot_rd || slot_wr || ss_wren || ram_rd || ram_wr))
      freeze_seen_early <= 1'b1;
  end
  reg  [31:0] ce_high_busy = 0;   // busy cycles with machine_ce=1 (freeze only)
  reg  [31:0] ce_low_busy  = 0;
  always @(posedge clk) begin
    if (busy) begin
      if (machine_ce) ce_high_busy <= ce_high_busy + 32'd1;
      else            ce_low_busy  <= ce_low_busy  + 32'd1;
    end
  end

  // ---- checkbook ----------------------------------------------------------
  integer nfail = 0;
  integer nloop = 0;
  task check(input [1023:0] name, input cond);
    begin
      if (!cond) begin
        nfail = nfail + 1;
        $display("FAIL: %0s", name);
      end else begin
        $display("ok  : %0s", name);
      end
    end
  endtask

  task wait_done(input [1023:0] name, output reg [1:0] code,
                 input integer timeout);
    integer t;
    begin
      t = 0; code = 2'd0;
      while (!done && t < timeout) begin
        @(posedge clk); t = t + 1;
      end
      if (!done) begin
        nfail = nfail + 1;
        $display("FAIL: %0s (timeout, no done)", name);
      end else begin
        code = error_code;
      end
    end
  endtask

  // ---- tests ---------------------------------------------------------------
  integer k, i;
  reg [63:0] expect_word;
  reg [1:0]  ec;

  initial begin
    // init
    for (i = 0; i < 16416; i = i + 1)
      blob[i] = 64'd0;
    for (i = 0; i < 131072; i = i + 1)
      ram[i] = 8'hA0 ^ i[7:0];
    reset = 1'b1;
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    // ================= T1: save =================
    // note: the donor increments ss_counter on the save request, so the
    // first capture stores counter==2 (T5 checks the increment).
    nloop = 0;
    request_save = 1'b1;
    repeat (2) @(posedge clk);
    request_save = 1'b0;
    wait_done("T1 save completes", ec, 4_000_000);
    check("T1 no error", error === 1'b0);
    check("T1 header0 {size,counter=2}",
          blob[0] === {32832, 32'd2});
    check("T1 header1 {MAGIC,ver,cpu}",
          blob[1] === {32'h41324C31, 8'd1, 23'd0, 1'b1});
    check("T1 headers 2-15 zero", (blob[2] === 64'd0) && (blob[15] === 64'd0));
    for (k = 0; k < 11; k = k + 1) begin
      expect_word = (k == 3) ? GOLD_MACH :
                    (k == 4) ? GOLD_LATCH :
                    (k == 5 || k == 6) ? GOLD_TIMING :
                    (k == 7) ? GOLD_VIDEO : GOLD_CPU;
      if (blob[16 + k] !== expect_word) begin
        nfail = nfail + 1;
        nloop = nloop + 1;
        $display("FAIL: T1 shadow word %0d = %h expect %h", k, blob[16+k], expect_word);
      end
    end
    check("T1 shadow 0-10", nloop == 0);
    // RAM: blob[32+k] = {ram[8k+7],...,ram[8k]}
    nloop = 0;
    for (k = 0; k < 16384; k = k + 1) begin
      expect_word = {ram[8*k+7], ram[8*k+6], ram[8*k+5], ram[8*k+4],
                     ram[8*k+3], ram[8*k+2], ram[8*k+1], ram[8*k]};
      if (blob[32 + k] !== expect_word) begin
        nfail = nfail + 1;
        nloop = nloop + 1;
        if (nloop <= 5)
          $display("FAIL: T1 ram word %0d = %h expect %h", k, blob[32+k], expect_word);
      end
    end
    check("T1 all 16384 ram words", nloop == 0);
    check("T1 machine_ce only in freeze window (<=20 cycles)",
          ce_high_busy <= 32'd20);
    check("T1 machine_ce deasserted for the op (>1000 cycles)",
          ce_low_busy > 32'd1000);
    check("T1 no access before cpu_frozen", freeze_seen_early === 1'b0);
    // save must not disturb the machine
    check("T1 ram untouched by save",
          ram[0] === 8'hA0 && ram[1] === 8'hA1 && ram[131071] === 8'h5F);

    // ================= T2: load restores =================
    // corrupt live state
    nloop = 0;
    for (i = 0; i < 131072; i = i + 1)
      ram[i] = 8'hFF ^ i[7:0];
    for (ai = 0; ai < 11; ai = ai + 1) begin
      applied_seen[ai] <= 1'b0;
      applied_w[ai]    <= 64'd0;
    end
    repeat (4) @(posedge clk);
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T2 load completes", ec, 4_000_000);
    check("T2 no error", error === 1'b0);
    for (i = 0; i < 131072; i = i + 1) begin
      if (ram[i] !== (8'hA0 ^ i[7:0])) begin
        nfail = nfail + 1;
        nloop = nloop + 1;
        if (nloop <= 5)
          $display("FAIL: T2 ram[%0d] = %h expect %h", i, ram[i], 8'hA0 ^ i[7:0]);
      end
    end
    check("T2 all 131072 ram bytes restored", nloop == 0);
    check("T2 applied word3 (machine)",
          applied_seen[3] === 1'b1 && applied_w[3] === GOLD_MACH);
    check("T2 applied word4 (latches)",
          applied_seen[4] === 1'b1 && applied_w[4] === GOLD_LATCH);
    check("T2 applied words 0/1/2 (cpu)",
          applied_seen[0] === 1'b1 && applied_w[0] === GOLD_CPU &&
          applied_seen[1] === 1'b1 && applied_w[1] === GOLD_CPU &&
          applied_seen[2] === 1'b1 && applied_w[2] === GOLD_CPU);

    // ================= T3: error taxonomy =================
    // T3a rejected
    allow_save_state = 1'b0;
    request_save = 1'b1;
    repeat (2) @(posedge clk);
    request_save = 1'b0;
    wait_done("T3a rejected completes", ec, 100_000);
    check("T3a rejected -> error_code 1", error === 1'b1 && ec === 2'd1);
    allow_save_state = 1'b1;
    repeat (4) @(posedge clk);

    // T3b empty slot (word1 == 0)
    blob[1] = 64'd0;
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T3b empty completes", ec, 100_000);
    check("T3b empty -> 2 (invalid)", error === 1'b1 && ec === 2'd2);

    // T3c bad magic
    blob[1] = {32'hDEADBEEF, 8'd1, 23'd0, 1'b1};
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T3c bad-magic completes", ec, 100_000);
    check("T3c bad magic -> 2 (invalid)", error === 1'b1 && ec === 2'd2);
    blob[1] = {32'h41324C31, 8'd1, 23'd0, 1'b1};

    // T3d bad version
    blob[1] = {32'h41324C31, 8'd2, 23'd0, 1'b1};
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T3d bad-version completes", ec, 100_000);
    check("T3d bad version -> 3 (incompatible)", error === 1'b1 && ec === 2'd3);
    blob[1] = {32'h41324C31, 8'd1, 23'd0, 1'b1};

    // T3e bad cpu
    blob[1] = {32'h41324C31, 8'd1, 23'd0, 1'b0};
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T3e bad-cpu completes", ec, 100_000);
    check("T3e bad cpu -> 3 (incompatible)", error === 1'b1 && ec === 2'd3);
    blob[1] = {32'h41324C31, 8'd1, 23'd0, 1'b1};

    // T3f size zero / oversized
    blob[0] = {32'd0, 32'd5};
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T3f zero-size completes", ec, 100_000);
    check("T3f size==0 -> 2 (invalid)", error === 1'b1 && ec === 2'd2);
    blob[0] = {32832 + 1, 32'd5};
    request_load = 1'b1;
    repeat (2) @(posedge clk);
    request_load = 1'b0;
    wait_done("T3f oversized completes", ec, 100_000);
    check("T3f size>max -> 2 (invalid)", error === 1'b1 && ec === 2'd2);
    blob[0] = {32832, 32'd5};

    // failed loads must not have touched the machine
    check("T3 failed loads left ram intact",
          ram[0] === 8'hA0 && ram[131071] === 8'h5F);

    // ================= T5: counter increments =================
    request_save = 1'b1;
    repeat (2) @(posedge clk);
    request_save = 1'b0;
    wait_done("T5 save#2 completes", ec, 4_000_000);
    check("T5 counter incremented", blob[0] === {32832, 32'd3});
    check("T5 no error", error === 1'b0);

    // ---- verdict ----------------------------------------------------------
    if (nfail == 0)
      $display("SAVESTATE MANAGER TB: PASS (T1 save, T2 load, T3 errors, T5 counter)");
    else
      $display("SAVESTATE MANAGER TB: FAIL (%0d failures)", nfail);
    $finish;
  end

  // global watchdog
  initial begin
    #(14.318ms * 400);   // ~5.7 s of sim time
    $display("SAVESTATE MANAGER TB: FAIL (global watchdog timeout)");
    $finish;
  end

endmodule
