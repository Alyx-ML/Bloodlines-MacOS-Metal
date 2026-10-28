// The movies' list is build/hires/movies/*.sig, each with its .mov beside it. A frame is
// matched by its 8x8 picture: first a little after the frame drawn before, then
// anywhere in that movie, and when that fails (another movie has started) in all of
// them, taking a movie only when one is clearly closer than the rest (the black frames
// most of them start with match every movie). The .mov is read in order, from the start
// again only if Bink goes back.
#import "movie_hires.h"
#import <AVFoundation/AVFoundation.h>
#include <dirent.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SIG 192           // bytes of an 8x8 RGB picture
#define GOOD (SIG * 8)    // the most a match may differ by: 8 in 255 per channel on average
#define AHEAD 16          // frames after the last one looked at first
#define MAX_MOVIES 16

static struct movie {
    char name[256], path[1024];
    uint8_t *sig;
    uint32_t n;
} movies[MAX_MOVIES];
static int nmovies, loaded;

// The movie playing, its reader, the index of the frame it gives next and the frame in
// `tex`.
static int cur = -1;
static AVAssetReader *reader;
static AVAssetReaderTrackOutput *output;
static uint32_t next_idx, shown = UINT32_MAX;
static id<MTLTexture> tex;

static void load(void)
{
    loaded = 1;
    char exe[1024], dir[1100];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) return;
    char *slash = strrchr(exe, '/');
    if (!slash) return;
    *slash = 0;  // build/tests
    snprintf(dir, sizeof dir, "%s/../hires/movies", exe);
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) && nmovies < MAX_MOVIES) {
        size_t len = strlen(e->d_name);
        if (len < 5 || len - 4 >= sizeof movies[0].name || strcmp(e->d_name + len - 4, ".sig")) continue;
        struct movie *m = &movies[nmovies];
        snprintf(m->name, sizeof m->name, "%.*s", (int)(len - 4), e->d_name);
        snprintf(m->path, sizeof m->path, "%s/%s.mov", dir, m->name);
        char path[1400];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        m->n = (uint32_t)(ftell(f) / SIG);
        fseek(f, 0, SEEK_SET);
        m->sig = malloc((size_t)m->n * SIG);
        int ok = m->n && !access(m->path, R_OK) && fread(m->sig, SIG, m->n, f) == m->n;
        fclose(f);
        if (ok) nmovies++;
        else free(m->sig);
    }
    closedir(d);
    fprintf(stderr, "[movies] %d upscaled movies in %s\n", nmovies, dir);
}

// The 8x8 picture of the part r of the frame, as tools/movie_upscale.sh makes them
// (ffmpeg's area scaling: the average of each block), in RGB.
static void signature(uint8_t out[SIG], const uint8_t *px, uint32_t w, uint32_t h, int bottom_up, const uint32_t r[4])
{
    uint32_t rw = r[2] - r[0], rh = r[3] - r[1];
    for (uint32_t by = 0; by < 8; by++)
        for (uint32_t bx = 0; bx < 8; bx++) {
            uint32_t x0 = r[0] + bx * rw / 8, x1 = r[0] + (bx + 1) * rw / 8;
            uint32_t y0 = r[1] + by * rh / 8, y1 = r[1] + (by + 1) * rh / 8;
            uint64_t s[3] = {0}, k = (uint64_t)(x1 - x0) * (y1 - y0);
            for (uint32_t y = y0; y < y1; y++) {
                const uint8_t *row = px + (size_t)(bottom_up ? h - 1 - y : y) * w * 4;
                for (uint32_t x = x0; x < x1; x++) s[0] += row[x * 4 + 2], s[1] += row[x * 4 + 1], s[2] += row[x * 4];
            }
            for (int c = 0; c < 3; c++) out[(by * 8 + bx) * 3 + c] = k ? (uint8_t)((s[c] + k / 2) / k) : 0;
        }
}

