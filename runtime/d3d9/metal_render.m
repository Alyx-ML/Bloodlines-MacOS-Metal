// Metal renderer behind the D3D9 device.
//
// Render targets and depth buffers are Metal textures; a render pass stays open while
// the bound targets stay the same. A Clear() covering the whole target becomes the next
// pass's load action, a partial one draws a quad. Draws translate the D3D9 state into
// cached pipeline, depth-stencil and sampler states; shaders go through
// d3d9_shader.c. Dynamic vertex buffers, user-pointer draws and all index data are
// copied per draw into per-frame upload buffers, so later guest writes cannot change
// what an earlier draw reads; static vertex buffers live in MTLBuffers refreshed on
// Unlock. Present() copies the back buffer to the window's CAMetalLayer when there is
// a window (BL_WINDOW=1), otherwise the frame stays offscreen.
//
// Debug environment:
//   BL_MAX_FRAMES=n          exit after n presented frames
//   BL_CLICKS="f:x,y ..."    left clicks at game pixels x,y from frame f (bl_cocoa.m)
//   BL_DUMP_FRAME=n[,m...]   write frame n's back buffer to BL_DUMP_DIR/frame_<n>.png, and the last
//                            offscreen target (e.g. the shadow atlas) to frame_<n>_rt.png
//   BL_DUMP_DIR=dir          (default: current directory)
//   BL_DRAW_STATS=n[+k]      log the draws of frame n (and the k-1 frames after it)
//   BL_DRAW_DUMP=n[,m...]    log the vertices, constants and shaders of draws n, m...; with "p<count>[:k]",
//                            of the k-th (default first) draw in frame BL_DRAW_STATS with that many primitives
//                            (with BL_DUMP_DIR, its 32-bit textures are also written as PNGs)
//   BL_TEX_STATS=1           with BL_DRAW_STATS, log the mean brightness of each 32-bit texture drawn
//   BL_SHADOW_SHOW=1         draw shadow receivers opaque instead of darkening
//   BL_FPS_MAX=n             with a window, present at most n frames a second (default 60, 0 = no cap)
//   BL_MOVIE_DUMP=1          write frame 60 of each GDI-drawn movie to BL_DUMP_DIR
//   BL_SHADER_EARLY=0        compile shaders only when a draw first needs them
//   BL_SHADER_STATS=1        log frames that wait for shader or pipeline builds
//   BL_DEEP_COLOR=0          8-bit back buffer and window (default: 16-bit back buffer, 10-bit window)
//   BL_PACING=0              plain presents, even on screens whose refresh is a multiple of the cap
//   BL_PACING_STATS=1        log how many refreshes apart frames reach the screen
//   BL_FULLSCREEN=0|1        start in a window or full screen (default: what the game asks for)
//   BL_WIDESCREEN=stretch    keep the game's 4:3 projection on wider modes (default: corrected)
//   BL_MSAA=n                multisampling of the back buffer and its depth buffer (default 2, 1 = off)
//   BL_ANISO=n               anisotropic filtering for filtered mipmapped textures (default 16, 1 = off)
//   BL_AO=0|1|show           ambient occlusion (see ao_run), over the options' check box;
//                            BL_AO_RADIUS, BL_AO_STRENGTH tune it
//   BL_GPU_STATS=1           log the mean GPU time per frame every 100 frames
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <math.h>
#include <stdatomic.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_cocoa.h"
#include "bl_win32.h"
#include "d3d9_shader.h"
#include "d3d9_state.h"

static id<MTLDevice> mtl;
static id<MTLCommandQueue> queue;
static id<MTLCommandBuffer> cmd;
static id<MTLRenderCommandEncoder> enc;
static struct obj *enc_color, *enc_depth;  // targets of the open pass
static int enc_samples = 1;                // and its sample count
static CAMetalLayer *layer;

// Clears waiting for the next pass on these targets.
static struct obj *clear_color_target, *clear_depth_target;
static MTLClearColor clear_color;
static double clear_depth;
static uint32_t clear_stencil;
static int clear_has_stencil;

static uint32_t resized_w, resized_h;  // back buffer size (resize comes before init)
static unsigned long frames, draws, frame_draws;
static long max_frames = -1;
static int draw_stats;
static long draw_stats_frame, draw_stats_count = 1;
// Debug switches read once at start-up: getenv() per draw showed up in profiles.
static const char *env_draw_dump, *env_dump_dir;
static int env_tex_stats, env_shadow_show;
static double fps_max;  // frame cap with a window (BL_FPS_MAX, default 60; 0 = none)
static int env_pacing, env_pacing_stats;  // BL_PACING (default on), BL_PACING_STATS
static int env_aniso;   // forced anisotropy (BL_ANISO, default 16)
static int env_widescreen;  // correct the 4:3 projection on wider modes (BL_WIDESCREEN, default on)
static int frame_has_3d, menu_frame;  // a perspective draw to the back buffer: this frame, the last
static int last_3d;
static float frame_squeeze = 1;       // menu draws this frame were narrowed to this share of the width
static int msaa;        // samples for the back buffer and its depth (BL_MSAA, default 2; 1 = off)
static int deep_color;  // 16-bit back buffer, 10-bit window (BL_DEEP_COLOR, default on)

// Ambient occlusion (ao_run). ao_state: 0 no world view yet this frame, 1 world drawn
// (ao_proj holds its projection), 2 done for this frame.
static int env_ao, env_ao_show;
static float env_ao_radius, env_ao_strength;
static int ao_state;
static struct { float alpha, beta, p00, p11; } ao_proj;
static id<MTLTexture> ao_result;  // waiting to be multiplied in at the next pass on the back buffer
static void ao_apply(id<MTLRenderCommandEncoder> e, id<MTLTexture> color, int samples, int has_depth);

// The Visual options tab's check box (bl_vgui.c, read once a frame by bl_vgui_poll)
// sets env_ao and saves it in the registry; BL_AO, when set, wins over both.
#define AO_KEY "HKCU\\Software\\Troika\\Vampire\\Native"
static int ao_loaded, ao_forced;
void bl_vgui_poll(void);

static void ao_settings(void)
{
    if (ao_loaded) return;
    ao_loaded = 1;
    const char *e = getenv("BL_AO");
    ao_forced = e != NULL;
    env_ao_show = e && !strcmp(e, "show");
    env_ao = e ? atoi(e) != 0 || env_ao_show : bl_reg_get_dword(AO_KEY, "AmbientOcclusion", 0) != 0;
}

int bl_ao_enabled(void)
{
    ao_settings();
    return env_ao;
}

void bl_ao_set(int on)
{
    ao_settings();
    bl_reg_set_dword(AO_KEY, "AmbientOcclusion", on != 0);
    if (!ao_forced) env_ao = on != 0;
}

#define LOG_ONCE(...) do { static int once_; if (!once_++) fprintf(stderr, __VA_ARGS__); } while (0)

// --- per-frame upload buffers ------------------------------------------------------

#define FRAMES_IN_FLIGHT 3
#define CHUNK (32u << 20)
static dispatch_semaphore_t in_flight;
static NSMutableArray<id<MTLBuffer>> *chunks[FRAMES_IN_FLIGHT];
static int frame_slot;
static NSUInteger chunk_index, chunk_used;

// Copies n bytes into this frame's upload space (aligned); returns buffer and offset.
static id<MTLBuffer> upload(const void *data, NSUInteger n, NSUInteger *offset)
{
    NSMutableArray<id<MTLBuffer>> *list = chunks[frame_slot];
    chunk_used = (chunk_used + 255) & ~(NSUInteger)255;
    if (chunk_index >= list.count || chunk_used + n > list[chunk_index].length) {
        if (chunk_index < list.count && chunk_used) chunk_index++;
        while (chunk_index < list.count && list[chunk_index].length < n) chunk_index++;
        if (chunk_index >= list.count)
            [list addObject:[mtl newBufferWithLength:n > CHUNK ? n : CHUNK options:MTLResourceStorageModeShared]];
        chunk_used = 0;
    }
    id<MTLBuffer> b = list[chunk_index];
    if (data) memcpy((uint8_t *)b.contents + chunk_used, data, n);
    *offset = chunk_used;
    chunk_used += n;
    return b;
}

// --- formats and textures --------------------------------------------------------

static int is_depth_format(uint32_t f) { return f >= 70 && f <= 83; }  // D3DFMT_D16_LOCKABLE .. D24FS8

static MTLPixelFormat target_format(uint32_t f)
{
    if (is_depth_format(f)) return MTLPixelFormatDepth32Float_Stencil8;
    switch (f) {
    case 113: return MTLPixelFormatRGBA16Float;  // A16B16G16R16F
    case 36: return MTLPixelFormatRGBA16Unorm;   // A16B16G16R16
    case 114: return MTLPixelFormatR32Float;     // R32F
    case 116: return MTLPixelFormatRGBA32Float;  // A32B32G32R32F
    default: return MTLPixelFormatBGRA8Unorm;    // A8R8G8B8, X8R8G8B8 and the 16-bit RGB formats
    }
}

#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

// How a D3D texture format is stored: the Metal format, a channel swizzle, and whether
// the texels need converting to BGRA8 on upload.
struct texfmt {
    MTLPixelFormat pf;
    MTLTextureSwizzleChannels swz;
    int convert;  // 0 copy, else the D3D format to expand to BGRA8
    int block;    // bytes per 4x4 block for BC formats
};

static struct texfmt texture_format(uint32_t f)
{
    MTLTextureSwizzleChannels id = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                                                  MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    MTLTextureSwizzleChannels rgb1 = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                                                    MTLTextureSwizzleBlue, MTLTextureSwizzleOne);
    switch (f) {
    case 21: return (struct texfmt){MTLPixelFormatBGRA8Unorm, id, 0, 0};
    case 22: return (struct texfmt){MTLPixelFormatBGRA8Unorm, rgb1, 0, 0};
    case 20: case 23: case 24: case 25: case 26: case 27: case 29: case 30: case 31: case 32: case 33: case 52:
        return (struct texfmt){MTLPixelFormatBGRA8Unorm, id, (int)f, 0};
    case 28: return (struct texfmt){MTLPixelFormatA8Unorm, id, 0, 0};
    case 50:  // L8
        return (struct texfmt){MTLPixelFormatR8Unorm,
                               MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed,
                                                             MTLTextureSwizzleRed, MTLTextureSwizzleOne), 0, 0};
    case 51:  // A8L8
        return (struct texfmt){MTLPixelFormatRG8Unorm,
                               MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed,
                                                             MTLTextureSwizzleRed, MTLTextureSwizzleGreen), 0, 0};
    case 60:  // V8U8
        return (struct texfmt){MTLPixelFormatRG8Snorm,
                               MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                                             MTLTextureSwizzleOne, MTLTextureSwizzleOne), 0, 0};
    case 63: return (struct texfmt){MTLPixelFormatRGBA8Snorm, id, 0, 0};  // Q8W8V8U8
    case 36: return (struct texfmt){MTLPixelFormatRGBA16Unorm, id, 0, 0};
    case 113: return (struct texfmt){MTLPixelFormatRGBA16Float, id, 0, 0};
    case 114: return (struct texfmt){MTLPixelFormatR32Float, id, 0, 0};
    case 116: return (struct texfmt){MTLPixelFormatRGBA32Float, id, 0, 0};
    case FOURCC('D', 'X', 'T', '1'): return (struct texfmt){MTLPixelFormatBC1_RGBA, id, 0, 8};
    case FOURCC('D', 'X', 'T', '2'): case FOURCC('D', 'X', 'T', '3'):
        return (struct texfmt){MTLPixelFormatBC2_RGBA, id, 0, 16};
    case FOURCC('D', 'X', 'T', '4'): case FOURCC('D', 'X', 'T', '5'):
        return (struct texfmt){MTLPixelFormatBC3_RGBA, id, 0, 16};
    }
    if (is_depth_format(f)) return (struct texfmt){MTLPixelFormatDepth32Float_Stencil8, id, 0, 0};
    LOG_ONCE("[metal] texture format %u not supported, using BGRA8\n", f);
    return (struct texfmt){MTLPixelFormatBGRA8Unorm, id, 0, 0};
}

static inline uint32_t expand(uint32_t v, int bits) { return bits ? (v * 255 + ((1u << bits) - 1) / 2) / ((1u << bits) - 1) : 255; }

// One row of a 16/24/32-bit D3D format as BGRA8.
static void convert_row(uint32_t f, const uint8_t *src, uint8_t *dst, uint32_t w)
{
    for (uint32_t x = 0; x < w; x++, dst += 4) {
        uint32_t r = 0, g = 0, b = 0, a = 255;
        if (f == 20) {  // R8G8B8 (bytes B, G, R)
            b = src[3 * x], g = src[3 * x + 1], r = src[3 * x + 2];
        } else if (f == 31 || f == 32 || f == 33) {  // A2B10G10R10, A8B8G8R8, X8B8G8R8
            uint32_t v = ((const uint32_t *)src)[x];
            if (f == 31) r = v >> 2 & 255, g = v >> 12 & 255, b = v >> 22 & 255, a = expand(v >> 30, 2);
            else r = v & 255, g = v >> 8 & 255, b = v >> 16 & 255, a = f == 32 ? v >> 24 : 255;
        } else if (f == 52) {  // A4L4
            uint8_t v = src[x];
            r = g = b = expand(v & 15, 4), a = expand(v >> 4, 4);
        } else if (f == 27) {  // R3G3B2
            uint8_t v = src[x];
            r = expand(v >> 5 & 7, 3), g = expand(v >> 2 & 7, 3), b = expand(v & 3, 2);
        } else {
            uint32_t v = ((const uint16_t *)src)[x];
            switch (f) {
            case 23: r = expand(v >> 11, 5), g = expand(v >> 5 & 63, 6), b = expand(v & 31, 5); break;  // R5G6B5
            case 24: case 25:  // X1R5G5B5, A1R5G5B5
                r = expand(v >> 10 & 31, 5), g = expand(v >> 5 & 31, 5), b = expand(v & 31, 5);
                a = f == 25 ? (v >> 15 ? 255 : 0) : 255;
                break;
            case 26: case 30:  // A4R4G4B4, X4R4G4B4
                r = expand(v >> 8 & 15, 4), g = expand(v >> 4 & 15, 4), b = expand(v & 15, 4);
                a = f == 26 ? expand(v >> 12, 4) : 255;
                break;
            case 29: r = expand(v >> 5 & 7, 3), g = expand(v >> 2 & 7, 3), b = expand(v & 3, 2), a = v >> 8; break;
            }
        }
        dst[0] = (uint8_t)b, dst[1] = (uint8_t)g, dst[2] = (uint8_t)r, dst[3] = (uint8_t)a;
    }
}

static id<MTLTexture> target_texture(struct obj *o);

// Uploads one level (2D surface or volume) from guest memory.
static void upload_level(id<MTLTexture> t, struct texfmt tf, struct obj *s, NSUInteger slice, NSUInteger level)
{
    const uint8_t *src = bl_g2h(s->mem);
    MTLRegion r = MTLRegionMake3D(0, 0, 0, s->width, s->height, t.textureType == MTLTextureType3D ? s->depth : 1);
    if (tf.convert) {
        uint32_t row = s->width * 4;
        uint8_t *tmp = malloc((size_t)row * s->height * s->depth);
        for (uint32_t z = 0; z < s->depth; z++)
            for (uint32_t y = 0; y < s->height; y++)
                convert_row((uint32_t)tf.convert, src + z * s->slice + y * s->pitch, tmp + (z * s->height + y) * row,
                            s->width);
        [t replaceRegion:r mipmapLevel:level slice:slice withBytes:tmp bytesPerRow:row bytesPerImage:row * s->height];
        free(tmp);
    } else if (tf.block) {
        // Levels smaller than a block still upload a whole block.
        [t replaceRegion:r mipmapLevel:level slice:slice withBytes:src bytesPerRow:s->pitch bytesPerImage:s->slice];
    } else {
        [t replaceRegion:r mipmapLevel:level slice:slice withBytes:src bytesPerRow:s->pitch bytesPerImage:s->slice];
    }
    s->dirty = 0;
}

