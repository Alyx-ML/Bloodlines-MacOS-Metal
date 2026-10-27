// Native parts of vtmb-tweaks (c6, github.com/c6-dev/vtmb-tweaks, GPL-2.0), the Unofficial
// Patch's loader plugin, redone as instruction replacements in vampire.dll
// (native/modules/vampire/instruction_replacements.manual.sci). The plugin's hook sites
// are the same in the Unofficial Patch 11.1 module the port runs. Each routine stands in
// for one replaced instruction, so a replaced call also takes its callee's stack
// arguments off (thiscall) and leaves its answer in eax.
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "bl_vm.h"
#include "llasm_cpu.h"

extern char vampire_GetWeapon[], vampire_WeaponDrop[], vampire_GetActiveWeapon[], vampire_SwitchToNextBestWeapon[],
    vampire_OwnsThisType[], vampire_StatGetBase[], vampire_StatSetBase[], vampire_GetVHistory[], vampire_SetVHistory[],
    vampire_ChangeHistory[], client_HistoryRefresh[], client_HistoryUI[], vampire_WarformAdd[], vampire_LocalPlayer[];

static uint32_t this_call(_cpu *cpu, const char *fn, uint32_t self, int n, const uint32_t *args)
{
    return bl_call_guest(cpu, bl_h2g(fn), BL_THISCALL, self, n, args);
}

static uint32_t u32_at(uint32_t guest) { return *(const uint32_t *)bl_g2h(guest); }

// CBaseCombatWeapon::IsStackable (vtable +0x5CC): the item's is_stackable in vdata/items.
static int stackable(_cpu *cpu, uint32_t weapon)
{
    return (uint8_t)bl_call_guest(cpu, u32_at(u32_at(weapon) + 0x5cc), BL_THISCALL, weapon, 0, NULL);
}

// On an NPC's death (0x1032BA84, ecx the NPC): drop every weapon it holds, not only the
// active one. CBaseCombatCharacter::GetWeapon(i), Weapon_Drop(weapon, NULL, NULL).
void bl_vampire_DropAllWeapons(_cpu *cpu)
{
    uint32_t npc = ecx;
    for (uint32_t i = 0; i < 224; i++) {
        uint32_t w = this_call(cpu, vampire_GetWeapon, npc, 1, &i);
        if (w) this_call(cpu, vampire_WeaponDrop, npc, 3, (uint32_t[]){ w, 0, 0 });
    }
}

// Dropping the active weapon (0x1032D142, esi the weapon): eax 0 when it is a stack of
// more than one, so only one of them is dropped (+0x8D0 is the stack's count).
void bl_vampire_ShouldDropActive(_cpu *cpu)
{
    uint32_t w = esi;
    eax = !stackable(cpu, w) || *(const int32_t *)bl_g2h(w + 0x8d0) <= 1;
}

// After a weapon is dropped (0x1017788C, ecx the player, one argument): switch to the
// next best weapon only when none is active any more.
void bl_vampire_SwitchToNextBest(_cpu *cpu)
{
    uint32_t player = ecx, arg = 0;
    eax = this_call(cpu, vampire_GetActiveWeapon, player, 0, NULL) ? 1
          : this_call(cpu, vampire_SwitchToNextBestWeapon, player, 1, &arg);
    esp += 4;
}

// Picking up a weapon (0x1017724E, ecx the player, arguments type and 0): an owned
// stackable weapon counts as not owned, so another one can be picked up.
void bl_vampire_OwnsThisType(_cpu *cpu)
{
    const uint32_t *args = REG2PTR(esp);
    uint32_t w = this_call(cpu, vampire_OwnsThisType, ecx, 2, (uint32_t[]){ args[0], args[1] });
    eax = w && stackable(cpu, w) ? 0 : w;
    esp += 8;
}

// The player's field of view (+0x1E78) as the fov command last set it (0x100D2DC1, the
// command's atoi), which zooming out restores (0x10239E01) instead of the default.
static int32_t fov_set;

void bl_vampire_SetFov(_cpu *cpu)
{
    fov_set = atoi((const char *)REG2PTR(*(const uint32_t *)REG2PTR(esp)));
    eax = (uint32_t)fov_set;
}

