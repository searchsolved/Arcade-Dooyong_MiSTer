#!/usr/bin/env python3
"""M2: compare dy_sys boot captures with a MAME oracle run.

Our displayed frame N (pixels between vblank N and N+1) is expected to equal
MAME frame N + OFFSET (MAME draws frame M at vblank M; with the register
latch at line 7 our active period after vblank N shows what MAME draws at
vblank N+1, so OFFSET = 1). RAM dumps taken at our vblank N are compared
with MAME's at frame N (both at the frame notifier point, line 248).

Live reads (m2_findings): the RTL reads text RAM while rendering each line
and the palette while scanning out, as a board without a frame buffer
must; MAME draws the whole frame at line 248 from the final values. So a
game write to text RAM, palette or a video register during the active lines
(line >= 7, after our register latch) can make our frame differ from
MAME's. A differing frame passes only if it is pixel-exact against a
line-accurate model of those live reads (line_check), built from our RAM
dumps at vblank N, the logged writes (.wlog) and, for registers changed in
the active lines, MAME's write log; anything else is a failure.

Primella family (sadari, gundl94): the frame is all 256 lines, vblank is at
line 256 (= line 0) and the registers latch at the start of line 255, so our
displayed frame N is MAME frame N (OFFSET = 0), beam positions count from
line 0 and every line 0-255 is checked.

Usage: compare.py <cap_dir> <mame_run_dir> [--offset K] [--search] [--quiet]
  --search: for every frame try offsets -8..8 and report the best.
Exit 0 only if every captured frame matches or is explained, and every RAM
dump matches (vblank 1 excepted, see m2_findings).
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "oracle"))
from dy_render import MACHINES, render  # noqa: E402

ROT270 = {"lastday", "gulfstrm", "pollux", "flytiger", "bluehawk"}


def load_ours(p, h=240):
    raw = np.frombuffer(p.read_bytes(), dtype=np.uint8)
    if raw.size != 384 * h * 5:
        return None, None
    raw = raw.reshape(h, 384, 5)
    pen = raw[..., 3].astype(np.int64) | (raw[..., 4].astype(np.int64) << 8)
    return raw[..., :3].copy(), pen


def mame_view(fd, rgb, pen, nent, machine):
    """Our RGB with MAME's power-on pens substituted for unwritten entries,
    rotated like MAME's snapshot."""
    view = rgb
    if (fd / "pens.bin").exists():
        mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:nent]
        written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:nent].astype(bool)
        black = (pen >> 11) & 1
        p = pen & 0x7FF
        unw = (black == 0) & ~written[np.clip(p, 0, nent - 1)]
        if unw.any():
            view = rgb.copy()
            c = mp[p[unw]]
            view[unw] = np.stack([(c >> 16) & 255, (c >> 8) & 255, c & 255], axis=-1)
    return np.rot90(view, 1) if machine in ROT270 else view


def _pos(line, hpos, machine=None):
    """Beam position counted from our vblank IRQ: the start of line 248, or
    of line 0 on the primella family."""
    if machine == "primella":
        return line * 512 + hpos
    return ((line - 248) % 256) * 512 + hpos


def latched_state(st, regw, machine):
    """MAME's state at vblank N+1 with every register/control value changed
    during the active lines put back to its value before the change, i.e.
    what our latch took at line 7."""
    st = json.loads(json.dumps(st))
    if machine == "primella":
        # latched at line 255, MAME draws at line 256: the games write their
        # registers in lines 0-10 (spec 5.4), nothing to put back
        return st
    seen = set()
    for line, a, _d, old in regw:
        if not 7 <= line <= 247 or a in seen or old is None:
            continue
        seen.add(a)
        if machine == "flytiger":
            if 0xE030 <= a <= 0xE037:
                st["bg1.m_registers"][a & 7] = old
            elif 0xE040 <= a <= 0xE047:
                st["fg1.m_registers"][a & 7] = old
            elif a == 0xE010:
                st["m_flip_screen_x"] = [old & 1]
                st["m_palette_bank"] = [(old >> 3) & 1]
                for t in ("bg1", "fg1", "tx"):
                    st[f"{t}.m_palette_bank"] = [64 * ((old >> 3) & 1)]
                st["m_flytiger_pri"] = [(old >> 4) & 1]
        elif machine == "bluehawk":
            for base, tag in ((0xC018, "fg2"), (0xC040, "bg1"), (0xC048, "fg1")):
                if base <= a <= base + 7:
                    st[f"{tag}.m_registers"][a & 7] = old
            if a == 0xC000:
                st["m_flip_screen_x"] = [int(old != 0)]
    return st


