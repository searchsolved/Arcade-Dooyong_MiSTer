//============================================================================
//  Dooyong (Flying Tiger, Blue Hawk, Sadari, Gun Dealer '94, ...) for MiSTer
//  - framework shell (M4)
//
//  Wraps rtl/dy_board.sv (CPUs, video, sound, SDRAM, download) in the
//  Template_MiSTer `emu` interface. The MRA selects the game with the
//  index-1 game ID byte and streams the SDRAM image on index 0
//  (tools/make_mra.py). The vertical games are rotated through the
//  framework's screen_rotate (DDR3 frame buffer, MISTER_FB=1).
//
//  Clocks: 96 MHz system (8 MHz CPU / pixel enables = /12), a -90 degree
//  copy for SDRAM_CLK, and 48 MHz for the video path (arcade_video's HQ2x
//  does not close timing at 96 MHz), all from pll.v.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign BUTTONS = 0;
assign VGA_F1 = 1'b0;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;
assign FB_FORCE_BLANK = 1'b0;
assign AUDIO_MIX = 2'b00;

// ---------------------------------------------------------------------------
// clocks
// ---------------------------------------------------------------------------
wire clk_sys, clk_sdram, clk_vid, pll_locked;
pll pll (
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),      // 96 MHz
	.outclk_1(clk_sdram),    // 96 MHz, -90 degrees
	.outclk_2(clk_vid),      // 48 MHz, phase aligned with clk_sys
	.locked(pll_locked)
);
assign SDRAM_CLK = clk_sdram;

