#!/usr/bin/env python3
"""Dooyong reference renderer (PLAN M0.5), Z80 family.

Implements spec sections 6-12 from a MAME oracle frame dump
(sim/mame/dy_oracle.lua) plus the region images from
tools/build_regions.py, and reproduces MAME's frame pixel for pixel. It is
the model the M1 video RTL is checked against, so it is written from the
spec and the driver, not from MAME internals beyond those the spec cites.

Coverage: lastday, gulfstrm, pollux, flytiger, bluehawk, primella family
(sadari, gundl94, primella). The 68000 family is not implemented yet (it
needs the 16x16 layers, colour ROM and 68000 sprite list, spec 7.4/10.2).

Usage:
  dy_render.py <frame_dir> [--regions DIR] [--out out.png]
Frame dirs hold state.json, palette.bin, text.bin, spriteram_buf.bin.
"""
import json
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent.parent
REGIONS = ROOT / "sim" / "build" / "regions"

SCREEN_W, SCREEN_H = 512, 256

# --------------------------------------------------------------------------
# graphics layouts (spec 12; dooyong.cpp 1342-1378, generic.cpp)
# offsets are bit offsets into a logical big-endian byte stream, bit 0 = MSB
# of byte 0; the first plane is the MSB of the pen.
# --------------------------------------------------------------------------


def _step(start, step, n):
    return [start + step * i for i in range(n)]


TILELAYOUT = dict(
    w=32, h=32, planes=_step(0, 4, 4),
    x=_step(0, 1, 4) + _step(16, 1, 4)
    + _step(4 * 8 * 32, 1, 4) + _step(4 * 8 * 32 + 16, 1, 4)
    + _step(2 * 4 * 8 * 32, 1, 4) + _step(2 * 4 * 8 * 32 + 16, 1, 4)
    + _step(3 * 4 * 8 * 32, 1, 4) + _step(3 * 4 * 8 * 32 + 16, 1, 4),
    y=_step(0, 4 * 8, 32), inc=32 * 32 * 4, frac=None)

SPRITELAYOUT = dict(
    w=16, h=16, planes=_step(0, 4, 4),
    x=_step(0, 1, 4) + _step(16, 1, 4) + _step(4 * 8 * 16, 1, 4) + _step(4 * 8 * 16 + 16, 1, 4),
    y=_step(0, 4 * 8, 16), inc=128 * 8, frac=None)

# planes 0,1 from the first half of the region, 2,3 from the second half
LASTDAY_CHARLAYOUT = dict(
    w=8, h=8, planes=[0, 4, "F+0", "F+4"],
    x=_step(0, 1, 4) + _step(8, 1, 4), y=_step(0, 2 * 8, 8), inc=8 * 8 * 2, frac=2)

PACKED_8X8 = dict(   # gfx_8x8x4_packed_msb
    w=8, h=8, planes=_step(0, 1, 4), x=_step(0, 4, 8), y=_step(0, 4 * 8, 8),
    inc=8 * 8 * 4, frac=None)


def decode_gfx(data, lay):
    """Return uint8 array (count, h, w) of 4-bit pens."""
    bits = np.unpackbits(np.frombuffer(data, dtype=np.uint8))
    total_bits = len(data) * 8
    if lay["frac"]:
        half = total_bits // lay["frac"]
        count = half // lay["inc"]
        planes = [half + int(p[2:]) if isinstance(p, str) else p for p in lay["planes"]]
    else:
        count = total_bits // lay["inc"]
        planes = lay["planes"]
    base = np.arange(count, dtype=np.int64)[:, None, None] * lay["inc"]
    yx = np.array(lay["y"], dtype=np.int64)[:, None] + np.array(lay["x"], dtype=np.int64)[None, :]
    out = np.zeros((count, lay["h"], lay["w"]), dtype=np.uint8)
    n = len(planes)
    for i, p in enumerate(planes):
        out |= (bits[base + p + yx[None, :, :]] << (n - 1 - i)).astype(np.uint8)
    return out


