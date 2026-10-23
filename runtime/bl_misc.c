// Small Win32 imports of the engine modules: winmm timers, dbghelp ("Loader.dll"),
// COM start-up, Winsock start-up, shlwapi, and the user32/gdi32 queries a headless
// start-up makes. Windows, devices and sockets are not here yet.
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "bl_cocoa.h"
#include "bl_win32.h"
#include "llasm_cpu.h"

#define U32(addr) (*(uint32_t *)bl_g2h(addr))

// winmm
uint32_t bl_mm_timeGetTime_c(void)
{
    bl_cocoa_pump_if_idle();
    return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000);
}
uint32_t bl_mm_timeBeginPeriod_c(uint32_t ms) { (void)ms; return 0; }
uint32_t bl_mm_timeEndPeriod_c(uint32_t ms) { (void)ms; return 0; }
uint32_t bl_mm_joyGetNumDevs_c(void) { return 0; }
uint32_t bl_mm_auxGetNumDevs_c(void) { return 0; }
uint32_t bl_mm_mixerGetNumDevs_c(void) { return 0; }

// dbghelp, imported as Loader.dll by launcher: symbols are unavailable.
uint32_t bl_dbg_SymInitialize_c(uint32_t p, uint32_t path, uint32_t invade) { (void)p, (void)path, (void)invade; return 0; }
uint32_t bl_dbg_SymSetOptions_c(uint32_t opts) { return opts; }
uint32_t bl_dbg_SymSetSearchPath_c(uint32_t p, uint32_t path) { (void)p, (void)path; return 0; }
uint32_t bl_dbg_SymGetSearchPath_c(uint32_t p, uint32_t buf, uint32_t n) { (void)p, (void)buf, (void)n; return 0; }

// ole32: COM is initialized but no class can be created.
uint32_t bl_ole_CoInitialize_c(uint32_t r) { (void)r; return 0; }
uint32_t bl_ole_OleInitialize_c(uint32_t r) { (void)r; return 0; }

// wsock32 by ordinal: 115 WSAStartup fails with WSASYSNOTREADY (no networking yet),
// 116 WSACleanup, 111 WSAGetLastError.
uint32_t bl_wsock_wsock32_ord115_c(uint32_t version, uint32_t data) { (void)version, (void)data; return 10091; }
uint32_t bl_wsock_wsock32_ord116_c(void) { return 0; }
uint32_t bl_wsock_wsock32_ord111_c(void) { return 10091; }

// shlwapi
uint32_t bl_shlw_PathRemoveFileSpecA_c(uint32_t path)
{
    char *p = bl_g2h(path);
    char *s = strrchr(p, '\\');
    if (!s) return 0;
    if (s == p || (s == p + 2 && p[1] == ':')) s++;  // keep the root's backslash
    int changed = *s != 0;
    *s = 0;
    return changed;
}

// user32 queries
uint32_t bl_u32_GetSystemMetrics_c(uint32_t i)
{
    switch (i) {
    case 0: case 1: {  // SM_CXSCREEN, SM_CYSCREEN
        uint32_t w, h;
        bl_screen_size(&w, &h);
        return i ? h : w;
    }
    case 43: return 3;    // SM_CMOUSEBUTTONS
    default: return 0;
    }
}

uint32_t bl_u32_MessageBoxA_c(uint32_t w, uint32_t text, uint32_t caption, uint32_t type)
{
    (void)w, (void)type;
    fprintf(stderr, "[MessageBox] %s: %s\n", caption ? (const char *)bl_g2h(caption) : "",
            text ? (const char *)bl_g2h(text) : "");
    return 1;  // IDOK
}

static uint32_t next_fake_handle = 0x20000;
uint32_t bl_u32_LoadCursorA_c(uint32_t inst, uint32_t name) { (void)inst, (void)name; return next_fake_handle += 4; }
uint32_t bl_u32_LoadIconA_c(uint32_t inst, uint32_t name) { (void)inst, (void)name; return next_fake_handle += 4; }

uint32_t bl_u32_GetSysColor_c(uint32_t i) { (void)i; return 0; }

// wsprintfA(buf, fmt, ...): cdecl, at most 1024 bytes.
uint32_t bl_u32_wsprintfA_c(uint32_t buf, uint32_t fmt)
{
    _cpu *cpu = bl_thread_cpu;
    int n = bl_format(bl_g2h(buf), 1024, bl_g2h(fmt), esp + 12);
    return (uint32_t)(n > 1023 ? 1023 : n);
}

