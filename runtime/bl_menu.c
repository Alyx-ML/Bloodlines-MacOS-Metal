// The pause menu in the gothic style. In a level, Esc opens the client's main menu panel
// (CVMainMenu) with Continue, Reload, Load Game, Save Game, Options and Main Menu. The
// panel and its buttons (CVMenuButton) keep doing all the work: hover, clicks, sounds,
// fades, confirmations and the actions themselves. Hooks change only the look
// (modules/client/instruction_replacements.manual.sci), with the mockup's measurements
// (1920x1080 pixels, scaled to the screen's height):
//   - the menu's Paint (0x10065AF0) first calls bl_menu_Layout, which puts the buttons in
//     a column under the logo;
//   - its PaintBackground (0x10065C40) leaves out the black fill and its smoke (the call at
//     0x10065BDC) is left out too. In its place bl_menu_Smoke has the renderer draw the
//     game, darkened, over everything drawn so far, the HUD included (bl_metal_backdrop,
//     d3d9/metal_render.m), then draws the gold divider under the logo;
//   - the logo's draw (0x10065C15) gets a smaller size, top left (bl_menu_Logo);
//   - each button's Paint (0x100653B0) first calls bl_menu_ButtonPaint, which draws the
//     label in Cinzel capitals, letter-spaced, in ivory. The button under the mouse (the
//     menu's +0x440) is brighter, with a blood drop to its left, an underline from red
//     through gold, and a red glow behind it (drawn by the renderer). The game's own button
//     paint is skipped.
// At the start-up menu (no level loaded) all of them leave the game's look alone. The
// drawing itself is in bl_gothic.c, shared with the options dialog (bl_options.c).
//
// Menu fields: +0x170 the buttons, +0x17c their count, +0x2d8 the logo's fade and +0x2e0
// the buttons' fade (both 0 to 255), +0x440 the button under the mouse. A button's +0xf0
// is its action.
#include <math.h>
#include <stdint.h>

#include "bl_gothic.h"
#include "bl_vm.h"
#include "llasm_cpu.h"

extern char client_ScreenTall[], client_MenuState[], client_Surface[], client_PanelSetPos[], client_PanelSetSize[];

#define field gothic_field
#define ffield gothic_ffield

static uint32_t the_menu;  // the client's main menu panel, once seen
static uint32_t cur_menu;  // the menu painting this frame in the new style, else 0
static int glow[4];        // the hovered label's box, for the renderer

static uint32_t call(void *cpu, const void *fn, uint32_t self, int n, const uint32_t *a)
{
    return gothic_call(cpu, bl_h2g(fn), self, n, a);
}

static uint32_t surface(void *cpu) { return call(cpu, client_Surface, 0, 0, NULL); }

static const char *label(int action)
{
    switch (action) {
    case 0: return "New Game";
    case 1: return "Load Game";
    case 2: return "Reload";
    case 3: return "Save Game";
    case 4: return "Options";
    case 9: return "Main Menu";
    case 10: return "Quit";
    case 11: return "Continue";
    default: return "";
    }
}

// The mockup's pixel (1920x1080) on this screen.
static double unit(void *cpu) { return (double)(int)call(cpu, client_ScreenTall, 0, 0, NULL) / 1080; }

// The layout, in mockup pixels: the logo 560x280 at 160, 96; the divider 560 wide, 22
// under it; the items 44 under that, 30-pixel Cinzel with 10 above and below, the text 44
// in from the column.
enum { COL_X = 160, LOGO_Y = 96, LOGO_W = 560, LOGO_H = 280, RULE_Y = LOGO_Y + LOGO_H + 22 + 12,
       ITEMS_Y = RULE_Y + 12 + 44, TEXT_X = 44, EM = 30, PAD = 10 };

static int row_for(double u) { return gothic_tall(EM * u) + (int)lround(2 * PAD * u); }
static int track_for(double u) { return (int)lround(EM * u * 0.24); }

static void caps_label(uint32_t button, char *caps, int size) { gothic_caps(label((int)field(button, 0xf0)), caps, size); }

// Menu Paint: the buttons in a column under the logo, and the hovered label's box for the
// renderer's glow.
static void layout(void *cpu, uint32_t menu)
{
    double u = unit(cpu);
    int n = (int)field(menu, 0x17c), row = row_for(u);
    uint32_t list = field(menu, 0x170), hover = field(menu, 0x440);
    int x = (int)lround(COL_X * u), y = (int)lround(ITEMS_Y * u);
    glow[0] = glow[1] = glow[2] = glow[3] = 0;
    for (int i = 0; i < n; i++) {
        uint32_t b = field(list, i * 4);
        if (!b) continue;
        uint32_t pos[2] = { x, y + i * row }, wh[2] = { (uint32_t)lround(LOGO_W * u), row };
        call(cpu, client_PanelSetPos, b, 2, pos);
        call(cpu, client_PanelSetSize, b, 2, wh);
        if (b == hover) {
            char caps[32];
            caps_label(b, caps, sizeof caps);
            uint32_t s = surface(cpu);
            int tx = x + (int)lround(TEXT_X * u), ty = y + i * row + (int)lround(PAD * u);
            glow[0] = tx, glow[1] = ty;
            glow[2] = tx + gothic_text_width(cpu, s, gothic_font(cpu, s, EM * u), caps, track_for(u));
            glow[3] = ty + gothic_tall(EM * u);
        }
    }
}

