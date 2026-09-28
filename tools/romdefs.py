#!/usr/bin/env python3
"""Parse the ROM_START blocks of the vendored MAME driver and rebuild regions.

The expected-ROM table is generated from reference/mame/dooyong.cpp, never
typed by hand (PLAN M0.1). Region reconstruction follows MAME romload.cpp
semantics for the macros this driver uses:

  ROM_REGION(size, tag, 0)        8-bit region, zero filled
  ROM_REGION16_BE(size, tag, 0)   16-bit big-endian region, zero filled
  ROM_LOAD(name, ofs, len, hash)  bytes copied to ofs..ofs+len
  ROM_LOAD16_BYTE(...)            byte i -> ofs + 2*i (one byte lane)
  ROM_LOAD16_WORD_SWAP(...)       bytes swapped within each 16-bit word
  ROM_CONTINUE(ofs, len)          next len bytes of the same file, same mode
  ROM_RELOAD(ofs, len)            same file again from its start, same mode
  ROM_FILL(ofs, len, value)       fill

Region images are returned as a LOGICAL byte stream: for 16-bit BE regions
byte 2n is the high byte of word n (the view MAME's gfx decoder and
required_region_ptr<u16> see). This is also the byte order used for every
.bin file this project writes.
"""
import re
import zipfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DRIVER = ROOT / "reference" / "mame" / "dooyong.cpp"
ROMDIR = ROOT / "roms"


@dataclass
class Load:
    kind: str            # LOAD, LOAD16_BYTE, LOAD16_WORD_SWAP, FILL
    name: str | None
    offset: int
    length: int
    crc: str | None = None
    sha1: str | None = None
    bad_dump: bool = False
    line: int = 0
    # continuation pieces: list of (kind, offset, length, file_pos)
    pieces: list = field(default_factory=list)


@dataclass
class Region:
    tag: str
    size: int
    width: int           # 8 or 16
    endian: str          # little or big
    loads: list = field(default_factory=list)
    line: int = 0


@dataclass
class RomSet:
    name: str
    parent: str | None
    machine: str
    rot: str
    regions: list
    line_start: int
    line_end: int

    def region(self, tag):
        for r in self.regions:
            if r.tag == tag:
                return r
        return None


def _num(s):
    return int(s.strip(), 0)


_RE_START = re.compile(r"^ROM_START\(\s*(\w+)\s*\)")
_RE_REGION = re.compile(r"^\s*ROM_REGION(16_BE)?\(\s*([^,]+),\s*\"([^\"]+)\"")
_RE_LOAD = re.compile(
    r"^\s*ROM_(LOAD|LOAD16_BYTE|LOAD16_WORD_SWAP)\(\s*\"([^\"]+)\"\s*,\s*([^,]+),\s*([^,]+),(.*)\)")
_RE_CONT = re.compile(r"^\s*ROM_(CONTINUE|RELOAD)\(\s*([^,]+),\s*([^,\)]+)\s*\)")
_RE_FILL = re.compile(r"^\s*ROM_FILL\(\s*([^,]+),\s*([^,]+),\s*([^,\)]+)\s*\)")
_RE_GAME = re.compile(r"^GAME\(\s*\d+,\s*(\w+),\s*(\w+),\s*(\w+),\s*\w+,\s*\w+,\s*\w+,\s*(ROT\d+)")