// The Metal texture of a D3D texture object, created and refreshed from guest memory.
static id<MTLTexture> texture_of(struct obj *tex)
{
    if (tex->type == OBJ_SURFACE) return target_texture(tex);
    int rt = (tex->usage & 1) != 0;  // D3DUSAGE_RENDERTARGET
    id<MTLTexture> t = (__bridge id<MTLTexture>)tex->gpu;
    struct texfmt tf = texture_format(tex->format);
    if (!t) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = tex->type == OBJ_CUBETEXTURE ? MTLTextureTypeCube
                      : tex->type == OBJ_VOLUMETEXTURE ? MTLTextureType3D : MTLTextureType2D;
        d.pixelFormat = rt ? target_format(tex->format) : tf.pf;
        d.width = tex->width, d.height = tex->height, d.depth = tex->type == OBJ_VOLUMETEXTURE ? tex->depth : 1;
        d.mipmapLevelCount = tex->levels;
        d.usage = MTLTextureUsageShaderRead | (rt ? MTLTextureUsageRenderTarget : 0);
        d.storageMode = rt ? MTLStorageModePrivate : MTLStorageModeShared;
        if (!rt) d.swizzle = tf.swz;
        t = [mtl newTextureWithDescriptor:d];
        if (!t) bl_fatal("cannot create a %ux%u texture of format %u", tex->width, tex->height, tex->format);
        tex->gpu = (__bridge_retained void *)t;
        tex->dirty = !rt;
        if (!rt)
            for (uint32_t i = 0; i < tex->nsubs; i++) tex->subs[i]->dirty = 1;
    }
    if (tex->dirty && !rt && tex->used) {
        // Rewritten after draws used it, which may still be encoded in this frame or running
        // on the GPU: those keep the old texture (command buffers retain it) and the new
        // contents go to a new one. The main menu's particle systems share a few textures
        // and rewrite them between draws within a frame; uploading in place showed every
        // system the last image written.
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = t.textureType, d.pixelFormat = t.pixelFormat;
        d.width = t.width, d.height = t.height, d.depth = t.depth, d.mipmapLevelCount = t.mipmapLevelCount;
        d.usage = t.usage, d.storageMode = t.storageMode, d.swizzle = t.swizzle;
        id<MTLTexture> n = [mtl newTextureWithDescriptor:d];
        if (n) {
            CFRelease(tex->gpu);
            tex->gpu = (__bridge_retained void *)n;
            t = n;
            for (uint32_t i = 0; i < tex->nsubs; i++) tex->subs[i]->dirty = 1;
        }
    }
    if (tex->dirty && !rt) {
        uint32_t faces = tex->type == OBJ_CUBETEXTURE ? 6 : 1;
        for (uint32_t f = 0; f < faces; f++)
            for (uint32_t l = 0; l < tex->levels; l++) {
                struct obj *s = tex->subs[f * tex->levels + l];
                if (s->dirty) upload_level(t, tf, s, f, l);
            }
        tex->dirty = 0;
    }
    tex->used = 1;
    return t;
}

// Render target surfaces: their own texture, or a level of the texture they belong to.
static id<MTLTexture> target_texture(struct obj *o)
{
    if (o->gpu) return (__bridge id<MTLTexture>)o->gpu;
    id<MTLTexture> t;
    struct obj *owner = o->owner;
    if (owner && owner->type != OBJ_DEVICE && (owner->usage & 1)) {
        id<MTLTexture> parent = texture_of(owner);
        uint32_t i = 0;
        while (i < owner->nsubs && owner->subs[i] != o) i++;
        NSUInteger level = i % owner->levels, slice = i / owner->levels;
        t = [parent newTextureViewWithPixelFormat:parent.pixelFormat textureType:MTLTextureType2D
                                           levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    } else {
        // The device's own colour surfaces (the back buffer) keep 16 bits per channel
        // with deep colour, so the game's many blended passes (lightmaps, fog, decals)
        // do not band. The values still clamp to 0..1 like the 8-bit format they stand
        // for; reads and copies to 8-bit surfaces convert (as_bgra8, d3d_render_stretch).
        MTLPixelFormat pf = target_format(o->format);
        if (deep_color && pf == MTLPixelFormatBGRA8Unorm && owner && owner->type == OBJ_DEVICE)
            pf = MTLPixelFormatRGBA16Unorm;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                     width:o->width
                                                                                    height:o->height
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        t = [mtl newTextureWithDescriptor:d];
    }
    t.label = [NSString stringWithFormat:@"surface %ux%u fmt %u", o->width, o->height, o->format];
    o->gpu = (__bridge_retained void *)t;
    return t;
}

// Multisampling covers the device's own surfaces: the back buffer and the automatic
// depth buffer. Passes on them draw into a multisampled copy and resolve into the
// surface's texture at the end, so everything that reads the surface sees the
// resolved image. Other render targets (shadows, reflections) stay single-sampled.
static int multisampled(struct obj *o) { return msaa > 1 && o && o->owner && o->owner->type == OBJ_DEVICE; }

static id<MTLTexture> ms_texture(struct obj *o)
{
    if (o->gpu_ms) return (__bridge id<MTLTexture>)o->gpu_ms;
    id<MTLTexture> single = target_texture(o);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:single.pixelFormat
                                                                                 width:o->width
                                                                                height:o->height
                                                                             mipmapped:NO];
    d.textureType = MTLTextureType2DMultisample;
    d.sampleCount = (NSUInteger)msaa;
    d.usage = MTLTextureUsageRenderTarget | (is_depth_format(o->format) ? MTLTextureUsageShaderRead : 0);  // ao_run reads depth
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [mtl newTextureWithDescriptor:d];
    t.label = [NSString stringWithFormat:@"surface %ux%u fmt %u x%d", o->width, o->height, o->format, msaa];
    o->gpu_ms = (__bridge_retained void *)t;
    o->ms_stale = 1;  // whatever the surface holds is not in the new copy
    return t;
}

// --- shaders -----------------------------------------------------------------------

// One D3DVERTEXELEMENT9.
struct element { uint16_t stream, offset; uint8_t type, method, usage, index; };

@interface BLShader : NSObject {
@public
    struct d3d_shader_info info;
    const uint32_t *code;  // NULL for fixed-function stages: ff (pixel) or ffv (vertex)
    struct d3d_ff_ps ff;
    struct d3d_ff_vs ffv;
    int ff_vertex;
    uint64_t serial;
    NSMutableDictionary<NSData *, id> *variants;  // id<MTLFunction>, or NSNull for a shader that failed
    // Background compile of the likely variant, started when the game creates the
    // shader (d3d_render_shader_created); shader_function waits for it.
    dispatch_group_t early;
    struct d3d_shader_variant early_variant;
    id early_function;  // id<MTLFunction> or NSNull, written by the background block
    _Atomic int early_state;  // 0 queued, 1 compiling in the background, 2 taken by a draw
}
@end
@implementation BLShader
@end

static uint64_t next_serial = 1;

static BLShader *shader_of(struct obj *o)
{
    if (o->gpu) return (__bridge BLShader *)o->gpu;
    BLShader *sh = [BLShader new];
    char err[256];
    sh->code = bl_g2h(o->mem);
    if (d3d_shader_parse(sh->code, &sh->info, err, sizeof err)) bl_fatal("shader: %s", err);
    sh->serial = next_serial++;
    sh->variants = [NSMutableDictionary new];
    o->gpu = (__bridge_retained void *)sh;
    return sh;
}

// The pixel "shader" of a draw without one: the texture stage cascade, one BLShader per
// distinct set of stage states.
static BLShader *ff_pixel_shader(struct d3d_state *s)
{
    static NSMutableDictionary<NSData *, BLShader *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    struct d3d_ff_ps k;
    memset(&k, 0, sizeof k);
    for (int i = 0; i < 8; i++) {
        const uint32_t *t = s->tss[i];
        k.colorop[i] = (uint8_t)t[1];
        if (k.colorop[i] <= 1) break;
        k.colorarg[i][0] = (uint8_t)t[26], k.colorarg[i][1] = (uint8_t)t[2], k.colorarg[i][2] = (uint8_t)t[3];
        k.alphaop[i] = (uint8_t)t[4];
        k.alphaarg[i][0] = (uint8_t)t[27], k.alphaarg[i][1] = (uint8_t)t[5], k.alphaarg[i][2] = (uint8_t)t[6];
        k.resultarg[i] = (uint8_t)t[28], k.texcoord[i] = (uint8_t)(t[11] & 7);
    }
    k.specular = s->rs[29] != 0;  // SPECULARENABLE
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    BLShader *sh = cache[key];
    if (sh) return sh;
    sh = [BLShader new];
    sh->ff = k;
    sh->info.pixel = 1, sh->info.major = 1;  // ps_1_x rules for projected texcoords
    sh->info.color_outputs = 1;
    sh->info.sampler_mask = d3d_ff_ps_samplers(&k);
    sh->serial = next_serial++;
    sh->variants = [NSMutableDictionary new];
    cache[key] = sh;
    if (getenv("BL_FF_TRACE")) {
        fprintf(stderr, "[ff] pixel stages %lu:", (unsigned long)sh->serial);
        for (int i = 0; i < 8 && k.colorop[i] > 1; i++)
            fprintf(stderr, " [%d: color %u(%#x,%#x,%#x) alpha %u(%#x,%#x,%#x) tc %u%s]", i, k.colorop[i],
                    k.colorarg[i][1], k.colorarg[i][2], k.colorarg[i][0], k.alphaop[i], k.alphaarg[i][1],
                    k.alphaarg[i][2], k.alphaarg[i][0], k.texcoord[i], k.resultarg[i] == 5 ? " temp" : "");
        fprintf(stderr, "%s\n", k.specular ? " +specular" : "");
    }
    return sh;
}

// The vertex "shader" of a draw without one, for the inputs its declaration has.
static BLShader *ff_vertex_shader(const struct element *el, int nel)
{
    static NSMutableDictionary<NSData *, BLShader *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    struct d3d_ff_vs k;
    memset(&k, 0, sizeof k);
    for (int j = 0; j < nel; j++) {
        if (el[j].usage == 9 && el[j].index == 0) k.positiont = 1;  // POSITIONT
        if (el[j].usage == 10 && el[j].index < 2) k.color[el[j].index] = 1;
        if (el[j].usage == 5 && el[j].index < 8) k.tex_mask |= (uint8_t)(1u << el[j].index);
    }
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    BLShader *sh = cache[key];
    if (sh) return sh;
    sh = [BLShader new];
    sh->ffv = k, sh->ff_vertex = 1;
    sh->info.input_mask = 1, sh->info.input_usage[0] = k.positiont ? 9 : 0;
    for (int c = 0; c < 2; c++)
        if (k.color[c]) sh->info.input_mask |= 2u << c, sh->info.input_usage[1 + c] = 10, sh->info.input_index[1 + c] = (uint8_t)c;
    for (int n = 0; n < 8; n++)
        if (k.tex_mask & (1u << n))
            sh->info.input_mask |= 8u << n, sh->info.input_usage[3 + n] = 5, sh->info.input_index[3 + n] = (uint8_t)n;
    sh->serial = next_serial++;
    sh->variants = [NSMutableDictionary new];
    cache[key] = sh;
    return sh;
}

// Row-major 4x4 product a * b (D3D matrices are row-major, vectors are rows).
static void mat_mul(const float *a, const float *b, float *out)
{
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            float t = 0;
            for (int k = 0; k < 4; k++) t += a[4 * i + k] * b[4 * k + j];
            out[4 * i + j] = t;
        }
}

// BL_SHADER_STATS=1: time spent building shaders and pipelines during draws, per frame.
static int env_shader_stats;
static uint64_t build_ns[2], build_count[2], frame_build_ns;  // [0] shaders, [1] pipelines
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Translates and compiles one variant: an MTLFunction, or NSNull (logged) when the
// shader does not translate or compile. Thread-safe; `code` is the shader's bytecode
// (NULL for the fixed-function stages in sh).
static id compile_variant(BLShader *sh, const uint32_t *code, const struct d3d_shader_variant *v)
{
    char err[256];
    char *msl = code ? d3d_shader_msl(code, v, err, sizeof err)
                : sh->ff_vertex ? d3d_ff_vs_msl(&sh->ffv, err, sizeof err) : d3d_ff_ps_msl(&sh->ff, v, err, sizeof err);
    if (!msl) {
        fprintf(stderr, "[metal] shader %lu does not translate: %s\n", (unsigned long)sh->serial, err);
        return [NSNull null];
    }
    NSError *error = nil;
    MTLCompileOptions *opt = [MTLCompileOptions new];
    if (@available(macOS 15.0, *)) opt.mathMode = MTLMathModeSafe;
    else opt.fastMathEnabled = NO;
    NSString *source = [NSString stringWithUTF8String:msl];
    // BL_SHADER_SALT=x changes every source, so macOS's own shader cache misses: a
    // first launch, for measuring.
    if (getenv("BL_SHADER_SALT")) source = [NSString stringWithFormat:@"// %s\n%@", getenv("BL_SHADER_SALT"), source];
    id<MTLLibrary> lib = [mtl newLibraryWithSource:source options:opt error:&error];
    if (!lib) {
        fprintf(stderr, "[metal] shader %lu does not compile, its draws are skipped: %s\n%s\n",
                (unsigned long)sh->serial, error.localizedDescription.UTF8String, msl);
        free(msl);
        return [NSNull null];
    }
    free(msl);
    return [lib newFunctionWithName:@"bl_main"];
}

// A shader that does not translate or compile is logged once and its draws are
// skipped (NSNull in the cache), so one bad shader does not end the game.
static id<MTLFunction> shader_function(BLShader *sh, const struct d3d_shader_variant *v)
{
    NSData *key = [NSData dataWithBytes:v length:sizeof *v];
    id f = sh->variants[key];
    if (f) return f == [NSNull null] ? nil : f;
    uint64_t t0 = now_ns();
    if (sh->early) {
        // Still queued behind other shaders: compile it here instead of waiting. Already
        // compiling: wait for it.
        int queued = 0;
        if (!atomic_compare_exchange_strong(&sh->early_state, &queued, 2)) {
            dispatch_group_wait(sh->early, DISPATCH_TIME_FOREVER);
            sh->variants[[NSData dataWithBytes:&sh->early_variant length:sizeof sh->early_variant]] = sh->early_function;
        }
        sh->early = nil, sh->early_function = nil;
        f = sh->variants[key];
    }
    if (!f) {
        f = compile_variant(sh, sh->code, v);
        sh->variants[key] = f;
        build_count[0]++;
    }
    uint64_t dt = now_ns() - t0;  // with an early compile: only the part not yet done
    build_ns[0] += dt, frame_build_ns += dt;
    return f == [NSNull null] ? nil : f;
}

// Compiling a shader the first time a draw uses it stalls that frame: about 30 ms per
// shader when macOS's shader cache does not have it yet (first launch, or after a
// macOS update), and over half a second on a map's first frame. The game creates its
// shaders while loading, so each one starts compiling then, on all cores, for the
// variant its draws most likely use: float vertex inputs, 2D textures, no projected
// texture coordinates. A draw that needs another variant compiles it as before.
// BL_SHADER_EARLY=0 turns this off.
static int env_shader_early;
static unsigned long shaders_early;
static void ensure_device(void);

void d3d_render_shader_created(struct obj *o)
{
    ensure_device();
    if (!env_shader_early) return;
    BLShader *sh = shader_of(o);
    struct d3d_shader_variant v;
    memset(&v, 0, sizeof v);
    if (sh->info.pixel)
        for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++)
            if (sh->info.sampler_mask & (1u << i))
                v.tex_kind[i] = (uint8_t)(sh->info.sampler_type[i] ? sh->info.sampler_type[i] : D3D_TEX_2D);
    static dispatch_queue_t queue;
    if (!queue) queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    // The game may release the shader before the compile ends: compile from a copy.
    NSData *code = [NSData dataWithBytes:sh->code length:o->size];
    sh->early = dispatch_group_create();
    sh->early_variant = v;
    shaders_early++;
    dispatch_group_async(sh->early, queue, ^{
      int queued = 0;
      if (atomic_compare_exchange_strong(&sh->early_state, &queued, 1))
          sh->early_function = compile_variant(sh, code.bytes, &v);
    });
}

// Internal shaders: partial clears.
static id<MTLRenderPipelineState> clear_pipeline(MTLPixelFormat color, MTLPixelFormat depth, uint32_t mask,
                                                 int samples);
static id<MTLRenderPipelineState> stretch_pipeline(MTLPixelFormat color, int samples);

// --- vertex input --------------------------------------------------------------------

