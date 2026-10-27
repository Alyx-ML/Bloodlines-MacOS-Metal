// Console Pause Fix 1.1.0, the Unofficial Patch's loader plugin, redone as instruction
// replacements at its four hook sites, which are the same in the port's engine and GameUI
// (native/modules/engine and native/modules/GameUI). Opening the console pauses the game
// with "setpause"; closing it with X or ~ only hid the dialog, so the game stayed paused
// without input. These wrappers remember who owned the pause when the console opened and,
// when it closes, undo only the console's own pause and go back to the menu or the game it
// came from. Ordinary pause, a script's pause and an open menu are kept. The console's
// Minimize button and its title menu entry are hidden.
//
// Each wrapper replaces the first instruction of its routine, calls the rest of the
// original (a global proc named ..._Orig in the replacement) and returns for it.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bl_vm.h"
#include "llasm_cpu.h"

extern char engine_ShowConsoleOrig[], engine_ClientCmdOrig[], engine_HideGameUI[], GameUI_FrameVisibleOrig[],
    GameUI_HideUIOrig[], GameUI_Globals[], GameUI_Frame_SetMinimizeButtonVisible[];

static uint32_t u32_at(uint32_t guest) { return *(const uint32_t *)bl_g2h(guest); }

static uint32_t pop(_cpu *cpu)
{
    uint32_t v = *(const uint32_t *)REG2PTR(esp);
    esp += 4;
    return v;
}

// Engine globals, from the labels the engine hook pushes: the IGameUI pointer
// (0x213064A4), the console dialog's handle (0x213064A8: in use at +4, panel at +8), the
// engine time (0x20314890, a double) and three pause states (0x20B43788, 0x20B4378C: a
// count the console's open adds to, 0x212B0758).
static struct { uint32_t gameui, console, time, pause_on, pause_count, paused; } eng;
// GameUI's globals at 0x1006C330: the engine client (IVEngineClient) and, at +8, the
// game menu panel.
static uint32_t ui;

// The console's session, from its opening to its closing.
static int in_show, open_before, tracking, menu_open, console_pause, prior_pause, reopening;
static uint32_t panel_at_open;
static double time_at_open;
static char level_at_open[128];
// Inside GameUI's hide (0x100059D0), for the "unpause" it sends.
static int in_hide, hide_arg, hide_console_open, hide_menu_open, hide_prior_pause;

static uint32_t guest_str(uint32_t *slot, const char *s)
{
    if (!*slot) {
        *slot = bl_guest_malloc((uint32_t)strlen(s) + 1);
        strcpy(bl_g2h(*slot), s);
    }
    return *slot;
}

static uint32_t ui_globals(_cpu *cpu)
{
    if (!ui) ui = bl_call_guest(cpu, bl_h2g(GameUI_Globals), BL_CDECL, 0, 0, NULL);
    return ui;
}

static uint32_t console_panel(void)
{
    uint32_t h = eng.console ? u32_at(eng.console) : 0;
    return h && u32_at(h + 4) ? u32_at(h + 8) : 0;
}

// vgui Panel::IsVisible (vtable +0x58).
static int visible(_cpu *cpu, uint32_t panel)
{
    return panel && (uint8_t)bl_call_guest(cpu, u32_at(u32_at(panel) + 0x58), BL_THISCALL, panel, 0, NULL);
}

// IVEngineClient::GetLevelName (vtable +0x1A8), "" when there is no engine client.
static const char *level_name(_cpu *cpu)
{
    uint32_t ec = u32_at(ui_globals(cpu)), name = 0;
    if (ec) name = bl_call_guest(cpu, u32_at(u32_at(ec) + 0x1a8), BL_THISCALL, ec, 0, NULL);
    return name ? (const char *)bl_g2h(name) : "";
}

static double engine_time(void) { return eng.time ? *(const double *)bl_g2h(eng.time) : 0; }

// Con_ShowConsole (engine 0x2010DC10, cdecl, no arguments).
void bl_engine_ShowConsole(_cpu *cpu)
{
    eng.paused = pop(cpu), eng.pause_count = pop(cpu), eng.pause_on = pop(cpu);
    eng.time = pop(cpu), eng.console = pop(cpu), eng.gameui = pop(cpu);
    int was_in_show = in_show, was_open_before = open_before;
    uint32_t panel = console_panel();
    if (visible(cpu, panel))
        open_before = 1;
    else {
        open_before = 0;
        const char *name = level_name(cpu);
        tracking = 1;
        menu_open = visible(cpu, u32_at(ui_globals(cpu) + 8));
        panel_at_open = panel;
        time_at_open = engine_time();
        snprintf(level_at_open, sizeof level_at_open, "%s", name);
    }
    in_show = 1;
    bl_call_guest(cpu, bl_h2g(engine_ShowConsoleOrig), BL_CDECL, 0, 0, NULL);
    if ((panel = console_panel())) {
        static uint32_t minimize;
        uint32_t zero = 0, args[2] = { guest_str(&minimize, "Minimize"), 0 };
        bl_call_guest(cpu, bl_h2g(GameUI_Frame_SetMinimizeButtonVisible), BL_THISCALL, panel, 1, &zero);
        // The title menu (+0xCC): FindChildByName (+0x98), then SetVisible (+0xB8).
        uint32_t menu = u32_at(panel + 0xcc), item = 0;
        if (menu) item = bl_call_guest(cpu, u32_at(u32_at(menu) + 0x98), BL_THISCALL, menu, 2, args);
        if (item) bl_call_guest(cpu, u32_at(u32_at(item) + 0xb8), BL_THISCALL, item, 1, &zero);
    }
    in_show = was_in_show, open_before = was_open_before;
}