def parse_driver(path=DRIVER):
    lines = path.read_text(encoding="utf-8").splitlines()
    sets = {}
    cur = None
    region = None
    last = None
    for i, ln in enumerate(lines, 1):
        code = ln.split("//")[0]
        m = _RE_START.match(code)
        if m:
            cur = RomSet(m.group(1), None, "", "", [], i, 0)
            region = None
            last = None
            continue
        if cur is None:
            continue
        if code.strip().startswith("ROM_END"):
            cur.line_end = i
            sets[cur.name] = cur
            cur = None
            continue
        m = _RE_REGION.match(code)
        if m:
            wide = bool(m.group(1))
            region = Region(m.group(3), _num(m.group(2)), 16 if wide else 8,
                            "big" if wide else "little", [], i)
            cur.regions.append(region)
            last = None
            continue
        m = _RE_LOAD.match(code)
        if m:
            rest = m.group(5)
            crc = re.search(r"CRC\((\w+)\)", rest)
            sha = re.search(r"SHA1\((\w+)\)", rest)
            ld = Load(m.group(1), m.group(2), _num(m.group(3)), _num(m.group(4)),
                      crc.group(1).lower() if crc else None,
                      sha.group(1).lower() if sha else None,
                      "BAD_DUMP" in rest, i)
            ld.pieces.append((ld.kind, ld.offset, ld.length, 0))
            region.loads.append(ld)
            last = ld
            continue
        m = _RE_CONT.match(code)
        if m:
            ofs, length = _num(m.group(2)), _num(m.group(3))
            if m.group(1) == "CONTINUE":
                # file position continues after the last non-reload piece
                pos = last.pieces[-1][3] + last.pieces[-1][2]
                last.pieces.append((last.kind, ofs, length, pos))
            else:
                last.pieces.append((last.kind, ofs, length, 0))
            continue
        m = _RE_FILL.match(code)
        if m:
            region.loads.append(Load("FILL", None, _num(m.group(1)), _num(m.group(2)),
                                     crc=hex(_num(m.group(3))), line=i))
            last = None
            continue
    for i, ln in enumerate(lines, 1):
        m = _RE_GAME.match(ln)
        if m and m.group(1) in sets:
            s = sets[m.group(1)]
            s.parent = None if m.group(2) == "0" else m.group(2)
            s.machine = m.group(3)
            s.rot = m.group(4)
    return sets


def file_size(ld):
    """Bytes the load consumes from its file (RELOAD pieces re-read)."""
    return max(p[3] + p[2] for p in ld.pieces)


def zip_index(setname, sets):
    """Map crc -> bytes over the zip that holds this set (merged sets live in
    the parent zip, clone-only files under '<clone>/')."""
    top = setname
    while sets[top].parent:
        top = sets[top].parent
    zpath = ROMDIR / f"{top}.zip"
    out = {}
    names = {}
    with zipfile.ZipFile(zpath) as z:
        for info in z.infolist():
            data = z.read(info)
            crc = "%08x" % (zlib.crc32(data) & 0xFFFFFFFF)
            out.setdefault(crc, data)
            names.setdefault(crc, []).append(info.filename)
    return zpath, out, names


def build_region(region, files):
    """Return the logical byte image of one region. files: crc -> bytes."""
    img = bytearray(region.size)
    for ld in region.loads:
        if ld.kind == "FILL":
            val = int(ld.crc, 16)
            img[ld.offset:ld.offset + ld.length] = bytes([val]) * ld.length
            continue
        data = files[ld.crc]
        for kind, ofs, length, pos in ld.pieces:
            chunk = data[pos:pos + length]
            assert len(chunk) == length, (ld.name, pos, length, len(data))
            if kind == "LOAD":
                img[ofs:ofs + length] = chunk
            elif kind == "LOAD16_BYTE":
                for k in range(length):
                    img[ofs + 2 * k] = chunk[k]
            elif kind == "LOAD16_WORD_SWAP":
                sw = bytearray(length)
                sw[0::2] = chunk[1::2]
                sw[1::2] = chunk[0::2]
                img[ofs:ofs + length] = sw
            else:
                raise ValueError(kind)
    return bytes(img)


def build_set(setname, sets=None):
    sets = sets or parse_driver()
    _, files, _ = zip_index(setname, sets)
    return {r.tag: build_region(r, files) for r in sets[setname].regions}


if __name__ == "__main__":
    s = parse_driver()
    for name, rs in s.items():
        print(name, rs.parent, rs.machine, rs.rot,
              ", ".join(f"{r.tag}:{r.size:#x}" for r in rs.regions))
