// The normal maps' list (normals.txt, written by tools/tex_normals.py) is one line per
// texture: width, height, its 8x8 mean colour (192 values, 0..1, rows top to bottom) and
// the map's path; the roughness map beside it (_r.png) goes in the map's alpha. A texture the game loads is matched to the line with the same shape
// whose signature is closest, if close enough; the game may have loaded a smaller mipmap,
// so only the aspect has to agree. BL_TEX_DIR names the folder (default:
// native/build/textures/characters, beside the boot binary's build folder).
#import "tex_detail.h"
#import <ImageIO/ImageIO.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct entry { uint32_t w, h; float sig[192]; char path[512]; };
static struct entry *entries;
static int nentries, loaded;
static char dir[1024];
static NSMutableDictionary<NSString *, id> *cache;

static void load_list(void)
{
    loaded = 1;
    const char *d = getenv("BL_TEX_DIR");
    if (d) snprintf(dir, sizeof dir, "%s", d);
    else {
        char exe[1024];
        uint32_t n = sizeof exe;
        if (_NSGetExecutablePath(exe, &n)) return;
        char *slash = strrchr(exe, '/');
        if (!slash) return;
        *slash = 0;  // build/tests
        snprintf(dir, sizeof dir, "%s/../textures/characters", exe);
    }
    char list[1100];
    snprintf(list, sizeof list, "%s/normals.txt", dir);
    FILE *f = fopen(list, "r");
    if (!f) return;
    int cap = 0;
    for (;;) {
        struct entry e;
        if (fscanf(f, "%u %u", &e.w, &e.h) != 2) break;
        int ok = 1;
        for (int i = 0; i < 192 && ok; i++) ok = fscanf(f, "%f", &e.sig[i]) == 1;
        if (!ok || fscanf(f, " %511[^\n]", e.path) != 1) break;
        if (nentries == cap) entries = realloc(entries, sizeof *entries * (size_t)(cap = cap ? cap * 2 : 256));
        entries[nentries++] = e;
    }
    fclose(f);
    fprintf(stderr, "[detail] %d normal maps listed in %s\n", nentries, dir);
}

// One block of DXT colour (8 bytes) as 16 RGB pixels, 0..255.
static void dxt_block(const uint8_t *b, float out[16][3])
{
    uint32_t c0 = b[0] | b[1] << 8, c1 = b[2] | b[3] << 8;
    float p[4][3];
    for (int k = 0; k < 2; k++) {
        uint32_t c = k ? c1 : c0;
        p[k][0] = (c >> 11 & 31) * 255.0f / 31, p[k][1] = (c >> 5 & 63) * 255.0f / 63, p[k][2] = (c & 31) * 255.0f / 31;
    }
    for (int i = 0; i < 3; i++) {
        if (c0 > c1) p[2][i] = (2 * p[0][i] + p[1][i]) / 3, p[3][i] = (p[0][i] + 2 * p[1][i]) / 3;
        else p[2][i] = (p[0][i] + p[1][i]) / 2, p[3][i] = 0;
    }
    uint32_t bits = b[4] | b[5] << 8 | b[6] << 16 | (uint32_t)b[7] << 24;
    for (int i = 0; i < 16; i++) memcpy(out[i], p[bits >> (2 * i) & 3], sizeof out[i]);
}

// The texture's 8x8 mean colour, as tools/tex_extract.py works it out. 0 if the format
// is not one characters use.
static int signature(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch, float sig[192])
{
    double sum[64][3] = {{0}};
    double n[64] = {0};
    uint32_t cw = w / 8 * 8, ch = h / 8 * 8;
    if (cw < 8 || ch < 8) return 0;
    if (format == 0x31545844 || format == 0x33545844 || format == 0x35545844) {  // DXT1, DXT3, DXT5
        uint32_t size = format == 0x31545844 ? 8 : 16;
        for (uint32_t by = 0; by < (h + 3) / 4; by++)
            for (uint32_t bx = 0; bx < (w + 3) / 4; bx++) {
                float px[16][3];
                dxt_block(data + by * pitch + bx * size + (size - 8), px);
                for (int i = 0; i < 16; i++) {
                    uint32_t x = bx * 4 + (uint32_t)(i & 3), y = by * 4 + (uint32_t)(i >> 2);
                    if (x >= cw || y >= ch) continue;
                    int c = (int)(y * 8 / ch) * 8 + (int)(x * 8 / cw);
                    for (int k = 0; k < 3; k++) sum[c][k] += px[i][k];
                    n[c]++;
                }
            }
    } else if (format == 21 || format == 22 || format == 20) {  // A8R8G8B8, X8R8G8B8, R8G8B8
        uint32_t bpp = format == 20 ? 3 : 4;
        for (uint32_t y = 0; y < ch; y++)
            for (uint32_t x = 0; x < cw; x++) {
                const uint8_t *q = data + y * pitch + x * bpp;
                int c = (int)(y * 8 / ch) * 8 + (int)(x * 8 / cw);
                sum[c][0] += q[2], sum[c][1] += q[1], sum[c][2] += q[0], n[c]++;
            }
    } else
        return 0;
    for (int c = 0; c < 64; c++)
        for (int k = 0; k < 3; k++) sig[c * 3 + k] = n[c] ? (float)(sum[c][k] / n[c] / 255) : 0;
    return 1;
}

