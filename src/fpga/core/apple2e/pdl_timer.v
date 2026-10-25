//
// pdl_timer.v - Apple II paddle $C07x one-shot interval timer (J2)
//
// Direct port of the "P1" block from the MiSTer Apple II core
// (rtl/apple2_top.v). On each rising edge of the 2 MHz tick (the
// machine core's CLK_2M) the X and Y one-shot counters decrement and
// the PDL0/PDL1 outputs are driven from them; a $C07x read strobe
// (the machine core's PDL_STROBE output, one machine cycle wide)
// reloads the counters from the joystick axis values:
//
//     cx/cy = 2800 + 22 * (signed axis)     axis 0..255, 128 = centre
//     clamped to 0 .. 5650 ticks
//
// so the time PDL0/PDL1 stay high after a strobe is proportional to
// the paddle position, exactly like a hardware paddle port. The
// GAMEPORT merge (joyx -> PDL0, joyy -> PDL1, PDL2/PDL3 tied 0) is
// done at the apple2 core instance in the top.
//
// The statement body is VERBATIM from the donor block - only the
// clock/tick/strobe names changed to module ports (clk/tick/
// pdl_strobe) and joyx/joyy became module outputs.
//
`timescale 1ns/10ps
module pdl_timer (
    input  wire        clk,         // machine clock (donor's CLK_14M)
    input  wire        tick,        // 2 MHz tick (donor's CLK_2M)
    input  wire        pdl_strobe,  // $C07x read strobe (donor's pdl_strobe)
    input  wire [15:0] joy_an,      // {x, y} axis 0..255 (128 = centre)
    output reg         joyx,        // PDL0
    output reg         joyy         // PDL1
);
    reg signed [31:0] cx = 0, cy = 0;
    reg               CLK_2M_D = 0;

    always @(posedge clk) begin : P1
        CLK_2M_D <= tick;
        if (CLK_2M_D == 1'b0 && tick == 1'b1) begin
            if (cx > 0) begin
                cx = cx - 1;
                joyx <= 1'b1;
            end
            else begin
                joyx <= 1'b0;
            end
            if (cy > 0) begin
                cy = cy - 1;
                joyy <= 1'b1;
            end
            else begin
                joyy <= 1'b0;
            end
            if (pdl_strobe == 1'b1) begin
                cx = 2800 + (22 * ($signed(joy_an[15:8])));
                cy = 2800 + (22 * ($signed(joy_an[7:0])));
                // max 5650
                if (cx < 0) begin
                    cx = 0;
                end
                else if (cx >= 5590) begin
                    cx = 5650;
                end
                if (cy < 0) begin
                    cy = 0;
                end
                else if (cy >= 5590) begin
                    cy = 5650;
                end
            end
        end
    end
endmodule
