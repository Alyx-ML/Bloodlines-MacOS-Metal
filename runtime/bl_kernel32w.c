// Wide-character (UTF-16) kernel32 entry points. The game's paths and names are
// ASCII, so each one narrows its string arguments into guest memory, calls the ANSI
// handler and widens string results back. Characters above 0x7f become '?'.
#include <stdint.h>
#include <string.h>

#include "bl_vm.h"
#include "bl_win32.h"

#define G(addr) ((void *)bl_g2h(addr))
#define U16(addr) (*(uint16_t *)bl_g2h(addr))

uint32_t bl_k32_CreateDirectoryA_c(uint32_t name, uint32_t sec);
uint32_t bl_k32_CreateFileA_c(uint32_t name, uint32_t access, uint32_t share, uint32_t sec,
                              uint32_t disp, uint32_t flags, uint32_t tmpl);
uint32_t bl_k32_DeleteFileA_c(uint32_t name);
uint32_t bl_k32_FindFirstFileA_c(uint32_t name, uint32_t data);
uint32_t bl_k32_FindNextFileA_c(uint32_t h, uint32_t data);
uint32_t bl_k32_GetCommandLineA_c(void);
uint32_t bl_k32_GetCurrentDirectoryA_c(uint32_t len, uint32_t buf);
uint32_t bl_k32_GetDriveTypeA_c(uint32_t root);
uint32_t bl_k32_GetFileAttributesA_c(uint32_t name);
uint32_t bl_k32_GetFullPathNameA_c(uint32_t name, uint32_t len, uint32_t buf, uint32_t file_part);
uint32_t bl_k32_GetModuleFileNameA_c(uint32_t h, uint32_t buf, uint32_t size);
uint32_t bl_k32_MoveFileA_c(uint32_t from, uint32_t to);
uint32_t bl_k32_RemoveDirectoryA_c(uint32_t name);
uint32_t bl_k32_SetCurrentDirectoryA_c(uint32_t path);
uint32_t bl_k32_SetEnvironmentVariableA_c(uint32_t name, uint32_t value);
uint32_t bl_k32_SetFileAttributesA_c(uint32_t name, uint32_t attrs);

// Narrowed copy of a guest UTF-16 string on the guest heap (0 stays 0); free with
// bl_guest_free.
static uint32_t narrow(uint32_t ws)
{
    if (!ws) return 0;
    uint32_t n = 0;
    while (U16(ws + 2 * n)) n++;
    uint32_t s = bl_guest_malloc(n + 1);
    char *p = G(s);
    for (uint32_t i = 0; i < n; i++) {
        uint16_t c = U16(ws + 2 * i);
        p[i] = c < 0x80 ? (char)c : '?';
    }
    p[n] = 0;
    return s;
}

// Widens n chars of an ANSI string to dst and terminates it.
static void widen(uint32_t dst, const char *s, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) U16(dst + 2 * i) = (uint8_t)s[i];
    U16(dst + 2 * n) = 0;
}

static void free2(uint32_t a, uint32_t b)
{
    if (a) bl_guest_free(a);
    if (b) bl_guest_free(b);
}

#define NARROW1(call)          \
    uint32_t a = narrow(name); \
    uint32_t r = call;         \
    free2(a, 0);               \
    return r

uint32_t bl_k32_CreateDirectoryW_c(uint32_t name, uint32_t sec) { NARROW1(bl_k32_CreateDirectoryA_c(a, sec)); }
uint32_t bl_k32_DeleteFileW_c(uint32_t name) { NARROW1(bl_k32_DeleteFileA_c(a)); }
uint32_t bl_k32_GetDriveTypeW_c(uint32_t name) { NARROW1(bl_k32_GetDriveTypeA_c(a)); }
uint32_t bl_k32_GetFileAttributesW_c(uint32_t name) { NARROW1(bl_k32_GetFileAttributesA_c(a)); }
uint32_t bl_k32_RemoveDirectoryW_c(uint32_t name) { NARROW1(bl_k32_RemoveDirectoryA_c(a)); }
uint32_t bl_k32_SetCurrentDirectoryW_c(uint32_t name) { NARROW1(bl_k32_SetCurrentDirectoryA_c(a)); }
uint32_t bl_k32_SetFileAttributesW_c(uint32_t name, uint32_t attrs) { NARROW1(bl_k32_SetFileAttributesA_c(a, attrs)); }

uint32_t bl_k32_CreateFileW_c(uint32_t name, uint32_t access, uint32_t share, uint32_t sec,
                              uint32_t disp, uint32_t flags, uint32_t tmpl)
{
    NARROW1(bl_k32_CreateFileA_c(a, access, share, sec, disp, flags, tmpl));
}

