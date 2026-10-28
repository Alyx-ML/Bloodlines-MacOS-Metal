// The options dialog in the gothic style of the pause menu (bl_menu.c), to the approved
// mockup (1920x1080 pixels, scaled to the screen's height). GameUI's COptionsDialog is a
// PropertyDialog: a Frame holding a PropertySheet (the tabs and their pages) and OK and
// Cancel. The dialog and its controls keep doing all the work (clicks, keys, cvars, the
// Apply on OK); hooks in GameUI's vgui controls (modules/GameUI/instruction_replacements
// .manual.sci) place them and draw them:
//   - layout, at the end of the game's own: COptionsDialog::PerformLayout (0x10018A4F) makes
//     the dialog full screen with Cancel and OK at the bottom right; PropertySheet::
//     PerformLayout (0x1003F4C0) puts the tabs in a row under the title and the page under
//     them. Done there, and not at paint time, the game's layout can't undo it. The page's
//     controls are placed when the dialog paints (nothing else moves them): in one to three
//     one column of rows in the .res's order, the label on the left and the control on the
//     right, a red bar behind the row under the mouse and what it does on the right of the
//     screen; or on the Controls tab the key list with its
//     buttons in a row under it.
//   - Frame::PaintBackground (0x10021A40): for the dialog, the renderer's darkened backdrop
//     (bl_metal_backdrop: the game in a level, else the start-up menu), the title, its
//     divider, and the blood drop by the setting under the mouse; for a confirmation or
//     message box, over it or anywhere else (the "Please note" after it closes, the pause
//     menu's), a dark panel in a gold frame with its title; for the Load Game and Save
//     Game dialogs, the same panel where the game puts them, over the darkened backdrop.
//   - each control's paint: tabs and buttons (Button::Paint 0x10032BB0), tick boxes (the same,
//     as a diamond and On or Off), labels (Label::Paint 0x10023D80; also the key list's
//     cells), sliders (Slider::PaintBackground 0x10036570; Slider::Paint 0x10036040 is left
//     out), drop-down boxes as "< value >" (TextEntry::PaintBackground 0x100271C0; a click
//     on either half steps through the choices, ComboBox::OnMousePressed 0x10025A90), their lists
//     (Menu::Paint 0x10034480, the items through Button::Paint), scroll bars
//     (ScrollBarSlider 0x100402E0, 0x10040200 left out), and the Controls tab's "press a
//     key" box (after VControlsListPanel's list paint, 0x10010EBB).
//   - backgrounds and borders are left out: Panel::PaintBackground (0x1001D130),
//     Panel::PaintBorder (0x1001D110), PropertyPage::PaintBorder (0x10025300) and
//     ImagePanel::PaintBackground (0x10035490). A selected row of the key list gets a dark
//     red bar instead.
// Only panels inside the options dialog, the Load Game or Save Game dialog, or a
// confirmation or message box change; the rest of GameUI is drawn as before. A text entry
// that is not a drop-down (the save's name) is a dark field with a gold line under it.
//
// The recompiled module's data isn't at the DLL's addresses but keeps its layout: a class's
// vtable is COptionsDialog's (GameUI_OptionsVtable) plus the distance between the two in
// the DLL.
//
// Fields used: the dialog's +0xe4 the sheet, +0xe8 OK, +0xec Cancel; the sheet's +0x64 the
// tab count, +0x6c the tabs, +0x70 the shown page, +0x74 the chosen tab. A panel's +4 is
// its vgui handle, +0x19 whether it is enabled, +0x24 its text colour. A label's +0x60 and
// +0x6c are its images and their count. A button's +0xb8 says the mouse is on it, +0xba
// that it is ticked. A slider's +0x58 is its knob's width, +0x60 and +0x64 the knob's ends,
// +0x78 and +0x7c its range, +0x80 its value, +0x98 its caption (a TextImage), +0x9c its
// tick count. A text entry's +0x58 and +0x60 are its text's length and characters. A combo
// box's +0x12c is its list (a Menu: +0x64 the item count, +0x6c the items). A scroll bar
// knob's +0x58 says it is vertical, +0x5c and +0x60 are its ends. A list's +0xec is its
// header's height, +0x104 a row's; the key list's +0x128 says a key is being set, for row
// +0x12c and column +0x130. A frame's +0x88 is its title (a TextImage).
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#include "bl_gothic.h"
#include "bl_vm.h"
#include "llasm_cpu.h"

extern char GameUI_Surface[], GameUI_Input[], GameUI_IPanel[], GameUI_Label_GetText[], GameUI_Panel_SetPos[],
    GameUI_Panel_SetSize[], GameUI_Panel_GetPos[], GameUI_Panel_GetSize[], GameUI_OptionsVtable[];
int bl_vgui_slider_in_units(uint32_t p);  // bl_vgui.c: the Field of View slider, shown in degrees

#define field gothic_field

// Classes, by their vtables in the DLL.
enum {
    OPTIONS = 0x10054694, PAGE_TAB = 0x1005ad0c, CONFIRM = 0x1004f5c4, MESSAGE_BOX = 0x10059e74,
    BUTTON = 0x10058b34, CHECK = 0x10057ed4, CVAR_TOGGLE = 0x10052424, COMMAND_CHECK = 0x1005185c,
    CVAR_NEGATE = 0x10051ccc, KEY_TOGGLE = 0x100526c4, CONTENT_CHECK = 0x1005491c, SLIDER = 0x100594d4,
    CVAR_SLIDER = 0x10051f7c, LABEL = 0x10056ddc, LABELED_COMBO = 0x10052964, CVAR_COMBO = 0x10051afc,
    COMMAND_COMBO = 0x10052b3c, COMBO = 0x10057714, COMBO_BUTTON = 0x10057474, LIST = 0x1005832c,
    KEY_LIST = 0x10052ee4, COLUMN_BUTTON = 0x10058574, SCROLL_BAR = 0x10059964, MENU_ITEM = 0x1005a7ec,
    FRAME_BUTTON = 0x10056264, FRAME_SYSTEM_BUTTON = 0x10055fac, TEXT_IMAGE = 0x1005a0d4,
    LOAD_GAME = 0x1005383c, SAVE_GAME = 0x10054434,
};

// Methods, by vtable offset: a panel's, the input's, the IPanel's, a text image's, a
// list's, a combo box's and a menu's.
enum { P_GET_NAME = 0x48, P_IS_VISIBLE = 0x58, P_SCREEN_TO_LOCAL = 0x6c, P_PAINT = 0x188, IN_MOUSE_OVER = 0x10,
       IN_CURSOR_POS = 0x6c, IP_CLIENT = 0x4, IP_CHILD_COUNT = 0x40, IP_CHILD = 0x44, IP_PARENT = 0x48,
       TI_GET_TEXT = 0x70, LIST_CELL_BOUNDS = 0x224, COMBO_ACTIVATE_ROW = 0x2d4, MENU_IS_VISIBLE = 0x58 };

// The mockup, in its pixels: the title (40-pixel Cinzel) at 160, 92, its divider at 171;
// the tabs (19-pixel) from 160, 206, 46 apart; the page from 300 to 200 from the bottom;
// Cancel and OK (21-pixel, 64 apart) 160 from the right and 96 from the bottom.
enum { LEFT = 160, TITLE_Y = 92, TITLE_EM = 40, RULE_Y = 171, TABS_Y = 206, TAB_EM = 19, TAB_GAP = 46,
       TAB_PAD = 14, PAGE_Y = 300, PAGE_FOOT = 40, BTN_EM = 21, BTN_GAP = 64, BTN_PAD = 10,
       BTN_BOTTOM = 96, FOOT = 160 };
// A setting: its 15-pixel label, 16 under it the control (30-pixel Cormorant); 54 between
// settings; two columns 640 wide and 160 apart, or three 80 apart.
enum { SET_LABEL_EM = 15, SET_GAP = 16, SET_TALL = 76, SET_SPACE = 54, COL_W = 640, COL_GAP = 160,
       COL3_GAP = 80, VALUE_EM = 30, ARROW_EM = 22, COMBO_W = 320, SLIDER_W = 600, PAGE_BTN_EM = 19 };
// The rows: 960 wide, up to 56 tall (a heading's slot up to 60), less when they don't all
// fit down to 40 from the bottom of the sheet; the label 22 in, the control in the last 380
// (a slider's value in its last 70), its value 26-pixel. The description 120 right of them,
// its title 22-pixel.
enum { ROW_W = 960, ROW_H = 56, ROW_MIN = 38, ROW_TIGHT = 30, ROW_HEAD = 60, ROW_PAD = 22, CTRL_W = 380, NUM_W = 70,
       ROW_VALUE_EM = 26, DESC_GAP = 120, DESC_EM = 22 };

static const int IVORY[3] = { 236, 226, 207 }, GOLD[3] = { 176, 143, 88 }, GOLD_HI[3] = { 230, 201, 143 },
                 BLOOD_HI[3] = { 224, 40, 58 }, MUTED[3] = { 166, 153, 132 };

static uint32_t dialog;          // the options dialog, once seen
static double dialog_seen;       // when it last painted
static uint32_t options_vtable;  // COptionsDialog's in the module
static uint32_t buf;             // guest scratch: text at +0, numbers at +256
static int screen_w, screen_h;

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static uint32_t call(void *cpu, const void *fn, uint32_t self, int n, const uint32_t *a)
{
    return gothic_call(cpu, bl_h2g(fn), self, n, a);
}

static uint32_t vcall(void *cpu, uint32_t obj, uint32_t slot, int n, const uint32_t *a)
{
    return gothic_scall(cpu, obj, slot, n, a);
}

