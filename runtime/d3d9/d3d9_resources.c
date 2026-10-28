// D3D9 resources in guest memory: textures and their level surfaces, standalone
// surfaces, vertex/index buffers, vertex declarations, shaders, queries and state
// blocks. Locks hand out pointers into that memory; the renderer reads it from there.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "com_gen.h"
#include "d3d9_objects.h"

_Noreturn void bl_com_unimplemented(const char *method);

#define D3DPOOL_DEFAULT 0

static void put_out(uint32_t out, struct obj *o)
{
    if (out) G32(out) = o ? o->guest : 0;
}

// D3DSURFACE_DESC (32 bytes)
static void surface_desc(struct obj *s, uint32_t d)
{
    G32(d) = s->format;
    G32(d + 4) = OBJ_SURFACE;
    G32(d + 8) = s->usage;
    G32(d + 12) = s->pool;
    G32(d + 16) = s->multisample;
    G32(d + 20) = 0;
    G32(d + 24) = s->width;
    G32(d + 28) = s->height;
}

struct obj *d3d_new_surface(uint32_t w, uint32_t h, uint32_t format, uint32_t usage, uint32_t pool,
                            uint32_t multisample)
{
    struct obj *s = obj_new(OBJ_SURFACE, bl_vtbl_IDirect3DSurface9());
    s->format = format;
    s->usage = usage;
    s->pool = pool;
    s->multisample = multisample;
    d3d_alloc_image(s, w, h, 1);
    return s;
}

static uint32_t mip_levels(uint32_t w, uint32_t h, uint32_t d, uint32_t levels)
{
    uint32_t n = 1, m = w > h ? w : h;
    if (d > m) m = d;
    while (m > 1) m >>= 1, n++;
    return levels && levels < n ? levels : n;
}

static uint32_t lvl(uint32_t size, uint32_t level)
{
    size >>= level;
    return size ? size : 1;
}

// A texture: `faces` sets of `levels` surfaces (volumes for volume textures).
static struct obj *new_texture(enum obj_type type, uint32_t vtbl, uint32_t w, uint32_t h, uint32_t d,
                               uint32_t levels, uint32_t usage, uint32_t format, uint32_t pool, uint32_t faces)
{
    struct obj *t = obj_new(type, vtbl);
    t->width = w, t->height = h, t->depth = d;
    t->format = format, t->usage = usage, t->pool = pool;
    t->levels = (usage & 0x400) ? 1 : mip_levels(w, h, type == OBJ_VOLUMETEXTURE ? d : 1, levels);  // AUTOGENMIPMAP
    t->nsubs = faces * t->levels;
    t->subs = calloc(t->nsubs, sizeof *t->subs);
    for (uint32_t f = 0; f < faces; f++)
        for (uint32_t l = 0; l < t->levels; l++) {
            struct obj *s = obj_new(type == OBJ_VOLUMETEXTURE ? OBJ_VOLUME : OBJ_SURFACE, bl_vtbl_IDirect3DSurface9());
            s->format = format, s->usage = usage, s->pool = pool, s->owner = t;
            d3d_alloc_image(s, lvl(w, l), lvl(h, l), type == OBJ_VOLUMETEXTURE ? lvl(d, l) : 1);
            t->subs[f * t->levels + l] = s;
        }
    return t;
}

uint32_t d3d_create_texture(uint32_t w, uint32_t h, uint32_t levels, uint32_t usage, uint32_t format,
                            uint32_t pool, uint32_t out)
{
    if (!w || !h) return D3DERR_INVALIDCALL;
    struct obj *t = new_texture(OBJ_TEXTURE, bl_vtbl_IDirect3DTexture9(), w, h, 1, levels, usage, format, pool, 1);
    put_out(out, t);
    return D3D_OK;
}

uint32_t d3d_create_volume_texture(uint32_t w, uint32_t h, uint32_t d, uint32_t levels, uint32_t usage,
                                   uint32_t format, uint32_t pool, uint32_t out)
{
    if (!w || !h || !d) return D3DERR_INVALIDCALL;
    struct obj *t = new_texture(OBJ_VOLUMETEXTURE, bl_vtbl_IDirect3DVolumeTexture9(), w, h, d, levels, usage, format, pool, 1);
    put_out(out, t);
    return D3D_OK;
}

