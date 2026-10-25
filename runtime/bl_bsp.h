// The map the game opened (its .bsp, read from the player's own files): its lights and
// what can be seen from where, for the volumetric lighting (metal_render.m fog_run).
#pragma once
#include <stdint.h>

struct bl_light {
    float pos[3];        // world units
    float color[3];      // intensity, as the map compiler stored it (falls off with att)
    float dir[3];        // spot lights: where they point
    float att[3];        // constant, linear and quadratic falloff
    float radius;        // 0: none, else the light ends there
    float inner, outer;  // spot lights: cosines of the full and the zero cone; 0 0 for points
    float exponent;      // spot lights: falloff inside the full cone
    float vis;           // 0..1: how much it shows from the camera (smoothed over frames)
    int spot;
};

// Called with the host path of each file the game opens; a .bsp under maps/ is loaded.
void bl_bsp_note_open(const char *host_path);
// Up to max lights for a camera at cam, brightest first: those that can be seen from
// the camera's part of the map, fading out over a few frames when a wall comes between.
// Returns how many.
int bl_bsp_lights(const float cam[3], struct bl_light *out, int max);
