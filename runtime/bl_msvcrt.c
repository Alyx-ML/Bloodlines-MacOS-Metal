// msvcrt imports implemented natively. Arguments and results are guest values.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_vm.h"
#include "imports_names.h"

static uint32_t guest_errno_addr;

uint32_t bl_msvcrt_malloc_c(uint32_t size)
{
    return bl_guest_malloc(size);
}

void bl_msvcrt_free_c(uint32_t addr)
{
    bl_guest_free(addr);
}

uint32_t bl_msvcrt_errno_c(void)
{
    if (!guest_errno_addr) guest_errno_addr = bl_guest_calloc(1, 4);
    return guest_errno_addr;
}

// Runs the CRT's table of initializers (C++ static constructors and the like).
void bl_msvcrt_initterm_c(uint32_t begin, uint32_t end)
{
    for (uint32_t p = begin; p < end; p += 4) {
        uint32_t fn = *(uint32_t *)bl_g2h(p);
        if (fn) bl_call_guest(bl_thread_cpu, fn, BL_CDECL, 0, 0, NULL);
    }
}

void bl_import_trap_c(uint32_t id)
{
    if (id < sizeof(bl_import_trap_names) / sizeof(bl_import_trap_names[0]))
        bl_fatal("unimplemented import %s", bl_import_trap_names[id]);
    bl_fatal("unimplemented import #%u", id);
}

void bl_guest_backtrace(uint32_t sp);

// BL_IMPORT_TRACE=1 logs every import call guest code makes, with its caller and arguments.
void bl_import_trace_c(uint32_t id, uint32_t sp)
{
    static int on = -1;
    if (on < 0) on = getenv("BL_IMPORT_TRACE") != NULL;
    if (!on) return;
    const uint32_t *s = bl_g2h(sp);
    // Name the caller by the nearest exported symbol, cached per return address.
    static struct { uint32_t addr; const char *name; uintptr_t off; } cache[1 << 16];
    uint32_t slot = (s[0] * 2654435761u) >> 16;
    while (cache[slot].addr && cache[slot].addr != s[0]) slot = (slot + 1) & 0xffff;
    if (!cache[slot].addr) {
        Dl_info info;
        cache[slot].addr = s[0];
        int ok = dladdr(bl_g2h(s[0]), &info);
        cache[slot].name = ok && info.dli_sname ? info.dli_sname : "?";
        cache[slot].off = ok ? (uintptr_t)bl_g2h(s[0]) - (uintptr_t)info.dli_fbase : 0;
    }
    // +offset is from the executable's load address (add 0x100000000 for nm).
    fprintf(stderr, "[imp] %08x +%lx %s %s(", s[0], (unsigned long)cache[slot].off, cache[slot].name, bl_import_names[id]);
    // Arguments known to be strings are printed as text.
    static const struct { const char *name; unsigned mask; } strs[] = {
        {"kernel32!LoadLibraryA", 1}, {"kernel32!GetProcAddress", 2}, {"kernel32!GetModuleHandleA", 1},
        {"kernel32!CreateFileA", 1}, {"kernel32!OutputDebugStringA", 1}, {"kernel32!GetFileAttributesA", 1},
        {"kernel32!FindFirstFileA", 1}, {"user32!DrawTextA", 2}, {"user32!MessageBoxA", 6},
        {"user32!CreateWindowExA", 6}, {"advapi32!RegOpenKeyExA", 2}, {"advapi32!RegQueryValueExA", 2},
        {"kernel32!GetPrivateProfileStringA", 7}, {"kernel32!LoadLibraryExA", 1},
    };
    unsigned mask = 0;
    for (size_t k = 0; k < sizeof strs / sizeof strs[0]; k++)
        if (!strcmp(strs[k].name, bl_import_names[id])) mask = strs[k].mask;
    for (uint32_t i = 0; i < bl_import_nargs[id]; i++) {
        if (mask >> i & 1 && s[1 + i] > 0xffff) fprintf(stderr, "%s\"%.200s\"", i ? ", " : "", (const char *)bl_g2h(s[1 + i]));
        else fprintf(stderr, "%s0x%x", i ? ", " : "", s[1 + i]);
    }
    fprintf(stderr, ")\n");

    // BL_BACKTRACE_AT=<dll!name> also prints, at the first call of that import, every
    // stack word that points into the executable: return addresses among them resolve
    // to loc_<original VA>+0 (see the +offset note above).
    static const char *at;
    static int done;
    if (!at) at = getenv("BL_BACKTRACE_AT") ? getenv("BL_BACKTRACE_AT") : "";
    if (done || strcmp(at, bl_import_names[id])) return;
    done = 1;
    bl_guest_backtrace(sp);
}

// Prints every guest stack word that points into the executable; return addresses
// among them resolve (nm) to loc_<original VA>+0. Offsets are from the load address.
void bl_guest_backtrace(uint32_t sp)
{
    const uint32_t *s = bl_g2h(sp);
    Dl_info self;
    dladdr((const void *)bl_guest_backtrace, &self);
    for (uint32_t i = 0; i < 2048; i++) {
        Dl_info info;
        if (dladdr(bl_g2h(s[i]), &info) && info.dli_fbase == self.dli_fbase)
            fprintf(stderr, "[bt] esp=%x +%lx\n", 4 * i, (unsigned long)((uintptr_t)bl_g2h(s[i]) - (uintptr_t)info.dli_fbase));
    }
}
