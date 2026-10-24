// Guest memory window, guest heap and CPU state. See bl_vm.h.
#include "bl_vm.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <setjmp.h>
#include <sys/mman.h>

#define PTROFS_64BIT 1
#include "llasm_cpu.h"

#define GiB (UINT64_C(1) << 30)
#define WINDOW_SIZE (4 * GiB)
#define HEAP_SIZE (1 * GiB)
// Guest addresses below this stay unmapped so small integers never look like pointers.
#define LOW_GUARD (16u << 20)

uint64_t bl_ptrofs;
uint32_t X86_InterruptFlag;  // used by llasm_pushx.c (pushfd/popfd)

// Set by each translated module's constructor; calling it fixes up the
// absolute addresses stored in that module's data segments.
extern void (*ptr_initialize_pointers)(uint64_t);

// The guest heap is every large free range of the window, used one after another.
#define MAX_ARENAS 32
static struct { uint8_t *base, *end; } arenas[MAX_ARENAS];
static int narenas, cur_arena;
static uint8_t *heap_bump;

_Noreturn void bl_fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("bloodlines runtime: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    abort();
}

static void main_image_range(uint64_t *lo, uint64_t *hi)
{
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    *lo = UINT64_MAX;
    *hi = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strcmp(seg->segname, SEG_PAGEZERO) == 0) continue;
        uint64_t start = seg->vmaddr + slide, end = start + seg->vmsize;
        if (start < *lo) *lo = start;
        if (end > *hi) *hi = end;
    }
}

void bl_crash_install(void);

