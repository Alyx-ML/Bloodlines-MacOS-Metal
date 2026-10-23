// Win32 structured exception handling for guest code: RaiseException walks the
// fs:[0] registration chain and calls each handler as Windows' dispatcher would;
// RtlUnwind calls the handlers above a target frame with EXCEPTION_UNWINDING and
// unlinks them. MSVC builds C++ throw (_CxxThrowException in msvcrt) and __try/__except
// on these. A handler that continues at a catch or __except block jumps there itself;
// bl_call_guest (bl_vm.c) then lets the outer host -> guest call take over.
//
// Only software exceptions exist: guest faults (access violations, divide by zero)
// still stop the process.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bl_vm.h"
#include "bl_win32.h"
#include "llasm_cpu.h"

#define U32(addr) (*(uint32_t *)bl_g2h(addr))

uint32_t X86_ReadFsDword(uint32_t addr);
void X86_WriteFsDword(uint32_t addr, uint32_t value);

#define CHAIN_END 0xffffffffu
#define EXCEPTION_NONCONTINUABLE 1
#define EXCEPTION_UNWINDING 2
#define EXCEPTION_EXIT_UNWIND 4
#define STATUS_UNWIND 0xc0000027u
#define STATUS_NONCONTINUABLE_EXCEPTION 0xc0000025u
#define MSVC_CPP_EXCEPTION 0xe06d7363u

// EXCEPTION_RECORD (80 bytes) and CONTEXT (716 bytes) on the guest stack below esp.
#define RECORD_SIZE 80
#define CONTEXT_SIZE 716
#define CTX_EDI 156
#define CTX_ESI 160
#define CTX_EBX 164
#define CTX_EDX 168
#define CTX_ECX 172
#define CTX_EAX 176
#define CTX_EBP 180
#define CTX_EIP 184
#define CTX_EFLAGS 192
#define CTX_ESP 196

// The caller's registers as the handlers see them: at entry to the import esp points
// at the return address, which is the exception address.
static void fill_context(_cpu *cpu, uint32_t ctx)
{
    memset(bl_g2h(ctx), 0, CONTEXT_SIZE);
    U32(ctx) = 0x10007;  // CONTEXT_FULL
    U32(ctx + CTX_EDI) = edi;
    U32(ctx + CTX_ESI) = esi;
    U32(ctx + CTX_EBX) = ebx;
    U32(ctx + CTX_EDX) = edx;
    U32(ctx + CTX_ECX) = ecx;
    U32(ctx + CTX_EAX) = eax;
    U32(ctx + CTX_EBP) = ebp;
    U32(ctx + CTX_EIP) = U32(esp);
    U32(ctx + CTX_ESP) = esp + 4;
    U32(ctx + CTX_EFLAGS) = 0x202;
}

static uint32_t call_handler(_cpu *cpu, uint32_t reg, uint32_t rec, uint32_t ctx)
{
    uint32_t args[4] = { rec, reg, ctx, 0 };
    return bl_call_guest(cpu, U32(reg + 4), BL_CDECL, 0, 4, args);
}

static _Noreturn void unhandled(uint32_t rec)
{
    uint32_t code = U32(rec), addr = U32(rec + 12);
    if (code == MSVC_CPP_EXCEPTION && U32(rec + 16) >= 3)
        bl_fatal("unhandled C++ exception (object 0x%08x, throw info 0x%08x) thrown at 0x%08x",
                 U32(rec + 24), U32(rec + 28), addr);
    bl_fatal("unhandled guest exception 0x%08x at 0x%08x", code, addr);
}

uint32_t bl_k32_RaiseException_c(uint32_t code, uint32_t flags, uint32_t nargs, uint32_t args)
{
    _cpu *cpu = bl_thread_cpu;
    uint32_t esp0 = esp, base = (esp0 - 0x400) & ~15u, rec = base, ctx = base + 0x80;
    memset(bl_g2h(rec), 0, RECORD_SIZE);
    U32(rec) = code;
    U32(rec + 4) = flags & EXCEPTION_NONCONTINUABLE;
    U32(rec + 12) = U32(esp0);
    if (nargs > 15) nargs = 15;
    U32(rec + 16) = nargs;
    if (args && nargs) memcpy(bl_g2h(rec + 20), bl_g2h(args), 4 * nargs);
    fill_context(cpu, ctx);
    esp = base;

    for (uint32_t reg = X86_ReadFsDword(0); reg != CHAIN_END && reg; reg = U32(reg)) {
        uint32_t disposition = call_handler(cpu, reg, rec, ctx);
        if (disposition == 0) {  // ExceptionContinueExecution
            if (U32(rec + 4) & EXCEPTION_NONCONTINUABLE)
                bl_fatal("guest handler continued non-continuable exception 0x%08x", code);
            if (U32(ctx + CTX_EIP) != U32(esp0) || U32(ctx + CTX_ESP) != esp0 + 4)
                bl_fatal("guest handler changed the context of exception 0x%08x", code);
            esp = esp0;
            return 0;
        }
        if (disposition != 1)  // not ExceptionContinueSearch: nested or collided
            fprintf(stderr, "[seh] handler at 0x%08x returned %u for exception 0x%08x\n", U32(reg + 4),
                    disposition, code);
    }
    unhandled(rec);
}

uint32_t bl_k32_RtlUnwind_c(uint32_t target, uint32_t target_ip, uint32_t record, uint32_t value)
{
    (void)target_ip;  // MSVC passes the return address: unwinding returns normally
    _cpu *cpu = bl_thread_cpu;
    uint32_t esp0 = esp, base = (esp0 - 0x400) & ~15u, rec = record ? record : base, ctx = base + 0x80;
    if (!record) {
        memset(bl_g2h(rec), 0, RECORD_SIZE);
        U32(rec) = STATUS_UNWIND;
        U32(rec + 12) = U32(esp0);
    }
    U32(rec + 4) |= EXCEPTION_UNWINDING | (target ? 0 : EXCEPTION_EXIT_UNWIND);
    fill_context(cpu, ctx);
    esp = base;

    uint32_t reg = X86_ReadFsDword(0);
    while (reg != CHAIN_END && reg && reg != target) {
        call_handler(cpu, reg, rec, ctx);
        reg = U32(reg);
        X86_WriteFsDword(0, reg);
    }
    if (target && reg != target) bl_fatal("RtlUnwind: frame 0x%08x is not on the handler chain", target);
    esp = esp0;
    return value;
}
