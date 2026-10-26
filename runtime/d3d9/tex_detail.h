// Normal maps for characters' colour textures, made on the player's machine from their own
// game files (tools/tex_extract.py, tools/tex_normals.py): the renderer (metal_render.m)
// asks for the one that goes with a texture the game loaded, recognised by its size and
// colours, since the game's copy of the texture is its own (another format, maybe a
// smaller mipmap) and has no name.
#pragma once
#import <Metal/Metal.h>
#include <stdint.h>

// The normal map for the texture `key` (whose top level the game filled: w x h of D3D
// format `format`, rows `pitch` bytes apart), or nil; *color the upscaled texture to draw
// in its place (tools/tex_upscale.py), or nil. Remembered per texture; `stamp` changes
// when the game refills it.
id<MTLTexture> bl_detail_normal(id<MTLDevice> dev, const void *key, uint32_t stamp, uint32_t w, uint32_t h,
                                uint32_t format, const uint8_t *data, uint32_t pitch, id<MTLTexture> *color);

// Starts loading the normal map and upscaled colour for a top level the game just filled,
// on another thread, for bl_detail_normal to find ready (the data must stay as it is).
void bl_detail_prefetch(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch);

// A normal map at `path` (a <name>_n.png, with <name>_r.png's roughness in alpha), as
// the characters' are loaded: xyz the normal, mipmaps renormalised; nil without one.
id<MTLTexture> bl_load_normal_map(id<MTLDevice> dev, const char *path);

// A flat normal map (roughness 0.5) for character parts without one of their own (hair,
// teeth, characters not in the list), so they get the same light as the rest.
id<MTLTexture> bl_detail_flat(id<MTLDevice> dev);

// Hair redrawn as strips (made by the hair tools on the player's machine from their own
// game files, beside the texture's normal map path as <name>_hair.bin and _hair.png): the
// strips, in the space of `anchors` (the game's hair vertices they replace, in the same
// units as the tools' import), with their own texture; or, with no strips, the part of
// the game's hair to keep drawing, as a rectangle of its texture coordinates (`keep`).
struct bl_hair_mesh {
    uint32_t nverts, nidx, nanchors;
    const float *verts;  // nverts x {position xyz, normal xyz, uv}
    const uint32_t *idx;
    const float *anchors;  // nanchors x xyz
    float keep[4];         // u0, v0, u1, v1
    // With strips, the game's triangles still drawn under them, by their centres in the
    // anchors' space (all of them when nbase is 0).
    uint32_t nbase;
    const float *base;  // nbase x xyz
    id<MTLTexture> tex;
    id<MTLTexture> base_color;  // with strips: the game's hair under them in their colour, or nil
};

// The hair mesh for the texture `key` (w x h), or NULL; after bl_detail_normal saw it.
const struct bl_hair_mesh *bl_detail_hair(id<MTLDevice> dev, const void *key, uint32_t w, uint32_t h);
