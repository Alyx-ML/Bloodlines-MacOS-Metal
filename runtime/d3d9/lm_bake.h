// The lighting rebake: a map's lightmaps baked again on the GPU from its own lights and
// surfaces (bl_bsp_world_load), with `scale` times the luxels along each side,
// ray-traced shadows (Metal's ray tracing, which M1 runs without hardware for it) and
// several bounces. The lights are taken as the map compiler (vrad) left them in the
// world lights lump and fall off as it computed them; bounced light takes each
// texture's reflectivity, as vrad's does.
//
// Every lit face is baked: the world's, brush entities' and displacements' (the outdoor
// ground, its luxels on the displaced surface). Shadows come from the world, brush
// entities, displacements and props (bl_props.h: box props as boxes, others with their
// collision models or visible meshes). Lights with a style (ones that switch or flicker)
// are left out: the renderer keeps what the game's own lightmaps have of them.
#pragma once
#import <Metal/Metal.h>
#include "bl_bsp.h"

struct bl_bake_face {
    int offset;  // first luxel in bl_bake.light; -1: not baked
    int w, h;    // luxels: (size + 1) * scale along each side, row by row: each of the map's
                 // luxels split into scale x scale, so luxel x sits at lightmap s = mins +
                 // (x + 0.5) / scale - 0.5 and the bake drops into a page `scale` times the
                 // size of the game's, texel for texel
};
struct bl_bake {
    int scale;
    int nluxels;
    struct bl_bake_face *faces;  // one per world face
    uint32_t (*light)[4];        // per luxel: flat, then the three bump directions; linear light
                                 // packed as RGB9E5 (bl_bake_unpack, MTLPixelFormatRGB9E5Float)
    double seconds;
    int cached;                  // read from the cache, not baked
    char summary[512];
};
// The scale bl_rebake_get bakes the map at: 4, or less where 4 would pass 8 million luxels
// (the biggest maps: 2).
int bl_bake_scale(const struct bl_bsp_world *w);
struct bl_bake *bl_bake_map(id<MTLDevice> dev, const struct bl_bsp_world *w, int scale, int bounces, char *err,
                            int errlen);
void bl_bake_free(struct bl_bake *b);
// The bump directions of a face, in world space, as vrad builds them from its texture axes.
void bl_bake_bump_normals(const struct bl_bsp_world *w, const struct bl_bsp_face *f, float out[3][3]);
// Decodes one of the map's RGBE lightmap samples to linear light.
void bl_bake_rgbe(const uint8_t *s, float out[3]);
uint32_t bl_bake_pack(const float rgb[3]);
void bl_bake_unpack(uint32_t v, float rgb[3]);

// The open map's rebake, for the renderer (metal_render.m, lightmaps). Each map's path is
// noted as the game opens it (gi_probes.m, bl_map_note); the first ask with start set
// reads the map again and, with bake set, bakes it (bl_bake_scale, 3 bounces) on a thread
// of its own, or reads the bake from the cache (~/Library/Caches/Vampire The Masquerade -
// Bloodlines/lightmaps, one file per map, for its size and date); without bake: the map
// alone, bake NULL, for its own samples. gen counts the maps opened, so the renderer can
// tell a bake is for the map it draws.
struct bl_rebake {
    int gen;
    struct bl_bsp_world *world;
    struct bl_bake *bake;
};
void bl_rebake_note_path(const char *host_path);
// The open map's bake once it is done, else NULL; good until the map after next opens.
const struct bl_rebake *bl_rebake_get(int start, int bake);
int bl_rebake_gen(void);
// Called once a frame the game draws the world: a bake then sends only one small slice of
// its work a frame, so play stays smooth while it runs (a hub's takes about two minutes);
// with no such frame for a quarter second (loading, menus) it runs flat out.
void bl_bake_world_frame(void);
