#!/usr/bin/env python3
"""Find code addresses SRW emitted as data labels and seed them as code.

Function pointers stored by immediate (`mov [esi+0x20], offset zcalloc`), vtables
and callback tables reach SRW only as relocations. When SRW does not treat the
target as code it emits `dlabel loc_X` inside the .text copy, and an indirect
call to it jumps into data at run time.

A data label inside an executable section is seeded as code when
  * the address is an instruction boundary in a linear disassembly, and
  * it starts a function: preceded by int3/nop padding, ret or jmp
    (or is the first byte of the section).
Seeds are appended to fixup_interpret_as_code.sci in the work directory.

Usage: seed_code_pointers.py <pe> <workdir>
Exit status: 0 no new seeds, 10 new seeds written (re-run SRW), other = error.
"""
import os
import re
import struct
import subprocess
import sys

# Homebrew LLVM's objdump: no xcrun, so it works inside the sandbox too.
OBJDUMP = os.path.join(os.environ.get("LLVM", "/opt/homebrew/opt/llvm/bin"), "llvm-objdump")

LINE_RE = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)")
PADDING = {"int3", "nop"}
ENDS = {"ret", "retl", "jmp", "jmpl"}


def code_sections(pe):
    d = open(pe, "rb").read()
    off = struct.unpack_from("<I", d, 0x3C)[0]
    nsec = struct.unpack_from("<H", d, off + 6)[0]
    optsz = struct.unpack_from("<H", d, off + 20)[0]
    base = struct.unpack_from("<I", d, off + 24 + 28)[0]
    o = off + 24 + optsz
    out = []
    for _ in range(nsec):
        vsize, va = struct.unpack_from("<II", d, o + 8)
        ch = struct.unpack_from("<I", d, o + 36)[0]
        if ch & 0x20000000:  # IMAGE_SCN_MEM_EXECUTE
            out.append((base + va, base + va + vsize))
        o += 40
    return out


def main():
    pe, workdir = sys.argv[1:3]
    sections = code_sections(pe)
    dis = subprocess.run([OBJDUMP, "-d", "--no-show-raw-insn", pe], capture_output=True, text=True, check=True).stdout
    insns = []
    for line in dis.splitlines():
        m = LINE_RE.match(line)
        if m:
            insns.append((int(m.group(1), 16), m.group(2)))
    index_of = {a: i for i, (a, _) in enumerate(insns)}

    labels = set()
    for name in os.listdir(workdir):
        if re.fullmatch(r"seg\d+_data\.llinc", name):
            labels |= {int(x, 16) for x in re.findall(r"^dlabel loc_([0-9A-Fa-f]+)", open(os.path.join(workdir, name)).read(), re.M)}

    sci = os.path.join(workdir, "fixup_interpret_as_code.sci")
    existing = set()
    if os.path.exists(sci):
        existing = {int(x, 16) for x in re.findall(r"loc_([0-9A-Fa-f]+)", open(sci).read())}

    seeds = []
    for a in sorted(labels - existing):
        if not any(lo <= a < hi for lo, hi in sections) or a not in index_of:
            continue
        i = index_of[a]
        prev = insns[i - 1][1] if i else None
        if i == 0 or any(a == lo for lo, _ in sections) or prev in PADDING or prev in ENDS:
            seeds.append(a)

    if not seeds:
        print("code pointer seeds: none new")
        return 0
    with open(sci, "a") as f:
        f.write("".join(f"loc_{a:X}\n" for a in seeds))
    print(f"code pointer seeds: {len(seeds)} new ({', '.join(f'0x{a:x}' for a in seeds[:8])}{' ...' if len(seeds) > 8 else ''})")
    return 10


if __name__ == "__main__":
    sys.exit(main())
