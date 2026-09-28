// One tilemap pass over one visible line (384 px, screen x 64-447).
//
// Tile mode: a ROM tilemap layer (spec 7), 32x32 tiles, 1024 x 256 pixmap.
// Text mode: the RAM text layer (spec 8), 8x8 chars, 512 x 256 pixmap.
//
// Model: sim/oracle/dy_render.py rom_layer_pixmap / text_pixmap /
// scroll_sample. For screen pixel sx on line sy (spec 11.10):
//   normal : tx = (sx + scrollx) mod W        ty = (sy + scrolly) mod 256
//   flipped: tx = (scrollx + 511 - sx) mod W  ty = (scrolly + 255 - sy) mod 256
// The pixmap holds the logical tilemap, so screen flip needs no tile flips.
//
// Three overlapping stages:
//   issue  : tile mode first requests the 13 map words the line can touch,
//            then walks the line in 8-pixel pixmap groups and requests one
//            32-bit graphics word per group (text split layout: two, one
//            per plane half).
//   return : responses arrive in request order; map words fill the column
//            table, graphics words are decoded into 8 pens (pixmap order)
//            and queued.
//   pixel  : one pixel per clock from the queue into the line buffer.
//
// ROM port (pipelined, in order): a request is accepted in a clock with
// o_rom_req && i_rom_gnt; i_rom_rv/i_rom_data return accepted requests in
// order, [31:24] = byte at the (4-byte aligned) address.
// Text RAM port: registered read, data valid the clock after the address.

