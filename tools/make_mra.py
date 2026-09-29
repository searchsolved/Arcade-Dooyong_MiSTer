#!/usr/bin/env python3
"""M4: generate the MRA files and prove each one reproduces the SDRAM image.

For every set the ROM stream the MiSTer assembles (index 0) must equal
sim/build/regions/<set>/sdram.bin byte for byte, up to the end of the last
region the core uses (PLAN 4.3 layout; the SDRAM controller writes the
stream from byte 0). The generator tracks where every output byte comes from
(file + position, or a fill value) while replaying the ROM_START loads
(tools/romdefs.py semantics), then encodes the sequence as MRA parts:
  linear run from one file      <part name crc offset length/>
  16-bit byte-lane interleave   <interleave output="16"> two parts, map 01/10
                                (a lane may be inline fill data)
  16-bit word swap of one file  <interleave output="16"> one part, map 12
  fill                          <part repeat="N">VV</part>
Then assemble() replays the MRA with Main_MiSTer's mra_loader.cpp rules
(map nibble k = output byte k of the unit, rightmost = lowest address;
offset/length/repeat/crc reset per part) from the zip and compares.

Usage: tools/make_mra.py [set ...]      (default: the sets the core supports)
Writes releases/mra/<Title>.mra; exit 0 only if every MRA verifies.
"""
import json
import re
import sys
import zipfile
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).parent))
from romdefs import ROOT, parse_driver, zip_index               # noqa: E402
from build_regions import SDRAM_SLOTS, REGION_SLOT, OUT as REGIONS  # noqa: E402

GAME_ID = {"lastday": 0, "gulfstrm": 1, "pollux": 2, "flytiger": 3, "bluehawk": 4}
# primella machine config: sadari 5; gundl94 and its clone primella 6
PRIMELLA_ID = {"sadari": 5, "gundl94": 6}
SUPPORTED = ("lastday", "gulfstrm", "pollux", "flytiger", "bluehawk", "primella")      # machines the RBF runs so far
RBF = "Dooyong"
OUTDIR = ROOT / "releases" / "mra"


# ------------------------------------------------------------------ sources
def region_sources(region):
    """Per byte of the region: (crc, file_pos) or ("fill", value)."""
    src = [("fill", 0)] * region.size
    for ld in region.loads:
        if ld.kind == "FILL":
            v = int(ld.crc, 16)
            for k in range(ld.length):
                src[ld.offset + k] = ("fill", v)
            continue
        for kind, ofs, length, pos in ld.pieces:
            if kind == "LOAD":
                for k in range(length):
                    src[ofs + k] = (ld.crc, pos + k)
            elif kind == "LOAD16_BYTE":
                for k in range(length):
                    src[ofs + 2 * k] = (ld.crc, pos + k)
            elif kind == "LOAD16_WORD_SWAP":
                for k in range(0, length, 2):
                    src[ofs + k] = (ld.crc, pos + k + 1)
                    src[ofs + k + 1] = (ld.crc, pos + k)
            else:
                raise ValueError(kind)
    return src


def stream_sources(rs):
    placed = []
    for region in rs.regions:
        if region.tag not in REGION_SLOT:
            continue
        slot, sub = REGION_SLOT[region.tag]
        base, cap = SDRAM_SLOTS[slot]
        n = min(region.size, cap - sub)
        placed.append((base + sub, region_sources(region)[:n]))
    end = max(b + len(s) for b, s in placed)
    src = [("fill", 0)] * end
    for b, s in placed:
        src[b:b + len(s)] = s
    return src


# ------------------------------------------------------------------ encoder
def _lin(src, p):
    a = src[p]
    n = 1
    while p + n < len(src):
        b = src[p + n]
        if a[0] == "fill":
            if b != a:
                break
        elif b[0] != a[0] or b[1] != a[1] + n:
            break
        n += 1
    return n


def _lane_ok(first, cur, k):
    if first[0] == "fill":
        return cur == first
    return cur[0] == first[0] and cur[1] == first[1] + k


def encode(src):
    """-> list of ('lin', src0, n) | ('fill', v, n) | ('il', even0, odd0, pairs)
    | ('swap', crc, pos, n)."""
    out = []
    p = 0
    N = len(src)
    while p < N:
        n = _lin(src, p)
        if src[p][0] == "fill":
            out.append(("fill", src[p][1], n))
            p += n
            continue
        if n >= 16 or p % 2 or p + 1 >= N:
            out.append(("lin", src[p], n))
            p += n
            continue
        e0, o0 = src[p], src[p + 1]
        # word swap of one file: even = pos+1, odd = pos
        if e0[0] != "fill" and o0[0] == e0[0] and o0[1] == e0[1] - 1:
            k = 0
            while p + 2 * k + 1 < N and src[p + 2 * k] == (e0[0], e0[1] + 2 * k) \
                    and src[p + 2 * k + 1] == (e0[0], o0[1] + 2 * k):
                k += 1
            out.append(("swap", e0[0], o0[1], 2 * k))
            p += 2 * k
            continue
        k = 0
        while p + 2 * k + 1 < N and _lane_ok(e0, src[p + 2 * k], k) and _lane_ok(o0, src[p + 2 * k + 1], k):
            k += 1
        if k >= 2:
            out.append(("il", e0, o0, k))
            p += 2 * k
        else:
            out.append(("lin", src[p], n))
            p += n
    return out


