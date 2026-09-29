// M1 frame-replay harness for dy_video (Verilator, C++).
//
// For each frame file in the list: load the frame state through the CPU
// ports with the pixel enable stopped just before line 248, then run one
// full 512 x 256 frame: the registers latch and the sprite list is copied
// at line 248, lines 8-247 of the next frame are rendered and scanned out,
// and every o_de pixel is captured.
//
// Frame file (.dyf, written by sim/m1/replay.py):
//   "DYF1", game u8, flags u8 (0 flip, 1 palette bank, 2 flytiger priority /
//   primella text priority / 68000 bg2 priority, 3 lastday sprite disable),
//   npal u16 LE, 32 tilemap register bytes (bg0, fg0, fg1, bg1 x reg 0-7),
//   npal palette bytes (CPU order), 4096 text bytes (CPU offsets, per-game
//   layout), 4096 sprite bytes (CPU order). The 68000 games (7-9) write
//   palette and sprites as big-endian 16-bit words.
// Output (.rgbp): 384 x 240 x 5 bytes: R, G, B, pen low, pen high
// (pen bit 11 = black pen).
// Primella family (game 5, 6; flags bit 2 = text below fg0): these games
// latch at the start of line 255 and show lines 0-255, so each frame is
// loaded at line 255 (palette at line 0) and captured as 384 x 256 x 5 bytes.
//
// Plusargs: +sdram=FILE +list=FILE (lines "in out") +div=N (clocks per
// pixel, default 12 = 96 MHz / 8 MHz). ROM model: pipelined, in order; one
// request accepted every +intv=N clocks (default 8), data returned +lat=N
// clocks after acceptance (default 9). The defaults approximate a
// close-page 16-bit SDRAM at 96 MHz doing 32-bit reads with no bank
// overlap (Hyper Duel's controller policy), i.e. a pessimistic port.

#include "Vdy_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>
#include <deque>
#include <unistd.h>

static std::unique_ptr<Vdy_video> top;
static std::vector<uint8_t> sdram;
static int lat = 9, intv = 8, divn = 12;
static uint64_t cycles = 0, last_acc = 0;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;

static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (a + i < sdram.size() ? sdram[a + i] : 0);
    return v;
}

