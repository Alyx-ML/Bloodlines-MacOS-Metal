// Props remodelled (metal_render.m): a prop's mesh drawn as a new model made for it
// (tools/prop_revolve.py, tools/prop_pack.py), by the game's own shaders. The draw is
// recognised by its contents: the SHA-1 of its triangles' vertex numbers (u32, counted
// from the lowest), as tools/prop_pack.py computes it from the model file, then every
// position it uses checked against the original's, to 0.01 units (the game unpacks
// compressed models itself). build/remodels/index.txt lists "key triangles file"; a
// file is "BLPM", u32 vertex, triangle and original vertex counts, then per vertex
// position, normal and UV (8 floats), 3 u32 per triangle, and the original's positions
// (3 floats each, from its lowest vertex number on).
// Each new vertex takes every attribute of the game's own (its lighting, colours,
// weights...) interpolated from the nearest point of the original triangles, then the
// remodel's position, normal and UV.
#pragma once
#include <stddef.h>

#include "prop_smooth.h"

// Whether some listed mesh has this many triangles: the cheap test every draw takes.
int prop_remodel_listed(uint32_t ntris);

// 1 and out filled (out->moved and sharp unused), name set; 0 when the draw is no
// remodelled prop.
int prop_remodel(const struct prop_in *in, struct prop_out *out, char *name, size_t namelen);
