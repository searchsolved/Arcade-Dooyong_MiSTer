//============================================================================
//  Dooyong (Flying Tiger, Blue Hawk, ...) for MiSTer - framework shell (M4)
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
	"J1,Button 1,Button 2,Start,Coin,Service;",
	"jn,A,B,Start,Select,L;",
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
	.joystick_1(joystick_1)
);

// ---------------------------------------------------------------------------
// inputs, active low (spec 9.2). MiSTer joystick: 0 R, 1 L, 2 D, 3 U, then
// the J1 list: 4 Button 1, 5 Button 2, 6 Start, 7 Coin, 8 Service.
// P1/P2: 0 R, 1 L, 2 D, 3 U, 4 B1, 5 B2. SYSTEM: 0 Coin1, 1 Start1,
// 2 Coin2, 3 Start2, 4 Service. (lastday/gulfstrm/pollux use other SYSTEM
// orders; they are not in this build.)
// ---------------------------------------------------------------------------
wire [7:0] p1  = ~{2'b00, joystick_0[5:4], joystick_0[3:0]};
wire [7:0] p2  = ~{2'b00, joystick_1[5:4], joystick_1[3:0]};
wire [7:0] sys = ~{3'b000, joystick_0[8] | joystick_1[8],
                   joystick_1[6], joystick_1[7], joystick_0[6], joystick_0[7]};

// ---------------------------------------------------------------------------
// board
// ---------------------------------------------------------------------------
wire reset = RESET | status[0] | buttons[1];

wire [7:0] r, g, b;
wire       hbl, vbl, hs, vs, de, ce_pix;
wire signed [15:0] audio;
wire [3:0] game;

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
// video: 384 x 240, rotated for the vertical games
// ---------------------------------------------------------------------------
// flytiger and bluehawk are ROT270 in MAME: turn the picture 90 degrees
// counter-clockwise to stand it upright
wire vertical   = (game <= 4'd4);        // every Z80-family game so far is ROT270
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
