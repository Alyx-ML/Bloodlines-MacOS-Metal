#!/usr/bin/env python3
"""Iterate SRW until it stops failing on flags that are live across a region start.

MSVC reuses flags across jumps, e.g.

    cmp  cx, 0x10
    jae  X          ; X: jne Y   <- jne reads ZF from the cmp above

SRW then stops with "unknown flags on start of region ... (0xX) - 0xF". Two fixes,
tried in order:

1. Flags pair (as in the SRW-games examples): instruction_flags.sci forces the
   producer to write F and clears F at X.
2. Re-compare: when the producer is fused with its own jcc, SRW refuses the pair
   ("mixing flags and instruction flags"). If every path reaches X from the same
   `cmp r32, r32|imm` with the operands untouched, X's jcc is replaced in
   instruction_replacements.sci by an llasm compare + conditional tail call.

Anything else stops the loop with a message; nothing is guessed silently.

Usage: fix_region_flags.py <SRW> <pe> <out.llasm> <workdir>
The workdir receives instruction_flags.sci, instruction_replacements.sci and
global_aliases.sci
(both regenerated on every iteration from this script's state plus any
hand-written *.manual.sci files of the same base name).
"""
import glob
import os
import re
import subprocess
import sys

# Homebrew LLVM's objdump: no xcrun, so it works inside the sandbox too.
OBJDUMP = os.path.join(os.environ.get("LLVM", "/opt/homebrew/opt/llvm/bin"), "llvm-objdump")

REGION_RE = re.compile(r"unknown flags on start of region - \d+ - \d+ \(0x([0-9a-f]+)\) - 0x([0-9a-f]+)")
MIXING_RE = re.compile(r"mixing flags and instruction flags - \d+ - \d+ \(0x([0-9a-f]+)\)")
SPECIAL_RE = re.compile(r"unknown flags - \d+ - \d+ \(0x([0-9a-f]+)\) - (\w+)")
EMPTY_RE = re.compile(r"llasm instruction error - (\d+) - (\d+) - (.*)")
UNKNOWN_ANY_RE = re.compile(r"unknown instruction - (\d+) - (\d+) - ")
UNKNOWN_RE = re.compile(r"unknown instruction - (\d+) - (\d+) - (\w+) loc_([0-9A-F]+)")
LINE_RE = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")

# Instructions that write the arithmetic flags SRW tracks (CF ZF SF OF).
FLAG_WRITERS = {
    "cmp", "test", "add", "sub", "and", "or", "xor", "inc", "dec", "neg", "adc", "sbb",
    "shl", "shr", "sar", "sal", "rol", "ror", "rcl", "rcr", "shld", "shrd", "bt", "bts",
    "btr", "btc", "imul", "mul", "cmpxchg", "bsf", "bsr", "scasb", "scasd", "scasw",
    "cmpsb", "cmpsd", "cmpsw", "sahf", "popfd", "popf", "comiss", "ucomiss",
    "comisd", "ucomisd", "fcomi", "fcomip", "fucomi", "fucomip", "stc", "clc", "cmc",
}
NO_FALLTHROUGH = {"jmp", "ret", "retn", "int3", "ud2"}
WALK_STOP = {"call", "ret", "jmp", "retn"}
REG32 = {"eax", "ebx", "ecx", "edx", "esi", "edi", "ebp"}
# Instructions SRW cannot translate, replaced by a call to a runtime helper
# taking the CPU state (runtime/bl_special.c, declared in runtime/llasm/bl_special.llinc).
# None: x87 exception-state instructions with no effect here (exceptions stay masked).
SPECIAL = {"cpuid": "bl_cpuid", "rdtsc": "bl_rdtsc", "fclex": None, "fnclex": None, "fwait": None, "wait": None,
           "ffree": None}  # ffree: register tags are not tracked
# Branches on ecx SRW lacks: llasm setting tmp0 to "take the branch". loop does not
# change flags, and neither does llasm arithmetic.
ECX_BRANCH = {"jecxz": "cmovz ecx, tmp0, 1, 0", "loop": "sub ecx, ecx, 1|mov tmp0, ecx"}
# x87 instructions SRW lacks: runtime/bl_special.c.
SPECIAL.update({m: f"bl_x87_{m}" for m in ("fsincos", "fldl2e", "fldl2t", "fldpi", "f2xm1", "fscale", "frndint", "fxtract",
                                          "fprem", "fprem1", "fpatan", "fxam", "ftst", "fincstp", "fdecstp")})
# Flags (SRW FL_* bits) each jcc reads.
JCC_FLAGS = {
    "je": 0x08, "jz": 0x08, "jne": 0x08, "jnz": 0x08,
    "jl": 0x30, "jnge": 0x30, "jge": 0x30, "jnl": 0x30,
    "jg": 0x38, "jnle": 0x38, "jle": 0x38, "jng": 0x38,
    "jb": 0x01, "jc": 0x01, "jnae": 0x01, "jae": 0x01, "jnb": 0x01, "jnc": 0x01,
    "ja": 0x09, "jnbe": 0x09, "jbe": 0x09, "jna": 0x09,
    "js": 0x10, "jns": 0x10,
}
# jcc -> (llasm compare, value when condition holds, value otherwise); args are (a, b).
JCC = {
    "je": ("cmoveq", 1, 0), "jz": ("cmoveq", 1, 0),
    "jne": ("cmoveq", 0, 1), "jnz": ("cmoveq", 0, 1),
    "jl": ("cmovslt", 1, 0), "jnge": ("cmovslt", 1, 0),
    "jge": ("cmovslt", 0, 1), "jnl": ("cmovslt", 0, 1),
    "jg": ("cmovsgt", 1, 0), "jnle": ("cmovsgt", 1, 0),
    "jle": ("cmovsgt", 0, 1), "jng": ("cmovsgt", 0, 1),
    "jb": ("cmovult", 1, 0), "jc": ("cmovult", 1, 0), "jnae": ("cmovult", 1, 0),
    "jae": ("cmovult", 0, 1), "jnb": ("cmovult", 0, 1), "jnc": ("cmovult", 0, 1),
    "ja": ("cmovugt", 1, 0), "jnbe": ("cmovugt", 1, 0),
    "jbe": ("cmovugt", 0, 1), "jna": ("cmovugt", 0, 1),
}


def disassemble(pe):
    out = subprocess.run([OBJDUMP, "-d", "--no-show-raw-insn", "--x86-asm-syntax=intel", pe],
                         capture_output=True, text=True, check=True).stdout
    insns = []
    for line in out.splitlines():
        m = LINE_RE.match(line)
        if m:
            insns.append((int(m.group(1), 16), m.group(2), m.group(3).split("#")[0].strip()))
    return insns


REG32 = {"eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp"}


