// Native replacements for routines in GameUI's statically linked vgui (see
// native/modules/README.md). Each takes the guest CPU, like bl_crt.c.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "llasm_cpu.h"

// RichText::GetCursorLine (GameUI 0x10029250, thiscall, no arguments): the line the
// cursor is on. The original scans the line-break table from the start, and the
// console calls it per character and again in a loop when scrolling to the end, so
// text appended under -dev cost O(lines) per character. The table holds text offsets
// in ascending order, so a binary search gives the same answer: the index of the
// first break after the cursor, minus one when the cursor sits on a soft break that
// is not the end of the text.
//
// Fields of the RichText (this = ecx): +0x58 text length, +0x64 break count,
// +0x6c break table, +0x70 cursor position, +0x75 "cursor before soft break" flag.
// BL_VGUI_CHECK=1 compares every answer with the original linear scan.
void bl_vgui_GetCursorLine_c(_cpu *cpu)
{
    const uint8_t *self = REG2PTR(ecx);
    int32_t count = *(const int32_t *)(self + 0x64);
    int32_t cursor = *(const int32_t *)(self + 0x70);
    const int32_t *breaks = count > 0 ? REG2PTR(*(const uint32_t *)(self + 0x6c)) : NULL;
    int32_t lo = 0, hi = count > 0 ? count : 0;
    while (lo < hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (cursor < breaks[mid]) hi = mid;
        else lo = mid + 1;
    }
    static int check = -1;
    if (check < 0) check = getenv("BL_VGUI_CHECK") != NULL;
    if (check) {
        int32_t i = 0;
        while (i < count && cursor >= breaks[i]) i++;
        if (i != lo) fprintf(stderr, "[vgui] GetCursorLine: linear %d, binary %d (cursor %d, %d breaks)\n", i, lo, cursor, count);
        lo = i;
    }
    if (self[0x75] && cursor != *(const int32_t *)(self + 0x58)) lo--;
    eax = (uint32_t)lo;
}

// The options dialog gets an "Enhanced" tab after "Visual", holding the renderer's
// effects as check boxes in three headed columns: "Lighting" (Global Illumination, Bounced
// Light, Ambient Occlusion, Volumetric Light), "Camera" (HDR, Bloom, Eye Adaptation,
// Sharpening, Lens Glare) and "Surfaces & Characters" (Reflections, Skin Scattering, Smooth
// Characters, Skin Detail, Rain Effects). The renderer's shadows are not a box: they are "Enhanced", a fifth choice
// in the Visual tab's Shadows drop-down, after "Soft".
// Like the Visual tab's settings they take effect as soon as they are clicked:
// bl_vgui_poll, once a frame, passes a change to the renderer, which saves it
// (bl_effect_enabled, bl_effect_set in metal_render.m).
// - PropertyDialog::AddPage (0x10024eb0) is replaced (bl_vgui_AddPage_c): it does what
//   the original did, and after the options dialog's Visual tab adds the Enhanced one, a
//   plain vgui::PropertyPage.
// - COptionsSubVisual's OnResetData (0x1001bd30) is replaced: it does what the original
//   did (the controls' own reset, through the aliases in
//   modules/GameUI/global_aliases.manual.sci), then the first time makes the boxes on the
//   Enhanced tab, placed and lettered like the Visual tab's controls (whose fonts and size
//   are set by then). Its destructor (0x1001bcd0) is replaced to forget the boxes: the
//   dialog deletes both pages together.
// - Tooltip::ShowTooltip (0x10038160) shows nothing (runtime/llasm/vgui.llasm): GameUI's
//   only tooltips are these pages' hints, which the gothic options screen (bl_options.c)
//   left as loose text by the setting.
//
// Visual page fields: +0x80 shadows combo box, +0x84 "Combat effects" box, +0x88..+0x94
// sliders. The box is a plain vgui::CheckButton (0xfc bytes): SetFont at vtable +0x1d8,
// GetFont at +0x1dc, SetSelected(bool) at +0x23c; IsSelected() reads the byte at +0xba.
// A vgui::Label (0xd4 bytes) is built with (parent, name, text). A PropertyPage is 0x7c
// bytes, built with no arguments; the dialog's PropertySheet
// (+0xe4) adds a page with AddPage(page, title, NULL) at vtable +0x1ac.
#include "bl_vm.h"
#include <math.h>

