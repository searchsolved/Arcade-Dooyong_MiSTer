// M2 full-system harness for dy_sys (Verilator, C++).
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

#include "Vdy_sys.h"
#include "Vdy_sys___024root.h"
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

static std::unique_ptr<Vdy_sys> top;
static std::vector<uint8_t> sdram;
static int lat = 5, intv = 4;
static uint64_t cycles = 0, last_acc = (uint64_t)-1000;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;

static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (a + i < sdram.size() ? sdram[a + i] : 0);
    return v;
}

static void tick() {
    bool rv = !rq.empty() && rq.front().t <= cycles;
    top->i_rom_rv = rv;
    if (rv) { top->i_rom_data = rq.front().d; rq.pop_front(); }
    bool gnt = cycles - last_acc >= (uint64_t)intv;
    top->i_rom_gnt = gnt;
    top->clk = 0; top->eval();
    if (gnt && top->o_rom_req) {
        rq.push_back({cycles + (uint64_t)lat, rd32(top->o_rom_addr)});
        last_acc = cycles;
    }
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
    top = std::make_unique<Vdy_sys>();
    std::string sd = plus("sdram", ""), out = plus("out", "."), capf = plus("cap", "");
    long nframes = atol(plus("frames", "600").c_str());
    lat = atoi(plus("lat", "5").c_str());
    intv = atoi(plus("intv", "4").c_str());
    int game = atoi(plus("game", "3").c_str());
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
    top->i_game = game;
    top->i_p1 = top->i_p2 = top->i_system = 0xFF;
    top->i_dswa = strtol(plus("dswa", "FF").c_str(), nullptr, 16);
    top->i_dswb = strtol(plus("dswb", "FF").c_str(), nullptr, 16);
    top->rst_n = 0;
    top->i_dl_we = 0;
    for (int i = 0; i < 8; i++) tick();
    for (int a = 0; a < 0x20000; a++) {            // main CPU region at SDRAM 0
        top->i_dl_we = 1; top->i_dl_addr = a; top->i_dl_data = sdram[a];
        tick();
    }
    top->i_dl_we = 0;
    for (int i = 0; i < 8; i++) tick();
    top->rst_n = 1;

    auto *r = top->rootp;
    long frame = 0;                                 // vblanks seen
    std::vector<uint8_t> px;
    px.reserve(384 * 240 * 5);
    std::string wlog;
    while (frame < nframes) {
        bool ce = r->dy_sys__DOT__ce_pix;          // enable going into this edge
        if (r->dy_sys__DOT__wr && r->dy_sys__DOT__A >= 0xC000 && cap.count(frame)) {
            char b[48];
            snprintf(b, sizeof b, "%d %d %04x %02x\n", r->dy_sys__DOT__u_video__DOT__vcnt,
                     r->dy_sys__DOT__u_video__DOT__hcnt, r->dy_sys__DOT__A, r->dy_sys__DOT__cpu_dout);
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
                if (px.size() != 384 * 240 * 5)
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
                    uint16_t w = r->dy_sys__DOT__u_video__DOT__u_pal__DOT__mem[i];
                    b[2 * i] = w & 0xFF; b[2 * i + 1] = w >> 8;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.pal", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 2048; i++) {        // text, logical big-endian words
                    uint16_t w = r->dy_sys__DOT__u_video__DOT__u_txt__DOT__mem[i];
                    b[2 * i] = w >> 8; b[2 * i + 1] = w & 0xFF;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.txt", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 1024; i++) {       // sprite RAM, 32-bit words, byte 4w in [31:24]
                    uint32_t w = r->dy_sys__DOT__u_video__DOT__u_spr_live__DOT__mem[i];
                    for (int k = 0; k < 4; k++) b[4 * i + k] = (w >> (24 - 8 * k)) & 0xFF;
                }
                snprintf(fn, sizeof fn, "%s/%06ld.spr", out.c_str(), frame); dump(fn, b.data(), 4096);
                for (int i = 0; i < 4096; i++) b[i] = r->dy_sys__DOT__u_wram__DOT__mem[i];
                snprintf(fn, sizeof fn, "%s/%06ld.wram", out.c_str(), frame); dump(fn, b.data(), 4096);
            }
            if (frame % 100 == 0) {
                printf("vblank %ld pc %04x overruns %d maxcyc %d romwr %d bankhi %d\n", frame,
                       top->o_cpu_pc_dbg, top->o_dbg_overruns, top->o_dbg_maxcyc,
                       top->o_dbg_rom_writes, top->o_dbg_bank_hi);
                fflush(stdout);
            }
        }
    }
    printf("DONE vblanks %ld cycles %llu overruns %d maxcyc %d romwr %d bankhi %d\n", frame,
           (unsigned long long)cycles, top->o_dbg_overruns, top->o_dbg_maxcyc,
           top->o_dbg_rom_writes, top->o_dbg_bank_hi);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(0);
}
