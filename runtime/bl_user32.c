// user32, advapi32 and ws2_32 imports of the tools DLLs (tier0's assert dialog,
// registry settings, remote-console sockets). Headless until the window layer
// exists: no windows, an empty registry, sockets that trap.
#include <stdio.h>
#include <string.h>

#include "bl_input.h"
#include "bl_win32.h"

#define U32(addr) (*(uint32_t *)bl_g2h(addr))

uint32_t bl_u32_EndDialog_c(uint32_t dlg, uint32_t result) { (void)dlg, (void)result; return 1; }
uint32_t bl_u32_EnumWindows_c(uint32_t fn, uint32_t param) { (void)fn, (void)param; return 1; }
// Virtual key state from the window layer: bit 15 while down, bit 0 toggled on each press.
static uint8_t vk_down[256], vk_toggle[256];

void bl_input_vk(int vk, int down)
{
    vk &= 0xFF;
    if (down && !vk_down[vk]) vk_toggle[vk] ^= 1;
    vk_down[vk] = (uint8_t)(down != 0);
}

uint32_t bl_u32_GetKeyState_c(uint32_t key)
{
    key &= 0xFF;
    // SHORT result: the caller tests the sign bit or bit 0.
    return (vk_down[key] ? 0xFFFF8000u : 0) | vk_toggle[key];
}

uint32_t bl_u32_GetWindowThreadProcessId_c(uint32_t w, uint32_t pid)
{
    (void)w;
    if (pid) U32(pid) = 0;
    return 0;
}

uint32_t bl_u32_GetDlgItemInt_c(uint32_t dlg, uint32_t id, uint32_t ok, uint32_t is_signed)
{
    (void)dlg, (void)id, (void)is_signed;
    if (ok) U32(ok) = 0;
    return 0;
}

uint32_t bl_u32_SetDlgItemInt_c(uint32_t dlg, uint32_t id, uint32_t v, uint32_t s)
{
    (void)dlg, (void)id, (void)v, (void)s;
    return 1;
}

uint32_t bl_u32_SetDlgItemTextA_c(uint32_t dlg, uint32_t id, uint32_t text)
{
    (void)dlg, (void)id, (void)text;
    return 1;
}

// Registry: reads find nothing (callers fall back to defaults), writes are dropped.
uint32_t bl_adv_RegOpenKeyExA_c(uint32_t key, uint32_t sub, uint32_t opts, uint32_t sam, uint32_t out)
{
    (void)key, (void)sub, (void)opts, (void)sam;
    if (out) U32(out) = 0;
    return BL_ERROR_FILE_NOT_FOUND;
}

uint32_t bl_adv_RegCreateKeyExA_c(uint32_t key, uint32_t sub, uint32_t res, uint32_t cls, uint32_t opts,
                                  uint32_t sam, uint32_t sec, uint32_t out, uint32_t disp)
{
    (void)key, (void)sub, (void)res, (void)cls, (void)opts, (void)sam, (void)sec, (void)disp;
    if (out) U32(out) = 0;
    return BL_ERROR_ACCESS_DENIED;
}

uint32_t bl_adv_RegQueryValueExA_c(uint32_t key, uint32_t name, uint32_t res, uint32_t type, uint32_t data,
                                   uint32_t size)
{
    (void)key, (void)name, (void)res, (void)type, (void)data, (void)size;
    return BL_ERROR_FILE_NOT_FOUND;
}

uint32_t bl_adv_RegSetValueExA_c(uint32_t key, uint32_t name, uint32_t res, uint32_t type, uint32_t data,
                                 uint32_t size)
{
    (void)key, (void)name, (void)res, (void)type, (void)data, (void)size;
    return BL_ERROR_INVALID_HANDLE;
}

uint32_t bl_adv_RegCloseKey_c(uint32_t key) { (void)key; return 0; }

// ws2_32 by ordinal: 111 WSAGetLastError, 112 WSASetLastError.
static uint32_t wsa_error;
uint32_t bl_ws2_ws2_32_ord111_c(void) { return wsa_error; }
uint32_t bl_ws2_ws2_32_ord112_c(uint32_t e) { wsa_error = e; return 0; }
