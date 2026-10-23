// x86 instructions SRW cannot translate, replaced by calls from the translated code
// (tools/fix_region_flags.py emits the calls; runtime/llasm/bl_special.llinc declares them).
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include "bl_vm.h"
#include "llasm_cpu.h"

#define ST0 cpu->_st[cpu->_st_top]

// cpuid: a plain Pentium-class CPU with FPU, TSC, CX8 and CMOV but no MMX/SSE, so
// the game's CPU detection keeps to x87 code paths, which SRW translates.
void bl_cpuid(_cpu *cpu)
{
    switch (eax) {
    case 0:
        eax = 1;
        ebx = 0x756e6547;  // "Genu"
        edx = 0x49656e69;  // "ineI"
        ecx = 0x6c65746e;  // "ntel"
        break;
    case 1:
        eax = 0x00000f29;  // family 15 (Pentium 4)
        ebx = ecx = 0;
        edx = (1u << 0) | (1u << 4) | (1u << 8) | (1u << 15);
        break;
    default:  // no extended leaves
        eax = ebx = ecx = edx = 0;
        break;
    }
}

// rdtsc: a 1 GHz time stamp counter (nanoseconds since boot).
void bl_rdtsc(_cpu *cpu)
{
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    eax = (uint32_t)t;
    edx = (uint32_t)(t >> 32);
}

// fld tbyte [addr]: the emulated x87 stack holds doubles, so 80-bit values are
// rounded to double on load.
void bl_x87_fld80(_cpu *cpu, uint32_t addr)
{
    const uint8_t *p = REG2PTR(addr);
    uint64_t mant;
    memcpy(&mant, p, 8);
    unsigned se = p[8] | (p[9] << 8), exp = se & 0x7fff;
    double v;
    if (exp == 0x7fff)
        v = (mant << 1) ? NAN : INFINITY;
    else
        v = ldexp((double)mant, (int)exp - 16383 - 63);
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    ST0 = (se & 0x8000) ? -v : v;
}

// fstp tbyte [addr]
void bl_x87_fstp80(_cpu *cpu, uint32_t addr)
{
    uint8_t *p = REG2PTR(addr);
    double v = ST0;
    unsigned se = signbit(v) ? 0x8000 : 0;
    uint64_t mant = 0;
    if (isnan(v)) {
        se |= 0x7fff;
        mant = 0xc000000000000000ull;
    } else if (isinf(v)) {
        se |= 0x7fff;
        mant = 0x8000000000000000ull;
    } else if (v != 0) {
        int e;
        double m = frexp(fabs(v), &e);  // m in [0.5, 1)
        mant = (uint64_t)ldexp(m, 64);
        se |= (unsigned)(e - 1 + 16383);
    }
    memcpy(p, &mant, 8);
    p[8] = (uint8_t)se;
    p[9] = (uint8_t)(se >> 8);
    cpu->_st_top = (cpu->_st_top + 1) & 7;
}

// x87 instructions SRW lacks. Condition codes as in SR's llasm_float.c.
#define ST1 cpu->_st[(cpu->_st_top + 1) & 7]
#define X87_C0 0x0100
#define X87_C1 0x0200
#define X87_C2 0x0400
#define X87_C3 0x4000

static void push(_cpu *cpu, double v)
{
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    ST0 = v;
}

static void pop(_cpu *cpu)
{
    cpu->_st_top = (cpu->_st_top + 1) & 7;
}

void bl_x87_fldl2e(_cpu *cpu) { push(cpu, M_LOG2E); }
void bl_x87_fldl2t(_cpu *cpu) { push(cpu, 3.32192809488736234787); }
void bl_x87_fldpi(_cpu *cpu) { push(cpu, M_PI); }
void bl_x87_f2xm1(_cpu *cpu) { ST0 = exp2(ST0) - 1.0; }
void bl_x87_fscale(_cpu *cpu) { ST0 = ldexp(ST0, (int)trunc(fmax(fmin(ST1, 1e5), -1e5))); }

void bl_x87_frndint(_cpu *cpu)
{
    switch ((cpu->_st_cw >> 10) & 3) {
    case 0: ST0 = nearbyint(ST0); break;  // host default mode is round-to-nearest-even
    case 1: ST0 = floor(ST0); break;
    case 2: ST0 = ceil(ST0); break;
    default: ST0 = trunc(ST0); break;
    }
}

