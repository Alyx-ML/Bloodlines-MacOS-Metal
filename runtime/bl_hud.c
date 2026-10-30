// The HUD in the gothic style of the menus and dialogue (bl_menu.c, bl_dialog.c), to the
// approved mockup (1920x1080 pixels, scaled to the screen's height): health and blood as two
// plain glass vials low on the screen's edges, pale blue on the left and blood red on the
// right, each liquid glowing softly, with no frame or caps and no words: above each, a small
// symbol in its colour, an ankh for health and a drop for blood; beside the blood, the
// selected discipline's symbol (the game's own, without its name), and beside the health,
// the ammo in Cormorant figures, the clip large and the reserve small.
//
// The client's HUD elements keep their logic: the values, the fades and when they show.
// Hooks in client (modules/client/instruction_replacements.manual.sci) replace their look:
//   - CHealthAnkh::Paint once it has its fade (+0x188, 0 to 255) and its shown health
//     (+0x198, 0 to 100, eased towards +0x190) (0x10051498): bl_hud_Health draws the left
//     vial and the paint leaves before the game's frame, icon and fill;
//   - CBloodBar::Paint once it has its fade (+0x19c, 0 to 255) (0x1004CD04) skips its frame
//     and the ring at the bottom right; once it has eased the shown blood (+0x1d8, tenths of
//     a point) (0x1004CF2B), bl_hud_Blood draws the right vial (full at 15 points) and the
//     paint leaves;
//   - CAmmoCounter::Paint (which draws the discipline, not the ammo) once it has its fade
//     (+0x198, 0 to 255) (0x1004BF6A): bl_hud_Discipline draws the symbol and the paint
//     leaves before the game's icon, highlight and name. The symbol is the HUD script's
//     "discipline_unsel_<n>" sprite (hud/disciplines/<name>, 100x64 texels, its name in the
//     bottom 20), drawn with its height cut to 44 texels;
//   - CTargeted::Paint once it has the held weapon (ebx) (0x1006401C): bl_hud_Ammo notes its
//     ammo and the paint goes on to the crosshair, past the game's weapon icon and numbers.
//     The weapon's ammo type is +0x7a4 (none 0 or less), its clip +0x7ac, the player's
//     reserve of the type at player +0xfdc + 4 * type; the fade is the global 0x103EEF48 (0
//     to 255). bl_hud_Health draws the noted ammo, since its panel covers the screen.
// The globals read here (the player 0x104A0D50, the HUD's sprites 0x104CFE38 and the ammo
// fade) are not at their original addresses: client_HudPlayer, client_HudSprites and
// client_HudAmmoFade, in the same file, return where they are.
// The vials are images drawn here in software, as the mockup's were, and put on the screen
// by the renderer (bl_metal_hud_image); the ammo and the symbol go through vgui. The health
// panel is moved to cover the screen, so the ammo isn't clipped to the game's place.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bl_gothic.h"
#include "bl_vm.h"
#include "llasm_cpu.h"

extern char client_Surface[], client_PanelSetPos[], client_PanelSetSize[], client_HudSprite[],
    client_ImageDraw[], client_HudPlayer[], client_HudSprites[], client_HudAmmoFade[];

#define field gothic_field

enum { NO_DISCIPLINE = 0x1f };
// The player's fields read here end before this; a weapon's before WEAPON_SIZE.
enum { PLAYER_SIZE = 0x14e4, WEAPON_SIZE = 0x7b0 };

// The mockup, in its pixels: each vial 12 wide, its centre 60 in from the edge, from 470 to
// 978 down; the glow a blur of 9, its image 30 beyond the glass. Above each, its symbol (an
// ankh for health, a drop for blood) 26 tall, 12 over the glass.
enum { VIAL_X = 60, VIAL_HW = 6, VIAL_TOP = 470, VIAL_BOTTOM = 978, GLOW_SIGMA = 9, VIAL_PAD = 30 };
enum { MARK_H = 26, MARK_GAP = 12 };
enum { MARK_ANKH, MARK_DROP };
// The symbol 50 tall, its right 84 in from the edge, its foot on the vial's; the ammo 96 in
// and 58 up, the clip in 40-pixel figures, the reserve in 20.
enum { SYMBOL_H = 50, SYMBOL_RIGHT = 84, AMMO_X = 96, AMMO_BOTTOM = 58, CLIP_EM = 40, RESERVE_EM = 20 };
enum { ICON_TEXELS_W = 100, ICON_TEXELS_H = 64, SYMBOL_TEXELS_H = 44 };

static const double HEALTH[3] = { 96, 200, 232 }, BLOOD[3] = { 242, 26, 41 };
static const int IVORY[3] = { 236, 226, 207 }, MUTED[3] = { 166, 153, 132 };

