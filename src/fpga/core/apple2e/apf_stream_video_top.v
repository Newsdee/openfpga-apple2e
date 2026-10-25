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
    32'h01F0xxxx: begin
        // TEMP DISK-BISECT (2026-10-25): exact 09:26 wildcard (pre-fix).
        // The fixed build decodes 0x01F00000/0x01F00004 individually (the
        // wildcard clobbered the Joystick persist entry on every quit).
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

    reg             target_dataslot_read;       
    reg             target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id;
    reg     [31:0]  target_dataslot_slotoffset;
    reg     [31:0]  target_dataslot_bridgeaddr;
    reg     [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
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
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
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

// Fixed configuration per plan section 4 (owner decisions 2026-10-24):
// exactly TWO user-facing knobs exist (SCREEN_MODE, comp_preset) and v1 ships
// both as constants. Everything else is hardwired and must NOT be exposed:
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
    .SCREEN_MODE        (2'b00),        // Colour
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
    .comp_preset        (2'd0),         // Calibrated
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
    .osk_visible(osk_visible)
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
joystick_input #(.RELATIVE_UPDATE_CYCLES(71591)) u_joy (
    .clk(joy_clk),
    .reset(machine_reset),
    .joystick_digital(joy_dig),
    .joystick_analog(16'h0),
    .paddle(8'h0),
    .swap_axes(1'b0),
    .paddle_as_x(1'b0),
    .paddle_as_y(1'b0),
    .x_center(3'd0),
    .relative_mode(1'b0),   // J10: hardwired Absolute (mode option removed)
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

apple2 d1 (
    .CLK_14M(clk_core_14318), .CLK_2M(m_clk2m),
    .PALMODE(1'b0), .ROMSWITCH(1'b0), .CPU_WAIT(1'b0),
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
// audio i2s silence generator
// see other examples for actual audio generation
//

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

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
    reg         audgen_lrck_1;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S 
// 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
//
    reg     [4:0]   audgen_lrck_cnt;    
    reg             audgen_lrck;
    reg             audgen_dac;
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;
        
    end 
end


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

// Full debug-overlay gate: 0 = shipping build (the status overlay is a
// pixel pass-through - no MO/ACK/ST lines, show window, marker, or
// fingerprint rows). 1 = hardware-debug build. Separate from FP_DIAG so a
// build can carry the verifier fp logic without drawing anything.
// TEMP DISK-BISECT (2026-10-25): forced 1 so the failing bitstream's load
// chain is readable on the Pocket screen (badge + MT/RD/AC/MO). Draw-only
// (video chain; no disk-path logic) so the bisect verdict stands. Replaced
// by the runtime "Debug" interact option in the follow-up compile (J9).
parameter OVL_DEBUG = 1'b1;

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
reboot_ctl woz_reboot (
    .clk         ( clk_core_14318 ),
    .rst         ( machine_reset_base ),
    .reboot_opt  ( reboot_opt_m ),
    .mount_rise  ( mc_mount_rise ),
    .clr_done    ( swp_done ),
    .cold_reset  ( cold_reset_m ),
    .ram_clear   ( ram_clear_m )
);
// slot-qualified PD mux (C9): the disk slot is $C0E0-$C0EF (device select)
// plus the Disk II ROM at $C600-$C6FF (IO select); D_OUT is already gated
// internally (rom vs data register) - the mux only selects the slot.
wire [7:0]  m_pd_mux = (m_dev_sel[6] | m_io_sel[6]) ? woz_dout : 8'h00;

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
    .img_mounted     ( mc_img_mounted ),
    .img_size        ( mc_img_size ),
    .img_readonly    ( ),
    .mount_state_m   ( mc_state )
);

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
// J11 (2026-10-25): overlay visibility = OSK visible OR ~4.7 s after each
// machine reset (2026-10-25 rev2: shortened from ~9.4 s - owner found the
// longer window "always on" in practice). The boot window covers the
// disk-load/verify diagnostics (they happen while the keyboard is closed)
// and re-arms on every reset, including the "Reboot on disk change" cold
// reboots. Machine-domain only - no bridge read-back (J7/J9 two-line
// mystery). Keyboard open (Start) shows diagnostics at any time.
reg  [25:0] dbg_win_cnt = 26'd0;
always @(posedge clk_core_14318)
    if (machine_reset) dbg_win_cnt <= 26'd0;
    else if (dbg_win_cnt != 26'h3FFFFF) dbg_win_cnt <= dbg_win_cnt + 26'd1;
wire        ovl_debug_en = osk_visible | (dbg_win_cnt != 26'h3FFFFF);

sdram_status_overlay #(.SHOW_FP(FP_DIAG), .OVL_DBG(OVL_DEBUG)) ovl (
    .clk(clk_core_14318), .reset(machine_reset),
    // sel_* (NTSC): RGB and its own blanking travel together - the overlay must
    // be positioned by the same blanking that produced the pixels.
    // debug_en (main, J11): overlay visibility = OSK visible OR ~4.7 s post-reset.
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
    .drv_rdreq(woz_sd_rd)
);


    
endmodule
