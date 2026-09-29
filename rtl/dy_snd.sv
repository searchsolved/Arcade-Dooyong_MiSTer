// Dooyong sound system, YM2151 variant (PLAN M3; spec 2, 4): sound Z80,
// sound ROM (BRAM), 2 KB RAM, sound latch, YM2151 (jt51), M6295 (jt6295).
// Used by flytiger, bluehawk and the primella family (and later the 68000
// games, which share this map).
//
// Sound map (spec 4, YM2151 games): 0x0000-0xEFFF ROM, 0xF000-0xF7FF RAM,
// 0xF800 latch (read; no NMI, reading does not clear), 0xF808-0xF809
// YM2151, 0xF80A M6295. Unmapped reads return 0. The YM2151 IRQ drives the
// Z80 INT line directly; the acknowledge cycle reads 0xFF.
//
// Clock enables from the system clock:
//   CPU  : clk / CPU_DIV (4 MHz)
//   YM   : fractional YM_NUM / YM_DEN of clk (3.579545 MHz on flytiger,
//          bluehawk "3.579545MHz or 4Mhz ???" in MAME, spec 2), or
//          YM4_NUM / YM_DEN with i_ym_4m (4 MHz, primella family); cen_p1 is
//          every other YM enable, as jt51 expects
//   OKI  : clk / OKI_DIV (1 MHz), pin 7 high (ss = 1, sample rate /132)
//
// Mix (MAME parity, spec 2, driver 1492-1495): YM2151 left and right at
// 0.35 each and the M6295 at 0.42 into one mono speaker. jt51's xleft /
// xright are 16-bit full scale; jt6295's sound is the sum of the channels
// in 12-bit units, which MAME converts at 1/2048 of full scale, so the
// OKI term is 0.42 * 16 = 6.72 in 16-bit units. Calibrated in M3 against
// MAME's WAV output (m3_findings).