# --------------------------------------------------------------------------
# per-machine configuration (spec 6.2, 7.5, 10.1, 11)
# layer: tag (MAME device), gfx region, map region, map word offset (negative
# = from end), map length in words (-1 = whole), colour base, colour count
# of the gfx entry, transparent pen (None = opaque), map format callback.
# --------------------------------------------------------------------------
L = dict
MACHINES = {
    "lastday": dict(
        layers={"bg0": L(tag="bg1", gfx="bg0", map="bg0_tmap", off=0, len=-1, base=768, colors=16, transpen=None),
                "fg0": L(tag="fg1", gfx="fg0", map="fg0_tmap", off=0, len=-1, base=512, colors=16, transpen=15)},
        text=L(layout="lastday", colors=16, yscroll=8), sprites=L(colors=16, ext=()),
        palette="xBGR_444", pal_entries=1024),
    "gulfstrm": dict(
        layers={"bg0": L(tag="bg1", gfx="bg0", map="bg0_tmap", off=0, len=-1, base=768, colors=16, transpen=None),
                "fg0": L(tag="fg1", gfx="fg0", map="fg0_tmap", off=0, len=-1, base=512, colors=16, transpen=15)},
        text=L(layout="lastday", colors=16, yscroll=8), sprites=L(colors=16, ext=("12BIT",)),
        palette="xRGB_555", pal_entries=1024),
    "pollux": dict(
        layers={"bg0": L(tag="bg1", gfx="bg0", map="bg0_tmap", off=0, len=-1, base=768, colors=80, transpen=None),
                "fg0": L(tag="fg1", gfx="fg0", map="fg0_tmap", off=0, len=-1, base=512, colors=80, transpen=15)},
        text=L(layout="lastday", colors=80, yscroll=0), sprites=L(colors=80, ext=("12BIT", "HEIGHT")),
        palette="xRGB_555", pal_entries=2048),
    "flytiger": dict(
        layers={"bg0": L(tag="bg1", gfx="bg0", map="bg0", off=0x3C000, len=0x4000, base=768, colors=80, transpen=15),
                "fg0": L(tag="fg1", gfx="fg0", map="fg0", off=0x3C000, len=0x4000, base=512, colors=96, transpen=15)},
        text=L(layout="lastday", colors=80, yscroll=0),
        sprites=L(colors=80, ext=("12BIT", "HEIGHT", "YSHIFT_FLYTIGER")),
        palette="xRGB_555", pal_entries=2048),
    "bluehawk": dict(
        layers={"bg0": L(tag="bg1", gfx="bg0", map="bg0", off=0x3C000, len=0x4000, base=768, colors=16, transpen=None, cb="bluehawk"),
                "fg0": L(tag="fg1", gfx="fg0", map="fg0", off=0x3C000, len=0x4000, base=512, colors=16, transpen=15, cb="bluehawk"),
                "fg1": L(tag="fg2", gfx="fg1", map="fg1", off=0x1C000, len=0x4000, base=0, colors=16, transpen=15, cb="bluehawk")},
        text=L(layout="packed", colors=16, yscroll=0),
        sprites=L(colors=16, ext=("12BIT", "HEIGHT", "YSHIFT_BLUEHAWK")),
        palette="xRGB_555", pal_entries=1024),
    "primella": dict(
        layers={"bg0": L(tag="bg1", gfx="bg0", map="bg0", off=-0x4000, len=0x4000, base=768, colors=16, transpen=None, cb="bluehawk"),
                "fg0": L(tag="fg1", gfx="fg0", map="fg0", off=-0x4000, len=0x4000, base=512, colors=16, transpen=15, cb="bluehawk")},
        text=L(layout="packed", colors=16, yscroll=0), sprites=None,
        palette="xRGB_555", pal_entries=1024),
}
VISIBLE = {"primella": (64, 447, 0, 255)}
DEFAULT_VISIBLE = (64, 447, 8, 247)


@lru_cache(maxsize=None)
def region(setname, tag):
    return (REGIONS / setname / f"{tag}.bin").read_bytes()