extern char GameUI_operator_new[], GameUI_CheckButton_ctor[], GameUI_Panel_SetPos[], GameUI_Panel_GetPos[],
    GameUI_Panel_SetSize[], GameUI_Panel_GetSize[], GameUI_PropertyPage_ctor[], GameUI_PropertyPage_dtor[], GameUI_Label_ctor[],
    GameUI_SubVisual_Update[], GameUI_CvarSlider_Reset[], GameUI_CommandCombo_Reset[], GameUI_CvarToggle_Reset[],
    GameUI_LabeledCombo_ctor[];
int bl_effect_enabled(int effect);
void bl_effect_set(int effect, int on);
int bl_upscaler_get(int which);
int bl_upscaler_set(int which, int value);  // 0: refused (FSR 4 that cannot run here)
int bl_render_live_mode(uint32_t width, uint32_t height);
int bl_display_mode_get(void);
void bl_display_mode_set(int mode);
void bl_render_output_size(uint32_t *width, uint32_t *height);

// In the order of the renderer's effects (BL_EFFECT_* in metal_render.m). Shadows and the
// quest compass have no box here (SHADOWS_EFFECT and COMPASS_EFFECT, below).
static const char *const box_names[] = { "AmbientOcclusion", "Reflections", "HDR", "VolumetricLight",
                                         "SkinScattering", "Shadows", "Bloom", "EyeAdaptation",
                                         "BouncedLight", "GlobalIllumination", "SmoothCharacters",
                                         "SharpenAfterAA", "SkinDetail", "QuestCompass", "RainEffects",
                                         "LensGlare" };
static const char *const box_texts[] = { "Ambient Occlusion", "Reflections", "HDR", "Volumetric Light",
                                         "Skin Scattering", "Shadows", "Bloom", "Eye Adaptation",
                                         "Bounced Light", "Global Illumination", "Smooth Characters",
                                         "Sharpening", "Skin Detail", "Quest compass", "Rain Effects",
                                         "Lens Glare" };
#define NBOXES 16
static uint32_t box_page, enhanced_page, boxes[NBOXES];
// The Gameplay tab gets one more: the quest compass (bl_compass.c), the renderer's setting
// after the Enhanced tab's (BL_EFFECT_COMPASS), under the tab's "Damage floaters" box.
#define COMPASS_EFFECT 13
static uint32_t gameplay_page, compass_box;
#define LOG_ONCE_VGUI(...) do { static int once_; if (!once_++) fprintf(stderr, __VA_ARGS__); } while (0)

static uint32_t call_this(void *cpu, const void *fn, uint32_t self, int nargs, const uint32_t *args)
{
    return bl_call_guest(cpu, bl_h2g(fn), BL_THISCALL, self, nargs, args);
}

static uint32_t field(uint32_t self, uint32_t off) { return *(const uint32_t *)bl_g2h(self + off); }

static uint32_t vcall(void *cpu, uint32_t self, uint32_t slot, int nargs, const uint32_t *args)
{
    return bl_call_guest(cpu, field(field(self, 0), slot), BL_THISCALL, self, nargs, args);
}