void bl_vm_init(void)
{
    bl_crash_install();
    uint64_t lo, hi;
    main_image_range(&lo, &hi);
    bl_ptrofs = (lo - LOW_GUARD) & ~(uint64_t)0xFFFF;
    if (hi - bl_ptrofs > 2 * GiB)
        bl_fatal("executable image too large for the guest window (%llu MiB)",
                 (unsigned long long)((hi - lo) >> 20));

    // The heap takes every free range of 64 MiB or more in the window, largest
    // pieces first at each address. The dyld shared cache and early dylib and malloc
    // mappings split the window, so one region would be at most a few hundred MiB.
    // mmap treats the address as a hint, so check the result rather than MAP_FIXED
    // over unknown mappings.
    uint64_t total = 0;
    uint64_t hint = (bl_ptrofs + LOW_GUARD + (64u << 20) - 1) & ~(uint64_t)((64u << 20) - 1);
    for (; hint < bl_ptrofs + WINDOW_SIZE && narenas < MAX_ARENAS; hint += 64u << 20) {
        for (uint64_t size = 2 * GiB; size >= (64u << 20); size /= 2) {
            if (hint + size > bl_ptrofs + WINDOW_SIZE) continue;
            void *p = mmap((void *)hint, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (p == MAP_FAILED) continue;
            if ((uint64_t)p != hint) {
                munmap(p, size);
                continue;
            }
            arenas[narenas].base = p;
            arenas[narenas++].end = (uint8_t *)p + size;
            total += size;
            hint += size - (64u << 20);
            break;
        }
    }
    if (!narenas) bl_fatal("could not map the guest heap inside the 4 GiB window at 0x%llx",
                           (unsigned long long)bl_ptrofs);
    heap_bump = arenas[0].base;
    if (getenv("BL_HEAP_TRACE")) fprintf(stderr, "[heap] %d ranges, %llu MiB\n", narenas, (unsigned long long)(total >> 20));

    if (ptr_initialize_pointers) ptr_initialize_pointers(bl_ptrofs);
}

// Guest heap: size classes at quarter steps between powers of two (at most 25%
// waste), with free lists. Blocks never return to the host.
#define MIN_SHIFT 4
#define MAX_SHIFT 30
#define HDR 16
#define NCLASSES (4 * (MAX_SHIFT + 1))
static uint32_t free_lists[NCLASSES];

// Class c holds blocks of (4 + c % 4) << (c / 4 - 2) bytes.
static uint64_t class_len(unsigned c) { return (uint64_t)(4 + c % 4) << (c / 4 - 2); }

static unsigned size_class(uint32_t size)
{
    uint64_t need = (uint64_t)size + HDR;
    unsigned c = 4 * MIN_SHIFT;
    while (c < NCLASSES && (class_len(c) < need || class_len(c) % 16)) c++;  // keep blocks 16-byte aligned
    return c;
}

static pthread_mutex_t heap_lock = PTHREAD_MUTEX_INITIALIZER;
static void bl_guest_free_unlocked(uint32_t addr);

static uint32_t bl_guest_malloc_unlocked(uint32_t size)
{
    unsigned s = size_class(size);
    if (size >= (64u << 20) && getenv("BL_HEAP_TRACE")) {
        uint64_t used = heap_bump - arenas[cur_arena].base;
        for (int i = 0; i < cur_arena; i++) used += arenas[i].end - arenas[i].base;
        fprintf(stderr, "[heap] asked for %u MiB, %llu MiB used\n", size >> 20, (unsigned long long)(used >> 20));
    }
    if (s >= NCLASSES) return 0;
    uint8_t *block;
    if (free_lists[s]) {
        block = bl_g2h(free_lists[s]);
        free_lists[s] = *(uint32_t *)(block + 4);
    } else {
        uint64_t len = class_len(s);
        while ((uint64_t)(arenas[cur_arena].end - heap_bump) < len) {
            if (cur_arena + 1 >= narenas) {
                if (getenv("BL_HEAP_TRACE"))
                    fprintf(stderr, "[heap] full asking %u: arena %d of %d, bump %p, end %p, base %p\n", size, cur_arena, narenas,
                            (void *)heap_bump, (void *)arenas[cur_arena].end, (void *)arenas[cur_arena].base);
                return 0;
            }
            heap_bump = arenas[++cur_arena].base;
        }
        block = heap_bump;
        heap_bump += len;
    }
    static uint32_t class_count[NCLASSES];
    if (++class_count[s] % (class_len(s) >= 4096 ? 1000 : 20000) == 0 && getenv("BL_HEAP_TRACE"))
        fprintf(stderr, "[heap] %u blocks of %u bytes (last asked %u)\n", class_count[s], (unsigned)class_len(s), size);
    *(uint32_t *)block = s;
    *(uint32_t *)(block + 4) = 0;
    *(uint32_t *)(block + 8) = size;
    return bl_h2g(block + HDR);
}

uint32_t bl_guest_calloc(uint32_t count, uint32_t size)
{
    uint64_t total = (uint64_t)count * size;
    if (total > UINT32_MAX) return 0;
    uint32_t g = bl_guest_malloc((uint32_t)total);
    if (g) memset(bl_g2h(g), 0, (size_t)total);
    return g;
}

uint32_t bl_guest_size(uint32_t addr)
{
    return *(uint32_t *)((uint8_t *)bl_g2h(addr) - HDR + 8);
}

static uint32_t bl_guest_realloc_unlocked(uint32_t addr, uint32_t size)
{
    if (!addr) return bl_guest_malloc_unlocked(size);
    uint8_t *block = (uint8_t *)bl_g2h(addr) - HDR;
    if (size + (uint64_t)HDR <= class_len(*(uint32_t *)block)) {
        *(uint32_t *)(block + 8) = size;
        return addr;
    }
    uint32_t n = bl_guest_malloc_unlocked(size);
    if (!n) return 0;
    uint32_t old = *(uint32_t *)(block + 8);
    memcpy(bl_g2h(n), bl_g2h(addr), old < size ? old : size);
    bl_guest_free_unlocked(addr);
    return n;
}

static void bl_guest_free_unlocked(uint32_t addr)
{
    if (!addr) return;
    uint8_t *block = (uint8_t *)bl_g2h(addr) - HDR;
    uint32_t s = *(uint32_t *)block;
    int in_heap = 0;
    for (int i = 0; i <= cur_arena; i++)
        in_heap |= block >= arenas[i].base && block < (i == cur_arena ? heap_bump : arenas[i].end);
    if (s < 4 * MIN_SHIFT || s >= NCLASSES || !in_heap) bl_fatal("free of invalid guest pointer 0x%08x", addr);
    *(uint32_t *)(block + 4) = free_lists[s];
    free_lists[s] = bl_h2g(block);
}

uint32_t bl_guest_malloc(uint32_t size)
{
    pthread_mutex_lock(&heap_lock);
    uint32_t g = bl_guest_malloc_unlocked(size);
    pthread_mutex_unlock(&heap_lock);
    return g;
}

uint32_t bl_guest_realloc(uint32_t addr, uint32_t size)
{
    pthread_mutex_lock(&heap_lock);
    uint32_t g = bl_guest_realloc_unlocked(addr, size);
    pthread_mutex_unlock(&heap_lock);
    return g;
}

void bl_guest_free(uint32_t addr)
{
    pthread_mutex_lock(&heap_lock);
    bl_guest_free_unlocked(addr);
    pthread_mutex_unlock(&heap_lock);
}

_Thread_local void *bl_thread_cpu;

#define STACK_GUARD 0x10000u  // a multiple of the host page size

void *bl_cpu_new(uint32_t stack_size)
{
    // The x87 helpers return pointers into the CPU state as 32-bit guest values
    // (x87_fstp_double gives &ST0), so it has to live inside the guest window.
    uint32_t gcpu = bl_guest_malloc(sizeof(_cpu));
    _cpu *cpu = gcpu ? memset(bl_g2h(gcpu), 0, sizeof(_cpu)) : NULL;
    // An inaccessible guard below the stack turns an overflow into a fault instead of
    // silent writes into whatever lies below (for the first block, the executable's data).
    uint32_t block = bl_guest_malloc(stack_size + 2 * STACK_GUARD);
    if (!cpu || !block) bl_fatal("out of memory creating a guest CPU");
    uint32_t guard = (block + STACK_GUARD - 1) & ~(STACK_GUARD - 1);
    if (mprotect(bl_g2h(guard), STACK_GUARD, PROT_NONE)) bl_fatal("could not protect a guest stack guard");
    uint32_t stack = guard + STACK_GUARD;
    cpu->stack_bottom = bl_g2h(stack);
    cpu->stack_top = (uint8_t *)cpu->stack_bottom + stack_size;
    cpu->_pointer_offset = bl_ptrofs;
    cpu->_st_cw = 0x037f;  // x87 default: round to nearest, 64-bit precision, all masked
    esp = (stack + stack_size - 16) & ~15u;
    eflags = 0x0202;
    if (!bl_thread_cpu) bl_thread_cpu = cpu;
    return cpu;
}

uint32_t bl_call_cdecl(void *vcpu, void (*entry)(void *), int nargs, const uint32_t *args)
{
    _cpu *cpu = vcpu;
    for (int i = nargs - 1; i >= 0; i--) {
        esp -= 4;
        *(uint32_t *)bl_g2h(esp) = args[i];
    }
    uint32_t saved = esp;
    entry(cpu);  // c_<name> pushes its own return address and pops it on ret
    if (esp != saved) bl_fatal("cdecl call left esp off by %d", (int)(esp - saved));
    esp += 4 * nargs;
    return eax;
}

extern void c_bl_guest_invoke(void *cpu);

// Host -> guest calls active on this thread, innermost last (see bl_call_guest).
#define MAX_INVOCATIONS 256
struct invocation {
    uint32_t expect;  // guest esp once the call has returned
    jmp_buf jb;
};
static _Thread_local struct invocation invocations[MAX_INVOCATIONS];
static _Thread_local int ninvocations;

uint32_t bl_call_guest(void *vcpu, uint32_t fn, enum bl_callconv conv, uint32_t this_ptr, int nargs,
                       const uint32_t *args)
{
    _cpu *cpu = vcpu;
    if (fn == 0) bl_fatal("call to guest address 0");
    for (int i = nargs - 1; i >= 0; i--) {
        esp -= 4;
        *(uint32_t *)bl_g2h(esp) = args[i];
    }
    uint32_t expect = conv == BL_CDECL ? esp : esp + 4 * nargs;
    if (conv == BL_THISCALL) ecx = this_ptr;
    eax = fn;
    if (ninvocations == MAX_INVOCATIONS) bl_fatal("guest calls nested too deeply");
    struct invocation *self = &invocations[ninvocations++];
    self->expect = expect;
    if (!_setjmp(self->jb)) {
        c_bl_guest_invoke(cpu);
        if (esp != expect) {
            // Translated code is tail calls only, so a guest `ret` to an outer
            // invocation's return address returns through the innermost host frame.
            // That happens when a C++ catch continues past a nested call such as an SEH
            // handler run by RaiseException; the outer invocation takes over.
            for (int i = ninvocations - 2; i >= 0; i--)
                if (invocations[i].expect == esp) {
                    ninvocations = i + 1;
                    _longjmp(invocations[i].jb, 1);
                }
            bl_fatal("guest call 0x%08x left esp off by %d", fn, (int)(esp - expect));
        }
    }
    ninvocations = (int)(self - invocations);
    if (conv == BL_CDECL) esp += 4 * nargs;
    return eax;
}

uint32_t bl_guest_strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    uint32_t g = bl_guest_malloc((uint32_t)n);
    if (!g) bl_fatal("out of guest memory");
    memcpy(bl_g2h(g), s, n);
    return g;
}

