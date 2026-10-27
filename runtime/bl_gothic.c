// Drawing for the gothic menus; see bl_gothic.h.
//
// Cinzel and Cormorant Garamond (SIL Open Font License, native/assets/fonts; Cormorant cut
// to its Medium weight) are registered with Core Text, which draws the game's GDI fonts
// (bl_gdi.c), and reach vgui through the surface's CreateFont/AddGlyphSetToFont like any
// scheme font.
#include "bl_gothic.h"

#include <CoreText/CoreText.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "bl_vm.h"

// The surface's methods (vtable offsets in this vgui, checked against the client's calls).
enum {
    S_SET_COLOR = 0x2c, S_FILLED_RECT = 0x30, S_TEXT_FONT = 0x44, S_TEXT_COLOR = 0x4c,
    S_TEXT_POS = 0x50, S_PRINT_TEXT = 0x54, S_SCREEN_SIZE = 0x9c, S_CREATE_FONT = 0xf4,
    S_ADD_GLYPHS = 0xf8, S_CHAR_WIDTH = 0x104,
};

static uint32_t scratch;  // guest buffer: the screen size and one UTF-16 character

uint32_t gothic_field(uint32_t a, uint32_t off) { return *(const uint32_t *)bl_g2h(a + off); }
float gothic_ffield(uint32_t a, uint32_t off) { return *(const float *)bl_g2h(a + off); }
double gothic_clamp01(double v) { return fmin(fmax(v, 0), 1); }

uint32_t gothic_call(void *cpu, uint32_t fn, uint32_t self, int n, const uint32_t *a)
{
    return bl_call_guest(cpu, fn, self ? BL_THISCALL : BL_CDECL, self, n, a);
}

uint32_t gothic_scall(void *cpu, uint32_t s, uint32_t slot, int n, const uint32_t *a)
{
    return bl_call_guest(cpu, gothic_field(gothic_field(s, 0), slot), BL_THISCALL, s, n, a);
}

static uint32_t buffer(void)
{
    if (!scratch) scratch = bl_guest_calloc(1, 16 + 2 * 256);
    return scratch;
}

void gothic_color(void *cpu, uint32_t s, int r, int g, int b, double a)
{
    uint32_t v[4] = { r, g, b, (uint32_t)lround(gothic_clamp01(a) * 255) };
    gothic_scall(cpu, s, S_SET_COLOR, 4, v);
}

void gothic_rect(void *cpu, uint32_t s, int x0, int y0, int x1, int y1)
{
    uint32_t v[4] = { x0, y0, x1, y1 };
    gothic_scall(cpu, s, S_FILLED_RECT, 4, v);
}

void gothic_screen(void *cpu, uint32_t s, int *w, int *h)
{
    uint32_t b = buffer(), a[2] = { b, b + 4 };
    gothic_scall(cpu, s, S_SCREEN_SIZE, 2, a);
    *w = (int)gothic_field(b, 0), *h = (int)gothic_field(b, 4);
}

// Each face's ascent + descent per em, set when the fonts are registered.
static double cell_per_em[2] = { 1.35, 1.25 };
static const char *const face_file[2] = { "Cinzel.ttf", "Cormorant.ttf" };
static const char *const face_name[2] = { "Cinzel", "CormorantGaramond-Medium" };

static void register_fonts(void)
{
    static int done;
    if (done) return;
    done = 1;
    char exe[1024], path[1200];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) return;
    char *slash = strrchr(exe, '/');
    if (slash) *slash = 0;  // build/tests
    for (int k = 0; k < 2; k++) {
        snprintf(path, sizeof path, "%s/../../assets/fonts/%s", exe, face_file[k]);
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
        CFErrorRef err = NULL;
        if (!CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &err)) {
            fprintf(stderr, "[menu] couldn't register %s\n", path);
            if (err) CFRelease(err);
        }
        CFRelease(url);
        CFStringRef name = CFStringCreateWithCString(NULL, face_name[k], kCFStringEncodingASCII);
        CTFontRef f = CTFontCreateWithName(name, 100, NULL);
        cell_per_em[k] = (CTFontGetAscent(f) + CTFontGetDescent(f)) / 100;
        CFRelease(f);
        CFRelease(name);
    }
}

int gothic_face_tall(int face, double em)
{
    register_fonts();
    return (int)lround(em * cell_per_em[face]);
}

int gothic_tall(double em) { return gothic_face_tall(GOTHIC_CAPS, em); }

uint32_t gothic_face_font(void *cpu, uint32_t s, int face, double em)
{
    static uint32_t names[2], fonts[32];
    static int keys[32], count;
    int tall = gothic_face_tall(face, em), key = tall * 2 + face;
    if (!names[face]) names[face] = bl_guest_strdup(face_name[face]);
    for (int i = 0; i < count; i++)
        if (keys[i] == key) return fonts[i];
    uint32_t f = gothic_scall(cpu, s, S_CREATE_FONT, 0, NULL);
    uint32_t a[8] = { f, names[face], tall, 400, 0, 0, 0xff, 1 };  // flags, characters 0-255, kept
    gothic_scall(cpu, s, S_ADD_GLYPHS, 8, a);
    int i = count < 32 ? count++ : 31;  // a screen has a handful of sizes
    keys[i] = key, fonts[i] = f;
    return f;
}

uint32_t gothic_font(void *cpu, uint32_t s, double em) { return gothic_face_font(cpu, s, GOTHIC_CAPS, em); }

