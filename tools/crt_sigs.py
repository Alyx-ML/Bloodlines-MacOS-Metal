#!/usr/bin/env python3
"""Recognise statically linked MSVC C-runtime routines and replace them natively.

Every game DLL carries its own copy of the CRT. Some routines are hand-written
assembly SRW cannot translate (jump tables inside code, results returned in CPU
flags across calls), and all of them are faster as native code.

A signature is a byte range identified by length and the SHA-256 of its bytes after
masking what differs between modules: relocated dwords and rel32 branch targets
outside the range. Only hashes are stored (native/crt/signatures.txt), never code.

  crt_sigs.py add  <pe> <start> <length> <name> <offset>=<replacement>[,...]
  crt_sigs.py scan <pe> <workdir>

`scan` appends to <workdir>/external_procedures.sci (entry -> bl_crt_* routine) and
ignored_areas.sci (the whole range) for every signature found.
"""
import bisect
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile

# Homebrew LLVM's objdump: no xcrun, so it works inside the sandbox too.
OBJDUMP = os.path.join(os.environ.get("LLVM", "/opt/homebrew/opt/llvm/bin"), "llvm-objdump")

SIGFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "crt", "signatures.txt")
LINE_RE = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s*(\S+)?\s*(.*)$")


class Module:
    def __init__(self, path):
        self.data = bytearray(open(path, "rb").read())
        d = self.data
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        opt = pe + 24
        self.base = struct.unpack_from("<I", d, opt + 28)[0]
        nsec = struct.unpack_from("<H", d, pe + 6)[0]
        o = opt + struct.unpack_from("<H", d, pe + 20)[0]
        self.sections = []
        for _ in range(nsec):
            vsize, va, rsize, raw = struct.unpack_from("<IIII", d, o + 8)
            ch = struct.unpack_from("<I", d, o + 36)[0]
            self.sections.append((va, max(vsize, rsize), raw, rsize, ch))
            o += 40
        reloc_rva, reloc_size = struct.unpack_from("<II", d, opt + 96 + 5 * 8)
        self.relocs = set()
        p, end = self.rva2off(reloc_rva), self.rva2off(reloc_rva) + reloc_size
        while p < end:
            page, size = struct.unpack_from("<II", d, p)
            if size < 8:
                break
            for i in range(8, size, 2):
                e = struct.unpack_from("<H", d, p + i)[0]
                if e >> 12 == 3:  # IMAGE_REL_BASED_HIGHLOW
                    self.relocs.add(self.base + page + (e & 0xFFF))
            p += size
        # Linear disassembly of a copy with relocated dwords zeroed, so instruction
        # boundaries do not depend on where the module was linked.
        norm = bytearray(d)
        for a in self.relocs:
            off = self.addr2off(a)
            if off is not None:
                norm[off:off + 4] = b"\0\0\0\0"
        with tempfile.NamedTemporaryFile(suffix=".dll", delete=False) as tmp:
            tmp.write(norm)
        try:
            out = subprocess.run([OBJDUMP, "-d", "--x86-asm-syntax=intel", tmp.name],
                                 capture_output=True, text=True, check=True).stdout
        finally:
            os.unlink(tmp.name)
        self.insns = []
        for line in out.splitlines():
            m = LINE_RE.match(line)
            if m:
                self.insns.append((int(m.group(1), 16), bytes.fromhex(m.group(2)), m.group(3) or "", m.group(4)))
        self.sorted_relocs = sorted(self.relocs)
        self.index_of = {a: i for i, (a, *_) in enumerate(self.insns)}

    def rva2off(self, rva):
        for va, size, raw, rsize, _ in self.sections:
            if va <= rva < va + size and rva - va < rsize:
                return raw + rva - va
        return None

    def addr2off(self, a):
        return self.rva2off(a - self.base)

    def code_ranges(self):
        return [(self.base + va, self.base + va + size) for va, size, _, _, ch in self.sections if ch & 0x20000000]

    def normalized(self, start, length):
        """Range bytes with relocations and outbound rel32 branch targets zeroed, or None."""
        off = self.addr2off(start)
        if off is None or start not in self.index_of:
            return None
        buf = bytearray(self.data[off:off + length])
        if len(buf) != length:
            return None
        lo = bisect.bisect_left(self.sorted_relocs, start)
        for a in self.sorted_relocs[lo:bisect.bisect_left(self.sorted_relocs, start + length)]:
            buf[a - start:a - start + 4] = b"\0\0\0\0"
        i = self.index_of[start]
        while i < len(self.insns) and self.insns[i][0] < start + length:
            a, raw, mn, ops = self.insns[i]
            if mn in ("call", "calll", "jmp", "jmpl") or (mn.startswith("j") and len(raw) >= 5):
                if len(raw) >= 5 and raw[-5] in (0xE8, 0xE9) or (len(raw) >= 6 and raw[-6] == 0x0F and 0x80 <= raw[-5] <= 0x8F):
                    target = (a + len(raw) + struct.unpack_from("<i", raw, len(raw) - 4)[0]) & 0xFFFFFFFF
                    if not start <= target < start + length:
                        p = a + len(raw) - 4 - start
                        buf[max(p, 0):p + 4] = b"\0\0\0\0"
            i += 1
        return bytes(buf)

    def candidates(self):
        """Instruction addresses that may start a function."""
        calls = set()
        for a, raw, mn, ops in self.insns:
            if mn in ("call", "calll") and len(raw) == 5 and raw[0] == 0xE8:
                calls.add((a + 5 + struct.unpack_from("<i", raw, 1)[0]) & 0xFFFFFFFF)
        out = set()
        for i, (a, raw, mn, ops) in enumerate(self.insns):
            prev = self.insns[i - 1][2] if i else ""
            if a in calls or prev in ("ret", "retl", "int3", "nop", "jmp", "jmpl"):
                out.add(a)
        return sorted(out)