static uint32_t vt(uint32_t dll) { return options_vtable + dll - OPTIONS; }
static int is(uint32_t p, uint32_t dll) { return p && field(p, 0) == vt(dll); }
static int is_check(uint32_t p)
{
    return is(p, CHECK) || is(p, CVAR_TOGGLE) || is(p, COMMAND_CHECK) || is(p, CVAR_NEGATE) || is(p, KEY_TOGGLE) ||
           is(p, CONTENT_CHECK);
}
static int is_slider(uint32_t p) { return is(p, SLIDER) || is(p, CVAR_SLIDER); }
static int is_combo_set(uint32_t p) { return is(p, LABELED_COMBO) || is(p, CVAR_COMBO) || is(p, COMMAND_COMBO); }
static int is_list(uint32_t p) { return is(p, LIST) || is(p, KEY_LIST); }
static uint8_t byte_at(uint32_t a) { return *(const uint8_t *)bl_g2h(a); }

static uint32_t surface(void *cpu) { return call(cpu, GameUI_Surface, 0, 0, NULL); }
static uint32_t input(void *cpu) { return call(cpu, GameUI_Input, 0, 0, NULL); }
static uint32_t ipanel(void *cpu) { return call(cpu, GameUI_IPanel, 0, 0, NULL); }
static double unit(void) { return screen_h / 1080.0; }
static int px(double v) { return (int)lround(v * unit()); }

static int dialog_open(void) { return dialog && field(dialog, 0) == options_vtable && now() - dialog_seen < 0.25; }

// The Load Game or Save Game dialog, while it paints.
static uint32_t games;
static double games_seen;
static int games_open(void) { return games && now() - games_seen < 0.25; }
static uint32_t sheet(void) { return dialog ? field(dialog, 0xe4) : 0; }
static uint32_t page(void) { return sheet() ? field(sheet(), 0x70) : 0; }
static int tab_count(void) { return (int)field(sheet(), 0x64); }
static uint32_t tab(int i) { return field(field(sheet(), 0x6c), i * 4); }

static uint32_t parent_vp(void *cpu, uint32_t vp) { return vp ? vcall(cpu, ipanel(cpu), IP_PARENT, 1, &vp) : 0; }

static uint32_t panel_of(void *cpu, uint32_t vp)
{
    uint32_t c = vp ? vcall(cpu, ipanel(cpu), IP_CLIENT, 1, &vp) : 0;
    return c ? vcall(cpu, c, 4, 0, NULL) : 0;
}

static uint32_t parent(void *cpu, uint32_t p) { return p ? panel_of(cpu, parent_vp(cpu, field(p, 4))) : 0; }

static void get_bounds(void *cpu, uint32_t p, int *x, int *y, int *w, int *h)
{
    uint32_t a[2] = { buf + 256, buf + 260 };
    call(cpu, GameUI_Panel_GetPos, p, 2, a);
    if (x) *x = (int)field(buf, 256);
    if (y) *y = (int)field(buf, 260);
    call(cpu, GameUI_Panel_GetSize, p, 2, a);
    if (w) *w = (int)field(buf, 256);
    if (h) *h = (int)field(buf, 260);
}

// Only what differs is set: a new size has the panel lay out again.
static void set_bounds(void *cpu, uint32_t p, int x, int y, int w, int h)
{
    int ox, oy, ow, oh;
    get_bounds(cpu, p, &ox, &oy, &ow, &oh);
    uint32_t pos[2] = { x, y }, size[2] = { w, h };
    if (ox != x || oy != y) call(cpu, GameUI_Panel_SetPos, p, 2, pos);
    if (ow != w || oh != h) call(cpu, GameUI_Panel_SetSize, p, 2, size);
}

// The confirmation and message boxes open, over the dialog or not.
static uint32_t popup_vp[4];
static double popup_seen[4];

static int popup_open(void)
{
    for (int i = 0; i < 4; i++)
        if (popup_vp[i] && now() - popup_seen[i] < 0.25) return 1;
    return 0;
}

// Whether `p` is in the dialog or one of those boxes, remembered for the frame.
static struct { uint32_t p, frame; uint8_t yes; } seen[512];
static uint32_t frame_no;

static int styled(void *cpu, uint32_t p)
{
    if (!p || (!dialog_open() && !popup_open() && !games_open())) return 0;
    uint32_t h = (p >> 2) * 2654435761u >> 23;
    if (seen[h].p == p && seen[h].frame == frame_no) return seen[h].yes;
    int yes = 0;
    double t = now();
    uint32_t vp = field(p, 4), dv = dialog_open() ? field(dialog, 4) : 0, gv = games_open() ? field(games, 4) : 0;
    for (int k = 0; k < 24 && vp && !yes; k++) {
        if (vp == dv || vp == gv) yes = 1;
        for (int i = 0; i < 4; i++)
            if (popup_vp[i] == vp && t - popup_seen[i] < 0.25) yes = 1;
        vp = parent_vp(cpu, vp);
    }
    seen[h].p = p, seen[h].frame = frame_no, seen[h].yes = (uint8_t)yes;
    return yes;
}

// Whether the mouse is on `p` or inside it.
static int hovered(void *cpu, uint32_t p)
{
    if (!p) return 0;
    uint32_t vp = vcall(cpu, input(cpu), IN_MOUSE_OVER, 0, NULL);
    for (int k = 0; k < 4 && vp; k++, vp = parent_vp(cpu, vp))
        if (vp == field(p, 4)) return 1;
    return 0;
}

static int enabled(uint32_t p) { return byte_at(p + 0x19) != 0; }

// Text without the '&' that marks a hot key (`out` may be `t`).
static void clean(const char *t, char *out, int size)
{
    int n = 0;
    for (int i = 0; t[i] && n < size - 1 && i < 255; i++)
        if (t[i] != '&' || t[i + 1] == ' ' || !t[i + 1]) out[n++] = t[i];
    out[n] = 0;
}

static void label_text(void *cpu, uint32_t label, char *out, int size)
{
    uint32_t a[2] = { buf, 256 };
    *(char *)bl_g2h(buf) = 0;
    call(cpu, GameUI_Label_GetText, label, 2, a);
    clean((const char *)bl_g2h(buf), out, size);
}

static void image_text(void *cpu, uint32_t image, char *out, int size)
{
    uint32_t a[2] = { buf, 256 };
    *(char *)bl_g2h(buf) = 0;
    if (image) vcall(cpu, image, TI_GET_TEXT, 2, a);
    clean((const char *)bl_g2h(buf), out, size);
}

// A key list cell is a label showing the list's text image among its images.
static void cell_text(void *cpu, uint32_t label, char *out, int size)
{
    out[0] = 0;
    uint32_t images = field(label, 0x60);
    for (int i = 0; i < (int)field(label, 0x6c) && i < 8 && !out[0]; i++) {
        uint32_t im = field(images, i * 4);
        if (im && field(im, 0) == vt(TEXT_IMAGE)) image_text(cpu, im, out, size);
    }
    if (!out[0]) label_text(cpu, label, out, size);
}

static void caps(void *cpu, uint32_t label, char *out, int size)
{
    char t[256];
    label_text(cpu, label, t, sizeof t);
    gothic_caps(t, out, size);
}

static void color3(void *cpu, uint32_t s, const int c[3], double a) { gothic_color(cpu, s, c[0], c[1], c[2], a); }
static void text3(void *cpu, uint32_t s, uint32_t font, const char *t, int x, int y, int track, const int c[3],
                  double a)
{
    gothic_text(cpu, s, font, t, x, y, track, c[0], c[1], c[2], a);
}

static void filled_diamond(void *cpu, uint32_t s, int cx, int cy, int r)
{
    for (int k = -r; k <= r; k++) {
        int dx = r - abs(k);
        gothic_rect(cpu, s, cx - dx, cy + k, cx + dx + 1, cy + k + 1);
    }
}

static void frame_rect(void *cpu, uint32_t s, int x0, int y0, int x1, int y1)
{
    gothic_rect(cpu, s, x0, y0, x1, y0 + 1);
    gothic_rect(cpu, s, x0, y1 - 1, x1, y1);
    gothic_rect(cpu, s, x0, y0, x0 + 1, y1);
    gothic_rect(cpu, s, x1 - 1, y0, x1, y1);
}

static const float gold_fade[3][5] = { { 0, 176, 143, 88, 1 }, { .5f, 176, 143, 88, .5f }, { 1, 176, 143, 88, 0 } };
static const float both_fade[3][5] = { { 0, 176, 143, 88, 0 }, { .5f, 176, 143, 88, 1 }, { 1, 176, 143, 88, 0 } };
static const float underline[3][5] = { { 0, 224, 40, 58, .9f }, { .6f, 176, 143, 88, .5f }, { 1, 176, 143, 88, 0 } };
static const float track_fill[2][5] = { { 0, 224, 40, 58, .9f }, { 1, 176, 143, 88, 1 } };

static int tab_track(void) { return px(TAB_EM * 0.26); }
static int btn_track(void) { return px(BTN_EM * 0.26); }
static int label_track(void) { return px(SET_LABEL_EM * 0.3); }
static int control_y(void) { return px(SET_LABEL_EM * 1.35 + SET_GAP); }

