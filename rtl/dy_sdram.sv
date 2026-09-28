// SDRAM controller for the Dooyong core (PLAN M4).
//
// One 16-bit SDRAM (MiSTer module: 4 banks x 8192 rows x 512 columns), the
// byte layout of PLAN 4.3 / tools/build_regions.py (the MRA streams exactly
// that image from byte 0). Clients, highest priority first:
//   download  ioctl bytes paired into words (the core is in reset)
//   OKI       jt6295 byte reads (address held until ok, jt style); rare,
//             and jt6295 stalls without data, so it outranks graphics
//   graphics  dy_video's pipelined 32-bit port: accepted on req && gnt,
//             data returned in order on rv; two words from one row
//   refresh   in idle gaps, forced ahead of grants when overdue
//
// Timing and protocol follow Hyper Duel's controller, proven on the MiSTer
// SDRAM board: close-page (ACT, tRCD, CAS with auto precharge on the last
// word), CL2, data captured P_RET cycles after the CAS command, full-word
// writes only (the board ties DQML/DQMH low, so byte masking is impossible),
// init = wait, PALL, 2x REF, MODE. SDRAM_CLK is the PLL's phase-shifted copy
// of clk.
//
// Byte lanes: even byte address = word[15:8] (the big-endian region view
// used everywhere in this project).