// ST1 = exponent, ST0 = significand in [1, 2).
void bl_x87_fxtract(_cpu *cpu)
{
    double v = ST0, e, m;
    if (v == 0) {
        e = -INFINITY;
        m = v;
    } else if (isinf(v) || isnan(v)) {
        e = isnan(v) ? v : INFINITY;
        m = v;
    } else {
        int x;
        m = frexp(v, &x) * 2.0;
        e = x - 1;
    }
    ST0 = e;
    push(cpu, m);
}

static void prem(_cpu *cpu, double r, double q)
{
    long long qi = (long long)fabs(q);
    ST0 = r;
    cpu->_st_sw_cond = ((qi & 4) ? X87_C0 : 0) | ((qi & 2) ? X87_C3 : 0) | ((qi & 1) ? X87_C1 : 0);
}

void bl_x87_fprem(_cpu *cpu) { prem(cpu, fmod(ST0, ST1), trunc(ST0 / ST1)); }
void bl_x87_fprem1(_cpu *cpu) { prem(cpu, remainder(ST0, ST1), nearbyint(ST0 / ST1)); }

void bl_x87_fpatan(_cpu *cpu)
{
    double v = atan2(ST1, ST0);
    pop(cpu);
    ST0 = v;
}

void bl_x87_fxam(_cpu *cpu)
{
    double v = ST0;
    unsigned c = signbit(v) ? X87_C1 : 0;
    switch (fpclassify(v)) {
    case FP_NAN: c |= X87_C0; break;
    case FP_INFINITE: c |= X87_C2 | X87_C0; break;
    case FP_ZERO: c |= X87_C3; break;
    case FP_SUBNORMAL: c |= X87_C3 | X87_C2; break;
    default: c |= X87_C2; break;
    }
    cpu->_st_sw_cond = c;
}

void bl_x87_ftst(_cpu *cpu)
{
    double v = ST0;
    cpu->_st_sw_cond = isnan(v) ? X87_C3 | X87_C2 | X87_C0 : v < 0 ? X87_C0 : v == 0 ? X87_C3 : 0;
}

void bl_x87_fincstp(_cpu *cpu) { cpu->_st_top = (cpu->_st_top + 1) & 7; }
void bl_x87_fdecstp(_cpu *cpu) { cpu->_st_top = (cpu->_st_top + 7) & 7; }

// fsincos: ST0 = sin(x), then push cos(x).
void bl_x87_fsincos(_cpu *cpu)
{
    double x = ST0;
    ST0 = sin(x);
    push(cpu, cos(x));
}

// Entry of an MMX/SSE/3DNow! function that was left untranslated (tools/fix_region_flags.py).
// The game only takes these paths when cpuid reports the feature, which bl_cpuid does not.
void bl_simd_unreachable_c(_cpu *cpu)
{
    extern _Noreturn void bl_fatal(const char *fmt, ...);
    bl_fatal("untranslated SIMD function called (return address 0x%08x)", *(uint32_t *)REG2PTR(esp));
}

// An MMX/SSE/3DNow! instruction replaced by a call (tools/fix_region_flags.py). Its
// function is translated but only runs when cpuid reports the feature.
void bl_simd_trap(_cpu *cpu, uint32_t addr)
{
    (void)cpu;
    bl_fatal("untranslated SIMD instruction at 0x%08x reached", addr);
}

// rep cmpsd (tools/srw-macos.patch): compares dwords at [esi] and [edi] while they are
// equal (repe) or differ (repne) and ecx > 0, updating esi, edi and ecx; the
// translated code then sets the flags from the last pair, at esi - 4 and edi - 4.
// SRW only calls these with ecx != 0; the direction flag is clear in MSVC code.
static void rep_cmpsd(_cpu *cpu, int until_equal)
{
    while (ecx) {
        uint32_t a, b;
        memcpy(&a, bl_g2h(esi), 4);
        memcpy(&b, bl_g2h(edi), 4);
        esi += 4;
        edi += 4;
        ecx--;
        if ((a == b) == until_equal) break;
    }
}

void bl_repe_cmpsd(_cpu *cpu) { rep_cmpsd(cpu, 0); }
void bl_repne_cmpsd(_cpu *cpu) { rep_cmpsd(cpu, 1); }