void bl_vampire_ZoomOutFov(_cpu *cpu)
{
    *(uint32_t *)REG2PTR(edi + 0x1e78) = fov_set > 0 ? (uint32_t)fov_set : ebx;
}

// Griffith Park frenzy fix (griffith-frenzy-werewolf-fix 1.2.1, the Unofficial Patch's
// loader plugin; its maps already make frenzy possible there). While the player frenzies
// on sp_observatory_2, the player's body stays behind and a player-owned FrenzyShadow
// moves instead, so the werewolf stood on and collided with the body. Here the werewolf's
// movement traces skip the body and hit the shadow, and the body never becomes the
// werewolf's ground entity. The plugin patched the engine trace's vtable and the
// werewolf's; the same calls are hooked at their call sites instead.
static struct {
    uint32_t entlist, globals, vt_shadow, vt_wolf, vt_filter, vt_filter_simple;  // guest addresses
} wolf_va;
static uint32_t wolf_player, wolf_shadow, wolf_wolf;               // set while the fix applies
static uint32_t wolf_hplayer = ~0u, wolf_hshadow = ~0u, wolf_hwolf = ~0u;
static uint32_t wolf_cache, wolf_cache_idx = ~0u, wolf_cache_serial;  // last werewolf found
static uint32_t wolf_filter;                                          // the wrapping filter

extern char bl_vampire_WolfShouldHit[];

// g_pEntityList's entries: 0x2000 of { ?, entity, serial }, a handle is serial << 13 | index.
static uint32_t entity_entry(uint32_t i) { return u32_at(u32_at(wolf_va.entlist)) + i * 12; }

static uint32_t from_handle(uint32_t h)
{
    if (h == ~0u || !u32_at(wolf_va.entlist)) return 0;
    uint32_t e = entity_entry(h & 0x1fff);
    return u32_at(e + 8) == h >> 13 ? u32_at(e + 4) : 0;
}

static int on_observatory(void)
{
    uint32_t g = u32_at(wolf_va.globals), name = g ? u32_at(g + 0x24) : 0;  // gpGlobals->mapname
    if (!name) return 0;
    const char *m = (const char *)bl_g2h(name);
    return !strcasecmp(m, "sp_observatory_2") || !strcasecmp(m, "sp_observatory_2.bsp") ||
           !strcasecmp(m, "maps/sp_observatory_2.bsp") || !strcasecmp(m, "maps\\sp_observatory_2.bsp");
}

// The player's FrenzyShadow (+0x1DB0 its handle) while the player frenzies (+0x146C > 0).
static uint32_t shadow_of(uint32_t player)
{
    if (!player || *(const int32_t *)bl_g2h(player + 0x146c) <= 0) return 0;
    uint32_t s = from_handle(u32_at(player + 0x1db0));
    return s && u32_at(s) == wolf_va.vt_shadow ? s : 0;
}

static int is_werewolf(uint32_t e)
{
    uint32_t name = u32_at(e + 0x26c);  // m_iName
    return u32_at(e) == wolf_va.vt_wolf && name && !strcmp((const char *)bl_g2h(name), "werewolf");
}

static void wolf_reset(void)
{
    wolf_player = wolf_shadow = wolf_wolf = 0;
    wolf_hplayer = wolf_hshadow = wolf_hwolf = ~0u;
}

static int wolf_valid(void)
{
    return wolf_player && wolf_shadow && wolf_wolf && on_observatory() && from_handle(wolf_hplayer) == wolf_player &&
           from_handle(wolf_hshadow) == wolf_shadow && from_handle(wolf_hwolf) == wolf_wolf &&
           shadow_of(wolf_player) == wolf_shadow;
}