// gdi32 device queries for the desktop: the display's size, 32-bit, 96 dpi.
uint32_t bl_gdi_GetDeviceCaps_c(uint32_t dc, uint32_t i)
{
    (void)dc;
    switch (i) {
    case 8: case 10: {     // HORZRES, VERTRES
        uint32_t w, h;
        bl_screen_size(&w, &h);
        return i == 8 ? w : h;
    }
    case 12: return 32;    // BITSPIXEL
    case 14: return 1;     // PLANES
    case 88: return 96;    // LOGPIXELSX
    case 90: return 96;    // LOGPIXELSY
    case 116: return 60;   // VREFRESH
    default: return 0;
    }
}

uint32_t bl_gdi_GetStockObject_c(uint32_t i) { return 0x30000 + 4 * i; }

// winmm devices: none. Opening a wave, MIDI or mixer device fails with
// MMSYSERR_NODRIVER (6), queries with MMSYSERR_BADDEVICEID (2), joysticks report
// JOYERR_PARMS/JOYERR_UNPLUGGED; operations on handles that cannot exist succeed.
uint32_t bl_mm_waveOutOpen_c(uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4, uint32_t a5) { (void)a0, (void)a1, (void)a2, (void)a3, (void)a4, (void)a5; return 6; }
uint32_t bl_mm_waveOutClose_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveOutGetDevCapsA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_waveOutGetID_c(uint32_t a0, uint32_t a1) { (void)a0, (void)a1; return 2; }
uint32_t bl_mm_waveOutPause_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveOutPrepareHeader_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_waveOutReset_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveOutRestart_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveOutSetVolume_c(uint32_t a0, uint32_t a1) { (void)a0, (void)a1; return 0; }
uint32_t bl_mm_waveOutUnprepareHeader_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_waveOutWrite_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_waveInAddBuffer_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_waveInClose_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveInOpen_c(uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4, uint32_t a5) { (void)a0, (void)a1, (void)a2, (void)a3, (void)a4, (void)a5; return 6; }
uint32_t bl_mm_waveInPrepareHeader_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_waveInReset_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveInStart_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_waveInUnprepareHeader_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_midiOutClose_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_midiOutLongMsg_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_midiOutOpen_c(uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4) { (void)a0, (void)a1, (void)a2, (void)a3, (void)a4; return 6; }
uint32_t bl_mm_midiOutPrepareHeader_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_midiOutReset_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_midiOutShortMsg_c(uint32_t a0, uint32_t a1) { (void)a0, (void)a1; return 0; }
uint32_t bl_mm_midiOutUnprepareHeader_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }
uint32_t bl_mm_mixerClose_c(uint32_t a0) { (void)a0; return 0; }
uint32_t bl_mm_mixerGetControlDetailsA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_mixerGetDevCapsA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_mixerGetLineControlsA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_mixerGetLineInfoA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_mixerOpen_c(uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4) { (void)a0, (void)a1, (void)a2, (void)a3, (void)a4; return 6; }
uint32_t bl_mm_mixerSetControlDetails_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_auxGetDevCapsA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 2; }
uint32_t bl_mm_auxGetVolume_c(uint32_t a0, uint32_t a1) { (void)a0, (void)a1; return 2; }
uint32_t bl_mm_auxSetVolume_c(uint32_t a0, uint32_t a1) { (void)a0, (void)a1; return 2; }
uint32_t bl_mm_joyGetDevCapsA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 165; }
uint32_t bl_mm_joyGetPosEx_c(uint32_t a0, uint32_t a1) { (void)a0, (void)a1; return 167; }
uint32_t bl_mm_PlaySoundA_c(uint32_t a0, uint32_t a1, uint32_t a2) { (void)a0, (void)a1, (void)a2; return 0; }

// gdi32 text rendering is in bl_gdi.c.

