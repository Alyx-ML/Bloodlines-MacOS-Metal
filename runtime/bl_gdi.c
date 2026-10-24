// gdi32 text rendering on Core Text: memory DCs, fonts, 32-bit DIB sections, text
// metrics, ABC widths, GGO_GRAY8_BITMAP glyph outlines and ExtTextOut.
//
// That is what vguimatsurface's Win32Font needs: it creates a font and a DIB the size
// of the widest character, then for each character asks GetGlyphOutline for an 8-bit
// coverage bitmap, or draws the character white on black with ExtTextOut and reads
// the DIB back.
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "bl_win32.h"

#define G(a) ((uint8_t *)bl_g2h(a))
#define U32(a) (*(uint32_t *)bl_g2h(a))
#define I32(a) (*(int32_t *)bl_g2h(a))

enum kind { K_FREE, K_DC, K_FONT, K_BITMAP };

struct font {
    CTFontRef ct;
    int marlett;  // em size in pixels when the font is Marlett, drawn by marlett_render
    int ascent, descent, height, internal_leading, ave_width, max_width, weight, italic;
};

struct bitmap {
    uint32_t bits;  // guest address
    int width, height, top_down, bpp;
};

struct dc {
    uint32_t font, bitmap;  // selected handles, 0 if none
    uint32_t text_color, bk_color, bk_mode, align, stretch_mode;
    int x, y;  // current position
};

#define MAX_OBJECTS 4096
#define HANDLE_BASE 0x50000u
static struct object {
    enum kind kind;
    union { struct dc dc; struct font font; struct bitmap bitmap; };
} objects[MAX_OBJECTS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t new_object(enum kind kind)
{
    for (int i = 0; i < MAX_OBJECTS; i++)
        if (objects[i].kind == K_FREE) {
            memset(&objects[i], 0, sizeof objects[i]);
            objects[i].kind = kind;
            return HANDLE_BASE + 4u * i;
        }
    bl_fatal("too many GDI objects");
}

static struct object *object(uint32_t h, enum kind kind)
{
    if (h < HANDLE_BASE || (h - HANDLE_BASE) % 4 || (h - HANDLE_BASE) / 4 >= MAX_OBJECTS) return NULL;
    struct object *o = &objects[(h - HANDLE_BASE) / 4];
    return o->kind == kind ? o : NULL;
}

// Windows-1252 0x80-0x9F; the rest of the code page matches Unicode.
static const uint16_t cp1252[32] = {
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
};
static UniChar ansi_char(uint32_t c)
{
    c &= 0xff;
    return c >= 0x80 && c < 0xa0 ? cp1252[c - 0x80] : (UniChar)c;
}

static CGGlyph glyph_of(CTFontRef f, UniChar c)
{
    CGGlyph g = 0;
    CTFontGetGlyphsForCharacters(f, &c, &g, 1);
    return g;
}

// Pixel box of a glyph at the origin, y up: x0..x1, y0..y1. Empty glyphs give 0x0.
struct box { int x0, y0, x1, y1, advance; };
static struct box glyph_box(CTFontRef f, CGGlyph g)
{
    CGRect r = CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, &g, NULL, 1);
    CGSize adv;
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &g, &adv, 1);
    struct box b = { 0, 0, 0, 0, (int)lround(adv.width) };
    if (r.size.width > 0 && r.size.height > 0) {
        b.x0 = (int)floor(r.origin.x), b.y0 = (int)floor(r.origin.y);
        b.x1 = (int)ceil(r.origin.x + r.size.width), b.y1 = (int)ceil(r.origin.y + r.size.height);
    }
    return b;
}

