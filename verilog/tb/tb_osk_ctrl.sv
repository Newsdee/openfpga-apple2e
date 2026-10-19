// Minimal controller-only test: does enabled_toggle fire on joystick[6]?
`default_nettype wire
module tb_osk_ctrl;
  reg clk = 0;
  always #35 clk = ~clk;   // ~14.286 MHz
  reg reset = 1;
  reg [10:0] joy = 0;
  wire [10:0] ps2o;
  wire en_toggle, active, cmd_rst;
  wire [2:0] row; wire [3:0] col;
  wire sh_l, ct_l, cp_l, sh_a, ct_a;
  wire op_a, cl_a, tr_c, ov_t;
  wire v_ev, v_pr; wire [6:0] v_cd;

  virtual_keyboard_controller dut (
    .clk(clk), .reset(reset),
    .ps2_key(11'h0),
    .joystick(joy),
    .joystick_analog(16'h0),
    .enabled(1'b0),
    .filtered_ps2_key(ps2o),
    .active(active), .commands_page(), .selected_row(row), .selected_col(col),
    .shift_latched(sh_l), .control_latched(ct_l), .caps_latched(cp_l),
    .shift_active(sh_a), .control_active(ct_a),
    .enabled_toggle(en_toggle),
    .open_apple(op_a), .closed_apple(cl_a), .transparency_cycle(tr_c),
    .overlay_top(ov_t),
    .virtual_event(v_ev), .virtual_pressed(v_pr), .virtual_code(v_cd),
    .command_reset(cmd_rst)
  );

  integer tog = 0;
  always @(posedge clk) if (en_toggle) tog = tog + 1;

  initial begin
    #10_000;
    reset = 0;
    #100_000;
    // press visibility (bit 6)
    joy = 11'h0;
    #1_000;
    joy[6] = 1;
    $display("t=%0t joy=%b", $time, joy);
    #30_000;
    joy[6] = 0;
    #50_000;
    $display("RESULT tog=%0d (expect 1) active=%b row=%d col=%d", tog, active, row, col);
    if (tog != 1) $display("FAIL"); else $display("PASS");
    $finish;
  end
endmodule