def address_llasm(ops):
    """llasm lines putting the address of a [base + index*scale +/- disp] operand in
    tmp0, or None. An absolute address (relocated, so it names a data label SRW
    emits for the relocation target) becomes loc_<address>."""
    m = re.search(r"\[([^\]]+)\]", ops)
    if not m or ":" in ops.split("[")[0]:
        return None
    base = index = None
    scale = disp = 0
    for sign, term in re.findall(r"([+-]?)\s*([^+-]+)", m.group(1).replace(" ", "")):
        neg = sign == "-"
        if term in REG32 and not neg and base is None:
            base = term
        elif re.fullmatch(r"(\d)\*(e\w\w)", term) and not neg:
            scale, index = int(term[0]), term[2:]
        elif re.fullmatch(r"(e\w\w)\*(\d)", term) and not neg:
            index, scale = term[:3], int(term[-1])
        elif re.fullmatch(r"0x[0-9a-f]+|\d+", term):
            disp += -int(term, 0) if neg else int(term, 0)
        else:
            return None
    if base is None:
        if not 0x10000 <= disp <= 0xFFFFFFFF:
            return None
        base, disp = f"loc_{disp:X}", 0
    lines = [f"mov tmp0, {base}"]
    if index:
        lines += [f"shl tmp1, {index}, {scale.bit_length() - 1}", "add tmp0, tmp0, tmp1"]
    if disp:
        lines.append(f"{'sub' if disp < 0 else 'add'} tmp0, tmp0, {abs(disp):#x}")
    return lines


# 80-bit x87 memory operands, which SRW does not translate: runtime/bl_special.c.
X87_TBYTE = {"fld": "bl_x87_fld80", "fstp": "bl_x87_fstp80"}
# x87 environment instructions with a memory operand: runtime/bl_special.c.
X87_ENV = {"fldenv": "bl_x87_fldenv", "fnstenv": "bl_x87_fnstenv", "fstenv": "bl_x87_fnstenv",
           "fnsave": "bl_x87_fnsave", "fsave": "bl_x87_fnsave", "frstor": "bl_x87_frstor"}


BIT_OPS = {"bt", "bts", "btr", "btc"}
CF_JCC = {"jb": "ctcallnz", "jc": "ctcallnz", "jnae": "ctcallnz", "jae": "ctcallz", "jnb": "ctcallz", "jnc": "ctcallz"}
BT_CF_WRITERS = {"cmp", "test", "or", "and", "xor", "add", "sub"}


def bit_test(insns, index_of, i):
    """Replacement for bt/bts/btr/btc dword ptr [mem], r32|imm, which SRW does not
    translate: (sci line, jcc target or None) or (None, reason). A CF jcc right after
    is folded in as a conditional tail call; otherwise CF must be dead."""
    addr, mn, ops = insns[i]
    m = re.fullmatch(r"dword ptr (\[[^\]]+\]), (e\w\w|0x[0-9a-f]+|\d+)", ops)
    lines = address_llasm(m.group(1)) if m else None
    if lines is None:
        return None, f"operands {ops}"
    bit = m.group(2)
    if bit in REG32:
        lines += [f"ashr tmp1, {bit}, 5", "shl tmp1, tmp1, 2", "add tmp0, tmp0, tmp1", f"and tmp2, {bit}, 31",
                  "mov tmp3, 1", "shl tmp3, tmp3, tmp2"]
    else:
        lines += [f"mov tmp3, {1 << (int(bit, 0) & 31):#x}"]
    lines.append("load tmp4, tmp0, 4")
    if mn == "bts":
        lines += ["or tmp5, tmp4, tmp3", "store tmp5, tmp0, 4"]
    elif mn == "btr":
        lines += ["xor tmp5, tmp3, 0xffffffff", "and tmp5, tmp4, tmp5", "store tmp5, tmp0, 4"]
    elif mn == "btc":
        lines += ["xor tmp5, tmp4, tmp3", "store tmp5, tmp0, 4"]
    nxt = insns[i + 1]
    if nxt[1] in CF_JCC:
        target = jump_target(nxt[2])
        after = f"loc_{addr:X}_after"
        lines += ["and tmp6, tmp4, tmp3", f"{CF_JCC[nxt[1]]} tmp6, recmp_{target:X}", f"tcall {after}", "endp",
                  f"proc {after}"]
        length = insns[i + 2][0] - addr
        return f"loc_{addr:X},{length},;{mn} {ops}; {nxt[1]} loc_{target:X}|" + "|".join(lines) + " ; auto: bit test", target
    # CF unused: the next flag access, following jmps, must be a flag writer.
    j = i + 1
    for _ in range(16):
        jm, jo = insns[j][1], insns[j][2]
        if jm in ("jmp", "jmpl") and jump_target(jo) in index_of:
            j = index_of[jump_target(jo)]
        elif jm in ("mov", "movzx", "lea", "push", "pop"):
            j += 1
        elif jm in BT_CF_WRITERS:
            length = insns[i + 1][0] - addr
            return f"loc_{addr:X},{length},;{mn} {ops}|" + "|".join(lines) + " ; auto: bit test", None
        else:
            break
    return None, f"CF may be read at 0x{insns[j][0]:x} ({insns[j][1]})"


SIMD_REG = re.compile(r"\b(?:x?mm\d)\b")
SIMD_MNEMONICS = {"femms", "emms", "prefetch", "prefetchw", "prefetchnta", "prefetcht0", "prefetcht1", "prefetcht2",
                  "sfence", "lfence", "mfence", "ldmxcsr", "stmxcsr", "fxsave", "fxrstor"}


SIMD_FLAG_WRITERS = {"comiss", "ucomiss", "comisd", "ucomisd", "ptest"}


# MMX instructions emulated by bl_mmx (runtime/bl_special.c), in the order of its op
# enum: some game code uses MMX without asking cpuid (the engine's sound mixer).
MMX_OPS = ["movq", "movd", "packssdw", "packsswb", "packuswb", "punpcklbw", "punpcklwd", "punpckldq",
           "punpckhbw", "punpckhwd", "punpckhdq", "paddb", "paddw", "paddd", "paddsb", "paddsw",
           "paddusb", "paddusw", "psubb", "psubw", "psubd", "psubsb", "psubsw", "psubusb", "psubusw",
           "pmullw", "pmulhw", "pmaddwd", "pand", "pandn", "por", "pxor", "pcmpeqb", "pcmpeqw",
           "pcmpeqd", "pcmpgtb", "pcmpgtw", "pcmpgtd", "psllw", "pslld", "psllq", "psrlw", "psrld",
           "psrlq", "psraw", "psrad", "emms"]
GPR_ORDER = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]


def mmx_llasm(mn, ops):
    """llasm lines emulating one MMX instruction with bl_mmx, or None."""
    if mn not in MMX_OPS or "xmm" in ops:
        return None
    if mn == "emms":
        return [f"call bl_mmx $, {MMX_OPS.index(mn)}, 0, 0"]
    parts = [p.strip() for p in ops.split(",")]
    if len(parts) != 2:
        return None
    lines, arg, codes = [], "0", []
    for p in parts:
        if re.fullmatch(r"mm[0-7]", p):
            codes.append(int(p[2]))
        elif p in GPR_ORDER:
            codes.append(1 << 4 | GPR_ORDER.index(p))
        elif "[" in p:
            if lines or (addr := address_llasm(p)) is None:
                return None
            lines, arg = addr, "tmp0"
            codes.append(2 << 4)
        elif re.fullmatch(r"0x[0-9a-f]+|\d+", p):
            codes.append(3 << 4)
            arg = p
        else:
            return None
    return lines + [f"call bl_mmx $, {MMX_OPS.index(mn)}, {codes[0] | codes[1] << 8:#x}, {arg}"]