module dy_snd #(
    parameter int CPU_DIV = 24,
    parameter int YM_NUM  = 3579545,
    parameter int YM4_NUM = 4000000,  // with i_ym_4m (primella family)
    parameter int YM_DEN  = 96000000,
    parameter int OKI_DIV = 96,
    parameter int YM_GAIN  = 90,     // x/256: 0.352
    parameter int OKI_GAIN = 1720    // x/256: 6.72
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_ym_4m,       // YM clock YM4_NUM / YM_DEN instead

    // sound ROM download (64 KB)
    input  logic        i_dl_we,
    input  logic [15:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,

    input  logic [7:0]  i_latch,

    // M6295 sample ROM (256 KB); data valid when i_oki_ok
    output logic [17:0] o_oki_addr,
    input  logic [7:0]  i_oki_data,
    input  logic        i_oki_ok,

    output logic signed [15:0] o_audio,
    output logic signed [15:0] o_ym_l,
    output logic signed [15:0] o_ym_r,
    output logic signed [13:0] o_oki,

    // debug
    output logic [15:0] o_dbg_rom_writes
);

  // ================================================================ enables
  logic [5:0]  cpu_cnt, oki_cnt;
  logic        ce_cpu, ym_cen, ym_ph, oki_cen;
  logic [27:0] ym_acc;
  wire  [27:0] ym_num = i_ym_4m ? 28'(YM4_NUM) : 28'(YM_NUM);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cpu_cnt <= '0;
      oki_cnt <= '0;
      ce_cpu  <= 1'b0;
      ym_cen  <= 1'b0;
      ym_ph   <= 1'b0;
      oki_cen <= 1'b0;
      ym_acc  <= '0;
    end else begin
      ce_cpu  <= (cpu_cnt == 6'd0);
      cpu_cnt <= (cpu_cnt == 6'(CPU_DIV - 1)) ? 6'd0 : cpu_cnt + 6'd1;
      oki_cen <= (oki_cnt == 6'd0);
      oki_cnt <= (oki_cnt == 6'(OKI_DIV - 1)) ? 6'd0 : oki_cnt + 6'd1;
      if (ym_acc + ym_num >= 28'(YM_DEN)) begin
        ym_acc <= ym_acc + ym_num - 28'(YM_DEN);
        ym_cen <= 1'b1;
        ym_ph  <= !ym_ph;
      end else begin
        ym_acc <= ym_acc + ym_num;
        ym_cen <= 1'b0;
      end
    end
  end
  wire ym_cen_p1 = ym_cen && ym_ph;

  // ================================================================ CPU
  logic [15:0] A /* verilator public_flat_rd */;
  logic [7:0]  dout /* verilator public_flat_rd */;
  logic [7:0]  din /* verilator public_flat_rd */;
  logic        m1_n /* verilator public_flat_rd */;
  logic        rd_n /* verilator public_flat_rd */;
  logic        mreq_n, iorq_n, wr_n, rfsh_n, halt_n, busak_n;
  logic        ym_irq_n;

  T80s u_cpu (
    .RESET_n(rst_n), .CLK(clk), .CEN(ce_cpu),
    .WAIT_n(1'b1), .INT_n(ym_irq_n), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
    .DI(din),
    .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
    .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
    .A(A), .DOUT(dout));

  wire mem     = !mreq_n && rfsh_n;
  wire int_ack = !m1_n && !iorq_n;
  logic wr_q;
  always_ff @(posedge clk) wr_q <= mem && !wr_n;
  wire wr /* verilator public_flat_rd */ = mem && !wr_n && !wr_q;

  wire s_rom  = A < 16'hF000;
  wire s_ram  = A[15:11] == 5'b11110;           // F000-F7FF
  wire s_lat  = A == 16'hF800;
  wire s_ym   = A[15:1] == 15'h7C04;           // F808-F809
  wire s_oki  = A == 16'hF80A;

  // ================================================================ memories
  logic [7:0] rom_q, ram_q;
  dy_dpram #(.AW(16), .DW(8)) u_rom (
    .clk(clk),
    .addr_a(i_dl_addr), .d_a(i_dl_data), .we_a(i_dl_we), .be_a(1'b1), .q_a(),
    .addr_b(A), .q_b(rom_q));
  dy_dpram #(.AW(11), .DW(8)) u_ram (
    .clk(clk),
    .addr_a(A[10:0]), .d_a(dout), .we_a(wr && s_ram), .be_a(1'b1), .q_a(ram_q),
    .addr_b(11'd0), .q_b());

  // ================================================================ chips
  logic [7:0] ym_dout, oki_dout;
  logic signed [15:0] ym_xl, ym_xr;
  jt51 u_ym (
    .rst(!rst_n), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
    .cs_n(!(wr && s_ym)), .wr_n(1'b0), .a0(A[0]), .din(dout),
    .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(), .left(), .right(), .xleft(ym_xl), .xright(ym_xr));

  logic signed [13:0] oki_snd;
  jt6295 #(.INTERPOL(0)) u_oki (
    .rst(!rst_n), .clk(clk), .cen(oki_cen), .ss(1'b1),
    .wrn(!(wr && s_oki)), .din(dout), .dout(oki_dout),
    .rom_addr(o_oki_addr), .rom_data(i_oki_data), .rom_ok(i_oki_ok),
    .sound(oki_snd), .sample());

  always_ff @(posedge clk) begin
    if (int_ack)    din <= 8'hFF;
    else if (s_rom) din <= rom_q;
    else if (s_ram) din <= ram_q;
    else if (s_lat) din <= i_latch;
    else if (s_ym)  din <= ym_dout;
    else if (s_oki) din <= oki_dout;
    else            din <= 8'h00;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) o_dbg_rom_writes <= '0;
    else if (wr && s_rom) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
  end

  // ================================================================ mix
  assign o_ym_l = ym_xl;
  assign o_ym_r = ym_xr;
  assign o_oki  = oki_snd;
  always_comb begin
    logic signed [27:0] m;
    m = (((28'(ym_xl) + 28'(ym_xr)) * $signed(28'(YM_GAIN))) + (28'(oki_snd) * $signed(28'(OKI_GAIN)))) >>> 8;
    if (m > 28'sd32767)       o_audio = 16'sd32767;
    else if (m < -28'sd32768) o_audio = -16'sd32768;
    else                      o_audio = m[15:0];
  end

  wire unused = &{1'b0, halt_n, busak_n, rd_n};

endmodule
