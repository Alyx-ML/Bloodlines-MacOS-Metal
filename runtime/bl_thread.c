// Guest threads and Win32 synchronization. Each guest thread is a host thread with
// its own CPU state, guest stack and TIB (bl_loader.c); critical sections, events
// and the Interlocked functions map to pthreads and atomics.
#include <errno.h>
#include <pthread.h>
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

struct waitable {
    pthread_mutex_t m;
    pthread_cond_t c;
    int signaled, manual;
    int sem_count, sem_max;  // semaphores: signaled while sem_count > 0
    int is_sem;
    // threads only
    pthread_t thread;
    int started;
    uint32_t start, param, stack_size, exit_code;
};

static struct waitable *waitable_new(int manual, int signaled)
{
    struct waitable *w = calloc(1, sizeof *w);
    pthread_mutex_init(&w->m, NULL);
    pthread_cond_init(&w->c, NULL);
    w->manual = manual;
    w->signaled = signaled;
    return w;
}

static void waitable_signal(struct waitable *w)
{
    pthread_mutex_lock(&w->m);
    w->signaled = 1;
    pthread_cond_broadcast(&w->c);
    pthread_mutex_unlock(&w->m);
}

static uint32_t waitable_wait(struct waitable *w, uint32_t ms)
{
    struct timespec until;
    if (ms != INFINITE) {
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += ms / 1000;
        until.tv_nsec += (long)(ms % 1000) * 1000000;
        if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    }
    pthread_mutex_lock(&w->m);
    int timed_out = 0;
    while (!w->signaled && !timed_out) {
        if (ms == INFINITE)
            pthread_cond_wait(&w->c, &w->m);
        else
            timed_out = pthread_cond_timedwait(&w->c, &w->m, &until) == ETIMEDOUT;
    }
    uint32_t r = WAIT_TIMEOUT;
    if (w->signaled) {
        if (w->is_sem)
            w->signaled = --w->sem_count > 0;
        else if (!w->manual)
            w->signaled = 0;
        r = WAIT_OBJECT_0;
    }
    pthread_mutex_unlock(&w->m);
    return r;
}

uint32_t bl_k32_CreateEventA_c(uint32_t sec, uint32_t manual, uint32_t initial, uint32_t name)
{
    (void)sec, (void)name;
    return bl_handle_new(BL_H_EVENT, waitable_new(manual != 0, initial != 0));
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
    if (!w) return 0;
    pthread_mutex_lock(&w->m);
    w->signaled = 0;
    pthread_mutex_unlock(&w->m);
    return 1;
}

// Mutexes are auto-reset events that start signaled (not recursive: a thread that
// takes one twice deadlocks, unlike Windows). Semaphores keep a count.
uint32_t bl_k32_CreateMutexA_c(uint32_t sec, uint32_t owned, uint32_t name)
{
    (void)sec, (void)name;
    return bl_handle_new(BL_H_EVENT, waitable_new(0, !owned));
}

uint32_t bl_k32_ReleaseMutex_c(uint32_t h) { return bl_k32_SetEvent_c(h); }

uint32_t bl_k32_CreateSemaphoreA_c(uint32_t sec, uint32_t initial, uint32_t max, uint32_t name)
{
    (void)sec, (void)name;
    struct waitable *w = waitable_new(0, initial > 0);
    w->is_sem = 1;
    w->sem_count = (int)initial;
    w->sem_max = (int)max;
    return bl_handle_new(BL_H_EVENT, w);
}

uint32_t bl_k32_ReleaseSemaphore_c(uint32_t h, uint32_t n, uint32_t prev)
{
    struct waitable *w = bl_handle_get(h, BL_H_EVENT);
    if (!w || !w->is_sem) return 0;
    pthread_mutex_lock(&w->m);
    if (prev) U32(prev) = (uint32_t)w->sem_count;
    if (w->sem_count + (int)n > w->sem_max) {
        pthread_mutex_unlock(&w->m);
        return 0;
    }
    w->sem_count += (int)n;
    w->signaled = w->sem_count > 0;
    pthread_cond_broadcast(&w->c);
    pthread_mutex_unlock(&w->m);
    return 1;
}

// Polls: good enough for the few places that wait on several objects.
uint32_t bl_k32_WaitForMultipleObjects_c(uint32_t n, uint32_t handles, uint32_t all, uint32_t ms)
{
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (;;) {
        uint32_t ready = 0;
        for (uint32_t i = 0; i < n; i++) {
            struct waitable *w = waitable_of(U32(handles + 4 * i));
            if (!w) return 0xffffffffu;
            if (!all && waitable_wait(w, 0) == WAIT_OBJECT_0) return WAIT_OBJECT_0 + i;
            if (all) ready += w->signaled != 0;
        }
        if (all && ready == n) {
            for (uint32_t i = 0; i < n; i++) waitable_wait(waitable_of(U32(handles + 4 * i)), 0);
            return WAIT_OBJECT_0;
        }
        if (ms != INFINITE && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start >= (uint64_t)ms * 1000000) return WAIT_TIMEOUT;
        usleep(1000);
    }
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
    return waitable_wait(w, ms);
}

uint32_t bl_k32_Sleep_c(uint32_t ms)
{
    if (ms == 0)
        sched_yield();
    else
        usleep(ms * 1000u);
    return 0;
}

// --- threads ---------------------------------------------------------------------

static void *thread_main(void *arg)
{
    struct waitable *t = arg;
    void *cpu = bl_cpu_new(t->stack_size);
    uint32_t param = t->param;
    uint32_t code = bl_call_guest(cpu, t->start, BL_STDCALL, 0, 1, &param);
    t->exit_code = code;
    t->manual = 1;  // a finished thread stays signaled
    waitable_signal(t);
    return NULL;
}

static _Thread_local struct waitable *current_thread;

static void *thread_trampoline(void *arg)
{
    current_thread = arg;
    return thread_main(arg);
}

static void thread_start(struct waitable *t)
{
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 8u << 20);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    t->started = 1;
    if (pthread_create(&t->thread, &a, thread_trampoline, t)) bl_fatal("pthread_create failed");
    pthread_attr_destroy(&a);
}

uint32_t bl_k32_CreateThread_c(uint32_t sec, uint32_t stack, uint32_t start, uint32_t param, uint32_t flags,
                               uint32_t tid)
{
    (void)sec;
    struct waitable *t = waitable_new(1, 0);
    t->start = start;
    t->param = param;
    // dwStackSize is the initial commit unless STACK_SIZE_PARAM_IS_A_RESERVATION; the
    // reserve is then the executable's default, 1 MB.
    uint32_t size = (stack + 0xffffu) & ~0xffffu;
    if (!(flags & 0x10000) && size < (1u << 20)) size = 1u << 20;
    t->stack_size = size;
    if (getenv("BL_THREAD_TRACE")) fprintf(stderr, "[thread] start 0x%x stack %u (asked %u)\n", start, size, stack);
    uint32_t h = bl_handle_new(BL_H_THREAD, t);
    if (tid) U32(tid) = h;  // thread ids only need to be unique
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

uint32_t bl_k32_ExitThread_c(uint32_t code)
{
    struct waitable *t = current_thread;
    if (!t) bl_fatal("ExitThread on the main thread");
    t->exit_code = code;
    waitable_signal(t);
    pthread_exit(NULL);
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
