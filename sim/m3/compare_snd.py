#!/usr/bin/env python3
"""M3: compare the sound CPU's register streams with MAME's.

Streams (each in order):
  ym   : YM2151 register writes as (register, value), from address/data
         write pairs at 0xF808/0xF809
  oki  : M6295 command bytes (0xF80A)
  romw : writes into the sound ROM range (spec T4), (address, value)
Each stream must be identical in order and values over the compared
window. Timing: every matched event's beam position (vblank * 256 + line)
is compared, reported as drift in lines (1 line = 65.1 us).

Ours: sim/m2/tb_sys.cpp +snd= log ("vblank line hpos addr data").
MAME: <run>/writes.csv (frame = vblank count at the write).

Usage: compare_snd.py <ours.txt> <mame_run_dir> [--frames N] [--tol LINES]
Exit 0 if all streams match and the drift stays within --tol (default 32
lines, about 2 ms).
"""
import json
import sys
from pathlib import Path


def streams(events):
    ym, oki, romw = [], [], []
    reg = None
    for t, a, d in events:
        if a == 0xF808:
            reg = d
        elif a == 0xF809:
            ym.append((t, (reg, d)))
        elif a == 0xF80A:
            oki.append((t, d))
        elif a < 0xF000:
            romw.append((t, (a, d)))
    return {"ym": ym, "oki": oki, "romw": romw}


VBL = 248      # vblank line; 0 (= 256) on the primella family, set in main()


def load_ours(p, frames):
    ev = []
    for ln in Path(p).read_text().split("\n"):
        if not ln or ln[0] in "#R":
            continue
        f, line, _h, a, d = ln.split()
        f, line = int(f), int(line)
        if f >= frames:
            break
        ev.append((f * 256 + ((line - VBL) % 256), int(a, 16), int(d, 16)))
    return ev


def load_mame(run, frames):
    ev = []
    for ln in (Path(run) / "writes.csv").read_text().split("\n")[1:]:
        x = ln.split(",")
        if len(x) < 9 or x[5] != "audio":
            continue
        f, line = int(x[0]), int(x[1])
        if f >= frames:
            break
        ev.append((f * 256 + ((line - VBL) % 256), int(x[7], 16), int(x[8], 16)))
    return ev


def main(argv):
    global VBL
    ours_p, run = argv[0], argv[1]
    fr = sorted((Path(run) / "frames").glob("*/state.json"))
    if fr and json.loads(fr[0].read_text())["machine"] == "primella":
        VBL = 0
    frames = int(argv[argv.index("--frames") + 1]) if "--frames" in argv else 10 ** 9
    tol = int(argv[argv.index("--tol") + 1]) if "--tol" in argv else 32
    o = streams(load_ours(ours_p, frames))
    m = streams(load_mame(run, frames))
    ok = True
    for k in ("ym", "oki", "romw"):
        a, b = o[k], m[k]
        n = min(len(a), len(b))
        first = next((i for i in range(n) if a[i][1] != b[i][1]), None)
        # the last few events may fall either side of the window edge
        tail = abs(len(a) - len(b))
        # an event within 12 lines of the vblank line can be attributed to
        # adjacent frames by the two logs (MAME computes the beam position
        # from the time within the frame); for those, drift is taken modulo
        # one frame and counted
        drift, wrapped = [], 0
        for i in range(n if first is None else first):
            d = a[i][0] - b[i][0]
            near = min(a[i][0] % 256, 256 - a[i][0] % 256, b[i][0] % 256, 256 - b[i][0] % 256) <= 12
            if near and abs(d) > 128:
                d -= 256 * round(d / 256)
                wrapped += 1
            drift.append(d)
        dmin, dmax = (min(drift), max(drift)) if drift else (0, 0)
        good = first is None and tail <= 4 and max(abs(dmin), abs(dmax)) <= tol
        ok &= good
        msg = (f"{k:5s}: ours {len(a)}, MAME {len(b)}; "
               + ("values and order identical over the common length" if first is None
                  else f"FIRST MISMATCH at event {first}: ours {a[first][1]} at {a[first][0]}, MAME {b[first][1]} at {b[first][0]}")
               + f"; timing drift {dmin}..{dmax} lines"
               + (f" ({wrapped} events at the vblank boundary taken modulo one frame)" if wrapped else ""))
        print(("OK    " if good else "FAIL  ") + msg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
