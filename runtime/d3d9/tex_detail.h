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

// A flat normal map (roughness 0.5) for character parts without one of their own (hair,
// teeth, characters not in the list), so they get the same light as the rest.
id<MTLTexture> bl_detail_flat(id<MTLDevice> dev);
