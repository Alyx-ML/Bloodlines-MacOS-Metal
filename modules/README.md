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

## GameUI
- `0x10029250` vgui `RichText::GetCursorLine` (63 bytes), replaced by
  `bl_vgui_GetCursorLine`: a binary search over the line-break table instead of a
  linear scan, which made the `-dev` console O(n²).

## shaderapidx9
- `0x2A026250` the texture memory estimate (481 bytes), replaced by
  `bl_shaderapi_TextureMemory` (`runtime/bl_shaderapi.c`, `runtime/llasm/shaderapi.llasm`).
  Unofficial Patch 12.0 restored the measurement that creates 256x256 textures until
  one fails; here that uses up the guest heap, so it returns 11.1's fixed answer.
