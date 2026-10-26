// The upscaled textures' list (index.txt, written by tools/tex_pack.py) is one line per
// original mipmap: the first 16 hex digits of the SHA-1 of its contents, its width and
// height, and the texture's name. <name>.tex is "BLHR", then u32 format (the VTF number:
// 13/14/15 DXT1/3/5, 0 for BGRA8), width, height and mipmap count, then the mipmaps,
// largest first. The contents hashed are those the game gives a level: DXT blocks as
// they are, 24- and 32-bit pixels as B, G, R, A bytes (A 255 without alpha).
// names.txt (tools/tex_names.py) lists every texture in the game the same way: a texture
// drawn without an upscale is logged by name once and added to build/logs/not_upscaled.txt,
// which tools/tex_extract.py --list exports.
#import "tex_hires.h"

#include <CommonCrypto/CommonDigest.h>
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
    uint32_t fmt = h[1], w = h[2], ht = h[3], mips = h[4];
    MTLPixelFormat pf = fmt == 13 ? MTLPixelFormatBC1_RGBA : fmt == 14 ? MTLPixelFormatBC2_RGBA
                      : fmt == 15 ? MTLPixelFormatBC3_RGBA : MTLPixelFormatBGRA8Unorm;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:ht
                                                                             mipmapped:mips > 1];
    d.mipmapLevelCount = mips;
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    uint8_t *buf = NULL;
    for (uint32_t l = 0; t && l < mips; l++) {
        uint32_t lw = w >> l ? w >> l : 1, lh = ht >> l ? ht >> l : 1;
        size_t row = fmt == 0 ? lw * 4 : (lw + 3) / 4 * (fmt == 13 ? 8 : 16), rows = fmt == 0 ? lh : (lh + 3) / 4;
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

id<MTLTexture> bl_hires_texture(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data,
                                uint32_t pitch)
{
    if (!loaded) load_list();
    if ((!nentries && !nnames) || w < 8 || h < 8) return nil;
    struct entry k = {.key = level_key(w, h, format, data, pitch)};
    if (!k.key) return nil;
    struct entry *e = nentries ? bsearch(&k, entries, nentries, sizeof *entries, by_key) : NULL;
    if (!e || e->w != w || e->h != h) {
        not_upscaled(k.key, w, h);
        return nil;
    }
    NSString *name = @(e->name);
    id<MTLTexture> t = [cache objectForKey:name];
    if (!t && (t = load_texture(dev, e->name))) {
        [cache setObject:t forKey:name];
        fprintf(stderr, "[hires] %ux%u %s: upscaled %lux%lu\n", w, h, e->name, (unsigned long)t.width,
                (unsigned long)t.height);
    }
    return t;
}