uint32_t bl_k32_MoveFileW_c(uint32_t from, uint32_t to)
{
    uint32_t a = narrow(from), b = narrow(to);
    uint32_t r = bl_k32_MoveFileA_c(a, b);
    free2(a, b);
    return r;
}

uint32_t bl_k32_SetEnvironmentVariableW_c(uint32_t name, uint32_t value)
{
    uint32_t a = narrow(name), b = narrow(value);
    uint32_t r = bl_k32_SetEnvironmentVariableA_c(a, b);
    free2(a, b);
    return r;
}

uint32_t bl_k32_GetCommandLineW_c(void)
{
    static uint32_t wide;
    if (!wide) {
        const char *s = G(bl_k32_GetCommandLineA_c());
        uint32_t n = (uint32_t)strlen(s);
        wide = bl_guest_malloc(2 * (n + 1));
        widen(wide, s, n);
    }
    return wide;
}

// The ANSI calls below return the length written (without the terminator) when the
// buffer is big enough, else the required size; the result is widened in the first case.
uint32_t bl_k32_GetCurrentDirectoryW_c(uint32_t len, uint32_t buf)
{
    uint32_t tmp = bl_guest_malloc(len ? len : 1);
    uint32_t r = bl_k32_GetCurrentDirectoryA_c(len, tmp);
    if (r && r < len) widen(buf, G(tmp), r);
    bl_guest_free(tmp);
    return r;
}

uint32_t bl_k32_GetFullPathNameW_c(uint32_t name, uint32_t len, uint32_t buf, uint32_t file_part)
{
    uint32_t a = narrow(name), tmp = bl_guest_malloc(len ? len : 1);
    uint32_t r = bl_k32_GetFullPathNameA_c(a, len, tmp, 0);
    if (r && r < len) {
        widen(buf, G(tmp), r);
        if (file_part) {
            const char *s = G(tmp), *base = s;
            for (const char *p = s; *p; p++)
                if (*p == '\\' || *p == '/') base = p + 1;
            *(uint32_t *)G(file_part) = *base ? buf + 2 * (uint32_t)(base - s) : 0;
        }
    }
    free2(a, tmp);
    return r;
}

// Unlike the calls above, GetModuleFileName truncates and returns the count copied.
uint32_t bl_k32_GetModuleFileNameW_c(uint32_t h, uint32_t buf, uint32_t size)
{
    if (!size) return 0;
    uint32_t tmp = bl_guest_malloc(size);
    uint32_t r = bl_k32_GetModuleFileNameA_c(h, tmp, size);
    if (r || size) widen(buf, G(tmp), r);
    bl_guest_free(tmp);
    return r;
}

// WIN32_FIND_DATAA (320 bytes) -> WIN32_FIND_DATAW (592 bytes): 44 header bytes, then
// cFileName[260] and cAlternateFileName[14].
static void find_data_widen(uint32_t w, uint32_t a)
{
    memcpy(G(w), G(a), 44);
    const char *name = (const char *)G(a) + 44, *alt = (const char *)G(a) + 304;
    widen(w + 44, name, (uint32_t)strnlen(name, 259));
    widen(w + 564, alt, (uint32_t)strnlen(alt, 13));
}

uint32_t bl_k32_FindFirstFileW_c(uint32_t name, uint32_t data)
{
    uint32_t a = narrow(name), tmp = bl_guest_calloc(1, 320);
    uint32_t h = bl_k32_FindFirstFileA_c(a, tmp);
    if (h != 0xffffffffu) find_data_widen(data, tmp);
    free2(a, tmp);
    return h;
}

uint32_t bl_k32_FindNextFileW_c(uint32_t h, uint32_t data)
{
    uint32_t tmp = bl_guest_calloc(1, 320);
    uint32_t r = bl_k32_FindNextFileA_c(h, tmp);
    if (r) find_data_widen(data, tmp);
    bl_guest_free(tmp);
    return r;
}

// The game starts no processes.
uint32_t bl_k32_CreateProcessW_c(uint32_t app, uint32_t cmd, uint32_t psec, uint32_t tsec, uint32_t inherit,
                                 uint32_t flags, uint32_t env, uint32_t dir, uint32_t si, uint32_t pi)
{
    (void)app, (void)cmd, (void)psec, (void)tsec, (void)inherit, (void)flags, (void)env, (void)dir, (void)si, (void)pi;
    bl_set_last_error(2);  // ERROR_FILE_NOT_FOUND
    return 0;
}
