// tb_pmp_probe.sv - minimal standalone probe: can the REAL
// io_bridge_peripheral (port-split for two-state) complete ONE read
// transaction (SS + 4 address bytes -> 16-edge data TX) in this sim build?
// Isolation test for the hdv_ab hang.
`timescale 1ns/1ps
module tb_pmp_probe;

    reg clk_74a = 1'b0;
    initial begin
        forever #6.733 clk_74a = ~clk_74a;
    end
    reg reset_n_r = 1'b0;
    always @(posedge clk_74a) begin
        if (reset_n_r == 1'b0 && clk_74a) reset_n_r <= 1'b1;
    end
    wire reset_n = reset_n_r;

    wire        pmp_rd, pmp_wr, pmp_addr_valid;
    wire [31:0] pmp_addr, pmp_wr_data, pmp_rd_data;
    reg         h_ss = 1'b0;
    reg         h_sclk = 1'b0, h_mosi = 1'b0, h_miso = 1'b0;
    wire        c_sclk, c_mosi, c_miso;

    // fake core: echo the address into the data word. Note the PMP zeroes
    // addr[1:0] (pmp_addr[7:0] = {byte[7:2], 2'b00}), so the address is
    // always 4-byte aligned: 0xA8 in, 0x112233A8 back.
    assign pmp_rd_data = pmp_addr;

    io_bridge_peripheral_phy u_pmp (
        .clk            ( clk_74a ),
        .reset_n        ( reset_n ),
        .endian_little  ( 1'b0 ),
        .pmp_addr       ( pmp_addr ),
        .pmp_addr_valid ( pmp_addr_valid ),
        .pmp_rd         ( pmp_rd ),
        .pmp_rd_data    ( pmp_rd_data ),
        .pmp_wr         ( pmp_wr ),
        .pmp_wr_data    ( pmp_wr_data ),
        .phy_spiclk_in  ( h_sclk ),
        .phy_spimosi_in ( h_mosi ),
        .phy_spimiso_in ( h_miso ),
        .phy_spiss      ( h_ss ),
        .phy_spiclk_out ( c_sclk ),
        .phy_spimosi_out( c_mosi ),
        .phy_spimiso_out( c_miso )
    );

    integer cclk_pos = 0, cclk_neg = 0;
    always @(posedge c_sclk) cclk_pos = cclk_pos + 1;
    always @(negedge c_sclk) begin
        cclk_neg = cclk_neg + 1;
        $display("CCLK fall t=%0t (pos=%0d neg=%0d)", $time, cclk_pos, cclk_neg);
    end

    task tx_byte(input [7:0] by);
        integer k;
        begin
            repeat (2) @(negedge clk_74a);
            for (k = 3; k >= 0; k = k - 1) begin
                h_mosi = by[2*k+1];
                h_miso = by[2*k];
                @(negedge clk_74a);
                h_sclk = 1'b1;
                @(negedge clk_74a);
                h_sclk = 1'b0;
                @(negedge clk_74a);
            end
        end
    endtask

    reg [31:0] cap = 32'd0;
    integer k;

    initial begin
        $display("PROBE start");
        @(posedge clk_74a);
        if (!reset_n) wait (reset_n);
        repeat (20) @(posedge clk_74a);
        // SS
        h_ss = 1'b1;
        repeat (2) @(negedge clk_74a);
        h_ss = 1'b0;
        repeat (10) @(negedge clk_74a);
        h_sclk = 1'b0;
        tx_byte(8'h11);
        tx_byte(8'h22);
        tx_byte(8'h33);
        tx_byte(8'hA8);   // {addr[7:2]=101010, bit1=0, bit0(RW)=0}
        $display("PROBE bytes sent t=%0t pmp_addr=0x%08X valid=%b rd=%b", $time, pmp_addr, pmp_addr_valid, pmp_rd);
        @(posedge c_sclk);
        $display("PROBE first cclk rise t=%0t", $time);
        @(negedge c_sclk);
        $display("PROBE first cclk fall t=%0t", $time);
        for (k = 0; k < 16; k = k + 1) begin
            @(posedge c_sclk);
            cap[31 - 2*k] = c_mosi;
            cap[30 - 2*k] = c_miso;
        end
        $display("PROBE captured 0x%08X (want 0x112233A8)", cap);
        if (cap === 32'h112233A8)
            $display("PROBE PASS");
        else
            $display("PROBE FAIL (data mismatch)");
        $finish;
    end

    initial begin
        #500_000;
        $display("PROBE FAIL: watchdog (cclk pos=%0d neg=%0d pmp_addr=0x%08X valid=%b rd=%b wr=%b)",
                 cclk_pos, cclk_neg, pmp_addr, pmp_addr_valid, pmp_rd, pmp_wr);
        $finish;
    end

endmodule
