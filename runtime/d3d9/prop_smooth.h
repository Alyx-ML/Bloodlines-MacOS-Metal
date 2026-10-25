// Props smoothed (metal_render.m, BL_PROP_TESS): a rigid model's triangles split finer
// and their points moved onto the curve the corners' normals describe, once per mesh on
// the CPU, so round things (table tops, stools, bottles) lose their facets and are then
// drawn by the game's own shaders. Phong tessellation (Boubekeur and Alexa 2008) with
// sharp edges kept: where corners share a position but not a normal (a table top's
// rim), each corner's point is projected onto all of those surfaces at once, the same
// from either side of the edge, so a rim curves along its length and stays sharp, a
// box stays a box, and no gaps open.
#pragma once
#include <stdint.h>

struct prop_elem { uint16_t stream, offset; uint8_t type, usage, index; };  // as D3DVERTEXELEMENT9

struct prop_in {
    const uint8_t *data[16];  // per stream: its vertex 0
    uint32_t stride[16], nverts[16];
    const struct prop_elem *el;
    int nel;
    const uint32_t *idx;  // 3 per triangle, vertex numbers
    uint32_t ntris;
    int split;            // segments per edge (2 or more)
};

struct prop_out {
    uint8_t *data[16];  // per stream the in's stride, nverts of them (malloc'd; NULL for unused streams)
    uint32_t nverts;
    uint32_t *idx;  // nidx (malloc'd)
    uint32_t nidx;
    float moved;     // the most a point moved, as a share of its triangle's longest edge
    uint32_t sharp;  // corners on sharp edges
};

// 0 and out filled; -1 when the mesh cannot be read (no float3 position or normal on it).
int prop_smooth(const struct prop_in *in, struct prop_out *out);
void prop_smooth_free(struct prop_out *out);