// 0x1016C5BE, in the player's think (ebp the player): finds the frenzying player, their
// shadow and the werewolf. The replacement pushes the module addresses it needs.
void bl_vampire_WolfWatch(_cpu *cpu)
{
    memcpy(&wolf_va, REG2PTR(esp), sizeof wolf_va);
    esp += sizeof wolf_va;
    uint32_t player = ebp, shadow = player ? shadow_of(player) : 0;
    if (!on_observatory() || !shadow) {
        wolf_reset();
        return;
    }
    if (!(wolf_cache && wolf_cache_idx < 0x2000 && u32_at(entity_entry(wolf_cache_idx) + 4) == wolf_cache &&
          u32_at(entity_entry(wolf_cache_idx) + 8) == wolf_cache_serial && is_werewolf(wolf_cache))) {
        wolf_cache = 0, wolf_cache_idx = ~0u, wolf_cache_serial = 0;
        for (uint32_t i = 0; i < 0x2000 && !wolf_cache; i++) {
            uint32_t e = u32_at(entity_entry(i) + 4);
            if (e && is_werewolf(e)) wolf_cache = e, wolf_cache_idx = i, wolf_cache_serial = u32_at(entity_entry(i) + 8);
        }
        if (!wolf_cache) {
            wolf_reset();
            return;
        }
    }
    if (wolf_player != player || from_handle(wolf_hplayer) != player) {
        wolf_hplayer = ~0u;
        for (uint32_t i = 0; i < 0x2000; i++)
            if (u32_at(entity_entry(i) + 4) == player) {
                wolf_hplayer = u32_at(entity_entry(i) + 8) << 13 | i;
                break;
            }
    }
    wolf_hshadow = u32_at(player + 0x1db0);
    wolf_hwolf = wolf_cache_serial << 13 | wolf_cache_idx;
    if (wolf_hplayer == ~0u || from_handle(wolf_hwolf) != wolf_cache) {
        wolf_reset();
        return;
    }
    wolf_player = player, wolf_shadow = shadow, wolf_wolf = wolf_cache;
}

// Before IEngineTrace::TraceRay(ray, mask, filter, trace) at the werewolf's movement
// traces (args on the stack): when the filter passes the werewolf, the mask is solid and
// the shadow is within 160 units, the filter is wrapped by one that skips the body and
// hits the shadow.
void bl_vampire_WolfTrace(_cpu *cpu)
{
    uint32_t *args = REG2PTR(esp), f = args[2], vt, pass;
    if (!wolf_wolf || !f) return;
    vt = u32_at(f);
    if (vt == wolf_va.vt_filter) pass = u32_at(f + 0x10);
    else if (vt == wolf_va.vt_filter_simple) pass = u32_at(f + 4);
    else return;
    if (pass != wolf_wolf || (args[1] & ~0x20000u) != 0x200400b || !wolf_valid()) return;
    const float *s = bl_g2h(bl_call_guest(cpu, u32_at(u32_at(wolf_shadow) + 0x364), BL_THISCALL, wolf_shadow, 0, NULL));
    const float *w = bl_g2h(bl_call_guest(cpu, u32_at(u32_at(wolf_wolf) + 0x364), BL_THISCALL, wolf_wolf, 0, NULL));
    float dx = s[0] - w[0], dy = s[1] - w[1];
    if (!(sqrtf(dx * dx + dy * dy) < 160.0f) || shadow_of(wolf_player) != wolf_shadow || !u32_at(vt + 4)) return;
    if (!wolf_filter) wolf_filter = bl_guest_malloc(24);
    uint32_t *m = bl_g2h(wolf_filter);  // vtable { ShouldHitEntity, GetTraceType }, then the filter
    m[0] = bl_h2g(bl_vampire_WolfShouldHit), m[1] = u32_at(vt + 4);
    m[2] = wolf_filter, m[3] = pass, m[4] = 0, m[5] = f;
    args[2] = wolf_filter + 8;
}

// The wrapping filter's ShouldHitEntity(entity, contents) (thiscall, +0xC the filter it wraps).
void bl_vampire_WolfShouldHit_c(_cpu *cpu)
{
    const uint32_t *a = REG2PTR(esp);  // return address, entity, contents mask
    uint32_t inner = u32_at(ecx + 12);
    if (a[1] == wolf_player) eax = 0;
    else if (a[1] == wolf_shadow) eax = 1;
    else eax = bl_call_guest(cpu, u32_at(u32_at(inner)), BL_THISCALL, inner, 2, (uint32_t[]){ a[1], a[2] });
}

