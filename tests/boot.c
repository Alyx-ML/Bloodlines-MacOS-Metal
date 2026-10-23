// Milestone 3 boot test: starts the game the way Vampire.exe does, by loading
// launcher.dll and calling LauncherMain(hInstance, hPrevInstance, lpCmdLine, nCmdShow)
// (cdecl: Vampire.exe pops the four arguments itself). Everything after that is the
// game's own start-up, recompiled; the run ends at the first unimplemented import
// (a trap naming it) or when LauncherMain returns.
//
//   boot <game dir> [command line]
//
// The default command line is "-window", with "-game Unofficial_Patch" added when that
// folder exists (GOG's shortcut does the same). -dev is left out: it sends every
// developer message to the console, and the Unofficial Patch's model precache prints
// thousands of them, which GameUI's RichText appends one character at a time.
//
// Headless: window, Direct3D, input and sound imports are stubs or traps here.
#include <stdio.h>
#include <sys/stat.h>

#include "bl_win32.h"

uint32_t bl_k32_GetModuleHandleA_c(uint32_t name);

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <game dir> [command line]\n", argv[0]);
        return 2;
    }
    const char *cmdline = argc > 2 ? argv[2] : "-window";
    char up[4096];
    struct stat st;
    snprintf(up, sizeof up, "%s/Unofficial_Patch", argv[1]);
    if (argc <= 2 && stat(up, &st) == 0 && S_ISDIR(st.st_mode)) cmdline = "-game Unofficial_Patch -window";
    setvbuf(stdout, NULL, _IONBF, 0);
    bl_vm_init();
    void *cpu = bl_cpu_new(1u << 20);
    bl_win32_init(argv[1], cmdline);
    bl_loader_init();

    uint32_t launcher = bl_load_module("launcher.dll");
    if (!launcher) {
        fprintf(stderr, "boot: launcher.dll did not load\n");
        return 1;
    }
    uint32_t launcher_main = bl_module_export(launcher, "LauncherMain");
    if (!launcher_main) {
        fprintf(stderr, "boot: launcher.dll has no LauncherMain\n");
        return 1;
    }
    uint32_t args[4] = { bl_k32_GetModuleHandleA_c(0), 0, bl_guest_strdup(cmdline), 1 /* SW_SHOWNORMAL */ };
    uint32_t ret = bl_call_guest(cpu, launcher_main, BL_CDECL, 0, 4, args);
    printf("boot: LauncherMain returned %u\n", ret);
    return (int)ret;
}
