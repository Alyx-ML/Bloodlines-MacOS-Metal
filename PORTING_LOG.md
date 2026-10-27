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

## 2026-10-26: baked light read smoothly (BL_LIGHTMAP_SMOOTH); prop smoothing off

- Prop smoothing (`BL_PROP_TESS`) is now off by default: in the user's own play it spoiled
  the textures of many props. A per-model approach made offline (Blender) and checked by
  eye is the proposed replacement; nothing of it is built yet.
- The map's lightmaps sit in shared pages, each surface's rectangle packed edge to edge
  (sm_asylum_1: one 512x256 page). Bilinear filtering shows their low resolution as
  blocks and steps. `metal_render.m` `lightmap_for` finds the draws that read a page (a
  one-level 32-bit texture sampled with TEXCOORD1 as it is, which
  `d3d_shader_sample_coord` and `d3d_shader_lightmap_coord` check in the shaders' bytecode),
  joins the triangles that share lightmap coordinates into surfaces, and notes each
  surface's rectangle on every texel of it in an RGBA16Uint texture the page's size (once
  per vertex and index range). The shaders' reads of the page become `bl_lightmap`
  (d3d9_shader.c): Catmull-Rom over 4x4 texels, clamped to the four nearest so it does not
  ring, every read kept inside the surface's rectangle. A first try with a cubic B-spline
  blurred away small shadows (the bar stools' on the counter front) and was replaced.
- `BL_LIGHTMAP_SMOOTH_AT=n` (debugging) turns it on from frame n, for a before and after
  in one run.
- Verified: headless sm_asylum_1, frames 780 (off) and 840 (on) of one run: 3,333
  surfaces on the page, 97 texels claimed by two (read bilinear); the counter front's
  shadows keep their depth with smoother edges; the floor barely changes (its glow is
  mostly reflection).
- Bump-mapped surfaces read three copies of their lightmap, one per bump direction, side
  by side on the page after the flat one: their vertex shaders add TEXCOORD2, the step to
  the next copy, scaled by a constant, to TEXCOORD1 (`d3d_shader_lightmap_coord` checks
  this pattern). Their rectangles are noted for all four copies, and every sampler of the
  draw that reads the page is smoothed. `BL_DRAW_DUMP=lightmap` dumps, and the log names
  once per pair of shaders, any draw still reading a known page plain.
- Verified: headless sm_asylum_1, frames 780 (off) and 840 (on) of one run: no draw read
  the page plain after the switch; the bump-mapped frieze above the bar is smoother with
  no seams or wrong colours. Not verified: other maps, a window run, frame rate.
- The smoother lightmaps kept reading surfaces again: in a long window run the surface
  count climbed from about 9,000 to 382,000, more than the page has texels. Two causes in
  `lightmap_for`. Some world geometry is drawn from dynamic buffers that are filled
  somewhere new each frame, so a key made of the buffer, the range and a sample of its
  indices was new every time. And the key's padding was never cleared, so equal keys
  could still compare unequal. Ranges of static buffers keep the old key, now with its
  padding cleared. Ranges of dynamic buffers are keyed by a hash of the lightmap
  coordinates read from them. A page's set of known draws is emptied if it ever reaches
  65,536; reading a draw again does no harm. A surface now counts only when it notes a
  texel nothing noted before, and the log adds how many draws were read.
- Built; not run. A window run's log should show the surfaces and draws-read counts
  levelling off once the map has been looked around.

## 2026-10-26: hair under-layer lifted

- Jeanette's hair cards sit over the game's own hair triangles, whose texture
  (`jeanette_hair_1`) is much darker than the cards (mean colour about 67,52,36 against
  180,143,105). Where the cards thin out, that dark core showed through as black streaks.
  `tex_detail.m` `hair_base_color` now makes a copy of the base texture in which texels
  darker than 0.8 of the cards' mean colour are lifted up to it (keeping a little of
  their own variation); lighter texels, such as the fringe locks, are left as they are.
  The renderer draws the base triangles with that copy. A first try that scaled the whole
  texture turned the fringe almost white and was replaced.
- Verified: headless sm_asylum_1, Jeanette close up: 80% of the base texture's texels
  lifted; fewer black streaks at the pigtail ends, fringe unchanged. The dark-speck count
  is not a reliable measure here (her pose differs between runs). Not verified: a window
  run.

## 2026-10-26: bounced light (BL_SSIL), ported from Godot's SSIL

- Light bounced off what is on screen onto what is near it, for colour the lightmaps
  cannot carry: the bar's green neon on the floor and stools, club lights on walls and
  people. A port of Godot 4.4's screen-space indirect lighting (Intel's ASSAO turned into
  indirect light) with kubaofc123's changes (github.com/kubaofc123/
  godot-feature-updated_screen_space_shaders: twice the taps, interleaved gradient noise,
  a smaller sampling disk). MIT; the notices are in `metal_render.m`'s bounced light
  section.
- Godot's high preset: 12 taps of two samples, the longer ones reading the AO's smaller
  depth copies (now made once a frame for both, `ao_depth_copies`), depth edges, haloing
  reduction, and two edge-aware blur passes after.
- Differences from Godot: half resolution on the AO's view depth instead of four
  deinterleaved layers (each pixel takes its layer's sample pattern); normals rebuilt from
  that depth; this frame's world view as the colour (a half-resolution copy, mipmapped,
  read at Godot's 1/32 level) rather than last frame's reprojected; no adaptive pass.
  Godot multiplies the result by each surface's albedo, which the game's shaders do not
  give, so `post_apply` uses the pixel's own hue at half brightness in its place.
- "Bounced Light" check box on the Visual tab, under "Eye Adaptation", on until unticked
  (registry value `BouncedLight`). `BL_SSIL=0|1|show` wins over it; `BL_SSIL_RADIUS`
  (128 world units), `BL_SSIL_STRENGTH`, `BL_SSIL_BLUR` (2).
- Verified: it builds, and the shaders compile offline with `xcrun metal`. Not verified:
  how it looks, its strength, its cost, the check box's place on the page.
- The user's window run, on and off in the bar: the change was hard to see (a little
  warmth on the red walls and floor). The strength is now 1 (was 0.5), and under TAA the
  noise pattern turns each frame (interleaved gradient noise offset by the frame, as in
  Jimenez 2014) and the result is blended with last frame's along the camera's motion
  vectors, kept within its 3x3 neighbourhood's range (`ssil_history`), so it is steadier.
  Built and the shaders compile; not yet seen.
- The user's next window run (the alcove by the bar, on and off): the bounce showed, but
  as an even lift of the whole alcove (red walls lighting each other, green from the
  floor), with little spill from the neon. Two changes: each sample reads the colour copy
  at a level that grows with its distance, as the depth does (level 1 for the nearest, up
  to Godot's 1/32 of the screen for the farthest), so thin neon strips are not averaged
  away; and only light brighter than what the receiving pixel already has bounces
  (per channel, against the colour copy at the pixel), because the lightmaps already hold
  the bounce between the map's surfaces. Built and the shaders compile; not yet seen.
- Two more, at the user's request. Cleaner edges: the half-resolution result is brought to
  full resolution in its own pass (`ssil_upscale`), each of the four half-resolution
  pixels around weighted by how close its view depth is to the full-resolution pixel's
  (from the depth buffer), or the closest one where none is close, so a wall's bounce no
  longer leaks onto the outline of a character in front. More than one bounce: last
  frame's half-resolution result is added into the colour copy at half strength, tinted
  as post_apply tints it and moved along the TAA motion vectors when TAA is on, so light
  bounces on from what it lit and reaches round corners; each further bounce is halved
  again, so it cannot build up. Skipped on a camera cut. Built and the shaders compile;
  not yet seen.
- The real surface colour, at the user's request, in place of the hue guessed from the
  lit colour. With bounced light on, the world view's passes on the back buffer get a
  third colour attachment (`albedo_texture`, RGBA8, cleared to 0 with the frame), and
  every draw there that replaces the colour writes its surface's colour into it
  (`d3d_shader_variant albedo`): for game shaders, the first plain 2D texture the shader
  reads (lightmaps, shadow-atlas reads and cubemaps left out), sampled again at the same
  coordinate after the body; for the fixed-function stages, stage 0's 2D texture; mid
  grey for shaders that read none. Draws that blend keep what is there, like the
  reflection info. post_apply multiplies the bounced light by it, and the second bounce
  is tinted by it too. `BL_SSIL=albedo` shows it. `tests/shader_test` gained an
  info/albedo variant: 5388 compiled, 0 failed over the dumped shaders. Runtime built;
  not yet seen in the game.

## 2026-10-26: lighting rebake, step 1: reading the maps' surfaces

The plan: bake each map's lightmaps again on the GPU when it loads (sharper shadows, more
luxels, several bounces, cached to disk), in place of the 2004 ones. Step 1 only reads
what that needs; nothing is baked or drawn differently yet.