// Before the werewolf's movement calls SetGroundEntity(entity) (0x1026E843, esi the
// werewolf, the entity on the stack): the player's body is never its ground.
void bl_vampire_WolfGround(_cpu *cpu)
{
    uint32_t *arg = REG2PTR(esp);
    if (wolf_wolf && esi == wolf_wolf && *arg == wolf_player && wolf_valid()) *arg = 0;
}

// History stat reset fix (history-stat-reset-fix 1.5.2, the Unofficial Patch's loader
// plugin, read from its disassembly). Character creation sets the History with
// SetVHistory (0x100D6DD3, or -1 at 0x100D6DE6) and never takes the old History's stat
// changes back, so changing gender or History, also after Auto-Spend Points, left stats
// and the point pool off. After either call the character is put through the History
// change routine again (0x10206AA0), which takes the History's changes away and gives
// them again, keeping stat 0x22 of its base stat list, and the History is set again.
static uint32_t history_busy;  // the character being reset

// The character's base stat list: of its lists (+0x13C0, +0x13BC of them) the first of
// type 0x23 (+4) whose +0x10 is 0.
static uint32_t base_stats(uint32_t ch)
{
    uint32_t n = u32_at(ch + 0x13bc), a = u32_at(ch + 0x13c0);
    if (!a || n - 1 >= 0x20) return 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t l = u32_at(a + 4 * i);
        if (l && !u32_at(l + 0x10) && u32_at(l + 4) == 0x23) return l;
    }
    return 0;
}

static void history_reset(_cpu *cpu, uint32_t histories, uint32_t ch, uint32_t history)
{
    uint32_t stats = base_stats(ch);
    if (stats && !history_busy) {
        uint32_t stat = 0x22, kept = this_call(cpu, vampire_StatGetBase, stats, 1, &stat);
        uint32_t cur = this_call(cpu, vampire_GetVHistory, ch, 0, NULL);
        history_busy = ch;
        this_call(cpu, vampire_ChangeHistory, histories, 2, (uint32_t[]){ cur, ch });
        history_busy = 0;
        if ((stats = base_stats(ch))) this_call(cpu, vampire_StatSetBase, stats, 2, (uint32_t[]){ 0x22, kept });
        // The client's character sheet, when open, shows the new stats.
        uint32_t sheet = u32_at(bl_call_guest(cpu, bl_h2g(client_HistoryUI), BL_CDECL, 0, 0, NULL));
        if (sheet && u32_at(sheet + 0x274) && u32_at(sheet + 0xedc))
            bl_call_guest(cpu, bl_h2g(client_HistoryRefresh), BL_THISCALL, u32_at(sheet + 0xedc), 1, &cur);
    }
    this_call(cpu, vampire_SetVHistory, ch, 1, &history);
}

// At 0x100D6DD8 and 0x100D6DEB (esi the character, edi the History); the replacement
// pushes the History list (0x1074F028).
void bl_vampire_HistoryReset(_cpu *cpu)
{
    uint32_t histories = *(const uint32_t *)REG2PTR(esp);
    esp += 4;
    history_reset(cpu, histories, esi, edi);
}

void bl_vampire_HistoryResetNone(_cpu *cpu)
{
    uint32_t histories = *(const uint32_t *)REG2PTR(esp);
    esp += 4;
    history_reset(cpu, histories, esi, ~0u);
}

// The History change routine's "already has it" test (0x10206AD1, ebx the new History,
// ebp the current one, esi the character): ecx 0 goes ahead, 1 skips.
void bl_vampire_HistorySame(_cpu *cpu)
{
    if (ebx != ebp) ecx = 0;
    else if (history_busy == esi) history_busy = 0, ecx = 0;
    else ecx = 1;
}

// Protean Improved's Warform Frenzy (protean-improved 1.2.2, the Unofficial Patch's
// loader plugin, read from its disassembly): Protean 5 (Warform, flag +0x1EDC) and a
// frenzy (+0x146C > 0, the FrenzyShadow's handle at +0x1DB0) together, without a second
// controller or doubled bonuses. The plugin jumps to code it copies in; each site here
// does the same. Decisions go back on the guest stack so no register is changed.
static int frenzying(uint32_t pc) { return *(const int32_t *)bl_g2h(pc + 0x146c) > 0; }

