#!/usr/bin/env python3
"""M0.1: check every ROM zip against the expected table generated from
reference/mame/dooyong.cpp (names, sizes, CRC32 and SHA1).

Matching is by CRC over the whole zip that holds the set (MAME merged sets
keep clone-only files under '<clone>/'), so renamed files are reported but
still count as present. BAD_DUMP entries are reported, not failed.

Usage: tools/check_roms.py [set ...]      (default: all 25 sets)
Exit status 0 when every set is complete.
"""
import hashlib
import sys

from romdefs import parse_driver, zip_index, file_size


def check_set(name, sets):
    zpath, files, names = zip_index(name, sets)
    rs = sets[name]
    problems, notes = [], []
    n = 0
    for region in rs.regions:
        for ld in region.loads:
            if ld.kind == "FILL":
                continue
            n += 1
            want = file_size(ld)
            data = files.get(ld.crc)
            if data is None:
                problems.append(f"MISSING {ld.name} crc {ld.crc} (line {ld.line})")
                continue
            if len(data) != want:
                problems.append(f"SIZE {ld.name}: {len(data):#x} != {want:#x}")
            sha = hashlib.sha1(data).hexdigest()
            if ld.sha1 and sha != ld.sha1:
                problems.append(f"SHA1 {ld.name}: {sha} != {ld.sha1}")
            base = [p.split("/")[-1] for p in names[ld.crc]]
            if ld.name not in base:
                notes.append(f"renamed {ld.name} -> {names[ld.crc][0]}")
            if ld.bad_dump:
                notes.append(f"BAD_DUMP (expected) {ld.name}")
    return zpath.name, n, problems, notes


def main(argv):
    sets = parse_driver()
    todo = argv or list(sets)
    bad = 0
    for name in todo:
        zname, n, problems, notes = check_set(name, sets)
        status = "OK " if not problems else "BAD"
        print(f"{status} {name:11s} {n:2d} files in {zname}")
        for p in problems:
            print("     " + p)
        for p in notes:
            print("     note: " + p)
        bad += bool(problems)
    print(f"{len(todo) - bad}/{len(todo)} sets complete")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