// x87 register arithmetic SRW does not translate (e.g. `fsubr st(1), st`), identified by
// its two opcode bytes: D8 /r ST(0) = ST(0) op ST(i); DC /r ST(i) = ST(i) op ST(0) with
// the subtract/divide directions swapped (Intel SDM encoding); DE /r as DC, then pop.
void bl_x87_arith(_cpu *cpu, uint32_t code)
{
    uint32_t opcode = code >> 8, modrm = code & 0xff;
    int i = (int)(modrm & 7), op = (int)((modrm >> 3) & 7);
    double *sti = &cpu->_st[(cpu->_st_top + (uint32_t)i) & 7], *st0 = &ST0;
    double a, b, *dst;  // dst = a op b
    if (opcode == 0xD8) {
        dst = st0, a = *st0, b = *sti;
        if (op == 5 || op == 7) a = *sti, b = *st0;  // fsubr, fdivr
    } else {
        dst = sti, a = *sti, b = *st0;
        if (op == 4 || op == 6) a = *st0, b = *sti;  // DC E0+i fsubr, DC F0+i fdivr
    }
    switch (op) {
    case 0: *dst = a + b; break;
    case 1: *dst = a * b; break;
    case 4: case 5: *dst = a - b; break;
    case 6: case 7: *dst = a / b; break;
    default: bl_fatal("bl_x87_arith: unsupported %02X %02X", opcode, modrm);
    }
    if (opcode == 0xDE) pop(cpu);
}

// x87 environment (protected-mode 32-bit layout, 28 bytes): control word, status word
// (condition codes and TOP), tag word, then instruction/operand pointers (zero here).
// Exceptions stay masked, so no pending-exception state is kept.
void bl_x87_fnstenv(_cpu *cpu, uint32_t addr)
{
    uint32_t *e = REG2PTR(addr);
    memset(e, 0, 28);
    e[0] = 0xffff0000u | cpu->_st_cw;
    e[1] = 0xffff0000u | (cpu->_st_sw_cond & 0x4700) | ((cpu->_st_top & 7) << 11);
    e[2] = 0xffff0000u;  // tags: not tracked, reported as valid
    cpu->_st_cw |= 0x3f;  // fnstenv masks all exceptions
}

void bl_x87_fldenv(_cpu *cpu, uint32_t addr)
{
    const uint32_t *e = REG2PTR(addr);
    cpu->_st_cw = e[0] & 0xffff;
    cpu->_st_sw_cond = e[1] & 0x4700;
    cpu->_st_top = (e[1] >> 11) & 7;
}

// fnsave: environment, then ST(0)..ST(7) as 80-bit values; then fninit.
void bl_x87_fnsave(_cpu *cpu, uint32_t addr)
{
    bl_x87_fnstenv(cpu, addr);
    for (uint32_t i = 0; i < 8; i++) bl_x87_fstp80(cpu, addr + 28 + 10 * i);  // pops: TOP returns to start
    cpu->_st_cw = 0x37f;
    cpu->_st_sw_cond = 0;
    cpu->_st_top = 0;
}

void bl_x87_frstor(_cpu *cpu, uint32_t addr)
{
    for (int i = 7; i >= 0; i--) bl_x87_fld80(cpu, addr + 28 + 10 * (uint32_t)i);
    bl_x87_fldenv(cpu, addr);
}

// MMX, for code that uses it without checking cpuid (the engine's sound mixer). Each
// instruction becomes a call bl_mmx(cpu, op, operands, arg) (tools/fix_region_flags.py):
// op indexes MMX_OPS below (the same list as MMX_OPS in fix_region_flags.py); operands
// holds the destination in bits 0-7 and the source in bits 8-15, each kind << 4 | index
// with kind 0 = mm register, 1 = 32-bit general register (eax ecx edx ebx esp ebp esi
// edi), 2 = memory at arg, 3 = immediate arg. The MMX registers are per thread and do
// not alias the x87 stack, which no game code depends on.
enum {
    MMX_MOVQ, MMX_MOVD, MMX_PACKSSDW, MMX_PACKSSWB, MMX_PACKUSWB, MMX_PUNPCKLBW, MMX_PUNPCKLWD, MMX_PUNPCKLDQ,
    MMX_PUNPCKHBW, MMX_PUNPCKHWD, MMX_PUNPCKHDQ, MMX_PADDB, MMX_PADDW, MMX_PADDD, MMX_PADDSB, MMX_PADDSW,
    MMX_PADDUSB, MMX_PADDUSW, MMX_PSUBB, MMX_PSUBW, MMX_PSUBD, MMX_PSUBSB, MMX_PSUBSW, MMX_PSUBUSB, MMX_PSUBUSW,
    MMX_PMULLW, MMX_PMULHW, MMX_PMADDWD, MMX_PAND, MMX_PANDN, MMX_POR, MMX_PXOR, MMX_PCMPEQB, MMX_PCMPEQW,
    MMX_PCMPEQD, MMX_PCMPGTB, MMX_PCMPGTW, MMX_PCMPGTD, MMX_PSLLW, MMX_PSLLD, MMX_PSLLQ, MMX_PSRLW, MMX_PSRLD,
    MMX_PSRLQ, MMX_PSRAW, MMX_PSRAD, MMX_EMMS,
};