// Words wrapped to `width`, into up to `max` lines.
static int wrap_measure(void *cpu, uint32_t s, uint32_t font, const char *t, int width, char lines[][160], int max)
{
    int n = 0;
    char line[160] = "";
    while (*t && n < max) {
        if (*t == '\n') {
            strcpy(lines[n++], line), line[0] = 0, t++;
            continue;
        }
        const char *e = t;
        while (*e && *e != ' ' && *e != '\n') e++;
        char word[160], trial[320];
        int wl = (int)(e - t) < 159 ? (int)(e - t) : 159;
        memcpy(word, t, wl), word[wl] = 0;
        snprintf(trial, sizeof trial, "%s%s%s", line, line[0] ? " " : "", word);
        if (line[0] && gothic_text_width(cpu, s, font, trial, 0) > width) {
            strcpy(lines[n++], line);
            snprintf(line, sizeof line, "%s", word);
        } else {
            snprintf(line, sizeof line, "%s", trial);
        }
        t = e;
        while (*t == ' ') t++;
    }
    if (line[0] && n < max) strcpy(lines[n++], line);
    return n;
}

// wrap_measure's last results: the same texts (the description, the notes) are wrapped
// every frame, and measuring them takes a call into the game per character.
#define WRAP_KEEP 8
#define WRAP_LINES 16
static struct { uint32_t font; int width, max, n; char *text; char lines[WRAP_LINES][160]; } wrapped[WRAP_KEEP];
static int wrap_next;

static int wrap(void *cpu, uint32_t s, uint32_t font, const char *t, int width, char lines[][160], int max)
{
    if (max > WRAP_LINES) return wrap_measure(cpu, s, font, t, width, lines, max);
    for (int i = 0; i < WRAP_KEEP; i++)
        if (wrapped[i].text && wrapped[i].font == font && wrapped[i].width == width && wrapped[i].max == max &&
            !strcmp(wrapped[i].text, t)) {
            memcpy(lines, wrapped[i].lines, sizeof(char[160]) * (size_t)wrapped[i].n);
            return wrapped[i].n;
        }
    int i = wrap_next, n = wrap_measure(cpu, s, font, t, width, wrapped[i].lines, max);
    wrap_next = (wrap_next + 1) % WRAP_KEEP;
    free(wrapped[i].text);
    wrapped[i].text = strdup(t), wrapped[i].font = font, wrapped[i].width = width, wrapped[i].max = max;
    wrapped[i].n = n;
    memcpy(lines, wrapped[i].lines, sizeof(char[160]) * (size_t)n);
    return n;
}

// ---- Layout ----

// Glows behind the chosen tab and the tab or button under the mouse, for the renderer;
// the setting under the mouse gets the blood drop.
static int glows[4][4], nglow;
static int drop_x, drop_y, drop_on;
// The shown page in rows (all but the Controls tab); its sliders' rows, whose label and
// value the dialog paints (the slider itself is only the track); the row under the mouse;
// a heading with no settings after it (the Gameplay tab's patch version), at the bottom;
// the setting described on the right (the last one under the mouse on this page).
static int rows;
static struct { uint32_t p; int x, y, w, h; } row_slider[16];
static int nrow_slider, bar_on, bar_x, bar_y, bar_w, bar_h;
static uint32_t foot_heading[4];
static int nfoot;
static char desc_name[128];
static uint32_t desc_page;
static int desc_x, desc_y, desc_w;
// Where each graphics setting was when first seen (the .res's place, before the rows moved
// it), which keeps the rows in the .res's order. Kept while one dialog (`home_owner`) is
// laid out, and forgotten when another is or it has not been for a second (closed: a
// dialog opened again is built anew, and its settings may take the old ones' addresses).
static struct { uint32_t p, vt; int x, y; } home[128];
static int nhome;
static uint32_t home_owner;
static double home_seen;

static void home_begin(uint32_t owner)
{
    double t = now();
    if (owner != home_owner || t - home_seen > 1.0) nhome = 0, home_owner = owner;
    home_seen = t;
}

static void home_pos(uint32_t p, int *x, int *y)
{
    for (int i = 0; i < nhome; i++)
        if (home[i].p == p && home[i].vt == field(p, 0)) {
            *x = home[i].x, *y = home[i].y;
            return;
        }
    int i = nhome < 128 ? nhome++ : (int)(p >> 4) % 128;
    home[i].p = p, home[i].vt = field(p, 0), home[i].x = *x, home[i].y = *y;
}

static void add_glow(int x, int y, int w, int h)
{
    if (nglow < 4) glows[nglow][0] = x, glows[nglow][1] = y, glows[nglow][2] = x + w, glows[nglow][3] = y + h, nglow++;
}

static void screen(void *cpu, uint32_t s) { gothic_screen(cpu, s, &screen_w, &screen_h); }

// Cancel then OK, from the right.
static void layout_buttons(void *cpu, uint32_t s)
{
    uint32_t b[2] = { field(dialog, 0xec), field(dialog, 0xe8) };
    uint32_t font = gothic_font(cpu, s, BTN_EM * unit());
    int tall = gothic_tall(BTN_EM * unit());
    int right = screen_w - px(LEFT), y = screen_h - px(BTN_BOTTOM) - tall - px(BTN_PAD);
    for (int i = 1; i >= 0; i--) {
        if (!b[i]) continue;
        char t[64];
        caps(cpu, b[i], t, sizeof t);
        int w = gothic_text_width(cpu, s, font, t, btn_track());
        set_bounds(cpu, b[i], right - w, y, w + px(6), tall + px(BTN_PAD));
        right -= w + px(BTN_GAP);
    }
}

static void page_bounds(int *x, int *y, int *w, int *h)
{
    *x = px(LEFT), *y = px(PAGE_Y), *w = screen_w - 2 * px(LEFT);
    *h = screen_h - px(FOOT) - px(PAGE_FOOT) - px(PAGE_Y);
}

static void layout_sheet(void *cpu, uint32_t s)
{
    set_bounds(cpu, sheet(), 0, 0, screen_w, screen_h - px(FOOT));
    uint32_t font = gothic_font(cpu, s, TAB_EM * unit());
    int tall = gothic_tall(TAB_EM * unit()), x = px(LEFT);
    for (int i = 0; i < tab_count(); i++) {
        uint32_t t = tab(i);
        if (!t) continue;
        char c[64];
        caps(cpu, t, c, sizeof c);
        int w = gothic_text_width(cpu, s, font, c, tab_track());
        set_bounds(cpu, t, x, px(TABS_Y), w + px(6), tall + px(TAB_PAD));
        x += w + px(TAB_GAP);
    }
    int x0, y0, w, h;
    page_bounds(&x0, &y0, &w, &h);
    if (page()) set_bounds(cpu, page(), x0, y0, w, h);
}

// A page's controls, by kind.
enum { K_OTHER, K_CHECK, K_SLIDER, K_COMBO, K_NOTE, K_HEADING, K_LIST, K_BUTTON };

static int kind_of(void *cpu, uint32_t p)
{
    if (is_check(p)) return K_CHECK;
    if (is_slider(p)) return K_SLIDER;
    if (is_combo_set(p)) return K_COMBO;
    if (is_list(p)) return K_LIST;
    if (is(p, LABEL)) {
        const char *name = (const char *)bl_g2h(vcall(cpu, p, P_GET_NAME, 0, NULL));
        return !strcmp(name, "Note") ? K_NOTE : K_HEADING;
    }
    // Anything else painted by Button::Paint is a button.
    if (field(field(p, 0), P_PAINT) == field(vt(BUTTON), P_PAINT)) return K_BUTTON;
    return K_OTHER;
}

static uint32_t body_font(void *cpu, uint32_t s, double em) { return gothic_face_font(cpu, s, GOTHIC_BODY, em); }
static int body_tall(double em) { return gothic_face_tall(GOTHIC_BODY, em); }

// A drop-down setting: its label on top, the box under it. The box's own list button (at
// its right end, under the ">") is shrunk to nothing, so a click there reaches the box
// (bl_options_ComboPressed) and steps instead of opening the list.
// In rows the label takes the row's left and the box its last CTRL_W.
static void layout_combo_set(void *cpu, uint32_t set, int w, int h)
{
    uint32_t vp = field(set, 4), ip = ipanel(cpu);
    int n = (int)vcall(cpu, ip, IP_CHILD_COUNT, 1, &vp);
    for (int i = 0; i < n && i < 8; i++) {
        uint32_t a[2] = { vp, i }, c = panel_of(cpu, vcall(cpu, ip, IP_CHILD, 2, a));
        if (is(c, LABEL))
            set_bounds(cpu, c, 0, 0, rows ? w - px(CTRL_W) : w,
                       rows ? h : gothic_tall(SET_LABEL_EM * unit()) + px(2));
        else if (is(c, COMBO)) {
            if (rows) set_bounds(cpu, c, w - px(CTRL_W), (h - px(36)) / 2, px(CTRL_W) - px(ROW_PAD), px(36));
            else set_bounds(cpu, c, 0, control_y(), px(COMBO_W), px(40));
            uint32_t cvp = field(c, 4);
            int m = (int)vcall(cpu, ip, IP_CHILD_COUNT, 1, &cvp);
            for (int j = 0; j < m && j < 8; j++) {
                uint32_t b[2] = { cvp, j }, k = panel_of(cpu, vcall(cpu, ip, IP_CHILD, 2, b));
                if (is(k, COMBO_BUTTON)) set_bounds(cpu, k, 0, 0, 0, 0);
            }
        }
    }
}

static int hovered_vp(void *cpu, uint32_t mouse, uint32_t p)
{
    for (int d = 0; d < 4 && mouse; d++, mouse = parent_vp(cpu, mouse))
        if (mouse == field(p, 4)) return 1;
    return 0;
}