// ---------------------------------------------------------------------------
// hps_io
// ---------------------------------------------------------------------------
`include "build_id.v"
localparam CONF_STR = {
	"Dooyong;;",
	"-;",
	"H0OMN,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H0O2,Orientation,Vertical,Horizontal;",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Start,Coin,Service,Button 3;",
	"jn,A,B,Start,Select,L,X;",
	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;
wire [21:0] gamma_bus;
wire        video_rotated;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;

wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

// ---------------------------------------------------------------------------
// keyboard, MAME default keys (ps2_key: [10] toggles per event, [9] pressed,
// [8] extended, [7:0] set-2 scancode)
//   P1: arrows, LCtrl = B1, LAlt/Space = B2, LShift = B3, 1 = Start,
//       5 = Coin, 9 = Service
//   P2: R/F/D/G, A = B1, S = B2, Q = B3, 2 = Start, 6 = Coin
// ---------------------------------------------------------------------------
reg k_up, k_dn, k_lt, k_rt, k_b1, k_b2, k_b2b, k_b3, k_st1, k_co1, k_svc;
reg k2_up, k2_dn, k2_lt, k2_rt, k2_b1, k2_b2, k2_b3, k_st2, k_co2;
reg ps2_last = 1'b0;
always @(posedge clk_sys) begin
	ps2_last <= ps2_key[10];
	if (ps2_key[10] != ps2_last) begin
		case ({ps2_key[8], ps2_key[7:0]})
			9'h175: k_up  <= ps2_key[9];
			9'h172: k_dn  <= ps2_key[9];
			9'h16B: k_lt  <= ps2_key[9];
			9'h174: k_rt  <= ps2_key[9];
			9'h014: k_b1  <= ps2_key[9];   // left ctrl
			9'h011: k_b2  <= ps2_key[9];   // left alt
			9'h029: k_b2b <= ps2_key[9];   // space
			9'h012: k_b3  <= ps2_key[9];   // left shift
			9'h016: k_st1 <= ps2_key[9];   // 1
			9'h01E: k_st2 <= ps2_key[9];   // 2
			9'h02E: k_co1 <= ps2_key[9];   // 5
			9'h036: k_co2 <= ps2_key[9];   // 6
			9'h046: k_svc <= ps2_key[9];   // 9
			9'h02D: k2_up <= ps2_key[9];   // R
			9'h02B: k2_dn <= ps2_key[9];   // F
			9'h023: k2_lt <= ps2_key[9];   // D
			9'h034: k2_rt <= ps2_key[9];   // G
			9'h01C: k2_b1 <= ps2_key[9];   // A
			9'h01B: k2_b2 <= ps2_key[9];   // S
			9'h015: k2_b3 <= ps2_key[9];   // Q
			default: ;
		endcase
	end
end
// joystick layout: 0 R, 1 L, 2 D, 3 U, 4 B1, 5 B2, 6 Start, 7 Coin, 8 Service,
// 9 B3
wire [9:0] joy0 = joystick_0[9:0] | {k_b3, k_svc, k_co1, k_st1, k_b2 | k_b2b, k_b1, k_up, k_dn, k_lt, k_rt};
wire [9:0] joy1 = joystick_1[9:0] | {k2_b3, 1'b0, k_co2, k_st2, k2_b2, k2_b1, k2_up, k2_dn, k2_lt, k2_rt};

// ---------------------------------------------------------------------------
// inputs, active low (spec 9.2). MiSTer joystick: 0 R, 1 L, 2 D, 3 U, then
// the J1 list: 4 Button 1, 5 Button 2, 6 Start, 7 Coin, 8 Service,
// 9 Button 3. P1/P2: 0 R, 1 L, 2 D, 3 U, 4 B1, 5 B2, 6 B3 on sadari only
// (spec 9.2; unknown bits read 1 elsewhere). SYSTEM: 0 Coin1, 1 Start1,
// 2 Coin2, 3 Start2, 4 Service. (lastday/gulfstrm/pollux use other SYSTEM
// orders; they are not in this build.)
// ---------------------------------------------------------------------------
wire [3:0] game;
wire       b3_on = (game == 4'd5);   // sadari
wire [7:0] p1  = ~{1'b0, b3_on & joy0[9], joy0[5:4], joy0[3:0]};
wire [7:0] p2  = ~{1'b0, b3_on & joy1[9], joy1[5:4], joy1[3:0]};
wire [7:0] sys = ~{3'b000, joy0[8] | joy1[8], joy1[6], joy1[7], joy0[6], joy0[7]};

// ---------------------------------------------------------------------------
// board
// ---------------------------------------------------------------------------
wire reset = RESET | status[0] | buttons[1];

wire [7:0] r, g, b;
wire       hbl, vbl, hs, vs, de, ce_pix;
wire signed [15:0] audio;

dy_board #(.CPU_DIV(12), .CLK_HZ(96000000), .V_TOTAL(260), .PIX_NUM(1), .PIX_DEN(12)) board (
	.clk(clk_sys), .i_sdram_rst_n(pll_locked), .i_reset(reset),
	.i_ioctl_download(ioctl_download), .i_ioctl_wr(ioctl_wr), .i_ioctl_addr(ioctl_addr),
	.i_ioctl_dout(ioctl_dout), .i_ioctl_index(ioctl_index), .o_ioctl_wait(ioctl_wait),
	.i_p1(p1), .i_p2(p2), .i_system(sys),
	.o_r(r), .o_g(g), .o_b(b), .o_hblank(hbl), .o_vblank(vbl), .o_hs(hs), .o_vs(vs),
	.o_de(de), .o_ce_pix(ce_pix), .o_audio(audio), .o_game(game),
	.o_pen(), .o_vbl_irq(),
	.o_dbg_overruns(), .o_dbg_maxcyc(),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_CKE(SDRAM_CKE)
);

// ---------------------------------------------------------------------------
// video: 384 x 240 (384 x 256 on the primella family), rotated for the
// vertical games
// ---------------------------------------------------------------------------
// flytiger and bluehawk are ROT270 in MAME: turn the picture 90 degrees
// counter-clockwise to stand it upright
wire vertical   = (game <= 4'd4);        // lastday..bluehawk ROT270; primella family ROT0
wire no_rotate  = status[2] | direct_video | ~vertical;
wire rotate_ccw = 1'b1;
wire flip       = 1'b0;

wire [1:0] ar = status[23:22];
assign VIDEO_ARX = (!ar) ? ((no_rotate) ? 13'd4 : 13'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? ((no_rotate) ? 13'd3 : 13'd4) : 12'd0;

// The core's video outputs change once every 12 clk_sys clocks (8 MHz),
// i.e. every 6 clk_vid clocks; re-registered here and sampled once per
// pixel by a divide-by-6 enable. (ce_pix itself is not needed: the pixel
// rate is exact and fixed on hardware.)
reg  [2:0] vdiv = 3'd0;
reg        ce_vid;
reg  [7:0] r_v, g_v, b_v;
reg        hbl_v, vbl_v, hs_v, vs_v;
always @(posedge clk_vid) begin
	vdiv   <= (vdiv == 3'd5) ? 3'd0 : vdiv + 3'd1;
	ce_vid <= (vdiv == 3'd0);
	{r_v, g_v, b_v} <= {r, g, b};
	{hbl_v, vbl_v, hs_v, vs_v} <= {hbl, vbl, hs, vs};
end

screen_rotate screen_rotate (.*);

arcade_video #(.WIDTH(384), .DW(24)) arcade_video (
	.*,
	.clk_video(clk_vid),
	.ce_pix(ce_vid),
	.RGB_in({r_v, g_v, b_v}),
	.HBlank(hbl_v),
	.VBlank(vbl_v),
	.HSync(hs_v),
	.VSync(vs_v),
	.fx(status[5:3])
);

// ---------------------------------------------------------------------------
// audio / LEDs
// ---------------------------------------------------------------------------
assign AUDIO_L = audio;
assign AUDIO_R = audio;
assign AUDIO_S = 1'b1;

assign LED_USER  = ioctl_download;
assign LED_POWER = 2'b00;
assign LED_DISK  = 2'b00;

endmodule
