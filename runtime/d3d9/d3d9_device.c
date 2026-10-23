// IDirect3DDevice9 (one device) and its swap chain. Every Set* is stored and every
// Get* answers from that state; draws, clears and Present go to the renderer hooks in
// d3d9_render.c.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "com_gen.h"
#include "d3d9_objects.h"
#include "d3d9_state.h"

struct obj *d3d_new_surface(uint32_t w, uint32_t h, uint32_t format, uint32_t usage, uint32_t pool, uint32_t multisample);
uint32_t d3d_create_texture(uint32_t w, uint32_t h, uint32_t levels, uint32_t usage, uint32_t format, uint32_t pool, uint32_t out);
uint32_t d3d_create_volume_texture(uint32_t w, uint32_t h, uint32_t d, uint32_t levels, uint32_t usage, uint32_t format, uint32_t pool, uint32_t out);
uint32_t d3d_create_cube_texture(uint32_t edge, uint32_t levels, uint32_t usage, uint32_t format, uint32_t pool, uint32_t out);
uint32_t d3d_create_vertex_buffer(uint32_t len, uint32_t usage, uint32_t fvf, uint32_t pool, uint32_t out);
uint32_t d3d_create_index_buffer(uint32_t len, uint32_t usage, uint32_t format, uint32_t pool, uint32_t out);
uint32_t d3d_create_vertex_declaration(uint32_t elements, uint32_t out);
uint32_t d3d_create_shader(enum obj_type type, uint32_t code, uint32_t out);
uint32_t d3d_create_query(uint32_t type, uint32_t out);
uint32_t d3d_create_state_block(uint32_t out);
uint32_t d3d_guest(void);
void d3d_fill_caps(uint32_t caps);

struct d3d_state st;
static struct obj *device, *swapchain;

uint32_t d3d_device_guest(void) { return device->guest; }
uint32_t d3d_viewport_word(int i) { return st.viewport[i]; }

static void hold(struct obj **slot, uint32_t guest)
{
    struct obj *o = obj_of(guest);
    if (o) obj_addref(o);
    if (*slot) obj_release(*slot);
    *slot = o;
}

static void give(uint32_t out, struct obj *o)
{
    if (!out) return;
    if (o) obj_addref(o);
    G32(out) = o ? o->guest : 0;
}

// Back buffer and automatic depth buffer from D3DPRESENT_PARAMETERS (56 bytes).
int bl_window_client_size(uint32_t h, uint32_t *w, uint32_t *hgt);

static void make_back_buffers(void)
{
    // Windowed with a zero size: the device window's client area (hDeviceWindow, else
    // the focus window).
    uint32_t cw, ch;
    if ((!st.pp[0] || !st.pp[1]) && st.pp[8] && bl_window_client_size(st.pp[7] ? st.pp[7] : st.creation[2], &cw, &ch)) {
        if (!st.pp[0]) st.pp[0] = cw;
        if (!st.pp[1]) st.pp[1] = ch;
    }
    if (!st.pp[0]) st.pp[0] = 1024;
    if (!st.pp[1]) st.pp[1] = 768;
    if (!st.pp[2]) st.pp[2] = 22;  // X8R8G8B8
    struct obj *old_back = st.back_buffer, *old_depth = st.auto_depth;
    st.back_buffer = d3d_new_surface(st.pp[0], st.pp[1], st.pp[2], 1, 0, 0);
    st.back_buffer->owner = device;
    st.auto_depth = NULL;
    if (st.pp[9]) {  // EnableAutoDepthStencil
        st.auto_depth = d3d_new_surface(st.pp[0], st.pp[1], st.pp[10], 2, 0, 0);
        st.auto_depth->owner = device;
    }
    hold(&st.render_target[0], st.back_buffer->guest);
    hold(&st.depth_stencil, st.auto_depth ? st.auto_depth->guest : 0);
    // The old buffers belonged to the device; the game has released its references.
    if (old_back) old_back->owner = NULL, obj_release(old_back);
    if (old_depth) old_depth->owner = NULL, obj_release(old_depth);
    st.viewport[0] = 0, st.viewport[1] = 0, st.viewport[2] = st.pp[0], st.viewport[3] = st.pp[1];
    st.viewport[4] = f2u(0.0f), st.viewport[5] = f2u(1.0f);
    st.scissor[0] = 0, st.scissor[1] = 0, st.scissor[2] = st.pp[0], st.scissor[3] = st.pp[1];
    d3d_render_resize(st.pp[0], st.pp[1]);
    d3d_render_windowed(st.pp[8] != 0);
}

