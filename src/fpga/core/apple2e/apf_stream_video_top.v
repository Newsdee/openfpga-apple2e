//
// apf_stream_video_top.v - Phase 2 streaming-video core (EXPERIMENTAL)
//
// A separately-selectable variant of core_top (apple2e_core_top.v) that
// replaces the apf_video frame-buffer path with the apf_stream_video
// streaming adapter. Feeds the real machine video + full-color OSK
// (24-bit RGB, with transparency) directly to the APF DDR pad on the
// 14.318 MHz machine clock. No M10K, no PSRAM, no clock-domain crossing.
//
// NOT part of the working core. Compiled only by apf_stream_video.qsf
// (top entity apf_top_stream). The working path (core_top + apf_video)
// is untouched.
//
`default_nettype none

module stream_video_core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// ---- "Reboot on disk change" option word (interact.json variable) ----
// The Pocket framework writes the selected value here at boot (before
// Reset Exit) and reads it back at shutdown (after Reset Enter) - the
// register must therefore survive machine_reset (it is bridge-domain,
// clocked only by clk_74a). 0x01F00000 sits outside the data-slot FIFO
// window (0x00xxxxxx) and the F8/F9 command/diagnostic spaces.
reg [31:0] cfg_reboot_word = 32'd1;   // default ON (fresh users reboot)
always @(posedge clk_74a)
    if (bridge_wr && bridge_addr == 32'h01F00000)
        cfg_reboot_word <= bridge_wr_data;

// ---- "Joystick" option word: REMOVED (2026-10-25, J10) ----
// The option + its 0x01F00004 bridge latch were removed after the disk-
// regression bisection (J7/J9): builds carrying the option-word delta
// (read-back mux arm + cfg_joy_word) failed to load disks on silicon
// (11:02, 14:42) while option-free logic booted (09:26, 12:49, 15:24).
// Joystick mode is now hardwired to Absolute at the instance below.
// The 01F0xxxx read-back wildcard stays in its proven 09:26 form.

// ---- Colour Preset (MERGED) option word (2026-10-26, 0.2.6) ----
// The former two knobs ("Display Mode" @0x01F00004 + "Colour Preset" @
// 0x01F00008) are merged into ONE writeonly list (interact.json id 4,
// 7 options) - saves one of the APF's 16 interact entries:
//   0 = NTSC //e   (colour, preset 0)     4 = Monochrome
//   1 = Old TV     (colour, preset 1)     5 = Green
//   2 = AppleWin   (colour, preset 2)     6 = Amber
//   3 = Muted      (colour, preset 3)
// Still writeonly: the host never reads it back, so the 01F0xxxx read-back
// wildcard stays byte-identical to its proven 09:26 form (the J7/J9
// constraint). 0x01F00008 is now dead - no latch, reads fall through to
// the wildcard exactly as before.
// Bridge-domain (clk_74a) register, so like cfg_reboot_word it must survive
// machine_reset - it holds a host preference, not machine state.
// Default 0 = (colour, preset 0) = the previously hardwired picture
// (SCREEN_MODE 2'b00, comp_preset 2'd0), so behaviour is unchanged until
// the user moves the option.
// Decode (machine domain, after CDC): [2] clear -> colour, comp_preset =
// [1:0], SCREEN_MODE = 0; [2] set -> SCREEN_MODE = [1:0] + 1 (1..3 = the
// mono variants: 4=Monochrome, 5=Green, 6=Amber), comp_preset = 0
// (irrelevant off the colour path).
reg [31:0] cfg_colour_word = 32'd0;    // [2:0] = option value
always @(posedge clk_74a)
    if (bridge_wr && bridge_addr == 32'h01F00004)
        cfg_colour_word <= bridge_wr_data;

// bridge(74.25) -> machine(14.318) CDC, same synch_3 pattern as the reboot
// option above. Per-bit synchronization means the 3-bit value can
// transiently present a mixed code while it settles (e.g. 3 -> 4 may pass
// through 5 or 6). For this knob that is at most one frame of a different
// picture mode while the user is actively changing the option, which is
// cosmetically harmless; it is not acceptable for a multi-bit datapath
// value, and would need a handshake or gray coding if these ever became one.
wire [2:0] colour_opt_m;
synch_3 #(.WIDTH(3)) u_colour_opt_sync (
    .i(cfg_colour_word[2:0]), .o(colour_opt_m),
    .clk(clk_core_14318), .rise(), .fall()
);
wire        colour_on_m    = ~colour_opt_m[2];
// Verilog-2001 safe (no SV size casts - Quartus 17 rejects `N'(expr)` in
// .v files, Error 10170): the add is 2-bit self-determined, so
// [1:0]+1 gives 4->1, 5->2, 6->3.
wire [1:0] mono_mode_sel  = colour_opt_m[1:0] + 2'd1;
wire [1:0] display_mode_m  = colour_on_m ? 2'b00 : mono_mode_sel;
wire [1:0] comp_preset_m   = colour_on_m ? colour_opt_m[1:0] : 2'b00;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

