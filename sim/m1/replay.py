#!/usr/bin/env python3
"""M1 video parity: replay oracle frame dumps through the dy_video RTL
(Verilator harness sim/m1/tb_video.cpp) and compare every frame.

Reference per frame:
  - MAME's snapshot (snap.png) when the frame dir has one: the M1 gate.
    Pixels whose pen was never written by the game show MAME's power-on
    pen (spec 6.3); for those the RTL pen index is looked up in pens.bin,
    exactly as sim/oracle/compare_frames.py does for the Python renderer.
  - otherwise (synthetic scenes) the Python reference renderer
    sim/oracle/dy_render.py.
Both pen index and RGB of the RTL are checked: RGB against the reference,
and on reference frames also the RTL pen against dy_render's pen.

Usage:
  replay.py <run_dir>... [--jobs N] [--batch N] [--lat N] [--intv N] [--div N]
            [--limit N] [--keep DIR] [--quiet]
run_dir holds frames/NNNNNN/ (sim/mame/out/<run> or a synthetic scene dir).
Exit 0 only if every frame matches.
"""
import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "oracle"))
from dy_render import MACHINES, palette_rgb, render  # noqa: E402

BIN = HERE.parent / "build" / "m1" / "obj_dir" / "Vdy_video"
REGIONS = ROOT / "sim" / "build" / "regions"
GAME_ID = {"lastday": 0, "gulfstrm": 1, "pollux": 2, "flytiger": 3, "bluehawk": 4}
ROT270 = {"lastday", "gulfstrm", "pollux", "flytiger", "bluehawk"}
LAYER_ORDER = ("bg0", "fg0", "fg1")


def text_cpu_bytes(words, lane0):
    """Logical text entries (2048 x u16) -> 4096 CPU bytes (spec 8)."""
    out = bytearray(4096)
    for i, w in enumerate(words):
        lo, hi = w & 0xFF, w >> 8
        if lane0:        # bluehawk layout: offset bit 0 = lane
            out[2 * i], out[2 * i + 1] = lo, hi
        else:            # lastday layout: offset bit 11 = lane
            out[i], out[0x800 + i] = lo, hi
    return bytes(out)


def make_dyf(fd, path):
    st = json.loads((fd / "state.json").read_text())
    mname = st["machine"]
    mc = MACHINES[mname]
    regs = bytearray(24)
    for li, name in enumerate(LAYER_ORDER):
        lc = mc["layers"].get(name)
        if lc:
            r = st[f"{lc['tag']}.m_registers"]
            regs[li * 8:li * 8 + 8] = bytes(v & 0xFF for v in r[:8])
    flags = (bool(st.get("m_flip_screen_x", [0])[0])
             | bool(st.get("m_palette_bank", [0])[0]) << 1
             | bool(st.get("m_flytiger_pri", [0])[0]) << 2
             | bool(st.get("m_sprites_disabled", [0])[0]) << 3)
    pal = (fd / "palette.bin").read_bytes()[:mc["pal_entries"] * 2]
    words = np.frombuffer((fd / "text.bin").read_bytes(), dtype=">u2")
    txt = text_cpu_bytes([int(w) for w in words], mc["text"]["layout"] == "packed")
    spr = (fd / "spriteram_buf.bin").read_bytes()
    spr = (spr + bytes(4096))[:4096]
    hdr = b"DYF1" + bytes([GAME_ID[mname], flags]) + len(pal).to_bytes(2, "little")
    path.write_bytes(hdr + bytes(regs) + pal + txt + spr)
    return st