def is_simd(insn):
    """MMX, 3DNow! or SSE: only reached when cpuid reports the feature, which bl_cpuid
    never does."""
    _, mn, ops = insn
    return mn in SIMD_MNEMONICS or mn.startswith("pf") or bool(SIMD_REG.search(ops))


PADDING = re.compile(r"(nop|int3)\b.*|lea (e\w\w), \[\2\]|mov edi, edi")


def is_padding(insn):
    return bool(PADDING.fullmatch(f"{insn[1]} {insn[2]}".strip()))


def function_bounds(insns, index_of, calls, i, jumps):
    """[start, end) of the function around insns[i]. A function starts at a call
    target or after padding that follows a ret/jmp; the range then grows until no
    conditional jump (or short jmp) crosses its edges, so loop-alignment padding
    inside a function does not split it."""
    def boundary(k):
        if k == 0 or insns[k][0] in calls:
            return True
        if is_padding(insns[k]):
            return False
        p = k - 1
        while p > 0 and is_padding(insns[p]):
            p -= 1
        return insns[p][1] in ("ret", "retl", "jmp", "jmpl") and (p != k - 1 or insns[k][0] % 16 == 0)

    def start_of(k):
        while k > 0 and not boundary(k):
            k -= 1
        return k

    def end_of(k):
        k += 1
        while k < len(insns) and not boundary(k):
            k += 1
        return k

    s, e = start_of(i), end_of(i)
    for _ in range(64):
        lo, hi = insns[s][0], insns[e][0] if e < len(insns) else insns[-1][0] + 1
        grown = False
        for src, t, conditional in jumps:
            a = insns[src][0]
            if not conditional and (t in calls or abs(t - a) > 0x1000):
                continue  # tail call
            if lo <= a < hi and not lo <= t < hi:
                k = index_of[t]
                s, e = min(s, start_of(k)), max(e, end_of(k))
                grown = True
            elif lo < t < hi and not lo <= a < hi:
                s, e = min(s, start_of(src)), max(e, end_of(src))
                grown = True
            if grown:
                break
        if not grown:
            break
    end = insns[e][0] if e < len(insns) else insns[-1][0] + 1
    return insns[s][0], end


def reached_in(insns, index_of, calls, jumps, at, start, end):
    """Indices in [start, end) that SRW is known to decode: forward closure from `at`,
    call targets and targets of jumps from outside the range. A replacement makes SRW
    emit its instruction even when nothing reaches it, outside any proc, so traps are
    only placed on these; a later SRW error picks up anything missed."""
    targets = {}
    # An instruction that nothing jumps or calls to is only reached by falling through,
    # so the straight-line code before `at` was decoded too.
    landing = {t for _, t, _ in jumps} | calls
    k = index_of[at]
    while k > 0 and start <= insns[k - 1][0] and insns[k][0] not in landing \
            and insns[k - 1][1] not in ("ret", "retl", "jmp", "jmpl") and not is_padding(insns[k - 1]):
        k -= 1
    seeds = [index_of[at], k]
    for src, t, _ in jumps:
        if start <= t < end:
            if start <= insns[src][0] < end:
                targets.setdefault(src, []).append(index_of[t])
            else:
                seeds.append(index_of[t])
    seeds += [index_of[a] for a in calls if start <= a < end and a in index_of]
    seen = set()
    while seeds:
        k = seeds.pop()
        while k not in seen and k < len(insns) and start <= insns[k][0] < end:
            seen.add(k)
            seeds += targets.get(k, [])
            if insns[k][1] in ("ret", "retl", "jmp", "jmpl"):
                break
            k += 1
    return seen


def same_reg(ops):
    a = [x.strip() for x in ops.split(",")]
    return len(a) == 2 and a[0] == a[1] and a[0] in REG32


R8L = {"al": "eax", "cl": "ecx", "dl": "edx", "bl": "ebx"}
R8H = {"ah": "eax", "ch": "ecx", "dh": "edx", "bh": "ebx"}
R16 = {"ax": "eax", "cx": "ecx", "dx": "edx", "bx": "ebx", "sp": "esp", "bp": "ebp", "si": "esi", "di": "edi"}
FLAG_READERS = {"adc", "sbb", "rcl", "rcr", "pushfd", "pushf", "lahf", "into"}
FULL_FLAG_WRITERS = {"cmp", "test", "add", "sub", "and", "or", "xor", "neg", "sahf", "popfd", "popf"}


SIMD_TRAPS = set()  # addresses replaced by bl_simd_trap


def flags_dead(insns, index_of, j):
    """True if no instruction reads the arithmetic flags before they are overwritten,
    starting at insns[j] and following jmps. Calls end the search: SRW assumes a call
    clobbers the flags, so code after it cannot read flags from before it."""
    for _ in range(64):
        if j >= len(insns):
            return False
        mn, ops = insns[j][1], insns[j][2]
        if mn in ("jmp", "jmpl"):
            t = jump_target(ops)
            if t not in index_of:
                return False
            j = index_of[t]
            continue
        if mn in ("ret", "retl", "call", "calll") or mn in FULL_FLAG_WRITERS or insns[j][0] in SIMD_TRAPS:
            return True
        if mn.startswith(("j", "set", "cmov")) or mn in FLAG_READERS:
            return False
        j += 1
    return False


def operand_llasm(op, dst):
    """(llasm lines, value, width) loading an x86 operand zero-extended: value is a
    register, `dst` or a constant. Memory operands use tmp0/tmp1 for the address."""
    op = op.strip()
    if op in REG32:
        return [], op, 32
    if op in R16:
        return [f"and {dst}, {R16[op]}, 0xffff"], dst, 16
    if op in R8L:
        return [f"and {dst}, {R8L[op]}, 0xff"], dst, 8
    if op in R8H:
        return [f"lshr {dst}, {R8H[op]}, 8", f"and {dst}, {dst}, 0xff"], dst, 8
    if re.fullmatch(r"-?(0x[0-9a-f]+|\d+)", op):
        return [], int(op, 0), None
    m = re.match(r"(byte|word|dword) ptr ", op)
    lines = address_llasm(op) if m else None
    if lines is None:
        return None, None, None
    width = {"byte": 8, "word": 16, "dword": 32}[m.group(1)]
    load = {8: "load8z", 16: "load16z", 32: "load"}[width]
    return lines + [f"{load} {dst}, tmp0, {width // 8}"], dst, width