// IVEngineClient::ClientCmd (engine 0x2001A570, thiscall, the command).
void bl_engine_ClientCmd(_cpu *cpu)
{
    uint32_t self = ecx, cmd = *(const uint32_t *)REG2PTR(esp + 4);
    const char *s = cmd ? (const char *)bl_g2h(cmd) : NULL;
    eax = 1;
    // Going back to the menu the console came from does not pause again.
    if (s && reopening && !strcmp(s, "setpause")) return;
    if (s && in_show && !strcmp(s, "setpause")) {
        if (open_before) return;
        if (u32_at(eng.pause_count))
            console_pause = 1, prior_pause = 0;
        else if (u32_at(eng.paused) || u32_at(eng.pause_on)) {
            // Already paused by something else: that pause stays its owner's.
            prior_pause = 1, console_pause = 0;
            return;
        } else
            console_pause = 1, prior_pause = 0;
    }
    if (s && in_hide && hide_arg && hide_console_open && !hide_menu_open && hide_prior_pause && !strcmp(s, "unpause"))
        return;
    eax = bl_call_guest(cpu, bl_h2g(engine_ClientCmdOrig), BL_THISCALL, self, 1, &cmd);
}

// vgui Frame::SetVisible (GameUI 0x10022070, thiscall, the state): the console closing.
void bl_GameUI_FrameVisible(_cpu *cpu)
{
    uint32_t self = ecx, arg = *(const uint32_t *)REG2PTR(esp + 4), console = console_panel();
    uint32_t ret = bl_call_guest(cpu, bl_h2g(GameUI_FrameVisibleOrig), BL_THISCALL, self, 1, &arg);
    if (!(uint8_t)arg && self == console && tracking) {
        const char *name = level_name(cpu);
        // The same console on the same level, with no load in between.
        int same = panel_at_open == console_panel() && !strcmp(name, level_at_open) && engine_time() >= time_at_open;
        int owned = console_pause && same, hiding = in_hide, menu = menu_open;
        console_pause = tracking = prior_pause = 0;
        panel_at_open = 0;
        uint32_t ec = u32_at(ui_globals(cpu));
        if (owned && (!hide_arg || !hiding) && ec) {
            if (u32_at(eng.pause_on) && u32_at(eng.pause_count))
                *(uint32_t *)bl_g2h(eng.pause_count) = u32_at(eng.pause_count) - 1;
            else {
                static uint32_t unpause;
                uint32_t a = guest_str(&unpause, "unpause");
                bl_call_guest(cpu, bl_h2g(engine_ClientCmdOrig), BL_THISCALL, ec, 1, &a);
            }
        }
        if (same && !hiding) {
            uint32_t g = u32_at(eng.gameui), zero = 0;
            if (menu && g) {
                // IGameUI::ActivateGameUI (+0xC): back to the menu.
                reopening = 1;
                bl_call_guest(cpu, u32_at(u32_at(g) + 0xc), BL_THISCALL, g, 0, NULL);
                reopening = 0;
            } else if (!menu)
                bl_call_guest(cpu, bl_h2g(engine_HideGameUI), BL_CDECL, 0, 1, &zero);
        }
    }
    eax = ret;
}

// GameUI's hide of the game menu (0x100059D0, thiscall, a flag), which sends "unpause".
void bl_GameUI_HideUI(_cpu *cpu)
{
    uint32_t self = ecx, arg = *(const uint32_t *)REG2PTR(esp + 4);
    int s_in = in_hide, s_arg = hide_arg, s_con = hide_console_open, s_menu = hide_menu_open, s_prior = hide_prior_pause;
    in_hide = 1;
    hide_arg = (uint8_t)arg;
    hide_console_open = visible(cpu, console_panel());
    hide_menu_open = visible(cpu, u32_at(ui_globals(cpu) + 8));
    hide_prior_pause = prior_pause;
    eax = bl_call_guest(cpu, bl_h2g(GameUI_HideUIOrig), BL_THISCALL, self, 1, &arg);
    in_hide = s_in, hide_arg = s_arg, hide_console_open = s_con, hide_menu_open = s_menu, hide_prior_pause = s_prior;
}
