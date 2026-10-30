// The pixels of the normal and height maps, worked out on the CPU from their PNGs: used by
// the renderer for the characters' maps (tex_detail.m) and by tools/tex_bake_maps.m, which
// stores the surfaces' PBRify maps ready for the GPU (BC7 and R8 in <name>_n.tex and
// <name>_h.tex), so the same code makes both.
#pragma once
#include <stddef.h>
#include <stdint.h>

// A map's mipmaps, as Metal counts them for w x h: level l is max(w >> l, 1) by
// max(h >> l, 1) pixels, 4 bytes each for a normal map, 1 for a height map.
struct bl_map_levels {
    uint32_t w, h, count, bpp;
    uint8_t *level[16];
};

// A normal map at `path` (a <name>_n.png, with <name>_r.png's roughness in alpha) as the
// characters' are drawn: its middle detail only, xyz the normal, mipmaps renormalised.
// 0 without one.
int bl_normal_map_levels(const char *path, struct bl_map_levels *out);

// A height map at `path` (a <name>_h.png, white high): stretched so its 1st to 99th
// percentile span 0 to 255, with box-filtered mipmaps. 0 without one.
int bl_height_map_levels(const char *path, struct bl_map_levels *out);

void bl_map_levels_free(struct bl_map_levels *m);

// A box blur of n floats `stride` apart, radius r, in place (edges clamped); tmp holds n.
void bl_map_box(float *v, size_t n, size_t stride, int r, float *tmp);
