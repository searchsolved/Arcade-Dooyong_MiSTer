#!/usr/bin/env python3
"""Render oracle frame dumps with dy_render.py and diff them against MAME,
pixel for pixel.

Primary check: snap.png, MAME's snapshot of frame N (rotated like the game;
for ROT270 snap = numpy.rot90(native, 1), for ROT0 snap = native).
Secondary check: screen.argb (screen:pixels() captured one frame later,
same pens, converted with palette_next.bin), which confirms the pens
independently of the snapshot path.

Palette: the renderer converts palette RAM (spec 6). MAME keeps a power-on
default colour for every pen until the game first writes that entry (black,
red, ..., white pattern; real boards have undefined SRAM there instead), so
for entries the oracle log marks as never written (palette_written.bin) the
comparison takes MAME's pen colour from pens.bin, and reports how many
frames showed such pens. For every written entry the RAM decode must equal
MAME's pen colour exactly (checked on every frame).

Usage: compare_frames.py <run_dir> [--set SET] [--diffdir DIR] [--quiet]
  run_dir = sim/mame/out/<name> (holds frames/NNNNNN/)
Exit status 0 only if every frame matches on both checks.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent.parent / "mame"))
from dy_render import render, palette_rgb, MACHINES  # noqa: E402
from frame_tools import load_argb  # noqa: E402

ROT270 = {"lastday", "gulfstrm", "pollux", "flytiger", "bluehawk", "superx", "rshark"}


def diff_report(tag, name, ours, ref, diffdir):
    neq = np.any(ours != ref, axis=-1)
    n = int(neq.sum())
    if n:
        ys, xs = np.nonzero(neq)
        print(f"DIFF  {name} [{tag}]: {n} px, first (x={xs[0]},y={ys[0]}) mame={tuple(int(v) for v in ref[ys[0], xs[0]])} "
              f"ours={tuple(int(v) for v in ours[ys[0], xs[0]])}, bbox x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()}")
        diffdir.mkdir(parents=True, exist_ok=True)
        vis = np.concatenate([ref, ours, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
        Image.fromarray(vis, "RGB").save(diffdir / f"{name}_{tag}.png")
    return n


def main(argv):
    run = Path(argv[0])
    regions_set = argv[argv.index("--set") + 1] if "--set" in argv else None
    diffdir = Path(argv[argv.index("--diffdir") + 1]) if "--diffdir" in argv else run / "diffs"
    quiet = "--quiet" in argv
    frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
    bad = 0
    checked = {"snap": 0, "pixels": 0}
    stats = {"unwritten_frames": 0, "pixels_skipped": 0}
    px = 0
    for fd in frames:
        st = json.loads((fd / "state.json").read_text())
        mc = MACHINES[st["machine"]]
        rgb, pens = render(fd, regions_set)
        fail = 0
        nent = mc["pal_entries"]
        unwritten_visible = 0
        if (fd / "pens.bin").exists():
            ours_pal = palette_rgb((fd / "palette.bin").read_bytes(), mc["palette"], nent)
            mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:nent]
            mame_pal = np.stack([(mp >> 16) & 255, (mp >> 8) & 255, mp & 255], axis=-1).astype(np.uint8)
            written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:nent].astype(bool)
            bad_dec = np.nonzero(np.any(ours_pal[:nent][written] != mame_pal[written], axis=-1))[0]
            if len(bad_dec):
                print(f"PALDEC {fd.name}: {len(bad_dec)} written entries decode differently from MAME's pens")
                fail += 1
            eff = ours_pal.copy()
            eff[:nent][~written] = mame_pal[~written]
            rgb = eff[pens]
            unwritten_visible = int(np.isin(pens, np.nonzero(~written)[0]).sum())
            if unwritten_visible:
                stats["unwritten_frames"] += 1
        if (fd / "snap.png").exists():
            snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
            view = np.rot90(rgb, 1) if st["machine"] in ROT270 else rgb
            if view.shape != snap.shape:
                print(f"SHAPE {fd.name}: ours {view.shape} snap {snap.shape}")
                fail += 1
            else:
                fail += bool(diff_report("snap", fd.name, view, snap, diffdir))
                checked["snap"] += 1
                px += snap.shape[0] * snap.shape[1]
        if unwritten_visible:
            stats["pixels_skipped"] += 1
        elif (fd / "screen.argb").exists() and (fd / "palette_next.bin").exists():
            pal = palette_rgb((fd / "palette_next.bin").read_bytes(), mc["palette"], mc["pal_entries"])
            fail += bool(diff_report("pixels", fd.name, pal[pens], load_argb(fd), diffdir))
            checked["pixels"] += 1
        bad += bool(fail)
        if not fail and not quiet:
            print(f"MATCH {fd.name}")
    print(f"{len(frames) - bad}/{len(frames)} frames pixel-exact "
          f"(snap checks {checked['snap']}, pixels() checks {checked['pixels']}, {px} snapshot px; "
          f"{stats['unwritten_frames']} frames showed never-written palette entries = MAME power-on pens, "
          f"their pixels() check skipped)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
