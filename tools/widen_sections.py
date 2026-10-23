"""Widen each PE section's VirtualSize to its SizeOfRawData.

Windows maps a section's whole raw data, so bytes between VirtualSize and
SizeOfRawData are readable at run time. The Unofficial Patch keeps data there
(engine.dll's resolution whitelist at 0x20195dd0, past .rdata's VirtualSize).
SRW only knows the VirtualSize range and mistranslates references into the
slack, so the analysis copy gets the wider size. Sections are never widened
past the next section's start.

    widen_sections.py <file.pe>    (edited in place; prints what changed)
"""
import struct
import sys


def main(path):
    d = bytearray(open(path, "rb").read())
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    first = pe + 24 + opt
    secs = []
    for i in range(nsec):
        s = first + 40 * i
        vsize, va, rsize = struct.unpack_from("<III", d, s + 8)
        secs.append((s, vsize, va, rsize))
    for i, (s, vsize, va, rsize) in enumerate(secs):
        limit = secs[i + 1][2] - va if i + 1 < len(secs) else rsize
        new = min(rsize, limit)
        if new > vsize:
            name = bytes(d[s:s + 8]).rstrip(b"\0").decode()
            print(f"{name}: VirtualSize 0x{vsize:x} -> 0x{new:x}")
            struct.pack_into("<I", d, s + 8, new)
    open(path, "wb").write(d)


if __name__ == "__main__":
    main(sys.argv[1])
