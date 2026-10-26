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
// bytes apart, or nil.
id<MTLTexture> bl_hires_texture(id<MTLDevice> dev, uint32_t w, uint32_t h, uint32_t format, const uint8_t *data,
                                uint32_t pitch);
