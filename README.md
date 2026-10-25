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

Requires Apple silicon, Xcode, Homebrew LLVM (`/opt/homebrew/opt/llvm`) and `ldc2`
(the D compiler, for llasm).

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

## Running

```sh
cd build/tests
BL_WINDOW=1 ./boot "/path/to/Bloodlines"
```

Without a command line, the game starts in a window with `-game Unofficial_Patch`
when that folder exists. Saves and `config.cfg` live in
`~/Library/Application Support/Vampire The Masquerade - Bloodlines/`.

Options (environment variables):

| Variable | Effect |
| --- | --- |
| `BL_WINDOW=1` | open a window (otherwise headless) |
| `BL_FULLSCREEN=0/1` | start in a window or full screen; Cmd+Ctrl+F toggles |
| `BL_ANISO=n` | anisotropic filtering, default 16, 1 = off |
| `BL_FPS_MAX=n` | frame cap, default 60 (the game's physics expect it) |
| `BL_SHADER_EARLY=0` | compile shaders only when a draw first needs them; by default they compile in the background when the game creates them |
| `BL_DEEP_COLOR=0` | 8-bit back buffer and window; by default the back buffer is 16-bit and the window 10-bit |
| `BL_PACING=0` | plain presents; by default each frame is held for whole refreshes when the screen rate is a multiple of the cap (120 Hz ProMotion) |
| `BL_PACING_STATS=1` | log how many refreshes apart frames reach the screen |
| `BL_RAW_MOUSE=0` | use macOS's accelerated pointer for mouse look |
| `BL_PAD_LOOK=n` | controller look speed, default 1400 |
| `BL_DATA_DIR=dir` | where saves and settings go (`off` = the game folder) |

Controllers (Xbox, PlayStation, MFi) are mapped to the default key bindings; the
layout is at the top of `runtime/bl_gamecontroller.m`. Debugging switches are
listed at the top of `runtime/d3d9/metal_render.m`.

## Legal

Vampire: The Masquerade – Bloodlines is © Activision; World of Darkness is © Paradox
Interactive. This project is not affiliated with either and distributes none of
their code or data.