- `bl_bsp.c` gains `bl_bsp_world_load`: from the map's .bsp (the player's own file, read
  when the game opens it, as the volumetric light's lights already were) the vertices,
  each face's corners (surfedges and edges), plane, texinfo (texture and lightmap axes,
  flags), owning model, light styles, lightmap corner and size and its offset in the
  lighting lump; the texture names and reflectivity (the mean colours the map compiler
  bounced light with); every world light (point, spot, glowing surfaces, sun, sky); and
  the lighting lump itself.
- Bloodlines' VBSP 17 faces are 104 bytes: Half-Life 2's fields plus eight light styles
  and eight day and eight night bytes, and a mean colour per style. Found by the face
  lump's size (3193 x 104 in sm_asylum_1) and confirmed by the lightmaps: every lit
  face's samples, (w + 1) x (h + 1) x styles, x 4 for bump-mapped faces, tile the
  lighting lump exactly.
- Two layouts: the maps the Unofficial Patch compiled again (27 of 209) hold each face's
  mean colour per style just before its samples, as Half-Life 2's do; the original maps
  do not. The reader tells them apart by which one fills the lump exactly
  (`world->means`).
- `bl_bsp_world_check`, also run at each map's load ("[bsp] ..." in the log), and
  `tests/bsp_check`: each face's samples inside the lump, none overlapping, and every
  corner's lightmap coordinate inside its lightmap. All 209 maps (101 original, 108 from
  the Unofficial Patch) as expected; sm_asylum_1 has 3193 faces, 2991 lit and all
  bump-mapped, and 448 lights (25 point, 47 spot, 376 glowing surfaces). No corner
  falls outside its lightmap on any map.
- Not read yet: displacements (8848 faces over all maps, the outdoor terrain), whose
  lightmaps follow their grid; their lumps come with the bake. Not run in the game yet:
  the runtime builds with the load-time check in it.

## 2026-10-26: lighting rebake, step 2: the asylum baked on the GPU

The first bake, outside the game: `runtime/d3d9/lm_bake.m` bakes a map's lightmaps again
from its own lights and surfaces, and `tests/bake_view` compares them with the 2004 ones.
Nothing in the game uses it yet (step 3).

- Four times the luxels along each side (16 times as many), each placed on its face and
  pulled inside the face's outline where the lightmap's grid runs past its edge.
- Direct light as vrad works it out (point, spot and glowing-surface falloff, sun and sky
  only where a ray reaches a sky face), for the flat light and the three bump directions.
  Shadows are ray-traced with Metal's ray tracing (M1 runs it without hardware for it):
  16 rays per light to points over a ball 6 units across, so shadow edges fade over a
  few luxels instead of stepping.
- Three bounces: 512 cosine-weighted rays per luxel read the light where they land from
  the pass before, times that texture's reflectivity; each bounce is blurred within its
  face over about one of the map's own luxels, which takes away the rays' speckle.
- The occluders are the world's faces (not see-through ones or brush entities, as vrad
  leaves them out). Brush entities' faces (doors, drapery, grates) are in their model's
  own space: they are now placed at their entity's origin from the entity lump; before
  that a quarter of the faces came out black.
- A face's normal is its plane's as stored; the side byte belongs to the BSP node, and
  flipping by it had turned ceilings to face up.
- sm_asylum_1: 697,727 luxels, 5,677 occluding triangles, 440 lights, 3 bounces in
  1.1 s on the M4 Pro. Against the 2004 lightmaps: 1.33 times as bright over the map by
  area; per face a median of 1.12, quartiles 0.94 to 1.50.
- `bake_view` draws six views with the texture's mean colour times the light (no
  textures, normal maps or models), the old and new with the same exposure, into
  `build/bake/`. The new: sharp spotlight pools on the bar top and floor, the light
  fittings' pools on the walls, and shadows where the old had a smooth wash.
- Not done: shadows from props (their models are in the game's archives), displacements,
  and lights with a style (switching or flickering ones; style 0 only). Not run in the game.
- Why the new bake is brighter (measured, not fixed): next to the lights the direct light
  matches the old to within 0.8 to 1.2 times, so the falloff is right. The extra light is
  where the 2004 bake had props in the way: static props cast shadows in it (their
  collision models, .phy; flag 0x10 turns it off). In Jeanette's room a painting on the
  wall leaves a sharp-edged dark patch where the art light behind the stage_light model
  aims; the new bake lights the whole wall. 84 of the map's 440 lights sit within 32
  units of a prop; faces those lights mostly light come out 1.42 times as bright, the
  rest 1.19 (furniture also blocks bounced light). 33 of the map's 45 prop models cast
  shadows, 26 of them with a .phy in the game's archives (the old IVP format, no "VPHY"
  header). A flat scale-down would darken the places that already match.

## 2026-10-26: lighting rebake: prop shadows

