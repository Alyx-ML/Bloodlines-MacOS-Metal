// Fault reporter: prints the faulting address as host and guest values plus the
// translated procedure (loc_XXXXXXXX = original x86 address) that faulted.
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include "bl_vm.h"

// Async-signal-safe text for the first line: appends s, or v in decimal or hex.
static size_t add_str(char *buf, size_t n, const char *s)
{
    while (*s && n < 255) buf[n++] = *s++;
    return n;
}

static size_t add_num(char *buf, size_t n, uint64_t v, unsigned base)
{
    char d[20];
    int k = 0;
    do d[k++] = "0123456789abcdef"[v % base], v /= base;
    while (v);
    while (k && n < 255) buf[n++] = d[--k];
    return n;
}

static const char *sig_name(int sig)
{
    switch (sig) {
    case SIGSEGV: return "Segmentation fault";
    case SIGBUS: return "Bus error";
    case SIGILL: return "Illegal instruction";
    case SIGFPE: return "Floating point exception";
    default: return "?";
    }
}

static void report(int sig, siginfo_t *info, void *vctx)
{
    ucontext_t *ctx = vctx;
    uint64_t pc = ctx->uc_mcontext->__ss.__pc, lr = ctx->uc_mcontext->__ss.__lr;
    uint64_t addr = (uint64_t)info->si_addr;
    // The first line goes out with write() alone, so it still shows when the fault
    // is inside malloc or stdio and the rest of the report hangs or faults again.
    char line[256];
    size_t n = add_str(line, 0, "bloodlines runtime: signal ");
    n = add_num(line, n, (uint64_t)sig, 10);
    n = add_str(line, n, " (");
    n = add_str(line, n, sig_name(sig));
    n = add_str(line, n, ") at host 0x");
    n = add_num(line, n, addr, 16);
    n = add_str(line, n, " (guest 0x");
    n = add_num(line, n, addr - bl_ptrofs, 16);
    n = add_str(line, n, ")\n");
    write(2, line, n);
    Dl_info pci = {0}, lri = {0};
    dladdr((void *)pc, &pci);
    dladdr((void *)lr, &lri);
    fprintf(stderr, "  pc +%llx lr +%llx (from the load address)\n", (unsigned long long)(pc - (uint64_t)pci.dli_fbase),
            (unsigned long long)(lr - (uint64_t)pci.dli_fbase));
    fprintf(stderr, "  pc 0x%llx %s+0x%llx\n  lr 0x%llx %s+0x%llx\n", (unsigned long long)pc,
            pci.dli_sname ? pci.dli_sname : "?", (unsigned long long)(pc - (uint64_t)pci.dli_saddr),
            (unsigned long long)lr, lri.dli_sname ? lri.dli_sname : "?",
            (unsigned long long)(lr - (uint64_t)lri.dli_saddr));
    void bl_vm_describe(void);
    uint32_t bl_vm_stack_guard(uint32_t g);
    bl_vm_describe();
    fprintf(stderr, "  host thread %s\n", pthread_main_np() ? "main" : "other");
    void *frames[48];
    backtrace_symbols_fd(frames, backtrace(frames, 48), 2);
    // A fault just below a guest page is usually a guest stack overflow: show the frames.
    uint32_t g = (uint32_t)(addr - bl_ptrofs);
    uint32_t bl_vm_esp(void);
    if (!bl_vm_stack_guard(g) && bl_vm_esp()) {
        void bl_guest_backtrace(uint32_t sp);
        bl_guest_backtrace(bl_vm_esp());
    } else if ((g & 0xfff) >= 0xff0 || bl_vm_stack_guard(g)) {
        if (bl_vm_stack_guard(g)) fprintf(stderr, "  guest stack overflow\n");
        void bl_guest_backtrace(uint32_t sp);
        bl_guest_backtrace(bl_vm_stack_guard(g) ? bl_vm_stack_guard(g) : g + 4);
    }
    _exit(128 + sig);
}

// Each thread that runs guest code reports on its own signal stack, so a host stack
// overflow still gets a report.
#define ALT_STACK_SIZE (64u << 10)
static _Thread_local void *alt_stack;

void bl_crash_thread_init(void)
{
    if (alt_stack) return;
    alt_stack = malloc(ALT_STACK_SIZE);
    stack_t ss = { .ss_sp = alt_stack, .ss_size = ALT_STACK_SIZE, .ss_flags = 0 };
    if (!alt_stack || sigaltstack(&ss, NULL)) bl_fatal("could not set up a signal stack");
}

void bl_crash_thread_done(void)
{
    if (!alt_stack) return;
    stack_t ss = { .ss_flags = SS_DISABLE };
    sigaltstack(&ss, NULL);
    free(alt_stack);
    alt_stack = NULL;
}

void bl_crash_install(void)
{
    bl_crash_thread_init();
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = report;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}
