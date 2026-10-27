//-------------------------------------------------------------------------------
// HDD equivalence harness - Verilator CANDIDATE (the Verilog port)
//
// Instantiates src/fpga/core/hdd.v (the port under test). Drives the SAME
// stimulus schedule as hdd_vhdl_tb.vhd (keep in lockstep - see the schedule
// table in that file) and writes a per-cycle CSV trace for
// run_equivalence.ps1 to compare field-by-field against the GHDL golden trace.
//
// Metavalue handling: the VHDL golden starts sec_addr/ram_do as 'U' (the donor
// has no init and reset does not touch them); the Verilog port starts at 0.
// The two are behaviour-identical (a read of U/0 can never compare as 1 /
// produce a different select_d/increment path before the first C0F0 execute
// or cmd=02 write defines sec_addr), so the runner ignores fields where the
// VHDL side reports a metavalue (U / -1).
//
// Run with CWD = verilog/hdd_equivalence/ (the DUT's $readmemh path is
// "rtl/roms/hddrom.hex", copied here; the runner verifies the copy).
//-------------------------------------------------------------------------------
`timescale 1ns/1ns
module hdd_verilog_tb;

    reg clk = 1'b0;
    integer c = 0;

    // stimulus
    reg        reset = 1'b0;
    reg        io_select = 1'b0;
    reg        device_select = 1'b0;
    reg [15:0] a = 16'h0000;
    reg        rd = 1'b0;
    reg [7:0]  d_in = 8'h00;
    reg [7:0]  d_out;
    wire [15:0] sector;
    wire       hdd_read, hdd_write;
    reg        hdd_mounted = 1'b0;
    reg        hdd_protect = 1'b0;
    reg [8:0]  ram_addr = 9'd0;
    reg [7:0]  ram_di = 8'h00;
    wire [7:0] ram_do;
    reg        ram_we = 1'b0;

    hdd dut (
        .CLK_14M(clk),
        .IO_SELECT(io_select),
        .DEVICE_SELECT(device_select),
        .RESET(reset),
        .A(a),
        .RD(rd),
        .D_IN(d_in),
        .D_OUT(d_out),
        .sector(sector),
        .hdd_read(hdd_read),
        .hdd_write(hdd_write),
        .hdd_mounted(hdd_mounted),
        .hdd_protect(hdd_protect),
        .ram_addr(ram_addr),
        .ram_di(ram_di),
        .ram_do(ram_do),
        .ram_we(ram_we)
    );

    // collision monitor: CPU C0F8 write + ram port on the same address in the
    // same cycle is unreachable in-system and non-deterministic in both
    // languages (mirrors the VHDL TB monitor).
    always @* begin
        if (device_select && !rd && (a[3:0] == 4'h8) &&
            ram_we && (dut.sec_addr == ram_addr))
            $fatal(1, "TB: dual-port collision (CPU C0F8 write + ram_we same addr)");
    end

    integer tf;
    integer i, w, s;

    // Stimulus schedule: set stim(c) (identical to hdd_vhdl_tb.vd - keep in
    // lockstep with that file's schedule table).
    task automatic set_stim(input integer c);
        begin
            reset = 1'b0;
            io_select = 1'b0;
            device_select = 1'b0;
            rd = 1'b0;
            a = 16'h0000;
            d_in = 8'h00;
            ram_addr = 9'd0;
            ram_di = 8'h00;
            ram_we = 1'b0;
            hdd_mounted = 1'b0;
            hdd_protect = 1'b0;

            if (c < 4) begin
                reset = 1'b1;
            end else if (c >= 10 && c <= 265) begin
                io_select = 1'b1;
                rd = 1'b1;
                a = 16'hC600 + (c - 10);
            end else if (c >= 266 && c <= 267) begin
                // drain: the ROM readout is two registered stages (hdd_rom
                // dout, then D_OUT); hold IO_SELECT+last address so
                // ROM[255] reaches D_OUT before the FF default kills it
                io_select = 1'b1;
                rd = 1'b1;
                a = 16'hC6FF;
            end else if (c >= 300 && c <= 399) begin
                i = c - 300;
                device_select = 1'b1;
                if (i % 2 == 0) begin
                    w = i / 2;
                    rd = 1'b0;
                    a = 16'hC0F3 + (w % 5);
                    d_in = ((w * 3 + 1) % 256);
                end else begin
                    rd = 1'b1;
                    a = 16'hC0F3 + ((i / 2) % 5);
                end
            end else if (c >= 500 && c <= 699) begin
                i = c - 500;
                hdd_mounted = 1'b1;
                s = i / 2;
                if (i % 2 == 0) begin
                    device_select = 1'b1;
                    case (s % 20)
                        0:  begin rd = 1'b0; a = 16'hC0F3; d_in = 8'h70; end
                        1:  begin rd = 1'b1; a = 16'hC0F0; end
                        2:  begin hdd_mounted = 1'b0; rd = 1'b1; a = 16'hC0F0; end
                        3:  begin hdd_mounted = 1'b1; rd = 1'b0; a = 16'hC0F3; d_in = 8'h00; end
                        4:  begin rd = 1'b1; a = 16'hC0F0; end
                        5:  begin rd = 1'b0; a = 16'hC0F3; d_in = 8'h70; end
                        6:  begin rd = 1'b0; a = 16'hC0F2; d_in = 8'h01; end
                        7:  begin rd = 1'b1; a = 16'hC0F0; end
                        8:  begin hdd_mounted = 1'b0; rd = 1'b1; a = 16'hC0F0; end
                        9:  begin hdd_mounted = 1'b1; rd = 1'b0; a = 16'hC0F2; d_in = 8'h02; end
                        10: begin rd = 1'b1; a = 16'hC0F0; end
                        11: begin hdd_protect = 1'b1; rd = 1'b1; a = 16'hC0F0; end
                        12: begin hdd_protect = 1'b0; hdd_mounted = 1'b0; rd = 1'b1; a = 16'hC0F0; end
                        13: begin hdd_mounted = 1'b1; rd = 1'b0; a = 16'hC0F2; d_in = 8'h03; end
                        14: begin rd = 1'b1; a = 16'hC0F0; end
                        15: begin rd = 1'b1; a = 16'hC0F1; end
                        16: begin
                            hdd_protect = 1'b0;
                            rd = 1'b0; a = 16'hC0F2;
                            d_in = ((s * 3) % 4);
                        end
                        17: begin rd = 1'b1; a = 16'hC0F0; end
                        default: begin
                            if ((s % 7) == 3) hdd_protect = 1'b1;
                            if ((s / 20) % 2 == 0) begin
                                rd = 1'b0;
                                a = 16'hC0F3 + (s % 5);
                                d_in = ((s * 7 + 11) % 256);
                            end else begin
                                rd = 1'b1; a = 16'hC0F0;
                            end
                        end
                    endcase
                end
            end else if (c == 798) begin
                device_select = 1'b1; rd = 1'b0; a = 16'hC0F3; d_in = 8'h70;
                hdd_mounted = 1'b1; hdd_protect = 1'b0;
            end else if (c == 799) begin
                device_select = 1'b1; rd = 1'b0; a = 16'hC0F2; d_in = 8'h01;
            end else if (c == 800) begin
                device_select = 1'b1; rd = 1'b1; a = 16'hC0F0;
            end else if (c >= 802 && c <= 1825) begin
                i = c - 802;
                if (i % 2 == 0) begin
                    device_select = 1'b1; rd = 1'b0; a = 16'hC0F8;
                    d_in = (((i / 2) * 31 + 7) % 256);
                end
            end else if (c >= 1900 && c <= 2923) begin
                i = c - 1900;
                if (i % 2 == 0) begin
                    device_select = 1'b1; rd = 1'b1; a = 16'hC0F8;
                end
            end else if (c >= 3000 && c <= 4023) begin
                i = c - 3000;
                if (i % 2 == 0)
                    ram_addr = (i / 2);
            end else if (c >= 4100 && c <= 5123) begin
                i = c - 4100;
                if (i % 2 == 0) begin
                    ram_we = 1'b1;
                    ram_addr = (i / 2);
                    ram_di = (((i / 2) * 13 + 3) % 256);
                end
            end else if (c >= 5200 && c <= 6223) begin
                i = c - 5200;
                if (i % 2 == 0) begin
                    device_select = 1'b1; rd = 1'b1; a = 16'hC0F8;
                end
            end else if (c >= 6300 && c <= 6359) begin
                i = c - 6300;
                if (i < 20) begin
                    if (i % 2 == 0) begin
                        device_select = 1'b1; rd = 1'b0; a = 16'hC0F8;
                        d_in = (i / 2) + 40;
                    end
                end else if (i == 22) begin
                    device_select = 1'b1; rd = 1'b0; a = 16'hC0F2; d_in = 8'h02;
                end else if (i >= 24 && i < 44) begin
                    if (i % 2 == 0) begin
                        device_select = 1'b1; rd = 1'b1; a = 16'hC0F8;
                    end
                end
            end else if (c >= 6400 && c <= 6440) begin
                i = c - 6400;
                if (i < 8) begin
                    // hold DS HIGH across 4 consecutive C0F8 reads (latched
                    // increment flag; fires only after release)
                    device_select = 1'b1; rd = 1'b1; a = 16'hC0F8;
                end
            end
        end
    endtask

    initial begin
        forever #7 clk = ~clk;
    end

    initial begin
        tf = $fopen("build/verilog_trace.csv", "w");
        if (tf == 0) $fatal(1, "TB: cannot open build/verilog_trace.csv");
        $fwrite(tf, "CYCLE,RESET,IO_SELECT,DEVICE_SELECT,RD,A_LOW,D_IN,D_OUT,SECTOR,HDD_READ,HDD_WRITE,MOUNTED,PROTECT,RAM_ADDR,RAM_WE,RAM_DI,RAM_DO\n");

        // stim(0) at t=0 (reset high, as in the VHDL TB)
        set_stim(0);

        for (c = 0; c < 7600; c = c + 1) begin
            @(negedge clk);
            // trace row c: state after the DUT processed stim(c), settled
            // $fwrite with EXACTLY as many specifiers as arguments (a
            // count mismatch corrupts the output on this toolchain
            // build; with a match the values are correct, just
            // space-padded to the argument bit width - the runner trims).
            $fwrite(tf,
                "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                c,
                reset, io_select, device_select, rd,
                a[3:0], d_in, d_out, sector,
                hdd_read, hdd_write, hdd_mounted, hdd_protect,
                ram_addr, ram_we, ram_di,
                ram_do);

            if (c < 7599)
                set_stim(c + 1);
        end

        $fclose(tf);
        $display("hdd_verilog_tb: trace complete (rows 0..7599)");
        $finish;
    end
endmodule