// A box blur of n floats `stride` apart, radius r, in place (edges clamped).
static void box(float *v, size_t n, size_t stride, int r, float *tmp)
{
    for (size_t i = 0; i < n; i++) tmp[i] = v[i * stride];
    double sum = 0;
    for (int k = -r; k <= r; k++) sum += tmp[k < 0 ? 0 : (size_t)k >= n ? n - 1 : (size_t)k];
    for (size_t i = 0; i < n; i++) {
        v[i * stride] = (float)(sum / (2 * r + 1));
        long out = (long)i - r, in = (long)i + r + 1;
        sum += tmp[in >= (long)n ? n - 1 : (size_t)in] - tmp[out < 0 ? 0 : (size_t)out];
    }
}

// Keeps only the map's middle detail (creases, pores): its broad slopes, guessed from the
// shading painted into the texture, are the model's shape, which the mesh already has,
// and laid on the mesh's flat triangles they show them; its finest grain (the model
// learnt from stone and brick) makes skin and cloth look like concrete. Half strength.
static void high_pass(uint8_t *px, size_t w, size_t h)
{
    int r = (int)(w > h ? w : h) / 128;
    if (r < 2) r = 2;
    int fine = (int)(w > h ? w : h) / 512;
    if (fine < 1) fine = 1;
    float *xy[2], *sharp[2], *tmp = malloc(sizeof(float) * (w > h ? w : h));
    for (int c = 0; c < 2; c++) {
        float *b = xy[c] = malloc(sizeof(float) * w * h), *f = sharp[c] = malloc(sizeof(float) * w * h);
        for (size_t i = 0; i < w * h; i++) b[i] = px[i * 4 + c] / 127.5f - 1;
        memcpy(f, b, sizeof(float) * w * h);
        for (size_t y = 0; y < h; y++) box(f + y * w, w, 1, fine, tmp);
        for (size_t x = 0; x < w; x++) box(f + x, h, w, fine, tmp);
        for (int pass = 0; pass < 2; pass++) {
            for (size_t y = 0; y < h; y++) box(b + y * w, w, 1, r, tmp);
            for (size_t x = 0; x < w; x++) box(b + x, h, w, r, tmp);
        }
    }
    for (size_t i = 0; i < w * h; i++) {
        float x = (sharp[0][i] - xy[0][i]) * 0.5f, y = (sharp[1][i] - xy[1][i]) * 0.5f;
        float l = x * x + y * y;
        if (l > 0.9f) x *= sqrtf(0.9f / l), y *= sqrtf(0.9f / l), l = 0.9f;
        float z = sqrtf(1 - l);
        px[i * 4] = (uint8_t)lrintf(x * 127.5f + 127.5f);
        px[i * 4 + 1] = (uint8_t)lrintf(y * 127.5f + 127.5f);
        px[i * 4 + 2] = (uint8_t)lrintf(z * 127.5f + 127.5f);
    }
    free(xy[0]), free(xy[1]), free(sharp[0]), free(sharp[1]), free(tmp);
}