// one clock; ce selects whether this clock carries the pixel enable
static void tick(bool ce) {
    top->ce_pix = ce;
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

static void run_pixel(bool &ce_out) {
    // divn clocks, the first carries ce
    for (int i = 0; i < divn; i++) tick(i == 0);
    ce_out = true;
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vdy_video>();
    std::string sd = plus("sdram", ""), list = plus("list", "");
    lat = atoi(plus("lat", "9").c_str());
    intv = atoi(plus("intv", "8").c_str());
    divn = atoi(plus("div", "12").c_str());
    last_acc = (uint64_t)-1000;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sd.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::vector<std::pair<std::string, std::string>> frames;
    {
        std::ifstream f(list);
        std::string a, b;
        while (f >> a >> b) frames.push_back({a, b});
    }
    if (frames.empty()) { fprintf(stderr, "empty list\n"); return 2; }

    // game id from the first frame
    std::vector<uint8_t> fb;
    auto load = [&](const std::string &p) {
        std::ifstream f(p, std::ios::binary);
        fb.assign(std::istreambuf_iterator<char>(f), {});
        return fb.size() > 32 && memcmp(fb.data(), "DYF1", 4) == 0;
    };
    if (!load(frames[0].first)) { fprintf(stderr, "bad frame %s\n", frames[0].first.c_str()); return 2; }
    top->i_game = fb[4];
    const bool prm = fb[4] == 5 || fb[4] == 6;
    const int start_line = prm ? 255 : 248, lines = prm ? 256 : 240;
    top->rst_n = 0;
    top->i_pal_we = top->i_txt_we = top->i_spr_we = top->i_tm_we = 0;
    for (int i = 0; i < 16; i++) tick(false);
    top->rst_n = 1;
    tick(false);
    // advance to the start of the latch line (ce not yet given for h=0).
    // The counters start at line 248 (0 on the primella family, dy_video
    // power-on phase) and the first vblank is one frame later, so the
    // normal games run one full frame to reach their first line 248.
    bool dummy;
    const int reset_line = prm ? 0 : 248;
    long adv = ((start_line - reset_line) % 256 + 256) % 256;
    if (adv == 0) adv = 256;
    for (long i = 0; i < adv * 512; i++) run_pixel(dummy);

    int bad = 0;
    // CPU writes with the pixel enable stopped
    const bool m68k = fb[4] >= 7 && fb[4] <= 9;
    auto wr1 = [&](int which, int a, uint16_t d) {
        top->i_cpu_addr = a; top->i_cpu_din = d; top->i_cpu_be = 3;
        top->i_pal_we = which == 0; top->i_txt_we = which == 1; top->i_spr_we = which == 2;
        tick(false);
        top->i_pal_we = top->i_txt_we = top->i_spr_we = 0;
    };
    // Z80: one byte per address; 68000: one word per even address
    auto wrblk = [&](int which, const uint8_t *p, int n) {
        if (m68k) for (int a = 0; a < n; a += 2) wr1(which, a, (p[a] << 8) | p[a + 1]);
        else      for (int a = 0; a < n; a++) wr1(which, a, p[a]);
    };
    auto capture = [&](std::vector<uint8_t> &out, long npix) {
        for (long i = 0; i < npix; i++) {
            run_pixel(dummy);
            if (top->o_de) {
                out.push_back(top->o_r);
                out.push_back(top->o_g);
                out.push_back(top->o_b);
                out.push_back(top->o_pen & 0xFF);
                out.push_back(top->o_pen >> 8);
            }
        }
    };
    auto finish = [&](const std::string &in, const std::string &outp, const std::vector<uint8_t> &out,
                      uint16_t over0) {
        if (out.size() != 384u * lines * 5) {
            fprintf(stderr, "%s: captured %zu pixels\n", in.c_str(), out.size() / 5);
            bad++;
        }
        std::ofstream o(outp, std::ios::binary);
        o.write((const char *)out.data(), out.size());
        printf("FRAME %s overruns %d maxcyc %d\n", in.c_str(),
               (int)(uint16_t)(top->o_dbg_overruns - over0), (int)top->o_dbg_maxcyc);
    };
    // primella: frame k's line 255 is scanned out during the line in which
    // frame k+1 latches (line 255 renders line 0), so frame k+1's text and
    // registers go in at the start of line 255 and its palette (read live at
    // scan-out) at the start of line 0, after frame k's last line
    std::vector<uint8_t> prev;
    std::string prev_in, prev_out;
    uint16_t prev_over0 = 0;
    for (auto &fr : frames) {
        if (!load(fr.first)) { fprintf(stderr, "bad frame %s\n", fr.first.c_str()); return 2; }
        int flags = fb[5];
        int npal = fb[6] | (fb[7] << 8);
        const uint8_t *regs = &fb[8];
        const uint8_t *pal = &fb[40];
        const uint8_t *txt = pal + npal;
        const uint8_t *spr = txt + 4096;
        uint16_t over0 = top->o_dbg_overruns;
        if (!prm) wrblk(0, pal, npal);
        if (!m68k) wrblk(1, txt, 4096);
        wrblk(2, spr, 4096);
        for (int l = 0; l < 4; l++)
            for (int r = 0; r < 8; r++) {
                top->i_tm_we = 1; top->i_tm_layer = l; top->i_tm_reg = r; top->i_tm_din = regs[l * 8 + r];
                tick(false);
            }
        top->i_tm_we = 0;
        top->i_flip = flags & 1;
        top->i_pal_bank = (flags >> 1) & 1;
        top->i_pri_swap = (flags >> 2) & 1;
        top->i_spr_disable = (flags >> 3) & 1;

        std::vector<uint8_t> out;
        out.reserve(384 * lines * 5);
        if (prm) {
            std::vector<uint8_t> tail;
            capture(tail, 512);                            // line 255 of the previous frame
            if (!prev_in.empty()) {
                prev.insert(prev.end(), tail.begin(), tail.end());
                finish(prev_in, prev_out, prev, prev_over0);
            }
            wrblk(0, pal, npal);
            capture(out, 255L * 512);                     // lines 0-254
            prev = std::move(out);
            prev_in = fr.first;
            prev_out = fr.second;
            prev_over0 = over0;
        } else {
            capture(out, 256L * 512);
            finish(fr.first, fr.second, out, over0);
        }
    }
    if (prm && !prev_in.empty()) {
        capture(prev, 512);
        finish(prev_in, prev_out, prev, prev_over0);
    }
    printf("DONE frames %zu bad %d cycles %llu\n", frames.size(), bad, (unsigned long long)cycles);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(bad ? 1 : 0);
}