// Marlett, the Windows symbol font that vgui draws check boxes, radio buttons, scroll
// arrows and the combo box arrow with, is not on macOS. Its glyphs are drawn here as
// shapes in an em square: vgui's CheckButton prints 'g' (background), 'e' and 'f' (the
// dark and light edges) and 'b' (the check); RadioButton 'n', 'j', 'k', 'l', 'm' and 'h';
// ScrollBar and Menu '3' to '6'; ComboBox 'u'; Frame '0' to '2' and 'r'.
static int marlett_has(UniChar c)
{
    return strchr("abeghjklmnrtu0123456", c) != NULL && c != 0;
}

static void marlett_tri(CGContextRef cg, double s, double cx, double cy, double r, int dir)
{
    // dir: 0 left, 1 right, 2 up, 3 down; y runs down from the top of the cell.
    double p[3][2];
    if (dir < 2) {
        double t = dir ? r : -r;
        p[0][0] = cx + t, p[0][1] = cy;
        p[1][0] = cx - t, p[1][1] = cy - r * 1.8;
        p[2][0] = cx - t, p[2][1] = cy + r * 1.8;
    } else {
        double t = dir == 3 ? r : -r;
        p[0][0] = cx, p[0][1] = cy + t;
        p[1][0] = cx - r * 1.8, p[1][1] = cy - t;
        p[2][0] = cx + r * 1.8, p[2][1] = cy - t;
    }
    CGContextMoveToPoint(cg, p[0][0], s - p[0][1]);
    CGContextAddLineToPoint(cg, p[1][0], s - p[1][1]);
    CGContextAddLineToPoint(cg, p[2][0], s - p[2][1]);
    CGContextClosePath(cg);
    CGContextFillPath(cg);
}

