// Runtime checks that need no game files: the Windows text conversion, printf
// formatting (bl_format.c), waits, events, semaphores, mutexes, named objects and
// threads (bl_thread.c), the guest heap and thread stacks (bl_vm.c), DirectInput's
// mouse motion (dinput8.c) and the shader translator's loops (d3d9_shader.c), each
// from made-up inputs. Built and run by tools/runtime_unit.sh against the runtime's
// own objects, with the real guest memory window (bl_vm_init); the other pieces those
// need (handles, D3D objects, the guest code a thread runs) are small stand-ins here.
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bl_win32.h"
#include "d3d9_objects.h"
#include "d3d9_shader.h"
#include "llasm_cpu.h"

static int failures, checks;

static void check(int ok, const char *what)
{
    checks++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

// --- stand-ins ---------------------------------------------------------------------

// Guest memory is the runtime's own (bl_vm.o); no module data to fix up.
void (*ptr_initialize_pointers)(uint64_t);

static uint32_t guest_alloc(uint32_t size)
{
    uint32_t g = bl_guest_calloc(1, size);
    if (!g) abort();
    return g;
}

static uint32_t last_error;
void bl_set_last_error(uint32_t err) { last_error = err; }

static void *handles[64];
static enum bl_handle_type handle_types[64];
uint32_t bl_handle_new(enum bl_handle_type type, void *obj)
{
    for (uint32_t i = 1; i < 64; i++)
        if (!handles[i]) {
            handles[i] = obj, handle_types[i] = type;
            return i * 4;
        }
    abort();
}
void *bl_handle_get(uint32_t h, enum bl_handle_type type)
{
    return h / 4 < 64 && handle_types[h / 4] == type ? handles[h / 4] : NULL;
}
void bl_handle_free(uint32_t h) { handles[h / 4] = NULL; }

struct obj *obj_new(enum obj_type type, uint32_t vtbl)
{
    (void)vtbl;
    struct obj *o = bl_g2h(guest_alloc(sizeof *o));
    o->type = type, o->refs = 1, o->guest = bl_h2g(o);
    return o;
}
struct obj *obj_of(uint32_t guest) { return bl_g2h(guest); }
uint32_t bl_vtbl_IDirectInput8A(void) { return 0; }
uint32_t bl_vtbl_IDirectInputDevice8A(void) { return 0; }

void bl_guest_backtrace(uint32_t sp) { (void)sp; }

// The guest code threads run: bl_call_guest lands here with the guest address in eax
// and one stdcall argument on the guest stack, which the "callee" pops.
uint32_t bl_k32_GetCurrentThreadId_c(void);
uint32_t bl_k32_ExitThread_c(uint32_t code);
uint32_t X86_ReadFsDword(uint32_t addr);
enum { FAKE_THREAD_MAIN = 0x1000 };

void c_bl_guest_invoke(void *vcpu)
{
    _cpu *cpu = vcpu;
    if (eax != FAKE_THREAD_MAIN) abort();
    uint32_t *rec = bl_g2h(*(uint32_t *)bl_g2h(esp));  // id, tib, peb, stack, exit?
    rec[0] = bl_k32_GetCurrentThreadId_c();
    rec[1] = X86_ReadFsDword(0x18);
    rec[2] = X86_ReadFsDword(0x30);
    rec[3] = bl_h2g(cpu->stack_bottom);
    if (rec[4]) bl_k32_ExitThread_c(rec[4]);  // leaves through thread_main, not here
    esp += 4;
    eax = 7;
}

// --- the runtime's functions under test --------------------------------------------

uint32_t bl_k32_CreateMutexA_c(uint32_t sec, uint32_t owned, uint32_t name);
uint32_t bl_k32_ReleaseMutex_c(uint32_t h);
uint32_t bl_k32_CreateEventA_c(uint32_t sec, uint32_t manual, uint32_t initial, uint32_t name);
uint32_t bl_k32_WaitForSingleObject_c(uint32_t h, uint32_t ms);
uint32_t bl_k32_WaitForMultipleObjects_c(uint32_t n, uint32_t handles, uint32_t all, uint32_t ms);
uint32_t bl_k32_SetEvent_c(uint32_t h);
uint32_t bl_k32_ResetEvent_c(uint32_t h);
uint32_t bl_k32_CreateSemaphoreA_c(uint32_t sec, uint32_t initial, uint32_t max, uint32_t name);
uint32_t bl_k32_ReleaseSemaphore_c(uint32_t h, uint32_t n, uint32_t prev);
uint32_t bl_k32_Sleep_c(uint32_t ms);
uint32_t bl_k32_CreateThread_c(uint32_t sec, uint32_t stack, uint32_t start, uint32_t param, uint32_t flags,
                               uint32_t tid);
int bl_format(char *outbuf, size_t cap, const char *fmt, uint32_t ap);
uint32_t bl_dinput_DirectInput8Create_c(uint32_t inst, uint32_t ver, uint32_t iid, uint32_t out, uint32_t outer);
uint32_t bl_IDirectInput8A_CreateDevice_c(uint32_t self, uint32_t guid, uint32_t out, uint32_t outer);
uint32_t bl_IDirectInputDevice8A_Acquire_c(uint32_t self);
uint32_t bl_IDirectInputDevice8A_Unacquire_c(uint32_t self);
uint32_t bl_IDirectInputDevice8A_GetDeviceState_c(uint32_t self, uint32_t size, uint32_t data);
void bl_input_mouse_move(int dx, int dy);

static uint32_t guest_str(const char *s)
{
    uint32_t g = guest_alloc((uint32_t)strlen(s) + 1);
    strcpy(bl_g2h(g), s);
    return g;
}

static void text(void)
{
    check(bl_cp1252_to_wide(0x92) == 0x2019, "cp1252: 0x92 is a right single quote");
    check(bl_cp1252_to_wide(0x85) == 0x2026, "cp1252: 0x85 is an ellipsis");
    check(bl_cp1252_to_wide(0x97) == 0x2014, "cp1252: 0x97 is an em dash");
    check(bl_cp1252_to_wide('A') == 'A' && bl_cp1252_to_wide(0xE9) == 0xE9, "cp1252: ASCII and Latin-1 unchanged");
    int round = 1;
    for (int c = 0; c < 256; c++) round &= bl_wide_to_cp1252(bl_cp1252_to_wide((uint8_t)c)) == c;
    check(round, "cp1252: every byte converts to wide and back");
    check(bl_wide_to_cp1252(0x0080) == -1, "cp1252: control code U+0080 has no byte");
    check(bl_wide_to_cp1252(0x4E00) == -1, "cp1252: CJK has no byte");
}

static void *take_mutex(void *arg)
{
    return (void *)(uintptr_t)bl_k32_WaitForSingleObject_c(*(uint32_t *)arg, 0);
}

static void mutexes(void)
{
    uint32_t m = bl_k32_CreateMutexA_c(0, 0, 0);
    check(bl_k32_WaitForSingleObject_c(m, 0) == 0, "mutex: first wait takes it");
    check(bl_k32_WaitForSingleObject_c(m, 0) == 0, "mutex: same thread takes it again without blocking");
    pthread_t t;
    void *r;
    pthread_create(&t, NULL, take_mutex, &m);
    pthread_join(t, &r);
    check((uintptr_t)r == 0x102, "mutex: another thread times out while it is held");  // WAIT_TIMEOUT
    check(bl_k32_ReleaseMutex_c(m) && bl_k32_ReleaseMutex_c(m), "mutex: released as many times as taken");
    pthread_create(&t, NULL, take_mutex, &m);
    pthread_join(t, &r);
    check((uintptr_t)r == 0, "mutex: another thread takes it once released");
    check(!bl_k32_ReleaseMutex_c(m) && last_error == 288, "mutex: release by a non-owner fails (ERROR_NOT_OWNER)");

    uint32_t name = guest_str("bloodlines-single-instance");
    last_error = 183;  // as a file call might leave it
    uint32_t a = bl_k32_CreateMutexA_c(0, 1, name);
    check(a && last_error == 0, "named mutex: new one clears the last error");
    uint32_t b = bl_k32_CreateMutexA_c(0, 1, name);
    check(b && b != a && last_error == 183, "named mutex: second create opens it (ERROR_ALREADY_EXISTS)");
    check(bl_handle_get(a, BL_H_EVENT) == bl_handle_get(b, BL_H_EVENT), "named mutex: both handles are one object");
    check(!bl_k32_CreateEventA_c(0, 0, 0, name) && last_error == 6, "named object: an event can't take a mutex's name");
}

// Guest printf arguments: 32-bit words in guest memory.
static uint32_t guest_args(int n, const uint32_t *words)
{
    uint32_t g = guest_alloc(4 * (uint32_t)n);
    memcpy(bl_g2h(g), words, 4 * (size_t)n);
    return g;
}

static uint32_t guest_wstr(const char *s)
{
    uint32_t n = (uint32_t)strlen(s), g = guest_alloc(2 * (n + 1));
    uint16_t *w = bl_g2h(g);
    for (uint32_t i = 0; i <= n; i++) w[i] = (uint8_t)s[i];
    return g;
}

static int formats(const char *fmt, const char *want, int n, const uint32_t *words)
{
    char buf[256];
    int r = bl_format(buf, sizeof buf, fmt, guest_args(n, words));
    if (r != (int)strlen(want) || strcmp(buf, want)) printf("     \"%s\" gave \"%s\" (%d)\n", fmt, buf, r);
    return r == (int)strlen(want) && !strcmp(buf, want);
}

static void format(void)
{
    // `*` width and precision of INT_MIN with every flag and I64: the case that ran past
    // the format's spec buffer. The width is cut to 1 MiB; the output stays in the buffer.
    uint32_t big[4] = {0x80000000u, 0x80000000u, 5, 0};
    char buf[80];
    memset(buf, 'X', sizeof buf);
    int r = bl_format(buf, 64, "%-+ #0*.*I64d", guest_args(4, big));
    check(r == 0x100000 && !strncmp(buf, "+5 ", 3) && buf[63] == 0 && buf[64] == 'X',
          "format: INT_MIN * width and precision stay bounded");
    uint32_t big2[4] = {0x7fffffffu, 0x7fffffffu, 1, 0};
    check(bl_format(NULL, 0, "%*.*I64x", guest_args(4, big2)) == 0x100000, "format: INT_MAX * width is cut to 1 MiB");
    check(formats("%-+*.*I64d|", "+042  |", 4, (uint32_t[]){6, 3, 42, 0}), "format: flags, * width and precision, I64");
    check(formats("%*d|", "7   |", 2, (uint32_t[]){(uint32_t)-4, 7}), "format: negative * width left-justifies");
    check(formats("%.*d|", "7|", 2, (uint32_t[]){(uint32_t)-1, 7}), "format: negative * precision is none");
    uint32_t narrow_s = guest_str("abc"), wide_s = guest_wstr("wide");
    check(formats("%hS", "abc", 1, &narrow_s), "format: %hS is a single-byte string");
    check(formats("%S", "wide", 1, &wide_s), "format: %S is wide");
    check(formats("%ls %hs %s", "wide abc abc", 3, (uint32_t[]){wide_s, narrow_s, narrow_s}), "format: %ls wide, %hs and %s narrow");
    check(formats("%5.2s|%-4s|", "   ab|abc |", 2, (uint32_t[]){narrow_s, narrow_s}), "format: string width and precision");
    check(formats("%d %u %x %X %o %c %%", "-3 4294967293 ff FF 10 A %", 6, (uint32_t[]){(uint32_t)-3, (uint32_t)-3, 255, 255, 8, 'A'}),
          "format: integer conversions");
    double d = 3.14159;
    uint32_t dw[2];
    memcpy(dw, &d, 8);
    check(formats("%08.3f %g", "0003.142 3.14159", 4, (uint32_t[]){dw[0], dw[1], dw[0], dw[1]}), "format: doubles");
    check(formats("%I64u %hd", "1099511627776 -1", 3, (uint32_t[]){0, 0x100, 0xffff}), "format: I64u and h");
    check(formats("100%", "100%", 0, NULL), "format: a lone % at the end is copied, not read past");
    check(formats("%0040d", "0000000000000000000000000000000000000001", 1, (uint32_t[]){1}),
          "format: a literal width");
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static uint32_t handle_list(int n, const uint32_t *hs) { return guest_args(n, hs); }

static void *set_later(void *arg)
{
    bl_k32_Sleep_c(30);
    bl_k32_SetEvent_c(*(uint32_t *)arg);
    return NULL;
}

static void *release_later(void *arg)
{
    bl_k32_Sleep_c(30);
    bl_k32_ReleaseSemaphore_c(*(uint32_t *)arg, 1, 0);
    return NULL;
}

static void events(void)
{
    uint32_t e = bl_k32_CreateEventA_c(0, 0, 0, 0);
    check(bl_k32_WaitForSingleObject_c(e, 0) == 0x102, "event: unset event times out");
    bl_k32_SetEvent_c(e);
    check(bl_k32_WaitForSingleObject_c(e, 0) == 0 && bl_k32_WaitForSingleObject_c(e, 0) == 0x102,
          "event: auto-reset event wakes one wait, then resets");
    uint32_t m = bl_k32_CreateEventA_c(0, 1, 1, 0);
    check(bl_k32_WaitForSingleObject_c(m, 0) == 0 && bl_k32_WaitForSingleObject_c(m, 0) == 0, "event: manual event stays set");
    bl_k32_ResetEvent_c(m);
    check(bl_k32_WaitForSingleObject_c(m, 0) == 0x102, "event: ResetEvent clears a manual event");
    double t0 = now_ms();
    uint32_t r = bl_k32_WaitForSingleObject_c(e, 50);
    double dt = now_ms() - t0;
    check(r == 0x102 && dt >= 45 && dt < 1000, "event: a 50 ms wait times out after about 50 ms");
    pthread_t t;
    t0 = now_ms();
    pthread_create(&t, NULL, set_later, &e);
    r = bl_k32_WaitForSingleObject_c(e, 0xffffffffu);
    dt = now_ms() - t0;
    pthread_join(t, NULL);
    check(r == 0 && dt < 1000, "event: SetEvent from another thread wakes an infinite wait");
    check(bl_k32_WaitForSingleObject_c(0x1234, 0) == 0xffffffffu && last_error == 6, "wait: bad handle fails (ERROR_INVALID_HANDLE)");
    t0 = now_ms();
    bl_k32_Sleep_c(20);
    check(now_ms() - t0 >= 19, "Sleep: sleeps at least as long as asked");
}

static void semaphores(void)
{
    check(!bl_k32_CreateSemaphoreA_c(0, 0, 0, 0) && last_error == 87, "semaphore: maximum 0 is refused");
    check(!bl_k32_CreateSemaphoreA_c(0, 3, 2, 0) && last_error == 87, "semaphore: initial above maximum is refused");
    check(!bl_k32_CreateSemaphoreA_c(0, (uint32_t)-1, 2, 0) && last_error == 87, "semaphore: negative initial is refused");
    uint32_t s = bl_k32_CreateSemaphoreA_c(0, 2, 3, 0);
    check(bl_k32_WaitForSingleObject_c(s, 0) == 0 && bl_k32_WaitForSingleObject_c(s, 0) == 0 &&
              bl_k32_WaitForSingleObject_c(s, 0) == 0x102,
          "semaphore: each wait takes one count");
    uint32_t prev = guest_alloc(4);
    *(uint32_t *)bl_g2h(prev) = 0xdeadbeef;
    check(bl_k32_ReleaseSemaphore_c(s, 2, prev) && *(uint32_t *)bl_g2h(prev) == 0, "semaphore: release gives the previous count");
    *(uint32_t *)bl_g2h(prev) = 0xdeadbeef;
    check(!bl_k32_ReleaseSemaphore_c(s, 2, prev) && last_error == 298 && *(uint32_t *)bl_g2h(prev) == 0xdeadbeef,
          "semaphore: release past the maximum fails (ERROR_TOO_MANY_POSTS), count untouched");
    check(!bl_k32_ReleaseSemaphore_c(s, 0, 0) && last_error == 87, "semaphore: release of 0 is refused");
    bl_k32_WaitForSingleObject_c(s, 0), bl_k32_WaitForSingleObject_c(s, 0);
    pthread_t t;
    double t0 = now_ms();
    pthread_create(&t, NULL, release_later, &s);
    uint32_t r = bl_k32_WaitForSingleObject_c(s, 2000);
    pthread_join(t, NULL);
    check(r == 0 && now_ms() - t0 < 1000, "semaphore: a release from another thread wakes a wait");
}

static void waits(void)
{
    uint32_t a = bl_k32_CreateEventA_c(0, 0, 0, 0), b = bl_k32_CreateEventA_c(0, 0, 0, 0);
    uint32_t ab = handle_list(2, (uint32_t[]){a, b});
    check(bl_k32_WaitForMultipleObjects_c(0, ab, 0, 0) == 0xffffffffu && last_error == 87, "wait multiple: no handles is refused");
    check(bl_k32_WaitForMultipleObjects_c(65, ab, 0, 0) == 0xffffffffu && last_error == 87, "wait multiple: 65 handles is refused");
    check(bl_k32_WaitForMultipleObjects_c(2, handle_list(2, (uint32_t[]){a, 0x1234}), 0, 0) == 0xffffffffu && last_error == 6,
          "wait multiple: a bad handle fails (ERROR_INVALID_HANDLE)");
    check(bl_k32_WaitForMultipleObjects_c(2, handle_list(2, (uint32_t[]){a, a}), 1, 0) == 0xffffffffu && last_error == 87,
          "wait all: the same object twice is refused");
    double t0 = now_ms();
    check(bl_k32_WaitForMultipleObjects_c(2, ab, 0, 40) == 0x102 && now_ms() - t0 >= 35, "wait any: times out");
    bl_k32_SetEvent_c(b);
    check(bl_k32_WaitForMultipleObjects_c(2, ab, 0, 0) == 1, "wait any: gives the index of the set object");
    bl_k32_SetEvent_c(a), bl_k32_SetEvent_c(b);
    check(bl_k32_WaitForMultipleObjects_c(2, ab, 0, 0) == 0 && bl_k32_WaitForSingleObject_c(b, 0) == 0,
          "wait any: takes only the lowest set object");
    bl_k32_SetEvent_c(a);
    check(bl_k32_WaitForMultipleObjects_c(2, ab, 1, 20) == 0x102 && bl_k32_WaitForSingleObject_c(a, 0) == 0,
          "wait all: timing out takes nothing");
    pthread_t t;
    bl_k32_SetEvent_c(a);
    t0 = now_ms();
    pthread_create(&t, NULL, set_later, &b);
    uint32_t r = bl_k32_WaitForMultipleObjects_c(2, ab, 1, 2000);
    pthread_join(t, NULL);
    check(r == 0 && now_ms() - t0 < 1000, "wait all: wakes when the last object is set");
    check(bl_k32_WaitForSingleObject_c(a, 0) == 0x102 && bl_k32_WaitForSingleObject_c(b, 0) == 0x102,
          "wait all: takes every object");
    uint32_t s = bl_k32_CreateSemaphoreA_c(0, 1, 1, 0), mx = bl_k32_CreateMutexA_c(0, 1, 0);
    uint32_t smx = handle_list(3, (uint32_t[]){s, mx, a});
    check(bl_k32_WaitForMultipleObjects_c(3, smx, 1, 0) == 0x102 && bl_k32_WaitForSingleObject_c(s, 0) == 0,
          "wait all: a semaphore count is not taken unless all are ready");
    bl_k32_ReleaseSemaphore_c(s, 1, 0);
    bl_k32_SetEvent_c(a);
    check(bl_k32_WaitForMultipleObjects_c(3, smx, 1, 0) == 0, "wait all: an owned mutex, a semaphore and an event");
    check(bl_k32_ReleaseMutex_c(mx) && bl_k32_ReleaseMutex_c(mx) && !bl_k32_ReleaseMutex_c(mx),
          "wait all: the owner took its mutex once more");
}

static void *thread_id_of(void *arg)
{
    uint32_t *ids = arg;
    ids[0] = bl_k32_GetCurrentThreadId_c();
    ids[1] = bl_k32_GetCurrentThreadId_c();
    return NULL;
}

static void threads(void)
{
    uint32_t me = bl_k32_GetCurrentThreadId_c(), other[2];
    pthread_t t;
    pthread_create(&t, NULL, thread_id_of, other);
    pthread_join(t, NULL);
    check(me && me == bl_k32_GetCurrentThreadId_c() && other[0] == other[1] && other[0] != me,
          "thread id: stable in a thread, different between threads");

    // A thread that returns, then one that calls ExitThread: each one's stack and TIB
    // go back to the guest heap, so the next blocks of those sizes are theirs.
    uint32_t main_peb = X86_ReadFsDword(0x30);  // this thread's TIB first, so it can't take theirs
    for (int exit = 0; exit < 2; exit++) {
        uint32_t rec = guest_alloc(20), tid = guest_alloc(4);
        uint32_t *rv = bl_g2h(rec);
        rv[4] = exit ? 42 : 0;
        uint32_t h = bl_k32_CreateThread_c(0, 0, FAKE_THREAD_MAIN, rec, 0, tid);
        check(h && bl_k32_WaitForSingleObject_c(h, 5000) == 0, exit ? "thread: ExitThread ends it" : "thread: returning ends it");
        check(rv[0] == *(uint32_t *)bl_g2h(tid) && rv[0] != me, "thread: CreateThread's id is its GetCurrentThreadId");
        check(main_peb && rv[2] == main_peb, "thread: one PEB for every thread");
        uint32_t tib = bl_guest_malloc(0x1000);
        check(tib == rv[1], "thread: its TIB is freed");
        uint32_t block = bl_guest_malloc((1u << 20) + 0x20000u);
        check(block && block <= rv[3] && rv[3] - block <= 0x20000u, "thread: its stack is freed");
        memset(bl_g2h(block), 1, (1u << 20) + 0x20000u);  // faults if a guard stayed protected
        check(1, "thread: its stack guard is writable again");
        bl_guest_free(block), bl_guest_free(tib);
    }
}

// Guest heap: many sizes at once, none overlapping, all 16-byte aligned, contents kept
// through realloc.
static void heap(void)
{
    enum { N = 3000 };
    static uint32_t addr[N], size[N];
    uint32_t seed = 12345;
    int aligned = 1, kept = 1, fits = 1;
    for (int i = 0; i < N; i++) {
        seed = seed * 1103515245u + 12345u;
        size[i] = i % 100 == 0 ? (seed >> 8) % (1u << 20) : (seed >> 16) % 2000 + 1;
        addr[i] = bl_guest_malloc(size[i]);
        aligned &= addr[i] && addr[i] % 16 == 0;
        fits &= bl_guest_fits(addr[i], size[i]) && !bl_guest_fits(addr[i], size[i] * 2 + 64);
        memset(bl_g2h(addr[i]), i & 0xff, size[i]);
        if (i % 3 == 0 && i > 0) {  // free some as we go so blocks get reused
            bl_guest_free(addr[i - 1]);
            addr[i - 1] = 0;
        }
    }
    for (int i = 0; i < N; i += 2) {
        if (!addr[i]) continue;
        uint32_t n = size[i] + (uint32_t)(i % 7) * 300;
        uint32_t r = bl_guest_realloc(addr[i], n);
        const uint8_t *p = bl_g2h(r);
        for (uint32_t k = 0; k < size[i]; k++) kept &= p[k] == (i & 0xff);
        aligned &= r % 16 == 0;
        addr[i] = r, size[i] = n;
        memset(bl_g2h(r), i & 0xff, n);
    }
    int apart = 1;
    for (int i = 0; i < N; i++) {
        if (!addr[i]) continue;
        const uint8_t *p = bl_g2h(addr[i]);
        for (uint32_t k = 0; k < size[i]; k++) apart &= p[k] == (i & 0xff);
    }
    check(aligned, "heap: blocks are 16-byte aligned");
    check(fits, "heap: a block fits its own size but not twice that");
    check(kept, "heap: realloc keeps the contents");
    check(apart, "heap: no two live blocks overlap");
    uint32_t a = bl_guest_malloc(100);
    check(bl_guest_realloc(a, 100 + 4) == a, "heap: realloc within the block stays in place");
    for (int i = 0; i < N; i++) bl_guest_free(addr[i]);
    bl_guest_free(a);
}

static void mouse(void)
{
    uint32_t out = guest_alloc(4), di, mouse_dev;
    bl_dinput_DirectInput8Create_c(0, 0x800, 0, out, 0);
    di = *(uint32_t *)bl_g2h(out);
    static const uint8_t sys_mouse[16] = {0x60, 0x2B, 0x1D, 0x6F, 0xA0, 0xD5, 0xCF, 0x11,
                                          0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};
    uint32_t guid = guest_alloc(16);
    memcpy(bl_g2h(guid), sys_mouse, 16);
    check(bl_IDirectInput8A_CreateDevice_c(di, guid, out, 0) == 0, "dinput: system mouse created");
    mouse_dev = *(uint32_t *)bl_g2h(out);
    uint32_t state = guest_alloc(16);
    int32_t *axes = bl_g2h(state);

    bl_input_mouse_move(500, -300);  // in a menu: not acquired
    bl_IDirectInputDevice8A_Acquire_c(mouse_dev);
    bl_IDirectInputDevice8A_GetDeviceState_c(mouse_dev, 16, state);
    check(axes[0] == 0 && axes[1] == 0, "dinput: motion while not acquired is not applied on acquire");
    bl_input_mouse_move(7, 3);
    bl_IDirectInputDevice8A_GetDeviceState_c(mouse_dev, 16, state);
    check(axes[0] == 7 && axes[1] == 3, "dinput: motion while acquired is read");
    bl_input_mouse_move(9, 9);
    bl_IDirectInputDevice8A_Unacquire_c(mouse_dev);
    bl_IDirectInputDevice8A_Acquire_c(mouse_dev);
    bl_IDirectInputDevice8A_GetDeviceState_c(mouse_dev, 16, state);
    check(axes[0] == 0 && axes[1] == 0, "dinput: motion unread at unacquire is dropped");
}

static void shader_loops(void)
{
    // vs_2_0: rep i0 { mov oPos, c0 } and loop aL, i1 { mov oPos, c0 }.
    static const uint32_t code[] = {
        0xFFFE0200,
        0x01000026, 0xF0E40000,              // rep i0
        0x02000001, 0xC00F0000, 0xA0E40000,  // mov oPos, c0
        0x00000027,                          // endrep
        0x0200001B, 0xF0E40800, 0xF0E40001,  // loop aL, i1
        0x02000001, 0xC00F0000, 0xA0E40000,  // mov oPos, c0
        0x0000001D,                          // endloop
        0x0000FFFF,
    };
    char err[256] = "";
    char *msl = d3d_shader_msl(code, NULL, err, sizeof err);
    check(msl != NULL, "shader: rep/loop shader translates");
    if (!msl) {
        printf("     %s\n", err);
        return;
    }
    check(strstr(msl, "< int((float4(p.i[0])).x)") != NULL, "shader: rep counts from i0");
    check(strstr(msl, "aL = p.i[1].y;") && strstr(msl, "< p.i[1].x;"), "shader: loop reads i1");
    free(msl);
}

int main(void)
{
    bl_vm_init();
    text();
    format();
    mutexes();
    events();
    semaphores();
    waits();
    threads();
    heap();
    mouse();
    shader_loops();
    printf("%d of %d checks passed\n", checks - failures, checks);
    return failures != 0;
}