// Crash reports: the guest heap and the faulting thread's guest stack and esp.
void bl_vm_describe(void)
{
    _cpu *cpu = bl_thread_cpu;
    uint64_t used = heap_bump - arenas[cur_arena].base, total = 0;
    for (int i = 0; i < narenas; i++) {
        if (i < cur_arena) used += arenas[i].end - arenas[i].base;
        total += arenas[i].end - arenas[i].base;
    }
    fprintf(stderr, "  guest heap %d ranges, %llu of %llu MiB used\n", narenas, (unsigned long long)(used >> 20),
            (unsigned long long)(total >> 20));
    if (cpu)
        fprintf(stderr, "  thread stack 0x%08x-0x%08x esp 0x%08x\n", bl_h2g(cpu->stack_bottom),
                bl_h2g(cpu->stack_top), esp);
}

// If guest address g is in this thread's stack guard, the stack's lowest address; else 0.
uint32_t bl_vm_stack_guard(uint32_t g)
{
    _cpu *cpu = bl_thread_cpu;
    uint32_t bottom = cpu ? bl_h2g(cpu->stack_bottom) : 0;
    return cpu && g < bottom && g >= bottom - STACK_GUARD ? bottom : 0;
}

// This thread's guest esp, if it lies inside its stack (crash reports); else 0.
uint32_t bl_vm_esp(void)
{
    _cpu *cpu = bl_thread_cpu;
    return cpu && esp >= bl_h2g(cpu->stack_bottom) && esp < bl_h2g(cpu->stack_top) ? esp : 0;
}