// 8-bit coverage of Marlett character c in an s x s cell, top row first.
static uint8_t *marlett_render(UniChar c, int s, int *w, int *h)
{
    *w = *h = s;
    if (s <= 0 || !marlett_has(c)) return NULL;
    uint8_t *px = calloc((size_t)s * s, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef cg = CGBitmapContextCreate(px, s, s, 8, s, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextSetGrayFillColor(cg, 1, 1);
    CGContextSetGrayStrokeColor(cg, 1, 1);
    double u = s / 13.0;  // Windows draws a 13-pixel check box from a 13-pixel Marlett
#define RECT(x0, y0, x1, y1) CGContextFillRect(cg, CGRectMake((x0) * u, s - (y1) * u, ((x1) - (x0)) * u, ((y1) - (y0)) * u))
    switch (c) {
    case 'g': RECT(1, 1, 12, 12); break;                        // box background
    case 'e': RECT(1, 1, 12, 2); RECT(1, 1, 2, 12); break;      // top and left edge
    case 'f': RECT(1, 11, 12, 12); RECT(11, 1, 12, 12); break;  // bottom and right edge
    case 'a': case 'b':                                         // check mark
        CGContextSetLineWidth(cg, 1.7 * u);
        CGContextSetLineCap(cg, kCGLineCapSquare);
        CGContextMoveToPoint(cg, 3.5 * u, s - 6.0 * u);
        CGContextAddLineToPoint(cg, 5.5 * u, s - 8.3 * u);
        CGContextAddLineToPoint(cg, 9.5 * u, s - 4.0 * u);
        CGContextStrokePath(cg);
        break;
    case 'n': CGContextFillEllipseInRect(cg, CGRectMake(1 * u, s - 12 * u, 11 * u, 11 * u)); break;
    case 'j': case 'k': case 'l': case 'm': {                   // radio edges: outer, inner
        double in = (c == 'l' || c == 'm') ? 1 : 0;
        double a0 = (c == 'j' || c == 'l') ? M_PI * 0.25 : M_PI * 1.25;
        CGContextSetLineWidth(cg, 1.0 * u);
        CGContextAddArc(cg, 6.5 * u, s - 6.5 * u, (5.0 - in) * u, a0, a0 + M_PI, 0);
        CGContextStrokePath(cg);
        break;
    }
    case 'h': CGContextFillEllipseInRect(cg, CGRectMake(4.5 * u, s - 8.5 * u, 4 * u, 4 * u)); break;
    case '3': marlett_tri(cg, s, 6.5 * u, 6.5 * u, 1.8 * u, 0); break;
    case '4': marlett_tri(cg, s, 6.5 * u, 6.5 * u, 1.8 * u, 1); break;
    case '5': marlett_tri(cg, s, 6.5 * u, 6.5 * u, 1.8 * u, 2); break;
    case '6': marlett_tri(cg, s, 6.5 * u, 6.5 * u, 1.8 * u, 3); break;
    case 't': marlett_tri(cg, s, 6.5 * u, 6.5 * u, 1.4 * u, 2); break;
    case 'u': marlett_tri(cg, s, 6.5 * u, 6.5 * u, 1.4 * u, 3); break;
    case '0': RECT(3, 9, 9, 11); break;                          // minimise
    case '1': RECT(2, 2, 11, 11); CGContextClearRect(cg, CGRectMake(3 * u, s - 10 * u, 7 * u, 6 * u)); break;
    case '2': RECT(4, 1, 12, 8); CGContextClearRect(cg, CGRectMake(5 * u, s - 7 * u, 6 * u, 4 * u));
              RECT(1, 5, 9, 12); CGContextClearRect(cg, CGRectMake(2 * u, s - 11 * u, 6 * u, 4 * u)); break;
    case 'r':                                                    // close
        CGContextSetLineWidth(cg, 1.6 * u);
        CGContextMoveToPoint(cg, 3.5 * u, s - 3.5 * u), CGContextAddLineToPoint(cg, 9.5 * u, s - 9.5 * u);
        CGContextMoveToPoint(cg, 9.5 * u, s - 3.5 * u), CGContextAddLineToPoint(cg, 3.5 * u, s - 9.5 * u);
        CGContextStrokePath(cg);
        break;
    }
#undef RECT
    CGContextRelease(cg);
    return px;
}

// Face names the game asks for that macOS does not have, and the stand-in.
static CFStringRef face_name(const char *face)
{
    static const struct { const char *win, *mac; } subst[] = {
        { "Arial Unicode MS", "Arial Unicode MS" }, { "MS Sans Serif", "Arial" }, { "System", "Arial" },
        { "Marlett", "Arial" }, { "Lucida Console", "Menlo" }, { "Courier", "Courier New" },
    };
    for (size_t i = 0; i < sizeof subst / sizeof subst[0]; i++)
        if (!strcasecmp(face, subst[i].win)) face = subst[i].mac;
    return CFStringCreateWithCString(NULL, *face ? face : "Arial", kCFStringEncodingWindowsLatin1);
}

static CTFontRef make_font(const char *face, double size, int bold, int italic)
{
    CFStringRef name = face_name(face);
    CTFontRef f = CTFontCreateWithName(name, size, NULL);
    // Core Text falls back to a default font silently; use Arial when the family differs.
    CFStringRef family = CTFontCopyFamilyName(f);
    if (CFStringCompare(family, name, kCFCompareCaseInsensitive) != kCFCompareEqualTo) {
        CFRelease(f);
        f = CTFontCreateWithName(CFSTR("Arial"), size, NULL);
    }
    CFRelease(family);
    CFRelease(name);
    CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    if (traits) {
        CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(f, size, NULL, traits, traits);
        if (styled) CFRelease(f), f = styled;
    }
    return f;
}

uint32_t bl_gdi_CreateFontA_c(uint32_t h, uint32_t w, uint32_t esc, uint32_t orient, uint32_t weight,
                              uint32_t italic, uint32_t underline, uint32_t strike, uint32_t charset,
                              uint32_t out_prec, uint32_t clip_prec, uint32_t quality, uint32_t pitch, uint32_t face)
{
    (void)w, (void)esc, (void)orient, (void)underline, (void)strike, (void)charset;
    (void)out_prec, (void)clip_prec, (void)quality, (void)pitch;
    char name[64] = "";
    if (face) snprintf(name, sizeof name, "%s", (const char *)G(face));
    int height = (int32_t)h;
    // Positive heights are cell heights (ascent + descent), negative ones em sizes.
    double size = 12;
    if (height < 0) size = -height;
    if (height > 0) {
        CTFontRef unit = make_font(name, 100, 0, 0);
        double cell = CTFontGetAscent(unit) + CTFontGetDescent(unit);
        CFRelease(unit);
        size = height * 100 / cell;
    }
    int bold = (int32_t)weight >= 600, ital = (italic & 0xff) != 0;
    static int trace = -1;
    if (trace < 0) trace = getenv("BL_FONT_TRACE") != NULL;
    if (trace) fprintf(stderr, "[gdi] CreateFont \"%s\" height %d weight %u\n", name, height, weight);
    CTFontRef ct = make_font(name, size, bold, ital);
    pthread_mutex_lock(&lock);
    uint32_t handle = new_object(K_FONT);
    struct font *f = &object(handle, K_FONT)->font;
    f->ct = ct;
    f->ascent = (int)ceil(CTFontGetAscent(ct));
    f->descent = (int)ceil(CTFontGetDescent(ct));
    f->height = height > 0 ? height : f->ascent + f->descent;
    if (f->ascent + f->descent > f->height) f->descent = f->height - f->ascent;
    f->internal_leading = f->height - (int)lround(size);
    if (f->internal_leading < 0) f->internal_leading = 0;
    f->ave_width = glyph_box(ct, glyph_of(ct, 'x')).advance;
    int max = 0;
    for (UniChar c = 32; c < 256; c++) {
        struct box b = glyph_box(ct, glyph_of(ct, c));
        int wdt = b.x1 > b.advance ? b.x1 : b.advance;
        if (b.x0 < 0) wdt -= b.x0;
        if (wdt > max) max = wdt;
    }
    f->max_width = max ? max : 1;
    f->weight = weight ? (int)weight : 400;
    f->italic = ital;
    if (!strcasecmp(name, "Marlett")) {
        // A square cell, the glyph filling it from the top.
        int em = height < 0 ? -height : height > 0 ? height : 12;
        f->marlett = em;
        f->ascent = f->height = f->ave_width = f->max_width = em;
        f->descent = f->internal_leading = 0;
    }
    pthread_mutex_unlock(&lock);
    return handle;
}

uint32_t bl_gdi_CreateCompatibleDC_c(uint32_t other)
{
    (void)other;
    pthread_mutex_lock(&lock);
    uint32_t h = new_object(K_DC);
    struct dc *d = &object(h, K_DC)->dc;
    d->text_color = 0, d->bk_color = 0xffffff, d->bk_mode = 2;  // black on white, OPAQUE
    pthread_mutex_unlock(&lock);
    return h;
}

uint32_t bl_gdi_DeleteDC_c(uint32_t h)
{
    pthread_mutex_lock(&lock);
    struct object *o = object(h, K_DC);
    if (o) o->kind = K_FREE;
    pthread_mutex_unlock(&lock);
    return o != NULL;
}

uint32_t bl_gdi_DeleteObject_c(uint32_t h)
{
    pthread_mutex_lock(&lock);
    struct object *o = object(h, K_FONT);
    if (o) CFRelease(o->font.ct), o->kind = K_FREE;
    else if ((o = object(h, K_BITMAP))) bl_guest_free(o->bitmap.bits), o->kind = K_FREE;
    pthread_mutex_unlock(&lock);
    return 1;
}

// Returns the previously selected object of the same kind (or a stock object).
uint32_t bl_gdi_SelectObject_c(uint32_t dc, uint32_t h)
{
    pthread_mutex_lock(&lock);
    struct object *d = object(dc, K_DC);
    uint32_t old = 0x30000 + 4 * 13;  // SYSTEM_FONT
    if (d && object(h, K_FONT)) old = d->dc.font ? d->dc.font : old, d->dc.font = h;
    else if (d && object(h, K_BITMAP)) old = d->dc.bitmap ? d->dc.bitmap : 0x30000 + 4 * 21, d->dc.bitmap = h;
    pthread_mutex_unlock(&lock);
    return old;
}

#define DC_SETTER(name, field)                                                                                     \
    uint32_t bl_gdi_##name##_c(uint32_t dc, uint32_t v)                                                           \
    {                                                                                                             \
        pthread_mutex_lock(&lock);                                                                                \
        struct object *d = object(dc, K_DC);                                                                      \
        uint32_t old = d ? d->dc.field : 0;                                                                       \
        if (d) d->dc.field = v;                                                                                   \
        pthread_mutex_unlock(&lock);                                                                              \
        return old;                                                                                               \
    }
DC_SETTER(SetTextColor, text_color)
DC_SETTER(SetBkColor, bk_color)
DC_SETTER(SetBkMode, bk_mode)
DC_SETTER(SetTextAlign, align)
DC_SETTER(SetStretchBltMode, stretch_mode)

void d3d_render_present_pixels(const void *pixels, uint32_t w, uint32_t h, int bottom_up, const int32_t src_rect[4],
                               const int32_t dst_rect[4]);

// Bink draws movie frames with these when it has no DirectDraw surface: from a memory
// DC holding a 32-bit DIB section to the window's DC. Those blits go to the window
// through Metal; any other pair of DCs is not drawn.
static uint32_t blit(const char *name, uint32_t dst, int x, int y, int w, int h, uint32_t src, int sx, int sy, int sw,
                     int sh)
{
    pthread_mutex_lock(&lock);
    struct object *d = object(dst, K_DC), *s = object(src, K_DC);
    struct object *b = s && s->dc.bitmap ? object(s->dc.bitmap, K_BITMAP) : NULL;
    struct bitmap bm = b ? b->bitmap : (struct bitmap){0};
    pthread_mutex_unlock(&lock);
    if (!d && (dst & 0xffff0000) == 0x40000 && bm.bits && bm.bpp == 32) {  // a window DC (user32 GetDC)
        int32_t sr[4] = {sx, sy, sx + sw, sy + sh}, dr[4] = {x, y, x + w, y + h};
        static int trace = -1;
        static int32_t last[6];
        if (trace < 0) trace = getenv("BL_GDI_TRACE") != NULL;
        int32_t now[6] = {x, y, w, h, sw, sh};
        if (trace && memcmp(now, last, sizeof now)) {
            const uint32_t *px = bl_g2h(bm.bits);
            fprintf(stderr, "[gdi] %s %dx%d DIB, src %d,%d %dx%d -> dst %d,%d %dx%d, corner %08x centre %08x\n", name,
                    bm.width, bm.height, sx, sy, sw, sh, x, y, w, h, px[0], px[bm.height / 2 * bm.width + bm.width / 2]);
            memcpy(last, now, sizeof now);
        }
        d3d_render_present_pixels(bl_g2h(bm.bits), (uint32_t)bm.width, (uint32_t)bm.height, !bm.top_down, sr, dr);
        return 1;
    }
    static int logged;
    if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) fprintf(stderr, "[gdi] %s between these DCs ignored\n", name);
    return 1;
}

uint32_t bl_gdi_StretchBlt_c(uint32_t dst, int x, int y, int w, int h, uint32_t src, int sx, int sy, int sw, int sh,
                             uint32_t rop)
{
    (void)rop;
    return blit("StretchBlt", dst, x, y, w, h, src, sx, sy, sw, sh);
}

uint32_t bl_gdi_BitBlt_c(uint32_t dst, int x, int y, int w, int h, uint32_t src, int sx, int sy, uint32_t rop)
{
    (void)rop;
    return blit("BitBlt", dst, x, y, w, h, src, sx, sy, w, h);
}

uint32_t bl_gdi_MoveToEx_c(uint32_t dc, uint32_t x, uint32_t y, uint32_t old)
{
    pthread_mutex_lock(&lock);
    struct object *d = object(dc, K_DC);
    if (d && old) I32(old) = d->dc.x, I32(old + 4) = d->dc.y;
    if (d) d->dc.x = (int32_t)x, d->dc.y = (int32_t)y;
    pthread_mutex_unlock(&lock);
    return d != NULL;
}

static struct font *dc_font(uint32_t dc)
{
    struct object *d = object(dc, K_DC);
    struct object *f = d ? object(d->dc.font, K_FONT) : NULL;
    return f ? &f->font : NULL;
}

// TEXTMETRICA
uint32_t bl_gdi_GetTextMetricsA_c(uint32_t dc, uint32_t tm)
{
    pthread_mutex_lock(&lock);
    struct font *f = dc_font(dc);
    if (f) {
        memset(G(tm), 0, 56);
        I32(tm + 0) = f->height;
        I32(tm + 4) = f->ascent;
        I32(tm + 8) = f->height - f->ascent;
        I32(tm + 12) = f->internal_leading;
        I32(tm + 16) = 0;  // external leading
        I32(tm + 20) = f->ave_width;
        I32(tm + 24) = f->max_width;
        I32(tm + 28) = f->weight;
        I32(tm + 36) = 96, I32(tm + 40) = 96;  // digitized aspect
        G(tm)[44] = 32, G(tm)[45] = 255, G(tm)[46] = 31, G(tm)[47] = 32;  // first, last, default, break
        G(tm)[48] = (uint8_t)f->italic;
        G(tm)[51] = 0x06;  // TMPF_VECTOR | TMPF_TRUETYPE
        G(tm)[52] = 0;     // ANSI_CHARSET
    }
    pthread_mutex_unlock(&lock);
    return f != NULL;
}

// BITMAPINFOHEADER with 32 bits per pixel and no compression only.
uint32_t bl_gdi_CreateDIBSection_c(uint32_t dc, uint32_t bmi, uint32_t usage, uint32_t bits_out, uint32_t section,
                                   uint32_t offset)
{
    (void)dc, (void)usage, (void)section, (void)offset;
    int w = I32(bmi + 4), h = I32(bmi + 8), bpp = *(uint16_t *)G(bmi + 14);
    if (w <= 0 || h == 0 || bpp != 32) {
        fprintf(stderr, "[gdi] CreateDIBSection %dx%d %d bpp not supported\n", w, h, bpp);
        if (bits_out) U32(bits_out) = 0;
        return 0;
    }
    uint32_t size = (uint32_t)w * (uint32_t)(h < 0 ? -h : h) * 4;
    uint32_t bits = bl_guest_calloc(1, size);
    if (!bits) return 0;
    pthread_mutex_lock(&lock);
    uint32_t handle = new_object(K_BITMAP);
    struct bitmap *b = &object(handle, K_BITMAP)->bitmap;
    b->bits = bits, b->width = w, b->height = h < 0 ? -h : h, b->top_down = h < 0, b->bpp = bpp;
    pthread_mutex_unlock(&lock);
    if (bits_out) U32(bits_out) = bits;
    return handle;
}

static struct box font_box(const struct font *f, UniChar c);

static uint32_t abc_widths(uint32_t dc, uint32_t first, uint32_t last, uint32_t out, int wide)
{
    pthread_mutex_lock(&lock);
    struct font *f = dc_font(dc);
    for (uint32_t c = first; f && c <= last; c++) {
        struct box b = font_box(f, wide ? (UniChar)c : ansi_char(c));
        int a = b.x0, w = b.x1 - b.x0;
        if (w <= 0) a = 0, w = 1;  // Windows reports at least one pixel of black box
        uint32_t e = out + 12 * (c - first);
        I32(e) = a, U32(e + 4) = (uint32_t)w, I32(e + 8) = b.advance - a - w;
    }
    pthread_mutex_unlock(&lock);
    return f != NULL;
}
uint32_t bl_gdi_GetCharABCWidthsA_c(uint32_t dc, uint32_t first, uint32_t last, uint32_t out)
{
    return abc_widths(dc, first, last, out, 0);
}
uint32_t bl_gdi_GetCharABCWidthsW_c(uint32_t dc, uint32_t first, uint32_t last, uint32_t out)
{
    return abc_widths(dc, first, last, out, 1);
}

// 8-bit coverage of glyph g, top row first, w x h bytes.
static uint8_t *render_gray(CTFontRef f, CGGlyph g, struct box b, int *w, int *h)
{
    *w = b.x1 - b.x0, *h = b.y1 - b.y0;
    if (*w <= 0 || *h <= 0) return NULL;
    uint8_t *px = calloc((size_t)*w * *h, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef cg = CGBitmapContextCreate(px, *w, *h, 8, *w, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextSetGrayFillColor(cg, 1, 1);
    CGContextSetShouldAntialias(cg, true);
    CGContextSetShouldSmoothFonts(cg, false);
    CGPoint at = { -b.x0, -b.y0 };
    CTFontDrawGlyphs(f, &g, &at, 1, cg);
    CGContextRelease(cg);
    return px;  // CG bitmaps store the top row first
}

// A character's box and coverage in font f, for Core Text fonts and Marlett alike.
static struct box font_box(const struct font *f, UniChar c)
{
    if (f->marlett) return marlett_has(c) ? (struct box){ 0, 0, f->marlett, f->marlett, f->marlett }
                                          : (struct box){ 0, 0, 0, 0, f->marlett };
    return glyph_box(f->ct, glyph_of(f->ct, c));
}

static uint8_t *font_render(const struct font *f, UniChar c, struct box b, int *w, int *h)
{
    if (f->marlett) return marlett_render(c, f->marlett, w, h);
    return render_gray(f->ct, glyph_of(f->ct, c), b, w, h);
}

// GetGlyphOutlineA with GGO_METRICS (0) or GGO_GRAY8_BITMAP (6) and an identity matrix.
uint32_t bl_gdi_GetGlyphOutlineA_c(uint32_t dc, uint32_t ch, uint32_t format, uint32_t gm, uint32_t size,
                                   uint32_t buf, uint32_t mat2)
{
    (void)mat2;
    if (format != 0 && format != 6) {
        fprintf(stderr, "[gdi] GetGlyphOutline format %u not supported\n", format);
        return 0xffffffff;  // GDI_ERROR
    }
    pthread_mutex_lock(&lock);
    struct font *f = dc_font(dc);
    if (!f) {
        pthread_mutex_unlock(&lock);
        return 0xffffffff;
    }
    // vguimatsurface passes wide characters here; values above 0xff are Unicode.
    UniChar c = ch > 0xff ? (UniChar)ch : ansi_char(ch);
    struct box b = font_box(f, c);
    int w = b.x1 - b.x0, h = b.y1 - b.y0;
    if (gm) {
        U32(gm) = w > 0 ? (uint32_t)w : 1, U32(gm + 4) = h > 0 ? (uint32_t)h : 1;
        I32(gm + 8) = b.x0, I32(gm + 12) = b.y1;
        *(int16_t *)G(gm + 16) = (int16_t)b.advance, *(int16_t *)G(gm + 18) = 0;
    }
    uint32_t pitch = ((uint32_t)(w > 0 ? w : 0) + 3) & ~3u, need = pitch * (uint32_t)(h > 0 ? h : 0);
    uint32_t ret = format == 0 ? 0 : need;
    if (format == 6 && need && buf && size >= need) {
        int rw, rh;
        uint8_t *px = font_render(f, c, b, &rw, &rh);
        uint8_t *dst = G(buf);
        memset(dst, 0, need);
        for (int y = 0; y < rh; y++)
            for (int x = 0; x < rw; x++) dst[y * pitch + x] = (uint8_t)((px[y * rw + x] * 64 + 127) / 255);
        free(px);
    }
    pthread_mutex_unlock(&lock);
    return ret;
}

// Draws text into the DIB selected into dc: the background box (OPAQUE) in the
// background colour, glyph coverage blended in the text colour. TA_UPDATECP draws at
// and advances the current position; otherwise at x, y. TA_TOP only.
static uint32_t ext_text_out(uint32_t dc, int x, int y, const UniChar *s, int n)
{
    pthread_mutex_lock(&lock);
    struct object *d = object(dc, K_DC);
    struct font *f = dc_font(dc);
    struct object *bo = d ? object(d->dc.bitmap, K_BITMAP) : NULL;
    if (!d || !f || !bo) {
        pthread_mutex_unlock(&lock);
        return d != NULL;
    }
    struct bitmap *bm = &bo->bitmap;
    if (d->dc.align & 1) x = d->dc.x, y = d->dc.y;  // TA_UPDATECP
    uint8_t *bits = G(bm->bits);
    uint32_t fg = d->dc.text_color, bg = d->dc.bk_color;
    for (int i = 0; i < n; i++) {
        struct box b = font_box(f, s[i]);
        int rw = 0, rh = 0;
        uint8_t *px = font_render(f, s[i], b, &rw, &rh);
        for (int row = 0; row < f->height; row++) {
            int py = y + row;
            if (py < 0 || py >= bm->height) continue;
            uint8_t *line = bits + (size_t)(bm->top_down ? py : bm->height - 1 - py) * bm->width * 4;
            for (int col = 0; col < b.advance || col < b.x1; col++) {
                int pxl = x + col;
                if (pxl < 0 || pxl >= bm->width) continue;
                // Coverage at this cell pixel: glyph rows run down from ascent - y1.
                int gy = row - (f->ascent - b.y1), gx = col - b.x0;
                unsigned cov = gy >= 0 && gy < rh && gx >= 0 && gx < rw ? px[gy * rw + gx] : 0;
                uint8_t *p = line + 4 * pxl;  // B, G, R, X
                for (int k = 0; k < 3; k++) {
                    unsigned fc = (fg >> (8 * (2 - k))) & 0xff, bc = (bg >> (8 * (2 - k))) & 0xff;
                    unsigned base = d->dc.bk_mode == 2 ? bc : p[k];
                    p[k] = (uint8_t)((fc * cov + base * (255 - cov) + 127) / 255);
                }
            }
        }
        free(px);
        x += b.advance;
    }
    if (d->dc.align & 1) d->dc.x = x;
    pthread_mutex_unlock(&lock);
    return 1;
}

uint32_t bl_gdi_ExtTextOutA_c(uint32_t dc, uint32_t x, uint32_t y, uint32_t options, uint32_t rect, uint32_t str,
                              uint32_t count, uint32_t dx)
{
    (void)options, (void)rect, (void)dx;
    UniChar s[256];
    int n = count < 256 ? (int)count : 256;
    for (int i = 0; i < n; i++) s[i] = ansi_char(G(str)[i]);
    return ext_text_out(dc, (int32_t)x, (int32_t)y, s, n);
}

uint32_t bl_gdi_ExtTextOutW_c(uint32_t dc, uint32_t x, uint32_t y, uint32_t options, uint32_t rect, uint32_t str,
                              uint32_t count, uint32_t dx)
{
    (void)options, (void)rect, (void)dx;
    UniChar s[256];
    int n = count < 256 ? (int)count : 256;
    for (int i = 0; i < n; i++) s[i] = ((uint16_t *)G(str))[i];
    return ext_text_out(dc, (int32_t)x, (int32_t)y, s, n);
}