uint32_t d3d_create_cube_texture(uint32_t edge, uint32_t levels, uint32_t usage, uint32_t format, uint32_t pool,
                                 uint32_t out)
{
    if (!edge) return D3DERR_INVALIDCALL;
    struct obj *t = new_texture(OBJ_CUBETEXTURE, bl_vtbl_IDirect3DCubeTexture9(), edge, edge, 1, levels, usage, format, pool, 6);
    put_out(out, t);
    return D3D_OK;
}

static struct obj *level(uint32_t self, uint32_t face, uint32_t l)
{
    struct obj *t = obj_of(self);
    if (l >= t->levels || face * t->levels + l >= t->nsubs) return NULL;
    return t->subs[face * t->levels + l];
}

// Debugging: a debugger breakpoint here sees each lock of a surface matching BL_LOCK_TRAP=<width>x<height>[:<format>].
__attribute__((noinline)) void bl_debug_lock(uint32_t guest_bits, uint32_t pitch, uint32_t height)
{
    __asm__ volatile("" ::"r"(guest_bits), "r"(pitch), "r"(height));
}

static struct obj *trap_surface;  // the last BL_LOCK_TRAP lock, reported on unlock
static uint32_t trap_rect[4];

// D3DLOCKED_RECT {Pitch, pBits}; rect = optional RECT {left, top, right, bottom}.
static uint32_t lock_rect(struct obj *s, uint32_t locked, uint32_t rect)
{
    uint32_t x = 0, y = 0;
    if (rect) x = G32(rect), y = G32(rect + 4);
    int block;
    uint32_t bpp = d3d_format_size(s->format, &block);
    uint32_t off = block ? (y / 4) * s->pitch + (x / 4) * bpp : y * s->pitch + x * bpp;
    G32(locked) = s->pitch;
    G32(locked + 4) = s->mem + off;
    static const char *trap;
    static int trap_read;
    if (!trap_read) trap = getenv("BL_LOCK_TRAP"), trap_read = 1;
    if (trap && (uint32_t)atoi(trap) == s->width && strchr(trap, 'x') && (uint32_t)atoi(strchr(trap, 'x') + 1) == s->height &&
        (!strchr(trap, ':') || (uint32_t)atoi(strchr(trap, ':') + 1) == s->format)) {
        bl_debug_lock(s->mem + off, s->pitch, s->height);
        trap_rect[0] = x, trap_rect[1] = y;
        trap_rect[2] = rect ? G32(rect + 8) : s->width, trap_rect[3] = rect ? G32(rect + 12) : s->height;
        trap_surface = s;
    }
    return D3D_OK;
}

void d3d_image_changed(struct obj *s);  // renderer: re-upload on unlock
void d3d_render_shader_created(struct obj *s);  // renderer: start compiling it

static void report_trap(struct obj *s)
{
    if (s == trap_surface && d3d_format_size(s->format, &(int){0}) == 4) {
        unsigned long sum[4] = {0}, n = 0;
        for (uint32_t y = trap_rect[1]; y < trap_rect[3]; y++)
            for (uint32_t x = trap_rect[0]; x < trap_rect[2]; x++, n++)
                for (int c = 0; c < 4; c++) sum[c] += ((const uint8_t *)bl_g2h(s->mem))[y * s->pitch + x * 4 + c];
        if (n)
            fprintf(stderr, "[locktrap] %#x rect %u,%u-%u,%u mean bgra %lu %lu %lu %lu\n", s->mem, trap_rect[0], trap_rect[1],
                    trap_rect[2], trap_rect[3], sum[0] / n, sum[1] / n, sum[2] / n, sum[3] / n);
        trap_surface = NULL;
    }
}


uint32_t bl_IDirect3DTexture9_GetLevelDesc_c(uint32_t self, uint32_t l, uint32_t desc)
{
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    surface_desc(s, desc);
    return D3D_OK;
}

uint32_t bl_IDirect3DTexture9_GetSurfaceLevel_c(uint32_t self, uint32_t l, uint32_t out)
{
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    obj_addref(s);
    put_out(out, s);
    return D3D_OK;
}