def write_r8(reg, val):
    """llasm writing the low byte of `val` (a tmp register) to an 8-bit register."""
    if reg in R8L:
        return [f"and {val}, {val}, 0xff", f"and {R8L[reg]}, {R8L[reg]}, 0xffffff00", f"or {R8L[reg]}, {R8L[reg]}, {val}"]
    return [f"and {val}, {val}, 0xff", f"shl {val}, {val}, 8", f"and {R8H[reg]}, {R8H[reg]}, 0xffff00ff",
            f"or {R8H[reg]}, {R8H[reg]}, {val}"]


BYTE_ALU = {"and", "or", "xor", "add", "sub"}
BYTE_SHIFTS = {"shl", "shr", "sar", "rol", "ror"}


def byte_op(insn):
    """llasm for an 8-bit xchg or ALU op SRW cannot translate (high-byte registers),
    ignoring flags, or None."""
    _, mn, ops = insn
    parts = [x.strip() for x in ops.split(",")]
    if mn in BYTE_SHIFTS and parts[0] in R8L | R8H.keys() and (len(parts) == 1 or re.fullmatch(r"\d+|0x[0-9a-f]+", parts[1])):
        n = (int(parts[1], 0) if len(parts) == 2 else 1) & 7
        lines, v, _ = operand_llasm(parts[0], "tmp2")
        if mn == "sar":
            lines += ["ext8s tmp2, tmp2", f"ashr tmp4, tmp2, {n}"]
        elif mn == "shr":
            lines += [f"lshr tmp4, tmp2, {n}"]
        elif mn == "shl":
            lines += [f"shl tmp4, tmp2, {n}"]
        else:  # rotates
            left = n if mn == "rol" else (8 - n) & 7
            lines += [f"shl tmp4, tmp2, {left}", f"lshr tmp3, tmp2, {(8 - left) & 7 or 8}", "or tmp4, tmp4, tmp3"]
        return lines + write_r8(parts[0], "tmp4")
    if mn == "not" and len(parts) == 1 and parts[0] in R8L | R8H.keys():
        lines, v, _ = operand_llasm(parts[0], "tmp2")
        return lines + [f"xor tmp4, {v}, 0xff"] + write_r8(parts[0], "tmp4")
    if mn in ("mul", "imul") and len(parts) == 1:  # ax = al * r/m8
        lines, v, w = operand_llasm(parts[0], "tmp2")
        if lines is None or w != 8:
            return None
        ext = "ext8s" if mn == "imul" else "and"
        tail = "" if mn == "imul" else ", 0xff"
        return lines + [f"{ext} tmp4, {v}{tail}", f"{ext} tmp3, eax{tail}", "mul tmp4, tmp4, tmp3",
                        "and tmp4, tmp4, 0xffff", "and eax, eax, 0xffff0000", "or eax, eax, tmp4"]
    if len(parts) != 2 or (mn != "xchg" and mn not in BYTE_ALU):
        return None
    a, b = parts
    la, va, wa = operand_llasm(a, "tmp2")
    lb, vb, wb = operand_llasm(b, "tmp3")
    if la is None or lb is None or 8 not in (wa, wb) or (wa or 8) != 8 or (wb or 8) != 8:
        return None
    if a.startswith("byte ptr") and b.startswith("byte ptr"):
        return None
    if mn == "xchg":
        if a not in R8L and a not in R8H or b not in R8L and b not in R8H:
            return None
        return la + lb + write_r8(a, "tmp3") + write_r8(b, "tmp2")
    vb = f"{vb & 0xff:#x}" if isinstance(vb, int) else vb
    lines = la + lb + [f"{mn} tmp4, {va}, {vb}"]
    if a.startswith("byte ptr"):
        return lines + ["store8 tmp4, tmp0, 1"]
    if a in R8L or a in R8H:
        return lines + write_r8(a, "tmp4")
    return None


SIGNED_JCC = {"jl", "jnge", "jge", "jnl", "jg", "jnle", "jle", "jng", "js", "jns"}


def fused_compare(insns, index_of, i):
    """Replacement for `cmp|test a, b` + jcc when SRW cannot translate the compare
    (8/16-bit or high-byte operands): (sci line, jcc target) or (None, reason)."""
    addr, mn, ops = insns[i]
    jaddr, jmn, jops = insns[i + 1]
    if jmn not in JCC and jmn not in ("js", "jns"):
        return None, f"followed by {jmn}"
    if mn == "cmp" and jmn in ("js", "jns"):
        return None, "sign flag of a subtraction"
    parts = [x.strip() for x in ops.split(",")]
    la, va, wa = operand_llasm(parts[0], "tmp2")
    if la is None:
        return None, f"operand {parts[0]}"
    lb, vb, wb = operand_llasm(parts[1], "tmp3")
    if lb is None:
        return None, f"operand {parts[1]}"
    width = wa or wb
    if lb and la and (address_llasm(parts[0]) and address_llasm(parts[1])):
        return None, "two memory operands"
    lines = la + lb
    mask = (1 << width) - 1
    if isinstance(vb, int):
        vb &= mask
    if mn == "test":
        lines.append(f"and tmp4, {va}, {vb:#x}" if isinstance(vb, int) else f"and tmp4, {va}, {vb}")
        va, vb = "tmp4", 0
    elif mn != "cmp":
        return None, f"{mn} is not a compare"
    if jmn in SIGNED_JCC and width < 32:
        ext = "ext8s" if width == 8 else "ext16s"
        if not va.startswith("tmp"):
            return None, "signed compare of a register"
        lines.append(f"{ext} {va}, {va}")
        if isinstance(vb, int):
            vb = vb - (1 << width) if vb >> (width - 1) else vb
            vb &= 0xFFFFFFFF
        else:
            lines.append(f"{ext} {vb}, {vb}")
    op, t, f = JCC.get(jmn) or {"js": ("cmovslt", 1, 0), "jns": ("cmovslt", 0, 1)}[jmn]
    target = jump_target(jops)
    after = f"loc_{addr:X}_after"
    vb = f"{vb:#x}" if isinstance(vb, int) else vb
    lines += [f"{op} {va}, {vb}, tmp5, {t}, {f}", f"ctcallnz tmp5, recmp_{target:X}", f"tcall {after}", "endp",
              f"proc {after}"]
    length = insns[i + 2][0] - addr
    return f"loc_{addr:X},{length},;{mn} {ops}; {jmn} loc_{target:X}|" + "|".join(lines) + " ; auto: fused compare", target


# MSVC CRT math helpers (_fload and friends) that return ZF to the caller:
# ZF = ((high dword of the double argument) & 0x7ff00000) == 0x7ff00000 (NaN/Inf),
# and leave edx alone. First instruction -> the operand as seen by the caller after
# the call returns.
CRT_ZF_HELPERS = {"mov eax, dword ptr [edx + 0x4]": "dword ptr [edx + 0x4]",
                  "mov eax, dword ptr [esp + 0x8]": "dword ptr [esp + 0x4]"}