// What each setting does, shown on the right for the one under the mouse.
static const char *const descriptions[][2] = {
    { "Resolution", "The size of the picture. Higher is sharper, lower is faster." },
    { "Display Mode", "In a window, a borderless window over the whole screen, or full screen." },
    { "Upscaler", "What enlarges the picture to the screen's size: Apple's MetalFX or AMD's FSR 4. Both "
                  "also smooth jagged edges. None draws it at full size with MetalFX smoothing the edges "
                  "only." },
    { "Upscaling Quality", "How big the picture is drawn before it is enlarged. Native draws it at full "
                           "size; the lower settings are faster but softer. Not used with no upscaler." },
    { "Image Quality", "The game's own edge smoothing and texture filtering. Here the upscaler smooths "
                       "the edges and textures are always filtered at their sharpest, so it changes "
                       "little." },
    { "Lighting", "How the world is lit. Higher looks better and costs more." },
    { "Bump Mapping", "Relief on walls, floors and characters from their surface maps." },
    { "Shadows", "How characters and objects cast shadows. Enhanced gives sharp shadows with soft edges "
                 "from the lamps around them." },
    { "Shadow Count", "How many shadows are drawn at once." },
    { "Particles", "How much smoke, sparks, dust and blood the effects throw." },
    { "Geometric Detail", "How far away models keep their full detail." },
    { "Gamma", "How bright the darker shades are. Raise it if the night is too dark to see." },
    { "Combat Effects", "The flashes and blood of hits in a fight." },
    { "Global Illumination", "Light from the lamps in the scene filling the shadows, on top of the game's "
                             "own lighting." },
    { "Bounced Light", "Light thrown back off nearby walls and floors, taking on their colour." },
    { "Ambient Occlusion", "Soft shade in corners, in creases and where objects meet the ground." },
    { "Volumetric Light", "Haze in the light of lamps and windows, with beams where walls, pillars and "
                          "railings cut it." },
    { "HDR", "Brighter lights and richer colour on a screen that shows high dynamic range." },
    { "Bloom", "A soft glow around bright lights." },
    { "Eye Adaptation", "The picture brightens in dark places and dims in bright ones, the way eyes "
                        "adjust." },
    { "Sharpening", "Sharpens the picture after its edges are smoothed." },
    { "Reflections", "Shiny floors, glass and puddles reflect what is around them." },
    { "Skin Scattering", "Light passing softly into skin, so faces look less waxy." },
    { "Smooth Characters", "Rounder characters, without the corners of their original shapes." },
    { "Skin Detail", "Fine pores and creases on faces and hands." },
    { "Rain Effects", "Where it rains, streets and pavements turn dark and shiny, with puddles that "
                     "reflect the lights and ripple in the rain. Grass, dirt and sand stay as they are." },
    { "Lens Glare", "Bright lamps streak and glow at night, as through a camera's lens." },
    { "Depth of Field", "The picture focuses on what you look at, as a camera's lens does: what is near "
                        "stays sharp and the distance goes soft. In conversations the one you talk to "
                        "stays sharp and the background goes soft, as in a film's close-up." },
    { "Motion Blur", "Moving people and things blur along their motion, as through a film camera. The view "
                     "itself blurs only when you turn quickly." },
    { "Auto Renew Disciplines", "A discipline starts again by itself when it runs out, while you have "
                                "the blood for it." },
    { "Show Damage Floaters", "Numbers rise from those you hit, showing the damage." },
    { "Quest Compass", "A marker at the top of the screen pointing the way to your quest." },
    { "Skip Intro Movies", "Starts the game at the main menu, without the company logos first." },
    { "First-person Body", "Look down to see your own body, legs and feet." },
    { "Field of View", "How wide you see, in degrees. The game's own is 75; higher shows more at the "
                       "sides." },
    { "Volume", "How loud the sound effects are." },
    { "High Quality Audio", "Better sound, at a little more work for the computer." },
    { "Environmental Effects", "Echoes and the sound of the room around you." },
    { "View Subtitles", "What is said shown as text." },
    { "Mouse Look", "The mouse turns the view." },
    { "Invert Mouse", "Moving the mouse forward looks down." },
    { "Mouse Filter", "Smooths the mouse's movement over two frames." },
    { "Mouse Sensitivity", "How far the view turns for a move of the mouse." },
};

static const char *description(const char *name)
{
    for (size_t i = 0; i < sizeof descriptions / sizeof descriptions[0]; i++)
        if (!strcasecmp(descriptions[i][0], name)) return descriptions[i][1];
    return NULL;
}

// A setting's name: a tick box's label, a slider's caption, a drop-down's label.
static void setting_name(void *cpu, uint32_t p, int kind, char *out, int size)
{
    out[0] = 0;
    if (kind == K_CHECK) label_text(cpu, p, out, size);
    else if (kind == K_SLIDER) image_text(cpu, field(p, 0x98), out, size);
    else if (kind == K_COMBO) {
        uint32_t vp = field(p, 4), ip = ipanel(cpu);
        int n = (int)vcall(cpu, ip, IP_CHILD_COUNT, 1, &vp);
        for (int i = 0; i < n && i < 8 && !out[0]; i++) {
            uint32_t a[2] = { vp, i }, c = panel_of(cpu, vcall(cpu, ip, IP_CHILD, 2, a));
            if (is(c, LABEL)) label_text(cpu, c, out, size);
        }
    }
}

static int is_setting(int kind) { return kind == K_CHECK || kind == K_SLIDER || kind == K_COMBO; }

// The settings in order (by the .res's columns, then top to bottom) as one column of rows
// from `top`, made shorter when they don't all fit; a heading with no settings after it at
// the bottom.
static void layout_rows(void *cpu, uint32_t pg, const uint32_t *ps, const int *kinds, const int *ws,
                        const int *hs0, int k, int top, int pw, int ph, int x0, int y0)
{
    int foot[40] = { 0 }, nh = 0, nr = 0, other = 0, after = 0;
    for (int a = k - 1; a >= 0; a--) {
        if (is_setting(kinds[a])) after = 1;
        if (kinds[a] == K_HEADING && !after) foot[a] = 1;
    }
    for (int a = 0; a < k; a++) {
        if (foot[a]) continue;
        if (kinds[a] == K_HEADING) nh++;
        else if (is_setting(kinds[a])) nr++;
        else other += kinds[a] == K_BUTTON ? gothic_tall(PAGE_BTN_EM * unit()) + px(10) : hs0[a];
    }
    int htall = gothic_tall(17 * unit()) + px(14), want = nh * px(ROW_HEAD) + nr * px(ROW_H);
    int room = ph - top - other;
    for (int a = 0; a < k; a++)
        if (foot[a]) room -= htall;
    double f = want > room && want > 0 ? (double)room / want : 1;
    int rh = (int)(px(ROW_H) * f), hh = (int)(px(ROW_HEAD) * f);
    if (rh < px(ROW_MIN)) rh = px(ROW_MIN);
    if (hh < htall + px(4)) hh = htall + px(4);
    // Still too many (the Enhanced tab's): the rows share what the headings leave, down to
    // ROW_TIGHT, so the last one is not cut off.
    if (nr && nh * hh + nr * rh > room) {
        int fit = (room - nh * hh) / nr;
        rh = fit < px(ROW_TIGHT) ? px(ROW_TIGHT) : fit;
    }
    int w = pw < px(ROW_W) ? pw : px(ROW_W);
    if (pg != desc_page) desc_page = pg, desc_name[0] = 0;
    desc_x = x0 + w + px(DESC_GAP), desc_y = y0 + top, desc_w = pw - w - px(DESC_GAP);
    uint32_t mouse = vcall(cpu, input(cpu), IN_MOUSE_OVER, 0, NULL);
    int y = top;
    for (int a = 0; a < k; a++) {
        uint32_t p = ps[a];
        int kind = kinds[a];
        if (foot[a]) {
            set_bounds(cpu, p, 0, ph - htall, w, htall);
            if (nfoot < 4) foot_heading[nfoot++] = p;
            continue;
        }
        int h = kind == K_HEADING  ? hh
                : kind == K_BUTTON ? gothic_tall(PAGE_BTN_EM * unit()) + px(10)
                : kind == K_OTHER  ? hs0[a]
                                   : rh;
        if (kind == K_SLIDER) {
            set_bounds(cpu, p, w - px(CTRL_W), y, px(CTRL_W) - px(NUM_W), h);
            if (nrow_slider < 16) {
                row_slider[nrow_slider].p = p, row_slider[nrow_slider].x = x0, row_slider[nrow_slider].y = y0 + y;
                row_slider[nrow_slider].w = w, row_slider[nrow_slider].h = h, nrow_slider++;
            }
        } else if (kind == K_HEADING)
            set_bounds(cpu, p, 0, y + h - htall, w, htall);
        else set_bounds(cpu, p, 0, y, kind == K_OTHER ? ws[a] : w, h);
        if (kind == K_COMBO) layout_combo_set(cpu, p, w, h);
        if (is_setting(kind) && hovered_vp(cpu, mouse, p)) {
            bar_on = 1, bar_x = x0, bar_y = y0 + y, bar_w = w, bar_h = h;
            drop_on = 1, drop_x = x0 - px(28), drop_y = y0 + y + (h - px(17)) / 2;
            setting_name(cpu, p, kind, desc_name, sizeof desc_name);
        }
        y += h;
    }
}