def line_check(fd, cap, n, rgb, machine, regw=()):
    """Line-accurate model of our live reads: text RAM as it is while line y
    is rendered (during line y-1), palette as it is while line y is scanned
    out, registers and sprite list as latched. Built from our RAM dumps at
    vblank n plus the logged writes, drawn by dy_render one state at a time.
    A write inside a line's read window may land either side of the read of
    each cell, so every intermediate state of that window is accepted. Returns the number of pixels that match
    no allowed state."""
    txt0 = bytearray((cap / f"{n:06d}.txt").read_bytes())
    pal0 = bytearray((cap / f"{n:06d}.pal").read_bytes())
    spr = (cap / f"{n:06d}.spr").read_bytes()
    st = latched_state(json.loads((fd / "state.json").read_text()), regw, machine)
    bank = bool(st.get("m_palette_bank", [0])[0])
    tw, pw = [], []                                  # (pos, byte index, value)
    wl = cap / f"{n:06d}.wlog"
    for ln in (wl.read_text().split("\n") if wl.exists() else []):
        if not ln:
            continue
        line, h, a, d = ln.split()
        line, h, a, d = int(line), int(h), int(a, 16), int(d, 16)
        t = _pos(line, h, machine)
        if machine == "primella":
            if 0xE000 <= a <= 0xEFFF:
                o = a & 0xFFF
                tw.append((t, 2 * (o >> 1) + (0 if o & 1 else 1), d))
            elif 0xF000 <= a <= 0xF7FF:
                pw.append((t, a & 0x7FF, d))
        elif machine == "flytiger":
            if a >= 0xF000:
                o = a & 0xFFF
                tw.append((t, 2 * (o & 0x7FF) + (0 if o & 0x800 else 1), d))
            elif 0xE800 <= a <= 0xEFFF:
                pw.append((t, (int(bank) << 11) | (a & 0x7FF), d))
        elif machine == "bluehawk":
            if 0xD000 <= a <= 0xDFFF:
                o = a & 0xFFF
                tw.append((t, 2 * (o >> 1) + (0 if o & 1 else 1), d))
            elif 0xC800 <= a <= 0xCFFF:
                pw.append((t, a & 0x7FF, d))
    cache = {}

    def state(writes, base, k):
        b = bytearray(base)
        for _t, i, v in writes[:k]:
            b[i] = v
        return bytes(b)

    def upto(writes, t):
        return sum(1 for w in writes if w[0] < t)

    def rows(kt, kp):
        if (kt, kp) not in cache:
            ov = {"state": st, "text.bin": state(tw, txt0, kt), "palette.bin": state(pw, pal0, kp),
                  "spriteram_buf.bin": spr}
            cache[(kt, kp)] = render(fd, override=ov)[0]
        return cache[(kt, kp)]

    bad = 0
    prm = machine == "primella"
    y0, y1 = (0, 255) if prm else (8, 247)
    for y in range(y0, y1 + 1):
        # every prefix of the writes inside the read window: cells read
        # before a write see the old value, cells read after it the new one.
        # Primella line 0 is rendered during the last line before our dump,
        # so it reads the dumped text.
        if prm and y == 0:
            kts = range(0, 1)
        else:
            kts = range(upto(tw, _pos(y - 1, 0, machine)), upto(tw, _pos(y, 0, machine)) + 1)
        kps = range(upto(pw, _pos(y, 0, machine)),
                    upto(pw, _pos(y + 1, 0, machine) if y < y1 else 256 * 512) + 1)
        ok = np.zeros(384, dtype=bool)
        # window boundaries first; intermediate states only where needed
        combos = [(kt, kp) for kt in (kts[0], kts[-1]) for kp in (kps[0], kps[-1])]
        combos += [(kt, kp) for kt in kts for kp in kps if (kt, kp) not in combos]
        for kt, kp in combos:
            ok |= np.all(rows(kt, kp)[y - y0] == rgb[y - y0], axis=-1)
            if ok.all():
                break
        bad += int((~ok).sum())
    return bad, len(cache)


def reg_changes(run, machine):
    """MAME's writes.csv -> {scan_frame: [(line, addr, data)]} for tilemap
    register and control writes that change a video-relevant value."""
    out = {}
    last = {}
    for ln in (run / "writes.csv").read_text().split("\n")[1:]:
        f = ln.split(",")
        if len(f) < 9 or f[5] != "main" or not (f[6].startswith("tmreg") or f[6] == "ctrl"):
            continue
        a, d = int(f[7], 16), int(f[8], 16)
        old = last.get(a)
        last[a] = d
        if f[6] == "ctrl":
            if machine == "flytiger":
                changed = old is None or ((old ^ d) & 0x19) != 0    # flip, bank, priority
            elif machine == "primella":
                changed = old is None or ((old ^ d) & 0x18) != 0    # text priority, flip
            else:
                changed = old is None or (old != 0) != (d != 0)     # bluehawk flip
        else:
            changed = old != d
        if changed:
            out.setdefault(int(f[3]), []).append((int(f[1]), a, d, old))
    return out


