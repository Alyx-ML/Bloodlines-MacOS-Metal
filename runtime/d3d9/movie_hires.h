// Upscaled intro movies (tools/movie_upscale.sh, made on the player's machine from their
// own game files): build/hires/movies/<movie>.mov, twice the size, frame for frame, and
// <movie>.sig, each of the original's frames shrunk to 8x8 RGB. Bink still plays the
// movie, its sound and its timing; the frame it draws is found among the originals by
// that 8x8 picture, and the same frame of the .mov is drawn in its place.
#pragma once
#import <Metal/Metal.h>
#include <stdint.h>

// The upscaled frame for the part sr (x0, y0, x1, y1) of Bink's w x h frame `pixels`
// (32-bit BGRX rows, bottom row first when `bottom_up`), or nil when there is none.
id<MTLTexture> bl_movie_frame(id<MTLDevice> dev, const void *pixels, uint32_t w, uint32_t h, int bottom_up,
                              const uint32_t sr[4]);