static void layout_page(void *cpu, uint32_t s, uint32_t pg)
{
    struct { uint32_t p; int kind, x, y, w, h; } it[40];
    int n = 0, pw, ph, x0, y0;
    home_begin(dialog);
    page_bounds(&x0, &y0, &pw, &ph);
    uint32_t vp = field(pg, 4), ip = ipanel(cpu);
    int count = (int)vcall(cpu, ip, IP_CHILD_COUNT, 1, &vp), has_list = 0;
    for (int i = 0; i < count && n < 40; i++) {
        uint32_t a[2] = { vp, i }, c = panel_of(cpu, vcall(cpu, ip, IP_CHILD, 2, a));
        if (!c || !(vcall(cpu, c, P_IS_VISIBLE, 0, NULL) & 0xff)) continue;
        it[n].p = c, it[n].kind = kind_of(cpu, c);
        get_bounds(cpu, c, &it[n].x, &it[n].y, &it[n].w, &it[n].h);
        home_pos(c, &it[n].x, &it[n].y);
        has_list |= it[n].kind == K_LIST;
        n++;
    }
    drop_on = 0, bar_on = 0, nrow_slider = 0, nfoot = 0;
    rows = !has_list;
    if (rows) {
        ph = screen_h - px(FOOT) - px(PAGE_Y);
        set_bounds(cpu, pg, x0, y0, pw, ph);
    }
    if (has_list) {
        // The Controls tab: the list, its buttons in a row under it.
        int bt = gothic_tall(PAGE_BTN_EM * unit()) + px(10), x = 0;
        uint32_t font = gothic_font(cpu, s, PAGE_BTN_EM * unit());
        for (int i = 0; i < n; i++)
            if (it[i].kind == K_LIST) {
                uint32_t l = it[i].p;
                *(uint32_t *)bl_g2h(l + 0x104) = (uint32_t)px(32);
                *(uint32_t *)bl_g2h(l + 0xec) = (uint32_t)px(34);
                set_bounds(cpu, l, 0, 0, pw, ph - bt - px(30));
            }
        for (int i = 0; i < n; i++)
            if (it[i].kind == K_BUTTON) {
                char t[64];
                caps(cpu, it[i].p, t, sizeof t);
                int w = gothic_text_width(cpu, s, font, t, px(PAGE_BTN_EM * 0.26));
                set_bounds(cpu, it[i].p, x, ph - bt, w + px(6), bt);
                x += w + px(BTN_GAP);
            }
        return;
    }
    // Notes across the top; the rest in columns by their x, each top to bottom.
    int top = 0;
    for (int i = 0; i < n; i++)
        if (it[i].kind == K_NOTE) {
            char t[256], lines[6][160];
            int w = pw < px(rows ? ROW_W : 1200) ? pw : px(rows ? ROW_W : 1200);
            label_text(cpu, it[i].p, t, sizeof t);
            int k = wrap(cpu, s, body_font(cpu, s, 24 * unit()), t, w, lines, 6);
            int h = k * body_tall(24 * unit());
            set_bounds(cpu, it[i].p, 0, top, w, h > 0 ? h : 1);
            top += h + px(36);
        }
    int order[40], m = 0;
    for (int i = 0; i < n; i++)
        if (it[i].kind != K_NOTE) order[m++] = i;
    for (int a = 1; a < m; a++)  // by x
        for (int b = a; b > 0 && it[order[b]].x < it[order[b - 1]].x; b--) {
            int t = order[b];
            order[b] = order[b - 1], order[b - 1] = t;
        }
    int col[40], ncol = 0, start = 0;
    for (int a = 0; a < m; a++) {
        if (a > 0 && it[order[a]].x - start > px(100) && ncol < 2) ncol++, start = it[order[a]].x;
        if (a == 0) start = it[order[a]].x;
        col[a] = ncol;
    }
    ncol = m ? col[m - 1] + 1 : 0;
    if (rows) {
        uint32_t ps[40];
        int kinds[40], ws[40], hs[40], k = 0;
        for (int c = 0; c < ncol; c++) {
            int idx[40], q = 0;
            for (int a = 0; a < m; a++)
                if (col[a] == c) idx[q++] = order[a];
            for (int a = 1; a < q; a++)  // by y
                for (int b = a; b > 0 && it[idx[b]].y < it[idx[b - 1]].y; b--) {
                    int t = idx[b];
                    idx[b] = idx[b - 1], idx[b - 1] = t;
                }
            for (int a = 0; a < q; a++)
                ps[k] = it[idx[a]].p, kinds[k] = it[idx[a]].kind, ws[k] = it[idx[a]].w, hs[k] = it[idx[a]].h, k++;
        }
        layout_rows(cpu, pg, ps, kinds, ws, hs, k, top, pw, ph, x0, y0);
        return;
    }
    int colw = ncol <= 2 ? px(COL_W) : (pw - 2 * px(COL3_GAP)) / 3;
    int gapc = ncol <= 2 ? px(COL_GAP) : px(COL3_GAP);
    uint32_t mouse = vcall(cpu, input(cpu), IN_MOUSE_OVER, 0, NULL);
    for (int c = 0; c < ncol; c++) {
        int idx[40], hs[40], k = 0, sum = 0;
        for (int a = 0; a < m; a++)
            if (col[a] == c) idx[k++] = order[a];
        for (int a = 1; a < k; a++)  // by y
            for (int b = a; b > 0 && it[idx[b]].y < it[idx[b - 1]].y; b--) {
                int t = idx[b];
                idx[b] = idx[b - 1], idx[b - 1] = t;
            }
        for (int a = 0; a < k; a++) {
            int kind = it[idx[a]].kind;
            hs[a] = kind == K_HEADING  ? px(44)
                    : kind == K_OTHER  ? it[idx[a]].h
                    : kind == K_BUTTON ? gothic_tall(PAGE_BTN_EM * unit()) + px(10)
                                       : px(SET_TALL);
            sum += hs[a];
        }
        int gap = px(SET_SPACE);
        if (k > 1 && top + sum + gap * (k - 1) > ph) gap = (ph - top - sum) / (k - 1);
        if (gap < px(8)) gap = px(8);
        int y = top, x = c * (colw + gapc);
        for (int a = 0; a < k; a++) {
            uint32_t p = it[idx[a]].p;
            int kind = it[idx[a]].kind;
            int w = kind == K_SLIDER  ? (colw < px(SLIDER_W) ? colw : px(SLIDER_W))
                    : kind == K_OTHER ? it[idx[a]].w
                                      : colw;
            set_bounds(cpu, p, x, y, w, hs[a]);
            if (kind == K_COMBO) layout_combo_set(cpu, p, w, hs[a]);
            if (kind == K_CHECK || kind == K_SLIDER || kind == K_COMBO) {
                uint32_t v = mouse;
                for (int d = 0; d < 4 && v; d++, v = parent_vp(cpu, v))
                    if (v == field(p, 4)) {
                        drop_on = 1, drop_x = x0 + x - px(28), drop_y = y0 + y + control_y() + px(10);
                        break;
                    }
            }
            y += hs[a] + gap;
        }
    }
}

// ---- Drawing ----

static void paint_dialog(void *cpu, uint32_t s)
{
    gothic_flush(cpu, s);
    bl_metal_backdrop(1, bl_menu_in_level(cpu), (const int (*)[4])glows, nglow, screen_w, screen_h);
    uint32_t font = gothic_font(cpu, s, TITLE_EM * unit());
    text3(cpu, s, font, "OPTIONS", px(LEFT), px(TITLE_Y), px(TITLE_EM * 0.32), IVORY, 1);
    gothic_line(cpu, s, px(LEFT + 22), px(LEFT + 560), px(RULE_Y), gold_fade, 3, 1);
    gothic_diamond(cpu, s, px(LEFT + 10), px(RULE_Y), px(9), GOLD[0], GOLD[1], GOLD[2], 1);
    gothic_dot(cpu, s, px(LEFT + 10), px(RULE_Y), px(2.6), 163, 18, 31, 1);
    if (bar_on) {
        int steps = 48;
        for (int k = 0; k < steps; k++) {
            double t = (k + 0.5) / steps;
            gothic_color(cpu, s, 110, 12, 22, 0.5 * (t < 0.6 ? 1 - 0.5 * t / 0.6 : 0.5 * (1 - t) / 0.4));
            gothic_rect(cpu, s, bar_x + bar_w * k / steps, bar_y, bar_x + bar_w * (k + 1) / steps, bar_y + bar_h);
        }
        color3(cpu, s, BLOOD_HI, 0.8);
        gothic_rect(cpu, s, bar_x, bar_y, bar_x + px(3), bar_y + bar_h);
    }
    for (int i = 0; i < nrow_slider; i++) {
        uint32_t p = row_slider[i].p;
        int x = row_slider[i].x, y = row_slider[i].y, w = row_slider[i].w, h = row_slider[i].h;
        char t[128], c[128], num[16];
        image_text(cpu, field(p, 0x98), t, sizeof t);
        gothic_caps(t, c, sizeof c);
        int on = bar_on && bar_x == x && bar_y == y;
        text3(cpu, s, gothic_font(cpu, s, SET_LABEL_EM * unit()), c, x + px(ROW_PAD),
              y + (h - gothic_tall(SET_LABEL_EM * unit())) / 2, label_track(), on ? GOLD_HI : GOLD, 1);
        int lo = (int)field(p, 0x78), hi = (int)field(p, 0x7c), v = (int)field(p, 0x80);
        snprintf(num, sizeof num, "%d", bl_vgui_slider_in_units(p) ? v : hi > lo ? (int)lround(100.0 * (v - lo) / (hi - lo)) : 0);
        uint32_t nf = gothic_font(cpu, s, 18 * unit());
        text3(cpu, s, nf, num, x + w - px(ROW_PAD) - gothic_text_width(cpu, s, nf, num, px(2)),
              y + (h - gothic_tall(18 * unit())) / 2, px(2), IVORY, enabled(p) ? 1 : 0.35);
    }
    if (rows && desc_name[0] && desc_w > px(200)) {
        char c[128], lines[8][160];
        gothic_caps(desc_name, c, sizeof c);
        uint32_t tf = gothic_font(cpu, s, DESC_EM * unit());
        text3(cpu, s, tf, c, desc_x, desc_y, px(DESC_EM * 0.3), IVORY, 1);
        int ly = desc_y + gothic_tall(DESC_EM * unit()) + px(14);
        gothic_line(cpu, s, desc_x, desc_x + desc_w, ly, gold_fade, 3, 0.8);
        const char *d = description(desc_name);
        if (d) {
            uint32_t bf = body_font(cpu, s, 26 * unit());
            int n = wrap(cpu, s, bf, d, desc_w, lines, 8);
            for (int i = 0; i < n; i++)
                text3(cpu, s, bf, lines[i], desc_x, ly + px(22) + i * body_tall(26 * unit()), 0, MUTED, 1);
        }
    }
    if (drop_on) gothic_drop(cpu, s, drop_x, drop_y, px(12), px(17), 1);
}

