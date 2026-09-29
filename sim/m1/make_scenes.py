#!/usr/bin/env python3
"""M1 synthetic scenes (PLAN M1 tests, m0_findings 7.4).

Writes frame dirs in the oracle dump format (state.json, palette.bin,
text.bin, spriteram_buf.bin, no snap.png), so sim/m1/replay.py compares the
RTL against the Python reference renderer for them.

Two kinds, one run dir per set (replay.py takes the set from the first
frame):
  <set>_targeted : real attract frames with one feature forced, for what the
                   captures did not exercise: flytiger sprite X/Y flips,
                   bluehawk layer disable, flytiger palette bank 0 with
                   content, sprite X 0x1F0-0x1FF and the left edge, negative
                   Y-shift positions, multi-tile heights, colour 0/15
                   sprites, the other map format, scroll extremes, flip;
                   primella family (sadari, gundl94): flip, both text
                   priorities, layer disable, format A, scroll extremes.
  <set>_random   : fully random registers, flags, palette, text and sprite
                   RAM (fixed seed), every Z80 game the RTL supports.

Usage: make_scenes.py <out_dir>
"""
import json
import random
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_MAME = HERE.parent / "mame" / "out"
TAGS = {"bg0": "bg1", "fg0": "fg1", "fg1": "fg2"}
LAYERS = {"lastday": ("bg0", "fg0"), "gulfstrm": ("bg0", "fg0"), "pollux": ("bg0", "fg0"),
          "flytiger": ("bg0", "fg0"), "bluehawk": ("bg0", "fg0", "fg1"),
          "sadari": ("bg0", "fg0"), "gundl94": ("bg0", "fg0")}
PAL_BYTES = {"lastday": 2048, "gulfstrm": 2048, "pollux": 4096, "flytiger": 4096, "bluehawk": 2048,
             "sadari": 2048, "gundl94": 2048}
PRIMELLA = ("sadari", "gundl94")
SEED = 20260928
N_RANDOM = 60


class Scene:
    def __init__(self, src):
        self.st = json.loads((src / "state.json").read_text())
        self.pal = bytearray((src / "palette.bin").read_bytes())
        self.txt = bytearray((src / "text.bin").read_bytes())
        sp = src / "spriteram_buf.bin"          # none on the primella family
        self.spr = bytearray(sp.read_bytes()) if sp.exists() else None

    def regs(self, layer):
        return self.st[f"{TAGS[layer]}.m_registers"]

    def set_bank(self, on):
        self.st["m_palette_bank"] = [1 if on else 0]
        for lay in ("bg1", "fg1", "fg2", "tx"):
            if f"{lay}.m_palette_bank" in self.st:
                self.st[f"{lay}.m_palette_bank"] = [64 if on else 0]

    def write(self, d):
        d.mkdir(parents=True, exist_ok=True)
        (d / "state.json").write_text(json.dumps(self.st))
        (d / "palette.bin").write_bytes(bytes(self.pal))
        (d / "text.bin").write_bytes(bytes(self.txt))
        if self.spr is not None:
            (d / "spriteram_buf.bin").write_bytes(bytes(self.spr))


def src_frame(run, n):
    return OUT_MAME / run / "frames" / f"{n:06d}"


