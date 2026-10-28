// Guest threads and Win32 synchronization. Each guest thread is a host thread with
// its own CPU state, guest stack and TIB (bl_loader.c); critical sections, events
// and the Interlocked functions map to pthreads and atomics.
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "bl_win32.h"

#define U32(addr) (*(uint32_t *)bl_g2h(addr))
#define WAIT_OBJECT_0 0
#define WAIT_TIMEOUT 0x102
#define INFINITE 0xffffffffu

// --- critical sections ---------------------------------------------------------
// The host mutex index (+1) lives in the guest CRITICAL_SECTION's LockSemaphore
// field (+16); RecursionCount (+8) and OwningThread (+12) are kept for code that
// reads them.

#define MAX_CS 8192
static pthread_mutex_t cs_mutex[MAX_CS];
static uint8_t cs_used[MAX_CS];
static pthread_mutex_t cs_table_lock = PTHREAD_MUTEX_INITIALIZER;

static pthread_mutex_t *cs_get(uint32_t cs)
{
    uint32_t i = __atomic_load_n((uint32_t *)bl_g2h(cs + 16), __ATOMIC_ACQUIRE);
    if (i) return &cs_mutex[i - 1];
    pthread_mutex_lock(&cs_table_lock);  // never initialized: set it up now
    i = U32(cs + 16);
    if (!i) {
        for (uint32_t k = 0; k < MAX_CS && !i; k++)
            if (!cs_used[k]) {
                pthread_mutexattr_t a;
                pthread_mutexattr_init(&a);
                pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
                pthread_mutex_init(&cs_mutex[k], &a);
                pthread_mutexattr_destroy(&a);
                cs_used[k] = 1;
                i = k + 1;
            }
        if (!i) bl_fatal("too many critical sections");
        __atomic_store_n((uint32_t *)bl_g2h(cs + 16), i, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&cs_table_lock);
    return &cs_mutex[i - 1];
}

uint32_t bl_k32_InitializeCriticalSection_c(uint32_t cs)
{
    memset(bl_g2h(cs), 0, 24);
    cs_get(cs);
    return 0;
}

uint32_t bl_k32_DeleteCriticalSection_c(uint32_t cs)
{
    pthread_mutex_lock(&cs_table_lock);
    uint32_t i = U32(cs + 16);
    if (i) {
        pthread_mutex_destroy(&cs_mutex[i - 1]);
        cs_used[i - 1] = 0;
        U32(cs + 16) = 0;
    }
    pthread_mutex_unlock(&cs_table_lock);
    return 0;
}

uint32_t bl_k32_GetCurrentThreadId_c(void);

uint32_t bl_k32_EnterCriticalSection_c(uint32_t cs)
{
    pthread_mutex_lock(cs_get(cs));
    U32(cs + 8) += 1;
    U32(cs + 12) = bl_k32_GetCurrentThreadId_c();
    return 0;
}

uint32_t bl_k32_LeaveCriticalSection_c(uint32_t cs)
{
    if (--U32(cs + 8) == 0) U32(cs + 12) = 0;
    pthread_mutex_unlock(cs_get(cs));
    return 0;
}

uint32_t bl_k32_InterlockedIncrement_c(uint32_t p)
{
    return __atomic_add_fetch((uint32_t *)bl_g2h(p), 1, __ATOMIC_SEQ_CST);
}

uint32_t bl_k32_InterlockedDecrement_c(uint32_t p)
{
    return __atomic_sub_fetch((uint32_t *)bl_g2h(p), 1, __ATOMIC_SEQ_CST);
}

uint32_t bl_k32_InterlockedExchange_c(uint32_t p, uint32_t v)
{
    return __atomic_exchange_n((uint32_t *)bl_g2h(p), v, __ATOMIC_SEQ_CST);
}

// --- waitable objects ----------------------------------------------------------

// Every waitable's state is guarded by one lock, and every change that can satisfy a
// wait broadcasts one condition: a wait on several objects (and WaitAll, which takes
// them all at once) then sleeps until something changes, never polling.
static pthread_mutex_t wait_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wait_cond = PTHREAD_COND_INITIALIZER;

struct waitable {
    int signaled, manual;
    int sem_count, sem_max;  // semaphores: signaled while sem_count > 0
    int is_sem;
    // mutexes: signaled while no thread owns it; the owner may take it again (depth)
    int is_mutex, depth;
    uint64_t owner;
    // threads only
    pthread_t thread;
    int started;
    uint32_t start, param, stack_size, exit_code, id;
    jmp_buf exit_jb;  // ExitThread jumps back to thread_main through this
};

static struct waitable *waitable_new(int manual, int signaled)
{
    struct waitable *w = calloc(1, sizeof *w);
    w->manual = manual;
    w->signaled = signaled;
    return w;
}

static void waitable_signal(struct waitable *w)
{
    pthread_mutex_lock(&wait_lock);
    w->signaled = 1;
    pthread_cond_broadcast(&wait_cond);
    pthread_mutex_unlock(&wait_lock);
}

static uint64_t self_id(void)
{
    uint64_t tid;
    pthread_threadid_np(NULL, &tid);
    return tid;
}

// Under wait_lock: whether a wait on w would succeed now, and taking it.
static int waitable_ready(const struct waitable *w, uint64_t me)
{
    return w->signaled || (w->is_mutex && w->owner == me);  // its owner takes it again
}

static void waitable_take(struct waitable *w, uint64_t me)
{
    if (w->is_mutex && w->owner == me)
        w->depth++;
    else if (w->is_mutex)
        w->owner = me, w->depth = 1, w->signaled = 0;
    else if (w->is_sem)
        w->signaled = --w->sem_count > 0;
    else if (!w->manual)
        w->signaled = 0;
}

// Waits for one of ws (all of them when `all`) for up to ms milliseconds; the index
// of the object taken (0 for all), or WAIT_TIMEOUT.
static uint32_t wait_objects(uint32_t n, struct waitable *const *ws, int all, uint32_t ms)
{
    struct timespec until;
    if (ms != INFINITE && ms != 0) {
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += ms / 1000;
        until.tv_nsec += (long)(ms % 1000) * 1000000;
        if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    }
    uint64_t me = self_id();
    uint32_t r = WAIT_TIMEOUT;
    int timed_out = 0;
    pthread_mutex_lock(&wait_lock);
    for (;;) {
        if (all) {
            uint32_t ready = 0;
            while (ready < n && waitable_ready(ws[ready], me)) ready++;
            if (ready == n) {
                for (uint32_t i = 0; i < n; i++) waitable_take(ws[i], me);
                r = WAIT_OBJECT_0;
                break;
            }
        } else {
            uint32_t i = 0;
            while (i < n && !waitable_ready(ws[i], me)) i++;
            if (i < n) {
                waitable_take(ws[i], me);
                r = WAIT_OBJECT_0 + i;
                break;
            }
        }
        if (ms == 0 || timed_out) break;  // checked once more after the deadline
        if (ms == INFINITE)
            pthread_cond_wait(&wait_cond, &wait_lock);
        else
            timed_out = pthread_cond_timedwait(&wait_cond, &wait_lock, &until) == ETIMEDOUT;
    }
    pthread_mutex_unlock(&wait_lock);
    return r;
}

static uint32_t waitable_wait(struct waitable *w, uint32_t ms)
{
    return wait_objects(1, &w, 0, ms);
}

// Named events, mutexes and semaphores: creating one with a name already in use opens
// the existing object, with ERROR_ALREADY_EXISTS (single-instance checks read that).
// Objects are never freed (bl_sync_close), so the table holds them for good.
enum { KIND_EVENT, KIND_MUTEX, KIND_SEMAPHORE };
static struct named { char *name; int kind; struct waitable *w; } *named;
static size_t nnamed;
static pthread_mutex_t named_lock = PTHREAD_MUTEX_INITIALIZER;

// The object `name` (guest string, or 0) already has, or what make() returns, as a new
// handle; 0 if the name belongs to another kind of object.
static uint32_t create_named(uint32_t name, int kind, struct waitable *(*make)(void *), void *arg)
{
    if (!name) {
        bl_set_last_error(0);
        return bl_handle_new(BL_H_EVENT, make(arg));
    }
    const char *n = (const char *)bl_g2h(name);
    pthread_mutex_lock(&named_lock);
    for (size_t i = 0; i < nnamed; i++)
        if (!strcmp(named[i].name, n)) {
            struct waitable *w = named[i].kind == kind ? named[i].w : NULL;
            pthread_mutex_unlock(&named_lock);
            if (!w) {
                bl_set_last_error(BL_ERROR_INVALID_HANDLE);
                return 0;
            }
            bl_set_last_error(BL_ERROR_ALREADY_EXISTS);
            return bl_handle_new(BL_H_EVENT, w);
        }
    struct waitable *w = make(arg);
    named = realloc(named, (nnamed + 1) * sizeof *named);
    named[nnamed++] = (struct named){strdup(n), kind, w};
    pthread_mutex_unlock(&named_lock);
    bl_set_last_error(0);
    return bl_handle_new(BL_H_EVENT, w);
}

static struct waitable *make_event(void *arg)
{
    const int *a = arg;  // manual, initial
    return waitable_new(a[0], a[1]);
}

uint32_t bl_k32_CreateEventA_c(uint32_t sec, uint32_t manual, uint32_t initial, uint32_t name)
{
    (void)sec;
    int a[2] = {manual != 0, initial != 0};
    return create_named(name, KIND_EVENT, make_event, a);
}

uint32_t bl_k32_SetEvent_c(uint32_t h)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    if (!w) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    waitable_signal(w);
    return 1;
}

