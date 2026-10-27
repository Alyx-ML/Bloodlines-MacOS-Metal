# Per-module SRW inputs

`<module>/*.sci` files are copied into `build/<module>/` before SRW runs.
Write hand-made fixes here; the pipeline generates the rest.

- `external_procedures.sci`: `loc_<addr>,bl_crt_<name>` replaces a statically linked
  MSVC C-runtime routine with the runtime's native version (`runtime/bl_crt.c`,
  `runtime/llasm/crt.llasm`). `bl_vgui_<name>` does the same for GameUI's vgui
  (`runtime/bl_vgui.c`, `runtime/llasm/vgui.llasm`). Used for hand-written CRT assembly SRW cannot
  translate, such as math helpers that return results in CPU flags across a call.
- `ignored_areas.sci`: `loc_<addr>,<length>` bytes SRW must not translate (the
  replaced routine's body).

## vstdlib
- `0x100048D0` `_CIsqrt`, `0x100048E4` `sqrt` and their shared worker up to
  `0x10004989` (186 bytes).

## FileSystem_Stdio
- `0x10007C40` the wildcard search's matcher (584 bytes), replaced by `bl_fs_FindMatch`
  (`runtime/bl_filesystem.c`, `runtime/llasm/filesystem.llasm`): it walks the file tree
  from the start entry in order and compares prefix and extension directly, without the
  original's per-entry string work; most of the start-up and map-load time went there.
- `global_aliases.manual.sci` names the symbol table getter at `0x1000CB20`
  (`FileSystem_SymbolTable`), which the replacement calls for the entries' names.

## GameUI
- `0x10029250` vgui `RichText::GetCursorLine` (63 bytes), replaced by
  `bl_vgui_GetCursorLine`: a binary search over the line-break table instead of a
  linear scan, which made the `-dev` console O(n²).
- `0x10024EB0` vgui `PropertyDialog::AddPage` (29 bytes), replaced by `bl_vgui_AddPage`:
  does what the original did, and after the options dialog's Visual tab adds an
  "Enhanced" tab (a plain `PropertyPage`).
- `0x1001BD30` `COptionsSubVisual::OnResetData` (75 bytes), replaced by
  `bl_vgui_VisualReset`: does the original's resets, then the first time adds the
  renderer's effects as check boxes on the Enhanced tab.
- `0x1001BCD0` `COptionsSubVisual`'s destructor body (11 bytes), replaced by
  `bl_vgui_VisualDestroy`, which forgets those boxes.
- `global_aliases.manual.sci` gives the routines those replacements call global names
  (`GameUI_<name>`): the check box constructor, Panel position and size, and the page
  controls' reset methods, and the PropertyPage constructor.
- Console Pause Fix (see engine): `0x10022070` vgui `Frame::SetVisible` and `0x100059D0`
  (the game menu's hide, which sends "unpause") go through `bl_GameUI_FrameVisible` and
  `bl_GameUI_HideUI`. The second replacement also holds `GameUI_Globals`, which returns the
  address of the globals at `0x1006C330`. `global_aliases.manual.sci` names `0x100220E0`
  (`GameUI_Frame_SetMinimizeButtonVisible`).
- Gothic options screen, with `runtime/bl_options.c` (drawing in `runtime/bl_gothic.c`).
  Layout, at the end of the game's own (each replaces the `pop esi` epilogue):
  - `0x10018A4F` `COptionsDialog::PerformLayout` (`bl_options_DialogLayout`): the dialog
    full screen, Cancel and OK at the bottom right;
  - `0x1003F4C0` `PropertySheet::PerformLayout` (`bl_options_SheetLayout`): the tabs in a
    row under the title, the page under them.
  Each of these first instructions calls a native that may skip the rest of the routine:
  - `0x10021A40` vgui `Frame::PaintBackground` (`bl_options_FrameBackground`): for the
    options dialog, places the page's controls, has the renderer draw the darkened
    backdrop, then draws the title, divider and hairlines; for a confirmation or message
    box over it, a dark panel in a gold frame with its title;
  - `0x10032BB0` `Button::Paint` (`bl_options_ButtonPaint`): tabs, buttons, tick boxes,
    drop-down list items, list headers;
  - `0x10023D80` `Label::Paint` (`bl_options_LabelPaint`): labels, notes, key list cells;
  - `0x10036570` `Slider::PaintBackground` (`bl_options_SliderBackground`): the slider;
  - `0x100271C0` `TextEntry::PaintBackground` (`bl_options_EntryBackground`): drop-down
    boxes as "< value >";
  - `0x10025A90` `ComboBox::OnMousePressed` (`bl_options_ComboPressed`): the arrows step
    to the previous or next choice;
  - `0x100402E0` `ScrollBarSlider::PaintBackground` (`bl_options_ScrollBackground`);
  - `0x10034480` `Menu::Paint` (`bl_options_MenuPaint`): drop-down lists;
  - `0x1001D130` `Panel::PaintBackground` (`bl_options_PanelBackground`): none, a red bar
    for the key list's selected row;
  - `0x1001D110` `Panel::PaintBorder`, `0x10025300` `PropertyPage::PaintBorder`,
    `0x10035490` `ImagePanel::PaintBackground`, `0x10036040` `Slider::Paint` and
    `0x10040200` `ScrollBarSlider::Paint` (`bl_options_Skip`): left out.
  - `0x10010EBB` in `VControlsListPanel::Paint`, after the list (`bl_options_KeyCapture`):
    a red box for the key being set; skipping jumps to the epilogue at `0x10011052`.
  Only panels inside the dialog, or a box open over it, change. The first replacement also
  holds `GameUI_OptionsVtable`, which returns `COptionsDialog`'s vtable (`0x10054694` in the
  DLL); the module's data isn't at the DLL's addresses, so other classes' vtables are found
  by their distance from it. `global_aliases.manual.sci` names `0x1001FB70`
  (`GameUI_Surface`), `0x1001FB50` (`GameUI_Input`), `0x1001FBA0` (`GameUI_IPanel`) and
  `0x10023B50` (`GameUI_Label_GetText`).

## engine
Console Pause Fix 1.1.0 (Unofficial Patch's loader plugin), with `runtime/bl_console.c`:
- `instruction_replacements.manual.sci`: `0x2010DC10` `Con_ShowConsole` and `0x2001A570`
  `IVEngineClient::ClientCmd` go through `bl_engine_ShowConsole` and `bl_engine_ClientCmd`.
  Each replacement also opens the rest of the original as a global proc
  (`engine_ShowConsoleOrig`, `engine_ClientCmdOrig`) that the native calls.
- `global_aliases.manual.sci` names `0x2010D650` (`engine_HideGameUI`), which closing the
  console calls to go back to the game.
- Subtitle Pause Fix 1.3.0, with `runtime/bl_subtitle.c`: `0x201188B0` (the caption
  timing's read of the sound device time, vtable +0x38) becomes `bl_engine_SentenceTime`,
  and `0x2002D130` (the call that reads the pause state into `cl.paused`) becomes
  `bl_engine_PauseState`. Both push the engine globals the natives read.
  `global_aliases.manual.sci` names the pause state read (`0x2003C190`), the MP3 mixer's
  GetOutputData (`0x20139C80`), the MP3 source's sample rate (`0x20137970`) and a channel's
  sample position (`0x201383E0`).

## shaderapidx9
- `0x2A026250` the texture memory estimate (481 bytes), replaced by
  `bl_shaderapi_TextureMemory` (`runtime/bl_shaderapi.c`, `runtime/llasm/shaderapi.llasm`).
  Unofficial Patch 12.0 restored the measurement that creates 256x256 textures until
  one fails; here that uses up the guest heap, so it returns 11.1's fixed answer
  for both versions.

## client
- `0x1018C870` the scheme font name for the screen size (128 bytes), replaced by
  `bl_client_FontName` (`runtime/bl_client.c`, `runtime/llasm/client.llasm`): the same
  rule as the game (the largest size whose 4:3 area fits the screen), with Unofficial
  Patch's 1920, 2400 and 2880 font sets added to the game's 640 to 1600.
- `global_aliases.manual.sci` names the screen width and height getters at `0x100CD100`
  and `0x100CD0F0` (`client_ScreenWide`, `client_ScreenTall`).
- `instruction_replacements.manual.sci`: in `CViewRender::Render`, the `je` at
  `0x10191FD5` that skips the hidden `r_anamorphic`'s "field of view times 4/3" now
  calls `bl_client_HorPlus` (`runtime/bl_client.c`) and goes on at `0x10191FE3`. It widens
  the view's and the first-person hands' fields of view (view setup +0x38, +0x3c) for
  Hor+ on screens wider than 4:3.
- `instruction_replacements.manual.sci`: for history-stat-reset-fix, `0x101713E0` also
  holds `client_HistoryUI`, which returns the address of the global at `0x105FB14C` (the
  character sheet), and `global_aliases.manual.sci` names its refresh `0x1017D930`
  (`client_HistoryRefresh`); `runtime/bl_vampire.c` calls both.
- `instruction_replacements.manual.sci`: protean-improved's Filter Load Fix, the
  `cmp edi, eax; je` at `0x1019DA7D` that skips setting the Protean filter when its level
  is unchanged, asks `bl_client_FilterSame` (`runtime/bl_client.c`) first.
- `instruction_replacements.manual.sci`: vtmb-tweaks' bNoTracers, the `test eax, eax; je` at
  `0x10040998` that skips drawing a bullet tracer always jumps
  (`global_aliases.manual.sci` keeps its target `0x10040A4F` as code).
- `instruction_replacements.manual.sci`: the gothic pause menu (`runtime/bl_menu.c`), in a
  level only (menu state `0x10067850`, `client_MenuState`, not 0); the start-up menu is
  unchanged. `CVMainMenu::Paint` (`0x10065AF0`) first calls `bl_menu_Layout`, which moves
  the buttons under the logo. `PaintBackground` (`0x10065C40`) skips its black fill, and the
  smoke's call at `0x10065BDC` (`client_MenuSmoke`) is replaced by `bl_menu_Smoke`, which
  draws the gold divider and tells the renderer to put the darkened game behind the menu
  (`pause_backdrop` in `runtime/d3d9/metal_render.m`). The logo's draw at `0x10065C15`
  (`client_ImageDraw`) gets the mockup's place and size from `bl_menu_Logo`.
  `CVMenuButton::Paint` (`0x100653B0`) asks `bl_menu_ButtonPaint`, which draws the item in
  Cinzel capitals (a blood drop and an underline when hovered) and returns 1 to skip the
  game's paint. `global_aliases.manual.sci` also names the surface getter `0x101AC8D0` and
  the panel's SetPos and SetSize (`0x101A9890`, `0x101A98F0`). The font is
  `assets/fonts/Cinzel.ttf` (OFL).
- `instruction_replacements.manual.sci`: the gothic dialogue screen (`runtime/bl_dialog.c`).
  `CHudDialog::Paint`, once it has decided to draw (`0x100535A7`), calls `bl_dialog_Paint`,
  which draws the character's line and the answers over a dark fade, then runs
  `ComputeSizes` (`0x100530F0`) and leaves at `0x10053758`, past the game's frame, box and
  text. `ComputeSizes`' SetPos and SetSize calls (`0x100531D8`, `0x100531ED`) get the screen's
  origin and size from `bl_dialog_Pos` and `bl_dialog_Size`, so nothing is clipped to the old
  box. `CHudDialog::Key_Event` (`0x10055265`, after its first instruction) asks
  `bl_dialog_Key`, which picks the answer under the mouse on a click
  (`global_aliases.manual.sci`: `0x100549F0` `client_DialogPick`, `CHudDialog::Pick`) and
  returns "handled" instead of the game's show-or-hide of the line.
- `instruction_replacements.manual.sci`: the gothic HUD (`runtime/bl_hud.c`). Four paints
  draw in the new style (the vials as images the renderer puts on screen,
  `bl_metal_hud_image`) once they have their fades, then leave past the game's art:
  `CHealthAnkh::Paint` at `0x10051498` (`bl_hud_Health`, the left vial and the ammo),
  `CBloodBar::Paint` at `0x1004CD04` (skips the frame) and `0x1004CF2B` (`bl_hud_Blood`, the
  right vial, once the game has eased the shown blood), `CAmmoCounter::Paint`
  at `0x1004BF6A` (`bl_hud_Discipline`, the discipline's symbol; this class draws the
  discipline, not the ammo), and `CTargeted::Paint` at `0x1006401C` (`bl_hud_Ammo` notes the
  held weapon's ammo, then the crosshair is drawn as before). `global_aliases.manual.sci`
  names the HUD script's sprite lookup `0x100F11D0` (`client_HudSprite`).

## vampire
vtmb-tweaks (c6, github.com/c6-dev/vtmb-tweaks), Unofficial Patch's loader plugin, redone
as `instruction_replacements.manual.sci` at the plugin's own hook sites, which are the
same in the 11.1 module. The native parts are in `runtime/bl_vampire.c`;
`global_aliases.manual.sci` names the routines they call.
- bNoCorpseDespawn: `0x1032C402` never starts the corpse fade; `0x10265D72` fades out on
  death only a `CNPC_VRat`.
- bNPCsDropAllWeapons: `0x1032BA84` drops every weapon an NPC holds.
- bNonSolidRagdolls: `0x10154E93` puts `c_ragdoll_prop` ragdolls in the debris group.
- bStackableWeapons: `0x1032D142` (drop one of a stack), `0x1017788C` (switch weapons only
  when none is active), `0x1017724E` (an owned stackable weapon can be picked up again).
- The field of view fix: `0x100D2DC1` remembers the value the fov command sets, and
  zooming out (`0x10239E01`) restores it.
Not ported: bFixDoorsAtHighFPS (the port caps at 60 frames a second), bNoDoorAutoClose
(off in the patch) and bEnableAltF4.

The Unofficial Patch's griffith-frenzy-werewolf-fix (closed source, read from its
disassembly, never run) is redone the same way, in `runtime/bl_vampire.c`:
- `0x1016C5BE` in the player's think finds the frenzying player, their FrenzyShadow and
  the entity named `werewolf`, on sp_observatory_2 only (gpGlobals->mapname). The
  replacement pushes the module addresses the native part reads (g_pEntityList,
  gpGlobals, the shadow's, werewolf's and two trace filters' vtables).
- The `push` before `IEngineTrace::TraceRay` at the werewolf's eight movement traces
  (`0x1026AD63`, `0x1026EB35`, `0x102A9AEB`, `0x102E362C`, `0x102E38A3`, `0x103CBB55`,
  `0x103CBC4E`, `0x103CBD2F`) wraps a filter that passes the werewolf, for solid masks
  within 160 units of the shadow, in one whose ShouldHitEntity
  (`bl_vampire_WolfShouldHit`, `runtime/llasm/vampire.llasm`) skips the player's body and
  hits the shadow.
- The `push` before `SetGroundEntity` at `0x1026E840` passes NULL for the player's body.
The plugin patched the trace's and the werewolf's vtables; here the call sites are hooked.

history-stat-reset-fix (closed source, read from its disassembly): character creation
sets the History with `SetVHistory` and never takes the old one's stat changes back.
- `0x100D6DD8` and `0x100D6DEB`, the `pop edi` after `SetVHistory(history)` and
  `SetVHistory(-1)`: `bl_vampire_HistoryReset` / `HistoryResetNone` put the character
  through the History change routine (`0x10206AA0`, `vampire_ChangeHistory`) again,
  keeping stat 0x22 of its base stat list, refresh the client's character sheet and set
  the History again. The replacement pushes the History list (`0x1074F028`).
- `0x10206AD1`, the routine's "already has this History" `cmp; je`: goes ahead once for
  the character being reset (`bl_vampire_HistorySame`).
`global_aliases.manual.sci` names the stat list's `GetBase`/`SetBase`, `GetVHistory`,
`SetVHistory` and the change routine.

protean-improved's Warform Frenzy (closed source, read from its disassembly and the code
block it copies in) is redone at its six sites and its one byte patch, in
`runtime/bl_vampire.c`: `0x1016C558` (the Warform flag reads as off in a frenzy),
`0x1033E9BE` (the Protean command does not end a frenzy), `0x101F9177` (Protean 5 in a
frenzy uses the FrenzyShadow; `vampire_WarformAdd` is `0x10227A30`), `0x103510D7` (with its
`jne`, whose target `0x10351131` is named `vampire_WarformChanged`), the starts of
`0x101E56E0` and `0x101E5B30` (the shadow's owner becomes the local player,
`vampire_LocalPlayer` `0x101193B0`), and `0x1033ED73` (the `je` the plugin turns into a
`jmp`). The natives put their decisions on the guest stack, which the replacement pops,
so no register changes.
- Subtitle Pause Fix (see engine): the `CBaseEntity::Activate` call at `0x1022C50F` in
  `CPropRadio::Activate` becomes `bl_vampire_RadioActivate`, and the
  `CBaseEntity::SetFakeSilence` call at `0x1022C807` (the radio's switch) becomes
  `bl_vampire_RadioSilence`. `global_aliases.manual.sci` names both callees
  (`vampire_EntityActivate`, `vampire_SetFakeSilence`).

## mssmp3, vaudio_miles
`global_aliases.manual.sci` names, for the Subtitle Pause Fix's check that a radio stream is
decoded by Miles' MP3 provider, mssmp3's decoder (`0x26F05AD0`, `mssmp3_Decode`) and the
first two entries of vaudio_miles' stream vtable at `0x1000D184` (`0x10001AA0`, `0x10001AB0`).