// Places in optionssubvisual.res units (scaled to the screen like the Visual tab, where
// "Combat effects" is at 336,160 and 28 tall; the page runs from about -120 to 935
// across and -15 to 300 down): three columns 300 apart around the page's middle, each a
// heading and its boxes 40 apart (four in the first, five in the others). x, y.
#define COLUMN_W 290
static const int heading_x[3] = { -24, 276, 576 };
#define HEADING_Y 45
static const char *const heading_texts[3] = { "Lighting", "Camera", "Surfaces & Characters" };
static const int box_place[NBOXES][2] = { { -24, 165 }, { 576, 85 },  { 276, 85 },  { -24, 205 },
                                           { 576, 125 }, { 0, 0 },     { 276, 125 }, { 276, 165 },
                                           { -24, 125 }, { -24, 85 },  { 576, 165 }, { 276, 205 },
                                           { 576, 205 }, { 0, 0 },     { 576, 245 }, { 276, 245 } };

// The Shadows drop-down (the Visual page's +0x80) is a CCvarLabeledComboBox: +0x58 its
// ComboBox, +0x6c its item count, +0x7c the cvar's value at the last reset; AddItem(text,
// command) at vtable +0x1b8, ActivateItem(index) at +0x1bc. Picking an item runs its
// command (OnTextChanged, 0x10010320). "Enhanced" runs Soft's command, cl_v_shadows 3, and
// the renderer's shadows follow the box's text (bl_vgui_poll). It is added only after
// "Soft", which the game leaves out below DirectX 8.1.
#define SHADOWS_EFFECT 5
#define ENHANCED_TEXT "Enhanced"
static uint32_t shadow_combo;

static void add_enhanced_shadows(void *cpu, uint32_t combo)
{
    static uint32_t text, command;
    if (!text) text = bl_guest_strdup(ENHANCED_TEXT), command = bl_guest_strdup("cl_v_shadows 3");
    uint32_t n = field(combo, 0x6c);
    if (n != 4) return;
    uint32_t a[2] = { text, command };
    vcall(cpu, combo, 0x1b8, 2, a);
    shadow_combo = combo;
    // The setting shows as Enhanced only with Soft shadows; with any other it is off.
    if (field(combo, 0x7c) != 3) {
        if (bl_effect_enabled(SHADOWS_EFFECT)) bl_effect_set(SHADOWS_EFFECT, 0);
    } else if (bl_effect_enabled(SHADOWS_EFFECT)) {
        vcall(cpu, combo, 0x1bc, 1, &n);
    }
}

// Drop-downs of the renderer's settings: on the Visual tab the upscaling ones
// (bl_upscaler_get/set in metal_render.m), the scaler and the world view's resolution,
// under the Shadows drop-down; on the Video tab Display Mode (bl_display_mode_get/set),
// under Resolution. Each is a CLabeledCommandComboBox (0x78 bytes, built with (parent,
// name, label text) at 0x1000fe40, aliased GameUI_LabeledCombo_ctor), laid out like the
// game's; its items' commands are empty, and the choice is read from the box's text
// (bl_vgui_poll).
enum { UPSCALER_COMBO, QUALITY_COMBO, DISPLAY_COMBO, NCOMBOS };
static const char *const combo_names[NCOMBOS] = { "Upscaler", "UpscalingQuality", "DisplayMode" };
static const char *const combo_labels[NCOMBOS] = { "Upscaler", "Upscaling Quality", "Display Mode" };
static const char *const combo_items[NCOMBOS][5] = {
    { "None", "MetalFX", "FSR 4" },
    { "Ultra Performance (33%)", "Performance (50%)", "Balanced (59%)", "Quality (67%)", "Native" },
    { "Windowed", "Borderless", "Fullscreen" } };
static const int combo_count[NCOMBOS] = { 3, 5, 3 };
static uint32_t upscale_page, combos[NCOMBOS];