module dy_layer_pass (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_start,
    input  logic        i_text,
    input  logic [7:0]  i_line,
    input  logic        i_flip,
    input  logic        i_bank,        // palette bank: pen + 1024
    // tile layer
    input  logic [22:0] i_gfx_base,
    input  logic [9:0]  i_tile_mask,
    input  logic [22:0] i_map_base,
    input  logic [15:0] i_map_mask,
    input  logic        i_opaque,
    input  logic [9:0]  i_cbase,
    input  logic [7:0]  i_reg0,
    input  logic [7:0]  i_reg1,
    input  logic [7:0]  i_reg3,
    input  logic        i_fmt_a,
    // text layer
    input  logic        i_tx_packed,
    input  logic [22:0] i_tx_base,
    input  logic [16:0] i_tx_half,
    input  logic [11:0] i_tx_mask,
    input  logic [7:0]  i_tx_yscroll,
    // memories
    output logic        o_rom_req,
    output logic [22:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,
    output logic [10:0] o_txt_addr,
    input  logic [15:0] i_txt_data,
    // line buffer
    output logic        o_lb_we,
    output logic [8:0]  o_lb_x,        // 0..383 = screen x 64..447
    output logic [10:0] o_lb_pen,
    output logic        o_done
);

  localparam int NCOL = 13;            // 32-px columns a 384-px line can touch
  localparam int QD   = 8;             // decoded-group queue depth

  // ---------------------------------------------------------------- setup
  logic        text, flip, bank, opaque, fmt_a, packed_tx;
  logic [7:0]  ty;
  logic [9:0]  wmask;
  logic [22:0] gfx_base, map_base, tx_base;
  logic [16:0] tx_half;
  logic [9:0]  tile_mask, cbase;
  logic [11:0] tx_mask;
  logic [15:0] map_mask;
  logic [7:0]  reg1;

  wire [7:0] scy   = i_text ? i_tx_yscroll : i_reg3;
  wire [9:0] scx   = i_text ? 10'd0 : {2'b0, i_reg0};
  wire [9:0] wm    = i_text ? 10'd511 : 10'd1023;
  wire [9:0] tx0_c = (i_flip ? scx + 10'd447 : scx + 10'd64) & wm;
  wire [7:0] ty_c  = i_flip ? 8'(scy + 8'd255 - i_line) : 8'(i_line + scy);

  // ---------------------------------------------------------------- issue
  typedef enum logic [2:0] {I_IDLE, I_MAP, I_GRP, I_TXT, I_TXTW, I_TXB} istate_t;
  istate_t     is;
  logic [9:0]  ftx;                   // pixmap x of the current group's first pixel
  logic signed [10:0] frem;           // pixels still to be covered
  logic [3:0]  mk;                    // map request index
  logic [3:0]  gk;                    // column index of the current group
  logic [4:0]  c0;                    // first column
  logic [15:0] mapw [NCOL];
  logic [NCOL-1:0] mapv;
  logic [15:0] tattr;                 // text entry of the current char (split: for the 2nd request)
  logic [3:0]  inq;                   // groups requested and not yet consumed

  wire [2:0]  trow  = ty[7:5];
  wire [4:0]  tline = ty[4:0];
  wire [4:0]  mcol  = flip ? c0 - 5'(mk) : c0 + 5'(mk);
  wire [15:0] map_idx  = (16'({mcol, 3'b000}) + 16'(trow) + {2'b00, reg1, 6'b000000}) & map_mask;
  wire [22:0] map_addr = map_base + {6'b0, map_idx, 1'b0};

  // current group, tile mode
  wire [15:0] attr   = mapw[gk];
  wire [9:0]  a_code = (fmt_a ? {attr[15], attr[8:0]} : attr[9:0]) & tile_mask;
  wire [3:0]  a_col  = fmt_a ? attr[14:11] : attr[13:10];
  wire        a_fx   = fmt_a ? attr[9]  : attr[14];
  wire        a_fy   = fmt_a ? attr[10] : attr[15];
  wire [1:0]  grp    = ftx[4:3];
  wire [1:0]  gsel   = a_fx ? ~grp : grp;
  wire [4:0]  tl_sel = a_fy ? ~tline : tline;
  wire [22:0] tile_addr = gfx_base + {4'b0, a_code, 9'b0} + {14'b0, gsel, 7'b0} + {16'b0, tl_sel, 2'b0};

  // current group, text mode (the entry is on the RAM bus in I_TXTW)
  wire [15:0] t_ent   = (is == I_TXTW) ? i_txt_data : tattr;
  wire [11:0] t_char  = t_ent[11:0] & tx_mask;
  wire [22:0] ch_addr = packed_tx ? tx_base + {6'b0, t_char, 5'b0} + {15'b0, ty[2:0], 2'b0}
                                  : tx_base + {7'b0, t_char, 4'b0} + {16'b0, ty[2:0], 1'b0};
  wire [22:0] ch_addr2 = ch_addr + {6'b0, tx_half};
  assign o_txt_addr = {ftx[8:3], ty[7:3]};   // col * 32 + row

  wire [3:0]  gcount   = flip ? 4'(ftx[2:0]) + 4'd1 : 4'd8 - 4'(ftx[2:0]);
  wire signed [10:0] frem_n = frem - $signed({7'b0, gcount});
  wire [9:0]  ftx_next = (flip ? {ftx[9:3], 3'b000} - 10'd1 : {ftx[9:3], 3'b111} + 10'd1) & wmask;
  wire        col_step = flip ? (ftx[4:3] == 2'd0) : (ftx[4:3] == 2'd3);

  // in-flight record per accepted request: {kind[1:0], colour[3:0], sel, idx[3:0]}
  //   kind 0 map word (idx = table slot, sel = half), 1 tile or packed char
  //   word (sel = tile X flip), 2 split plane-0/1 half, 3 split plane-2/3
  //   half (sel = half)
  localparam int IFD = 32;
  logic [10:0] inflt [IFD];
  logic [4:0]  if_wp, if_rp;
  logic [10:0] if_push_d;
  wire         room = (inq < 4'(QD));

  always_comb begin
    o_rom_req  = 1'b0;
    o_rom_addr = '0;
    if_push_d  = '0;
    case (is)
      I_MAP: begin
        o_rom_req  = 1'b1;
        o_rom_addr = {map_addr[22:2], 2'b00};
        if_push_d  = {2'd0, 4'd0, map_addr[1], mk};
      end
      I_GRP: begin
        o_rom_req  = mapv[gk] && room;
        o_rom_addr = tile_addr;
        if_push_d  = {2'd1, a_col, a_fx, 4'd0};
      end
      I_TXTW: begin
        o_rom_req  = room;
        o_rom_addr = {ch_addr[22:2], 2'b00};
        if_push_d  = {packed_tx ? 2'd1 : 2'd2, t_ent[15:12], ch_addr[1], 4'd0};
      end
      I_TXB: begin
        o_rom_req  = 1'b1;
        o_rom_addr = {ch_addr2[22:2], 2'b00};
        if_push_d  = {2'd3, t_ent[15:12], ch_addr2[1], 4'd0};
      end
      default: ;
    endcase
  end
  wire acc      = o_rom_req && i_rom_gnt;
  wire grp_done = acc && (is == I_GRP || is == I_TXB || (is == I_TXTW && packed_tx));

  // ---------------------------------------------------------------- return
  logic [35:0] q [QD];                 // {colour, 8 pens in pixmap order}
  logic [2:0]  q_wp, q_rp;
  logic [3:0]  q_cnt;
  logic        pop;
  logic [35:0] q_d;
  logic [15:0] split_a;

  function automatic logic [3:0] dec_tile(logic [31:0] w, logic [2:0] p);
    logic [4:0] k;
    k = {3'b0, p[1:0]};
    if (!p[2]) return {w[5'd31 - k], w[5'd27 - k], w[5'd23 - k], w[5'd19 - k]};
    else       return {w[5'd15 - k], w[5'd11 - k], w[5'd7 - k],  w[5'd3 - k]};
  endfunction
  function automatic logic [3:0] dec_split(logic [15:0] a, logic [15:0] b, logic [2:0] p);
    logic [3:0] k;
    k = {2'b0, p[1:0]};
    if (!p[2]) return {a[4'd15 - k], a[4'd11 - k], b[4'd15 - k], b[4'd11 - k]};
    else       return {a[4'd7 - k],  a[4'd3 - k],  b[4'd7 - k],  b[4'd3 - k]};
  endfunction

  wire [10:0] rrec  = inflt[if_rp];
  wire [1:0]  rkind = rrec[10:9];
  wire [3:0]  rcol  = rrec[8:5];
  wire        rsel  = rrec[4];
  wire [15:0] rhalf = rsel ? i_rom_data[15:0] : i_rom_data[31:16];
  wire        q_push = i_rom_rv && (rkind == 2'd1 || rkind == 2'd3);

  always_comb begin
    q_d = '0;
    q_d[35:32] = rcol;
    for (int p = 0; p < 8; p++) begin
      logic [3:0] pen;
      if (text && packed_tx) pen = i_rom_data[31 - 4 * p -: 4];
      else if (text)         pen = dec_split(split_a, rhalf, 3'(p));
      else                   pen = dec_tile(i_rom_data, rsel ? 3'(7 - p) : 3'(p));
      q_d[4 * p +: 4] = pen;
    end
  end

  // ---------------------------------------------------------------- issue / return registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      is    <= I_IDLE;
      if_wp <= '0;
      if_rp <= '0;
      q_wp  <= '0;
      q_rp  <= '0;
      q_cnt <= '0;
      inq   <= '0;
      mapv  <= '0;
    end else begin
      case (is)
        I_MAP: if (acc) begin
          mk <= mk + 4'd1;
          if (mk == 4'(NCOL - 1)) is <= I_GRP;
        end
        I_GRP, I_TXB: if (acc) begin
          ftx  <= ftx_next;
          frem <= frem_n;
          if (!text && col_step) gk <= gk + 4'd1;
          is   <= (frem_n > 0) ? (text ? I_TXT : I_GRP) : I_IDLE;
        end
        I_TXT: is <= I_TXTW;                       // text RAM address registered
        I_TXTW: if (acc) begin
          tattr <= i_txt_data;
          if (!packed_tx) is <= I_TXB;
          else begin
            ftx  <= ftx_next;
            frem <= frem_n;
            is   <= (frem_n > 0) ? I_TXT : I_IDLE;
          end
        end
        default: ;
      endcase
      if (acc) begin
        inflt[if_wp] <= if_push_d;
        if_wp <= if_wp + 5'd1;
      end
      if (i_rom_rv) begin
        if_rp <= if_rp + 5'd1;
        if (rkind == 2'd0) begin
          mapw[rrec[3:0]] <= rhalf;
          mapv[rrec[3:0]] <= 1'b1;
        end
        if (rkind == 2'd2) split_a <= rhalf;
      end
      if (q_push) begin
        q[q_wp] <= q_d;
        q_wp <= q_wp + 3'd1;
      end
      if (pop) q_rp <= q_rp + 3'd1;
      q_cnt <= q_cnt + 4'(q_push) - 4'(pop);
      inq   <= inq + 4'(grp_done) - 4'(pop);

      if (i_start) begin
        text      <= i_text;
        flip      <= i_flip;
        bank      <= i_bank;
        opaque    <= i_text ? 1'b0 : i_opaque;
        fmt_a     <= i_fmt_a;
        packed_tx <= i_tx_packed;
        ty        <= ty_c;
        wmask     <= wm;
        gfx_base  <= i_gfx_base;
        map_base  <= i_map_base;
        tx_base   <= i_tx_base;
        tx_half   <= i_tx_half;
        tile_mask <= i_tile_mask;
        tx_mask   <= i_tx_mask;
        map_mask  <= i_map_mask;
        cbase     <= i_text ? 10'd0 : i_cbase;
        reg1      <= i_reg1;
        ftx       <= tx0_c;
        frem      <= 11'sd384;
        c0        <= tx0_c[9:5];
        mk        <= 4'd0;
        gk        <= 4'd0;
        mapv      <= '0;
        is        <= i_text ? I_TXT : I_MAP;
      end
    end
  end

  // ---------------------------------------------------------------- pixel unit
  logic        prun;
  logic [8:0]  px;
  logic [9:0]  ptx;
  wire  [35:0] head  = q[q_rp];
  wire  [3:0]  pix   = head[4 * ptx[2:0] +: 4];
  wire  [3:0]  hcol  = head[35:32];
  wire         gend  = flip ? (ptx[2:0] == 3'd0) : (ptx[2:0] == 3'd7);
  wire         step  = prun && q_cnt != 4'd0;
  assign pop = step && (gend || px == 9'd383);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      prun    <= 1'b0;
      o_lb_we <= 1'b0;
      o_done  <= 1'b0;
    end else begin
      o_lb_we <= 1'b0;
      o_done  <= 1'b0;
      if (i_start) begin
        prun <= 1'b1;
        px   <= 9'd0;
        ptx  <= tx0_c;
      end else if (step) begin
        o_lb_we  <= opaque || pix != 4'd15;
        o_lb_x   <= px;
        o_lb_pen <= {bank, cbase + {2'b00, hcol, pix}};
        ptx      <= (flip ? ptx - 10'd1 : ptx + 10'd1) & wmask;
        px       <= px + 9'd1;
        if (px == 9'd383) begin
          prun   <= 1'b0;
          o_done <= 1'b1;
        end
      end
    end
  end

endmodule