@lru_cache(maxsize=None)
def gfx(setname, tag, layout_name):
    lay = {"tile": TILELAYOUT, "sprite": SPRITELAYOUT,
           "lastday": LASTDAY_CHARLAYOUT, "packed": PACKED_8X8}[layout_name]
    return decode_gfx(region(setname, tag), lay)


@lru_cache(maxsize=None)
def map_words(setname, tag):
    b = region(setname, tag)
    return np.frombuffer(b, dtype=">u2").astype(np.int64)


def palette_rgb(pal_bytes, fmt, entries):
    """Palette RAM (little-endian Z80 words) -> (entries+1, 3) uint8; the
    extra last entry is MAME's black pen used for the background fill."""
    w = np.frombuffer(pal_bytes[:entries * 2], dtype="<u2").astype(np.int64)
    if fmt == "xRGB_555":
        r, g, b = (w >> 10) & 31, (w >> 5) & 31, w & 31
        conv = lambda v: (v << 3) | (v >> 2)
    elif fmt == "xBGR_444":
        r, g, b = w & 15, (w >> 4) & 15, (w >> 8) & 15
        conv = lambda v: v * 0x11
    else:
        raise ValueError(fmt)
    rgb = np.stack([conv(r), conv(g), conv(b)], axis=-1).astype(np.uint8)
    return np.vstack([rgb, np.zeros((1, 3), dtype=np.uint8)])


# --------------------------------------------------------------------------
# layers
# --------------------------------------------------------------------------