// D3DDECLTYPE -> Metal vertex format and the shader-side type.
static MTLVertexFormat decl_format(uint32_t type, uint8_t *kind)
{
    *kind = D3D_IN_FLOAT;
    switch (type) {
    case 0: return MTLVertexFormatFloat;
    case 1: return MTLVertexFormatFloat2;
    case 2: return MTLVertexFormatFloat3;
    case 3: return MTLVertexFormatFloat4;
    case 4: return MTLVertexFormatUChar4Normalized_BGRA;  // D3DCOLOR
    case 5: *kind = D3D_IN_UINT; return MTLVertexFormatUChar4;
    case 6: *kind = D3D_IN_SINT; return MTLVertexFormatShort2;
    case 7: *kind = D3D_IN_SINT; return MTLVertexFormatShort4;
    case 8: return MTLVertexFormatUChar4Normalized;
    case 9: return MTLVertexFormatShort2Normalized;
    case 10: return MTLVertexFormatShort4Normalized;
    case 11: return MTLVertexFormatUShort2Normalized;
    case 12: return MTLVertexFormatUShort4Normalized;
    case 14: return MTLVertexFormatInt1010102Normalized;
    case 15: return MTLVertexFormatHalf2;
    case 16: return MTLVertexFormatHalf4;
    default: LOG_ONCE("[metal] vertex type %u not supported\n", type); return MTLVertexFormatFloat4;
    }
}


// Elements of the bound declaration, or of the FVF expressed as a declaration.
static int vertex_elements(struct d3d_state *s, struct element *e, int max)
{
    int n = 0;
    if (s->vdecl) {
        const struct element *d = bl_g2h(s->vdecl->mem);
        while (n < max && d[n].stream != 0xFF) e[n] = d[n], n++;
        return n;
    }
    uint32_t fvf = s->fvf;
    uint16_t off = 0;
#define ADD(t, u, i, size) (e[n++] = (struct element){0, off, t, 0, u, i}, off += size)
    uint32_t pos = fvf & 0x400E;
    if (pos == 0x4) ADD(3, 9, 0, 16);       // XYZRHW: POSITIONT
    else if (pos) {
        ADD(2, 0, 0, 12);                   // XYZ
        int weights = pos == 0x6 ? 1 : pos == 0x8 ? 2 : pos == 0xA ? 3 : pos == 0xC ? 4 : pos == 0xE ? 5 : 0;
        if (pos == 0x4002) ADD(3, 0, 1, 4); // XYZW: w joins the position (approximation)
        if (weights) {
            int last_is_index = (fvf & 0x1000) || (fvf & 0x8000);  // LASTBETA_UBYTE4 / D3DCOLOR
            int w = weights - (last_is_index ? 1 : 0);
            if (w) ADD((uint8_t)(w - 1), 1, 0, (uint16_t)(4 * w));
            if (last_is_index) ADD((fvf & 0x1000) ? 5 : 4, 2, 0, 4);
        }
    }
    if (fvf & 0x10) ADD(2, 3, 0, 12);       // NORMAL
    if (fvf & 0x20) ADD(0, 4, 0, 4);        // PSIZE
    if (fvf & 0x40) ADD(4, 10, 0, 4);       // DIFFUSE
    if (fvf & 0x80) ADD(4, 10, 1, 4);       // SPECULAR
    uint32_t ntex = (fvf >> 8) & 15;
    for (uint32_t i = 0; i < ntex && n < max; i++) {
        uint32_t f = (fvf >> (16 + 2 * i)) & 3;  // 0: 2 floats, 1: 3, 2: 4, 3: 1
        static const uint8_t type[4] = {1, 2, 3, 0}, size[4] = {8, 12, 16, 4};
        ADD(type[f], 5, (uint8_t)i, size[f]);
    }
#undef ADD
    return n;
}

// --- pipeline state --------------------------------------------------------------------

struct pipe_key {
    uint64_t vs, ps;
    struct d3d_shader_variant vsv, psv;
    uint16_t color_format, depth_format;
    uint32_t blend[7];  // enable, src, dst, op, src alpha, dst alpha, op alpha
    uint32_t write_mask;
    struct { uint16_t offset; uint8_t format, buffer; } attr[16];
    uint16_t stride[17];
    uint8_t constant[17];
    uint8_t point;
    uint8_t samples, alpha_to_coverage;
};

static NSMutableDictionary<NSData *, id<MTLRenderPipelineState>> *pipelines;
static NSMutableDictionary<NSData *, id<MTLDepthStencilState>> *depth_states;
static NSMutableDictionary<NSData *, id<MTLSamplerState>> *samplers;
static id<MTLBuffer> zero_buffer;

