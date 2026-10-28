// Module registry for the recompiled DLLs linked into this executable, the Win32
// loader imports on top of it, and the per-thread TIB the FS segment points at.
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "bl_win32.h"
#include "llasm_cpu.h"

#define U32(addr) (*(uint32_t *)bl_g2h(addr))
#define MAX_MODULES 64

static struct bl_module *modules[MAX_MODULES];
static int nmodules;
static uint32_t exe_handle;

void bl_register_module(struct bl_module *m)
{
    if (nmodules == MAX_MODULES) bl_fatal("too many modules");
    modules[nmodules++] = m;
}

// "C:\path\Tier0.DLL" and "tier0" both name tier0.dll; "mssmp3.asi" names mssmp3.dll.
static struct bl_module *find_module(const char *name)
{
    const char *base = name;
    for (const char *p = name; *p; p++)
        if (*p == '\\' || *p == '/') base = p + 1;
    size_t n = strlen(base);
    if (n > 4 && (!strcasecmp(base + n - 4, ".dll") || !strcasecmp(base + n - 4, ".asi"))) n -= 4;  // Miles providers
    for (int i = 0; i < nmodules; i++) {
        const char *m = modules[i]->name;
        size_t mn = strlen(m) - 4;  // registered names end in ".dll"
        if (mn == n && !strncasecmp(m, base, n)) return modules[i];
    }
    return NULL;
}

static struct bl_module *module_of_handle(uint32_t h)
{
    for (int i = 0; i < nmodules; i++)
        if (modules[i]->handle && modules[i]->handle == h) return modules[i];
    return NULL;
}

// A fake image header, so the handle points at "MZ" like a real HMODULE.
static uint32_t new_module_handle(void)
{
    uint32_t h = bl_guest_calloc(1, 0x1000);
    memcpy(bl_g2h(h), "MZ", 2);
    return h;
}

uint32_t bl_load_module(const char *name)
{
    struct bl_module *m = find_module(name);
    if (!m) {
        bl_set_last_error(BL_ERROR_MOD_NOT_FOUND);
        return 0;
    }
    if (m->loaded) return m->handle;
    for (const char *const *d = m->deps; d && *d; d++) {
        if (!bl_load_module(*d)) {
            fprintf(stderr, "[loader] %s: import %s did not load\n", m->name, *d);
            return 0;
        }
    }
    m->handle = new_module_handle();
    m->loaded = 1;
    if (m->entry) {
        uint32_t args[3] = { m->handle, 1, 0 };  // DLL_PROCESS_ATTACH
        if (!bl_call_guest(bl_thread_cpu, bl_h2g(m->entry), BL_STDCALL, 0, 3, args)) {
            m->loaded = 0;
            bl_set_last_error(1114);  // ERROR_DLL_INIT_FAILED
            fprintf(stderr, "[loader] %s: DllMain(PROCESS_ATTACH) failed\n", m->name);
            return 0;
        }
    }
    return m->handle;
}

uint32_t bl_module_export(uint32_t handle, const char *name)
{
    struct bl_module *m = module_of_handle(handle);
    if (!m) return 0;
    for (uint32_t i = 0; i < m->nexports; i++)
        if (!strcmp(m->exports[i].name, name)) return bl_h2g(m->exports[i].sym);
    return 0;
}

uint32_t bl_k32_LoadLibraryA_c(uint32_t name)
{
    uint32_t h = bl_load_module(bl_g2h(name));
    if (!h) fprintf(stderr, "[loader] LoadLibraryA(\"%s\"): not a recompiled module\n", (const char *)bl_g2h(name));
    return h;
}

uint32_t bl_k32_FreeLibrary_c(uint32_t h)
{
    (void)h;  // modules stay loaded
    return 1;
}

uint32_t bl_k32_GetModuleHandleA_c(uint32_t name)
{
    if (!name) return exe_handle;
    struct bl_module *m = find_module(bl_g2h(name));
    if (m && m->loaded) return m->handle;
    bl_set_last_error(BL_ERROR_MOD_NOT_FOUND);
    return 0;
}