// The roughness map beside the normal map (<name>_r.png for <name>_n.png) into px's alpha,
// w x h; 0.6 (between skin and cloth) without one.
static void load_rough(const char *path, uint8_t *px, size_t w, size_t h)
{
    for (size_t i = 0; i < w * h; i++) px[i * 4 + 3] = 153;
    char rp[1600];
    snprintf(rp, sizeof rp, "%s", path);
    char *u = strstr(rp, "_n.png");
    if (!u) return;
    memcpy(u, "_r", 2);
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:rp]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return;
    uint8_t *g = calloc(w * h, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef cg = CGBitmapContextCreate(g, w, h, 8, w, cs, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
    CGContextDrawImage(cg, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGContextRelease(cg), CGColorSpaceRelease(cs), CGImageRelease(img);
    for (size_t i = 0; i < w * h; i++) px[i * 4 + 3] = g[i];
    free(g);
}

static id<MTLTexture> load_map_at(id<MTLDevice> dev, const char *path);
static id<MTLTexture> load_map(id<MTLDevice> dev, const char *rel)
{
    char path[1600];
    snprintf(path, sizeof path, "%s/%s", dir, rel);
    return load_map_at(dev, path);
}

id<MTLTexture> bl_load_normal_map(id<MTLDevice> dev, const char *path) { return load_map_at(dev, path); }

static id<MTLTexture> load_map_at(id<MTLDevice> dev, const char *path)
{
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint8_t *px = calloc(w * h, 4);
    // Raw values: no colour management (the map holds directions, not colours).
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    CGContextRef cg = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGContextSetBlendMode(cg, kCGBlendModeCopy);
    CGContextDrawImage(cg, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGContextRelease(cg), CGColorSpaceRelease(cs), CGImageRelease(img);
    high_pass(px, w, h);
    load_rough(path, px, w, h);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:w height:h mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    free(px);
    // Smaller levels by box filter on the CPU, renormalised as directions.
    uint8_t *prev = NULL;
    size_t pw = w, ph = h;
    for (NSUInteger level = 1; level < t.mipmapLevelCount; level++) {
        size_t lw = pw > 1 ? pw / 2 : 1, lh = ph > 1 ? ph / 2 : 1;
        if (!prev) {
            prev = malloc(pw * ph * 4);
            [t getBytes:prev bytesPerRow:pw * 4 fromRegion:MTLRegionMake2D(0, 0, pw, ph) mipmapLevel:0];
        }
        uint8_t *cur = malloc(lw * lh * 4);
        for (size_t y = 0; y < lh; y++)
            for (size_t x = 0; x < lw; x++) {
                float v[3] = {0, 0, 0}, rough = 0;
                for (int j = 0; j < 4; j++) {
                    size_t sx = x * 2 + (j & 1), sy = y * 2 + (j >> 1);
                    if (sx >= pw) sx = pw - 1;
                    if (sy >= ph) sy = ph - 1;
                    for (int k = 0; k < 3; k++) v[k] += prev[(sy * pw + sx) * 4 + k] / 127.5f - 1;
                    rough += prev[(sy * pw + sx) * 4 + 3];
                }
                float l = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
                for (int k = 0; k < 3; k++) cur[(y * lw + x) * 4 + k] = (uint8_t)lrintf(fminf(fmaxf((l > 0 ? v[k] / l : 0) * 127.5f + 127.5f, 0), 255));
                cur[(y * lw + x) * 4 + 3] = (uint8_t)lrintf(rough / 4);
            }
        [t replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:level withBytes:cur bytesPerRow:lw * 4];
        free(prev);
        prev = cur, pw = lw, ph = lh;
    }
    free(prev);
    return t;
}

// The upscaled colour texture beside the normal map (<name>_u.png for <name>_n.png), its
// bytes as they are (alpha not premultiplied), with box-filtered mipmaps; nil without one.
static id<MTLTexture> load_rgba(id<MTLDevice> dev, const char *path);
static id<MTLTexture> load_color(id<MTLDevice> dev, const char *rel)
{
    char path[1600];
    snprintf(path, sizeof path, "%s/%s", dir, rel);
    char *u = strstr(path, "_n.png");
    if (!u) return nil;
    memcpy(u, "_u", 2);
    return load_rgba(dev, path);
}

// RGBA8 pixels of a PNG (malloc'd), or NULL.
static uint8_t *load_pixels(const char *path, size_t *pw, size_t *ph)
{
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img), row = CGImageGetBytesPerRow(img);
    CGImageAlphaInfo ai = CGImageGetAlphaInfo(img);
    CFDataRef raw = CGImageGetBitsPerPixel(img) == 32 && CGImageGetBitsPerComponent(img) == 8 &&
                            (ai == kCGImageAlphaLast || ai == kCGImageAlphaNoneSkipLast) &&
                            !(CGImageGetBitmapInfo(img) & kCGBitmapByteOrderMask)
                        ? CGDataProviderCopyData(CGImageGetDataProvider(img))
                        : NULL;
    CGImageRelease(img);
    if (!raw) return NULL;
    uint8_t *px = malloc(w * h * 4);
    for (size_t y = 0; y < h; y++) memcpy(px + y * w * 4, CFDataGetBytePtr(raw) + y * row, w * 4);
    CFRelease(raw);
    *pw = w, *ph = h;
    return px;
}

// A mipmapped texture of RGBA8 pixels (which it overwrites with the smaller levels).
static id<MTLTexture> make_rgba(id<MTLDevice> dev, uint8_t *px, size_t w, size_t h)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:w height:h mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    size_t pw = w, ph = h;
    for (NSUInteger level = 0;; level++) {
        [t replaceRegion:MTLRegionMake2D(0, 0, pw, ph) mipmapLevel:level withBytes:px bytesPerRow:pw * 4];
        if (level + 1 >= t.mipmapLevelCount) break;
        size_t lw = pw > 1 ? pw / 2 : 1, lh = ph > 1 ? ph / 2 : 1;
        for (size_t y = 0; y < lh; y++)
            for (size_t x = 0; x < lw; x++)
                for (int k = 0; k < 4; k++) {
                    unsigned v = 0;
                    for (int j = 0; j < 4; j++) {
                        size_t sx = x * 2 + (j & 1), sy = y * 2 + (j >> 1);
                        if (sx >= pw) sx = pw - 1;
                        if (sy >= ph) sy = ph - 1;
                        v += px[(sy * pw + sx) * 4 + k];
                    }
                    px[(y * lw + x) * 4 + k] = (uint8_t)((v + 2) / 4);  // in place: row y reads rows 2y, 2y+1
                }
        pw = lw, ph = lh;
    }
    return t;
}

static id<MTLTexture> load_rgba(id<MTLDevice> dev, const char *path)
{
    size_t w, h;
    uint8_t *px = load_pixels(path, &w, &h);
    if (!px) return nil;
    id<MTLTexture> t = make_rgba(dev, px, w, h);
    free(px);
    return t;
}

// The mean colour of a picture's solid pixels (alpha over 200); 0 without any.
static int solid_mean(const uint8_t *px, size_t n, double mean[3])
{
    double sum[3] = {0};
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (px[i * 4 + 3] > 200) k++, sum[0] += px[i * 4], sum[1] += px[i * 4 + 1], sum[2] += px[i * 4 + 2];
    for (int c = 0; c < 3; c++) mean[c] = k ? sum[c] / (double)k : 0;
    return k > 0;
}

// The game's hair under strips, in their colour: its upscaled texture (path) lifted where
// it is darker than HAIR_BASE_SHADE of the strips' mean colour, to that (keeping some of
// its own variation), and left alone where lighter (the fringe's locks). The game's own
// (Jeanette's pigtail cores and scalp, about a third as bright as the strips) showed as
// black between strips and along their edges.
#define HAIR_BASE_SHADE 0.8
static id<MTLTexture> hair_base_color(id<MTLDevice> dev, const char *path, const char *strips)
{
    size_t w, h, sw, sh;
    uint8_t *px = load_pixels(path, &w, &h), *sp = load_pixels(strips, &sw, &sh);
    double want[3], have[3];
    id<MTLTexture> t = nil;
    if (px && sp && solid_mean(sp, sw * sh, want) && solid_mean(px, w * h, have)) {
        double lum = (have[0] + have[1] + have[2]) / 3;
        size_t lifted = 0;
        for (size_t i = 0; i < w * h; i++) {
            uint8_t *q = px + i * 4;
            double l = (q[0] + q[1] + q[2]) / 3.0, var = lum > 1 ? fmin(l / lum, 1.5) : 1;
            int up = 0;
            for (int c = 0; c < 3; c++) {
                double f = HAIR_BASE_SHADE * want[c] * (0.85 + 0.15 * var);
                if (q[c] < f) q[c] = (uint8_t)fmin(f + 0.5, 255), up = 1;
            }
            lifted += up;
        }
        fprintf(stderr, "[detail] hair under strips: %.0f%% of its texture lifted to the strips' colour\n",
                100.0 * (double)lifted / (double)(w * h));
        t = make_rgba(dev, px, w, h);
    }
    free(px), free(sp);
    return t;
}

// The closest entry to a texture's signature, or -1.
static int best_match(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch, float *err_out)
{
    float sig[192];
    if (!signature(w, h, format, data, pitch, sig)) return -1;
    int best = -1;
    float best_err = 0.01f;  // mean difference per channel, 0..1 (a texture matches itself within 0.003)
    for (int i = 0; i < nentries; i++) {
        struct entry *e = &entries[i];
        if ((uint64_t)e->w * h != (uint64_t)e->h * w || e->w < w) continue;
        float err = 0;
        for (int j = 0; j < 192; j++) err += fabsf(e->sig[j] - sig[j]);
        err /= 192;
        if (err < best_err) best_err = err, best = i;
    }
    *err_out = best_err;
    return best;
}

// Loaded ahead (bl_detail_prefetch), by path, until first asked for: map, colour (or
// NSNull) and when; and the paths being loaded.
static NSMutableDictionary<NSString *, NSArray *> *ready;
static NSMutableSet<NSString *> *loading;
static os_unfair_lock ready_lock = OS_UNFAIR_LOCK_INIT;

void bl_detail_prefetch(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch)
{
    if (!loaded) load_list();
    if (!nentries || !data) return;
    if (!ready) ready = [NSMutableDictionary new], loading = [NSMutableSet new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        float err;
        int best = best_match(w, h, format, data, pitch, &err);
        if (best < 0) return;
        NSString *path = @(entries[best].path);
        double now = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_lock(&ready_lock);
        for (NSString *n in ready.allKeys)
            if (now - [ready[n][2] doubleValue] > 120) [ready removeObjectForKey:n];
        int skip = ready[path] || [loading containsObject:path];
        if (!skip) [loading addObject:path];
        os_unfair_lock_unlock(&ready_lock);
        if (skip) return;
        id<MTLTexture> map = load_map(dev, entries[best].path), col = load_color(dev, entries[best].path);
        os_unfair_lock_lock(&ready_lock);
        [loading removeObject:path];
        ready[path] = @[map ? (id)map : [NSNull null], col ? (id)col : [NSNull null], @(now)];
        os_unfair_lock_unlock(&ready_lock);
    });
}

