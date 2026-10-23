// Milestone 2 check: the game's tier0, vstdlib and FileSystem_Stdio, recompiled to
// arm64, start up through their DllMains and read a game file through the
// filesystem interface, compared byte for byte with the file read natively.
//
//   fs_smoke <game dir> [relative file]
//
// VFileSystem005 vtable slots used (from the module's own "Tried to X NULL file
// handle" messages and argument counts): 0 Open(name, options, pathID),
// 1 Close(h), 2 Read(buf, size, h), 6 Size(h), 11 AddSearchPath(path, pathID).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_win32.h"

enum { FS_OPEN = 0, FS_CLOSE = 1, FS_READ = 2, FS_SIZE_H = 6, FS_ADD_SEARCH_PATH = 11 };

static void *cpu;
static int failures, checks;

static void check(int ok, const char *what)
{
    checks++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static uint32_t method(uint32_t obj, int slot, int nargs, const uint32_t *args)
{
    uint32_t vt = *(uint32_t *)bl_g2h(obj);
    uint32_t fn = *(uint32_t *)bl_g2h(vt + 4 * (uint32_t)slot);
    return bl_call_guest(cpu, fn, BL_THISCALL, obj, nargs, args);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <game dir> [file under Vampire/]\n", argv[0]);
        return 2;
    }
    const char *rel = argc > 2 ? argv[2] : "resource/trackerscheme.res";
    setvbuf(stdout, NULL, _IONBF, 0);
    bl_vm_init();
    cpu = bl_cpu_new(1u << 20);
    bl_win32_init(argv[1], "");
    bl_loader_init();

    check(bl_load_module("tier0.dll") != 0, "tier0 DllMain");
    check(bl_load_module("vstdlib.dll") != 0, "vstdlib DllMain");
    uint32_t fs_mod = bl_load_module("FileSystem_Stdio.dll");
    check(fs_mod != 0, "FileSystem_Stdio DllMain");

    uint32_t create = bl_module_export(fs_mod, "CreateInterface");
    uint32_t args[3] = { bl_guest_strdup("VFileSystem005"), 0 };
    uint32_t fs = bl_call_guest(cpu, create, BL_CDECL, 0, 2, args);
    check(fs != 0, "CreateInterface(\"VFileSystem005\")");
    if (!fs) return 1;

    args[0] = bl_guest_strdup(BL_WIN_ROOT "\\Vampire");
    args[1] = bl_guest_strdup("GAME");
    method(fs, FS_ADD_SEARCH_PATH, 2, args);

    // Native copy for comparison.
    char host[2048];
    snprintf(host, sizeof host, "%s/Vampire/%s", argv[1], rel);
    FILE *f = fopen(host, "rb");
    if (!f) {
        perror(host);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long want_size = ftell(f);
    rewind(f);
    char *want = malloc((size_t)want_size);
    fread(want, 1, (size_t)want_size, f);
    fclose(f);

    args[0] = bl_guest_strdup(rel);
    args[1] = bl_guest_strdup("rb");
    args[2] = bl_guest_strdup("GAME");
    uint32_t h = method(fs, FS_OPEN, 3, args);
    check(h != 0, "Open via search path");
    if (!h) return 1;
    uint32_t size = method(fs, FS_SIZE_H, 1, &h);
    check(size == (uint32_t)want_size, "Size matches native file size");
    uint32_t buf = bl_guest_malloc(size + 1);
    uint32_t rargs[3] = { buf, size, h };
    uint32_t got = method(fs, FS_READ, 3, rargs);
    check(got == size && !memcmp(bl_g2h(buf), want, size), "Read returns the file's bytes");
    method(fs, FS_CLOSE, 1, &h);

    printf("%s: %d/%d checks passed (%s, %u bytes)\n", failures ? "FAILED" : "OK", checks - failures, checks, rel,
           size);
    return failures != 0;
}