static struct waitable *waitable_of(uint32_t h)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    return w ? w : bl_handle_get(h, BL_H_THREAD);
}

uint32_t bl_k32_ResetEvent_c(uint32_t h)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    if (!w) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    pthread_mutex_lock(&wait_lock);
    w->signaled = 0;
    pthread_mutex_unlock(&wait_lock);
    return 1;
}

// Mutexes are auto-reset events, signaled while free, that remember their owner: it may
// take one again without blocking, and must release it as many times. Semaphores keep a
// count.
static struct waitable *make_mutex(void *arg)
{
    int owned = *(const int *)arg;
    struct waitable *w = waitable_new(0, !owned);
    w->is_mutex = 1;
    if (owned) w->owner = self_id(), w->depth = 1;
    return w;
}

uint32_t bl_k32_CreateMutexA_c(uint32_t sec, uint32_t owned, uint32_t name)
{
    (void)sec;
    int o = owned != 0;  // ignored for an existing named mutex, as on Windows
    return create_named(name, KIND_MUTEX, make_mutex, &o);
}

uint32_t bl_k32_ReleaseMutex_c(uint32_t h)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    if (!w || !w->is_mutex) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    pthread_mutex_lock(&wait_lock);
    if (w->owner != self_id()) {
        pthread_mutex_unlock(&wait_lock);
        bl_set_last_error(288);  // ERROR_NOT_OWNER
        return 0;
    }
    if (--w->depth == 0) {
        w->owner = 0, w->signaled = 1;
        pthread_cond_broadcast(&wait_cond);
    }
    pthread_mutex_unlock(&wait_lock);
    return 1;
}