static MTLBlendFactor blend_factor(uint32_t b, int alpha)
{
    switch (b) {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return alpha ? MTLBlendFactorSourceAlpha : MTLBlendFactorSourceColor;
    case 4: return alpha ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return alpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorDestinationColor;
    case 10: return alpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 14: return alpha ? MTLBlendFactorBlendAlpha : MTLBlendFactorBlendColor;
    case 15: return alpha ? MTLBlendFactorOneMinusBlendAlpha : MTLBlendFactorOneMinusBlendColor;
    default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blend_op(uint32_t op)
{
    switch (op) {
    case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract;
    case 4: return MTLBlendOperationMin;
    case 5: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

static MTLCompareFunction compare(uint32_t f)
{
    static const MTLCompareFunction m[] = {
        MTLCompareFunctionAlways, MTLCompareFunctionNever, MTLCompareFunctionLess, MTLCompareFunctionEqual,
        MTLCompareFunctionLessEqual, MTLCompareFunctionGreater, MTLCompareFunctionNotEqual,
        MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways,
    };
    return f <= 8 ? m[f] : MTLCompareFunctionAlways;
}

static MTLStencilOperation stencil_op(uint32_t op)
{
    static const MTLStencilOperation m[] = {
        MTLStencilOperationKeep, MTLStencilOperationKeep, MTLStencilOperationZero, MTLStencilOperationReplace,
        MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp, MTLStencilOperationInvert,
        MTLStencilOperationIncrementWrap, MTLStencilOperationDecrementWrap,
    };
    return op <= 8 ? m[op] : MTLStencilOperationKeep;
}

static id<MTLRenderPipelineState> pipeline(struct pipe_key *k, id<MTLFunction> vs, id<MTLFunction> ps)
{
    NSData *key = [NSData dataWithBytes:k length:sizeof *k];
    id<MTLRenderPipelineState> p = pipelines[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs;
    d.fragmentFunction = ps;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    uint32_t used = 0;
    for (int i = 0; i < 16; i++) {
        if (!k->attr[i].format) continue;
        vd.attributes[i].format = (MTLVertexFormat)k->attr[i].format;
        vd.attributes[i].offset = k->attr[i].offset;
        vd.attributes[i].bufferIndex = k->attr[i].buffer;
        used |= 1u << k->attr[i].buffer;
    }
    for (int b = 0; b < 17; b++) {
        if (!(used & (1u << b))) continue;
        if (k->constant[b] || !k->stride[b]) {
            vd.layouts[b].stepFunction = MTLVertexStepFunctionConstant;
            vd.layouts[b].stepRate = 0;
            vd.layouts[b].stride = k->stride[b] ? k->stride[b] : 16;
        } else {
            vd.layouts[b].stride = k->stride[b];
        }
    }
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = (MTLPixelFormat)k->color_format;
    if (k->color_format) {
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0];
        c.blendingEnabled = k->blend[0] != 0;
        c.sourceRGBBlendFactor = blend_factor(k->blend[1], 0);
        c.destinationRGBBlendFactor = blend_factor(k->blend[2], 0);
        c.rgbBlendOperation = blend_op(k->blend[3]);
        c.sourceAlphaBlendFactor = blend_factor(k->blend[4], 1);
        c.destinationAlphaBlendFactor = blend_factor(k->blend[5], 1);
        c.alphaBlendOperation = blend_op(k->blend[6]);
        MTLColorWriteMask m = 0;
        if (k->write_mask & 1) m |= MTLColorWriteMaskRed;
        if (k->write_mask & 2) m |= MTLColorWriteMaskGreen;
        if (k->write_mask & 4) m |= MTLColorWriteMaskBlue;
        if (k->write_mask & 8) m |= MTLColorWriteMaskAlpha;
        c.writeMask = m;
    }
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k->depth_format;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->depth_format;
    d.inputPrimitiveTopology = k->point ? MTLPrimitiveTopologyClassPoint : MTLPrimitiveTopologyClassUnspecified;
    d.rasterSampleCount = k->samples ? k->samples : 1;
    d.alphaToCoverageEnabled = k->alpha_to_coverage != 0;
    NSError *error = nil;
    uint64_t t0 = now_ns();
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    uint64_t dt = now_ns() - t0;
    build_ns[1] += dt, build_count[1]++, frame_build_ns += dt;
    if (!p) {
        fprintf(stderr, "[metal] pipeline failed, its draws are skipped: %s\n", error.localizedDescription.UTF8String);
        return nil;  // not cached: rare, and the log says each time
    }
    pipelines[key] = p;
    return p;
}

static id<MTLDepthStencilState> depth_state(struct d3d_state *s, int has_depth)
{
    const uint32_t *rs = s->rs;
    uint32_t k[16] = {0};
    if (has_depth) {
        k[0] = rs[7] ? 1 : 0;           // ZENABLE
        k[1] = rs[14];                  // ZWRITEENABLE
        k[2] = rs[23];                  // ZFUNC
        k[3] = rs[52];                  // STENCILENABLE
        if (k[3]) {
            k[4] = rs[53], k[5] = rs[54], k[6] = rs[55], k[7] = rs[56];  // FAIL, ZFAIL, PASS, FUNC
            k[8] = rs[58], k[9] = rs[59];                                // MASK, WRITEMASK
            k[10] = rs[185];                                             // TWOSIDEDSTENCILMODE
            if (k[10]) k[11] = rs[186], k[12] = rs[187], k[13] = rs[188], k[14] = rs[189];
        }
    }
    NSData *key = [NSData dataWithBytes:k length:sizeof k];
    id<MTLDepthStencilState> d = depth_states[key];
    if (d) return d;
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = k[0] ? compare(k[2]) : MTLCompareFunctionAlways;
    dd.depthWriteEnabled = k[0] && k[1];
    if (k[3]) {
        MTLStencilDescriptor *front = [MTLStencilDescriptor new];
        front.stencilFailureOperation = stencil_op(k[4]);
        front.depthFailureOperation = stencil_op(k[5]);
        front.depthStencilPassOperation = stencil_op(k[6]);
        front.stencilCompareFunction = compare(k[7]);
        front.readMask = k[8] & 0xFF;
        front.writeMask = k[9] & 0xFF;
        dd.frontFaceStencil = front;
        if (k[10]) {
            MTLStencilDescriptor *back = [MTLStencilDescriptor new];
            back.stencilFailureOperation = stencil_op(k[11]);
            back.depthFailureOperation = stencil_op(k[12]);
            back.depthStencilPassOperation = stencil_op(k[13]);
            back.stencilCompareFunction = compare(k[14]);
            back.readMask = k[8] & 0xFF;
            back.writeMask = k[9] & 0xFF;
            dd.backFaceStencil = back;
        } else {
            dd.backFaceStencil = front;
        }
    }
    d = [mtl newDepthStencilStateWithDescriptor:dd];
    depth_states[key] = d;
    return d;
}

static MTLSamplerAddressMode address_mode(uint32_t m)
{
    switch (m) {
    case 2: return MTLSamplerAddressModeMirrorRepeat;
    case 3: return MTLSamplerAddressModeClampToEdge;
    case 4: return MTLSamplerAddressModeClampToBorderColor;
    case 5: return MTLSamplerAddressModeMirrorClampToEdge;
    default: return MTLSamplerAddressModeRepeat;
    }
}

static id<MTLSamplerState> sampler_state(const uint32_t *ss, int mipmapped)
{
    uint32_t k[8] = {ss[1], ss[2], ss[3], ss[5], ss[6], mipmapped ? ss[7] : 0, ss[9], ss[10]};
    uint32_t border = ss[4];
    k[0] |= (border == 0xFFFFFFFFu ? 1u : border >> 24 ? 2u : 0u) << 8;  // border: opaque white/black or transparent
    NSData *key = [NSData dataWithBytes:k length:sizeof k];
    id<MTLSamplerState> st = samplers[key];
    if (st) return st;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.sAddressMode = address_mode(ss[1]);
    d.tAddressMode = address_mode(ss[2]);
    d.rAddressMode = address_mode(ss[3]);
    d.borderColor = border == 0xFFFFFFFFu ? MTLSamplerBorderColorOpaqueWhite
                  : border >> 24 ? MTLSamplerBorderColorOpaqueBlack : MTLSamplerBorderColorTransparentBlack;
    d.magFilter = ss[5] >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = ss[6] >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = !mipmapped || ss[7] == 0 ? MTLSamplerMipFilterNotMipmapped
                : ss[7] == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    d.lodMinClamp = ss[9];  // MAXMIPLEVEL: the largest level used
    if (ss[5] == 3 || ss[6] == 3) d.maxAnisotropy = ss[10] < 1 ? 1 : ss[10] > 16 ? 16 : ss[10];
    // The game asks for trilinear at most; filtered mipmapped textures also get
    // anisotropic filtering (BL_ANISO, default 16, 1 turns it off).
    if (d.minFilter == MTLSamplerMinMagFilterLinear && d.mipFilter != MTLSamplerMipFilterNotMipmapped &&
        env_aniso > d.maxAnisotropy)
        d.maxAnisotropy = env_aniso;
    st = [mtl newSamplerStateWithDescriptor:d];
    samplers[key] = st;
    return st;
}

// Placeholder for unbound samplers: D3D9 reads (0, 0, 0, 1).
static id<MTLTexture> dummy_texture(int kind)
{
    static id<MTLTexture> t[5];
    if (t[kind]) return t[kind];
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == D3D_TEX_CUBE ? MTLTextureTypeCube : kind == D3D_TEX_3D ? MTLTextureType3D : MTLTextureType2D;
    d.pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.width = d.height = 1;
    d.storageMode = MTLStorageModeShared;
    t[kind] = [mtl newTextureWithDescriptor:d];
    uint32_t black = 0xFF000000u;
    for (NSUInteger slice = 0; slice < (kind == D3D_TEX_CUBE ? 6u : 1u); slice++)
        [t[kind] replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:slice withBytes:&black bytesPerRow:4
                 bytesPerImage:4];
    return t[kind];
}

static int tex_kind_of(struct obj *t)
{
    if (!t) return D3D_TEX_2D;
    return t->type == OBJ_CUBETEXTURE ? D3D_TEX_CUBE : t->type == OBJ_VOLUMETEXTURE ? D3D_TEX_3D : D3D_TEX_2D;
}

// --- passes ----------------------------------------------------------------------

static void ensure_device(void)
{
    if (mtl) return;
    mtl = MTLCreateSystemDefaultDevice();
    if (!mtl) bl_fatal("no Metal device");
    queue = [mtl newCommandQueue];
    in_flight = dispatch_semaphore_create(FRAMES_IN_FLIGHT);
    for (int i = 0; i < FRAMES_IN_FLIGHT; i++) chunks[i] = [NSMutableArray new];
    dispatch_semaphore_wait(in_flight, DISPATCH_TIME_FOREVER);
    pipelines = [NSMutableDictionary new];
    depth_states = [NSMutableDictionary new];
    samplers = [NSMutableDictionary new];
    static const float zero[4] = {0, 0, 0, 0};
    zero_buffer = [mtl newBufferWithBytes:zero length:sizeof zero options:MTLResourceStorageModeShared];
    const char *m = getenv("BL_MAX_FRAMES");
    if (m) max_frames = atol(m);
    draw_stats = getenv("BL_DRAW_STATS") != NULL;
    draw_stats_frame = draw_stats ? atol(getenv("BL_DRAW_STATS")) : -1;
    if (draw_stats && strchr(getenv("BL_DRAW_STATS"), '+')) draw_stats_count = atol(strchr(getenv("BL_DRAW_STATS"), '+') + 1);
    env_draw_dump = getenv("BL_DRAW_DUMP");
    env_dump_dir = getenv("BL_DUMP_DIR");
    env_tex_stats = getenv("BL_TEX_STATS") != NULL;
    env_shadow_show = getenv("BL_SHADOW_SHOW") != NULL;
    fps_max = getenv("BL_FPS_MAX") ? atof(getenv("BL_FPS_MAX")) : 60;
    env_pacing = !(getenv("BL_PACING") && !strcmp(getenv("BL_PACING"), "0"));
    env_pacing_stats = getenv("BL_PACING_STATS") != NULL;
    env_shader_stats = getenv("BL_SHADER_STATS") != NULL;
    env_shader_early = !(getenv("BL_SHADER_EARLY") && !strcmp(getenv("BL_SHADER_EARLY"), "0"));
    env_aniso = getenv("BL_ANISO") ? atoi(getenv("BL_ANISO")) : 16;
    env_aniso = env_aniso < 1 ? 1 : env_aniso > 16 ? 16 : env_aniso;
    msaa = getenv("BL_MSAA") ? atoi(getenv("BL_MSAA")) : 2;
    deep_color = !(getenv("BL_DEEP_COLOR") && !strcmp(getenv("BL_DEEP_COLOR"), "0"));
    env_widescreen = !(getenv("BL_WIDESCREEN") && !strcmp(getenv("BL_WIDESCREEN"), "stretch"));
    if (msaa < 1 || ![mtl supportsTextureSampleCount:(NSUInteger)msaa]) msaa = 1;
    ao_settings();
    env_ao_radius = getenv("BL_AO_RADIUS") ? (float)atof(getenv("BL_AO_RADIUS")) : 32;
    env_ao_strength = getenv("BL_AO_STRENGTH") ? (float)atof(getenv("BL_AO_STRENGTH")) : 0.6f;
}

static id<MTLCommandBuffer> command_buffer(void)
{
    if (!cmd) cmd = [queue commandBuffer];
    return cmd;
}

static void end_pass(void)
{
    if (!enc) return;
    [enc endEncoding];
    enc = nil;
    enc_color = enc_depth = NULL;
}

// Opens a pass on the bound targets (render_target[0], depth_stencil), applying
// pending clears for them.
static void write_png(id<MTLBuffer> b, NSUInteger w, NSUInteger h, const char *path);
static struct obj *last_offscreen_target;  // for BL_DUMP_FRAME: the last non-back-buffer color target

// Copies a surface's texture into its multisampled copy, after something other than a
// multisampled pass wrote it (StretchRect, a pass that could not be multisampled).
static void restore_ms(struct obj *o, id<MTLTexture> ms)
{
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = ms;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:stretch_pipeline(ms.pixelFormat, (int)ms.sampleCount)];
    [e setViewport:(MTLViewport){0, 0, ms.width, ms.height, 0, 1}];
    float p[4] = {0, 0, 1, 1};
    [e setVertexBytes:p length:sizeof p atIndex:0];
    [e setFragmentTexture:target_texture(o) atIndex:0];
    static id<MTLSamplerState> nearest;
    if (!nearest) nearest = [mtl newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    [e setFragmentSamplerState:nearest atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

static id<MTLRenderCommandEncoder> pass(struct d3d_state *s)
{
    struct obj *color = s->render_target[0], *depth = s->depth_stencil;
    if (enc && enc_color == color && enc_depth == depth) return enc;
    end_pass();
    if (color && color != s->back_buffer) last_offscreen_target = color;
    int samples = multisampled(color ? color : depth) ? msaa : 1;
    if (samples > 1 && color && depth && !multisampled(depth)) {
        LOG_ONCE("[metal] back buffer with a depth surface of its own: not multisampled\n");
        samples = 1;
    }
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
    if (color) {
        if (samples > 1) {
            id<MTLTexture> ms = ms_texture(color);
            if (color->ms_stale && clear_color_target != color) restore_ms(color, ms);
            color->ms_stale = 0;
            d.colorAttachments[0].texture = ms;
            d.colorAttachments[0].resolveTexture = target_texture(color);
            d.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        } else {
            d.colorAttachments[0].texture = target_texture(color);
            d.colorAttachments[0].storeAction = MTLStoreActionStore;
            if (multisampled(color)) color->ms_stale = 1;
        }
        if (clear_color_target == color) {
            d.colorAttachments[0].loadAction = MTLLoadActionClear;
            d.colorAttachments[0].clearColor = clear_color;
            clear_color_target = NULL;
        } else {
            d.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
    }
    if (depth) {
        id<MTLTexture> t = samples > 1 ? ms_texture(depth) : target_texture(depth);
        d.depthAttachment.texture = t;
        d.stencilAttachment.texture = t;
        d.depthAttachment.storeAction = d.stencilAttachment.storeAction = MTLStoreActionStore;
        d.depthAttachment.loadAction = d.stencilAttachment.loadAction = MTLLoadActionLoad;
        if (clear_depth_target == depth) {
            d.depthAttachment.loadAction = MTLLoadActionClear;
            d.depthAttachment.clearDepth = clear_depth;
            if (clear_has_stencil) {
                d.stencilAttachment.loadAction = MTLLoadActionClear;
                d.stencilAttachment.clearStencil = clear_stencil;
            }
            clear_depth_target = NULL;
        }
    }
    enc = [command_buffer() renderCommandEncoderWithDescriptor:d];
    enc_color = color, enc_depth = depth, enc_samples = samples;
    if (ao_result && color && color == s->back_buffer) ao_apply(enc, target_texture(color), samples, depth != NULL);
    return enc;
}

// Runs clears that no draw picked up.
static void flush_clears(struct d3d_state *s)
{
    if ((clear_color_target && clear_color_target == s->render_target[0]) ||
        (clear_depth_target && clear_depth_target == s->depth_stencil))
        pass(s);
    end_pass();
}

void d3d_render_free(struct obj *o)
{
    if (o->gpu_ms) {
        id m = (__bridge_transfer id)o->gpu_ms;
        (void)m;
        o->gpu_ms = NULL;
    }
    if (!o->gpu) return;
    id t = (__bridge_transfer id)o->gpu;  // released when t goes out of scope
    (void)t;
    o->gpu = NULL;
    if (enc_color == o || enc_depth == o) end_pass();
    if (clear_color_target == o) clear_color_target = NULL;
    if (clear_depth_target == o) clear_depth_target = NULL;
}

// Full screen when the game asks for it (no -window), unless BL_FULLSCREEN says otherwise.
static int game_windowed = 1;
static int full_screen(void)
{
    const char *f = getenv("BL_FULLSCREEN");
    return f && *f ? f[0] != '0' : !game_windowed;
}

static uint32_t game_window;

void d3d_render_init(uint32_t window)
{
    ensure_device();
    game_window = window;
    if (getenv("BL_WINDOW")) {
        uint32_t w = resized_w ? resized_w : 1024, h = resized_h ? resized_h : 768;
        layer = bl_cocoa_open_window(w, h, "Vampire: The Masquerade – Bloodlines", window);
        if (layer) {
            layer.device = mtl;
            // The game's colours are sRGB. Without a colour space the compositor shows
            // them unconverted, too saturated on a wide-gamut (P3) screen.
            layer.pixelFormat = deep_color ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm;
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            layer.colorspace = srgb;
            CGColorSpaceRelease(srgb);
            layer.framebufferOnly = NO;
            layer.drawableSize = CGSizeMake(w, h);
            bl_cocoa_set_fullscreen(full_screen());
        }
    }
}

void d3d_render_windowed(int windowed)
{
    // Only a change of the game's setting moves the window; Cmd+Ctrl+F in between stays.
    if (windowed == game_windowed) return;
    game_windowed = windowed;
    if (layer) bl_cocoa_set_fullscreen(full_screen());
}

void d3d_render_resize(uint32_t width, uint32_t height)
{
    ensure_device();
    resized_w = width, resized_h = height;
    if (layer) {
        layer.drawableSize = CGSizeMake(width, height);
        bl_cocoa_set_content_size(width, height);
    }
}

// Viewport and scissor for the bound target.
// `squeeze` < 1 narrows everything horizontally about the target's centre (menus at 4:3).
static void set_viewport(struct d3d_state *s, id<MTLRenderCommandEncoder> e, uint32_t tw, uint32_t th, float squeeze)
{
    const uint32_t *vp = s->viewport;
    static uint32_t full[6];
    static int force = -1;
    if (force < 0) force = getenv("BL_FORCE_VIEWPORT") != NULL;
    if (force) {  // debugging: draw everything to the whole target
        full[2] = tw, full[3] = th, full[4] = vp[4], full[5] = vp[5];
        vp = full;
    }
    double cx = tw / 2.0;
#define SQUEEZE(x) (squeeze < 1 ? cx + ((x) - cx) * squeeze : (x))
    [e setViewport:(MTLViewport){SQUEEZE(vp[0]), vp[1], vp[2] * (squeeze < 1 ? squeeze : 1), vp[3], u2f(vp[4]), u2f(vp[5])}];
    int32_t x0 = (int32_t)vp[0], y0 = (int32_t)vp[1], x1 = x0 + (int32_t)vp[2], y1 = y0 + (int32_t)vp[3];
    if (s->rs[174]) {  // SCISSORTESTENABLE
        const int32_t *r = (const int32_t *)s->scissor;
        if (r[0] > x0) x0 = r[0];
        if (r[1] > y0) y0 = r[1];
        if (r[2] < x1) x1 = r[2];
        if (r[3] < y1) y1 = r[3];
    }
    if (squeeze < 1) x0 = (int32_t)floor(SQUEEZE(x0)), x1 = (int32_t)ceil(SQUEEZE(x1));
#undef SQUEEZE
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int32_t)tw) x1 = (int32_t)tw;
    if (y1 > (int32_t)th) y1 = (int32_t)th;
    if (x1 <= x0 || y1 <= y0) x0 = y0 = 0, x1 = y1 = 0;
    [e setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
}

void d3d_render_clear(struct d3d_state *s, uint32_t count, uint32_t rects, uint32_t flags, uint32_t color, float z,
                      uint32_t stencil)
{
    ensure_device();
    struct obj *rt = s->render_target[0], *ds = s->depth_stencil;
    if (!rt) return;
    // A depth clear after a view (a sky box drawn first) starts over: the occlusion is
    // for the view drawn after it.
    if ((flags & 2) && ds && ao_state == 1) ao_state = 0;
    const uint32_t *vp = s->viewport;
    int full = count == 0 && vp[0] == 0 && vp[1] == 0 && vp[2] >= rt->width && vp[3] >= rt->height &&
               (!s->rs[174] || (s->scissor[0] == 0 && s->scissor[1] == 0 && s->scissor[2] >= rt->width &&
                                s->scissor[3] >= rt->height));
    MTLClearColor cc = MTLClearColorMake((color >> 16 & 255) / 255.0, (color >> 8 & 255) / 255.0,
                                         (color & 255) / 255.0, (color >> 24) / 255.0);
    if (full) {
        end_pass();
        if (flags & 1) clear_color_target = rt, clear_color = cc;  // D3DCLEAR_TARGET
        if ((flags & 6) && ds) {                                    // D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL
            if (clear_depth_target != ds) clear_has_stencil = 0;
            clear_depth_target = ds;
            if (flags & 2) clear_depth = z;
            if (flags & 4) clear_stencil = stencil, clear_has_stencil = 1;
        }
        return;
    }
    // Partial clear: a quad per rectangle, inside the viewport.
    id<MTLRenderCommandEncoder> e = pass(s);
    id<MTLTexture> t = target_texture(rt);
    MTLPixelFormat dfmt = ds ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    uint32_t mask = (flags & 1 ? 1u : 0u) | (flags & 2 && ds ? 2u : 0u) | (flags & 4 && ds ? 4u : 0u);
    if (!mask) return;
    [e setRenderPipelineState:clear_pipeline(t.pixelFormat, dfmt, mask, enc_samples)];
    static NSMutableDictionary *clear_depth_states;
    if (!clear_depth_states) clear_depth_states = [NSMutableDictionary new];
    NSNumber *dk = @(mask);
    id<MTLDepthStencilState> dss = clear_depth_states[dk];
    if (!dss) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = (mask & 2) != 0;
        if (mask & 4) {
            MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
            sd.depthStencilPassOperation = MTLStencilOperationReplace;
            dd.frontFaceStencil = dd.backFaceStencil = sd;
        }
        dss = [mtl newDepthStencilStateWithDescriptor:dd];
        clear_depth_states[dk] = dss;
    }
    [e setDepthStencilState:dss];
    [e setStencilReferenceValue:stencil & 0xFF];
    [e setCullMode:MTLCullModeNone];
    [e setTriangleFillMode:MTLTriangleFillModeFill];
    [e setDepthBias:0 slopeScale:0 clamp:0];
    [e setViewport:(MTLViewport){0, 0, t.width, t.height, 0, 1}];
    float params[5] = {(float)cc.red, (float)cc.green, (float)cc.blue, (float)cc.alpha, z};
    [e setFragmentBytes:params length:sizeof params atIndex:0];
    [e setVertexBytes:params length:sizeof params atIndex:0];
    int32_t vx0 = (int32_t)vp[0], vy0 = (int32_t)vp[1], vx1 = vx0 + (int32_t)vp[2], vy1 = vy0 + (int32_t)vp[3];
    uint32_t n = count ? count : 1;
    for (uint32_t i = 0; i < n; i++) {
        int32_t x0 = vx0, y0 = vy0, x1 = vx1, y1 = vy1;
        if (count) {
            const int32_t *r = bl_g2h(rects + 16 * i);
            if (r[0] > x0) x0 = r[0];
            if (r[1] > y0) y0 = r[1];
            if (r[2] < x1) x1 = r[2];
            if (r[3] < y1) y1 = r[3];
        }
        if (s->rs[174]) {
            const int32_t *r = (const int32_t *)s->scissor;
            if (r[0] > x0) x0 = r[0];
            if (r[1] > y0) y0 = r[1];
            if (r[2] < x1) x1 = r[2];
            if (r[3] < y1) y1 = r[3];
        }
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > (int32_t)t.width) x1 = (int32_t)t.width;
        if (y1 > (int32_t)t.height) y1 = (int32_t)t.height;
        if (x1 <= x0 || y1 <= y0) continue;
        [e setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
}

static id<MTLRenderPipelineState> clear_pipeline(MTLPixelFormat color, MTLPixelFormat depth, uint32_t mask,
                                                 int samples)
{
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSString *src = @"#include <metal_stdlib>\n"
                         "using namespace metal;\n"
                         "struct V { float4 pos [[position]]; };\n"
                         "vertex V clear_vs(uint id [[vertex_id]], constant float *p [[buffer(0)]]) {\n"
                         "    V v; float2 uv = float2((id << 1) & 2, id & 2);\n"
                         "    v.pos = float4(uv * 2.0 - 1.0, p[4], 1.0); return v; }\n"
                         "struct F { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
                         "fragment F clear_fs(V in [[stage_in]], constant float *p [[buffer(0)]]) {\n"
                         "    F f; f.c = float4(p[0], p[1], p[2], p[3]); f.d = p[4]; return f; }\n";
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:src options:nil error:&error];
        if (!lib) bl_fatal("clear shader: %s", error.localizedDescription.UTF8String);
    }
    NSString *key = [NSString stringWithFormat:@"%lu/%lu/%u/%d", (unsigned long)color, (unsigned long)depth, mask,
                                               samples];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"clear_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"clear_fs"];
    d.colorAttachments[0].pixelFormat = color;
    d.colorAttachments[0].writeMask = mask & 1 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    d.rasterSampleCount = (NSUInteger)samples;
    d.depthAttachmentPixelFormat = depth;
    d.stencilAttachmentPixelFormat = depth;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("clear pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

// Scaled StretchRect: one triangle covering the destination rectangle (set as the
// viewport) samples the source rectangle. p = {u0, v0, u1, v1} in normalized coordinates.
static id<MTLRenderPipelineState> stretch_pipeline(MTLPixelFormat color, int samples)
{
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSString *src = @"#include <metal_stdlib>\n"
                         "using namespace metal;\n"
                         "struct V { float4 pos [[position]]; float2 uv; };\n"
                         "vertex V stretch_vs(uint id [[vertex_id]], constant float4 &p [[buffer(0)]]) {\n"
                         "    V v; float2 t = float2((id << 1) & 2, id & 2);\n"
                         "    v.pos = float4(t.x * 2.0 - 1.0, 1.0 - t.y * 2.0, 0.0, 1.0);\n"
                         "    v.uv = mix(p.xy, p.zw, t); return v; }\n"
                         "fragment float4 stretch_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
                         "                           sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n";
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:src options:nil error:&error];
        if (!lib) bl_fatal("stretch shader: %s", error.localizedDescription.UTF8String);
    }
    NSNumber *key = @(color * 64 + (NSUInteger)samples);
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"stretch_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"stretch_fs"];
    d.colorAttachments[0].pixelFormat = color;
    d.rasterSampleCount = (NSUInteger)samples;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("stretch pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

static void stretch_draw(id<MTLTexture> a, const uint32_t sr[4], id<MTLTexture> b, const uint32_t dr[4], int linear)
{
    if (a == b) {  // a pass cannot sample its own target: copy the source first
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:a.pixelFormat
                                                                                     width:a.width height:a.height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> copy = [mtl newTextureWithDescriptor:td];
        id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
        [blit copyFromTexture:a toTexture:copy];
        [blit endEncoding];
        a = copy;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = b;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:stretch_pipeline(b.pixelFormat, 1)];
    [e setViewport:(MTLViewport){dr[0], dr[1], dr[2] - dr[0], dr[3] - dr[1], 0, 1}];
    float p[4] = {(float)sr[0] / a.width, (float)sr[1] / a.height, (float)sr[2] / a.width, (float)sr[3] / a.height};
    [e setVertexBytes:p length:sizeof p atIndex:0];
    [e setFragmentTexture:a atIndex:0];
    static id<MTLSamplerState> samp[2];
    if (!samp[linear]) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        samp[linear] = [mtl newSamplerStateWithDescriptor:sd];
    }
    [e setFragmentSamplerState:samp[linear] atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// --- ambient occlusion -------------------------------------------------------------------
//
// Ground-truth ambient occlusion (Jimenez et al. 2016, as in Intel's XeGTAO) from the
// back buffer's depth, once the world is drawn and before the view model and HUD
// (ao_before_draw). The depth is turned back into view-space positions with the world
// view's projection, taken from its draws (ao_note_projection). Four passes, the first
// three at half resolution: view depth from the depth buffer; the occlusion, 3 slices of
// 8 steps a side whose angles and offsets follow a 4x4 pattern; a depth-aware 4x4 filter
// that averages the pattern out; and, at full resolution, a depth-aware upsample that
// multiplies the image by the result. BL_AO=1 turns it on, BL_AO=show shows the
// occlusion alone; BL_AO_RADIUS (world units, default 32) and BL_AO_STRENGTH (default 0.6)
// tune it.

struct ao_params {
    float full[2], half[2];  // back buffer and half-resolution sizes
    float alpha, beta;       // depth d = alpha + beta / w
    float p00, p11;          // projection scales in x and y
    float radius, inv_radius2;
    float max_px, strength;  // max_px: largest radius in half-resolution pixels
};

static NSString *const ao_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct AOP { float2 full, hsize; float alpha, beta, p00, p11, radius, inv_radius2, max_px, strength; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V ao_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     "static float rd(depth2d_ms<float> t, uint2 p) { return t.read(p, 0); }\n"
     "static float rd(depth2d<float> t, uint2 p) { return t.read(p); }\n"
     // View depth, 0 for the sky (cleared depth) and anything not drawn.
     "static float lin(constant AOP &a, float d) { return d >= 0.99999 || d <= 0.0 ? 0.0 : a.beta / (d - a.alpha); }\n"
     "fragment float ao_depth_ms(V in [[stage_in]], depth2d_ms<float> dt [[texture(0)]], constant AOP &a [[buffer(0)]]) {\n"
     "    uint2 p = min(uint2(in.pos.xy) * 2, uint2(a.full) - 1); return lin(a, rd(dt, p)); }\n"
     "fragment float ao_depth(V in [[stage_in]], depth2d<float> dt [[texture(0)]], constant AOP &a [[buffer(0)]]) {\n"
     "    uint2 p = min(uint2(in.pos.xy) * 2, uint2(a.full) - 1); return lin(a, rd(dt, p)); }\n"
     "static float3 vpos(constant AOP &a, texture2d<float> zt, int2 p) {\n"
     "    p = clamp(p, int2(0), int2(a.hsize) - 1);\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    if (w <= 0.0) w = 1e6;\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.hsize.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.hsize.y);\n"
     "    return float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w); }\n"
     "constant float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};\n"
     "fragment float ao_main(V in [[stage_in]], texture2d<float> zt [[texture(0)]], constant AOP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    if (zt.read(uint2(p)).x <= 0.0) return 1.0;\n"
     "    float3 P = vpos(a, zt, p);\n"
     "    float3 l = vpos(a, zt, p - int2(1, 0)), r = vpos(a, zt, p + int2(1, 0));\n"
     "    float3 u = vpos(a, zt, p - int2(0, 1)), b = vpos(a, zt, p + int2(0, 1));\n"
     "    float3 dx = abs(r.z - P.z) < abs(P.z - l.z) ? r - P : P - l;\n"
     "    float3 dy = abs(b.z - P.z) < abs(P.z - u.z) ? b - P : P - u;\n"
     "    float3 V = normalize(-P);\n"
     "    float3 N = normalize(cross(dx, dy));\n"
     "    if (dot(N, V) < 0.0) N = -N;\n"
     "    float rpx = min(a.radius * a.p00 * 0.5 * a.hsize.x / P.z, a.max_px);\n"
     "    if (rpx < 1.0) return 1.0;\n"
     "    float n0 = (bayer[(p.x & 3) + (p.y & 3) * 4] + 0.5) / 16.0;\n"
     "    float n1 = (bayer[((p.x + 2) & 3) + ((p.y + 1) & 3) * 4] + 0.5) / 16.0;\n"
     "    const int SLICES = 2, STEPS = 4;\n"
     "    float vis = 0.0;\n"
     "    for (int s = 0; s < SLICES; s++) {\n"
     "        float phi = (float(s) + n0) * (M_PI_F / float(SLICES));\n"
     "        float2 omega = float2(cos(phi), -sin(phi));\n"
     "        float3 dir = float3(cos(phi), sin(phi), 0.0);\n"
     "        float3 ortho = dir - dot(dir, V) * V;\n"
     "        float3 axis = normalize(cross(dir, V));\n"
     "        float3 pn = N - axis * dot(N, axis);\n"
     "        float plen = length(pn);\n"
     "        float cosn = saturate(dot(pn, V) / max(plen, 1e-4));\n"
     "        float n = sign(dot(ortho, pn)) * acos(cosn);\n"
     "        float low0 = cos(n + M_PI_2_F), low1 = cos(n - M_PI_2_F);\n"
     "        float h0c = low0, h1c = low1;\n"
     "        for (int k = 0; k < STEPS; k++) {\n"
     "            float t = (float(k) + n1) / float(STEPS);\n"
     "            float2 off = omega * max(t * t * rpx, float(k) * 0.5 + 1.0);\n"
     "            int2 q0 = int2(float2(p) + 0.5 + off), q1 = int2(float2(p) + 0.5 - off);\n"
     "            float3 S0 = vpos(a, zt, q0) - P, S1 = vpos(a, zt, q1) - P;\n"
     "            float l0 = dot(S0, S0), l1 = dot(S1, S1);\n"
     "            float c0 = dot(S0, V) * rsqrt(max(l0, 1e-6)), c1 = dot(S1, V) * rsqrt(max(l1, 1e-6));\n"
     "            float w0 = saturate((1.0 - l0 * a.inv_radius2) * 2.5), w1 = saturate((1.0 - l1 * a.inv_radius2) * 2.5);\n"
     "            h0c = max(h0c, mix(low0, c0, w0));\n"
     "            h1c = max(h1c, mix(low1, c1, w1));\n"
     "        }\n"
     "        float h1 = n + clamp(acos(h0c) - n, -M_PI_2_F, M_PI_2_F);\n"
     "        float h0 = n + clamp(-acos(h1c) - n, -M_PI_2_F, M_PI_2_F);\n"
     "        float sn = sin(n);\n"
     "        vis += plen * 0.25 * ((cosn + 2.0 * h0 * sn - cos(2.0 * h0 - n)) + (cosn + 2.0 * h1 * sn - cos(2.0 * h1 - n)));\n"
     "    }\n"
     "    return saturate(vis / float(SLICES)); }\n"
     // Depth-aware 4x4 average: covers one tile of the pattern. Output: occlusion, depth.
     "fragment float2 ao_blur(V in [[stage_in]], texture2d<float> ao [[texture(0)]], texture2d<float> zt [[texture(1)]],\n"
     "                        constant AOP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), hs = int2(a.hsize) - 1;\n"
     "    float z = zt.read(uint2(p)).x;\n"
     "    if (z <= 0.0) return float2(1.0, 0.0);\n"
     "    float sum = 0.0, wsum = 0.0;\n"
     "    for (int j = -2; j < 2; j++)\n"
     "        for (int i = -2; i < 2; i++) {\n"
     "            uint2 q = uint2(clamp(p + int2(i, j), int2(0), hs));\n"
     "            float w = exp(-abs(zt.read(q).x - z) * 20.0 / z);\n"
     "            sum += ao.read(q).x * w, wsum += w;\n"
     "        }\n"
     "    return float2(sum / wsum, z); }\n"
     // Full resolution, in the game's next pass on the back buffer: the filtered
     // occlusion, upsampled.
     "fragment float4 ao_apply(V in [[stage_in]], texture2d<float> ao [[texture(0)]], constant AOP &a [[buffer(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    float o = mix(1.0, ao.sample(s, in.pos.xy / a.full).x, a.strength);\n"
     "    return float4(o, o, o, 1.0); }\n";

// kind 0: view depth (from the depth buffer, multisampled or not); 1: occlusion;
// 2: filter; 3: multiply into the image; 4: show the occlusion alone. Kinds 3 and 4 draw
// in the game's pass, with its depth attachment (`depth`).
static id<MTLRenderPipelineState> ao_pipeline(int kind, int ms_depth, MTLPixelFormat color, int samples,
                                              MTLPixelFormat depth)
{
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:ao_source options:nil error:&error];
        if (!lib) bl_fatal("ambient occlusion shader: %s", error.localizedDescription.UTF8String);
    }
    NSString *key = [NSString stringWithFormat:@"%d/%d/%lu/%d/%lu", kind, ms_depth, (unsigned long)color, samples,
                                               (unsigned long)depth];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    static NSString *const names[] = {@"ao_depth", @"ao_main", @"ao_blur", @"ao_apply", @"ao_apply"};
    NSString *fs = names[kind];
    if (ms_depth && kind == 0) fs = [fs stringByAppendingString:@"_ms"];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"ao_vs"];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = color;
    d.rasterSampleCount = (NSUInteger)samples;
    d.depthAttachmentPixelFormat = depth;
    d.stencilAttachmentPixelFormat = depth;
    if (kind == 3) {  // image *= occlusion; alpha kept
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorZero;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorSourceColor;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorZero;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    }
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("ambient occlusion pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

// Called for perspective draws of the world view to the back buffer: the first one after
// the depth buffer was last cleared gives the projection (a sky box drawn before the
// clear does not count). Draws of models carry the model transform in c8-c11 as well,
// which leaves the depth terms alone and only changes the x/y scales by its scale.
static void ao_note_projection(const float r8[4], const float r9[4], const float r10[4], const float r11[4], float clip_y)
{
    if (ao_state) return;
    float ww = r11[0] * r11[0] + r11[1] * r11[1] + r11[2] * r11[2];
    if (ww <= 0) return;
    // z = alpha w + beta, with w the view depth: the z row is alpha times the w row plus
    // a constant. Dividing the x and y rows by the w row's length cancels a model scale.
    float alpha = (r10[0] * r11[0] + r10[1] * r11[1] + r10[2] * r11[2]) / ww;
    float lw = sqrtf(ww);
    ao_proj.alpha = alpha;
    ao_proj.beta = r10[3] - alpha * r11[3];
    ao_proj.p00 = sqrtf(r8[0] * r8[0] + r8[1] * r8[1] + r8[2] * r8[2]) / lw;
    ao_proj.p11 = sqrtf(r9[0] * r9[0] + r9[1] * r9[1] + r9[2] * r9[2]) / lw * clip_y;
    if (ao_proj.beta != 0 && ao_proj.p00 > 0 && ao_proj.p11 > 0) ao_state = 1;
}

// A half-resolution texture for ao_run, kept between frames.
static id<MTLTexture> ao_texture(int i, MTLPixelFormat pf, NSUInteger w, NSUInteger h)
{
    static id<MTLTexture> t[3];
    if (!t[i] || t[i].width != w || t[i].height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t[i] = [mtl newTextureWithDescriptor:td];
    }
    return t[i];
}

// One full-screen pass of ao_pipeline `kind` into `target`.
static void ao_pass(int kind, int ms_depth, id<MTLTexture> target, id<MTLTexture> t0, id<MTLTexture> t1,
                    const struct ao_params *a)
{
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ao_pipeline(kind, ms_depth, target.pixelFormat, 1, MTLPixelFormatInvalid)];
    [e setFragmentTexture:t0 atIndex:0];
    [e setFragmentTexture:t1 atIndex:1];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// ao_result's parameters: the occlusion of the frame's world view is multiplied into
// the back buffer at the start of the game's next pass on it (ao_apply).
static struct ao_params ao_result_params;

static void ao_run(struct d3d_state *s)
{
    ao_state = 2;
    LOG_ONCE("[metal] ambient occlusion: depth %g + %g / w, scales %g %g\n", ao_proj.alpha, ao_proj.beta, ao_proj.p00,
             ao_proj.p11);
    struct obj *bb = s->back_buffer, *ds = s->depth_stencil;
    if (!bb || !ds || clear_color_target == bb || clear_depth_target == ds) return;
    int samples = multisampled(bb) ? msaa : 1;
    if (multisampled(ds) != (samples > 1)) return;
    end_pass();
    id<MTLTexture> color = target_texture(bb);
    id<MTLTexture> depth = samples > 1 ? ms_texture(ds) : target_texture(ds);
    if (depth.width != color.width || depth.height != color.height) return;
    NSUInteger hw = (color.width + 1) / 2, hh = (color.height + 1) / 2;
    id<MTLTexture> z = ao_texture(0, MTLPixelFormatR32Float, hw, hh);
    id<MTLTexture> raw = ao_texture(1, MTLPixelFormatR16Float, hw, hh);
    id<MTLTexture> soft = ao_texture(2, MTLPixelFormatRG32Float, hw, hh);
    struct ao_params a = {{(float)color.width, (float)color.height}, {(float)hw, (float)hh}, ao_proj.alpha,
                          ao_proj.beta, ao_proj.p00, ao_proj.p11, env_ao_radius,
                          1 / (env_ao_radius * env_ao_radius), 0.2f * (float)hh, env_ao_strength};
    ao_pass(0, samples > 1, z, depth, nil, &a);
    ao_pass(1, 0, raw, z, nil, &a);
    ao_pass(2, 0, soft, raw, z, &a);
    ao_result = soft, ao_result_params = a;
}

// Called by pass() for a new pass on the back buffer.
static void ao_apply(id<MTLRenderCommandEncoder> e, id<MTLTexture> color, int samples, int has_depth)
{
    MTLPixelFormat df = has_depth ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    [e setRenderPipelineState:ao_pipeline(env_ao_show ? 4 : 3, 0, color.pixelFormat, samples, df)];
    static id<MTLDepthStencilState> none;
    if (!none) none = [mtl newDepthStencilStateWithDescriptor:[MTLDepthStencilDescriptor new]];
    [e setDepthStencilState:none];
    [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){0, 0, color.width, color.height, 0, 1}];
    [e setScissorRect:(MTLScissorRect){0, 0, color.width, color.height}];
    [e setFragmentTexture:ao_result atIndex:0];
    [e setFragmentBytes:&ao_result_params length:sizeof ao_result_params atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    ao_result = nil;
}

// Before a draw to the back buffer: once the world view is drawn, the first draw of the
// view model (drawn with a narrowed depth range) or of the 2D HUD runs the occlusion.
static void ao_before_draw(struct d3d_state *s, const struct element *el, int nel)
{
    if (ao_state != 1 || s->render_target[0] != s->back_buffer) return;
    int end = u2f(s->viewport[5]) < 0.99f;
    if (!end) {
        int perspective;
        if (s->vs) {
            const uint32_t *w = s->vs_f[11];
            perspective = w[0] || w[1] || w[2] || u2f(w[3]) != 1;
        } else {
            int pretransformed = 0;
            for (int i = 0; i < nel; i++) pretransformed |= el[i].usage == 9;  // POSITIONT
            const float *p = (const float *)s->transform[3];
            perspective = !pretransformed && (p[3] != 0 || p[7] != 0 || p[11] != 0 || p[15] != 1);
        }
        end = !perspective;
    }
    if (end) ao_run(s);
}

// --- draws -------------------------------------------------------------------------

static uint32_t index_count(uint32_t type, uint32_t prims)
{
    switch (type) {
    case 1: return prims;          // POINTLIST
    case 2: return 2 * prims;      // LINELIST
    case 3: return prims + 1;      // LINESTRIP
    case 4: return 3 * prims;      // TRIANGLELIST
    case 5: return prims + 2;      // TRIANGLESTRIP
    case 6: return 3 * prims;      // TRIANGLEFAN, drawn as a list
    default: return 0;
    }
}

static MTLPrimitiveType primitive(uint32_t type)
{
    switch (type) {
    case 1: return MTLPrimitiveTypePoint;
    case 2: return MTLPrimitiveTypeLine;
    case 3: return MTLPrimitiveTypeLineStrip;
    case 5: return MTLPrimitiveTypeTriangleStrip;
    default: return MTLPrimitiveTypeTriangle;
    }
}

// Where a stream's vertices come from for this draw.
struct stream_src { id<MTLBuffer> buf; NSUInteger offset; uint32_t stride; };

// A stream's data for vertices [first, first + count): a static buffer in place, or a
// copy of the range from a dynamic one. The offset is that of vertex 0 for static
// buffers and of vertex `first` for copies (*rebased set).
static struct stream_src stream_data(struct obj *vb, uint32_t offset, uint32_t stride, uint32_t first, uint32_t count,
                                     int *rebased)
{
    struct stream_src r = {nil, 0, stride};
    if (!vb) return r;
    // A static buffer rewritten after draws used it must not change under those draws:
    // they may still be encoded in this frame or running on the GPU (the window keeps
    // up to FRAMES_IN_FLIGHT frames queued). Each rewrite gets a new MTLBuffer, and a
    // buffer rewritten often is copied per draw from then on, like D3DUSAGE_DYNAMIC ones.
    if (vb->dirty && vb->gpu && !(vb->usage & 0x200) && vb->rewrites < 8) {
        CFRelease(vb->gpu);
        vb->gpu = NULL;
        vb->rewrites++;
    }
    int dynamic = (vb->usage & 0x200) != 0 || vb->rewrites >= 8;  // D3DUSAGE_DYNAMIC
    if (!dynamic) {
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)vb->gpu;
        if (!b) {
            b = [mtl newBufferWithBytes:bl_g2h(vb->mem) length:vb->size ? vb->size : 4
                                options:MTLResourceStorageModeShared];
            vb->gpu = (__bridge_retained void *)b;
            vb->dirty = 0;
        }
        r.buf = b, r.offset = offset;
        *rebased = 0;
        return r;
    }
    uint64_t start = (uint64_t)offset + (uint64_t)first * stride, len = (uint64_t)count * stride;
    if (start > vb->size) start = vb->size, len = 0;
    if (start + len > vb->size) len = vb->size - start;
    r.buf = upload((const uint8_t *)bl_g2h(vb->mem) + start, len ? len : 4, &r.offset);
    *rebased = 1;
    return r;
}

// Whether n is in a comma-separated list of numbers.
static int listed(const char *list, unsigned long n)
{
    for (const char *p = list; p; p = strchr(p, ','), p = p ? p + 1 : NULL)
        if (strtoul(p, NULL, 10) == n) return 1;
    return 0;
}

static void log_draw(struct d3d_state *s, const char *what, uint32_t type, uint32_t count)
{
    if (!draw_stats || (long)frames < draw_stats_frame || (long)frames >= draw_stats_frame + draw_stats_count) return;
    struct obj *t = s->texture[0];
    fprintf(stderr, "[%s] #%lu type %u prims %u vs %d ps %d fvf 0x%x rt %ux%u vp %u,%u %ux%u z %g-%g tex0 %ux%u fmt %u blend %u z %u/%u\n",
            what, draws, type, count, s->vs != NULL, s->ps != NULL, s->fvf,
            s->render_target[0] ? s->render_target[0]->width : 0, s->render_target[0] ? s->render_target[0]->height : 0,
            s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3], u2f(s->viewport[4]), u2f(s->viewport[5]),
            t ? t->width : 0, t ? t->height : 0, t ? t->format : 0, s->rs[27], s->rs[7], s->rs[14]);
}

// Everything a draw needs except vertex and index data; returns 0 if it cannot draw.
static int setup_draw(struct d3d_state *s, id<MTLRenderCommandEncoder> e, uint32_t type, struct element *el, int nel,
                      struct pipe_key *k)
{
    BLShader *vs = s->vs ? shader_of(s->vs) : ff_vertex_shader(el, nel);
    BLShader *ps = s->ps ? shader_of(s->ps) : ff_pixel_shader(s);
    memset(k, 0, sizeof *k);
    k->vs = vs->serial, k->ps = ps->serial;
    // Vertex inputs: match the shader's dcl_<usage><index> against the declaration.
    for (int i = 0; i < 16; i++) {
        if (!(vs->info.input_mask & (1u << i))) continue;
        int found = -1;
        for (int j = 0; j < nel; j++)
            if (el[j].usage == vs->info.input_usage[i] && el[j].index == vs->info.input_index[i]) found = j;
        if (found < 0) {
            k->attr[i].format = (uint8_t)MTLVertexFormatFloat4;
            k->attr[i].buffer = 16;
            k->constant[16] = 1;
            k->vsv.input_kind[i] = D3D_IN_FLOAT;
            continue;
        }
        uint8_t kind;
        k->attr[i].format = (uint8_t)decl_format(el[found].type, &kind);
        k->attr[i].offset = el[found].offset;
        k->attr[i].buffer = (uint8_t)el[found].stream;
        k->vsv.input_kind[i] = kind;
    }
    // Pixel shader samplers: texture types (ps_1_x does not declare them) and projection.
    for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++) {
        if (!(ps->info.sampler_mask & (1u << i))) continue;
        k->psv.tex_kind[i] = (uint8_t)(ps->info.sampler_type[i] ? ps->info.sampler_type[i] : tex_kind_of(s->texture[i]));
        if (ps->info.major == 1 && i < 8 && (s->tss[i][24] & 256)) {  // TEXTURETRANSFORMFLAGS: PROJECTED
            uint32_t n = s->tss[i][24] & 255;
            k->psv.projected[i] = (uint8_t)(n == 3 ? 3 : 4);
        }
    }
    struct obj *rt = s->render_target[0];
    id<MTLTexture> rtt = target_texture(rt);
    k->color_format = (uint16_t)rtt.pixelFormat;
    k->depth_format = s->depth_stencil ? (uint16_t)MTLPixelFormatDepth32Float_Stencil8 : 0;
    const uint32_t *rs = s->rs;
    if (rs[27]) {  // ALPHABLENDENABLE
        uint32_t src = rs[19], dst = rs[20];
        if (src == 12) src = 5, dst = 6;   // BOTHSRCALPHA
        if (src == 13) src = 6, dst = 5;   // BOTHINVSRCALPHA
        if (src == 1 && dst == 4 && env_shadow_show) src = 2, dst = 1;  // debugging: draw shadows opaque
        k->blend[0] = 1, k->blend[1] = src, k->blend[2] = dst, k->blend[3] = rs[171];
        if (rs[206]) {  // SEPARATEALPHABLENDENABLE
            k->blend[4] = rs[207], k->blend[5] = rs[208], k->blend[6] = rs[209];
        } else {
            k->blend[4] = src, k->blend[5] = dst, k->blend[6] = rs[171];
        }
    }
    k->write_mask = rs[168] & 15;
    k->point = type == 1;
    k->samples = (uint8_t)enc_samples;
    // Alpha-tested cut-outs (fences, foliage, hair) get soft edges from the samples.
    k->alpha_to_coverage = enc_samples > 1 && rs[15] && !rs[27];  // ALPHATESTENABLE, no blending
    for (int b = 0; b < 16; b++) k->stride[b] = (uint16_t)s->stream_stride[b];
    k->stride[16] = 16;

    id<MTLFunction> vf = shader_function(vs, &k->vsv), pf = shader_function(ps, &k->psv);
    id<MTLRenderPipelineState> pso = vf && pf ? pipeline(k, vf, pf) : nil;
    if (!pso) return 0;
    [e setRenderPipelineState:pso];
    [e setDepthStencilState:depth_state(s, s->depth_stencil != NULL)];
    [e setStencilReferenceValue:rs[57] & 0xFF];
    uint32_t bf = rs[193];
    [e setBlendColorRed:(bf >> 16 & 255) / 255.0f green:(bf >> 8 & 255) / 255.0f blue:(bf & 255) / 255.0f
                  alpha:(bf >> 24) / 255.0f];
    [e setFrontFacingWinding:MTLWindingClockwise];
    [e setCullMode:rs[22] == 2 ? MTLCullModeFront : rs[22] == 3 ? MTLCullModeBack : MTLCullModeNone];
    [e setTriangleFillMode:rs[8] == 2 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    [e setDepthBias:u2f(rs[195]) * 16777215.0f slopeScale:u2f(rs[175]) clamp:0];

    // Constants: the game's, with the shader's own definitions on top.
    float vc[256][4];
    memcpy(vc, s->vs_f, sizeof vc);
    for (int i = 0; i < vs->info.ndefs; i++)
        if (vs->info.defs[i].reg < 256) memcpy(vc[vs->info.defs[i].reg], vs->info.defs[i].value, 16);
    if (vs->ff_vertex) {
        float m[16], t[16];
        if (vs->ffv.positiont) {
            vc[0][0] = (float)s->viewport[0], vc[0][1] = (float)s->viewport[1];
            vc[0][2] = s->viewport[2] ? 1.0f / s->viewport[2] : 0, vc[0][3] = s->viewport[3] ? 1.0f / s->viewport[3] : 0;
        } else {
            mat_mul((const float *)s->transform[24], (const float *)s->transform[2], t);  // WORLD * VIEW
            mat_mul(t, (const float *)s->transform[3], m);                              // * PROJECTION
            for (int j = 0; j < 4; j++)
                for (int i = 0; i < 4; i++) vc[j][i] = m[4 * i + j];  // columns
        }
    }
    [e setVertexBytes:vc length:sizeof vc atIndex:20];
    struct d3d_vs_params vp;
    memset(&vp, 0, sizeof vp);
    memcpy(vp.i, s->vs_i, sizeof vp.i);
    memcpy(vp.b, s->vs_b, sizeof vp.b);
    for (int i = 0; i < vs->info.ndefis; i++)
        if (vs->info.defis[i].reg < 16) memcpy(vp.i[vs->info.defis[i].reg], vs->info.defis[i].value, 16);
    for (int i = 0; i < vs->info.ndefbs; i++)
        if (vs->info.defbs[i].reg < 16) vp.b[vs->info.defbs[i].reg] = vs->info.defbs[i].value;
    vp.inv_viewport[0] = s->viewport[2] ? 1.0f / s->viewport[2] : 0;
    vp.inv_viewport[1] = s->viewport[3] ? 1.0f / s->viewport[3] : 0;
    // The game projects 3D views for a 4:3 screen whatever the resolution, so wider
    // modes come out stretched sideways. Perspective draws whose projection aspect is
    // narrower than the viewport are scaled up vertically to undo it (the view keeps
    // its width and loses some height), so the game's culling, made for that width,
    // still matches. The projection aspect is the ratio of the y and x scales: rows
    // c9 and c8 of the view-projection (Source's cViewProj), or PROJECTION _22/_11 for
    // fixed-function draws. 2D draws (last row 0 0 0 1) are left alone.
    // BL_WIDESCREEN=stretch keeps the game's own picture.
    vp.clip_y = 1;
    float aspect = s->viewport[3] ? (float)s->viewport[2] / (float)s->viewport[3] : 0;
    const float *w_row = vs->ff_vertex ? vc[3] : vc[11];
    int perspective = !(vs->ff_vertex && vs->ffv.positiont) &&
                      (w_row[0] != 0 || w_row[1] != 0 || w_row[2] != 0 || w_row[3] != 1);
    int to_back_buffer = enc_color && enc_color == s->back_buffer;
    // A world view has its camera away from the origin; the main menu's smoke is drawn
    // with a camera at the origin (the w row has no translation), like a sky box.
    if (perspective && to_back_buffer && fabsf(w_row[3]) > 1e-4f) frame_has_3d++;
    // Screens with no world view (the main menu, loading screens) are the game's 4:3
    // layouts stretched across a wider window. Their draws to the back buffer go to a
    // centred 4:3 area instead, with black bars (menu_bars) and the mouse mapped to
    // match (bl_cocoa_set_squeeze); the projection then needs no correction. Which kind
    // of screen it is comes from the frame before. BL_WIDESCREEN=stretch keeps the
    // stretch.
    float squeeze = 1;
    float target_aspect = rtt.height ? (float)rtt.width / (float)rtt.height : 0;
    if (env_widescreen && menu_frame && to_back_buffer && target_aspect > 4.0f / 3.0f + 0.01f)
        squeeze = (4.0f / 3.0f) / target_aspect, frame_squeeze = squeeze;
    if (env_widescreen && aspect > 4.0f / 3.0f + 0.01f && perspective && squeeze == 1) {
        float proj = 0;
        if (vs->ff_vertex) {
            const float *p = (const float *)s->transform[3];
            if (p[0] != 0) proj = p[5] / p[0];
        } else {
            float lx = sqrtf(vc[8][0] * vc[8][0] + vc[8][1] * vc[8][1] + vc[8][2] * vc[8][2]);
            float ly = sqrtf(vc[9][0] * vc[9][0] + vc[9][1] * vc[9][1] + vc[9][2] * vc[9][2]);
            if (lx != 0) proj = ly / lx;
        }
        if (proj > 0 && aspect > proj * 1.01f) vp.clip_y = aspect / proj;
    }
    if (env_ao && perspective && to_back_buffer && fabsf(w_row[3]) > 1e-4f && s->viewport[2] == rtt.width &&
        s->viewport[3] == rtt.height && u2f(s->viewport[4]) == 0 && u2f(s->viewport[5]) >= 0.99f) {
        const float(*r)[4] = vs->ff_vertex ? vc : vc + 8;
        ao_note_projection(r[0], r[1], r[2], r[3], vp.clip_y);
    }
    set_viewport(s, e, (uint32_t)rtt.width, (uint32_t)rtt.height, squeeze);
    [e setVertexBytes:&vp length:sizeof vp atIndex:21];

    float pc[224][4];
    memcpy(pc, s->ps_f, sizeof pc);
    for (int i = 0; i < ps->info.ndefs; i++)
        if (ps->info.defs[i].reg < 224) memcpy(pc[ps->info.defs[i].reg], ps->info.defs[i].value, 16);
    if (!ps->code) {  // fixed-function stages read TEXTUREFACTOR from c0
        uint32_t f = rs[60];
        pc[0][0] = (f >> 16 & 255) / 255.0f, pc[0][1] = (f >> 8 & 255) / 255.0f;
        pc[0][2] = (f & 255) / 255.0f, pc[0][3] = (f >> 24) / 255.0f;
    }
    [e setFragmentBytes:pc length:sizeof pc atIndex:0];
    struct d3d_ps_params pp;
    memset(&pp, 0, sizeof pp);
    memcpy(pp.i, s->ps_i, sizeof pp.i);
    memcpy(pp.b, s->ps_b, sizeof pp.b);
    for (int i = 0; i < ps->info.ndefis; i++)
        if (ps->info.defis[i].reg < 16) memcpy(pp.i[ps->info.defis[i].reg], ps->info.defis[i].value, 16);
    for (int i = 0; i < ps->info.ndefbs; i++)
        if (ps->info.defbs[i].reg < 16) pp.b[ps->info.defbs[i].reg] = ps->info.defbs[i].value;
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 4; j++) pp.bumpenv[i][j] = u2f(s->tss[i][7 + j]);  // BUMPENVMAT00..11
        pp.bumpenv_l[i][0] = u2f(s->tss[i][22]), pp.bumpenv_l[i][1] = u2f(s->tss[i][23]);
    }
    pp.alpha_func = rs[15] ? rs[25] : 8;  // ALPHATESTENABLE, ALPHAFUNC
    pp.alpha_ref = (rs[24] & 255) / 255.0f;
    if (rs[28]) {  // FOGENABLE
        uint32_t c = rs[34];
        pp.fog_color[0] = (c >> 16 & 255) / 255.0f, pp.fog_color[1] = (c >> 8 & 255) / 255.0f;
        pp.fog_color[2] = (c & 255) / 255.0f, pp.fog_color[3] = 1;
        uint32_t table = rs[35];  // FOGTABLEMODE: 0 none, 1 exp, 2 exp2, 3 linear
        pp.fog_mode = table == 3 ? 2 : table == 1 ? 3 : table == 2 ? 4 : 1;
        pp.fog_start = u2f(rs[36]), pp.fog_end = u2f(rs[37]), pp.fog_density = u2f(rs[38]);
    }
    [e setFragmentBytes:&pp length:sizeof pp atIndex:1];

    for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++) {
        if (!(ps->info.sampler_mask & (1u << i))) continue;
        struct obj *t = s->texture[i];
        id<MTLTexture> mt = t ? texture_of(t) : dummy_texture(k->psv.tex_kind[i]);
        if (tex_kind_of(t) != k->psv.tex_kind[i]) mt = dummy_texture(k->psv.tex_kind[i]);
        [e setFragmentTexture:mt atIndex:i];
        [e setFragmentSamplerState:sampler_state(s->ss[i], mt.mipmapLevelCount > 1) atIndex:i];
    }
    [e setVertexBuffer:zero_buffer offset:0 atIndex:16];
    return 1;
}

// Index data for a draw, as 16- or 32-bit indices in upload space. Triangle fans
// become lists.
static id<MTLBuffer> index_data(uint32_t type, const void *src, int is32, uint32_t prims, uint32_t *count,
                                NSUInteger *offset, MTLIndexType *itype)
{
    uint32_t n = index_count(type, prims);
    *count = n;
    *itype = is32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
    if (type != 6) return upload(src, (NSUInteger)n * (is32 ? 4 : 2), offset);
    id<MTLBuffer> b = upload(NULL, (NSUInteger)n * 4, offset);
    uint32_t *out = (uint32_t *)((uint8_t *)b.contents + *offset);
    for (uint32_t i = 0; i < prims; i++) {
        uint32_t a = 0, c = i + 1, d = i + 2;
        if (src) {
            a = is32 ? ((const uint32_t *)src)[0] : ((const uint16_t *)src)[0];
            c = is32 ? ((const uint32_t *)src)[i + 1] : ((const uint16_t *)src)[i + 1];
            d = is32 ? ((const uint32_t *)src)[i + 2] : ((const uint16_t *)src)[i + 2];
        }
        out[3 * i] = a, out[3 * i + 1] = c, out[3 * i + 2] = d;
    }
    *itype = MTLIndexTypeUInt32;
    return b;
}

void d3d_render_draw(struct d3d_state *s, uint32_t type, int32_t base_vertex, uint32_t min_index, uint32_t nverts,
                     uint32_t start, uint32_t count, int indexed, uint32_t unused0, uint32_t unused1)
{
    (void)unused0, (void)unused1;
    ensure_device();
    draws++, frame_draws++;
    log_draw(s, indexed ? "drawindexed" : "draw", type, count);
    if (draw_stats && (long)frames >= draw_stats_frame && (long)frames < draw_stats_frame + draw_stats_count)
        fprintf(stderr, "[drawsrc] f%lu #%lu vb %#x+%u ib %#x start %u base %d min %u n %u vs %#x c11 %g %g %g %g zw %u\n", frames, draws,
                s->stream[0] ? s->stream[0]->guest : 0, s->stream_offset[0], s->indices ? s->indices->guest : 0, start,
                base_vertex, min_index, nverts, s->vs ? s->vs->guest : 0, u2f(s->vs_f[11][0]), u2f(s->vs_f[11][1]),
                u2f(s->vs_f[11][2]), u2f(s->vs_f[11][3]), s->rs[14]);
    if (!s->render_target[0] || !count) return;
    struct element el[64];
    int nel = vertex_elements(s, el, 64);
    ao_before_draw(s, el, nel);
    id<MTLRenderCommandEncoder> e = pass(s);
    struct pipe_key k;
    if (!setup_draw(s, e, type, el, nel, &k)) return;
    if (env_tex_stats && (long)frames == draw_stats_frame) {
        // debugging: brightness of each plain 32-bit texture the frame samples, once per texture
        static void *seen[256];
        static int nseen;
        for (int i = 0; i < 8; i++) {
            struct obj *t = s->texture[i];
            if (!t || t->type != OBJ_TEXTURE || (t->usage & 1) || t->format != 21) continue;
            int known = 0;
            for (int j = 0; j < nseen; j++) known |= seen[j] == t;
            if (known || nseen == 256) continue;
            seen[nseen++] = t;
            const uint8_t *px = bl_g2h(t->subs[0]->mem);
            unsigned long sum[3] = {0}, n = 0, sat = 0;
            for (uint32_t y = 0; y < t->height; y++)
                for (uint32_t x = 0; x < t->width; x++, n++) {
                    const uint8_t *q = px + y * t->subs[0]->pitch + x * 4;
                    for (int c = 0; c < 3; c++) sum[c] += q[c];
                    sat += q[0] == 255 && q[1] == 255 && q[2] == 255;
                }
            fprintf(stderr, "[texstats] draw %lu stage %d %ux%u mem %#x mean bgr %lu %lu %lu, white %lu of %lu\n", draws, i,
                    t->width, t->height, t->subs[0]->mem, sum[0] / n, sum[1] / n, sum[2] / n, sat, n);
        }
    }
    const char *dd = env_draw_dump;
    static int dumped_by_prims;
    int dump = dd && (dd[0] == 'p' ? (long)frames == draw_stats_frame &&
                                         (uint32_t)atol(dd + 1) == count &&
                                         ++dumped_by_prims == (strchr(dd, ':') ? atoi(strchr(dd, ':') + 1) : 1)
                                   : listed(dd, draws));
    if (dump) {
        fprintf(stderr, "[dump] draw %lu: base %d min %u nverts %u start %u prims %u\n", draws, base_vertex, min_index,
                nverts, start, count);
        for (int i = 0; i < nel; i++)
            fprintf(stderr, "[dump]   element stream %u offset %u type %u usage %u index %u\n", el[i].stream,
                    el[i].offset, el[i].type, el[i].usage, el[i].index);
        for (int b = 0; b < 2; b++)
            if (s->stream[b]) {
                const float *f = (const float *)((const uint8_t *)bl_g2h(s->stream[b]->mem) + s->stream_offset[b] +
                                                 (size_t)(base_vertex + (int32_t)min_index) * s->stream_stride[b]);
                for (uint32_t v = 0; v < 4 && v < nverts; v++) {
                    fprintf(stderr, "[dump]   s%d v%u:", b, v);
                    for (uint32_t j = 0; j < s->stream_stride[b] / 4 && j < 12; j++)
                        fprintf(stderr, " %g", f[v * s->stream_stride[b] / 4 + j]);
                    fprintf(stderr, "\n");
                }
            }
        for (int i = 0; i < 96; i++)
            fprintf(stderr, "[dump]   c%d = %g %g %g %g\n", i, u2f(s->vs_f[i][0]), u2f(s->vs_f[i][1]),
                    u2f(s->vs_f[i][2]), u2f(s->vs_f[i][3]));
        for (int i = 0; i < 32; i++)
            fprintf(stderr, "[dump]   pc%d = %g %g %g %g\n", i, u2f(s->ps_f[i][0]), u2f(s->ps_f[i][1]),
                    u2f(s->ps_f[i][2]), u2f(s->ps_f[i][3]));
        fprintf(stderr, "[dump]   blend %u src %u dst %u op %u, alphatest %u ref %u func %u, wmask %#x, z %u/%u\n", s->rs[27],
                s->rs[19], s->rs[20], s->rs[171], s->rs[15], s->rs[24], s->rs[25], s->rs[168], s->rs[7], s->rs[14]);
        fprintf(stderr, "[dump]   viewport %u %u %u %u\n", s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3]);
        if (s->vs)
            for (int i = 0; i < 16; i++)
                if (shader_of(s->vs)->info.input_mask & (1u << i))
                    fprintf(stderr, "[dump]   vs input v%d usage %u index %u\n", i, shader_of(s->vs)->info.input_usage[i],
                            shader_of(s->vs)->info.input_index[i]);
        fprintf(stderr, "[dump]   zfunc %u, depth bias %g slope %g, cull %u\n", s->rs[23], u2f(s->rs[195]), u2f(s->rs[175]),
                s->rs[22]);
        for (int i = 0; i < 8; i++)
            if (s->texture[i])
                fprintf(stderr, "[dump]   tex%d %ux%u fmt %u usage %#x levels %u mtl %p\n", i, s->texture[i]->width,
                        s->texture[i]->height, s->texture[i]->format, s->texture[i]->usage, s->texture[i]->levels,
                        s->texture[i]->gpu);
        for (int i = 0; i < 8 && env_dump_dir; i++) {  // plain 32-bit textures as PNGs
            struct obj *t = s->texture[i];
            if (!t || t->type != OBJ_TEXTURE || (t->usage & 1) || (t->format != 21 && t->format != 22)) continue;
            id<MTLTexture> mt = texture_of(t);
            id<MTLBuffer> b = [mtl newBufferWithLength:mt.width * mt.height * 4 options:MTLResourceStorageModeShared];
            [mt getBytes:b.contents bytesPerRow:mt.width * 4 fromRegion:MTLRegionMake2D(0, 0, mt.width, mt.height)
             mipmapLevel:0];
            char path[1024];
            snprintf(path, sizeof path, "%s/draw_%lu_tex%d.png", env_dump_dir, draws, i);
            write_png(b, mt.width, mt.height, path);
        }
        if (s->render_target[0])
            fprintf(stderr, "[dump]   last offscreen target %p parent %p\n", last_offscreen_target,
                    last_offscreen_target ? (__bridge void *)target_texture(last_offscreen_target).parentTexture : NULL);
        char err[256];
        char *msl = s->vs ? d3d_shader_msl(shader_of(s->vs)->code, &k.vsv, err, sizeof err) : NULL;
        fprintf(stderr, "%s\n", msl ? strstr(msl, "vertex BLVSOut") : err);
        free(msl);
        msl = s->ps ? d3d_shader_msl(shader_of(s->ps)->code, &k.psv, err, sizeof err) : NULL;
        fprintf(stderr, "%s\n", msl ? strstr(msl, "fragment BLPSOut") : err);
        free(msl);
    }
    // Vertex range read by this draw.
    uint32_t first, nv;
    if (indexed) {
        first = (uint32_t)base_vertex + min_index, nv = nverts;
    } else {
        first = (uint32_t)base_vertex, nv = type == 6 ? count + 2 : index_count(type, count);
    }
    int any_rebased = 0, all_rebased = 1;
    struct stream_src src[16];
    for (int b = 0; b < 16; b++) {
        int used = 0;
        for (int i = 0; i < 16; i++)
            if (k.attr[i].format && k.attr[i].buffer == b) used = 1;
        if (!used) continue;
        int rebased;
        src[b] = stream_data(s->stream[b], s->stream_offset[b], s->stream_stride[b], first, nv, &rebased);
        if (!src[b].buf) {
            LOG_ONCE("[metal] draw without a vertex buffer on stream %d\n", b);
            return;
        }
        any_rebased |= rebased, all_rebased &= rebased;
        [e setVertexBuffer:src[b].buf offset:src[b].offset atIndex:(NSUInteger)b];
    }
    if (any_rebased && !all_rebased) {
        // Mixed static and dynamic streams: express everything relative to `first`.
        for (int b = 0; b < 16; b++) {
            int used = 0;
            for (int i = 0; i < 16; i++)
                if (k.attr[i].format && k.attr[i].buffer == b) used = 1;
            if (!used || !s->stream[b] || (s->stream[b]->usage & 0x200)) continue;
            [e setVertexBuffer:src[b].buf offset:src[b].offset + (NSUInteger)first * src[b].stride atIndex:(NSUInteger)b];
        }
    }
    int rel = any_rebased;  // vertex 0 of the bound buffers is vertex `first`
    if (!indexed) {
        if (type == 6) {
            uint32_t ic;
            NSUInteger io;
            MTLIndexType it;
            id<MTLBuffer> ib = index_data(type, NULL, 1, count, &ic, &io, &it);
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:ic indexType:it indexBuffer:ib
                   indexBufferOffset:io instanceCount:1 baseVertex:rel ? 0 : (NSInteger)first baseInstance:0];
        } else {
            [e drawPrimitives:primitive(type) vertexStart:rel ? 0 : first vertexCount:nv];
        }
        return;
    }
    struct obj *ibo = s->indices;
    if (!ibo) return;
    int is32 = ibo->format == 102;  // D3DFMT_INDEX32
    uint32_t isz = is32 ? 4 : 2, ic;
    if ((uint64_t)start * isz + (uint64_t)index_count(type, count) * isz > ibo->size) {
        LOG_ONCE("[metal] index range past the end of the index buffer\n");
        return;
    }
    NSUInteger io;
    MTLIndexType it;
    id<MTLBuffer> ib = index_data(type, (const uint8_t *)bl_g2h(ibo->mem) + (size_t)start * isz, is32, count, &ic, &io, &it);
    NSInteger bv = rel ? -(NSInteger)min_index : base_vertex;
    [e drawIndexedPrimitives:primitive(type) indexCount:ic indexType:it indexBuffer:ib indexBufferOffset:io
               instanceCount:1 baseVertex:bv baseInstance:0];
}