def passthrough_llasm(insn):
    """llasm for the few flag-neutral instructions found between a CRT helper call
    and the jcc reading its ZF, or None."""
    _, mn, ops = insn
    if mn in ("push", "pushl") and ops in REG32:
        return [f"PUSH {ops}"]
    if mn in ("wait", "fwait"):
        return []
    if mn == "fnstcw" and ops == "word ptr [esp]":
        return ["FNSTCW_VOID", "store16 tmp0, esp, 1"]
    m = re.fullmatch(r"mov (e\w\w), (.+)", f"{mn} {ops}")
    if m and m.group(1) in REG32:
        src = m.group(2)
        if src in REG32 or re.fullmatch(r"-?(0x[0-9a-f]+|\d+)", src):
            return [f"mov {m.group(1)}, {int(src, 0) & 0xFFFFFFFF:#x}" if src[-1].isdigit() else f"mov {m.group(1)}, {src}"]
        if src.startswith("dword ptr ") and (lines := address_llasm(src)) is not None:
            return lines + [f"load {m.group(1)}, tmp0, 4"]
    return None


def crt_zf_jcc(insns, index_of, targets, addr):
    """Replacement for the code right after a call to a CRT helper that returns ZF,
    up to and including the je/jne reading it: (sci line, target) or (None, reason)."""
    i = index_of[addr]
    call = insns[i - 1]
    if call[1] not in ("call", "calll"):
        return None, "not after a call"
    t = jump_target(call[2])
    if t not in index_of:
        return None, "indirect call"
    k = index_of[t]
    head = [f"{m} {o}".strip() for _, m, o in insns[k:k + 3]]
    if head[0] not in CRT_ZF_HELPERS or head[1:] != ["and eax, 0x7ff00000", "cmp eax, 0x7ff00000"]:
        return None, f"callee 0x{t:x} is not a known flag-returning helper"
    # The passthrough instructions run first (llasm temporaries do not survive their
    # macro calls); the operand is then read with esp adjusted for their pushes.
    operand = CRT_ZF_HELPERS[head[0]]
    # When the caller set edx with `lea edx, [esp + N]`, read the operand through esp:
    # the code after the call can also be entered directly, with edx unset (_CIacos
    # is called after _fload's esp-based twin, and shares the tail of the edx path).
    prev = insns[i - 2] if i >= 2 else None
    m = prev and re.fullmatch(r"edx, \[esp \+ (0x[0-9a-f]+)\]", prev[2]) if prev and prev[1] == "lea" else None
    if m and operand == "dword ptr [edx + 0x4]":
        operand = f"dword ptr [esp + {int(m.group(1), 16) + 4:#x}]"
    base = re.search(r"\[(e\w\w)", operand).group(1)
    lines, pushed = [], 0
    j = i
    while insns[j][1] not in ("je", "jz", "jne", "jnz"):
        middle = passthrough_llasm(insns[j])
        if middle is None or (j > i and insns[j][0] in targets):
            return None, f"0x{insns[j][0]:x} {insns[j][1]} {insns[j][2]} before the jcc"
        if insns[j][1] == "mov" and insns[j][2].split(",")[0].strip() == base:
            return None, f"0x{insns[j][0]:x} overwrites {base}"
        pushed += 4 if insns[j][1] in ("push", "pushl") else 0
        lines += middle
        j += 1
    if j > i and insns[j][0] in targets:
        return None, "jcc is a jump target"
    if base == "esp" and pushed:
        disp = int(re.search(r"\+ (0x[0-9a-f]+)", operand).group(1), 16) + pushed
        operand = f"dword ptr [esp + {disp:#x}]"
    lines += address_llasm(operand) + ["load tmp7, tmp0, 4", "and tmp7, tmp7, 0x7ff00000"]
    jmn, jops = insns[j][1], insns[j][2]
    eq = jmn in ("je", "jz")
    target = jump_target(jops)
    after = f"loc_{addr:X}_after"
    lines += [f"cmoveq tmp7, 0x7ff00000, tmp8, {int(eq)}, {int(not eq)}",
              f"ctcallnz tmp8, recmp_{target:X}", f"tcall {after}", "endp", f"proc {after}"]
    length = insns[j + 1][0] - addr
    return f"loc_{addr:X},{length},;{jmn} loc_{target:X} (ZF from CRT helper 0x{t:X})|" + "|".join(lines) + " ; auto: CRT flag return", target


def jump_target(ops):
    m = re.match(r"0x([0-9a-f]+)", ops)
    return int(m.group(1), 16) if m else None


def find_producer(insns, idx, targets):
    """Index of the nearest flag writer before insns[idx], or None if ambiguous."""
    i = idx - 1
    while i >= 0:
        addr, mn, ops = insns[i]
        if mn in FLAG_WRITERS:
            return i
        if mn in WALK_STOP:
            return None
        if addr in targets and i != idx - 1:
            return None
        i -= 1
    return None


def predecessors(insns, index_of, target):
    preds = [i for i, (_, mn, ops) in enumerate(insns) if mn.startswith("j") and jump_target(ops) == target]
    # Fall-through only counts if the previous real instruction can fall through;
    # nop/int3 padding after a ret or jmp is not a path.
    j = index_of[target]
    k = j - 1
    while k >= 0 and insns[k][1] in ("nop", "int3"):
        k -= 1
    if k >= 0 and insns[k][1] not in NO_FALLTHROUGH and insns[k][1] not in ("retl", "jmpl"):
        preds.append(j)
    return preds


def compare_operands(mn, ops):
    """(a, b) such that the flags of `mn ops` equal those of `cmp a, b`, or None."""
    a, b = [x.strip() for x in ops.split(",")]
    if mn == "cmp":
        return a, b
    if mn == "test" and a == b:  # test r, r == cmp r, 0 for CF ZF SF OF
        return a, "0"
    return None


def recompare(insns, index_of, addr, paths):
    """(llasm replacement for the flag reader at addr, jump target or None) or (None, reason)."""
    _, jmn, jops = insns[index_of[addr]]
    sbb = jmn == "sbb" and len({x.strip() for x in jops.split(",")}) == 1
    if jmn not in JCC and not sbb:
        return None, f"region start is {jmn} {jops}, not a jcc or sbb r, r"
    producers = {compare_operands(*insns[p][1:]) for p, _ in paths}
    if len(producers) != 1 or None in producers:
        return None, f"producers not one cmp/test r, r: {[insns[p][1:] for p, _ in paths]}"
    a, b = producers.pop()
    pops = f"{a}, {b}"
    if a not in REG32 or not (b in REG32 or re.fullmatch(r"-?(0x[0-9a-f]+|\d+)", b)):
        return None, f"operands {pops} not r32, r32|imm"
    for p, start in paths:
        for i in range(p + 1, start):
            mn, ops = insns[i][1:]
            dst = ops.split(",")[0].strip()
            if not mn.startswith("j") and dst in (a, b):
                return None, f"{a}/{b} written at 0x{insns[i][0]:x}"
    length = insns[index_of[addr] + 1][0] - addr
    if sbb:  # sbb r, r after cmp a, b: r = (a <u b) ? -1 : 0
        r = jops.split(",")[0].strip()
        text = f";sbb {r}, {r} (re-compare {pops})|cmovult {a}, {b}, {r}, 0xffffffff, 0"
        return f"loc_{addr:X},{length},{text} ; auto: flags live at region start", None
    op, t, f = JCC[jmn]
    target = jump_target(jops)
    after = f"loc_{addr:X}_after"
    text = (f";{jmn} loc_{target:X} (re-compare {pops})|{op} {a}, {b}, tmp0, {t}, {f}|"
            f"ctcallnz tmp0, recmp_{target:X}|tcall {after}|endp|proc {after}")
    return f"loc_{addr:X},{length},{text} ; auto: flags live at region start", target