uint32_t bl_IDirect3DTexture9_LockRect_c(uint32_t self, uint32_t l, uint32_t locked, uint32_t rect, uint32_t flags)
{
    (void)flags;
    struct obj *s = level(self, 0, l);
    return s ? lock_rect(s, locked, rect) : D3DERR_INVALIDCALL;
}

uint32_t bl_IDirect3DTexture9_UnlockRect_c(uint32_t self, uint32_t l)
{
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    report_trap(s);
    d3d_image_changed(s);
    return D3D_OK;
}

uint32_t bl_IDirect3DTexture9_AddDirtyRect_c(uint32_t self, uint32_t rect) { (void)self, (void)rect; return D3D_OK; }

uint32_t bl_IDirect3DCubeTexture9_GetLevelDesc_c(uint32_t self, uint32_t l, uint32_t desc)
{
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    surface_desc(s, desc);
    return D3D_OK;
}

uint32_t bl_IDirect3DCubeTexture9_GetCubeMapSurface_c(uint32_t self, uint32_t face, uint32_t l, uint32_t out)
{
    struct obj *s = level(self, face, l);
    if (!s) return D3DERR_INVALIDCALL;
    obj_addref(s);
    put_out(out, s);
    return D3D_OK;
}

uint32_t bl_IDirect3DCubeTexture9_LockRect_c(uint32_t self, uint32_t face, uint32_t l, uint32_t locked, uint32_t rect,
                                            uint32_t flags)
{
    (void)flags;
    struct obj *s = level(self, face, l);
    return s ? lock_rect(s, locked, rect) : D3DERR_INVALIDCALL;
}

uint32_t bl_IDirect3DCubeTexture9_UnlockRect_c(uint32_t self, uint32_t face, uint32_t l)
{
    struct obj *s = level(self, face, l);
    if (!s) return D3DERR_INVALIDCALL;
    d3d_image_changed(s);
    return D3D_OK;
}

uint32_t bl_IDirect3DCubeTexture9_AddDirtyRect_c(uint32_t self, uint32_t face, uint32_t rect)
{
    (void)self, (void)face, (void)rect;
    return D3D_OK;
}

// D3DVOLUME_DESC {Format, Type, Usage, Pool, Width, Height, Depth}
uint32_t bl_IDirect3DVolumeTexture9_GetLevelDesc_c(uint32_t self, uint32_t l, uint32_t desc)
{
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    G32(desc) = s->format;
    G32(desc + 4) = OBJ_VOLUME;
    G32(desc + 8) = s->usage;
    G32(desc + 12) = s->pool;
    G32(desc + 16) = s->width;
    G32(desc + 20) = s->height;
    G32(desc + 24) = s->depth;
    return D3D_OK;
}

uint32_t bl_IDirect3DVolumeTexture9_GetVolumeLevel_c(uint32_t self, uint32_t l, uint32_t out)
{
    (void)self, (void)l, (void)out;
    bl_com_unimplemented("IDirect3DVolumeTexture9::GetVolumeLevel (needs IDirect3DVolume9)");
}

// D3DLOCKED_BOX {RowPitch, SlicePitch, pBits}; box = optional D3DBOX {Left, Top, Right, Bottom, Front, Back}.
uint32_t bl_IDirect3DVolumeTexture9_LockBox_c(uint32_t self, uint32_t l, uint32_t locked, uint32_t box, uint32_t flags)
{
    (void)flags;
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    uint32_t off = 0;
    if (box) {
        int block;
        uint32_t bpp = d3d_format_size(s->format, &block);
        off = G32(box + 16) * s->slice + G32(box + 4) * s->pitch + G32(box) * bpp;
    }
    G32(locked) = s->pitch;
    G32(locked + 4) = s->slice;
    G32(locked + 8) = s->mem + off;
    return D3D_OK;
}

uint32_t bl_IDirect3DVolumeTexture9_UnlockBox_c(uint32_t self, uint32_t l)
{
    struct obj *s = level(self, 0, l);
    if (!s) return D3DERR_INVALIDCALL;
    d3d_image_changed(s);
    return D3D_OK;
}

uint32_t bl_IDirect3DVolumeTexture9_AddDirtyBox_c(uint32_t self, uint32_t box) { (void)self, (void)box; return D3D_OK; }

