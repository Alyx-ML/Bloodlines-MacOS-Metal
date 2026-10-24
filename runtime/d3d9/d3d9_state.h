// Device state as guest code sets it, and the renderer interface that consumes it.
#pragma once
#include <stdint.h>

#include "d3d9_objects.h"

struct d3d_state {
    uint32_t pp[14];               // D3DPRESENT_PARAMETERS
    uint32_t creation[4];          // D3DDEVICE_CREATION_PARAMETERS
    uint32_t rs[256];              // render states
    uint32_t tss[8][33];           // texture stage states
    uint32_t ss[20][14];           // sampler states: 16 pixel, 4 vertex samplers
    struct obj *texture[20];
    struct obj *stream[16];
    uint32_t stream_offset[16], stream_stride[16], stream_freq[16];
    struct obj *indices, *vdecl, *vs, *ps;
    uint32_t fvf;
    struct obj *render_target[4], *depth_stencil, *back_buffer, *auto_depth;
    uint32_t viewport[6];          // D3DVIEWPORT9: X, Y, Width, Height, MinZ, MaxZ (floats)
    uint32_t scissor[4];           // RECT
    uint32_t transform[28][16];    // 0-23 by D3DTRANSFORMSTATETYPE, 24-27 WORLD..WORLD3
    uint32_t material[17];
    uint32_t light[8][26];
    int light_on[8];
    uint32_t clip_plane[6][4];
    uint32_t vs_f[256][4], vs_i[16][4], vs_b[16];
    uint32_t ps_f[224][4], ps_i[16][4], ps_b[16];
    uint16_t gamma[3][256];
};

void d3d_state_defaults(struct d3d_state *s);

// Renderer (d3d9_render.c).
void d3d_render_init(uint32_t window);
void d3d_render_resize(uint32_t width, uint32_t height);
void d3d_render_windowed(int windowed);  // the game's Windowed flag: full screen when 0
void d3d_render_present(struct d3d_state *s);
void d3d_render_clear(struct d3d_state *s, uint32_t count, uint32_t rects, uint32_t flags, uint32_t color, float z,
                      uint32_t stencil);
// Draw from the bound streams; indexed draws read the bound index buffer from `start`.
void d3d_render_draw(struct d3d_state *s, uint32_t type, int32_t base_vertex, uint32_t min_index, uint32_t nverts,
                     uint32_t start, uint32_t count, int indexed, uint32_t unused0, uint32_t unused1);
// Draw from guest memory (DrawPrimitiveUP / DrawIndexedPrimitiveUP; indices = 0 for the former).
void d3d_render_draw_up(struct d3d_state *s, uint32_t type, uint32_t min_index, uint32_t nverts, uint32_t count,
                        uint32_t indices, uint32_t index_format, uint32_t data, uint32_t stride);
void d3d_render_stretch(struct obj *src, uint32_t src_rect, struct obj *dst, uint32_t dst_rect, uint32_t filter);
void d3d_render_color_fill(struct obj *surf, uint32_t rect, uint32_t color);
void d3d_render_present_pixels(const void *pixels, uint32_t w, uint32_t h, int bottom_up, const int32_t src_rect[4],
                               const int32_t dst_rect[4]);  // a GDI blit to the window
void d3d_render_read_back(struct obj *render_target);  // GPU contents into guest memory
void d3d_image_changed(struct obj *surface);            // guest memory written (unlock)
void d3d_buffer_changed(struct obj *buffer);
void d3d_render_free(struct obj *o);                    // object destroyed: drop its GPU copy
void d3d_render_shader_created(struct obj *shader);     // start compiling it in the background
