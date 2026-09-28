// Dooyong per-game video configuration (spec 6.2, 7.5, 8, 10.1, 11).
//
// The game ID comes from the MRA; everything else is decoded here, so a bad
// MRA cannot create an illegal configuration (PLAN 4.1). Addresses are byte
// addresses in the fixed SDRAM layout of PLAN 4.3 / tools/build_regions.py.
// Z80 family only for now; primella family and the 68000 games come later.

package dy_pkg;

  localparam logic [3:0] G_LASTDAY  = 4'd0;
  localparam logic [3:0] G_GULFSTRM = 4'd1;
  localparam logic [3:0] G_POLLUX   = 4'd2;
  localparam logic [3:0] G_FLYTIGER = 4'd3;
  localparam logic [3:0] G_BLUEHAWK = 4'd4;

  // SDRAM layout (PLAN 4.3)
  localparam logic [22:0] SD_TX     = 23'h050000;
  localparam logic [22:0] SD_AUX    = 23'h0C0000;   // separate map ROMs
  localparam logic [22:0] SD_SPRITE = 23'h140000;
  localparam logic [22:0] SD_BG0    = 23'h340000;
  localparam logic [22:0] SD_FG0    = 23'h540000;
  localparam logic [22:0] SD_FG1    = 23'h640000;

  typedef struct packed {
    logic        present;
    logic [22:0] gfx_base;
    logic [9:0]  tile_mask;   // decoded tiles - 1 (region bytes / 512 - 1)
    logic [22:0] map_base;    // byte address of map word 0 (region + 2 * offset)
    logic [15:0] map_mask;    // map length in words - 1
    logic        opaque;      // no transparent pen (bg0 on most games)
    logic [9:0]  cbase;       // colour base pen
  } layer_cfg_t;

  typedef struct packed {
    layer_cfg_t  bg0, fg0, fg1;
    logic        tx_packed;   // 1: gfx_8x8x4_packed_msb; 0: lastday split planes
    logic [16:0] tx_half;     // byte offset of planes 2-3 (split layout)
    logic [11:0] tx_mask;     // chars - 1
    logic        tx_lane0;    // CPU layout: 1 = offset bit 0 selects lane (bluehawk)
    logic [7:0]  tx_yscroll;  // 8 on lastday/gulfstrm (negated when flipped)
    logic [11:0] spr_mask;    // sprite codes - 1
    logic        spr_12bit, spr_height, spr_ysh_ft, spr_ysh_bh;
    logic        pal_444;     // xBGR_444 (lastday); else xRGB_555
  } cfg_t;

  function automatic layer_cfg_t lay(logic [22:0] gfx, logic [9:0] tmask,
                                     logic [22:0] map, logic [15:0] mmask,
                                     logic opq, logic [9:0] cbase);
    layer_cfg_t l;
    l.present   = 1'b1;
    l.gfx_base  = gfx;
    l.tile_mask = tmask;
    l.map_base  = map;
    l.map_mask  = mmask;
    l.opaque    = opq;
    l.cbase     = cbase;
    return l;
  endfunction

  function automatic cfg_t game_cfg(logic [3:0] g);
    cfg_t c;
    c = '0;
    case (g)
      G_LASTDAY, G_GULFSTRM, G_POLLUX: begin
        // separate 0x10000-word map ROMs at aux +0 / +0x20000 (spec 7.5)
        // bg0 512 KB = 1024 tiles; fg0 256 KB on lastday/gulfstrm, 512 KB on pollux
        c.bg0 = lay(SD_BG0, 10'd1023, SD_AUX, 16'hFFFF, 1'b1, 10'd768);
        c.fg0 = lay(SD_FG0, (g == G_POLLUX) ? 10'd1023 : 10'd511,
                    SD_AUX + 23'h20000, 16'hFFFF, 1'b0, 10'd512);
        c.tx_packed  = 1'b0;
        c.tx_half    = (g == G_POLLUX) ? 17'h08000 : 17'h04000;
        c.tx_mask    = (g == G_POLLUX) ? 12'h7FF : 12'h3FF;
        c.tx_yscroll = (g == G_POLLUX) ? 8'd0 : 8'd8;
        c.spr_mask   = (g == G_LASTDAY) ? 12'h7FF : 12'hFFF;
        c.spr_12bit  = (g != G_LASTDAY);
        c.spr_height = (g == G_POLLUX);
        c.pal_444    = (g == G_LASTDAY);
      end
      G_FLYTIGER: begin
        // map in the top 32 KB of each 512 KB tile region (word 0x3C000)
        c.bg0 = lay(SD_BG0, 10'd1023, SD_BG0 + 23'h78000, 16'h3FFF, 1'b0, 10'd768);
        c.fg0 = lay(SD_FG0, 10'd1023, SD_FG0 + 23'h78000, 16'h3FFF, 1'b0, 10'd512);
        c.tx_packed  = 1'b0;
        c.tx_half    = 17'h08000;
        c.tx_mask    = 12'h7FF;
        c.spr_mask   = 12'hFFF;
        c.spr_12bit  = 1'b1;
        c.spr_height = 1'b1;
        c.spr_ysh_ft = 1'b1;
      end
      G_BLUEHAWK: begin
        c.bg0 = lay(SD_BG0, 10'd1023, SD_BG0 + 23'h78000, 16'h3FFF, 1'b1, 10'd768);
        c.fg0 = lay(SD_FG0, 10'd1023, SD_FG0 + 23'h78000, 16'h3FFF, 1'b0, 10'd512);
        c.fg1 = lay(SD_FG1, 10'd511,  SD_FG1 + 23'h38000, 16'h3FFF, 1'b0, 10'd0);
        c.tx_packed  = 1'b1;
        c.tx_mask    = 12'h7FF;
        c.tx_lane0   = 1'b1;
        c.spr_mask   = 12'hFFF;
        c.spr_12bit  = 1'b1;
        c.spr_height = 1'b1;
        c.spr_ysh_bh = 1'b1;
      end
      default: ;
    endcase
    return c;
  endfunction

endpackage