def section_starts(pe):
    """Addresses of the PE's sections, indexed like SRW's section entries."""
    import struct
    d = open(pe, "rb").read()
    off = struct.unpack_from("<I", d, 0x3C)[0]
    base = struct.unpack_from("<I", d, off + 24 + 28)[0]
    sec = off + 24 + struct.unpack_from("<H", d, off + 20)[0]
    count = struct.unpack_from("<H", d, off + 6)[0]
    return [base + struct.unpack_from("<I", d, sec + 40 * k + 12)[0] for k in range(count)]


def orphan_traps(workdir):
    """Addresses of bl_simd_trap calls that SRW emitted outside any procedure."""
    out, in_proc = set(), False
    for path in glob.glob(os.path.join(workdir, "seg*_code.llinc")):
        for line in open(path):
            if line.startswith("proc "):
                in_proc = True
            elif line.startswith("endp"):
                in_proc = False
            elif not in_proc and line.startswith("call bl_simd_trap $, "):
                out.add(int(line.split(",")[1].split()[0], 16))
    return out


def known_entries(pe, workdir):
    """Code entries SRW is given besides jumps and calls: exports and the code
    pointers seeded into the work directory's .sci files."""
    import struct
    d = open(pe, "rb").read()
    off = struct.unpack_from("<I", d, 0x3C)[0]
    base = struct.unpack_from("<I", d, off + 24 + 28)[0]
    out = set()
    exp_rva = struct.unpack_from("<I", d, off + 24 + 96)[0]
    if exp_rva:
        sec = off + 24 + struct.unpack_from("<H", d, off + 20)[0]
        def rva2off(rva):
            for k in range(struct.unpack_from("<H", d, off + 6)[0]):
                vsize, va, rsize, raw = struct.unpack_from("<IIII", d, sec + 40 * k + 8)
                if va <= rva < va + max(vsize, rsize):
                    return raw + rva - va
            return None
        e = rva2off(exp_rva)
        if e is not None:
            n, funcs = struct.unpack_from("<I", d, e + 20)[0], rva2off(struct.unpack_from("<I", d, e + 28)[0])
            if funcs is not None:
                out |= {base + struct.unpack_from("<I", d, funcs + 4 * i)[0] for i in range(n)}
    for name in ("fixup_interpret_as_code.sci", "global_aliases.manual.sci", "global_aliases.sci"):
        path = os.path.join(workdir, name)
        if os.path.exists(path):
            out |= {int(x, 16) for x in re.findall(r"^loc_([0-9A-Fa-f]+)", open(path).read(), re.M)}
    return out


def pe_bytes(pe, addr, n):
    """n bytes of the PE image at a virtual address."""
    import struct
    d = open(pe, "rb").read()
    off = struct.unpack_from("<I", d, 0x3C)[0]
    base = struct.unpack_from("<I", d, off + 24 + 28)[0]
    sec = off + 24 + struct.unpack_from("<H", d, off + 20)[0]
    for k in range(struct.unpack_from("<H", d, off + 6)[0]):
        vsize, va, rsize, raw = struct.unpack_from("<IIII", d, sec + 40 * k + 8)
        if base + va <= addr < base + va + max(vsize, rsize):
            return d[raw + addr - base - va:raw + addr - base - va + n]
    return b""


FIXED = object()
UNRECOGNIZED = object()
ADDR_RE = re.compile(r" - \d+ - \d+ \(0x([0-9a-f]+)\)")
ENTRY_OFFSET_RE = re.compile(r"(?:llasm instruction error|unknown instruction) - (\d+) - (\d+) - ")


def error_address(err, starts):
    """Guest address an SRW error line refers to, or None."""
    if m := ADDR_RE.search(err):
        return int(m.group(1), 16)
    if m := ENTRY_OFFSET_RE.search(err):
        return starts[int(m.group(1))] + int(m.group(2))
    return None


def write_sci(workdir, name, entries):
    manual = os.path.join(workdir, name.replace(".sci", ".manual.sci"))
    body = open(manual).read() if os.path.exists(manual) else ""
    with open(os.path.join(workdir, name), "w") as f:
        f.write(body + "\n".join(entries.values()) + "\n")