// What was loaded ahead for `path`, waiting for it if it is being loaded; nil if nothing.
static NSArray *take_ready(const char *path)
{
    if (!ready) return nil;
    NSString *p = @(path);
    for (;;) {
        os_unfair_lock_lock(&ready_lock);
        NSArray *r = ready[p];
        int busy = !r && [loading containsObject:p];
        if (r) [ready removeObjectForKey:p];
        os_unfair_lock_unlock(&ready_lock);
        if (!busy) return r;
        usleep(200);
    }
}

// The cache's entries by texture, size and stamp, with a small table in front of it: draws ask
// for the same few hundred textures every frame, and making the key string each time showed
// in profiles.
static struct { const void *key; uint32_t stamp, w, h; } memo_key[512];
static NSArray *memo_hit[512];
static NSString *cache_key(const void *key, uint32_t stamp, uint32_t w, uint32_t h)
{
    return [NSString stringWithFormat:@"%p/%u/%ux%u", key, stamp, w, h];
}
static NSArray *cache_find(const void *key, uint32_t stamp, uint32_t w, uint32_t h)
{
    unsigned i = (unsigned)(((uintptr_t)key >> 4) ^ ((uintptr_t)key >> 13) ^ stamp * 31u) % 512u;
    if (memo_hit[i] && memo_key[i].key == key && memo_key[i].stamp == stamp && memo_key[i].w == w && memo_key[i].h == h)
        return memo_hit[i];
    NSArray *hit = cache[cache_key(key, stamp, w, h)];
    if (hit) memo_key[i].key = key, memo_key[i].stamp = stamp, memo_key[i].w = w, memo_key[i].h = h, memo_hit[i] = hit;
    return hit;
}