def load_sigs():
    sigs = []
    if os.path.exists(SIGFILE):
        for line in open(SIGFILE):
            line = line.split("#")[0].strip()
            if line:
                name, length, digest, entries = line.split()
                sigs.append((name, int(length), digest,
                             [(int(o, 0), r) for o, r in (e.split("=") for e in entries.split(","))]))
    return sigs


def cmd_add(pe, start, length, name, entries):
    m = Module(pe)
    start, length = int(start, 16), int(length, 0)
    buf = m.normalized(start, length)
    if buf is None:
        sys.exit(f"0x{start:x} is not an instruction boundary")
    digest = hashlib.sha256(buf).hexdigest()
    os.makedirs(os.path.dirname(SIGFILE), exist_ok=True)
    with open(SIGFILE, "a") as f:
        f.write(f"{name} {length} {digest} {entries}\n")
    print(f"added {name}: {length} bytes, sha256 {digest[:16]}...")


def cmd_scan(pe, workdir):
    m = Module(pe)
    sigs = load_sigs()
    lengths = {}
    for s in sigs:
        lengths.setdefault(s[1], []).append(s)
    found = []
    for a in m.candidates():
        for length, group in lengths.items():
            buf = m.normalized(a, length)
            if buf is None:
                continue
            digest = hashlib.sha256(buf).hexdigest()
            for name, _, d, entries in group:
                if d == digest:
                    found.append((a, length, name, entries))
    with open(os.path.join(workdir, "external_procedures.sci"), "a") as f:
        for a, length, name, entries in found:
            for o, r in entries:
                f.write(f"loc_{a + o:X},{r}\n")
    with open(os.path.join(workdir, "ignored_areas.sci"), "a") as f:
        for a, length, name, entries in found:
            f.write(f"loc_{a:X},{length}\n")
    print("crt: " + (", ".join(f"{n}@0x{a:x}" for a, _, n, _ in found) if found else "none"))


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "add" and len(sys.argv) == 7:
        cmd_add(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "scan":
        cmd_scan(*sys.argv[2:])
    else:
        sys.exit(__doc__)
