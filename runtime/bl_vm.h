// Guest memory window and CPU state for recompiled modules.
//
// Translated code works with 32-bit guest addresses; host address = guest + bl_ptrofs.
// The window [bl_ptrofs, bl_ptrofs + 4 GiB) must hold the executable's own text and
// data (recompiled code and the modules' data segments) and every guest allocation.
#ifndef BL_VM_H
#define BL_VM_H

#include <stddef.h>
#include <stdint.h>

struct _cpu_s;

extern uint64_t bl_ptrofs;

// Picks the window, maps the guest heap and fixes up the modules' data pointers.
// Aborts with a message if the layout cannot be satisfied.
void bl_vm_init(void);

static inline void *bl_g2h(uint32_t guest) { return guest ? (void *)(uintptr_t)(guest + bl_ptrofs) : NULL; }
static inline uint32_t bl_h2g(const void *host) { return host ? (uint32_t)((uintptr_t)host - bl_ptrofs) : 0; }

// Guest heap; returns guest addresses (0 on failure). Thread-safe.
uint32_t bl_guest_malloc(uint32_t size);
uint32_t bl_guest_calloc(uint32_t count, uint32_t size);
void bl_guest_free(uint32_t addr);
uint32_t bl_guest_realloc(uint32_t addr, uint32_t size);
uint32_t bl_guest_size(uint32_t addr);  // size requested at allocation

// Guest string helpers.
uint32_t bl_guest_strdup(const char *s);

// One CPU state per host thread that runs guest code; stack lives in the guest heap.
void *bl_cpu_new(uint32_t stack_size);

// The CPU state of this thread (its first bl_cpu_new), for import handlers that
// call back into guest code.
extern _Thread_local void *bl_thread_cpu;

// Calls a translated cdecl entry point (c_<name>) with 32-bit arguments; returns eax.
uint32_t bl_call_cdecl(void *cpu, void (*entry)(void *), int nargs, const uint32_t *args);

// Calls translated code by guest address (function pointers held in guest memory,
// or bl_h2g() of a translated proc). stdcall/thiscall callees pop their arguments;
// thiscall passes this_ptr in ecx. Returns eax.
enum bl_callconv { BL_CDECL, BL_STDCALL, BL_THISCALL };
uint32_t bl_call_guest(void *cpu, uint32_t fn, enum bl_callconv conv, uint32_t this_ptr, int nargs,
                       const uint32_t *args);

_Noreturn void bl_fatal(const char *fmt, ...);

#endif
