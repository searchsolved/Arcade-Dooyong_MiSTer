// Lint-only stubs for the MiSTer framework modules, so the emu shell
// elaborates under Verilator on the Mac before any Quartus build.
// NOT part of the Quartus project - the real sys/ framework provides
// these. Keep the port lists in sync with Template_MiSTer sys/.

`ifdef LINT_STUBS

module pll (
    input  refclk,
    input  rst,
    output outclk_0,
    output outclk_1,
    output outclk_2,
    output locked
);
  assign outclk_0 = refclk;
  assign outclk_1 = refclk;
  assign outclk_2 = refclk;
  assign locked = 1'b1;
endmodule

module hps_io #(parameter CONF_STR = "", CONF_STR_BRAM = 0, PS2DIV = 0,
                WIDE = 0, VDNUM = 1, BLKSZ = 2, PS2WE = 0, STRLEN = 0) (
    input         clk_sys,
    inout  [45:0] HPS_BUS,
    inout  [35:0] EXT_BUS,
    inout  [21:0] gamma_bus,
    output [1:0]  buttons,
    output [127:0] status,
    input  [15:0] status_menumask,
    output        forced_scandoubler,
    output        direct_video,
    input         video_rotated,
    output        ioctl_download,
    output        ioctl_wr,
    output [26:0] ioctl_addr,
    output [7:0]  ioctl_dout,
    output [15:0] ioctl_index,
    input         ioctl_wait,
    output        ioctl_upload,
    input         ioctl_upload_req,
    input  [7:0]  ioctl_upload_index,
    input  [7:0]  ioctl_din,
    output [31:0] joystick_0,
    output [31:0] joystick_1
);
endmodule

module arcade_video #(parameter WIDTH = 320, DW = 8, GAMMA = 1) (
    input         clk_video,
    input         ce_pix,
    input [DW-1:0] RGB_in,
    input         HBlank,
    input         VBlank,
    input         HSync,
    input         VSync,
    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [7:0]  VGA_R,
    output [7:0]  VGA_G,
    output [7:0]  VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output [1:0]  VGA_SL,
    input  [2:0]  fx,
    input         forced_scandoubler,
    inout  [21:0] gamma_bus
);
endmodule

module screen_rotate (
    input         CLK_VIDEO,
    input         CE_PIXEL,
    input   [7:0] VGA_R,
    input   [7:0] VGA_G,
    input   [7:0] VGA_B,
    input         VGA_HS,
    input         VGA_VS,
    input         VGA_DE,
    input         rotate_ccw,
    input         no_rotate,
    input         flip,
    output        video_rotated,
    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,
    output        DDRAM_RD
);
endmodule

`endif