def targeted(out):
    scenes = {"flytiger": [], "bluehawk": [], "sadari": [], "gundl94": []}

    # flytiger demo play frames (2000-2599 consecutive capture)
    for n in (2000, 2200, 2400):
        base = src_frame("flytiger_attract", n)
        for flip in (0, 1):
            s = Scene(base)
            s.st["m_flip_screen_x"] = [flip]
            for o in range(0, 4096, 32):                 # X and Y flip on every sprite
                s.spr[o + 0x1C] |= 0x0C if (o // 32) % 3 == 0 else (0x08 if (o // 32) % 3 == 1 else 0x04)
            scenes["flytiger"].append((f"sprflip{n}_f{flip}", s))
        s = Scene(base)
        s.set_bank(False)                                # palette bank 0 with content
        scenes["flytiger"].append((f"bank0_{n}", s))
        s = Scene(base)
        s.st["m_flytiger_pri"] = [1 - s.st["m_flytiger_pri"][0]]
        scenes["flytiger"].append((f"priswap{n}", s))
        for layer in ("bg0", "fg0"):                     # map format B on a format A game
            s = Scene(base)
            s.regs(layer)[6] &= ~0x20
            scenes["flytiger"].append((f"fmtB_{layer}_{n}", s))

    # sprite placement edge cases, on a flytiger and a bluehawk frame
    for set_, run, n in (("flytiger", "flytiger_attract", 2100), ("bluehawk", "bluehawk_attract", 900)):
        for flip in (0, 1):
            s = Scene(src_frame(run, n))
            s.st["m_flip_screen_x"] = [flip]
            spr = s.spr
            for i in range(128):
                o = 32 * i
                code = (i * 37) & 0x7FF
                spr[o] = code & 0xFF
                col = (0, 15, 3, 7)[i % 4]                 # include the 0/15 mask class
                spr[o + 1] = ((code >> 3) & 0xE0) | col
                ext = 0
                if i < 32:                                 # X 0x1F0-0x1FF (9-bit X, no wrap)
                    x = 0x1F0 + (i % 16)
                    y = 20 + 6 * i
                elif i < 48:                               # left edge and just past it
                    x = 40 + 2 * (i - 32)
                    y = 30 + 10 * (i - 32)
                elif i < 80:                               # negative Y-shift: straddle the top
                    x = 80 + 9 * (i - 48)
                    y = 240 + (i - 48) % 16
                    ext |= 0x02 if set_ == "flytiger" else 0x00
                else:                                      # multi-tile heights and flips
                    x = 60 + 7 * (i - 80)
                    y = (i * 29) & 0xFF
                    ext |= ((i % 8) << 4) | ((i & 3) << 2)
                    if set_ == "bluehawk":
                        ext |= 0x02
                if set_ == "bluehawk" and i < 48:
                    ext |= 0x02                            # bluehawk: bit 1 set = no -256
                spr[o + 1] |= ((x >> 8) & 1) << 4
                spr[o + 2] = y & 0xFF
                spr[o + 3] = x & 0xFF
                spr[o + 0x1C] = ext | (i & 1)              # code bit 11
            scenes[set_].append((f"sprpos_f{flip}", s))

    # bluehawk layer disable, one layer at a time and all
    for n in (700, 1000):
        base = src_frame("bluehawk_attract", n)
        for dis in (("bg0",), ("fg0",), ("fg1",), ("bg0", "fg0", "fg1")):
            s = Scene(base)
            for layer in dis:
                s.regs(layer)[6] |= 0x10
            scenes["bluehawk"].append((f"off_{'_'.join(dis)}_{n}", s))
        s = Scene(base)
        s.regs("bg0")[6] |= 0x20                         # format A on bg0
        scenes["bluehawk"].append((f"fmtA_bg0_{n}", s))

    # scroll extremes on both sets
    for set_, run, n in (("flytiger", "flytiger_attract", 2300), ("bluehawk", "bluehawk_attract", 800)):
        for r0, r1, r3 in ((0xFF, 0xFF, 0xFF), (0x00, 0xFF, 0x80), (0x1F, 0xFE, 0x01), (0xE1, 0x00, 0x7F)):
            for flip in (0, 1):
                s = Scene(src_frame(run, n))
                s.st["m_flip_screen_x"] = [flip]
                a0, a1, a3 = r0, r1, r3                  # first layer exact, others derived
                for layer in LAYERS[set_]:
                    rg = s.regs(layer)
                    rg[0], rg[1], rg[3] = a0, a1, a3
                    a0, a1, a3 = (a0 * 7 + 13) & 0xFF, (a1 * 5 + 3) & 0xFF, (a3 * 3 + 1) & 0xFF
                scenes[set_].append((f"scroll_{r0:02x}{r1:02x}{r3:02x}_f{flip}", s))

    # primella family: flip, text priority both ways, layer disable, format
    # A, scroll extremes (the attract captures never flip or disable)
    for set_, nums in (("sadari", (1500, 4500, 7500)), ("gundl94", (1500, 4500, 7500))):
        for n in nums:
            base = src_frame(f"extra_{set_}", n)
            for flip in (0, 1):
                for pri in (0, 1):
                    s = Scene(base)
                    s.st["m_flip_screen_x"] = [flip]
                    s.st["m_tx_pri"] = [pri]
                    scenes[set_].append((f"f{flip}_txpri{pri}_{n}", s))
            for dis in (("bg0",), ("fg0",), ("bg0", "fg0")):
                s = Scene(base)
                for layer in dis:
                    s.regs(layer)[6] |= 0x10
                scenes[set_].append((f"off_{'_'.join(dis)}_{n}", s))
            s = Scene(base)
            s.regs("fg0")[6] |= 0x20
            scenes[set_].append((f"fmtA_fg0_{n}", s))
        for r0, r1, r3 in ((0xFF, 0xFF, 0xFF), (0x00, 0xFF, 0x80), (0x1F, 0xFE, 0x01)):
            for flip in (0, 1):
                s = Scene(src_frame(f"extra_{set_}", nums[1]))
                s.st["m_flip_screen_x"] = [flip]
                s.st["m_tx_pri"] = [flip]
                a0, a1, a3 = r0, r1, r3
                for layer in LAYERS[set_]:
                    rg = s.regs(layer)
                    rg[0], rg[1], rg[3] = a0, a1, a3
                    a0, a1, a3 = (a0 * 7 + 13) & 0xFF, (a1 * 5 + 3) & 0xFF, (a3 * 3 + 1) & 0xFF
                scenes[set_].append((f"scroll_{r0:02x}{r1:02x}{r3:02x}_f{flip}", s))

    for set_, lst in scenes.items():
        run = out / f"{set_}_targeted" / "frames"
        for i, (name, s) in enumerate(lst):
            s.write(run / f"{i + 1:06d}")
        (out / f"{set_}_targeted" / "index.txt").write_text(
            "\n".join(f"{i + 1:06d} {name}" for i, (name, _) in enumerate(lst)) + "\n")
        print(f"{set_}_targeted: {len(lst)} scenes")


def randoms(out):
    rng = random.Random(SEED)
    for set_ in ("lastday", "gulfstrm", "pollux", "flytiger", "bluehawk") + PRIMELLA:
        run = out / f"{set_}_random" / "frames"
        prm = set_ in PRIMELLA
        for i in range(N_RANDOM):
            st = {"set": set_, "machine": "primella" if prm else set_, "frame": i + 1,
                  "width": 384, "height": 256 if prm else 240}
            bank = rng.random() < 0.5 if set_ in ("pollux", "flytiger") else False
            for layer in LAYERS[set_]:
                r = [rng.randrange(256) for _ in range(8)] + [0] * 8
                r[6] = (r[6] & ~0x30) | rng.choice((0x00, 0x20, 0x20, 0x10 if rng.random() < 0.15 else 0x20))
                st[f"{TAGS[layer]}.m_registers"] = r
                st[f"{TAGS[layer]}.m_palette_bank"] = [64 if bank else 0]
            st["tx.m_palette_bank"] = [64 if bank else 0]
            st["m_palette_bank"] = [int(bank)]
            st["m_flytiger_pri"] = [rng.randrange(2) if set_ == "flytiger" else 0]
            st["m_flip_screen_x"] = [rng.randrange(2)]
            st["m_sprites_disabled"] = [int(rng.random() < 0.2) if set_ == "lastday" else 0]
            if prm:
                st["m_tx_pri"] = [rng.randrange(2)]
            d = run / f"{i + 1:06d}"
            d.mkdir(parents=True, exist_ok=True)
            (d / "state.json").write_text(json.dumps(st))
            (d / "palette.bin").write_bytes(bytes(rng.randrange(256) for _ in range(PAL_BYTES[set_])))
            # text: mostly transparent-ish random chars so layers below show
            (d / "text.bin").write_bytes(bytes(rng.randrange(256) for _ in range(4096)))
            spr = bytearray(rng.randrange(256) for _ in range(4096))
            if not prm:
                (d / "spriteram_buf.bin").write_bytes(bytes(spr))
        print(f"{set_}_random: {N_RANDOM} scenes")


def main(argv):
    out = Path(argv[0])
    if out.exists():
        shutil.rmtree(out)
    targeted(out)
    randoms(out)


if __name__ == "__main__":
    main(sys.argv[1:])