- `runtime/bl_props.c`: the map's static props (game lump "sprp", version 4, 56 bytes a
  prop), each one that casts shadows (flag 0x10 clear) placed with its collision model.
  The .phy comes from the player's files: the mod's folder, then Vampire's, loose files
  before pack*.vpk (Bloodlines' archives: the directory at the end, its count and offset
  in the last 9 bytes). The .phy is the old IVP format: a 16-byte header, then per solid
  its size and a compact surface ("IVPS" at 44, the ledge tree's offset at 32); the tree's
  leaves are convex ledges, triangles over 16-byte points in metres with Havok's Y and Z
  swapped and Y negated. Placed with Half-Life's AngleMatrix.
- Checked against the old bake: the painting in Jeanette's room comes out 192 tall and 140
  wide, 2.4 units off the wall, and its edges land within two units of the sharp dark
  patch the 2004 lightmap has there.
- The bake adds them to the ray tracing as one more unlit face: they block direct and
  bounced light and give none back. sm_asylum_1: 103 props, 80 casting shadows, 36 of
  those with a collision model, 996 triangles; the bake takes 1.0 s.
- Brightness against the 2004 lightmaps: 1.15 over the map by area (was 1.33), direct
  light alone 1.00; per face a median of 1.10, quartiles 0.94 to 1.47.
- What is left, measured per light on luxels one light mostly lights: point lights come
  out at 0.86 to 1.17 of the formula in the old bake; spot lights inside light fittings
  that have no collision model are dimmer there (the bar's ceiling lights about 0.55, the
  stage light in Jeanette's room close to 0). So vrad shaded those lights with the
  fittings' visible meshes; the new bake lets them through. Their models are Bloodlines'
  own .mdl version (2531, vertices in the .mdl, strips in the .dx80.vtx), not read yet.

## 2026-10-26: lighting rebake: props without a collision model

- `bl_props.c` now also reads Bloodlines' own models: .mdl version 2531 (names 128 bytes,
  the vertices inside the .mdl in one of three formats: 44 bytes with float positions,
  or 12 or 8 bytes with positions as 16-bit steps from the model's minimum) and
  .dx80.vtx version 107 (Half-Life 2's layout but for 20-byte strip groups: a table of
  16-bit vertex numbers and triangle lists). Checked: the painting's mesh has the same
  bounds as its .phy and its .mdl hull; the stage light's mesh is 37 x 28 x 36 units
  round its spot light.
- The meshes alone did not match the 2004 bake: the stage light is open at its lens, so
  its spot still lit the wall at three times the old brightness. Five rules were baked and
  compared with the old lightmaps; the one that matches: box props (solid type 3) cast
  their model's box (the hull at 0xb4 and 0xc0 in the .mdl), which closes the stage light
  round its spot; others cast their .phy, and props with no .phy their visible mesh (the
  bar tables, which bring the floor round them closer to the old). sm_asylum_1: 80 props
  casting shadows, 34 as boxes, 35 by collision model, 11 by mesh; 3422 triangles.
- The soft shadows' sample points round each light are now the same for every luxel (seeded
  by the light), where they were drawn per luxel: lights at the edge of a prop's box had
  left the walls speckled.
- Brightness against the 2004 lightmaps: 1.07 over the map by area (1.15 with collision
  models only, 1.33 with no props); direct light alone 0.93; per face a median of 1.07,
  quartiles 0.92 to 1.44. The walls round the painting: 0.044 and 0.060 against the old
  0.030 and 0.037 (were 0.094 and 0.119). The bake takes 1.0 s.
- Still brighter than the old, not explained: the bar's ceiling lights' spots (about half
  as bright in the old). Their fittings are thin discs above the lights, so neither box
  nor mesh shades them.

## 2026-10-26: lighting rebake, step 3: the rebake in the game ("Rebaked Lighting")

- New Visual option "Rebaked Lighting" (BL_REBAKE, registry RebakedLighting, off by
  default), the tenth box, under "Bounced Light".
- The bake's grid now lines up with the game's lightmaps: (size + 1) x 4 luxels a side,
  luxel x at lightmap s = mins + (x + 0.5) / 4 - 0.5, so each of the game's texels holds 4 x 4
  of the bake's exactly (before: size x 4 + 1, corner to corner). sm_asylum_1: 982,640
  luxels, 1.4 s; 1.05 times as bright as the 2004 lightmaps by area (was 1.07).
- `bl_bsp` hands each map it reads over to the rebake (`bl_rebake_note_map`) instead of
  freeing it; the renderer's first lightmapped draw with the option on starts the bake on
  a thread of its own (`bl_rebake_get`), and a bake for a map no longer open is dropped.
- The renderer (metal_render.m, "the lighting rebake in the game"): each surface it finds
  on a lightmap page is noted with three corners (position and lightmap coordinates) and
  matched to the map face with those corners whose lightmap, placed where the coordinates
  say, starts on a whole texel. The face's bake goes into a page 4 times the size
  (RGBA16Float), its rectangle is marked in a copy of the rectangles texture (x0 + 0x8000),
  and the shader reads the big page there with the same cubic (`bl_lightmap_rebaked`).
- The game's pages hold the light encoded (gamma, overbright). The encoding is learnt
  from the pages: the map's own samples against the bytes the game wrote for them, the
  mean linear light per byte and channel, from the first 4000 samples matched; the bake is
  encoded back through it, between bytes where it falls between.
- Left as the game has them: faces with a light style (switching and flickering lights),
  displacements, and what dynamic lights add to the page. Needs the smooth lightmaps
  (BL_LIGHTMAP_SMOOTH, on by default).
- Verified: the runtime builds and links; `shader_test` compiles all 898 dumped shaders in
  the lightmap and the rebake variants (7184 compiles, none failed). Not verified yet: the
  matching, the encoding and the look in the game (the user's test). The log says
  "[metal] rebake: the lightmaps' encoding learnt ..." and, every 300 frames, faces filled
  and surfaces matched to none.
- Fixes after the first test in the game (the user saw no change):
  - The option box sat below the page's bottom edge; the right-hand column now starts one
    row higher.
  - No surface matched: every asylum face has the bump directions' samples, but the page
    holds their copies only for bump-mapped materials, and the match asked for them.
    Now 547 faces match in the first view, 7 surfaces match none (their corners are on no
    face).
  - The asylum came out magenta where it is green: the game adds dynamic light (the green
    neon) to its page as it runs, which the map's samples do not hold (mean bytes red,
    green, blue 20.5 21.3 10.5 on the page against 14.2 10.2 7.8 from the samples). The
    rebake now goes in as a change: the page as the game has it, plus the bake encoded,
    less the old samples encoded (a second texture at [[texture(17)]], the page's size), so
    the dynamic light stays and the encoding's errors cancel. Each byte's light is now the
    upper quarter of what is seen with it (dynamic light makes some texels brighter than
    their samples), learnt only from texels the game did not scale down.
- Verified: headless sm_asylum_1, frame 950 of one run each with BL_REBAKE=0 and 1
  (build/bake/game/off_950.png, on5_950.png): the green neon stays, the counter front
  shows the rebake's pools of light between the stools. But the user found it looks
  awful: the floor and the counter front are blotched orange, green and purple where the
  old light is an even green.
- Why, measured against the 2004 lightmaps on the asylum's bump-mapped faces (56,868
  luxels, the bake taken down to the game's size): each of the four sets is closest to
  its own (so the bump directions are right), but they differ by 0.057 a luxel on a mean
  of 0.124 (about half). More bounce rays (4096) or a wider blur change nothing, and the
  direct light alone differs as much: the difference is in the direct light's shadows,
  not noise. So the bake is not yet close enough to the old one, luxel by luxel, to swap
  in; area-wide brightness (1.05) hid it. Debugging: BL_BAKE_RAYS, BL_BAKE_BLUR.
- Shelved (the user's call): the "Rebaked Lighting" box is gone from the Visual tab and
  the registry value is no longer read; the rebake runs only with BL_REBAKE=1, for working
  on it. Off, nothing of it runs in the game: no bake starts and the lightmaps are read
  as before. What it would need: the bake's direct light matched to vrad's light by light
  and luxel by luxel (shadows above all), before it goes into the game again.

## 2026-10-26: global illumination from light probes ("Global Illumination")

- Rendered, not ray traced (M1 is the baseline): runtime/d3d9/gi_probes.m. When the game
  opens a map, bl_bsp hands its surfaces over (bl_map_note, which also tells the shelved
  rebake the path); on the first frame after, a thread captures probes: a grid 64 units
  apart, a probe wherever the map is open (BSP leaf not solid, in a cluster) with a floor
  within 160 units below, so only where models go. Each probe is six 16 x 16 views of the
  map (its lightmaps on each texture's mean colour, glowing surfaces at their surface
  lights' radiance, the sky at its ambient light's), drawn 341 probes per instanced draw
  into the layers of one texture; a compute pass sums each probe's views per axis
  direction into an ambient cube (and, kept for later, the map's point and spot lights
  it can see). Probes that see much back face (inside a wall) are dropped.
- Timing (tests/gi_view.m, M4 Pro): asylum 311 probes 0.07 s; Chinatown hub 9,477 1.0 s;
  Hollywood hub 20,414 2.0 s; Santa Monica hub 23,207 2.7 s; downtown hub 16,293 3.4 s.
  No cache needed; until a map's probes are ready its models keep the game's light.
- Use (metal_render.m gi_light): the game lights models from the ambient cube in c21..c26
  (640 of the 860 vertex shaders seen read it; the shader parser now records the constants
  each shader reads). Its same-from-every-side part (the per-channel minimum over the six
  sides: the lightmap under the model) is swapped for the probes' light at the model's
  place (c48..c50 w: the model's or its first bone's), at the same mean brightness, so
  each side takes the colour and share of the light from that way; the lights the game
  folded into the cube stay. BL_GI, BL_GI_MIX, BL_GI_LOG; a tenth box on the Visual tab
  (the column moved up a row). Not yet: static props and displacements in the captures.
- Verified: builds; captures on five maps as above. Not yet seen in the game.
- Stronger (the user's ask: the first version did not show): the whole cube now comes from
  the probes, their surfaces' and lights' light together, each side at its share of the
  probes' mean times the game's mean brightness (capped at four times it), mixed in by
  BL_GI_MIX. Before and after pictures in build/gi/.

## 2026-10-26: load times, hitches and GPU time

Measured on the asylum (sm_asylum_1, M4 Pro, 1080p, headless runs one at a time).
- Start-up and map load: FileSystem_Stdio's wildcard search matcher walked its file
  tree with string work per entry; replaced by a native one (modules/README.md) along with
  native strnicmp/stricmp signatures (crt/signatures.txt). Start-up before the movies
  10.4 s to 1.0 s; the slowest frame while the map loads 6.3 s to 1.0 s; loading screen
  to playing about 12 s to about 6 s.
- Textures loaded ahead: when the game fills a texture's top level (d3d_image_changed,
  first fill only), its upscale (tex_hires.m), PBR maps and character normal map
  (tex_detail.m) start loading on other threads; the draws take them when ready, waiting
  if one is still loading. The level's first frame spent 1.1 s on these, now about 40 ms.
  BL_PREFETCH=0 turns it off. Same pictures with it on (checked at frame 950).
- GPU: BL_GPU_STATS=2 times each pass (Metal counter samples at pass boundaries, each
  pass charged from the end of the one before), named per shader for the haze, skin and
  bounced light. 15.1 ms a frame to 11.4 ms:
  - the haze (fog_scatter) takes each light only over the steps of the view ray it can
    reach: inside its range, and where it could still add a 4096th of the haze. 3.0 to
    1.3 ms; the picture is the same (only the bartender's animation and the HUD differ).
  - the bounced light's trace reads its normals as RGBA8Snorm and its colour copy as
    RG11B10Float instead of RGBA16Float (it reads them 24 times a pixel). 3.2 to 1.8 ms;
    the picture differs by at most 1 level outside moving things.
  What is left: the game's own passes 4.1 ms, the occlusion 0.8, TAA 0.6, the rest small.
- CPU: getenv("BL_COM_BT") ran on every COM call when unset (bl_com_trace_c); the
  character normal map lookup made a key string per draw (now a small table in front of
  the cache).
- Hitches: BL_HITCH=ms logs slow frames with the time in shaders, textures, PBR maps,
  normal maps, waiting for the GPU and presenting; BL_HITCH_STACKS=ms (runtime/bl_hitch.c)
  samples the game thread's stack every 2 ms through a slow frame. The few 30 to 90 ms
  frames in the first seconds of the level are none of those: they are the game's own
  code (engine, vampire.dll, StudioRender), about 40% of the samples in the x87 helpers.
  Making those faster is its own piece of work (SR_INLINE=1 inlining was slower before).
- Not yet checked on an M1, nor with a window (the user's test).

## 2026-10-26: x87 speed-up looked into (no change kept)

Measured on the Santa Monica hub (sm_hub_1, M4 Pro), headless, one run at a time.
- The game caps itself at about 63 frames a second by spinning (fps_max): uncapped
  (`+fps_max 1000`) and with the screen effects off, the game thread needs about 5.5 ms a
  frame. BL_HITCH now also prints, every 100 frames, the mean frame time and the part not
  spent waiting for the GPU.
- Where that goes (5 s `sample` of steady play, the game thread's own time): translated
  game code 68%, the x87 helpers 15%, the renderer about 8%, the rest system code. The
  helpers' share was higher (about 40%) only in the busy first seconds of a level.
- SR_INLINE=1 never inlined the helpers: they are compiled for apple-m1 and the translated
  procs carry no target, so opt refuses ("conflicting target features"); the 2026-10-23
  "6% slower" was the same calls to internal copies. An opt plugin that gave the procs the
  helpers' target and told opt that guest memory and the CPU state never overlap (scoped
  alias metadata; addresses made from a helper's returned pointer left alone) did inline
  them all.
- Result, uncapped hub with effects off: original 5.4 to 6.1 ms a frame; alias metadata
  alone no change; inlined about the same in steady play and a few percent better in the
  first seconds, within run-to-run noise. Kept the original build: no gain worth the risk
  of a wrong alias assumption. The plugin's source is in build/analysis/guest_alias_pass.cpp.
- What would help: the translated code's own speed (68%), not the x87 helpers. Even all
  of the helpers' time is under 1 ms a frame here.

## 2026-10-26: Metal 4, stage 1 (the renderer's frame); macOS 26 required

The renderer (runtime/d3d9/metal_render.m) now draws every frame through Metal 4, and the
runtime, boot and modules are built for macOS 26 (`-mmacosx-version-min=26.0`; module
objects built for 14 still link). The game stops with a message on a GPU without Metal 4.

- runtime/d3d9/mtl4.{h,m}: render and compute encoders that take the Metal 3 calls the
  renderer was written with, so most call sites only changed type. Bindings go into three
  argument tables (vertex, fragment, compute) that are reused, since Metal takes a copy at
  each draw; `set*Bytes` copies into the frame's upload space; blits are compute-encoder
  copies, each waiting for the command before it.
- Residency and lifetime: everything bound (and render targets, MetalFX's textures) is
  added to one residency set on first use and held until unused for 300 frames; texture
  views keep their parent with them. The drawable's texture is left to the layer's own set.
- Order: every pass waits on one fence and updates it at its end, as Metal 3's tracking
  ordered them; MetalFX (now MTL4FXTemporalScaler, built with an MTL4Compiler) takes the
  same fence.
- Frames: one MTL4CommandBuffer, an allocator per frame in flight (reset once the GPU is
  done with that frame), commit feedback for the frame semaphore, GPU time and errors;
  the drawable is waited for, signalled and presented on the queue. Reading a target back
  waits on a shared event. BL_GPU_STATS=2 uses an MTL4CounterHeap.
- Character tessellation (2026-10-25): Metal 4 has no tessellator. The shader now runs once
  per vertex into a buffer (a draw with rasterization off), then each triangle is drawn as
  an instance of an n x n grid that weights its corners (d3d9_shader.c, draw_patches).
  Found while checking it: the Metal 3 version never split anything. Its factors were
  stored as the integer 3 in half-float fields (a tiny number, so factor 1), and its
  pictures matched the untessellated ones. Really split, Phong at 0.75 puffs faces up
  enough to cover the eyes, so the strength is now BL_TESS_ROUND (0 to 1, default 0: not
  split, as the game looked). BL_TESS still sets the props' split.
- Verified, headless sm_hub_1 (M4 Pro): with Metal API validation, no errors (only the
  "redundant call" hints Metal 3 also had). Frame 850 matches the Metal 3 build's (mean
  difference 1.1 of 255 with the same path). GPU time 11.8 ms a frame, Metal 3 12.5.
  Split with no rounding (a temporary switch), characters looked as unsplit (by eye; the
  animation moment differed).
- Not verified: anything in a window (presenting, pacing, HDR and deep-colour output to
  the drawable never run headless), other levels, an M1.
- Still Metal 3: the background queues of the lighting rebake (lm_bake.m) and the light
  probes (gi_probes.m). Next stage.

## 2026-10-26: Shadow Count looked into (no change made)

Static reading of client.dll and GameUI.dll only; nothing run.

- The Options > Visual "Shadow Count" slider (GameUI) runs from 1 to 2 and sets
  cl_v_shadow_count (default.cfg: 2).
- The character shadow setup in client.dll (the function at 0x1009e2d0, run per character
  and again for all characters when shadow settings change) asks the engine for at most 8
  lights near the character, sorts them by strength and keeps at most 7. Lights with zero
  strength are dropped (the cutoff is 0.0).
- cl_v_shadow_count is only tested as "more than 1": at 1 the lights are blended into one
  shadow; at 2 (or anything higher) each kept light casts its own shadow. So values above 2
  change nothing; the real limit is the 8 asked for and the 7 kept.
- Going from 7 to 8 is one constant. More than 8 needs a larger light list than the
  function's fixed 8-entry stack array, so the function would have to be replaced in the
  runtime.
- The shadow texture is 1024x1024 with each shadow in a 256x256 or 128x128 square, so it
  holds 16 large or 64 small shadows.
- Measured once, headless, sm_hub_1 frame 850 (the opening dialogue in the alley), with
  cl_v_shadows 3 and cl_v_shadow_count 2: one character cast 2 shadows (the same body, hat
  and attachment meshes drawn into two 256x256 squares); 4 of the 16 large squares were in
  use. Nothing near the 7-light cap. One scene only: busier, brighter streets not measured.
- BL_DRAW_STATS' [drawsrc] lines now also print "at": the model's place, or its first
  bone's (c48..c50's w), which tells apart the characters drawn into the shadow texture.

## 2026-10-26: "Smooth Characters" and "Sharpening" boxes

- Smooth Characters (BL_ROUND, registry value SmoothCharacters, on until unticked):
  characters' split triangles move BL_TESS_ROUND (now default 0.25, was 0 and off) of the
  way onto Phong's curve, so chins and cheeks soften without the puffing seen at 0.75.
  Unticked, characters are drawn as the game made them.
- Sharpening (BL_SHARPEN, registry value SharpenAfterAA, on until unticked): the copy of
  the TAA's picture back into the back buffer (taa_copy in taa_resolve) sharpens it,
  contrast adaptive like AMD's CAS, BL_SHARPEN_STRENGTH (default 0.3). It runs after the
  anti-aliasing and before the HUD; the old sharpening (removed 2026-10-26) ran before the
  anti-aliasing. It has no hair exception like the old one had; to check: dark specks
  beside bright hair strands.
- Boxes: "Smooth Characters" above the Shadow Count slider, "Sharpening" a row above the
  right-hand column (bl_vgui.c).
- Verified: builds; the TAA shader compiles offline. Not verified: anything on screen (the
  boxes' places, the look), left for the user's window run.

## 2026-10-26: "Enhanced" options tab

- The user asked to tidy the Visual tab: twelve check boxes had filled every gap between
  its own controls. The options dialog now has an "Enhanced" tab after "Visual", and all
  twelve boxes moved there, in two columns of six (lighting: Ambient Occlusion,
  Reflections, Volumetric Light, Shadows, Bounced Light, Global Illumination; picture
  and characters: HDR, Bloom, Eye Adaptation, Sharpening, Skin Scattering, Smooth
  Characters). The Visual tab is the game's own again.
- How: GameUI's `PropertyDialog::AddPage` (0x10024eb0) is replaced by
  `bl_vgui_AddPage` (runtime/bl_vgui.c), which adds a plain `PropertyPage` after the
  Visual tab; the Visual tab's OnResetData still makes the boxes (now on the new page),
  with the font and scale of its "Combat effects" box. GameUI re-translated (17 s).
- Settings are unchanged (the same registry values).
- First window run: no tab. The Visual tab was matched by the address of its title, but
  GameUI is not loaded at its own base; it is now matched by the title's text.
- Second window run (the user's screenshot): the tab and both columns showed, working.
- Tidied at the user's ask: three columns around the page's middle, each under a heading
  (vgui::Label, 0x10023730, aliased GameUI_Label_ctor): "Lighting" (Global Illumination,
  Bounced Light, Ambient Occlusion, Volumetric Light), "Camera" (HDR, Bloom, Eye
  Adaptation, Sharpening), "Surfaces & Characters" (Shadows, Reflections, Skin Scattering,
  Smooth Characters). Built; not yet seen.

## 2026-10-26: Rebuilt head test (Jeanette, still renders only, nothing in the game)

Tried rebuilding one character's head on MakeHuman's CC0 base head (`tools/heads/`):
`export_head.py` takes the mesh and flex keys out of the Blender import,
`fit_head.py` fits the base head to the game's face and binds every new vertex to a face
triangle (barycentric place plus an offset in the triangle's own axes), and
`render_head.py` renders old against new. The binding is exact at rest (error 0). It
follows the face through bones and flexes in the same way the hair strips do.

Fixes made along the way:
- The mouth cut is now a flood fill from inside the mouth that stops at forward-facing
  faces. The opening's edge lands where the lips meet: 52 vertices, where the old box cut
  gave 156 and tore the area round the mouth.
- The lips are mapped upper to upper and lower to lower, corner to corner. This removed
  a notch under the nose.
- Where the base head folds over the game's coarse face (the ears, the lid corners), it
  keeps its own shape. The ears are now real ears.
- UVs are worked out per corner, on one texture piece per triangle. This removed a
  smeared band at the collar.

Result: 2979 vertices and 5670 triangles, against the game face's 2136 triangles. Seen in
renders (`build/heads/jeanette_tex.png`): from the front the new head looks almost the
same as the old one, but its ears and side profile are better. Her ear texture looks
smeared, because it was painted for the game's flat ear. There are faint facets on the
cheek.

Not verified: expressions in the game. In Blender, the flex keys imported from the SMD
break the game's own teeth and lids at full weight, on the old head as much as the new
one, so the Blender test can only show that the new head copies the old face's movement.
It cannot show what the game's expressions really look like.

## 2026-10-26: "Skin Detail" box (pores and uneven shine on faces)

A new layer is drawn over the faces' original textures, which are left unchanged
(`ps_skin_detail` in d3d9_shader.c, called from ps_detail for skin that is not hair).
- It lays a grid on the face texture, with one cell every BL_SKIN_DETAIL_SIZE texels
  (default 3). Each cell gets either no pore or a small pit at a random place, size and
  depth, chosen by an integer hash.
- The pits tilt the skin's normal, so the game's lights pick them out, and they make the
  shine rougher where they are. The shine also varies in patches about fourteen pores
  wide.
- The layer fades out once a cell gets smaller than about a pixel, so it doesn't shimmer
  at a distance. No texture files are involved.

It applies only to textures whose file name has "face" or "head" in it and not "hair":
252 of the 1219 character textures (tex_detail.m, `bl_detail_is_face`). Body textures
mix skin and clothes, so they get none for now.

The constants gained a fifth header row (strength and pores across and down the
texture), so the lights start at bl_dl[5]. The setting is `SkinDetail` in the Native key,
on by default, with a "Skin Detail" box under "Surfaces & Characters" on the Enhanced tab.
BL_SKIN_DETAIL_STRENGTH (0 to 2, default 1) can be used for tuning.

Verified: the runtime builds, and the new shader code compiles on its own with Metal.
Not verified: how it looks in the game. That needs a window test, which the user will do.

## 2026-10-26: Skin detail on bodies' skin too

Skin Detail now covers body textures as well, limited to their skin by a mask made from
each texture's colours when its map loads (tex_detail.m `make_skin_mask`, an R8 texture
up to 512 across, bound at texture 18; bl_dl[4].w says a mask is in use).
- Skin is found by colour: warm (red over green over blue, with green a fair way above
  blue), slightly saturated, and not too dark.
- White and grey cloth, jeans, black leather and strong reds are left out.
- The mask is box-blurred and thresholded again so stray specks drop out.
- Faces keep no mask (all skin).

Checked on stills of five body textures. Jeanette's chest, arms and hands come out
clean and her shirt is left out. The damsel's bare midriff is found. Pale streaks on a
bum's brown jacket and bits of dark leather also pass, so they get faint pores.

A stricter test that tried to leave out olive tones was dropped, because it broke up
Jeanette's real skin.

Verified: the runtime builds, and the shader piece compiles on its own. Not verified: the
look in the game. The log prints "[detail] skin mask" with each body's skin share.

Fix: the user's first test run printed no mask lines, and a standalone test of the mask
code found 0% skin on Jeanette. Drawing her texture through Core Graphics had multiplied
its colour by the alpha channel, which on bodies is often a shine mask set to 0 over skin.
The raw bytes are now read (load_pixels), and the image is only drawn when its layout
needs it. Standalone results on bodies: Jeanette 31% skin (matching the still), bum 6%,
damsel 11%, the Brujah player body 10%. Goth girl 67%, mostly the skin-coloured padding
between texture pieces, which never shows on the model, but also parts of her cream corset.

## 2026-10-26: Gentler pores on bodies

The user said the body pores looked a bit much. Bodies' skin detail now runs at 0.7 of
the faces' strength (BL_SKIN_DETAIL_BODY, default 0.7). Faces are unchanged. Built; the
user is checking the look.

## 2026-10-26: "Cloth Detail" box (a fine weave on clothes)

Body textures now get a plain weave wherever their skin mask says the surface isn't skin
(`ps_skin_detail` in d3d9_shader.c, after the pores).
- Threads go one over and one under, with a thread every BL_CLOTH_DETAIL_SIZE texels
  (default 2).
- Each thread has its own thickness, chosen by a hash.
- The weave tilts the normal (0.05 at strength 1, BL_CLOTH_DETAIL_STRENGTH) and fades out
  where a thread gets smaller than about a pixel.
- It's generated in the shader, with no textures. Faces get none (no mask). Tongues,
  teeth and eyes get no mask now, so they get neither pores nor weave.

The constants gained a sixth header row (cloth strength and threads across and down the
texture), so the lights start at bl_dl[6]. bl_dl[4].w (is there a mask) is now set
whether or not Skin Detail is on.

The setting is `ClothDetail`, on by default, with a "Cloth Detail" box under "Surfaces &
Characters". The Enhanced tab's boxes are now 36 apart (they were 40) to fit a sixth row.

Step 1 is one general weave. Leather, buckles and other non-fabric parts get it too,
because colour can't tell fabrics apart.

Verified: the runtime builds, and the shader piece compiles on its own. Not verified: the
look in the game.

## 2026-10-26: Pores and weave sized in the world; the weave always on

In the user's screenshot, Danielle (a 256x256 head texture) had pores as big as scales,
because pore size was set in texels and her texture is low resolution. Pores and threads
are now set in world units instead.
- Sizes are BL_SKIN_DETAIL_SIZE (default 0.06) and BL_CLOTH_DETAIL_SIZE (default 0.08).
  Both were measured on Jeanette, whose look the user approved: 3 texels of her face
  texture and 2 of her body texture. The measurement used the Blender import's triangle
  areas against their UV areas, times the 52.49 that the hair tools found between the
  import and the game.
- The shader works out the world size of a texel from how position and texture
  coordinates change across the pixel (constant over a triangle).
- It takes the grids in steps of two either side of the wanted size and mixes the two by
  how close each is, so the size changes smoothly between triangles. Each step fades out
  on its own once its cells get smaller than a pixel.
- Bodies keep 0.7 of the faces' pore strength.

The user wanted Cloth Detail always on rather than as an option, so its box is gone and
the Enhanced tab is back to 40-apart boxes. BL_CLOTH_DETAIL=0 turns the weave off for
comparisons. The Skin Detail box stays.

Verified: the runtime builds, and the shader piece compiles on its own. Not verified: the
look in the game.

## 2026-10-26: Texel sizing back, with a limit only for coarse textures

The world sizing above weakened Jeanette's pores. Her wanted size fell between two grid
steps, so she got a mix of two half-strength patterns. The user had only asked for care
with some characters, so the change was too broad.

Sizes are back to texels (3 per pore, 2 per thread), so Jeanette and characters with
similar textures look exactly as before. The same hashes are used and one grid is drawn.
A limit only applies where a pore or thread would come out bigger in the world than:
- 0.10 world units on faces (BL_SKIN_DETAIL_MAX);
- 0.20 on bodies (_MAX_BODY);
- 0.13 for threads (BL_CLOTH_DETAIL_MAX).

These sit just above what 98% of Jeanette's face, body and shirt have, measured per
triangle from her model. There, and only there, the grid gets finer in steps of two,
mixed between steps. The constants gained a seventh row (texels per pore and per thread),
so the lights start at bl_dl[7].

Verified: the runtime builds, and the shader piece compiles on its own. Not verified: the
look in the game (Jeanette should be unchanged from the version the user approved, and
Danielle should have finer pores).

## 2026-10-26: Jeanette's body from a new picture

The user supplied a 2048x2048 picture of Jeanette's body texture in the original layout
(build/textures/characters/.../jeanette/jeanette_body_opaque2.png; the layout matches the
original, correlation 0.97). It replaces the upscaled copy the renderer draws:
- jeanette_body_u.png is the picture at 4096, keeping the old alpha (the original's shine mask);
- jeanette_body_n.png is remade from it with PBRify's normal model, at 1024 as before,
  because the pore and thread sizes count in that map's texels;
- jeanette_body_r.png is remade with PBRify's roughness model, at 2048.
The skin mask still comes from the game's own texture. The old three files are kept in
build/textures/characters_backup/jeanette_body_before_opaque2/.

Not verified: the look in the game.

## 2026-10-26: Jeanette's face and skirt from new pictures

The user supplied new pictures of Jeanette's face (2912x1440) and skirt (2048x2048), in
.../jeanette/Newtex/. The face matches the original's layout when stretched to 2:1
(correlation 0.99). The skirt covers all but 0.1% of the original's opaque part. Made as
for the body:
- jeanette_face_u.png at 4096x2048 and a new jeanette_skirt_u.png at 2048 (the skirt had
  no upscaled copy, so the renderer drew the game's own), each keeping the game texture's
  alpha (the skirt's alpha is its UV wireframe, as the game ships it);
- _n remade at the old sizes, 1024x512 and 1024, so pore and thread sizes stay;
- _r remade at the pictures' size.
The old files are in build/textures/characters_backup/jeanette_face_skirt_before_newtex/
(the skirt had no _u, so deleting jeanette_skirt_u.png goes back to the game's skirt).

Not verified: the look in the game.

## 2026-10-26: no Gigapixel upscales

The user wants no Gigapixel upscales in use. Comparing each file the renderer reads
(_u, _n, _r, _hair under build/textures/characters) with every Gigapixel picture
(the same size and the same pixels, mean difference 0.00) found 61 made from one:
- all 56 eye textures (_u);
- Jeanette's two hair textures (jeanette_hair_1_u, _2_u);
- the other Jeanette model's jeanettebody_u and jeanettebody_n;
- the tongue (_u).

These 61 and the 254 Gigapixel pictures themselves (in characters/, export/ and
unused/) were moved to build/textures/removed_gigapixel/, keeping their paths. The eyes,
the tongue and Jeanette's hair now draw the game's own textures (the eye highlights are
shader work and stay).

The hair under Jeanette's strips was lifted from the hair's upscaled copy (_u). It is now
lifted from the game's texture as exported (<name>.png beside the map), in
tex_detail.m's bl_detail_hair. The map textures (build/hires) come from PBRify and
-replace pictures, none from Gigapixel.

Verified: the runtime builds. Not verified: the look in the game.

## 2026-10-26: Danielle from new pictures

The user supplied new pictures of Danielle's body (2912x1440), head (1029x1028) and hair
(2912x1440), in .../danielle/NewTex/. Each matches the game texture's layout (correlation
0.98). Made as for Jeanette:
- danielle_body_u.png at 4096x2048 and danielle_head_u.png at 1024, keeping the game
  textures' alpha;
- their _n remade at the old sizes (1024x512, 256), so pore and thread sizes stay;
- their _r remade at the pictures' size.

Danielle's hair texture has exactly the same pixels as Angela's (angelahair). The game's
texture matches Angela's line in normals.txt first, so the new hair went in as
downtown/angela/angelahair_u.png (4096x2048, no maps, as hair has none) and shows on
both. The old Danielle files are in
build/textures/characters_backup/danielle_before_newtex/ (angelahair had no _u).

Not verified: the look in the game.

## 2026-10-26: the masked male dancer from a new picture

The user supplied a 2048x2048 picture for the asylum bar's shirtless masked dancer
(dancer/male_2/male2targa, in .../male_2/NewTx/; the layout matches, correlation 0.985).
male2targa_u.png is the picture at 2048 with the game texture's alpha. _n is remade at
512, so pore and thread sizes stay. _r is remade at 2048. The old files are in
build/textures/characters_backup/male_dancer_2_before_newtx/.

Not verified: the look in the game.

## 2026-10-26: parallax occlusion on floors and walls

Surfaces with a height map now get parallax occlusion: bricks, tiles, planks and
carvings look set into the surface, not painted on.
- New `tools/tex_height.py` makes `<name>_h.png` (white high) beside a map texture's
  export with PBRify's height model, from the picture the renderer draws (-replace, else
  -pbrify, else the export), read as a tile so it repeats without a seam. It ran on 19
  asylum materials with real relief: brick/doora, concrete/wllb, ground/sidewalka,
  plaster/asceilinga, aswllc, pillara, wlla, wllb, stone/asfloora, bar, doorb, rocka,
  wlla, tile/tilea, wood/ceilingb, floora, floorb, woodbeamsa, woodpanela (and the same
  names in the other exported maps). The flat painted walls, smooth concrete and metal
  were left out.
- metal_render.m loads the height maps with the PBRify maps (same tables, key "<name>#h",
  loaded ahead the same way). tex_detail.m's `bl_load_height_map` makes them R8,
  stretched 1st to 99th percentile to 0..1, with mipmaps. `struct obj` gained `pom`.
- d3d9_shader.c: in the surface variant, a dry pass of the body finds the coordinates
  plain 2D textures are read with. `ps_pom`, at the top of the shader, steps the view ray
  through the height map (8 steps head on to 24 edge on, refined between the last two)
  along the albedo coordinate. It moves that input register, and the other plain 2D
  registers by as much on the screen, before any pass reads them. The lightmap's
  coordinates stay. The depth is `BL_POM_DEPTH` (default 0.015 of the texture's shorter
  side, 0 off); it fades out towards `BL_POM_DIST` (1500) and edge on. The height map is
  at [[texture(19)]]; d3d_ps_params gained pom and pom_dist (pad2 gone).
- Like the PBRify bumps, it is part of the surface variant, so it needs Reflections on.

Verified: the runtime builds, and shader_test compiles all 7184 variants (0 failed).
Not verified: the look in the game.

## 2026-10-26: new pictures for the asylum's ram frieze and stone door

The user supplied 2048×2048 pictures for `materials/stone/bar` (the ram-head frieze above the bar; the file was named `bar_h.png` but is a colour picture) and `materials/stone/doorb` (the stone doorway with wooden doors). Their layouts match the originals (luminance correlation 0.96 and 0.999). They went in as `<name>-replace.png`, replacing the PBRify upscales (removed, since tex_pack refuses two upscales of one texture). The bump and roughness maps were remade from each picture at the game texture's size (128 and 512, read as a tile), and the height maps from the pictures with tools/tex_height.py (27 s). tex_pack wrote both at 2048×2048 BC7. Not yet checked in the game.

## 2026-10-26: larger interface fonts at high resolutions

Almost all of the game's text is drawn from prebuilt bitmap fonts (`materials/fonts/*.fnt`, one per face, size and weight). Sizes without one fall back to GDI, which here is Core Text with a stand-in face. The client turns a scheme font name such as `Dlg_Base` into `Dlg_Base_<size>` at 0x1018C870 (81 callers, all passing the result to the scheme's GetFont). It uses a table of 640, 800, 1024, 1280 and 1600, and takes the largest size `s` with `s <= width` and `s*3/4 <= height`.

Unofficial Patch's `trackerscheme.res` also has 1920, 2400 and 2880 sets, and the patch ships bitmap fonts for them in `Unofficial_Patch/materials/fonts` (checked: every font in the 1920 set has one, except Marlett 16, which the port draws as shapes, and the 100-pixel Times New Roman headline). Its loader adds those sizes to the table. The port doesn't run the loader, so the game stopped at 1600.

- `bl_client_FontName` (`runtime/bl_client.c`) replaces the routine, with the same rule and the three larger sizes. The client was re-translated (1 min 47 s).
- Which set is used: 1920x1080 still gets 1280 (the 1920 set needs 1440 rows); 2560x1440 gets 1920; 2880x1800 gets 2400; 3600x2250 gets 2880.
- At 1920x1080 on a Retina screen, the whole 1080-row image is magnified by the window, which softens text. Choosing a resolution near the screen's own pixel size gives sharp text in the right size.

Not verified: any run since the change. The user checks it in the window.

## 2026-10-26: Hor+ field of view on wide screens

Until now a wide screen showed the 4:3 picture with its top and bottom cut off (metal_render.m scales the projection's y by viewport aspect over 4:3, see "widescreen correction"). Unofficial Patch's widescreen plugin (`Bin/loader/widescreen_fix.vtm`, read with llvm-objdump, never run) instead patches the engine's projection aspect (the 4:3 constant at engine 0x2007A440, in the routine that calls the material system's PerspectiveX), turns off a client multiply, and raises `default_fov` and `viewmodel_fov`.

What the code does:
- The engine's projection aspect is fixed at 4/3, or 16/9 when Troika's hidden `r_anamorphic` is on.
- With `r_anamorphic` on, `CViewRender::Render` (client 0x10191FD7) also multiplies the view's field of view (view setup +0x38) by 4/3. It then takes tan(fov/2) of it and of the hands' field of view (+0x3c) for the rest of the frame. Every camera passes through here: the player's, dialogue and cutscene cameras, and zooms.

Change: the `je` at 0x10191FD5 that skips that multiply is replaced (`modules/client/instruction_replacements.manual.sci`) by a call to `bl_client_HorPlus` (`runtime/bl_client.c`). On screens wider than 4:3 it sets each field of view to `2·atan(tan(fov/2)·(aspect/(4/3)))`, so 90 becomes 106.3 at 16:9 and 100.4 at 16:10. The projection stays 4:3 and the renderer still crops it to the screen's shape, so the visible height is the 4:3 view's and the sides gain. The game builds its culling frustum from the widened field of view, so nothing at the edges is culled away. `r_anamorphic` itself is no longer used.

- `BL_FOV=<degrees>` sets the player's usual 4:3 field of view (50 to 130). Only a view at exactly the game's 90 changes, so zooms and dialogue cameras keep theirs.
- `BL_WIDESCREEN=stretch` turns this off, along with the projection correction.

Client re-translated. Not verified in the game: the user checks it in the window. Things to look at: the edges of the screen for missing objects, the first-person hands and weapons, dialogue framing, sniper zoom, and the 3D sky.

## 2026-10-26: Unofficial Patch loader plugins, audit

The port runs none of `Bin/loader/*.vtm` (Windows DLLs that `Loader.exe` injects). Read from their own notes and settings, without running them. Most say they need Unofficial Patch 11.5 or later game modules, and they find their hook sites by address or byte pattern. The port runs the 11.1 modules (see "Unofficial Patch 12.0"), so none of them would apply as they are. Each fix has to be redone against the 11.1 code.

Gameplay fixes, in a suggested order:
1. `vtmb-tweaks` (c6, open source: github.com/c6-dev/vtmb-tweaks): corpses stay until the level changes, NPCs drop every weapon they used, non-solid `c_ragdoll_prop` ragdolls (cutscene bugs), stackable weapons, no bullet tracers. Not needed here: doors at high frame rates (the port caps at 60) and Alt+F4.
2. `griffith-frenzy-werewolf-fix`: the werewolf's movement during Frenzy on sp_observatory_2. Its map files are part of the 12.0 content the port uses; the code part is missing.
3. `history-stat-reset-fix`: character creation stats reset when changing gender or History.
4. `protean-improved`: Warform Frenzy with Protean 5 without duplicate controllers or bonuses, and the Protean filter's brightness after loading.
5. `subtitle-pause-fix` (radio captions and streams), `console-pause-fix`, `cutscene-subtitle-background-fix`.
6. `model-loader-fix` (JillCrungus, open source): a model loading memory leak.
7. `bugs_fix` and the 12.0 loader's "Internal Hooks": coronas, lights through walls, claw stats, paths, the too-many-histories crash, forced shadow rebuilds. Whether the 11.1 modules already contain any of these is not checked yet.

Interface: `uhd-list-fix` / `UHDDropdownListFontFix` set drop-down row heights for the 1920 to 2880 font sets. These are now in use at high resolutions (see "larger interface fonts"), so drop-down lists there may cut letters off until this is done.

## 2026-10-26: vtmb-tweaks ported

The plugin's source (github.com/c6-dev/vtmb-tweaks, GPL-2.0) patches vampire.dll and client.dll at fixed offsets from their base. Each site was checked in our 11.1 modules with llvm-objdump, and every one holds the instruction the plugin expects (for example the `jne` at vampire 0x1032C402, the `shr ecx,2; and ecx,1` at 0x10154E90, the 6-byte `je` at client 0x1004099A, replaced together with its `test` at 0x10040998 because the pipeline fuses the pair). They are redone as instruction replacements (`modules/vampire`, `modules/client`), with native helpers in `runtime/bl_vampire.c`. The settings are the patch's own `vtmb-tweaks.ini`, fixed on:
- corpses stay until the level changes (rats still fade);
- NPCs drop every weapon they held;
- `c_ragdoll_prop` ragdolls are non-solid (cutscene bugs);
- no bullet tracers;
- stackable weapons: the patch's items mark knives, katanas, the fire axe, drugs and others `is_stackable`;
- zooming out restores the field of view the fov command set.

Not ported: the high frame rate door fix (the port runs at 60), doors staying open (off in the patch), Alt+F4.

Two pipeline notes. A replaced `call` loses its return label, because SRW no longer sees the call, so the corpse replacement continues at `<site>_after`. A jump target reached only from a replaced jump would be dropped, so the tracer target is named in `global_aliases.manual.sci`.

Not verified in the game: the user checks it in the window.

## 2026-10-26: Griffith Park werewolf frenzy fix ported

`Bin/loader/griffith-frenzy-werewolf-fix.vtm` (1.2.1) is closed source, so it was read from its disassembly and never run. Its notes: frenzy is possible in the library and Griffith Park through its two maps, which are already part of the 12.0 content the port loads. During frenzy the player's body stays put and a player-owned FrenzyShadow moves instead, and the werewolf on sp_observatory_2 stood on and collided with the body.

The plugin checks the vampire.dll and engine.dll time stamps and sizes and four byte patterns; all match our 11.1 modules. It then:
- hooks `mov eax,[ebx+0x6F0]` at vampire 0x1016C5BE (the player's think, ebp the player) to track the player (frenzying when +0x146C > 0), the shadow (handle at +0x1DB0, vtable 0x104B2184) and the entity named `werewolf` (vtable 0x104CF4D4), only on sp_observatory_2;
- replaces the engine trace's `TraceRay` in its vtable: for traces from eight vampire call sites whose filter passes the werewolf, with a solid mask (0x200400B, with or without 0x20000), while the shadow is within 160 units (2D), it wraps the filter so the player's body is skipped and the shadow is hit;
- replaces the werewolf's `SetGroundEntity` (vtable +0x340, `CBaseEntity::SetGroundEntity` by its profiler name) so the body is never its ground when called from 0x1026E843.

Redone in `runtime/bl_vampire.c` with instruction replacements at the same places, hooking the call sites instead of the vtables. The map name comes from vampire's own gpGlobals->mapname (gpGlobals at 0x1070B228, +0x24, as the node graph loader reads it) instead of the engine routine at engine+0x1B800, so the engine is not rebuilt. The wrapping filter's ShouldHitEntity is a hand-written llasm entry, `runtime/llasm/vampire.llasm`, given to the engine as a guest function pointer.

Not verified in the game: the user checks it in the window (frenzy near the werewolf in Griffith Park).

## 2026-10-26: History stat reset fix ported

`Bin/loader/history-stat-reset-fix.vtm` (1.5.2, closed source) was read from its disassembly. It finds its sites by byte pattern at fixed offsets; all five patterns match our vampire.dll and both of its client.dll patterns match too. It writes small stubs at run time, so their bytes were decoded from the code that writes them:
- after character creation's `SetVHistory(history)` (vampire 0x100D6DD3, a console command the creation screen runs) and `SetVHistory(-1)` (0x100D6DE6), it calls a hook and then sets the History again;
- the hook saves stat 0x22 of the character's base stat list (the first list of type 0x23), runs the History change routine (0x10206AA0, which takes the old History's stat changes away and applies the new one) for the character's current History, puts stat 0x22 back and refreshes the client's character sheet (client 0x1017D930 on the panel at global 0x105FB14C, +0xEDC, when +0x274 is set);
- the change routine normally does nothing when the History is unchanged (`cmp ebx, ebp; je` at 0x10206AD1); for the character being reset it goes ahead once.

Redone with instruction replacements and `runtime/bl_vampire.c`. The client part needs the address of a client global from vampire's native code, so a small `client_HistoryUI` proc returning it is added inside the client replacement at 0x101713E0.

Not verified in the game: on the character creation screen, change gender or History (also after Auto-Spend Points) and the stats and points left should reset each time.

## 2026-10-26: Protean Improved ported

`Bin/loader/protean-improved.vtm` (1.2.2 Core, closed source) has two parts, both on by default (its ini is not shipped). It checks seven byte patterns in vampire.dll and one in client.dll, plus an address operand in each; all match our 11.1 modules. It copies a 0x800-byte code block with a fix-up table into memory and jumps there from six places; the block was relocated and disassembled to read it.

Warform Frenzy (vampire.dll): Protean 5 (Warform, flag +0x1EDC) and a frenzy (+0x146C > 0) together.
- 0x1016C558, the player's think: the Warform flag reads as 0 during a frenzy.
- 0x1033E9BE: the Protean command does not end a frenzy.
- 0x101F9177, a case of the discipline switch that starts the Warform: during a frenzy the FrenzyShadow is used instead of a new controller. The flag is cleared, the stat block +0x23D4 is applied to the player and the shadow (vtable +0x1A4), +0x1C68 is set to the current time, and the player is added to the warform list (0x10227A30 on 0x10750CB4).
- 0x103510D7: a frenzy counts as the Warform state the code compares against.
- The starts of 0x101E56E0 and 0x101E5B30: an argument that is the FrenzyShadow's owner (+0x9C) during a Warform frenzy becomes the local player (0x101193B0).
- 0x1033ED75: a `je` becomes a `jmp`.

Filter Load Fix (client.dll): at 0x1019DA7D the Protean filter was not set again when its level was unchanged, so after loading a save it kept the wrong brightness. Now it is skipped only when the filter's material is already in that state.

Redone as instruction replacements with natives in `runtime/bl_vampire.c` and `runtime/bl_client.c`. Natives that choose a branch push their answer on the guest stack and the replacement pops it, so registers stay as the plugin's pushad/popad left them.

Not verified in the game.


## 2026-10-26: Console Pause Fix ported

`Bin/loader/console-pause-fix.vtm` (1.1.0) hooks two engine routines and two GameUI routines, after checking eight byte patterns; all match our modules. Opening the console sends "setpause"; closing it with X or ~ only hid the dialog, so the game stayed paused with no input.

- engine 0x2010DC10 `Con_ShowConsole`: remembers whether the console was already open, whether the game menu was open, the level name and the engine time, then calls the original. Afterwards it hides the console's Minimize button and the Minimize entry of its title menu.
- engine 0x2001A570 `IVEngineClient::ClientCmd`: while the console opens, a "setpause" is dropped when the console was already open or the game was already paused by something else (that pause stays its owner's), and otherwise marks the pause as the console's. Going back to the menu does not pause again. Inside the game menu's hide, "unpause" is dropped when the console is open over an older pause.
- GameUI 0x10022070 vgui `Frame::SetVisible`: when the console hides on the same level with no load in between, the console's own pause is undone (a pause count at 0x20B4378C goes down by one, or "unpause"), and the game goes back to the menu it came from (`IGameUI::ActivateGameUI`) or to the game (0x2010D650).
- GameUI 0x100059D0, the game menu's hide: records the state that rule needs.

Redone as instruction replacements whose natives are in `runtime/bl_console.c`. Each replaces the first instruction of its routine and opens the rest as a global proc, which the native calls as the original. Rebuilt engine and GameUI.

Not verified in the game.


## 2026-10-26: Subtitle Pause Fix ported

`Bin/loader/subtitle-pause-fix.vtm` (1.3.0) checks nine byte patterns in engine.dll, vampire.dll and mssmp3.asi (all match our modules), copies a small code block into memory and hooks four calls.

Engine:
- 0x201188B0: the caption timing read the sound device's time. It now reads the sentence channel's start time plus the samples it has played (wrapped around the loop for a radio station), or, with no usable channel, a clock that is Plat_FloatTime less the time spent paused.
- 0x2002D130: reading the pause state also moves that clock.

Radio (vampire):
- 0x1022C50F, `CPropRadio::Activate` (also when a saved location loads): the station's record starts again at the current time.
- 0x1022C807, the radio's `SetFakeSilence`: going silent remembers the stream's position. Coming back decodes the MP3 stream forward (the mixer's GetOutputData, 4096 samples at a time) to where the broadcast would be now. When that cannot be worked out, the radio stays silent, as in the plugin.
- A station's loop length comes from its file: the plugin reads the MP3 through the engine's file system and counts its MPEG-1 Layer III frames.

Redone in `runtime/bl_subtitle.c` from the plugin's code and the copied block. The plugin compares vtables and function pointers with module offsets; here those are the labels and aliases of the same objects. Its byte pattern checks are not repeated, because the port only runs the pinned modules. Rebuilt engine, vampire, mssmp3 and vaudio_miles.

Not verified in the game. Most of it only matters with sound on.


## 2026-10-26: Audit fixes (cache keys and the medium findings)

From the runtime audit of this date.
- Texture and buffer caches (`tex_detail.m` and the hair, smoothed-prop, remodel and lightmap-range caches in `metal_render.m`) are keyed by a serial number each `struct obj` gets in `obj_new`, which is never reused. Before, they were keyed by the object's address, which the next object can reuse. `obj_free` calls `d3d_render_forget`: a texture's detail entry goes at once, and the hair and prop copies of freed buffers go at the next present.
- Focus loss (`bl_cocoa.m`): every key and mouse button the game saw go down, and the pad's (`bl_gc_release`), is released. Caps Lock is left as it is.
- Mouse motion and wheel (`dinput8.c`) add up only while the mouse is acquired, and are cleared on Acquire and Unacquire.
- Mouse presses reach the game only inside the content view (not the title bar), and not the click that brings the window to the front. A release reaches the game only for a press it saw. y is clamped like x.
- The Enhanced tab's boxes (`bl_vgui.c`) save when the box changes, not while it differs from a forced effect, which used to save every frame.
- Shader `rep` reads its count from p[0] and `loop` its integer register from p[1]. Both used to read after a destination they don't have.
- Mixed static and copied vertex streams: only streams bound in place are shifted by `first`. A buffer rewritten 8 or more times was shifted twice.
- GetRenderTargetData reads 32-bit targets whatever the GPU copy's format, so it works with the deep-colour back buffer. It skips only the shadow atlas, scaled targets and targets whose size differs.
- Code page 1252 (`bl_codepage.c`): bytes 0x80-0x9F convert to the right characters (quotes, dashes, ellipsis, euro), both ways.
- Mutexes have an owner and a count, so the owner can take one again. ReleaseMutex by a non-owner fails. Named events, mutexes and semaphores open the existing object with ERROR_ALREADY_EXISTS, and creates set the last error.
- `tests/runtime_unit.c` (`tools/runtime_unit.sh`) checks the text conversion, mutexes, named objects, mouse motion and shader loops without game files. 24 of 24 checks pass.

Not verified in the game. The runtime builds and `boot` links.