# ------------------------------------------------------------------ XML
def _part(names, crc, pos, n, mapv=None):
    e = ET.Element("part", name=names[crc], crc=crc, offset=f"0x{pos:X}", length=f"0x{n:X}")
    if mapv:
        e.set("map", mapv)
    return e


def _fill(v, n, mapv=None):
    e = ET.Element("part", repeat=f"0x{n:X}")
    if mapv:
        e.set("map", mapv)
    e.text = f"{v:02X}"
    return e


def rom_element(rs, sets, src):
    _, files, names_by_crc = zip_index(rs.name, sets)
    names = {}
    for region in rs.regions:
        for ld in region.loads:
            if ld.crc:
                names[ld.crc] = ld.name
    zips = []
    s = rs.name
    while True:
        zips.append(f"{s}.zip")
        if not sets[s].parent:
            break
        s = sets[s].parent
    rom = ET.Element("rom", index="0", zip="|".join(zips), md5="none")
    for item in encode(src):
        if item[0] == "fill":
            rom.append(_fill(item[1], item[2]))
        elif item[0] == "lin":
            (crc, pos), n = item[1], item[2]
            rom.append(_part(names, crc, pos, n))
        elif item[0] == "swap":
            il = ET.SubElement(rom, "interleave", output="16")
            il.append(_part(names, item[1], item[2], item[3], "12"))
        else:
            _, e0, o0, k = item
            il = ET.SubElement(rom, "interleave", output="16")
            for lane, mapv in ((e0, "01"), (o0, "10")):
                if lane[0] == "fill":
                    il.append(_fill(lane[1], k, mapv))
                else:
                    il.append(_part(names, lane[0], lane[1], k, mapv))
    return rom, files


# ------------------------------------------------------------------ assembler (mra_loader.cpp)
def assemble(mra_path, zipdir):
    root = ET.parse(mra_path).getroot()
    rom = next(r for r in root.findall("rom") if r.get("index") == "0")
    zips = [zipfile.ZipFile(zipdir / z) for z in rom.get("zip").split("|") if (zipdir / z).exists()]
    by_crc = {}
    for z in zips:
        for info in z.infolist():
            by_crc.setdefault("%08x" % info.CRC, (z, info))

    out = bytearray()

    def data_of(part):
        if part.get("name"):
            z, info = by_crc[part.get("crc").lower()]
            d = z.read(info)
            off = int(part.get("offset", "0"), 0)
            ln = int(part.get("length", "-1"), 0)
            d = d[off:] if ln <= 0 else d[off:off + ln]
        else:
            d = bytes.fromhex("".join((part.text or "").split()))
        return d * int(part.get("repeat", "1"), 0)

    for el in rom:
        if el.tag == "part":
            out += data_of(el)
        elif el.tag == "interleave":
            unit = int(el.get("output"), 0) // 8
            lanes = {}
            base = len(out)
            for part in el.findall("part"):
                m = part.get("map")
                nib = [int(c, 16) for c in reversed(m.rjust(unit, "0"))]
                d = data_of(part)
                used = [i for i in range(unit) if nib[i]]
                per = len(used)
                cnt = len(d) // per
                for j in range(cnt):
                    for i in used:
                        lanes[base + j * unit + i] = d[j * per + nib[i] - 1]
            end = max(lanes) + 1
            out += bytes(end - base)
            for a, v in lanes.items():
                out[a] = v
    return bytes(out)


# ------------------------------------------------------------------ switches (spec 9.3, driver 1012-1059)
def game_id(setname, sets):
    rs = sets[setname]
    if rs.machine == "primella":
        return PRIMELLA_ID[rs.parent or setname]
    return GAME_ID[rs.machine]


