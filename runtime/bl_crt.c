// Native replacements for statically linked MSVC C-runtime routines (see
// native/modules/README.md). Each takes the guest CPU; arguments are on the guest
// stack above the return address, x87 values on the emulated x87 stack.
#include <math.h>
#include <stdint.h>
#include <string.h>

#include "llasm_cpu.h"

#define ST0 cpu->_st[cpu->_st_top]

static double stack_double(_cpu *cpu, uint32_t offset)
{
    double v;
    memcpy(&v, REG2PTR(esp + offset), sizeof v);
    return v;
}

static void x87_push(_cpu *cpu, double v)
{
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    ST0 = v;
}

// double sqrt(double x): cdecl, result in ST0.
void bl_crt_sqrt_c(_cpu *cpu)
{
    x87_push(cpu, sqrt(stack_double(cpu, 4)));
}

// _CIsqrt: argument and result in ST0.
void bl_crt_CIsqrt_c(_cpu *cpu)
{
    ST0 = sqrt(ST0);
}

// double log(double x): cdecl, result in ST0.
void bl_crt_log_c(_cpu *cpu)
{
    x87_push(cpu, log(stack_double(cpu, 4)));
}

// _CIlog: argument and result in ST0.
void bl_crt_CIlog_c(_cpu *cpu)
{
    ST0 = log(ST0);
}

// memcpy and memmove share one MSVC implementation that handles overlap.
void bl_crt_memcpy_c(_cpu *cpu)
{
    uint32_t *args = REG2PTR(esp + 4);
    if (args[2]) memmove(REG2PTR(args[0]), REG2PTR(args[1]), args[2]);
    eax = args[0];
}

// _strnicmp and _stricmp: the C locale's (the game never sets another), as MSVC does it:
// A-Z taken as a-z, bytes compared unsigned; -1, 0 or 1.
static int lower(uint8_t c) { return c >= 'A' && c <= 'Z' ? c + 0x20 : c; }

void bl_crt_strnicmp_c(_cpu *cpu)
{
    uint32_t *args = REG2PTR(esp + 4);
    const uint8_t *a = REG2PTR(args[0]), *b = REG2PTR(args[1]);
    int r = 0;
    for (uint32_t n = args[2]; n; n--, a++, b++) {
        int x = lower(*a), y = lower(*b);
        if (x != y) {
            r = x < y ? -1 : 1;
            break;
        }
        if (!x) break;
    }
    eax = (uint32_t)r;
}

void bl_crt_stricmp_c(_cpu *cpu)
{
    uint32_t *args = REG2PTR(esp + 4);
    const uint8_t *a = REG2PTR(args[0]), *b = REG2PTR(args[1]);
    int x, y;
    do x = lower(*a++), y = lower(*b++);
    while (x == y && x);
    eax = (uint32_t)(x == y ? 0 : x < y ? -1 : 1);
}