void d3d_render_draw_up(struct d3d_state *s, uint32_t type, uint32_t min_index, uint32_t nverts, uint32_t count,
                        uint32_t indices, uint32_t index_format, uint32_t data, uint32_t stride)
{
    ensure_device();
    draws++, frame_draws++;
    log_draw(s, indices ? "drawindexedup" : "drawup", type, count);
    if (!s->render_target[0] || !count || !stride) return;
    struct element el[64];
    int nel = vertex_elements(s, el, 64);
    ao_before_draw(s, el, nel);
    id<MTLRenderCommandEncoder> e = pass(s);
    struct pipe_key k;
    // UP draws read stream 0 with the given stride.
    uint32_t saved_stride = s->stream_stride[0];
    s->stream_stride[0] = stride;
    int ok = setup_draw(s, e, type, el, nel, &k);
    s->stream_stride[0] = saved_stride;
    if (!ok) return;
    uint32_t nv = indices ? min_index + nverts : (type == 6 ? count + 2 : index_count(type, count));
    NSUInteger vo;
    id<MTLBuffer> vb = upload(bl_g2h(data), (NSUInteger)nv * stride, &vo);
    [e setVertexBuffer:vb offset:vo atIndex:0];
    if (!indices && type != 6) {
        [e drawPrimitives:primitive(type) vertexStart:0 vertexCount:nv];
        return;
    }
    uint32_t ic;
    NSUInteger io;
    MTLIndexType it;
    id<MTLBuffer> ib = index_data(type, indices ? bl_g2h(indices) : NULL, index_format == 102, count, &ic, &io, &it);
    [e drawIndexedPrimitives:primitive(type) indexCount:ic indexType:it indexBuffer:ib indexBufferOffset:io
               instanceCount:1 baseVertex:0 baseInstance:0];
}