def switches(machine, parent):
    """DIPs from the driver's INPUT_PORTS (spec 9.3); primella family:
    SWB:1-2 Show Girl, SWB:5 cabinet, sadari also SWB:7 Girl Show Point
    (dooyong.cpp 1261-1292), default DSWB 0xFD."""
    prm = machine == "primella"
    sw = ET.Element("switches", default="FF,FD" if prm else "FF,FF")
    d = [
        ("Service Mode", "0", "On,Off", None),
        ("Coin Type", "1", "B,A", None),
        ("Demo Sounds", "2", "Off,On", None),
        ("Flip Screen", "3", "On,Off", None),
        # coin tables for coin type A (the default); MRA DIPs cannot follow
        # MAME's PORT_CONDITION on coin type B
        ("Coin A", "4,5", "2C/3C,2C/1C,1C/2C,1C/1C", None),
        ("Coin B", "6,7", "2C/3C,2C/1C,1C/2C,1C/1C", None),
    ]
    if prm:
        d.append(("Show Girl", "8,9", "Skip Skip Skip,Dress Half Naked,Dress Half Half,Dress Dress Dress", None))
    else:
        d.append(("Lives", "8,9", "1,4,2,3", None))
    d.append(("Difficulty", "10,11", "Hardest,Hard,Easy,Normal", None))
    if prm:
        d.append(("Cabinet", "12", "Cocktail,Upright", None))
    if prm and parent == "sadari":
        d.append(("Girl Show Point", "14", "Asia,Other Country", None))
    if machine == "flytiger":
        d.append(("Auto Fire", "14", "Off,On", None))
    if machine == "lastday":                     # dooyong.cpp 1183-1191
        d.append(("Bonus Life", "12,13", "None,280000,Every 240000,Every 200000", None))
        d.append(("Speed", "14", "Low,High", None))
    if machine == "gulfstrm":                    # dooyong.cpp 1207-1215
        d.append(("Bonus Life", "12,13", "None,Every 500000,Every 400000,Every 300000", None))
        d.append(("Power Rise(?)", "14", "2,1", None))
    d.append(("Allow Continue", "15", "No,Yes", None))
    for name, bits, ids, vals in d:
        e = ET.SubElement(sw, "dip", name=name, bits=bits, ids=ids)
        if vals:
            e.set("values", vals)
    return sw


def title_of(setname):
    for ln in (ROOT / "reference" / "mame" / "dooyong.cpp").read_text().splitlines():
        m = re.match(r'GAME\(\s*(\d+),\s*(\w+),[^"]*"([^"]*)",\s*"([^"]*)"', ln)
        if m and m.group(2) == setname:
            return m.group(1), m.group(3), m.group(4)
    raise KeyError(setname)


def make(setname, sets):
    rs = sets[setname]
    parent = rs.parent or setname
    year, maker, title = title_of(setname)
    src = stream_sources(rs)
    rom, _ = rom_element(rs, sets, src)
    root = ET.Element("misterromdescription")
    for tag, val in (("name", title), ("setname", setname), ("rbf", RBF), ("mameversion", "0289"),
                     ("year", year), ("manufacturer", maker), ("players", "2"),
                     ("joystick", "8-way"),
                     ("rotation", "vertical (ccw)" if rs.rot == "ROT270" else "horizontal")):
        ET.SubElement(root, tag).text = val
    root.append(switches(rs.machine, parent))
    if parent == "sadari":              # P1/P2 bit 6 = Button 3 (spec 9.2)
        ET.SubElement(root, "buttons", names="Button 1,Button 2,Start,Coin,Service,Button 3",
                      default="A,B,Start,Select,L,X")
    else:
        ET.SubElement(root, "buttons", names="Button 1,Button 2,Start,Coin,Service",
                      default="A,B,Start,Select,L")
    gid = ET.SubElement(root, "rom", index="1")
    ET.SubElement(gid, "part").text = f"{game_id(setname, sets):02X}"
    root.append(rom)
    ET.indent(root, "    ")
    safe = re.sub(r'[\\/:*?"<>|]', "-", title)
    path = OUTDIR / f"{safe}.mra"
    OUTDIR.mkdir(parents=True, exist_ok=True)
    path.write_text(ET.tostring(root, encoding="unicode") + "\n")
    return path, len(src)


def main(argv):
    sets = parse_driver()
    todo = argv or [s for s, r in sets.items() if r.machine in SUPPORTED]
    bad = 0
    for s in todo:
        path, n = make(s, sets)
        got = assemble(path, ROOT / "roms")
        want = (REGIONS / s / "sdram.bin").read_bytes()[:n]
        ok = got == want
        parts = sum(1 for _ in ET.parse(path).getroot().iter("part"))
        if ok:
            print(f"OK   {s:11s} {path.name}: stream {n:#x} bytes = sdram.bin, {parts} parts")
        else:
            m = min(len(got), len(want))
            first = next((i for i in range(m) if got[i] != want[i]), m)
            print(f"BAD  {s:11s} {path.name}: lengths {len(got):#x}/{len(want):#x}, first diff at {first:#x}")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
