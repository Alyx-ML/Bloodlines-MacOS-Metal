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

// COptionsSubVisual, the Visual tab of the options dialog, gets "Ambient Occlusion",
// "Reflections", "HDR", "Volumetric Light", "Skin Scattering", "Shadows", "Bloom" and
// "Eye Adaptation" check boxes under "Combat effects". Like the tab's other
// settings they take effect as soon as they are clicked: bl_vgui_poll, once a frame,
// passes a change to the renderer, which saves it (bl_effect_enabled, bl_effect_set in
// metal_render.m). The page's OnResetData (0x1001bd30) is replaced to create the boxes:
// it does what the original did (the controls' own reset, through the aliases in
// modules/GameUI/global_aliases.manual.sci), then adds the boxes the first time. Its
// destructor (0x1001bcd0) is replaced to forget the boxes with the page.
//
// Page fields: +0x80 shadows combo box, +0x84 "Combat effects" box, +0x88..+0x94
// sliders. The box is a plain vgui::CheckButton (0xfc bytes): SetFont at vtable +0x1d8,
// GetFont at +0x1dc, SetSelected(bool) at +0x23c; IsSelected() reads the byte at +0xba.
#include "bl_vm.h"
#include <math.h>

extern char GameUI_operator_new[], GameUI_CheckButton_ctor[], GameUI_Panel_SetPos[], GameUI_Panel_GetPos[],
    GameUI_Panel_SetSize[], GameUI_Panel_GetSize[], GameUI_PropertyPage_dtor[], GameUI_SubVisual_Update[],
    GameUI_CvarSlider_Reset[], GameUI_CommandCombo_Reset[], GameUI_CvarToggle_Reset[];
int bl_effect_enabled(int effect);
void bl_effect_set(int effect, int on);

// In the order of the renderer's effects (BL_EFFECT_* in metal_render.m).
static const char *const box_names[] = { "AmbientOcclusion", "Reflections", "HDR", "VolumetricLight",
                                         "SkinScattering", "Shadows", "Bloom", "EyeAdaptation" };
static const char *const box_texts[] = { "Ambient Occlusion", "Reflections", "HDR", "Volumetric Light",
                                         "Skin Scattering", "Shadows", "Bloom", "Eye Adaptation" };
#define NBOXES 8
static uint32_t box_page, boxes[NBOXES];

static uint32_t call_this(void *cpu, const void *fn, uint32_t self, int nargs, const uint32_t *args)
{
    return bl_call_guest(cpu, bl_h2g(fn), BL_THISCALL, self, nargs, args);
}

static uint32_t field(uint32_t self, uint32_t off) { return *(const uint32_t *)bl_g2h(self + off); }

static uint32_t vcall(void *cpu, uint32_t self, uint32_t slot, int nargs, const uint32_t *args)
{
    return bl_call_guest(cpu, field(field(self, 0), slot), BL_THISCALL, self, nargs, args);
}

// The boxes go where optionssubvisual.res leaves room, in its units (scaled to the
// screen like the rest: "Combat effects" is 28 tall there): "Ambient Occlusion" just
// below "Combat effects" (336,160 360x28), the others in a column to the right of the
// "Shadow count" slider, from level with it down to two below "Ambient Occlusion" (still
// beside the slider under it, which reaches 296). In the page's
// Copperplate font.
// From Combat effects: x, y, width (0: Combat effects' own).
static const int box_place[NBOXES][3] = { { 0, 28, 248 },     { 248, -84, 240 }, { 248, -56, 240 },
                                           { 248, -28, 240 }, { 248, 0, 240 },   { 248, 28, 240 },
                                           { 248, 56, 240 },  { 248, 84, 240 } };
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
    for (int i = 0; i < NBOXES; i++) {
        uint32_t size = 0xfc;
        uint32_t box = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
        if (!box) return;
        uint32_t a[3] = { page, names[i], texts[i] };
        call_this(cpu, GameUI_CheckButton_ctor, box, 3, a);
        uint32_t at[2] = { pos[0] + (uint32_t)(int32_t)floor(box_place[i][0] * k + 0.5),
                           pos[1] + (uint32_t)(int32_t)floor(box_place[i][1] * k + 0.5) };
        uint32_t wh[2] = { box_place[i][2] ? (uint32_t)(box_place[i][2] * k + 0.5) : sz[0], sz[1] };
        call_this(cpu, GameUI_Panel_SetPos, box, 2, at);
        call_this(cpu, GameUI_Panel_SetSize, box, 2, wh);
        vcall(cpu, box, 0x1d8, 1, &font);
        uint32_t on = bl_effect_enabled(i) != 0;
        vcall(cpu, box, 0x23c, 1, &on);
        boxes[i] = box;
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
    if (box_page != page || !boxes[0]) make_boxes(cpu, page);
}

// The page's destructor body: the vtable it restores is the one already in place.
// vgui deletes the box with the rest of the page's children.
void bl_vgui_VisualDestroy_c(_cpu *cpu)
{
    uint32_t page = ecx;
    if (box_page == page) box_page = 0, memset(boxes, 0, sizeof boxes);
    call_this(cpu, GameUI_PropertyPage_dtor, page, 0, NULL);
}

void bl_vgui_poll(void)
{
    for (int i = 0; i < NBOXES; i++) {
        if (!boxes[i]) continue;
        int on = *(const uint8_t *)bl_g2h(boxes[i] + 0xba) != 0;
        if (on != (bl_effect_enabled(i) != 0)) bl_effect_set(i, on);
    }
}
