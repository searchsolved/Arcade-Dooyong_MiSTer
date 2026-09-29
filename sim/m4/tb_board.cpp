// M4 board harness for dy_board + SDRAM model (derived from sim/m2/tb_sys.cpp).
// The program ROMs, graphics and samples arrive through the ioctl download
// (the MRA stream = sdram.bin), through dy_sdram into the SDRAM model, as on
// the MiSTer. +dlen=N limits the streamed bytes (default: whole image).
//
//
// Downloads the main CPU ROM from the set's sdram.bin, resets, and runs the
// system from power-on. Displayed frame N = the pixels scanned out between
// vblank IRQ N and N+1 (vblank N = the N-th start of line 248, MAME's frame
// notifier). Requested frames are written as .rgbp (384 x 240 x 5: R, G, B,
// pen low, pen high), and at each requested vblank the video RAMs are dumped
// in the oracle's byte order (.pal/.txt/.spr/.wram). For each requested
// displayed frame, every CPU write to 0xC000-0xFFFF during it is logged in
// .wlog ("line hpos addr data", beam position at the write).
//
// Plusargs: +sdram=FILE +frames=N (run until vblank N) +cap=FILE (frame
// numbers to capture, one per line) +out=DIR +intv=N +lat=N (ROM model, see
// sim/m1/tb_video.cpp) +dswa=HEX +dswb=HEX +game=N (dy_pkg game ID)
// +inputs=FILE: lines "frame p1 p2 system" (hex bytes, active low), each
// applied from that vblank onward (input replay).
// Sound (M3): the sound ROM is downloaded from SDRAM 0x040000; the M6295
// reads its samples from SDRAM 0x080000 with +okilat=N clocks of latency
// after each address change. +snd=FILE logs every sound CPU write to
// 0xF808-0xF80A and to its ROM range as "vblank line hpos addr data" (the
// same beam position the MAME oracle logs). +wav=FILE writes the mono mix
// as 16-bit 48 kHz samples (raw, little-endian).

#include "Vtb_board.h"
#include "Vtb_board___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <map>
#include <set>
#include <tuple>
#include <string>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vtb_board> top;
static std::vector<uint8_t> sdram;
static uint64_t cycles = 0, last_acc = (uint64_t)-1000;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;

static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (a + i < sdram.size() ? sdram[a + i] : 0);
    return v;
}

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cycles++;
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

