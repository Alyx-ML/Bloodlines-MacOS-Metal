// Pilot check: the game's zlib1.dll, recompiled to arm64, against macOS's own zlib.
//
// macOS zlib is loaded with dlopen so its symbols never meet the translated ones.
// zlib1.dll is zlib 1.2.1 and macOS ships a newer zlib, so compressed bytes may
// legitimately differ; the checks are checksums, round trips in both directions
// and a streaming inflate that splits with inflateCopy.
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_vm.h"

// Exports are prefixed by module and encoded by gen_extern.py ("_" becomes "__").
#define ENTRY(name, sym) extern void c_##name(void *) __asm__("_c_zlib1_" #sym);
ENTRY(zlibVersion, zlibVersion) ENTRY(adler32, adler32) ENTRY(crc32, crc32)
ENTRY(compressBound, compressBound) ENTRY(compress2, compress2) ENTRY(uncompress, uncompress)
ENTRY(inflateInit_, inflateInit__) ENTRY(inflate, inflate) ENTRY(inflateEnd, inflateEnd)
ENTRY(inflateCopy, inflateCopy)
#undef ENTRY
extern void zlib1_DllEntry(void);  // translated DllMain (fastcc; called by guest address)

typedef unsigned long uLong;
static struct {
    uLong (*adler32)(uLong, const unsigned char *, unsigned);
    uLong (*crc32)(uLong, const unsigned char *, unsigned);
    int (*compress2)(unsigned char *, uLong *, const unsigned char *, uLong, int);
    int (*uncompress)(unsigned char *, uLong *, const unsigned char *, uLong);
    const char *(*zlibVersion)(void);
} sys;

static void *cpu;
static int failures, checks;

static uint32_t G(void (*fn)(void *), int n, ...)
{
    uint32_t args[8];
    va_list ap;
    va_start(ap, n);
    for (int i = 0; i < n; i++) args[i] = va_arg(ap, uint32_t);
    va_end(ap);
    return bl_call_cdecl(cpu, fn, n, args);
}

static void check(int ok, const char *what)
{
    checks++;
    if (!ok) {
        failures++;
        printf("FAIL %s\n", what);
    }
}

static uint32_t guest_copy(const void *src, uint32_t len)
{
    uint32_t g = bl_guest_malloc(len ? len : 1);
    memcpy(bl_g2h(g), src, len);
    return g;
}

static void fill(unsigned char *buf, size_t len, unsigned seed, int texty)
{
    static const char words[] = "the blood of caine runs thin in santa monica tonight ";
    srand(seed);
    for (size_t i = 0; i < len; i++)
        buf[i] = texty ? (unsigned char)words[(i + (size_t)(rand() % 3)) % (sizeof words - 1)] : (unsigned char)rand();
}

static void test_checksums(void)
{
    static const unsigned sizes[] = {0, 1, 7, 64, 1000, 5552, 65539};
    char what[64];
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        unsigned len = sizes[i];
        unsigned char *buf = malloc(len + 1);
        fill(buf, len, len, 0);
        uint32_t g = guest_copy(buf, len);
        snprintf(what, sizeof what, "adler32 len %u", len);
        check(G(c_adler32, 3, 1u, g, len) == (uint32_t)sys.adler32(1, buf, len), what);
        snprintf(what, sizeof what, "crc32 len %u", len);
        check(G(c_crc32, 3, 0u, g, len) == (uint32_t)sys.crc32(0, buf, len), what);
        bl_guest_free(g);
        free(buf);
    }
}

static void test_round_trips(void)
{
    enum { LEN = 200000 };
    unsigned char *src = malloc(LEN), *back = malloc(LEN);
    char what[96];
    int identical = 0;
    for (int texty = 0; texty <= 1; texty++) {
        fill(src, LEN, 42 + texty, texty);
        uint32_t gsrc = guest_copy(src, LEN);
        uint32_t bound = G(c_compressBound, 1, (uint32_t)LEN);
        uint32_t gdst = bl_guest_malloc(bound), glen = bl_guest_malloc(4);
        unsigned char *sysbuf = malloc(bound);
        for (int level = 0; level <= 9; level++) {
            // guest compress -> macOS uncompress
            *(uint32_t *)bl_g2h(glen) = bound;
            snprintf(what, sizeof what, "guest compress2 level %d %s", level, texty ? "text" : "random");
            check(G(c_compress2, 5, gdst, glen, gsrc, (uint32_t)LEN, (uint32_t)level) == 0, what);
            uint32_t clen = *(uint32_t *)bl_g2h(glen);
            uLong outlen = LEN;
            memset(back, 0, LEN);
            snprintf(what, sizeof what, "macOS uncompress of guest level %d %s", level, texty ? "text" : "random");
            check(sys.uncompress(back, &outlen, bl_g2h(gdst), clen) == 0 && outlen == LEN && !memcmp(back, src, LEN), what);

            // macOS compress -> guest uncompress
            uLong slen = bound;
            sys.compress2(sysbuf, &slen, src, LEN, level);
            identical += slen == clen && !memcmp(sysbuf, bl_g2h(gdst), clen);
            uint32_t gin = guest_copy(sysbuf, (uint32_t)slen), gout = bl_guest_malloc(LEN);
            *(uint32_t *)bl_g2h(glen) = LEN;
            snprintf(what, sizeof what, "guest uncompress of macOS level %d %s", level, texty ? "text" : "random");
            check(G(c_uncompress, 4, gout, glen, gin, (uint32_t)slen) == 0 && *(uint32_t *)bl_g2h(glen) == LEN &&
                      !memcmp(bl_g2h(gout), src, LEN), what);
            bl_guest_free(gin);
            bl_guest_free(gout);
        }
        free(sysbuf);
        bl_guest_free(gsrc);
        bl_guest_free(gdst);
        bl_guest_free(glen);
    }
    printf("info: compressed bytes identical to macOS zlib %s in %d of 20 cases\n", sys.zlibVersion(), identical);
    free(src);
    free(back);
}

