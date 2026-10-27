// Light probes for characters and props (global illumination): a grid through the open
// map, each point's light from around it as Source's ambient cube (six colours, one per
// axis direction), so models take the colour and brightness of the room where they
// stand. Captured by rendering, not ray tracing: at each point the map is drawn six ways
// (a small cube map) with its own lightmaps on each texture's mean colour, and the
// light seen is summed per direction. The map's lights are added straight, where the
// cube map shows nothing nearer in their direction. Takes the map's surfaces from bl_bsp
// (bl_map_note), and the static props that cast shadows (bl_props: lit from a first
// capture without them, on the map's mean colour); not yet: displacements.
#pragma once
#import <Metal/Metal.h>
#include "bl_bsp.h"
#include "bl_props.h"

#define GI_VIS 8  // how far each probe sees: cells across each of its six views

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
    // Per probe, how far it sees over each of its six views' GI_VIS x GI_VIS cells (mean and
    // mean square of the distances, up to twice the step, in steps): a probe whose view ends before a
    // point (a wall between) gives it no light.
    _Float16 (*vis)[6 * GI_VIS * GI_VIS][2];
    uint8_t *valid;       // 0: too near a wall's back to tell (inside it, or the void beyond)
    int nvalid;
    double seconds;
    char summary[256];
};
struct bl_gi *bl_gi_capture(id<MTLDevice> dev, const struct bl_bsp_world *w, char *err, int errlen);
void bl_gi_free(struct bl_gi *g);
// The light at p, blended from the valid probes round it (of the eight grid points) that
// can see it. Returns 0 where there are none.
int bl_gi_sample(const struct bl_gi *g, const float p[3], float bounce[6][3], float direct[6][3]);
// How much of probe i's light reaches the point d from it: 1 when what the probe saw that
// way is no nearer, falling off as Chebyshev's bound on its distances there (as DDGI) when
// its view ends first: there is a wall between.
float bl_gi_seen(const struct bl_gi *g, int i, const float d[3]);

// The open map's probes, for the renderer: bl_bsp hands each map over as the game opens it
// (bl_map_note keeps its surfaces); the first ask with start set captures them on a thread
// of their own. NULL until done; good until the map after next opens.
void bl_map_note(struct bl_bsp_world *w, const char *host_path);
const struct bl_gi *bl_gi_get(int start);
int bl_gi_gen(void);
