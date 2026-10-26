// The upscaled textures' list (index.txt, written by tools/tex_pack.py) is one line per
// original mipmap: the first 16 hex digits of the SHA-1 of its contents, its width and
// height, and the texture's name. <name>.tex is "BLHR", then u32 format (98, BC7 as
// DXGI numbers it), width, height and mipmap count, then the mipmaps, largest first. The contents hashed are those the game gives a level: DXT blocks as
// they are, 24- and 32-bit pixels as B, G, R, A bytes (A 255 without alpha).
// names.txt (tools/tex_names.py) lists every texture in the game the same way: a texture
// drawn without an upscale is logged by name once and added to build/logs/not_upscaled.txt,
// which tools/tex_extract.py --list exports.
#import "tex_hires.h"

#include <CommonCrypto/CommonDigest.h>
#include <os/lock.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct entry {
    uint64_t key;
    uint32_t w, h;
    char name[256];
};

static struct entry *entries, *names;
static size_t nentries, nnames;
static int loaded;
static char dir[1024];
static NSMapTable<NSString *, id<MTLTexture>> *cache;  // one Metal texture per name while in use

static int by_key(const void *a, const void *b)
{
    uint64_t x = ((const struct entry *)a)->key, y = ((const struct entry *)b)->key;
    return x < y ? -1 : x > y;
}

static size_t read_list(const char *file, struct entry **out)
{
    char list[1100];
    snprintf(list, sizeof list, "%s/%s", dir, file);
    FILE *f = fopen(list, "r");
    if (!f) return 0;
    size_t n = 0, cap = 0;
    struct entry e;
    while (fscanf(f, "%16llx %u %u %255[^\n]", (unsigned long long *)&e.key, &e.w, &e.h, e.name) == 4) {
        if (n == cap) *out = realloc(*out, sizeof **out * (cap = cap ? cap * 2 : 1024));
        (*out)[n++] = e;
    }
    fclose(f);
    qsort(*out, n, sizeof **out, by_key);
    return n;
}

static void load_list(void)
{
    loaded = 1;
    char exe[1024];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) return;
    char *slash = strrchr(exe, '/');
    if (!slash) return;
    *slash = 0;  // build/tests
    snprintf(dir, sizeof dir, "%s/../hires", exe);
    nentries = read_list("index.txt", &entries);
    nnames = read_list("names.txt", &names);
    cache = [NSMapTable strongToWeakObjectsMapTable];
    fprintf(stderr, "[hires] %zu mipmaps of upscaled textures listed in %s, %zu of the game's named\n", nentries,
            dir, nnames);
}

// A game texture drawn without an upscale: logged by name the first time.
static void not_upscaled(uint64_t key, uint32_t w, uint32_t h)
{
    static NSMutableSet *seen;
    struct entry k = {.key = key}, *e = bsearch(&k, names, nnames, sizeof *names, by_key);
    if (!e || e->w != w || e->h != h) return;
    if (!seen) seen = [NSMutableSet set];
    if ([seen containsObject:@(key)]) return;
    [seen addObject:@(key)];
    while (e > names && e[-1].key == key) e--;  // identical textures under several names
    char log[1100];
    snprintf(log, sizeof log, "%s/../logs/not_upscaled.txt", dir);
    FILE *f = fopen(log, "a");
    for (; e < names + nnames && e->key == key; e++) {
        fprintf(stderr, "[hires] %ux%u %s: not upscaled\n", w, h, e->name);
        if (f) fprintf(f, "%s\n", e->name);
    }
    if (f) fclose(f);
}

// SHA-1 of the level's contents as tex_pack.py hashes them; 0 for formats it does not use.
static uint64_t level_key(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch)
{
    CC_SHA1_CTX c;
    CC_SHA1_Init(&c);
    if (format == 0x31545844 || format == 0x33545844 || format == 0x35545844) {  // DXT1, DXT3, DXT5
        uint32_t row = (w + 3) / 4 * (format == 0x31545844 ? 8 : 16);
        for (uint32_t y = 0; y < (h + 3) / 4; y++) CC_SHA1_Update(&c, data + y * pitch, row);
    } else if (format == 20 || format == 21 || format == 22) {  // R8G8B8, A8R8G8B8, X8R8G8B8
        uint32_t bpp = format == 20 ? 3 : 4;
        uint8_t *row = malloc((size_t)w * 4);
        for (uint32_t y = 0; y < h; y++) {
            const uint8_t *s = data + y * pitch;
            for (uint32_t x = 0; x < w; x++) {
                memcpy(row + x * 4, s + x * bpp, 3);
                row[x * 4 + 3] = format == 21 ? s[x * 4 + 3] : 255;
            }
            CC_SHA1_Update(&c, row, w * 4);
        }
        free(row);
    } else
        return 0;
    uint8_t d[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(d, &c);
    uint64_t k = 0;
    for (int i = 0; i < 8; i++) k = k << 8 | d[i];
    return k;
}

static id<MTLTexture> load_texture(id<MTLDevice> dev, const char *name)
{
    char path[1400];
    snprintf(path, sizeof path, "%s/%s.tex", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "[hires] %s is listed but missing\n", path);
        return nil;
    }
    uint32_t h[5];
    if (fread(h, 4, 5, f) != 5 || memcmp(h, "BLHR", 4)) {
        fclose(f);
        fprintf(stderr, "[hires] %s is not an upscaled texture file\n", path);
        return nil;
    }
    uint32_t w = h[2], ht = h[3], mips = h[4];
    if (h[1] != 98) {
        fclose(f);
        fprintf(stderr, "[hires] %s is in an old format: run tools/tex_pack.py --force\n", path);
        return nil;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC7_RGBAUnorm
                                                                                 width:w
                                                                                height:ht
                                                                             mipmapped:mips > 1];
    d.mipmapLevelCount = mips;
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    uint8_t *buf = NULL;
    for (uint32_t l = 0; t && l < mips; l++) {
        uint32_t lw = w >> l ? w >> l : 1, lh = ht >> l ? ht >> l : 1;
        size_t row = (lw + 3) / 4 * 16, rows = (lh + 3) / 4;
        buf = realloc(buf, row * rows);
        if (fread(buf, 1, row * rows, f) != row * rows) {
            fprintf(stderr, "[hires] %s is cut short\n", path);
            t = nil;
            break;
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:l withBytes:buf bytesPerRow:row];
    }
    free(buf);
    fclose(f);
    return t;
}