id<MTLTexture> bl_detail_normal(id<MTLDevice> dev, const void *key, uint32_t stamp, uint32_t w, uint32_t h,
                                uint32_t format, const uint8_t *data, uint32_t pitch, id<MTLTexture> *color)
{
    *color = nil;
    if (!loaded) load_list();
    if (!nentries || !data) return nil;
    if (!cache) cache = [NSMutableDictionary new];
    NSArray *hit = cache_find(key, stamp, w, h);
    if (hit) {
        if (hit.count > 1 && hit[1] != [NSNull null]) *color = hit[1];
        return hit[0] == [NSNull null] ? nil : hit[0];
    }
    id<MTLTexture> result = nil;
    const char *name = NULL;
    float best_err;
    int best = best_match(w, h, format, data, pitch, &best_err);
    if (best >= 0) {
        NSArray *r = take_ready(entries[best].path);
        result = r ? (r[0] == [NSNull null] ? nil : r[0]) : load_map(dev, entries[best].path);
        name = entries[best].path;
        *color = r ? (r[1] == [NSNull null] ? nil : r[1]) : load_color(dev, entries[best].path);
        fprintf(stderr, "[detail] %ux%u texture: %s (difference %.4f)%s%s\n", w, h, entries[best].path, best_err,
                *color ? [[NSString stringWithFormat:@", upscaled %lux%lu", (unsigned long)(*color).width,
                                                     (unsigned long)(*color).height] UTF8String]
                       : "",
                r ? ", loaded ahead" : "");
    }
    cache[cache_key(key, stamp, w, h)] = @[result ? (id)result : [NSNull null], *color ? (id)*color : [NSNull null],
                 name ? (id)[NSString stringWithUTF8String:name] : [NSNull null]];
    return result;
}

