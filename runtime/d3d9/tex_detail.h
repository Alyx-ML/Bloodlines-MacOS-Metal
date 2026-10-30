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
// when the game refills it. `fills` counts the game's changes to the top level: when
// bl_detail_prefetch already matched that same fill of the texture `key`, its match is used.
id<MTLTexture> bl_detail_normal(id<MTLDevice> dev, uint64_t key, uint32_t stamp, uint32_t fills, uint32_t w, uint32_t h,
                                uint32_t format, const uint8_t *data, uint32_t pitch, id<MTLTexture> *color);

// Starts loading the normal map and upscaled colour for a top level the game just filled,
// on another thread, for bl_detail_normal to find ready (the data must stay as it is). The
// match is kept for the texture `key` (its serial) at fill `fills`.
void bl_detail_prefetch(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch,
                        uint64_t key, uint32_t fills);

// The surfaces' PBRify normal map for `path` (a <name>_n.png, with <name>_r.png's
// roughness in alpha) as tools/tex_bake_maps.m stored it in <name>_n.tex: BC7, worked out
// as the characters' maps are (map_levels.h); nil when not baked.
id<MTLTexture> bl_load_normal_map(id<MTLDevice> dev, const char *path);

// The height map for `path` (a <name>_h.png, white high) for the surfaces' parallax, as
// tools/tex_bake_maps.m stored it in <name>_h.tex: R8, stretched so its 1st to 99th
// percentile span 0 to 1, with box-filtered mipmaps; nil when not baked.
id<MTLTexture> bl_load_height_map(id<MTLDevice> dev, const char *path);

// Whether the texture `key` (w x h) is a face or a head by its file's name (with "face"
// or "head" in it, not "hair"), for the skin detail; after bl_detail_normal saw it.
int bl_detail_is_face(uint64_t key, uint32_t w, uint32_t h);

// Where a body texture `key` (w x h) shows skin (R8, 1 skin), from its colours when its
// map was loaded; for a face, where its pores go and how big (RG8: strength, size less
// 0.5); nil for textures without a map.
id<MTLTexture> bl_detail_skin_mask(uint64_t key, uint32_t w, uint32_t h);

// A flat normal map (roughness 0.5) for character parts without one of their own (hair,
// teeth, characters not in the list), so they get the same light as the rest.
id<MTLTexture> bl_detail_flat(id<MTLDevice> dev);

// Hair redrawn as strips (made by the hair tools on the player's machine from their own
// game files, beside the texture's normal map path as <name>_hair.bin and _hair.png): the
// strips, in the space of `anchors` (the game's hair vertices they replace, in the same
// units as the tools' import), with their own texture; or, with no strips, the part of
// the game's hair to keep drawing, as a rectangle of its texture coordinates (`keep`).
// Strands (version 3 of the file): points along the strands, whose indices are pairs (a
// segment each), drawn by the renderer itself (metal_render.m, hair_run).
struct bl_hair_mesh {
    uint32_t nverts, nidx, nanchors;
    const float *verts;  // nverts x {position xyz, normal xyz, uv}
    const float *strand; // strands: nverts x {colour rgb, half-width}; else NULL
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
const struct bl_hair_mesh *bl_detail_hair(id<MTLDevice> dev, uint64_t key, uint32_t w, uint32_t h);

// A character rebuilt for the texture `key` (w x h): its mesh (char_remodel.h, made by
// tools/bodies/export_game_mesh.py beside the texture's normal map as <name>_mesh.bin),
// or NULL; after bl_detail_normal saw it. `name` is set to the file's name.
struct bl_body_mesh;
const struct bl_body_mesh *bl_detail_body(uint64_t key, uint32_t w, uint32_t h, const char **name);

// The texture `key` (w x h) is gone: what was remembered for it is dropped.
void bl_detail_forget(uint64_t key, uint32_t w, uint32_t h);
