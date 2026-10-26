# Bloodlines → Apple silicon (static recompilation) — porting log

## 2026-10-22 — Milestone 1: Identify (survey only)

Install: GOG 1.2 with Unofficial Patch (Werner Spahl). macOS 27.2, arm64, Xcode beta.

### Verified
- 27 PE32 (i386, MSVC) modules, ~11.7 MB of x86 code in total. Largest:
  `Vampire/dlls/vampire.dll` 4.3 MB, `cl_dlls/client.dll` 1.9 MB, `engine.dll` 1.5 MB,
  `vphysics.dll` 0.8 MB, `vampire_python21.dll` 0.45 MB, `StudioRender.dll` 0.4 MB.
- Every module checked has a `.reloc` section and no TLS directory. Many share image
  base 0x10000000, so each module needs its own fixed base inside the 32-bit guest window.
- `vampire.exe.12` has `stxt774`/`stxt371` sections (SecuROM remnant, no relocs): exclude.
  The GOG `Vampire.exe` (73 KB, sha256 prefix 15aff1c342de1df5) is clean.
- Modules are loaded at run time by name (`LoadLibrary` + `CreateInterface`):
  engine loads `cl_dlls\client.dll`, `cl_dlls\GameUI.dll`, `VPHYSICS.DLL`,
  `StudioRender.dll`, `materialsystem.dll`, `vaudio_miles.dll`, `dsound.dll`, game dll.
  The runtime needs a multi-module loader mapping these names to recompiled images.
- Graphics: only `d3d9.dll!Direct3DCreate9` is imported; everything else goes through
  COM vtables in `shaderapidx9.dll`. Shader paths: `stdshader_dx6/dx7` (fixed function)
  and `stdshader_dx8/dx9` (D3D9 shader bytecode, SM1.x–2.0). Metal shader converter
  takes DXIL only, so SM1–2 bytecode needs its own MSL translator.
- Other APIs: dinput8, winmm, wsock32/ws2_32, Miles (`Mss32.dll`, recompilable),
  Bink 1 (`binkw32.dll`), embedded Python 2.1 (`vampire_python21.dll`, imports 151 msvcrt fns).
- About 600 distinct Win32/CRT imports across all modules (kernel32 185, msvcrt 152,
  user32 98, winmm 45, gdi32 35, ...).
- Toolchain present: clang, cmake, ninja, python3. Missing: SR/SRW/llasm, LDC, Homebrew llvm + lld.

### Not verified
- Function/jump-table/vtable recovery coverage (no recompiler built yet).
- SSE/MMX/3DNow! usage per module (string hits only, e.g. vampire.dll mentions MMX/SSE).

### Proposed milestone order
0. Toolchain: build SR/SRW + llasm (LDC), Homebrew llvm + lld.
1. Pilot: recompile `zlib1.dll`, call its exports natively, compare output with system zlib.
2. Core modules (tier0, vstdlib, FileSystem_Stdio, launcher/loader) + multi-module loader;
   run to engine init headless.
3. All modules translated; imports implemented until the main menu loop runs on a null renderer.
4. D3D9 → Metal: dxlevel 70 fixed-function uber shader first, then SM1–2 bytecode → MSL.
5. Input (AppKit/GameController), audio (Miles over Core Audio), Bink video.
6. Package: runtime + converter only; player's own files converted on first launch.

## 2026-10-22 — Milestone 0: toolchain

### Verified
- Homebrew llvm 23.1.2, lld 23.1.2, ldc 1.43.0 were already installed.
- M-HT/SR at commit `ac690ddf3010bc3d2c875cb1b5e8da4f53a8d5b3` copied (without `.git`; the
  sandbox blocks writing `.git` inside the project) to `native/third_party/SR`, unmodified.
- `native/tools/build_tools.sh` builds `SRW` (llasm output mode, switched in a copy of
  `SR_defs.h`) and `llasm` into `native/build/tools/`. macOS needed a `<malloc.h>` shim
  (`native/tools/compat/`).

## 2026-10-22 — Milestone 1 pilot: zlib1.dll

Pipeline (`native/tools/recompile_module.sh <dll> <name>`, about 2 s for zlib1):
1. `fix_region_flags.py` runs SRW repeatedly. When SRW stops on flags that are live across
   a region start (MSVC reuses flags after a jump), it adds an `instruction_flags.sci`
   pair. When the producer `cmp` is fused with its own jcc, it replaces the region-start
   jcc with an llasm re-compare and seeds the jump target through `global_aliases.sci`.