id<MTLTexture> bl_detail_flat(id<MTLDevice> dev)
{
    static id<MTLTexture> t;
    if (!t) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                        width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        t = [dev newTextureWithDescriptor:td];
        const uint8_t px[4] = {128, 128, 255, 128};  // straight up; roughness 0.5
        [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:px bytesPerRow:4];
    }
    return t;
}

// <name>_hair.bin: "BLHM", version 1, vertex count, index count, anchor count (uint32 each),
// the vertices {position xyz, normal xyz, uv}, the indices (uint32), the anchors (xyz) and
// the rectangle of the game's texture to keep (u0 v0 u1 v1), all little-endian floats; then
// optionally a count (uint32) and that many centres (xyz) of the game's triangles to draw
// under the strips.
const struct bl_hair_mesh *bl_detail_hair(id<MTLDevice> dev, const void *key, uint32_t w, uint32_t h)
{
    static NSMutableDictionary<NSString *, NSValue *> *meshes;
    if (!cache) return NULL;
    NSArray *hit = cache_find(key, 0, w, h);
    if (!hit || hit.count < 3 || hit[2] == [NSNull null]) return NULL;
    NSString *name = hit[2];
    if (!meshes) meshes = [NSMutableDictionary new];
    NSValue *v = meshes[name];
    if (v) return v.pointerValue;
    struct bl_hair_mesh *m = NULL;
    char path[1600];
    snprintf(path, sizeof path, "%s/%s", dir, name.UTF8String);
    char *u = strstr(path, "_n.png");
    if (u) {
        snprintf(u, path + sizeof path - u, "_hair.bin");
        NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
        const uint32_t *hd = d.bytes;
        if (d.length >= 20 && !memcmp(hd, "BLHM", 4) && hd[1] == 1) {
            uint32_t nv = hd[2], ni = hd[3], na = hd[4];
            size_t need = 20 + (size_t)nv * 32 + (size_t)ni * 4 + (size_t)na * 12 + 16;
            uint32_t nb = 0;
            if (d.length >= need + 4) memcpy(&nb, (const uint8_t *)d.bytes + need, 4);
            if (d.length == need || d.length == need + 4 + (size_t)nb * 12) {
                m = calloc(1, sizeof *m);
                m->nverts = nv, m->nidx = ni, m->nanchors = na;
                const uint8_t *p = (const uint8_t *)d.bytes + 20;
                m->verts = memcpy(malloc((size_t)nv * 32 + 1), p, (size_t)nv * 32), p += (size_t)nv * 32;
                m->idx = memcpy(malloc((size_t)ni * 4 + 1), p, (size_t)ni * 4), p += (size_t)ni * 4;
                m->anchors = memcpy(malloc((size_t)na * 12 + 1), p, (size_t)na * 12), p += (size_t)na * 12;
                memcpy(m->keep, p, 16), p += 16;
                if (d.length > need)
                    m->nbase = nb, m->base = memcpy(malloc((size_t)nb * 12 + 1), p + 4, (size_t)nb * 12);
                if (nv) {
                    snprintf(u, path + sizeof path - u, "_hair.png");
                    m->tex = load_rgba(dev, path);
                    char base[1600];
                    snprintf(base, sizeof base, "%.*s_u.png", (int)(u - path), path);
                    if (m->tex) m->base_color = hair_base_color(dev, base, path);
                    if (!m->tex) free(m), m = NULL;
                }
            }
        }
        if (m) fprintf(stderr, "[detail] hair mesh for %s: %u vertices, %u triangles\n", name.UTF8String, m->nverts, m->nidx / 3);
    }
    meshes[name] = [NSValue valueWithPointer:m];
    return m;
}
