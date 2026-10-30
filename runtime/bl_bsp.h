// The map the game opened (its .bsp, read from the player's own files): its lights and
// what can be seen from where, for the volumetric lighting (metal_render.m fog_run).
#pragma once
#include <stdint.h>
#include "bl_props.h"

struct bl_light {
    float pos[3];        // world units
    float color[3];      // intensity, as the map compiler stored it (falls off with att)
    float dir[3];        // spot lights: where they point
    float att[3];        // constant, linear and quadratic falloff
    float radius;        // 0: none, else the light ends there
    float inner, outer;  // spot lights: cosines of the full and the zero cone; 0 0 for points
    float exponent;      // spot lights: falloff inside the full cone
    float vis;           // 0..1: how much it shows from the camera (smoothed over frames)
    float seen;          // 0..1: whether it is in the part of the map the camera is in (smoothed):
                         // for lighting things, which a fitting hiding it from the camera does not darken
    int spot;            // 1 a spot
};

// Called with the host path of each file the game opens; a .bsp under maps/ is loaded.
void bl_bsp_note_open(const char *host_path);
// Up to max lights for a camera at cam, brightest first: those that can be seen from
// the camera's part of the map, fading out over a few frames when a wall comes between.
// Returns how many.
int bl_bsp_lights(const float cam[3], struct bl_light *out, int max);

// The map's surfaces and baked light, for baking it again (the lighting rebake): its
// faces with their corners, textures and place in the lighting lump, and every light
// the map compiler worked with.
struct bl_bsp_face {
    int first, count;      // corners: world->index[first .. first + count), in order round the face
    float normal[3];       // the way it faces (its plane's)
    float dist;            // plane: dot(normal, p) = dist
    int texinfo;           // into world->texinfo; -1 none
    int model;             // 0 the world, else a brush entity (a door, a window)
    float origin[3];       // where its brush entity stands: its corners and plane are the
                           // model's own, so add this for the world position; 0 for the world
    int disp;              // displacement: -1 none
    int dfirst, dside;     // a displacement's surface: dside x dside points, rows from its
                           // start corner to the next, world->dverts[dfirst ..]; dside 0: none
    int lightofs;          // into world->lighting, in samples (4 bytes each); -1: no lightmap
    uint8_t styles[8];     // light styles, 255 unused; each a set of samples
    int nstyles;
    int bumped;            // 4 sample sets per style: flat, then the three bump directions
    int mins[2], size[2];  // the lightmap: luxel coordinates of its corner, and size - 1
    float area;
};
struct bl_bsp_texinfo {
    float tex[2][4];  // texture s, t = dot(p, xyz) + w, in texels
    float lm[2][4];   // lightmap s, t, in luxels (before the face's mins)
    int flags;        // SURF_*: 0x4 sky, 0x80 nodraw, 0x800 bump-mapped lightmap...
    int texdata;
};
struct bl_bsp_texdata {
    float reflectivity[3];  // the texture's mean colour, linear, as the map compiler used it
    int width, height;
    char name[128];         // material, without materials/ and .vmt
};
struct bl_bsp_worldlight {  // dworldlight_t
    float origin[3], intensity[3], normal[3];
    int cluster, type;      // 0 surface, 1 point, 2 spot, 3 sky (sun), 4 quake, 5 sky ambient
    int style;
    float stopdot, stopdot2, exponent, radius;
    float att[3];           // constant, linear, quadratic
    int flags, texinfo, owner;
};
struct bl_bsp_world {
    char name[128];  // e.g. sm_asylum_1.bsp
    float (*verts)[3];
    int nverts;
    int *index;      // the faces' corners, vertex numbers
    int nindex;
    struct bl_bsp_face *faces;
    int nfaces;
    struct bl_bsp_texinfo *texinfo;
    int ntexinfo;
    struct bl_bsp_texdata *texdata;
    int ntexdata;
    struct bl_bsp_worldlight *lights;
    int nlights;
    struct bl_bsp_dvert { float pos[3], lux[2]; } *dverts;  // displacements' points, luxels
                                                            // from their lightmap's corner
    int ndverts;
    uint8_t *lighting;  // the lighting lump: RGBE samples (r, g, b, signed exponent)
    int nsamples;
    int means;          // each face's mean colour per style comes before its samples
    int nmodels;
    struct bl_props *props;  // the static props that cast shadows (NULL: their lump not as expected)
    char props_err[128];
    // The BSP tree, to tell open space from solid (bl_bsp_world_open).
    float (*planes)[4];  // normal, dist
    int nplanes;
    int (*nodes)[3];     // plane, front child, back child (a child < 0: leaf -1 - child)
    int nnodes;
    int (*leaves)[2];    // contents, cluster
    int nleaves;
};
// The map at host_path; NULL with err filled when it cannot be read.
struct bl_bsp_world *bl_bsp_world_load(const char *host_path, char *err, int errlen);
// The same without the static props (their models are many files to read), for uses
// that need only the faces and their lighting.
struct bl_bsp_world *bl_bsp_world_load_no_props(const char *host_path, char *err, int errlen);
void bl_bsp_world_free(struct bl_bsp_world *w);
// 1 where p is in the map's open space: a leaf that is not solid and belongs to a cluster
// (outside the map, leaves have none).
int bl_bsp_world_open(const struct bl_bsp_world *w, const float p[3]);
// Checks that the lightmaps' layout is read right: each face's samples fit the lighting
// lump without overlapping, and its corners' luxel coordinates fall inside its lightmap.
// Writes a one-line summary to buf; returns the number of faces that fail.
int bl_bsp_world_check(const struct bl_bsp_world *w, char *buf, int len);
