// Inference matrix: which single change to the known-good PLAIN shape
// (ram_repro_plain: 3 regs / 524,288 bits, infers fine) breaks Quartus
// 17.0.2 M10K inference? One project, ten independent RAMs; the per-
// instance 276007 warnings in the map log name the culprits.
//
//  u_a  exact plain (baseline)
//  u_b  plain + separate counter block (counter output used at top)
//  u_c  plain + muxed WRITE ADDRESS only
//  u_d  plain + muxed WRITE DATA only
//  u_e  plain + OR'd WRITE ENABLE only
//  u_f  plain + all three muxed + separate counter (the full v4 shape)
//
// 2026-11-14 extension (savestate manager second-read problem -
// docs/EXPERT_BRIEF_RAM_BANK_INFERENCE_2026-11-14.md): does a SECOND
// read consumer infer on 17.0.2, and in which shapes?
//  u_g  plain + 2nd read SAME address expression, PRIVATE register
//  u_h  plain + 2nd read DISTINCT address (TDP template)
//  u_i  plain x2 SMALL arrays + 2nd read SAME address through a bank
//       mux into ONE shared register (the exact V2 mgr shape, scaled down)
//  u_j  the exact shape the design needs: 2 x 64KiB, per-bank write-first
//       W/R1 (shared address expr) + R2 at OWN address, bank mux on R2
//       data only, separate always block (the zero-megafunction fix)
`timescale 1ns/1ps

module m_plain (
    input  wire        clk,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_plain_ctr (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata,
    output reg        cdone
);
    reg [7:0] ram [0:65535];
    reg [15:0] c;
    always @(posedge clk) begin
        if (sel) begin
            c     <= c + 16'd1;
            cdone <= (c == 16'hFFFF);
        end else begin
            c     <= 16'd0;
            cdone <= 1'b0;
        end
    end
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_mux_addr (
    input  wire        clk,
    input  wire        sel,
    input  wire [15:0] c,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    wire [15:0] wr_addr = sel ? c : waddr;
    always @(posedge clk) begin
        if (we) begin
            ram[wr_addr] <= wdata;
            rdata        <= wdata;
        end else
            rdata        <= ram[waddr];
    end
endmodule

module m_mux_data (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    wire [7:0] wr_data = sel ? 8'd0 : wdata;
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wr_data;
            rdata      <= wr_data;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_mux_en (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata
);
    reg [7:0] ram [0:65535];
    wire wr_en = we | sel;
    always @(posedge clk) begin
        if (wr_en) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
endmodule

module m_full_v4 (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata,
    output reg        cdone
);
    reg [7:0] ram [0:65535];
    reg [15:0] c;
    always @(posedge clk) begin
        if (sel) begin
            c     <= c + 16'd1;
            cdone <= (c == 16'hFFFF);
        end else begin
            c     <= 16'd0;
            cdone <= 1'b0;
        end
    end
    wire [15:0] wr_addr = sel ? c : waddr;
    wire [7:0]  wr_data = sel ? 8'd0 : wdata;
    wire        wr_en   = sel | we;
    always @(posedge clk) begin
        if (wr_en) begin
            ram[wr_addr] <= wr_data;
            rdata        <= wr_data;
        end else
            rdata        <= ram[waddr];
    end
endmodule

module m_rd2_same (
    input  wire        clk,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata,
    input  wire        rd2,
    output reg [7:0] q2
);
    reg [7:0] ram [0:65535];
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
    // 2nd read: SAME address expression as the machine read, private reg
    always @(posedge clk)
        if (rd2) q2 <= ram[waddr];
endmodule

module m_rd2_diff (
    input  wire        clk,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata,
    input  wire        rd2,
    input  wire [15:0] raddr2,
    output reg [7:0] q2
);
    reg [7:0] ram [0:65535];
    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
            rdata      <= wdata;
        end else
            rdata      <= ram[waddr];
    end
    // 2nd read: DISTINCT address (the TDP template)
    always @(posedge clk)
        if (rd2) q2 <= ram[raddr2];
endmodule

module m_rd2_bankmux (
    input  wire        clk,
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [7:0] wdata,
    output reg [7:0] rdata_main,
    output reg [7:0] rdata_aux,
    input  wire        rd2,
    input  wire        bank2,
    output reg [7:0] q2
);
    // the exact V2 mgr shape scaled down: two small arrays, each with its
    // own write-first read, plus a 2nd read of BOTH at the SAME address
    // expression through a bank mux into ONE shared register
    reg [7:0] ram_m [0:255];
    reg [7:0] ram_a [0:255];
    always @(posedge clk) begin
        if (we & ~bank2) begin
            ram_m[waddr] <= wdata;
            rdata_main  <= wdata;
        end else rdata_main  <= ram_m[waddr];
        if (we &  bank2) begin
            ram_a[waddr] <= wdata;
            rdata_aux   <= wdata;
        end else rdata_aux   <= ram_a[waddr];
    end
    always @(posedge clk)
        if (rd2) q2 <= bank2 ? ram_a[waddr] : ram_m[waddr];
endmodule

module m_tdp_full (
    input  wire        clk,
    input  wire        we,
    input  wire        aux,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [15:0] r1,
    input  wire        rd2,
    input  wire        bank2,
    input  wire [15:0] raddr2,
    output reg [7:0]  r2
);
    // the exact shape apple2e_ram_bank needs: per-bank write-first W/R1
    // (write and read share ONE address expression) + R2 at its OWN
    // address in a separate always block, bank mux on R2 data only
    reg [7:0] ram_main [0:65535];
    reg [7:0] ram_aux  [0:65535];
    always @(posedge clk) begin
        if (we & ~aux) begin
            ram_main[waddr] <= wdata;
            r1[7:0]        <= wdata;
        end else r1[7:0]  <= ram_main[waddr];
        if (we & aux) begin
            ram_aux[waddr] <= wdata;
            r1[15:8]       <= wdata;
        end else r1[15:8] <= ram_aux[waddr];
    end
    always @(posedge clk)
        if (rd2) r2 <= bank2 ? ram_aux[raddr2] : ram_main[raddr2];
endmodule

module m_tdp_full_mux (
    input  wire        clk,
    input  wire        we,
    input  wire        aux,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    output reg [15:0] r1,
    input  wire        rd2,
    input  wire        bank2,
    input  wire [15:0] raddr2,
    output wire [7:0] r2          // fabric (combinational) bank mux, T+1 valid
);
    // u_k: u_h shape x2 (per-bank PRIVATE 2nd-read registers at own
    // address) + bank mux OUTSIDE the templates (on the register outputs)
    reg [7:0] ram_main [0:65535];
    reg [7:0] ram_aux  [0:65535];
    reg [7:0] q2_main, q2_aux;
    always @(posedge clk) begin
        if (we & ~aux) begin
            ram_main[waddr] <= wdata;
            r1[7:0]        <= wdata;
        end else r1[7:0]  <= ram_main[waddr];
        if (we & aux) begin
            ram_aux[waddr] <= wdata;
            r1[15:8]       <= wdata;
        end else r1[15:8] <= ram_aux[waddr];
    end
    always @(posedge clk)
        if (rd2) begin
            q2_main <= ram_main[raddr2];
            q2_aux  <= ram_aux[raddr2];
        end
    assign r2 = bank2 ? q2_aux : q2_main;
endmodule

module ram_repro_matrix (
    input  wire        clk,
    input  wire        sel,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0] wdata,
    input  wire        rd2,
    input  wire        bank2,
    input  wire [15:0] raddr2,
    output wire [7:0] r_a, output wire [7:0] r_b,
    output wire [7:0] r_c, output wire [7:0] r_d,
    output wire [7:0] r_e, output wire [7:0] r_f,
    output wire [7:0] r_g, output wire [7:0] q_g,
    output wire [7:0] r_h, output wire [7:0] q_h,
    output wire [7:0] r_i_m, output wire [7:0] r_i_a, output wire [7:0] q_i,
    output wire [7:0] r_j,
    output wire [15:0] r1_j,
    output wire        cdone_b, output wire cdone_f
);
    // counter-value feed for u_c / u_f (register so it survives)
    reg [15:0] c_ext;
    always @(posedge clk) begin
        if (sel) c_ext <= c_ext + 16'd1; else c_ext <= 16'd0;
    end
    m_plain     u_a (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_a));
    // u_c / u_f are the KNOWN FAILURES (recorded 2026-10-24): their
    // register explosion aborts A&S (276003) before the new u_g..u_j
    // shapes get reported. Instantiations disabled; modules retained.
    // m_plain_ctr u_b (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata),
    //                .rdata(r_b), .cdone(cdone_b));
    // m_mux_addr  u_c (.clk(clk), .sel(sel), .c(c_ext), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_c));
    // m_mux_data  u_d (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_d));
    // m_mux_en    u_e (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_e));
    // m_full_v4   u_f (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata),
    //                 .rdata(r_f), .cdone(cdone_f));
    //
    // PASS controls re-enabled for the 2026-11-14 u_g..u_j run (they infer
    // fine, no explosion) so the matrix stays a fair comparator:
    m_plain_ctr u_b (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata),
                     .rdata(r_b), .cdone(cdone_b));
    m_mux_data  u_d (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_d));
    m_mux_en    u_e (.clk(clk), .sel(sel), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_e));
    m_rd2_same  u_g (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_g),
                     .rd2(rd2), .q2(q_g));
    m_rd2_diff  u_h (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .rdata(r_h),
                     .rd2(rd2), .raddr2(raddr2), .q2(q_h));
    // u_i / u_j: VERDICT RECORDED 2026-11-14 (uninferred 276007 x2 each -
    // the shared-destination bank-mux shape is the poison). Instantiations
    // disabled so their register explosion doesn't abort A&S.
    // m_rd2_bankmux u_i (.clk(clk), .we(we), .waddr(waddr[7:0]), .wdata(wdata),
    //                   .rdata_main(r_i_m), .rdata_aux(r_i_a),
    //                   .rd2(rd2), .bank2(bank2), .q2(q_i));
    // m_tdp_full    u_j (.clk(clk), .we(we), .aux(bank2), .waddr(waddr), .wdata(wdata),
    //                    .r1(r1_j),
    //                    .rd2(rd2), .bank2(bank2), .raddr2(raddr2), .r2(r_j));
    m_tdp_full_mux u_k (.clk(clk), .we(we), .aux(bank2), .waddr(waddr), .wdata(wdata),
                        .r1(r1_j),
                        .rd2(rd2), .bank2(bank2), .raddr2(raddr2), .r2(r_j));
endmodule
