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

// PLL lock, synchronized into the 14.318 domain: the machine must not
// leave reset until clk_core_14318 is valid (locked = 1).
reg [1:0] lock_sync;
always @(posedge clk_core_14318) begin
    lock_sync <= {lock_sync[0], pll_core_locked};
end
wire machine_reset = ~rst_sync[1] | ~lock_sync[1] | osk_cmd_reset;
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
reg  [7:0]  ram_main [0:65535];
reg  [7:0]  ram_aux  [0:65535];
reg  [15:0] m_ram_do;
wire [15:0] m_addr;
wire [17:0] m_ram_addr;
wire [7:0]  m_ram_di;
wire        m_ram_aux;
wire        m_ram_we;
always @(posedge clk_core_14318) begin
    if (m_ram_we & ~m_ram_aux) begin
        ram_main[m_ram_addr[15:0]] <= m_ram_di;
        m_ram_do[7:0]              <= m_ram_di;
    end else m_ram_do[7:0]  <= ram_main[m_ram_addr[15:0]];
    if (m_ram_we & m_ram_aux) begin
        ram_aux[m_ram_addr[15:0]] <= m_ram_di;
        m_ram_do[15:8]            <= m_ram_di;
    end else m_ram_do[15:8]  <= ram_aux[m_ram_addr[15:0]];
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

// ---- OSK (buttons -> keystrokes; overlay over the native video) ----
wire        osk_video;
wire [23:0] osk_rgb24;
wire        osk_cmd_reset;
wire        osk_open_apple, osk_closed_apple;
apple2e_osk osk (
    .clk(clk_core_14318),
    .reset(osk_reset),
    .cont1_key(cont1_key),
    .video_in(m_video),
    .hblank(m_hbl),
    .vblank(m_vbl),
    .video_out(osk_video),
    .video_rgb24(osk_rgb24),
    .K(m_K),
    .reads(m_read_key),
    .akd(m_akd),
    .open_apple(osk_open_apple),
    .closed_apple(osk_closed_apple),
    .command_reset(osk_cmd_reset)
);

apple2 d1 (
    .CLK_14M(clk_core_14318), .CLK_2M(m_clk2m),
    .PALMODE(1'b0), .ROMSWITCH(1'b0), .CPU_WAIT(1'b0),
    .PHASE_ZERO(m_pz), .PHASE_ZERO_R(m_pzr), .PHASE_ZERO_F(m_pzf),
    .FLASH_CLK(blink_div[22]),
    .reset(machine_reset), .cpu(1'b1),
    .STALL(1'b0),
    .ADDR(m_addr), .ram_addr(m_ram_addr), .D(m_ram_di), .ram_do(m_ram_do),
    .aux(m_ram_aux), .PD(8'h00), .CPU_WE(),
    .IRQ_n(1'b1), .NMI_n(1'b1), .ram_we(m_ram_we),
    .VIDEO(m_video), .COLOR_LINE(m_col_line), .RUN_FILL_OK(m_run_fill_ok),
    .TEXT_MODE(m_text_mode), .EARLY_VIDEO(m_early_video), .HGR_MODE(m_hgr_mode),
    .HGR80_MODE(m_hgr80_mode), .GR2(m_gr2), .COL80(m_col80), .DHIRES_MODE(m_dhires),
    .HBL(m_hbl), .VBL(m_vbl),
    .K(m_K), .READ_KEY(m_read_key), .AKD(m_akd), .AN(m_an),
     .GAMEPORT({2'b00,1'b0,1'b0,1'b0,osk_closed_apple,osk_open_apple,1'b0}),
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
    .rgb_in(ovl_rgb), .hbl(m_hbl), .vbl(m_vbl),
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
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
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
// debug counters to the overlay (machine domain)
wire [47:0] stor_dbg_rc_m;
synch_3 #(.WIDTH(48)) s_dbg_rc({stor_received, stor_committed},
                              stor_dbg_rc_m, clk_core_14318, , );
// furthest storage stage (0..6) to the overlay marker (machine domain;
// sdram_storage syncs 74.25 -> machine internally, like res_*_m)
wire [2:0] stor_stage_m;

// 0xF9xxxxxx diagnostics routing (config writes + debug reads)
wire f9_wr = bridge_wr && (bridge_addr[31:16] == 16'hF900);
wire f9_rd = bridge_rd && (bridge_addr[31:16] == 16'hF900);

sdram_storage stor (
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
    .stage_m         ( stor_stage_m ),
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

// ---- on-screen diagnostic (temporary, M0 only) ----
wire [23:0] ovl_rgb;
sdram_status_overlay ovl (
    .clk(clk_core_14318), .reset(machine_reset),
    .rgb_in(osk_rgb24), .hbl(m_hbl), .vbl(m_vbl),
    .rgb_out(ovl_rgb),
    .res_valid_m(stor_res_valid_m), .res_code_m(stor_res_code_m),
    .res_fail_m(stor_res_fail_m), .res_crc_m(stor_res_crc_m),
    .res_nbytes_m(stor_res_nbytes_m),
    .dbg_rc_m(stor_dbg_rc_m),
    // bit2=S(verifier stuck), bit1=T(store timeout), bit0=O(FIFO overflow) -
    // the overlay's interpretation; an earlier revision had O and S swapped
    .dbg_fl_m({stor_vstuck, stor_timeout_m, stor_ovf_m}),
    .stage_m(stor_stage_m)
);


    
endmodule
