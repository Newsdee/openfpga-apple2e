//
// apple2e_osk.v - on-screen keyboard for the Pocket Apple IIe core
//
// Self-contained OSK: APF buttons -> virtual_keyboard_controller ->
// virtual_keyboard_overlay (composited over the machine's 1-bit video in
// the 14.318 MHz domain) + keyboard.v (OSK/PS2 -> Apple II K/READ_KEY
// interface). All MiSTer OSK RTL is byte-identical (machine/ folder).
//
// Button map (cont1, per the APF key bitmap, remapped 2026-10-17):
//   D-pad [3:0]  cursor (with repeat + snap, in the controller)
//   face-A       press the selected key
//   start [15]   toggle OSK on/off            (controller: visibility)
//   face-X       space press
//   face-Y       enter (commands-page confirm)
//   face-select [14]  transparency cycle
//   trig-L1 [8]  overlay position (top/bottom)
//   (no physical PS/2 on the Pocket: ps2_key = 0; OSK is the only key path)
//
// Debug: while the OSK is open, a 16-pixel button-indicator strip is
// drawn in the panel's bottom margin (panel lines 92..93): one 2-px
// block per cont1 bit, lit while that button reads pressed. This is
// the on-hardware polarity/bit-map diagnostic (see PLAN_POCKET_CORE.md
// P2b).
//
// The overlay is full-color (cream panel, colored Apple badges); the
// Pocket P2a video is monochrome, so the composited result is collapsed
// back to 1 bit on the R-channel threshold (bit 17): panel/border ->
// white, key wells/lines -> black. Identical to the pre-OSK 1-bit video
// everywhere outside the panel.
//
`default_nettype none

module apple2e_osk #(
    // RGB_IN=1: composite the OSK over a supplied 24-bit RGB background instead
    // of expanding the 1-bit `video_in` internally. This is what the NTSC color
    // path needs (plan §5 N2 step 2: "make OSK RGB input compatible with every
    // caller"). Default 0 keeps every existing instantiation - apf_stream_proto_top,
    // apple2e_core_top, tb_apf_video, tb_p2b_shots, tb_phase2_shots and the
    // simulation runners - bit-for-bit unchanged; they simply omit the port and
    // the parameter, and `rgb_in` reads as unconnected/z without being used.
    // (Wording note: do not begin a comment line with the word "verilator" -
    // the tool parses `// verilator ...` as a lint pragma and errors out with
    // BADVLTPRAGMA. This comment was rewritten for exactly that reason.)
    parameter RGB_IN = 1'b0
) (
    input  wire        clk,          // 14.318 MHz (machine domain)
    input  wire        reset,        // machine reset
    input  wire [31:0] cont1_key,    // APF pad domain (74.25 MHz) - synced internally
    // machine video (1-bit, 14.318 domain)
    input  wire        video_in,     //   native 1-bit video
    input  wire        hblank,
    input  wire        vblank,
    // externally composited background (RGB_IN=1 only). Must be pixel-aligned
    // with hblank/vblank: RGB and its own blanking travel together, so the NTSC
    // path supplies the pipeline's HBL_O/VBL_O, not the raw machine flags.
    input  wire [23:0] rgb_in,
    output wire        video_out,    //   OSK-composited 1-bit video
    output wire [23:0] video_rgb24,  //   OSK-composited 24-bit RGB (Phase 2 streaming)
    // Apple II keyboard interface (to the machine core)
    output wire [7:0]  K,
    input  wire        reads,      // machine-driven read strobe (clears the key)
    output wire        akd,
    // Apple-button state -> machine GAMEPORT[1]/[2] (cold/warm/self-test)
    output wire        open_apple,
    output wire        closed_apple,
    // OSK command (warm/cold) reset - OR into the machine reset
    output wire        command_reset
);

    // ------------------------------------------------------------------
    // APF key CDC: 3-stage sync (pad domain -> 14.318), same pattern as
    // the myc64 reference core.
    // ------------------------------------------------------------------
    reg [31:0] cont1_key_s1;
    reg [31:0] cont1_key_s2;
    reg [31:0] cont1_key_s3;
    always @(posedge clk) begin
        cont1_key_s1 <= cont1_key;
        cont1_key_s2 <= cont1_key_s1;
        cont1_key_s3 <= cont1_key_s2;
    end

    // ------------------------------------------------------------------
    // APF buttons -> controller joystick[10:0]
    //   dpad NOTE: the controller's joystick[3:0] convention is
    //   [0]=right [1]=left [2]=down [3]=up (see its requested_direction),
    //   while APF cont1 bits are [0]=up [1]=down [2]=left [3]=right -
    //   the dpad nibble is therefore bit-reversed.
    //   [4] fire (face-A)
    //   [6] visibility = start [15]       [7] transparency = select [14]
    //   [8] move (top/bottom) = trig-L1 [8]   [9] enter (trig-R1)
    //   [10] space (face-X)                [5] back (face-Y)
    // ------------------------------------------------------------------
    wire [10:0] btn_raw = {
        cont1_key_s3[6],   // [10] space          (face-X)
        cont1_key_s3[9],   // [9]  enter          (trig-R1)
        cont1_key_s3[8],   // [8]  move           (trig-L1)
        cont1_key_s3[14],  // [7]  transparency   (face-select)
        cont1_key_s3[15],  // [6]  visibility     (start) - OSK on/off
        cont1_key_s3[7],   // [5]  back arrow     (face-Y)
        cont1_key_s3[4],   // [4]  fire           (face-A)
        cont1_key_s3[0],   // [3]  up (APF bit 0)
        cont1_key_s3[1],   // [2]  down (APF bit 1)
        cont1_key_s3[2],   // [1]  left (APF bit 2)
        cont1_key_s3[3]    // [0]  right (APF bit 3)
    };

    // ------------------------------------------------------------------
    // Button input cleanup, two stages:
    //  1) DEBOUNCE - accept a transition only after the bit has been
    //     stable for ~1.4 ms (filters fast contact bounce).
    //  2) PRESS LATCH + release confirmation - the signal the OSK
    //     controller actually sees. Each button RISES on the first
    //     stable press, STAYS latched while held (any dip shorter
    //     than BTN_RELEASE_CNT is ignored), and only FALLS once the
    //     button has been stably low for ~30 ms. The controller is
    //     edge-triggered and re-arms its key on every falling edge,
    //     so an oscillating delivered signal (slow bounce, host
    //     re-delivery, glitch) would otherwise type the same key
    //     many times (the on-hardware "one press, whole rows of the
    //     same key" report). The latch makes one physical press =
    //     exactly one 0->1 and one 1->0, however the raw signal
    //     wobbles in between.
    // ------------------------------------------------------------------
    localparam [15:0] BTN_DEBOUNCE_CNT = 16'h5000;    // ~1.4 ms
    reg  [10:0] btn_stable = 11'h0;
    reg  [15:0] btn_cnt [0:10];
    localparam [20:0] BTN_RELEASE_CNT = 21'd430_000;  // ~30 ms
    reg  [10:0] btn_latched = 11'h0;
    reg  [20:0] btn_rel [0:10];
    integer bi;
    always @(posedge clk) begin
        for (bi = 0; bi < 11; bi = bi + 1) begin
            if (btn_raw[bi] !== btn_stable[bi]) begin
                if (btn_cnt[bi] == BTN_DEBOUNCE_CNT - 16'd1)
                    btn_stable[bi] <= btn_raw[bi];
                else
                    btn_cnt[bi] <= btn_cnt[bi] + 16'd1;
            end else begin
                btn_cnt[bi] <= 16'h0;
            end
        end
    end
    always @(posedge clk) begin
        for (bi = 0; bi < 11; bi = bi + 1) begin
            if (btn_stable[bi]) begin
                btn_latched[bi] <= 1'b1;
                btn_rel[bi] <= 21'd0;
            end else if (btn_latched[bi]) begin
                if (btn_rel[bi] == BTN_RELEASE_CNT - 21'd1)
                    btn_latched[bi] <= 1'b0;
                else
                    btn_rel[bi] <= btn_rel[bi] + 21'd1;
            end
        end
    end
    wire [10:0] osk_joystick = btn_latched;

    // OSK enable: toggled by the controller's enabled_toggle pulse
    // (face-B press), cleared on machine reset.
    reg osk_en;
    wire osk_enabled_toggle;
    always @(posedge clk or posedge reset) begin
        if (reset) osk_en <= 1'b0;
        else if (osk_enabled_toggle) osk_en <= ~osk_en;
    end

    // ------------------------------------------------------------------
    // controller (cursor state machine + virtual key events)
    // ------------------------------------------------------------------
    wire [10:0] kb_ps2;
    wire        kb_active;
    wire        kb_commands;
    wire [2:0]  kb_row;
    wire [3:0]  kb_col;
    wire        kb_shift, kb_ctrl, kb_caps;
    wire        kb_shift_a, kb_ctrl_a;
    wire        kb_open_apple, kb_closed_apple;
    wire        kb_v_event, kb_v_pressed;
    wire [6:0]  kb_v_code;

    virtual_keyboard_controller oskc (
        .clk(clk),
        .reset(reset),
        .ps2_key(11'h0),              // no physical PS/2 on the Pocket
        .joystick(osk_joystick),
        .joystick_analog(16'h0),
        .enabled(osk_en),
        .filtered_ps2_key(kb_ps2),
        .active(kb_active),
        .commands_page(kb_commands),
        .selected_row(kb_row),
        .selected_col(kb_col),
        .shift_latched(kb_shift),
        .control_latched(kb_ctrl),
        .caps_latched(kb_caps),
        .shift_active(kb_shift_a),
        .control_active(kb_ctrl_a),
        .enabled_toggle(osk_enabled_toggle),
        .open_apple(kb_open_apple),
        .closed_apple(kb_closed_apple),
        .transparency_cycle(kb_transp_cycle),
        .overlay_top(osk_ov_top_w),
        .virtual_event(kb_v_event),
        .virtual_pressed(kb_v_pressed),
        .virtual_code(kb_v_code),
        .command_reset(command_reset)
    );

    // ------------------------------------------------------------------
    // On-hardware diagnostic: key-press EVENT counter
    // Edge-detect kb_v_event (the controller toggles it once per press
    // and once per release) and count the press edges. Rendered in the
    // panel's bottom margin (see dbg_cnt_row below). ONE physical A-tap
    // must yield exactly 1 event:
    //   count == 1  -> button side is clean; the screen-flood comes
    //                  downstream (the machine re-reading one key)
    //   count > 5   -> the delivered button signal is oscillating;
    //                  the events are real (upstream: button/CDC)
    // ------------------------------------------------------------------
    reg  [7:0] key_press_cnt = 8'd0;
    reg        kb_v_event_d  = 1'b0;
    reg        kb_active_d   = 1'b0;
    wire       kb_v_event_edge = kb_v_event ^ kb_v_event_d;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            key_press_cnt <= 8'd0;
            kb_v_event_d  <= 1'b0;
            kb_active_d   <= 1'b0;
        end else begin
            kb_v_event_d <= kb_v_event;
            kb_active_d  <= kb_active;
            if (kb_active && !kb_active_d)
                key_press_cnt <= 8'd0;                // OSK just opened
            else if (kb_v_event_edge && kb_v_pressed)
                key_press_cnt <= key_press_cnt + 8'd1;
        end
    end
    wire key_press_many = (key_press_cnt > 8'd5);

    // ------------------------------------------------------------------
    // keyboard (OSK/PS2 -> Apple II K/READ_KEY/AKD)
    // ------------------------------------------------------------------
    wire kb_soft_reset;
    wire kb_video_toggle, kb_palette_toggle;
    keyboard kbd (
        .PS2_Key(kb_ps2),
        .virtual_active(kb_active),
        .virtual_event(kb_v_event),
        .virtual_pressed(kb_v_pressed),
        .virtual_code(kb_v_code),
        .virtual_control(kb_ctrl_a),
        .virtual_open_apple(kb_open_apple),
        .virtual_closed_apple(kb_closed_apple),
        .CLK_14M(clk),
        .reset(reset),
        .reads(reads),
        .K(K),
        .akd(akd),
        .open_apple(open_apple),
        .closed_apple(closed_apple),
        .soft_reset(kb_soft_reset),
        .video_toggle(kb_video_toggle),
        .palette_toggle(kb_palette_toggle)
    );

    // ------------------------------------------------------------------
    // video: 1-bit -> RGB -> OSK overlay -> 1-bit (R-channel threshold)
    // ------------------------------------------------------------------
    // transparency level: cycles 00 (opaque) -> 01 (25%) -> 10 (50%) ->
    // 11 (75%) on each controller transparency pulse (face-select) -
    // the same integration MiSTer does into its status[41:40]
    reg     [1:0] transp;
    wire          kb_transp_cycle;
    always @(posedge clk) begin
        if (kb_transp_cycle) transp <= transp + 1'b1;
    end

    // Background select. With RGB_IN=0 this is byte-for-byte the original
    // expression, so the monochrome fallback path is unchanged; with RGB_IN=1
    // the caller supplies the background (NTSC-decoded RGB, or the same mono
    // expansion computed one level up - see apf_stream_video_top.v).
    wire [23:0] m_rgb_mono = video_in ? 24'hFFFFFF : 24'h000000;
    wire [23:0] m_rgb = RGB_IN ? rgb_in : m_rgb_mono;
    wire [23:0] osk_rgb;
    wire        osk_font_alt, osk_font_lcase;
    wire [6:0]  osk_font_char;
    wire [2:0]  osk_font_row;
    wire [7:0]  osk_font_data;
    wire        osk_ov_top_w;

    // second font ROM instance for the OSK glyphs (the machine core has
    // its own inside video_generator.v; same ROM image, separate port)
    apple2_font_rom osk_fontrom (
        .CLK_14M(clk),
        .ROMSWITCH(1'b0),
        .alternate_character(osk_font_alt),
        .lowercase_character(osk_font_lcase),
        .character_code(osk_font_char),
        .glyph_row(osk_font_row),
        .ioctl_addr(25'b0),
        .ioctl_data(8'b0),
        .ioctl_wr(1'b0),
        .glyph_data(osk_font_data)
    );

    virtual_keyboard_overlay oskov (
        .clk(clk),
        .reset(reset),
        .active(kb_active),
        .commands_page(kb_commands),
        .selected_row(kb_row),
        .selected_col(kb_col),
        .shift_latched(kb_shift_a),
        .control_latched(kb_ctrl_a),
        .caps_latched(kb_caps),
        .open_apple(kb_open_apple),
        .closed_apple(kb_closed_apple),
        .transparency(transp),          // cycled by face-select
        .overlay_top(osk_ov_top_w),
        .pixel_clock_double(1'b1),     // full 560-px raster: each font bit
                                       // renders individually (8-column
                                       // glyphs; pcd=0 OR-compresses 2 bits
                                       // per column - "I" rendered as "C")
        .hblank(hblank),
        .vblank(vblank),
        .rgb_in(m_rgb),
        .font_alternate(osk_font_alt),
        .font_lowercase(osk_font_lcase),
        .font_character(osk_font_char),
        .font_row(osk_font_row),
        .font_data(osk_font_data),
        .rgb_out(osk_rgb)
    );

    // controller overlay_top output drives the overlay position input
    // 1-bit collapse on the R-channel threshold (see header)
    //
    // Debug button-indicator strip: while the OSK is open, 16 2-px blocks
    // (1-px gap) in the panel's empty bottom margin (panel lines 92..93)
    // light up for each cont1 bit that reads pressed - the on-hardware
    // polarity/bit-map diagnostic.
    localparam [9:0] DBG_PANEL_X = 10'd4;   // = overlay PANEL_X default
    reg  [9:0] dbg_x;
    reg  [7:0] dbg_y;
    reg        dbg_hbl_d, dbg_vbl_d;
    always @(posedge clk) begin
        dbg_hbl_d <= hblank;
        dbg_vbl_d <= vblank;
        if (hblank) dbg_x <= 10'd0;        // line start
        else dbg_x <= dbg_x + 1'b1;
        if (!hblank && dbg_hbl_d && !vblank) dbg_y <= dbg_y + 1'b1;
        if (dbg_vbl_d && !vblank) dbg_y <= 8'd0;   // VBL->active: line 0
    end
    wire [7:0] dbg_panel_y = osk_ov_top_w ? 8'd0 : 8'd94;
    wire       dbg_strip   = kb_active
                           && ((dbg_y == dbg_panel_y + 8'd92) ||
                               (dbg_y == dbg_panel_y + 8'd93))
                           && (dbg_x >= DBG_PANEL_X)
                           && (dbg_x <  DBG_PANEL_X + 10'd48);
    // 3-px grouping: btn = (x - PANEL_X) / 3  (0..15)
    wire [3:0] dbg_btn = (dbg_x - DBG_PANEL_X) / 3'd3;
    wire       dbg_lit = dbg_strip && cont1_key_s3[dbg_btn];

    // Key-press count row (panel lines 94..95, just below the button
    // strip): blocks 0..7 = key_press_cnt[7:0] in binary (block 0 =
    // bit 0, leftmost); blocks 8..15 = the "MANY" bar (all lit when
    // the count exceeds 5). Tap A once -> expect exactly ONE block lit
    // (block 0).
    wire [3:0] dbg_cnt_blk = (dbg_x - DBG_PANEL_X) / 3'd3;   // 0..15
    wire       dbg_cnt_row = kb_active
                           && ((dbg_y == dbg_panel_y + 8'd94) ||
                               (dbg_y == dbg_panel_y + 8'd95))
                           && (dbg_x >= DBG_PANEL_X)
                           && (dbg_x <  DBG_PANEL_X + 10'd48);
    wire       dbg_cnt_lit = dbg_cnt_row
                           && ((dbg_cnt_blk < 4'd8) ? key_press_cnt[dbg_cnt_blk[2:0]]
                                                    : key_press_many);

    assign video_out = osk_rgb[17] | dbg_lit | dbg_cnt_lit;
    assign video_rgb24 = osk_rgb;

endmodule