module dy_sdram #(
    parameter bit P_SHORT_INIT   = 1'b0,  // sim: skip the 100 us power-up wait
    parameter int P_RET          = 3,     // CAS command -> captured data, cycles
    parameter int REFRESH_PERIOD = 750,   // 7.8125 us at 96 MHz
    parameter int INIT_CYCLES    = 9600,  // 100 us at 96 MHz
    // tRCD and tRP in clocks. 3 at 96 MHz = 31 ns: the MiSTer modules'
    // AS4C32M16SB-7 is 21 ns, which 2 clocks (20.8 ns) would miss
    parameter int T_RCD          = 3,
    parameter int T_RP           = 3
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        o_ready,

    // download (byte writes)
    input  logic        i_dl_wr,
    input  logic [24:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,
    output logic        o_dl_busy,

    // graphics (dy_video ROM port)
    input  logic        i_gfx_req,
    input  logic [22:0] i_gfx_addr,     // byte address, 4-byte aligned
    output logic        o_gfx_gnt,
    output logic        o_gfx_rv,
    output logic [31:0] o_gfx_data,     // [31:24] = byte at the address

    // M6295 samples (byte address within the 256 KB OKI region)
    input  logic [17:0] i_oki_addr,
    output logic [7:0]  o_oki_data,
    output logic        o_oki_ok,

    // debug
    output logic [15:0] o_dbg_refreshes,
    output logic [15:0] o_dbg_dl_words,

    // SDRAM pins
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

  localparam logic [23:0] OKI_WBASE = 24'h040000;   // byte 0x080000

  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;
  localparam logic [12:0] MODE_REG = 13'h020;       // BL1, sequential, CL2
  localparam int INIT_WAIT = P_SHORT_INIT ? 32 : INIT_CYCLES;

  /* verilator lint_off PROCASSINIT */
  logic [3:0] cmd = CMD_NOP;
  /* verilator lint_on PROCASSINIT */
  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
  assign SDRAM_CKE = 1'b1;

  logic [15:0] dq_out;
  logic        dq_oe;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
  logic [15:0] dq_in;
  always_ff @(posedge clk) dq_in <= SDRAM_DQ;

  // return tags, in step with dq_in P_RET cycles after the CAS:
  // 0 none, 1 graphics word 0, 2 graphics word 1, 3 OKI
  logic [1:0] ret_tag [P_RET+1];
  always_ff @(posedge clk)
    for (int i = P_RET; i > 0; i--) ret_tag[i] <= ret_tag[i-1];
  wire [1:0] land = ret_tag[P_RET];

  // ------------------------------------------------------------------
  // download: pair bytes into words, small FIFO
  // ------------------------------------------------------------------
  logic [39:0] dlf [4];                 // {word address, data}
  logic [1:0]  dlf_wp, dlf_rp;
  logic [2:0]  dlf_cnt;
  logic        dlf_pop;
  logic [7:0]  dl_even;
  wire         dlf_empty = (dlf_cnt == 3'd0);
  assign o_dl_busy = (dlf_cnt >= 3'd2);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dlf_wp  <= '0;
      dlf_rp  <= '0;
      dlf_cnt <= '0;
    end else begin
      logic push;
      push = i_dl_wr && i_dl_addr[0];
      if (i_dl_wr && !i_dl_addr[0]) dl_even <= i_dl_data;
      if (push) begin
        dlf[dlf_wp] <= {i_dl_addr[24:1], dl_even, i_dl_data};
        dlf_wp <= dlf_wp + 2'd1;
      end
      if (dlf_pop) dlf_rp <= dlf_rp + 2'd1;
      dlf_cnt <= dlf_cnt + 3'(push) - 3'(dlf_pop);
    end
  end

  // ------------------------------------------------------------------
  // main FSM
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_INIT_WAIT, ST_INIT_PALL, ST_INIT_REF1, ST_INIT_REF2, ST_INIT_MODE,
    ST_IDLE, ST_ACT, ST_RCD, ST_CAS, ST_CAS2, ST_WAIT
  } st_e;
  st_e st;
  typedef enum logic [1:0] {OWN_GFX, OWN_OKI, OWN_DL} own_e;
  own_e owner;

  logic [23:0] cur_word;
  logic [15:0] dl_data_q;
  logic [3:0]  wait_cnt;
  logic [13:0] init_cnt;
  logic [9:0]  ref_cnt;
  logic        ref_due, ref_urgent;

  // OKI: serve whenever the address differs from the one held
  logic        oki_have, oki_pend, oki_busy;
  logic [17:0] oki_served, oki_q;
  wire         oki_want = !oki_have || (i_oki_addr != oki_served);

  wire idle_free = (st == ST_IDLE) && (wait_cnt == 4'd0) && !ref_urgent && dlf_empty && !oki_pend;
  assign o_gfx_gnt = idle_free;
  wire gfx_take = idle_free && i_gfx_req;

  always_ff @(posedge clk) begin
    cmd        <= CMD_NOP;
    SDRAM_A    <= '0;
    SDRAM_BA   <= cur_word[23:22];
    dq_oe      <= 1'b0;
    ret_tag[0] <= 2'd0;
    dlf_pop    <= 1'b0;

    if (!rst_n) begin
      st         <= ST_INIT_WAIT;
      owner      <= OWN_GFX;
      o_ready    <= 1'b0;
      init_cnt   <= '0;
      wait_cnt   <= '0;
      ref_cnt    <= '0;
      ref_due    <= 1'b0;
      ref_urgent <= 1'b0;
      oki_pend   <= 1'b0;
      oki_busy   <= 1'b0;
      SDRAM_DQML <= 1'b1;
      SDRAM_DQMH <= 1'b1;
      o_dbg_refreshes <= '0;
      o_dbg_dl_words  <= '0;
    end else begin
      if (32'(ref_cnt) == REFRESH_PERIOD - 1) begin
        ref_cnt    <= '0;
        ref_urgent <= ref_due;
        ref_due    <= 1'b1;
      end else ref_cnt <= ref_cnt + 10'd1;

      if (oki_want && !oki_pend && !oki_busy && st == ST_IDLE) begin
        oki_pend <= 1'b1;
        oki_q    <= i_oki_addr;
      end

      case (st)
        ST_INIT_WAIT: begin
          init_cnt <= init_cnt + 14'd1;
          if (32'(init_cnt) == INIT_WAIT) st <= ST_INIT_PALL;
        end
        ST_INIT_PALL: begin
          cmd <= CMD_PALL; SDRAM_A <= 13'h400;
          wait_cnt <= 4'd2; st <= ST_INIT_REF1;
        end
        ST_INIT_REF1:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
          else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_REF2; end
        ST_INIT_REF2:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
          else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_MODE; end
        ST_INIT_MODE:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
          else begin
            cmd <= CMD_MODE; SDRAM_A <= MODE_REG; SDRAM_BA <= 2'b00;
            wait_cnt <= 4'd2; st <= ST_IDLE; o_ready <= 1'b1;
          end

        ST_IDLE: begin
          SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
          else if (ref_urgent || (ref_due && dlf_empty && !i_gfx_req && !oki_pend)) begin
            cmd <= CMD_REF;
            ref_due <= 1'b0; ref_urgent <= 1'b0;
            o_dbg_refreshes <= o_dbg_refreshes + 16'd1;
            wait_cnt <= 4'd8; st <= ST_WAIT;
          end else if (!dlf_empty) begin
            owner     <= OWN_DL;
            cur_word  <= dlf[dlf_rp][39:16];
            dl_data_q <= dlf[dlf_rp][15:0];
            dlf_pop   <= 1'b1;
            st        <= ST_ACT;
          end else if (oki_pend) begin
            owner    <= OWN_OKI;
            cur_word <= OKI_WBASE + 24'(oki_q[17:1]);
            st       <= ST_ACT;
          end else if (gfx_take) begin
            owner    <= OWN_GFX;
            cur_word <= {1'b0, i_gfx_addr[22:1]};
            st       <= ST_ACT;
          end
        end

        ST_ACT: begin
          cmd <= CMD_ACT;
          SDRAM_A <= cur_word[21:9];
          wait_cnt <= 4'(T_RCD - 2);
          st <= ST_RCD;
        end
        ST_RCD:                                      // ACT .. CAS = T_RCD clocks
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
          else st <= ST_CAS;

        ST_CAS: begin
          if (owner == OWN_DL) begin
            cmd <= CMD_WRIT; dq_oe <= 1'b1;
            dq_out <= dl_data_q;
            SDRAM_A <= {4'b0010, cur_word[8:0]};     // auto precharge
            o_dbg_dl_words <= o_dbg_dl_words + 16'd1;
            wait_cnt <= 4'(T_RP + 1);                // tWR + tRP
            st <= ST_WAIT;
          end else if (owner == OWN_GFX) begin
            cmd <= CMD_READ;
            SDRAM_A <= {4'b0000, cur_word[8:0]};
            ret_tag[0] <= 2'd1;
            cur_word <= cur_word + 24'd1;
            st <= ST_CAS2;
          end else begin
            cmd <= CMD_READ;
            SDRAM_A <= {4'b0010, cur_word[8:0]};
            ret_tag[0] <= 2'd3;
            oki_pend <= 1'b0;
            oki_busy <= 1'b1;
            wait_cnt <= 4'(T_RP);
            st <= ST_IDLE;
          end
        end
        ST_CAS2: begin                               // second word, same row
          cmd <= CMD_READ;
          SDRAM_A <= {4'b0010, cur_word[8:0]};
          ret_tag[0] <= 2'd2;
          wait_cnt <= 4'(T_RP);
          st <= ST_IDLE;
        end

        ST_WAIT: begin
          SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
          else st <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase

      if (land == 2'd3) oki_busy <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // landing
  // ------------------------------------------------------------------
  logic [15:0] g_w0;
  always_ff @(posedge clk) begin
    o_gfx_rv <= 1'b0;
    if (!rst_n) begin
      oki_have   <= 1'b0;
      oki_served <= '0;
    end else begin
      if (land == 2'd1) g_w0 <= dq_in;
      if (land == 2'd2) begin
        o_gfx_data <= {g_w0, dq_in};
        o_gfx_rv   <= 1'b1;
      end
      if (land == 2'd3) begin
        o_oki_data <= oki_q[0] ? dq_in[7:0] : dq_in[15:8];
        oki_served <= oki_q;
        oki_have   <= 1'b1;
      end
    end
  end
  assign o_oki_ok = oki_have && (i_oki_addr == oki_served);

endmodule