2. `seed_code_pointers.py` finds code that SRW emitted as data (function pointers stored
   by immediate, e.g. zlib's `zcalloc`/`zcfree`) and adds it to
   `fixup_interpret_as_code.sci`. Steps 1–2 repeat until no new seeds appear (2 passes).
3. `gen_extern.py` renames imports to `imp_<name>` (avoids clashing with libc) and declares
   imports referenced only by address.
4. llasm `-m64 -ptrofs` → `opt -O2` / `llc -O2` for arm64-apple-macos14 → `build/zlib1/zlib1.o`.

Runtime (`native/runtime`, built by `native/tools/build_runtime.sh`): 4 GiB guest window
around the executable, guest heap (power-of-two free lists), guest CPU/stack, cdecl call
helper, fault reporter, SR's x86 helper C files, import thunks generated from
`runtime/imports.def` (malloc, free, _errno implemented; 15 others trap with their name).

### Verified
- `native/build/tests/zlib_pilot` (source `native/tests/zlib_pilot.c`), run headless:
  **81/81 checks passed** against macOS zlib 1.2.12 loaded with dlopen:
  zlibVersion = "1.2.1"; adler32 and crc32 on 7 buffer sizes; compress2 at levels 0–9 on
  text and random data, decompressed by macOS; macOS-compressed data decompressed by the
  guest; streaming inflate in 1000-byte input / 777-byte output slices, split mid-stream
  with inflateCopy, both streams finished and compared. Guest compressed bytes matched
  macOS zlib output in 18 of 20 cases (version differences are expected).
- Fixes needed for zlib1: 2 flag pairs (0x1000496a, 0x1000635e), 2 re-compares
  (0x10007408, 0x100076e4), 3 code seeds (0x10006d20, 0x10009140, 0x10009160).

### Not verified
- inflateBack (contains the 0x1000496a fix) and the gz* file functions were not called;
  their file imports trap. Whether the test hit the two re-compare branches was not traced.
- DllMain was not run (`_initterm`, `DisableThreadLibraryCalls` trap). There is no
  native→guest callback mechanism (`guest_invoke`) yet.
- Guest heap and CPU state are single-threaded.

### Known issues before multi-module work
- Translated procedures and exports are global symbols (`_adler32`, `_c_adler32`). Every
  Source DLL exports `CreateInterface`, so modules need per-module symbol prefixes.
- Imports are keyed by name only; per-DLL prefixes are needed once two DLLs export the
  same name.
- The heap gap after the executable is limited by the dyld shared cache at 0x180000000;
  the 1 GiB request currently fits, but the full game will need a planned layout.

## 2026-10-22 — Milestone 2: tier0, vstdlib, FileSystem_Stdio and a multi-module loader

Supported files are now pinned: `native/modules/hashes.txt` holds the SHA-256 of
zlib1, tier0, vstdlib and FileSystem_Stdio (GOG release; the copies in `Bin/` are
identical), and `recompile_module.sh` refuses anything else.

### What changed
- **Symbol names** (`tools/gen_extern.py`): every export becomes `<module>_<enc(name)>`
  (C entry `c_<module>_...`), where `enc` is injective and maps MSVC C++ names to
  identifiers (`_`→`__`, `?`→`_q`, `@`→`_a`, `$`→`_d`, others `_xHH`). Imports from a
  recompiled module (listed in `modules/modules.txt`) resolve at link time to the
  exporter's symbol; imports from system DLLs become `imp_<enc(name)>`. Each module also
  gets a generated `<module>_exports.c` that registers its export table and DllMain with
  the runtime loader. Generated files stay in `native/build/`.
- **Native → guest calls**: `bl_call_guest(cpu, guest_addr, cdecl|stdcall|thiscall, ...)`
  through a one-line llasm thunk (`runtime/llasm/invoke.llasm`). Each module's entry point
  is aliased as `<module>_DllEntry`.
- **SRW gaps handled by `tools/fix_region_flags.py`**, each replaced with llasm or a call
  into `runtime/bl_special.c`:
  - 80-bit `fld/fstp tbyte` (x87 stack holds doubles; values are rounded on load);
  - x87 instructions SRW lacks: fldl2e, fldl2t, fldpi, f2xm1, fscale, frndint, fxtract,
    fprem, fprem1, fpatan, fxam, ftst, fincstp, fdecstp;
  - `cpuid` (reports a Pentium 4 with FPU/TSC/CX8/CMOV and no MMX/SSE, so the game keeps
    to x87 paths) and `rdtsc` (1 GHz counter);
  - `jecxz`/`loop` and `bt/bts/btr/btc` on memory (a following CF jcc is folded in);
  - replaced instructions that fall through into a new region now close their procedure,
    and `daddr` of an exported proc uses its alias name.
- **Win32 layer** (`runtime/bl_kernel32.c`, `bl_thread.c`, `bl_loader.c`, `bl_format.c`,
  `bl_user32.c`): all 133 imports of the three DLLs. Files map `C:\VTMB\...` to the game
  directory; heap, VirtualAlloc, TLS, time, code pages (1252 as Latin-1), environment,
  module loader (LoadLibrary/GetProcAddress/GetModuleHandle over the registry), FS
  segment → per-thread TIB, real guest threads (own CPU, stack and TIB) with
  pthread-backed critical sections, events and atomic Interlocked calls. The guest heap
  and handle table are now locked. user32, advapi32 and ws2_32 are headless stubs:
  no windows, empty registry, socket send/recv trap.
- MSVC printf with guest varargs (`bl_format`) for `_vsnprintf`, `sprintf`, `wvsprintfA`.

Per-module fixes (from `build/<module>/srw-fix.log`):

| module | flag pairs | re-compares | instruction replacements | code seeds | CRT signatures |
|---|---|---|---|---|---|
| tier0 | 22 | 15 | 12 rdtsc, cpuid, fclex, jecxz | 24 | memcpy ×2 |
| vstdlib | 14 | 146 | 35 fld tbyte, 102 fstp tbyte, 3 ftst, f2xm1, fldl2e, frndint, fscale, fclex, jecxz | 8 | sqrt, log, memcpy ×2 |
| FileSystem_Stdio | 24 | 4 | bt, bts, fclex, jecxz | 23 | memcpy ×2 |

### Verified
- All three modules plus the runtime link into one arm64 executable with no
  unresolved symbols; cross-module imports (vstdlib→tier0, FileSystem_Stdio→tier0 and
  vstdlib) resolve to the translated exports.
- `native/build/tests/fs_smoke <game dir>` (source `native/tests/fs_smoke.c`), headless:
  tier0, vstdlib and FileSystem_Stdio DllMains succeed (static CRT start-up, `_initterm`
  constructors, FileSystem_Stdio's worker thread created suspended and resumed);
  `CreateInterface("VFileSystem005")` returns the filesystem; `AddSearchPath("C:\VTMB\Vampire",
  "GAME")`, then `Open`/`Size`/`Read`/`Close` return files byte-identical to the native read:
  `resource/trackerscheme.res` (58,639 bytes), `python/vamputil.py` (26,295),
  `resource/gameui_english.txt` (18,238). 7/7 checks each; 5 repeated runs passed.
- zlib pilot still passes under the new naming, now also running zlib1's DllMain:
  **82/82**.
- Unsupported files are refused (tested with vgui2.dll passed as tier0).

### Not verified
- Reading from `.vpk` packs: only loose files were read. The vtable slots used by the test
  (0 Open, 1 Close, 2 Read, 6 Size, 11 AddSearchPath) were identified from the module's
  own error strings and argument counts, not from headers; other slots are unnamed.
- 80-bit x87 precision is reduced to double in the vstdlib CRT's float formatting; printf
  output of floats was not compared with Windows.
- Thread safety is exercised by only one extra thread (FileSystem_Stdio's worker, which
  idles). `WaitForMultipleObjects`, thread exit codes and thread-handle reuse are untested.
- SEH: the TIB chain head is maintained, but `RaiseException`/`RtlUnwind` trap, so any
  guest exception stops the process.
- user32/advapi32 are stubs: tier0's assert dialog cannot show, registry reads find nothing.
- ws2_32 recv/recvfrom/send trap (used only by tier0's remote tooling).

### Next
Milestone 3: the remaining engine DLLs (engine, launcher, vgui2, MaterialSystem,
StudioRender, vphysics, client/server game DLLs, vampire_python21) through the same
pipeline, growing the Win32 layer from their traps, before the D3D9 → Metal work.

## 2026-10-22 — Milestone 3: remaining engine DLLs (in progress)

All 23 modules in `native/modules/modules.txt` are pinned by SHA-256 and go through the
same pipeline. 19 of them compile to arm64 objects: zlib1, tier0, vstdlib,
FileSystem_Stdio, launcher, MaterialSystem, StudioRender, stdshader_dx9, stdshader_dbg,
vgui2, vguimatsurface, vphysics, vaudio_miles, voice_miles, vampire_python21, Mss32,
binkw32, GameUI and msvcrt. msvcrt is the game's own copy, so the other modules use its
recompiled CRT. Still compiling at the time of writing: engine, client, vampire and
shaderapidx9. These four are large and have to be built one at a time to stay within memory.

### What changed
- **SRW patches** (`tools/srw-macos.patch`):
  - `rep cmpsd` calls runtime helpers.
  - `cmovcc r32, r/m32` is translated.
  - `cmp r32, [import]` is accepted (engine compares against PyInt_Type and similar).
  - Disassembly stops at the end of a section.
  - A code section extends past VirtualSize into its raw data, trimmed to the last
    non-zero byte. The Unofficial Patch's GameUI keeps code there.
- **Fixer** (`tools/fix_region_flags.py`):
  - Fused compares on 8- and 16-bit and high-byte operands.
  - 8-bit ALU, shift, rotate, `not`, `xchg` and one-operand `mul`/`imul`, when the flags
    are dead.
  - CRT helpers that return a result in ZF.
  - x87 register arithmetic (D8/DC/DE forms) and fnstenv/fldenv/fnsave/frstor.
  - SIMD: cpuid reports no MMX/SSE, so every SIMD instruction in a function becomes a
    `bl_simd_trap` call. Traps are placed only on instructions SRW is known to reach. A
    replacement on unreachable code made SRW emit it outside any proc (Mss32).
- **CRT signature scan** (`tools/crt_sigs.py`): relocations are looked up by bisection.
  The old linear scan took more than 30 minutes on client.dll. Hits on vgui2 and engine
  are unchanged.
- **Symbol names** (`tools/gen_extern.py`):
  - Exports that share an address (`define` aliases) resolve to the real symbol.
    Other modules importing them link through ld64 `-alias_list` files.
  - Stdcall-decorated exports (`_Foo@4`, which is all of Mss32 and binkw32) are also
    renamed under the undecorated name that SRW emits.
  - wsock32 ordinals use SRW's names.
- **Loader**: each module loads its recompiled imports, and runs their DllMains, before
  running its own DllMain.
- **Win32 layer**: 446 imports, 356 implemented, 90 still trap.
  - Headless user32 window manager (`runtime/bl_window.c`): classes, windows and their
    messages, a message queue, focus, cursor and painting stubs. The screen is 1024×768.
  - Wide-character kernel32 calls (`runtime/bl_kernel32w.c`).
  - winmm with no devices, dbghelp, ole32 init, and registry reads that find nothing.
  - gdi32 font handles that draw nothing.
  - Console, file mapping and TerminateThread fail cleanly.
  - Sockets fail after WSAStartup reports no network. DirectInput8Create returns E_FAIL.
- **SEH** (`runtime/bl_seh.c`):
  - RaiseException walks the fs:[0] handler chain.
  - RtlUnwind unwinds and unlinks handlers up to a target frame.
  - Translated code only uses tail calls. When a catch or __except block continues past a
    nested host → guest call, `bl_call_guest` therefore hands control back to the
    invocation whose guest esp matches, using setjmp/longjmp.

### Verified
- zlib pilot 82/82 and fs_smoke 7/7, with zlib1 now linked against the recompiled msvcrt.
- The 19 built modules and the runtime link into `native/build/tests/boot` with no
  unresolved symbols. That includes Mss32 and binkw32.
- The boot test runs headless (`tests/boot.c`: launcher's `LauncherMain` with
  `-window -dev`). The launcher, tier0, vstdlib, FileSystem_Stdio and MaterialSystem
  DllMains and start-up succeed. It stops at the launcher's own "Unable to load
  engine.dll" message box, because engine.dll is not built yet.

### Not verified
- SEH and C++ exceptions: the code builds but no guest exception has gone through it yet.
  A loop that throws continuously would leak a few host stack frames per throw until
  the outer call returns.
- Any code in the 19 modules beyond the start-up paths above.
- SIMD paths are trapped, not translated. They are only taken if cpuid reports SSE.
- No window, rendering, audio, input or networking. Those are stubs until the Metal and
  device milestones.

## 2026-10-23 — Milestone 3: all modules compile; build time cut

### What changed
- **SRW keeps going after a region error** (`tools/srw-macos.patch`, `SR_full.c`). It now
  reports every untranslatable instruction or flag problem in one run (exit codes
  5–7), instead of stopping at the first.
- **The fixer applies one fix per reported error, every run.** Errors at addresses an
  earlier fix in the same run already covers are skipped.
  - SIMD traps also cover the straight-line code before the error. That code is known to
    be decoded too: nothing jumps into it, and it is not an export or seeded code pointer.
  - After a clean SRW run, any trap emitted outside a procedure (on code SRW never
    reached) is dropped and SRW runs again.
- **Code generation runs in parallel.** `llvm-split` cuts the IR into one part per core,
  `opt` and `llc` run on all parts at once, and `ld -r` joins the results.
- **`tools/table_init_pointers.py`** rewrites llasm's `initialize_pointers` as two
  constant tables and a loop. The original was one basic block with up to 236,660
  stores, which made llc run for tens of minutes.

### Build times (whole module, this machine)
| module | before | now |
|---|---|---|
| tier0 | 38 SRW runs | 2 SRW runs, 13 s |
| MaterialSystem | ~480 SRW runs | 4 runs, 18 s |
| engine | not finished | 2 min 40 s |
| shaderapidx9 | hit the 5,000-iteration limit | 14 s |
| client | more than 20 min, unfinished | 87 s |
| vampire | not finished | 7 min |

Outputs are unchanged where they can be compared: tier0 still has 22 flag pairs and 15
re-compares, and MaterialSystem still has 14 flag pairs and 466 re-compares.

### Verified
- All 23 modules plus the runtime link into `build/tests/boot` with no unresolved symbols.
- The boot test, headless, gets through the launcher and engine.dll load and
  initialisation to shader-system start-up. It stops in shaderapidx9 at the first
  Direct3D call, `d3d9!Direct3DCreate9`, about 1 s after start.

### Not verified
- zlib 82/82 and fs_smoke were not rerun after the codegen split.
- Nothing has rendered yet. The next milestone is D3D9 on Metal.

## 2026-10-23 — Milestones 5–6: frame loop reached; D3D9 on Metal draws the main menu

### Runtime imports added to reach the frame loop
- **DirectInput 8** (`runtime/d3d9/dinput8.c`, COM interfaces in `com.def`): system
  keyboard and mouse with immediate and buffered data. The old stub returned E_FAIL,
  which made `CreateGameWindow` fail and the engine quit silently after the splash.
- **Anonymous pipes** (`CreatePipe`, `PeekNamedPipe`, `DuplicateHandle`): Troika's Python
  sends its stdout through one.
- **`GetProfileStringA`** returns the caller's default.

### Renderer
- `runtime/d3d9/d3d9_shader.c` translates D3D9 shader bytecode (vs_1_1 to vs_2_x,
  ps_1_1 to ps_2_x) to MSL. All 898 shaders the game creates up to the menu translate
  and compile (`tests/shader_test.m` on the dumped set).
- `runtime/d3d9/metal_render.m` replaces the null renderer. It covers textures
  (including DXT), vertex declarations and FVF, pipeline, depth and sampler state
  caches, clears, draws, StretchRect and frame dumps to PNG (`BL_DUMP_FRAME`).
- `runtime/bl_cocoa.m` provides an NSWindow with a CAMetalLayer and the event pump.
  It is used only with `BL_WINDOW=1`.

### Bugs fixed
- **The CPU state was outside the guest window.** SR's `x87_fstp_double` returns `&ST0`
  as a 32-bit guest pointer. The `_cpu` struct came from `calloc`, so when ASLR put it
  above the window the pointer was truncated. That caused random faults, for example
  in tier0's CRT FDIV check. `bl_cpu_new` now allocates it from the guest heap.
- **Guest stacks now have a guard.** The main thread's stack is the first heap block,
  directly above the executable's `__DATA`. An overflow wrote into translated data for
  64 MB before it faulted. Each stack now has a 64 KiB PROT_NONE guard, and the crash
  report says "guest stack overflow".
- **Data past the import directory, and section slack.** The Unofficial Patch keeps
  engine.dll's resolution whitelist at 0x20195dd0, which is past `.rdata`'s VirtualSize
  and after the import directory. SRW stops a section's data at the import directory
  and mistranslated the reference as `loc_20001000`. The engine therefore rejected
  every display mode, set its screen size to garbage (2x177), and the menu's particle
  view got a 3x177 viewport. Two new pipeline steps fix this:
  - `tools/widen_sections.py` widens VirtualSize to SizeOfRawData in the analysis copy,
    as the Windows loader maps it.
  - `tools/append_section_tail.py` appends the missing bytes, with labels and
    relocated pointers.
  The engine now picks 800x600 and the menu renders.

### Tooling
- `CODEGEN_ONLY=1 recompile_module.sh` redoes only opt and llc, in about 10 s for
  engine. A full engine run, including SRW, takes about 2 min.
- Translated procs are `internal` rather than `private`, so `loc_<VA>` symbols survive
  for traces.
- The crash report adds the offset from the load address, the guest heap range, the
  thread's stack and esp, and host and guest backtraces.
- `BL_IMPORT_TRACE`, `BL_BACKTRACE_AT=dll!name`, `BL_COM_BT=Iface::Method`,
  `BL_VIEWPORT_WATCH`, `BL_D3D_TRACE`, `BL_DRAW_STATS` and `BL_DRAW_DUMP` are
  available for debugging.
- `recompile_module.sh` now makes the DLL path absolute. A relative path used to delete
  the module's outputs and then fail at the copy.

### Verified
- Headless: the main menu (logo, background and the New Game, Load Game, Options and
  Quit buttons) renders at 800x600 in the frame-300 PNG dump.
- 6 of 6 runs of 600 frames and 10 of 10 runs of 300 frames exit cleanly. Before the
  fixes, about 1 run in 3 crashed.

### Not verified
- Only engine.dll was re-translated with the new section steps. Other Unofficial
  Patch modules may reference slack data too; they need a full re-run.
- Fixed-function draws are skipped (one draw on the menu).
- The window path (`BL_WINDOW=1`), input, audio, video and in-game rendering have not
  been run.
- SEH, zlib and fs_smoke have not been rerun since these changes.

## 2026-10-23 — Window run; New Game reaches character creation

### Verified
- `BL_WINDOW=1` opens a Cocoa window. The menu is clickable and New Game loads
  `sp_genesisdevice_1`.
- Headless, `+map sp_genesisdevice_1` runs 1500 frames without a crash. The frame-1400
  dump shows the character-creation screen, with text drawn by the new GDI code.

### Fixed
- **Guest heap.** It now takes every free range of 64 MiB or more in the 4 GiB window
  (1.6 GB in 4 to 7 ranges; it was a single 512 MiB to 1 GiB block). Size classes step
  in quarters between powers of two, so at most 25% is wasted; before, sizes doubled.
  Map load uses about 700 to 850 MiB.
- **SRW code-section data layout** (`tools/srw-layout.patch`). SRW left instruction
  bytes out of a code section's data, so jump tables were packed together and SRW's
  `dalign` moved unaligned ones. Tables indexed relative to a label then read the
  wrong bytes; msvcrt's memmove uses negative indices. Gaps are now filled with the
  original bytes and no `dalign` is emitted in code sections, so every label keeps
  its section offset. Only msvcrt has been re-translated with this so far.
- **msvcrt memcpy and memmove** (`modules/msvcrt/instruction_replacements.manual.sci`).
  Four jump tables whose base address SRW decoded as code are replaced. Two now index
  from the neighbouring labelled table; the other two branch on the index directly.
  This fixed the crash when Python writes to its stdout pipe.
- **CRT ZF auto-fix** (`fix_region_flags.py`). When the caller set edx with
  `lea edx, [esp+N]`, the operand is now read through esp. `_CIacos` enters the same
  tail directly, with edx unset, which crashed StudioRender at map load. Only
  StudioRender has been re-translated; 14 other modules have the old form.
- **gdi32 text** (`runtime/bl_gdi.c`, on Core Text). Adds memory DCs, CreateFontA,
  DIB sections, text metrics, ABC widths, `GetGlyphOutlineA` (GGO_GRAY8_BITMAP) and
  `ExtTextOutA`/`ExtTextOutW`, which is what vguimatsurface's Win32Font uses.

### Not verified
- The other modules have not been re-translated with the layout patch or the ZF fix.
- The game's own fonts (for example "Dominican") are not registered, so they fail
  and the game falls back to others.
- Python reports "SystemError: error return without exception set" once at map load.
- Audio (`dsound.dll`, Miles `.asi`), video and fixed-function draws are missing.

## 2026-10-23 — Every module re-translated with the new pipeline

- New script `tools/rebuild_all.sh <game dir> [module ...]` runs the full pipeline
  (SRW included) per module. It takes each DLL from the file under the game directory
  that matches the pinned SHA-256, and writes logs to `build/logs/<module>.log`.
- `append_section_tail.py` now drops the label SRW puts at the end of a widened
  section when the next segment, code or data, starts with the same label. That
  collision broke tier0 and binkw32.
- All 26 modules were rebuilt with the layout patch, section widening, the tail data
  step and the CRT ZF fix, in about 17 minutes. The longest were vampire at 524 s,
  engine at 182 s and client at 103 s; most others took under 30 s.

### Verified
- After relinking, the menu passes 3 of 3 runs of 600 frames, and
  `+map sp_genesisdevice_1` passes 1500 frames. Character creation renders as before.
- The previous windowed session ran about 9,200 frames and exited without a crash.

### Not verified
- `zlib_pilot` and `fs_smoke` were not relinked or rerun.
- The Python "SystemError: error return without exception set" at map load is still
  there.


## 2026-10-23 — Input fixes and trace

User reported controls not working properly. Changes:
- The cursor is now kept in screen coordinates. The game centres it at 512,384 on the 1024x768 virtual screen, so its window is offset; before, GetCursorPos returned client coordinates and menu clicks landed off by the window offset.
- Mouse capture: when the game hides the cursor (SetCursor(NULL) or a negative ShowCursor count) or holds the DirectInput mouse exclusively, the window hides the pointer, freezes it, and moves the virtual cursor by relative motion only. The game's SetCursorPos recentring then yields real deltas. Before, nothing ever captured the mouse and absolute positions broke mouse look.
- WM_MOUSEMOVE is coalesced and the message queue is 1024 entries, so fast mouse motion no longer drops key messages.
- GetKeyState returns real key state (it always returned 0); vgui2 and tier0 use it.
- Sub-pixel mouse deltas are accumulated instead of truncated.
- `BL_INPUT_TRACE=1` logs DirectInput setup and acquisition, cursor calls, key events and dropped events.

Verified: the build is clean, the game boots to the menu with the Metal HUD, and key and mouse events reach the trace. The menu does not create DirectInput devices; it uses window messages. Not verified: in-game mouse look and movement, and whether menu clicks now line up.

## 2026-10-23 — Map-load messages, scaled StretchRect

- The Python `SystemError: error return without exception set` at map load is the original game's behaviour, not a translation fault. The game evaluates `__main__.ccmd.createplayer` (traced with lldb breakpoints on `PyRun_String`). The engine's `ccmd` type has its getattr at 0x200da640, which queues the console command and returns NULL without setting an exception, so Python 2.1 raises SystemError after the command has been queued. The `NameError: sp_genesisdevice_1_patch` comes from the Unofficial Patch calling a per-map hook that this map does not define.
- The "Couldn't create bitmap font" warnings are for faces with no prebuilt `materials/fonts/*.fnt` in the VPKs. vguimatsurface falls back to GDI fonts, which the Core Text path renders. This matches Windows behaviour.
- StretchRect with differing source and destination sizes now draws the source rectangle into the destination viewport with a sampling pass: linear filtering unless D3DTEXF_POINT, and a temporary copy when the source and destination are the same texture. It used to copy only the overlap.
- Fixed-function draws: one draw with no shaders and FVF 0 in a 1500-frame map run, so none worth implementing yet. The log now counts them.

Verified: headless `+map sp_genesisdevice_1` for 1500 frames, exit 0, no scaled-StretchRect warning; frame 1400 shows the character-creation screen rendered correctly. Not verified: in-world scenes that use the scaled copy (bloom, refraction).

## 2026-10-23 — Audio: DirectSound on Core Audio, MMX emulation, Miles MP3 provider

- `runtime/d3d9/dsound.c`: DirectSound as a module registered under the name `dsound.dll`, so the engine's and Miles' `LoadLibrary("dsound.dll")` calls find it. Its exports are import thunks (`DirectSoundCreate`, `DirectSoundEnumerateA`, and `DirectSoundCaptureCreate`, which fails because there is no voice chat). All buffers are software; one mixer resamples every playing buffer (linear interpolation, DirectSound volume and pan) to 44.1 kHz float stereo. With `BL_WINDOW` or `BL_AUDIO=1` the mix goes to the default output through an AudioUnit; otherwise a thread mixes into nothing at the same rate, so play cursors still advance in headless runs. `BL_AUDIO_TRACE=1` logs buffer setup and the peak level of each second.
- The engine (CAudioDirectSound) uses one primary buffer (set to 44.1 kHz 16-bit stereo) and one 64 KB secondary buffer it streams into.
- Once sound initialised, vaudio_miles crashed calling an MP3 decoder function through a garbage pointer: Miles gets the decoder from the `mssmp3.asi` provider, which was not translated. `mssmp3` is now a recompiled module (hash pinned; `rebuild_all.sh` also finds `.asi` files; the loader treats `name.asi` like `name.dll`). `mssvoice.asi` (voice-chat codec) fails in SRW ("output not found") and is left out.
- The engine's sound mixer (Mix16Mono variants at 0x201369f0 to 0x20136e97) uses MMX without checking cpuid. `fix_region_flags.py` now emits each MMX instruction of such functions as a call to `bl_mmx` (`runtime/bl_special.c`), an interpreter for the integer MMX set with per-thread registers, instead of `bl_simd_trap`. 68 instructions in the engine. cpuid-gated SSE/3DNow code still traps.

Verified: headless menu and `+map` runs exit 0; at the menu the mixer outputs a non-silent signal (peak about 0.06 to 0.09) from the engine's secondary buffer; the window run opens the AudioUnit. Not verified: whether it sounds right (user listening test), Miles-played streams (dialogue, music through vaudio_miles), and Bink video audio.

Also seen: the previous windowed session aborted on a Metal pixel-shader compile failure. The terminal showed the generated MSL but the log was overwritten by the next run, so the failing shader is not known yet.

## 2026-10-23 — Shader compile crash

- Cause: the ps_1_x co-issue temporaries were numbered per co-issued pair (`_co0`, `_co1`), so a shader with two co-issued pairs declared `_co0` twice and Metal rejected it ("redefinition of '_co0'"). Both windowed crashes were this; the second window log confirms it. Temporaries are now numbered across the whole shader.
- Test coverage: `vpk_shaders.py` and `vcs_split.py` (session scratch, not in the repo because they write game data) extracted every combo from the game's `shaders/*.vcs` in the VPKs: 4520 distinct shaders. `tests/shader_test.m` now compiles each one in five variants (default, cube/uint, volume/sint, projected 3 and 4) with the renderer's compile options. Before the fix 30 of 22600 failed, all with this error; after the fix 0 fail.
- A shader that fails to translate or compile no longer ends the game: it is logged once with its MSL, and its draws are skipped. The same applies to pipeline creation.
- Window runs now log to `build/analysis/window-<time>.log`, so a crash log survives the next launch.

Verified: shader_test 22600 compiled, 0 failed; headless `+map` for 1500 frames, exit 0. Not verified: the scene that triggered it, in the window.

## 2026-10-23 — Fixed-function stages

- Draws without a pixel shader now get one generated from the texture stage states (`d3d_ff_ps_msl`): the COLOROP/ALPHAOP cascade with its arguments (diffuse, current, texture, TFACTOR, specular, temp; complement and alpha-replicate), RESULTARG, TEXCOORDINDEX, projected coordinates, SPECULARENABLE, then the same alpha test and fog as translated shaders. Ops 2–16, 18–21 and 24–26 are supported; others are logged and the draw skipped. Shaders are cached per stage-state key. `BL_FF_TRACE=1` prints each new key.
- Draws without a vertex shader get one from the declaration (`d3d_ff_vs_msl`): untransformed positions use WORLD·VIEW·PROJECTION, POSITIONT uses the viewport and RHW; diffuse and specular pass through (white and black when absent). There is no fixed-function lighting, fog or texture transform yet.
- Vertex shaders that never write oD0 now output white diffuse instead of black, which is what wined3d does for vs_1/vs_2.
- `BL_FF_HIGHLIGHT=1` paints fixed-function pixel output magenta (alpha kept) to find these draws.

What the draws are in `sp_theatre`: two world-space draws without shaders per frame (an 8-triangle sky/cloud quad with a 256x256 texture, and a 4-triangle DXT5 sprite), both alpha-blended and faint. Then about 22 per frame with a vertex shader and no pixel shader, which render character silhouettes into 256x256 tiles of a 1024x1024 shadow texture.

The shadow texture stays black, so no character shadows show. The shadow vertex shader computes its colour as `dot(c42.xyz, worldpos) * c43 + c44`. The game sets c43 = -0.0083 and c44 = -17.6, so the result saturates to 0. Painting the shadow pass magenta makes green shadows appear under the NPC, which shows the receiving side works. Whether those constants are wrong because of a translation fault in the engine's math is not known; it may share a cause with the NPC rendering black.

Verified: headless `+map sp_theatre` for 1200 frames, exit 0, no skipped draws; frame 1150 dumped with and without highlight. Not verified: lit fixed-function geometry (none seen), menus or other maps in the window.

## 2026-10-23 — x87 store translation bug (black models)

**Cause.** NPCs rendered almost black because the model ambient cube (vertex constants c21–c26) held denormals such as 1.08e-42. Those values looked like integers (772, 726, 463) but were tiny floats. The chain behind it:
- StudioRender passes the engine's six colours through unchanged.
- The engine computes them in `0x200AB5B0` by tracing 162 rays and sampling the lightmap at each hit (`0x20077C70`).
- Each sample is `byte * power2_n[exponent] * lightstyle`.
- The `power2_n` table (0x20FFA480, 256 floats, meant to be 2^(i-128)/255) held 4, 8, … 1024 as raw integers.

**Translator bug.** SRW translated `fstp dword [esi*4+table]` as `FSTP_FLOAT` (value in tmp0), then computed the scaled index with `shl tmp0, esi, 2`, then stored tmp0. So every x87 store to a `[base + index*scale]` address wrote index*scale instead of the value. The 64-bit variants already copied tmp0 to tmp1/tmp2 first.

**Fix.** `tools/srw-x87-store.patch` (applied by `build_tools.sh`) makes FST/FSTP m32, FIST/FISTP m32/m16 and FNSTSW/FNSTCW m16 move the value to tmp1 before the address calculation. A scan of the old llasm found 95 affected stores, all `fst`/`fstp` with a scaled index:

| Module | Affected stores |
|---|---|
| client | 13 |
| vampire | 13 |
| mssmp3 | 11 |
| MaterialSystem | 9 |
| engine | 6 |
| StudioRender | 6 |
| shaderapidx9 | 6 |
| vphysics | 6 |
| stdshader_* | 5 each |

In the engine they are the mathlib tables: `power2_n`, the gamma and linear-to-texture tables at 0x20FF9760–0x20FFA890, and one at 0x20D5E47C.

**Rebuilt:** engine, StudioRender, MaterialSystem, shaderapidx9, stdshader_dbg/dx6/dx7/dx8/dx9 (about 4 min in total). **Not rebuilt yet:** client, vampire, vphysics and mssmp3, which still carry the bug.

**Result** at frame 1150 of `sp_theatre`:
- The table now reads 2^(i-128)/255.
- The ambient cube on the NPC's draw is about 0.01–0.02 linear, and the NPC shows shading instead of a black silhouette (head about 15/255 instead of 8).
- The sky glow appears.
- That brightness matches a hand calculation from the shader and its constants (two point lights with 1/d² falloff plus the ambient, gamma 1/2.2, overbright x2). The map's lighting lump really is dark (median luxel about 0.009 linear).
- The game's gamma ramp is identity, so not applying it at present changes nothing.
- The shadow-pass colour constants changed too (c43/c44 now about -0.002/-4.6). Shadows are still faint or invisible.

Verified: headless `+map sp_theatre` for 1151 frames, exit 0; frame dump compared before and after. Not verified: whether NPC brightness now matches the original game (no reference capture), shadows, and the modules not yet rebuilt.

Follow-up, same day: rebuilt the last four modules with the patched SRW:

| Module | Rebuild time |
|---|---|
| mssmp3 | 4 s |
| vphysics | 36 s |
| client | 108 s |
| vampire | 537 s |
| Total | 11.5 min |

The scan now finds no x87 store with a scaled index writing tmp0 in any module. Headless `+map sp_theatre` for 1500 frames exits 0 with no traps or Metal errors. Frame 1150 looks the same as after the first rebuild: NPC head about 15/255. Frame 1500 now has 98 draws where it had 45. The game DLL's table fixes probably changed what happens later in the scene; this is not yet checked.

## 2026-10-23 — x87 condition codes cleared by fst (white lightmaps, faint shadows)

**Symptom.** Character shadows were missing and NPCs looked much darker than the street around them.

**What the shadow path showed.**
- The shadow atlas (1024x1024 render target) holds correct caster silhouettes with the bottom/top gradient.
- The receiver decals land in the right place and sample that atlas, which `BL_SHADOW_SHOW=1` confirmed.
- The darkening was only 1–2/255, because the shadow colours come from the same per-light intensities as model lighting. Those intensities were low, so the shadows were too.

**Real cause.** Every lightmap page was solid 255 (`BL_TEX_STATS`; `BL_LOCK_TRAP` showed every lightmap update writing 255). So the world was effectively fullbright, while models and shadows got the real, dim light.

MaterialSystem builds its linear-to-lightmap table (0x10050D68) like this:

```
fcom  dword [1.0]
fst   dword [esi*4+table]
fnstsw ax
test  ah, 0x41
jnz   keep
mov   dword [esi*4+table], 1.0     ; clamp
```

SR's `x87_fst_float` (and fst_double, fst_st, fxch, fchs, fabs, the arithmetic helpers and fldcw) ran `CLEAR_X87_FLAGS`, which zeroed C0–C3. The `fnstsw` then read "greater" for every entry, so the whole table clamped to 1.0. Real x87 hardware leaves the condition codes alone across these instructions, and MSVC relies on that.

**Fix.** `tools/sr-x87-flags.patch` makes `CLEAR_X87_FLAGS` a no-op. `tools/build_runtime.sh` now copies SR's helper sources to `build/runtime/sr-src` and patches them before compiling. The helpers live in the runtime, so no game module needed recompiling (runtime and link: under a minute).

**Result** (headless `+map sp_theatre`):
- Lightmaps now vary. The scene has the proper night look: lit windows, street lamps, dark sky.
- The player now starts facing another way, and the draw count at frame 1100 is 126. The fixed comparisons change game logic too, since this pattern is everywhere MSVC compares floats.
- No NPC is in view from the new start position, so the shadow and NPC lighting were **not** re-checked on screen after this fix. They need a look in the window.
- 1800 frames, exit 0, no traps.

New debug switches in `metal_render.m`:
- `frame_<n>_rt.png`: a dump of the last offscreen target.
- `BL_TEX_STATS`: per-texture brightness.
- `BL_SHADOW_SHOW`: draws receivers opaque.

`BL_LOCK_TRAP=<w>x<h>[:fmt]` in `d3d9_resources.c` logs the mean of each locked rect on unlock and calls `bl_debug_lock` for a debugger.

## 2026-10-23 — "Not Responding" and CPU use with a window

**Not Responding.** AppKit events were drained only in `PeekMessage`, `GetMessage` and `MsgWaitForMultipleObjects`. During long stretches without those calls (map loads in particular), macOS marked the window "Not Responding". `bl_cocoa_pump_if_idle()` now also drains events from `QueryPerformanceCounter`, `GetTickCount` and `timeGetTime`. It runs on the main thread only, at most every 100 ms. Events are still only queued as window messages, and the game reads them as before. Not verified: watching a full map load in the window without the macOS flag appearing.

**CPU.** The game's main loop never sleeps. A 5 s `sample` of headless `sp_theatre` showed the main thread busy 100% of the time, with x87 helper calls making up about 18% of its samples. With a window, Present followed the display (120 Hz here).

Changes:
- `BL_FPS_MAX` (default 60, 0 = no cap) now caps Present when there is a window.
- The per-draw `getenv` debug checks are now read once. They were about 2.5% of samples.

Measured with a window on `sp_theatre`, 5 s after frame 700:

| Cap | Frame rate | CPU |
|---|---|---|
| None | 120 fps | ~61% of a core |
| 60 fps | 60 fps | ~43% of a core |

Busy gameplay, where scene and AI logic take 16–50 ms a frame, stays CPU-bound at 100% of one core. There the cap does nothing. The remaining cost is translated code speed, mainly every x87 instruction being an out-of-line helper call. Inlining those helpers would need every module rebuilt.

## 2026-10-23 — Inlining the x87 helpers (tried, slower, kept off)

**Build.**
- `build_runtime.sh` now also compiles SR's patched `llasm_float.c` to bitcode (`build/runtime/sr_inline.bc`).
- That copy goes through `tools/sr_inline_prep.py` first. It changes the `float_int` union parameters to `uint32_t`: clang passes a 4-byte union as i64, and LLVM will not inline a call whose type differs from the callee's.
- With `SR_INLINE=1`, `recompile_module.sh` runs `llvm-link --only-needed --internalize` on each split part with that bitcode before opt, so the helpers become internal and inlinable.
- Signatures checked against all 89 helpers the modules declare. Only `x87_fistp_int16`, which is defined elsewhere, stays a call.

**Rebuild cost.** `CODEGEN_ONLY=1 sh tools/rebuild_all.sh .. <modules>` redoes only llvm-link/opt/llc from the existing `.ll` files. All 27 modules take 70 s, against about 15 min with SRW.

**Measured** on headless `sp_theatre`, frames 500–1500, uncapped. Both builds use the same runtime and are run alternately, twice each:

| Build | Frames 500–1500 |
|---|---|
| Helpers as calls | 230–232 fps |
| Helpers inlined | 217–218 fps |

Inlined is about 6% slower. With inlining, no module references `_x87_*` any more, so inlining worked. Calls are cheap on arm64; the cost is in the helper bodies. The x87 stack is kept in the `_cpu` struct, and opt cannot hold it in registers across stores to guest memory. The inlined code is just larger. Inlining stays off by default, and the current build uses calls.

Making floating point faster would need a different translation: keeping the x87 stack in registers within a proc, or alias information that separates `_cpu` from guest memory. Not attempted.

## 2026-10-23 — Launching with -game Unofficial_Patch

GOG's shortcut starts the game with `-game Unofficial_Patch` (no `-dev`). With our
default `-window -dev` and the patch active, loading appeared to hang.

- **Cause.** `-dev` sends every developer message to GameUI's console. The patch
  precaches the player models for every clan, which prints thousands of "chained
  model ... has a bone ... isn't in chaining model" warnings. GameUI's statically
  linked vgui RichText appends text one character at a time (InsertString at
  0x10029D10 calls InsertChar through vtable +0x1E0), and each character re-runs a
  line-break search over all lines (0x10029250). The console is therefore O(n²) in
  its text. The original game behaves the same way under `-dev`; our slower code
  makes it look like a hang. Not changed in the game code.
- **Without -dev** the load gets past that point and stops at
  `gdi32!SetStretchBltMode`. binkw32 draws the intro movies with GDI when it has no
  DirectDraw surface (`-dev` skips the intros, so this was never reached before).
- **Fix.** `SetStretchBltMode` stores the mode in the DC. `StretchBlt` and `BitBlt`
  from a memory DC holding a 32-bit DIB section to a window DC now go through
  `d3d_render_present_pixels` (metal_render.m). It scales the frame into a persistent
  black window-sized image and presents it. Other DC pairs are not drawn, and are
  logged once. The first version was a stub, and the window stayed blank for the
  length of the intro movies.
- **Default command line.** `tests/boot.c` now defaults to `-window`, adding
  `-game Unofficial_Patch` when that folder exists.

Verified headless:
- `-game Unofficial_Patch -window +map sp_theatre` runs 1500 frames with no traps;
  frame 1500 shows the street outside the theatre with the patch's HUD.
- The default command line reaches the main menu by frame 800.

Not verified:
- (Since verified by the user in the window: the intro movies show, and the game
  runs well and stays stable.)
- Play beyond the first map.
- `-dev` with the patch is still slow.

The "_stat on file ...\sound\ which appeared to exist failed" and "Unable to remove
...\SAVE\*.HL1" debug lines are probably benign. MSVC's `_stat` also rejects a
directory path with a trailing backslash, and the save files do not exist yet. Not
checked against Windows.

## 2026-10-23 — Modernising: filtering, input, full screen, save location

- **Anisotropic filtering.** Filtered, mipmapped samplers now get 16x anisotropy
  (`BL_ANISO`, 1 turns it off). The game itself asks for trilinear at most.
  Verified: headless frame 1500 of sp_theatre shows the road and pavement textures
  noticeably sharper at a distance than the earlier dump.
- **Raw mouse** (`bl_gamecontroller.m`). While the mouse is captured, GCMouse deltas
  (unaccelerated) drive DirectInput and the game's cursor instead of AppKit's
  accelerated deltas. `BL_RAW_MOUSE=0` turns this off. Not verified yet.
  GameController's y axis is assumed to point up; if look is inverted, that sign is
  the cause.
- **Gamepads** (`bl_gamecontroller.m`). Any extended gamepad is mapped onto the
  default bindings from `Vampire/cfg/config.cfg`; the table is at the top of the
  file. In menus and dialogue, the sticks move the real pointer and A clicks.
  `BL_PAD_LOOK` sets the look speed. Not verified with a controller yet.
- **Full screen.** The window can be resized and goes full screen (green button,
  Cmd+Ctrl+F or Cmd+Return). The game image keeps its aspect ratio with black bars
  (`contentsGravity` resize-aspect), and mouse coordinates are mapped through the
  same rectangle. A game started without `-window` goes full screen when it creates
  its device; `BL_FULLSCREEN=0|1` overrides that. Not verified yet.
- **Saves and settings.** `<mod>\save\...` and `<mod>\cfg\config.cfg` now map to
  `~/Library/Application Support/Vampire The Masquerade - Bloodlines/<mod>/`
  (`BL_DATA_DIR`, `off` keeps them in the game folder). Existing saves and
  config.cfg are copied there on the first start. `nul` paths now open `/dev/null`
  instead of creating a file called `nul`. Verified headless with a temporary
  `BL_DATA_DIR`: both mods' saves and Vampire's config.cfg were copied, the run
  wrote only there, and the game folder's save files were unchanged. A first
  version copied `save` into `save/save`; copyfile copies into an existing folder,
  so the empty target is now removed first.
- Verified by the user in the window afterwards: the controller, raw mouse look
  and full screen all work.
- **Motion vectors.** The game produces none. Camera motion could be rebuilt from
  depth and the view-projection matrices in the vertex shader constants; moving
  characters would need per-draw previous-frame transforms. MetalFX temporal
  upscaling and frame interpolation both need these vectors, so neither is a quick
  add.

## 2026-10-23 — Motion vectors for temporal upscaling (investigation)

The game has no motion vectors, but it gives us enough to compute exact ones.
Measured headless with `BL_DRAW_STATS`/`BL_DRAW_DUMP` in sp_theatre (street, 124
draws a frame) and sm_hub_1 (the dialogue with the homeless man, 77 draws).

- **Nearly every 3D draw uses a vertex shader** with Source's constant layout:
  c4–c7 model-view-projection, c8–c11 view-projection, c2 eye position,
  c16 fog, c21–c26 ambient cube, c48 onward the model matrix or the bone matrices
  (indexed through a0 in skinned shaders). The shaders compute
  `world = v0 · c48..` (or bones) and `clip = world · c8..c11`, or use
  `clip = v0 · c4..c7` directly for brushes and static props.
- **Draws can be matched between frames.** In both scenes, every draw's source
  (vertex buffer, index buffer, start index, base vertex, vertex range, vertex
  shader) was identical between consecutive frames. A few keys repeat within a
  frame (multi-pass), so the match also needs the occurrence number.
- **Character animation shows in the constants.** For a skinned draw 20 frames apart,
  c46–c47 and c51–c95 (bones) changed while the camera stayed still. Between two
  consecutive headless frames nothing changed, which suggests animation does not
  update on every rendered frame.
- **Frame layout:**
  1. the 3D skybox (its own view-projection),
  2. sometimes a few orthographic draws with depth off,
  3. the main 3D pass,
  4. the HUD and dialogue as orthographic draws (c8–c11 last row 0 0 0 1),
     depth off and blended, at the end.

Plan this supports:
- Keep each draw's constants for one frame, keyed as above.
- Translate each vertex shader so its body also runs with last frame's
  constants for the same draw, giving the previous clip position per vertex.
- A draw with no match (first frame on screen) falls back to the current
  constants with last frame's c8–c11.
- Pixel shaders write `(prev - cur)` in pixels to a second render target. Blended
  draws don't write it.
- Jitter is added to the current position only.
- The back buffer becomes a lower-resolution scene target.
- Draws after the previous frame's last perspective draw go to a full-resolution
  HUD layer, composited over the MetalFX output.
- A camera cut (a large jump in c8–c11) resets the history.

**TODO (later): temporal upscaling.** Nothing above is implemented yet. Order of work:
1. Per-draw constant snapshots and draw matching.
2. Previous-position vertex shader pass and a motion-vector target, checked with a
   debug view before anything else.
3. Jitter, a lower-resolution scene target and a full-resolution HUD layer.
4. MetalFX temporal scaler at present, and a history reset on camera cuts.

## 2026-10-23 — 2x MSAA

- **What.** The back buffer and the automatic depth buffer get 2x multisampled copies
  (`BL_MSAA`, default 2, 1 turns it off). Passes on them draw into the copies and
  resolve into the surfaces' own textures at the end of each pass
  (StoreAndMultisampleResolve), so present, StretchRect sources, GetRenderTargetData
  and frame dumps all read the resolved image. The game's other render targets
  (shadows, reflections) stay single-sampled; a pass on one of them with the
  automatic depth buffer uses the single-sampled depth texture.
- **Alpha-to-coverage.** Alpha-tested draws without blending (fences, foliage,
  hair) get alpha-to-coverage when multisampled.
- **Writes that bypass the copy.** A StretchRect into the back buffer, or a pass
  that cannot be multisampled, marks the copy stale. The next multisampled pass
  first redraws the copy from the surface (`restore_ms`). A back buffer paired with
  a depth surface of the game's own is drawn single-sampled, and logged once.
  Neither case was seen in the test scenes.

Verified headless:
- sp_theatre frame 1500 with `BL_MSAA=1` and `2`, zoomed on the power pole: with
  2x the wires are continuous instead of broken into steps, and the pole and
  crossarm edges are smoother.
- sm_hub_1 dialogue frame 1450 renders correctly with 2x (character, dialogue box,
  text).

Not verified: the cost in the window, and the alpha-to-coverage edges up close.

## 2026-10-23 — Mac resolutions, a persistent registry, widescreen correction

- **Registry** (`runtime/bl_registry.c`). Reads used to find nothing and writes were
  dropped, so a resolution picked in Options was lost on restart. Keys and values now
  live in memory and are saved to `<data dir>/registry.txt` after every change.
  `BL_REG_TRACE=1` logs each call. The game keeps its video mode in
  `HKCU\Software\Troika\Vampire\ResPatch` (ScreenWidth, ScreenHeight, ScreenBPP,
  ScreenWindowed: the Unofficial Patch's resolution patch), plus Python's
  `...\Vampire\Settings\User Token n`.
- **Display modes** (`runtime/bl_display.c`). Direct3D's mode list, the desktop
  size (`GetAdapterDisplayMode`, `GetSystemMetrics`, `GetDeviceCaps`) and the
  virtual screen now come from the main display.
  - The list holds every pixel size and "looks like" size the display offers, plus
    the common 4:3, 16:10 and 16:9 sizes that fit, from 640x480 up.
  - On this Mac: desktop 3600x2250, 38 modes, logged at start-up as `[display]`.
  - Windows for modes bigger than the screen are shrunk to fit; the drawable keeps
    the game's resolution.
- **Widescreen.** At 1680x1050 the 3D view came out stretched sideways: a window arch
  was 1.18x wider relative to its height than at 800x600, which is 16:10 over 4:3.
  The game's view-projection always has a y/x scale ratio of 4:3. The Unofficial
  Patch adds the resolutions but not this correction.
  - The vertex output's y is now scaled by viewport aspect over projection aspect.
    The projection aspect is measured from the c8/c9 row lengths, or PROJECTION
    _22/_11 for fixed-function draws, so a correct projection is left alone.
  - Only perspective draws on a viewport wider than their projection are scaled; 2D
    draws are left alone. This crops the top and bottom (vert-) rather than widening
    the view, so the game's culling still matches what is drawn.
  - `BL_WIDESCREEN=stretch` turns it off.

Verified headless at 1680x1050 (seeded through registry.txt):
- sp_theatre: the arch proportions match the 4:3 frame, and the HUD gauges sit at the
  screen edges unstretched.
- sm_hub_1 dialogue: the face has natural proportions and the dialogue box is right.
- The main menu draws. Its 2D art is the game's own 4:3 layout spread across the
  width, which this does not change.

Not verified:
- Picking a mode in Options in the window, and the mode surviving a restart.
- Native Retina sizes such as 3024x1964.
- Screen-space effects (water refraction, discipline overlays) at 16:10.

## 2026-10-23 — Frame pacing on ProMotion, and a fast -dev console

### Frame pacing
The game is capped at 60 fps (`BL_FPS_MAX`), since its physics and scripts expect it.
A plain `presentDrawable` shows each frame at the first refresh after the GPU
finishes. On a 120 Hz ProMotion screen the small jitter of the cap's sleep made some
frames last one refresh and others three.

- When the screen's `maximumFramesPerSecond` is a whole multiple of the cap, the
  present is now `presentDrawable:afterMinimumDuration:1/cap`. Each frame is held
  for exactly two refreshes at 120 Hz. The game tick is unchanged: the cap's sleep
  still sets the loop rate.
- Other rates (144 Hz, say) keep the plain present. Holding whole refreshes there
  would slow the game to 48 fps.
- The screen is re-checked every 120 frames, in case the window moves to another
  display. `BL_PACING=0` turns this off.
- `BL_PACING_STATS=1` logs, every 600 frames, how many refreshes apart frames
  reached the screen (from the drawables' `presentedTime`).

Measured in the window on this Mac's built-in 120 Hz screen, at the main menu:

| | 1 refresh | 2 refreshes | 3 refreshes |
|---|---|---|---|
| before (`BL_PACING=0`) | 24 to 28 | 544 to 552 | 24 to 28 |
| after | 0 | 600 | 0 |

That is out of each 600 frames, over 3 windows of 600.

Not verified:
- In-game scenes, where a slow frame can still take three refreshes.
- 60 Hz and 144 Hz external screens.
- Added input latency. The minimum duration can hold a finished frame back by up to
  one refresh.

### -dev console
The slow path noted earlier (see "Launching with -game Unofficial_Patch") was profiled
with `sample` during a `-dev +map sp_theatre` load. About 99% of the main thread's
time was in GameUI 0x10029250, vgui `RichText::GetCursorLine`.
- That routine scans the line-break table from the start for the first break after
  the cursor.
- InsertChar calls it per character. The scroll-to-end code (0x100284CF onward)
  calls it again in a loop, once per line it scrolls.
- The table is in ascending text order, so a binary search gives the same index.

Fix:
- `runtime/bl_vgui.c` replaces the routine through
  `modules/GameUI/external_procedures.sci` and `ignored_areas.sci` (63 bytes).
- GameUI needs a re-translation for this, which takes 13 s.
- `BL_VGUI_CHECK=1` also runs the original linear scan and logs any difference.

Verified headless:
- `-game Unofficial_Patch -window -dev +map sp_theatre` reaches frame 300 in the map
  in 54 s, with 56,000 console lines. Before the fix the same run was still on frame
  1 after 150 s, when it was stopped.
- With `BL_VGUI_CHECK=1`, about 13,700 console lines gave no difference between the
  two searches. That run was stopped early, since it runs at the old speed.

Not verified:
- Opening the console in the window and scrolling it.

## 2026-10-23 — sRGB colour and deep colour

The game has no HDR rendering: the 2003 Source branch draws 8-bit standard-range
colour (HDR came with Source 2005). Two smaller display fixes instead:

- **sRGB tag.** The CAMetalLayer had no colour space. The compositor then shows the
  values unconverted, so the game's sRGB colours looked too saturated on a P3 screen
  such as the MacBook Pro's XDR display. The layer is now tagged sRGB and macOS
  colour-matches it.
- **Deep colour** (`BL_DEEP_COLOR`, default on). The back buffer is `RGBA16Unorm`
  instead of `BGRA8Unorm`, and the window's drawable is `BGR10A2Unorm`. The game's
  blended passes (lightmaps, fog, decals) now keep 16 bits between passes, which
  reduces banding in dark gradients. A unorm format still clamps to 0..1 like the
  8-bit format, so blending results do not change otherwise. A float format would not
  clamp.
  - Places that assumed 8 bits now convert with a draw instead of a blit: the present,
    StretchRect from the back buffer to an 8-bit surface, GetRenderTargetData, and
    the frame dumps (`as_bgra8`, `copy_to_drawable`).
  - Only the device's own colour surface changes. The game's render-target textures
    stay 8-bit.

Verified:
- Headless `-dev +map sp_theatre` at 1920x1080: frame 1150 matches the 8-bit run
  within 6/255 per channel, which is rounding. No StretchRect warnings.
- In the window: the intro movies (GDI path) and 900 frames of the main menu present
  through the 10-bit drawable, with no Metal errors.

Not verified:
- That the colours look right on screen: this needs the user's eye.
- Whether banding is visibly less in-game.
- The cost at high resolutions: the back buffer is twice the size, and twice again
  with 2x MSAA.

## 2026-10-23 — Black surround for centred intro movies

The user saw white around some intro movies. `BL_GDI_TRACE=1` (new) logs each change of
Bink's GDI blit geometry. At 1920x1080 the four intro movies are:

| DIB | source | destination |
|---|---|---|
| 640x480 | whole | 0,0 1920x1080 (stretched) |
| 720x480 | whole | 0,0 1920x1080 (stretched); white background |
| 1920x1080 | 640,300 640x480 | 640,300 640x480 (centred) |
| 1920x1080 | 560,340 800x400 | 560,340 800x400 (centred) |

The centred movies blit only their own rectangle. The persistent window image still held
the last frame of the white-background movie around them. Windows repaints the window
black in between, but our FillRect and WM_ERASEBKGND do nothing.

Fix: `d3d_render_present_pixels` clears the window image to black whenever the frame
size or destination rectangle changes.

Verified: in the window, all four movies play with no errors, and the trace shows the
geometry above. Not verified by me on screen: that the surround is now black (the
user's check).

Not changed here: the first two movies are 4:3 and 3:2 but are stretched to fill a
16:9 window. The game asks for that stretch; Windows would do the same. (Since
changed; see the next section.)

## 2026-10-23 — Intro movies at 4:3

A movie the game stretches over the whole window, on a window wider than 4:3, is now
drawn as a centred 4:3 picture with black bars. That is how it looked on the 4:3
screens of the time. The 720x480 White Wolf movie is included: DV-sized frames are
4:3 pictures with narrow pixels. Centred movies drawn at their own size (nVidia,
Troika) are left alone. `BL_WIDESCREEN=stretch` restores the stretch, as it does for
the 3D projection.

`BL_MOVIE_DUMP=1` with `BL_DUMP_DIR` writes frame 60 of each GDI-drawn movie, taken
from the window image.

Verified in the window at 1920x1080, from those dumps:
- Activision and White Wolf fill a 1440x1080 area with black bars on both sides.
- nVidia and Troika sit centred on black, with no white left from the movie before.

Not verified: other window sizes, and movies played later in the game, if any use
this path.

## 2026-10-24 — Shader compile hitches

**Measurement.** `BL_SHADER_STATS=1` (new) logs every frame that waits more than 2 ms
for shader or pipeline builds, and totals every 100 frames. `BL_SHADER_SALT=x` (new)
changes every generated MSL source, so macOS's own shader cache misses. That stands
in for a first launch, or the first launch after a macOS update.

Headless, `-game Unofficial_Patch -window`, 1500 frames:

| map | cache | shaders at draws | worst frames |
|---|---|---|---|
| sp_theatre | cold | 24, 755 ms | 584 ms (first map frame), 174 ms |
| sp_theatre | warm | 24, 2 ms | none over 2 ms |
| sm_hub_1 | cold | 33, 789 ms | 657, 130 (in the world), 128 ms |
| sm_hub_1 | warm | 33, 1 ms | none |

Pipelines cost only 3 ms warm; 158 ms cold on sm_hub_1. So the hitch happens only the
first time each shader is ever compiled. Once macOS has cached it, building it again is
almost free, and a cache of our own would add nothing.

**Change: early compiles** (`BL_SHADER_EARLY`, default on).
- When the game creates a vertex or pixel shader (`d3d_render_shader_created`), its
  likely variant starts compiling on GCD's concurrent queue: float vertex inputs, 2D
  textures (or the declared sampler types), no projection.
- The game creates its whole shader set while loading, 1431 shaders, so all cores
  work on them during the load.
- A draw that needs a shader still waiting in the queue claims it and compiles it
  itself, instead of waiting behind the rest. A shader already compiling is waited
  for.
- A draw that needs another variant compiles it as before.
- The compile works from a copy of the bytecode, in case the game releases the
  shader first.

Result on sm_hub_1, 1500 frames:

| cache | early | waiting in draws | worst frames | max RSS |
|---|---|---|---|---|
| cold | off | 786 ms | 572, 126, 75 (in the world) ms | — |
| cold | on | 315 ms | 266 (first map frame), 47, 5 ms | 761 MB |
| warm | off | 3 ms | 2 ms | 714 MB |
| warm | on | 0 ms | 5 ms | 748 MB |

- On a cold cache the in-world hitch is gone. The first map frame still waits for the
  7 shaders whose variant was guessed wrong; that frame falls in the load transition.
- The cost is about 34 MB more memory for the compiled functions. Run time is
  unchanged.
- Frame 1400 of sm_hub_1 (dialogue) looks the same with early compiles on and off.
  Pixel differences between runs match those between two runs with it off
  (animation timing).

Not verified:
- In the window.
- Other maps, and discipline or combat effects first seen mid-game.
- The machine cost of 1431 cold compiles at startup on a Mac with fewer cores.

## 2026-10-24 — Room reverb checked; menus at 4:3

### Reverb
- Nothing to add. The engine has no EAX code. Its room echo is Source's own software
  DSP (`dsp_presets.txt`, the automatic `adsp_*` room detection), mixed into the
  DirectSound buffer before it reaches our mixer, so it is already in the output.
- No game module imports Miles' reverb or room calls (`AIL_set_3D_room_type` and so
  on).
- `BL_QI_TRACE=1` (new) logs every refused QueryInterface. A `+map sm_hub_1` run
  refuses none, so nothing asks for IKsPropertySet (EAX).
- Not verified by ear: that the DSP is audible in the window (`dsp_off 1` in the
  console should remove it).
- One headless `-window +map sm_hub_1` run with `BL_QI_TRACE` hung before its first
  frames: all threads were waiting, at 0.8% CPU. Two reruns of the same command
  finished normally. Not investigated further.

### Menus at 4:3
The main menu and loading screens are 4:3 layouts that the game stretches across a
wider mode.
- A frame counts as "no world view" when none of its perspective draws to the back
  buffer has a camera away from the origin (a w-row translation of 0). The main menu's
  smoke is drawn with a camera at the origin, as sky boxes are, while every in-game
  frame has world draws with a translation.
- Counts of draws with a camera away from the origin, per frame:

  | screen | count |
  |---|---|
  | main menu | 0 |
  | loading screens | 0 |
  | character creation (`sp_genesisdevice_1`) | 11 |
  | sm_hub_1 dialogue | 60 |
  | sp_theatre | 109 |

- When the previous frame had no world view, every draw to the back buffer is
  narrowed to a centred 4:3 area through the Metal viewport and scissor
  (`set_viewport` with a squeeze). The projection then gets no widescreen
  correction. Black bars are drawn at present (`menu_bars`).
- `bl_cocoa_set_squeeze` maps mouse positions back (and the controller's pointer
  warp forward), so clicks land on what is drawn.
- The first frame after the menu or a load still draws at 4:3, since the decision
  comes from the frame before. `BL_WIDESCREEN=stretch` keeps the stretch.
- Character creation keeps the full width.

Verified headless at 1920x1080:
- The main menu is 1440x1080 with bars, and its logo and item images in proportion.
- The sm_hub_1 loading screen is pillarboxed.
- In the map, frames are full width (the log says "full width" from the first world
  frame).

Not verified:
- Clicking menu items in the window (the mouse mapping).
- The in-game Esc menu, and other 2D-only screens.

### Text size
Not changed. GameUI and the HUD draw text with bitmap fonts, not GDI: the game creates
one GDI font (Arial, -15) at both 1024x768 and 1920x1200. Larger dialogue text would
need a change to how the game's 2D code draws those fonts. `BL_FONT_TRACE=1` (new)
logs GDI font requests.

## 2026-10-24 — Unofficial Patch 12.0

The player's copy had Unofficial Patch 11.1. The 12.0 installer
(`VTMBup120.6.exe`, SHA-256 `e3bf44aa…f734`) is an Inno Setup 5.6 package, so it was
unpacked with `innoextract` into a temporary folder instead of being run. Nothing from it
was executed.

Installed into the game folder:
- `Unofficial_Patch/` replaced as a whole (the readme says to remove the old folder).
- `Bin/`: engine, launcher, shaderapidx9, vampire_python21 (changed), vguimatsurface and
  binkw32 (same as before).
- `Vampire/`: cl_dlls/client.dll, cl_dlls/GameUI.dll, dlls/vampire.dll, pack102/103.vpk,
  and 103 files under maps/ and python/.
- `Loader.exe`, `Bin/loader/`, `Version.inf`, `VTMBup-readme.txt`.
- Not installed: `Patch_Extras/` (dgVoodoo, ENB, ReShade, tools) and the `.12` files,
  which are the stock 1.2 files from 2004 that the installer keeps for older retail copies.

The 11.1 files that were replaced are in `UP11.1_backup/` beside the game.

What changed in the code: every changed DLL keeps its size, so these are byte patches
and no addresses move.

| Module | Bytes patched in .text | Other |
| --- | --- | --- |
| engine | 106 in 22 places | .rdata, .data |
| GameUI | 290 in 5 places | .rdata, most of .reloc |
| shaderapidx9 | 43 | .data |
| client | 28 | .data |
| vampire | 1 | .data |
| launcher | none | 11 bytes of .rdata |
| vampire_python21 | none | .rdata, .data |

None of the patches touch the one hand-replaced routine (GameUI `loc_10029250`,
`bl_vgui_GetCursorLine`), and the runtime has no hard-coded addresses in these modules.
Data sections are built into the translated objects, so all seven modules need a full
re-translation, not just a relink.

`modules/hashes.txt` now pins the 12.0 hashes as well as the old ones, and
`rebuild_all.sh` takes the first version listed that it finds (12.0 first). A dry run
picked the 12.0 file for each of the seven modules.

Not covered: the 12.0 Game Mod Loader. `Bin/loader/*.vtm` are Windows DLLs that
`Loader.exe` injects into the game, each with its own fixes (Griffith frenzy werewolf,
history stat reset, subtitle and console pause, Protean, and the vtmb-tweaks options
such as corpses not despawning). The port starts the game without the loader, so those
fixes are missing until the .vtm modules are translated and loaded.

Also noted: the old `Unofficial_Patch/` held a 299 KB file named `nul` written on
2026-10-23, so a guest write to the Windows `NUL` device created a real file.

### 12.0 rebuild (2026-10-24)
All seven modules re-translated with no SRW errors: launcher 2 s, vampire_python21 36 s,
shaderapidx9 16 s, GameUI 12 s, client 100 s, engine 147 s, vampire 525 s.

The first boot stopped before the menu with "out of guest memory for a 256x256x1 image".
The cause is the texture memory estimate in shaderapidx9 (0x2A026250):
- 11.1 had patched it to return 0x7F000000 straight away.
- 12.0 undoes that. With no `Bin/vidcfg.bin` cache, it creates 256x256 R5G6B5 textures
  until CreateTexture fails, then frees them and caches the count.
- Our CreateTexture does not fail, so about 10,000 textures used up the 1.6 GB guest
  heap. Making it fail would not be enough, because freed guest blocks stay in their size
  class, so the measurement would still leave the heap unusable for anything else.

The routine is now replaced by `bl_shaderapi_TextureMemory`. It returns 0x7F000000 as
11.1 did, or 64 MiB when the second argument is 2 as 12.0 does, and it does not write
`vidcfg.bin`.

`BL_HEAP_TRACE=1` now also logs:
- a count every 1000 blocks of a size class of 4 KiB or more, and every 20000 below that;
- requests of 64 MiB or more;
- the arena state when the heap is full.

Verified: headless `-game Unofficial_Patch -window +map sm_hub_1`, 1500 frames, exit 0,
no traps. Frame 1400 shows the hub with the HUD.

Not verified:
- Play in the window, and whether old 11.1 saves load.
- Any of the 12.0 fixes themselves in play.
- The menu and character creation under 12.0.

### 12.0 content on 11.1 code (2026-10-24)
In the window under the 12.0 DLLs, two things were wrong:
- The resolution list had only the stock 4:3 modes.
- The main menu flickered.

Comparing the 12.0 DLLs with 11.1 shows that 12.0 took most of its code fixes out of
them, and the 12.0 loader applies them in memory instead (`Bin/loader/loader.ini`,
"Internal Hooks"). For example:
- **engine:** the allowed-mode table at 0x200fc8b0 points at the stock five 4:3 entries
  (0x201ad44c, count 5); 11.1 had a 34-entry table at 0x20195dd0. The 11.1 code cave at
  0x20172fb0 (66 bytes) is gone, and several byte fixes are back to stock.
- **GameUI:** the 11.1 code caves at 0x1004e640 (Cyrillic text conversion) are gone.
- **shaderapidx9:** the texture memory measurement is back (see above).

The loader also does widescreen aspect, FOV and HUD correction, and fixes coronas, lights
through walls, model LODs, claw stats and refresh rate. The port does not run
`Loader.exe`, so on the 12.0 DLLs those fixes are missing.

Decision (the user's choice): use the 12.0 content (`Unofficial_Patch/`, `Vampire/maps`,
`Vampire/python`, pack files) with the 11.1 DLLs.
- The 11.1 DLLs are back in `Bin/` and `Vampire/`. The 12.0 DLLs are kept in
  `UP12.0_dlls/`.
- `modules/hashes.txt` lists 11.1 first, so `rebuild_all.sh` prefers it, and still
  accepts 12.0.
- `bl_shaderapi_TextureMemory` now always returns 0x7F000000, as 11.1 does.

Between 11.1 and 12.0, vampire.dll differs by 1 byte of code and client.dll by 28, so
the 12.0 scripts should match the 11.1 game DLL. This is not tested in play.

Rebuilt from the 11.1 DLLs (the same seven modules, 14 minutes; the translated engine
uses the 34-entry mode table at 0x20195dd0 again).

Verified:
- Two headless `+map sm_hub_1` runs of 600 frames exit 0 with no traps.

Not verified:
- The resolution list and the menu flicker in the window (needs the user).

Also seen: one more headless run hung before its first frame. Every thread was waiting,
and the main thread was in a WaitForSingleObject called from guest code. The same run
passed twice afterwards. This looks like the intermittent hang noted earlier, so it is
not new with 12.0, and it is still not understood.

In the user's window run on the 12.0 DLLs (before this rebuild), the game printed
"Not a RIFF File" after `_stat` of `unofficial_patch\sound\` for many sounds once a map
was loaded. All 1962 .wav files in the 12.0 `sound/` folder start with RIFF, so it looks
like a request for an empty sound name. It did not appear in the two headless runs on
the 11.1 DLLs. It still needs checking in the window.

### Node graphs, Marlett check boxes, wait trace (2026-10-24)
**Node graph out of date.** Every map rebuilt its AI node graph on load, which made
loading long. The cause: I copied the 12.0 files with `cp -R`, which drops modification
times, so each `.bsp` looked newer than its `maps/graphs/*.ain`. The times are now restored
from the unpacked installer with `rsync -a` (this also put back the shipped `.ain` files the
game had rewritten). Only `sp_genesisdevice_1`, which has no NPCs, ships with its map newer
than its graph.
- Verified: 8 headless loads of `sp_tutorial_1` print no "Node Graph out of Date".

**Missing check boxes in Options.** vgui draws check boxes, radio buttons, scroll arrows,
the combo box arrow and frame buttons with characters of the Windows Marlett symbol font.
macOS has no Marlett, and `bl_gdi.c` substituted Arial, so check boxes showed the letters
g/e/f/b and combo boxes a "u". This predates 12.0. Marlett fonts are now flagged at
CreateFont: square cells, and the glyphs that vgui uses are drawn as shapes in a 13-unit
em (`marlett_render`). Other characters are blank.
- Verified: it builds, and the game creates Marlett at heights 12, 13 and 16.
- Not verified: how the drawn glyphs look (Options cannot be opened headless).

**Startup hang.** It happened again twice, at the same point: after `config.cfg` is read
and before DirectSound starts. Both times the user's game was running at the same time.
Eight more headless runs on an otherwise idle machine did not hang. `BL_WAIT_TRACE=1`
(new) logs any infinite WaitForSingleObject still blocked after 5 s, with the handle and
the guest backtrace, so the next hang shows what the main thread is waiting for.

**Menu flicker.** Not reproduced headless. Consecutive menu frames differ only where
the particles move. It needs a description from the user.

### Main menu particle flicker (2026-10-24)
**Cause.** The menu's smoke and fire are five fixed-function particle draws per frame,
blended ONE / INVSRCALPHA. The game shares a few 256x256 textures between those particle
systems and rewrites them with LockRect between draws, within a frame: one texture object
was drawn twice in frame 320 with different contents. `texture_of` uploaded into the same
MTLTexture in place, so every draw in the command buffer saw the last image written, and
which system got the wrong image changed from frame to frame. That gave the sharp-edged
shards and the frame-to-frame flashing. The vertex data was correct (I dumped it over four
frames: square quads, smooth motion, valid index ranges, nothing behind the near plane).
The earlier "not reproduced headless" was wrong: headless flickers too. My first metric
compared runs that caught different phases of the menu animation.

**Fix.** A texture rewritten after a draw has bound it gets a new MTLTexture with all
levels uploaded. Command buffers retain the old one, so draws already encoded keep their
image. Static vertex buffers rewritten after use get the same treatment (a new MTLBuffer;
after 8 rewrites they are copied per draw like dynamic ones). That case is the same bug
class, but it is not what caused this flicker.

**Muting test runs.** A window used to turn audio on regardless of `BL_AUDIO`. Now an
explicit `BL_AUDIO=0` mutes a window run and `BL_AUDIO=1` enables headless audio. All my
test runs pass `BL_AUDIO=0`.

- Verified: brightness of the lower menu band, frames 300-339. Before the fix, most runs
  had a mean frame-to-frame jitter of 5-23, with alternating values (113, 77, 108, 74).
  After it, three headless and two window runs gave 0.1 each. The frames show soft smoke
  and fire with no shards. A 900-frame run into `sm_hub_1` renders normally.
- Not verified: the user's own view of the menu in the window, and whether the extra
  texture allocations cost frame time in busy scenes.

### Ambient occlusion, with a check box in the Visual options (2026-10-24)
**Effect.** Screen-space ambient occlusion (GTAO) on the world view, in
`metal_render.m` (`ao_run`). The renderer notes the world's projection from the first
full-screen perspective draw to the back buffer. When the world is done (the view model's
short depth range, a non-perspective draw such as the HUD, or Present), it ends the pass
and runs three half-resolution passes: linear depth from the multisampled depth buffer,
GTAO with 2 slices of 4 steps and normals from neighbouring depths, and a 4x4
depth-aware blur. The next pass on the back buffer starts by multiplying the result into
the colour. Sky (depth 1) is left alone. `BL_AO=0|1|show` overrides the setting;
`BL_AO_RADIUS` (32 world units) and `BL_AO_STRENGTH` (0.6) tune it. `BL_GPU_STATS=1`
prints the mean GPU time per frame.

**Check box.** GameUI's Visual tab gets "Ambient Occlusion" under "Combat effects", the
same size and font. GameUI is rebuilt with the page's OnResetData and destructor replaced
(`modules/README.md`); the new reset creates a vgui CheckButton on the page. Like the
tab's other settings (its note says they apply at once), a click takes effect
immediately: once a frame the renderer reads the box, and a change is saved as
`HKCU\Software\Troika\Vampire\Native\AmbientOcclusion` in the runtime's registry file.
The default is off.

**Test input.** `BL_CLICKS="frame:x,y ..."` clicks at game pixels on given frames, so
menus can be driven without a window.

- Verified (M4 Pro, 1920x1080, MSAA 2x): the haven, an Elysium corridor, an outdoor
  street and a dialogue close-up look right, with corners, furniture and window recesses
  shaded and the sky untouched. GPU time in `sm_pawnshop_1` went from 1.75 ms to 2.79 ms
  a frame (an earlier full-resolution version cost 3.7 ms more); `la_hub_1` from 3.44 ms
  to 4.53 ms. With scripted clicks, headless: the box appears in the right place and font,
  a click ticks it, the setting saves as 1 and then 0, a restart shows it ticked, and a
  level started with the setting on runs AO while one with it off does not.
- Not verified: the view model (no weapon was drawn in the test scenes), cost at Retina
  resolution, toggling from the in-game pause menu, and the user's own look in the
  window. Some streaking shows on nearby floors at grazing angles.

**Toned down (2026-10-24).** In the window the user's on/off screenshots of the haven
kitchen showed the first settings (radius 48, strength 1) darkening whole surfaces: the
upper cabinets, ceiling and walls, not only corners. Measured on `sm_pawnshop_1` frame
650, they made the picture 18% darker overall, and a quarter of it more than 31% darker.
The defaults are now radius 32 and strength 0.6: 7% darker overall, half the pixels
changed by under 3%, and contact shadows under furniture and in corners kept. Tried
too: 24 / 0.7 (much the same) and 48 / 0.5 (9% darker, broader). Not verified: the
user's view of the new defaults.

### Screen-space reflections and sharpening, with check boxes (2026-10-24)
**Where reflections go.** The game marks its shiny surfaces itself: their pixel shaders
add a reflection cubemap (a fixed picture of the room) on top of the lit colour. A
diagnostic run over five levels found these are a handful of ps_1_1 shaders, all of the
form `base * lightmap * 2 + cubemap * mask * tint`: floors and walls in the Ventrue
Tower lobby, the Asylum's tiles, windows in the Downtown hub. One ps_1_4 shader also
reads a normalisation cubemap, used as a vector (`_bx2`); `d3d_shader_env_maps` skips
cube samplers read that way.

**Reflection info.** With reflections on, each shader drawn in the world view's passes on
the back buffer gets a second colour output (`d3d_shader_variant.reflection_info`). For a
shader with reflection cubemaps the translator runs its body twice more with them read as
black and as white, so the output holds exactly what the cubemaps added (rgb) and how
much a white cubemap would add (alpha), after fog. Other opaque draws write zero, so a
character standing on a shiny floor clears it; blended draws leave it. The attachment is
RGBA16Float, multisampled with the back buffer and resolved like it.

**Trace and apply.** At the world view's end (`post_run`, which now also runs the ambient
occlusion: `ao_run`, `ao_state` and `ao_before_draw` became `post_run`, `view_state` and
`post_before_draw`), from the occlusion's half-resolution view depth: a normal from
neighbouring depths, the reflected ray marched in screen space (24 steps, denser near the
start, offset in a 4x4 pattern, then 5 halvings), the colour where it meets the picture
weighted by a confidence that fades at the screen's edges, at the ray's end and for rays
coming back at the camera; then a depth-aware 5x5 filter. The next pass on the back buffer
starts with `post_apply`: a copy of the world view plus, on reflective pixels,
`strength * (weight * reflection - confidence * cubemap share)`, so where a ray finds
something it takes the cubemap's place and elsewhere the cubemap stays. `BL_SSR=0|1|show|hits`
overrides the setting; `BL_SSR_STRENGTH` (default 1) scales it.

**Sharpening.** `post_apply` also sharpens the world view before the view model and HUD
are drawn (so text and the HUD are left alone): a 5-tap contrast-adaptive filter like
AMD's CAS. `BL_SHARPEN=0|1` overrides the setting, `BL_SHARPEN_STRENGTH` (0..1, default
0.5) tunes it.

**Check boxes.** The Visual tab's three boxes are saved as `AmbientOcclusion`,
`Reflections` and `Sharpening` under `HKCU\Software\Troika\Vampire\Native` (default off).
Stacking them under "Combat effects" covered the "Particles" slider, so "Reflections" and
"Sharpening" sit beside that slider, placed in `optionssubvisual.res` units scaled from
"Combat effects".

- Verified (M4 Pro, 1920x1080, MSAA 2x, headless, no audio): in `sm_asylum_1` the bar's
  tiled floor shows the bar, stools and green lights reflected; in `la_ventruetower_1` the
  lobby floor reflects the desk, faintly, because the room is dark and its cubemap was
  brighter than the room; in `la_hub_1` only windows change. Sharpening visibly crisps
  the Asylum's frieze and bottles. All three effects together and the no-MSAA path run
  with Metal API validation clean. GPU time in `sm_asylum_1`: 1.79 ms a frame without,
  2.57 ms with reflections, sharpening about free. With scripted clicks the boxes appear
  beside the slider without covering it, ticking them saves 1, and a level started with
  the saved settings runs them.
- Not verified: the look in a window and in motion (the half-resolution trace may shimmer
  at edges), Retina resolution, reflections of the view model (drawn after the trace, so
  never reflected), and shaders on other levels that might write a second colour output
  themselves (they are left without reflections).

### Reflection tune-ups (2026-10-24)
Six small changes to the screen-space reflections, all in `metal_render.m`:

- **Fresnel.** The game's cubemaps are as strong head-on as at a grazing angle. The trace
  now also writes Schlick's term, `1 + fresnel * (1 - cos)^5`, to a second half-resolution
  target (RG16Float, with how far the ray went), and `post_apply` scales the whole
  reflection (screen-space part and the cubemap that stays) by it:
  `col += strength * (F * (weight * reflection + (1 - confidence) * cubemap) - cubemap)`,
  the old formula when F is 1. `BL_SSR_FRESNEL` (default 3).
- **Blur by ray length.** The filter's width follows how far the ray went (sigma 0.4 to 2
  half-resolution pixels, `BL_SSR_BLUR` per pixel of ray, default 0.02): sharp where
  things touch the surface, softer further off. A fixed 5x5 grid of taps, spaced 2 apart
  for the wider blurs, still weighted by depth.
- **Contact.** The ray starts half a pixel out instead of 1.5, with a small depth bias
  (0.2%) so the surface does not meet itself. The dark band under the Asylum's bar turned
  out to be mostly the bar's dark base reflected, which is right; it is now sharper.
- **Upsample.** `post_apply` blends the four half-resolution pixels around by hand and
  leaves out those that are not reflective (an object in front), instead of a plain
  bilinear sample that bled their zero into the reflection's edge. The trace marks them
  with confidence -1, which the filter skips too.
- **Back faces.** After the halvings the hit point's own normal comes from its depth
  neighbours; a ray going the way that surface faces came from behind it and is dropped.
- **Noise.** Interleaved gradient noise in place of the 4x4 Bayer offset, so the step
  pattern no longer repeats every 4 pixels.

- Verified (M4 Pro, 1920x1080, MSAA 2x, headless, no audio), against the previous commit:
  in `sm_asylum_1` the bar top now shows the bottles reflected and the floor's
  reflections are stronger towards the back, where the view is more grazing; in
  `la_ventruetower_1` the desk top reflects the guard and the sign. Metal API validation
  is clean with all three effects on. GPU time: `sm_asylum_1` 2.70 ms a frame (2.71
  before), `la_ventruetower_1` about 5.0 ms (4.5 before; the wider blur over its large
  reflective floor).
- Not verified: the look in motion and in a window.

## 2026-10-25 — Tone mapping tests, HDR, volumetric light, skin scattering

All in `runtime/d3d9/metal_render.m` unless named; each effect has an environment
variable (documented at the top of that file) and, apart from the tone maps, a check box in
the Visual options (`bl_vgui.c`: "HDR", "Volumetric Light", "Skin Scattering").

- **Tone map tests.** `BL_TONEMAP=gt7|gt7x|pbr|pbrx` tries Gran Turismo 7's curve and
  Khronos PBR Neutral on the world view in `post_apply`, with `BL_TONEMAP_EXPAND`. Off by
  default and not in the options: kept for comparison only.
- **HDR.** On a screen with extended dynamic range, `hdr_present` lifts bright parts above
  normal white by luminance: above a knee (`BL_HDR_KNEE`, default 0.05) the colour is
  scaled up towards `BL_HDR_PEAK` (default 4) times white, with a soft shoulder, capped by
  the screen's headroom at the time (`bl_cocoa_edr_headroom`). Checked with a
  ScreenCaptureKit HDR capture of a window run: pixels above white reach the screen
  (headroom 2.67 on the M4 Pro's screen at that brightness).
- **Volumetric light.** `runtime/bl_bsp.c` reads the map's `.bsp` when the game opens it
  (`bl_k32_CreateFileA_c`): its world lights (point and spot, with falloff and cones),
  BSP tree and visibility. Each frame the camera's leaf picks the lights it can see
  (within 3000 units, brightest 24, a line test against solid space fading those behind
  walls to 0.3). `fog_scatter` marches 16 jittered steps per half-resolution pixel through
  a thin haze (Henyey-Greenstein, g 0.35), a depth-aware blur follows, and `post_apply`
  adds it before the tone map. No shadows inside the haze. About 4 ms of GPU a frame.
- **Skin scattering.** Skinned draws (vertex shaders with blend weights or indices) get
  a shader variant (`d3d9_shader.c`) that runs the pixel shader a second time with its
  colour texture white and writes that light alone to the second colour target, marked
  -1. `skin_blur` blurs only that light (two passes, 13 taps, about 0.8 world units,
  red reaching further), then multiplies by the pixel's own colour (the picture divided
  by its light), so texture detail stays sharp. Only skin colours count (YCbCr test;
  blonde and red hair left out). On top: a two-lobe skin sheen lit by the map's lights
  and scaled to the game's own light there, Schlick Fresnel, wetter lips, the texture's
  fine detail as pores, creases (from depth) dimmed, and a faint rim at grazing angles.
  `BL_SSS=show` paints the characters' pixels red.
- **Fix found on the way:** with skin scattering on, characters' pixels skipped the
  sharpening filter and looked soft next to the sharpened world; they are now sharpened
  from the scattered picture like everything else.
- **Test input:** `BL_KEYS` (`bl_cocoa.m`) scripts keys, mouse turns and typed text by
  frame, for walking to characters in headless runs.

- Verified (M4 Pro, 1920x1080, headless, no audio): `sm_asylum_1`, Jeanette's dialog
  close-up and Cal at the bar, effects off and on; the lamp cones in the haze line up
  with the lamps downtown.
- Not verified: other levels' characters, the look in motion, GPU time of skin
  scattering on its own, Metal API validation with the new passes.

## 2026-10-25 — 4x MSAA, sharp cut-out edges, options layout, character detail and lighting

- **4x MSAA** by default (`BL_MSAA`, was 2).
- **Cut-out edges.** Alpha-tested draws (hair, fences, foliage) with alpha to coverage
  place the edge from how fast alpha changes across the pixel (`ps_alpha_and_fog`, the
  `edge` parameter), so the samples give a smooth, sharp edge instead of a dithered
  one. `BL_EDGES=0` off.
- **Options page.** The Visual check boxes sit in a column beside Shadow Count so none
  is cut off (`bl_vgui.c`).
- **Character textures from the player's own game.** `tools/tex_extract.py` reads the
  character textures out of the VPKs (Unofficial Patch's loose files first) into
  `build/textures/characters` (git-ignored: the game's art), with an 8x8 colour
  signature each. `tools/tex_normals.py`, run with chaiNNer's Python, makes a normal map
  and a roughness map for each NPC and player texture (1005, hair, eyes, teeth, lenses
  and gore left out) with PBRify_Remix's models, which the player downloads. At draw
  time `tex_detail.m` recognises the game's texture by size and signature (mean
  difference under 0.01) and binds the maps.
- **Smooth normals.** Normal mapping without stored tangents took the surface from the
  triangle and showed every facet of the low-poly faces. Detail draws now run the vertex
  shader twice, the second time on the position nudged along the model's normal through
  the same bones, and the step between the two is the smooth normal. The maps keep only
  their middle detail: the broad slopes the model guessed from the painted shading
  fought the mesh, and the finest grain looked like concrete.
- **Shine.** GGX specular with the roughness map (skin's 2.8% head on, Schlick Fresnel)
  and a soft "Charlie" sheen on rough cloth, from the map's lights, scaled to the game's
  own light there. Characters shone this way are marked -1.25 so the skin pass adds no
  second shine. `BL_SHINE` (default 4, 0 off).
- **Light with a direction.** The game lights characters per vertex, mostly from an even
  ambient, so faces looked flat. The light is shared out again per pixel: a third even,
  the rest by how the surface faces each nearby light, with a little wrap for skin; the
  same on average. `BL_CHARLIGHT` (0 to 1, default 1).
- **Upscaled faces, tried and stopped.** `tools/tex_upscale.py` (PBRify's 4x DAT
  upscaler) and the swap in `tex_detail.m` (`BL_UPSCALE=0` off) work, but at talking
  distance the sharper texture is hardly visible; only 7 were made.

- Verified (M4 Pro, 1920x1080, headless, no audio): `sm_asylum_1`, Jeanette's dialog
  close-up with each effect off and on; no triangle facets at 4x bump strength; the
  maps load for the Asylum's characters and the player's.
- Not verified: other levels, the look in motion, lights behind walls (not tested for
  occlusion yet, so a light in the next room can light a character), hair (still the
  game's flat light), GPU cost of the doubled vertex shader.

## 2026-10-25 — Better character shadows

A new "Shadows" check box in the Visual options (`BL_SHADOWS`, off by default) turns on
three changes to the shadows that characters and moving props cast. All the code is in
the shadows section and the contact shadows section of `metal_render.m`.

- **Sharper shadow atlas.** The game draws every caster into one 1024x1024 render
  target. With shadows on, its Metal texture is `BL_SHADOW_RES` times the size
  (default 4, so 4096x4096). Viewports, scissors, clears and stretch copies into it are
  scaled to match (`struct obj` field `gpu_scale`), and its paired depth surface is
  resized to the same scale (`shadow_match_depth`). Receivers read it with normalized
  coordinates, so they need no change. Flipping the setting mid-game redraws the old
  contents into the new texture.
- **Soft shadows (PCSS).** Default on, `BL_PCSS=0` turns them off. The shadows are
  crisp where they meet the caster and softer further away.
  - Casters write their light-space depth into the atlas's alpha, which is 16 bits a
    channel with shadows on (variant `shadow_caster`).
  - Receivers' atlas reads become one lookup (variant `shadow_receiver`,
    `bl_shadow_soft` in `d3d9_shader.c`): a 24-tap blocker search, then 24 filtered
    taps over a penumbra sized by the distance to the blocker.
  - Tuning: `BL_PCSS_SOFT`, `BL_PCSS_MAX`, `BL_PCSS_SEARCH`; `BL_PCSS=show` shows the
    lookup's inputs.
- **Contact shadows.** Default on, `BL_CONTACT=0` turns them off. This is a half
  resolution pass after the ambient occlusion's depth.
  - Each pixel marches 16 steps towards the light that gives it the most, up to
    `BL_CONTACT_LENGTH` world units (default 12).
  - Only characters cast or receive them, so baked lightmap shadows are never darkened
    twice. Characters are marked in the reflection info: variant `skin` 2 marks them
    without the skin pass.
  - The result is filtered with the AO filter and multiplied in. `BL_CONTACT_STRENGTH`
    (default 0.5) sets how much it darkens; `BL_CONTACT=show` shows the result alone.
- `BL_SHADOWS_AB=n` flips the setting every n frames, for comparing pictures and timings
  within one run. `BL_GPU_STATS` lines now say which frame they end at.
- Fixed while testing: the atlas's depth surface could keep the old size for its first
  pass. Metal validation caught this as a scissor larger than the pass.

GPU time (`BL_GPU_STATS`, sm_asylum_1, Jeanette's dialog close-up, 1920x1080, M4 Pro,
mean of 100-frame windows, shadows switched every 200 frames in the same run):

| setting | ms a frame |
|---|---|
| shadows off | about 2.9–3.5 |
| atlas only (`BL_SHADOW_RES=1`, `BL_PCSS=0`, `BL_CONTACT=0`) | about 2.8–3.1 (no change) |
| 4x atlas plus PCSS, no contact | about 4.0–4.6 |
| everything on | about 5.0–6.0 |

The windows vary by up to 1 ms from run to run.

- Verified: Metal API validation is clean with shadows on from the start, and with the
  setting flipped off, on and off again. Headless captures of `sm_asylum_1` show the
  shadows working. Contact shadows are subtle: under the feet and where the arms meet
  the body.
- Not verified:
  - The options page with the 7th box. Its place, (224, 196) from "Combat effects", was
    not seen on screen.
  - Other levels and the look in motion.
  - With `BL_SSR` on and `BL_SSS` off, contact shadows mark characters in the
    reflection info, which keeps the cubemap on characters instead of screen-space
    reflections.
  - The cost of contact shadows in the close-up, about 1–1.5 ms, has not been
    optimized.

## 2026-10-25 — Rounder characters (GPU smoothing)

Character draws that get the detail maps (skin, clothes, hair) are now drawn as
tessellated patches. Each triangle is split 3 times per edge (`BL_TESS`, 0 off, at most
16), and the new points are pushed out onto the curve the corners' normals describe
(Phong tessellation, three quarters of the way). That rounds off the faceted chins,
cheeks and pigtails.

- The game's vertex shader is generated as a function (`bl_vs`) run on the three corners
  of each patch, then a `[[patch(triangle, 3)]]` main function works in view space with
  the projection the renderer already reads from the world view (`view_proj`, buffer 22).
  The normal is the same clip-space step the detail maps use.
- Only indexed triangle lists of up to 65536 triangles in the world view. The indices are
  copied as 32-bit with the base vertex added, since patch draws have none. The patch
  winding had to be counter-clockwise to keep the game's culling.
- Verified: headless `sm_asylum_1` close-up of Jeanette with Metal API validation, no
  errors and no cracks; the jaw, chin and pigtails are smoother.
- Not verified: the frame cost, other levels, crowds of characters, and whether the
  shadow casters (drawn untessellated) leave visible gaps in self-shadowing.

## 2026-10-25 — Hair: soft edges, strands, roots, back light

Shader-only work on characters' hair (alpha-tested, skinned, with no normal map of its
own), tried on Jeanette:

- Two passes (`BL_HAIR_SOFT`, default 0.75, 0 off): first solid where the texture's alpha
  is above 0.75, writing depth, then again blended where it is below, without writing
  depth. Thin strands and tips now fade out instead of being cut off. Indexed draws only.
- Strands (`BL_HAIR_STRANDS`, default 1): about 420 strands across the texture, each with
  its own brightness and a slightly turned normal. The shine breaks up into strands, and
  the pattern fades out where strands get smaller than a pixel.
- Roots (`BL_HAIR_ROOT`, default 1): up to 45% darker where hair lies within 3 units of
  the head or body, from the depth copy the soft blend already uses.
- Back light (`BL_HAIR_GLOW`, default 1): light from behind the hair shows through it in
  the hair's colour.
- Verified: headless `sm_asylum_1` close-up with Metal API validation, no errors. The
  pigtail tips are soft and the strand pattern shows.
- Not verified: the look in motion, other characters' hair, and whether the unsorted
  blended pass shows hair-behind-hair in the wrong order anywhere.

## 2026-10-25 — Hair redrawn as strips (Jeanette)

A character's hair can be replaced in the renderer by new hair strips made on the
player's machine from their own game files (`BL_HAIR_MESH`, default on; 0 off).

- **Files:** beside a hair texture's normal map path, `<name>_hair.bin` (strips:
  positions, normals, texture coordinates, indices, plus the game's hair vertices they
  were made from, as anchors) and `<name>_hair.png` (the strips' strand texture). A file
  with no strips instead lists the part of the game's texture to keep drawing (the red
  hair ties). `tex_detail.m` now remembers which listed texture each game texture
  matched, and loads these files (`bl_detail_hair`).
- **Drawing (`metal_render.m` `hair_swap_for`):** for an indexed triangle draw of a
  skinned texture with strips, each strip vertex becomes a copy of the game's nearest
  vertex in that draw (so it keeps the same bone indices and weights and follows the
  head), with the strip's position, normal and texture coordinates. The strips are placed
  by fitting the anchors onto the draw's vertices: one of the 48 axis turns and flips,
  then scale and offset refined against nearest vertices. On Jeanette the fit is exact
  (scale 52.49 from the tools' metres to model units). The game's hair is drawn first as
  a base, then the strips alpha-tested and blended as hair, on both sides, untessellated.
- **Removed:** the strands grown on hair at draw time (`BL_STRANDS`, the quad-patch
  `strand_main`); they drew nothing useful.
- **Made by:** scratch Blender/Python scripts so far (SourceIO import, strands traced and
  combed over her hair surfaces, round pigtail bunches, strips from guide strands). Not
  yet a tool in `tools/`.
- Verified: headless `sm_asylum_1` close-up: 70100 strip vertices placed with a 0.0%
  fit error; the pigtails draw as round bunches in the right place; of the eight pigtail
  draws only the hair ties' 56 triangles remain.
- Not verified: the top of her head (out of the close-up's frame), the look in motion,
  frame cost, Metal API validation, other characters. The right pigtail is too bright.
- Later the same day: the first strips (one thin strip per traced strand, about 8,700)
  looked noisy and broken in game, so they were replaced. The new ones come from Daniel
  Bystedt's free Blender Geometry Nodes setup "hair cards from curves" (the player's own
  download; it works in Blender 5.3, its inputs set through
  `modifier.properties.inputs.<id>.value`). Her traced strands are clumped by k-means
  into 390 guide curves (top 170, fringe 50, pigtails 170), each becoming one card about
  2.4 cm wide. The cards lie on the top shell or on a round tube per pigtail, and carry a
  new 2048x2048 clump texture: four variants; the top's fade in and out softly so the
  overlapping rows show no edges, and the pigtails' start solid at the tie. 9,360
  vertices, 8,580 triangles. The renderer no longer adds the hair shader's strand pattern
  on such strips, since the texture has its own strands.
- Verified (new cards): headless `sm_asylum_1` close-up, placed with a 0.0% fit error,
  smooth round pigtails, no noise in the still frame.
- Not verified (new cards): in motion, other angles in game, frame cost, other characters.
- The fringe too (same day): the game's own fringe locks were still drawn under the cards
  as part of the base, and hung in front of the new ones. The strip file may now end with
  a list of the game's triangles to keep under the strips (their centres in the anchors'
  space, placed by the same fit); for Jeanette, the 196 triangles of her scalp, so her
  locks are no longer drawn. The new fringe cards run straight down those locks (lines
  of equal u in their texture on the big front piece; along their own long axis on the
  two small centre locks). The strips' soft edge near the skin is now 0.15 of the game
  hair's (`BL_HAIR_FADE`), since the fringe lies close to the forehead and faded away.
- Verified (fringe): headless close-up, 196 of 390 hair_1 triangles kept, the fringe drawn
  as new locks in the same style as the rest.
- After a window check (fringe stuck out like a visor; black dots and lines in the hair):
  the clump texture's colour had been left multiplied by its cover, so every hair had a
  dark edge where see-through (now divided out); the fringe guides' upper halves are
  brought down onto the scalp, since the game's lock piece curls forward at the
  hairline; and hair's smooth normal now faces the camera like its triangle normal
  (`d3d9_shader.c`), so the back of a two-sided card is not lit as facing away.
- Verified: Blender render (no visor, no dark edges); headless close-up, pigtails clean.
  Not verified: the fringe in game (out of the close-up's frame this run).
- The user's window check still showed black dots and lines: the dark room showing
  through gaps between the pigtail cards. Each pigtail now has a solid core under its
  cards (a smooth tube, 0.8 of the bunch's radius and three quarters of its length,
  textured with the dense roots of the pigtail texture), as the scalp is under the top,
  and the pigtail texture variants have about twice the hairs. 10,290 vertices.
- Verified: headless, frames 1300 and 1500 (the latter frames her whole head): solid
  pigtails with nothing showing through, the fringe falling from the scalp.
- The user's next window check: black specks still in the hair, the fringe looking
  pasted on with the outline of her head showing, and "not how it is in game". My
  headless runs had been forcing effects on and off (`BL_AO=0 BL_SSR=0 BL_SHARPEN=1 ...`)
  and a scratch data directory; the player's runs take the options from their own
  registry (all effects on except HDR). Captured again with nothing forced.
- Black specks: switching one effect off at a time and counting hair pixels much darker
  than their neighbourhood (frame 1500, per 1000 hair pixels): 3.5 with everything on,
  1.0 with only sharpening off, 4.7 to 6.6 with each other effect off alone (their
  poses differ, so those vary). The sharpening (contrast adaptive) darkens the gaps
  beside each fine bright strand. Hair (pixels shaded by ps_detail with `hair`) now
  marks its reflection info -1.4 instead of -1.25, still inside the skin range for skin
  scattering and contact shadows and below the sheen's -1.1; post_apply skips
  sharpening on such pixels and their four neighbours (`metal_render.m`). 1.6 after,
  with sharpening on; the game's own hair was 2.9.
- Fringe: drawn over the game's own fringe locks again, with the scalp (all 390 hair_1
  triangles kept under the strips), so nothing see-through and no edge of the scalp
  shows between the new locks. The base is drawn with a depth bias (64 units, slope 2)
  so the strips lying on it win.
- Verified: headless with the player's settings, frame 1500: fringe solid and joined to
  the top, no head outline, specks 1.5 per 1000. Not verified: a window run by the user.
- The user's next window check: with skin scattering off the new hair was a black blocky
  mess, and with it on the black dots and lines were still in the pigtails.
  - Skin scattering off: the strips only got their own texture and hair shading on the
    character path (variant skin 1), which only skin scattering turned on, so they were
    drawn with the game's hair texture. Strip draws now take that path whenever the
    reflection info is drawn, and always bind their own texture (`metal_render.m`).
  - The dots: the pigtail cores were textured from the pigtail slot's roots, 30 to 65%
    see-through, so the room showed through them. They now use an opaque strip of hair
    between slots 2 and 3 of the texture (pixels 1524-1547, which no card reaches; made
    by the scratch tool core_strip.py). What was left was the hair's blended second pass:
    with thousands of layered cards drawn in no order, it shows the dark behind as
    specks (gone with `BL_HAIR_SOFT=0`, unchanged with MSAA or the edge smoothing off).
    Strips now draw in one alpha-tested pass with alpha to coverage (`hair_soft_on`);
    the game's own hair keeps both passes.
  - The export script now keeps all 390 hair_1 triangles under the cards (as installed).
- Verified: headless with the player's settings, skin scattering on and off, frame 1500:
  pigtails solid without specks. With skin scattering off the fringe's edges are harder
  (the game's locks underneath are drawn plain then, as before this work).
- Seen by the user, not looked at yet: with skin scattering on, the barman goes dark
  when the camera moves, and back to normal from the side.
- The user saw patches of a different colour round Jeanette's neck as she moved: the
  contact shadows (`BL_CONTACT=show`). Two causes, both fixed in `contact_main`:
  the light each pixel steps toward was weighted by how the surface faces it, with a
  normal taken from the depth, so on the low-poly collar each flat face picked its own
  light; and the first steps hit the next face of the same fold. The light is now chosen
  by brightness alone, and hits within `1 + 0.004 * w` units of the start are skipped.
  Hair (info -1.4) still casts contact shadows but no longer takes them.
- Verified: headless, `BL_CONTACT=show`: the neck and collar shade smoothly, no facets.

## 2026-10-25: hair, collar and contact shadows with MetalFX TAA

- TAA is still opt-in in this tree (`BL_TAA=1`); earlier checks were all MSAA.
- Under TAA the contact shadows' step offset now changes each frame (the params' `pad`
  carries `frames % 16`), so the scaler averages their grain out instead of keeping it.
- Verified: headless with the player's settings plus `BL_TAA=1`, frame 1500, 100 of 100
  frames through the scaler, 390 hair triangles kept: hair specks 0.58 per 1000 (1.31
  with MSAA); hair tips and pigtail edges finer, collar smooth, contact shadows smooth.
- Not verified: moving shots. Skinned characters get no motion vectors, so the scaler
  may smear moving hair; a window run by the user is the check.

## 2026-10-25: characters going dark up close with skin scattering

- The user: walking up to a character (the barman in the asylum) darkens them; stepping
  to the side brings them back. Headless walk-up captures (frame 850, `BL_TAA=1`, one
  effect off at a time): only `BL_SSS=0` brings him back; shadows, contact shadows and
  ambient occlusion off do not.
- First fix tried: the characters' light (ps_detail, the skin's shine, contact shadows)
  now takes the lights as bright as they are in that part of the map (`bl_light.seen`,
  `char_lights`), not dimmed to 0.3 where a fitting hides them from the camera, and all
  24 of the frame's lights instead of the first 8 (`detail_bind`; its settings moved to
  bl_dl[2] and [3]).
- Verified: built, and one headless run: the barman is still dark at frame 850. So that
  was not the cause, or not all of it. Next suspect: the 24 lights are still the
  brightest at the camera (the map has 72), so walking up changes which ones light him;
  `BL_CHARLIGHT=0` would show whether the light with a direction is what darkens him.
- Verified (one headless run, frame 850, `BL_CHARLIGHT=0`): with the light with a
  direction off, the barman looks as he does with skin scattering off. That part of
  ps_detail is what darkens him: lit by lights behind him, his front is turned to 0.35
  to 0.5 of the game's light.
- Fix: the light with a direction now takes every light the frame has for this part of
  the map (up to 64, `CHAR_LIGHTS`, uploaded per draw because that is over
  setFragmentBytes' 4 KB), so each pixel uses what reaches it, wherever the camera is;
  the haze, the skin's shine and contact shadows keep the first 24. And the side away
  from the lights is darkened to no less than `BL_CHARLIGHT_MIN` of the game's light
  (default 0.8, was 0.35), passed in bl_dl[3].y.
- Verified: one headless run, frame 850 (`BL_TAA=1`, the player's settings): the barman
  lit as with skin scattering off, with a little more shape; frame 820, further away,
  unchanged. Not verified: other characters and maps, a window run by the user, and the
  cost of up to 64 lights per character pixel (not measured).

## 2026-10-25: props smoothed (BL_PROP_TESS)

- Props had faceted round shapes (the asylum's bar tables, 12-sided). The characters'
  GPU smoothing (Phong tessellation) can't simply be turned on for them: their round
  shapes end in sharp rims, where corners share a position but not a normal, and plain
  Phong opens gaps there or, turned off at those corners, leaves the rim faceted.
- New `prop_smooth.c`: once per mesh on the CPU, each triangle split into BL_TESS^2 and
  its points moved three quarters of the way onto Phong's curve, with each corner's
  point projected onto every surface meeting there (an orthonormal basis of the
  normals at that position, clustered within about 25 degrees). It is the same from
  either side of an edge, so there are no gaps, a rim curves along its length and stays
  sharp, and a box stays a box. All vertex elements are interpolated (blend indices
  and packed normals taken from the nearest corner), and the game's shaders draw the
  result. `metal_render.m` `prop_swap_for`: world-view draws to the back buffer whose
  vertex shader reads no bone weights, with no lightmap coordinates (the map itself),
  static vertex buffers, 8 to 20,000 triangles; skipped where nothing moves more than a
  thousandth of a triangle; at most 768 MB in all.
- Verified: one headless run, sm_asylum_1 frame 780 (`BL_TAA=1`): 16 props smoothed
  (7 MB), the bar stools' seats and bases rounder, with no gaps or other faults seen.
  Then the user's own window run: the round bar tables up close, smooth with no gaps.
  Not verified: other maps, the time it adds at map load, and frame rate.

## 2026-10-26: ambient occlusion with XeGTAO's depth copies and visibility bitmasks

- The AO was plain GTAO (2 slices of 4 steps a side, one horizon each way), which left
  grainy dark fuzz around thin parts (Jeanette's collar and neck) and dark halos behind
  them. Two changes in `metal_render.m`, both from published methods:
  1. XeGTAO's depth pyramid: 4 smaller copies of the half-resolution view depth
     (`ao_mip`, `ao_occlusion`), each pixel a weighted average of 4 that leans to the
     farthest. Steps longer than 2^3.3 pixels read the smaller copies, so they land on
     steady values. Now 3 slices of 6 steps a side.
  2. Visibility bitmasks (Therrien, Levesque and Gilet 2023) in place of the two
     horizons: each slice's half circle is 32 sectors, cosine weighted, and each sample
     is taken to be `BL_AO_THICKNESS` world units deep (default 16), so light gets in
     behind thin things.
- Fixed on the way: the result is divided by the slices' total weight, so surfaces
  facing away from the camera come out fully unshaded (before, low-poly faces showed).
- Verified: headless runs of the Jeanette dialogue (sm_asylum_1, frame 1500), AO alone
  and in game, against the old AO: no grain at the collar, no halos, no facets. Then the
  user's own window run: approved. Not verified: other maps, and the cost (timing runs
  were shared with other GPU work).

## 2026-10-26: bloom and eye adaptation (BL_BLOOM, BL_EXPOSURE); sharpening removed

- Bloom without HDR (the HDR path is broken for now): after the post effects, a bright
  pass on the SDR colour (threshold 0.6, soft knee, weighted by 1/(1 + brightness) so
  single bright pixels don't flicker), six levels of downsampling and a tent upsample
  back to half size, added to the picture at strength 0.35. `BL_BLOOM=0|1|show`,
  `BL_BLOOM_STRENGTH`, `BL_BLOOM_THRESHOLD`.
- Eye adaptation: a compute pass takes the geometric mean brightness of 64x36 points of
  the picture, weighted towards the centre, and aims the exposure at
  (0.095 / mean)^0.4, held between 0.8 and 1.3, easing there over about half a second
  (and jumping straight there after a pause, such as a load). The value stays on the GPU.
  Without tone mapping a soft shoulder keeps the brightened picture from clipping.
  `BL_EXPOSURE=0|1|show`, `BL_EXPOSURE_RANGE`. `BL_BLOOM_AT=n` (debugging) turns both on
  from frame n.
- A first test run hung at start-up: the exposure log in `d3d_render_present` asked for
  its buffer before the Metal device existed. It now waits for the device.
- Verified: headless sm_asylum_1 bar entrance, frames 780 (off) and 900 (on) of one run:
  exposure 1.14 (picture brightness 0.068), the green neon under the counter glows softly
  onto the panel and stool tops, mean picture level 21.8 to 24.5 of 255. Then the user's
  own window run: the exposure went from 0.80 to 1.18 between lit areas, the bar and the
  streets, as meant. Not verified: frame rate.
- Bloom and eye adaptation are now check boxes on the Visual options tab ("Bloom" and
  "Eye Adaptation", below "Shadows" in the right-hand column, `bl_vgui.c`), saved in the
  registry like the other effects (values `Bloom`, `EyeAdaptation`). Unlike the others
  they are on until unticked. `BL_BLOOM` and `BL_EXPOSURE`, when set, still win over the
  boxes. Built; not yet seen in a window.
- Sharpening (`BL_SHARPEN`, its check box and the pass in post_apply) is removed. That
  was another session's change; it goes in with these because the effect list, the
  check boxes and post_apply are built on it.