def rom_layer_pixmap(setname, lc, regs, bank):
    """Build the 1024x256 pixmap (pens, opaque mask) of one ROM layer from
    its registers (spec 7.1-7.3). Returns logical (unflipped) orientation."""
    tiles = gfx(setname, lc["gfx"], "tile")
    words = map_words(setname, lc["map"])
    nwords = len(words)
    off = lc["off"] if lc["off"] >= 0 else nwords + lc["off"]
    length = nwords if lc["len"] < 0 else lc["len"]
    cols, rows, tw = 32, 8, 32
    col = np.arange(cols)[:, None]
    row = np.arange(rows)[None, :]
    idx = col * rows + row + regs[1] * (256 // tw) * rows
    attr = words[off + (idx & (length - 1))]                    # (cols, rows)
    if regs[6] & 0x20:      # format A
        code = ((attr >> 15) & 1) << 9 | (attr & 0x1FF)
        color = (attr >> 11) & 15
        flipx = (attr >> 9) & 1
        flipy = (attr >> 10) & 1
    else:                   # format B (default and bluehawk callback agree)
        a = attr & 0x3FFF
        code = a & 0x3FF
        color = (a >> 10) & 15
        flipx = (attr >> 14) & 1
        flipy = (attr >> 15) & 1
    color = color | bank
    code = code % len(tiles)
    pens, opaque = _assemble(tiles, code, flipx, flipy,
                             lc["base"] + 16 * (color % lc["colors"]), lc["transpen"])
    return pens, opaque


def _assemble(tiles, code, flipx, flipy, pbase, transpen):
    """Place tiles[code[c, r]] (with per-tile flips) at column c, row r of a
    pixmap; returns (pens, opaque) with shape (rows*th, cols*tw)."""
    cols, rows = code.shape
    th, tw = tiles.shape[1:]
    yy = np.arange(th)
    xx = np.arange(tw)
    ty = np.where(flipy[..., None].astype(bool), th - 1 - yy, yy)       # (c, r, th)
    tx = np.where(flipx[..., None].astype(bool), tw - 1 - xx, xx)       # (c, r, tw)
    pix = tiles[code[..., None, None], ty[..., :, None], tx[..., None, :]].astype(np.int64)
    pens = pbase[..., None, None] + pix                                  # (c, r, th, tw)
    opaque = np.ones(pix.shape, dtype=bool) if transpen is None else pix != transpen
    pens = pens.transpose(1, 2, 0, 3).reshape(rows * th, cols * tw)
    opaque = opaque.transpose(1, 2, 0, 3).reshape(rows * th, cols * tw)
    return pens, opaque


def text_pixmap(setname, tcfg, text_words, bank):
    chars = gfx(setname, "tx", tcfg["layout"])
    cols, rows = 64, 32
    idx = np.arange(cols)[:, None] * rows + np.arange(rows)[None, :]
    attr = text_words[idx]
    code = (attr & 0xFFF) % len(chars)
    color = ((attr >> 12) & 15) | bank
    zeros = np.zeros_like(code)
    return _assemble(chars, code, zeros, zeros, 16 * (color % tcfg["colors"]), 15)


def scroll_sample(pens, opaque, scrollx, scrolly, flip):
    """Sample a tilemap pixmap onto the 512x256 screen bitmap with MAME's
    scroll rule (tilemap.cpp effective_rowscroll/colscroll with dx = dy = 0
    and screen_width/height = the full 512x256 bitmap, spec 11.10):
      normal:  tilemap x = (screen x + scroll) mod W
      flipped: the pixmap is the logical tilemap mirrored and its origin is
               screen_width - W + scroll, which works out to
               tilemap x = (scroll + 511 - screen x) mod W
    and the same for y with 255 and H."""
    h, w = pens.shape
    sx = np.arange(SCREEN_W)
    sy = np.arange(SCREEN_H)
    if flip:
        xs = (scrollx + SCREEN_W - 1 - sx) % w
        ys = (scrolly + SCREEN_H - 1 - sy) % h
    else:
        xs = (sx + scrollx) % w
        ys = (sy + scrolly) % h
    return pens[np.ix_(ys, xs)], opaque[np.ix_(ys, xs)]


# --------------------------------------------------------------------------
# sprites (spec 10.1, 10.3)
# --------------------------------------------------------------------------


def draw_z80_sprites(setname, scfg, spr, bitmap, prio, flip, bank, clip):
    tiles = gfx(setname, "sprite", "sprite")
    ntiles = len(tiles)
    x0, x1, y0, y1 = clip
    ext = scfg["ext"]
    for offs in range(0, len(spr), 32):
        sx = spr[offs + 3] | ((spr[offs + 1] & 0x10) << 4)
        sy = spr[offs + 2]
        code = spr[offs] | ((spr[offs + 1] & 0xE0) << 3)
        color = spr[offs + 1] & 0x0F
        pmask = (0xFC if color in (0, 15) else 0xF0) | (1 << 31)
        flipx = flipy = False
        height = 0
        if ext:
            e = spr[offs + 0x1C]
            if "12BIT" in ext:
                code |= (e & 1) << 11
            if "HEIGHT" in ext:
                height = (e & 0x70) >> 4
                code &= ~height
                flipx = bool(e & 8)
                flipy = bool(e & 4)
            if "YSHIFT_BLUEHAWK" in ext:
                sy += 6 - ((~e & 2) << 7)
            if "YSHIFT_FLYTIGER" in ext:
                sy -= (e & 2) << 7
        if flip:
            sx = 498 - sx
            sy = 240 - 16 * height - sy
            flipx, flipy = not flipx, not flipy
        color |= bank
        pbase = 256 + 16 * (color % scfg["colors"])
        for y in range(height + 1):
            t = tiles[(code + y) % ntiles]
            if flipx:
                t = t[:, ::-1]
            if flipy:
                t = t[::-1, :]
            ty = sy + 16 * ((height - y) if flipy else y)
            # clip the 16x16 tile against the visible cliprect
            ya, yb = max(ty, y0), min(ty + 15, y1)
            xa, xb = max(sx, x0), min(sx + 15, x1)
            if ya > yb or xa > xb:
                continue
            sub = t[ya - ty:yb - ty + 1, xa - sx:xb - sx + 1]
            pr = prio[ya:yb + 1, xa:xb + 1]
            bm = bitmap[ya:yb + 1, xa:xb + 1]
            solid = sub != 15
            allowed = ((np.left_shift(np.int64(1), pr.astype(np.int64) & 31)) & pmask) == 0
            draw = solid & allowed
            bm[draw] = pbase + sub[draw]
            pr[solid] = 31


# --------------------------------------------------------------------------
# frame
# --------------------------------------------------------------------------


def load_state(frame_dir):
    d = Path(frame_dir)
    st = json.loads((d / "state.json").read_text())
    return d, st


def render(frame_dir, regions_set=None):
    d, st = load_state(frame_dir)
    mname = st["machine"]
    mc = MACHINES[mname]
    setname = regions_set or st["set"]
    flip = bool(st.get("m_flip_screen_x", [0])[0])
    bank = 64 if st.get("m_palette_bank", [0])[0] else 0
    black = mc["pal_entries"]          # index of the appended black pen
    bitmap = np.full((SCREEN_H, SCREEN_W), black, dtype=np.int64)
    prio = np.zeros((SCREEN_H, SCREEN_W), dtype=np.uint8)
    clip = VISIBLE.get(mname, DEFAULT_VISIBLE)

    def draw_layer(name, pcode):
        lc = mc["layers"][name]
        regs = st[f"{lc['tag']}.m_registers"]
        if regs[6] & 0x10:            # layer disabled
            return
        lbank = st.get(f"{lc['tag']}.m_palette_bank", [0])[0]
        pens, opq = rom_layer_pixmap(setname, lc, regs, lbank)
        p, o = scroll_sample(pens, opq, regs[0], regs[3] | (regs[4] << 8), flip)
        bitmap[o] = p[o]
        prio[o] |= pcode

    def draw_text(pcode):
        tc = mc["text"]
        tw = np.frombuffer((d / "text.bin").read_bytes(), dtype=">u2").astype(np.int64)
        tbank = st.get("tx.m_palette_bank", [0])[0]
        pens, opq = text_pixmap(setname, tc, tw, tbank)
        ys = tc["yscroll"]
        if ys and flip:
            ys = -ys
        p, o = scroll_sample(pens, opq, 0, ys, flip)
        bitmap[o] = p[o]
        prio[o] |= pcode

    if mname == "flytiger":
        if st.get("m_flytiger_pri", [0])[0]:
            draw_layer("fg0", 1); draw_layer("bg0", 2)
        else:
            draw_layer("bg0", 1); draw_layer("fg0", 2)
        draw_text(4)
    elif mname == "bluehawk":
        draw_layer("bg0", 1); draw_layer("fg0", 2); draw_layer("fg1", 4); draw_text(4)
    elif mname in ("lastday", "gulfstrm", "pollux"):
        draw_layer("bg0", 1); draw_layer("fg0", 2); draw_text(4)
    elif mname == "primella":
        txpri = st.get("m_tx_pri", [0])[0]
        draw_layer("bg0", 0)
        if txpri:
            draw_text(0)
        draw_layer("fg0", 0)
        if not txpri:
            draw_text(0)
    else:
        raise NotImplementedError(mname)

    if mc["sprites"] is not None and not (mname == "lastday" and st.get("m_sprites_disabled", [0])[0]):
        spr = np.frombuffer((d / "spriteram_buf.bin").read_bytes(), dtype=np.uint8).astype(np.int64)
        draw_z80_sprites(setname, mc["sprites"], spr, bitmap, prio, flip, bank, clip)

    pal = palette_rgb((d / "palette.bin").read_bytes(), mc["palette"], mc["pal_entries"])
    x0, x1, y0, y1 = clip
    return pal[bitmap[y0:y1 + 1, x0:x1 + 1]], bitmap[y0:y1 + 1, x0:x1 + 1]


def main(argv):
    frame_dir = argv[0]
    out = None
    if "--out" in argv:
        out = argv[argv.index("--out") + 1]
    rgb, _ = render(frame_dir)
    if out:
        from PIL import Image
        Image.fromarray(rgb, "RGB").save(out)


if __name__ == "__main__":
    main(sys.argv[1:])