// The glows for the backdrop: the chosen tab, the tab or button under the mouse.
static void collect_glows(void *cpu, uint32_t s)
{
    nglow = 0;
    uint32_t font = gothic_font(cpu, s, TAB_EM * unit());
    for (int i = 0; i < tab_count(); i++) {
        uint32_t t = tab(i);
        if (!t || (t != field(sheet(), 0x74) && !hovered(cpu, t))) continue;
        int x, y;
        char c[64];
        get_bounds(cpu, t, &x, &y, NULL, NULL);
        caps(cpu, t, c, sizeof c);
        add_glow(x, y, gothic_text_width(cpu, s, font, c, tab_track()), gothic_tall(TAB_EM * unit()));
    }
    uint32_t b[2] = { field(dialog, 0xec), field(dialog, 0xe8) };
    for (int i = 0; i < 2; i++)
        if (b[i] && hovered(cpu, b[i])) {
            int x, y, w;
            get_bounds(cpu, b[i], &x, &y, &w, NULL);
            add_glow(x, y, w - px(6), gothic_tall(BTN_EM * unit()));
        }
}

// Spaced capitals, underlined when chosen: the tabs, Cancel and OK, the other buttons.
static void paint_caps_button(void *cpu, uint32_t p, double em, int on, int over, double rest)
{
    uint32_t s = surface(cpu);
    uint32_t font = gothic_font(cpu, s, em);
    int track = (int)lround(em * 0.26), tall = gothic_tall(em), h;
    char c[64];
    caps(cpu, p, c, sizeof c);
    get_bounds(cpu, p, NULL, NULL, NULL, &h);
    int y = (h - tall - px(8)) / 2;
    if (y < 0) y = 0;
    if (on) gothic_line(cpu, s, 0, gothic_text_width(cpu, s, font, c, track) + px(6), y + tall + px(6), underline, 3, 1);
    double a = !enabled(p) ? 0.22 : on ? 1 : over ? 0.85 : rest;
    text3(cpu, s, font, c, 0, y, track, IVORY, a);
}

static void paint_setting_label(void *cpu, uint32_t s, const char *text, int on, int h)
{
    char c[128];
    gothic_caps(text, c, sizeof c);
    int x = rows ? px(ROW_PAD) : 0, y = rows ? (h - gothic_tall(SET_LABEL_EM * unit())) / 2 : 0;
    text3(cpu, s, gothic_font(cpu, s, SET_LABEL_EM * unit()), c, x, y, label_track(), on ? GOLD_HI : GOLD, 1);
}

// A tick box: its label, then a diamond (filled red when ticked) and On or Off.
static void paint_check(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu);
    char t[128];
    label_text(cpu, p, t, sizeof t);
    int over = hovered(cpu, p), on = byte_at(p + 0xba) != 0, w, h;
    get_bounds(cpu, p, NULL, NULL, &w, &h);
    double a = enabled(p) ? 1 : 0.35;
    paint_setting_label(cpu, s, t, over, h);
    int cy = rows ? h / 2 : control_y() + px(20), r = px(12.7), cx = rows ? w - px(CTRL_W) + px(13) : px(13);
    gothic_diamond(cpu, s, cx, cy, r, GOLD_HI[0], GOLD_HI[1], GOLD_HI[2], a);
    if (on) {
        color3(cpu, s, BLOOD_HI, a);
        filled_diamond(cpu, s, cx, cy, r - px(4.5));
    }
    double em = (rows ? ROW_VALUE_EM : VALUE_EM) * unit();
    uint32_t font = body_font(cpu, s, em);
    text3(cpu, s, font, on ? "On" : "Off", cx + px(27), cy - body_tall(em) / 2, 0, on ? IVORY : MUTED, a);
}

// A slider: its caption and value on top, under them the track, red to gold up to the
// diamond knob.
static void paint_slider(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu);
    int w, h;
    get_bounds(cpu, p, NULL, NULL, &w, &h);
    double a = enabled(p) ? 1 : 0.35;
    if (!rows) {
        char t[128], num[16];
        image_text(cpu, field(p, 0x98), t, sizeof t);
        paint_setting_label(cpu, s, t, hovered(cpu, p), h);
        int lo = (int)field(p, 0x78), hi = (int)field(p, 0x7c), v = (int)field(p, 0x80);
        snprintf(num, sizeof num, "%d", bl_vgui_slider_in_units(p) ? v : hi > lo ? (int)lround(100.0 * (v - lo) / (hi - lo)) : 0);
        uint32_t nf = gothic_font(cpu, s, 18 * unit());
        text3(cpu, s, nf, num, w - gothic_text_width(cpu, s, nf, num, px(2)), 0, px(2), IVORY, a);
    }
    int knob_w = (int)field(p, 0x58), x0 = knob_w / 2, x1 = w - knob_w / 2;
    int cx = ((int)field(p, 0x60) + (int)field(p, 0x64)) / 2, y = rows ? h / 2 : control_y() + px(16);
    if (cx < x0) cx = x0;
    if (cx > x1) cx = x1;
    color3(cpu, s, GOLD, 0.3 * a);
    gothic_rect(cpu, s, x0, y, x1, y + 1);
    if (cx > x0) gothic_line(cpu, s, x0, cx, y, track_fill, 2, a);
    int ticks = (int)field(p, 0x9c);
    if (ticks > 1 && ticks < 40) {
        color3(cpu, s, GOLD, 0.35 * a);
        for (int i = 0; i <= ticks; i++) {
            int tx = x0 + (x1 - x0) * i / ticks;
            gothic_rect(cpu, s, tx, y + px(7), tx + 1, y + px(11));
        }
    }
    int r = px(10);
    gothic_color(cpu, s, 18, 6, 7, 1);
    filled_diamond(cpu, s, cx, y, r);
    gothic_diamond(cpu, s, cx, y, r, GOLD_HI[0], GOLD_HI[1], GOLD_HI[2], a);
    color3(cpu, s, BLOOD_HI, a);
    filled_diamond(cpu, s, cx, y, px(2.5));
}

// A drop-down box: "< value >", a click stepping through the list.
static void paint_combo(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu);
    int w, h;
    get_bounds(cpu, p, NULL, NULL, &w, &h);
    char t[160];
    int len = (int)field(p, 0x58);
    len = len < 0 ? 0 : len > 159 ? 159 : len;
    memcpy(t, bl_g2h(field(p, 0x60)), len), t[len] = 0;
    clean(t, t, sizeof t);
    int over = hovered(cpu, parent(cpu, p));
    double a = enabled(p) ? 1 : 0.35;
    double vem = (rows ? ROW_VALUE_EM : VALUE_EM) * unit();
    uint32_t af = gothic_font(cpu, s, ARROW_EM * unit()), vf = body_font(cpu, s, vem);
    int at = gothic_tall(ARROW_EM * unit()), right = w - px(24);
    text3(cpu, s, af, "<", 0, (h - at) / 2, 0, GOLD_HI, a * (over ? 1 : 0.8));
    text3(cpu, s, af, ">", right, (h - at) / 2, 0, GOLD_HI, a * (over ? 1 : 0.8));
    int tw = gothic_text_width(cpu, s, vf, t, 0);
    text3(cpu, s, vf, t, (right + px(14) - tw) / 2, (h - body_tall(vem)) / 2, 0, IVORY, a);
}