// The items' order to the renderer's: None first (the renderer's 2: MetalFX at full size,
// for its anti-aliasing alone), then MetalFX (0) and FSR 4 (1); the qualities run low to
// high like the game's other settings (the renderer's from native down).
#define UPSCALER_NONE 2
static int combo_get(int i)
{
    if (i == DISPLAY_COMBO) return bl_display_mode_get();
    if (i == QUALITY_COMBO) return 4 - bl_upscaler_get(1);
    int u = bl_upscaler_get(0);
    return u == UPSCALER_NONE ? 0 : u + 1;
}
static int combo_set(int i, int item)
{
    if (i == DISPLAY_COMBO) return bl_display_mode_set(item), 1;
    if (i == QUALITY_COMBO) return bl_upscaler_set(1, 4 - item);
    return bl_upscaler_set(0, item ? item - 1 : UPSCALER_NONE);
}

// Drop-down `i` on `page`, at x, y with the size of `like`, the game's drop-down it goes under.
static void make_combo(void *cpu, uint32_t page, int i, uint32_t like, uint32_t below)
{
    static uint32_t names[NCOMBOS], labels[NCOMBOS], items[NCOMBOS][5], empty, out;
    if (!out) {
        for (int c = 0; c < NCOMBOS; c++) {
            names[c] = bl_guest_strdup(combo_names[c]), labels[c] = bl_guest_strdup(combo_labels[c]);
            for (int j = 0; j < combo_count[c]; j++) items[c][j] = bl_guest_strdup(combo_items[c][j]);
        }
        empty = bl_guest_strdup(""), out = bl_guest_malloc(8);
    }
    uint32_t p[2] = { out, out + 4 };
    call_this(cpu, GameUI_Panel_GetPos, like, 2, p);
    uint32_t pos[2] = { field(out, 0), field(out, 4) };
    call_this(cpu, GameUI_Panel_GetSize, like, 2, p);
    uint32_t sz[2] = { field(out, 0), field(out, 4) };
    uint32_t size = 0x78;
    uint32_t combo = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
    if (!combo) return;
    uint32_t a[3] = { page, names[i], labels[i] };
    call_this(cpu, GameUI_LabeledCombo_ctor, combo, 3, a);
    for (int j = 0; j < combo_count[i]; j++) {
        uint32_t b[2] = { items[i][j], empty };
        vcall(cpu, combo, 0x1b8, 2, b);
    }
    // Just under `like`: the gothic layout (bl_options.c) puts the page's settings in
    // columns by x, each in the order of y.
    uint32_t at[2] = { pos[0], pos[1] + below };
    call_this(cpu, GameUI_Panel_SetPos, combo, 2, at);
    call_this(cpu, GameUI_Panel_SetSize, combo, 2, sz);
    uint32_t pick = (uint32_t)combo_get(i);
    vcall(cpu, combo, 0x1bc, 1, &pick);
    combos[i] = combo;
}

static void make_upscale_combos(void *cpu, uint32_t page)
{
    upscale_page = page;
    make_combo(cpu, page, UPSCALER_COMBO, field(page, 0x80), 1);
    make_combo(cpu, page, QUALITY_COMBO, field(page, 0x80), 2);
}