// --- surfaces --------------------------------------------------------------------

uint32_t bl_IDirect3DSurface9_GetContainer_c(uint32_t self, uint32_t riid, uint32_t out)
{
    (void)riid;
    struct obj *s = obj_of(self);
    if (!s->owner || s->owner->type == OBJ_DEVICE) {
        put_out(out, NULL);
        return E_NOINTERFACE;
    }
    obj_addref(s->owner);
    put_out(out, s->owner);
    return D3D_OK;
}

uint32_t bl_IDirect3DSurface9_GetDesc_c(uint32_t self, uint32_t desc)
{
    surface_desc(obj_of(self), desc);
    return D3D_OK;
}

uint32_t bl_IDirect3DSurface9_LockRect_c(uint32_t self, uint32_t locked, uint32_t rect, uint32_t flags)
{
    (void)flags;
    return lock_rect(obj_of(self), locked, rect);
}

uint32_t bl_IDirect3DSurface9_UnlockRect_c(uint32_t self)
{
    report_trap(obj_of(self));
    d3d_image_changed(obj_of(self));
    return D3D_OK;
}

uint32_t bl_IDirect3DSurface9_GetDC_c(uint32_t self, uint32_t hdc)
{
    (void)self;
    if (hdc) G32(hdc) = 0;
    return D3DERR_INVALIDCALL;
}

uint32_t bl_IDirect3DSurface9_ReleaseDC_c(uint32_t self, uint32_t hdc) { (void)self, (void)hdc; return D3DERR_INVALIDCALL; }

// --- vertex and index buffers ------------------------------------------------------

static struct obj *new_buffer(enum obj_type type, uint32_t vtbl, uint32_t len, uint32_t usage, uint32_t format,
                              uint32_t pool)
{
    struct obj *b = obj_new(type, vtbl);
    b->size = len;
    b->usage = usage;
    b->format = format;  // FVF for vertex buffers
    b->pool = pool;
    b->mem = bl_guest_calloc(1, len ? len : 1);
    if (!b->mem) bl_fatal("out of guest memory for a %u-byte buffer", len);
    return b;
}

uint32_t d3d_create_vertex_buffer(uint32_t len, uint32_t usage, uint32_t fvf, uint32_t pool, uint32_t out)
{
    struct obj *b = new_buffer(OBJ_VERTEXBUFFER, bl_vtbl_IDirect3DVertexBuffer9(), len, usage, 100, pool);
    b->fvf = fvf;
    put_out(out, b);
    return D3D_OK;
}

uint32_t d3d_create_index_buffer(uint32_t len, uint32_t usage, uint32_t format, uint32_t pool, uint32_t out)
{
    put_out(out, new_buffer(OBJ_INDEXBUFFER, bl_vtbl_IDirect3DIndexBuffer9(), len, usage, format, pool));
    return D3D_OK;
}

static uint32_t buffer_lock(uint32_t self, uint32_t offset, uint32_t size, uint32_t out)
{
    struct obj *b = obj_of(self);
    (void)size;
    if (offset > b->size) return D3DERR_INVALIDCALL;
    G32(out) = b->mem + offset;
    return D3D_OK;
}

void d3d_buffer_changed(struct obj *b);

uint32_t bl_IDirect3DVertexBuffer9_Lock_c(uint32_t self, uint32_t offset, uint32_t size, uint32_t out, uint32_t flags)
{
    (void)flags;
    return buffer_lock(self, offset, size, out);
}

uint32_t bl_IDirect3DVertexBuffer9_Unlock_c(uint32_t self)
{
    d3d_buffer_changed(obj_of(self));
    return D3D_OK;
}

// D3DVERTEXBUFFER_DESC {Format, Type, Usage, Pool, Size, FVF}
uint32_t bl_IDirect3DVertexBuffer9_GetDesc_c(uint32_t self, uint32_t d)
{
    struct obj *b = obj_of(self);
    G32(d) = 100;  // D3DFMT_VERTEXDATA
    G32(d + 4) = OBJ_VERTEXBUFFER;
    G32(d + 8) = b->usage;
    G32(d + 12) = b->pool;
    G32(d + 16) = b->size;
    G32(d + 20) = b->fvf;
    return D3D_OK;
}