static struct waitable *make_semaphore(void *arg)
{
    const uint32_t *a = arg;  // initial, max
    struct waitable *w = waitable_new(0, a[0] > 0);
    w->is_sem = 1;
    w->sem_count = (int)a[0];
    w->sem_max = (int)a[1];
    return w;
}

uint32_t bl_k32_CreateSemaphoreA_c(uint32_t sec, uint32_t initial, uint32_t max, uint32_t name)
{
    (void)sec;
    // The counts are LONGs: the maximum must be positive and the initial count in 0..max.
    if ((int32_t)max <= 0 || (int32_t)initial < 0 || (int32_t)initial > (int32_t)max) {
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
        return 0;
    }
    uint32_t a[2] = {initial, max};
    return create_named(name, KIND_SEMAPHORE, make_semaphore, a);
}

// Fails without touching *prev when the count would pass the maximum, as on Windows.
uint32_t bl_k32_ReleaseSemaphore_c(uint32_t h, uint32_t n, uint32_t prev)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    if (!w || !w->is_sem) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    if ((int32_t)n <= 0) {
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
        return 0;
    }
    pthread_mutex_lock(&wait_lock);
    if ((int64_t)w->sem_count + (int32_t)n > w->sem_max) {
        pthread_mutex_unlock(&wait_lock);
        bl_set_last_error(298);  // ERROR_TOO_MANY_POSTS
        return 0;
    }
    if (prev) U32(prev) = (uint32_t)w->sem_count;
    w->sem_count += (int32_t)n;
    w->signaled = 1;
    pthread_cond_broadcast(&wait_cond);
    pthread_mutex_unlock(&wait_lock);
    return 1;
}

