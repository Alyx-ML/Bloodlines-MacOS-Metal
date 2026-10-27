// Native replacements for routines in the client (see native/modules/README.md).
// Each takes the guest CPU, like bl_vgui.c.
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_vm.h"
#include "llasm_cpu.h"

extern char client_ScreenWide[], client_ScreenTall[];

// The scheme font name for the screen size (client 0x1018C870, cdecl, one argument):
// "<name>_<size>" with the largest size whose 4:3 area fits the screen, as the game
// does. The game's list stops at 1600; Unofficial Patch's trackerscheme.res also has
// fonts for 1920, 2400 and 2880 (bitmap fonts in its materials/fonts), which its
// loader adds the same way. Callers use the answer at once, like the game's one buffer.
void bl_client_FontName_c(_cpu *cpu)
{
    static const int sizes[] = { 640, 800, 1024, 1280, 1600, 1920, 2400, 2880 };
    static uint32_t buf;
    if (!buf) buf = bl_guest_malloc(128);
    const uint32_t *args = REG2PTR(esp + 4);
    int wide = (int)bl_call_guest(cpu, bl_h2g(client_ScreenWide), BL_CDECL, 0, 0, NULL);
    int tall = (int)bl_call_guest(cpu, bl_h2g(client_ScreenTall), BL_CDECL, 0, 0, NULL);
    int size = sizes[0];
    for (unsigned i = 0; i < sizeof sizes / sizeof *sizes && sizes[i] <= wide && sizes[i] * 3 / 4 <= tall; i++)
        size = sizes[i];
    snprintf(bl_g2h(buf), 128, "%s_%d", (const char *)bl_g2h(args[0]), size);
    eax = buf;
}

// Hor+ field of view, in CViewRender::Render (client 0x10191FD5, ebp = the view setup):
// where the game multiplies the field of view by 4/3 when its hidden r_anamorphic is on,
// both fields of view (+0x38 the view's, +0x3c the first-person hands') are widened
// so that a screen wider than 4:3 shows the 4:3 picture's full height and more at the
// sides. The game's projection stays 4:3 and metal_render.m crops its top and bottom to
// the screen's shape, so the result is the 4:3 view's height. The game culls with the
// widened field of view, so nothing at the sides is missing. Every camera passes here
// (the player's, dialogue and cutscenes), as do zooms, which stay in proportion.
//   BL_FOV=<degrees>        the player's usual 4:3 field of view (the game's is 90);
//                           only a view at exactly 90 is changed, so zooms and
//                           dialogue cameras keep theirs
//   BL_WIDESCREEN=stretch   turns this off too, with the projection correction
void bl_client_HorPlus(_cpu *cpu)
{
    static int on = -1;
    static double base;
    if (on < 0) {
        const char *w = getenv("BL_WIDESCREEN"), *f = getenv("BL_FOV");
        on = !(w && !strcmp(w, "stretch"));
        base = f ? atof(f) : 0;
        if (base > 0) base = fmin(fmax(base, 50), 130);
    }
    if (!on) return;
    int wide = (int)bl_call_guest(cpu, bl_h2g(client_ScreenWide), BL_CDECL, 0, 0, NULL);
    int tall = (int)bl_call_guest(cpu, bl_h2g(client_ScreenTall), BL_CDECL, 0, 0, NULL);
    double widen = tall > 0 ? fmax(1.0, (double)wide / tall * 0.75) : 1.0;  // over 4:3
    float *fov = REG2PTR(ebp + 0x38);
    for (int i = 0; i < 2; i++) {
        double deg = fov[i];
        if (i == 0 && base > 0 && deg == 90) deg = base;
        if (deg <= 0 || deg >= 179) continue;
        fov[i] = (float)(2 * atan(tan(deg * M_PI / 360) * widen) * 180 / M_PI);
    }
}

// protean-improved's Filter Load Fix: the Protean filter's level (edi) matching the one
// last set (eax) skips setting the filter (0x1019DA7D), so after loading a save it kept
// the wrong brightness. It is skipped only when the filter's material is already in that
// state. The replacement pushes the filter global (0x10619928); 1 on the stack skips.
void bl_client_FilterSame(_cpu *cpu)
{
    uint32_t filter = *(const uint32_t *)REG2PTR(esp), skip = 0;
    esp += 4;
    if (edi == eax) {
        uint32_t sa = eax, sc = ecx, sd = edx, m = *(const uint32_t *)REG2PTR(*(const uint32_t *)REG2PTR(filter) + 4);
        uint32_t vt = *(const uint32_t *)REG2PTR(m);
        int changed = (uint8_t)bl_call_guest(cpu, *(const uint32_t *)REG2PTR(vt + 4), BL_THISCALL, m, 0, NULL);
        eax = sa, ecx = sc, edx = sd;
        skip = !changed && *(const uint32_t *)REG2PTR(m + 0x2c) == 1;
    }
    esp -= 4;
    *(uint32_t *)REG2PTR(esp) = skip;
}