uint32_t bl_IDirect3DIndexBuffer9_Lock_c(uint32_t self, uint32_t offset, uint32_t size, uint32_t out, uint32_t flags)
{
    (void)flags;
    return buffer_lock(self, offset, size, out);
}

uint32_t bl_IDirect3DIndexBuffer9_Unlock_c(uint32_t self)
{
    d3d_buffer_changed(obj_of(self));
    return D3D_OK;
}

// D3DINDEXBUFFER_DESC {Format, Type, Usage, Pool, Size}
uint32_t bl_IDirect3DIndexBuffer9_GetDesc_c(uint32_t self, uint32_t d)
{
    struct obj *b = obj_of(self);
    G32(d) = b->format;
    G32(d + 4) = OBJ_INDEXBUFFER;
    G32(d + 8) = b->usage;
    G32(d + 12) = b->pool;
    G32(d + 16) = b->size;
    return D3D_OK;
}

// --- vertex declarations and shaders -------------------------------------------------

// D3DVERTEXELEMENT9 is 8 bytes; the list ends with Stream 0xFF.
uint32_t d3d_create_vertex_declaration(uint32_t elements, uint32_t out)
{
    uint32_t n = 0;
    while (*(uint16_t *)bl_g2h(elements + 8 * n) != 0xFF) n++;
    struct obj *d = obj_new(OBJ_VDECL, bl_vtbl_IDirect3DVertexDeclaration9());
    d->size = 8 * (n + 1);
    d->mem = bl_guest_malloc(d->size);
    memcpy(bl_g2h(d->mem), bl_g2h(elements), d->size);
    put_out(out, d);
    return D3D_OK;
}

uint32_t bl_IDirect3DVertexDeclaration9_GetDevice_c(uint32_t self, uint32_t out)
{
    return bl_IDirect3DResource9_GetDevice_c(self, out);
}

uint32_t bl_IDirect3DVertexDeclaration9_GetDeclaration_c(uint32_t self, uint32_t elements, uint32_t count)
{
    struct obj *d = obj_of(self);
    if (elements) memcpy(bl_g2h(elements), bl_g2h(d->mem), d->size);
    if (count) G32(count) = d->size / 8;
    return D3D_OK;
}

// The number of DWORD tokens of shader bytecode: the version token, then instructions up
// to the end token 0x0000FFFF, or 0 when there is none. Walked an instruction at a time, so
// data (comments, def's constants) is never taken for the end. Shader model 2 and later
// give each instruction's length; in 1.x, parameter tokens have the top bit set and are
// stepped over one by one.
static uint32_t shader_tokens(uint32_t code)
{
    uint32_t major = G32(code) >> 8 & 0xFF;
    for (uint32_t i = 1; i < 0x10000;) {
        uint32_t t = G32(code + 4 * i), op = t & 0xFFFF;
        if (t == 0x0000FFFF) return i + 1;
        if (t >> 31) i++;                                                // 1.x parameter
        else if (op == 0xFFFE) i += 1 + (t >> 16 & 0x7FFF);                // comment
        else if (op == 0x51 || op == 0x30) i += 6;                       // def, defi
        else if (op == 0x2F) i += 3;                                     // defb
        else i += major >= 2 ? 1 + (t >> 24 & 0xF) : 1;
    }
    return 0;
}

uint32_t d3d_create_shader(enum obj_type type, uint32_t code, uint32_t out)
{
    uint32_t n = code ? shader_tokens(code) : 0;
    if (!n) return D3DERR_INVALIDCALL;
    struct obj *s = obj_new(type, type == OBJ_VSHADER ? bl_vtbl_IDirect3DVertexShader9() : bl_vtbl_IDirect3DPixelShader9());
    s->size = 4 * n;
    s->mem = bl_guest_malloc(s->size);
    memcpy(bl_g2h(s->mem), bl_g2h(code), s->size);
    // BL_DUMP_SHADERS=<dir> writes each distinct shader's bytecode there (for tests).
    const char *dir = getenv("BL_DUMP_SHADERS");
    if (dir) {
        uint64_t h = 1469598103934665603ull;  // FNV-1a
        for (uint32_t i = 0; i < s->size; i++) h = (h ^ ((uint8_t *)bl_g2h(s->mem))[i]) * 1099511628211ull;
        char path[1024];
        snprintf(path, sizeof path, "%s/%s_%016llx.bin", dir, type == OBJ_VSHADER ? "vs" : "ps", (unsigned long long)h);
        FILE *f = fopen(path, "wb");
        if (f) fwrite(bl_g2h(s->mem), 1, s->size, f), fclose(f);
    }
    d3d_render_shader_created(s);
    put_out(out, s);
    return D3D_OK;
}

