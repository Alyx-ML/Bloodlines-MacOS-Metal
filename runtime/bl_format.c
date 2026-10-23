// MSVC printf formatting with the argument list in guest memory, and the printf
// family imports built on it (msvcrt _vsnprintf/sprintf, user32 wvsprintfA).
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_win32.h"
#include "llasm_cpu.h"

struct out {
    char *buf;
    size_t cap, len;
};

static void put(struct out *o, const char *s, size_t n)
{
    if (o->len < o->cap) {
        size_t room = o->cap - o->len;
        memcpy(o->buf + o->len, s, n < room ? n : room);
    }
    o->len += n;
}

static uint32_t arg32(uint32_t *ap)
{
    uint32_t v = *(uint32_t *)bl_g2h(*ap);
    *ap += 4;
    return v;
}

static uint64_t arg64(uint32_t *ap)
{
    uint64_t v;
    memcpy(&v, bl_g2h(*ap), 8);
    *ap += 8;
    return v;
}

int bl_format(char *outbuf, size_t cap, const char *fmt, uint32_t ap)
{
    struct out o = { outbuf, cap, 0 };
    char spec[32], tmp[512];
    while (*fmt) {
        const char *pct = strchr(fmt, '%');
        if (!pct) {
            put(&o, fmt, strlen(fmt));
            break;
        }
        put(&o, fmt, (size_t)(pct - fmt));
        const char *p = pct + 1;
        size_t sl = 0;
        spec[sl++] = '%';
        while (strchr("-+ #0", *p) && sl < 8) spec[sl++] = *p++;
        if (*p == '*') {
            sl += (size_t)snprintf(spec + sl, sizeof spec - sl, "%d", (int32_t)arg32(&ap));
            p++;
        } else {
            while (*p >= '0' && *p <= '9' && sl < 16) spec[sl++] = *p++;
        }
        if (*p == '.') {
            spec[sl++] = *p++;
            if (*p == '*') {
                sl += (size_t)snprintf(spec + sl, sizeof spec - sl, "%d", (int32_t)arg32(&ap));
                p++;
            } else {
                while (*p >= '0' && *p <= '9' && sl < 24) spec[sl++] = *p++;
            }
        }
        int wide = 0, is64 = 0;
        for (;;) {
            if (*p == 'h') { wide = -1; p++; }
            else if (*p == 'l' && p[1] == 'l') { is64 = 1; p += 2; }
            else if (*p == 'l' || *p == 'w') { wide = 1; p++; }
            else if (*p == 'L') p++;
            else if (!strncmp(p, "I64", 3)) { is64 = 1; p += 3; }
            else if (!strncmp(p, "I32", 3)) p += 3;
            else if (*p == 'I') p++;
            else break;
        }
        char conv = *p ? *p++ : 0;
        fmt = p;
        int n = 0;
        switch (conv) {
        case 'd': case 'i': case 'u': case 'o': case 'x': case 'X':
            if (is64) {
                spec[sl++] = 'l', spec[sl++] = 'l', spec[sl++] = conv, spec[sl] = 0;
                uint64_t v = arg64(&ap);
                n = (conv == 'd' || conv == 'i') ? snprintf(tmp, sizeof tmp, spec, (long long)v)
                                                 : snprintf(tmp, sizeof tmp, spec, (unsigned long long)v);
            } else {
                spec[sl++] = conv, spec[sl] = 0;
                uint32_t v = arg32(&ap);
                if (wide < 0) v = (conv == 'd' || conv == 'i') ? (uint32_t)(int16_t)v : (uint16_t)v;
                n = (conv == 'd' || conv == 'i') ? snprintf(tmp, sizeof tmp, spec, (int32_t)v)
                                                 : snprintf(tmp, sizeof tmp, spec, v);
            }
            put(&o, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
            break;
        case 'p':
            n = snprintf(tmp, sizeof tmp, "%08X", arg32(&ap));
            put(&o, tmp, (size_t)n);
            break;
        case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A': {
            uint64_t bits = arg64(&ap);
            double d;
            memcpy(&d, &bits, 8);
            spec[sl++] = conv, spec[sl] = 0;
            n = snprintf(tmp, sizeof tmp, spec, d);
            put(&o, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
            break;
        }
        case 'c': case 'C': {
            uint32_t c = arg32(&ap);
            char ch = (char)(c > 0xff ? '?' : c);  // narrow and wide alike
            spec[sl++] = 'c', spec[sl] = 0;
            n = snprintf(tmp, sizeof tmp, spec, ch);
            put(&o, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
            break;
        }
        case 's': case 'S': {
            uint32_t g = arg32(&ap);
            int is_wide = (conv == 'S') != (wide > 0);
            const char *str = "(null)";
            char *conv_buf = NULL;
            if (g && is_wide) {
                const uint16_t *w = bl_g2h(g);
                size_t len = 0;
                while (w[len]) len++;
                conv_buf = malloc(len + 1);
                for (size_t i = 0; i < len; i++) conv_buf[i] = w[i] > 0xff ? '?' : (char)w[i];
                conv_buf[len] = 0;
                str = conv_buf;
            } else if (g) {
                str = bl_g2h(g);
            }
            spec[sl++] = 's', spec[sl] = 0;
            if (sl == 2) {
                put(&o, str, strlen(str));  // plain %s: no length limit
            } else {
                char *big = NULL;
                n = snprintf(NULL, 0, spec, str);
                big = malloc((size_t)n + 1);
                snprintf(big, (size_t)n + 1, spec, str);
                put(&o, big, (size_t)n);
                free(big);
            }
            free(conv_buf);
            break;
        }
        case 'n': {
            uint32_t g = arg32(&ap);
            if (g) *(int32_t *)bl_g2h(g) = (int32_t)o.len;
            break;
        }
        case '%':
            put(&o, "%", 1);
            break;
        default:  // unknown: copy as is
            put(&o, pct, (size_t)(p - pct));
            break;
        }
    }
    if (cap) outbuf[o.len < cap ? o.len : cap - 1] = 0;
    return (int)o.len;
}

// int _vsnprintf(char *buf, size_t count, const char *fmt, va_list args): -1 when
// the output (without terminator) does not fit; terminated only when it fits.
uint32_t bl_msvcrt_vsnprintf_c(uint32_t buf, uint32_t count, uint32_t fmt, uint32_t args)
{
    char *tmp = malloc((size_t)count + 1);
    int n = bl_format(tmp, (size_t)count + 1, bl_g2h(fmt), args);
    if ((uint32_t)n > count) {
        memcpy(bl_g2h(buf), tmp, count);
        n = -1;
    } else {
        memcpy(bl_g2h(buf), tmp, (size_t)n + (n < (int)count));
    }
    free(tmp);
    return (uint32_t)n;
}

// Varargs follow the named arguments on the guest stack: the thunk calls with esp
// at the return address.
static uint32_t varargs(int named)
{
    _cpu *cpu = bl_thread_cpu;
    return esp + 4 + 4 * named;
}

uint32_t bl_msvcrt_sprintf_c(uint32_t buf, uint32_t fmt)
{
    const char *f = bl_g2h(fmt);
    uint32_t ap = varargs(2);
    int n = bl_format(NULL, 0, f, ap);
    return (uint32_t)bl_format(bl_g2h(buf), (size_t)n + 1, f, ap);
}

// wvsprintfA: output limited to 1024 bytes including the terminator.
uint32_t bl_u32_wvsprintfA_c(uint32_t buf, uint32_t fmt, uint32_t args)
{
    int n = bl_format(bl_g2h(buf), 1024, bl_g2h(fmt), args);
    return (uint32_t)(n > 1023 ? 1023 : n);
}
