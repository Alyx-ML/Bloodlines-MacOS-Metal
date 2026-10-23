// Native replacements for routines in GameUI's statically linked vgui (see
// native/modules/README.md). Each takes the guest CPU, like bl_crt.c.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "llasm_cpu.h"

// RichText::GetCursorLine (GameUI 0x10029250, thiscall, no arguments): the line the
// cursor is on. The original scans the line-break table from the start, and the
// console calls it per character and again in a loop when scrolling to the end, so
// text appended under -dev cost O(lines) per character. The table holds text offsets
// in ascending order, so a binary search gives the same answer: the index of the
// first break after the cursor, minus one when the cursor sits on a soft break that
// is not the end of the text.
//
// Fields of the RichText (this = ecx): +0x58 text length, +0x64 break count,
// +0x6c break table, +0x70 cursor position, +0x75 "cursor before soft break" flag.
// BL_VGUI_CHECK=1 compares every answer with the original linear scan.
void bl_vgui_GetCursorLine_c(_cpu *cpu)
{
    const uint8_t *self = REG2PTR(ecx);
    int32_t count = *(const int32_t *)(self + 0x64);
    int32_t cursor = *(const int32_t *)(self + 0x70);
    const int32_t *breaks = count > 0 ? REG2PTR(*(const uint32_t *)(self + 0x6c)) : NULL;
    int32_t lo = 0, hi = count > 0 ? count : 0;
    while (lo < hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (cursor < breaks[mid]) hi = mid;
        else lo = mid + 1;
    }
    static int check = -1;
    if (check < 0) check = getenv("BL_VGUI_CHECK") != NULL;
    if (check) {
        int32_t i = 0;
        while (i < count && cursor >= breaks[i]) i++;
        if (i != lo) fprintf(stderr, "[vgui] GetCursorLine: linear %d, binary %d (cursor %d, %d breaks)\n", i, lo, cursor, count);
        lo = i;
    }
    if (self[0x75] && cursor != *(const int32_t *)(self + 0x58)) lo--;
    eax = (uint32_t)lo;
}