// A key list cell, a drop-down setting's label, a heading on the Enhanced tab, a page's
// note or a box's message.
static void paint_label(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu), up = parent(cpu, p);
    int w, h, x;
    get_bounds(cpu, p, &x, NULL, &w, &h);
    char t[256], c[256];
    if (is_list(up)) {
        cell_text(cpu, p, t, sizeof t);
        int lw;
        get_bounds(cpu, up, NULL, NULL, &lw, NULL);
        if ((field(p, 0x24) & 0xffffff) == 0x44584c) {  // the key list's section headings
            gothic_caps(t, c, sizeof c);
            uint32_t f = gothic_font(cpu, s, 14 * unit());
            text3(cpu, s, f, c, px(6), (h - gothic_tall(14 * unit())) / 2, px(4), GOLD, 1);
            return;
        }
        double em = h * 0.7 / 1.25;
        int first = x < lw * 2 / 5;
        text3(cpu, s, body_font(cpu, s, em), t, px(6), (h - body_tall(em)) / 2, 0, first ? IVORY : GOLD_HI,
              first ? 0.92 : 0.9);
        return;
    }
    label_text(cpu, p, t, sizeof t);
    if (is_combo_set(up)) {
        paint_setting_label(cpu, s, t, hovered(cpu, up), h);
        return;
    }
    int on_page = up && up == page();
    if (on_page && strcmp((const char *)bl_g2h(vcall(cpu, p, P_GET_NAME, 0, NULL)), "Note")) {
        gothic_caps(t, c, sizeof c);
        uint32_t f = gothic_font(cpu, s, 17 * unit());
        int foot = 0;
        for (int i = 0; i < nfoot; i++) foot |= foot_heading[i] == p;
        text3(cpu, s, f, c, 0, 0, px(17 * 0.3), foot ? MUTED : GOLD_HI, foot ? 0.8 : 1);
        if (rows && !foot) gothic_line(cpu, s, 0, w, gothic_tall(17 * unit()) + px(10), gold_fade, 3, 0.6);
        return;
    }
    // Body text, wrapped: a note muted, a message in ivory.
    double em = 24 * unit();
    uint32_t f = body_font(cpu, s, em);
    char lines[8][160];
    int n = wrap(cpu, s, f, t, w, lines, 8);
    for (int i = 0; i < n; i++)
        text3(cpu, s, f, lines[i], 0, i * body_tall(em), 0, on_page ? MUTED : IVORY, on_page ? 0.9 : 1);
}

// A list's header: spaced gold capitals.
static void paint_column(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu);
    int h;
    get_bounds(cpu, p, NULL, NULL, NULL, &h);
    char c[64];
    caps(cpu, p, c, sizeof c);
    uint32_t f = gothic_font(cpu, s, 14 * unit());
    text3(cpu, s, f, c, px(6), (h - gothic_tall(14 * unit())) / 2, px(4), GOLD, 1);
}

// A drop-down list's item: body text, a red bar under the mouse.
static void paint_menu_item(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu);
    int w, h;
    get_bounds(cpu, p, NULL, NULL, &w, &h);
    char t[160];
    label_text(cpu, p, t, sizeof t);
    int on = byte_at(p + 0xb8) != 0;
    if (on) {
        gothic_color(cpu, s, 90, 10, 17, 0.55);
        gothic_rect(cpu, s, 0, 0, w, h);
        color3(cpu, s, BLOOD_HI, 0.9);
        gothic_rect(cpu, s, 0, 0, px(2), h);
    }
    double em = h * 0.72 / 1.25;
    text3(cpu, s, body_font(cpu, s, em), t, px(14), (h - body_tall(em)) / 2, 0, IVORY, on ? 1 : 0.78);
}

static void paint_box(void *cpu, uint32_t s, int w, int h)
{
    gothic_color(cpu, s, 14, 6, 8, 0.97);
    gothic_rect(cpu, s, 0, 0, w, h);
    color3(cpu, s, GOLD, 0.5);
    frame_rect(cpu, s, 0, 0, w, h);
}

// The Load Game and Save Game dialogs, laid out at the screen's scale like the options
// (the game's own layout is for its smaller fonts: rows 20 pixels tall at 1080): a panel
// 1500 by 860 in the middle, the notes under its title, then the save's name (Save Game),
// the list with 40-pixel rows, and its buttons in a row at the bottom. Each in the order
// the game put them, top to bottom.
enum { GAMES_W = 1500, GAMES_H = 860, GAMES_PAD = 48, GAMES_TOP = 100, GAMES_ROW = 40, GAMES_FIELD = 46 };

static void layout_games(void *cpu, uint32_t s, uint32_t f)
{
    home_begin(f);
    int w = px(GAMES_W) < screen_w - px(80) ? px(GAMES_W) : screen_w - px(80);
    int h = px(GAMES_H) < screen_h - px(80) ? px(GAMES_H) : screen_h - px(80);
    set_bounds(cpu, f, (screen_w - w) / 2, (screen_h - h) / 2, w, h);
    struct { uint32_t p; int kind, x, y; } it[24];
    int n = 0;
    uint32_t vp = field(f, 4), ip = ipanel(cpu);
    int count = (int)vcall(cpu, ip, IP_CHILD_COUNT, 1, &vp);
    for (int i = 0; i < count && n < 24; i++) {
        uint32_t a[2] = { vp, i }, c = panel_of(cpu, vcall(cpu, ip, IP_CHILD, 2, a));
        if (!c || is(c, FRAME_BUTTON) || is(c, FRAME_SYSTEM_BUTTON) || !(vcall(cpu, c, P_IS_VISIBLE, 0, NULL) & 0xff))
            continue;
        it[n].p = c, it[n].kind = kind_of(cpu, c);
        get_bounds(cpu, c, &it[n].x, &it[n].y, NULL, NULL);
        home_pos(c, &it[n].x, &it[n].y);
        n++;
    }
    for (int a = 1; a < n; a++)  // top to bottom, then left to right
        for (int b = a; b > 0 && (it[b].y < it[b - 1].y || (it[b].y == it[b - 1].y && it[b].x < it[b - 1].x)); b--) {
            __typeof__(it[0]) t = it[b];
            it[b] = it[b - 1], it[b - 1] = t;
        }
    int x0 = px(GAMES_PAD), cw = w - 2 * x0, y = px(GAMES_TOP);
    int bt = gothic_tall(PAGE_BTN_EM * unit()) + px(10), by = h - px(GAMES_PAD) * 3 / 4 - bt;
    double em = 24 * unit();
    uint32_t body = body_font(cpu, s, em);
    for (int i = 0; i < n; i++) {
        if (it[i].kind == K_NOTE || it[i].kind == K_HEADING) {
            char t[256], lines[4][160];
            label_text(cpu, it[i].p, t, sizeof t);
            int k = wrap(cpu, s, body, t, cw, lines, 4), lh = (k > 0 ? k : 1) * body_tall(em);
            set_bounds(cpu, it[i].p, x0, y, cw, lh);
            y += lh + px(18);
        } else if (it[i].kind == K_OTHER) {
            set_bounds(cpu, it[i].p, x0, y, cw / 2, px(GAMES_FIELD));
            y += px(GAMES_FIELD) + px(18);
        }
    }
    for (int i = 0; i < n; i++)
        if (it[i].kind == K_LIST) {
            uint32_t l = it[i].p;
            *(uint32_t *)bl_g2h(l + 0x104) = (uint32_t)px(GAMES_ROW);
            *(uint32_t *)bl_g2h(l + 0xec) = (uint32_t)px(GAMES_ROW);
            set_bounds(cpu, l, x0, y + px(6), cw, by - px(30) - y - px(6));
        }
    uint32_t font = gothic_font(cpu, s, PAGE_BTN_EM * unit());
    int x = x0;
    for (int i = 0; i < n; i++)
        if (it[i].kind == K_BUTTON) {
            char t[64];
            caps(cpu, it[i].p, t, sizeof t);
            int bw = gothic_text_width(cpu, s, font, t, px(PAGE_BTN_EM * 0.26));
            set_bounds(cpu, it[i].p, x, by, bw + px(6), bt);
            x += bw + px(BTN_GAP);
        }
}

// A confirmation or message box: a dark panel, a gold frame, the title over a divider.
static void paint_popup(void *cpu, uint32_t f)
{
    uint32_t s = surface(cpu);
    int w, h;
    get_bounds(cpu, f, NULL, NULL, &w, &h);
    gothic_flush(cpu, s);
    paint_box(cpu, s, w, h);
    color3(cpu, s, GOLD, 0.15);
    frame_rect(cpu, s, px(5), px(5), w - px(5), h - px(5));
    char t[128], c[128];
    image_text(cpu, field(f, 0x88), t, sizeof t);
    gothic_caps(t, c, sizeof c);
    uint32_t font = gothic_font(cpu, s, 22 * unit());
    int track = px(22 * 0.3), tw = gothic_text_width(cpu, s, font, c, track), y = px(24);
    text3(cpu, s, font, c, (w - tw) / 2, y, track, IVORY, 1);
    int ry = y + gothic_tall(22 * unit()) + px(14), cx = w / 2;
    gothic_line(cpu, s, px(40), w - px(40), ry, both_fade, 3, 0.8);
    gothic_diamond(cpu, s, cx, ry, px(7), GOLD[0], GOLD[1], GOLD[2], 1);
    gothic_dot(cpu, s, cx, ry, px(2), 163, 18, 31, 1);
}

// A scroll bar's knob: a thin gold track, the knob a brighter bar.
static void paint_scroll(void *cpu, uint32_t p)
{
    uint32_t s = surface(cpu);
    int w, h;
    get_bounds(cpu, p, NULL, NULL, &w, &h);
    int vertical = byte_at(p + 0x58) != 0, a = (int)field(p, 0x5c), b = (int)field(p, 0x60);
    color3(cpu, s, GOLD, 0.25);
    if (vertical) gothic_rect(cpu, s, w / 2, 0, w / 2 + 1, h);
    else gothic_rect(cpu, s, 0, h / 2, w, h / 2 + 1);
    color3(cpu, s, GOLD_HI, 0.75);
    if (vertical) gothic_rect(cpu, s, w / 2 - px(1.5), a, w / 2 + px(1.5) + 1, b);
    else gothic_rect(cpu, s, a, h / 2 - px(1.5), b, h / 2 + px(1.5) + 1);
}

// ---- Natives ----

// The replacements push a word; the natives below write 1 there to skip the game's code.
// Calls into the game change eax, ecx and edx, so each native reads them first.
static void answer(_cpu *cpu, uint32_t v) { *(uint32_t *)REG2PTR(esp) = v; }

