// The Mac's main display as the game sees it: the desktop size (the display's current
// mode in pixels) and the list of video modes offered to Direct3D. Read once.
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>

#include "bl_win32.h"

static uint32_t screen_w = 1024, screen_h = 768;
static uint32_t modes[64][2];
static int nmodes;

static void add_mode(uint32_t w, uint32_t h)
{
    if (w < 640 || h < 480 || w > screen_w || h > screen_h) return;
    for (int i = 0; i < nmodes; i++)
        if (modes[i][0] == w && modes[i][1] == h) return;
    if (nmodes < 64) modes[nmodes][0] = w, modes[nmodes][1] = h, nmodes++;
}

static int by_size(const void *a, const void *b)
{
    const uint32_t *x = a, *y = b;
    return x[0] != y[0] ? (x[0] < y[0] ? -1 : 1) : x[1] < y[1] ? -1 : x[1] > y[1];
}

static void init(void)
{
    static int done;
    if (done) return;
    done = 1;
    CGDirectDisplayID d = CGMainDisplayID();
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    if (cur) {
        screen_w = (uint32_t)CGDisplayModeGetPixelWidth(cur), screen_h = (uint32_t)CGDisplayModeGetPixelHeight(cur);
        add_mode(screen_w, screen_h);                                                          // native pixels
        add_mode((uint32_t)CGDisplayModeGetWidth(cur), (uint32_t)CGDisplayModeGetHeight(cur));  // the "looks like" size
        CGDisplayModeRelease(cur);
    }
    // Every size the display itself offers, Retina and scaled ones included.
    const void *k[] = {kCGDisplayShowDuplicateLowResolutionModes};
    const void *v[] = {kCFBooleanTrue};
    CFDictionaryRef opts = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFArrayRef all = CGDisplayCopyAllDisplayModes(d, opts);
    CFRelease(opts);
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
        add_mode((uint32_t)CGDisplayModeGetPixelWidth(m), (uint32_t)CGDisplayModeGetPixelHeight(m));
        add_mode((uint32_t)CGDisplayModeGetWidth(m), (uint32_t)CGDisplayModeGetHeight(m));
    }
    if (all) CFRelease(all);
    // The usual 4:3, 16:10 and 16:9 sizes that fit.
    static const uint32_t common[][2] = {
        {640, 480},   {800, 600},   {1024, 768},  {1152, 864},  {1280, 720},  {1280, 800},  {1280, 960},
        {1280, 1024}, {1366, 768},  {1440, 900},  {1600, 900},  {1600, 1000}, {1600, 1200}, {1680, 1050},
        {1920, 1080}, {1920, 1200}, {2560, 1440}, {2560, 1600},
    };
    for (size_t i = 0; i < sizeof common / sizeof common[0]; i++) add_mode(common[i][0], common[i][1]);
    qsort(modes, (size_t)nmodes, sizeof modes[0], by_size);
    fprintf(stderr, "[display] desktop %ux%u, %d modes:", screen_w, screen_h, nmodes);
    for (int i = 0; i < nmodes; i++) fprintf(stderr, " %ux%u", modes[i][0], modes[i][1]);
    fprintf(stderr, "\n");
}

void bl_screen_size(uint32_t *w, uint32_t *h)
{
    init();
    *w = screen_w, *h = screen_h;
}

int bl_display_mode(int i, uint32_t *w, uint32_t *h)
{
    init();
    if (i < 0 || i >= nmodes) return 0;
    *w = modes[i][0], *h = modes[i][1];
    return 1;
}

int bl_display_mode_count(void)
{
    init();
    return nmodes;
}
