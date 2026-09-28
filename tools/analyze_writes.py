#!/usr/bin/env python3
"""M0.3/M0.4: summarise an oracle run's register write log.

Answers, per run directory (sim/mame/out/<run>/):
  O9   map format per layer: register 6 values seen (bit 5 = format A)
  O10  writes that CHANGE a tilemap register or the ctrl register while the
       beam is in the visible area (lines 8-247). MAME renders the whole
       frame at vblank, so such writes are invisible in MAME but would split
       the frame on hardware. Equal-value rewrites are counted separately
       (tilemap regs only act on change, spec 7.2).
  O1   tilemap register 1 (X high byte) and register 2 ranges per layer
  T2/T4 ROM-area writes (main and sound CPU): address/value patterns
  heavy classes (palette, text, sprite RAM): frames with writes in the
       visible area, from heavy_summary.csv

Usage: tools/analyze_writes.py <run_dir> [...]
"""
import csv
import sys
from collections import Counter, defaultdict
from pathlib import Path


VIS = (8, 247)


def visible(line):
    return VIS[0] <= line <= VIS[1]


def analyze(run):
    run = Path(run)
    print(f"== {run.name}")
    summ = (run / "summary.txt").read_text().splitlines()
    print("  " + summ[0])
    global VIS
    # primella config: visible area is lines 0-255, every line is visible
    VIS = (0, 255) if "machine primella" in summ[0] else (8, 247)
    state = {}                     # (class, reg) -> value
    changes_vis = Counter()
    changes_all = Counter()
    rewrites_vis = Counter()
    examples = defaultdict(list)
    reg_values = defaultdict(Counter)
    romw = defaultdict(Counter)
    unk = Counter()
    with open(run / "writes.csv") as f:
        for r in csv.DictReader(f):
            cls = r["class"]
            addr = int(r["addr"], 16)
            data = int(r["data"], 16)
            line = int(r["line"])
            if cls.startswith("tmreg") or cls == "ctrl":
                if cls == "ctrl":
                    key = ("ctrl", 0)
                else:
                    # Z80: 8 consecutive bytes; 68000: odd bytes (umask 0x00ff)
                    reg = (addr & 7) if addr < 0x10000 else ((addr >> 1) & 7)
                    key = (cls[5:], reg)
                    if "mask" in r and addr >= 0x10000:
                        data &= 0xFF
                reg_values[key][data] += 1
                old = state.get(key)
                state[key] = data
                if old is not None and old != data:
                    changes_all[key] += 1
                    if visible(line):
                        changes_vis[key] += 1
                        if len(examples[key]) < 4:
                            examples[key].append(f"f{r['frame']} line {line} {old:#x}->{data:#x}")
                elif old == data and visible(line):
                    rewrites_vis[key] += 1
            elif cls == "romw":
                romw[r["cpu"]][(addr, data)] += 1
            elif cls == "unk":
                unk[(addr, data)] += 1

    print("  register 6 values (O9; bit 5 set = format A, bit 4 set = layer off):")
    for key in sorted(k for k in reg_values if k[1] == 6 and k[0] != "ctrl"):
        vals = ", ".join(f"{v:#04x} x{n}" for v, n in sorted(reg_values[key].items()))
        fmts = {("A" if v & 0x20 else "B") for v in reg_values[key]}
        print(f"    {key[0]}: {vals}  -> format {'/'.join(sorted(fmts))}")
    print("  register 1 and 2 ranges (O1):")
    for key in sorted(k for k in reg_values if k[1] in (1, 2) and k[0] != "ctrl"):
        vals = sorted(reg_values[key])
        print(f"    {key[0]} r{key[1]}: {len(vals)} values, min {vals[0]:#04x} max {vals[-1]:#04x}"
              + (f" ({', '.join(hex(v) for v in vals)})" if len(vals) <= 8 else ""))
    print(f"  value-changing writes in visible lines {VIS[0]}-{VIS[1]} (O10):")
    any_vis = False
    for key in sorted(changes_all):
        if changes_vis[key]:
            any_vis = True
        print(f"    {key[0]} r{key[1]}: {changes_vis[key]} of {changes_all[key]} changes in visible lines"
              + (f"; e.g. {'; '.join(examples[key])}" if examples[key] else ""))
    if not any_vis:
        print("    none")
    rv = {k: v for k, v in rewrites_vis.items() if v}
    if rv:
        print("  equal-value rewrites in visible lines (no effect under the change-only rule): "
              + ", ".join(f"{k[0]} r{k[1]} x{v}" for k, v in sorted(rv.items())))
    hs = run / "heavy_summary.csv"
    if hs.exists():
        vis = Counter()
        frames = Counter()
        with open(hs) as f:
            for r in csv.DictReader(f):
                frames[r["class"]] += 1
                if int(r["visible_count"]):
                    vis[r["class"]] += 1
        print("  heavy classes, frames with writes / frames with writes in visible lines: "
              + ", ".join(f"{c} {frames[c]}/{vis[c]}" for c in sorted(frames)))
    for cpu, c in romw.items():
        top = ", ".join(f"{a:#06x}={d:#04x} x{n}" for (a, d), n in c.most_common(10))
        print(f"  {cpu} CPU writes to ROM space: {sum(c.values())} total, {len(c)} distinct addr/value; {top}")
    if unk:
        top = ", ".join(f"{a:#08x}={d:#06x} x{n}" for (a, d), n in unk.most_common(8))
        print(f"  unmapped/unknown I/O writes: {sum(unk.values())}; {top}")
    for ln in summ[2:]:
        if ln.startswith("tap"):
            pass
    dead = [ln for ln in summ if ln.startswith("tap") and ln.endswith(" 0")]
    if dead:
        print("  WARNING taps with zero hits: " + "; ".join(dead))


def main(argv):
    for run in argv:
        analyze(run)


if __name__ == "__main__":
    main(sys.argv[1:])