def check(fd, st, out_path, diffdir):
    """Return (ok, message)."""
    mname = st["machine"]
    mc = MACHINES[mname]
    raw = np.frombuffer(out_path.read_bytes(), dtype=np.uint8)
    if raw.size != 384 * 240 * 5:
        return False, f"size {raw.size}"
    raw = raw.reshape(240, 384, 5)
    rgb = raw[..., :3].copy()
    pen = raw[..., 3].astype(np.int64) | (raw[..., 4].astype(np.int64) << 8)
    black = (pen >> 11) & 1
    pen = pen & 0x7FF
    nent = mc["pal_entries"]
    # pen index check against the reference renderer (black -> nent)
    _, ref_pens = render(fd)
    ours_idx = np.where(black == 1, nent, pen)
    npen = int((ours_idx != ref_pens).sum())
    msgs = []
    if npen:
        ys, xs = np.nonzero(ours_idx != ref_pens)
        msgs.append(f"pen {npen} px, first x={xs[0]} y={ys[0]} rtl={ours_idx[ys[0], xs[0]]} ref={ref_pens[ys[0], xs[0]]}")
    snap_p = fd / "snap.png"
    if snap_p.exists():
        view = rgb
        if (fd / "pens.bin").exists():
            mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:nent]
            written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:nent].astype(bool)
            unw = (black == 0) & ~written[np.clip(pen, 0, nent - 1)]
            if unw.any():
                c = mp[pen[unw]]
                view = rgb.copy()
                view[unw] = np.stack([(c >> 16) & 255, (c >> 8) & 255, c & 255], axis=-1)
        if mname in ROT270:
            view = np.rot90(view, 1)
        ref = np.array(Image.open(snap_p).convert("RGB"))
        tag = "snap"
    else:
        pal = palette_rgb((fd / "palette.bin").read_bytes(), mc["palette"], nent)
        ref = pal[ref_pens]
        view = rgb
        tag = "model"
    if view.shape != ref.shape:
        return False, f"shape {view.shape} vs {ref.shape}"
    neq = np.any(view != ref, axis=-1)
    n = int(neq.sum())
    if n:
        ys, xs = np.nonzero(neq)
        msgs.append(f"{tag} {n} px, first x={xs[0]} y={ys[0]} ref={tuple(int(v) for v in ref[ys[0], xs[0]])} "
                    f"rtl={tuple(int(v) for v in view[ys[0], xs[0]])}")
        diffdir.mkdir(parents=True, exist_ok=True)
        vis = np.concatenate([ref, view, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
        Image.fromarray(vis, "RGB").save(diffdir / f"{fd.name}_{tag}.png")
    return (not msgs), ("; ".join(msgs) if msgs else tag)


def run_batch(batch, setname, args, diffdir):
    with tempfile.TemporaryDirectory(prefix="dym1_") as td:
        td = Path(td)
        lines, states = [], []
        for fd in batch:
            inp, outp = td / f"{fd.name}.dyf", td / f"{fd.name}.rgbp"
            states.append(make_dyf(fd, inp))
            lines.append(f"{inp} {outp}")
        (td / "list.txt").write_text("\n".join(lines) + "\n")
        cmd = [str(BIN), f"+sdram={REGIONS / setname / 'sdram.bin'}", f"+list={td / 'list.txt'}",
               f"+lat={args['lat']}", f"+intv={args['intv']}", f"+div={args['div']}"]
        p = subprocess.run(cmd, capture_output=True, text=True)
        stats = {"overruns": 0, "maxcyc": 0}
        for ln in p.stdout.splitlines():
            if ln.startswith("FRAME"):
                f = ln.split()
                stats["overruns"] += int(f[3])
                stats["maxcyc"] = max(stats["maxcyc"], int(f[5]))
        if p.returncode not in (0, 1):
            return [(fd, False, f"harness rc {p.returncode}: {p.stderr[-300:]}") for fd in batch], stats
        res = []
        for fd, st in zip(batch, states):
            outp = td / f"{fd.name}.rgbp"
            if not outp.exists():
                res.append((fd, False, "no output"))
                continue
            ok, msg = check(fd, st, outp, diffdir)
            if args["keep"] is not None:
                keep = Path(args["keep"])
                keep.mkdir(parents=True, exist_ok=True)
                outp.replace(keep / outp.name)
            res.append((fd, ok, msg))
        return res, stats


def main(argv):
    opts = {"jobs": os.cpu_count() or 4, "batch": 60, "lat": 9, "intv": 8, "div": 12, "limit": 0, "keep": None}
    runs, quiet = [], False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--quiet":
            quiet = True
        elif a.startswith("--"):
            key = a[2:]
            opts[key] = argv[i + 1] if key == "keep" else int(argv[i + 1])
            i += 1
        else:
            runs.append(Path(a))
        i += 1
    if not BIN.exists():
        sys.exit(f"missing {BIN}; run make m1-build")
    rc = 0
    for run in runs:
        frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
        if opts["limit"]:
            frames = frames[:opts["limit"]]
        setname = json.loads((frames[0] / "state.json").read_text())["set"]
        batches = [frames[k:k + opts["batch"]] for k in range(0, len(frames), opts["batch"])]
        diffdir = run / "m1_diffs"
        good = 0
        over = 0
        maxcyc = 0
        tags = {}
        with ThreadPoolExecutor(max_workers=opts["jobs"]) as ex:
            for res, stats in ex.map(lambda b: run_batch(b, setname, opts, diffdir), batches):
                over += stats["overruns"]
                maxcyc = max(maxcyc, stats["maxcyc"])
                for fd, ok, msg in res:
                    good += ok
                    if ok:
                        tags[msg] = tags.get(msg, 0) + 1
                    if not ok or not quiet:
                        print(f"{'MATCH' if ok else 'DIFF '} {run.name}/{fd.name}: {msg}")
        print(f"== {run.name}: {good}/{len(frames)} frames exact ({tags}); "
              f"line overruns {over}; max render clocks/line {maxcyc} "
              f"(budget {512 * opts['div']} at div {opts['div']}; ROM 1 req / {opts['intv']} clk, latency {opts['lat']})")
        if good != len(frames) or over:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