// Console: the process has none (the engine only uses these for the dedicated server).
uint32_t bl_k32_FreeConsole_c(void) { return 1; }
uint32_t bl_k32_GetConsoleScreenBufferInfo_c(uint32_t h, uint32_t info) { (void)h, (void)info; bl_set_last_error(6); return 0; }
uint32_t bl_k32_GetLargestConsoleWindowSize_c(uint32_t h) { (void)h; bl_set_last_error(6); return 0; }
uint32_t bl_k32_ReadConsoleOutputCharacterA_c(uint32_t h, uint32_t buf, uint32_t len, uint32_t coord, uint32_t n)
{
    (void)h, (void)buf, (void)len, (void)coord;
    if (n) *(uint32_t *)bl_g2h(n) = 0;
    bl_set_last_error(6);  // ERROR_INVALID_HANDLE
    return 0;
}
uint32_t bl_k32_SetConsoleScreenBufferSize_c(uint32_t h, uint32_t size) { (void)h, (void)size; bl_set_last_error(6); return 0; }
uint32_t bl_k32_SetConsoleWindowInfo_c(uint32_t h, uint32_t abs, uint32_t rect) { (void)h, (void)abs, (void)rect; bl_set_last_error(6); return 0; }
uint32_t bl_k32_WriteConsoleInputA_c(uint32_t h, uint32_t buf, uint32_t len, uint32_t n)
{
    (void)h, (void)buf, (void)len;
    if (n) *(uint32_t *)bl_g2h(n) = 0;
    bl_set_last_error(6);
    return 0;
}

// File mappings: the engine maps only handles a dedicated-server parent passes in
// (-HFILE); there is none, so mapping fails.
uint32_t bl_k32_MapViewOfFile_c(uint32_t h, uint32_t access, uint32_t hi, uint32_t lo, uint32_t n)
{
    (void)h, (void)access, (void)hi, (void)lo, (void)n;
    bl_set_last_error(6);
    return 0;
}
uint32_t bl_k32_UnmapViewOfFile_c(uint32_t p) { (void)p; return 0; }

// Threads end by returning; forced termination is refused.
uint32_t bl_k32_TerminateThread_c(uint32_t h, uint32_t code)
{
    (void)h, (void)code;
    bl_set_last_error(5);  // ERROR_ACCESS_DENIED
    return 0;
}

// wsock32: WSAStartup fails, so sockets are only reached if the caller ignores that;
// they fail. Byte-order and address helpers work.
uint32_t bl_wsock_socket_c(uint32_t af, uint32_t type, uint32_t proto) { (void)af, (void)type, (void)proto; return 0xffffffffu; }
uint32_t bl_wsock_closesocket_c(uint32_t s) { (void)s; return 0; }
uint32_t bl_wsock_fail3_c(uint32_t a, uint32_t b, uint32_t c) { (void)a, (void)b, (void)c; return 0xffffffffu; }
uint32_t bl_wsock_fail5_c(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e) { (void)a, (void)b, (void)c, (void)d, (void)e; return 0xffffffffu; }
uint32_t bl_wsock_fail6_c(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e, uint32_t f) { (void)a, (void)b, (void)c, (void)d, (void)e, (void)f; return 0xffffffffu; }
uint32_t bl_wsock_htons_c(uint32_t v) { return ((v & 0xff) << 8) | ((v >> 8) & 0xff); }
uint32_t bl_wsock_gethostbyname_c(uint32_t name) { (void)name; return 0; }
uint32_t bl_wsock_gethostname_c(uint32_t buf, uint32_t len)
{
    if (len < 10) return 0xffffffffu;
    memcpy(bl_g2h(buf), "localhost", 10);
    return 0;
}
uint32_t bl_wsock_inet_addr_c(uint32_t s)
{
    unsigned a, b, c, d;
    char tail;
    if (sscanf(bl_g2h(s), "%u.%u.%u.%u%c", &a, &b, &c, &d, &tail) != 4 || (a | b | c | d) > 255) return 0xffffffffu;
    return a | b << 8 | c << 16 | d << 24;  // network order in a little-endian dword
}


// win.ini is empty: every lookup returns the default.
uint32_t bl_k32_GetProfileStringA_c(uint32_t app, uint32_t key, uint32_t def, uint32_t out, uint32_t size)
{
    (void)app, (void)key;
    if (!out || !size) return 0;
    const char *d = def ? (const char *)bl_g2h(def) : "";
    size_t n = strlen(d);
    if (n >= size) n = size - 1;
    memcpy(bl_g2h(out), d, n);
    ((char *)bl_g2h(out))[n] = 0;
    return (uint32_t)n;
}