def main():
    srw, pe, out, workdir = sys.argv[1:5]
    insns = disassemble(pe)
    index_of = {a: i for i, (a, _, _) in enumerate(insns)}
    targets = {jump_target(o) for _, m, o in insns if m.startswith("j")} - {None}
    starts = section_starts(pe)
    flag_pairs = {}      # region start -> sci lines
    producer_of = {}     # producer address -> region starts that forced it
    replacements = {}    # region start -> sci line
    pending = {}         # region start -> (flags, paths) for the re-compare fallback
    code_entries = {}    # region start -> global alias for its jump target
    simd_functions = {}  # start -> end of functions left untranslated
    calls = {jump_target(o) for _, m, o in insns if m in ("call", "calll")} - {None}
    entries = known_entries(pe, workdir)
    jumps = [(k, t, m not in ("jmp", "jmpl")) for k, (_, m, o) in enumerate(insns)
             if m.startswith("j") and (t := jump_target(o)) in index_of]
    def handle(err, iteration):
        """Fixes the one SRW error in `err`: FIXED, UNRECOGNIZED or an exit code."""
        m = REGION_RE.search(err)
        mix = MIXING_RE.search(err)
        special = SPECIAL_RE.search(err)
        empty = EMPTY_RE.search(err)
        bad = [int(x.group(1), 16) for x in (special,) if x]
        bad += [starts[int(x.group(1))] + int(x.group(2)) for x in (empty, UNKNOWN_ANY_RE.search(err)) if x]
        simd_at = next((a for a in bad if a in index_of and is_simd(insns[index_of[a]])), None)
        if simd_at is not None and simd_at not in replacements and insns[index_of[simd_at]][1] not in SIMD_FLAG_WRITERS:
            # Replace the instruction by a trap: its function stays translated (and
            # callable), but this path needs a CPU feature bl_cpuid does not report.
            # MMX is emulated instead (mmx_llasm), as some code uses it unconditionally.
            # One SRW run per instruction is too slow for SIMD-heavy modules, so every SIMD
            # instruction of the surrounding function is replaced at once.
            start, end = function_bounds(insns, index_of, calls, index_of[simd_at], jumps)
            count = 0
            for k in sorted(reached_in(insns, index_of, calls | entries, jumps, simd_at, start, end)):
                a = insns[k][0]
                if (a == simd_at or is_simd(insns[k])) and insns[k][1] not in SIMD_FLAG_WRITERS and a not in replacements:
                    length = insns[k + 1][0] - a
                    mmx = mmx_llasm(insns[k][1], insns[k][2])
                    body = "|".join(mmx) + " ; auto: MMX" if mmx else f"call bl_simd_trap $, {a:#x} ; auto: SIMD"
                    replacements[a] = f"loc_{a:X},{length},;{insns[k][1]} {insns[k][2]}|{body}"
                    SIMD_TRAPS.add(a)
                    count += 1
            print(f"fix {iteration}: 0x{simd_at:x} SIMD {insns[index_of[simd_at]][1]}: {count} instructions in 0x{start:x}-0x{end:x} -> trap")
            return FIXED
        if simd_at is not None:
            start, end = function_bounds(insns, index_of, calls, index_of[simd_at], jumps)
            # Earlier fixes inside the excluded range no longer apply.
            for table in (flag_pairs, replacements, code_entries, pending):
                for a in [a for a in table if start <= a < end]:
                    del table[a]
            if start in simd_functions:
                print(f"0x{simd_at:x}: SIMD function 0x{start:x} already excluded")
                return 3
            simd_functions[start] = end
            with open(os.path.join(workdir, "ignored_areas.sci"), "a") as f:
                f.write(f"loc_{start:X},{end - start}\n")
            with open(os.path.join(workdir, "external_procedures.sci"), "a") as f:
                f.write(f"loc_{start:X},bl_simd_unreachable\n")
            print(f"fix {iteration}: SIMD function 0x{start:x}-0x{end:x} ({insns[index_of[simd_at]][1]}) excluded")
            return FIXED
        if special and special.group(2) in X87_ENV:
            addr = int(special.group(1), 16)
            k = index_of.get(addr)
            lines = address_llasm(insns[k][2]) if k is not None else None
            if lines is None or addr in replacements:
                print(f"0x{addr:x}: cannot replace {special.group(2)}")
                return 3
            body = "|".join(lines + [f"call {X87_ENV[special.group(2)]} $, tmp0"])
            replacements[addr] = f"loc_{addr:X},{insns[k + 1][0] - addr},;{insns[k][1]} {insns[k][2]}|{body} ; auto: x87 environment"
            print(f"fix {iteration}: 0x{addr:x} {special.group(2)} -> {X87_ENV[special.group(2)]}")
            return FIXED
        if special and special.group(2) in SPECIAL:
            addr = int(special.group(1), 16)
            if addr in replacements:
                print(f"0x{addr:x}: {special.group(2)} replacement did not take")
                return 3
            length = insns[index_of[addr] + 1][0] - addr
            helper = SPECIAL[special.group(2)]
            body = f"|call {helper} $" if helper else ""
            replacements[addr] = f"loc_{addr:X},{length},;{special.group(2)}{body} ; auto: special instruction"
            print(f"fix {iteration}: 0x{addr:x} {special.group(2)} -> {SPECIAL[special.group(2)]}")
            return FIXED
        unknown = UNKNOWN_RE.search(err)
        if unknown and unknown.group(3) in ECX_BRANCH:
            # jecxz / loop: conditional branch on ecx, as a conditional tail call to a
            # procedure seeded at the target (like the re-compare jcc replacement).
            addr = starts[int(unknown.group(1))] + int(unknown.group(2))
            target = int(unknown.group(4), 16)
            if addr in replacements:
                print(f"0x{addr:x}: {unknown.group(3)} replacement did not take")
                return 3
            length = insns[index_of[addr] + 1][0] - addr
            after = f"loc_{addr:X}_after"
            replacements[addr] = (f"loc_{addr:X},{length},;{unknown.group(3)} loc_{target:X}|"
                                   f"{ECX_BRANCH[unknown.group(3)]}|ctcallnz tmp0, recmp_{target:X}|"
                                   f"tcall {after}|endp|proc {after} ; auto: ecx branch")
            code_entries[addr] = f"loc_{target:X},recmp_{target:X}"
            print(f"fix {iteration}: 0x{addr:x} {unknown.group(3)}")
            return FIXED
        region = (int(m.group(1), 16), int(m.group(2), 16)) if m else None
        if empty and not m:
            # A flag-only instruction whose flags SRW thinks nobody reads: the reader is
            # the next instruction, a jcc that is also a region start.
            addr = starts[int(empty.group(1))] + int(empty.group(2))
            i = index_of.get(addr)
            if i is not None and insns[i][1] in BIT_OPS:
                line, why = bit_test(insns, index_of, i)
                if line is None or addr in replacements:
                    print(f"0x{addr:x}: cannot replace {insns[i][1]} {insns[i][2]}: {why}")
                    return 3
                replacements[addr] = line
                if why is not None:
                    code_entries[addr] = f"loc_{why:X},recmp_{why:X}"
                print(f"fix {iteration}: 0x{addr:x} {insns[i][1]}")
                return FIXED
            if i is not None and insns[i][1] in X87_TBYTE and insns[i][2].startswith("tbyte ptr"):
                lines = address_llasm(insns[i][2])
                if lines is None or addr in replacements:
                    print(f"0x{addr:x}: cannot replace {insns[i][1]} {insns[i][2]}")
                    return 3
                length = insns[i + 1][0] - addr
                body = "|".join(lines + [f"call {X87_TBYTE[insns[i][1]]} $, tmp0"])
                replacements[addr] = f"loc_{addr:X},{length},;{insns[i][1]} tbyte|{body} ; auto: 80-bit x87 operand"
                print(f"fix {iteration}: 0x{addr:x} {insns[i][1]} tbyte -> {X87_TBYTE[insns[i][1]]}")
                return FIXED
            raw = pe_bytes(pe, addr, 2)
            if i is not None and len(raw) == 2 and raw[0] in (0xD8, 0xDC, 0xDE) and raw[1] >= 0xC0 \
                    and (raw[1] >> 3) & 7 not in (2, 3) and addr not in replacements:
                # x87 register arithmetic SRW lacks: runtime bl_x87_arith decodes the opcode.
                code = raw[0] << 8 | raw[1]
                replacements[addr] = f"loc_{addr:X},2,;{insns[i][1]} {insns[i][2]}|call bl_x87_arith $, {code:#x} ; auto: x87 arithmetic"
                print(f"fix {iteration}: 0x{addr:x} {insns[i][1]} {insns[i][2]} -> bl_x87_arith")
                return FIXED
            nxt = insns[i + 1] if i is not None else None
            # Follow `test r, r; jmp X` to the jcc at X.
            if nxt is not None and nxt[1] in ("jmp", "jmpl") and jump_target(nxt[2]) in index_of:
                nxt = insns[index_of[jump_target(nxt[2])]]
            flag_only = i is not None and (insns[i][1] in ("test", "cmp") or
                                           (insns[i][1] in ("or", "and") and same_reg(insns[i][2])))
            if flag_only and nxt is not None and nxt[1] in JCC_FLAGS and nxt[0] in targets:
                region = (nxt[0], JCC_FLAGS[nxt[1]])
            elif addr in replacements:
                print(f"0x{addr:x}: replacement did not take: {empty.group(3)}")
                return 3
            elif i is not None and insns[i][1] in ("test", "cmp") and insns[i + 1][1].startswith("j") \
                    and insns[i + 1][0] not in targets:
                # Compare SRW cannot translate (byte/high-byte operands), fused with its jcc.
                line, why = fused_compare(insns, index_of, i)
                if line is None:
                    print(f"0x{addr:x}: cannot fuse {insns[i][1:]}: {why}")
                    return 3
                replacements[addr] = line
                code_entries[addr] = f"loc_{why:X},recmp_{why:X}"
                print(f"fix {iteration}: 0x{addr:x} fused compare")
                return FIXED
            elif (alu := re.fullmatch(r"(and|or|xor|add|sub) (e[a-z]{2}), (loc_[0-9A-F]+)", empty.group(3).strip())) \
                    and flags_dead(insns, index_of, i + 1):
                # ALU op with a relocated immediate (an address used as a mask or offset).
                op, reg, label = alu.groups()
                length = insns[i + 1][0] - addr
                replacements[addr] = f"loc_{addr:X},{length},;{empty.group(3).strip()}|mov tmp0, {label}|{op} {reg}, {reg}, tmp0 ; auto: relocated immediate"
                print(f"fix {iteration}: 0x{addr:x} relocated immediate")
                return FIXED
            elif i is not None and (body := byte_op(insns[i])) is not None and \
                    (insns[i][1] == "xchg" or flags_dead(insns, index_of, i + 1)):
                length = insns[i + 1][0] - addr
                replacements[addr] = f"loc_{addr:X},{length},;{insns[i][1]} {insns[i][2]}|" + "|".join(body) + " ; auto: byte operation"
                print(f"fix {iteration}: 0x{addr:x} byte {insns[i][1]}")
                return FIXED
            elif flag_only and flags_dead(insns, index_of, i + 1):
                # Flags nobody reads (e.g. `or eax, eax` before ret in hand-written code).
                length = insns[i + 1][0] - addr
                replacements[addr] = f"loc_{addr:X},{length},;{insns[i][1]} {insns[i][2]} ; auto: dead flags"
                print(f"fix {iteration}: 0x{addr:x} dead flags")
                return FIXED
            else:
                print(f"0x{addr:x}: llasm instruction error not understood: {insns[i][1:] if i is not None else '?'}")
                return 3
        if mix:
            prod = int(mix.group(1), 16)
            for addr in producer_of.pop(prod, []):
                flags, paths = pending[addr]
                line, why = recompare(insns, index_of, addr, paths)
                if line is not None and why is not None:
                    # The replaced jcc no longer tells SRW its target is code;
                    # a global alias seeds it as a procedure SRW must emit.
                    code_entries[addr] = f"loc_{why:X},recmp_{why:X}"
                if line is None:
                    print(f"0x{addr:x}: producer 0x{prod:x} fused with its jcc; re-compare impossible: {why}")
                    return 4
                del flag_pairs[addr]
                replacements[addr] = line
                print(f"fix {iteration}: 0x{addr:x} re-compare")
            return FIXED
        if not region:
            return UNRECOGNIZED
        addr, flags = region
        if addr not in index_of or addr in flag_pairs or addr in replacements:
            print(f"0x{addr:x}: unresolvable (not decoded, or already fixed and still failing)")
            return 3
        preds = predecessors(insns, index_of, addr)
        if preds == [index_of[addr]] and insns[index_of[addr] - 1][1] in ("call", "calll"):
            line, why = crt_zf_jcc(insns, index_of, targets, addr)
            if line is None:
                print(f"0x{addr:x} flags 0x{flags:x} after a call: {why}")
                return 4
            replacements[addr] = line
            code_entries[addr] = f"loc_{why:X},recmp_{why:X}"
            print(f"fix {iteration}: 0x{addr:x} CRT flag return")
            return FIXED
        paths = []
        for p in preds:
            prod = find_producer(insns, p, targets)
            if prod is None:
                print(f"0x{addr:x} flags 0x{flags:x}: no unambiguous producer via 0x{insns[p][0]:x}")
                return 4
            paths.append((prod, p))
        lines = [f"loc_{insns[p][0]:X},0x{flags:02X},0          ; auto: producer for loc_{addr:X}" for p, _ in paths]
        lines.append(f"loc_{addr:X},0   ,0x{flags:02X}       ; auto: flags live at region start\n")
        flag_pairs[addr] = "\n".join(lines)
        pending[addr] = (flags, paths)
        for p, _ in paths:
            producer_of.setdefault(insns[p][0], []).append(addr)
        print(f"fix {iteration}: 0x{addr:x} flags 0x{flags:x} producers {len(paths)}")
        return FIXED

    for iteration in range(1, 20000):
        write_sci(workdir, "instruction_flags.sci", flag_pairs)
        write_sci(workdir, "instruction_replacements.sci", replacements)
        write_sci(workdir, "global_aliases.sci", code_entries)
        r = subprocess.run([srw, pe, out], cwd=workdir, capture_output=True, text=True)
        # SRW (tools/srw-macos.patch) reports every region error of a run; each is fixed
        # here unless an earlier fix of this run already covers its address.
        errors = [line for line in r.stderr.splitlines() if line.startswith("Error:")]
        before = {id(t): set(t) for t in (flag_pairs, replacements, code_entries)}
        excluded = dict(simd_functions)
        fixed, failed = 0, None
        for err in errors:
            addr = error_address(err, starts)
            if addr is not None and (any(addr in t and addr not in before[id(t)]
                                         for t in (flag_pairs, replacements, code_entries))
                                     or any(s <= addr < e for s, e in simd_functions.items() if s not in excluded)):
                continue
            result = handle(err, iteration)
            if result is FIXED:
                fixed += 1
            elif result is not UNRECOGNIZED and failed is None:
                failed = result
        if fixed:
            print(f"run {iteration}: {fixed} fixes for {len(errors)} errors", flush=True)
            continue
        if not errors and (orphans := orphan_traps(workdir) & SIMD_TRAPS):
            # SIMD traps on code SRW never reached: SRW emits a replacement even then,
            # outside any procedure, which llasm rejects. Drop them and run again.
            for a in orphans:
                del replacements[a]
                SIMD_TRAPS.discard(a)
            print(f"run {iteration}: {len(orphans)} unreached SIMD traps removed", flush=True)
            continue
        print(f"SRW exit {r.returncode}: {len(flag_pairs)} flag pairs, {len(replacements)} re-compares")
        sys.stderr.write(r.stderr[-1500:])
        return failed if failed is not None else r.returncode
    return 5


if __name__ == "__main__":
    sys.exit(main())