// `page`: the Visual tab, whose "Combat effects" box gives the scale and the font.
static void make_boxes(void *cpu, uint32_t page)
{
    static uint32_t names[NBOXES], texts[NBOXES], out;
    if (!out) {
        for (int i = 0; i < NBOXES; i++) names[i] = bl_guest_strdup(box_names[i]), texts[i] = bl_guest_strdup(box_texts[i]);
        out = bl_guest_malloc(8);
    }
    uint32_t combat = field(page, 0x84), p[2] = { out, out + 4 };
    call_this(cpu, GameUI_Panel_GetPos, combat, 2, p);
    uint32_t pos[2] = { field(out, 0), field(out, 4) };
    call_this(cpu, GameUI_Panel_GetSize, combat, 2, p);
    uint32_t sz[2] = { field(out, 0), field(out, 4) };
    double k = sz[1] / 28.0;
    uint32_t font = vcall(cpu, combat, 0x1dc, 0, NULL);
    box_page = page;
    static uint32_t headings[3];
    for (int i = 0; i < 3; i++) {
        if (!headings[i]) headings[i] = bl_guest_strdup(heading_texts[i]);
        uint32_t size = 0xd4;
        uint32_t label = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
        if (!label) return;
        uint32_t a[3] = { enhanced_page, headings[i], headings[i] };
        call_this(cpu, GameUI_Label_ctor, label, 3, a);
        uint32_t at[2] = { pos[0] + (uint32_t)(int32_t)floor((heading_x[i] - 336) * k + 0.5),
                           pos[1] + (uint32_t)(int32_t)floor((HEADING_Y - 160) * k + 0.5) };
        uint32_t wh[2] = { (uint32_t)(COLUMN_W * k + 0.5), sz[1] };
        call_this(cpu, GameUI_Panel_SetPos, label, 2, at);
        call_this(cpu, GameUI_Panel_SetSize, label, 2, wh);
        vcall(cpu, label, 0x1d8, 1, &font);
    }
    for (int i = 0; i < NBOXES; i++) {
        if (i == SHADOWS_EFFECT || i == COMPASS_EFFECT) continue;
        uint32_t size = 0xfc;
        uint32_t box = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
        if (!box) return;
        uint32_t a[3] = { enhanced_page, names[i], texts[i] };
        call_this(cpu, GameUI_CheckButton_ctor, box, 3, a);
        uint32_t at[2] = { pos[0] + (uint32_t)(int32_t)floor((box_place[i][0] - 336) * k + 0.5),
                           pos[1] + (uint32_t)(int32_t)floor((box_place[i][1] - 160) * k + 0.5) };
        uint32_t wh[2] = { (uint32_t)(COLUMN_W * k + 0.5), sz[1] };
        call_this(cpu, GameUI_Panel_SetPos, box, 2, at);
        call_this(cpu, GameUI_Panel_SetSize, box, 2, wh);
        vcall(cpu, box, 0x1d8, 1, &font);
        uint32_t on = bl_effect_enabled(i) != 0;
        vcall(cpu, box, 0x23c, 1, &on);
        boxes[i] = box;
    }
    if (gameplay_page && !compass_box) {  // at 40,90 in optionssubgameplay.res units
        static uint32_t name, text;
        if (!name) name = bl_guest_strdup("QuestCompass"), text = bl_guest_strdup("Quest compass");
        uint32_t size = 0xfc;
        uint32_t box = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
        if (!box) return;
        uint32_t a[3] = { gameplay_page, name, text };
        call_this(cpu, GameUI_CheckButton_ctor, box, 3, a);
        uint32_t at[2] = { pos[0] + (uint32_t)(int32_t)floor((40 - 336) * k + 0.5),
                           pos[1] + (uint32_t)(int32_t)floor((90 - 160) * k + 0.5) };
        uint32_t wh[2] = { (uint32_t)(420 * k + 0.5), sz[1] };
        call_this(cpu, GameUI_Panel_SetPos, box, 2, at);
        call_this(cpu, GameUI_Panel_SetSize, box, 2, wh);
        vcall(cpu, box, 0x1d8, 1, &font);
        uint32_t on = bl_effect_enabled(COMPASS_EFFECT) != 0;
        vcall(cpu, box, 0x23c, 1, &on);
        compass_box = box;
    }
}

void bl_vgui_VisualReset_c(_cpu *cpu)
{
    uint32_t page = ecx;
    call_this(cpu, GameUI_SubVisual_Update, page, 0, NULL);
    static const uint32_t sliders[] = { 0x90, 0x8c, 0x88, 0x94 };
    for (int i = 0; i < 4; i++) call_this(cpu, GameUI_CvarSlider_Reset, field(page, sliders[i]), 0, NULL);
    call_this(cpu, GameUI_CommandCombo_Reset, field(page, 0x80), 0, NULL);
    call_this(cpu, GameUI_CvarToggle_Reset, field(page, 0x84), 0, NULL);
    if (field(page, 0x80) != shadow_combo) add_enhanced_shadows(cpu, field(page, 0x80));
    if (upscale_page != page) make_upscale_combos(cpu, page);
    if (enhanced_page && (box_page != page || !boxes[0])) make_boxes(cpu, page);
}

