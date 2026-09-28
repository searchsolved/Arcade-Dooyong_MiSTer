// Z80-family sprite engine, one line at a time (spec 10.1, 10.3).
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
    input  logic [11:0] i_code_mask,
    input  logic        i_f12, i_fheight, i_ysh_ft, i_ysh_bh,
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
  logic        flip, bank;
  logic        busy;

  // ---------------------------------------------------------------- scan
  // hit record: {sx[10:0], fx, cls, colour[3:0], tile[11:0], trow[3:0]}
  localparam int HW = 33;
  localparam int HD = 4;
  logic [HW-1:0] hq [HD];
  logic [1:0]    hq_wp, hq_rp;
  logic [2:0]    hq_cnt;
  logic          hq_push, hq_pop;
  logic [HW-1:0] hq_d;

  logic        scan;            // issuing buffer reads
  logic [7:0]  sc;              // read index: entry sc[7:1], word sc[0] ? 7 : 0
  logic        d_v;             // buffer data valid this clock for index d_sc
  logic [7:0]  d_sc;
  logic [31:0] w0;
  wire         adv = scan && (hq_cnt < 3'(HD - 1));
  assign o_buf_addr = {sc[7:1], sc[0] ? 3'd7 : 3'd0};

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
  wire [11:0]        tile = (c_code + {9'b0, yidx}) & i_code_mask;
  wire [3:0]         col  = b1[3:0];
  assign hq_d    = {c_sx, c_fx, (col == 4'd0) || (col == 4'd15), col, tile, trow};
  assign hq_push = d_v && d_sc[0] && hit;

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
  wire [HW-1:0]  fh = hq[hq_rp];
  wire           f_req = (hq_cnt != 3'd0) && (f_half || rq_cnt < 3'(RD));
  assign o_rom_req  = f_req;
  assign o_rom_addr = SPR_BASE + {4'b0, fh[15:4], 7'b0} + {16'b0, f_half, 6'b0} + {17'b0, fh[3:0], 2'b0};
  wire           f_acc = f_req && i_rom_gnt;
  assign hq_pop = f_acc && f_half;

  // ---------------------------------------------------------------- draw
  logic        drawing;
  logic [3:0]  di;                        // even pixel index 0,2,..,14
  wire [HW-1:0] dr   = rq[rq_rp];
  wire signed [10:0] dsx = dr[32:22];
  wire         dfx  = dr[21];
  wire         dcls = dr[20];
  wire [3:0]   dcol = dr[19:16];
  wire [31:0]  dg0  = rq_g0[rq_rp];
  wire [31:0]  dg1  = rq_g1[rq_rp];

  function automatic logic [3:0] spix(logic [31:0] a, logic [31:0] b, logic [3:0] t);
    logic [31:0] w;
    logic [4:0]  kk;
    w  = t[3] ? b : a;
    kk = {3'b0, t[1:0]};
    if (!t[2]) return {w[5'd31 - kk], w[5'd27 - kk], w[5'd23 - kk], w[5'd19 - kk]};
    else       return {w[5'd15 - kk], w[5'd11 - kk], w[5'd7 - kk],  w[5'd3 - kk]};
  endfunction

  logic [3:0]  pp   [2];
  logic signed [10:0] px [2];
  logic        pin  [2];
  logic [8:0]  pbx  [2];
  always_comb begin
    for (int j = 0; j < 2; j++) begin
      logic [3:0] i;
      i      = di + 4'(j);
      pp[j]  = spix(dg0, dg1, dfx ? ~i : i);
      px[j]  = dsx + $signed({7'b0, i});
      pin[j] = (px[j] >= 11'sd64) && (px[j] <= 11'sd447) && pp[j] != 4'd15;
      pbx[j] = 9'(px[j] - 11'sd64);
    end
  end
  wire [10:0] dpen = 11'(256) + {bank, 10'b0} + {3'b000, dcol, 4'b0};

  // ---------------------------------------------------------------- sequential
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      scan     <= 1'b0;
      d_v      <= 1'b0;
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
      drawing  <= 1'b0;
      o_done   <= 1'b0;
      occ      <= '0;
    end else begin
      o_done <= 1'b0;
      // scan
      d_v <= adv;
      if (adv) begin
        d_sc <= sc;
        sc   <= sc + 8'd1;
        if (sc == 8'd255) scan <= 1'b0;
      end
      if (d_v && !d_sc[0]) w0 <= i_buf_data;
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
          rq[rq_wp] <= fh;
          rq_wp <= rq_wp + 2'd1;
        end
      end
      if (i_rom_rv) begin
        if (!rs_half) rq_g0[rs_wp] <= i_rom_data;
        else begin
          rq_g1[rs_wp] <= i_rom_data;
          rs_wp <= rs_wp + 2'd1;
        end
        rs_half <= !rs_half;
      end

      // draw
      if (!drawing && rq_ready != 3'd0) begin
        drawing <= 1'b1;
        di      <= 4'd0;
      end else if (drawing) begin
        for (int j = 0; j < 2; j++) begin
          if (pin[j] && !occ[pbx[j]]) begin
            occ[pbx[j]] <= 1'b1;
            if (pbx[j][0]) lbo[pbx[j][8:1]] <= {dcls, dpen + 11'(pp[j])};
            else           lbe[pbx[j][8:1]] <= {dcls, dpen + 11'(pp[j])};
          end
        end
        di <= di + 4'd2;
        if (di == 4'd14) begin
          drawing <= 1'b0;
          rq_rp   <= rq_rp + 2'd1;
        end
      end
      rq_cnt   <= rq_cnt + 3'(f_acc && !f_half) - 3'(drawing && di == 4'd14);
      rq_ready <= rq_ready + 3'(i_rom_rv && rs_half) - 3'(!drawing && rq_ready != 3'd0);

      if (i_start) begin
        line <= i_line;
        flip <= i_flip;
        bank <= i_bank;
        scan <= 1'b1;
        sc   <= 8'd0;
      end
      if (!i_start && !scan && !d_v && hq_cnt == 3'd0 && rq_cnt == 3'd0 && busy && !o_done)
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