#define MAXIMUM_WAIT_OBJECTS 64

uint32_t bl_k32_WaitForMultipleObjects_c(uint32_t n, uint32_t handles, uint32_t all, uint32_t ms)
{
    if (n == 0 || n > MAXIMUM_WAIT_OBJECTS) {
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
        return 0xffffffffu;  // WAIT_FAILED
    }
    struct waitable *ws[MAXIMUM_WAIT_OBJECTS];
    for (uint32_t i = 0; i < n; i++) {
        ws[i] = waitable_of(U32(handles + 4 * i));
        if (!ws[i]) {
            bl_set_last_error(BL_ERROR_INVALID_HANDLE);
            return 0xffffffffu;
        }
        // Waiting for all of one object twice is refused, as on Windows.
        for (uint32_t k = 0; all && k < i; k++)
            if (ws[k] == ws[i]) {
                bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
                return 0xffffffffu;
            }
    }
    return wait_objects(n, ws, all != 0, ms);
}

uint32_t bl_k32_SetThreadPriority_c(uint32_t h, uint32_t prio)
{
    (void)h, (void)prio;
    return 1;
}

uint32_t bl_k32_WaitForSingleObject_c(uint32_t h, uint32_t ms)
{
    struct waitable *w = waitable_of(h);
    if (!w) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0xffffffffu;  // WAIT_FAILED
    }
    // BL_WAIT_TRACE=1: an infinite wait still blocked after 5 s logs the handle and the
    // guest backtrace once, then keeps waiting.
    static int trace = -1;
    if (trace < 0) trace = getenv("BL_WAIT_TRACE") != NULL;
    if (trace && ms == INFINITE && waitable_wait(w, 5000) == WAIT_TIMEOUT) {
        uint32_t bl_vm_esp(void);
        void bl_guest_backtrace(uint32_t sp);
        fprintf(stderr, "[wait] thread %p blocked 5 s on handle 0x%x (%s, signaled %d)\n", (void *)pthread_self(), h,
                w->is_sem ? "semaphore" : w->start ? "thread" : w->manual ? "manual event" : "event", w->signaled);
        bl_guest_backtrace(bl_vm_esp());
        return waitable_wait(w, ms);
    }
    if (trace && ms == INFINITE) return WAIT_OBJECT_0;
    return waitable_wait(w, ms);
}

uint32_t bl_k32_Sleep_c(uint32_t ms)
{
    if (ms == 0) {
        sched_yield();
        return 0;
    }
    if (ms == INFINITE)
        for (;;) pause();  // forever, as on Windows
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000 };
    while (nanosleep(&ts, &ts) && errno == EINTR) {}
    return 0;
}

