// Native replacements for the zlib1.dll exports the game calls (see native/modules/README.md):
// the engine's compress2 and uncompress, and MaterialSystem's inflate and deflate streams,
// which unpack the compressed textures as a map loads. Translated, zlib's inflate was a
// sixth of a map's loading time; macOS's zlib does the same work natively.
//
// All are cdecl. A guest z_stream (zlib 1.2.1, 32-bit) is 56 bytes: next_in, avail_in,
// total_in, next_out, avail_out, total_out, msg, state, zalloc, zfree, opaque, data_type,
// adler, reserved. Its `state` holds a slot number here for the native stream behind it,
// whose buffers and counters are copied across on each call. The guest's allocators are
// not used.
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "llasm_cpu.h"
#include "bl_vm.h"

struct guest_stream {
    uint32_t next_in, avail_in, total_in, next_out, avail_out, total_out, msg, state, zalloc, zfree, opaque,
        data_type, adler, reserved;
};
_Static_assert(sizeof(struct guest_stream) == 56, "zlib 1.2.1's z_stream on 32-bit Windows");

struct slot {
    z_stream z;
    int deflating;
    uint32_t msg;  // a guest copy of the native stream's last message
};

static struct slot **slots;
static uint32_t nslots;
static pthread_mutex_t slots_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t slot_new(int deflating)
{
    struct slot *s = calloc(1, sizeof *s);
    s->deflating = deflating;
    pthread_mutex_lock(&slots_lock);
    uint32_t i = 0;
    while (i < nslots && slots[i]) i++;
    if (i == nslots) {
        slots = realloc(slots, sizeof *slots * (nslots + 64));
        memset(slots + nslots, 0, sizeof *slots * 64);
        nslots += 64;
    }
    slots[i] = s;
    pthread_mutex_unlock(&slots_lock);
    return i + 1;
}

static struct slot *slot_of(const struct guest_stream *g, int deflating)
{
    struct slot *s = NULL;
    pthread_mutex_lock(&slots_lock);
    if (g && g->state && g->state <= nslots) s = slots[g->state - 1];
    pthread_mutex_unlock(&slots_lock);
    return s && s->deflating == deflating ? s : NULL;
}

static void slot_free(struct guest_stream *g)
{
    pthread_mutex_lock(&slots_lock);
    free(slots[g->state - 1]);
    slots[g->state - 1] = NULL;
    pthread_mutex_unlock(&slots_lock);
    g->state = 0;
}

// The guest's buffers into the native stream, and back after the call.
static void stream_in(_cpu *cpu, const struct guest_stream *g, z_stream *z)
{
    z->next_in = g->next_in ? REG2PTR(g->next_in) : Z_NULL;
    z->avail_in = g->avail_in;
    z->total_in = g->total_in;
    z->next_out = g->next_out ? REG2PTR(g->next_out) : Z_NULL;
    z->avail_out = g->avail_out;
    z->total_out = g->total_out;
}

static void stream_out(_cpu *cpu, struct guest_stream *g, struct slot *s)
{
    z_stream *z = &s->z;
    if (g->next_in) g->next_in += (uint32_t)(z->next_in - (Bytef *)REG2PTR(g->next_in));
    if (g->next_out) g->next_out += (uint32_t)(z->next_out - (Bytef *)REG2PTR(g->next_out));
    g->avail_in = z->avail_in, g->total_in = (uint32_t)z->total_in;
    g->avail_out = z->avail_out, g->total_out = (uint32_t)z->total_out;
    g->data_type = (uint32_t)z->data_type, g->adler = (uint32_t)z->adler;
    if (z->msg) {
        if (!s->msg) s->msg = bl_guest_calloc(1, 128);
        strlcpy(REG2PTR(s->msg), z->msg, 128);
        g->msg = s->msg;
    } else {
        g->msg = 0;
    }
}

static const uint32_t *args_of(_cpu *cpu) { return REG2PTR(esp + 4); }

