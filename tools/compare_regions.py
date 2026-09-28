#!/usr/bin/env python3
"""Compare tools/build_regions.py output with MAME's own region dumps
(sim/mame/dump_regions.lua), byte for byte.

Usage: tools/compare_regions.py <set> [<set> ...]
Reads sim/build/regions/<set>/<tag>.bin and sim/mame/out/regions/<set>/<tag>.bin.
"""
import sys

from romdefs import ROOT

OURS = ROOT / "sim" / "build" / "regions"
MAME = ROOT / "sim" / "mame" / "out" / "regions"


def main(argv):
    bad = 0
    for name in argv:
        mdir = MAME / name
        tags = sorted(p.stem for p in mdir.glob("*.bin"))
        ours = sorted(p.stem for p in (OURS / name).glob("*.bin") if p.stem != "sdram")
        res = []
        if tags != ours:
            res.append(f"region list differs: mame {tags} ours {ours}")
        for t in tags:
            a = (mdir / f"{t}.bin").read_bytes()
            p = OURS / name / f"{t}.bin"
            if not p.exists():
                continue
            b = p.read_bytes()
            if a != b:
                diff = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
                res.append(f"{t}: DIFF len {len(a)}/{len(b)} first diff at {diff}")
        print(f"{'MATCH' if not res else 'DIFF '} {name:11s} {len(tags)} regions")
        for r in res:
            print("      " + r)
        bad += bool(res)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