// --- copies, read back and frame dumps -------------------------------------------------

// A BGRA8 copy of a colour target in another format (the deep-colour back buffer).
static id<MTLTexture> as_bgra8(id<MTLTexture> t)
{
    if (t.pixelFormat == MTLPixelFormatBGRA8Unorm) return t;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:t.width height:t.height
                                                                             mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> copy = [mtl newTextureWithDescriptor:td];
    uint32_t r[4] = {0, 0, (uint32_t)t.width, (uint32_t)t.height};
    stretch_draw(t, r, copy, r, 0);
    return copy;
}

// Copies a colour target into a shared BGRA8 buffer and waits; returns its contents.
static id<MTLBuffer> read_target(id<MTLTexture> t)
{
    end_pass();
    t = as_bgra8(t);
    NSUInteger row = t.width * 4;
    id<MTLBuffer> b = [mtl newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0
      destinationBytesPerRow:row destinationBytesPerImage:row * t.height];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    cmd = nil;
    return b;
}

static void write_png(id<MTLBuffer> b, NSUInteger w, NSUInteger h, const char *path)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, b.contents, w * h * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, dp, NULL,
                                   false, kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CFRelease(url);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    fprintf(stderr, "[metal] wrote %s\n", dst ? path : "(failed)");
}

static int dump_this_frame(unsigned long n)
{
    const char *list = getenv("BL_DUMP_FRAME");
    if (!list) return 0;
    for (const char *p = list; *p;) {
        char *end;
        unsigned long v = strtoul(p, &end, 10);
        if (end == p) break;
        if (v == n) return 1;
        p = *end ? end + 1 : end;
    }
    return 0;
}