// --- threads ---------------------------------------------------------------------

// Thread ids: multiples of 4 like Windows', from one counter, so each thread has its
// own while it runs. CreateThread gives the new thread its id; other host threads (the
// main one, Cocoa's) get one when they first ask.
static uint32_t next_thread_id;
static _Thread_local uint32_t thread_id;

static uint32_t new_thread_id(void)
{
    uint32_t id;
    do id = __atomic_add_fetch(&next_thread_id, 4, __ATOMIC_RELAXED);
    while (!id);
    return id;
}

uint32_t bl_k32_GetCurrentThreadId_c(void)
{
    if (!thread_id) thread_id = new_thread_id();
    return thread_id;
}

void bl_crash_thread_init(void);
void bl_crash_thread_done(void);
void bl_thread_tib_free(void);

static _Thread_local struct waitable *current_thread;

static void *thread_main(void *arg)
{
    struct waitable *t = arg;
    current_thread = t;
    thread_id = t->id;
    bl_crash_thread_init();
    void *cpu = bl_cpu_new(t->stack_size);
    uint32_t param = t->param;
    if (!_setjmp(t->exit_jb)) t->exit_code = bl_call_guest(cpu, t->start, BL_STDCALL, 0, 1, &param);
    // Returned, or ExitThread jumped here: the host is off the guest stack, so the
    // thread's TIB, CPU state and stack go back to the guest heap.
    bl_thread_tib_free();
    bl_cpu_free(cpu);
    bl_crash_thread_done();
    waitable_signal(t);  // a finished thread stays signaled (manual)
    return NULL;
}

static void thread_start(struct waitable *t)
{
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 8u << 20);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    t->started = 1;
    if (pthread_create(&t->thread, &a, thread_main, t)) bl_fatal("pthread_create failed");
    pthread_attr_destroy(&a);
}

uint32_t bl_k32_CreateThread_c(uint32_t sec, uint32_t stack, uint32_t start, uint32_t param, uint32_t flags,
                               uint32_t tid)
{
    (void)sec;
    struct waitable *t = waitable_new(1, 0);
    t->start = start;
    t->param = param;
    t->id = new_thread_id();
    // dwStackSize is the initial commit unless STACK_SIZE_PARAM_IS_A_RESERVATION; the
    // reserve is then the executable's default, 1 MB.
    uint32_t size = (stack + 0xffffu) & ~0xffffu;
    if (!(flags & 0x10000) && size < (1u << 20)) size = 1u << 20;
    t->stack_size = size;
    if (getenv("BL_THREAD_TRACE")) fprintf(stderr, "[thread] start 0x%x stack %u (asked %u)\n", start, size, stack);
    uint32_t h = bl_handle_new(BL_H_THREAD, t);
    if (tid) U32(tid) = t->id;  // what GetCurrentThreadId returns in the new thread
    if (!(flags & 4)) thread_start(t);  // not CREATE_SUSPENDED
    return h;
}

uint32_t bl_k32_ResumeThread_c(uint32_t h)
{
    struct waitable *t = bl_handle_get(h, BL_H_THREAD);
    if (!t) return 0xffffffffu;
    if (t->started) return 0;
    thread_start(t);
    return 1;  // previous suspend count
}

// Unwinds to thread_main, which frees the thread's guest memory: this call runs on the
// guest stack it frees.
uint32_t bl_k32_ExitThread_c(uint32_t code)
{
    struct waitable *t = current_thread;
    if (!t) bl_fatal("ExitThread on the main thread");
    t->exit_code = code;
    _longjmp(t->exit_jb, 1);
}

int bl_sync_close(uint32_t h)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    if (w) {
        bl_handle_free(h);
        return 1;  // the object is kept: another thread may still be waiting on it
    }
    if (bl_handle_get(h, BL_H_THREAD)) {
        bl_handle_free(h);
        return 1;
    }
    return 0;
}
