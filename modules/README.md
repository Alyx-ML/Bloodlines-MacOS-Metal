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

## vampire
- Subtitle Pause Fix (see engine): the `CBaseEntity::Activate` call at `0x1022C50F` in
  `CPropRadio::Activate` becomes `bl_vampire_RadioActivate`, and the
  `CBaseEntity::SetFakeSilence` call at `0x1022C807` (the radio's switch) becomes
  `bl_vampire_RadioSilence`. `global_aliases.manual.sci` names both callees
  (`vampire_EntityActivate`, `vampire_SetFakeSilence`).

## mssmp3, vaudio_miles
`global_aliases.manual.sci` names, for the Subtitle Pause Fix's check that a radio stream is
decoded by Miles' MP3 provider, mssmp3's decoder (`0x26F05AD0`, `mssmp3_Decode`) and the
first two entries of vaudio_miles' stream vtable at `0x1000D184` (`0x10001AA0`, `0x10001AB0`).
