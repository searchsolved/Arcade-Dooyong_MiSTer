// Sprite engine, one line at a time: Z80 family (spec 10.1, 10.3) and, with
// i_m68k, the 68000 family (spec 10.2; dy_render.py draw_68k_sprites):
// 256 entries of 8 words processed from the LAST to the first, enable bit,
// width x height tiles counted row-major, 9-bit X, signed 9-bit Y, packed
// 4 bpp tiles (gfx_8x8x4_col_2x2_group_packed_msb), colour base 0, mask
// class colour 0/15 (GFX_PMASK_2; GFX_PMASK_4 never matches on these games,
// whose layers set priority 1 or 2 only). A hit is one tile row of a
// sprite; the fetch stage expands it into width+1 tiles.
//
// Model: sim/oracle/dy_render.py draw_z80_sprites. Entries 0..127 of the
// vblank copy are processed in order. The first sprite with a solid
// (pen != 15) pixel at an x owns that pixel for the line, whether or not the
// tile layers later hide it (MAME prio_transpen sets pri = 31 either way).
// The line buffer keeps that owner's pen and its mask class; the resolve
// stage in dy_video applies the layer masks:
//   colour 0 or 15 (mask 0xFC): hidden where pri >= 2
//   other colours  (mask 0xF0): hidden where pri >= 4
//
// Three overlapping stages:
//   scan  : two sprite-buffer reads per entry (bytes 0-3, byte 0x1C),
//           decode, Y hit test; hits go to a small queue. Each entry hits
//           at most one 16-px tile row per line.
//   fetch : two 32-bit ROM words per hit (pixels 0-7, 8-15 of the row).
//   draw  : two pixels per clock into the line buffer, in hit order, so
//           first-drawn-wins holds.
//
// Sprite buffer port: 32-bit words, word w = bytes 4w..4w+3, [31:24] =
// byte 4w; registered read. ROM port as in dy_layer_pass.

