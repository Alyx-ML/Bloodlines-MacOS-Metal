// A map's static props as shadow casters, for the lighting rebake: each prop that casts
// shadows (not flagged otherwise) placed in the world as the map compiler (vrad) cast
// their shadows: box props (solid type 3) as their model's box, others as their collision
// model (.phy), or their visible mesh when they have none. The models come from the player's own game files: the mod's and
// then the game's own folder, loose files before the .vpk archives.
#pragma once
#include <stdint.h>

struct bl_props {
    float (*tris)[3][3];  // world space
    int ntris;
    int nprops;           // static props in the map
    int nshadow;          // of those, ones that cast shadows
    int nfound;           // of those, ones whose shape was read
    int nbox;             // of those, box props, shaped by their model's box
    int nmesh;            // of those, ones with no collision model, shaped by their visible mesh
};
// From the .bsp at bsp_path (its contents: file, size bytes); NULL with err filled when
// the static props lump cannot be read.
struct bl_props *bl_props_load(const char *bsp_path, const uint8_t *file, long size, char *err, int errlen);
void bl_props_free(struct bl_props *p);
