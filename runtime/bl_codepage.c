// Text in Windows' Western code page (bl_kernel32.c MultiByteToWideChar and
// WideCharToMultiByte).
#include "bl_win32.h"

// Windows' Western code page (1252, the ANSI one here: GetACP) is Latin-1 except bytes
// 0x80-0x9F, which hold curly quotes, dashes, the ellipsis and the like. The five it
// leaves unassigned map to the same code, as Windows does.
static const uint16_t cp1252_high[32] = {
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D,
    0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
    0x0153, 0x009D, 0x017E, 0x0178,
};

uint16_t bl_cp1252_to_wide(uint8_t c) { return c >= 0x80 && c < 0xA0 ? cp1252_high[c - 0x80] : c; }

// The byte for c, or -1 if code page 1252 has none.
int bl_wide_to_cp1252(uint16_t c)
{
    if (c < 0x80 || (c >= 0xA0 && c < 0x100)) return c;
    for (int i = 0; i < 32; i++)
        if (cp1252_high[i] == c) return 0x80 + i;
    return -1;
}
