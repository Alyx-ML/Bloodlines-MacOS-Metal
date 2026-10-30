// Stores the surfaces' PBRify maps ready for the GPU, so the game only reads them:
//   <name>_n.png (+ <name>_r.png)  ->  <name>_n.tex  BC7 (normal xyz, roughness in alpha)
//   <name>_h.png                    ->  <name>_h.tex  R8
// worked out by the renderer's own code (runtime/d3d9/map_levels.m) and, for BC7, encoded by
// tools/bc7_encode.c. The file is "BLPM", then the pixel format (98 BC7, 61 R8), width,
// height and mipmap count as 32-bit numbers, then each mipmap (tex_detail.m, load_baked).
// Built and run by tools/tex_bake_maps.sh:
//   tex_bake_maps [--force] [--only <png>] [<maps folder>]
// A map is baked again when its PNGs are newer than its .tex (or with --force).
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "map_levels.h"

void bc7_encode(const uint8_t *rgba, int w, int h, uint8_t *out);

static double mtime(const char *path)
{
    struct stat st;
    return stat(path, &st) ? -1 : st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec * 1e-9;
}

static long long fsize(const char *path)
{
    struct stat st;
    return stat(path, &st) ? 0 : st.st_size;
}

// One map: 1 baked, 0 up to date, -1 failed. *bytes is the .tex's size.
static int bake(const char *png, int force, long long *bytes)
{
    char out[1600], rough[1600], tmp[1700];
    size_t n = strlen(png);
    if (n < 6 || n + 1 > sizeof out) return -1;
    int normal = !strcmp(png + n - 6, "_n.png");
    memcpy(out, png, n - 4), strcpy(out + n - 4, ".tex");
    memcpy(rough, png, n - 6), strcpy(rough + n - 6, "_r.png");
    double made = mtime(out);
    if (!force && made >= 0 && made >= mtime(png) && (!normal || made >= mtime(rough))) {
        *bytes = fsize(out);
        return 0;
    }
    struct bl_map_levels m;
    if (!(normal ? bl_normal_map_levels(png, &m) : bl_height_map_levels(png, &m))) {
        fprintf(stderr, "%s: not read\n", png);
        return -1;
    }
    snprintf(tmp, sizeof tmp, "%s.tmp", out);
    FILE *f = fopen(tmp, "wb");
    if (!f) {
        bl_map_levels_free(&m);
        fprintf(stderr, "%s: cannot write\n", tmp);
        return -1;
    }
    uint32_t hd[5];
    memcpy(hd, "BLPM", 4);
    hd[1] = normal ? 98 : 61, hd[2] = m.w, hd[3] = m.h, hd[4] = m.count;
    fwrite(hd, 4, 5, f);
    for (uint32_t l = 0; l < m.count; l++) {
        uint32_t lw = m.w >> l ? m.w >> l : 1, lh = m.h >> l ? m.h >> l : 1;
        if (!normal) {
            fwrite(m.level[l], 1, (size_t)lw * lh, f);
            continue;
        }
        // Whole 4x4 blocks: a mipmap under 4 pixels repeats its edge to fill one.
        uint32_t pw = (lw + 3) / 4 * 4, ph = (lh + 3) / 4 * 4;
        uint8_t *px = malloc((size_t)pw * ph * 4), *blocks = malloc((size_t)pw * ph);
        for (uint32_t y = 0; y < ph; y++)
            for (uint32_t x = 0; x < pw; x++)
                memcpy(px + ((size_t)y * pw + x) * 4, m.level[l] + ((size_t)(y < lh ? y : lh - 1) * lw + (x < lw ? x : lw - 1)) * 4, 4);
        bc7_encode(px, (int)pw, (int)ph, blocks);
        fwrite(blocks, 1, (size_t)pw * ph, f);
        free(px), free(blocks);
    }
    bl_map_levels_free(&m);
    *bytes = ftell(f);
    int ok = !ferror(f);
    ok &= !fclose(f);
    if (!ok || rename(tmp, out)) {
        remove(tmp);
        fprintf(stderr, "%s: cannot write\n", out);
        return -1;
    }
    return 1;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        int force = 0;
        const char *only = NULL, *root = NULL;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--force")) force = 1;
            else if (!strcmp(argv[i], "--only") && i + 1 < argc) only = argv[++i];
            else root = argv[i];
        }
        NSMutableArray<NSString *> *pngs = [NSMutableArray array];
        if (only) [pngs addObject:@(only)];
        else {
            if (!root) {
                fprintf(stderr, "usage: tex_bake_maps [--force] [--only <png>] <maps folder>\n");
                return 2;
            }
            NSString *dir = @(root);
            for (NSString *rel in [NSFileManager.defaultManager enumeratorAtPath:dir])
                if ([rel hasSuffix:@"_n.png"] || [rel hasSuffix:@"_h.png"]) [pngs addObject:[dir stringByAppendingPathComponent:rel]];
        }
        NSDate *start = [NSDate date];
        __block long long total = 0;
        __block int baked = 0, fresh = 0, failed = 0;
        NSLock *lock = [NSLock new];
        dispatch_apply(pngs.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            @autoreleasepool {
                long long bytes = 0;
                int r = bake(pngs[i].UTF8String, force, &bytes);
                [lock lock];
                if (r > 0) baked++;
                else if (r == 0) fresh++;
                else failed++;
                total += bytes;
                [lock unlock];
            }
        });
        printf("%d baked, %d up to date, %d failed; %.1f MB of .tex; %.1f s\n", baked, fresh, failed, total / 1048576.0,
               -start.timeIntervalSinceNow);
        return failed ? 1 : 0;
    }
}
