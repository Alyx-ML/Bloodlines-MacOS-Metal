// Native replacements for routines in GameUI's statically linked vgui (see
// native/modules/README.md). Each takes the guest CPU, like bl_crt.c.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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

// COptionsSubVisual, the Visual tab of the options dialog, gets an "Ambient Occlusion"
// check box under "Combat effects". Like the tab's other settings it takes effect as
// soon as it is clicked: bl_vgui_poll, once a frame, passes a change to the renderer,
// which saves it (bl_ao_enabled, bl_ao_set in metal_render.m). The page's OnResetData
// (0x1001bd30) is replaced to create the box: it does what the original did (the
// controls' own reset, through the aliases in modules/GameUI/global_aliases.manual.sci),
// then adds the box the first time. Its destructor (0x1001bcd0) is replaced to forget
// the box with the page.
//
// Page fields: +0x80 shadows combo box, +0x84 "Combat effects" box, +0x88..+0x94
// sliders. The box is a plain vgui::CheckButton (0xfc bytes): SetFont at vtable +0x1d8,
// GetFont at +0x1dc, SetSelected(bool) at +0x23c; IsSelected() reads the byte at +0xba.
#include "bl_vm.h"

extern char GameUI_operator_new[], GameUI_CheckButton_ctor[], GameUI_Panel_SetPos[], GameUI_Panel_GetPos[],
    GameUI_Panel_SetSize[], GameUI_Panel_GetSize[], GameUI_PropertyPage_dtor[], GameUI_SubVisual_Update[],
    GameUI_CvarSlider_Reset[], GameUI_CommandCombo_Reset[], GameUI_CvarToggle_Reset[];
int bl_ao_enabled(void);
void bl_ao_set(int on);

static uint32_t ao_page, ao_box;

static uint32_t call_this(void *cpu, const void *fn, uint32_t self, int nargs, const uint32_t *args)
{
    return bl_call_guest(cpu, bl_h2g(fn), BL_THISCALL, self, nargs, args);
}

static uint32_t field(uint32_t self, uint32_t off) { return *(const uint32_t *)bl_g2h(self + off); }

static uint32_t vcall(void *cpu, uint32_t self, uint32_t slot, int nargs, const uint32_t *args)
{
    return bl_call_guest(cpu, field(field(self, 0), slot), BL_THISCALL, self, nargs, args);
}

// The box is the size of "Combat effects" and just below it (the .res file places that
// one, scaled to the screen), in the page's Copperplate font.
static void ao_make_box(void *cpu, uint32_t page)
{
    static uint32_t name, text, out;
    if (!out) {
        name = bl_guest_strdup("AmbientOcclusion");
        text = bl_guest_strdup("Ambient Occlusion");
        out = bl_guest_malloc(8);
    }
    uint32_t size = 0xfc;
    uint32_t box = bl_call_guest(cpu, bl_h2g(GameUI_operator_new), BL_CDECL, 0, 1, &size);
    if (!box) return;
    uint32_t a[3] = { page, name, text };
    call_this(cpu, GameUI_CheckButton_ctor, box, 3, a);
    uint32_t combat = field(page, 0x84), p[2] = { out, out + 4 };
    call_this(cpu, GameUI_Panel_GetPos, combat, 2, p);
    uint32_t pos[2] = { field(out, 0), field(out, 4) };
    call_this(cpu, GameUI_Panel_GetSize, combat, 2, p);
    uint32_t sz[2] = { field(out, 0), field(out, 4) };
    pos[1] += sz[1];
    call_this(cpu, GameUI_Panel_SetPos, box, 2, pos);
    call_this(cpu, GameUI_Panel_SetSize, box, 2, sz);
    uint32_t font = vcall(cpu, combat, 0x1dc, 0, NULL);
    vcall(cpu, box, 0x1d8, 1, &font);
    uint32_t on = bl_ao_enabled() != 0;
    vcall(cpu, box, 0x23c, 1, &on);
    ao_page = page, ao_box = box;
}

void bl_vgui_VisualReset_c(_cpu *cpu)
{
    uint32_t page = ecx;
    call_this(cpu, GameUI_SubVisual_Update, page, 0, NULL);
    static const uint32_t sliders[] = { 0x90, 0x8c, 0x88, 0x94 };
    for (int i = 0; i < 4; i++) call_this(cpu, GameUI_CvarSlider_Reset, field(page, sliders[i]), 0, NULL);
    call_this(cpu, GameUI_CommandCombo_Reset, field(page, 0x80), 0, NULL);
    call_this(cpu, GameUI_CvarToggle_Reset, field(page, 0x84), 0, NULL);
    if (ao_page != page || !ao_box) ao_make_box(cpu, page);
}

// The page's destructor body: the vtable it restores is the one already in place.
// vgui deletes the box with the rest of the page's children.
void bl_vgui_VisualDestroy_c(_cpu *cpu)
{
    uint32_t page = ecx;
    if (ao_page == page) ao_page = 0, ao_box = 0;
    call_this(cpu, GameUI_PropertyPage_dtor, page, 0, NULL);
}

void bl_vgui_poll(void)
{
    if (!ao_box) return;
    int on = *(const uint8_t *)bl_g2h(ao_box + 0xba) != 0;
    if (on != (bl_ao_enabled() != 0)) bl_ao_set(on);
}
