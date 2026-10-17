//-----------------------------------------------------------------------------
// apf_video.v — Apple II native video -> APF 400x512 @ 12.288 MHz adapter
//
// P2a: the machine core (apple2, 14.318 MHz domain) generates native 1-bit
// video: VIDEO (1=white) + HBL/VBL blanking, 65 H-slots/line (910 masters,
// HBL low = 560 active masters / HBL high = 351 masters at line start),
// 262-line NTSC frame (70 VBL: 6 top + 64 bottom band), 192 visible lines
// (24 text rows x 8). This module converts
// that into the APF video bus format (the same signals apf_top feeds to the
// 12-bit DDR pad): a 400x512 grid at 12.288 MHz (hbp=10/vbp=10, 320x240
// active — identical timing to the proven P1 test pattern), monochrome
// white-on-black.
//
// Architecture (two clock domains, ping-pong line RAM):
//  Capture (clk_14m):
//    - line start = HBL falling; during HBL low, sample VIDEO once per
//      master cycle into the line buffer (the active run is 350 cycles);
//      line end = HBL rising -> store the line's sample count (cap_len).
//      Only VBL-low (visible) lines are stored, indexed 0..191 per frame.
//    - frame start = VBL rising -> flip the write buffer, clear the line
//      index.
//  Display (clk_12288):
//    - 400x512 grid at 12.288 MHz (hbp=10/vbp=10, 320x240 active),
//      monochrome white-on-black. The frame start is LOCKED to the
//      machine's write-buffer change (wbuf, 3-stage synced + 1-cycle
//      delayed): the display frame rate follows the machine exactly, and
//      the display-buffer switch happens after wbuf's synchronizers have
//      settled, so the read buffer is always the last fully completed
//      frame (no ping-pong race / no tearing).
//    - active output line i (0..239) -> native visible line i - V_OFF
//      (V_OFF = 24 centers the 192-line screen in the 240-line window);
//      active output pixel x (0..319) -> native sample
//      (x * cap_len) / 320 (nearest-neighbor scale; no assumption on the
//      native pixel rate beyond "sampled once per master cycle").
//
// KB-014 honored (same rules as the template core): rgb = 0 outside DE;
// VS/HS are one-cycle pulses; HS (x=3) lands 3 cycles after VS (x=0).
//-----------------------------------------------------------------------------
module apf_video (
    // machine domain
    input  wire        clk_14m,          // 14.318 MHz machine master clock
    input  wire        reset,            // machine reset
    input  wire        video_in,         // native pixel: 1 = white
    input  wire        hbl,              // horizontal blanking (1 = blank)
    input  wire        vbl,              // vertical blanking (1 = blank)
    // display domain
    input  wire        clk_12288,        // 12.288 MHz (apple2e_pll outclk_1)
    // APF video outputs (clk_12288 domain)
    output reg   [23:0] video_rgb,
    output reg         video_de,
    output reg         video_vs,
    output reg         video_hs,
    output reg         video_skip
);

    // ------------------------------------------------------------------
    // Output grid (must match the APF scaler geometry / P1 pattern)
    // ------------------------------------------------------------------
    localparam H_TOTAL  = 400;
    localparam H_BPORCH = 10;
    localparam H_ACTIVE = 320;
    localparam V_TOTAL  = 512;
    localparam V_BPORCH = 10;
    localparam V_ACTIVE = 240;

    localparam VISIBLE_LINES = 192;      // 24 text rows x 8 (measured frame)
    localparam V_OFF         = (V_ACTIVE - VISIBLE_LINES) / 2;  // = 24
    localparam MAX_CAP       = 560;      // active run = 40 H-slots x 14 masters

    // ------------------------------------------------------------------
    // Frame store: 2 buffers x 256 line slots (192 visible used per buffer)
    // x 70 words x 8 pixels = 35,840 words (addr space 2^16 words; Quartus
    // pads the inferred depth -> 65,536 x 8 bits = 524,288 bits ~= 52 M10K).
    // Words are 8 pixels wide: a 1-bit data port on the dual-clock store is
    // NOT inferred as block RAM by Quartus 17 (276007 "asynchronous read
    // logic" -> 276003), while the word-wide 10-bit cap_ram infers fine as a
    // dual-clock RAM - so the pixel store uses the same word-wide pattern.
    // Address = {buf, line[7:0], word[6:0]} (16 bits).
    // ------------------------------------------------------------------
    localparam PIX_SAMPLES = 560;
    localparam PIX_WORDS   = (PIX_SAMPLES + 7) / 8;   // 70
    reg [7:0] pix_ram [0:2*256*PIX_WORDS-1];
    reg [9:0]   cap_ram [0:511];

    // ------------------------------------------------------------------
    // Capture side (clk_14m domain)
    // ------------------------------------------------------------------
    reg  [1:0]  wbuf;             // write buffer select (flips per frame)
    reg  [8:0]  vline;            // visible line index 0..191
    reg  [9:0]  xcap;             // samples captured in the current line
    reg  [6:0]  px_word;          // current 8-pixel word within the line
    reg  [2:0]  px_bit;           // bit within the current word
    reg  [7:0]  px_acc;           // pixel accumulator (filled then written)
    reg         hbl_r, vbl_r;
    wire        line_start = hbl_r & ~hbl;   // HBL falling
    wire        line_end   = ~hbl_r & hbl;   // HBL rising
    wire [15:0] pix_wr_addr = {wbuf[0], vline[7:0], px_word[6:0]};

    always @(posedge clk_14m or posedge reset) begin
        if (reset) begin
            wbuf    <= 2'd0;
            vline   <= 9'd0;
            xcap    <= 10'd0;
            px_word <= 7'd0;
            px_bit  <= 3'd0;
            px_acc  <= 8'd0;
            hbl_r   <= 1'b0;
            vbl_r   <= 1'b0;
        end else begin
            hbl_r <= hbl;
            vbl_r <= vbl;

            if (line_start) begin
                xcap    <= 10'd0;
                px_word <= 7'd0;
                px_bit  <= 3'd0;
                px_acc  <= 8'd0;
            end else if (!hbl) begin
                // active: sample the pixel stream into 8-pixel words.
                // Word w is written when its 8th pixel arrives: the word
                // being written is {new pixel, acc[7:1]} (acc holds the
                // previous 7). All 70 words are written in-line because
                // MAX_CAP = 560 = 70 * 8 is exact (no line_end flush needed).
                if (xcap < MAX_CAP) begin
                    if (px_bit == 3'd7) begin
                        pix_ram[pix_wr_addr] <= {video_in, px_acc[7:1]};
                        px_acc  <= video_in;      // seed the next word
                        px_word <= px_word + 7'd1;
                        px_bit  <= 3'd0;
                    end else begin
                        px_acc <= {video_in, px_acc[7:1]};
                        px_bit <= px_bit + 3'd1;
                    end
                end
                xcap <= xcap + 10'd1;
            end

            if (line_end) begin
                // store the line only when visible (VBL low)
                if (!vbl && vline < VISIBLE_LINES) begin
                    cap_ram[{wbuf[0], vline[7:0]}] <=
                        (xcap <= MAX_CAP) ? xcap[9:0] : 10'd559;
                    vline <= vline + 9'd1;
                end
            end

            if (vbl_r & ~vbl) begin
                // frame start: flip the write buffer, restart the line index
                wbuf  <= ~wbuf;
                vline <= 9'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Display side (clk_12288 domain)
    // ------------------------------------------------------------------
    reg        dbuf;               // display buffer select (1 bit)
    reg        wbuf_s1, wbuf_s2;  // 2FF synchronizer of the write-buffer sel
    reg  [9:0] x_count, y_count;
    wire [9:0] visible_x, visible_y;   // nets (continuous assigns; reg would fail Quartus 10219)
    assign visible_x = x_count - H_BPORCH;
    assign visible_y = y_count - V_BPORCH;

    // --- stage 0: combinational from the counters ---
    wire       in_window   = (x_count >= H_BPORCH && x_count < H_BPORCH+H_ACTIVE) &&
                             (y_count >= V_BPORCH && y_count < V_BPORCH+V_ACTIVE);
    wire [9:0] nline_c     = visible_y - V_OFF;   // native visible line (0..191 on screen)
    wire       in_screen_c = (visible_y >= V_OFF) & (visible_y - V_OFF < VISIBLE_LINES);

    // --- stage 1: registered (synchronous) RAM reads + latched address ---
    // Quartus 17 will NOT infer a RAM with asynchronous read logic
    // (276007: "uninferred due to asynchronous read logic" -> 276003), so
    // both cap_ram and pix_ram are read through registers. The pixel path
    // is therefore 3 stages deep from the counters; video_de is delayed by
    // the same amount (de_d2) so video_rgb stays pixel-aligned with video_de.
    // (vs/hs keep the template's 1-stage timing; the extra de delay just
    // shortens the hbp by 2 cycles - porches need not be accurate, KB-014.)
    reg  [9:0]  x_r;               // latched output pixel x (0..319)
    reg  [9:0]  nline_r;           // latched native visible line
    reg  [9:0]  capl_r;            // latched sample count for that line
    reg         scr_r;             // latched in-screen flag
    reg         de_d1;             // window flag, 1 stage
    always @(posedge clk_12288 or posedge reset) begin
        if (reset) begin
            x_r     <= 10'd0;
            nline_r <= 10'd0;
            capl_r  <= 10'd0;
            scr_r   <= 1'b0;
            de_d1   <= 1'b0;
        end else begin
            x_r     <= visible_x;
            nline_r <= nline_c;
            scr_r   <= in_screen_c;
            de_d1   <= in_window;
            capl_r  <= cap_ram[{dbuf, nline_c[7:0]}];   // sync read
        end
    end

    // --- stage 2: pixel index from latched values, then the pixel read ---
    // (x * capl) / 320 (constant division; max = 319*560/320 = 558 < 560)
    wire [19:0] px_prod  = x_r * capl_r;   // 20-bit product (no truncation)
    wire [9:0]  pidx_c   = scr_r ? px_prod / 20'd320 : 10'd0;
    // The RAM read is whole-word and DIRECT: a 2:1 MUX on the read data
    // (`? pix_ram[addr] : 0`) defeats Quartus 17's RAM inference (276007
    // "asynchronous read logic" -> 276003) even though the read is clocked -
    // proven by minimal reproduction in verilog/ramtest. The valid flag is
    // latched with the word (same cycle) and applied after the register.
    reg         de_d2;      // window flag, 2 stages (aligns with px_r)
    reg         pxv_r;      // latched valid flag (in-screen & index in range)
    reg  [7:0]  pxw_r;      // latched 8-pixel word
    reg  [2:0]  pxbit_r;    // latched pixel-within-word index
    always @(posedge clk_12288 or posedge reset) begin
        if (reset) begin
            de_d2   <= 1'b0;
            pxv_r   <= 1'b0;
            pxw_r   <= 8'd0;
            pxbit_r <= 3'd0;
        end else begin
            de_d2   <= de_d1;
            pxw_r   <= pix_ram[{dbuf, nline_r[7:0], pidx_c[9:3]}];  // direct sync read
            pxbit_r <= pidx_c[2:0];
            pxv_r   <= scr_r & (pidx_c < capl_r);
        end
    end
    wire px_r = pxv_r ? pxw_r[pxbit_r] : 1'b0;   // pixel, aligned with de_d2

    // --- machine frame start, tracked in the display domain ---
    // The machine flips wbuf once per frame (at its VBL falling edge).
    // We do NOT time our buffer switch to a synchronized VBL pulse: a VBL
    // edge sampled into the 12.288 domain lands up to one display cycle
    // early/late depending on clock phase, which in sim produced a
    // one-frame-late dbuf (display kept reading the buffer being written).
    // Instead we track wbuf itself: its change IS the machine frame start,
    // and the 3-stage synchronizer + 1-cycle delay guarantees that by the
    // time we act, wbuf_s2 (the 2FF dbuf samples) has settled to the NEW
    // write buffer. So dbuf = ~wbuf_s2 = the buffer the machine just
    // finished - never the one being written.
    //
    // The display frame start (VS / counter restart) is also locked to
    // this event, so the display frame rate follows the machine exactly
    // (60.03 Hz on hardware) - no drift, no ping-pong race.
    reg  [2:0]  wb_syn;              // 3-stage sync of wbuf[0]
    wire        wb_change;           // 1-cycle pulse on wbuf change
    reg         fs_d1;               // wb_change, delayed 1 (syncs settled)
    always @(posedge clk_12288 or posedge reset) begin
        if (reset) begin
            wb_syn <= 3'b000;
            fs_d1  <= 1'b0;
        end else begin
            wb_syn <= {wb_syn[1:0], wbuf[0]};
            fs_d1  <= wb_syn[0] ^ wb_syn[1];
        end
    end
    assign wb_change = wb_syn[0] ^ wb_syn[1];

    // --- stage 3: output registers (template timing skeleton) ---
    always @(posedge clk_12288 or posedge reset) begin
        if (reset) begin
            x_count  <= 10'd0;
            y_count  <= 10'd0;
            dbuf     <= 1'b0;
            wbuf_s1  <= 1'b0;
            wbuf_s2  <= 1'b0;
            video_rgb <= 24'h000000;
            video_de  <= 1'b0;
            video_vs  <= 1'b0;
            video_hs  <= 1'b0;
            video_skip<= 1'b0;
        end else begin
            video_de   <= de_d2;           // aligned with px_r (both 3 stages)
            video_vs   <= 1'b0;
            video_hs   <= 1'b0;
            video_skip <= 1'b0;
            video_rgb  <= px_r ? 24'hFFFFFF : 24'h000000;  // px_r=0 outside DE (KB-014)

            wbuf_s1 <= wbuf[0];
            wbuf_s2 <= wbuf_s1;

            // counters: line advance free; frame start locked to the
            // machine's wbuf change (wb_change, delayed 1: fs_d1).
            // The display frame rate therefore follows the machine exactly
            // (60.03 Hz on hardware) - no drift, no buffer race.
            x_count <= x_count + 1'b1;
            if (x_count == H_TOTAL-1) begin
                x_count <= 0;
                if (y_count != V_TOTAL-1)
                    y_count <= y_count + 1'b1;   // hold on last line until frame start
            end

            if (fs_d1) begin
                // machine frame start (wbuf change, delayed 1 cycle so all
                // synchronizers have settled): restart the display frame
                // (VS at x=0) and re-select the display buffer. wbuf_s2
                // now holds the machine's NEW write buffer, so dbuf =
                // ~wbuf_s2 = the buffer the machine just finished - never
                // the one being written.
                x_count  <= 10'd0;
                y_count  <= 10'd0;
                video_vs <= 1'b1;
                dbuf     <= ~wbuf_s2;
            end
            if (x_count == 3)
                video_hs <= 1'b1;       // one-cycle HS, 3 cycles after VS
        end
    end

endmodule