module dy_spr_z80 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_start,
    input  logic [7:0]  i_line,
    input  logic        i_flip,
    input  logic        i_bank,
    input  logic [13:0] i_code_mask,
    input  logic        i_f12, i_fheight, i_ysh_ft, i_ysh_bh,
    input  logic        i_m68k,
    // sprite buffer
    output logic [9:0]  o_buf_addr,
    input  logic [31:0] i_buf_data,
    // ROM port
    output logic        o_rom_req,
    output logic [22:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,
    output logic        o_done,
    // line buffer resolve port: registered read, clears the pixel
    input  logic        i_rs_en,
    input  logic [8:0]  i_rs_x,
    output logic        o_rs_occ,
    output logic        o_rs_cls,
    output logic [10:0] o_rs_pen
);

  localparam logic [22:0] SPR_BASE = dy_pkg::SD_SPRITE;

  // ---------------------------------------------------------------- line buffer
  logic [383:0] occ;
  logic [11:0]  lbe [192];      // even x: {cls, pen[10:0]}
  logic [11:0]  lbo [192];      // odd x

  logic [7:0]  line;
  logic        flip, bank, m68k;
  logic        busy;

  // ---------------------------------------------------------------- scan
  // hit record: {cnt[3:0], sx[10:0], fx, cls, colour[3:0], tile[13:0], trow[3:0]}
  // (cnt = tiles - 1 in the row, 0 on the Z80 games)
  localparam int HW = 39;
  localparam int HD = 4;
  logic [HW-1:0] hq [HD];
  logic [1:0]    hq_wp, hq_rp;
  logic [2:0]    hq_cnt;
  logic          hq_push, hq_pop;
  logic [HW-1:0] hq_d;

  logic        scan;            // issuing buffer reads
  // read index. Z80: entry sc[7:1], word sc[0] ? 7 : 0. 68000: entry
  // 255 - sc[9:2], 32-bit word sc[1:0] = sprite words {2k, 2k+1}
  logic [9:0]  sc;
  logic        d_v;             // buffer data valid this clock for index d_sc
  logic [9:0]  d_sc;
  logic [31:0] w0;
  logic [15:0] m_w0, m_w1, m_w3, m_w4;
  wire         adv = scan && (hq_cnt < 3'(HD - 1));
  wire [7:0]   m_ent = 8'd255 - sc[9:2];
  assign o_buf_addr = m68k ? {m_ent, sc[1:0]} : {sc[7:1], sc[0] ? 3'd7 : 3'd0};
  wire         sc_last = m68k ? (sc == 10'd1023) : (sc[7:0] == 8'd255);

  // entry decode: w0 = bytes 0-3, ext = byte 0x1C on the bus now
  wire [7:0] b0 = w0[31:24], b1 = w0[23:16], b2 = w0[15:8], b3 = w0[7:0];
  wire [7:0] e  = i_buf_data[31:24];
  logic signed [10:0] c_sx, c_sy;
  logic [11:0] c_code;
  logic [2:0]  c_h;
  logic        c_fx, c_fy;
  always_comb begin
    c_sx   = $signed({2'b00, b1[4], b3});
    c_sy   = $signed({3'b000, b2});
    c_code = {1'b0, b1[7:5], b0};
    c_h    = 3'd0;
    c_fx   = 1'b0;
    c_fy   = 1'b0;
    if (i_f12) c_code[11] = e[0];
    if (i_fheight) begin
      c_h    = e[6:4];
      c_code = c_code & ~{9'b0, c_h};
      c_fx   = e[3];
      c_fy   = e[2];
    end
    if (i_ysh_bh) c_sy = c_sy + 11'sd6 - (e[1] ? 11'sd0 : 11'sd256);
    if (i_ysh_ft) c_sy = c_sy - (e[1] ? 11'sd256 : 11'sd0);
    if (flip) begin
      c_sx = 11'sd498 - c_sx;
      c_sy = 11'sd240 - $signed({4'b0, c_h, 4'b0}) - c_sy;
      c_fx = !c_fx;
      c_fy = !c_fy;
    end
  end
  wire signed [10:0] d    = $signed({3'b000, line}) - c_sy;
  wire               hit  = (d >= 0) && (d < $signed({3'b0, {1'b0, c_h} + 4'd1, 4'b0}));
  wire [2:0]         k    = d[6:4];
  wire [2:0]         yidx = c_fy ? c_h - k : k;
  wire [3:0]         trow = c_fy ? ~d[3:0] : d[3:0];
  wire [11:0]        tile = (c_code + {9'b0, yidx}) & i_code_mask[11:0];
  wire [3:0]         col  = b1[3:0];

  // 68000 entry: w0 bit 0 enable, w1 width/height, w3 code, w4 X, w6 Y,
  // w7 colour. Two pipeline stages after the last word (m4 STA compile 8:
  // RAM output -> hit logic -> queue in one clock failed by 4 ns): E1
  // evaluates the hit from registered words, E2 adds the row offset to the
  // code and pushes. Entries arrive every 4 clocks, so throughput is kept.
  logic [15:0]       m_w6, m_w7;
  logic              e1_v, e2_v;
  wire [3:0]         m_w  = m_w1[3:0];
  wire [3:0]         m_h  = m_w1[7:4];
  wire signed [10:0] m_sx0 = $signed({2'b00, m_w4[8:0]});
  wire signed [10:0] m_sy0 = $signed({{2{m_w6[8]}}, m_w6[8:0]});
  wire signed [10:0] m_sx = flip ? 11'sd498 - $signed({3'b0, m_w, 4'b0}) - m_sx0 : m_sx0;
  wire signed [10:0] m_sy = flip ? 11'sd240 - $signed({3'b0, m_h, 4'b0}) - m_sy0 : m_sy0;
  wire signed [10:0] m_d  = $signed({3'b000, line}) - m_sy;
  wire               m_hit = m_w0[0] && (m_d >= 0) && (m_d < $signed({2'b0, {1'b0, m_h} + 5'd1, 4'b0}));
  wire [3:0]         m_k  = m_d[7:4];
  wire [3:0]         m_yi = flip ? m_h - m_k : m_k;
  wire [3:0]         m_tr = flip ? ~m_d[3:0] : m_d[3:0];
  wire [3:0]         m_col = m_w7[3:0];
  // E2 registers
  logic              e2_hit;
  logic [3:0]        e2_w, e2_yi, e2_tr, e2_col;
  logic signed [10:0] e2_sx;
  logic [15:0]       e2_code;
  wire  [13:0]       e2_tile = 14'(e2_code + {8'b0, e2_yi} * ({1'b0, e2_w} + 5'd1));
  assign hq_d    = m68k ? {e2_w, e2_sx, flip, (e2_col == 4'd0) || (e2_col == 4'd15), e2_col, e2_tile, e2_tr}
                        : {4'd0, c_sx, c_fx, (col == 4'd0) || (col == 4'd15), col, {2'b00, tile}, trow};
  assign hq_push = m68k ? (e2_v && e2_hit) : (d_v && d_sc[0] && hit);

  // ---------------------------------------------------------------- fetch
  // record queue: hit + its two words; filled in order by the responses
  localparam int RD = 4;
  logic [HW-1:0] rq   [RD];
  logic [31:0]   rq_g0 [RD];
  logic [31:0]   rq_g1 [RD];
  logic [1:0]    rq_wp, rq_rp, rs_wp;    // rs_wp: record the next response belongs to
  logic          rs_half;
  logic [2:0]    rq_cnt;                 // records allocated (fetching or waiting to draw)
  logic [2:0]    rq_ready;               // records with both words
  logic          f_half;                 // 0: issue word 0, 1: word 1
  logic [3:0]    f_t;                    // tile within the head hit's row
  wire [HW-1:0]  fh = hq[hq_rp];
  wire [3:0]     fh_cnt = fh[38:35];
  wire signed [10:0] fh_sx = $signed(fh[34:24]);
  wire           fh_fx  = fh[23];
  // tile t of the row: code + t, at X + 16t, or X + 16(cnt - t) when flipped
  wire [13:0]    ft_tile = (fh[17:4] + 14'(f_t)) & i_code_mask;   // wraps at the region size
  wire [3:0]     ft_pos  = fh_fx && m68k ? fh_cnt - f_t : f_t;
  wire signed [10:0] ft_sx = fh_sx + $signed({3'b0, ft_pos, 4'b0});
  // tiles wholly outside x 64-447 are skipped without a fetch (68000 rows
  // can be up to 16 tiles wide)
  wire           ft_vis  = (ft_sx <= 11'sd447) && (ft_sx >= 11'sd49);
  wire           ft_last = (f_t == fh_cnt);
  wire           f_have  = (hq_cnt != 3'd0);
  // the current tile's fetch decision, address and record are registered
  // one clock ahead (m4 STA compile 9: queue head -> address -> SDRAM)
  logic          fv, fv_vis, fv_last;
  logic [22:0]   fv_addr;
  logic [HW-1:0] fh_rec;                 // record pushed with the first word: this tile's X and code
  wire           f_skip  = fv && !f_half && !fv_vis;
  wire           f_req   = fv && fv_vis && (f_half || rq_cnt < 3'(RD));
  assign o_rom_req  = f_req;
  assign o_rom_addr = fv_addr | {16'b0, f_half, 6'b0};    // tile*128 + row*4 is 64-byte aligned for the half
  wire           f_acc = f_req && i_rom_gnt;
  wire           f_tile_done = (f_acc && f_half) || f_skip;
  assign hq_pop = f_tile_done && fv_last;

  // ---------------------------------------------------------------- draw
  // The head record is latched into registers when its draw starts (the
  // record queue may be a RAM block), then two pipeline stages: A computes
  // two pixels' pen, x and visibility, B checks and sets the owner bits
  // and writes the line buffer (m4 STA). B handles pixels strictly in
  // order, so first-drawn-wins is unchanged.
  logic        drawing;
  logic [3:0]  di;                        // even pixel index 0,2,..,14
  wire [HW-1:0] dr   = rq[rq_rp];
  logic signed [10:0] dsx;
  logic        dfx, dcls;
  logic [3:0]  dcol;
  logic [31:0] dg0, dg1;
  logic        sa_v  [2];                 // stage A -> B
  logic [8:0]  sa_bx [2];
  logic [11:0] sa_pen [2];
  logic        sa_act;

  function automatic logic [3:0] spix(logic [31:0] a, logic [31:0] b, logic [3:0] t);
    logic [31:0] w;
    logic [4:0]  kk;
    w  = t[3] ? b : a;
    kk = {3'b0, t[1:0]};
    if (!t[2]) return {w[5'd31 - kk], w[5'd27 - kk], w[5'd23 - kk], w[5'd19 - kk]};
    else       return {w[5'd15 - kk], w[5'd11 - kk], w[5'd7 - kk],  w[5'd3 - kk]};
  endfunction

  // packed 4 bpp, high nibble first; pixels 8-15 in the second word
  function automatic logic [3:0] ppix(logic [31:0] a, logic [31:0] b, logic [3:0] t);
    logic [31:0] w;
    w = t[3] ? b : a;
    return w[5'd31 - {t[2:0], 2'b00} -: 4];
  endfunction

  logic [3:0]  pp   [2];
  logic signed [10:0] px [2];
  logic        pin  [2];
  logic [8:0]  pbx  [2];
  always_comb begin
    for (int j = 0; j < 2; j++) begin
      logic [3:0] i;
      i      = di + 4'(j);
      pp[j]  = m68k ? ppix(dg0, dg1, dfx ? ~i : i) : spix(dg0, dg1, dfx ? ~i : i);
      px[j]  = dsx + $signed({7'b0, i});
      pin[j] = (px[j] >= 11'sd64) && (px[j] <= 11'sd447) && pp[j] != 4'd15;
      pbx[j] = 9'(px[j] - 11'sd64);
    end
  end
  wire [10:0] dpen = m68k ? {3'b000, dcol, 4'b0} : 11'(256) + {bank, 10'b0} + {3'b000, dcol, 4'b0};

  // ---------------------------------------------------------------- sequential
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      scan     <= 1'b0;
      d_v      <= 1'b0;
      e1_v     <= 1'b0;
      e2_v     <= 1'b0;
      hq_wp    <= '0;
      hq_rp    <= '0;
      hq_cnt   <= '0;
      rq_wp    <= '0;
      rq_rp    <= '0;
      rs_wp    <= '0;
      rs_half  <= 1'b0;
      rq_cnt   <= '0;
      rq_ready <= '0;
      f_half   <= 1'b0;
      f_t      <= 4'd0;
      fv       <= 1'b0;
      drawing  <= 1'b0;
      sa_act   <= 1'b0;
      o_done   <= 1'b0;
      occ      <= '0;
    end else begin
      o_done <= 1'b0;
      // scan
      d_v <= adv;
      if (adv) begin
        d_sc <= sc;
        sc   <= sc + 10'd1;
        if (sc_last) scan <= 1'b0;
      end
      if (d_v && !d_sc[0]) w0 <= i_buf_data;
      if (d_v && d_sc[1:0] == 2'd0) {m_w0, m_w1} <= i_buf_data;
      if (d_v && d_sc[1:0] == 2'd1) m_w3 <= i_buf_data[15:0];
      if (d_v && d_sc[1:0] == 2'd2) m_w4 <= i_buf_data[31:16];
      // 68000 pipeline: last word -> E1 (hit from registers) -> E2 (tile, push)
      e1_v <= m68k && d_v && d_sc[1:0] == 2'd3;
      if (d_v && d_sc[1:0] == 2'd3) {m_w6, m_w7} <= i_buf_data;
      e2_v <= e1_v;
      if (e1_v) begin
        e2_hit  <= m_hit;
        e2_w    <= m_w;
        e2_yi   <= m_yi;
        e2_tr   <= m_tr;
        e2_col  <= m_col;
        e2_sx   <= m_sx;
        e2_code <= m_w3;
      end
      if (hq_push) begin
        hq[hq_wp] <= hq_d;
        hq_wp <= hq_wp + 2'd1;
      end
      if (hq_pop) hq_rp <= hq_rp + 2'd1;
      hq_cnt <= hq_cnt + 3'(hq_push) - 3'(hq_pop);

      // fetch
      if (f_acc) begin
        f_half <= !f_half;
        if (!f_half) begin
          rq[rq_wp] <= fh_rec;
          rq_wp <= rq_wp + 2'd1;
        end
      end
      if (f_tile_done) f_t <= fv_last ? 4'd0 : f_t + 4'd1;
      if (f_tile_done) fv <= 1'b0;
      else if (!fv && f_have) begin
        fv      <= 1'b1;
        fv_vis  <= ft_vis;
        fv_last <= ft_last;
        fv_addr <= SPR_BASE + {2'b0, ft_tile, 7'b0} + {17'b0, fh[3:0], 2'b0};
        fh_rec  <= {fh[38:35], ft_sx, fh[23:18], ft_tile, fh[3:0]};
      end
      if (i_rom_rv) begin
        if (!rs_half) rq_g0[rs_wp] <= i_rom_data;
        else begin
          rq_g1[rs_wp] <= i_rom_data;
          rs_wp <= rs_wp + 2'd1;
        end
        rs_half <= !rs_half;
      end

      // draw: latch the head record, then stage A
      sa_act <= drawing;
      for (int j = 0; j < 2; j++) sa_v[j] <= 1'b0;
      if (!drawing && rq_ready != 3'd0) begin
        drawing <= 1'b1;
        di      <= 4'd0;
        dsx     <= dr[34:24];
        dfx     <= dr[23];
        dcls    <= dr[22];
        dcol    <= dr[21:18];
        dg0     <= rq_g0[rq_rp];
        dg1     <= rq_g1[rq_rp];
        rq_rp   <= rq_rp + 2'd1;
      end else if (drawing) begin
        for (int j = 0; j < 2; j++) begin
          sa_v[j]   <= pin[j];
          sa_bx[j]  <= pbx[j];
          sa_pen[j] <= {dcls, dpen + 11'(pp[j])};
        end
        di <= di + 4'd2;
        if (di == 4'd14) drawing <= 1'b0;
      end
      // stage B
      for (int j = 0; j < 2; j++) begin
        if (sa_v[j] && !occ[sa_bx[j]]) begin
          occ[sa_bx[j]] <= 1'b1;
          if (sa_bx[j][0]) lbo[sa_bx[j][8:1]] <= sa_pen[j];
          else             lbe[sa_bx[j][8:1]] <= sa_pen[j];
        end
      end
      rq_cnt   <= rq_cnt + 3'(f_acc && !f_half) - 3'(!drawing && rq_ready != 3'd0);
      rq_ready <= rq_ready + 3'(i_rom_rv && rs_half) - 3'(!drawing && rq_ready != 3'd0);

      if (i_start) begin
        line <= i_line;
        flip <= i_flip;
        bank <= i_bank;
        m68k <= i_m68k;
        scan <= 1'b1;
        sc   <= 10'd0;
      end
      if (!i_start && !scan && !d_v && !e1_v && !e2_v && hq_cnt == 3'd0 && rq_cnt == 3'd0 && !drawing && !sa_act
          && busy && !o_done)
        o_done <= 1'b1;

      // resolve read (only runs while the engine is idle)
      if (i_rs_en) begin
        o_rs_occ <= occ[i_rs_x];
        {o_rs_cls, o_rs_pen} <= i_rs_x[0] ? lbo[i_rs_x[8:1]] : lbe[i_rs_x[8:1]];
        occ[i_rs_x] <= 1'b0;
      end
    end
  end

  // busy from start until done
  always_ff @(posedge clk) begin
    if (!rst_n)      busy <= 1'b0;
    else if (i_start) busy <= 1'b1;
    else if (o_done)  busy <= 1'b0;
  end

endmodule