static int char_width(void *cpu, uint32_t s, uint32_t font, int c)
{
    uint32_t a[2] = { font, (uint32_t)c };
    return (int)gothic_scall(cpu, s, S_CHAR_WIDTH, 2, a);
}

void gothic_text(void *cpu, uint32_t s, uint32_t font, const char *str, int x, int y, int track, int r, int g, int b,
                 double a)
{
    uint32_t buf = buffer(), c[4] = { r, g, b, (uint32_t)lround(gothic_clamp01(a) * 255) };
    gothic_scall(cpu, s, S_TEXT_FONT, 1, &font);
    gothic_scall(cpu, s, S_TEXT_COLOR, 4, c);
    if (!track) {
        // Unspaced text goes in one call.
        int n = 0;
        for (; str[n] && n < 255; n++) ((uint16_t *)bl_g2h(buf + 16))[n] = (uint8_t)str[n];
        uint32_t p[2] = { x, y }, t[2] = { buf + 16, n };
        gothic_scall(cpu, s, S_TEXT_POS, 2, p);
        gothic_scall(cpu, s, S_PRINT_TEXT, 2, t);
        return;
    }
    for (; *str; str++) {
        uint32_t p[2] = { x, y };
        gothic_scall(cpu, s, S_TEXT_POS, 2, p);
        *(uint16_t *)bl_g2h(buf + 8) = (uint8_t)*str;
        uint32_t t[2] = { buf + 8, 1 };
        gothic_scall(cpu, s, S_PRINT_TEXT, 2, t);
        x += char_width(cpu, s, font, (uint8_t)*str) + track;
    }
}

int gothic_text_width(void *cpu, uint32_t s, uint32_t font, const char *str, int track)
{
    int w = 0;
    for (const char *p = str; *p; p++) w += char_width(cpu, s, font, (uint8_t)*p) + (p[1] ? track : 0);
    return w;
}

void gothic_caps(const char *in, char *out, int size)
{
    int n = 0;
    for (; in[n] && n < size - 1; n++) out[n] = (char)(in[n] >= 'a' && in[n] <= 'z' ? in[n] - 32 : in[n]);
    out[n] = 0;
}

void gothic_line(void *cpu, uint32_t s, int x0, int x1, int y, const float (*stops)[5], int n, double fade)
{
    int w = x1 - x0, steps = w < 64 ? (w > 0 ? w : 0) : 64;
    for (int k = 0; k < steps; k++) {
        float t = (k + 0.5f) / steps;
        int i = 0;
        while (i < n - 2 && t > stops[i + 1][0]) i++;
        float f = stops[i + 1][0] > stops[i][0] ? (t - stops[i][0]) / (stops[i + 1][0] - stops[i][0]) : 0;
        f = fminf(fmaxf(f, 0), 1);
        float c[4];
        for (int j = 0; j < 4; j++) c[j] = stops[i][j + 1] + (stops[i + 1][j + 1] - stops[i][j + 1]) * f;
        gothic_color(cpu, s, (int)lroundf(c[0]), (int)lroundf(c[1]), (int)lroundf(c[2]), fade * c[3]);
        gothic_rect(cpu, s, x0 + w * k / steps, y, x0 + w * (k + 1) / steps, y + 1);
    }
}

void gothic_diamond(void *cpu, uint32_t s, int cx, int cy, int r, int cr, int cg, int cb, double a)
{
    gothic_color(cpu, s, cr, cg, cb, a);
    for (int k = -r; k <= r; k++) {
        int dx = r - abs(k);
        gothic_rect(cpu, s, cx - dx, cy + k, cx - dx + 1, cy + k + 1);
        if (dx) gothic_rect(cpu, s, cx + dx, cy + k, cx + dx + 1, cy + k + 1);
    }
}

void gothic_dot(void *cpu, uint32_t s, int cx, int cy, int r, int cr, int cg, int cb, double a)
{
    gothic_color(cpu, s, cr, cg, cb, a);
    for (int k = -r; k <= r; k++) {
        int dx = (int)lround(sqrt(fmax(0, r * r - k * k)));
        gothic_rect(cpu, s, cx - dx, cy + k, cx + dx + 1, cy + k + 1);
    }
}

void gothic_drop(void *cpu, uint32_t s, int cx, int top, int w, int h, double a)
{
    double rad = w / 2.0;
    for (int k = 0; k < h; k++) {
        double y = k + 0.5, half;
        if (y < h - rad) half = rad * pow(y / (h - rad), 1.4);  // the narrowing tip
        else half = sqrt(fmax(0, rad * rad - (y - (h - rad)) * (y - (h - rad))));
        double shade = 0.45 + 0.55 * (y / h);  // darker at the tip
        gothic_color(cpu, s, (int)(224 * shade), (int)(40 * shade), (int)(58 * shade), a);
        gothic_rect(cpu, s, cx - (int)lround(half), top + k, cx + (int)lround(half) + (half > 0), top + k + 1);
    }
}

void gothic_flush(void *cpu, uint32_t s)
{
    gothic_text(cpu, s, gothic_font(cpu, s, 30), ".", 0, 0, 1, 0, 0, 0, 1.0 / 255);
    gothic_color(cpu, s, 0, 0, 0, 1.0 / 255);
    gothic_rect(cpu, s, 0, 0, 1, 1);
}
