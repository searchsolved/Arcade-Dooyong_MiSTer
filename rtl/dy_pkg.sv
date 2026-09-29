// Dooyong per-game video configuration (spec 6.2, 7.5, 8, 10.1, 11).
//
// The game ID comes from the MRA; everything else is decoded here, so a bad
// MRA cannot create an illegal configuration (PLAN 4.1). Addresses are byte
// addresses in the fixed SDRAM layout of PLAN 4.3 / tools/build_regions.py.
// Z80 family: lastday, gulfstrm, pollux, flytiger, bluehawk and the
// primella family (sadari; gundl94 and its clone primella); 68000 family:
// superx, rshark, popbingo.

package dy_pkg;

  localparam logic [3:0] G_LASTDAY  = 4'd0;
  localparam logic [3:0] G_GULFSTRM = 4'd1;
  localparam logic [3:0] G_POLLUX   = 4'd2;
  localparam logic [3:0] G_FLYTIGER = 4'd3;
  localparam logic [3:0] G_BLUEHAWK = 4'd4;
  localparam logic [3:0] G_SADARI   = 4'd5;   // primella machine config
  localparam logic [3:0] G_GUNDL94  = 4'd6;   // gundl94, primella (same regions)
  localparam logic [3:0] G_SUPERX   = 4'd7;   // 68000 family (rshark_state)
  localparam logic [3:0] G_RSHARK   = 4'd8;
  localparam logic [3:0] G_POPBINGO = 4'd9;

  function automatic logic is_m68k(logic [3:0] g);
    return g == G_SUPERX || g == G_RSHARK || g == G_POPBINGO;
  endfunction

  // primella family (spec 3.6, 5.3, 11.6): no sprites, 256 visible lines,
  // vblank at line 256, text priority from ctrl bit 3
  function automatic logic is_primella(logic [3:0] g);
    return g == G_SADARI || g == G_GUNDL94;
  endfunction

  // SDRAM layout (PLAN 4.3)
  localparam logic [22:0] SD_TX     = 23'h050000;
  localparam logic [22:0] SD_AUX    = 23'h0C0000;   // separate map ROMs
  localparam logic [22:0] SD_SPRITE = 23'h140000;
  localparam logic [22:0] SD_BG0    = 23'h340000;
  localparam logic [22:0] SD_BG1    = 23'h440000;
  localparam logic [22:0] SD_FG0    = 23'h540000;
  localparam logic [22:0] SD_FG1    = 23'h640000;

  typedef struct packed {
    logic        present;
    logic [22:0] gfx_base;
    logic [12:0] tile_mask;   // decoded tiles - 1 (region bytes / bytes per tile - 1)
    logic [22:0] map_base;    // byte address of map word 0 (region + 2 * offset)
    logic [16:0] map_mask;    // map length in words - 1
    logic        opaque;      // no transparent pen (bg0 on most games)
    logic [10:0] cbase;       // colour base pen
    logic        t16;         // 16x16 tiles, 64 x 32 map (rshark, superx)
    logic        crom;        // colour from the colour ROM (spec 7.4)
    logic [22:0] crom_base;   // colour ROM byte address of map entry 0
    logic        col0;        // colour 0 (popbingo)
  } layer_cfg_t;

  typedef struct packed {
    layer_cfg_t  bg0, fg0, fg1, bg1;
    logic        pbingo;      // popbingo: bg0/bg1 combined into 0x100 | bg0 << 4 | bg1 (spec 11.9)
    logic        tx_packed;   // 1: gfx_8x8x4_packed_msb; 0: lastday split planes
    logic [16:0] tx_half;     // byte offset of planes 2-3 (split layout)
    logic [11:0] tx_mask;     // chars - 1
    logic        tx_lane0;    // CPU layout: 1 = offset bit 0 selects lane (bluehawk)
    logic [7:0]  tx_yscroll;  // 8 on lastday/gulfstrm (negated when flipped)
    logic [13:0] spr_mask;    // sprite codes - 1
    logic        spr_12bit, spr_height, spr_ysh_ft, spr_ysh_bh;
    logic        pal_444;     // xBGR_444 (lastday); else xRGB_555
  } cfg_t;

  function automatic layer_cfg_t lay(logic [22:0] gfx, logic [12:0] tmask,
                                     logic [22:0] map, logic [16:0] mmask,
                                     logic opq, logic [10:0] cbase);
    layer_cfg_t l;
    l = '0;
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
      G_SUPERX, G_RSHARK: begin
        // four 16x16 layers, map = the first 0x20000 words of each tile
        // region, colour from tmap_hi (SD_AUX) at 0x60000/0x40000/0x20000/0
        // (spec 7.4, 7.5); 8192 tiles per 1 MB region
        c.bg0 = lay(SD_BG0, 13'h1FFF, SD_BG0, 17'h1FFFF, 1'b1, 11'd1024);
        c.bg1 = lay(SD_BG1, 13'h1FFF, SD_BG1, 17'h1FFFF, 1'b0, 11'd768);
        c.fg0 = lay(SD_FG0, 13'h1FFF, SD_FG0, 17'h1FFFF, 1'b0, 11'd512);
        c.fg1 = lay(SD_FG1, 13'h1FFF, SD_FG1, 17'h1FFFF, 1'b0, 11'd256);
        {c.bg0.t16, c.bg1.t16, c.fg0.t16, c.fg1.t16} = 4'hF;
        {c.bg0.crom, c.bg1.crom, c.fg0.crom, c.fg1.crom} = 4'hF;
        c.spr_mask      = 14'h3FFF;          // 2 MB, 16384 tiles
        c.bg0.crom_base = SD_AUX + 23'h60000;
        c.bg1.crom_base = SD_AUX + 23'h40000;
        c.fg0.crom_base = SD_AUX + 23'h20000;
        c.fg1.crom_base = SD_AUX;
      end
      G_POPBINGO: begin
        // two opaque 32x32 layers, 0x4000-word maps at the region start,
        // code 11 bits (2048 tiles), colour 0, raw pens combined
        c.bg0 = lay(SD_BG0, 13'h7FF, SD_BG0, 17'h3FFF, 1'b1, 11'd0);
        c.bg1 = lay(SD_BG1, 13'h7FF, SD_BG1, 17'h3FFF, 1'b1, 11'd0);
        c.bg0.col0 = 1'b1;
        c.bg1.col0 = 1'b1;
        c.pbingo   = 1'b1;
        c.spr_mask = 14'h1FFF;               // 1 MB, 8192 tiles
      end
      G_SADARI, G_GUNDL94: begin
        // map in the top 32 KB of each tile region (word offset -0x4000,
        // spec 7.5): 512 KB regions on sadari, 256 KB on gundl94
        if (g == G_SADARI) begin
          c.bg0 = lay(SD_BG0, 10'd1023, SD_BG0 + 23'h78000, 16'h3FFF, 1'b1, 10'd768);
          c.fg0 = lay(SD_FG0, 10'd1023, SD_FG0 + 23'h78000, 16'h3FFF, 1'b0, 10'd512);
        end else begin
          c.bg0 = lay(SD_BG0, 10'd511, SD_BG0 + 23'h38000, 16'h3FFF, 1'b1, 10'd768);
          c.fg0 = lay(SD_FG0, 10'd511, SD_FG0 + 23'h38000, 16'h3FFF, 1'b0, 10'd512);
        end
        c.tx_packed  = 1'b1;
        c.tx_mask    = 12'hFFF;          // 4096 chars (128 KB)
        c.tx_lane0   = 1'b1;
      end
      default: ;
    endcase
    return c;
  endfunction

endpackage
