"""Append the data SRW leaves out at the end of a section.

SRW stops a section's data at the import directory when that lies inside the
section (engine.dll's .rdata), so anything after it is missing: the export
directory and, in the Unofficial Patch, data the patch stores in the slack
(engine.dll's resolution whitelist). Code still refers to it as loc_<VA>.
This appends the missing bytes to the segment file, with a dlabel at every
referenced address and daddr at every relocated pointer.

    append_section_tail.py <file.pe> <module build dir>
"""
import glob
import os
import re
import struct
import sys

SIZES = {"db": 1, "dw": 2, "dd": 4, "daddr": 4}


def sections(d):
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    base = struct.unpack_from("<I", d, pe + 52)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    first = pe + 24 + struct.unpack_from("<H", d, pe + 20)[0]
    out = []
    for i in range(nsec):
        vsize, va, rsize, raw = struct.unpack_from("<IIII", d, first + 40 * i + 8)
        out.append((base + va, vsize, rsize, raw))
    reloc_rva, reloc_size = struct.unpack_from("<II", d, pe + 24 + 96 + 8 * 5)
    return base, out, reloc_rva, reloc_size


def va_to_off(secs, va):
    for sva, vsize, rsize, raw in secs:
        if sva <= va < sva + rsize:
            return raw + va - sva
    return None


def relocations(d, base, secs, rva, size):
    out = set()
    off = va_to_off(secs, base + rva)
    end = off + size if off is not None else 0
    while off is not None and off + 8 <= end:
        page, block = struct.unpack_from("<II", d, off)
        if block < 8:
            break
        for i in range((block - 8) // 2):
            e = struct.unpack_from("<H", d, off + 8 + 2 * i)[0]
            if e >> 12 == 3:  # IMAGE_REL_BASED_HIGHLOW
                out.add(base + page + (e & 0xFFF))
        off += block
    return out


def segment_range(path):
    start = addr = None
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "dlabel" and p[1].startswith("loc_"):
            addr = int(p[1][4:], 16)
            if start is None:
                start = addr
        elif p[0] in SIZES and addr is not None:
            addr += SIZES[p[0]]
    return start, addr


def drop_boundary_labels(files):
    """SRW ends a segment with a label at its end address. When a section is widened
    to the next one's start, that label is also the next segment's first: drop the
    trailing copy."""
    firsts = {}
    for f in files:
        for line in open(f):
            if line.startswith(("dlabel loc_", "proc loc_")):
                firsts[line.split()[1]] = f
                break
    for f in (f for f in files if f.endswith("_data.llinc")):
        lines = open(f).read().splitlines()
        while lines and not lines[-1].strip():
            lines.pop()
        if lines and lines[-1].startswith("dlabel loc_") and firsts.get(lines[-1].split()[1], f) != f:
            print(f"{os.path.basename(f)}: dropped boundary {lines[-1]}")
            open(f, "w").write("\n".join(lines[:-1]) + "\n")


def main(pe_path, out):
    d = open(pe_path, "rb").read()
    base, secs, reloc_rva, reloc_size = sections(d)
    relocs = relocations(d, base, secs, reloc_rva, reloc_size)
    files = sorted(glob.glob(os.path.join(out, "seg*.llinc")))
    drop_boundary_labels(files)
    referenced = set()
    for f in files:
        referenced.update(int(m, 16) for m in re.findall(r"\bloc_([0-9A-F]{8})\b", open(f).read()))
    for f in files:
        if not f.endswith("_data.llinc"):
            continue
        start, end = segment_range(f)
        if start is None:
            continue
        sec = next((s for s in secs if s[0] <= start < s[0] + max(s[1], s[2])), None)
        if not sec:
            continue
        sec_end = sec[0] + sec[1]
        if end >= sec_end:
            continue
        lines = []
        a = end
        while a < sec_end:
            if a in referenced and a != end:
                lines.append(f"dlabel loc_{a:08X}")
            off = va_to_off(secs, a)
            if a in relocs and a + 4 <= sec_end:
                target = struct.unpack_from("<I", d, off)[0]
                lines.append(f"daddr loc_{target:08X}")
                a += 4
                continue
            lines.append(f"db {d[off] if off is not None and off < len(d) else 0}")
            a += 1
        with open(f, "a") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"{os.path.basename(f)}: appended 0x{end:08x}-0x{sec_end:08x}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
