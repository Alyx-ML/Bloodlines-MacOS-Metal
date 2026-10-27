// Runtime checks that need no game files: the Windows text conversion, mutexes and
// named objects (bl_thread.c), DirectInput's mouse motion (dinput8.c) and the shader
// translator's loops (d3d9_shader.c), each from made-up inputs. Built and run by
// tools/runtime_unit.sh against the runtime's own objects; the guest-facing pieces
// those need (guest memory, handles, D3D objects) are small stand-ins here.
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_win32.h"
#include "d3d9_objects.h"
#include "d3d9_shader.h"

static int failures, checks;

static void check(int ok, const char *what)
{
    checks++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

// --- stand-ins ---------------------------------------------------------------------

// Guest memory: a small block, guest addresses from 0x1000.
static _Alignas(16) uint8_t mem[1 << 16];
static uint32_t mem_used;
uint64_t bl_ptrofs;

static uint32_t guest_alloc(uint32_t size)
{
    uint32_t g = 0x1000 + mem_used;
    mem_used += (size + 15) & ~15u;
    if (mem_used > sizeof mem) abort();
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

uint32_t bl_k32_GetCurrentThreadId_c(void)
{
    uint64_t tid;
    pthread_threadid_np(NULL, &tid);
    return (uint32_t)tid;
}

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

// Not reached by these checks (threads running guest code).
void *bl_cpu_new(uint32_t stack_size) { (void)stack_size; abort(); }
uint32_t bl_call_guest(void *cpu, uint32_t fn, enum bl_callconv conv, uint32_t this_ptr, int nargs,
                       const uint32_t *args)
{
    (void)cpu, (void)fn, (void)conv, (void)this_ptr, (void)nargs, (void)args;
    abort();
}
_Noreturn void bl_fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    abort();
}
void bl_guest_backtrace(uint32_t sp) { (void)sp; }
uint32_t bl_vm_esp(void) { return 0; }

// --- the runtime's functions under test --------------------------------------------

uint32_t bl_k32_CreateMutexA_c(uint32_t sec, uint32_t owned, uint32_t name);
uint32_t bl_k32_ReleaseMutex_c(uint32_t h);
uint32_t bl_k32_CreateEventA_c(uint32_t sec, uint32_t manual, uint32_t initial, uint32_t name);
uint32_t bl_k32_WaitForSingleObject_c(uint32_t h, uint32_t ms);
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
    bl_ptrofs = (uint64_t)(uintptr_t)mem - 0x1000;
    text();
    mutexes();
    mouse();
    shader_loops();
    printf("%d of %d checks passed\n", checks - failures, checks);
    return failures != 0;
}
