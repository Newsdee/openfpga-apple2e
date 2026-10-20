// tb_dram_model.sv - behavioral 4-bank mobile-SDRAM model for M0 storage TBs
//
// Matches the physical interface of io_sdram_pocket (basicassets io_sdram):
//   1:1 clock, 16-bit DQ, 4 banks, CAS=3, BL=1, 2-bit DQM
//   64 MiB: bank[1:0] x row[12:0] (8192) x col[9:0] (1024) x 16-bit
//
// Convention (matches the controller's pin driving):
//   ACT cycle:       row = a[12:0]
//   READ/WRITE:      col = a[9:0], 16-bit data on DQ
//
// Enforced SDRAM timing (violation => immediate $fatal with context):
//   tRCD=3 (ACT->READ/WRITE), tRP=3 (PRECHG->ACT), tRAS=7 (ACT->PRECHG),
//   tWR=3 (write data->PRECHG), tRC=9 (ACT->ACT same bank),
//   tRFC=12 (auto-refresh), power-on settle before first command.
//   Only one read pending at a time (the controller serializes ops).
//
// Commands (ras,cas,we): ACT=011 READ=101 WRITE=100 PRECHG=010
//                        AUTOREF=001 NOP=111, LMR=000 (ignored, like NOP)
//
module tb_dram_model (
    input  wire        clk,     // chip_clk
    input  wire        cke,
    input  wire        ras,
    input  wire        cas,
    input  wire        we,
    input  wire        por_done,  // TB-controlled: power-on settle elapsed
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm,
    input  wire        fault_halt   // TB-injected fault: chip ignores all commands
);

    localparam T_RCD  = 3;
    localparam T_RP   = 3;
    localparam T_RAS  = 7;
    localparam T_WR   = 3;
    localparam T_RC   = 9;
    localparam T_RFC  = 12;

    // ---- propagation delays (from the reference SDC windows) ----
    // set_output_delay (commands to chip): max 2.0 / min -1.0 -> use 1.5
    // set_input_delay  (DQ from chip):     max 5.9 / min 0.9  -> use 1.5
    localparam real TD_CMD = 1.5;   // ns, command pins -> model
    localparam real TD_DQ  = 1.5;   // ns, model DQ -> controller (in TB)

    reg  [2:0]  c_cmd;
    reg  [12:0] c_a;
    reg  [1:0]  c_ba;
    reg        c_cas;
    reg        c_we;
    reg        c_ras;
    reg  [15:0] c_dq;
    reg        c_cke;
    reg  [1:0]  c_dqm;
    always #(TD_CMD) c_cmd = {ras, cas, we};
    always #(TD_CMD) c_a   = a;
    always #(TD_CMD) c_ba  = ba;
    always #(TD_CMD) c_cas = cas;
    always #(TD_CMD) c_we  = we;
    always #(TD_CMD) c_ras = ras;
    always #(TD_CMD) c_dq  = dq;
    always #(TD_CMD) c_cke = cke;
    always #(TD_CMD) c_dqm = dqm;
    localparam CAS    = 3;

    // ---- storage: 4 banks x 8192 rows x 1024 cols x 16-bit = 64 MiB ----
    reg [15:0] mem [0:(1<<(2+13+10))-1];
    function [24:0] idx;
        input [1:0]  b;
        input [12:0] r;
        input [9:0]  c;
        begin
            idx = {b, r, c[9:0]};
        end
    endfunction

    // ---- per-bank state ----
    reg [3:0]             bank_active;
    reg [12:0]            bank_row [0:3];
    reg [15:0]            act_cnt  [0:3];  // cycles since ACT   (tRCD/tRAS/tRC)
    reg [15:0]            pre_cnt  [0:3];  // cycles since PRECHG (tRP)
    reg [15:0]            wr_cnt   [0:3];  // cycles since last write data (tWR)
    integer b;

    // ---- refresh ----
    reg  [4:0] ref_cnt;   // >0: auto-refresh in progress

    // ---- pending read pipeline (2 deep: the controller issues two
    //      back-to-back READ commands per 32-bit word - BL1, CAS=3;
    //      absolute fire times keep the order exact with no double-
    //      assignment races between the shift and the countdown) ----
    reg [31:0] tick;
    reg        rd_pend  [0:1];
    reg [31:0] rd_fire  [0:1];
    reg [1:0]  rd_bank  [0:1];
    reg [12:0] rd_row   [0:1];
    reg [9:0]  rd_col   [0:1];

    always @(posedge clk) tick <= tick + 1'b1;

    // ---- DQ driver (output delayed by TD_DQ, like the input_delay window) ----
    reg        dq_oe;
    reg [15:0] dq_out;
    reg [16:0] dq_drv;
    always #(TD_DQ) dq_drv = {dq_oe, dq_out};
    assign dq = dq_drv[16] ? dq_drv[15:0] : 16'bzzzzzzzzzzzzzzzz;

    wire [2:0] cmd = c_cmd;
    localparam CMD_ACT     = 3'b011;
    localparam CMD_READ    = 3'b101;
    localparam CMD_WRITE   = 3'b100;
    localparam CMD_PRECHG  = 3'b010;
    localparam CMD_AUTOREF = 3'b001;
    localparam CMD_NOP     = 3'b111;
    localparam CMD_LMR     = 3'b000;

    task viol(input string where, input string what);
    begin
        $fatal(1, "DRAM MODEL: %s %s (ba=%0d ras=%b cas=%b we=%b a=%0d cke=%b)",
               where, what, ba, ras, cas, we, a, cke);
    end
    endtask

    always @(posedge clk) begin
        // ---- timing counters (first: command-phase resets below win) ----
        for (b = 0; b < 4; b = b + 1) begin
            if (act_cnt[b]  < 16'd65535) act_cnt[b]  <= act_cnt[b]  + 16'd1;
            if (pre_cnt[b]  < 16'd65535) pre_cnt[b]  <= pre_cnt[b]  + 16'd1;
            if (wr_cnt[b]   < 16'd65535) wr_cnt[b]   <= wr_cnt[b]   + 16'd1;
        end
        if (ref_cnt != 0)
            ref_cnt <= ref_cnt - 1'b1;

        // ---- command phase ----
        if (fault_halt) begin
            ; // injected fault: chip ignores all commands (bus stays quiet)
        end else if (c_cke && !ref_cnt) begin
            if (!por_done && cmd != CMD_NOP && cmd != CMD_LMR)
                viol("power-on", "command before power-on settle");
            case (cmd)
            CMD_ACT: begin
                if (bank_active[c_ba])           viol("ACT", "bank already active");
                if (act_cnt[c_ba] < T_RC)        viol("ACT", "tRC violation");
                if (pre_cnt[c_ba] < T_RP)        viol("ACT", "tRP violation");
                bank_active[c_ba] <= 1'b1;
                bank_row[c_ba]    <= c_a[12:0];
                act_cnt[c_ba]     <= 16'd0;
            end

            CMD_READ: begin
                if (!bank_active[c_ba])          viol("READ", "bank not active");
                if (act_cnt[c_ba] < T_RCD)      viol("READ", "tRCD violation");
                if (rd_pend[0] && rd_pend[1]) viol("READ", "third read pending");
                if (rd_pend[0]) begin          // make room: shift slot0 -> slot1
                    rd_pend[1]  <= rd_pend[0];
                    rd_fire[1]  <= rd_fire[0]; // absolute: order preserved
                    rd_bank[1]  <= rd_bank[0];
                    rd_row[1]   <= rd_row[0];
                    rd_col[1]   <= rd_col[0];
                end
                rd_pend[0]  <= 1'b1;
                rd_fire[0]  <= tick + CAS;    // data phase CAS cycles after command
                rd_bank[0]  <= c_ba;
                rd_row[0]   <= bank_row[c_ba];   // row was latched at ACT
                rd_col[0]   <= c_a[9:0];
            end

            CMD_WRITE: begin
                if (!bank_active[c_ba])          viol("WRITE", "bank not active");
                if (act_cnt[c_ba] < T_RCD)      viol("WRITE", "tRCD violation");
                if (c_dqm == 2'b00) begin
                    mem[idx(c_ba, bank_row[c_ba], c_a[9:0])] <= c_dq;
                    wr_cnt[c_ba] <= 16'd0;
                end
            end

            CMD_PRECHG: begin
                if (c_a[10]) begin
                    // all banks
                    for (b = 0; b < 4; b = b + 1) begin
                        if (bank_active[b]) begin
                            if (act_cnt[b] < T_RAS)  viol("PRECHG(all)", "tRAS violation");
                            if (wr_cnt[b]  < T_WR)   viol("PRECHG(all)", "tWR violation");
                            bank_active[b] <= 1'b0;
                            pre_cnt[b]    <= 16'd0;
                        end
                    end
                end else begin
                    if (bank_active[c_ba]) begin
                        if (act_cnt[c_ba] < T_RAS)  viol("PRECHG", "tRAS violation");
                        if (wr_cnt[c_ba]  < T_WR)   viol("PRECHG", "tWR violation");
                        bank_active[c_ba] <= 1'b0;
                        pre_cnt[c_ba]    <= 16'd0;
                    end
                end
            end

            CMD_AUTOREF: begin
                for (b = 0; b < 4; b = b + 1)
                    if (bank_active[b])          viol("AUTOREF", "bank active");
                if (rd_pend[0] || rd_pend[1])   viol("AUTOREF", "read pending");
                ref_cnt <= T_RFC[4:0];
            end

            default: ; // NOP / LMR: no state change
            endcase
        end else if (c_cke && ref_cnt) begin
            // refresh in progress: bus must be idle, EXCEPT a re-issued
            // AUTOREF, which real SDRAMs accept (refresh window re-arms)
            if (cmd == CMD_AUTOREF) begin
                ref_cnt <= T_RFC[4:0];
            end else if (cmd != CMD_NOP && cmd != CMD_LMR)
                viol("REFRESH", "command during auto-refresh");
        end

        // ---- read data phases (absolute fire times, 2-deep pipeline) ----
        begin : data_phase
            integer d;
            integer ready;
            dq_oe = 1'b0;
            ready = 0;
            if (!fault_halt) begin
            for (d = 0; d < 2; d = d + 1) begin
                if (rd_pend[d] && tick == rd_fire[d]) begin
                    if (ready) viol("DATA", "two read data phases overlap");
                    ready  = 1'b1;
                    dq_oe  = 1'b1;
                    dq_out = mem[idx(rd_bank[d], rd_row[d], rd_col[d])];
                    rd_pend[d] <= 1'b0;
                end
            end
            end
        end
    end

endmodule