uint32_t bl_IDirect3D9_CreateDevice_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t window, uint32_t flags,
                                     uint32_t pp, uint32_t out)
{
    (void)self;
    if (adapter || device) return D3DERR_INVALIDCALL;
    device = obj_new(OBJ_DEVICE, bl_vtbl_IDirect3DDevice9());
    swapchain = obj_new(OBJ_SWAPCHAIN, bl_vtbl_IDirect3DSwapChain9());
    swapchain->owner = device;
    memcpy(st.pp, bl_g2h(pp), sizeof st.pp);
    st.creation[0] = adapter, st.creation[1] = type, st.creation[2] = window, st.creation[3] = flags;
    d3d_state_defaults(&st);
    make_back_buffers();
    memcpy(bl_g2h(pp), st.pp, sizeof st.pp);  // the runtime fills in defaults
    fprintf(stderr, "[d3d9] device %ux%u format %u, %s, depth %s\n", st.pp[0], st.pp[1], st.pp[2],
            st.pp[8] ? "windowed" : "fullscreen", st.pp[9] ? "auto" : "none");
    d3d_render_init(window);
    G32(out) = device->guest;
    return D3D_OK;
}

// --- device --------------------------------------------------------------------

#define DEV uint32_t self
#define UNUSED (void)self

uint32_t bl_IDirect3DDevice9_TestCooperativeLevel_c(DEV) { UNUSED; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetAvailableTextureMem_c(DEV) { UNUSED; return 256u << 20; }
uint32_t bl_IDirect3DDevice9_EvictManagedResources_c(DEV) { UNUSED; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetDirect3D_c(DEV, uint32_t out)
{
    UNUSED;
    G32(out) = d3d_guest();
    obj_addref(obj_of(G32(out)));
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetDeviceCaps_c(DEV, uint32_t caps) { UNUSED; d3d_fill_caps(caps); return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetDisplayMode_c(DEV, uint32_t chain, uint32_t mode)
{
    UNUSED, (void)chain;
    G32(mode) = st.pp[0], G32(mode + 4) = st.pp[1], G32(mode + 8) = 60, G32(mode + 12) = 22;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetCreationParameters_c(DEV, uint32_t p)
{
    UNUSED;
    memcpy(bl_g2h(p), st.creation, 16);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetCursorProperties_c(DEV, uint32_t x, uint32_t y, uint32_t bmp) { UNUSED, (void)x, (void)y, (void)bmp; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetCursorPosition_c(DEV, uint32_t x, uint32_t y, uint32_t f) { UNUSED, (void)x, (void)y, (void)f; return 0; }
uint32_t bl_IDirect3DDevice9_ShowCursor_c(DEV, uint32_t show) { UNUSED, (void)show; return 0; }

uint32_t bl_IDirect3DDevice9_CreateAdditionalSwapChain_c(DEV, uint32_t pp, uint32_t out) { UNUSED, (void)pp, (void)out; return D3DERR_NOTAVAILABLE; }

uint32_t bl_IDirect3DDevice9_GetSwapChain_c(DEV, uint32_t i, uint32_t out)
{
    UNUSED;
    if (i) return D3DERR_INVALIDCALL;
    give(out, swapchain);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetNumberOfSwapChains_c(DEV) { UNUSED; return 1; }

uint32_t bl_IDirect3DDevice9_Reset_c(DEV, uint32_t pp)
{
    UNUSED;
    memcpy(st.pp, bl_g2h(pp), sizeof st.pp);
    make_back_buffers();
    memcpy(bl_g2h(pp), st.pp, sizeof st.pp);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_Present_c(DEV, uint32_t src, uint32_t dst, uint32_t window, uint32_t dirty)
{
    UNUSED, (void)src, (void)dst, (void)window, (void)dirty;
    d3d_render_present(&st);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetBackBuffer_c(DEV, uint32_t chain, uint32_t i, uint32_t type, uint32_t out)
{
    UNUSED, (void)type;
    if (chain || i) return D3DERR_INVALIDCALL;
    give(out, st.back_buffer);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetRasterStatus_c(DEV, uint32_t chain, uint32_t rs)
{
    UNUSED, (void)chain;
    G32(rs) = 1, G32(rs + 4) = 0;  // in vertical blank
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetDialogBoxMode_c(DEV, uint32_t on) { UNUSED, (void)on; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_SetGammaRamp_c(DEV, uint32_t chain, uint32_t flags, uint32_t ramp)
{
    UNUSED, (void)chain, (void)flags;
    memcpy(st.gamma, bl_g2h(ramp), sizeof st.gamma);
    return 0;
}

uint32_t bl_IDirect3DDevice9_GetGammaRamp_c(DEV, uint32_t chain, uint32_t ramp)
{
    UNUSED, (void)chain;
    memcpy(bl_g2h(ramp), st.gamma, sizeof st.gamma);
    return 0;
}

uint32_t bl_IDirect3DDevice9_CreateTexture_c(DEV, uint32_t w, uint32_t h, uint32_t levels, uint32_t usage, uint32_t fmt,
                                            uint32_t pool, uint32_t out, uint32_t shared)
{
    UNUSED, (void)shared;
    return d3d_create_texture(w, h, levels, usage, fmt, pool, out);
}

uint32_t bl_IDirect3DDevice9_CreateVolumeTexture_c(DEV, uint32_t w, uint32_t h, uint32_t d, uint32_t levels, uint32_t usage,
                                                  uint32_t fmt, uint32_t pool, uint32_t out, uint32_t shared)
{
    UNUSED, (void)shared;
    return d3d_create_volume_texture(w, h, d, levels, usage, fmt, pool, out);
}

uint32_t bl_IDirect3DDevice9_CreateCubeTexture_c(DEV, uint32_t edge, uint32_t levels, uint32_t usage, uint32_t fmt,
                                                uint32_t pool, uint32_t out, uint32_t shared)
{
    UNUSED, (void)shared;
    return d3d_create_cube_texture(edge, levels, usage, fmt, pool, out);
}

uint32_t bl_IDirect3DDevice9_CreateVertexBuffer_c(DEV, uint32_t len, uint32_t usage, uint32_t fvf, uint32_t pool,
                                                 uint32_t out, uint32_t shared)
{
    UNUSED, (void)shared;
    return d3d_create_vertex_buffer(len, usage, fvf, pool, out);
}

uint32_t bl_IDirect3DDevice9_CreateIndexBuffer_c(DEV, uint32_t len, uint32_t usage, uint32_t fmt, uint32_t pool,
                                                uint32_t out, uint32_t shared)
{
    UNUSED, (void)shared;
    return d3d_create_index_buffer(len, usage, fmt, pool, out);
}

uint32_t bl_IDirect3DDevice9_CreateRenderTarget_c(DEV, uint32_t w, uint32_t h, uint32_t fmt, uint32_t ms, uint32_t q,
                                                 uint32_t lockable, uint32_t out, uint32_t shared)
{
    UNUSED, (void)q, (void)lockable, (void)shared;
    G32(out) = d3d_new_surface(w, h, fmt, 1, 0, ms)->guest;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_CreateDepthStencilSurface_c(DEV, uint32_t w, uint32_t h, uint32_t fmt, uint32_t ms, uint32_t q,
                                                        uint32_t discard, uint32_t out, uint32_t shared)
{
    UNUSED, (void)q, (void)discard, (void)shared;
    G32(out) = d3d_new_surface(w, h, fmt, 2, 0, ms)->guest;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_CreateOffscreenPlainSurface_c(DEV, uint32_t w, uint32_t h, uint32_t fmt, uint32_t pool,
                                                          uint32_t out, uint32_t shared)
{
    UNUSED, (void)shared;
    G32(out) = d3d_new_surface(w, h, fmt, 0, pool, 0)->guest;
    return D3D_OK;
}

// Copies between surfaces of the same format and size are done in guest memory;
// the renderer is told the destination changed.
static void copy_image(struct obj *src, struct obj *dst)
{
    if (!src || !dst || src->format != dst->format || src->width != dst->width || src->height != dst->height) return;
    memcpy(bl_g2h(dst->mem), bl_g2h(src->mem), src->size < dst->size ? src->size : dst->size);
    d3d_image_changed(dst);
}

uint32_t bl_IDirect3DDevice9_UpdateSurface_c(DEV, uint32_t src, uint32_t rect, uint32_t dst, uint32_t point)
{
    UNUSED, (void)rect, (void)point;
    copy_image(obj_of(src), obj_of(dst));
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_UpdateTexture_c(DEV, uint32_t src, uint32_t dst)
{
    UNUSED;
    struct obj *s = obj_of(src), *d = obj_of(dst);
    for (uint32_t i = 0; i < s->nsubs && i < d->nsubs; i++) copy_image(s->subs[i], d->subs[i]);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetRenderTargetData_c(DEV, uint32_t rt, uint32_t dst)
{
    UNUSED;
    d3d_render_read_back(obj_of(rt));
    copy_image(obj_of(rt), obj_of(dst));
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetFrontBufferData_c(DEV, uint32_t chain, uint32_t dst) { UNUSED, (void)chain, (void)dst; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_StretchRect_c(DEV, uint32_t src, uint32_t srect, uint32_t dst, uint32_t drect, uint32_t filter)
{
    UNUSED;
    d3d_render_stretch(obj_of(src), srect, obj_of(dst), drect, filter);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_ColorFill_c(DEV, uint32_t surf, uint32_t rect, uint32_t color)
{
    UNUSED;
    d3d_render_color_fill(obj_of(surf), rect, color);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetRenderTarget_c(DEV, uint32_t i, uint32_t surf)
{
    UNUSED;
    if (i >= 4 || (i == 0 && !surf)) return D3DERR_INVALIDCALL;
    hold(&st.render_target[i], surf);
    if (i == 0 && surf) {  // the viewport and scissor follow render target 0
        struct obj *s = obj_of(surf);
        st.viewport[0] = 0, st.viewport[1] = 0, st.viewport[2] = s->width, st.viewport[3] = s->height;
        st.viewport[4] = f2u(0.0f), st.viewport[5] = f2u(1.0f);
        st.scissor[0] = 0, st.scissor[1] = 0, st.scissor[2] = s->width, st.scissor[3] = s->height;
    }
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetRenderTarget_c(DEV, uint32_t i, uint32_t out)
{
    UNUSED;
    if (i >= 4) return D3DERR_INVALIDCALL;
    give(out, st.render_target[i]);
    return st.render_target[i] ? D3D_OK : 0x88760866u;  // D3DERR_NOTFOUND
}

uint32_t bl_IDirect3DDevice9_SetDepthStencilSurface_c(DEV, uint32_t surf) { UNUSED; hold(&st.depth_stencil, surf); return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetDepthStencilSurface_c(DEV, uint32_t out)
{
    UNUSED;
    give(out, st.depth_stencil);
    return st.depth_stencil ? D3D_OK : 0x88760866u;
}

uint32_t bl_IDirect3DDevice9_BeginScene_c(DEV) { UNUSED; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_EndScene_c(DEV) { UNUSED; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_Clear_c(DEV, uint32_t count, uint32_t rects, uint32_t flags, uint32_t color, uint32_t z,
                                    uint32_t stencil)
{
    UNUSED;
    d3d_render_clear(&st, count, rects, flags, color, u2f(z), stencil);
    return D3D_OK;
}

// D3DTRANSFORMSTATETYPE: VIEW 2, PROJECTION 3, TEXTURE0..7 16..23, WORLD(n) 256 + n.
static uint32_t *transform(uint32_t state)
{
    if (state < 24) return st.transform[state];
    if (state >= 256 && state < 256 + 4) return st.transform[24 + state - 256];
    return NULL;
}

uint32_t bl_IDirect3DDevice9_SetTransform_c(DEV, uint32_t state, uint32_t m)
{
    UNUSED;
    uint32_t *t = transform(state);
    if (t) memcpy(t, bl_g2h(m), 64);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetTransform_c(DEV, uint32_t state, uint32_t m)
{
    UNUSED;
    uint32_t *t = transform(state);
    if (t) memcpy(bl_g2h(m), t, 64);
    return t ? D3D_OK : D3DERR_INVALIDCALL;
}

uint32_t bl_IDirect3DDevice9_MultiplyTransform_c(DEV, uint32_t state, uint32_t m)
{
    UNUSED;
    uint32_t *t = transform(state);
    if (!t) return D3D_OK;
    float a[16], b[16], r[16];
    memcpy(a, t, 64);
    memcpy(b, bl_g2h(m), 64);
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            r[4 * i + j] = 0;
            for (int k = 0; k < 4; k++) r[4 * i + j] += b[4 * i + k] * a[4 * k + j];  // D3D: M * current
        }
    memcpy(t, r, 64);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetViewport_c(DEV, uint32_t vp)
{
    UNUSED;
    memcpy(st.viewport, bl_g2h(vp), 24);
    static int trace = -1;
    if (trace < 0) trace = getenv("BL_D3D_TRACE") != NULL;
    if (trace)
        fprintf(stderr, "[d3d9] viewport %u,%u %ux%u z %g-%g\n", st.viewport[0], st.viewport[1], st.viewport[2],
                st.viewport[3], u2f(st.viewport[4]), u2f(st.viewport[5]));
    return D3D_OK;
}
uint32_t bl_IDirect3DDevice9_GetViewport_c(DEV, uint32_t vp) { UNUSED; memcpy(bl_g2h(vp), st.viewport, 24); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetMaterial_c(DEV, uint32_t m) { UNUSED; memcpy(st.material, bl_g2h(m), 68); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetMaterial_c(DEV, uint32_t m) { UNUSED; memcpy(bl_g2h(m), st.material, 68); return D3D_OK; }

// D3DLIGHT9 is 104 bytes.
uint32_t bl_IDirect3DDevice9_SetLight_c(DEV, uint32_t i, uint32_t l)
{
    UNUSED;
    if (i < 8) memcpy(st.light[i], bl_g2h(l), 104);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetLight_c(DEV, uint32_t i, uint32_t l)
{
    UNUSED;
    if (i >= 8) return D3DERR_INVALIDCALL;
    memcpy(bl_g2h(l), st.light[i], 104);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_LightEnable_c(DEV, uint32_t i, uint32_t on) { UNUSED; if (i < 8) st.light_on[i] = on != 0; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetLightEnable_c(DEV, uint32_t i, uint32_t on)
{
    UNUSED;
    if (i >= 8) return D3DERR_INVALIDCALL;
    G32(on) = st.light_on[i] ? 128 : 0;  // D3D returns 128 for TRUE here
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetClipPlane_c(DEV, uint32_t i, uint32_t p) { UNUSED; if (i < 6) memcpy(st.clip_plane[i], bl_g2h(p), 16); return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetClipPlane_c(DEV, uint32_t i, uint32_t p)
{
    UNUSED;
    if (i >= 6) return D3DERR_INVALIDCALL;
    memcpy(bl_g2h(p), st.clip_plane[i], 16);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetRenderState_c(DEV, uint32_t s, uint32_t v) { UNUSED; if (s < 256) st.rs[s] = v; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetRenderState_c(DEV, uint32_t s, uint32_t v)
{
    UNUSED;
    G32(v) = s < 256 ? st.rs[s] : 0;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_CreateStateBlock_c(DEV, uint32_t type, uint32_t out) { UNUSED, (void)type; return d3d_create_state_block(out); }
uint32_t bl_IDirect3DDevice9_BeginStateBlock_c(DEV) { UNUSED; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_EndStateBlock_c(DEV, uint32_t out) { UNUSED; return d3d_create_state_block(out); }
uint32_t bl_IDirect3DDevice9_SetClipStatus_c(DEV, uint32_t cs) { UNUSED, (void)cs; return D3D_OK; }

uint32_t bl_IDirect3DDevice9_GetClipStatus_c(DEV, uint32_t cs)
{
    UNUSED;
    memset(bl_g2h(cs), 0, 8);
    return D3D_OK;
}

// Samplers: 0-15 pixel, D3DVERTEXTEXTURESAMPLER0 (257)-260 vertex, stored at 16-19.
static int sampler_index(uint32_t s) { return s < 16 ? (int)s : s >= 257 && s <= 260 ? (int)(s - 257 + 16) : -1; }

uint32_t bl_IDirect3DDevice9_GetTexture_c(DEV, uint32_t s, uint32_t out)
{
    UNUSED;
    int i = sampler_index(s);
    give(out, i < 0 ? NULL : st.texture[i]);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetTexture_c(DEV, uint32_t s, uint32_t tex)
{
    UNUSED;
    int i = sampler_index(s);
    if (i >= 0) hold(&st.texture[i], tex);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetTextureStageState_c(DEV, uint32_t stage, uint32_t type, uint32_t v)
{
    UNUSED;
    G32(v) = stage < 8 && type < 33 ? st.tss[stage][type] : 0;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetTextureStageState_c(DEV, uint32_t stage, uint32_t type, uint32_t v)
{
    UNUSED;
    if (stage < 8 && type < 33) st.tss[stage][type] = v;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetSamplerState_c(DEV, uint32_t s, uint32_t type, uint32_t v)
{
    UNUSED;
    int i = sampler_index(s);
    G32(v) = i >= 0 && type < 14 ? st.ss[i][type] : 0;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetSamplerState_c(DEV, uint32_t s, uint32_t type, uint32_t v)
{
    UNUSED;
    int i = sampler_index(s);
    if (i >= 0 && type < 14) st.ss[i][type] = v;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_ValidateDevice_c(DEV, uint32_t passes) { UNUSED; if (passes) G32(passes) = 1; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetPaletteEntries_c(DEV, uint32_t n, uint32_t e) { UNUSED, (void)n, (void)e; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetPaletteEntries_c(DEV, uint32_t n, uint32_t e) { UNUSED, (void)n, (void)e; return D3DERR_INVALIDCALL; }
uint32_t bl_IDirect3DDevice9_SetCurrentTexturePalette_c(DEV, uint32_t n) { UNUSED, (void)n; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetCurrentTexturePalette_c(DEV, uint32_t n) { UNUSED; G32(n) = 0; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetScissorRect_c(DEV, uint32_t r) { UNUSED; memcpy(st.scissor, bl_g2h(r), 16); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetScissorRect_c(DEV, uint32_t r) { UNUSED; memcpy(bl_g2h(r), st.scissor, 16); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetSoftwareVertexProcessing_c(DEV, uint32_t on) { UNUSED, (void)on; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetSoftwareVertexProcessing_c(DEV) { UNUSED; return 0; }
uint32_t bl_IDirect3DDevice9_SetNPatchMode_c(DEV, uint32_t n) { UNUSED, (void)n; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetNPatchMode_c(DEV) { UNUSED; return 0; }

uint32_t bl_IDirect3DDevice9_DrawPrimitive_c(DEV, uint32_t type, uint32_t start, uint32_t count)
{
    UNUSED;
    d3d_render_draw(&st, type, (int32_t)start, 0, 0, 0, count, 0, 0, 0);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_DrawIndexedPrimitive_c(DEV, uint32_t type, uint32_t base, uint32_t min, uint32_t nverts,
                                                   uint32_t start, uint32_t count)
{
    UNUSED;
    d3d_render_draw(&st, type, (int32_t)base, min, nverts, start, count, 1, 0, 0);
    return D3D_OK;
}

// UP draws: vertices (and indices) come from guest memory; stream 0 and the index
// buffer are unset afterwards, as on Windows.
uint32_t bl_IDirect3DDevice9_DrawPrimitiveUP_c(DEV, uint32_t type, uint32_t count, uint32_t data, uint32_t stride)
{
    UNUSED;
    hold(&st.stream[0], 0);
    st.stream_offset[0] = 0, st.stream_stride[0] = 0;
    d3d_render_draw_up(&st, type, 0, 0, count, 0, 0, data, stride);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_DrawIndexedPrimitiveUP_c(DEV, uint32_t type, uint32_t min, uint32_t nverts, uint32_t count,
                                                     uint32_t indices, uint32_t ifmt, uint32_t data, uint32_t stride)
{
    UNUSED;
    hold(&st.stream[0], 0);
    st.stream_offset[0] = 0, st.stream_stride[0] = 0;
    hold(&st.indices, 0);
    d3d_render_draw_up(&st, type, min, nverts, count, indices, ifmt, data, stride);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_ProcessVertices_c(DEV, uint32_t src, uint32_t dst, uint32_t n, uint32_t buf, uint32_t decl,
                                              uint32_t flags)
{
    UNUSED, (void)src, (void)dst, (void)n, (void)buf, (void)decl, (void)flags;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_CreateVertexDeclaration_c(DEV, uint32_t e, uint32_t out) { UNUSED; return d3d_create_vertex_declaration(e, out); }
uint32_t bl_IDirect3DDevice9_SetVertexDeclaration_c(DEV, uint32_t d) { UNUSED; hold(&st.vdecl, d); if (d) st.fvf = 0; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetVertexDeclaration_c(DEV, uint32_t out) { UNUSED; give(out, st.vdecl); return D3D_OK; }

uint32_t bl_IDirect3DDevice9_SetFVF_c(DEV, uint32_t fvf)
{
    UNUSED;
    st.fvf = fvf;
    if (fvf) hold(&st.vdecl, 0);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetFVF_c(DEV, uint32_t out) { UNUSED; G32(out) = st.fvf; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_CreateVertexShader_c(DEV, uint32_t code, uint32_t out) { UNUSED; return d3d_create_shader(OBJ_VSHADER, code, out); }
uint32_t bl_IDirect3DDevice9_SetVertexShader_c(DEV, uint32_t s) { UNUSED; hold(&st.vs, s); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetVertexShader_c(DEV, uint32_t out) { UNUSED; give(out, st.vs); return D3D_OK; }

// Shader constants: float4 / int4 registers (16 bytes), bools (4 bytes).
static uint32_t consts(void *bank, uint32_t nregs, uint32_t regsize, uint32_t start, uint32_t data, uint32_t count, int set)
{
    if (start + count > nregs) return D3DERR_INVALIDCALL;
    char *b = (char *)bank + start * regsize;
    if (set) memcpy(b, bl_g2h(data), count * regsize);
    else memcpy(bl_g2h(data), b, count * regsize);
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetVertexShaderConstantF_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.vs_f, 256, 16, s, d, n, 1); }
uint32_t bl_IDirect3DDevice9_GetVertexShaderConstantF_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.vs_f, 256, 16, s, d, n, 0); }
uint32_t bl_IDirect3DDevice9_SetVertexShaderConstantI_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.vs_i, 16, 16, s, d, n, 1); }
uint32_t bl_IDirect3DDevice9_GetVertexShaderConstantI_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.vs_i, 16, 16, s, d, n, 0); }
uint32_t bl_IDirect3DDevice9_SetVertexShaderConstantB_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.vs_b, 16, 4, s, d, n, 1); }
uint32_t bl_IDirect3DDevice9_GetVertexShaderConstantB_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.vs_b, 16, 4, s, d, n, 0); }

uint32_t bl_IDirect3DDevice9_SetStreamSource_c(DEV, uint32_t i, uint32_t vb, uint32_t offset, uint32_t stride)
{
    UNUSED;
    if (i >= 16) return D3DERR_INVALIDCALL;
    hold(&st.stream[i], vb);
    st.stream_offset[i] = offset;
    st.stream_stride[i] = stride;
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_GetStreamSource_c(DEV, uint32_t i, uint32_t out, uint32_t offset, uint32_t stride)
{
    UNUSED;
    if (i >= 16) return D3DERR_INVALIDCALL;
    give(out, st.stream[i]);
    if (offset) G32(offset) = st.stream_offset[i];
    if (stride) G32(stride) = st.stream_stride[i];
    return D3D_OK;
}

uint32_t bl_IDirect3DDevice9_SetStreamSourceFreq_c(DEV, uint32_t i, uint32_t f) { UNUSED; if (i < 16) st.stream_freq[i] = f; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetStreamSourceFreq_c(DEV, uint32_t i, uint32_t f) { UNUSED; G32(f) = i < 16 ? st.stream_freq[i] : 1; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetIndices_c(DEV, uint32_t ib) { UNUSED; hold(&st.indices, ib); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetIndices_c(DEV, uint32_t out) { UNUSED; give(out, st.indices); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_CreatePixelShader_c(DEV, uint32_t code, uint32_t out) { UNUSED; return d3d_create_shader(OBJ_PSHADER, code, out); }
uint32_t bl_IDirect3DDevice9_SetPixelShader_c(DEV, uint32_t s) { UNUSED; hold(&st.ps, s); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_GetPixelShader_c(DEV, uint32_t out) { UNUSED; give(out, st.ps); return D3D_OK; }
uint32_t bl_IDirect3DDevice9_SetPixelShaderConstantF_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.ps_f, 224, 16, s, d, n, 1); }
uint32_t bl_IDirect3DDevice9_GetPixelShaderConstantF_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.ps_f, 224, 16, s, d, n, 0); }
uint32_t bl_IDirect3DDevice9_SetPixelShaderConstantI_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.ps_i, 16, 16, s, d, n, 1); }
uint32_t bl_IDirect3DDevice9_GetPixelShaderConstantI_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.ps_i, 16, 16, s, d, n, 0); }
uint32_t bl_IDirect3DDevice9_SetPixelShaderConstantB_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.ps_b, 16, 4, s, d, n, 1); }
uint32_t bl_IDirect3DDevice9_GetPixelShaderConstantB_c(DEV, uint32_t s, uint32_t d, uint32_t n) { UNUSED; return consts(st.ps_b, 16, 4, s, d, n, 0); }
uint32_t bl_IDirect3DDevice9_DrawRectPatch_c(DEV, uint32_t h, uint32_t s, uint32_t i) { UNUSED, (void)h, (void)s, (void)i; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_DrawTriPatch_c(DEV, uint32_t h, uint32_t s, uint32_t i) { UNUSED, (void)h, (void)s, (void)i; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_DeletePatch_c(DEV, uint32_t h) { UNUSED, (void)h; return D3D_OK; }
uint32_t bl_IDirect3DDevice9_CreateQuery_c(DEV, uint32_t type, uint32_t out) { UNUSED; return d3d_create_query(type, out); }

// --- swap chain ------------------------------------------------------------------

uint32_t bl_IDirect3DSwapChain9_Present_c(uint32_t self, uint32_t src, uint32_t dst, uint32_t window, uint32_t dirty, uint32_t flags)
{
    (void)flags;
    return bl_IDirect3DDevice9_Present_c(self, src, dst, window, dirty);
}

uint32_t bl_IDirect3DSwapChain9_GetFrontBufferData_c(uint32_t self, uint32_t dst) { (void)self, (void)dst; return D3D_OK; }
uint32_t bl_IDirect3DSwapChain9_GetBackBuffer_c(uint32_t self, uint32_t i, uint32_t type, uint32_t out) { return bl_IDirect3DDevice9_GetBackBuffer_c(self, 0, i, type, out); }
uint32_t bl_IDirect3DSwapChain9_GetRasterStatus_c(uint32_t self, uint32_t rs) { return bl_IDirect3DDevice9_GetRasterStatus_c(self, 0, rs); }
uint32_t bl_IDirect3DSwapChain9_GetDisplayMode_c(uint32_t self, uint32_t mode) { return bl_IDirect3DDevice9_GetDisplayMode_c(self, 0, mode); }

uint32_t bl_IDirect3DSwapChain9_GetDevice_c(uint32_t self, uint32_t out)
{
    (void)self;
    give(out, device);
    return D3D_OK;
}

uint32_t bl_IDirect3DSwapChain9_GetPresentParameters_c(uint32_t self, uint32_t pp)
{
    (void)self;
    memcpy(bl_g2h(pp), st.pp, sizeof st.pp);
    return D3D_OK;
}