static void dump(const std::string &path, const void *p, size_t n) {
    std::ofstream o(path, std::ios::binary);
    o.write((const char *)p, n);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vtb_board>();
    std::string sd = plus("sdram", ""), out = plus("out", "."), capf = plus("cap", "");
    long nframes = atol(plus("frames", "600").c_str());
    int game = atoi(plus("game", "3").c_str());
    const size_t frame_px = (game == 5 || game == 6) ? 384 * 256 : 384 * 240;   // primella family: 256 lines
    std::string sndf = plus("snd", ""), wavf = plus("wav", "");
    FILE *fsnd = sndf.empty() ? nullptr : fopen(sndf.c_str(), "w");
    FILE *fwav = wavf.empty() ? nullptr : fopen(wavf.c_str(), "wb");
    std::string trf = plus("cputrace", "");       // sound CPU opcode fetch addresses
    FILE *ftr = trf.empty() ? nullptr : fopen(trf.c_str(), "w");
    bool m1_prev = true;
    const uint64_t clk_hz = 96000000;               // board sim runs the real 96 MHz clock
    uint64_t wav_acc = 0;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sd.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::set<long> cap;
    if (!capf.empty()) {
        std::ifstream f(capf);
        long n;
        while (f >> n) cap.insert(n);
    }

    std::map<long, std::tuple<int, int, int>> inputs;
    {
        std::string inf = plus("inputs", "");
        if (!inf.empty()) {
            std::ifstream f(inf);
            long n;
            std::string a, b, c;
            while (f >> n >> a >> b >> c)
                inputs[n] = {(int)strtol(a.c_str(), nullptr, 16), (int)strtol(b.c_str(), nullptr, 16),
                             (int)strtol(c.c_str(), nullptr, 16)};
        }
    }
    top->i_p1 = top->i_p2 = top->i_system = 0xFF;
    top->i_sdram_rst_n = 1;
    top->i_reset = 0;
    top->i_ioctl_download = 0;
    top->i_ioctl_wr = 0;
    for (int i = 0; i < 64; i++) tick();
    long dlen = strtol(plus("dlen", "0").c_str(), nullptr, 0);
    if (dlen <= 0 || dlen > (long)sdram.size()) dlen = sdram.size();
    auto ioctl = [&](int index, long addr, uint8_t d) {
        top->i_ioctl_index = index; top->i_ioctl_addr = addr; top->i_ioctl_dout = d;
        top->i_ioctl_wr = 1; tick(); top->i_ioctl_wr = 0;
        tick(); tick();                              // hps_io paces writes
        while (top->o_ioctl_wait) tick();
    };
    top->i_ioctl_download = 1;
    ioctl(1, 0, game);                               // MRA rom index 1: game ID
    top->i_ioctl_download = 0; for (int i = 0; i < 8; i++) tick();
    top->i_ioctl_download = 1;
    ioctl(254, 0, strtol(plus("dswa", "FF").c_str(), nullptr, 16));
    ioctl(254, 1, strtol(plus("dswb", "FF").c_str(), nullptr, 16));
    top->i_ioctl_download = 0; for (int i = 0; i < 8; i++) tick();
    top->i_ioctl_download = 1;
    for (long a = 0; a < dlen; a++) ioctl(0, a, sdram[a]);   // MRA rom index 0
    for (int i = 0; i < 64; i++) tick();             // drain the SDRAM write FIFO
    top->i_ioctl_download = 0;
    printf("download done: %ld bytes, %llu clocks\n", dlen, (unsigned long long)cycles);
    fflush(stdout);

    auto *r = top->rootp;
    long frame = 0;                                 // vblanks seen
    std::vector<uint8_t> px;
    px.reserve(384 * 240 * 5);
    std::string wlog;
    while (frame < nframes) {
        bool ce = r->tb_board__DOT__u_board__DOT__u_sys__DOT__ce_pix;          // enable going into this edge
        {   // OKI status reads: value on the bus at the end of the read cycle
            static bool rd_prev = true;
            bool rdn = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__rd_n;
            if (fsnd && rdn && !rd_prev && r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__A == 0xF80A)
                fprintf(fsnd, "R %ld %d %d %02x\n", frame, r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__vcnt,
                        r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__hcnt, r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__din);
            rd_prev = rdn;
        }
        if (fsnd && r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__wr) {
            uint16_t a = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__A;
            if (a >= 0xF808 && a <= 0xF80A || a < 0xF000)
                fprintf(fsnd, "%ld %d %d %04x %02x\n", frame, r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__vcnt,
                        r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__hcnt, a, r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__dout);
        }
        if (ftr) {
            bool m1 = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__m1_n;
            if (!m1 && m1_prev) fprintf(ftr, "%04X %llu\n", r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__A, (unsigned long long)(cycles / 24));
            m1_prev = m1;
        }
        if (fwav) {
            wav_acc += 48000;
            if (wav_acc >= clk_hz) {
                wav_acc -= clk_hz;
                int16_t v = (int16_t)top->o_audio;
                fwrite(&v, 2, 1, fwav);
            }
        }
        if (r->tb_board__DOT__u_board__DOT__u_sys__DOT__wr && r->tb_board__DOT__u_board__DOT__u_sys__DOT__A >= 0xC000 && cap.count(frame)) {
            char b[48];
            snprintf(b, sizeof b, "%d %d %04x %02x\n", r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__vcnt,
                     r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__hcnt, r->tb_board__DOT__u_board__DOT__u_sys__DOT__A, r->tb_board__DOT__u_board__DOT__u_sys__DOT__cpu_dout);
            wlog += b;
        }
        tick();
        if (ce && top->o_de) {
            px.push_back(top->o_r);
            px.push_back(top->o_g);
            px.push_back(top->o_b);
            px.push_back(top->o_pen & 0xFF);
            px.push_back(top->o_pen >> 8);
        }
        if (top->o_vbl_irq) {
            // close displayed frame `frame` (pixels since the previous vblank)
            if (frame > 0 && cap.count(frame)) {
                char fn[64];
                snprintf(fn, sizeof fn, "%s/%06ld.rgbp", out.c_str(), frame);
                if (px.size() != frame_px * 5)
                    fprintf(stderr, "frame %ld: %zu pixels\n", frame, px.size() / 5);
                dump(fn, px.data(), px.size());
                snprintf(fn, sizeof fn, "%s/%06ld.wlog", out.c_str(), frame);
                dump(fn, wlog.data(), wlog.size());
            }
            wlog.clear();
            px.clear();
            frame++;
            auto it = inputs.find(frame);
            if (it != inputs.end()) {
                top->i_p1 = std::get<0>(it->second);
                top->i_p2 = std::get<1>(it->second);
                top->i_system = std::get<2>(it->second);
            }
            if (cap.count(frame)) {
                // RAM state at vblank N (MAME's frame notifier point)
                char fn[64];
                std::vector<uint8_t> b;
                b.resize(4096);
                for (int i = 0; i < 2048; i++) {        // palette, CPU byte order
                    uint16_t w = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__u_pal__DOT__mem[i];
                    b[2 * i] = w & 0xFF; b[2 * i + 1] = w >> 8;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.pal", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 2048; i++) {        // text, logical big-endian words
                    uint16_t w = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__u_txt__DOT__mem[i];
                    b[2 * i] = w >> 8; b[2 * i + 1] = w & 0xFF;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.txt", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 1024; i++) {       // sprite RAM, 32-bit words, byte 4w in [31:24]
                    uint32_t w = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_video__DOT__u_spr_live__DOT__mem[i];
                    for (int k = 0; k < 4; k++) b[4 * i + k] = (w >> (24 - 8 * k)) & 0xFF;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.spr", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 4096; i++) b[i] = r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_wram__DOT__mem[i];
                snprintf(fn, sizeof fn, "%s/%06ld.wram", out.c_str(), frame); dump(fn, b.data(), 4096);
            }
            if (fsnd)
                fprintf(fsnd, "# vblank %ld oki busy %x start %x stop %x\n", frame,
                        r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__u_oki__DOT__busy, r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__u_oki__DOT__start,
                        r->tb_board__DOT__u_board__DOT__u_sys__DOT__u_snd__DOT__u_oki__DOT__stop);
            if (frame % 100 == 0) {
                printf("vblank %ld overruns %d maxcyc %d\n", frame, top->o_dbg_overruns, top->o_dbg_maxcyc);
                fflush(stdout);
            }
        }
    }
    printf("DONE vblanks %ld cycles %llu overruns %d maxcyc %d\n", frame,
           (unsigned long long)cycles, top->o_dbg_overruns, top->o_dbg_maxcyc);
    if (fsnd) fclose(fsnd);
    if (fwav) fclose(fwav);
    if (ftr) fclose(ftr);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(0);
}