// The divider: a gold hairline fading out at both ends; in the middle a gold diamond
// outline with a red dot, and a small gold lens either side.
static void divider(void *cpu, uint32_t menu)
{
    uint32_t s = surface(cpu);
    double u = unit(cpu), fade = gothic_clamp01(ffield(menu, 0x2d8) / 255);
    int x0 = (int)lround(COL_X * u), w = (int)lround(LOGO_W * u), y = (int)lround(RULE_Y * u);
    static const float rule[3][5] = { { 0, 176, 143, 88, 0 }, { .5f, 176, 143, 88, 1 }, { 1, 176, 143, 88, 0 } };
    gothic_line(cpu, s, x0, x0 + w, y, rule, 3, fade);
    int cx = x0 + w / 2;
    gothic_diamond(cpu, s, cx, y, (int)lround(9 * u), 176, 143, 88, fade);
    gothic_dot(cpu, s, cx, y, (int)lround(2.6 * u), 163, 18, 31, fade);
    // The lenses: 16 wide, 8 tall, their centres 26 either side of the diamond's.
    int half = (int)lround(8 * u), lift = (int)lround(4 * u), off = (int)lround(26 * u);
    gothic_color(cpu, s, 176, 143, 88, fade * 0.7);
    for (int side = -1; side <= 1; side += 2) {
        int lc = cx + side * off;
        for (int dx = -half; dx <= half; dx++) {
            double f = (double)dx / half;
            int dy = (int)lround(lift * (1 - f * f));
            gothic_rect(cpu, s, lc + dx, y - dy, lc + dx + 1, y - dy + 1);
            if (dy) gothic_rect(cpu, s, lc + dx, y + dy, lc + dx + 1, y + dy + 1);
        }
    }
}

// The underline under a chosen item: red to gold at 40% and gone at the end.
static const float underline[3][5] = { { 0, 224, 40, 58, .9f }, { .4f, 176, 143, 88, .5f }, { 1, 176, 143, 88, 0 } };

static void paint_button(void *cpu, uint32_t menu, uint32_t button)
{
    uint32_t s = surface(cpu);
    double u = unit(cpu);
    uint32_t font = gothic_font(cpu, s, EM * u);
    char caps[32];
    caps_label(button, caps, sizeof caps);
    double fade = gothic_clamp01(ffield(menu, 0x2e0) / 255);
    int track = track_for(u), x = (int)lround(TEXT_X * u), y = (int)lround(PAD * u), row = row_for(u);
    if (field(menu, 0x440) == button) {
        // The drop 6 in from the column, 14x20, at the row's middle; the underline 340 long,
        // 6 above the row's bottom.
        gothic_drop(cpu, s, (int)lround(13 * u), row / 2 - (int)lround(9.2 * u), (int)lround(14 * u),
                    (int)lround(20 * u), fade);
        int uy = row - (int)lround(7 * u);
        gothic_line(cpu, s, x, x + (int)lround(340 * u), uy, underline, 3, fade);
        gothic_text(cpu, s, font, caps, x, y, track, 236, 226, 207, fade);
    } else {
        gothic_text(cpu, s, font, caps, x, y, track, 236, 226, 207, fade * 0.62);
    }
}

// The menu state says whether a level is loaded (0 is the start-up menu).
static int in_level(void *cpu, uint32_t menu) { return call(cpu, client_MenuState, menu, 0, NULL) != 0; }

int bl_menu_in_level(void *cpu) { return the_menu && in_level(cpu, the_menu); }

// The replacements push a word; the natives below write 1 there to skip the game's code.
static void answer(_cpu *cpu, uint32_t v) { *(uint32_t *)REG2PTR(esp) = v; }

// CVMainMenu::Paint's first instruction (ecx = the menu). Registers are kept for the
// rest of the routine.
void bl_menu_Layout(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, menu = ecx;
    the_menu = menu;
    cur_menu = in_level(cpu, menu) ? menu : 0;
    if (cur_menu) layout(cpu, menu);
    eax = sa, ecx = sc, edx = sd;
}

// CVMainMenu::PaintBackground's first instruction: in a level, no black fill.
void bl_menu_Background(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = in_level(cpu, ecx);
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// The smoke's call in CVMainMenu::Paint (ecx = the menu): in a level, the renderer draws
// the darkened game over everything so far (the HUD, the crosshair), then the divider.
void bl_menu_Smoke(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0;
    if (cur_menu == ecx) {
        gothic_flush(cpu, surface(cpu));
        bl_metal_backdrop(0, 1, (const int (*)[4])glow, glow[2] > glow[0]);
        divider(cpu, ecx);
        skip = 1;
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// The logo's draw call: x, y, width, height and alpha on the stack. In a level, the
// mockup's place and size.
void bl_menu_Logo(_cpu *cpu)
{
    if (!cur_menu) return;
    uint32_t sa = eax, sc = ecx, sd = edx;
    double u = unit(cpu);
    uint32_t *a = (uint32_t *)REG2PTR(esp);
    a[0] = (uint32_t)lround(COL_X * u), a[1] = (uint32_t)lround(LOGO_Y * u);
    a[2] = (uint32_t)lround(LOGO_W * u), a[3] = (uint32_t)lround(LOGO_H * u);
    eax = sa, ecx = sc, edx = sd;
}

// CVMenuButton::Paint's first instruction (ecx = the button).
void bl_menu_ButtonPaint(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0;
    if (cur_menu) {
        paint_button(cpu, cur_menu, ecx);
        skip = 1;
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}