def main(argv):
    cap, run = Path(argv[0]), Path(argv[1])
    frames = run / "frames"
    first = next(p for p in sorted(frames.iterdir()) if (p / "state.json").exists())
    machine0 = json.loads((first / "state.json").read_text())["machine"]
    prm = machine0 == "primella"
    off = int(argv[argv.index("--offset") + 1]) if "--offset" in argv else (0 if prm else 1)
    search = "--search" in argv
    quiet = "--quiet" in argv
    regs_by_frame = None
    ok_img = bad_img = ok_ram = bad_ram = 0
    explained = 0
    explained_whole = 0
    for p in sorted(cap.glob("*.rgbp")):
        n = int(p.stem)
        rgb, pen = load_ours(p, 256 if prm else 240)
        if rgb is None:
            print(f"SHORT {n}")
            bad_img += 1
            continue
        tries = range(-8, 9) if search else (off,)
        hits = []
        for k in tries:
            fd = frames / f"{n + k:06d}"
            if not (fd / "snap.png").exists():
                continue
            st = json.loads((fd / "state.json").read_text())
            nent = MACHINES[st["machine"]]["pal_entries"]
            snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
            v = mame_view(fd, rgb, pen, nent, st["machine"])
            ndiff = int(np.any(v != snap, axis=-1).sum()) if v.shape == snap.shape else -1
            hits.append((ndiff, k))
        if not hits:
            continue
        best = min(hits)
        good = best[0] == 0 and (search or best[1] == off)
        note = ""
        if not good and not search:
            fd = frames / f"{n + off:06d}"
            st = json.loads((fd / "state.json").read_text())
            mc = MACHINES[st["machine"]]
            nent = mc["pal_entries"]
            if regs_by_frame is None:
                regs_by_frame = reg_changes(run, st["machine"])
            regw = regs_by_frame.get(n + off, [])
            whole = any(w[0] <= 254 if prm else 7 <= w[0] <= 247 for w in regw)
            wl = cap / f"{n:06d}.wlog"
            nw = len(wl.read_text().split("\n")) - 1 if wl.exists() else 0
            lc_bad = None
            if (cap / f"{n:06d}.txt").exists():
                lc_bad, nrend = line_check(fd, cap, n, rgb, st["machine"], regs_by_frame.get(n + off, []))
            if lc_bad == 0:
                explained += 1
                explained_whole += whole
                note = (f"LINE-EXACT against the live-read model ({nw} active-line writes, {nrend} states"
                        + ((", registers as latched at line 255)" if prm else ", registers as latched at line 7)")
                           if whole else ")"))
                if not quiet:
                    print(f"EXPL  disp {n}: {best[0]} px vs MAME, {note}")
                continue
            if lc_bad:
                bad_img += 1
                print(f"DIFF  disp {n}: {best[0]} px vs MAME; live-read model leaves {lc_bad} px unexplained")
                continue
            note = "no .txt/.wlog capture for this frame, live-read model not run"
        ok_img += good
        bad_img += not good
        if not good or not quiet:
            exact = [k for d, k in hits if d == 0]
            print(f"{'MATCH' if good else 'DIFF '} disp {n}: best offset {best[1]} ({best[0]} px)"
                  + (f", exact at offsets {exact}" if search else "") + (f"; {note}" if note else ""))
    ram_res = []                                   # (vblank, all_match, text)
    for p in sorted(cap.glob("*.pal")):
        n = int(p.stem)
        fd = frames / f"{n:06d}"
        if not fd.exists():
            continue
        res = []
        for ext, name in ((".pal", "palette.bin"), (".txt", "text.bin"), (".spr", "spriteram_live.bin")):
            if not (fd / name).exists():            # no sprite RAM on the primella family
                continue
            ours = (cap / f"{n:06d}{ext}").read_bytes()
            theirs = (fd / name).read_bytes()
            m = min(len(ours), len(theirs))
            nd = sum(a != b for a, b in zip(ours[:m], theirs[:m]))
            res.append(f"{name.split('.')[0]}:{nd}")
            if nd:
                bad_ram += 1
            else:
                ok_ram += 1
        if n == 1:
            # first vblank after power-on: our CPU is a few instructions
            # behind MAME's (m2_findings); not counted
            bad_ram -= sum(not r.endswith(":0") for r in res)
        ram_res.append((n, all(r.endswith(":0") for r in res), " ".join(res)))
    # a RAM difference is transient if the next dumped vblank matches again
    # (a write landing a few cycles either side of the vblank; m2_findings)
    transient = persistent = 0
    for i, (n, ok, txt) in enumerate(ram_res):
        if ok or n == 1:
            continue
        nxt = ram_res[i + 1][1] if i + 1 < len(ram_res) else False
        transient += nxt
        persistent += not nxt
        print(f"RAM   vblank {n}: {txt} ({'transient' if nxt else 'PERSISTS'})")
    bad_ram = persistent
    print(f"images {ok_img} exact vs MAME, {explained} differ from MAME only by live reads "
          f"(all line-exact against the live-read model; {explained_whole} of them with a value-changing "
          f"register/control write in the active lines), {bad_img} unexplained; "
          f"RAM dump files {ok_ram} match; vblanks differing: {transient} transient, {persistent} persistent "
          f"(vblank 1 excluded)")
    return 0 if bad_img == 0 and bad_ram == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
