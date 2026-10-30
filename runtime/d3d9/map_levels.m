// The normal and height maps' pixels (map_levels.h): decoded, filtered and mipmapped on
// the CPU, for tex_detail.m (characters) and tools/tex_bake_maps.m (surfaces).
#import "map_levels.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void bl_map_box(float *v, size_t n, size_t stride, int r, float *tmp)
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
        for (size_t y = 0; y < h; y++) bl_map_box(f + y * w, w, 1, fine, tmp);
        for (size_t x = 0; x < w; x++) bl_map_box(f + x, h, w, fine, tmp);
        for (int pass = 0; pass < 2; pass++) {
            for (size_t y = 0; y < h; y++) bl_map_box(b + y * w, w, 1, r, tmp);
            for (size_t x = 0; x < w; x++) bl_map_box(b + x, h, w, r, tmp);
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

static void levels_init(struct bl_map_levels *m, size_t w, size_t h, uint32_t bpp)
{
    memset(m, 0, sizeof *m);
    m->w = (uint32_t)w, m->h = (uint32_t)h, m->bpp = bpp;
    for (size_t s = w > h ? w : h; s; s >>= 1) m->count++;
    if (m->count > 16) m->count = 16;
}

void bl_map_levels_free(struct bl_map_levels *m)
{
    for (uint32_t l = 0; l < m->count; l++) free(m->level[l]);
    memset(m, 0, sizeof *m);
}

int bl_normal_map_levels(const char *path, struct bl_map_levels *out)
{
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return 0;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return 0;
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
    levels_init(out, w, h, 4);
    out->level[0] = px;
    // Smaller levels by box filter, renormalised as directions.
    size_t pw = w, ph = h;
    for (uint32_t level = 1; level < out->count; level++) {
        size_t lw = pw > 1 ? pw / 2 : 1, lh = ph > 1 ? ph / 2 : 1;
        const uint8_t *prev = out->level[level - 1];
        uint8_t *cur = out->level[level] = malloc(lw * lh * 4);
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
        pw = lw, ph = lh;
    }
    return 1;
}

int bl_height_map_levels(const char *path, struct bl_map_levels *out)
{
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return 0;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return 0;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint8_t *g = calloc(w * h, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef cg = CGBitmapContextCreate(g, w, h, 8, w, cs, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextDrawImage(cg, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGContextRelease(cg), CGColorSpaceRelease(cs), CGImageRelease(img);
    // The model's heights keep to a narrow band of greys: stretched, every material gets
    // the whole depth.
    size_t hist[256] = {0}, n = w * h, lo = 0, hi = 255, acc = 0;
    for (size_t i = 0; i < n; i++) hist[g[i]]++;
    for (lo = 0, acc = 0; lo < 255 && (acc += hist[lo]) < n / 100; lo++) {}
    for (hi = 255, acc = 0; hi > 0 && (acc += hist[hi]) < n / 100; hi--) {}
    if (hi > lo)
        for (size_t i = 0; i < n; i++) {
            int v = ((int)g[i] - (int)lo) * 255 / (int)(hi - lo);
            g[i] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
    levels_init(out, w, h, 1);
    out->level[0] = g;
    size_t pw = w, ph = h;
    for (uint32_t level = 1; level < out->count; level++) {
        size_t lw = pw > 1 ? pw / 2 : 1, lh = ph > 1 ? ph / 2 : 1;
        const uint8_t *prev = out->level[level - 1];
        uint8_t *cur = out->level[level] = malloc(lw * lh);
        for (size_t y = 0; y < lh; y++)
            for (size_t x = 0; x < lw; x++) {
                unsigned v = 0;
                for (int j = 0; j < 4; j++) {
                    size_t sx = x * 2 + (j & 1), sy = y * 2 + (j >> 1);
                    v += prev[(sy < ph ? sy : ph - 1) * pw + (sx < pw ? sx : pw - 1)];
                }
                cur[y * lw + x] = (uint8_t)((v + 2) / 4);
            }
        pw = lw, ph = lh;
    }
    return 1;
}