static _Thread_local uint64_t mmx[8];

static uint32_t *gpr(_cpu *cpu, unsigned i)
{
    switch (i & 7) {
    case 0: return &eax;
    case 1: return &ecx;
    case 2: return &edx;
    case 3: return &ebx;
    case 4: return &esp;
    case 5: return &ebp;
    case 6: return &esi;
    default: return &edi;
    }
}

typedef union { uint64_t q; uint32_t d[2]; int32_t sd[2]; uint16_t w[4]; int16_t sw[4]; uint8_t b[8]; int8_t sb[8]; } mmx_t;

static int16_t sat16(int32_t v) { return (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); }
static int8_t sat8(int32_t v) { return (int8_t)(v > 127 ? 127 : v < -128 ? -128 : v); }
static uint8_t satu8(int32_t v) { return (uint8_t)(v > 255 ? 255 : v < 0 ? 0 : v); }
static uint16_t satu16(int32_t v) { return (uint16_t)(v > 65535 ? 65535 : v < 0 ? 0 : v); }

void bl_mmx(_cpu *cpu, uint32_t op, uint32_t operands, uint32_t arg)
{
    unsigned dk = operands >> 4 & 15, di = operands & 15, sk = operands >> 12 & 15, si = operands >> 8 & 15;
    if (op == MMX_EMMS) return;
    if (op == MMX_MOVQ || op == MMX_MOVD) {
        int q = op == MMX_MOVQ;
        uint64_t v = 0;
        if (sk == 0) v = mmx[si];
        else if (sk == 1) v = *gpr(cpu, si);
        else memcpy(&v, bl_g2h(arg), q ? 8 : 4);
        if (!q) v = (uint32_t)v;
        if (dk == 0) mmx[di] = v;
        else if (dk == 1) *gpr(cpu, di) = (uint32_t)v;
        else memcpy(bl_g2h(arg), &v, q ? 8 : 4);
        return;
    }
    if (dk != 0) bl_fatal("bl_mmx: op %u with a non-register destination", op);
    mmx_t d = {mmx[di]}, s = {0}, r = {0};
    if (sk == 0) s.q = mmx[si];
    else if (sk == 2) memcpy(&s.q, bl_g2h(arg), 8);
    else if (sk == 3) s.q = arg;
    else bl_fatal("bl_mmx: op %u with a general register source", op);
    uint64_t n = s.q;  // shift count
    switch (op) {
    case MMX_PACKSSDW: for (int i = 0; i < 2; i++) r.sw[i] = sat16(d.sd[i]), r.sw[i + 2] = sat16(s.sd[i]); break;
    case MMX_PACKSSWB: for (int i = 0; i < 4; i++) r.sb[i] = sat8(d.sw[i]), r.sb[i + 4] = sat8(s.sw[i]); break;
    case MMX_PACKUSWB: for (int i = 0; i < 4; i++) r.b[i] = satu8(d.sw[i]), r.b[i + 4] = satu8(s.sw[i]); break;
    case MMX_PUNPCKLBW: for (int i = 0; i < 4; i++) r.b[2 * i] = d.b[i], r.b[2 * i + 1] = s.b[i]; break;
    case MMX_PUNPCKLWD: for (int i = 0; i < 2; i++) r.w[2 * i] = d.w[i], r.w[2 * i + 1] = s.w[i]; break;
    case MMX_PUNPCKLDQ: r.d[0] = d.d[0], r.d[1] = s.d[0]; break;
    case MMX_PUNPCKHBW: for (int i = 0; i < 4; i++) r.b[2 * i] = d.b[i + 4], r.b[2 * i + 1] = s.b[i + 4]; break;
    case MMX_PUNPCKHWD: for (int i = 0; i < 2; i++) r.w[2 * i] = d.w[i + 2], r.w[2 * i + 1] = s.w[i + 2]; break;
    case MMX_PUNPCKHDQ: r.d[0] = d.d[1], r.d[1] = s.d[1]; break;
    case MMX_PADDB: for (int i = 0; i < 8; i++) r.b[i] = (uint8_t)(d.b[i] + s.b[i]); break;
    case MMX_PADDW: for (int i = 0; i < 4; i++) r.w[i] = (uint16_t)(d.w[i] + s.w[i]); break;
    case MMX_PADDD: for (int i = 0; i < 2; i++) r.d[i] = d.d[i] + s.d[i]; break;
    case MMX_PADDSB: for (int i = 0; i < 8; i++) r.sb[i] = sat8(d.sb[i] + s.sb[i]); break;
    case MMX_PADDSW: for (int i = 0; i < 4; i++) r.sw[i] = sat16(d.sw[i] + s.sw[i]); break;
    case MMX_PADDUSB: for (int i = 0; i < 8; i++) r.b[i] = satu8(d.b[i] + s.b[i]); break;
    case MMX_PADDUSW: for (int i = 0; i < 4; i++) r.w[i] = satu16(d.w[i] + s.w[i]); break;
    case MMX_PSUBB: for (int i = 0; i < 8; i++) r.b[i] = (uint8_t)(d.b[i] - s.b[i]); break;
    case MMX_PSUBW: for (int i = 0; i < 4; i++) r.w[i] = (uint16_t)(d.w[i] - s.w[i]); break;
    case MMX_PSUBD: for (int i = 0; i < 2; i++) r.d[i] = d.d[i] - s.d[i]; break;
    case MMX_PSUBSB: for (int i = 0; i < 8; i++) r.sb[i] = sat8(d.sb[i] - s.sb[i]); break;
    case MMX_PSUBSW: for (int i = 0; i < 4; i++) r.sw[i] = sat16(d.sw[i] - s.sw[i]); break;
    case MMX_PSUBUSB: for (int i = 0; i < 8; i++) r.b[i] = satu8(d.b[i] - s.b[i]); break;
    case MMX_PSUBUSW: for (int i = 0; i < 4; i++) r.w[i] = satu16(d.w[i] - s.w[i]); break;
    case MMX_PMULLW: for (int i = 0; i < 4; i++) r.w[i] = (uint16_t)(d.sw[i] * s.sw[i]); break;
    case MMX_PMULHW: for (int i = 0; i < 4; i++) r.sw[i] = (int16_t)((d.sw[i] * s.sw[i]) >> 16); break;
    case MMX_PMADDWD:
        for (int i = 0; i < 2; i++) r.sd[i] = d.sw[2 * i] * s.sw[2 * i] + d.sw[2 * i + 1] * s.sw[2 * i + 1];
        break;
    case MMX_PAND: r.q = d.q & s.q; break;
    case MMX_PANDN: r.q = ~d.q & s.q; break;
    case MMX_POR: r.q = d.q | s.q; break;
    case MMX_PXOR: r.q = d.q ^ s.q; break;
    case MMX_PCMPEQB: for (int i = 0; i < 8; i++) r.b[i] = d.b[i] == s.b[i] ? 0xFF : 0; break;
    case MMX_PCMPEQW: for (int i = 0; i < 4; i++) r.w[i] = d.w[i] == s.w[i] ? 0xFFFF : 0; break;
    case MMX_PCMPEQD: for (int i = 0; i < 2; i++) r.d[i] = d.d[i] == s.d[i] ? ~0u : 0; break;
    case MMX_PCMPGTB: for (int i = 0; i < 8; i++) r.b[i] = d.sb[i] > s.sb[i] ? 0xFF : 0; break;
    case MMX_PCMPGTW: for (int i = 0; i < 4; i++) r.w[i] = d.sw[i] > s.sw[i] ? 0xFFFF : 0; break;
    case MMX_PCMPGTD: for (int i = 0; i < 2; i++) r.d[i] = d.sd[i] > s.sd[i] ? ~0u : 0; break;
    case MMX_PSLLW: for (int i = 0; i < 4; i++) r.w[i] = n > 15 ? 0 : (uint16_t)(d.w[i] << n); break;
    case MMX_PSLLD: for (int i = 0; i < 2; i++) r.d[i] = n > 31 ? 0 : d.d[i] << n; break;
    case MMX_PSLLQ: r.q = n > 63 ? 0 : d.q << n; break;
    case MMX_PSRLW: for (int i = 0; i < 4; i++) r.w[i] = n > 15 ? 0 : (uint16_t)(d.w[i] >> n); break;
    case MMX_PSRLD: for (int i = 0; i < 2; i++) r.d[i] = n > 31 ? 0 : d.d[i] >> n; break;
    case MMX_PSRLQ: r.q = n > 63 ? 0 : d.q >> n; break;
    case MMX_PSRAW: for (int i = 0; i < 4; i++) r.sw[i] = (int16_t)(d.sw[i] >> (n > 15 ? 15 : n)); break;
    case MMX_PSRAD: for (int i = 0; i < 2; i++) r.sd[i] = d.sd[i] >> (n > 31 ? 31 : n); break;
    default: bl_fatal("bl_mmx: unknown op %u", op);
    }
    mmx[di] = r.q;
}
