#!/usr/bin/env python3
"""Which spec features did an oracle capture actually exercise?

Counts dumped frames in which each renderer feature was live, so the M0/M1
gates can state what the MAME-matched frames prove and what still needs
synthetic scenes. Z80 family only.

Usage: tools/oracle_coverage.py <run_dir> [...]
"""
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np


def sprites(buf):
    s = np.frombuffer(buf, dtype=np.uint8)
    for offs in range(0, len(s), 32):
        yield s[offs:offs + 32]


def main(argv):
    for run in argv:
        run = Path(run)
        c = Counter()
        frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
        for fd in frames:
            st = json.loads((fd / "state.json").read_text())
            c["frames"] += 1
            if st.get("m_flip_screen_x", [0])[0]:
                c["flip screen"] += 1
            if st.get("m_palette_bank", [0])[0]:
                c["palette bank 1"] += 1
            if st.get("m_flytiger_pri", [0])[0]:
                c["flytiger bg0/fg0 swap"] += 1
            for tag in ("bg1", "fg1", "fg2"):
                regs = st.get(f"{tag}.m_registers")
                if not regs:
                    continue
                if regs[6] & 0x10:
                    c[f"{tag} disabled"] += 1
                else:
                    c[f"{tag} enabled, format {'A' if regs[6] & 0x20 else 'B'}"] += 1
                if regs[3] | regs[4]:
                    c[f"{tag} y scroll != 0"] += 1
            p = fd / "spriteram_buf.bin"
            if p.exists():
                seen = Counter()
                for e in sprites(p.read_bytes()):
                    sx = int(e[3]) | ((int(e[1]) & 0x10) << 4)
                    if not (48 < sx < 448):            # roughly on screen in x
                        continue
                    ext = int(e[0x1C])
                    col = int(e[1]) & 15
                    seen["on-screen sprite"] = 1
                    if ext & 0x70:
                        seen["sprite height > 1"] = 1
                    if ext & 0x08:
                        seen["sprite x flip"] = 1
                    if ext & 0x04:
                        seen["sprite y flip"] = 1
                    if ext & 0x02:
                        seen["sprite ext bit 1 (Y shift)"] = 1
                    if ext & 0x01:
                        seen["sprite code bit 11"] = 1
                    if col in (0, 15):
                        seen["sprite colour 0/15 (pmask 0xFC)"] = 1
                c.update(seen)
        print(f"== {run.name}")
        for k, v in sorted(c.items()):
            print(f"  {k:40s} {v}")


if __name__ == "__main__":
    main(sys.argv[1:])
