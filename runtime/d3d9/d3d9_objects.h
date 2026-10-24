// Direct3D 9 objects handed to guest code. Each COM object is 8 bytes of guest memory
// (vtable, index into the host object table); its state lives in a host `struct obj`.
#pragma once
#include <stdint.h>

#include "bl_vm.h"

#define D3D_OK 0u
#define S_FALSE 1u
#define E_NOINTERFACE 0x80004002u
#define D3DERR_NOTAVAILABLE 0x8876086Au
#define D3DERR_INVALIDCALL 0x8876086Cu

// D3DRESOURCETYPE, plus the non-resource objects.
enum obj_type {
    OBJ_SURFACE = 1, OBJ_VOLUME, OBJ_TEXTURE, OBJ_VOLUMETEXTURE, OBJ_CUBETEXTURE, OBJ_VERTEXBUFFER,
    OBJ_INDEXBUFFER, OBJ_D3D = 100, OBJ_DEVICE, OBJ_SWAPCHAIN, OBJ_VDECL, OBJ_VSHADER, OBJ_PSHADER,
    OBJ_STATEBLOCK, OBJ_QUERY, OBJ_DINPUT = 200, OBJ_DINPUT_DEVICE, OBJ_DSOUND = 300, OBJ_DSOUND_BUFFER,
};

struct obj {
    uint32_t guest;            // the COM pointer guest code holds
    enum obj_type type;
    uint32_t refs;
    struct obj *owner;         // texture of a level surface, device of its back buffer:
                               // reference counting goes to the owner
    // resources
    uint32_t format, usage, pool, width, height, depth, levels;
    uint32_t multisample;
    uint32_t mem, size, pitch, slice;  // guest memory and its layout
    struct obj **subs;         // texture levels (cube: face * levels + level)
    uint32_t nsubs;
    uint32_t fvf;              // vertex buffers
    uint32_t query_type;
    uint32_t input_kind, input_state_size;  // DirectInput devices (dinput8.c)
    void *gpu;                 // renderer's texture or buffer (metal_render.m)
    void *gpu_ms;              // back buffer and auto depth: the multisampled copy drawn into
    int ms_stale;              // gpu was written without going through gpu_ms
    void *sound;               // DirectSound buffer state (dsound.c)
    int dirty;                 // guest memory changed since the last upload
    int rewrites;              // static vertex buffers: times rewritten after first use
    int used;                  // textures: bound for a draw since the last upload
};

struct obj *obj_new(enum obj_type type, uint32_t vtbl);
struct obj *obj_of(uint32_t guest);  // NULL for 0, fatal for a pointer that is not ours
uint32_t obj_addref(struct obj *o);
uint32_t obj_release(struct obj *o);

// Bytes per pixel, or for block-compressed formats bytes per 4x4 block (with *block = 1).
uint32_t d3d_format_size(uint32_t format, int *block);
// Guest memory for a surface or volume of this format and size, with pitch and slice.
void d3d_alloc_image(struct obj *o, uint32_t w, uint32_t h, uint32_t d);

#define G32(addr) (*(uint32_t *)bl_g2h(addr))
static inline uint32_t f2u(float f) { union { float f; uint32_t u; } x = { .f = f }; return x.u; }
static inline float u2f(uint32_t u) { union { float f; uint32_t u; } x = { .u = u }; return x.f; }