// z_stream as laid out by 32-bit zlib 1.2.1.
enum { ZS_NEXT_IN = 0, ZS_AVAIL_IN = 4, ZS_NEXT_OUT = 12, ZS_AVAIL_OUT = 16, ZS_SIZE = 56 };
#define ZS(strm, off) (*(uint32_t *)((char *)bl_g2h(strm) + (off)))

static size_t drain(uint32_t strm, uint32_t gchunk, unsigned char *out, size_t have, size_t cap, uint32_t gin, uint32_t inlen, int *ret)
{
    // Feeds 1000-byte input slices from gin and collects output via a 777-byte window.
    for (;;) {
        if (ZS(strm, ZS_AVAIL_IN) == 0) {
            uint32_t used = ZS(strm, ZS_NEXT_IN) - gin;
            if (used >= inlen) return have;
            ZS(strm, ZS_AVAIL_IN) = inlen - used < 1000 ? inlen - used : 1000;
        }
        ZS(strm, ZS_NEXT_OUT) = gchunk;
        ZS(strm, ZS_AVAIL_OUT) = 777;
        *ret = (int)G(c_inflate, 2, strm, 0u);
        size_t got = 777 - ZS(strm, ZS_AVAIL_OUT);
        if (have + got > cap) return (size_t)-1;
        memcpy(out + have, bl_g2h(gchunk), got);
        have += got;
        if (*ret != 0) return have;
    }
}

static void test_streaming_inflate_copy(void)
{
    enum { LEN = 150000 };
    unsigned char *src = malloc(LEN), *a = malloc(LEN), *b = malloc(LEN);
    fill(src, LEN, 7, 1);
    uLong clen = LEN + 1024;
    unsigned char *comp = malloc(clen);
    sys.compress2(comp, &clen, src, LEN, 6);
    uint32_t gin = guest_copy(comp, (uint32_t)clen), gchunk = bl_guest_malloc(777);
    uint32_t ver = guest_copy("1.2.1", 6);
    uint32_t s1 = bl_guest_calloc(1, ZS_SIZE), s2 = bl_guest_calloc(1, ZS_SIZE);

    check(G(c_inflateInit_, 3, s1, ver, (uint32_t)ZS_SIZE) == 0, "inflateInit_");
    ZS(s1, ZS_NEXT_IN) = gin;
    int ret = 0;
    size_t have = drain(s1, gchunk, a, 0, LEN, gin, (uint32_t)clen / 2, &ret);
    check(ret == 0 && have != (size_t)-1, "inflate first half");

    check(G(c_inflateCopy, 2, s2, s1) == 0, "inflateCopy");
    memcpy(b, a, have);
    size_t ha = drain(s1, gchunk, a, have, LEN, gin, (uint32_t)clen, &ret);
    check(ret == 1 && ha == LEN && !memcmp(a, src, LEN), "inflate original stream to Z_STREAM_END");
    size_t hb = drain(s2, gchunk, b, have, LEN, gin, (uint32_t)clen, &ret);
    check(ret == 1 && hb == LEN && !memcmp(b, src, LEN), "inflate copied stream to Z_STREAM_END");
    check(G(c_inflateEnd, 1, s1) == 0 && G(c_inflateEnd, 1, s2) == 0, "inflateEnd both");
    free(src), free(a), free(b), free(comp);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);  // keep output if guest code crashes
    void *z = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!z) bl_fatal("dlopen libz: %s", dlerror());
    *(void **)&sys.adler32 = dlsym(z, "adler32");
    *(void **)&sys.crc32 = dlsym(z, "crc32");
    *(void **)&sys.compress2 = dlsym(z, "compress2");
    *(void **)&sys.uncompress = dlsym(z, "uncompress");
    *(void **)&sys.zlibVersion = dlsym(z, "zlibVersion");

    bl_vm_init();
    cpu = bl_cpu_new(1u << 20);
    // DllMain(hinst, DLL_PROCESS_ATTACH, NULL): runs the CRT startup and _initterm.
    check(bl_call_guest(cpu, bl_h2g((void *)zlib1_DllEntry), BL_STDCALL, 0, 3, (uint32_t[]){0x10000000u, 1, 0}) == 1,
          "DllMain(PROCESS_ATTACH)");
    printf("guest window at 0x%llx\n", (unsigned long long)bl_ptrofs);

    const char *ver = bl_g2h(G(c_zlibVersion, 0));
    printf("guest zlibVersion: %s\n", ver);
    check(strcmp(ver, "1.2.1") == 0, "zlibVersion");

    test_checksums();
    test_round_trips();
    test_streaming_inflate_copy();

    printf("%s: %d/%d checks passed\n", failures ? "FAILED" : "OK", checks - failures, checks);
    return failures != 0;
}