void d3d_render_read_back(struct obj *rt)
{
    // GetRenderTargetData: the guest copy of a render target after GPU rendering.
    if (!rt->gpu || !rt->mem || target_format(rt->format) != MTLPixelFormatBGRA8Unorm) return;
    end_pass();
    id<MTLBuffer> b = read_target((__bridge id<MTLTexture>)rt->gpu);
    for (uint32_t y = 0; y < rt->height; y++)
        memcpy((uint8_t *)bl_g2h(rt->mem) + y * rt->pitch, (uint8_t *)b.contents + y * rt->width * 4, rt->width * 4);
}

static void next_frame(void)
{
    __block dispatch_semaphore_t sem = in_flight;
    static int gpu_stats = -1;
    if (gpu_stats < 0) gpu_stats = getenv("BL_GPU_STATS") != NULL;
    int stats = gpu_stats;
    [command_buffer() addCompletedHandler:^(id<MTLCommandBuffer> b) {
      if (stats) {  // BL_GPU_STATS=1: mean GPU time per frame, every 100 frames
          static double sum;
          static int n;
          sum += b.GPUEndTime - b.GPUStartTime;
          if (++n == 100) fprintf(stderr, "[gpu] %.2f ms a frame\n", sum * 10), sum = 0, n = 0;
      }
      dispatch_semaphore_signal(sem);
    }];
    [cmd commit];
    cmd = nil;
    dispatch_semaphore_wait(in_flight, DISPATCH_TIME_FOREVER);
    frame_slot = (frame_slot + 1) % FRAMES_IN_FLIGHT;
    chunk_index = chunk_used = 0;
}

