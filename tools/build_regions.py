#!/usr/bin/env python3
"""M0.2: rebuild every MAME region exactly as the ROM_START block loads it,
write per-region .bin/.hex files for the Verilator harness, and emit the
SDRAM image in the fixed PLAN 4.3 layout.

Outputs (under sim/build/regions/<set>/, gitignored):
  <region>.bin   logical byte stream (16-bit BE regions: byte 2n = high byte
                 of word n)
  <region>.hex   $readmemh text: 16-bit regions one word per line (4 hex
                 digits), 8-bit regions one byte per line
  sdram.bin      SDRAM image, byte offsets per SDRAM_LAYOUT below, same
                 byte order as the .bin files (word n = bytes 2n:2n+1, high
                 byte first)
  manifest.json  region sizes, sha1s, SDRAM placement

Usage: tools/build_regions.py [--no-hex] [set ...]    (default: all sets)
"""
import hashlib
import json
import sys
from pathlib import Path

from romdefs import ROOT, parse_driver, zip_index, build_region

OUT = ROOT / "sim" / "build" / "regions"

# PLAN.md 4.3, fixed here (M0.2). base, max size.
SDRAM_SLOTS = {
    "main":   (0x000000, 0x040000),
    "sound":  (0x040000, 0x010000),
    "tx":     (0x050000, 0x030000),
    "oki":    (0x080000, 0x040000),
    "aux":    (0x0C0000, 0x080000),   # tmap_hi, or bg0_tmap + fg0_tmap
    "sprite": (0x140000, 0x200000),
    "bg0":    (0x340000, 0x100000),
    "bg1":    (0x440000, 0x100000),
    "fg0":    (0x540000, 0x100000),
    "fg1":    (0x640000, 0x100000),
}
SDRAM_END = 0x740000

# region tag -> (slot, offset inside slot). Regions not listed are not
# used by the core (gundl94 cpu2/gfx4).
REGION_SLOT = {
    "maincpu": ("main", 0),
    "audiocpu": ("sound", 0),
    "tx": ("tx", 0),
    "oki": ("oki", 0),
    "tmap_hi": ("aux", 0),
    "bg0_tmap": ("aux", 0x00000),
    "fg0_tmap": ("aux", 0x20000),
    "sprite": ("sprite", 0),
    "bg0": ("bg0", 0),
    "bg1": ("bg1", 0),
    "fg0": ("fg0", 0),
    "fg1": ("fg1", 0),
}
UNUSED = {"cpu2", "gfx4"}

# Region sizes the spec (section 13) lists per parent; checked here so a
# parser or spec error cannot pass silently.
SPEC_REGIONS = {
    "lastday": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x8000, sprite=0x40000, bg0=0x80000, fg0=0x40000, bg0_tmap=0x20000, fg0_tmap=0x20000),
    "gulfstrm": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x8000, sprite=0x80000, bg0=0x80000, fg0=0x40000, bg0_tmap=0x20000, fg0_tmap=0x20000),
    "pollux": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x10000, sprite=0x80000, bg0=0x80000, fg0=0x80000, bg0_tmap=0x20000, fg0_tmap=0x20000),
    "bluehawk": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x10000, sprite=0x80000, bg0=0x80000, fg0=0x80000, fg1=0x40000, oki=0x40000),
    "flytiger": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x10000, sprite=0x80000, bg0=0x80000, fg0=0x80000, oki=0x80000),
    "sadari": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x20000, bg0=0x80000, fg0=0x80000, oki=0x40000),
    "gundl94": dict(maincpu=0x20000, audiocpu=0x10000, tx=0x20000, bg0=0x40000, fg0=0x40000, oki=0x40000, cpu2=0x30000, gfx4=0x40000),
    "superx": dict(maincpu=0x40000, audiocpu=0x10000, sprite=0x200000, fg1=0x100000, fg0=0x100000, bg1=0x100000, bg0=0x100000, tmap_hi=0x80000, oki=0x40000),
    "rshark": dict(maincpu=0x40000, audiocpu=0x10000, sprite=0x200000, fg1=0x100000, fg0=0x100000, bg1=0x100000, bg0=0x100000, tmap_hi=0x80000, oki=0x40000),
    "popbingo": dict(maincpu=0x40000, audiocpu=0x10000, sprite=0x100000, bg0=0x100000, bg1=0x100000, oki=0x40000),
}
# region bytes per parent from spec 13 ("region bytes", KB)
SPEC_TOTAL_KB = {"lastday": 1504, "gulfstrm": 1760, "pollux": 2048, "bluehawk": 2304,
                 "flytiger": 2304, "sadari": 1600, "superx": 7232, "rshark": 7232,
                 "popbingo": 3648}


