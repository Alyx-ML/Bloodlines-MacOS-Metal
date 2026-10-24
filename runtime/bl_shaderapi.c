// Native replacements for routines in shaderapidx9 (see native/modules/README.md).
// Each takes the guest CPU, like bl_vgui.c.
#include <stdint.h>

#include "llasm_cpu.h"

// The texture memory estimate (shaderapidx9 0x2A026250, cdecl, two arguments). It
// returns the size cached in Bin/vidcfg.bin when the first argument's 16 bytes match the
// file. Unofficial Patch 11.1 then returns 0x7F000000. 12.0 returns 64 MiB when the
// second argument is 2, and otherwise measures by creating 256x256 textures until
// CreateTexture fails, then writes the cache. Here CreateTexture does not fail until the
// guest heap is gone, and freed blocks stay in their size class, so the measurement
// would use up the heap. Both versions get 11.1's answer, and vidcfg.bin is left alone.
void bl_shaderapi_TextureMemory_c(_cpu *cpu)
{
    eax = 0x7f000000u;
}
