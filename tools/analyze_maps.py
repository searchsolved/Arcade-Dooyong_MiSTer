#!/usr/bin/env python3
"""M0.3 / O1: inspect the ROM tilemap data of every parent.

For each map (separate *_tmap regions on lastday/gulfstrm/pollux, the
0x4000-word map window inside the combined tile+map regions elsewhere) it
reports, per 0x800-word (4 KB) block: fill fraction (0x0000/0xFFFF words),
distinct words, Shannon entropy of the word values, and whether the block is
an exact copy of an earlier block. It also compares the four 0x4000-word
quarters of the 0x10000-word maps with each other.

The MAME model only reaches words 0 .. 255*64+255 (0x40BF) of a 32x32
layer map: tile index (0..255) + reg1*64, masked by the map length.

Usage: tools/analyze_maps.py [--blocks] [set ...]   (default: the 3 O1 games
plus the combined-map games for comparison). Needs build_regions.py output.
"""
import math
import sys
from collections import Counter

from romdefs import ROOT

REG = ROOT / "sim" / "build" / "regions"
REACH = 255 * 64 + 256          # words reachable with 8-bit reg1

MAPS = {
    "lastday": [("bg0_tmap", 0, 0x10000), ("fg0_tmap", 0, 0x10000)],
    "gulfstrm": [("bg0_tmap", 0, 0x10000), ("fg0_tmap", 0, 0x10000)],
    "pollux": [("bg0_tmap", 0, 0x10000), ("fg0_tmap", 0, 0x10000)],
    "flytiger": [("bg0", 0x3C000, 0x4000), ("fg0", 0x3C000, 0x4000)],
    "bluehawk": [("bg0", 0x3C000, 0x4000), ("fg0", 0x3C000, 0x4000), ("fg1", 0x1C000, 0x4000)],
    "sadari": [("bg0", 0x3C000, 0x4000), ("fg0", 0x3C000, 0x4000)],
    "gundl94": [("bg0", 0x1C000, 0x4000), ("fg0", 0x1C000, 0x4000)],
    "popbingo": [("bg0", 0, 0x4000), ("bg1", 0, 0x4000)],
}


def words(setname, tag):
    b = (REG / setname / f"{tag}.bin").read_bytes()
    return [(b[i] << 8) | b[i + 1] for i in range(0, len(b), 2)]


def entropy(ws):
    c = Counter(ws)
    n = len(ws)
    return -sum(v / n * math.log2(v / n) for v in c.values())


def col_continuity(ws):
    """Fraction of 8-word columns identical to the previous column. Real map
    data (column-major, 8 rows per 32-px column) repeats columns often;
    random/unused data rarely does."""
    cols = [tuple(ws[i:i + 8]) for i in range(0, len(ws) - 7, 8)]
    if len(cols) < 2:
        return 0.0
    return sum(cols[i] == cols[i - 1] for i in range(1, len(cols))) / (len(cols) - 1)


def last_nonfill(ws):
    for i in range(len(ws) - 1, -1, -1):
        if ws[i] not in (0x0000, 0xFFFF):
            return i
    return -1


def analyze(setname, blocks):
    print(f"== {setname}")
    for tag, off, length in MAPS[setname]:
        ws = words(setname, tag)[off:off + length]
        print(f"  {tag} words {off:#x}+{length:#x}: entropy {entropy(ws):.2f} bits, "
              f"distinct {len(set(ws))}, last non-fill word {last_nonfill(ws):#x}")
        if length == 0x10000:
            qs = [ws[i * 0x4000:(i + 1) * 0x4000] for i in range(4)]
            for i, q in enumerate(qs):
                fill = sum(w in (0, 0xFFFF) for w in q) / len(q)
                same = [j for j in range(i) if qs[j] == q]
                cells = sum(a != b for a, b in zip(q, qs[0]))
                print(f"    quarter {i} (words {i * 0x4000:#06x}-{i * 0x4000 + 0x3FFF:#06x}): "
                      f"fill {fill:5.1%} distinct {len(set(q)):5d} entropy {entropy(q):5.2f} "
                      f"col-repeat {col_continuity(q):5.1%} "
                      f"words differing from q0 {cells:5d}"
                      + (f" IDENTICAL to q{same}" if same else ""))
            reach = ws[:REACH]
            beyond = ws[REACH:]
            print(f"    reachable (<{REACH:#x}) distinct {len(set(reach))}; beyond: distinct "
                  f"{len(set(beyond))}, fill {sum(w in (0, 0xFFFF) for w in beyond) / len(beyond):.1%}, "
                  f"words also present in reachable part {len(set(beyond) & set(reach))}")
        if blocks:
            seen = {}
            for b in range(0, len(ws), 0x800):
                blk = ws[b:b + 0x800]
                key = tuple(blk)
                fill = sum(w in (0, 0xFFFF) for w in blk) / len(blk)
                dup = seen.get(key)
                seen.setdefault(key, b)
                print(f"      blk {off + b:#07x}: fill {fill:5.1%} distinct {len(set(blk)):4d} "
                      f"H {entropy(blk):5.2f} colrep {col_continuity(blk):5.1%}"
                      + (f" dup of {off + dup:#07x}" if dup is not None else ""))


def main(argv):
    blocks = "--blocks" in argv
    argv = [a for a in argv if not a.startswith("--")]
    for s in argv or list(MAPS):
        analyze(s, blocks)


if __name__ == "__main__":
    main(sys.argv[1:])
