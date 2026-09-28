#!/usr/bin/env python3
"""Helpers for oracle frame dumps: read screen.argb, write PNG/PPM, sheets.

screen.argb = screen_device::pixels() of the visible area in native
(unrotated) orientation, 32 bits per pixel little-endian 0xAARRGGBB.

Usage:
  frame_tools.py png <frame_dir> [--rot270]     write screen.png next to it
  frame_tools.py sheet <out.png> <frame_dir>... contact sheet (rotated 270)
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def load_argb(frame_dir):
    d = Path(frame_dir)
    st = json.loads((d / "state.json").read_text())
    w, h = st["width"], st["height"]
    a = np.frombuffer((d / "screen.argb").read_bytes(), dtype="<u4").reshape(h, w)
    rgb = np.stack([(a >> 16) & 255, (a >> 8) & 255, a & 255], axis=-1).astype(np.uint8)
    return rgb


def to_image(rgb, rot270=False):
    im = Image.fromarray(rgb, "RGB")
    if rot270:
        im = im.transpose(Image.Transpose.ROTATE_90)   # ROT270 game shown upright
    return im


def main(argv):
    if argv[0] == "png":
        d = Path(argv[1])
        to_image(load_argb(d), "--rot270" in argv).save(d / "screen.png")
    elif argv[0] == "sheet":
        out = argv[1]
        dirs = argv[2:]
        ims = [to_image(load_argb(d), True).resize((120, 192)) for d in dirs]
        cols = 10
        sheet = Image.new("RGB", (120 * cols, 192 * ((len(ims) + cols - 1) // cols)))
        for i, im in enumerate(ims):
            sheet.paste(im, ((i % cols) * 120, (i // cols) * 192))
        sheet.save(out)


if __name__ == "__main__":
    main(sys.argv[1:])
