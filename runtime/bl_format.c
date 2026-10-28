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

// Formats one conversion with the host printf; output of any length.
static void emit(struct out *o, const char *spec, ...)
{
    char tmp[512];
    va_list ap, ap2;
    va_start(ap, spec);
    va_copy(ap2, ap);
    int n = vsnprintf(tmp, sizeof tmp, spec, ap);
    if (n >= (int)sizeof tmp) {
        char *big = malloc((size_t)n + 1);
        vsnprintf(big, (size_t)n + 1, spec, ap2);
        put(o, big, (size_t)n);
        free(big);
    } else if (n > 0) {
        put(o, tmp, (size_t)n);
    }
    va_end(ap2);
    va_end(ap);
}

// Widths and precisions past this are cut to it: far beyond any real format, and it
// keeps INT_MIN and other huge `*` values from overflowing the host printf.
#define MAX_FIELD 0x100000

static int clamp_field(int64_t v)
{
    return v > MAX_FIELD ? MAX_FIELD : v < -MAX_FIELD ? -MAX_FIELD : (int)v;
}

// A literal width or precision: digits, saturating.
static int64_t digits(const char **pp)
{
    int64_t v = 0;
    for (; **pp >= '0' && **pp <= '9'; (*pp)++)
        if (v <= MAX_FIELD) v = v * 10 + (**pp - '0');
    return v;
}

int bl_format(char *outbuf, size_t cap, const char *fmt, uint32_t ap)
{
    struct out o = { outbuf, cap, 0 };
    // The host spec is '%', the flags (each once), "*.*", an optional "ll" and the
    // conversion: width and precision go as int arguments, so it stays short.
    char spec[16];
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
        for (; *p && strchr("-+ #0", *p); p++)
            if (!memchr(spec + 1, *p, sl - 1)) spec[sl++] = *p;
        int has_width = 0;
        int64_t width = 0, prec = -1;  // a negative precision is the same as none
        if (*p == '*') {
            width = (int32_t)arg32(&ap), has_width = 1;  // negative: left-justified
            p++;
        } else if (*p >= '0' && *p <= '9') {
            width = digits(&p), has_width = 1;
        }
        if (*p == '.') {
            p++;
            if (*p == '*') {
                prec = (int32_t)arg32(&ap);
                p++;
            } else {
                prec = digits(&p);
            }
        }
        int w = clamp_field(width), pr = clamp_field(prec);
        spec[sl++] = '*', spec[sl++] = '.', spec[sl++] = '*';
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
        switch (conv) {
        case 'd': case 'i': case 'u': case 'o': case 'x': case 'X':
            if (is64) {
                spec[sl++] = 'l', spec[sl++] = 'l', spec[sl++] = conv, spec[sl] = 0;
                uint64_t v = arg64(&ap);
                if (conv == 'd' || conv == 'i')
                    emit(&o, spec, w, pr, (long long)v);
                else
                    emit(&o, spec, w, pr, (unsigned long long)v);
            } else {
                spec[sl++] = conv, spec[sl] = 0;
                uint32_t v = arg32(&ap);
                if (wide < 0) v = (conv == 'd' || conv == 'i') ? (uint32_t)(int16_t)v : (uint16_t)v;
                if (conv == 'd' || conv == 'i')
                    emit(&o, spec, w, pr, (int32_t)v);
                else
                    emit(&o, spec, w, pr, v);
            }
            break;
        case 'p':
            emit(&o, "%08X", arg32(&ap));
            break;
        case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A': {
            uint64_t bits = arg64(&ap);
            double d;
            memcpy(&d, &bits, 8);
            spec[sl++] = conv, spec[sl] = 0;
            emit(&o, spec, w, pr, d);
            break;
        }
        case 'c': case 'C': {
            uint32_t c = arg32(&ap);
            char ch = (char)(c > 0xff ? '?' : c);  // narrow and wide alike
            spec[sl++] = 'c', spec[sl] = 0;
            emit(&o, spec, w, pr, ch);
            break;
        }
        case 's': case 'S': {
            uint32_t g = arg32(&ap);
            // MSVC: h makes it narrow and l/w wide; without one, %s is narrow and %S wide.
            int is_wide = wide ? wide > 0 : conv == 'S';
            const char *str = "(null)";
            char *conv_buf = NULL;
            if (g && is_wide) {
                const uint16_t *ws = bl_g2h(g);
                size_t len = 0;
                while (ws[len]) len++;
                conv_buf = malloc(len + 1);
                for (size_t i = 0; i < len; i++) conv_buf[i] = ws[i] > 0xff ? '?' : (char)ws[i];
                conv_buf[len] = 0;
                str = conv_buf;
            } else if (g) {
                str = bl_g2h(g);
            }
            spec[sl++] = 's', spec[sl] = 0;
            if (sl == 5 && !has_width && prec < 0)
                put(&o, str, strlen(str));  // plain %s
            else
                emit(&o, spec, w, pr, str);
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