static void setup(void *cpu)
{
    if (!options_vtable) options_vtable = call(cpu, GameUI_OptionsVtable, 0, 0, NULL);
    if (!buf) buf = bl_guest_calloc(1, 512);
}

// Frame::PaintBackground's first instruction (ecx = the frame).
void bl_options_FrameBackground(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, f = ecx;
    setup(cpu);
    if (field(f, 0) == options_vtable) {
        dialog = f, dialog_seen = now(), frame_no++;
        uint32_t s = surface(cpu);
        screen(cpu, s);
        int x, y, w, h;
        get_bounds(cpu, f, &x, &y, &w, &h);
        if (x || y || w != screen_w || h != screen_h) set_bounds(cpu, f, 0, 0, screen_w, screen_h);
        if (page()) layout_page(cpu, s, page());
        collect_glows(cpu, s);
        paint_dialog(cpu, s);
        skip = 1;
    } else if (is(f, LOAD_GAME) || is(f, SAVE_GAME)) {
        games = f, games_seen = now(), frame_no++;
        uint32_t s = surface(cpu);
        screen(cpu, s);
        layout_games(cpu, s, f);
        gothic_flush(cpu, s);
        bl_metal_backdrop(1, bl_menu_in_level(cpu), NULL, 0, 0, 0);
        paint_popup(cpu, f);
        skip = 1;
    } else if (is(f, CONFIRM) || is(f, MESSAGE_BOX)) {
        double t = now();
        if (!dialog_open()) frame_no++;
        for (int i = 0; i < 4; i++)
            if (popup_vp[i] == field(f, 4) || t - popup_seen[i] > 0.25 || i == 3) {
                popup_vp[i] = field(f, 4), popup_seen[i] = t;
                break;
            }
        paint_popup(cpu, f);
        skip = 1;
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// COptionsDialog::PerformLayout's end (esi = the dialog): full screen, Cancel and OK at the
// bottom right, the sheet over the rest.
void bl_options_DialogLayout(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx;
    setup(cpu);
    if (field(esi, 0) == options_vtable) {
        dialog = esi;
        uint32_t s = surface(cpu);
        screen(cpu, s);
        set_bounds(cpu, dialog, 0, 0, screen_w, screen_h);
        layout_buttons(cpu, s);
        if (sheet()) set_bounds(cpu, sheet(), 0, 0, screen_w, screen_h - px(FOOT));
    }
    eax = sa, ecx = sc, edx = sd;
}

// PropertySheet::PerformLayout's end (esi = the sheet): the tabs and the page.
void bl_options_SheetLayout(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx;
    if (dialog && options_vtable && field(dialog, 0) == options_vtable && esi == sheet()) {
        uint32_t s = surface(cpu);
        screen(cpu, s);
        layout_sheet(cpu, s);
    }
    eax = sa, ecx = sc, edx = sd;
}

// Button::Paint's first instruction (ecx = the button).
void bl_options_ButtonPaint(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (styled(cpu, p)) {
        skip = 1;
        int is_tab = 0, in_dialog = dialog_open();
        if (in_dialog && is(p, PAGE_TAB))
            for (int i = 0; i < tab_count(); i++) is_tab |= tab(i) == p;
        if (is_tab) {
            paint_caps_button(cpu, p, TAB_EM * unit(), p == field(sheet(), 0x74), hovered(cpu, p), 0.5);
        } else if (in_dialog && (p == field(dialog, 0xe8) || p == field(dialog, 0xec))) {
            paint_caps_button(cpu, p, BTN_EM * unit(), hovered(cpu, p), 0, 0.6);
        } else if (is_check(p)) {
            paint_check(cpu, p);
        } else if (is(p, MENU_ITEM)) {
            paint_menu_item(cpu, p);
        } else if (is(p, COLUMN_BUTTON)) {
            paint_column(cpu, p);
        } else if (is(p, COMBO_BUTTON) || is(p, FRAME_BUTTON) || is(p, FRAME_SYSTEM_BUTTON) ||
                   is(parent(cpu, p), SCROLL_BAR)) {
            // Nothing: a drop-down's or scroll bar's arrows, a frame's corner buttons.
        } else {
            paint_caps_button(cpu, p, PAGE_BTN_EM * unit(), hovered(cpu, p), 0, 0.6);
        }
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// Label::Paint's first instruction (ecx = the label).
void bl_options_LabelPaint(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (options_vtable && is(p, LABEL) && styled(cpu, p)) {
        paint_label(cpu, p);
        skip = 1;
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// Panel::PaintBackground's first instruction (ecx = the panel). A key list cell paints
// its background only when its row is selected: a dark red bar.
void bl_options_PanelBackground(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (styled(cpu, p)) {
        skip = 1;
        if (is(p, LABEL) && is_list(parent(cpu, p))) {
            uint32_t s = surface(cpu);
            int w, h;
            get_bounds(cpu, p, NULL, NULL, &w, &h);
            gothic_color(cpu, s, 110, 12, 22, 0.55);
            gothic_rect(cpu, s, 0, 0, w, h);
        }
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// The first instruction of a paint that is left out in the dialog: Panel::PaintBorder,
// PropertyPage::PaintBorder, ImagePanel::PaintBackground, Slider::Paint and
// ScrollBarSlider::Paint (ecx = the panel).
void bl_options_Skip(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = styled(cpu, ecx);
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// Slider::PaintBackground's first instruction (ecx = the slider): the whole slider.
void bl_options_SliderBackground(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (styled(cpu, p)) paint_slider(cpu, p), skip = 1;
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// TextEntry::PaintBackground's first instruction (ecx = the entry): drop-down boxes, and
// other entries as a dark field over a gold line.
void bl_options_EntryBackground(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (styled(cpu, p)) {
        if (is(p, COMBO) || is(p, CVAR_COMBO) || is(p, COMMAND_COMBO)) {
            paint_combo(cpu, p);
        } else {
            uint32_t s = surface(cpu);
            int w, h;
            get_bounds(cpu, p, NULL, NULL, &w, &h);
            gothic_color(cpu, s, 10, 4, 6, 0.8);
            gothic_rect(cpu, s, 0, 0, w, h);
            color3(cpu, s, GOLD, 0.6);
            gothic_rect(cpu, s, 0, h - 1, w, h);
        }
        skip = 1;
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// ScrollBarSlider::PaintBackground's first instruction.
void bl_options_ScrollBackground(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (styled(cpu, p)) paint_scroll(cpu, p), skip = 1;
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// Menu::Paint's first instruction: a drop-down's list, a dark box in a gold frame.
void bl_options_MenuPaint(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    if (styled(cpu, p)) {
        uint32_t s = surface(cpu);
        int w, h;
        get_bounds(cpu, p, NULL, NULL, &w, &h);
        paint_box(cpu, s, w, h);
        skip = 1;
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// ComboBox::OnMousePressed's first instruction (ecx = the box, a mouse code on the stack):
// on its left half the previous choice, on its right half the next; the list never opens.
void bl_options_ComboPressed(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, p = ecx;
    uint32_t menu = styled(cpu, p) && enabled(p) ? field(p, 0x12c) : 0;
    if (menu && !(vcall(cpu, menu, MENU_IS_VISIBLE, 0, NULL) & 0xff)) {
        uint32_t a[2] = { buf + 256, buf + 260 };
        vcall(cpu, input(cpu), IN_CURSOR_POS, 2, a);
        vcall(cpu, p, P_SCREEN_TO_LOCAL, 2, a);
        int x = (int)field(buf, 256), w;
        get_bounds(cpu, p, NULL, NULL, &w, NULL);
        int step = x < w / 2 ? -1 : 1;
        if (step) {
            char cur[160], t[160];
            int len = (int)field(p, 0x58), n = (int)field(menu, 0x64), row = -1;
            len = len < 0 ? 0 : len > 159 ? 159 : len;
            memcpy(cur, bl_g2h(field(p, 0x60)), len), cur[len] = 0;
            for (int i = 0; i < n && i < 64; i++) {
                uint32_t item = field(field(menu, 0x6c), i * 4), g[2] = { buf, 256 };
                if (!item) continue;
                *(char *)bl_g2h(buf) = 0;
                call(cpu, GameUI_Label_GetText, item, 2, g);
                snprintf(t, sizeof t, "%s", (const char *)bl_g2h(buf));
                if (!strcmp(t, cur)) row = i;
            }
            uint32_t next = (uint32_t)(row < 0 ? 0 : row + step);
            if ((int)next >= 0 && (int)next < n && (int)next != row) vcall(cpu, p, COMBO_ACTIVATE_ROW, 1, &next);
            skip = 1;
        }
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}

// After the key list paints (edi = the list): while a key is being set, its cell gets a
// red box in a gold frame in place of the game's yellow one.
void bl_options_KeyCapture(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, skip = 0, l = edi;
    if (styled(cpu, l)) {
        skip = 1;
        if (byte_at(l + 0x128)) {
            uint32_t a[6] = { field(l, 0x12c), field(l, 0x130), buf + 256, buf + 260, buf + 264, buf + 268 };
            if (vcall(cpu, l, LIST_CELL_BOUNDS, 6, a) & 0xff) {
                uint32_t s = surface(cpu);
                int x = (int)field(buf, 256), y = (int)field(buf, 260), w = (int)field(buf, 264), h = (int)field(buf, 268);
                gothic_color(cpu, s, 120, 12, 22, 0.6);
                gothic_rect(cpu, s, x, y, x + w, y + h);
                color3(cpu, s, GOLD_HI, 0.9);
                frame_rect(cpu, s, x, y, x + w, y + h);
            }
        }
    }
    eax = sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}