static uint32_t shader_function(uint32_t self, uint32_t data, uint32_t size)
{
    struct obj *s = obj_of(self);
    if (data) memcpy(bl_g2h(data), bl_g2h(s->mem), s->size);
    if (size) G32(size) = s->size;
    return D3D_OK;
}

uint32_t bl_IDirect3DVertexShader9_GetDevice_c(uint32_t self, uint32_t out) { return bl_IDirect3DResource9_GetDevice_c(self, out); }
uint32_t bl_IDirect3DVertexShader9_GetFunction_c(uint32_t self, uint32_t data, uint32_t size) { return shader_function(self, data, size); }
uint32_t bl_IDirect3DPixelShader9_GetDevice_c(uint32_t self, uint32_t out) { return bl_IDirect3DResource9_GetDevice_c(self, out); }
uint32_t bl_IDirect3DPixelShader9_GetFunction_c(uint32_t self, uint32_t data, uint32_t size) { return shader_function(self, data, size); }

// --- queries and state blocks --------------------------------------------------------

#define D3DQUERYTYPE_EVENT 8
#define D3DQUERYTYPE_OCCLUSION 9

uint32_t d3d_create_query(uint32_t type, uint32_t out)
{
    if (type != D3DQUERYTYPE_EVENT && type != D3DQUERYTYPE_OCCLUSION) return D3DERR_NOTAVAILABLE;
    if (!out) return D3D_OK;  // support check
    struct obj *q = obj_new(OBJ_QUERY, bl_vtbl_IDirect3DQuery9());
    q->query_type = type;
    put_out(out, q);
    return D3D_OK;
}

uint32_t bl_IDirect3DQuery9_GetDevice_c(uint32_t self, uint32_t out) { return bl_IDirect3DResource9_GetDevice_c(self, out); }
uint32_t bl_IDirect3DQuery9_GetType_c(uint32_t self) { return obj_of(self)->query_type; }
uint32_t bl_IDirect3DQuery9_GetDataSize_c(uint32_t self) { (void)self; return 4; }
uint32_t bl_IDirect3DQuery9_Issue_c(uint32_t self, uint32_t flags) { (void)self, (void)flags; return D3D_OK; }

// Results are ready at once: events have completed; occlusion counts one visible pixel
// per query until the renderer counts real ones.
uint32_t bl_IDirect3DQuery9_GetData_c(uint32_t self, uint32_t data, uint32_t size, uint32_t flags)
{
    (void)flags;
    struct obj *q = obj_of(self);
    if (q->query_type == D3DQUERYTYPE_OCCLUSION) D3D_NOT_DONE("occlusion query (counts 1 pixel)");
    if (data && size >= 4) G32(data) = 1;  // event: TRUE; occlusion: 1 pixel
    return D3D_OK;
}

uint32_t d3d_create_state_block(uint32_t out)
{
    put_out(out, obj_new(OBJ_STATEBLOCK, bl_vtbl_IDirect3DStateBlock9()));
    return D3D_OK;
}

uint32_t bl_IDirect3DStateBlock9_GetDevice_c(uint32_t self, uint32_t out) { return bl_IDirect3DResource9_GetDevice_c(self, out); }
uint32_t bl_IDirect3DStateBlock9_Capture_c(uint32_t self) { (void)self; D3D_NOT_DONE("IDirect3DStateBlock9::Capture"); return D3D_OK; }
uint32_t bl_IDirect3DStateBlock9_Apply_c(uint32_t self) { (void)self; D3D_NOT_DONE("IDirect3DStateBlock9::Apply"); return D3D_OK; }
