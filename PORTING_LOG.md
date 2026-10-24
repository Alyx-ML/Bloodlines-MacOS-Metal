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