// Frame pacing. The game is capped at fps_max (its physics and scripts expect 60), but
// a plain present shows each frame at the next refresh after the GPU finishes, so on a
// 120 Hz ProMotion screen the small jitter of the cap's sleep makes frames alternate
// between one and three refreshes. When the refresh rate is a whole multiple of the cap,
// each frame is instead held for at least 1/fps_max (two refreshes at 120 Hz), which
// gives an even cadence. Other rates (144 Hz, say) keep the plain present: holding a
// frame for whole refreshes there would slow the game below the cap.
static int paced_present(void)
{
    static int checked_at = -1000, paced = -1;
    if (env_pacing && fps_max > 0 && (long)frames - checked_at >= 120) {  // the window may change screens
        checked_at = (int)frames;
        int hz = bl_cocoa_refresh_rate();
        double ratio = hz / fps_max;
        int whole = (int)(ratio + 0.5);
        int now = whole >= 1 && fabs(ratio - whole) < 0.01;
        if (now != paced)
            fprintf(stderr, "[present] screen %d Hz, cap %g: %s\n", hz, fps_max,
                    now ? "holding each frame for whole refreshes" : "plain present");
        paced = now;
    }
    return paced > 0;
}

// BL_PACING_STATS=1 logs how many refreshes apart frames actually reached the screen.
static void count_presented(id<CAMetalDrawable> drawable)
{
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static double last;
    static unsigned hist[5], total;
    double hz = bl_cocoa_refresh_rate();
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
      double t = d.presentedTime;
      if (t <= 0 || hz <= 0) return;  // dropped
      os_unfair_lock_lock(&lock);
      if (last > 0) {
          int n = (int)((t - last) * hz + 0.5);
          hist[n < 1 ? 0 : n > 4 ? 4 : n]++;
          if (++total == 600) {
              fprintf(stderr, "[pacing] last 600 frames, refreshes apart: 1:%u 2:%u 3:%u 4+:%u (dropped/odd %u)\n",
                      hist[1], hist[2], hist[3], hist[4], hist[0]);
              memset(hist, 0, sizeof hist), total = 0;
          }
      }
      last = t;
      os_unfair_lock_unlock(&lock);
    }];
}

// The drawable is 10-bit with deep colour: a blit needs equal formats, a draw converts.
static void copy_to_drawable(id<MTLTexture> t, id<CAMetalDrawable> drawable)
{
    end_pass();
    if (t.pixelFormat == drawable.texture.pixelFormat) {
        id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
        [blit copyFromTexture:t toTexture:drawable.texture];
        [blit endEncoding];
    } else {
        uint32_t r[4] = {0, 0, (uint32_t)t.width, (uint32_t)t.height};
        stretch_draw(t, r, drawable.texture, r, 0);
    }
}

static void present(id<CAMetalDrawable> drawable)
{
    if (env_pacing_stats) count_presented(drawable);
    if (paced_present())
        [command_buffer() presentDrawable:drawable afterMinimumDuration:1.0 / fps_max];
    else
        [command_buffer() presentDrawable:drawable];
}

// Black bars either side of a menu narrowed to 4:3: the game's own clears and
// backgrounds covered the whole width, so the bars may still hold an older frame.
static void menu_bars(id<MTLTexture> t, float squeeze)
{
    end_pass();
    static id<MTLTexture> black;
    if (!black) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:1 height:1 mipmapped:NO];
        black = [mtl newTextureWithDescriptor:td];
        uint32_t px = 0xFF000000;
        [black replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&px bytesPerRow:4];
    }
    uint32_t bar = (uint32_t)floor(t.width * (1 - squeeze) / 2), one[4] = {0, 0, 1, 1};
    if (!bar) return;
    uint32_t left[4] = {0, 0, bar, (uint32_t)t.height}, right[4] = {(uint32_t)t.width - bar, 0, (uint32_t)t.width, (uint32_t)t.height};
    stretch_draw(black, one, t, left, 0);
    stretch_draw(black, one, t, right, 0);
}

void d3d_render_present(struct d3d_state *s)
{
    ensure_device();
    bl_vgui_poll();  // the options' check box
    if (ao_state == 1) {  // a frame with no view model or HUD
        ao_run(s);
        if (ao_result && s->render_target[0] == s->back_buffer) pass(s);
    }
    ao_state = 0, ao_result = nil;
    flush_clears(s);
    frames++;
    bl_cocoa_script_input(frames, game_window);
    struct obj *bb = s->back_buffer;
    id<MTLTexture> back = bb ? target_texture(bb) : nil;
    if (back && frame_squeeze < 1) menu_bars(back, frame_squeeze);
    static float shown_squeeze = 1;
    if (frame_squeeze != shown_squeeze) {
        shown_squeeze = frame_squeeze;
        bl_cocoa_set_squeeze(frame_squeeze);
        fprintf(stderr, "[d3d9] frame %lu: %s\n", frames, frame_squeeze < 1 ? "menu at 4:3" : "full width");
    }
    last_3d = frame_has_3d;
    menu_frame = !frame_has_3d;
    frame_has_3d = 0, frame_squeeze = 1;
    if (back && dump_this_frame(frames)) {
        const char *dir = getenv("BL_DUMP_DIR") ? getenv("BL_DUMP_DIR") : ".";
        char path[1024];
        snprintf(path, sizeof path, "%s/frame_%lu.png", dir, frames);
        write_png(read_target(back), back.width, back.height, path);
        id<MTLTexture> off = last_offscreen_target ? target_texture(last_offscreen_target) : nil;
        if (off && off.pixelFormat == MTLPixelFormatBGRA8Unorm) {
            snprintf(path, sizeof path, "%s/frame_%lu_rt.png", dir, frames);
            write_png(read_target(off), off.width, off.height, path);
        }
    }
    if (layer && back) {
        @autoreleasepool {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (drawable && drawable.texture.width == back.width && drawable.texture.height == back.height) {
                copy_to_drawable(back, drawable);
                present(drawable);
            }
            next_frame();
        }
    } else {
        next_frame();
    }
    if (layer && fps_max > 0) {
        // The game runs its loop flat out; with a window, wait out the rest of the frame
        // instead of burning a core on frames nobody sees.
        static uint64_t next_ns;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), period = (uint64_t)(1e9 / fps_max);
        if (next_ns > now && next_ns - now <= period) {
            struct timespec ts = {0, (long)(next_ns - now)};
            nanosleep(&ts, NULL);
            next_ns += period;
        } else {
            next_ns = now + period;  // first frame, or behind by more than a frame
        }
    }
    if (env_shader_stats) {
        if (frame_build_ns > 2000000)
            fprintf(stderr, "[shaders] frame %lu: %.1f ms building\n", frames, frame_build_ns / 1e6);
        if (frames % 100 == 0)
            fprintf(stderr, "[shaders] total: %lu compiled early, %llu at draws; %.0f ms waiting in draws, %llu pipelines %.0f ms\n",
                    shaders_early, (unsigned long long)build_count[0], build_ns[0] / 1e6,
                    (unsigned long long)build_count[1], build_ns[1] / 1e6);
    }
    frame_build_ns = 0;
    if (frames == 1 || frames % 100 == 0)
        fprintf(stderr, "[d3d9] frame %lu: %lu draws (%lu total), %d perspective\n", frames, frame_draws, draws, last_3d);
    frame_draws = 0;
    if (max_frames >= 0 && (long)frames >= max_frames) {
        fprintf(stderr, "[d3d9] %lu frames presented, stopping (BL_MAX_FRAMES)\n", frames);
        exit(0);
    }
}

// GDI blits to the window (Bink draws movie frames this way when it has no DirectDraw
// surface). The pixels are 32-bit BGRX rows from a DIB section; `bottom_up` flips them.
// They are scaled into a persistent window-sized image, which is then presented, so
// the parts of the window a movie does not cover stay black.
void d3d_render_present_pixels(const void *pixels, uint32_t w, uint32_t h, int bottom_up, const int32_t sr[4],
                               const int32_t dr[4])
{
    ensure_device();
    if (!layer) return;
    end_pass();
    static id<MTLTexture> src, screen;
    if (!src || src.width != w || src.height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        src = [mtl newTextureWithDescriptor:td];
    }
    NSUInteger sw = (NSUInteger)layer.drawableSize.width, sh = (NSUInteger)layer.drawableSize.height;
    if (!sw || !sh) return;
    // A new movie (another frame size or place) starts on black. On Windows the window
    // is repainted between movies; here the last frame of the previous one would stay
    // around a smaller movie (the white Troika logo around the next, centred one).
    static int32_t last[6];
    int32_t now[6] = {(int32_t)w, (int32_t)h, dr[0], dr[1], dr[2], dr[3]};
    int fresh = memcmp(now, last, sizeof now) != 0;
    memcpy(last, now, sizeof now);
    if (!screen || screen.width != sw || screen.height != sh || fresh) {
        if (!screen || screen.width != sw || screen.height != sh) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                         width:sw height:sh mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModePrivate;
            screen = [mtl newTextureWithDescriptor:td];
        }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = screen;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[command_buffer() renderCommandEncoderWithDescriptor:rp] endEncoding];
    }
    // Overwriting src while the GPU still reads the previous frame from it would tear
    // that frame; at movie frame rates the GPU has long finished.
    for (uint32_t y = 0; y < h; y++)
        [src replaceRegion:MTLRegionMake2D(0, y, w, 1) mipmapLevel:0
                 withBytes:(const uint8_t *)pixels + (size_t)(bottom_up ? h - 1 - y : y) * w * 4 bytesPerRow:w * 4];
    // Clip both rectangles to their images, scaling the source with the destination.
    int32_t s0[4] = {sr[0], sr[1], sr[2], sr[3]}, d0[4] = {dr[0], dr[1], dr[2], dr[3]};
    // A movie stretched over a whole window wider than 4:3 is shown at 4:3 with black
    // bars instead, which is how it looked on the 4:3 screens it was made for. That
    // includes the 720x480 one: DV-sized frames are 4:3 pictures with narrow pixels.
    // Centred movies drawn at their own size are left alone. BL_WIDESCREEN=stretch
    // keeps the game's stretch.
    if (env_widescreen && d0[0] <= 0 && d0[1] <= 0 && d0[2] >= (int32_t)sw && d0[3] >= (int32_t)sh &&
        (d0[2] - d0[0] != s0[2] - s0[0] || d0[3] - d0[1] != s0[3] - s0[1]) && sw * 3 > sh * 4 + sh / 25) {
        int32_t fit = (int32_t)(sh * 4 / 3), x0 = ((int32_t)sw - fit) / 2;
        d0[0] = x0, d0[1] = 0, d0[2] = x0 + fit, d0[3] = (int32_t)sh;
    }
    if (d0[2] <= d0[0] || d0[3] <= d0[1] || s0[2] <= s0[0] || s0[3] <= s0[1]) return;
    float kx = (float)(s0[2] - s0[0]) / (d0[2] - d0[0]), ky = (float)(s0[3] - s0[1]) / (d0[3] - d0[1]);
    if (d0[0] < 0) s0[0] -= (int32_t)(d0[0] * kx), d0[0] = 0;
    if (d0[1] < 0) s0[1] -= (int32_t)(d0[1] * ky), d0[1] = 0;
    if (d0[2] > (int32_t)sw) s0[2] -= (int32_t)((d0[2] - (int32_t)sw) * kx), d0[2] = (int32_t)sw;
    if (d0[3] > (int32_t)sh) s0[3] -= (int32_t)((d0[3] - (int32_t)sh) * ky), d0[3] = (int32_t)sh;
    for (int i = 0; i < 4; i++) {
        if (s0[i] < 0) s0[i] = 0;
        if (s0[i] > (int32_t)(i & 1 ? h : w)) s0[i] = (int32_t)(i & 1 ? h : w);
    }
    if (d0[2] <= d0[0] || d0[3] <= d0[1] || s0[2] <= s0[0] || s0[3] <= s0[1]) return;
    uint32_t su[4] = {(uint32_t)s0[0], (uint32_t)s0[1], (uint32_t)s0[2], (uint32_t)s0[3]};
    uint32_t du[4] = {(uint32_t)d0[0], (uint32_t)d0[1], (uint32_t)d0[2], (uint32_t)d0[3]};
    stretch_draw(src, su, screen, du, 1);
    static int movie, movie_frame;  // BL_MOVIE_DUMP=1: frame 60 of each movie as a PNG
    if (fresh) movie++, movie_frame = 0;
    if (++movie_frame == 60 && getenv("BL_MOVIE_DUMP")) {
        char path[1024];
        snprintf(path, sizeof path, "%s/movie_%d.png", env_dump_dir ? env_dump_dir : ".", movie);
        write_png(read_target(screen), screen.width, screen.height, path);
    }
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable && drawable.texture.width == sw && drawable.texture.height == sh) {
            copy_to_drawable(screen, drawable);
            present(drawable);
        }
        next_frame();
    }
}

void d3d_render_stretch(struct obj *src, uint32_t src_rect, struct obj *dst, uint32_t dst_rect, uint32_t filter)
{
    if (!src || !dst) return;
    ensure_device();
    end_pass();
    // Only GPU-side surfaces (render targets) are copied here.
    id<MTLTexture> a = src->gpu || (src->usage & 1) || (src->owner && src->owner->type == OBJ_DEVICE)
                       ? target_texture(src) : nil;
    id<MTLTexture> b = target_texture(dst);
    int depth = is_depth_format(src->format) || is_depth_format(dst->format);
    if (!a || (a.pixelFormat != b.pixelFormat && depth)) {
        LOG_ONCE("[metal] StretchRect between these surfaces is not supported yet\n");
        return;
    }
    uint32_t sr[4] = {0, 0, (uint32_t)a.width, (uint32_t)a.height}, dr[4] = {0, 0, (uint32_t)b.width, (uint32_t)b.height};
    if (src_rect) memcpy(sr, bl_g2h(src_rect), 16);
    if (dst_rect) memcpy(dr, bl_g2h(dst_rect), 16);
    if (multisampled(dst)) dst->ms_stale = 1;  // written outside its multisampled copy
    if (sr[2] - sr[0] != dr[2] - dr[0] || sr[3] - sr[1] != dr[3] - dr[1]) {
        stretch_draw(a, sr, b, dr, filter != 1);  // D3DTEXF_POINT is 1; NONE and LINEAR filter
        return;
    }
    if (a.pixelFormat != b.pixelFormat) {  // deep-colour back buffer to an 8-bit texture, say
        stretch_draw(a, sr, b, dr, 0);
        return;
    }
    uint32_t w = sr[2] - sr[0] < dr[2] - dr[0] ? sr[2] - sr[0] : dr[2] - dr[0];
    uint32_t h = sr[3] - sr[1] < dr[3] - dr[1] ? sr[3] - sr[1] : dr[3] - dr[1];
    id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
    [blit copyFromTexture:a sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sr[0], sr[1], 0)
               sourceSize:MTLSizeMake(w, h, 1) toTexture:b destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(dr[0], dr[1], 0)];
    [blit endEncoding];
}

void d3d_render_color_fill(struct obj *surf, uint32_t rect, uint32_t color)
{
    (void)rect;
    if (!surf) return;
    ensure_device();
    // Whole-surface fills only, as a clear of the next pass on it.
    end_pass();
    clear_color_target = surf;
    clear_color = MTLClearColorMake((color >> 16 & 255) / 255.0, (color >> 8 & 255) / 255.0, (color & 255) / 255.0,
                                    (color >> 24) / 255.0);
    struct d3d_state tmp;
    memset(&tmp, 0, sizeof tmp);
    tmp.render_target[0] = surf;
    pass(&tmp);
    end_pass();
}

void d3d_image_changed(struct obj *surface)
{
    surface->dirty = 1;
    if (surface->owner && surface->owner->type != OBJ_DEVICE) surface->owner->dirty = 1;
}

void d3d_buffer_changed(struct obj *buffer) { buffer->dirty = 1; }