// The frame of m in [from, to) most like `sig` (the first of equals), and how far off.
static uint32_t best(const struct movie *m, const uint8_t *sig, uint32_t from, uint32_t to, uint32_t *off)
{
    uint32_t bi = from, bo = UINT32_MAX;
    for (uint32_t i = from; i < to && i < m->n; i++) {
        const uint8_t *a = m->sig + (size_t)i * SIG;
        uint32_t o = 0;
        for (int j = 0; j < SIG; j++) o += (uint32_t)abs(a[j] - sig[j]);
        if (o < bo) bo = o, bi = i;
    }
    *off = bo;
    return bi;
}

static int open_movie(int m)
{
    reader = nil, output = nil, next_idx = 0, shown = UINT32_MAX;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(movies[m].path)] options:nil];
    __block AVAssetTrack *track = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
                   (void)error;
                   track = tracks.firstObject;
                   dispatch_semaphore_signal(done);
                 }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!track) return 0;
    reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
                         outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
    output.alwaysCopiesSampleData = NO;
    if (!reader || ![reader canAddOutput:output]) return reader = nil, 0;
    [reader addOutput:output];
    return [reader startReading];
}

// Frame `idx` of the movie playing, read on from the last.
static id<MTLTexture> frame(id<MTLDevice> dev, uint32_t idx)
{
    if (idx == shown) return tex;
    if ((!reader || idx < next_idx) && !open_movie(cur)) return nil;
    CMSampleBufferRef sb = NULL;
    while (next_idx <= idx) {
        if (sb) CFRelease(sb);
        if (!(sb = [output copyNextSampleBuffer])) return nil;
        next_idx++;
    }
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return CFRelease(sb), nil;
    size_t pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb);
    if (!tex || tex.width != pw || tex.height != ph) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:pw height:ph mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        tex = [dev newTextureWithDescriptor:td];
    }
    // As with Bink's own frames, the GPU has long finished with the last one.
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    [tex replaceRegion:MTLRegionMake2D(0, 0, pw, ph) mipmapLevel:0 withBytes:CVPixelBufferGetBaseAddress(pb)
           bytesPerRow:CVPixelBufferGetBytesPerRow(pb)];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CFRelease(sb);
    shown = idx;
    return tex;
}

id<MTLTexture> bl_movie_frame(id<MTLDevice> dev, const void *pixels, uint32_t w, uint32_t h, int bottom_up,
                              const uint32_t sr[4])
{
    if (!loaded) load();
    if (!nmovies || sr[2] <= sr[0] || sr[3] <= sr[1]) return nil;
    @autoreleasepool {
        uint8_t sig[SIG];
        signature(sig, pixels, w, h, bottom_up, sr);
        int pick = -1;
        uint32_t idx = 0, off;
        if (cur >= 0) {
            uint32_t from = shown == UINT32_MAX ? 0 : shown;
            idx = best(&movies[cur], sig, from, from + AHEAD, &off);
            if (off > GOOD) idx = best(&movies[cur], sig, 0, movies[cur].n, &off);
            if (off <= GOOD) pick = cur;
        }
        if (pick < 0) {
            uint32_t o1 = UINT32_MAX, o2 = UINT32_MAX, i1 = 0;
            int m1 = -1;
            for (int m = 0; m < nmovies; m++) {
                uint32_t i = best(&movies[m], sig, 0, movies[m].n, &off);
                if (off < o1) o2 = o1, o1 = off, m1 = m, i1 = i;
                else if (off < o2) o2 = off;
            }
            if (m1 < 0 || o1 > GOOD || (o2 != UINT32_MAX && o2 <= o1 * 2 + SIG)) return nil;
            pick = m1, idx = i1;
        }
        if (pick != cur) {
            cur = pick, reader = nil, shown = UINT32_MAX;
            fprintf(stderr, "[movies] %s upscaled, from frame %u\n", movies[cur].name, idx);
        }
        return frame(dev, idx);
    }
}