// PropertyDialog::AddPage(page, title) (thiscall).
void bl_vgui_AddPage_c(_cpu *cpu)
{
    const uint32_t *args = REG2PTR(esp + 4);
    uint32_t dialog = ecx, page = args[0], title = args[1];
    uint32_t a[3] = { page, title, 0 };
    vcall(cpu, field(dialog, 0xe4), 0x1ac, 3, a);
    if (title && !strcmp((const char *)bl_g2h(title), "#GameUI_Gameplay")) gameplay_page = page, compass_box = 0;
    // The Video tab: Display Mode under Resolution (+0x1a0).
    if (title && !strcmp((const char *)bl_g2h(title), "#GameUI_Video") && field(page, 0x1a0))
        make_combo(cpu, page, DISPLAY_COMBO, field(page, 0x1a0), 1);
    // The options dialog's Visual tab (by name: the module is not loaded at its own base).
    if (!title || strcmp((const char *)bl_g2h(title), "#GameUI_Visual")) return;
    static uint32_t name;
    if (!name) name = bl_guest_strdup("Enhanced");
    uint32_t size = 0x80;
    uint32_t p = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
    if (!p) return;
    call_this(cpu, GameUI_PropertyPage_ctor, p, 0, NULL);
    enhanced_page = p;
    uint32_t b[3] = { p, name, 0 };
    vcall(cpu, field(dialog, 0xe4), 0x1ac, 3, b);
    LOG_ONCE_VGUI("[vgui] options: Enhanced tab added\n");
}

// A resolution applied without starting the game again (bl_render_live_mode in
// metal_render.m). The Video tab's ApplyChanges (0x1001b7c0, ecx = the page) parses the
// chosen mode into +0x10c (width, height, depth) and, when it differs from the current
// one at +0x7c, runs "_setvideomode", which only saves it, and shows "#GameUI_NotifyVideo"
// (start the game again) at 0x1001b8a5 (ebx = the page). The current one is read from the
// engine, which keeps the start-up size: bl_vgui_VideoApply puts the size the screen is
// drawn at in its place, and bl_vgui_VideoNote leaves the note out when the renderer takes
// the new one live. The page is made again each time Options opens and reads the current
// mode the same way (0x1001b750, then copied to +0x10c, which the drop-down selects):
// bl_vgui_VideoCurrent (0x1001b78a, edi = the page) does the same there, so the drop-down
// shows the applied size rather than the start-up one.
static void video_current(uint32_t page)
{
    uint32_t w, h;
    bl_render_output_size(&w, &h);
    if (w && h) *(uint32_t *)bl_g2h(page + 0x7c) = w, *(uint32_t *)bl_g2h(page + 0x80) = h;
}

void bl_vgui_VideoApply(_cpu *cpu) { video_current(ecx); }

void bl_vgui_VideoCurrent(_cpu *cpu) { video_current(edi); }

void bl_vgui_VideoNote(_cpu *cpu)
{
    uint32_t page = ebx;
    *(uint32_t *)REG2PTR(esp) = (uint32_t)bl_render_live_mode(field(page, 0x10c), field(page, 0x110));
}

// The Visual page's destructor body: the vtable it restores is the one already in place.
// vgui deletes the boxes with the rest of the Enhanced page's children.
void bl_vgui_VisualDestroy_c(_cpu *cpu)
{
    uint32_t page = ecx;
    if (box_page == page)
        box_page = 0, enhanced_page = 0, memset(boxes, 0, sizeof boxes), gameplay_page = 0, compass_box = 0;
    if (shadow_combo == field(page, 0x80)) shadow_combo = 0;
    // The dialog deletes its pages together: the Video tab's drop-down goes with these.
    if (upscale_page == page) upscale_page = 0, memset(combos, 0, sizeof combos);
    call_this(cpu, GameUI_PropertyPage_dtor, page, 0, NULL);
}