// dram_* pads: driven by the io_sdram instance (M0 image storage; see below).

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// add your own devices here
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h10xxxxxx: begin
        // example
        // bridge_rd_data <= example_device_data;
        bridge_rd_data <= 0;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    32'hF9xxxxxx: begin
        // M0 SDRAM storage diagnostics (see sdram_storage.v)
        bridge_rd_data <= stor_diag_rd;
    end
    32'h01F01xxx: begin
        // HDV sector buffer (deferload slot 2): the 0x0184 DMA reads it
        // here; written by host 0x0180 DMA + the machine-domain walker.
        // Window 0x01F01000-0x01F01FFF (HDV uses the first 512 B).
        bridge_rd_data <= hdv_ram_word;
    end
    32'h01F00xxx: begin
        // Reboot-on-disk-change persist word. Written ONLY at
        // 0x01F00000 (above); the host reads it back at the same address.
        // DISK-BISECT history (2026-10-25): this arm was the 0x01F0xxxx
        // wildcard ("proven 09:26 form"). When the HDV window took
        // 0x01F01xxx it overlapped that wildcard (Quartus warning 10935);
        // the arms are now a disjoint partition - 01F00xxx keeps every
        // address the host ever touches (0x01F00000, and 0x01F00004,
        // the retired Joystick persist entry) on the proven cfg_reboot_word
        // path, while 0x01F02xxx-0x01F0Fxxx fall to default: 0.
        bridge_rd_data <= cfg_reboot_word;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s; 
    // Host loads data slots only after SDRAM init (expert review: bounded,
    // no-deadlock gate): machine PLL lock AND io_sdram boot complete.
    wire            status_setup_done = pll_core_locked_s & stor_init_done;
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a
//
// The request/param nets are WIRES: hdv_bridge drives them as module
// OUTPUTS (H2, PLAN_HDV_READONLY). Quartus Error 10663 rejects a module
// output port connected to a `reg`-declared identifier ("must be
// connected to a structural net expression"); Verilator tolerates it,
// which is why the template's `reg` declarations survived the sim-only
// bring-up. core_bridge_cmd takes them as inputs; single driver =
// hdv_bridge.

    wire            target_dataslot_read;
    wire            target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped

    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    wire    [15:0]  target_dataslot_id;
    wire    [31:0]  target_dataslot_slotoffset;
    wire    [31:0]  target_dataslot_bridgeaddr;
    wire    [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;   // driven by the .a2k poller (74a domain)
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( 1'b0 ),   // port A is read-only for us
    .datatable_data         ( 32'd0 ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////



// video generation
// ~12,288,000 hz pixel clock
//
// P2a: Apple IIe machine core (14.318 MHz domain) + APF video adapter.
// The unmodified machine core (apple2.v, machine/ folder = byte-identical
// copy of Apple-II_MiSTer/rtl) generates native 1-bit video; apf_video
// converts it to the APF 400x512 @ 12.288 MHz bus (same grid as the P1
// test pattern). 64K main + 64K aux RAM are inferred block RAM. No
// slots/drives/HDD/NSC/ramcard in this bring-up build: the machine core's
// peripheral ports are tied off exactly as in the level-1 test harness.
//
assign video_rgb_clock = clk_core_14318;      // native Apple II pixel clock
assign video_rgb_clock_90 = clk_core_14318_90; // 90-degree phase copy (DDR)
// video_rgb/de/skip/vs/hs are driven by the apf_video adapter (below).

// ---- machine reset: host reset_n (74a domain) -> 14.318 domain, 2FF ----
reg [1:0] rst_sync;
always @(posedge clk_core_14318 or negedge reset_n) begin
    if (!reset_n) rst_sync <= 2'b00;
    else          rst_sync <= {rst_sync[0], 1'b1};
end

// PLL lock, synchronized into the 143.18 MHz domain: the machine must not
// leave reset until clk_core_14318 is valid (locked = 1).
reg [1:0] lock_sync;
always @(posedge clk_core_14318) begin
    lock_sync <= {lock_sync[0], pll_core_locked};
end
wire machine_reset_base = ~rst_sync[1] | ~lock_sync[1] | osk_cmd_reset;
// "Reboot on disk change" option: the cold-reboot FSM (reboot_ctl, below
// the mount logic) ORs its reset contribution in; it is async-reset by
// machine_reset_base ONLY, never by machine_reset, so a cold pulse can
// not re-trigger itself.
wire        cold_reset_m;
wire machine_reset = machine_reset_base | cold_reset_m;
wire osk_reset    = ~rst_sync[1] | ~lock_sync[1];   // host/POC only - the OSK must survive its own command reset (review #2)

// Power-on PLL release pulse (clk_74a domain): hold the PLL in reset for
// ~441 us after power-on (32767 x 13.47 ns), then release it to lock.
//
// DO NOT tie the PLL rst to ~reset_n: the framework polls Request-Status
// (0x0000) BEFORE sending Reset-Exit (0x0011), and status_boot_done =
// pll_locked. With rst = ~reset_n (which stays 0 until Reset-Exit) the PLL
// would be held in reset forever, status would stay "booting" forever, and
// the framework times out with "Error in Framework: RS: Host commands
// ignored". A host Reset (0x0010) still resets the machine via reset_n;
// the PLL keeps running (and locked) through host resets.
// (Un-reset counter: power-on value is bounded 0..32767, so the release
// is at most ~441 us after power-on in all cases.)
reg  [16:0] pll_por_cnt;
wire       pll_rst_pulse;
always @(posedge clk_74a) begin
    if (pll_por_cnt != 17'd32767)
        pll_por_cnt <= pll_por_cnt + 17'd1;
end
assign pll_rst_pulse = (pll_por_cnt < 17'd32767);

// ---- slow blink for the machine (FLASH_CLK, ~1.7 Hz) ----
reg [22:0] blink_div;
always @(posedge clk_core_14318 or posedge machine_reset) begin
    if (machine_reset) blink_div <= 23'b0;
    else               blink_div <= blink_div + 1'b1;
end

// ---- 64K main + 64K aux RAM (inferred M10K) ----
// ram_clear (reboot_ctl, "Reboot on disk change" option): sequential
// WRITE-SWEEP clear. Cyclone V M10Ks have no runtime content-clear pin
// (only output/address clear - expert review 2026-10-24, verified against
// the installed cyclonev_ram_block model), and Quartus 17.0.2 will not
// infer a single-port M10K whose write ADDRESS is conditional (if/else
// two-write form OR muxed address: Error 276003 + 276007 "uninferred due
// to asynchronous read logic" -> ~500K logic registers per bank -> Fitter
// 170011 / multi-hour TDS grind). The inference matrix
// (tools/ram_repro_matrix, 2026-10-24) isolated the poison precisely:
// muxed write DATA or write ENABLE is fine; only the conditional write
// ADDRESS breaks inference.
//
// So the RAM block below stays byte-identical to the proven M1 shape
// (plain single-port, per-bank enable, write-first bypass) and the sweep
// walks the BUS instead: ram_sweep_ctl drives we/addr/aux through a
// combinational overlay on the _f nets (one 65,536-address pass per
// bank = 131,072 cycles, ~0.92 ms at 143.18 MHz, data hardwired to 0).
// The machine (CPU + Disk II) is in cold reset for the whole sweep
// (reboot_ctl holds cold_reset until done + HOLD), so hijacking the RAM
// write port is safe: apple2 and disk_ii_woz are reset-gated. The
// initial block is the power-on state only (file zero-fill).
reg  [7:0]  ram_main [0:65535];
reg  [7:0]  ram_aux  [0:65535];
reg  [15:0] m_ram_do;
wire [15:0] m_addr;
wire [17:0] m_ram_addr;
wire [7:0]  m_ram_di;
wire        m_ram_aux;
wire        m_ram_we;
wire        ram_clear_m;

// ---- sweep bus overlay (inference-safe; the RAM block never sees a
//      conditional write address) ----
wire        swp_we, swp_aux, swp_done;
wire [15:0] swp_addr;
wire [17:0] m_ram_addr_f = swp_we ? {2'b00, swp_addr} : m_ram_addr;
wire [7:0]  m_ram_di_f   = swp_we ? 8'd0 : m_ram_di;
wire        m_ram_aux_f  = swp_we ? swp_aux : m_ram_aux;
wire        m_ram_we_f   = swp_we | m_ram_we;
ram_sweep_ctl woz_sweep (
    .clk(clk_core_14318),
    .start(ram_clear_m),
    .we(swp_we), .addr(swp_addr), .aux(swp_aux), .done(swp_done)
);
initial begin
    // power-on RAM state (file zero-fill, 2026-10-25 Phase B): the nested
    // 256x256 procedural loop cost ~19 min of single-threaded A&S CPU on
    // the full core (probe evidence: tools/ram_repro_init 19:13 vs
    // tools/ram_repro_file 1:28 for the identical one-bank RAM - the file
    // form is ~13x faster). Canonical image: src/fpga/rtl/roms/
    // ram_zero_64k.hex (65,536 x "00", LF, git-tracked, *.hex text eol=lf).
    // Path is CWD-relative: Quartus runs from src/fpga; the sim runner
    // stages the same file under its rtl/roms/ (verilog/pocket_boot/
    // build.sh, with preflight). Configuration-time initialization only -
    // a machine reset is NOT a reload of this file: the runtime clearing
    // sweep (ram_sweep_ctl below) still clears both banks after every
    // cold reset before the CPU is released.
    $readmemh("rtl/roms/ram_zero_64k.hex", ram_main);
    $readmemh("rtl/roms/ram_zero_64k.hex", ram_aux);
end
// ---- the proven M1 RAM shape: plain single-port per bank, write-first
//      bypass - consumes the overlayed _f nets only ----
always @(posedge clk_core_14318) begin
    if (m_ram_we_f & ~m_ram_aux_f) begin
        ram_main[m_ram_addr_f[15:0]] <= m_ram_di_f;
        m_ram_do[7:0]              <= m_ram_di_f;
    end else m_ram_do[7:0]  <= ram_main[m_ram_addr_f[15:0]];
    if (m_ram_we_f & m_ram_aux_f) begin
        ram_aux[m_ram_addr_f[15:0]] <= m_ram_di_f;
        m_ram_do[15:8]            <= m_ram_di_f;
    end else m_ram_do[15:8]  <= ram_aux[m_ram_addr_f[15:0]];
end

// ---- machine core (wiring mirrors the level-1 test harness) ----
wire        m_clk2m;
wire        m_pz, m_pzr, m_pzf;
wire        m_video, m_hbl, m_vbl;
wire        m_text_mode, m_hgr_mode, m_early_video, m_run_fill_ok;
wire        m_col_line, m_hgr80_mode, m_gr2, m_col80, m_dhires;
wire        m_read_key, m_spk;
wire [7:0]  m_K;
wire        m_akd;
wire [7:0]  m_io_sel, m_dev_sel;
wire        m_io_str, m_pdl, m_stb;
wire [3:0]  m_an;

// ---- NTSC color path (PLAN_NTSC_PORT_2026-10-24, N2) ----
// NTSC_EN=1 inserts the pinned donor video_pipeline between the machine and the
// OSK; NTSC_EN=0 restores the original monochrome path. The fallback is not a
// separate code path: mono_rgb below is the SAME expression apple2e_osk used to
// compute internally (video_in ? FFFFFF : 000000), and the OSK is now always
// instantiated with RGB_IN=1, so with NTSC_EN=0 the pixels reaching the overlay
// and APF are unchanged by construction. Verify that in simulation, do not
// assume it.
//
// The shipping build compiles the generated *_q17 modules (Quartus 17.0.2
// rejects the donor's 15 `N'(expr)` size casts with Error 10170). Those are
// proven cycle-exact against the pinned donor by verilog/verilate_ntsc_parity.sh
// over 3.8M cycles x all 4 presets x all 4 screen modes, 0 mismatches. The
// canonical donor files stay in machine/video/ as the reference only.
parameter NTSC_EN = 1'b1;

wire [23:0] ntsc_rgb;
wire        ntsc_hbl, ntsc_vbl, ntsc_hs, ntsc_vs;
wire        ntsc_ioctl_wait;   // must never assert (downloads are tied off)

// Fixed configuration per plan section 4 (owner decisions 2026-10-24),
// updated 2026-10-26 (0.2.6): the two user-facing knobs (SCREEN_MODE,
// comp_preset) are MERGED into the single "Colour Preset" option word
// (cfg_colour_word) - see its comment. Everything else is hardwired and
// must NOT be exposed:
//   use_composite=1 (always composite, no RGB-monitor mode)
//   NTSC_VERTICAL_COMB=1 (comb always on)
//   LO_RES_TEXT=1, comp_hue_adj=0, bright/sat/contrast offsets 0
//   COLOR_PALETTE=constant (dead: it only reaches vga_controller, which is
//   unobserved at use_composite=1 and must fold away in synthesis)
video_pipeline_q17 ntsc_pipe (
    .CLK_14M            (clk_core_14318),
    .VIDEO              (m_video),
    .HBL                (m_hbl),
    .VBL                (m_vbl),
    .COLOR_LINE         (m_col_line),
    .TEXT_MODE          (m_text_mode),
    .LO_RES_TEXT        (1'b1),
    .SCREEN_MODE        (display_mode_m),  // "Colour Preset" merged option (writeonly)
    .COLOR_PALETTE      (2'd0),
    .RUN_FILL_OK        (m_run_fill_ok),
    .NTSC_VERTICAL_COMB (1'b1),
    .EARLY_VIDEO        (m_early_video),
    .HGR_MODE           (m_hgr_mode),
    .HGR80_MODE         (m_hgr80_mode),
    .GR2                (m_gr2),
    .COL80              (m_col80),
    .DHIRES_MODE        (m_dhires),
    .ioctl_addr         (25'd0),
    .ioctl_data         (8'd0),
    .ioctl_index        (8'd0),
    .ioctl_download     (1'b0),
    .ioctl_wr           (1'b0),
    .ioctl_wait         (ntsc_ioctl_wait),
    // machine_reset now includes cold_reset_m (the disk-change cold reboot),
    // so the encoder/decoder is reset on EVERY disk change, not just at
    // power-on. Plan section 4a calls this the most important new interaction:
    // colour must re-acquire within the 2-frame bound after a disk swap.
    .reset              (machine_reset),
    .machine_ce         (1'b1),
    .use_composite      (1'b1),
    .comp_preset        (comp_preset_m),   // "Colour Preset" merged option (writeonly)
    .comp_hue_adj       (5'd0),
    .comp_bright_st     (2'd0),
    .comp_sat_st        (2'd0),
    .comp_contrast_st   (2'd0),
    .R                  (ntsc_rgb[23:16]),
    .G                  (ntsc_rgb[15:8]),
    .B                  (ntsc_rgb[7:0]),
    .HS                 (ntsc_hs),      // NOT driven onto APF: the adapter
    .VS                 (ntsc_vs),      // regenerates its own 1-clock pulses
    .HBL_O              (ntsc_hbl),
    .VBL_O              (ntsc_vbl)
);

// ---- VBL/HBL alignment for the APF adapter (measured, not assumed) ----
// apf_stream_video.v:81 generates its frame pulse as
//     vs_pulse = (vbl_r & ~vbl) & hbl
// so VBL's FALLING edge must be seen while HBL is high. The donor pipeline
// breaks that contract because it delays the two flags by DIFFERENT amounts:
//     HBL_O = hb_c_s   (hb_c_out piped through the variable hshift_idx tap)
//     VBL_O = vb_c_out (not piped)
// Measured in verilog/tb/tb_ntsc_parity.sv over 16 frames:
//     raw machine VBL falls = 15, of which HBL high = 15   (contract holds)
//     pipeline  VBL_O falls = 15, of which HBL_O high =  0 (contract broken)
// Raw VBL falls at the line start, so sampling HBL hshift_idx cycles earlier
// lands in the PREVIOUS line's active video - hence 0/15, hence video_vs never
// pulses and the boot harness counts frames=0.
//
// Fix in Pocket glue (the donor files are byte-pinned, so they must not change):
// delay VBL_O by a fixed VBL_ALIGN so its falling edge lands inside the same
// line's HBL_O window. Safe for any hshift_idx <= VBL_ALIGN because machine HBL
// is high for 352 clocks from the line start (132 pre-sync + 220 post-sync,
// per composite_decoder.sv:118-119), and hshift_idx is bounded by
// HSHIFT_COMP + HSHIFT_SMOOTH = 21 (video_pipeline.sv:271-272). A 32-clock
// shift is far inside the 54-line vertical blanking interval, so frame
// boundaries move by a negligible amount.
localparam VBL_ALIGN = 32;
reg [VBL_ALIGN:0] vbl_align_pipe;
always @(posedge clk_core_14318) begin
    if (machine_reset) vbl_align_pipe <= {(VBL_ALIGN+1){1'b1}};
    else               vbl_align_pipe <= {vbl_align_pipe[VBL_ALIGN-1:0], ntsc_vbl};
end
wire ntsc_vbl_aligned = vbl_align_pipe[VBL_ALIGN];

// ---- selected video: RGB and its OWN blanking always travel together ----
// Plan section 4: do not combine delayed decoded RGB with raw machine blanking.
wire [23:0] mono_rgb = m_video ? 24'hFFFFFF : 24'h000000;
wire [23:0] sel_rgb  = NTSC_EN ? ntsc_rgb : mono_rgb;
wire        sel_hbl  = NTSC_EN ? ntsc_hbl : m_hbl;
wire        sel_vbl  = NTSC_EN ? ntsc_vbl_aligned : m_vbl;

// ---- OSK (buttons -> keystrokes; overlay over the native video) ----
wire        osk_video;
wire [23:0] osk_rgb24;
wire        osk_cmd_reset;
wire        osk_open_apple, osk_closed_apple;
// Merged 2026-10-25: main's joystick/J11 work adds osk_visible (overlay
// visibility + paddle gating); the NTSC work adds RGB_IN so the OSK composites
// over decoded colour instead of expanding 1-bit video internally. Both wanted.
wire        osk_visible;
apple2e_osk #(.RGB_IN(1'b1)) osk (
    .clk(clk_core_14318),
    .reset(osk_reset),
    .cont1_key(cont1_key),
    // Docked USB HID keyboard (PLAN_USB_KEYBOARD_2026-11-02): type-4 reports
    // arrive on the Player-3 pad slot; apple2e_osk syncs + converts to PS/2.
    .cont3_key(cont3_key),
    .cont3_joy(cont3_joy),
    .cont3_trig(cont3_trig),
    .video_in(m_video),
    .hblank(sel_hbl),
    .vblank(sel_vbl),
    .rgb_in(sel_rgb),
    .video_out(osk_video),
    .video_rgb24(osk_rgb24),
    .K(m_K),
    .reads(m_read_key),
    .akd(m_akd),
    .open_apple(osk_open_apple),
    .closed_apple(osk_closed_apple),
    .command_reset(osk_cmd_reset),
    .osk_visible(osk_visible),
    .joy_key_code(j2k_key_code),
    .joy_key_press(j2k_key_press)
);

// ---- Joystick/paddle input (2026-10-25, PLAN_JOYSTICK_INPUT; J10) ----
// The byte-pinned donor joystick_input (NOTICE.md) runs in the machine
// domain on a gated slice of clk_core_14318 (143.18 MHz).
// J10 (2026-10-25): the "Joystick" mode option is REMOVED (disk-regression
// isolation, J7/J9) - the mode is hardwired to Absolute: the analog stick
// snaps combinationally (the gate is irrelevant in Absolute and sits at
// 100%) and d-pad/face inputs snap to the axis extremes.
//   * while the OSK is visible the gate closes: the state FREEZES (not
//     zeroed) and the face buttons belong to the OSK.
// face-X (joy[6]) overrides both paddles to centre (joy_an 0x0000 =
// signed 0 = the 2800-tick one-shot centre) - calibration-style games.
wire [31:0] cont1_key_m;
synch_3 #(.WIDTH(32)) s_joy_key (
    .i(cont1_key), .o(cont1_key_m), .clk(clk_core_14318)
);
// Step 0 stick-liveness probe (BRIEF_JOY_RELATIVE_MODE): sync the analog-stick
// word into the machine domain. cont1_joy layout: [7:0]=lstick_x [15:8]=lstick_y
// [23:16]=rstick_x [31:24]=rstick_y. The 3-FF sync of a multi-bit bus is
// formally skew-unsafe, but a mixed sample is one frame of paddle jitter in the
// worst case and both stick bytes update together on the pad side (brief §3).
wire [31:0] cont1_joy_m;
synch_3 #(.WIDTH(32)) s_joy_analog (
    .i(cont1_joy), .o(cont1_joy_m), .clk(clk_core_14318)
);
// Probe "stick ever moved" OR-tree: latches 1 the first time the left stick
// (x or y) leaves centre; stays 1 (no clear) for the rest of the session.
reg joy_ever_m = 1'b0;
always @(posedge clk_core_14318)
    if (cont1_joy_m[15:0] != 16'd0) joy_ever_m <= 1'b1;
wire        joy_enable = ~osk_visible;
wire        joy_clk    = clk_core_14318 & joy_enable;   // Absolute: full clock, OSK-gated
// APF d-pad/face bits -> donor digital convention
// ([0]=right [1]=left [2]=up [3]=down; [4]=A [5]=B [6]=X [7]=Y)
wire [15:0] joy_dig = {8'b0,
                       cont1_key_m[7],   // face Y  -> PB2 (bit 7)
                       cont1_key_m[6],   // face X  -> centre (bit 6)
                       cont1_key_m[5],   // face B  -> PB1 (bit 5)
                       cont1_key_m[4],   // face A  -> PB0 (bit 4)
                       cont1_key_m[1],   // dpad_down -> [3]
                       cont1_key_m[0],   // dpad_up   -> [2]
                       cont1_key_m[2],   // dpad_left -> [1]
                       cont1_key_m[3]};  // dpad_right -> [0]
wire [15:0] joy_an;
wire [7:0]  joy;
// RELATIVE_UPDATE_CYCLES: the period between relative-mode accumulator steps.
// 143182 (= 1 ms @ 143.18 MHz) is the donor default. 71591 (0.5 ms, 2x faster)
// felt "floaty" on hardware (the paddle overshoots before you release, reading
// as inertia), so use the donor 1 ms period - half the step rate, snappier stop.
// Re-tune upward (fewer ms) if it's now too sluggish.
joystick_input #(.RELATIVE_UPDATE_CYCLES(143182)) u_joy (
    .clk(joy_clk),
    .reset(machine_reset),
    .joystick_digital(joy_dig),
    // BRIEF_JOY_RELATIVE_MODE: feed the live left-stick bytes (donor convention
    // analog[15:8]=X, analog[7:0]=Y; cont1_joy [7:0]=X [15:8]=Y) and the
    // Relative-mode enable. In Absolute the module ignores the analog bytes
    // (d-pad snaps the paddles) so this is inert by default.
    .joystick_analog({cont1_joy_m[7:0], cont1_joy_m[15:8]}),
    .paddle(8'h0),
    .swap_axes(1'b0),
    .paddle_as_x(1'b0),
    .paddle_as_y(1'b0),
    .x_center(3'd0),
    .relative_mode(joy_rel_m),   // 0=Absolute (default) 1=Relative ("Joystick Mode")
    .joy_an(joy_an),
    .joy(joy)
);
// centre override + the one-shot interval timer (donor P1 block)
wire [15:0] joy_an_eff = (joy[6] & joy_enable) ? 16'h0000 : joy_an;
// ---- Y-axis PDL polarity fix (2026-10-25, found in hardware: "down goes up") ----
// Real Apple II 555 PDL time convention: left/up = SHORT duration, right/down
// = LONG duration. The donor joy_an Y (up=+127 / down=-127 in absolute mode)
// is correct for X but inverted for Y (up -> 5594 ticks, down -> 6). The
// donor module is byte-pinned, so flip it here in the glue: two's-complement
// negation of the Y byte, with the relative-mode saturation extreme 0x80
// (-128, held-down) remapped to +127 (its negation wraps to itself in
// 8-bit two's complement and would stay "short" = wrong direction).
// Centre 0x00 and the face-X centre override (0x0000) are invariant.
wire [7:0] joy_y_pdl = (joy_an_eff[7:0] == 8'h80) ? 8'h7F :
                       (~joy_an_eff[7:0] + 8'h01);
wire [15:0] joy_an_pdl = {joy_an_eff[15:8], joy_y_pdl};
wire        joyx, joyy;
pdl_timer u_pdl (
    .clk(clk_core_14318),
    .tick(m_clk2m),
    .pdl_strobe(m_pdl),
    .joy_an(joy_an_pdl),
    .joyx(joyx),
    .joyy(joyy)
);

// ---- joy2key (2026-10-26, PLAN_JOY2KEY_2026-10-26.md) ----
// Gamepad -> Apple II keystrokes via the byte-pinned donor joy_to_key
// (machine/osk/joy_to_key.v; the JOY_TO_KEY macro is defined in the QSF and
// the Verilator build, so the joy-injection path in the pinned keyboard.v is
// active - without it the feature would look wired and do nothing).
//
// Two writeonly list options (interact.json ids 5/6), both default Off (0):
//   DPad Keys (0x01F00008): 0=Off 1=Cursor keys 2=IJKL 3=IJMK 4=A/Z/left/right
//   Fire Keys (0x01F0000C): 0=Off 1=U/O 2=Space/Return (each with a
//     Select-hold layer: U/O->Space/Return, Space/Return->Y/N)
// Off is deliberately the default and doubles as the enable: the D-pad
// already drives the paddles (J10), so enabling a preset makes the same
// control do both jobs at once ("double duty" - the option help says to
// enable these only for software that ignores the joystick). Off also makes
// the illegal state (enabled, no map) unrepresentable.
// Values cross bridge->machine with the standard synch_3 (same reasoning as
// the video options: a transient mixed code is at worst one key press while
// the user is actively changing the option).
reg  [31:0] cfg_j2k_dir_word = 32'd0;
reg  [31:0] cfg_j2k_btn_word = 32'd0;
reg  [31:0] cfg_media_word   = 32'd0;   // "Boot Media" (0x01F00010)
reg  [31:0] cfg_joy_mode_word = 32'd0;  // "Joystick Mode" (0x01F00014)
always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr == 32'h01F00008)
        cfg_j2k_dir_word <= bridge_wr_data;
    if (bridge_wr && bridge_addr == 32'h01F0000C)
        cfg_j2k_btn_word <= bridge_wr_data;
    // Boot Media: write-only (host writes at boot, never reads back), so
    // the 01F00xxx read-back wildcard stays in its proven form - the same
    // safe pattern as cfg_j2k_* / cfg_colour_word (see the 2026-10-25
    // disk-bisect: read-back mux arms broke disk loading on silicon).
    // value: 0=Both 1=Floppy (HD card off the bus) 2=HDD (floppy ejected).
    // Replaces the 0742 build's "Floppy Eject" id 7 (same address).
    if (bridge_wr && bridge_addr == 32'h01F00010)
        cfg_media_word <= bridge_wr_data;
    // Joystick Mode (BRIEF_JOY_RELATIVE_MODE): 0=Absolute (default) 1=Relative.
    // write-only (same safe pattern as cfg_media_word - the 01F00xxx read-back
    // wildcard stays in its proven form; a new bridge_rd arm broke disk loading
    // on silicon in the 2026-10-25 bisect).
    if (bridge_wr && bridge_addr == 32'h01F00014)
        cfg_joy_mode_word <= bridge_wr_data;
end

// Joystick Mode (BRIEF_JOY_RELATIVE_MODE): the relative-mode enable, synced
// from the 74a-domain cfg_joy_mode_word[0] (0=Absolute, 1=Relative) into the
// machine domain (joystick_input runs on clk_core_14318). One bit -> a plain
// sync chain (no multi-bit skew concern).
wire joy_rel_m;
synch_3 #(.WIDTH(1)) s_joy_rel (
    .i(cfg_joy_mode_word[0]), .o(joy_rel_m), .clk(clk_core_14318)
);

// ---- .a2k profile slot (2026-10-27, joy2key Phase 2) ----
// data.json id 3: parameters 4 = bit2 (nonvolatile filename cloned from
// slot 0 - the disk slot - with this slot's extension). Slot 0 has a FIXED
// filename "disk", so at boot the host loads disk.woz and looks for
// disk.a2k; if the user re-picks the disk by name through the interact
// browser (slot 0 is user-reloadable), the clone follows the picked base
// name (JungleHunt.woz -> JungleHunt.a2k). bit1 (core-specific) is CLEARED,
// so the file lives in the platform-common Assets folder next to the disk.
// APF DMAs the 16-byte file to 0x01F10000 on mount - OUTSIDE the
// 0x01F0xxxx read wildcard. required false: a missing file is silently
// skipped (no writes, datatable size 0) and the presets stay in force.
// The slot is a plain volatile read: never written back (not nonvolatile),
// so no read-only bit is needed.
//
// Presence comes from the APF datatable, not from the writes: 2 words per
// slot in data.json DECLARATION order (word 2k = id, 2k+1 = size in bytes;
// layout verified against PCXT's disk_tds.c). The mf_datatable port-A read
// is registered (1-cycle latency), so the poller samples q one cycle after
// each address. We declare two slots, so the scan covers entries 0-1.
//
// A present file (size exactly 16) REPLACES the whole 16-byte table,
// overriding the preset options (donor whole-byte semantics). The map has
// no reset: like the donor's ioctl-loaded table it survives a machine
// reset; presence drops (and the presets return) when the host clears the
// size - e.g. remounting a disk that has no profile.

// Byte capture (clk_74a), alongside the cfg latches.
reg [7:0] a2k_map [0:15];
// The host DMAs the slot with 32-bit LITTLE-ENDIAN word writes: file byte i
// sits in word[i/4] at data[8*(i%4)+7 : 8*(i%4)]. All four bytes of every
// word must be latched - a low-byte-only capture silently drops bytes
// 1-3/5-7/9-11/13-15 (hardware bug 2026-10-27: only the right-dpad byte
// of the IJKL profile survived, so only DPad-right typed a key).
wire [4:0] a2k_wi = {1'b0, bridge_addr[3:0]};   // 0, 4, 8 or 12 for word writes
always @(posedge clk_74a) begin
    if (bridge_wr && bridge_addr[31:4] == 28'h01F1000) begin  // 0x01F10000..0C
        a2k_map[a2k_wi + 5'd0] <= bridge_wr_data[7:0];
        a2k_map[a2k_wi + 5'd1] <= bridge_wr_data[15:8];
        a2k_map[a2k_wi + 5'd2] <= bridge_wr_data[23:16];
        a2k_map[a2k_wi + 5'd3] <= bridge_wr_data[31:24];
    end
end

// Datatable poller (clk_74a): the first driver of the port-A wires of
// core_bridge_cmd (they were undriven before).
reg  [13:0] a2k_timer = 14'd0;
reg  [2:0]  a2k_ps = 3'd0;        // 0 idle, 1 id word valid, 2 size word valid
reg  [2:0]  a2k_k = 3'd0;      // slot entry index (entries 0..2)
reg  [31:0] a2k_id_q = 32'd0;
reg  [31:0] a2k_size_q = 32'd0;
reg  [31:0] hdv_size_q = 32'd0;  // HDV slot (id 2) size; 0 = not mounted
reg  [9:0]  datatable_addr_r = 10'd0;
always @(posedge clk_74a) begin
    if (a2k_timer == 14'hFFFF) begin
        a2k_timer <= 14'd0;
        if (a2k_ps == 3'd0) begin
            datatable_addr_r <= 10'd0;    // word 0 = entry 0 id
            a2k_k            <= 3'd0;    // restart from the first entry
            a2k_ps           <= 3'd1;
        end else if (a2k_ps == 3'd1) begin
            a2k_id_q           <= datatable_q[15:0];
            datatable_addr_r   <= {6'd0, {a2k_k, 1'b0} + 4'd1};   // entry k size word = 2k+1
            a2k_ps             <= 3'd2;
        end else begin
            if (a2k_id_q == 16'd3)
                a2k_size_q <= datatable_q;
            // HDV (deferload slot, id 2): the datatable carries its size
            // even though it is not loaded into SDRAM
            if (a2k_id_q == 16'd2)
                hdv_size_q <= datatable_q;
            if (a2k_k == 3'd2)
                a2k_ps <= 3'd0;
            else begin
                a2k_k              <= a2k_k + 3'd1;
                datatable_addr_r   <= {5'd0, {a2k_k + 3'd1, 1'b0}};   // next id word = 2(k+1)
                a2k_ps             <= 3'd1;
            end
        end
    end else
        a2k_timer <= a2k_timer + 14'd1;

    // 0x008A "Data slot update" (deferload slots report (re)mounts this
    // way). MUST live in this same always block: hdv_size_q needs exactly
    // one driver (Quartus Error 10028 "multiple constant drivers" - Verilator
    // silently merges two always blocks, which is a sim/hardware divergence).
    // Placed last so an update pulse wins over a coincident poller latch;
    // the next poller scan re-reads the datatable within ~884us either way.
    if (dataslot_update && dataslot_update_id == 16'd2)
        hdv_size_q <= dataslot_update_size;
end
assign datatable_addr = datatable_addr_r;

// HDV mounted state: 74a -> machine (the hdd instance lives in the 14M domain)
wire        hdv_mounted_74 = (hdv_size_q != 32'd0);
wire        hdv_mounted_m;
synch_3 #(.WIDTH(1)) u_hdv_mounted_sync (
    .i(hdv_mounted_74), .o(hdv_mounted_m), .clk(clk_core_14318), .rise(), .fall()
);

// Cross bridge->machine like the video options (a transient mixed value is
// harmless: worst case one extra 16-cycle idempotent reload).
wire [127:0] a2k_map_p = {a2k_map[15], a2k_map[14], a2k_map[13], a2k_map[12],
                          a2k_map[11], a2k_map[10], a2k_map[9],  a2k_map[8],
                          a2k_map[7],  a2k_map[6],  a2k_map[5],  a2k_map[4],
                          a2k_map[3],  a2k_map[2],  a2k_map[1],  a2k_map[0]};
wire [128:0] a2k_vec_74 = {a2k_size_q == 32'd16, a2k_map_p};
wire [128:0] a2k_m;   // synch_3 output: must be a net for Quartus (Error 10663)
synch_3 #(.WIDTH(129)) u_a2k_sync (
    .i(a2k_vec_74), .o(a2k_m),
    .clk(clk_core_14318), .rise(), .fall()
);

// 1-cycle settle gate in the machine domain (same pattern as the presets' d1
// pair): bursts and compares only use the stable snapshot.
reg  [128:0] a2k_d1 = 129'd0, a2k_d2 = 129'd0;
always @(posedge clk_core_14318) begin
    a2k_d1 <= a2k_m;
    a2k_d2 <= a2k_d1;
end
wire a2k_stable_m   = (a2k_d1 == a2k_d2);
wire a2k_present_m  = a2k_d1[128];

wire [2:0] j2k_dir_m, j2k_btn_m;
synch_3 #(.WIDTH(3)) u_j2k_dir_sync (
    .i(cfg_j2k_dir_word[2:0]), .o(j2k_dir_m),
    .clk(clk_core_14318), .rise(), .fall()
);
synch_3 #(.WIDTH(3)) u_j2k_btn_sync (
    .i(cfg_j2k_btn_word[2:0]), .o(j2k_btn_m),
    .clk(clk_core_14318), .rise(), .fall()
);

// Boot Media (machine domain): 00=Both 01=Floppy (HD off) 10=HDD (floppy eject).
// bit1 feeds woz_mount_ctl.eject_req (the HDD entry holds the WOZ drive
// unmounted); bit0 gates the HD card off the bus (the Floppy entry: the ROM
// slot-scan sees an empty slot 7 and falls through to the slot-6 floppy).
// Default (host never wrote) = 00 = Both = bit-identical to the pre-gate
// wiring (~0 selects everything, the eject level is 0).
wire [1:0] media_m;
synch_3 #(.WIDTH(2)) u_media_sync (
    .i(cfg_media_word[1:0]), .o(media_m),
    .clk(clk_core_14318), .rise(), .fall()
);
wire hd_off_m = media_m[0];

// joy_to_key's bus convention (post-fix MiSTer order). DO NOT feed joy_dig:
// its bits 2/3 are swapped and X/Y sit in the Start/Select slots - that is
// the exact bit-order bug that reached MiSTer hardware once (Bug B).
//   0=right 1=left 2=down 3=up 4=fire1(A) 5=fire2(B) 6=Start 7=Select
//   8..11 = L,R,X,Y (APF bits 8,9,6,7); 12..15 unused
wire [15:0] joy_j2k = {
    4'b0000,                          // [15:12] L3,R3,L2,R2
    cont1_key_m[7], cont1_key_m[6],   // [11:10] Y, X
    cont1_key_m[9], cont1_key_m[8],   // [9:8]   R, L
    cont1_key_m[14], cont1_key_m[15], // [7:6]   Select, Start
    cont1_key_m[5],  cont1_key_m[4],  // [5:4]   fire2(B), fire1(A)
    cont1_key_m[0],  cont1_key_m[1],  // [3:2]   up, down
    cont1_key_m[2],  cont1_key_m[3]   // [1:0]   left, right
};
wire j2k_shift = cont1_key_m[14];     // Select = the module's shift input

// Map loader: composes the 16-byte table from both preset values and drives
// the donor's ioctl arm (16 bytes, one per machine clock) - to the module it
// is indistinguishable from a host-streamed .a2k, so the donor's byte
// validation (data>127 -> store 0) and "table survives reset" semantics come
// for free. A future .a2k slot (plan Phase 2) is a second source for this
// same arm. Both values are latched at burst start so a CDC settling
// transition cannot compose one old and one new axis; the 1-cycle stability
// gate keeps a burst from starting mid-settle; loaded_* make a redundant
// reload impossible (idempotent - no spurious keystroke). A reset abandons
// the burst; the 3'd7 loaded_* sentinel forces the first load at reset
// release (defaults Off/Off = blank table, overwriting the donor's power-up
// IJKM/UO table - that is what "both presets Off" means).
reg  [4:0] j2k_cnt;
reg        j2k_busy;
reg  [2:0] j2k_ld_dir, j2k_ld_btn;
reg  [2:0] j2k_loaded_dir = 3'd7;
reg  [2:0] j2k_loaded_btn = 3'd7;
reg  [2:0] j2k_dir_d1 = 3'd0;
reg  [2:0] j2k_btn_d1 = 3'd0;
// .a2k source: a present file replaces the whole table (donor semantics),
// so the loaded-state tracking extends to the 128-bit map + presence bit.
reg         j2k_ld_a2k_present = 1'b0;
reg  [127:0] j2k_ld_a2k = 128'd0;
reg         j2k_loaded_a2k_present = 1'b0;
reg  [127:0] j2k_loaded_a2k = 128'd0;

wire j2k_stable  = (j2k_dir_m == j2k_dir_d1) && (j2k_btn_m == j2k_btn_d1);
wire j2k_a2k_changed = a2k_stable_m &&
    ((a2k_d1[128] != j2k_loaded_a2k_present) ||
     (a2k_d1[127:0] != j2k_loaded_a2k));
wire j2k_changed = (j2k_dir_d1 != j2k_loaded_dir) || (j2k_btn_d1 != j2k_loaded_btn) ||
                   j2k_a2k_changed;

always @(posedge clk_core_14318) begin
    if (machine_reset) begin
        j2k_busy                 <= 1'b0;
        j2k_cnt                  <= 5'd0;
        j2k_ld_dir               <= 3'd0;
        j2k_ld_btn               <= 3'd0;
        j2k_loaded_dir           <= 3'd7;
        j2k_loaded_btn           <= 3'd7;
        j2k_dir_d1               <= 3'd0;
        j2k_btn_d1               <= 3'd0;
        j2k_ld_a2k_present       <= 1'b0;
        j2k_ld_a2k               <= 128'd0;
        j2k_loaded_a2k_present   <= 1'b0;
        j2k_loaded_a2k           <= 128'd0;
    end else begin
        j2k_dir_d1 <= j2k_dir_m;
        j2k_btn_d1 <= j2k_btn_m;
        if (!j2k_busy) begin
            if (j2k_stable && j2k_changed) begin
                j2k_busy                 <= 1'b1;
                j2k_cnt                  <= 5'd0;
                j2k_ld_dir               <= j2k_dir_d1;
                j2k_ld_btn               <= j2k_btn_d1;
                j2k_loaded_dir           <= j2k_dir_d1;
                j2k_loaded_btn           <= j2k_btn_d1;
                j2k_ld_a2k_present       <= a2k_d1[128];
                j2k_ld_a2k               <= a2k_d1[127:0];
                j2k_loaded_a2k_present   <= a2k_d1[128];
                j2k_loaded_a2k           <= a2k_d1[127:0];
            end
        end else if (j2k_cnt == 5'd15) begin
            j2k_busy <= 1'b0;
        end else begin
            j2k_cnt <= j2k_cnt + 5'd1;
        end
    end
end

// Preset -> byte. Bytes 0-3 are right,left,down,up (that order IS the
// .a2k byte order - the TB's byte-order guard exists to keep it so); 4-9
// are A,B,L,R,X,Y unshifted; 10-15 the same with Select held.
function [7:0] j2k_table_byte;
    input [2:0] dir;
    input [2:0] btn;
    input [3:0] byt;
    begin
        if (byt < 4'd4) begin
            case (dir)
                3'd0:    j2k_table_byte = 8'h00;
                3'd1:    j2k_table_byte = (byt == 4'd0) ? 8'h15 :
                                       (byt == 4'd1) ? 8'h08 :
                                       (byt == 4'd2) ? 8'h0A : 8'h0B;
                3'd2:    j2k_table_byte = (byt == 4'd0) ? 8'h4C :
                                       (byt == 4'd1) ? 8'h4A :
                                       (byt == 4'd2) ? 8'h4B : 8'h49;
                3'd3:    j2k_table_byte = (byt == 4'd0) ? 8'h4B :
                                       (byt == 4'd1) ? 8'h4A :
                                       (byt == 4'd2) ? 8'h4D : 8'h49;
                default: j2k_table_byte = (byt == 4'd0) ? 8'h15 :
                                       (byt == 4'd1) ? 8'h08 :
                                       (byt == 4'd2) ? 8'h5A : 8'h41;
            endcase
        end else begin
            // Both presets carry a Select layer (2026-10-27): holding
            // Select switches A/B to the secondary pair -
            //   preset 1: A/B = U/O,  +Select = Space/Return
            //   preset 2: A/B = Space/Return, +Select = Y/N
            // The old preset 3 ("U/O + Select") was absorbed into preset 1
            // and is gone from the option list; out-of-range values (3-7)
            // stay blank.
            case (btn)
                3'd0:    j2k_table_byte = 8'h00;
                3'd1:    j2k_table_byte = (byt == 4'd4)  ? 8'h55 :
                                       (byt == 4'd5)  ? 8'h4F :
                                       (byt == 4'd10) ? 8'h20 :
                                       (byt == 4'd11) ? 8'h0D : 8'h00;
                3'd2:    j2k_table_byte = (byt == 4'd4)  ? 8'h20 :
                                       (byt == 4'd5)  ? 8'h0D :
                                       (byt == 4'd10) ? 8'h59 :
                                       (byt == 4'd11) ? 8'h4E : 8'h00;
                default: j2k_table_byte = 8'h00;
            endcase
        end
    end
endfunction

wire [7:0] j2k_preset_byte = j2k_table_byte(j2k_ld_dir, j2k_ld_btn, j2k_cnt[3:0]);

// .a2k source: the latched file bytes, selected by table index.
// Byte i sits at bits [7i:7i+7] of the packed vector (a2k_map_p packs
// map[0] in the LEAST-significant byte, map[15] in the most).
reg [7:0] j2k_a2k_byte;
always @(*) begin
    case (j2k_cnt[3:0])
        4'd0:  j2k_a2k_byte = j2k_ld_a2k[7:0];
        4'd1:  j2k_a2k_byte = j2k_ld_a2k[15:8];
        4'd2:  j2k_a2k_byte = j2k_ld_a2k[23:16];
        4'd3:  j2k_a2k_byte = j2k_ld_a2k[31:24];
        4'd4:  j2k_a2k_byte = j2k_ld_a2k[39:32];
        4'd5:  j2k_a2k_byte = j2k_ld_a2k[47:40];
        4'd6:  j2k_a2k_byte = j2k_ld_a2k[55:48];
        4'd7:  j2k_a2k_byte = j2k_ld_a2k[63:56];
        4'd8:  j2k_a2k_byte = j2k_ld_a2k[71:64];
        4'd9:  j2k_a2k_byte = j2k_ld_a2k[79:72];
        4'd10: j2k_a2k_byte = j2k_ld_a2k[87:80];
        4'd11: j2k_a2k_byte = j2k_ld_a2k[95:88];
        4'd12: j2k_a2k_byte = j2k_ld_a2k[103:96];
        4'd13: j2k_a2k_byte = j2k_ld_a2k[111:104];
        4'd14: j2k_a2k_byte = j2k_ld_a2k[119:112];
        default: j2k_a2k_byte = j2k_ld_a2k[127:120];
    endcase
end
wire [7:0] j2k_byte = j2k_ld_a2k_present ? j2k_a2k_byte : j2k_preset_byte;

// Enable: off while the OSK is open (the face buttons are the OSK's then -
// the same ~osk_visible term the paddle path uses, so the two paths cannot
// disagree), and off while both presets are Off AND no .a2k file is
// present. A present file is itself the enable.
wire j2k_en = ~osk_visible & ((j2k_dir_m != 3'd0) | (j2k_btn_m != 3'd0) |
                              a2k_present_m);

wire [6:0] j2k_key_code;
wire       j2k_key_press;
joy_to_key j2k (
    .clk(clk_core_14318),
    .reset(machine_reset),
    .enable(j2k_en),
    .joy(joy_j2k),
    .shift(j2k_shift),
    .ioctl_download(j2k_busy),
    .ioctl_wr(j2k_busy),
    .ioctl_addr({20'd0, j2k_cnt}),
    .ioctl_data(j2k_byte),
    .ioctl_index(8'h03),
    .joy_key_code(j2k_key_code),
    .joy_key_press(j2k_key_press)
);

apple2 d1 (
    .CLK_14M(clk_core_14318), .CLK_2M(m_clk2m),
    .PALMODE(1'b0), .ROMSWITCH(1'b0), .CPU_WAIT(cpu_wait_hdd_m),
    .PHASE_ZERO(m_pz), .PHASE_ZERO_R(m_pzr), .PHASE_ZERO_F(m_pzf),
    .FLASH_CLK(blink_div[22]),
    .reset(machine_reset), .cpu(1'b1),
    .STALL(1'b0),
    .ADDR(m_addr), .ram_addr(m_ram_addr), .D(m_ram_di), .ram_do(m_ram_do),
    .aux(m_ram_aux), .PD(m_pd_mux), .CPU_WE(m_cpu_we),
    .IRQ_n(1'b1), .NMI_n(1'b1), .ram_we(m_ram_we),
    .VIDEO(m_video), .COLOR_LINE(m_col_line), .RUN_FILL_OK(m_run_fill_ok),
    .TEXT_MODE(m_text_mode), .EARLY_VIDEO(m_early_video), .HGR_MODE(m_hgr_mode),
    .HGR80_MODE(m_hgr80_mode), .GR2(m_gr2), .COL80(m_col80), .DHIRES_MODE(m_dhires),
    .HBL(m_hbl), .VBL(m_vbl),
    .K(m_K), .READ_KEY(m_read_key), .AKD(m_akd), .AN(m_an),
     .GAMEPORT({1'b0,1'b0,joyy,joyx,
                joy[7] & joy_enable,
                (joy[5] & joy_enable) | osk_closed_apple,
                (joy[4] & joy_enable) | osk_open_apple,
                1'b0}),
    .PDL_STROBE(m_pdl), .STB(m_stb),
    .IO_SELECT(m_io_sel), .DEVICE_SELECT(m_dev_sel), .IO_STROBE(m_io_str),
    .ioctl_addr(25'b0), .ioctl_data(8'b0), .ioctl_index(8'b0),
    .ioctl_download(1'b0), .ioctl_wr(1'b0), .saturn_5_inslot(1'b0),
    .speaker(m_spk),
    .DBG_T65_REGS(), .DBG_DI(), .DBG_ROM_ADDR(), .DBG_ROM_OUT(),
    .ss_addr(10'b0), .ss_wdata(64'b0), .ss_wren(1'b0), .ss_rdata(),
    .machine_ce(1'b1), .cpu_frozen(),
    .Z80_EN(1'b0), .Z80_A(16'b0), .Z80_DO(8'b0), .Z80_WE(1'b0), .CPU_DI()
);

// ---- Phase 2 streaming video: real machine + full-color OSK ----
// Replaces apf_video (frame buffer). Streams the OSK's composited 24-bit
// RGB (machine video + full-color OSK, with transparency) + the machine's
// native HBL/VBL directly to the APF DDR pad on the 14.318 MHz clock.
wire [23:0] apf_rgb;
wire        apf_de, apf_vs, apf_hs, apf_skip;
// DEC2X=0 (shipping): the proven 560-px native stream. Aspect/stretch
// options are pure video.json presets (see the core package). DEC2X=1
// (280-px 2:1 decimation) is the separate experiment - see the expert
// brief (EXPERT_BRIEF_PHASE2_280_SHIFT) for its fix status.
apf_stream_video #(.DEC2X(0)) apfv (
    .clk(clk_core_14318), .reset(machine_reset),
    .rgb_in(ovl_rgb), .hbl(sel_hbl), .vbl(sel_vbl),
    .video_rgb(apf_rgb), .video_de(apf_de), .video_vs(apf_vs),
    .video_hs(apf_hs), .video_skip(apf_skip)
);
assign video_rgb  = apf_rgb;
assign video_de   = apf_de;
assign video_vs   = apf_vs;
assign video_hs   = apf_hs;
assign video_skip = apf_skip;





//
// 555 speaker audio (speaker_i2s.v, 2026-10-26): box-averaged duty sample
// from the machine's 1-bit speaker + local DC blocker + 16-bit I2S framing.
// Replaces the previous silence generator (mclk/sclk generation is kept).
//

assign audio_mclk = audgen_mclk;
assign audio_dac = spk_dac;
assign audio_lrck = spk_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum;
    reg                 audgen_mclk;
    parameter   [20:0]  CYCLE_48KHZ = 21'd245760;  // 122880*2, written final (no 32->21 truncation warning)
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// 555 speaker -> I2S (module; m_spk is the machine-domain speaker bit)
    wire        spk_dac, spk_lrck;
    speaker_i2s u_spk_i2s (
        .clk_14m  ( clk_core_14318 ),
        .spk_bit  ( m_spk ),
        .mclk     ( audgen_mclk ),
        .sclk     ( audgen_sclk ),
        .lrck     ( spk_lrck ),
        .dac      ( spk_dac )
    );


///////////////////////////////////////////////


    wire    clk_core_12288;
    wire    clk_core_12288_90deg;
    wire    clk_core_14318;
    wire    clk_core_14318_90;   // 90-degree phase copy (APF DDR clock pad)
    wire    clk_core_3072;

    wire    pll_core_locked;
    wire    pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

// Phase 1 streaming-prototype PLL: 74.25 MHz -> 14.318 (0deg, APF pixel clock
// = native Apple II video clock) / 14.318 (90deg, APF DDR clock pad) /
// 3.072 (audio). The machine + OSK still run on clk_core_14318 in the
// background (harmless); the apf_stream_video drives the APF video directly.
apf_stream_proto_pll mp1 (
    .refclk         ( clk_74a ),
    .rst            ( pll_rst_pulse ),   // power-on pulse only; see above

    .outclk_0       ( clk_core_14318 ),
    .outclk_1       ( clk_core_14318_90 ),
    .outclk_2       ( clk_core_3072 ),

    .locked         ( pll_core_locked )
);

// ---- Floppy M0: external image storage (SDRAM) ---------------------------
// SDRAM image-storage path (M0 rework, Units 1-4) - see sdram_storage.v:
//   host (74.25) --bridge word write--> slot_fifo --(CDC)--> disk_store
//     --word port (133.12)--> io_sdram_pocket --> 64MiB DRAM
//   disk_verifier (machine domain) reads the image back through the same
//   word port (level handshakes; M0 protocol: load and verify phases never
//   overlap - M1 adds the machine fetcher under arbitration).
//   Machine reset does NOT reset this path: the resident image survives
//   host resets (only core power, sdram_path_rst, resets it).
wire        sdram_ctrl_clk;    // 133.12 MHz (io_sdram controller)
wire        sdram_chip_clk;    // 133.12 MHz (SDRAM chip, 180 deg phase)
wire        sdram_chip_clk_90; // 133.12 MHz (DDR capture, unused)
wire        sdram_pll_locked;

apple2e_sdram_pll mp2 (
    .refclk   ( clk_74a ),
    .rst      ( pll_rst_pulse ),
    .outclk_0 ( sdram_ctrl_clk ),
    .outclk_1 ( sdram_chip_clk ),
    .outclk_2 ( sdram_chip_clk_90 ),
    .locked   ( sdram_pll_locked )
);

// core-power reset for the storage path (74.25 domain; ~441 us at POR)
wire sdram_path_rst = pll_rst_pulse;

wire        stor_init_done, stor_load_drained, stor_busy, stor_timeout;
wire [23:0] stor_received, stor_committed;
wire        stor_ovf;
wire [6:0]  stor_hw;
wire [31:0] stor_diag_rd;
wire        stor_vdone, stor_vok, stor_vstuck;
wire [31:0] stor_crc, stor_first, stor_last, stor_nbytes_m;
wire [15:0] stor_vread;
wire        stor_timeout_m, stor_ovf_m;
// load/verify coordinator result (machine domain, for the overlay)
wire        stor_res_valid_m;
wire [1:0]  stor_res_code_m, stor_res_fail_m;
wire [31:0] stor_res_crc_m, stor_res_nbytes_m;
wire [127:0] stor_fp_first_m, stor_fp_last_m, stor_fp_w_m;   // image fingerprint (overlay)
wire        stor_new_load_m;   // proactive unmount pulse (0082 generation)
// debug counters to the overlay (machine domain)
wire [47:0] stor_dbg_rc_m;
synch_3 #(.WIDTH(48)) s_dbg_rc (.i({stor_received, stor_committed}),
                               .o(stor_dbg_rc_m), .clk(clk_core_14318));
// furthest storage stage (0..6) to the overlay marker (machine domain;
// sdram_storage syncs 74.25 -> machine internally, like res_*_m)
wire [2:0] stor_stage_m;
// M1 sector service (machine domain; Unit-3 transport <-> Unit-2 fetcher)
wire        stor_fetch_req, stor_fetch_busy, stor_sector_ready;
wire [15:0] stor_fetch_lba;
wire [15:0] stor_sector_lba;   // 2026-10-22: lba of the fetcher's published window
wire [8:0]  stor_sector_byte_addr;
wire [7:0]  stor_sector_byte_data;
wire        stor_sector_done, stor_fetch_fault;

// 0xF9xxxxxx diagnostics routing (config writes + debug reads)
wire f9_wr = bridge_wr && (bridge_addr[31:16] == 16'hF900);
wire f9_rd = bridge_rd && (bridge_addr[31:16] == 16'hF900);

// Image-fingerprint diagnostic (M1 hardware-load): default 0 = shipping
// build (no overlay lines, verifier fp logic trimmed). A debug build sets
// 1 to restore the always-on W0..W3/F/L overlay lines + verifier window
// CRCs (PC oracle: tools/woz_fingerprint.py).
parameter FP_DIAG = 1'b0;

// Full debug-overlay gate: 0 = shipping build (no MO/ACK/ST/HD=PC=DA= lines;
// the drive lamps remain - they are a shipping feature not gated here).
// 1 = hardware-debug build. Separate from FP_DIAG so a build can carry the
// verifier fp logic without drawing anything.
// 2026-11-02: set to 0 for the 0.3.0 shipping build - HDV bring-up is done
// (auto boot + lamps verified), so the post-reset diagnostics are off.
// 2026-11-03: set to 1 for the Step 0 stick-liveness probe (BRIEF_JOY_RELATIVE
// _MODE): the debug text (HD/PC/DA + the new JOY line) is visible so the owner
// can wiggle the stick and read the raw bytes. Revert to 1'b0 once the probe
// verdict is in (feature build) or for the shipping build.
parameter OVL_DEBUG = 1'b0;   // shipping (0.3.2): debug text/lines off; drive lamps stay (not OVL_DBG-gated)

// Debug-line visibility window in machine clocks (14.318 MHz). The debug
// lines (MT=/RD=, AC=/MO=, ST=/A=/F=, RQ=) are drawn only while this window
// is open after each machine reset. The previous hardwired 0x3FFFFF was
// ~0.29 s - far too short to photograph (the "4.7 s" comment was stale).
// Default 10 s: long enough to capture the boot/load diagnostics, then it
// clears (not "always on"). Widen for a diagnostic build, shorten for a
// tighter boot screen.
parameter [27:0] OVL_DBG_WIN_CYCLES = 28'd143_180_000;

sdram_storage #(.FP_EN(FP_DIAG)) stor (
    .clk_74a         ( clk_74a ),
    .sdram_path_rst  ( sdram_path_rst ),
    .bridge_wr       ( bridge_wr ),
    .bridge_addr     ( bridge_addr ),
    .bridge_wr_data  ( bridge_wr_data ),
    .init_done       ( stor_init_done ),
    .load_drained    ( stor_load_drained ),
    .store_busy      ( stor_busy ),
    .store_timeout   ( stor_timeout ),
    .words_received  ( stor_received ),
    .words_committed ( stor_committed ),
    .fifo_overflow   ( stor_ovf ),
    .fifo_high_water ( stor_hw ),
    .diag_addr       ( bridge_addr[15:0] ),
    .diag_rd         ( f9_rd ),
    .diag_rd_data    ( stor_diag_rd ),
    .diag_wr         ( f9_wr ),
    .diag_wr_sel     ( bridge_addr[7:4] ),
    .ds_requestwrite   ( dataslot_requestwrite ),
    .ds_requestwrite_id( dataslot_requestwrite_id ),
    .ds_requestwrite_size(dataslot_requestwrite_size),
    .ds_allcomplete    ( dataslot_allcomplete ),
    .timeout_override  ( 32'd0 ),          // fault-injection hook: disabled
    .clk_mach        ( clk_core_14318 ),
    .rst_n_mach      ( ~sdram_path_rst ),
    .ver_done        ( stor_vdone ),
    .ver_ok          ( stor_vok ),
    .ver_stuck       ( stor_vstuck ),
    .ver_crc32       ( stor_crc ),
    .ver_first_word  ( stor_first ),
    .ver_last_word   ( stor_last ),
    .ver_words_readout( stor_vread ),
    .n_bytes_m       ( stor_nbytes_m ),
    .store_timeout_m ( stor_timeout_m ),
    .fifo_overflow_m ( stor_ovf_m ),
    .res_valid_m     ( stor_res_valid_m ),
    .res_code_m      ( stor_res_code_m ),
    .res_fail_m      ( stor_res_fail_m ),
    .res_crc_m       ( stor_res_crc_m ),
    .res_nbytes_m    ( stor_res_nbytes_m ),
    .fp_first_m      ( stor_fp_first_m ),
    .fp_last_m       ( stor_fp_last_m ),
    .fp_w_m          ( stor_fp_w_m ),
    .new_load_m      ( stor_new_load_m ),
    .stage_m         ( stor_stage_m ),
    .fetch_req       ( stor_fetch_req ),
    .fetch_lba       ( stor_fetch_lba ),
    .fetch_busy      ( stor_fetch_busy ),
    .sector_ready    ( stor_sector_ready ),
    .sector_lba      ( stor_sector_lba ),
    .sector_byte_addr( stor_sector_byte_addr ),
    .sector_byte_data( stor_sector_byte_data ),
    .sector_done     ( stor_sector_done ),
    .fetch_fault     ( stor_fetch_fault ),
    .ctrl_clk        ( sdram_ctrl_clk ),
    .chip_clk        ( sdram_chip_clk ),
    .clk_90          ( sdram_chip_clk_90 ),
    .dram_a          ( dram_a ),
    .dram_ba         ( dram_ba ),
    .dram_dq         ( dram_dq ),
    .dram_dqm        ( dram_dqm ),
    .dram_clk        ( dram_clk ),
    .dram_cke        ( dram_cke ),
    .dram_ras_n      ( dram_ras_n ),
    .dram_cas_n      ( dram_cas_n ),
    .dram_we_n       ( dram_we_n )
);

// ---- Floppy M1: WOZ floppy machine (engine + transport + mount ctl) ----
// The byte-identical MiSTer WOZ engine (src/fpga/core/woz/, 6 files) runs
// in the 14.318 MHz machine domain. Single drive: drive 0 is served by the
// M0 SDRAM image through the Unit-3 transport; drive 1 is inactive
// (IMG_MOUNTED1=0, SD_ACK1=0, D2_WP=1). Write protection is hardwired on
// (D1_WP=D2_WP=1: the parser ignores IMG_READONLY; WP reaches the flux
// drive's write gate - expert correction C3).
//
//   WOZ engine <--> sdram_woz_transport (Unit 3) <--> sdram_sector_fetch
//   (14.318 MHz, per-byte 512 B block)      (Unit-2 frozen window)
//   woz_mount_ctl (Unit 4) turns the M0 coordinator result into
//   IMG_MOUNTED/IMG_SIZE (mount = rising edge; eject = zero-size event).
wire        m_cpu_we;    // apple2 CPU_WE (was unconnected)
wire [7:0]  woz_dout;    // engine D_OUT (ROM on IO_SELECT, data reg elsewhere)
wire        woz_sd_rd, woz_sd_wr;
wire [31:0] woz_sd_lba;
wire        woz_sd_ack;
wire [8:0]  woz_sd_buff_addr;
wire [7:0]  woz_sd_buff_dout, woz_sd_buff_din;
wire        woz_sd_buff_wr;
wire        woz_wr_fault, woz_oor_fault, woz_transport_fault;
wire        mc_img_mounted;
wire [63:0] mc_img_size;
wire [2:0]  mc_state;
// transport fault clear: a fresh mount starts clean (engine re-parse)
reg         mc_mounted_d;
always @(posedge clk_core_14318)
    mc_mounted_d <= mc_img_mounted;
wire        mc_mount_rise = mc_img_mounted && !mc_mounted_d;

// ---- "Reboot on disk change" (interact.json option, persisted) ----
// bridge(74.25) -> machine sync of the option bit, then the cold-reboot
// FSM: every LATER disk mount (the power-on mount is suppressed) resets
// the machine and sweeps its RAM to zero (~465 us when the option is ON).
wire        reboot_opt_m;
synch_3 #(.WIDTH(1)) u_reboot_opt_sync (
    .i(cfg_reboot_word[0]), .o(reboot_opt_m), .clk(clk_core_14318)
);
// OSK Reset release -> a cold reboot (so an OSK Reset is a true cold boot that
// runs the ROM slot-scan and can load the HD). Synchronize osk_cmd_reset to the
// 14.318 MHz machine clock, then take its falling edge (release). Not gated by
// reboot_opt: an explicit OSK Reset always cold-boots.
reg [1:0] osk_reset_s;
always @(posedge clk_core_14318) osk_reset_s <= {osk_reset_s[0], osk_cmd_reset};
wire osk_cold_req = ~osk_reset_s[0] & osk_reset_s[1];   // synchronized falling edge

// ---- HDV mount -> cold reboot, DEFERRED until the host has finished ----
// (2026-11-02, restored) Selecting an HDV in the picker only updates the
// 0x008A dataslot (hdv_size_q -> hdv_mounted_m); it does NOT reset the 6502, so
// the ROM never re-scans and the HDV won't boot until a machine reset. OSK
// Reset does exactly that reset and reliably boots the HDV - so we reproduce it
// here on the HDV mount edge. The first attempt (1917) fired on the raw edge,
// MID-way through the host's select handshake, and left a black idle screen;
// the fix is to wait HDV_REBOOT_SETTLE after the edge so the host completes
// arming the HD first, then run the same cold reset OSK Reset uses.
reg  hdv_mounted_d;
always @(posedge clk_core_14318)
    hdv_mounted_d <= hdv_mounted_m;
wire hdv_mount_rise = hdv_mounted_m && !hdv_mounted_d;

// Settle: latch the mount edge, count HDV_REBOOT_SETTLE, then emit one pulse.
localparam [23:0] HDV_REBOOT_SETTLE = 24'd29000000;   // ~203 ms @ 143.18 MHz
reg  [23:0] hdv_settle_cnt;
reg         hdv_settle_pend;
always @(posedge clk_core_14318 or posedge machine_reset_base) begin
    if (machine_reset_base) begin
        hdv_settle_cnt  <= 24'd0;
        hdv_settle_pend <= 1'b0;
    end else if (hdv_mount_rise && !hdv_settle_pend) begin
        hdv_settle_pend <= 1'b1;
        hdv_settle_cnt  <= 24'd0;
    end else if (hdv_settle_pend) begin
        if (hdv_settle_cnt == (HDV_REBOOT_SETTLE - 24'd1))
            hdv_settle_pend <= 1'b0;   // -> next cycle hdv_reboot_req pulses
        else
            hdv_settle_cnt <= hdv_settle_cnt + 24'd1;
    end
end
wire hdv_reboot_req = hdv_settle_pend && (hdv_settle_cnt == (HDV_REBOOT_SETTLE - 24'd1));

// Power-on blanking: ignore every mount edge inside a short window after reset
// release (the framework's initial WOZ + HDV load), and pre-arm reboot_ctl's
// `ever` with a synthetic one-cycle rise at the window start (inert - reboot_ctl
// excludes first_rise from rebooting). So the FIRST REAL change after the window
// still reboots, but the power-on double-mount does not.
localparam [24:0] MOUNT_BLANK_MAX = 25'd25000000;    // ~175 ms @ 143.18 MHz
reg [24:0] blank_cnt;
reg        blank_done;
always @(posedge clk_core_14318 or posedge machine_reset_base) begin
    if (machine_reset_base) begin          // active-HIGH (see :621)
        blank_cnt  <= 25'd0;
        blank_done <= 1'b0;
    end else if (!blank_done) begin
        if (blank_cnt == (MOUNT_BLANK_MAX - 25'd1))
            blank_done <= 1'b1;
        else
            blank_cnt <= blank_cnt + 25'd1;
    end
end
wire        blank_arm     = !blank_done && (blank_cnt == 25'd0);
wire        mount_rise_any = blank_arm |
                             (((mc_mount_rise | hdv_reboot_req) & blank_done));

reboot_ctl woz_reboot (
    .clk         ( clk_core_14318 ),
    .rst         ( machine_reset_base ),
    .reboot_opt  ( reboot_opt_m ),
    .mount_rise  ( mount_rise_any ),   // WOZ immediate, HDV deferred, post-blanking
    .clr_done    ( swp_done ),
    .osk_cold_req( osk_cold_req ),
    .cold_reset  ( cold_reset_m ),
    .ram_clear   ( ram_clear_m )
);
// slot-qualified PD mux (C9): the disk slot is $C0E0-$C0EF (device select)
// plus the Disk II ROM at $C600-$C6FF (IO select); D_OUT is already gated
// internally (rom vs data register) - the mux only selects the slot.
// The HDV (slot 7: $C700-$C7FF ROM + $C0F0-$C0FF registers, the AppleWin
// HDD interface layout used by MiSTer) takes priority - its address
// ranges never overlap the disk slot's, so the ordering is only for form.
// Slot 7 presence gate: the Boot Media option's Floppy entry takes the HD
// card off the bus entirely (C7xx reads return the empty-slot value 0x00,
// the hdd instance is deselected) so the ROM slot-scan signature check
// (C701=$20, C703=$00, C705=$03) never matches and falls through to the
// slot-6 WOZ floppy. For Both/HDD (hd_off_m=0) the wiring is bit-identical
// to the pre-gate form.
wire sel7_live = (m_dev_sel[7] | m_io_sel[7]) & ~hd_off_m;
wire [7:0]  m_pd_mux = sel7_live ? hdd_dout :
                       (m_dev_sel[6] | m_io_sel[6]) ? woz_dout : 8'h00;

disk_ii_woz woz (
    .CLK_14M         ( clk_core_14318 ),
    .RESET           ( machine_reset ),
    .DD_RESET        ( machine_reset ),
    .PHASE_ZERO      ( m_pz ),
    .IO_SELECT       ( m_io_sel[6] ),
    .DEVICE_SELECT   ( m_dev_sel[6] ),
    .WE              ( m_cpu_we ),
    .A               ( m_addr ),
    .D_IN            ( m_ram_di ),
    .D_OUT           ( woz_dout ),
    .D1_ACTIVE       ( drv_active ), .D2_ACTIVE ( ),
    .D1_MOTOR_ON     ( drv_motor ), .D2_MOTOR_ON ( ),
    .D1_STEP         ( ), .D2_STEP ( ),
    .D1_TRACK0       ( ), .D2_TRACK0 ( ),
    .D1_IO           ( ), .D2_IO ( ),
    .D1_WP           ( 1'b1 ), .D2_WP ( 1'b1 ),
    .SD_LBA0         ( woz_sd_lba ),
    .SD_RD0          ( woz_sd_rd ),
    .SD_WR0          ( woz_sd_wr ),
    .SD_ACK0         ( woz_sd_ack ),
    .SD_BUFF_DIN0    ( woz_sd_buff_din ),
    .SD_LBA1         ( ), .SD_RD1 ( ), .SD_WR1 ( ),
    .SD_ACK1         ( 1'b0 ),
    .SD_BUFF_DIN1    ( ),
    .SD_BUFF_ADDR    ( woz_sd_buff_addr ),
    .SD_BUFF_DOUT    ( woz_sd_buff_dout ),
    .SD_BUFF_WR      ( woz_sd_buff_wr ),
    .IMG_MOUNTED0    ( mc_img_mounted ),
    .IMG_MOUNTED1    ( 1'b0 ),
    .IMG_READONLY    ( 1'b1 ),
    .IMG_SIZE        ( mc_img_size )
);

sdram_woz_transport woz_tr (
    .clk            ( clk_core_14318 ),
    .rst_n          ( ~sdram_path_rst ),
    .sd_rd          ( woz_sd_rd ),
    .sd_lba         ( woz_sd_lba ),
    .sd_ack         ( woz_sd_ack ),
    .sd_wr          ( woz_sd_wr ),
    .sd_buff_addr   ( woz_sd_buff_addr ),
    .sd_buff_din    ( woz_sd_buff_din ),
    .sd_buff_wr     ( woz_sd_buff_wr ),
    .sd_buff_dout   ( woz_sd_buff_dout ),
    .fetch_req      ( stor_fetch_req ),
    .fetch_lba      ( stor_fetch_lba ),
    .fetch_busy     ( stor_fetch_busy ),
    .sector_ready   ( stor_sector_ready ),
    .sector_lba     ( stor_sector_lba ),
    .sector_byte_data( stor_sector_byte_data ),
    .fetch_fault    ( stor_fetch_fault ),
    .sector_byte_addr( stor_sector_byte_addr ),
    .sector_done    ( stor_sector_done ),
    .drive_active   ( mc_img_mounted ),
    .fault_clr      ( mc_mount_rise ),
    .wr_fault       ( woz_wr_fault ),
    .oor_fault      ( woz_oor_fault ),
    .transport_fault( woz_transport_fault )
);

woz_mount_ctl woz_mc (
    .clk             ( clk_core_14318 ),
    .por_n           ( ~sdram_path_rst ),
    .res_valid_m     ( stor_res_valid_m ),
    .res_code_m      ( stor_res_code_m ),
    .res_nbytes_m    ( stor_res_nbytes_m ),
    .new_load_m      ( stor_new_load_m ),
    .transport_fault ( woz_transport_fault ),
    .eject_req       ( media_m[1] ),
    .img_mounted     ( mc_img_mounted ),
    .img_size        ( mc_img_size ),
    .img_readonly    ( ),
    .mount_state_m   ( mc_state )
);

// ----------------------------------------------------------------------
// HDV (read-only HD, PLAN_HDV_READONLY): hdd controller + bridge transfer
// ----------------------------------------------------------------------
// hdd (14M domain): the AppleWin ProDOS HDD interface, cycle-exact port of
// Apple-II_MiSTer rtl/hdd.vhd (differential proof: verilog/hdd_equivalence).
// Slot 7 per the machine decoder: $C0F0-$C0FF registers (devselect[7]) +
// $C700-$C7FF ROM (ioselect[7]) - the same layout MiSTer uses.
//
// hdv_bridge (74a + 14M domains): the hardwired sector mover (PLAN §4c).
// hdd pulses hdd_read/hdd_write on C0F0 execute; the bridge FSM arms
// 0x0180/0x0184 against the deferload HDV slot (id 2), stalls the 6502 via
// CPU_WAIT for the whole transfer, and walks the 512-byte sector buffer.
// Read-only milestone: hdd_protect=1, so hdd_write never fires (C0F0
// WRITE returns 0x2B PROTECT) and the 0x0184 arm stays inert.
wire        hdd_read, hdd_write;
wire [7:0]  hdd_dout;
wire [15:0] hdd_sector;
wire [8:0]  hdd_ram_addr;
wire [7:0]  hdd_ram_di, hdd_ram_do;
wire        hdd_ram_we;
wire        cpu_wait_hdd;
wire [31:0] hdv_ram_word;   // bridge readback window 0x01F01000-00F
wire [2:0]  hdv_state;
wire        hdv_fault;
wire [7:0]  hdv_fetch_cnt;
wire        bridge_err_74;   // bridge drop/timeout fault pulse (74a)
wire        bridge_err_m;    // 2FF-synced to the machine domain for hdd
synch_3 #(.WIDTH(1)) u_bridge_err_sync (
    .i(bridge_err_74), .o(bridge_err_m), .clk(clk_core_14318), .rise(), .fall()
);

hdd u_hdd (
    .CLK_14M        ( clk_core_14318 ),
    // Boot Media = Floppy takes the whole card off the bus - including the
    // WRITE path (C0F0/C0F2/C0F3 writes must not arm a 0x0180 fetch while
    // the ROM believes slot 7 is empty; the read mux alone is not enough).
    .IO_SELECT      ( m_io_sel[7] & ~hd_off_m ),
    .DEVICE_SELECT  ( m_dev_sel[7] & ~hd_off_m ),
    .RESET          ( machine_reset ),
    .A              ( m_addr ),
    .RD             ( ~m_cpu_we ),
    .D_IN           ( m_ram_di ),
    .D_OUT          ( hdd_dout ),
    .sector         ( hdd_sector ),
    .hdd_read       ( hdd_read ),
    .hdd_write      ( hdd_write ),
    .hdd_mounted    ( hdv_mounted_m ),
    .hdd_protect    ( 1'b1 ),
    .bridge_fault   ( bridge_err_m ),
    .ram_addr       ( hdd_ram_addr ),
    .ram_di         ( hdd_ram_di ),
    .ram_do         ( hdd_ram_do ),
    .ram_we         ( hdd_ram_we )
);

hdv_bridge u_hdv_bridge (
    .clk_74a        ( clk_74a ),
    .clk_14a        ( clk_core_14318 ),
    .reset_n        ( reset_n ),
    .bridge_wr      ( bridge_wr ),
    .bridge_addr    ( bridge_addr ),
    .bridge_wr_data ( bridge_wr_data ),
    .hdv_ram_word   ( hdv_ram_word ),
    .target_dataslot_read   ( target_dataslot_read ),
    .target_dataslot_write  ( target_dataslot_write ),
    .target_dataslot_done   ( target_dataslot_done ),
    .target_dataslot_err    ( target_dataslot_err ),
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
    .hdv_mounted    ( hdv_mounted_74 ),
    .hdv_protect    ( 1'b1 ),
    .hdd_ram_addr   ( hdd_ram_addr ),
    .hdd_ram_di     ( hdd_ram_di ),
    .hdd_ram_do     ( hdd_ram_do ),
    .hdd_ram_we     ( hdd_ram_we ),
    .hdd_read       ( hdd_read ),
    .hdd_write      ( hdd_write ),
    .hdd_sector     ( hdd_sector ),
    .cpu_wait_hdd   ( cpu_wait_hdd ),
    .hdv_state      ( hdv_state ),
    .hdv_fault      ( hdv_fault ),
    .hdv_fetch_cnt  ( hdv_fetch_cnt ),
    .bridge_err     ( bridge_err_74 )
);

// CPU_WAIT (active-high = stall the 6502) for the whole HDV transfer
wire        cpu_wait_hdd_m;
synch_3 #(.WIDTH(1)) u_hdd_wait_sync (
    .i(cpu_wait_hdd), .o(cpu_wait_hdd_m), .clk(clk_core_14318), .rise(), .fall()
);

// HDV bridge diagnostics for the on-screen debug line (74a -> 14M):
// {cpu stalled now, fetch/write timeout fault, FSM state, last host err,
// completed-fetch count}. The 10 s window renders it as
// "HD=S F=F E=E N=NN M=M" (see sdram_status_overlay.v). Bit[15] is the
// HDV MOUNTED state (hdv_size_q != 0) - the decisive 2026-11-02 hardware
// diagnostic: N=0+F=0+E=0+M=0 => every fetch dropped as not-mounted;
// N=0+M=1 => the driver never armed a 0x0180 at all.
wire [15:0] hd_dbg_74 = {hdv_mounted_74, hdv_fault, hdv_state,
                         target_dataslot_err, hdv_fetch_cnt};
wire [15:0] hd_dbg_m;
synch_3 #(.WIDTH(16)) u_hd_dbg_sync (
    .i(hd_dbg_74), .o(hd_dbg_m), .clk(clk_core_14318), .rise(), .fall()
);

// PC snapshot (2026-11-02 hardware slowness diagnostic): the 6502 crawls
// (~1 HD block / 30 s) and sits on the Apple logo. Capture the program
// counter on the fetch phase (PHASE_ZERO) so the overlay can show where the
// CPU is sitting. m_addr is the CPU address bus (PC on fetch, data address
// on access); gating on m_pz isolates the PC. Same machine clock as the
// overlay - no CDC needed.
reg  [15:0] pc_snap_m;
always @(posedge clk_core_14318) begin
    if (m_pz)
        pc_snap_m <= m_addr;
end

// DATA-address snapshot (2026-11-02): the PC flickers between two states = a
// tight two-address loop, i.e. a soft-switch polling loop. Capture m_addr on
// the ACCESS phase (!PHASE_ZERO) - that is the data address the 6502 is
// reading/writing. If the loop polls a soft switch, this sits steady on that
// C0xx address and identifies exactly which switch never changes on the FPGA.
reg  [15:0] da_snap_m;
always @(posedge clk_core_14318) begin
    if (!m_pz)
        da_snap_m <= m_addr;
end

// ---- drive-activity diagnostics (M1 no-boot: where is it stuck?) ----
wire        drv_active;            // engine D1_ACTIVE (selected-drive motor)
wire        drv_motor;             // engine D1_MOTOR_ON (controller command)
reg  [23:0] drv_reads;             // cumulative sd_buff_wr bytes (saturating)
always @(posedge clk_core_14318 or posedge machine_reset) begin
    if (machine_reset)
        drv_reads <= 24'd0;
    else if (drv_reads != 24'hFFFFF)
        drv_reads <= woz_sd_buff_wr ? drv_reads + 24'd1 : drv_reads;
end

// ---- on-screen diagnostic (temporary, M0 only) ----
wire [23:0] ovl_rgb;
// J11 (2026-10-25): overlay visibility = a fixed window after each machine
// reset, re-arming on every reset including "Reboot on disk change" cold
// reboots. Window length is now the OVL_DBG_WIN_CYCLES parameter (default
// 10 s - the old hardwired 0x3FFFFF was ~0.29 s, too short to photograph;
// the "4.7 s" comment that preceded it was already stale). The owner can
// shorten it if the boot screen feels "always on".
// Machine-domain only - no bridge read-back (J7/J9 two-line mystery).
// 0.2.6: the OSK-visible escape hatch (J11: "keyboard open shows diagnostics
// at any time") is REMOVED per owner request - while the on-screen keyboard
// is open the screen belongs to the keyboard; the same diagnostics remain
// available in the 0xF9xxxxxx bridge debug reads.
reg  [27:0] dbg_win_cnt = 28'd0;
always @(posedge clk_core_14318)
    if (machine_reset) dbg_win_cnt <= 28'd0;
    else if (dbg_win_cnt != OVL_DBG_WIN_CYCLES) dbg_win_cnt <= dbg_win_cnt + 28'd1;
wire        ovl_debug_en = (dbg_win_cnt != OVL_DBG_WIN_CYCLES);

sdram_status_overlay #(.SHOW_FP(FP_DIAG), .OVL_DBG(OVL_DEBUG)) ovl (
    .clk(clk_core_14318), .reset(machine_reset),
    // sel_* (NTSC): RGB and its own blanking travel together - the overlay must
    // be positioned by the same blanking that produced the pixels.
    // debug_en (main, J11): overlay visibility = OSK visible OR the OVL_DBG_WIN_CYCLES post-reset window.
    .rgb_in(osk_rgb24), .hbl(sel_hbl), .vbl(sel_vbl),
    .debug_en(ovl_debug_en),
    .rgb_out(ovl_rgb),
    .res_valid_m(stor_res_valid_m), .res_code_m(stor_res_code_m),
    .res_fail_m(stor_res_fail_m), .res_crc_m(stor_res_crc_m),
    .res_nbytes_m(stor_res_nbytes_m),
    // image fingerprint (lines 8-11, shown only when FP_DIAG=1; last latched verify pass)
    .fp_first(stor_fp_first_m), .fp_last(stor_fp_last_m),
    .fp_w(stor_fp_w_m),
    .dbg_rc_m(stor_dbg_rc_m),
    // bit2=S(verifier stuck), bit1=T(store timeout), bit0=O(FIFO overflow) -
    // the overlay's interpretation; an earlier revision had O and S swapped
    .dbg_fl_m({stor_vstuck, stor_timeout_m, stor_ovf_m}),
    .stage_m(stor_stage_m),
    .drv_mounted(mc_img_mounted),
    .drv_active(drv_active),
    .drv_motor(drv_motor),
    .drv_reads(drv_reads),
    .drv_mstate(mc_state),
    .drv_ack(woz_sd_ack),
    .drv_tfault(woz_transport_fault),
    .drv_rdreq(woz_sd_rd),
    .hd_dbg_m(hd_dbg_m),
    .pc_dbg(pc_snap_m),
    .da_dbg(da_snap_m),
    // Step 0 stick-liveness probe: raw synced left-stick bytes + ever-moved latch
    .joy_x_dbg(cont1_joy_m[7:0]),
    .joy_y_dbg(cont1_joy_m[15:8]),
    .joy_ever(joy_ever_m)
);


    
endmodule
