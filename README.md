# Bloodlines-MacOS-Metal

A static recompilation of *Vampire: The Masquerade – Bloodlines* (Troika, 2004) to
native arm64 macOS, with Direct3D 9 drawn through Metal.

This repository holds only the runtime and the tools. **It contains no game files and
no recompiled game code.** You need your own copy of the game (the GOG release, with
the Unofficial Patch it ships with). The tools translate your copy's DLLs on your Mac;
the result stays in `build/` and must not be shared.

## How it works

- Each 32-bit x86 game DLL is translated with
  [SR/SRW](https://github.com/M-HT/SR) (a git submodule) to LLasm and then LLVM IR,
  and compiled to an arm64 object.
- The runtime (`runtime/`) provides what the game imports, written natively for
  macOS:
  - Win32 (files, threads, windows, registry, GDI text) on AppKit and Core Text.
  - DirectInput on AppKit events and GameController.
  - DirectSound on Core Audio.
  - Direct3D 9 on Metal, with the D3D9 shaders translated to Metal Shading Language.
- `tests/boot.c` loads the recompiled modules and calls `LauncherMain`, as
  `Vampire.exe` does.
- The supported game files are pinned by SHA-256 (`modules/hashes.txt`); the tools
  refuse anything else.

Progress, what was verified and what was not are in [PORTING_LOG.md](PORTING_LOG.md).

## Building

Requires:

- A Mac with Apple silicon, running macOS 26 or later.
- Xcode.
- Homebrew LLVM (`/opt/homebrew/opt/llvm`). To use another LLVM, set `LLVM` to its
  `bin` folder. The build stops early if `$LLVM/opt` is missing.
- `ldc2` (the D compiler, for llasm).
- Python 3. The tools run with `python3`. The texture and prop tools (`tex_*.py`,
  `prop_*.py`) also need numpy and Pillow (`tools/requirements.txt`). Run those with a
  Python that has them, such as Homebrew's `python3.13`. The macOS `python3` (3.9) does
  not have them.

```sh
git clone --recursive https://github.com/Alyx-ML/Bloodlines-MacOS-Metal
cd Bloodlines-MacOS-Metal
sh tools/build_tools.sh                       # SRW and llasm
sh tools/rebuild_all.sh "/path/to/Bloodlines"  # translate the game DLLs (about 15 min)
sh tools/build_runtime.sh
sh tools/link_boot.sh                          # build/tests/boot
```

`CODEGEN_ONLY=1 sh tools/rebuild_all.sh ...` redoes only the LLVM steps (about a
minute) when the translation itself has not changed.

`sh tools/runtime_unit.sh` builds and runs the runtime's unit test
(`tests/runtime_unit.c`). It needs no game files. Run `tools/build_runtime.sh` first.

Only one build runs at a time. Each build script takes a lock on `build/`. A second
build waits until the first one ends. If the build that holds the lock is no longer
running, the next build takes the lock over.

## Running

```sh
cd build/tests
BL_WINDOW=1 ./boot "/path/to/Bloodlines"
```

Without a command line, the game starts in a window with `-game Unofficial_Patch`
when that folder exists. Saves and `config.cfg` live in
`~/Library/Application Support/Vampire The Masquerade - Bloodlines/`.

Options (environment variables). These are the ones a player or tester needs:

| Variable | Effect |
| --- | --- |
| `BL_WINDOW=1` | open a window (otherwise headless) |
| `BL_AUDIO=0/1` | sound plays in a window by default; 0 mutes it, 1 plays it headless too |
| `BL_FULLSCREEN=0/1` | start in a window or full screen; Cmd+Ctrl+F toggles |
| `BL_FPS_MAX=n` | frame cap, default 60 (the game's physics expect it); 0 = no cap |
| `BL_UPSCALER=u` | the upscaler: `metalfx` (default) or `fsr4` (AMD FSR 4); wins over the Visual tab's drop-down at start |
| `BL_UPSCALER_QUALITY=q` | the 3D view's resolution before upscaling: `native` (default), `quality` (67%), `balanced` (59%), `performance` (50%) or `ultra` (33%); wins over the Visual tab's drop-down at start |
| `BL_FSR4_DIR=dir` | where FSR 4 is loaded from (default: the FSR4Metal folder next to the game's) |
| `BL_FOV=degrees` | the player's field of view at 4:3 (the game's is 90, allowed 50 to 130); wider screens see more at the sides |
| `BL_WIDESCREEN=stretch` | keep the game's 4:3 picture stretched; turns off the wide-screen correction and the wider field of view |
| `BL_TONEMAP=t` | test tone maps, off by default: `gt7` (Gran Turismo 7), `pbr` (Khronos PBR Neutral), or `gt7x`/`pbrx`, which first expand highlights by `BL_TONEMAP_EXPAND` (0 to 1, default 0.8) |
| `BL_ANISO=n` | anisotropic filtering, default 16, 1 = off |
| `BL_UPSCALE=0` | use the game's own textures, not the upscaled ones |
| `BL_REMODEL=0` | use the game's own prop models, not the remodels |
| `BL_SHADER_EARLY=0` | compile shaders only when a draw first needs them; by default they compile in the background when the game creates them |
| `BL_DEEP_COLOR=0` | 8-bit back buffer and window; by default the back buffer is 16-bit and the window 10-bit |
| `BL_PACING=0` | plain presents; by default each frame is held for whole refreshes when the screen rate is a multiple of the cap (120 Hz ProMotion) |
| `BL_PACING_STATS=1` | log how many refreshes apart frames reach the screen |
| `BL_RAW_MOUSE=0` | use macOS's accelerated pointer for mouse look |
| `BL_PAD_LOOK=n` | controller look speed, default 1400 |
| `BL_DATA_DIR=dir` | where saves and settings go (`off` = the game folder) |

The effects. Each is a setting in the options, saved in the registry. Set to 0 or 1, the
variable wins over the saved setting at start. A click in the options wins after that.

| Variable | Option | Default |
| --- | --- | --- |
| `BL_AO` | Enhanced tab: Ambient Occlusion | off |
| `BL_SSR` | Enhanced tab: Reflections | off |
| `BL_HDR` | Enhanced tab: HDR | off |
| `BL_FOG` | Enhanced tab: Volumetric Light | off |
| `BL_SSS` | Enhanced tab: Skin Scattering | off |
| `BL_SHADOWS` | Visual tab: Shadows set to Enhanced | off |
| `BL_BLOOM` | Enhanced tab: Bloom | on |
| `BL_EXPOSURE` | Enhanced tab: Eye Adaptation | on |
| `BL_SSIL` | Enhanced tab: Bounced Light | on |
| `BL_GI` | Enhanced tab: Global Illumination | on |
| `BL_ROUND` | Enhanced tab: Smooth Characters | on |
| `BL_SHARPEN` | Enhanced tab: Sharpening | on |
| `BL_SKIN_DETAIL` | Enhanced tab: Skin Detail | on |
| `BL_COMPASS` | Gameplay tab: the quest compass | on |

The other switches tune the effects or help with debugging. Each is explained in a
comment in the file that reads it (for `metal_render.m`, mostly its header comment). The
few without a comment are traces that log to stderr. By file:

- `runtime/d3d9/metal_render.m`: `BL_MAX_FRAMES`, `BL_DUMP_FRAME`, `BL_DUMP_DIR`,
  `BL_DRAW_STATS`, `BL_DRAW_DUMP`, `BL_TEX_STATS`, `BL_MOVIE_DUMP`, `BL_SHADER_STATS`,
  `BL_SHADER_SALT`, `BL_GPU_STATS`, `BL_HITCH`, `BL_PREFETCH`, `BL_FF_TRACE`,
  `BL_FORCE_VIEWPORT`, `BL_SHADOW_SHOW`, `BL_TAA_JITTER`,
  `BL_AO_RADIUS`, `BL_AO_THICKNESS`, `BL_AO_STRENGTH`, `BL_AO_POWER`,
  `BL_SSR_STRENGTH`, `BL_SSR_FRESNEL`, `BL_SSR_BLUR`, `BL_GLOSS`,
  `BL_PBR`, `BL_PBR_BUMP`, `BL_PBR_SPEC`, `BL_POM_DEPTH`, `BL_POM_DIST`,
  `BL_HDR_PEAK`, `BL_HDR_HEADROOM`, `BL_FOG_DENSITY`, `BL_FOG_DIST`,
  `BL_SSS_WIDTH`, `BL_SSS_STRENGTH`, `BL_SSS_SHEEN`, `BL_SSS_THROUGH`, `BL_SSS_EYES`,
  `BL_SHADOW_RES`, `BL_PCSS`, `BL_PCSS_SOFT`, `BL_PCSS_MAX`, `BL_PCSS_SEARCH`,
  `BL_CONTACT`, `BL_CONTACT_LENGTH`, `BL_CONTACT_STRENGTH`,
  `BL_PROP_SHADOWS`, `BL_PROP_SHADOWS_STRENGTH`, `BL_PROP_SHADOWS_RES`,
  `BL_PROP_SHADOWS_NEAR`, `BL_PROP_SHADOWS_SOFT`, `BL_PROP_SHADOWS_DEBUG`,
  `BL_PROP_SHADOWS_LOG`, `BL_SHADOWS_AB`,
  `BL_SHARPEN_STRENGTH`, `BL_SKIN_DETAIL_STRENGTH`, `BL_SKIN_DETAIL_SIZE`,
  `BL_SKIN_DETAIL_MAX`, `BL_SKIN_DETAIL_MAX_BODY`, `BL_SKIN_DETAIL_BODY`,
  `BL_CLOTH_DETAIL`, `BL_CLOTH_DETAIL_STRENGTH`, `BL_CLOTH_DETAIL_SIZE`,
  `BL_CLOTH_DETAIL_MAX`, `BL_DETAIL`, `BL_DETAIL_STRENGTH`, `BL_SHINE`,
  `BL_CHARLIGHT`, `BL_CHARLIGHT_MIN`, `BL_HAIR_U`, `BL_HAIR_FADE`, `BL_HAIR_SOFT`,
  `BL_HAIR_STRANDS`, `BL_HAIR_ROOT`, `BL_HAIR_GLOW`, `BL_HAIR_MESH`,
  `BL_TESS`, `BL_TESS_ROUND`, `BL_PROP_TESS`, `BL_LIGHTMAP_SMOOTH`,
  `BL_LIGHTMAP_SMOOTH_AT`, `BL_REBAKE`, `BL_BLOOM_STRENGTH`, `BL_BLOOM_THRESHOLD`,
  `BL_BLOOM_AT`, `BL_EXPOSURE_RANGE`, `BL_SSIL_RADIUS`, `BL_SSIL_STRENGTH`,
  `BL_SSIL_BLUR`, `BL_GI_MIX`, `BL_GI_LOG`
- `runtime/d3d9/d3d9_objects.c`: `BL_D3D_TRACE` (also `d3d9_device.c`), `BL_QI_TRACE`,
  `BL_COM_BT`, `BL_VIEWPORT_WATCH`
- `runtime/d3d9/d3d9_resources.c`: `BL_DUMP_SHADERS`, `BL_LOCK_TRAP`
- `runtime/d3d9/d3d9_shader.c`: `BL_FF_HIGHLIGHT`
- `runtime/d3d9/dsound.c`: `BL_AUDIO_TRACE`
- `runtime/d3d9/dinput8.c`: `BL_INPUT_TRACE`
- `runtime/d3d9/lm_bake.m`: `BL_BAKE_NOSHADOW`, `BL_BAKE_RAYS`, `BL_BAKE_BLUR`
- `runtime/d3d9/tex_detail.m`: `BL_TEX_DIR`
- `runtime/bl_cocoa.m`: `BL_CLICKS`, `BL_KEYS` (scripted clicks and key presses)
- `runtime/bl_msvcrt.c`: `BL_IMPORT_TRACE`, `BL_BACKTRACE_AT`
- `runtime/bl_thread.c`: `BL_THREAD_TRACE`, `BL_WAIT_TRACE`
- `runtime/bl_gdi.c`: `BL_GDI_TRACE`, `BL_FONT_TRACE`
- `runtime/bl_registry.c`: `BL_REG_TRACE`
- `runtime/bl_vm.c`: `BL_HEAP_TRACE`
- `runtime/bl_hitch.c`: `BL_HITCH_STACKS`
- `runtime/bl_vgui.c`: `BL_VGUI_CHECK`
- `tests/bake_view.m`: `BL_BAKE_LIST`

Upscaled textures: export with `tools/tex_extract.py --map NAME`, put the upscaled PNG
next to its export (an upscaler's `-suffix` on the name is fine), then run
`tools/tex_pack.py`. It writes the upscaled textures to `build/hires/`, and the renderer
draws each in place of the game's texture whose contents match the original exactly. The
game's files are not touched: the game places wall and floor textures by their size, so
only the GPU sees the larger ones.

Controllers (Xbox, PlayStation, MFi) are mapped to the default key bindings; the
layout is at the top of `runtime/bl_gamecontroller.m`.

## Legal

Vampire: The Masquerade – Bloodlines is © Activision; World of Darkness is © Paradox
Interactive. This project is not affiliated with either and distributes none of
their code or data.