// Loaded ahead (bl_hires_prefetch), by name, until first asked for: the texture and when
// it was loaded; and the names being loaded.
static NSMutableDictionary<NSString *, NSArray *> *ready;
static NSMutableSet<NSString *> *loading;
static os_unfair_lock ready_lock = OS_UNFAIR_LOCK_INIT;

void bl_hires_prefetch(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch)
{
    if (!loaded) load_list();
    if (!nentries || w < 8 || h < 8 || !data) return;
    if (!ready) ready = [NSMutableDictionary new], loading = [NSMutableSet new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct entry k = {.key = level_key(w, h, format, data, pitch)};
        struct entry *e = k.key ? bsearch(&k, entries, nentries, sizeof *entries, by_key) : NULL;
        if (!e || e->w != w || e->h != h) return;
        NSString *name = @(e->name);
        double now = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_lock(&ready_lock);
        for (NSString *n in ready.allKeys)
            if (now - [ready[n][1] doubleValue] > 120) [ready removeObjectForKey:n];
        int skip = ready[name] || [loading containsObject:name] || [cache objectForKey:name];
        if (!skip) [loading addObject:name];
        os_unfair_lock_unlock(&ready_lock);
        if (skip) return;
        id<MTLTexture> t = load_texture(dev, e->name);
        os_unfair_lock_lock(&ready_lock);
        [loading removeObject:name];
        if (t) ready[name] = @[t, @(now)];
        os_unfair_lock_unlock(&ready_lock);
    });
}

// One loaded ahead for `name`, waiting for it if it is being loaded; nil if none.
static id<MTLTexture> take_ready(NSString *name)
{
    if (!ready) return nil;
    for (;;) {
        os_unfair_lock_lock(&ready_lock);
        id<MTLTexture> t = ready[name][0];
        int busy = !t && [loading containsObject:name];
        if (t) [ready removeObjectForKey:name];
        os_unfair_lock_unlock(&ready_lock);
        if (!busy) return t;
        usleep(200);
    }
}

// The last level hashed (bl_tex_name reuses it).
static const uint8_t *last_data;
static uint32_t last_w, last_h;
static uint64_t last_key;

const char *bl_tex_name(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch)
{
    if (!loaded) load_list();
    if (!nnames || w < 8 || h < 8) return NULL;
    struct entry k = {.key = data == last_data && w == last_w && h == last_h ? last_key
                                                                             : level_key(w, h, format, data, pitch)};
    if (!k.key) return NULL;
    struct entry *e = bsearch(&k, names, nnames, sizeof *names, by_key);
    return e && e->w == w && e->h == h ? e->name : NULL;
}

const char *bl_tex_name_any_thread(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch)
{
    if (!loaded || !nnames || w < 8 || h < 8) return NULL;
    struct entry k = {.key = level_key(w, h, format, data, pitch)};
    struct entry *e = k.key ? bsearch(&k, names, nnames, sizeof *names, by_key) : NULL;
    return e && e->w == w && e->h == h ? e->name : NULL;
}

id<MTLTexture> bl_hires_texture(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data,
                                uint32_t pitch)
{
    if (!loaded) load_list();
    if ((!nentries && !nnames) || w < 8 || h < 8) return nil;
    struct entry k = {.key = level_key(w, h, format, data, pitch)};
    last_data = data, last_w = w, last_h = h, last_key = k.key;
    if (!k.key) return nil;
    struct entry *e = nentries ? bsearch(&k, entries, nentries, sizeof *entries, by_key) : NULL;
    if (!e || e->w != w || e->h != h) {
        not_upscaled(k.key, w, h);
        return nil;
    }
    NSString *name = @(e->name);
    os_unfair_lock_lock(&ready_lock);
    id<MTLTexture> t = [cache objectForKey:name];
    os_unfair_lock_unlock(&ready_lock);
    if (!t && ((t = take_ready(name)) || (t = load_texture(dev, e->name)))) {
        os_unfair_lock_lock(&ready_lock);
        [cache setObject:t forKey:name];
        os_unfair_lock_unlock(&ready_lock);
        fprintf(stderr, "[hires] %ux%u %s: upscaled %lux%lu\n", w, h, e->name, (unsigned long)t.width,
                (unsigned long)t.height);
    }
    return t;
}
