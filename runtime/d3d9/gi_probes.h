// Light probes for characters and props (global illumination): a grid through the open
// map, each point's light from around it as Source's ambient cube (six colours, one per
// axis direction), so models take the colour and brightness of the room where they
// stand. Captured by rendering, not ray tracing: at each point the map is drawn six ways
// (a small cube map) with its own lightmaps on each texture's mean colour, and the
// light seen is summed per direction. The map's lights are added straight, where the
// cube map shows nothing nearer in their direction. Takes the map's surfaces from bl_bsp
// (bl_map_note); not yet: static props (they are not in the captures), displacements.
#pragma once
#import <Metal/Metal.h>
#include "bl_bsp.h"

struct bl_gi {
    int gen;              // the map it is for (bl_gi_gen)
    float origin[3];      // the grid's first point
    float step;           // between points, world units
    int n[3];             // points along x, y, z
    // Probes only where models go: in the map's open space, with a floor at most a few
    // feet below. slot[(z * n[1] + y) * n[0] + x]: the point's probe, -1 none.
    int *slot, nprobes;
    // Per probe, +x -x +y -y +z -z, linear, in lightmap units (a model lit by a cube of 1
    // everywhere shows its texture as a wall with a lightmap of 1 does): the light from
    // the map's surfaces, and from its point and spot lights.
    float (*bounce)[6][3], (*direct)[6][3];
    uint8_t *valid;       // 0: too near a wall's back to tell (inside it, or the void beyond)
    int nvalid;
    double seconds;
    char summary[256];
};
struct bl_gi *bl_gi_capture(id<MTLDevice> dev, const struct bl_bsp_world *w, char *err, int errlen);
void bl_gi_free(struct bl_gi *g);
// The light at p, blended from the valid probes round it (of the eight grid points). Returns 0 where there are none.
int bl_gi_sample(const struct bl_gi *g, const float p[3], float bounce[6][3], float direct[6][3]);

// The open map's probes, for the renderer: bl_bsp hands each map over as the game opens it
// (bl_map_note keeps its surfaces); the first ask with start set captures them on a thread
// of their own. NULL until done; good until the map after next opens.
void bl_map_note(struct bl_bsp_world *w, const char *host_path);
const struct bl_gi *bl_gi_get(int start);
int bl_gi_gen(void);