static uint32_t entity_at(uint32_t entlist, uint32_t h)
{
    if (h == ~0u) return 0;
    uint32_t e = u32_at(entlist) + (h & 0x1fff) * 12 + 4;
    return u32_at(e + 4) == h >> 13 ? u32_at(e) : 0;
}

static void push_u32(_cpu *cpu, uint32_t v)
{
    esp -= 4;
    *(uint32_t *)REG2PTR(esp) = v;
}

// 0x1016C558, the player's think (ebp the player): al the Warform flag, 0 in a frenzy.
void bl_vampire_WarformFlag(_cpu *cpu)
{
    eax = (eax & ~0xffu) | (frenzying(ebp) ? 0 : *(const uint8_t *)bl_g2h(ebp + 0x1edc));
}

// 0x1033E9BE (eax the player): 1 skips ending the frenzy.
void bl_vampire_FrenzyKeep(_cpu *cpu) { push_u32(cpu, frenzying(eax)); }

// 0x101F9177, Protean 5 switched on (edi the player): in a frenzy the FrenzyShadow takes
// the Warform's place instead of a new controller; 1 goes on at 0x101F8FA3. The
// replacement pushes the warform list (0x10750CB4), gpGlobals and g_pEntityList.
void bl_vampire_WarformShadow(_cpu *cpu)
{
    const uint32_t *a = REG2PTR(esp);
    uint32_t entlist = a[0], globals = a[1], warforms = a[2], pc = edi, shadow;
    esp += 12;
    if (!pc || !frenzying(pc) || !(shadow = entity_at(entlist, u32_at(pc + 0x1db0)))) {
        push_u32(cpu, 0);
        return;
    }
    *(uint8_t *)bl_g2h(pc + 0x1edc) = 0;
    uint32_t stats = pc + 0x23d4;
    bl_call_guest(cpu, u32_at(u32_at(pc) + 0x1a4), BL_THISCALL, pc, 1, &stats);
    bl_call_guest(cpu, u32_at(u32_at(shadow) + 0x1a4), BL_THISCALL, shadow, 1, &stats);
    *(uint32_t *)bl_g2h(pc + 0x1c68) = u32_at(u32_at(globals) + 0xc);  // gpGlobals->curtime
    this_call(cpu, vampire_WarformAdd, warforms, 2, (uint32_t[]){ pc, 2 });
    esi = shadow;
    push_u32(cpu, 1);
}

// 0x103510D7 (edi the player, cl the Warform state compared): 1 when equal, which a
// frenzy always is; 0 goes on at 0x10351131.
void bl_vampire_WarformSame(_cpu *cpu)
{
    push_u32(cpu, frenzying(edi) || *(const uint8_t *)bl_g2h(edi + 0x1edc) == (uint8_t)ecx);
}

// At the start of 0x101E56E0 and 0x101E5B30: an argument that is the FrenzyShadow's
// owner (+0x9C) during a Warform frenzy becomes the local player. The replacement
// pushes the shadow's vtable and g_pEntityList.
void bl_vampire_WarformTarget(_cpu *cpu)
{
    const uint32_t *a = REG2PTR(esp);
    uint32_t entlist = a[0], vt_shadow = a[1];
    esp += 8;
    uint32_t *arg = REG2PTR(esp + 4);
    if (!*arg) return;
    uint32_t sa = eax, sc = ecx, sd = edx;
    uint32_t p = bl_call_guest(cpu, bl_h2g(vampire_LocalPlayer), BL_CDECL, 0, 0, NULL);
    eax = sa, ecx = sc, edx = sd;
    uint32_t pc = p ? u32_at(p + 0xa8) : 0, shadow;
    if (pc && frenzying(pc) && *(const uint8_t *)bl_g2h(pc + 0x1edc) &&
        (shadow = entity_at(entlist, u32_at(pc + 0x1db0))) && u32_at(shadow) == vt_shadow && u32_at(shadow + 0x9c) == *arg)
        *arg = p;
}
