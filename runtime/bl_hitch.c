// BL_HITCH_STACKS=ms: when a frame of the game's thread runs longer than ms, its call stack
// is sampled every 2 ms until the frame ends, and the samples are printed, alike ones
// together (for the hitches BL_HITCH reports that are not shaders or textures). The thread
// is the one presenting (bl_hitch_frame); its stack is walked by frame pointers while it is
// suspended, so nothing that could take a lock it holds runs then. Functions without an
// exported name print as image+offset, for atos.
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DEPTH 24
#define SAMPLES 64

static thread_act_t target;
static uintptr_t stack_lo, stack_hi;
static double limit_ms;
static _Atomic uint64_t frame_start;
static _Atomic unsigned long frame_no;
static uintptr_t samples[SAMPLES][DEPTH];
static int depths[SAMPLES];
static double when[SAMPLES];

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int take(uintptr_t *pcs)
{
    if (thread_suspend(target) != KERN_SUCCESS) return 0;
    arm_thread_state64_t st;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    int d = 0;
    if (thread_get_state(target, ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS) {
        pcs[d++] = arm_thread_state64_get_pc(st);
        uintptr_t fp = arm_thread_state64_get_fp(st);
        while (d < DEPTH && fp >= stack_lo && fp + 16 <= stack_hi && !(fp & 7)) {
            uintptr_t next = ((const uintptr_t *)fp)[0], ret = ((const uintptr_t *)fp)[1];
            if (!ret) break;
            pcs[d++] = ret;
            if (next <= fp) break;
            fp = next;
        }
    }
    thread_resume(target);
    return d;
}

static void name(uintptr_t pc, char *out, size_t len)
{
    Dl_info di;
    if (dladdr((const void *)pc, &di) && di.dli_sname)
        snprintf(out, len, "%s+%lu", di.dli_sname, (unsigned long)(pc - (uintptr_t)di.dli_saddr));
    else if (di.dli_fname) {
        const char *base = strrchr(di.dli_fname, '/');
        snprintf(out, len, "%s+0x%lx", base ? base + 1 : di.dli_fname, (unsigned long)(pc - (uintptr_t)di.dli_fbase));
    } else
        snprintf(out, len, "0x%lx", (unsigned long)pc);
}

static void print(unsigned long frame, int n)
{
    int done[SAMPLES] = {0};
    for (int i = 0; i < n; i++) {
        if (done[i]) continue;
        int count = 1;
        for (int j = i + 1; j < n; j++)
            if (!done[j] && depths[j] == depths[i] && !memcmp(samples[j], samples[i], sizeof(uintptr_t) * (size_t)depths[i]))
                done[j] = 1, count++;
        fprintf(stderr, "[hitch-stack] frame %lu, %d of %d samples, first at %.0f ms:", frame, count, n, when[i]);
        for (int k = 0; k < depths[i]; k++) {
            char s[256];
            name(samples[i][k], s, sizeof s);
            fprintf(stderr, " %s", s);
        }
        fprintf(stderr, "\n");
    }
}

static void *watch(void *arg)
{
    (void)arg;
    unsigned long seen = 0;
    int n = 0;
    for (;;) {
        usleep(2000);
        unsigned long f = frame_no;
        uint64_t s = frame_start;
        if (f != seen) {
            if (n) print(seen, n);
            seen = f, n = 0;
        }
        if (n < SAMPLES && (now_ns() - s) / 1e6 > limit_ms) {
            when[n] = (now_ns() - s) / 1e6;
            depths[n] = take(samples[n]);
            n++;
        }
    }
    return NULL;
}

// Each frame's end on the game's thread: the next frame starts.
void bl_hitch_frame(unsigned long frame)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("BL_HITCH_STACKS");
        on = e && atof(e) > 0;
        if (on) {
            limit_ms = atof(e);
            target = mach_thread_self();
            pthread_t self = pthread_self();
            stack_hi = (uintptr_t)pthread_get_stackaddr_np(self);
            stack_lo = stack_hi - pthread_get_stacksize_np(self);
            frame_start = now_ns(), frame_no = frame;
            pthread_t t;
            pthread_create(&t, NULL, watch, NULL);
            pthread_detach(t);
        }
    }
    if (!on) return;
    frame_start = now_ns();
    frame_no = frame + 1;
}