uint32_t bl_k32_GetProcAddress_c(uint32_t h, uint32_t name)
{
    if (name < 0x10000) {  // by ordinal
        bl_set_last_error(BL_ERROR_PROC_NOT_FOUND);
        return 0;
    }
    uint32_t a = bl_module_export(h, bl_g2h(name));
    if (!a) bl_set_last_error(BL_ERROR_PROC_NOT_FOUND);
    return a;
}

uint32_t bl_k32_GetModuleFileNameA_c(uint32_t h, uint32_t buf, uint32_t size)
{
    char path[300];
    struct bl_module *m = h && h != exe_handle ? module_of_handle(h) : NULL;
    if (h && h != exe_handle && !m) {
        bl_set_last_error(BL_ERROR_MOD_NOT_FOUND);
        return 0;
    }
    snprintf(path, sizeof path, "%s\\%s", BL_WIN_ROOT, m ? m->name : "vampire.exe");
    uint32_t n = (uint32_t)strlen(path);
    if (!size) return 0;
    uint32_t c = n < size ? n : size - 1;
    memcpy(bl_g2h(buf), path, c);
    ((char *)bl_g2h(buf))[c] = 0;
    if (n >= size) bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER);
    return c;
}

// --- FS segment: thread information block ------------------------------------

static _Thread_local uint32_t tib;
static uint32_t peb;  // one per process, as on Windows
static pthread_once_t peb_once = PTHREAD_ONCE_INIT;

static void peb_new(void) { peb = bl_guest_calloc(1, 0x400); }

static uint32_t thread_tib(void)
{
    if (tib) return tib;
    _cpu *cpu = bl_thread_cpu;
    pthread_once(&peb_once, peb_new);
    tib = bl_guest_calloc(1, 0x1000);
    U32(tib + 0x00) = 0xffffffffu;  // end of the SEH chain
    if (cpu) {
        U32(tib + 0x04) = bl_h2g(cpu->stack_top);
        U32(tib + 0x08) = bl_h2g(cpu->stack_bottom);
    }
    U32(tib + 0x18) = tib;  // self
    U32(tib + 0x30) = peb;
    return tib;
}

// A CreateThread thread's TIB goes back to the guest heap when the thread ends.
void bl_thread_tib_free(void)
{
    bl_guest_free(tib);
    tib = 0;
}

uint32_t X86_ReadFsDword(uint32_t addr)
{
    if (addr > 0xffc) bl_fatal("read of fs:[0x%x]", addr);
    return U32(thread_tib() + addr);
}

void X86_WriteFsDword(uint32_t addr, uint32_t value)
{
    if (addr > 0xffc) bl_fatal("write of fs:[0x%x]", addr);
    U32(thread_tib() + addr) = value;
}

// int n: only int 3 (DebuggerBreak) is expected; it is reported and skipped.
void X86_InterruptProcedure(const uint8_t n, void *regs)
{
    (void)regs;
    if (n == 3) {
        fprintf(stderr, "[guest] breakpoint (int 3) ignored\n");
        return;
    }
    bl_fatal("guest interrupt 0x%02x", n);
}

// in/out: user-mode Windows code never reaches them (privileged); msvcrt's legacy
// _inp/_outp exports contain them.
uint32_t X86_InPortProcedure(const uint16_t port, const uint32_t size)
{
    bl_fatal("guest in from port 0x%04x (%u bytes)", port, size);
}

void X86_OutPortProcedure(const uint16_t port, const uint32_t size, const uint32_t value)
{
    (void)value;
    bl_fatal("guest out to port 0x%04x (%u bytes)", port, size);
}

// Absolute loads/stores at low addresses (SRW routes [0x0..0xffff] here): the NULL
// page, which faults on Windows; the game uses these only to crash deliberately.
uint32_t X86_ReadMemProcedure(const uint32_t addr, const uint32_t size)
{
    bl_fatal("guest read of %u bytes at 0x%08x (NULL page)", size, addr);
}

void X86_WriteMemProcedure(const uint32_t addr, const uint32_t size, const uint32_t value)
{
    (void)value;
    bl_fatal("guest write of %u bytes at 0x%08x (NULL page)", size, addr);
}

void bl_loader_init(void)
{
    exe_handle = new_module_handle();
}
