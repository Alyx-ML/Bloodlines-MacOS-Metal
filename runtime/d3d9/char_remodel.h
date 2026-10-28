// Characters remodelled (metal_render.m): a skinned character's draw with a texture a
// rebuild was made for (tools/bodies/export_game_mesh.py, <texture>_mesh.bin beside its
// normal map; tex_detail.m bl_detail_body) drawn as the rebuild, by the game's own
// shaders. The file is in the game's model space: its anchors are every vertex of the
// game's triangles with that texture, so the draw's vertices are found among them by
// position. The game splits a texture's triangles over several draws, each with a few
// bones loaded in its own slots: a draw takes the new triangles the file gives to one of
// its own triangles (chosen by the exporter as the draw that loads their bones), each
// vertex, bound to a game triangle (three anchors and barycentric weights), copying the
// draw's vertex at its binding's nearest corner, then its own position, normal, UV and
// bones. Which slot holds which of the model's bones is the file's (the game's strips, a
// draw each, found by its triangles), checked against the draw's vertices; a bone the
// draw has not loaded is taken as its nearest loaded parent. The game's triangles the
// file keeps (by their centres) are drawn with them; the rest are not.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "prop_smooth.h"

struct bl_body_vertex {
    float pos[3], nrm[3], uv[2];
    uint32_t bind;
    float bary[3];
    uint8_t bones[4];  // the model's
    float w[4];
};
_Static_assert(sizeof(struct bl_body_vertex) == 68, "the file's vertex");

struct bl_body_skin {
    uint8_t bones[4];
    float w[4];
};
_Static_assert(sizeof(struct bl_body_skin) == 20, "the file's anchor bones");

struct bl_body_mesh {
    uint32_t nverts, nidx, nanchors, nbinds, nkept, nbones, nstrips;
    const struct bl_body_vertex *verts;
    const uint32_t *idx;
    const uint32_t *owner;  // per triangle, the binding whose game triangle's draw draws it
    const float (*anchors)[3];
    const uint32_t (*binds)[3];
    const uint32_t *bind_strip;  // per binding, UINT32_MAX for none
    const float (*kept)[3];
    const struct bl_body_skin *skin;  // per anchor
    const int32_t *parent;            // per bone, -1 for the root
    const int16_t (*slots)[32];       // per strip, the bone in each slot (-1 for none)
};

// A <texture>_mesh.bin's bytes as a mesh (malloc'd, the bytes copied); NULL, said why
// with `path`, when it is not one.
struct bl_body_mesh *char_mesh_parse(const void *bytes, size_t len, const char *path);

// 1 and out filled (out->nidx may be 0: none of the draw is drawn; moved and sharp
// unused); 0 when the draw is not of the model the mesh was made for, or its vertices
// cannot be read (said once per mesh, as `name`).
int char_remodel(const struct prop_in *in, const struct bl_body_mesh *m, const char *name, struct prop_out *out);