// The held weapon's ammo, from CTargeted's last paint.
static int ammo_shown, ammo_clip, ammo_reserve;
static double ammo_fade;
static uint64_t ammo_ns;

// The globals' addresses in the module, asked for once.
static uint32_t player_global, sprites_global, fade_global;

static void find_globals(void *cpu)
{
    if (player_global) return;
    player_global = gothic_call(cpu, bl_h2g(client_HudPlayer), 0, 0, NULL);
    sprites_global = gothic_call(cpu, bl_h2g(client_HudSprites), 0, 0, NULL);
    fade_global = gothic_call(cpu, bl_h2g(client_HudAmmoFade), 0, 0, NULL);
}

// The player, or 0 while the global holds no object of the heap's.
static uint32_t player_now(void *cpu)
{
    find_globals(cpu);
    uint32_t p = field(player_global, 0);
    return p && !(p & 3) && bl_guest_heap_has(p, PLAYER_SIZE) ? p : 0;
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static uint32_t surface(void *cpu) { return gothic_call(cpu, bl_h2g(client_Surface), 0, 0, NULL); }

// The panel covers the screen; vgui keeps it as is when nothing changes.
static void cover(void *cpu, uint32_t panel, int w, int h)
{
    uint32_t p[2] = { 0, 0 }, s[2] = { (uint32_t)w, (uint32_t)h };
    gothic_call(cpu, bl_h2g(client_PanelSetPos), panel, 2, p);
    gothic_call(cpu, bl_h2g(client_PanelSetSize), panel, 2, s);
}

// A glass vial as the mockup drew it, into an image of its own `pad` beyond the glass on
// each side: the liquid shaded as a cylinder, lit from within, darker with depth and with
// a bright meniscus; the empty glass dark and clear at its middle; highlights down the
// glass; a soft glow of the liquid's colour and a drop shadow under it. Premultiplied BGRA,
// faded by `fade`.
static double box_blur(double x, double x0, double x1, double sigma)  // a box, blurred
{
    double k = 1 / (sigma * M_SQRT2);
    return .5 * (erf((x1 - x) * k) - erf((x0 - x) * k));
}

static void over(double *p, double r, double g, double b, double a)
{
    if (a <= 0) return;
    a = fmin(a, 1);
    p[0] = r * a + p[0] * (1 - a), p[1] = g * a + p[1] * (1 - a), p[2] = b * a + p[2] * (1 - a);
    p[3] = a + p[3] * (1 - a);
}

// The symbol's signed distance (pixels, negative inside), its top at `top`.
static double mark_sd(int mark, double x, double y, double cx, double top, double unit)
{
    double mx = (x - cx) / unit, my = (y - top) / unit, sd;  // in the mockup's pixels
    if (mark == MARK_ANKH) {
        double lx = mx / 4.2, ly = (my - 5.2) / 5.2;  // the loop, a ring
        double ring = fabs((sqrt(lx * lx + ly * ly) - 1) * 4.6) - 1.3;
        double bar = fmax(fabs(mx) - 7, fabs(my - 12.2) - 1.3);
        double flare = 1.2 + .9 * fmin(fmax((my - 13) / 13, 0), 1);
        double stem = fmax(fabs(mx) - flare, fmax(10.5 - my, my - 26));
        sd = fmin(ring, fmin(bar, stem));
    } else {
        double r = 7, cy = 18.5;  // a circle, and a point above it
        if (my < cy) {
            double t = fmin(fmax((cy - my) / cy, 0), 1);
            sd = my < 0 ? 99 : fabs(mx) - r * pow(1 - t, 1.3);
        } else
            sd = hypot(mx, my - cy) - r;
    }
    return sd * unit;
}

static void vial_image(uint8_t *px, int iw, int ih, double unit, int pad, int mark, double fill, const double *liquid,
                       double fade)
{
    double mark_top = pad, hw = VIAL_HW * unit, cx = iw / 2.0, top = pad + (MARK_H + MARK_GAP) * unit, bottom = ih - pad;
    double len = bottom - top;
    double fy = bottom - len * fmin(fmax(fill, 0), 1), r = 3 * unit, glow = GLOW_SIGMA * unit, soft = 2.5 * unit;
    double lc[3] = { liquid[0] / 255, liquid[1] / 255, liquid[2] / 255 };
    for (int j = 0; j < ih; j++)
        for (int i = 0; i < iw; i++) {
            double x = i + .5, y = j + .5, p[4] = { 0, 0, 0, 0 };
            if (fy < bottom) over(p, lc[0], lc[1], lc[2], .75 * box_blur(x, cx - hw, cx + hw, glow) * box_blur(y, fy, bottom, glow));
            over(p, 0, 0, 0, .7 * box_blur(x - unit, cx - hw, cx + hw, soft) * box_blur(y - 2 * unit, top, bottom, soft));
            // The glass: a rounded box.
            double qx = fabs(x - cx) - hw + r, qy = fabs(y - (top + bottom) / 2) - len / 2 + r;
            double sd = hypot(fmax(qx, 0), fmax(qy, 0)) + fmin(fmax(qx, qy), 0) - r, vm = fmin(fmax(.5 - sd, 0), 1);
            if (vm > 0) {
                double u = (x - cx) / hw, nz = sqrt(fmax(0, 1 - u * u));
                double wave = 1.2 * unit * sin(x / unit * .9), c[3];
                int liq = y > fy + wave;
                if (liq) {
                    double depth = fmin(fmax((y - fy) / len, 0), 1);
                    double men = .8 * exp(-pow((y - fy - wave - 1.5 * unit) / (1.4 * unit), 2));
                    for (int k = 0; k < 3; k++)
                        c[k] = lc[k] * (.35 + .75 * nz) * (1.05 - .35 * depth) + .35 * pow(nz, 8) * lc[k] + (lc[k] * .6 + .4) * men;
                } else {
                    double e = pow(1 - nz, 3);
                    c[0] = .05 + .3 * e, c[1] = .045 + .3 * e, c[2] = .05 + .32 * e;
                }
                double hl = .85 * exp(-pow((u + .45) / .12, 2)) + .25 * exp(-pow((u - .55) / .08, 2));
                for (int k = 0; k < 3; k++) c[k] = fmin(c[k] * (.55 + .45 * nz) + hl, 1);
                over(p, c[0], c[1], c[2], (liq ? 1 : .72) * vm);
            }
            // The symbol, in the liquid's colour, lit a little and glowing.
            double ms = mark_sd(mark, x, y, cx, mark_top, unit);
            if (ms < 6 * unit) {
                over(p, lc[0], lc[1], lc[2], .4 * exp(-fmax(ms, 0) / (2.5 * unit)));
                double lift = .25 + .2 * (1 - (y - mark_top) / (MARK_H * unit));
                over(p, fmin(lc[0] + lift, 1), fmin(lc[1] + lift, 1), fmin(lc[2] + lift, 1), fmin(fmax(.5 - ms, 0), 1));
            }
            uint8_t *o = px + ((size_t)j * iw + i) * 4;
            o[0] = (uint8_t)lround(fmin(p[2] * fade, 1) * 255), o[1] = (uint8_t)lround(fmin(p[1] * fade, 1) * 255);
            o[2] = (uint8_t)lround(fmin(p[0] * fade, 1) * 255), o[3] = (uint8_t)lround(fmin(p[3] * fade, 1) * 255);
        }
}

// The vial in `slot` (0 health, 1 blood) centred on cx: drawn again only when its size, fill
// or fade changes.
static void vial(int slot, int w, int h, int cx, int mark, double fill, const double *liquid, double fade)
{
    static uint8_t *px[2];
    static int made[2][4];
    static unsigned long version[2];
    double unit = h / 1080.0;
    int pad = (int)lround(VIAL_PAD * unit), top = (int)lround(VIAL_TOP * unit), bottom = (int)lround(VIAL_BOTTOM * unit);
    int above = (int)lround((MARK_H + MARK_GAP) * unit), iw = 2 * pad, ih = bottom - top + above + 2 * pad;
    int want[4] = { iw, ih, (int)lround(fill * (bottom - top) * 4), (int)lround(fade * 255) };
    if (!px[slot] || memcmp(made[slot], want, sizeof want)) {
        if (!px[slot] || made[slot][0] != iw || made[slot][1] != ih) {
            free(px[slot]);
            px[slot] = malloc((size_t)iw * ih * 4);
            if (!px[slot]) return;
        }
        vial_image(px[slot], iw, ih, unit, pad, mark, fill, liquid, fade);
        memcpy(made[slot], want, sizeof want);
        version[slot]++;
    }
    bl_metal_hud_image(slot, px[slot], (uint32_t)iw, (uint32_t)ih, cx - pad, top - above - pad, w, h, version[slot]);
}

// CHealthAnkh::Paint (esi = the panel): the left vial. The replacement then leaves.
void bl_hud_Health(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, panel = esi;
    uint32_t s = surface(cpu);
    int w, h;
    gothic_screen(cpu, s, &w, &h);
    cover(cpu, panel, w, h);
    double unit = h / 1080.0, a = fmin((int)field(panel, 0x188) / 255.0, 1);
    if (a > 0) vial(0, w, h, (int)lround(VIAL_X * unit), MARK_ANKH, (int)field(panel, 0x198) / 100.0, HEALTH, a);
    if (ammo_shown && ammo_fade > 0 && now_ns() - ammo_ns < 250000000ull) {
        char clip[16], reserve[16];
        snprintf(clip, sizeof clip, "%d", ammo_clip);
        snprintf(reserve, sizeof reserve, "/ %d", ammo_reserve);
        uint32_t big = gothic_face_font(cpu, s, GOTHIC_BODY, CLIP_EM * unit);
        uint32_t small = gothic_face_font(cpu, s, GOTHIC_BODY, RESERVE_EM * unit);
        int bt = gothic_face_tall(GOTHIC_BODY, CLIP_EM * unit), st = gothic_face_tall(GOTHIC_BODY, RESERVE_EM * unit);
        int x = (int)lround(AMMO_X * unit), y = h - (int)lround(AMMO_BOTTOM * unit) - bt;
        gothic_text(cpu, s, big, clip, x, y, 0, IVORY[0], IVORY[1], IVORY[2], ammo_fade);
        x += gothic_text_width(cpu, s, big, clip, 0) + (int)lround(4 * unit);
        gothic_text(cpu, s, small, reserve, x, y + (int)lround((bt - st) * .78), 0, MUTED[0], MUTED[1], MUTED[2], ammo_fade);
    }
    eax = sa, ecx = sc, edx = sd;
}

// CBloodBar::Paint (esi = the panel), its shown blood eased: the right vial. The replacement
// then leaves.
void bl_hud_Blood(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, panel = esi;
    int w, h;
    gothic_screen(cpu, surface(cpu), &w, &h);
    double unit = h / 1080.0, a = fmin(gothic_ffield(panel, 0x19c) / 255.0, 1);
    if (a > 0) vial(1, w, h, w - (int)lround(VIAL_X * unit), MARK_DROP, (int)field(panel, 0x1d8) / 150.0, BLOOD, a);
    eax = sa, ecx = sc, edx = sd;
}

// CAmmoCounter::Paint (esi = the panel): the selected discipline's symbol. The replacement
// then leaves.
void bl_hud_Discipline(_cpu *cpu)
{
    static uint32_t name;
    uint32_t sa = eax, sc = ecx, sd = edx, panel = esi, player = player_now(cpu);
    int id = player ? (int)field(player, 0x14d8) : -1;
    double a = fmin(gothic_ffield(panel, 0x198) / 255.0, 1);
    if (id >= 0 && id != NO_DISCIPLINE && a > 0) {
        if (!name) name = bl_guest_calloc(1, 32);
        snprintf((char *)bl_g2h(name), 32, "discipline_unsel_%d", id);
        uint32_t entry = gothic_call(cpu, bl_h2g(client_HudSprite), sprites_global, 1, &name);
        uint32_t sprite = entry ? field(entry, 0x84) : 0;
        if (sprite) {
            uint32_t *th = (uint32_t *)bl_g2h(sprite + 0x14), keep = *th;
            *th = SYMBOL_TEXELS_H;  // the symbol, without the name under it
            int w, h;
            gothic_screen(cpu, surface(cpu), &w, &h);
            double unit = h / 1080.0;
            int sh = (int)lround(SYMBOL_H * unit), sw = sh * ICON_TEXELS_W / SYMBOL_TEXELS_H;
            uint32_t args[5] = { (uint32_t)(w - (int)lround(SYMBOL_RIGHT * unit) - sw),
                                 (uint32_t)((int)lround(VIAL_BOTTOM * unit) - sh), (uint32_t)sw, (uint32_t)sh,
                                 (uint32_t)lround(a * 255) };
            gothic_call(cpu, bl_h2g(client_ImageDraw), sprite, 5, args);
            *th = keep;
        }
    }
    eax = sa, ecx = sc, edx = sd;
}

// CTargeted::Paint with the held weapon in ebx (0 for none): notes its ammo for
// bl_hud_Health. The replacement then goes on to the crosshair.
void bl_hud_Ammo(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, weapon = ebx, player = player_now(cpu);
    int type = weapon && !(weapon & 3) && bl_guest_heap_has(weapon, WEAPON_SIZE) ? (int)field(weapon, 0x7a4) : 0;
    ammo_shown = player && type > 0 && type < 32;
    if (ammo_shown) {
        int clip = (int)field(weapon, 0x7ac);
        ammo_clip = clip > 0 ? clip : 0;
        ammo_reserve = (int)field(player + 0xfdc + 4 * (uint32_t)type, 0);
    }
    ammo_fade = (int)field(fade_global, 0) / 255.0;
    ammo_ns = now_ns();
    eax = sa, ecx = sc, edx = sd;
}