def write_hex(path, data, width):
    if width == 16:
        lines = ["%02x%02x" % (data[i], data[i + 1]) for i in range(0, len(data), 2)]
    else:
        lines = ["%02x" % b for b in data]
    path.write_text("\n".join(lines) + "\n")


def build(name, sets, hexout=True):
    rs = sets[name]
    _, files, _ = zip_index(name, sets)
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    sdram = bytearray(SDRAM_END)
    manifest = {"set": name, "parent": rs.parent, "machine": rs.machine, "rot": rs.rot,
                "regions": {}, "sdram_end": SDRAM_END}
    errors = []
    for region in rs.regions:
        img = build_region(region, files)
        (d / f"{region.tag}.bin").write_bytes(img)
        if hexout:
            write_hex(d / f"{region.tag}.hex", img, region.width)
        entry = {"size": len(img), "width": region.width, "endian": region.endian,
                 "sha1": hashlib.sha1(img).hexdigest(), "line": region.line}
        if region.tag in REGION_SLOT:
            slot, sub = REGION_SLOT[region.tag]
            base, cap = SDRAM_SLOTS[slot]
            n = min(len(img), cap - sub)
            if n < len(img):
                # only flytiger's 512 KB OKI region hits this: the M6295
                # addresses 256 KB, and only 128 KB is loaded
                tail = img[n:]
                if any(tail):
                    errors.append(f"{region.tag}: non-zero data beyond slot")
                entry["sdram_truncated_from"] = len(img)
            sdram[base + sub: base + sub + n] = img[:n]
            entry["sdram_base"] = base + sub
            entry["sdram_bytes"] = n
        elif region.tag not in UNUSED:
            errors.append(f"{region.tag}: no SDRAM slot")
        manifest["regions"][region.tag] = entry
    (d / "sdram.bin").write_bytes(bytes(sdram))
    (d / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")

    spec = SPEC_REGIONS.get(name) or SPEC_REGIONS.get(rs.parent)
    if spec:
        got = {t: e["size"] for t, e in manifest["regions"].items()}
        for t, sz in spec.items():
            if t == "cpu2" and t not in got and name == "primella":
                continue
            if t in ("cpu2", "gfx4") and name == "primella":
                continue
            if got.get(t) != sz:
                errors.append(f"region {t}: {got.get(t)} != spec {sz:#x}")
    if name in SPEC_TOTAL_KB:
        tot = sum(e["size"] for e in manifest["regions"].values()) // 1024
        if tot != SPEC_TOTAL_KB[name]:
            errors.append(f"total {tot} KB != spec {SPEC_TOTAL_KB[name]} KB")
    return manifest, errors


def main(argv):
    hexout = "--no-hex" not in argv
    argv = [a for a in argv if not a.startswith("--")]
    sets = parse_driver()
    todo = argv or list(sets)
    fails = 0
    for name in todo:
        man, errors = build(name, sets, hexout)
        tot = sum(e["size"] for e in man["regions"].values())
        print(f"{'OK ' if not errors else 'BAD'} {name:11s} {len(man['regions'])} regions, "
              f"{tot // 1024} KB")
        for e in errors:
            print("     " + e)
        fails += bool(errors)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
