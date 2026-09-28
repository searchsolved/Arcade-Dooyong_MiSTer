// Dooyong Z80-family main system (PLAN M2): main Z80, program ROM, work RAM,
// bus decode, control registers, inputs, and the video (dy_video).
//
// The sound CPU side (Z80, YM, OKI) is M3; the main CPU only writes the
// sound latch and never reads anything back (spec 4), so the main system
// runs the same without it. The latch value is exported for M3.
//
// Clocks: one system clock (96 MHz on hardware; the simulation may run it
// lower). CPU enable = clk / CPU_DIV (8 MHz). The pixel enable comes from a
// fractional divider: PIX_NUM / PIX_DEN of the clock. MAME's parity frame
// is 512 x 256 at 60 Hz = 7,864,320 pixels per second (spec 5.3), which
// keeps the CPU/video cycle ratio identical to MAME's for M2 comparisons.
// The shipped geometry is an M4 decision (R1).
//
// Program ROM is in BRAM (zero wait states, as MAME's Z80 has none; no
// SDRAM arbitration with the renderer). Loaded through the download port.
//
// Games: flytiger and bluehawk memory maps (spec 3.4, 3.5).

module dy_sys #(
    parameter int CPU_DIV = 12,
    parameter int PIX_NUM = 786432,        // 7,864,320 / 10
    parameter int PIX_DEN = 9600000        // 96,000,000 / 10
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]  i_game,

    // program ROM download (main CPU region, 128 KB)
    input  logic        i_dl_we,
    input  logic [16:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,

    // inputs, active low (spec 9.2, 9.3)
    input  logic [7:0]  i_p1,
    input  logic [7:0]  i_p2,
    input  logic [7:0]  i_system,
    input  logic [7:0]  i_dswa,
    input  logic [7:0]  i_dswb,

    // graphics ROM port (see dy_video)
    output logic        o_rom_req,
    output logic [22:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,

    // video
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic [11:0] o_pen,
    output logic        o_vbl_irq,

    // to the sound side (M3)
    output logic [7:0]  o_snd_latch,
    output logic        o_snd_latch_we,

    // debug / gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [15:0] o_dbg_rom_writes,  // writes into 0x0000-0xBFFF (spec 3.8, T2)
    output logic [15:0] o_dbg_bank_hi,     // bankswitch writes with bits 3-7 set
    output logic [15:0] o_cpu_pc_dbg       // address of the last opcode fetch
);

  import dy_pkg::*;

  // ================================================================ enables
  logic [4:0]  cpu_cnt;
  logic        ce_cpu;
  logic        ce_pix /* verilator public_flat_rd */;
  logic [23:0] pix_acc;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cpu_cnt <= '0;
      ce_cpu  <= 1'b0;
      ce_pix  <= 1'b0;
      pix_acc <= '0;
    end else begin
      ce_cpu  <= (cpu_cnt == 5'd0);
      cpu_cnt <= (cpu_cnt == 5'(CPU_DIV - 1)) ? 5'd0 : cpu_cnt + 5'd1;
      if (pix_acc + 24'(PIX_NUM) >= 24'(PIX_DEN)) begin
        pix_acc <= pix_acc + 24'(PIX_NUM) - 24'(PIX_DEN);
        ce_pix  <= 1'b1;
      end else begin
        pix_acc <= pix_acc + 24'(PIX_NUM);
        ce_pix  <= 1'b0;
      end
    end
  end

  // ================================================================ CPU
  logic [15:0] A /* verilator public_flat_rd */;
  logic [7:0]  cpu_dout /* verilator public_flat_rd */;
  logic [7:0]  cpu_din;
  logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
  logic        int_n;

  T80s u_cpu (
    .RESET_n(rst_n), .CLK(clk), .CEN(ce_cpu),
    .WAIT_n(1'b1), .INT_n(int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .DI(cpu_din),
    .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
    .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
    .A(A), .DOUT(cpu_dout));

  // vblank IRQ, held until acknowledged (irq0_line_hold, spec 5.1); the
  // acknowledge cycle reads 0xFF (RST 38h in IM0, ignored in IM1)
  wire int_ack = !m1_n && !iorq_n;
  logic vbl_irq;
  always_ff @(posedge clk) begin
    if (!rst_n)       int_n <= 1'b1;
    else if (vbl_irq) int_n <= 1'b0;
    else if (int_ack) int_n <= 1'b1;
  end

  // ================================================================ decode
  wire is_ft = (i_game == G_FLYTIGER);
  wire is_bh = (i_game == G_BLUEHAWK);
  wire mem   = !mreq_n && rfsh_n;

  typedef enum logic [3:0] {
    D_NONE, D_ROM, D_BANK, D_WRAM, D_SPR, D_PAL, D_TXT, D_IO
  } dsel_t;
  dsel_t sel;
  always_comb begin
    sel = D_NONE;
    if (A[15] == 1'b0)          sel = D_ROM;
    else if (A[15:14] == 2'b10) sel = D_BANK;
    else if (is_ft) begin
      case (A[15:12])
        4'hC: sel = D_SPR;
        4'hD: sel = D_WRAM;
        4'hE: sel = A[11] ? D_PAL : D_IO;
        4'hF: sel = D_TXT;
        default: ;
      endcase
    end else if (is_bh) begin
      case (A[15:12])
        4'hC: sel = A[11] ? D_PAL : D_IO;
        4'hD: sel = D_TXT;
        4'hE: sel = D_SPR;
        4'hF: sel = D_WRAM;
        default: ;
      endcase
    end
  end

  // write strobe: one clock at the start of each memory write cycle
  logic wr_q;
  always_ff @(posedge clk) wr_q <= mem && !wr_n;
  wire wr /* verilator public_flat_rd */ = mem && !wr_n && !wr_q;

  // ================================================================ memories
  logic [2:0]  bank;
  logic [7:0]  rom_q, wram_q;
  wire  [16:0] rom_a = (sel == D_BANK) ? {bank, A[13:0]} : {2'b00, A[14:0]};
  dy_dpram #(.AW(17), .DW(8)) u_rom (
    .clk(clk),
    .addr_a(i_dl_addr), .d_a(i_dl_data), .we_a(i_dl_we), .be_a(1'b1), .q_a(),
    .addr_b(rom_a), .q_b(rom_q));

  dy_dpram #(.AW(12), .DW(8)) u_wram (
    .clk(clk),
    .addr_a(A[11:0]), .d_a(cpu_dout), .we_a(wr && sel == D_WRAM), .be_a(1'b1), .q_a(wram_q),
    .addr_b(12'd0), .q_b());

  // ================================================================ registers
  logic [7:0] ctrl;
  logic       flip, pal_bank, pri_swap;
  always_comb begin
    flip     = 1'b0;
    pal_bank = 1'b0;
    pri_swap = 1'b0;
    if (is_ft) begin
      flip     = ctrl[0];
      pal_bank = ctrl[3];
      pri_swap = ctrl[4];
    end else if (is_bh) begin
      flip     = ctrl != 8'd0;          // whole byte (spec 9.1)
    end
  end

  // I/O page offsets (A[11:0] within 0xE000 on flytiger, 0xC000 on bluehawk)
  wire [11:0] io = A[11:0];
  logic       tm_we;
  logic [1:0] tm_layer;
  logic       io_bank_w, io_ctrl_w, io_latch_w;
  always_comb begin
    tm_we      = 1'b0;
    tm_layer   = 2'd0;
    io_bank_w  = 1'b0;
    io_ctrl_w  = 1'b0;
    io_latch_w = 1'b0;
    if (wr && sel == D_IO) begin
      if (is_ft) begin
        io_bank_w  = io == 12'h000;
        io_ctrl_w  = io == 12'h010;
        io_latch_w = io == 12'h020;
        if (io[11:3] == 9'h006) begin tm_we = 1'b1; tm_layer = 2'd0; end   // E030-E037 bg0
        if (io[11:3] == 9'h008) begin tm_we = 1'b1; tm_layer = 2'd1; end   // E040-E047 fg0
      end else if (is_bh) begin
        io_ctrl_w  = io == 12'h000;                                         // flip_screen_w
        io_bank_w  = io == 12'h008;
        io_latch_w = io == 12'h010;
        if (io[11:3] == 9'h003) begin tm_we = 1'b1; tm_layer = 2'd2; end   // C018-C01F fg1
        if (io[11:3] == 9'h008) begin tm_we = 1'b1; tm_layer = 2'd0; end   // C040-C047 bg0
        if (io[11:3] == 9'h009) begin tm_we = 1'b1; tm_layer = 2'd1; end   // C048-C04F fg0
      end
    end
  end

  logic [7:0] io_q;
  always_comb begin
    io_q = 8'h00;                      // unmapped reads return 0 (spec 3)
    if (is_ft) begin
      case (io)
        12'h000: io_q = i_p1;
        12'h002: io_q = i_p2;
        12'h004: io_q = i_system;
        12'h006: io_q = i_dswa;
        12'h008: io_q = i_dswb;
        default: ;
      endcase
    end else if (is_bh) begin
      case (io)
        12'h000: io_q = i_dswa;
        12'h001: io_q = i_dswb;
        12'h002: io_q = i_p1;
        12'h003: io_q = i_p2;
        12'h004: io_q = i_system;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    o_snd_latch_we <= 1'b0;
    if (!rst_n) begin
      bank             <= 3'd0;
      ctrl             <= 8'd0;
      o_snd_latch      <= 8'd0;
      o_dbg_rom_writes <= '0;
      o_dbg_bank_hi    <= '0;
    end else begin
      if (io_bank_w) begin
        bank <= cpu_dout[2:0];
        if (cpu_dout[7:3] != 5'd0) o_dbg_bank_hi <= o_dbg_bank_hi + 16'd1;
      end
      if (io_ctrl_w) ctrl <= cpu_dout;
      if (io_latch_w) begin
        o_snd_latch    <= cpu_dout;
        o_snd_latch_we <= 1'b1;
      end
      if (wr && (sel == D_ROM || sel == D_BANK)) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
    end
    if (!m1_n && mem) o_cpu_pc_dbg <= A;
  end

  // ================================================================ video
  wire [11:0] pal_a = is_ft ? {pal_bank, A[10:0]} : {1'b0, A[10:0]};
  wire        v_pal_we = wr && sel == D_PAL;
  wire        v_txt_we = wr && sel == D_TXT;
  wire        v_spr_we = wr && sel == D_SPR;
  wire [11:0] v_addr   = (sel == D_PAL) ? pal_a : A[11:0];
  logic [7:0] pal_q, txt_q, spr_q;

  dy_video u_video (
    .clk(clk), .rst_n(rst_n), .ce_pix(ce_pix), .i_game(i_game),
    .i_cpu_addr(v_addr), .i_cpu_din(cpu_dout),
    .i_pal_we(v_pal_we), .i_txt_we(v_txt_we), .i_spr_we(v_spr_we),
    .o_pal_dout(pal_q), .o_txt_dout(txt_q), .o_spr_dout(spr_q),
    .i_tm_we(tm_we), .i_tm_layer(tm_layer), .i_tm_reg(A[2:0]), .i_tm_din(cpu_dout),
    .i_flip(flip), .i_pal_bank(pal_bank), .i_pri_swap(pri_swap), .i_spr_disable(1'b0),
    .o_rom_req(o_rom_req), .o_rom_addr(o_rom_addr),
    .i_rom_gnt(i_rom_gnt), .i_rom_rv(i_rom_rv), .i_rom_data(i_rom_data),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de),
    .o_hblank(o_hblank), .o_vblank(o_vblank), .o_hs(o_hs), .o_vs(o_vs),
    .o_pen(o_pen), .o_vbl_irq(vbl_irq),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc));
  assign o_vbl_irq = vbl_irq;

  // ================================================================ read mux
  // registered every clock; RAM outputs are one clock behind the address,
  // so the value is settled long before the CPU samples it (CPU_DIV clocks)
  always_ff @(posedge clk) begin
    if (int_ack) cpu_din <= 8'hFF;
    else begin
      case (sel)
        D_ROM, D_BANK: cpu_din <= rom_q;
        D_WRAM:        cpu_din <= wram_q;
        D_SPR:         cpu_din <= spr_q;
        D_PAL:         cpu_din <= pal_q;
        D_TXT:         cpu_din <= txt_q;
        D_IO:          cpu_din <= io_q;
        default:       cpu_din <= 8'h00;
      endcase
    end
  end

  wire unused = &{1'b0, halt_n, busak_n, rd_n};

endmodule