// A box's setting is saved when the player changes the box, compared with the box as last
// seen rather than with the effect: an effect forced by its environment variable stays as
// forced, and would otherwise be saved again every frame.
static void poll_box(uint32_t box, int effect, uint32_t *seen_box, int *seen_on)
{
    int on = *(const uint8_t *)bl_g2h(box + 0xba) != 0;
    if (*seen_box == box && *seen_on == on) return;
    int fresh = *seen_box != box;  // a new box: saved only if it differs from the setting
    *seen_box = box, *seen_on = on;
    if (!fresh || on != (bl_effect_enabled(effect) != 0)) bl_effect_set(effect, on);
}

void bl_vgui_poll(void)
{
    static uint32_t seen_box[NBOXES + 1];
    static int seen_on[NBOXES + 1];
    for (int i = 0; i < NBOXES; i++)
        if (boxes[i]) poll_box(boxes[i], i, &seen_box[i], &seen_on[i]);
    if (compass_box) poll_box(compass_box, COMPASS_EFFECT, &seen_box[NBOXES], &seen_on[NBOXES]);
    // The Shadows drop-down: as a box, a change is saved, compared with the text last seen.
    static uint32_t seen_combo;
    static int seen_enhanced;
    if (shadow_combo) {
        uint32_t box = field(shadow_combo, 0x58);
        int len = (int)field(box, 0x58);
        int on = len == (int)strlen(ENHANCED_TEXT) && !memcmp(bl_g2h(field(box, 0x60)), ENHANCED_TEXT, (size_t)len);
        if (seen_combo != shadow_combo || seen_enhanced != on) {
            int fresh = seen_combo != shadow_combo;
            seen_combo = shadow_combo, seen_enhanced = on;
            if (!fresh && on != (bl_effect_enabled(SHADOWS_EFFECT) != 0)) bl_effect_set(SHADOWS_EFFECT, on);
        }
    }
    // The renderer's drop-downs, the same way.
    static uint32_t seen_combo_box[NCOMBOS];
    static int seen_pick[NCOMBOS];
    for (int i = 0; i < NCOMBOS; i++) {
        uint32_t combo = combos[i];
        if (!combo) continue;
        uint32_t box = field(combo, 0x58);
        int len = (int)field(box, 0x58), pick = -1;
        for (int j = 0; j < combo_count[i]; j++)
            if (len == (int)strlen(combo_items[i][j]) && !memcmp(bl_g2h(field(box, 0x60)), combo_items[i][j], (size_t)len))
                pick = j;
        if (pick < 0 || (seen_combo_box[i] == combo && seen_pick[i] == pick)) continue;
        int fresh = seen_combo_box[i] != combo;
        seen_combo_box[i] = combo, seen_pick[i] = pick;
        if (fresh || pick == combo_get(i) || combo_set(i, pick)) continue;
        // Refused: the drop-down goes back to what is in use.
        uint32_t cur = (uint32_t)combo_get(i);
        if (bl_thread_cpu) vcall(bl_thread_cpu, combo, 0x1bc, 1, &cur);
        seen_pick[i] = (int)cur;
    }
    // With no upscaler the quality is not used: its drop-down is greyed and does not
    // change (the panel's enabled flag, +0x19, which the options' painting and
    // bl_options_ComboPressed read).
    if (combos[QUALITY_COMBO])
        *(uint8_t *)bl_g2h(field(combos[QUALITY_COMBO], 0x58) + 0x19) = bl_upscaler_get(0) != UPSCALER_NONE;
}
