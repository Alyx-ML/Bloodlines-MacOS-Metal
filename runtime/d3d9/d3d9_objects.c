#include <dlfcn.h>
// COM object table and the IUnknown / resource methods shared by every D3D9 object.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "com_gen.h"
#include "d3d9_objects.h"

_Noreturn void bl_com_unimplemented(const char *method)
{
    bl_fatal("unimplemented COM method %s", method);
}

static struct obj **table;
static uint32_t ntable, captable;

struct obj *obj_new(enum obj_type type, uint32_t vtbl)
{
    if (ntable == captable) {
        captable = captable ? 2 * captable : 1024;
        table = realloc(table, captable * sizeof *table);
        if (!table) bl_fatal("out of memory");
    }
    struct obj *o = calloc(1, sizeof *o);
    o->type = type;
    o->refs = 1;
    o->guest = bl_guest_malloc(8);
    G32(o->guest) = vtbl;
    G32(o->guest + 4) = ntable;
    table[ntable++] = o;
    return o;
}

struct obj *obj_of(uint32_t guest)
{
    if (!guest) return NULL;
    uint32_t i = G32(guest + 4);
    if (i >= ntable || !table[i] || table[i]->guest != guest) bl_fatal("0x%08x is not a D3D9 object", guest);
    return table[i];
}

void d3d_render_free(struct obj *o);
void dsound_buffer_free(struct obj *o);

static void obj_free(struct obj *o)
{
    if (o->type == OBJ_DSOUND_BUFFER) dsound_buffer_free(o);
    d3d_render_free(o);
    for (uint32_t i = 0; i < o->nsubs; i++) {
        struct obj *s = o->subs[i];
        d3d_render_free(s);
        if (s->mem) bl_guest_free(s->mem);
        table[G32(s->guest + 4)] = NULL;
        bl_guest_free(s->guest);
        free(s);
    }
    free(o->subs);
    if (o->mem) bl_guest_free(o->mem);
    table[G32(o->guest + 4)] = NULL;
    bl_guest_free(o->guest);
    free(o);
}

uint32_t obj_addref(struct obj *o)
{
    while (o->owner) o = o->owner;
    return ++o->refs;
}

uint32_t obj_release(struct obj *o)
{
    while (o->owner) o = o->owner;
    if (o->refs == 0) return 0;
    uint32_t r = --o->refs;
    // The device and Direct3D object stay (the game releases them only at exit).
    if (r == 0 && o->type != OBJ_DEVICE && o->type != OBJ_D3D) obj_free(o);
    return r;
}

uint32_t bl_IUnknown_QueryInterface_c(uint32_t self, uint32_t riid, uint32_t out)
{
    (void)self;
    // BL_QI_TRACE=1 logs each interface asked for and refused (EAX would show here as
    // IKsPropertySet, 31EFAC30-515C-11D0-A9AA-00AA0061BE93).
    static int trace = -1;
    if (trace < 0) trace = getenv("BL_QI_TRACE") != NULL;
    if (trace && riid) {
        const uint8_t *g = bl_g2h(riid);
        fprintf(stderr, "[com] QueryInterface %08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X refused\n",
                *(const uint32_t *)g, *(const uint16_t *)(g + 4), *(const uint16_t *)(g + 6), g[8], g[9], g[10],
                g[11], g[12], g[13], g[14], g[15]);
    }
    if (out) G32(out) = 0;
    return E_NOINTERFACE;
}

uint32_t bl_IUnknown_AddRef_c(uint32_t self) { return obj_addref(obj_of(self)); }
uint32_t bl_IUnknown_Release_c(uint32_t self) { return obj_release(obj_of(self)); }

// --- formats -------------------------------------------------------------------

#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

uint32_t d3d_format_size(uint32_t f, int *block)
{
    *block = 0;
    switch (f) {
    case FOURCC('D', 'X', 'T', '1'):
        *block = 1;
        return 8;
    case FOURCC('D', 'X', 'T', '2'): case FOURCC('D', 'X', 'T', '3'):
    case FOURCC('D', 'X', 'T', '4'): case FOURCC('D', 'X', 'T', '5'):
        *block = 1;
        return 16;
    case 20: return 3;                                     // R8G8B8
    case 27: case 28: case 41: case 50: case 52: return 1;  // R3G3B2 A8 P8 L8 A4L4
    case 23: case 24: case 25: case 26: case 29: case 30: case 40: case 51: case 60: case 61:
    case 70: case 73: case 80: case 81: case 101: case 111: case 117:
        return 2;
    case 36: case 110: case 113: case 115: return 8;       // 64-bit formats
    case 116: return 16;                                   // A32B32G32R32F
    default: return 4;
    }
}

void d3d_alloc_image(struct obj *o, uint32_t w, uint32_t h, uint32_t d)
{
    int block;
    uint32_t bpp = d3d_format_size(o->format, &block);
    o->width = w ? w : 1;
    o->height = h ? h : 1;
    o->depth = d ? d : 1;
    if (block) {
        o->pitch = (o->width + 3) / 4 * bpp;
        o->slice = o->pitch * ((o->height + 3) / 4);
    } else {
        o->pitch = (o->width * bpp + 3) & ~3u;
        o->slice = o->pitch * o->height;
    }
    o->size = o->slice * o->depth;
    o->mem = bl_guest_calloc(1, o->size);
    if (!o->mem) bl_fatal("out of guest memory for a %ux%ux%u image (format %u, %u bytes)", o->width, o->height, o->depth, o->format, o->size);
}

