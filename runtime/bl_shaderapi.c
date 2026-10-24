// Native replacements for routines in shaderapidx9 (see native/modules/README.md).
// Each takes the guest CPU, like bl_vgui.c.
#include <stdint.h>

#include "llasm_cpu.h"

// The texture memory estimate (shaderapidx9 0x2A026250, cdecl, two arguments). It
// returns the size cached in Bin/vidcfg.bin when the first argument's 16 bytes match the
// file, 64 MiB when the second argument is 2, and otherwise measures by creating
// 256x256 textures until CreateTexture fails, then writes the cache. Unofficial Patch
// 11.1 skipped all of that and returned 0x7F000000; 12.0 restored the measurement.
// Here CreateTexture does not fail until the guest heap is gone, and freed blocks stay
// in their size class, so the measurement would use up the heap. Return what 11.1
// returned instead (the 64 MiB case as in 12.0), and leave vidcfg.bin alone.
void bl_shaderapi_TextureMemory_c(_cpu *cpu)
{
    uint32_t mode = *(const uint32_t *)REG2PTR(esp + 8);
    eax = mode == 2 ? 0x4000000u : 0x7f000000u;
}
