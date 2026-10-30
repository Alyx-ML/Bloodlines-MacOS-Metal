// Upscaled textures (tools/tex_pack.py, made on the player's machine from their own game
// files): drawn in place of the game's texture, which the game itself keeps as it was.
// The game places brush textures by their size in texels, so the larger texture only
// ever reaches the GPU. A texture is recognised by the exact contents the game gave its
// top level (build/hires/index.txt holds a SHA-1 of each original's three largest
// mipmaps, so a game set to load smaller textures still finds them).
#pragma once
#import <Metal/Metal.h>
#include <stdint.h>

// The upscaled texture for a top level of w x h, D3D format `format`, rows `pitch`
// bytes apart, or nil. `serial` and `fills` name the texture and how many times the game
// has changed its top level: when bl_hires_prefetch already hashed that same fill, its
// hash is used instead of hashing the level again on this thread.
id<MTLTexture> bl_hires_texture(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data,
                                uint32_t pitch, uint64_t serial, uint32_t fills);
// Starts loading the upscaled texture for a top level the game just filled, on another
// thread, for bl_hires_texture to find ready when the texture is first drawn (the data
// must stay as it is). Textures loaded ahead and not asked for go after two minutes. The
// hash is kept for the texture `serial` at fill `fills`.
void bl_hires_prefetch(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch,
                       uint64_t serial, uint32_t fills);
// Whether upscaled textures load at full size (the Enhanced tab's "Full-Size Textures",
// metal_render.m) or a size down, never below the original's size: for Macs with 8 GB.
// Taken when a texture loads, so a change shows from the next area.
int bl_hires_full_size(void);
// The game's name for the same top level ("materials/wood/floorb"), from names.txt, or
// NULL. Cheap straight after bl_hires_texture for the same level.
const char *bl_tex_name(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch);
// The same from any thread (no reuse of the last hash), after the first bl_tex_name or
// bl_hires_prefetch.
const char *bl_tex_name_any_thread(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch);
// A level's fingerprint as names.txt and index.txt hold it (any size); 0 for formats not hashed.
uint64_t bl_tex_key(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch);