// --- IDirect3DResource9 / IDirect3DBaseTexture9 --------------------------------

uint32_t d3d_device_guest(void);

uint32_t bl_IDirect3DResource9_GetDevice_c(uint32_t self, uint32_t out)
{
    (void)self;
    G32(out) = d3d_device_guest();
    obj_addref(obj_of(G32(out)));
    return D3D_OK;
}

uint32_t bl_IDirect3DResource9_SetPrivateData_c(uint32_t self, uint32_t guid, uint32_t data, uint32_t size, uint32_t flags)
{
    (void)self, (void)guid, (void)data, (void)size, (void)flags;
    return D3D_OK;
}

uint32_t bl_IDirect3DResource9_GetPrivateData_c(uint32_t self, uint32_t guid, uint32_t data, uint32_t size)
{
    (void)self, (void)guid, (void)data, (void)size;
    return 0x88760866u;  // D3DERR_NOTFOUND
}

uint32_t bl_IDirect3DResource9_FreePrivateData_c(uint32_t self, uint32_t guid) { (void)self, (void)guid; return D3D_OK; }
uint32_t bl_IDirect3DResource9_SetPriority_c(uint32_t self, uint32_t p) { (void)self, (void)p; return 0; }
uint32_t bl_IDirect3DResource9_GetPriority_c(uint32_t self) { (void)self; return 0; }
uint32_t bl_IDirect3DResource9_PreLoad_c(uint32_t self) { (void)self; return 0; }
uint32_t bl_IDirect3DResource9_GetType_c(uint32_t self) { return obj_of(self)->type; }

uint32_t bl_IDirect3DBaseTexture9_SetLOD_c(uint32_t self, uint32_t lod) { (void)self, (void)lod; return 0; }
uint32_t bl_IDirect3DBaseTexture9_GetLOD_c(uint32_t self) { (void)self; return 0; }
uint32_t bl_IDirect3DBaseTexture9_GetLevelCount_c(uint32_t self) { return obj_of(self)->levels; }
uint32_t bl_IDirect3DBaseTexture9_SetAutoGenFilterType_c(uint32_t self, uint32_t t) { (void)self, (void)t; return D3D_OK; }
uint32_t bl_IDirect3DBaseTexture9_GetAutoGenFilterType_c(uint32_t self) { (void)self; return 2; }  // LINEAR
uint32_t bl_IDirect3DBaseTexture9_GenerateMipSubLevels_c(uint32_t self) { (void)self; return 0; }

// BL_D3D_TRACE=1 logs every COM call guest code makes (thunks call this first).
extern const char *const bl_com_method_names[];
extern const unsigned char bl_com_method_nargs[];

void bl_com_trace_c(uint32_t id, uint32_t sp)
{
    // BL_VIEWPORT_WATCH: name the COM call after which the viewport changed.
    static int watch = -1;
    static uint32_t last_vp[6], last_id;
    extern uint32_t d3d_viewport_word(int i);
    if (watch < 0) watch = getenv("BL_VIEWPORT_WATCH") != NULL;
    if (watch) {
        uint32_t vp[6];
        for (int i = 0; i < 6; i++) vp[i] = d3d_viewport_word(i);
        if (memcmp(vp, last_vp, sizeof vp))
            fprintf(stderr, "[watch] viewport %u,%u %ux%u after %s\n", vp[0], vp[1], vp[2], vp[3], bl_com_method_names[last_id]);
        memcpy(last_vp, vp, sizeof vp);
        last_id = id;
        static int traced;
        if (!strcmp(bl_com_method_names[id], "IDirect3DDevice9::SetViewport") && !traced) {
            const uint32_t *v = bl_g2h(G32(sp + 8));
            if (v[2] < 16) {
                void bl_guest_backtrace(uint32_t sp);
                traced = 1;
                bl_guest_backtrace(sp);
                const uint32_t *w = bl_g2h(sp);
                for (int i = 0; i < 64; i += 8)
                    fprintf(stderr, "[stk] %02x: %08x %08x %08x %08x %08x %08x %08x %08x\n", i * 4,
                            w[i], w[i + 1], w[i + 2], w[i + 3], w[i + 4], w[i + 5], w[i + 6], w[i + 7]);
            }
        }
    }
    // BL_COM_BT=<Interface::Method>: guest backtrace at its first call.
    static const char *bt_at;
    static int bt_done;
    if (!bt_done && (bt_at || (bt_at = getenv("BL_COM_BT"))) && !strcmp(bl_com_method_names[id], bt_at)) {
        void bl_guest_backtrace(uint32_t sp);
        bt_done = 1;
        bl_guest_backtrace(sp);
    }
    static int on = -1;
    if (on < 0) on = getenv("BL_D3D_TRACE") != NULL;
    if (!on) return;
    fprintf(stderr, "[com] %s(", bl_com_method_names[id]);
    for (uint32_t i = 0; i < bl_com_method_nargs[id]; i++)  // after the return address and this
        fprintf(stderr, "%s0x%x", i ? ", " : "", G32(sp + 8 + 4 * i));
    fprintf(stderr, ")\n");
}