// inflateInit_(strm, version, stream_size)
void bl_zlib_inflateInit_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    struct guest_stream *g = a[0] ? REG2PTR(a[0]) : NULL;
    if (!g || a[2] != sizeof *g) {
        eax = (uint32_t)Z_VERSION_ERROR;
        return;
    }
    uint32_t n = slot_new(0);
    struct slot *s = slots[n - 1];
    stream_in(cpu, g, &s->z);
    int r = inflateInit(&s->z);
    if (r != Z_OK) {
        g->state = n;
        slot_free(g);
    } else {
        g->state = n;
        g->total_in = g->total_out = 0, g->msg = 0;
    }
    eax = (uint32_t)r;
}

// inflate(strm, flush)
void bl_zlib_inflate_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    struct guest_stream *g = a[0] ? REG2PTR(a[0]) : NULL;
    struct slot *s = slot_of(g, 0);
    if (!s) {
        eax = (uint32_t)Z_STREAM_ERROR;
        return;
    }
    stream_in(cpu, g, &s->z);
    int r = inflate(&s->z, (int)a[1]);
    stream_out(cpu, g, s);
    eax = (uint32_t)r;
}

// inflateEnd(strm)
void bl_zlib_inflateEnd_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    struct guest_stream *g = a[0] ? REG2PTR(a[0]) : NULL;
    struct slot *s = slot_of(g, 0);
    if (!s) {
        eax = (uint32_t)Z_STREAM_ERROR;
        return;
    }
    int r = inflateEnd(&s->z);
    slot_free(g);
    eax = (uint32_t)r;
}

// deflateInit_(strm, level, version, stream_size)
void bl_zlib_deflateInit_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    struct guest_stream *g = a[0] ? REG2PTR(a[0]) : NULL;
    if (!g || a[3] != sizeof *g) {
        eax = (uint32_t)Z_VERSION_ERROR;
        return;
    }
    uint32_t n = slot_new(1);
    struct slot *s = slots[n - 1];
    stream_in(cpu, g, &s->z);
    int r = deflateInit(&s->z, (int)a[1]);
    g->state = n;
    if (r != Z_OK) slot_free(g);
    else g->total_in = g->total_out = 0, g->msg = 0;
    eax = (uint32_t)r;
}

// deflate(strm, flush)
void bl_zlib_deflate_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    struct guest_stream *g = a[0] ? REG2PTR(a[0]) : NULL;
    struct slot *s = slot_of(g, 1);
    if (!s) {
        eax = (uint32_t)Z_STREAM_ERROR;
        return;
    }
    stream_in(cpu, g, &s->z);
    int r = deflate(&s->z, (int)a[1]);
    stream_out(cpu, g, s);
    eax = (uint32_t)r;
}

// deflateEnd(strm)
void bl_zlib_deflateEnd_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    struct guest_stream *g = a[0] ? REG2PTR(a[0]) : NULL;
    struct slot *s = slot_of(g, 1);
    if (!s) {
        eax = (uint32_t)Z_STREAM_ERROR;
        return;
    }
    int r = deflateEnd(&s->z);
    slot_free(g);
    eax = (uint32_t)r;
}

// compress2(dest, destLen *, source, sourceLen, level)
void bl_zlib_compress2_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    uint32_t *dest_len = REG2PTR(a[1]);
    uLongf n = *dest_len;
    int r = compress2(REG2PTR(a[0]), &n, REG2PTR(a[2]), a[3], (int)a[4]);
    *dest_len = (uint32_t)n;
    eax = (uint32_t)r;
}

// uncompress(dest, destLen *, source, sourceLen)
void bl_zlib_uncompress_c(_cpu *cpu)
{
    const uint32_t *a = args_of(cpu);
    uint32_t *dest_len = REG2PTR(a[1]);
    uLongf n = *dest_len;
    int r = uncompress(REG2PTR(a[0]), &n, REG2PTR(a[2]), a[3]);
    *dest_len = (uint32_t)n;
    eax = (uint32_t)r;
}
