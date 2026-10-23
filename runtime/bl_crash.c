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

static void report(int sig, siginfo_t *info, void *vctx)
{
    ucontext_t *ctx = vctx;
    uint64_t pc = ctx->uc_mcontext->__ss.__pc, lr = ctx->uc_mcontext->__ss.__lr;
    uint64_t addr = (uint64_t)info->si_addr;
    Dl_info pci = {0}, lri = {0};
    dladdr((void *)pc, &pci);
    dladdr((void *)lr, &lri);
    fprintf(stderr, "bloodlines runtime: signal %d (%s) at host 0x%llx (guest 0x%llx)\n", sig, strsignal(sig),
            (unsigned long long)addr, (unsigned long long)(addr - bl_ptrofs));
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

void bl_crash_install(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = report;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}
