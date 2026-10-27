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
//                            (with BL_DUMP_DIR, its 32-bit textures are also written as PNGs); with
//                            "lightmap", of the first draw in that frame reading a lightmap page unsmoothed
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
//   BL_ANISO=n               anisotropic filtering for filtered mipmapped textures (default 16, 1 = off)
//   BL_AO=0|1|show           ambient occlusion (see post_run), over the options' check box;
//                            BL_AO_RADIUS, BL_AO_THICKNESS, BL_AO_STRENGTH tune it
//   BL_SSR=0|1|show|hits     screen-space reflections (see post_run), over the options' check box;
//                            "hits": red the reflection weight, green where rays met the picture,
//                            blue what the cubemaps added; BL_SSR_STRENGTH (default 1) scales them,
//                            BL_SSR_FRESNEL (3) and BL_SSR_BLUR (0.02) tune them; BL_GLOSS scales
//                            the reflections given to materials the game left without (0 none);
//                            BL_PBR=0 leaves out the surfaces' facing and PBRify maps (pbr_map),
//                            BL_PBR_BUMP (default 1) how much their bumps shade the light,
//                            BL_PBR_SPEC (default 1.5) how much the lights shine on them,
//                            BL_POM_DEPTH (default 0.015, 0 off) how deep the parallax of
//                            surfaces with a height map goes, as a share of their texture's
//                            size, BL_POM_DIST (default 1500) how far out it fades
//   BL_HDR=0|1               HDR output on screens that have it (see hdr_present), over the
//                            options' check box; BL_HDR_PEAK, BL_HDR_KNEE, BL_HDR_HEADROOM tune it
//   BL_FOG=0|1               volumetric light: the map's lights in a thin haze (see fog_run), over
//                            the options' check box; BL_FOG_DENSITY (default 0.0002 a world unit)
//                            and BL_FOG_DIST (how far it is traced, default 2000)
//   BL_SSS=0|1               light scattered under the skin of characters (see skin_run), over the
//                            options' check box ("show": the characters' pixels in red); BL_SSS_WIDTH (world units, default 0.8) and
//                            BL_SSS_STRENGTH (0..1, default 0.8); BL_SSS_SHEEN the skin's shine
//                            (default 3, 0 none)
//   BL_SHADOWS=0|1           better character shadows (see the shadows section), over the options'
//                            check box: BL_SHADOW_RES (atlas resolution, 1..4 times, default 4);
//                            BL_PCSS=0|1|show (soft shadows, default on; "show": red the distance
//                            to the caster, green the blockers found, blue the penumbra) with
//                            BL_PCSS_SOFT (penumbra per world unit, 0.03), BL_PCSS_MAX (largest
//                            penumbra, world units, 4), BL_PCSS_SEARCH (blocker search radius, 3);
//                            BL_CONTACT=0|1|show (contact shadows, default on) with
//                            BL_CONTACT_LENGTH (world units, 12) and BL_CONTACT_STRENGTH (0..1, 0.5);
//                            BL_SHADOWS_AB=n turns the setting over every n frames (comparisons)
//   BL_TAA_JITTER=n          the temporal anti-aliasing's offset (pixels, default 0.5; see the TAA
//                            section), negative flips it for MetalFX
//   BL_SHARPEN=0|1           sharpening of the world view after the anti-aliasing (taa_resolve), over
//                            the options' check box; BL_SHARPEN_STRENGTH (0..1, default 0.3)
//   BL_SKIN_DETAIL=0|1       pores and uneven shine on characters' faces (ps_detail), over the
//                            options' check box; BL_SKIN_DETAIL_STRENGTH (0..2, default 1) and
//                            BL_SKIN_DETAIL_SIZE (texels per pore, default 3), never bigger than
//                            BL_SKIN_DETAIL_MAX on faces (world units, 0.10) or _MAX_BODY on bodies
//                            (0.20); BL_SKIN_DETAIL_BODY (bodies' share of the strength, 0.7)
//   BL_CLOTH_DETAIL=0        no weave on characters' clothes (where the skin mask is not skin;
//                            on by default); BL_CLOTH_DETAIL_STRENGTH (0..2, default 1),
//                            BL_CLOTH_DETAIL_SIZE (texels per thread, 2), never bigger than
//                            BL_CLOTH_DETAIL_MAX (world units, 0.13)
//   BL_ROUND=0|1             characters' split triangles rounded (BL_TESS_ROUND), over the options'
//                            check box
//   BL_GPU_STATS=1          log the mean GPU time per frame every 100 frames (2: also per pass)
//   BL_PROP_TESS=0|1         props split and rounded like characters (BL_TESS per edge; default off)
//   BL_LIGHTMAP_SMOOTH=0|1   the map's baked light read smoothly (see the lightmaps section; default on)
//   BL_REBAKE=1              the lightmaps baked again on the GPU (shelved: see "the lighting rebake in the game")
//   BL_BLOOM=0|1|show        bright lights glow (see the bloom section), over the options' check box
//                            (on until unticked); BL_BLOOM_STRENGTH (default 0.35), BL_BLOOM_THRESHOLD (0.6)
//   BL_EXPOSURE=0|1|show     eye adaptation: the view brightens in the dark and dims in bright places
//                            (see the bloom section), over the options' check box (on until unticked);
//                            BL_EXPOSURE_RANGE (lo,hi: 0.8,1.3)
//   BL_BLOOM_AT=n            debugging: bloom and eye adaptation only from frame n
//   BL_SSIL=0|1|show|albedo  bounced light (see the bounced light section), over the options' check
//                            box (on until unticked); albedo shows the surfaces' colour; BL_SSIL_RADIUS (world units, default 128),
//                            BL_SSIL_STRENGTH (default 1), BL_SSIL_BLUR (passes, default 2)
//   BL_GI=0|1                global illumination: characters' and props' light from around them
//                            (see the light probes section), over the options' check box (on
//                            until unticked); BL_GI_MIX (0..1, default 1) how much of the game's
//                            own; BL_GI_LOG=n logs the first n changed draws
//   BL_LIGHTMAP_SMOOTH_AT=n  debugging: only from frame n (before and after in one run)
//   BL_UPSCALE=0            the game's own colour textures: no upscales (characters, build/hires)
//   BL_REMODEL=0            the game's own prop models: no remodels (build/remodels)
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import "mtl4.h"
#import <objc/runtime.h>

#include <math.h>
#include <stdatomic.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_bsp.h"
#import "gi_probes.h"
#import "lm_bake.h"
#import "tex_detail.h"
#import "tex_hires.h"
#include <mach-o/dyld.h>
#include "prop_remodel.h"
#include "prop_smooth.h"
#include "bl_cocoa.h"
#include "bl_win32.h"
#include "d3d9_shader.h"
#include "d3d9_state.h"

static id<MTLDevice> mtl;
static id<MTL4CommandQueue> queue;
static id<MTL4CommandBuffer> cmd;
static BLRender *enc;
static struct obj *enc_color, *enc_depth;  // targets of the open pass
static int env_detail = -1;  // see detail_bind
static float env_detail_strength = 1.0f, env_shine = 4.0f, env_charlight = 1.0f, env_charlight_min = 0.8f;
static int env_hair_u;  // BL_HAIR_U=1: hair strands run along the textures' u, not v
static float env_hair_fade = 1.0f;  // BL_HAIR_FADE: hair's soft edge, world units (0 off)
static float env_hair_soft = 0.75f;   // BL_HAIR_SOFT: hair drawn solid above this alpha, blended below (0 off)
static float env_hair_strands = 1.0f; // BL_HAIR_STRANDS: strength of hair's strand pattern
static float env_hair_root = 1.0f;    // BL_HAIR_ROOT: hair darker where it lies on the head
static float env_hair_glow = 1.0f;    // BL_HAIR_GLOW: light through hair from behind
static int env_hair_mesh = 1;         // BL_HAIR_MESH=0: the game's own hair, not the strips made for it
static int env_tess = 3;            // BL_TESS: characters' and props' triangles split this many times per edge (0 off)
// BL_TESS_ROUND: how far characters' split triangles move onto Phong's curve, 0 to 1 (0: not
// split), with the options' "Smooth Characters" box (BL_ROUND). 0.75 puffs faces up enough
// to cover the eyes; 0.25 softens chins and cheeks.
static float env_tess_round = 0.25f;
static int env_round;               // BL_ROUND (the effects table)
static int env_sharpen;             // BL_SHARPEN (the effects table)
static float env_sharpen_strength = 0.3f;  // BL_SHARPEN_STRENGTH
static int env_skin_detail;                // BL_SKIN_DETAIL (the effects table)
// Sizes in texels, as they look right on Jeanette; the largest in the world just over
// what 98% of her skin and shirt has (her face's pores up to 0.093 world units, her body's
// 0.196, her shirt's threads 0.131, measured from her model's triangles), so she keeps
// hers and only characters with coarser textures get finer ones.
static float env_skin_detail_strength = 1.0f, env_skin_detail_size = 3.0f;  // BL_SKIN_DETAIL_STRENGTH, _SIZE
static float env_skin_detail_max = 0.10f, env_skin_detail_max_body = 0.20f;  // BL_SKIN_DETAIL_MAX, _MAX_BODY
static float env_skin_detail_body = 0.7f;  // BL_SKIN_DETAIL_BODY: bodies' pores, gentler than faces'
static int env_cloth_detail = 1;            // BL_CLOTH_DETAIL=0: no weave
static float env_cloth_detail_strength = 1.0f, env_cloth_detail_size = 2.0f;  // BL_CLOTH_DETAIL_STRENGTH, _SIZE
static float env_cloth_detail_max = 0.13f;  // BL_CLOTH_DETAIL_MAX
static int env_prop_tess = 0;       // BL_PROP_TESS: props' too (prop_swap_for)
static int env_lightmap_smooth = 1;  // BL_LIGHTMAP_SMOOTH (lightmap_for)
static int env_rebake;               // BL_REBAKE=1: the lightmaps baked again (lightmap_rebake; shelved, off)
static long env_lightmap_at;         // BL_LIGHTMAP_SMOOTH_AT
static int env_bloom, env_bloom_show, env_exposure, env_exposure_show;  // BL_BLOOM, BL_EXPOSURE (the effects table)
static long env_bloom_at;  // BL_BLOOM_AT
static int env_ssil, env_ssil_show, env_ssil_blur = 2;  // BL_SSIL (the effects table), BL_SSIL_BLUR
static int env_gi, env_gi_log;  // BL_GI (the effects table), BL_GI_LOG
static float env_gi_mix = 1;    // BL_GI_MIX
static float env_ssil_radius = 128, env_ssil_strength = 1;
static float env_bloom_strength = 0.35f, env_bloom_threshold = 0.6f, env_exposure_lo = 0.8f, env_exposure_hi = 1.3f;
static int env_upscale_off;  // BL_UPSCALE=0: the game's own colour textures (characters, tex_hires.h)
static int env_remodel_off;  // BL_REMODEL=0: the game's own prop models (prop_remodel.h)
static int env_sss_eyes = 1;  // BL_SSS_EYES=0: no eye highlights
static int enc_info;                       // and whether it draws reflection info (info_texture)
static int enc_albedo;                     // and the surfaces' own colour (albedo_texture)
static int enc_surface;                    // and the surfaces' facing and roughness (surface_texture)
#define SURFACE_FORMAT MTLPixelFormatRGBA16Float
#define INFO_FORMAT MTLPixelFormatRGBA16Float
#define ALBEDO_FORMAT MTLPixelFormatRGBA8Unorm
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
// BL_HITCH=ms: log frames that take longer, with the time spent this frame loading
// upscaled and PBR textures and character normal maps (the rest: shaders, see frame_build_ns).
static double env_hitch;
static int env_prefetch_off;  // BL_PREFETCH=0: load upscales and normal maps when first drawn
static uint64_t hitch_tex_ns, hitch_pbr_ns;
static uint64_t hitch_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t hitch_detail_ns;
static uint64_t hitch_wait_ns, hitch_present_start;  // waiting for the GPU's frames in flight; present's start
static id<MTLTexture> detail_normal_timed(id<MTLDevice> dev, uint64_t key, uint32_t stamp, uint32_t w, uint32_t h,
                                          uint32_t format, const uint8_t *data, uint32_t pitch, id<MTLTexture> *color)
{
    uint64_t t0 = hitch_now();
    id<MTLTexture> r = bl_detail_normal(dev, key, stamp, w, h, format, data, pitch, color);
    hitch_detail_ns += hitch_now() - t0;
    return r;
}
static int env_aniso;   // forced anisotropy (BL_ANISO, default 16)
static int env_widescreen;  // correct the 4:3 projection on wider modes (BL_WIDESCREEN, default on)
static int frame_has_3d, menu_frame;  // a perspective draw to the back buffer: this frame, the last
static int last_3d;
static float frame_squeeze = 1;       // menu draws this frame were narrowed to this share of the width
static int deep_color;  // 16-bit back buffer, 10-bit window (BL_DEEP_COLOR, default on)

// Effects at the end of the world view, before the view model and HUD (post_run):
// ambient occlusion, screen-space reflections, volumetric light and skin.
// view_state: 0 no world view yet this frame, 1 world drawn (view_proj holds its
// projection), 2 done for this frame.
static int env_ao, env_ao_show, env_ssr, env_ssr_show, env_tonemap, env_hdr, env_fog, env_sss, env_sss_show;
static float env_ao_radius, env_ao_strength, env_ao_thickness, env_ssr_strength, env_ssr_fresnel, env_ssr_blur,
    env_tonemap_expand, env_hdr_peak, env_hdr_knee, env_hdr_headroom, env_fog_density, env_fog_dist, env_sss_width,
    env_sss_strength, env_sss_sheen;
static int view_state;
static struct { float alpha, beta, p00, p11; } view_proj;
// The camera of that projection: rows giving view x (right), y (up) and depth from a world
// position (dot with xyz, plus w).
static float view_rows[3][4];
static id<MTLTexture> ao_result;  // waiting to be multiplied in at the next pass on the back buffer
static int post_result;           // reflections, fog, skin or tone mapping waiting for that pass too
static void ao_apply(BLRender *e, id<MTLTexture> color, int has_depth);
static void post_apply(BLRender *e, id<MTLTexture> color, int has_depth);
static id<MTLTexture> ao_texture(int i, MTLPixelFormat pf, NSUInteger w, NSUInteger h);

// Temporal anti-aliasing (the TAA section): the world view's offset this frame, in pixels
// (y down), and whether post_run left motion vectors for the next pass on the back buffer.
static float taa_jitter[2];
static int taa_pending;
static void taa_note_camera(const float r8[4], const float r9[4], const float r10[4], const float r11[4], float clip_y);
static void taa_forget_camera(void);
static int taa_motion(id<MTLTexture> depth, NSUInteger w, NSUInteger h);
static void taa_resolve(id<MTLTexture> color);
static void taa_frame_end(void);

// The Visual options tab's check boxes (bl_vgui.c, read once a frame by bl_vgui_poll)
// set the effects and save them in the registry; the environment, when set, wins over both.
#define EFFECT_KEY "HKCU\\Software\\Troika\\Vampire\\Native"
enum { BL_EFFECT_AO, BL_EFFECT_SSR, BL_EFFECT_HDR, BL_EFFECT_FOG, BL_EFFECT_SSS, BL_EFFECT_SHADOWS,
       BL_EFFECT_BLOOM, BL_EFFECT_EXPOSURE, BL_EFFECT_SSIL, BL_EFFECT_GI, BL_EFFECT_ROUND, BL_EFFECT_SHARPEN,
       BL_EFFECT_SKIN_DETAIL,
       BL_EFFECTS };
static int env_shadows;  // the shadows section's switch
// The shadows section (below the stretch copies): the atlas's scale, its receivers, contact shadows.
static struct obj *shadow_atlas;
static int is_shadow_atlas(const struct obj *tex);
static int shadow_res_wanted(void);
static int obj_scale(const struct obj *o);
static MTLPixelFormat shadow_format_wanted(void);
static void shadow_settings(void);
static void shadow_frame_start(void);
static int pcss_on(void);
static void shadow_match_depth(struct obj *color, struct obj *depth);
static int contact_on(void);
static id<MTLTexture> contact_result;  // waiting to be multiplied in, like ao_result
static void contact_apply(BLRender *e, id<MTLTexture> color, int has_depth);
// Off until ticked, except where `def` says otherwise.
static const struct { const char *env, *value; int *on, *show, def; } effects[BL_EFFECTS] = {
    {"BL_AO", "AmbientOcclusion", &env_ao, &env_ao_show},
    {"BL_SSR", "Reflections", &env_ssr, &env_ssr_show},
    {"BL_HDR", "HDR", &env_hdr, NULL},
    {"BL_FOG", "VolumetricLight", &env_fog, NULL},
    {"BL_SSS", "SkinScattering", &env_sss, &env_sss_show},
    {"BL_SHADOWS", "Shadows", &env_shadows, NULL},
    {"BL_BLOOM", "Bloom", &env_bloom, &env_bloom_show, 1},
    {"BL_EXPOSURE", "EyeAdaptation", &env_exposure, &env_exposure_show, 1},
    {"BL_SSIL", "BouncedLight", &env_ssil, &env_ssil_show, 1},
    {"BL_GI", "GlobalIllumination", &env_gi, NULL, 1},
    {"BL_ROUND", "SmoothCharacters", &env_round, NULL, 1},
    {"BL_SHARPEN", "SharpenAfterAA", &env_sharpen, NULL, 1},
    {"BL_SKIN_DETAIL", "SkinDetail", &env_skin_detail, NULL, 1},
};
static int effects_loaded, effect_forced[BL_EFFECTS];
void bl_vgui_poll(void);

static void effect_settings(void)
{
    if (effects_loaded) return;
    effects_loaded = 1;
    for (int i = 0; i < BL_EFFECTS; i++) {
        const char *e = getenv(effects[i].env);
        int show = !e ? 0 : !strcmp(e, "show") ? 1 : !strcmp(e, "hits") || !strcmp(e, "albedo") ? 2 : 0;
        effect_forced[i] = e != NULL;
        if (effects[i].show) *effects[i].show = show;
        *effects[i].on = e ? atoi(e) != 0 || show : bl_reg_get_dword(EFFECT_KEY, effects[i].value, effects[i].def) != 0;
    }
}

int bl_effect_enabled(int effect)
{
    effect_settings();
    return effect >= 0 && effect < BL_EFFECTS && *effects[effect].on;
}

void bl_effect_set(int effect, int on)
{
    effect_settings();
    if (effect < 0 || effect >= BL_EFFECTS) return;
    bl_reg_set_dword(EFFECT_KEY, effects[effect].value, on != 0);
    if (!effect_forced[effect]) *effects[effect].on = on != 0;
}

#define LOG_ONCE(...) do { static int once_; if (!once_++) fprintf(stderr, __VA_ARGS__); } while (0)

// --- per-frame upload buffers ------------------------------------------------------

#define FRAMES_IN_FLIGHT 3
#define CHUNK (32u << 20)
static dispatch_semaphore_t in_flight;
static NSMutableArray<id<MTLBuffer>> *chunks[FRAMES_IN_FLIGHT];
static id<MTL4CommandAllocator> allocators[FRAMES_IN_FLIGHT];  // command_buffer
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

// How much a material the game drew without a reflection cubemap reflects, by its name's
// folder (the game's material types): the share of the screen-space reflections its
// surfaces get head on (more at grazing angles, BL_SSR_FRESNEL). Wood (varnished panels
// and floors) and tile so far; walls and the rest none. BL_GLOSS scales it (0: none).
static float material_gloss(const char *name)
{
    static const struct { const char *folder; float gloss; } table[] = {
        {"materials/tile/", 0.10f},
        {"materials/wood/", 0.06f},
        {"materials/metal/", 0.15f},
    };
    static float scale = -1;
    if (scale < 0) scale = getenv("BL_GLOSS") ? (float)atof(getenv("BL_GLOSS")) : 1;
    if (!name || scale <= 0) return 0;
    for (size_t i = 0; i < sizeof table / sizeof *table; i++)
        if (!strncmp(name, table[i].folder, strlen(table[i].folder))) return table[i].gloss * scale;
    return 0;
}

// The PBRify normal and roughness map for the texture the game calls `name`
// ("materials/wood/floorb"): build/textures/maps/<map>/wood/floorb_n.png and _r.png,
// made on the player's machine (tools/tex_normals.py), loaded as the characters' are
// (bl_load_normal_map); nil without one. The reflections use them for the surfaces'
// facing and roughness (variant surface). BL_PBR=0: none.
static int env_pbr = 1;
static float env_pbr_bump = 1;  // BL_PBR_BUMP: how much the maps' bumps shade the light (0 none)
static float env_pbr_spec = 1.5f;  // BL_PBR_SPEC: how much the lights shine on them (0 none)
static float env_pom_depth = 0.015f, env_pom_dist = 1500;  // BL_POM_DEPTH, BL_POM_DIST

// How metallic a material is, by its name: the metal folder, and chrome or steel
// anywhere (models' parts).
static float material_metal(const char *name)
{
    if (!name) return 0;
    if (strstr(name, "chrome") || strstr(name, "steel")) return 1;
    return strncmp(name, "materials/metal/", 16) ? 0 : 0.8f;
}
// PBRify maps by surface (materials/ left off): where each is, those loaded (while in use),
// and those loaded ahead (pbr_prefetch) until first asked for, with the ones being loaded.
// A surface's height map for the parallax (<name>_h.png beside its <name>_n.png, from
// tools/tex_height.py) goes in the same tables under "<name>#h".
static NSMutableDictionary<NSString *, NSString *> *pbr_paths;
static NSMapTable<NSString *, id<MTLTexture>> *pbr_loaded;
static NSMutableDictionary<NSString *, id<MTLTexture>> *pbr_ready;
static NSMutableSet<NSString *> *pbr_loading;
static os_unfair_lock pbr_lock = OS_UNFAIR_LOCK_INIT;

static void pbr_paths_load(void)
{
    if (pbr_paths) return;
    pbr_paths = [NSMutableDictionary dictionary];
    pbr_loaded = [NSMapTable strongToWeakObjectsMapTable];
    pbr_ready = [NSMutableDictionary dictionary], pbr_loading = [NSMutableSet set];
    char exe[1024];
    uint32_t n = sizeof exe;
    if (!_NSGetExecutablePath(exe, &n) && strrchr(exe, '/')) {
        *strrchr(exe, '/') = 0;  // build/tests
        NSString *root = [[@(exe) stringByAppendingPathComponent:@"../textures/maps"] stringByStandardizingPath];
        for (NSString *map in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
            NSString *dir = [root stringByAppendingPathComponent:map];
            for (NSString *rel in [NSFileManager.defaultManager enumeratorAtPath:dir])
                if ([rel hasSuffix:@"_n.png"])
                    pbr_paths[[rel substringToIndex:rel.length - 6]] = [dir stringByAppendingPathComponent:rel];
        }
        // Height maps: those beside the normal maps found.
        unsigned long heights = 0;
        for (NSString *key in pbr_paths.allKeys) {
            NSString *h = [[pbr_paths[key] substringToIndex:pbr_paths[key].length - 6] stringByAppendingString:@"_h.png"];
            if ([NSFileManager.defaultManager fileExistsAtPath:h]) pbr_paths[[key stringByAppendingString:@"#h"]] = h, heights++;
        }
        fprintf(stderr, "[metal] PBRify maps: %lu surfaces (%lu with height) in %s\n", (unsigned long)pbr_paths.count - heights,
                heights, root.UTF8String);
    }
}

static id<MTLTexture> pbr_load(id<MTLDevice> dev, NSString *key, NSString *path)
{
    return [key hasSuffix:@"#h"] ? bl_load_height_map(dev, path.UTF8String) : bl_load_normal_map(dev, path.UTF8String);
}

// The map `suffix` ("" the normal map, "#h" the height map) of the texture `name`.
static id<MTLTexture> pbr_map_of(const char *name, NSString *suffix)
{
    if (!env_pbr || !name || strncmp(name, "materials/", 10)) return nil;
    pbr_paths_load();
    NSString *key = [@(name + 10) stringByAppendingString:suffix];
    NSString *path = pbr_paths[key];
    if (!path) return nil;
    for (;;) {
        os_unfair_lock_lock(&pbr_lock);
        id<MTLTexture> t = [pbr_loaded objectForKey:key];
        if (!t && (t = pbr_ready[key])) [pbr_loaded setObject:t forKey:key], [pbr_ready removeObjectForKey:key];
        int busy = !t && [pbr_loading containsObject:key];
        os_unfair_lock_unlock(&pbr_lock);
        if (t) return t;
        if (!busy) break;
        usleep(200);
    }
    id<MTLTexture> t = pbr_load(mtl, key, path);
    os_unfair_lock_lock(&pbr_lock);
    if (t) [pbr_loaded setObject:t forKey:key];
    os_unfair_lock_unlock(&pbr_lock);
    return t;
}
static id<MTLTexture> pbr_map(const char *name) { return pbr_map_of(name, @""); }

// Starts loading the PBRify maps of a texture the game just filled, on another thread.
static void pbr_prefetch(uint32_t w, uint32_t h, uint32_t format, const uint8_t *data, uint32_t pitch)
{
    if (!env_pbr) return;
    pbr_paths_load();
    if (!pbr_paths.count) return;
    id<MTLDevice> dev = mtl;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const char *name = bl_tex_name_any_thread(w, h, format, data, pitch);
        if (!name || strncmp(name, "materials/", 10)) return;
        for (NSString *suffix in @[@"", @"#h"]) {
            NSString *key = [@(name + 10) stringByAppendingString:suffix], *path = pbr_paths[key];
            if (!path) continue;
            os_unfair_lock_lock(&pbr_lock);
            int skip = [pbr_loaded objectForKey:key] || pbr_ready[key] || [pbr_loading containsObject:key];
            if (!skip) [pbr_loading addObject:key];
            os_unfair_lock_unlock(&pbr_lock);
            if (skip) continue;
            id<MTLTexture> t = pbr_load(dev, key, path);
            os_unfair_lock_lock(&pbr_lock);
            [pbr_loading removeObject:key];
            if (t) pbr_ready[key] = t;
            os_unfair_lock_unlock(&pbr_lock);
        }
    });
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
        tex->gpu_scale = 1;
        if (rt && is_shadow_atlas(tex)) {
            shadow_atlas = tex;
            tex->gpu_scale = shadow_res_wanted();
            d.width *= (NSUInteger)tex->gpu_scale, d.height *= (NSUInteger)tex->gpu_scale;
            d.pixelFormat = shadow_format_wanted();
        }
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
        int top = tex->subs[0]->dirty;
        for (uint32_t f = 0; f < faces; f++)
            for (uint32_t l = 0; l < tex->levels; l++) {
                struct obj *s = tex->subs[f * tex->levels + l];
                if (s->dirty) upload_level(t, tf, s, f, l);
            }
        tex->dirty = 0;
        // An upscaled texture for what the game put in the top level (not for textures it
        // rewrites as it goes, D3DUSAGE_DYNAMIC).
        uint64_t t0 = hitch_now();
        if (top && tex->type == OBJ_TEXTURE && !(tex->usage & 0x200) && !env_upscale_off) {
            if (tex->hires) CFRelease(tex->hires);
            id<MTLTexture> h = bl_hires_texture(mtl, tex->width, tex->height, tex->format, bl_g2h(tex->subs[0]->mem),
                                                tex->subs[0]->pitch);
            tex->hires = h ? (__bridge_retained void *)h : NULL;
        }
        if (top && tex->type == OBJ_TEXTURE && !(tex->usage & 0x200)) {
            const char *name = bl_tex_name(tex->width, tex->height, tex->format, bl_g2h(tex->subs[0]->mem),
                                           tex->subs[0]->pitch);
            tex->gloss = material_gloss(name);
            tex->metal = material_metal(name);
            if (tex->pbr) CFRelease(tex->pbr);
            uint64_t t1 = hitch_now();
            id<MTLTexture> m = pbr_map(name);
            hitch_pbr_ns += hitch_now() - t1;
            tex->pbr = m ? (__bridge_retained void *)m : NULL;
            if (tex->pom) CFRelease(tex->pom);
            id<MTLTexture> hm = m && env_pom_depth > 0 ? pbr_map_of(name, @"#h") : nil;
            tex->pom = hm ? (__bridge_retained void *)hm : NULL;
        }
        hitch_tex_ns += hitch_now() - t0;
    }
    tex->used = 1;
    return tex->hires ? (__bridge id<MTLTexture>)tex->hires : t;
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
        o->gpu_scale = owner->gpu_scale;
    } else {
        // The device's own colour surfaces (the back buffer) keep 16 bits per channel
        // with deep colour, so the game's many blended passes (lightmaps, fog, decals)
        // do not band. The values still clamp to 0..1 like the 8-bit format they stand
        // for; reads and copies to 8-bit surfaces convert (as_bgra8, d3d_render_stretch).
        MTLPixelFormat pf = target_format(o->format);
        if (deep_color && pf == MTLPixelFormatBGRA8Unorm && owner && owner->type == OBJ_DEVICE)
            pf = MTLPixelFormatRGBA16Unorm;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                     width:o->width * obj_scale(o)
                                                                                    height:o->height * obj_scale(o)
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        t = [mtl newTextureWithDescriptor:d];
    }
    t.label = [NSString stringWithFormat:@"surface %ux%u fmt %u", o->width, o->height, o->format];
    o->gpu = (__bridge_retained void *)t;
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
    // For lightmap_for: pixel, the coordinate t<n> each of stages 0-7 reads as it is (-1
    // none); vertex, what each oT<n> is made from (d3d_shader_sample_coord, _lightmap_coord).
    int8_t lm_reg[8];
    int lm_known;
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

// A tessellated vertex shader's pre-pass (d3d9_shader.c), on its main function; and the
// pre-pass's pipeline, on the main pipeline.
static char tess_pre_key;

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
    opt.mathMode = MTLMathModeSafe;
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
    id<MTLFunction> f = [lib newFunctionWithName:@"bl_main"], pre = [lib newFunctionWithName:@"bl_pre"];
    if (pre) objc_setAssociatedObject(f, &tess_pre_key, pre, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return f;
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
    // With reflections on, the world's shaders draw with reflection info (setup_draw).
    effect_settings();
    if (sh->info.pixel && (env_ssr || env_sss) && !(sh->info.color_outputs & 2)) v.reflection_info = 1;
    if (sh->info.pixel && env_ssil && !(sh->info.color_outputs & 4)) v.albedo = 1;
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
static id<MTLRenderPipelineState> clear_pipeline(MTLPixelFormat color, MTLPixelFormat depth, uint32_t mask, int info);
static id<MTLRenderPipelineState> stretch_pipeline(MTLPixelFormat color);

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
    uint8_t info;    // reflection info attachment: 0 none, 1 kept, 2 written
    uint8_t albedo;  // the surfaces' colour attachment (albedo_texture), the same
    uint8_t surface; // the surfaces' facing and roughness attachment (surface_texture), the same
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
    // Tessellated (draw_patches): the main function reads the pre-pass's results instead.
    id<MTLFunction> pre = k->vsv.tess ? objc_getAssociatedObject(vs, &tess_pre_key) : nil;
    d.vertexDescriptor = pre ? nil : vd;
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
    if (k->info) {
        d.colorAttachments[1].pixelFormat = INFO_FORMAT;
        d.colorAttachments[1].writeMask = k->info == 2 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    }
    if (k->albedo) {
        d.colorAttachments[2].pixelFormat = ALBEDO_FORMAT;
        d.colorAttachments[2].writeMask = k->albedo == 2 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    }
    if (k->surface) {
        d.colorAttachments[3].pixelFormat = SURFACE_FORMAT;
        d.colorAttachments[3].writeMask = k->surface == 2 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    }
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k->depth_format;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->depth_format;
    d.inputPrimitiveTopology = k->point ? MTLPrimitiveTopologyClassPoint : MTLPrimitiveTopologyClassUnspecified;
    NSError *error = nil;
    uint64_t t0 = now_ns();
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    uint64_t dt = now_ns() - t0;
    build_ns[1] += dt, build_count[1]++, frame_build_ns += dt;
    if (!p) {
        fprintf(stderr, "[metal] pipeline failed, its draws are skipped: %s\n", error.localizedDescription.UTF8String);
        return nil;  // not cached: rare, and the log says each time
    }
    if (pre) {
        d.vertexFunction = pre, d.fragmentFunction = nil, d.vertexDescriptor = vd, d.rasterizationEnabled = NO;
        id<MTLRenderPipelineState> pp = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
        if (!pp) {
            fprintf(stderr, "[metal] pipeline failed, its draws are skipped: %s\n", error.localizedDescription.UTF8String);
            return nil;
        }
        objc_setAssociatedObject(p, &tess_pre_key, pp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    pipelines[key] = p;
    return p;
}

// Hair in two passes (env_hair_soft): first solid where its alpha is high, writing
// depth, then blended where it is lower (2 while setup_draw sets up that one), so its
// thin edges fade smoothly instead of being cut out.
static int hair_pass;

static id<MTLDepthStencilState> depth_state(struct d3d_state *s, int has_depth)
{
    const uint32_t *rs = s->rs;
    uint32_t k[16] = {0};
    if (has_depth) {
        k[0] = rs[7] ? 1 : 0;           // ZENABLE
        k[1] = rs[14] && hair_pass < 2;  // ZWRITEENABLE; not hair's blended passes
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
    d.supportArgumentBuffers = YES;  // for argument tables
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
    if (![mtl supportsFamily:MTLGPUFamilyMetal4]) bl_fatal("this Mac's GPU does not support Metal 4");
    queue = [mtl newMTL4CommandQueue];
    cmd = [mtl newCommandBuffer];
    in_flight = dispatch_semaphore_create(FRAMES_IN_FLIGHT);
    for (int i = 0; i < FRAMES_IN_FLIGHT; i++) chunks[i] = [NSMutableArray new], allocators[i] = [mtl newCommandAllocator];
    mtl4_setup(mtl, queue, upload);
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
    if (getenv("BL_HITCH")) env_hitch = atof(getenv("BL_HITCH"));
    env_prefetch_off = getenv("BL_PREFETCH") && !atoi(getenv("BL_PREFETCH"));
    env_shader_stats = getenv("BL_SHADER_STATS") != NULL;
    env_shader_early = !(getenv("BL_SHADER_EARLY") && !strcmp(getenv("BL_SHADER_EARLY"), "0"));
    env_aniso = getenv("BL_ANISO") ? atoi(getenv("BL_ANISO")) : 16;
    env_aniso = env_aniso < 1 ? 1 : env_aniso > 16 ? 16 : env_aniso;
    deep_color = !(getenv("BL_DEEP_COLOR") && !strcmp(getenv("BL_DEEP_COLOR"), "0"));
    env_widescreen = !(getenv("BL_WIDESCREEN") && !strcmp(getenv("BL_WIDESCREEN"), "stretch"));
    effect_settings();
    env_ao_radius = getenv("BL_AO_RADIUS") ? (float)atof(getenv("BL_AO_RADIUS")) : 32;
    env_ao_strength = getenv("BL_AO_STRENGTH") ? (float)atof(getenv("BL_AO_STRENGTH")) : 0.6f;
    env_ao_thickness = getenv("BL_AO_THICKNESS") ? (float)atof(getenv("BL_AO_THICKNESS")) : 16;
    env_pbr = getenv("BL_PBR") ? atoi(getenv("BL_PBR")) != 0 : 1;
    env_pbr_spec = getenv("BL_PBR_SPEC") ? (float)atof(getenv("BL_PBR_SPEC")) : 1.5f;
    env_pbr_bump = getenv("BL_PBR_BUMP") ? (float)atof(getenv("BL_PBR_BUMP")) : 1;
    env_pom_depth = getenv("BL_POM_DEPTH") ? (float)atof(getenv("BL_POM_DEPTH")) : 0.015f;
    env_pom_dist = getenv("BL_POM_DIST") ? (float)atof(getenv("BL_POM_DIST")) : 1500;
    env_ssr_strength = getenv("BL_SSR_STRENGTH") ? (float)atof(getenv("BL_SSR_STRENGTH")) : 1;
    env_ssr_fresnel = getenv("BL_SSR_FRESNEL") ? (float)atof(getenv("BL_SSR_FRESNEL")) : 3;
    env_ssr_blur = getenv("BL_SSR_BLUR") ? (float)atof(getenv("BL_SSR_BLUR")) : 0.02f;
    const char *tm = getenv("BL_TONEMAP");
    env_tonemap = !tm                   ? 0
                  : !strcmp(tm, "gt7")  ? 1
                  : !strcmp(tm, "gt7x") ? 2
                  : !strcmp(tm, "pbr")  ? 3
                  : !strcmp(tm, "pbrx") ? 4
                                        : 0;
    env_detail = !(getenv("BL_DETAIL") && !strcmp(getenv("BL_DETAIL"), "0"));
    if (getenv("BL_DETAIL_STRENGTH")) env_detail_strength = (float)atof(getenv("BL_DETAIL_STRENGTH"));
    if (getenv("BL_SHINE")) env_shine = (float)atof(getenv("BL_SHINE"));
    if (getenv("BL_CHARLIGHT")) env_charlight = (float)atof(getenv("BL_CHARLIGHT"));
    if (getenv("BL_GI_MIX")) env_gi_mix = (float)atof(getenv("BL_GI_MIX"));
    if (getenv("BL_GI_LOG")) env_gi_log = atoi(getenv("BL_GI_LOG"));
    if (getenv("BL_CHARLIGHT_MIN")) env_charlight_min = (float)atof(getenv("BL_CHARLIGHT_MIN"));
    env_hair_u = getenv("BL_HAIR_U") && atoi(getenv("BL_HAIR_U"));
    if (getenv("BL_HAIR_FADE")) env_hair_fade = (float)atof(getenv("BL_HAIR_FADE"));
    if (getenv("BL_TESS")) env_tess = atoi(getenv("BL_TESS"));
    if (getenv("BL_TESS_ROUND")) env_tess_round = (float)atof(getenv("BL_TESS_ROUND"));
    if (getenv("BL_SHARPEN_STRENGTH")) env_sharpen_strength = (float)atof(getenv("BL_SHARPEN_STRENGTH"));
    if (getenv("BL_SKIN_DETAIL_STRENGTH")) env_skin_detail_strength = (float)atof(getenv("BL_SKIN_DETAIL_STRENGTH"));
    if (getenv("BL_SKIN_DETAIL_SIZE")) env_skin_detail_size = (float)atof(getenv("BL_SKIN_DETAIL_SIZE"));
    if (getenv("BL_SKIN_DETAIL_BODY")) env_skin_detail_body = (float)atof(getenv("BL_SKIN_DETAIL_BODY"));
    env_cloth_detail = !(getenv("BL_CLOTH_DETAIL") && !strcmp(getenv("BL_CLOTH_DETAIL"), "0"));
    if (getenv("BL_CLOTH_DETAIL_STRENGTH")) env_cloth_detail_strength = (float)atof(getenv("BL_CLOTH_DETAIL_STRENGTH"));
    if (getenv("BL_CLOTH_DETAIL_SIZE")) env_cloth_detail_size = (float)atof(getenv("BL_CLOTH_DETAIL_SIZE"));
    if (getenv("BL_SKIN_DETAIL_MAX")) env_skin_detail_max = (float)atof(getenv("BL_SKIN_DETAIL_MAX"));
    if (getenv("BL_SKIN_DETAIL_MAX_BODY")) env_skin_detail_max_body = (float)atof(getenv("BL_SKIN_DETAIL_MAX_BODY"));
    if (getenv("BL_CLOTH_DETAIL_MAX")) env_cloth_detail_max = (float)atof(getenv("BL_CLOTH_DETAIL_MAX"));
    if (getenv("BL_PROP_TESS")) env_prop_tess = atoi(getenv("BL_PROP_TESS"));
    if (getenv("BL_LIGHTMAP_SMOOTH")) env_lightmap_smooth = atoi(getenv("BL_LIGHTMAP_SMOOTH"));
    if (getenv("BL_LIGHTMAP_SMOOTH_AT")) env_lightmap_at = atol(getenv("BL_LIGHTMAP_SMOOTH_AT"));
    if (getenv("BL_REBAKE")) env_rebake = atoi(getenv("BL_REBAKE"));
    if (getenv("BL_BLOOM_AT")) env_bloom_at = atol(getenv("BL_BLOOM_AT"));
    if (getenv("BL_SSIL_RADIUS")) env_ssil_radius = (float)atof(getenv("BL_SSIL_RADIUS"));
    if (getenv("BL_SSIL_STRENGTH")) env_ssil_strength = (float)atof(getenv("BL_SSIL_STRENGTH"));
    if (getenv("BL_SSIL_BLUR")) env_ssil_blur = atoi(getenv("BL_SSIL_BLUR"));
    if (getenv("BL_BLOOM_STRENGTH")) env_bloom_strength = (float)atof(getenv("BL_BLOOM_STRENGTH"));
    if (getenv("BL_BLOOM_THRESHOLD")) env_bloom_threshold = (float)atof(getenv("BL_BLOOM_THRESHOLD"));
    if (getenv("BL_EXPOSURE_RANGE")) sscanf(getenv("BL_EXPOSURE_RANGE"), "%f,%f", &env_exposure_lo, &env_exposure_hi);
    if (getenv("BL_HAIR_SOFT")) env_hair_soft = (float)atof(getenv("BL_HAIR_SOFT"));
    if (getenv("BL_HAIR_STRANDS")) env_hair_strands = (float)atof(getenv("BL_HAIR_STRANDS"));
    if (getenv("BL_HAIR_ROOT")) env_hair_root = (float)atof(getenv("BL_HAIR_ROOT"));
    if (getenv("BL_HAIR_GLOW")) env_hair_glow = (float)atof(getenv("BL_HAIR_GLOW"));
    if (getenv("BL_HAIR_MESH")) env_hair_mesh = atoi(getenv("BL_HAIR_MESH"));
    if (env_tess > 16) env_tess = 16;
    env_upscale_off = getenv("BL_UPSCALE") && !strcmp(getenv("BL_UPSCALE"), "0");
    env_remodel_off = getenv("BL_REMODEL") && !strcmp(getenv("BL_REMODEL"), "0");
    env_sss_eyes = !(getenv("BL_SSS_EYES") && !strcmp(getenv("BL_SSS_EYES"), "0"));
    env_tonemap_expand = getenv("BL_TONEMAP_EXPAND") ? (float)atof(getenv("BL_TONEMAP_EXPAND")) : 0.8f;
    env_hdr_peak = getenv("BL_HDR_PEAK") ? (float)atof(getenv("BL_HDR_PEAK")) : 4;
    env_hdr_knee = getenv("BL_HDR_KNEE") ? (float)atof(getenv("BL_HDR_KNEE")) : 0.05f;
    env_hdr_headroom = getenv("BL_HDR_HEADROOM") ? (float)atof(getenv("BL_HDR_HEADROOM")) : 0;
    env_fog_density = getenv("BL_FOG_DENSITY") ? (float)atof(getenv("BL_FOG_DENSITY")) : 0.0002f;
    env_fog_dist = getenv("BL_FOG_DIST") ? (float)atof(getenv("BL_FOG_DIST")) : 2000;
    env_sss_width = getenv("BL_SSS_WIDTH") ? (float)atof(getenv("BL_SSS_WIDTH")) : 0.8f;
    env_sss_strength = getenv("BL_SSS_STRENGTH") ? (float)atof(getenv("BL_SSS_STRENGTH")) : 0.8f;
    env_sss_sheen = getenv("BL_SSS_SHEEN") ? (float)atof(getenv("BL_SSS_SHEEN")) : 3;
    shadow_settings();
}

// One Metal 4 command buffer, begun on the frame slot's allocator when first needed and
// committed at the end of the frame (or early, to read a target back). Each allocator is
// reset once the GPU has finished the frame that last used it (next_frame).
static int cmd_open;

static id<MTL4CommandBuffer> command_buffer(void)
{
    if (!cmd_open) [cmd beginCommandBufferWithAllocator:allocators[frame_slot]], cmd_open = 1;
    return cmd;
}

static void end_pass(void);

// Ends the open passes and commits (an empty command buffer if nothing was drawn, so
// the options' handlers still run).
static void commit(MTL4CommitOptions *options)
{
    end_pass();
    [command_buffer() endCommandBuffer];
    cmd_open = 0;
    mtl4_before_commit();
    id<MTL4CommandBuffer> list[1] = {cmd};
    if (options) [queue commit:list count:1 options:options];
    else [queue commit:list count:1];
}

// BL_GPU_STATS=2: GPU time per pass, summed by the function that began it, logged every
// 100 frames (GPU timestamps at the start and end of each pass; passes can overlap, so
// the parts may add up to more than the frame).
static int gpu_pass_stats = -1;
static id<MTL4CounterHeap> pass_heaps[FRAMES_IN_FLIGHT];
static const char *pass_names[FRAMES_IN_FLIGHT][512];
static int pass_count[FRAMES_IN_FLIGHT];
static double gpu_tick_ns = 1;  // ns per GPU timestamp tick

static int pass_stats_on(void)
{
    if (gpu_pass_stats < 0) {
        const char *e = getenv("BL_GPU_STATS");
        gpu_pass_stats = e && atoi(e) == 2;
        if (gpu_pass_stats) {
            MTL4CounterHeapDescriptor *d = [MTL4CounterHeapDescriptor new];
            d.type = MTL4CounterHeapTypeTimestamp, d.count = 2 * 512;
            for (int i = 0; i < FRAMES_IN_FLIGHT; i++) pass_heaps[i] = [mtl newCounterHeapWithDescriptor:d error:nil];
            gpu_tick_ns = 1e9 / (double)[mtl queryTimestampFrequency];
            fprintf(stderr, "[gpu] %.4f ns a timestamp tick\n", gpu_tick_ns);
        }
    }
    return gpu_pass_stats;
}

// The pass's pair of timestamps in this frame's heap (-1: none).
static NSInteger pass_stat(const char *name)
{
    if (!pass_stats_on() || pass_count[frame_slot] >= 512) return -1;
    int n = pass_count[frame_slot]++;
    pass_names[frame_slot][n] = name;
    return n;
}

static BLRender *stat_render(MTL4RenderPassDescriptor *d, const char *name)
{
    for (int i = 0; i < 4; i++) mtl4_track(d.colorAttachments[i].texture);
    mtl4_track(d.depthAttachment.texture), mtl4_track(d.stencilAttachment.texture);
    NSInteger n = pass_stat(name);
    return [[BLRender alloc] initWithEncoder:[command_buffer() renderCommandEncoderWithDescriptor:d]
                                        heap:pass_heaps[frame_slot] stat:n];
}

// A compute pass, also used for copies (Metal 4 has no blit passes).
static BLCompute *stat_compute(const char *name)
{
    NSInteger n = pass_stat(name);
    return [[BLCompute alloc] initWithEncoder:[command_buffer() computeCommandEncoder] heap:pass_heaps[frame_slot]
                                         stat:n];
}

// At the end of a frame's GPU work: its passes' times, added up by name.
static void pass_stats_done(int slot, unsigned long frame)
{
    static NSMutableDictionary<NSString *, NSNumber *> *sum;
    static int nframes;
    if (!sum) sum = [NSMutableDictionary dictionary];
    int n = pass_count[slot];
    NSData *r = n ? [pass_heaps[slot] resolveCounterRange:NSMakeRange(0, 2 * (NSUInteger)n)] : nil;
    const MTL4TimestampHeapEntry *t = r.bytes;
    // Passes overlap (one's vertex stage starts while the last one's fragments run), so
    // each is charged from the end of the one before it (or its own start, after a gap)
    // to its end: the parts add up to the frame.
    uint64_t prev_end = 0;
    for (int i = 0; t && i < n; i++) {
        uint64_t lo = t[2 * i].timestamp, hi = t[2 * i + 1].timestamp;
        if (!lo || hi <= lo) continue;
        if (prev_end > lo) lo = prev_end < hi ? prev_end : hi;
        prev_end = hi > prev_end ? hi : prev_end;
        NSString *k = @(pass_names[slot][i]);
        sum[k] = @(sum[k].doubleValue + (double)(hi - lo) * gpu_tick_ns / 1e6);
    }
    if (++nframes == 100) {
        NSArray *keys = [sum keysSortedByValueUsingComparator:^(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
        fprintf(stderr, "[gpu] passes, ms a frame (to frame %lu):", frame);
        for (NSString *k in keys) fprintf(stderr, " %s %.2f", k.UTF8String, sum[k].doubleValue / 100);
        fprintf(stderr, "\n");
        [sum removeAllObjects], nframes = 0;
    }
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

// Reflection info drawn by the world view's shaders (d3d_shader_variant reflection_info),
// the back buffer's size.
static unsigned long info_frame = ~0ul;  // the frame it was last drawn in
static id<MTLTexture> info_texture(id<MTLTexture> color)
{
    static id<MTLTexture> t;
    if (!t || t.width != color.width || t.height != color.height) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:INFO_FORMAT
                                                                                     width:color.width
                                                                                    height:color.height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t = [mtl newTextureWithDescriptor:td];
        t.label = @"reflection info";
    }
    return t;
}

// The surfaces' own colour (d3d_shader_variant albedo), drawn by the world view's shaders
// for the bounced light, the back buffer's size; alpha 0 where nothing was drawn.
static unsigned long albedo_frame = ~0ul;  // the frame it was last drawn in
static id<MTLTexture> albedo_texture(id<MTLTexture> color)
{
    static id<MTLTexture> t;
    if (!t || t.width != color.width || t.height != color.height) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ALBEDO_FORMAT
                                                                                     width:color.width
                                                                                    height:color.height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t = [mtl newTextureWithDescriptor:td];
        t.label = @"surface colour";
    }
    return t;
}

// The surfaces' facing (view space) and roughness (-1 unknown) drawn by the world view's
// shaders (d3d_shader_variant surface) for the reflections, the back buffer's size; 0
// where nothing was drawn.
static unsigned long surface_frame = ~0ul;  // the frame it was last drawn in
static id<MTLTexture> surface_texture(id<MTLTexture> color)
{
    static id<MTLTexture> t;
    if (!t || t.width != color.width || t.height != color.height) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:SURFACE_FORMAT
                                                                                     width:color.width
                                                                                    height:color.height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t = [mtl newTextureWithDescriptor:td];
        t.label = @"surface facing";
    }
    return t;
}

static id<MTLTexture> hdr_world;
static unsigned long hdr_world_frame;

static BLRender *pass(struct d3d_state *s)
{
    struct obj *color = s->render_target[0], *depth = s->depth_stencil;
    if (enc && enc_color == color && enc_depth == depth) return enc;
    end_pass();
    shadow_match_depth(color, depth);
    if (color && color != s->back_buffer) last_offscreen_target = color;
    MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new];
    if (color) {
        d.colorAttachments[0].texture = target_texture(color);
        d.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (clear_color_target == color) {
            d.colorAttachments[0].loadAction = MTLLoadActionClear;
            d.colorAttachments[0].clearColor = clear_color;
            clear_color_target = NULL;
        } else {
            d.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
    }
    if (depth) {
        id<MTLTexture> t = target_texture(depth);
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
    // The world view's passes on the back buffer also draw reflection info (post_run),
    // cleared with the frame's first one or with the colour; with skin scattering it also
    // marks what characters drew (d3d_shader_variant skin).
    int info = (env_ssr || env_sss || contact_on()) && color && color == s->back_buffer && !menu_frame &&
               view_state != 2;
    if (info) {
        id<MTLTexture> ct = target_texture(color);
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[1];
        a.texture = info_texture(ct);
        a.storeAction = MTLStoreActionStore;
        int fresh = info_frame != frames || d.colorAttachments[0].loadAction == MTLLoadActionClear;
        a.loadAction = fresh ? MTLLoadActionClear : MTLLoadActionLoad;
        a.clearColor = MTLClearColorMake(0, 0, 0, 0);
        info_frame = frames;
    }
    // And the surfaces' colour, for the bounced light, cleared the same way.
    int albedo = env_ssil && color && color == s->back_buffer && !menu_frame && view_state != 2;
    if (albedo) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[2];
        a.texture = albedo_texture(target_texture(color));
        a.storeAction = MTLStoreActionStore;
        int fresh = albedo_frame != frames || d.colorAttachments[0].loadAction == MTLLoadActionClear;
        a.loadAction = fresh ? MTLLoadActionClear : MTLLoadActionLoad;
        a.clearColor = MTLClearColorMake(0, 0, 0, 0);
        albedo_frame = frames;
    }
    // And the surfaces' facing and roughness, for the reflections, cleared the same way.
    int surface = info && env_ssr && env_pbr;
    if (surface) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[3];
        a.texture = surface_texture(target_texture(color));
        a.storeAction = MTLStoreActionStore;
        int fresh = surface_frame != frames || d.colorAttachments[0].loadAction == MTLLoadActionClear;
        a.loadAction = fresh ? MTLLoadActionClear : MTLLoadActionLoad;
        a.clearColor = MTLClearColorMake(0, 0, 0, 0);
        surface_frame = frames;
    }
    enc = stat_render(d, __func__);
    enc_color = color, enc_depth = depth, enc_info = info, enc_albedo = albedo, enc_surface = surface;
    int world_end = (post_result || ao_result || contact_result) && color && color == s->back_buffer;
    if (post_result && color && color == s->back_buffer) post_apply(enc, target_texture(color), depth != NULL);
    if (ao_result && color && color == s->back_buffer) ao_apply(enc, target_texture(color), depth != NULL);
    if (contact_result && color && color == s->back_buffer)
        contact_apply(enc, target_texture(color), depth != NULL);
    if (taa_pending && color && color == s->back_buffer) {
        // The world view with its effects drawn in, before the view model and HUD:
        // through the temporal scaler and back.
        [enc endEncoding];
        taa_resolve(target_texture(color));
        taa_pending = 0;
        d.colorAttachments[0].loadAction = MTLLoadActionLoad;
        d.depthAttachment.loadAction = d.stencilAttachment.loadAction = MTLLoadActionLoad;
        if (info) d.colorAttachments[1].loadAction = MTLLoadActionLoad;
        enc = stat_render(d, __func__);
    }
    if (world_end && env_hdr) {
        // A copy of the finished world view, before the view model and HUD: what
        // hdr_present may brighten.
        [enc endEncoding];
        id<MTLTexture> ct = target_texture(color);
        hdr_world = ao_texture(7, ct.pixelFormat, ct.width, ct.height);
        BLCompute *blit = stat_compute(__func__);
        [blit copyFromTexture:ct toTexture:hdr_world];
        [blit endEncoding];
        hdr_world_frame = frames;
        d.colorAttachments[0].loadAction = MTLLoadActionLoad;
        d.depthAttachment.loadAction = d.stencilAttachment.loadAction = MTLLoadActionLoad;
        if (info) d.colorAttachments[1].loadAction = MTLLoadActionLoad;
        enc = stat_render(d, __func__);
    }
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

static NSMutableSet<NSNumber *> *dead_buffers;  // serials of buffers freed since the last swaps_forget

// The game destroyed `o`: what the caches remember of it goes (its serial is never used
// again, so nothing would find it; this frees the memory).
void d3d_render_forget(struct obj *o)
{
    if (o->type == OBJ_TEXTURE || o->type == OBJ_CUBETEXTURE)
        bl_detail_forget(o->serial, o->width, o->height);
    else if (o->type == OBJ_VERTEXBUFFER || o->type == OBJ_INDEXBUFFER) {
        if (!dead_buffers) dead_buffers = [NSMutableSet new];
        [dead_buffers addObject:@(o->serial)];
    }
}

static void lightmap_forget(struct obj *o);
void d3d_render_free(struct obj *o)
{
    if (o->hires) CFRelease(o->hires), o->hires = NULL;
    if (o->pbr) CFRelease(o->pbr), o->pbr = NULL;
    if (o->pom) CFRelease(o->pom), o->pom = NULL;
    if (!o->gpu) return;
    id t = (__bridge_transfer id)o->gpu;  // released when t goes out of scope
    (void)t;
    o->gpu = NULL;
    if (enc_color == o || enc_depth == o) end_pass();
    if (clear_color_target == o) clear_color_target = NULL;
    if (clear_depth_target == o) clear_depth_target = NULL;
    if (shadow_atlas == o) shadow_atlas = NULL;
    lightmap_forget(o);
}

// Full screen when the game asks for it (no -window), unless BL_FULLSCREEN says otherwise.
static int game_windowed = 1;
static int full_screen(void)
{
    const char *f = getenv("BL_FULLSCREEN");
    return f && *f ? f[0] != '0' : !game_windowed;
}

static uint32_t game_window;

// The window's pixels: sRGB, or with HDR (hdr_present) linear values, 1 at normal white
// and above it up to the screen's headroom. Switched when the HDR box changes.
static int layer_hdr = -1;
static void layer_format(void)
{
    if (!layer || layer_hdr == env_hdr) return;
    layer_hdr = env_hdr;
    // The game's colours are sRGB. Without a colour space the compositor shows them
    // unconverted, too saturated on a wide-gamut (P3) screen.
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(env_hdr ? kCGColorSpaceExtendedLinearSRGB : kCGColorSpaceSRGB);
    layer.pixelFormat = env_hdr ? MTLPixelFormatRGBA16Float : deep_color ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm;
    layer.colorspace = cs;
    layer.wantsExtendedDynamicRangeContent = env_hdr != 0;
    CGColorSpaceRelease(cs);
}

void d3d_render_init(uint32_t window)
{
    ensure_device();
    game_window = window;
    if (getenv("BL_WINDOW")) {
        uint32_t w = resized_w ? resized_w : 1024, h = resized_h ? resized_h : 768;
        layer = bl_cocoa_open_window(w, h, "Vampire: The Masquerade – Bloodlines", window);
        if (layer) {
            layer.device = mtl;
            [queue addResidencySet:layer.residencySet];
            layer_format();
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
static void set_viewport(struct d3d_state *s, BLRender *e, uint32_t tw, uint32_t th, float squeeze)
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
    int sc = obj_scale(s->render_target[0]);
    if (sc > 1) {  // the shadow atlas, drawn larger than the game made it
        [e setViewport:(MTLViewport){(double)vp[0] * sc, (double)vp[1] * sc, (double)vp[2] * sc, (double)vp[3] * sc,
                                     u2f(vp[4]), u2f(vp[5])}];
        x0 *= sc, y0 *= sc, x1 *= sc, y1 *= sc;
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
    if (draw_stats && (long)frames >= draw_stats_frame && (long)frames < draw_stats_frame + draw_stats_count)
        fprintf(stderr, "[clear] rt %ux%u count %u flags %#x color %#x vp %u,%u %ux%u\n", rt->width, rt->height, count, flags,
                color, s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3]);
    // A depth clear after a view (a sky box drawn first) starts over: the occlusion is
    // for the view drawn after it.
    if ((flags & 2) && ds && view_state == 1) view_state = 0;
    if ((flags & 2) && ds && rt == s->back_buffer && view_state != 2) taa_forget_camera();
    const uint32_t *vp = s->viewport;
    int full = count == 0 && vp[0] == 0 && vp[1] == 0 && vp[2] >= rt->width && vp[3] >= rt->height &&
               (!s->rs[174] || (s->scissor[0] == 0 && s->scissor[1] == 0 && s->scissor[2] >= rt->width &&
                                s->scissor[3] >= rt->height));
    if (rt->owner && rt->owner == shadow_atlas && pcss_on()) color &= 0xFFFFFF;  // alpha: no caster (shadows)
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
    BLRender *e = pass(s);
    id<MTLTexture> t = target_texture(rt);
    MTLPixelFormat dfmt = ds ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    uint32_t mask = (flags & 1 ? 1u : 0u) | (flags & 2 && ds ? 2u : 0u) | (flags & 4 && ds ? 4u : 0u);
    if (!mask) return;
    [e setRenderPipelineState:clear_pipeline(t.pixelFormat, dfmt, mask, enc_info | enc_albedo << 1 | enc_surface << 2)];
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
        int sc = obj_scale(rt);
        x0 *= sc, y0 *= sc, x1 *= sc, y1 *= sc;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > (int32_t)t.width) x1 = (int32_t)t.width;
        if (y1 > (int32_t)t.height) y1 = (int32_t)t.height;
        if (x1 <= x0 || y1 <= y0) continue;
        [e setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
}

static id<MTLRenderPipelineState> clear_pipeline(MTLPixelFormat color, MTLPixelFormat depth, uint32_t mask, int info)
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
    NSString *key = [NSString stringWithFormat:@"%lu/%lu/%u/%d", (unsigned long)color, (unsigned long)depth, mask, info];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"clear_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"clear_fs"];
    d.colorAttachments[0].pixelFormat = color;
    d.colorAttachments[0].writeMask = mask & 1 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    // info: bit 0 the reflection info attachment, bit 1 the surfaces' colour.
    if (info & 1) d.colorAttachments[1].pixelFormat = INFO_FORMAT, d.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
    if (info & 2) d.colorAttachments[2].pixelFormat = ALBEDO_FORMAT, d.colorAttachments[2].writeMask = MTLColorWriteMaskNone;
    if (info & 4) d.colorAttachments[3].pixelFormat = SURFACE_FORMAT, d.colorAttachments[3].writeMask = MTLColorWriteMaskNone;
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
static id<MTLRenderPipelineState> stretch_pipeline(MTLPixelFormat color)
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
    NSNumber *key = @(color);
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"stretch_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"stretch_fs"];
    d.colorAttachments[0].pixelFormat = color;
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
        BLCompute *blit = stat_compute(__func__);
        [blit copyFromTexture:a toTexture:copy];
        [blit endEncoding];
        a = copy;
    }
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = b;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:stretch_pipeline(b.pixelFormat)];
    [e setViewport:(MTLViewport){dr[0], dr[1], dr[2] - dr[0], dr[3] - dr[1], 0, 1}];
    float p[4] = {(float)sr[0] / a.width, (float)sr[1] / a.height, (float)sr[2] / a.width, (float)sr[3] / a.height};
    [e setVertexBytes:p length:sizeof p atIndex:0];
    [e setFragmentTexture:a atIndex:0];
    static id<MTLSamplerState> samp[2];
    if (!samp[linear]) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.supportArgumentBuffers = YES;
        samp[linear] = [mtl newSamplerStateWithDescriptor:sd];
    }
    [e setFragmentSamplerState:samp[linear] atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// --- shadows -----------------------------------------------------------------------------
//
// Bloodlines draws the shadows of characters and moving props into one 1024x1024 render
// target, each caster in a 128x128 or 256x256 viewport seen from its light, and then
// projects that atlas onto the surfaces under them, which darken by it. With BL_SHADOWS
// (the options' "Shadows" box):
//  - the atlas's Metal texture is BL_SHADOW_RES times the size (default 4). Draws into it
//    get their viewports, scissors and clears scaled to match (set_viewport,
//    d3d_render_clear); the receivers sample it with normalized coordinates and need no
//    change. A change of the setting redraws the old contents into the new texture.
//  - percentage-closer soft shadows where the receivers read the atlas (BL_PCSS, default
//    on): crisp where a shadow meets its caster, softer further from it. The receivers'
//    pixel shaders average five taps around the shadow's texel; their variant
//    shadow_receiver turns those reads into one lookup, bl_shadow_soft in d3d9_shader.c.
//    That needs the casters' depth, which the atlas does not keep: casters (variant
//    shadow_caster) write 1 - depth to the atlas's alpha, which the receivers never
//    write out, keeping the nearest (blend MAX); the atlas's clears leave alpha at 0.
//    Each caster's light-space depth row comes from its draw's constants, per 128-texel
//    cell of the atlas it covers (shadow_cells). Cells shared by small casters (blobs,
//    distant characters), casters drawn with a perspective projection and cells not seen
//    yet keep the game's own lookup.
static int env_shadow_res = 4, env_pcss = 1, env_pcss_show, env_contact = 1, env_contact_show;
static float env_pcss_soft = 0.03f, env_pcss_max = 4, env_pcss_search = 3;
static float env_contact_length = 12, env_contact_strength = 0.5f;
static struct d3d_shadow_cell shadow_cells[64];

static int is_shadow_atlas(const struct obj *tex)
{
    return tex && tex->type == OBJ_TEXTURE && (tex->usage & 1) && tex->width == 1024 && tex->height == 1024 &&
           tex->format == 21;  // A8R8G8B8
}

static int shadow_res_wanted(void) { return env_shadows ? env_shadow_res : 1; }

// With shadows the atlas keeps 16 bits a channel: its alpha holds the casters' depth, whose
// range is thousands of world units.
static MTLPixelFormat shadow_format_wanted(void)
{
    return env_shadows ? MTLPixelFormatRGBA16Unorm : MTLPixelFormatBGRA8Unorm;
}

static int obj_scale(const struct obj *o) { return o && o->gpu_scale > 1 ? o->gpu_scale : 1; }

static void shadow_settings(void)
{
    const char *r = getenv("BL_SHADOW_RES");
    if (r) env_shadow_res = atoi(r);
    env_shadow_res = env_shadow_res < 1 ? 1 : env_shadow_res > 4 ? 4 : env_shadow_res;
    if (getenv("BL_PCSS")) env_pcss = atoi(getenv("BL_PCSS")) != 0 || !strcmp(getenv("BL_PCSS"), "show");
    env_pcss_show = getenv("BL_PCSS") && !strcmp(getenv("BL_PCSS"), "show");
    if (env_pcss_show) env_pcss = 1;
    if (getenv("BL_PCSS_SOFT")) env_pcss_soft = (float)atof(getenv("BL_PCSS_SOFT"));
    if (getenv("BL_PCSS_MAX")) env_pcss_max = (float)atof(getenv("BL_PCSS_MAX"));
    if (getenv("BL_PCSS_SEARCH")) env_pcss_search = (float)atof(getenv("BL_PCSS_SEARCH"));
    const char *c = getenv("BL_CONTACT");
    if (c) env_contact = atoi(c) != 0 || !strcmp(c, "show"), env_contact_show = !strcmp(c, "show");
    if (getenv("BL_CONTACT_LENGTH")) env_contact_length = (float)atof(getenv("BL_CONTACT_LENGTH"));
    if (getenv("BL_CONTACT_STRENGTH")) env_contact_strength = (float)atof(getenv("BL_CONTACT_STRENGTH"));
    env_contact_strength = env_contact_strength < 0 ? 0 : env_contact_strength > 1 ? 1 : env_contact_strength;
}

static int pcss_on(void) { return env_shadows && env_pcss && shadow_atlas; }
static int contact_on(void) { return env_shadows && env_contact; }

static int draws_to_atlas(const struct d3d_state *s)
{
    return shadow_atlas && s->render_target[0] && s->render_target[0]->owner == shadow_atlas;
}

// The shader variant and blending of casters and receivers (setup_draw).
static void shadow_variant(const struct d3d_state *s, BLShader *ps, struct pipe_key *k)
{
    if (!pcss_on()) return;
    if (draws_to_atlas(s)) {
        if (!s->vs) return;
        // Alpha keeps whichever of depth and 1 - depth is larger nearer the light: the
        // game's shadow projections have depth growing up or down. (Lights are above.)
        k->psv.shadow_caster = u2f(s->vs_f[10][2]) > 0 ? 2 : 1;
        k->write_mask |= 8;
        if (!k->blend[0]) k->blend[0] = 1, k->blend[1] = 2, k->blend[2] = 1, k->blend[3] = 1;  // ONE, ZERO, ADD
        k->blend[4] = 2, k->blend[5] = 2, k->blend[6] = 5;  // alpha: ONE, ONE, MAX
        return;
    }
    if (!ps->code) return;
    for (uint32_t i = 0; i < 8; i++)
        if ((ps->info.sampler_mask & (1u << i)) && s->texture[i] == shadow_atlas) k->psv.shadow_receiver |= 1u << i;
}

static int invert4(const float m[4][4], float out[4][4])
{
    float a[4][8];
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 8; j++) a[i][j] = j < 4 ? m[i][j] : (j - 4 == i);
    for (int c = 0; c < 4; c++) {
        int p = c;
        for (int i = c + 1; i < 4; i++)
            if (fabsf(a[i][c]) > fabsf(a[p][c])) p = i;
        if (fabsf(a[p][c]) < 1e-12f) return 0;
        for (int j = 0; j < 8; j++) {
            float t = a[c][j];
            a[c][j] = a[p][j], a[p][j] = t;
        }
        float d = 1 / a[c][c];
        for (int j = 0; j < 8; j++) a[c][j] *= d;
        for (int i = 0; i < 4; i++) {
            if (i == c) continue;
            float f = a[i][c];
            for (int j = 0; j < 8; j++) a[i][j] -= f * a[c][j];
        }
    }
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) out[i][j] = a[i][j + 4];
    return 1;
}

// After the constants (`r`: the rows taking world positions to clip space): a caster
// notes its cells, a receiver gets the lookup's parameters.
static void shadow_draw(const struct d3d_state *s, BLRender *e, const struct pipe_key *k,
                        const float (*r)[4], const struct d3d_vs_params *vp)
{
    const uint32_t *v = s->viewport;
    if (draws_to_atlas(s)) {
        float aw = (float)shadow_atlas->width, ah = (float)shadow_atlas->height;
        float lz = sqrtf(r[2][0] * r[2][0] + r[2][1] * r[2][1] + r[2][2] * r[2][2]);
        float lx = sqrtf(r[0][0] * r[0][0] + r[0][1] * r[0][1] + r[0][2] * r[0][2]);
        int ortho = fabsf(r[3][0]) + fabsf(r[3][1]) + fabsf(r[3][2]) < 1e-6f && fabsf(r[3][3] - 1) < 1e-4f;
        struct d3d_shadow_cell c = {
            {r[2][0], r[2][1], r[2][2], r[2][3]},
            {v[0] / aw, v[1] / ah, (v[0] + v[2]) / aw, (v[1] + v[3]) / ah},
            {lz > 0 ? 1 / lz : 0, lx * 0.5f * v[2] / aw, ortho && lz > 0 && s->vs && v[2] >= 128 && v[3] >= 128,
             r[2][2] > 0}};
        for (uint32_t y = v[1] / 128; y < 8 && y * 128 < v[1] + v[3]; y++)
            for (uint32_t x = v[0] / 128; x < 8 && x * 128 < v[0] + v[2]; x++) shadow_cells[y * 8 + x] = c;
        return;
    }
    if (!k->psv.shadow_receiver) return;
    struct d3d_shadow_params p;
    memset(&p, 0, sizeof p);
    if (!invert4(r, p.inv)) return;  // shadow_cells' k.z stays: the game's lookup below
    p.vp[0] = (float)v[0], p.vp[1] = (float)v[1];
    p.vp[2] = v[2] ? 1.0f / v[2] : 0, p.vp[3] = v[3] ? 1.0f / v[3] : 0;
    p.ndc[0] = vp->clip_y, p.ndc[1] = vp->inv_viewport[0], p.ndc[2] = vp->inv_viewport[1], p.ndc[3] = env_pcss_soft;
    p.lim[0] = 0.75f / shadow_atlas->width, p.lim[1] = env_pcss_max, p.lim[2] = env_pcss_search;
    p.lim[3] = 0.5f / (shadow_atlas->width * (float)obj_scale(shadow_atlas));
    memcpy(p.cell, shadow_cells, sizeof p.cell);
    p.show[0] = (float)env_pcss_show;
    [e setFragmentBytes:&p length:sizeof p atIndex:2];
}

// Once a frame, between frames: the atlas at the scale the setting asks for.
static void shadow_frame_start(void)
{
    // BL_SHADOWS_AB=n: the setting flips every n frames (before/after pictures and timings).
    static long ab = -1;
    if (ab < 0) ab = getenv("BL_SHADOWS_AB") ? atol(getenv("BL_SHADOWS_AB")) : 0;
    if (ab > 0 && ((long)frames + 1) % ab == 0) {
        env_shadows = !env_shadows;
        fprintf(stderr, "[shadows] %s at frame %lu\n", env_shadows ? "on" : "off", frames + 1);
    }
    struct obj *t = shadow_atlas;
    if (!t || !t->gpu || (obj_scale(t) == shadow_res_wanted() &&
                          ((__bridge id<MTLTexture>)t->gpu).pixelFormat == shadow_format_wanted()))
        return;
    end_pass();
    id<MTLTexture> old = (__bridge id<MTLTexture>)t->gpu;
    for (uint32_t i = 0; i < t->nsubs; i++) d3d_render_free(t->subs[i]);
    d3d_render_free(t);  // `old` keeps the texture until it is copied
    id<MTLTexture> n = texture_of(t);
    uint32_t sr[4] = {0, 0, (uint32_t)old.width, (uint32_t)old.height}, dr[4] = {0, 0, (uint32_t)n.width, (uint32_t)n.height};
    stretch_draw(old, sr, n, dr, 1);
    fprintf(stderr, "[shadows] atlas now %lux%lu\n", (unsigned long)n.width, (unsigned long)n.height);
}

// The depth surface the game draws the atlas with is scaled with it: a pass covers only
// what all its targets cover.
static void shadow_match_depth(struct obj *color, struct obj *depth)
{
    // The atlas's Metal texture, and the scale its levels take from it, may not be made
    // yet: the scale it will have.
    int sc = color && color->owner && is_shadow_atlas(color->owner) ? shadow_res_wanted() : obj_scale(color);
    if (!color || !depth || sc == obj_scale(depth) || depth->width != color->width ||
        depth->height != color->height || (depth->owner && depth->owner->type == OBJ_DEVICE))
        return;
    if (depth->gpu) {
        id t = (__bridge_transfer id)depth->gpu;  // released when t goes out of scope
        (void)t;
        depth->gpu = NULL;
    }
    depth->gpu_scale = sc;
}

// Whether a draw samples the atlas: a shadow receiver.
static int draw_reads_atlas(const struct d3d_state *s)
{
    if (!shadow_atlas) return 0;
    for (int i = 0; i < 8; i++)
        if (s->texture[i] == shadow_atlas) return 1;
    return 0;
}

// --- ambient occlusion -------------------------------------------------------------------
//
// Ground-truth ambient occlusion (Jimenez et al. 2016, as in Intel's XeGTAO) from the
// back buffer's depth, once the world is drawn and before the view model and HUD
// (post_before_draw). The depth is turned back into view-space positions with the world
// view's projection, taken from its draws (note_projection). The passes, all but the last
// at half resolution: view depth from the depth buffer, and 4 smaller copies of it, each
// pixel a weighted average of 4 that leans to the farthest (XeGTAO's depth filter), which
// the longer steps read so that they land on stable values; the occlusion, 3 slices of 6
// steps a side whose angles and offsets follow a 4x4 pattern; a depth-aware 4x4 filter
// that averages the pattern out; and, at full resolution, a depth-aware upsample that
// multiplies the image by the result. The occlusion uses visibility bitmasks (Therrien,
// Levesque and Gilet 2023) in place of GTAO's two horizons: each slice's half circle
// around the normal is 32 sectors, spaced so that each carries the same share of
// cosine-weighted light, and every sample, taken to be BL_AO_THICKNESS deep, blocks only
// the sectors between its front and its back. Light then gets in behind thin things
// (railings, an arm) instead of the wall behind them darkening as if they were solid all
// the way back. BL_AO=1 turns it on, BL_AO=show shows the occlusion alone; BL_AO_RADIUS
// (world units, default 32), BL_AO_THICKNESS (world units, default 16) and BL_AO_STRENGTH
// (default 0.6) tune it.

struct ao_params {
    float full[2], half[2];  // back buffer and half-resolution sizes
    float alpha, beta;       // depth d = alpha + beta / w
    float p00, p11;          // projection scales in x and y
    float radius, inv_radius2;
    float max_px, strength;  // max_px: largest radius in half-resolution pixels
    float thickness;         // how deep each sample is taken to be (world units)
    float mip_offset;        // steps longer than 2^this half-resolution pixels read the smaller depth copies
};

static NSString *const ao_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct AOP { float2 full, hsize; float alpha, beta, p00, p11, radius, inv_radius2, max_px, strength, thickness, mip_offset; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V ao_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     // View depth, 0 for the sky (cleared depth) and anything not drawn.
     "static float lin(constant AOP &a, float d) { return d >= 0.99999 || d <= 0.0 ? 0.0 : a.beta / (d - a.alpha); }\n"
     "fragment float ao_depth(V in [[stage_in]], depth2d<float> dt [[texture(0)]], constant AOP &a [[buffer(0)]]) {\n"
     "    uint2 p = min(uint2(in.pos.xy) * 2, uint2(a.full) - 1); return lin(a, dt.read(p)); }\n"
     "static float3 vpos(constant AOP &a, texture2d<float> zt, int2 p) {\n"
     "    p = clamp(p, int2(0), int2(a.hsize) - 1);\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    if (w <= 0.0) w = 1e6;\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.hsize.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.hsize.y);\n"
     "    return float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w); }\n"
          // A smaller copy of the view depth: of each 2x2, an average weighted to the
     // farthest, leaving out what is much nearer (the edge of something in front). The
     // sky (0 at the top level) counts as very far.
     "fragment float ao_mip(V in [[stage_in]], texture2d<float> src [[texture(0)]], constant AOP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy) * 2, m = int2(src.get_width(), src.get_height()) - 1;\n"
     "    float4 d = float4(src.read(uint2(min(p, m))).x, src.read(uint2(min(p + int2(1, 0), m))).x,\n"
     "                      src.read(uint2(min(p + int2(0, 1), m))).x, src.read(uint2(min(p + int2(1, 1), m))).x);\n"
     "    d = select(d, float4(1e6), d <= 0.0);\n"
     "    float mx = max(max(d.x, d.y), max(d.z, d.w));\n"
     "    float range = 0.615 * 0.75 * a.radius, from = (1.0 - 0.615) * 0.75 * a.radius;\n"
     "    float4 w = saturate((d - mx) / range + from / range + 1.0);\n"
     "    return dot(w, d) / max(dot(w, float4(1.0)), 1e-6); }\n"
     "constant float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};\n"
     // The view depth at half-resolution pixel q from copy m (0 the full half-resolution
     // one); c: the centre of the pixel read, in half-resolution pixels.
     "static float zmip(texture2d<float> z0, texture2d<float> z1, texture2d<float> z2, texture2d<float> z3,\n"
     "                  texture2d<float> z4, int m, int2 q, thread float2 &c) {\n"
     "    uint2 r = uint2(q >> m);\n"
     "    c = (float2(r) + 0.5) * float(1 << m);\n"
     "    float w = m == 0 ? z0.read(r).x : m == 1 ? z1.read(r).x : m == 2 ? z2.read(r).x : m == 3 ? z3.read(r).x : z4.read(r).x;\n"
     "    return w <= 0.0 ? 1e6 : w; }\n"
     "fragment float ao_main(V in [[stage_in]], texture2d<float> zt [[texture(0)]], texture2d<float> z1 [[texture(1)]],\n"
     "                       texture2d<float> z2 [[texture(2)]], texture2d<float> z3 [[texture(3)]],\n"
     "                       texture2d<float> z4 [[texture(4)]], constant AOP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), hs = int2(a.hsize) - 1;\n"
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
     "    const int SLICES = 3, STEPS = 6;\n"
     "    float vis = 0.0, wsum = 0.0;\n"
     "    for (int s = 0; s < SLICES; s++) {\n"
     "        float phi = (float(s) + n0) * (M_PI_F / float(SLICES));\n"
     "        float2 omega = float2(cos(phi), -sin(phi));\n"
     "        float3 dir = float3(cos(phi), sin(phi), 0.0);\n"
     "        float3 ortho = dir - dot(dir, V) * V;\n"
     "        float3 axis = normalize(cross(dir, V));\n"
     "        float3 pn = N - axis * dot(N, axis);\n"
     "        float plen = length(pn);\n"
     "        float cosn = saturate(dot(pn, V) / max(plen, 1e-4));\n"
     // Angles in the slice from the view direction, positive towards `dir` (the +omega
     // side on screen); the normal's half circle is n - pi/2 .. n + pi/2.
     "        float n = sign(dot(ortho, pn)) * acos(cosn);\n"
     "        uint bits = 0u;\n"
     "        for (int side = 0; side < 2; side++) {\n"
     "            float sd = side ? -1.0 : 1.0;\n"
     "            for (int k = 0; k < STEPS; k++) {\n"
     "                float t = (float(k) + n1) / float(STEPS);\n"
     "                float len = max(t * t * rpx, float(k) * 0.5 + 1.0);\n"
     "                int2 q = clamp(int2(float2(p) + 0.5 + sd * omega * len), int2(0), hs);\n"
     // Longer steps read the smaller copies (XeGTAO's mip offset, 3.3).
     "                int m = clamp(int(log2(len) - a.mip_offset), 0, 4);\n"
     "                float2 c;\n"
     "                float w = zmip(zt, z1, z2, z3, z4, m, q, c);\n"
     "                float2 ndc = float2(c.x * 2.0 / a.hsize.x - 1.0, 1.0 - c.y * 2.0 / a.hsize.y);\n"
     "                float3 d = float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w) - P;\n"
     "                float l2 = dot(d, d);\n"
     // Past the radius a sample fades out: kept for a share of the pixels, which the
     // filter averages.
     "                float keep = saturate((1.0 - l2 * a.inv_radius2) * 2.5);\n"
     "                if (l2 < 1e-6 || keep < fract(n1 + float(k) * 0.618034 + float(side) * 0.5)) continue;\n"
     "                float3 L = d * rsqrt(l2), Lb = normalize(d - V * a.thickness);\n"
     "                float2 h = sd * acos(clamp(float2(dot(L, V), dot(Lb, V)), -1.0, 1.0)) - n;\n"
     // Sectors equal in cosine-weighted light: sin of the angle from the normal.
     "                h = 0.5 + 0.5 * sin(clamp(h, -M_PI_2_F, M_PI_2_F));\n"
     "                uint b0 = uint(round(min(h.x, h.y) * 32.0)), b1 = uint(round(max(h.x, h.y) * 32.0));\n"
     "                if (b1 > b0) bits |= (b1 - b0 >= 32u ? 0xFFFFFFFFu : (1u << (b1 - b0)) - 1u) << b0;\n"
     "            }\n"
     "        }\n"
     "        vis += plen * (1.0 - float(popcount(bits)) / 32.0), wsum += plen;\n"
     "    }\n"
     // Weighted by how much of the normal each slice holds; an open half circle is 1
     // whichever way the surface faces.
     "    return saturate(vis / max(wsum, 1e-4)); }\n"
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

// kind 0: view depth (from the depth buffer); 1: occlusion (ao_occlusion);
// 2: filter; 3: multiply into the image; 4: show the occlusion alone; 5: a smaller copy of the view depth. Kinds 3 and 4 draw
// in the game's pass, with its depth attachment (`depth`).
static id<MTLRenderPipelineState> ao_pipeline(int kind, MTLPixelFormat color, MTLPixelFormat depth)
{
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:ao_source options:nil error:&error];
        if (!lib) bl_fatal("ambient occlusion shader: %s", error.localizedDescription.UTF8String);
    }
    NSString *key = [NSString stringWithFormat:@"%d/%lu/%lu", kind, (unsigned long)color, (unsigned long)depth];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    static NSString *const names[] = {@"ao_depth", @"ao_main", @"ao_blur", @"ao_apply", @"ao_apply", @"ao_mip"};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"ao_vs"];
    d.fragmentFunction = [lib newFunctionWithName:names[kind]];
    d.colorAttachments[0].pixelFormat = color;
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
static void note_projection(const float r8[4], const float r9[4], const float r10[4], const float r11[4], float clip_y)
{
    if (view_state) return;
    float ww = r11[0] * r11[0] + r11[1] * r11[1] + r11[2] * r11[2];
    if (ww <= 0) return;
    // z = alpha w + beta, with w the view depth: the z row is alpha times the w row plus
    // a constant. Dividing the x and y rows by the w row's length cancels a model scale.
    float alpha = (r10[0] * r11[0] + r10[1] * r11[1] + r10[2] * r11[2]) / ww;
    float lw = sqrtf(ww);
    view_proj.alpha = alpha;
    view_proj.beta = r10[3] - alpha * r11[3];
    view_proj.p00 = sqrtf(r8[0] * r8[0] + r8[1] * r8[1] + r8[2] * r8[2]) / lw;
    view_proj.p11 = sqrtf(r9[0] * r9[0] + r9[1] * r9[1] + r9[2] * r9[2]) / lw * clip_y;
    if (view_proj.beta != 0 && view_proj.p00 > 0 && view_proj.p11 > 0) view_state = 1;
    const float *rows[3] = {r8, r9, r11};
    for (int i = 0; i < 3; i++) {
        float l = sqrtf(rows[i][0] * rows[i][0] + rows[i][1] * rows[i][1] + rows[i][2] * rows[i][2]);
        for (int k = 0; k < 4; k++) view_rows[i][k] = l > 0 ? rows[i][k] / l : 0;
    }
}

// A texture for post_run, kept between frames (half resolution but for the copy of the
// world view).
static id<MTLTexture> ao_texture(int i, MTLPixelFormat pf, NSUInteger w, NSUInteger h)
{
    static id<MTLTexture> t[19];
    if (!t[i] || t[i].width != w || t[i].height != h || t[i].pixelFormat != pf) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t[i] = [mtl newTextureWithDescriptor:td];
    }
    return t[i];
}

// One full-screen pass of ao_pipeline `kind` into `target`.
static void ao_pass(int kind, id<MTLTexture> target, id<MTLTexture> t0, id<MTLTexture> t1,
                    const struct ao_params *a)
{
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:ao_pipeline(kind, target.pixelFormat, MTLPixelFormatInvalid)];
    [e setFragmentTexture:t0 atIndex:0];
    [e setFragmentTexture:t1 atIndex:1];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// The half-resolution view depth z's 4 smaller copies (kept between frames), made once a
// frame for the occlusion and the bounced light (ssil_run).
static id<MTLTexture> ao_mips[4];
static void ao_depth_copies(id<MTLTexture> z, const struct ao_params *a)
{
    static unsigned long made = ~0ul;
    if (made == frames) return;
    made = frames;
    NSUInteger w = z.width, h = z.height;
    id<MTLTexture> prev = z;
    for (int i = 0; i < 4; i++) {
        w = (w + 1) / 2, h = (h + 1) / 2;
        if (!ao_mips[i] || ao_mips[i].width != w || ao_mips[i].height != h) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                         width:w height:h mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            ao_mips[i] = [mtl newTextureWithDescriptor:td];
        }
        ao_pass(5, ao_mips[i], prev, nil, a);
        prev = ao_mips[i];
    }
}

// The occlusion into `raw` from the half-resolution view depth z and its smaller copies.
static void ao_occlusion(id<MTLTexture> raw, id<MTLTexture> z, const struct ao_params *a)
{
    ao_depth_copies(z, a);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = raw;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:ao_pipeline(1, raw.pixelFormat, MTLPixelFormatInvalid)];
    [e setFragmentTexture:z atIndex:0];
    for (int i = 0; i < 4; i++) [e setFragmentTexture:ao_mips[i] atIndex:(NSUInteger)i + 1];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// --- screen-space reflections ----------------------------------------------------------
//
// The game's shiny surfaces add a reflection cubemap to their colour: a picture of the
// room from one point, the same wherever it is seen from. With reflections on, the world
// view's shaders also write how much their cubemaps added and how much a white one would
// (reflection info, d3d_shader_variant reflection_info), and the trace replaces that
// share of the cubemap with what the screen shows where the reflected ray meets it.
// Three passes after the ambient occlusion's view depth (half resolution): the trace,
// 24 steps along the reflected ray from the depth's normal, denser near the start and
// offset by interleaved gradient noise, then 5 halvings, with hits on the backs of
// surfaces dropped; a filter that blurs more the further the ray went (sharp where things
// touch the surface, soft further off) and keeps to similar depths; and, at full
// resolution in the game's next pass on the back buffer, post_apply: a copy of the world
// view plus the reflections, upsampled from the reflective half-resolution pixels only. Elsewhere (off screen,
// behind things) the cubemap stays. Both are stronger at grazing angles (Schlick's
// Fresnel term, which the game's cubemaps lack).
// BL_SSR=show shows the reflections alone, BL_SSR=hits what the trace had to go on;
// BL_SSR_STRENGTH (default 1) scales them, BL_SSR_FRESNEL (default 3) is the extra
// reflection at a grazing angle, BL_SSR_BLUR (default 0.02) the blur per pixel of ray.

struct ssr_params {
    float full[2], half[2];  // back buffer and half-resolution sizes
    float p00, p11;          // projection scales in x and y
    float strength;          // of the reflections; 0: none this frame
    float max_dist, show;    // longest ray (world units); show the reflections (1) or the trace's inputs (2)
    float fresnel, blur;     // extra reflection at a grazing angle; blur radius per half-resolution pixel of ray
    float tonemap, expand;   // tone mapping: 0 off, 1 GT7, 3 Khronos PBR Neutral; 2 and 4 the same after
                             // expanding highlights by `expand` (0..1)
    float fog, skin;         // add the volumetric light (fog_run); use the scattered skin (skin_run)
    float bloom, exposure;   // add the glow this much (bloom_run); scale by the eye's exposure (1; 2 show it)
    float ssil, ssil_show;   // add the bounced light this much (ssil_run); show it alone
};

static NSString *const ssr_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct SP { float2 full, hsize; float p00, p11, strength, max_dist, show, fresnel, blur, tonemap, expand,\n"
     "            fog, skin, bloom, exposure, ssil, ssil_show; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V ssr_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     "static float3 vpos(constant SP &a, texture2d<float> zt, int2 p) {\n"
     "    p = clamp(p, int2(0), int2(a.hsize) - 1);\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    if (w <= 0.0) w = 1e6;\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.hsize.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.hsize.y);\n"
     "    return float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w); }\n"
     // The normal from neighbouring depths (the nearer side of an edge), facing the camera.
     "static float3 vnormal(constant SP &a, texture2d<float> zt, int2 p, float3 P) {\n"
     "    float3 l = vpos(a, zt, p - int2(1, 0)), r = vpos(a, zt, p + int2(1, 0));\n"
     "    float3 u = vpos(a, zt, p - int2(0, 1)), b = vpos(a, zt, p + int2(0, 1));\n"
     "    float3 dx = abs(r.z - P.z) < abs(P.z - l.z) ? r - P : P - l;\n"
     "    float3 dy = abs(b.z - P.z) < abs(P.z - u.z) ? b - P : P - u;\n"
     "    float3 N = normalize(cross(dx, dy));\n"
     "    return dot(N, P) > 0.0 ? -N : N; }\n"
     // View-space point to half-resolution pixel coordinates (centres at +0.5).
     "static float2 project(constant SP &a, float3 q) {\n"
     "    return float2((q.x * a.p00 / q.z + 1.0) * 0.5 * a.hsize.x, (1.0 - q.y * a.p11 / q.z) * 0.5 * a.hsize.y); }\n"
     "static float ign(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }\n"
     // c: the colour where the ray meets the picture, times the confidence; the confidence
     // (-1: not reflective). aux: how far the ray went (half-resolution pixels; 1e4 no hit),
     // and the Fresnel factor.
     "struct TOut { float4 c [[color(0)]]; float4 aux [[color(1)]]; };\n"
     // surf: the surfaces' facing and roughness (surface_texture), all 0 where unknown.
     "fragment TOut ssr_trace(V in [[stage_in]], texture2d<float> zt [[texture(0)]], texture2d<float> info [[texture(1)]],\n"
     "                        texture2d<float> color [[texture(2)]], texture2d<float> surf [[texture(3)]],\n"
     "                        constant SP &a [[buffer(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    TOut o; o.c = float4(0.0, 0.0, 0.0, -1.0); o.aux = float4(1e4, 1.0, 0.0, -1.0);\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    if (zt.read(uint2(p)).x <= 0.0 || info.sample(s, in.pos.xy / a.hsize).w < 0.004) return o;\n"
     "    float3 P = vpos(a, zt, p), N = vnormal(a, zt, p, P), D = normalize(P);\n"
     "    float4 sf = surf.read(uint2(in.pos.xy * float2(surf.get_width(), surf.get_height()) / a.hsize));\n"
     "    if (dot(sf.xyz, sf.xyz) > 0.5) N = sf.xyz, o.aux.w = sf.w;\n"
     "    o.c.w = 0.0, o.aux.y = 1.0 + a.fresnel * pow(1.0 - saturate(dot(-D, N)), 5.0);\n"
     "    float3 R = reflect(D, N);\n"
     "    float len = a.max_dist;\n"
     "    if (R.z < 0.0) len = min(len, (P.z - 4.0) / -R.z);\n"
     "    if (len <= 0.0) return o;\n"
     "    float3 E = P + R * len;\n"
     "    float2 s0 = project(a, P), d = project(a, E) - s0;\n"
     "    float t1 = 1.0;\n"
     "    if (d.x > 1e-3) t1 = min(t1, (a.hsize.x - 0.5 - s0.x) / d.x); else if (d.x < -1e-3) t1 = min(t1, (0.5 - s0.x) / d.x);\n"
     "    if (d.y > 1e-3) t1 = min(t1, (a.hsize.y - 0.5 - s0.y) / d.y); else if (d.y < -1e-3) t1 = min(t1, (0.5 - s0.y) / d.y);\n"
     "    float dl = length(d);\n"
     "    if (dl * t1 < 2.0) return o;\n"
     "    float iz0 = 1.0 / P.z, iz1 = 1.0 / E.z;\n"
     // Start half a pixel out; the depth bias keeps the surface from meeting itself.
     "    float t0 = 0.5 / dl;\n"
     "    float jitter = ign(in.pos.xy);\n"
     "    const int STEPS = 24;\n"
     "    float lo = 0.0, hi = -1.0, prz = P.z;\n"
     "    for (int i = 0; i < STEPS; i++) {\n"
     "        float f = (float(i) + jitter) / float(STEPS);\n"
     "        float t = t0 + (t1 - t0) * f * f;\n"
     "        float rz = 1.0 / mix(iz0, iz1, t);\n"
     "        float sz = zt.read(uint2(s0 + d * t)).x;\n"
     "        float gap = rz - sz;\n"
     "        if (sz > 0.0 && gap > sz * 0.002 && gap < max(abs(rz - prz) * 2.0, sz * 0.02)) { hi = t; break; }\n"
     "        lo = t, prz = rz;\n"
     "    }\n"
     "    if (hi < 0.0) return o;\n"
     "    for (int i = 0; i < 5; i++) {\n"
     "        float t = 0.5 * (lo + hi);\n"
     "        float rz = 1.0 / mix(iz0, iz1, t);\n"
     "        float sz = zt.read(uint2(s0 + d * t)).x;\n"
     "        if (sz > 0.0 && rz - sz > sz * 0.002) hi = t; else lo = t;\n"
     "    }\n"
     "    int2 q = int2(s0 + d * hi);\n"
     // A ray going the way the surface it meets faces came from behind it.
     "    float3 H = vpos(a, zt, q);\n"
     "    if (dot(vnormal(a, zt, q, H), R) > 0.1) return o;\n"
     "    float2 uv = (s0 + d * hi) / a.hsize, edge = min(uv, 1.0 - uv);\n"
     // Fade out towards the screen's edges, the ray's end and rays coming back at the camera.
     "    float conf = saturate(min(edge.x, edge.y) * 12.0) * (1.0 - smoothstep(0.7, 1.0, hi)) * saturate(R.z * 2.0 + 1.0);\n"
     "    o.c = float4(color.sample(s, uv).rgb * conf, conf);\n"
     "    o.aux.x = dl * hi, o.aux.z = length(H - P);\n"
     "    return o; }\n"
     "fragment float4 ssr_blur(V in [[stage_in]], texture2d<float> ssr [[texture(0)]], texture2d<float> zt [[texture(1)]],\n"
     "                         texture2d<float> aux [[texture(2)]], constant SP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), hs = int2(a.hsize) - 1;\n"
     "    float z = zt.read(uint2(p)).x;\n"
     "    if (z <= 0.0 || ssr.read(uint2(p)).w < 0.0) return float4(0.0, 0.0, 0.0, -1.0);\n"
     // 5 by 5 taps, spaced out for the wider blurs.
     "    float4 ax = aux.read(uint2(p));\n"
     "    float sigma = clamp(ax.x * a.blur, 0.4, 2.0);\n"
     // Rougher surfaces blur more (their roughness from the PBRify map, when known).
     "    if (ax.w >= 0.0) sigma = clamp(sigma * (0.25 + 2.5 * ax.w), 0.4, 3.0);\n"
     "    int step = sigma > 1.3 ? 2 : 1;\n"
     "    float k = -0.5 / (sigma * sigma);\n"
     "    float4 sum = 0.0;\n"
     "    float wsum = 0.0;\n"
     "    for (int j = -2; j <= 2; j++)\n"
     "        for (int i = -2; i <= 2; i++) {\n"
     "            int2 o = int2(i, j) * step;\n"
     "            uint2 q = uint2(clamp(p + o, int2(0), hs));\n"
     "            float4 v = ssr.read(q);\n"
     "            if (v.w < 0.0) continue;\n"
     "            float w = exp(-abs(zt.read(q).x - z) * 20.0 / z + float(o.x * o.x + o.y * o.y) * k);\n"
     "            sum += v * w, wsum += w;\n"
     "        }\n"
     "    return sum / max(wsum, 1e-5); }\n"
     // Under TAA (post_run): the filtered reflections blended with last frame's. The
     // history is kept within the 3x3 neighbourhood's range (a little wider), so it
     // follows when the reflection really changes but not when a thin thing is hit one
     // frame and missed the next. Last frame's place is that of the reflected point (as
     // in AMD's FidelityFX SSSR): what a surface reflects appears behind it, as far again
     // as the ray went (the 3x3's average of the hits' lengths), on the same view ray, and
     // moves with the camera as that point would, not as the surface does. SSRH holds the
     // TAA's reprojection (taa_motion): this frame's NDC without its offset and depth
     // (alpha + beta / w) to last frame's clip space. Without a hit, the camera's motion
     // vectors at the surface (full resolution, texture coordinates).
     "struct SSRH { float4x4 reproj; float2 offset; float alpha, beta; };\n"
     "fragment float4 ssr_history(V in [[stage_in]], texture2d<float> cur [[texture(0)]],\n"
     "                            texture2d<float> hist [[texture(1)]], texture2d<float> mv [[texture(2)]],\n"
     "                            texture2d<float> zt [[texture(3)]], texture2d<float> aux [[texture(4)]],\n"
     "                            constant SP &a [[buffer(0)]], constant SSRH &r [[buffer(1)]]) {\n"
     "    int2 p = int2(in.pos.xy), hs = int2(a.hsize) - 1;\n"
     "    float4 c = cur.read(uint2(p));\n"
     "    if (c.w < 0.0) return c;\n"
     "    float4 lo = c, hi = c;\n"
     "    float len = 0.0, n = 0.0;\n"
     "    for (int j = -1; j <= 1; j++)\n"
     "        for (int i = -1; i <= 1; i++) {\n"
     "            uint2 q = uint2(clamp(p + int2(i, j), int2(0), hs));\n"
     "            float4 v = cur.read(q);\n"
     "            if (v.w >= 0.0) lo = min(lo, v), hi = max(hi, v);\n"
     "            float l = aux.read(q).z;\n"
     "            if (l > 0.0) len += l, n += 1.0;\n"
     "        }\n"
     "    float2 m = mv.read(uint2(min(p * 2, int2(mv.get_width(), mv.get_height()) - 1))).xy;\n"
     "    if (n > 0.0) {\n"
     "        float3 P = vpos(a, zt, p);\n"
     "        float w = P.z * (1.0 + len / n / length(P));\n"
     "        float2 ndc = float2(in.pos.x / a.hsize.x * 2.0 - 1.0, 1.0 - in.pos.y / a.hsize.y * 2.0) - r.offset;\n"
     "        float4 pc = r.reproj * float4(ndc, r.alpha + r.beta / w, 1.0);\n"
     "        if (pc.w > 1e-6) m = (pc.xy / pc.w - ndc) * float2(0.5, -0.5);\n"
     "    }\n"
     "    float2 q = (in.pos.xy / a.hsize + m) * a.hsize;\n"
     "    if (any(q < 0.0) || any(q >= a.hsize)) return c;\n"
     "    float4 h = hist.read(uint2(q));\n"
     "    if (h.w < 0.0) return c;\n"
     "    float4 ext = (hi - lo) * 0.25;\n"
     "    return mix(clamp(h, lo - ext, hi + ext), c, 0.1); }\n"
     // GT7's tone mapping (Polyphony Digital's published SDR curve and chroma handling):
     // frame buffer 1.0 is 100 nits, paper white 250 nits. The curve maps each channel
     // (toe, linear section, exponential shoulder); the result's intensity in ICtCp is kept,
     // with the original chroma faded out towards white, and the two are blended 40:60.
     "static float gt7_smooth(float x, float e0, float e1) { float t = saturate((x - e0) / (e1 - e0)); return t * t * (3.0 - 2.0 * t); }\n"
     "constant float GT7_PEAK = 2.5, GT7_ALPHA = 0.25, GT7_MID = 0.538, GT7_LIN = 0.444, GT7_TOE = 1.28;\n"
     "static float gt7_curve(float x) {\n"
     "    if (x < 0.0) return 0.0;\n"
     "    float k = (GT7_LIN - 1.0) / (GT7_ALPHA - 1.0);\n"
     "    float ka = GT7_PEAK * GT7_LIN + GT7_PEAK * k, kb = -GT7_PEAK * k * exp(GT7_LIN / k), kc = -1.0 / (k * GT7_PEAK);\n"
     "    if (x >= GT7_LIN * GT7_PEAK) return ka + kb * exp(x * kc);\n"
     "    float wl = gt7_smooth(x, 0.0, GT7_MID);\n"
     "    return (1.0 - wl) * GT7_MID * pow(x / GT7_MID, GT7_TOE) + wl * x; }\n"
     "static float3 pq_encode(float3 l) {\n"
     "    float3 p = pow(max(l, 0.0), 0.1593017578125);\n"
     "    return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), 78.84375); }\n"
     "static float3 pq_decode(float3 n) {\n"
     "    float3 p = pow(max(n, 0.0), 1.0 / 78.84375);\n"
     "    return pow(max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p), 1.0 / 0.1593017578125); }\n"
     // Rec.2020 frame buffer values to ICtCp and back.
     "static float3 to_ictcp(float3 c) {\n"
     "    float3 lms = float3(dot(c, float3(1688, 2146, 262)), dot(c, float3(683, 2951, 462)), dot(c, float3(99, 309, 3688))) / 4096.0;\n"
     "    float3 q = pq_encode(lms * 0.01);\n"
     "    return float3(0.5 * (q.x + q.y), dot(q, float3(6610, -13613, 7003)) / 4096.0, dot(q, float3(17933, -17390, -543)) / 4096.0); }\n"
     "static float3 from_ictcp(float3 i) {\n"
     "    float3 q = float3(i.x + 0.00860904 * i.y + 0.11102963 * i.z, i.x - 0.00860904 * i.y - 0.11102963 * i.z,\n"
     "                      i.x + 0.56003134 * i.y - 0.32062717 * i.z);\n"
     "    float3 lms = pq_decode(q) * 100.0;\n"
     "    return float3(dot(lms, float3(3.4366066943, -2.5064521187, 0.0698454243)),\n"
     "                  dot(lms, float3(-0.7913295556, 1.9836004518, -0.1922708962)),\n"
     "                  dot(lms, float3(-0.0259498997, -0.0989137147, 1.1248636144))); }\n"
     "static float3 gt7(float3 srgb, float mode, float expand) {\n"
     "    float3 lin = select(pow((srgb + 0.055) / 1.055, 2.4), srgb / 12.92, srgb <= 0.04045);\n"
     // Highlights the game clamped at 1, pushed back up (inverse Reinhard on the brightest channel).
     "    if (mode > 1.5) { float m = max(max(lin.r, lin.g), lin.b); lin *= 1.0 / max(1.0 - expand * m, 1.0 - expand); }\n"
     "    float3 c = float3(dot(lin, float3(0.6274, 0.3293, 0.0433)), dot(lin, float3(0.0691, 0.9195, 0.0114)),\n"
     "                      dot(lin, float3(0.0164, 0.0880, 0.8956))) * GT7_PEAK;\n"
     "    float3 ucs = to_ictcp(c);\n"
     "    float3 skew = float3(gt7_curve(c.r), gt7_curve(c.g), gt7_curve(c.b));\n"
     "    float3 su = to_ictcp(skew);\n"
     "    float target = to_ictcp(float3(GT7_PEAK)).x;\n"
     "    float chroma = 1.0 - gt7_smooth(ucs.x, 0.98 * target, 1.16 * target);\n"
     "    float3 scaled = from_ictcp(float3(su.x, ucs.y * chroma, ucs.z * chroma));\n"
     "    float3 o = min(mix(skew, scaled, 0.6), GT7_PEAK) / GT7_PEAK;\n"
     "    o = float3(dot(o, float3(1.6605, -0.5876, -0.0728)), dot(o, float3(-0.1246, 1.1329, -0.0083)),\n"
     "               dot(o, float3(-0.0182, -0.1006, 1.1187)));\n"
     "    o = saturate(o);\n"
     "    return select(1.055 * pow(o, 1.0 / 2.4) - 0.055, o * 12.92, o <= 0.0031308); }\n"
     // Khronos PBR Neutral (the reference version), on linear sRGB.
     "static float3 pbr_neutral(float3 srgb, float mode, float expand) {\n"
     "    float3 c = select(pow((srgb + 0.055) / 1.055, 2.4), srgb / 12.92, srgb <= 0.04045);\n"
     "    if (mode > 3.5) { float m = max(max(c.r, c.g), c.b); c *= 1.0 / max(1.0 - expand * m, 1.0 - expand); }\n"
     "    const float start = 0.8 - 0.04, desat = 0.15;\n"
     "    float x = min(c.r, min(c.g, c.b));\n"
     "    c -= x < 0.08 ? x - 6.25 * x * x : 0.04;\n"
     "    float peak = max(c.r, max(c.g, c.b));\n"
     "    if (peak >= start) {\n"
     "        const float d = 1.0 - start;\n"
     "        float np = 1.0 - d * d / (peak + d - start);\n"
     "        c *= np / peak;\n"
     "        c = mix(c, float3(np), 1.0 - 1.0 / (desat * (peak - np) + 1.0));\n"
     "    }\n"
     "    c = saturate(c);\n"
     "    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }\n"
     // HDR output: the picture in linear light, 1 at normal white. Where the HUD and view
     // model left the world view alone, everything lit brighter than `knee` (luminance) is
     // brightened, more the brighter it is (in proportion to how far it is from `knee`
     // to white), white reaching `peak`; then the brightest channel is rolled off at the
     // screen's headroom with GT7's shoulder (straight, then exponential towards the
     // peak) and whitened a little near it. The HUD stays at normal white, below the lit
     // world. `preview` writes the result divided by the headroom, in sRGB, for dumps.
     "struct HP { float headroom, peak, knee, world, preview, pad0, pad1, pad2; };\n"
     "fragment float4 hdr_present(V in [[stage_in]], texture2d<float> pic [[texture(0)]], texture2d<float> world [[texture(1)]],\n"
     "                            constant HP &h [[buffer(0)]]) {\n"
     "    uint2 p = uint2(in.pos.xy);\n"
     "    float3 c = saturate(pic.read(p).rgb);\n"
     "    float3 o = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);\n"
     "    float H = h.headroom;\n"
     "    if (h.world > 0.0 && H > 1.001 && all(abs(world.read(p).rgb - c) < 1e-3)) {\n"
     "        float Y = dot(o, float3(0.2126, 0.7152, 0.0722));\n"
     "        if (Y > h.knee) {\n"
     "            float u = saturate((Y - h.knee) / (1.0 - h.knee));\n"
     "            o *= 1.0 + (h.peak - 1.0) * u;\n"
     "            float m = max(max(o.r, o.g), o.b), x = m;\n"
     "            float L = max(GT7_LIN, min(1.0 / H, 0.999)), k = (L - 1.0) / (GT7_ALPHA - 1.0);\n"
     "            float ka = H * L + H * k, kb = -H * k * exp(L / k), kc = -1.0 / (k * H);\n"
     "            float y = x < L * H ? x : min(ka + kb * exp(x * kc), H);\n"
     "            o *= y / m;\n"
     "            o = mix(o, float3(y), 0.4 * smoothstep(0.5, 1.0, y / H));\n"
     "        }\n"
     "    }\n"
     "    if (h.preview > 0.0) {\n"
     "        o = saturate(o / H);\n"
     "        return float4(select(1.055 * pow(o, 1.0 / 2.4) - 0.055, o * 12.92, o <= 0.0031308), 1.0);\n"
     "    }\n"
     "    return float4(o, 1.0); }\n"
     // Full resolution, in the game's next pass on the back buffer: the world view again,
     // with the reflections in place of that share of the cubemaps.
     "static float3 picture(texture2d<float> base, texture2d<float> info, texture2d<float> skin, float sk, int2 q) {\n"
     "    return sk > 0.0 && info.read(uint2(q)).w < -0.5 ? skin.read(uint2(q)).rgb : base.read(uint2(q)).rgb; }\n"
     "fragment float4 post_apply(V in [[stage_in]], texture2d<float> base [[texture(0)]], texture2d<float> info [[texture(1)]],\n"
     "                           texture2d<float> ssr [[texture(2)]], texture2d<float> aux [[texture(3)]],\n"
     "                           texture2d<float> fogt [[texture(4)]], texture2d<float> skin [[texture(5)]],\n"
     "                           texture2d<float> glow [[texture(6)]], texture2d<float> bounce [[texture(7)]],\n"
     "                           texture2d<float> alb [[texture(8)]], constant SP &a [[buffer(0)]],\n"
     "                           constant float *eye [[buffer(1)]]) {\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    float4 c = base.read(uint2(p));\n"
     // Characters' pixels come from the scattered skin picture (in red for the options'
     // "show"). (Without reflections or skin the info texture is not bound.)
     "    float3 col = picture(base, info, skin, a.skin, p);\n"
     "    if (a.skin > 1.5 && info.read(uint2(p)).w < -0.5) col = float3(1.0, 0.1, 0.1);\n"
     "    if (a.strength > 0.0) {\n"
     "        float4 f = info.read(uint2(p)), r = 0.0;\n"
     "        float F = 1.0;\n"
     "        if (f.w > 0.004) {\n"
     // Bilinear from the half-resolution pixels around, leaving out those that are not
     // reflective (an object in front), so their edges do not bleed in.
     "            float2 h = (float2(p) + 0.5) * 0.5 - 0.5, t = fract(h);\n"
     "            int2 b = int2(floor(h)), hs = int2(a.hsize) - 1;\n"
     "            float fs = 0.0, ws = 0.0;\n"
     "            for (int j = 0; j < 2; j++)\n"
     "                for (int i = 0; i < 2; i++) {\n"
     "                    uint2 q = uint2(clamp(b + int2(i, j), int2(0), hs));\n"
     "                    float4 v = ssr.read(q);\n"
     "                    if (v.w < 0.0) continue;\n"
     "                    float w = (i ? t.x : 1.0 - t.x) * (j ? t.y : 1.0 - t.y);\n"
     "                    r += v * w, fs += aux.read(q).y * w, ws += w;\n"
     "                }\n"
     "            if (ws > 1e-4) r /= ws, F = fs / ws;\n"
     "        }\n"
     "        if (a.show > 1.5) col = float3(f.w, r.a, length(f.rgb));\n"
     "        else if (a.show > 0.0) col = f.w > 0.004 ? F * r.rgb : col * 0.25;\n"
     "        else if (f.w > 0.004) col += a.strength * (F * (max(f.w, 0.0) * r.rgb + (1.0 - r.a) * f.rgb) - f.rgb);\n"
     "    }\n"
     // The bounced light (ssil_run) on the surface's own colour (albedo_texture).
     "    if (a.ssil > 0.0 || a.ssil_show > 0.0) {\n"
     "        float3 b = bounce.read(uint2(p)).rgb;\n"
     "        col = a.ssil_show > 1.5 ? alb.read(uint2(p)).rgb : a.ssil_show > 0.0 ? b : col + a.ssil * b * alb.read(uint2(p)).rgb;\n"
     "    }\n"
     "    if (a.fog > 0.0) {\n"
     "        constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
     "        float4 f = fogt.sample(ls, (float2(p) + 0.5) / a.full);\n"
     "        col = col * f.w + f.rgb;\n"
     "    }\n"
     // The eye's exposure, then the glow (bloom section), and a soft shoulder so what they
     // push past white rolls off instead of clipping (without tone mapping, which has its own).
     "    if (a.exposure > 0.0 || a.bloom > 0.0) {\n"
     "        constexpr sampler gs(filter::linear, address::clamp_to_edge);\n"
     "        if (a.exposure > 0.0) col *= eye[0];\n"
     "        if (a.bloom > 1.5) col = glow.sample(gs, (float2(p) + 0.5) / a.full).rgb;\n"
     "        else if (a.bloom > 0.0) col += a.bloom * glow.sample(gs, (float2(p) + 0.5) / a.full).rgb;\n"
     "        float m = max(max(col.r, col.g), col.b), k = 0.75;\n"
     "        if (a.tonemap == 0.0 && m > k) col *= (k + (1.0 - k) * (1.0 - exp(-(m - k) / (1.0 - k)))) / m;\n"
     "        if (a.exposure > 1.5 && p.y < 12) col = float(p.x) < a.full.x * eye[0] * 0.5 ? float3(1.0, 0.8, 0.0) : float3(0.1);\n"
     "    }\n"
     "    if (a.tonemap > 2.5) col = pbr_neutral(saturate(col), a.tonemap, a.expand);\n"
     "    else if (a.tonemap > 0.0) col = gt7(saturate(col), a.tonemap, a.expand);\n"
     "    return float4(saturate(col), c.a); }\n";

// kind 0: trace (a second target for the ray's length and Fresnel factor); 1: filter;
// 2: post_apply, in the game's pass with its depth attachment (`depth`); 4: the blend
// with last frame's reflections under TAA.
#define SSR_AUX_FORMAT MTLPixelFormatRGBA16Float
static id<MTLRenderPipelineState> ssr_pipeline(int kind, MTLPixelFormat color, MTLPixelFormat depth)
{
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:ssr_source options:nil error:&error];
        if (!lib) bl_fatal("reflection shader: %s", error.localizedDescription.UTF8String);
    }
    NSString *key = [NSString stringWithFormat:@"%d/%lu/%lu", kind, (unsigned long)color, (unsigned long)depth];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    static NSString *const names[] = {@"ssr_trace", @"ssr_blur", @"post_apply", @"hdr_present", @"ssr_history"};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"ssr_vs"];
    d.fragmentFunction = [lib newFunctionWithName:names[kind]];
    d.colorAttachments[0].pixelFormat = color;
    if (kind == 0) d.colorAttachments[1].pixelFormat = SSR_AUX_FORMAT;
    d.depthAttachmentPixelFormat = depth;
    d.stencilAttachmentPixelFormat = depth;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("reflection pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

// The trace's surface facing (surface_texture this frame, or an empty one).
static id<MTLTexture> ssr_surface;

// ssr_history's SSRH: the TAA's reprojection (set by taa_motion) and the depth's alpha and beta.
static struct { float reproj[4][4]; float offset[2]; float alpha, beta; } ssr_reproj;

// One full-screen pass of ssr_pipeline `kind` into `target` (and `target2` for the trace).
static void ssr_pass(int kind, id<MTLTexture> target, id<MTLTexture> target2, id<MTLTexture> t0, id<MTLTexture> t1,
                     id<MTLTexture> t2, const struct ssr_params *a)
{
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (target2) {
        rp.colorAttachments[1].texture = target2;
        rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[1].storeAction = MTLStoreActionStore;
    }
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:ssr_pipeline(kind, target.pixelFormat, MTLPixelFormatInvalid)];
    [e setFragmentTexture:t0 atIndex:0];
    [e setFragmentTexture:t1 atIndex:1];
    [e setFragmentTexture:t2 atIndex:2];
    if (kind == 0) [e setFragmentTexture:ssr_surface atIndex:3];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// The blend with last frame's reflections (ssr_history) into `next`: the filtered
// reflections `cur`, last frame's `prev`, the camera's motion vectors `mv`, and the view
// depth and trace's aux it follows the reflected point by.
static void ssr_history_run(id<MTLTexture> next, id<MTLTexture> cur, id<MTLTexture> prev, id<MTLTexture> mv,
                            id<MTLTexture> z, id<MTLTexture> aux, const struct ssr_params *a)
{
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = next;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:ssr_pipeline(4, next.pixelFormat, MTLPixelFormatInvalid)];
    [e setFragmentTexture:cur atIndex:0];
    [e setFragmentTexture:prev atIndex:1];
    [e setFragmentTexture:mv atIndex:2];
    [e setFragmentTexture:z atIndex:3];
    [e setFragmentTexture:aux atIndex:4];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    ssr_reproj.alpha = view_proj.alpha, ssr_reproj.beta = view_proj.beta;
    [e setFragmentBytes:&ssr_reproj length:sizeof ssr_reproj atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// --- volumetric light and skin -----------------------------------------------------------
//
// Volumetric light (BL_FOG, fog_run): a thin haze lit by the map's own lights. The map's
// file has every light its compiler baked (bl_bsp.c), with its colour, falloff and spot
// cone; the brightest 24 that the camera's part of the map can see, put into view space
// with the world view's camera (view_rows), light the air along each pixel's view ray up
// to what the pixel shows: 16 steps offset by interleaved gradient noise, each adding
// what every light sends towards the camera there (Henyey-Greenstein, mostly forwards),
// at half resolution; then a depth-aware 3x3 filter. post_apply adds it, and dims what
// lies behind a little. Lights are not shadowed in the haze: a light beyond a wall
// (the map's tree says so) fades to 0.3 of its haze.
//
// Skin (BL_SSS, skin_run): light that enters skin comes out again a little way off, red
// furthest. The world view's skinned draws (characters) write into the reflection info
// the light on them alone, their shader run again with its colour texture read as white
// (d3d_shader_variant skin), marked with -1. Two passes blur that light, across then
// down, over a width in world units (so less with distance), red the widest and blue
// the narrowest, keeping to the marked pixels at the same depth; the second multiplies
// it by the skin's own colour (the picture divided by the unblurred light), so the
// texture stays sharp, where that colour looks like skin (in YCbCr), and adds skin's
// shine from the map's lights (wetter on the lips, picked out by their colour; broken up
// by the texture's fine detail, dimmed in creases) and a little light at its edges, with
// normals from the depth smoothed over a world unit. post_apply uses it for the marked pixels.

// post_apply's inputs (post_run): the world view, the reflections and their aux, the
// volumetric light, the scattered skin.
static id<MTLTexture> post_base, post_ssr, post_aux, post_fog, post_skin;

#define FOG_LIGHTS 24
struct fog_light { float pos[4], color[4], dir[4], att[4]; };  // see FL in fx_source
struct fx_params {
    float full[2], half[2];
    float p00, p11;
    float density, dist;   // fog: per world unit; how far to trace
    float steps, nlights;  // fog
    float width, strength; // skin: blur width (world units); how much of it to use
    float dir[2];          // skin: blur direction (1 0 or 0 1)
    float final, sheen;    // skin: the second pass (mixes in); strength of the shine (0 none)
};

static NSString *const fx_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct FP { float2 full, hsize; float p00, p11, density, dist, steps, nlights, width, strength; float2 dir;\n"
     "            float final, sheen; };\n"
     // pos.w: range (0 none); color.w: spot's full cone (cosine); dir.w: its zero cone;
     // att.w: its exponent. Points have dir 0.
     "struct FL { float4 pos, color, dir, att; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V fx_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     "static float ign(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }\n"
     "fragment float4 fog_scatter(V in [[stage_in]], texture2d<float> zt [[texture(0)]], constant FP &a [[buffer(0)]],\n"
     "                            constant FL *L [[buffer(1)]]) {\n"
     "    uint2 p = uint2(in.pos.xy);\n"
     "    float w = zt.read(p).x;\n"
     "    if (w <= 0.0) w = a.dist;\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.hsize.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.hsize.y);\n"
     "    float3 ray = float3(ndc.x / a.p00, ndc.y / a.p11, 1.0);\n"
     "    float rl = length(ray), T = min(w, a.dist), dt = T / a.steps;\n"
     "    float3 vd = ray / rl, acc = 0.0;\n"
     "    float j = ign(float2(p));\n"
     "    const float g = 0.35, g1 = 1.0 - g * g, g2 = 1.0 + g * g;\n"
     "    int n = int(a.nlights), steps = int(a.steps);\n"
          // Each light only over the steps it reaches: inside its range, and where it could
          // still add a 4096th to the haze over the whole ray (the phase at its most).
     "    float most = 4096.0 * 3.2 * 1.5 * a.density * a.dist, rr = dot(ray, ray);\n"
     "    for (int k = 0; k < n; k++) {\n"
     "        float3 at = L[k].att.xyz;\n"
     "        float K = most * max(L[k].color.r, max(L[k].color.g, L[k].color.b)), r = 1e30;\n"
     "        if (at.z > 0.0) r = (-at.y + sqrt(max(at.y * at.y - 4.0 * at.z * (at.x - K), 0.0))) / (2.0 * at.z);\n"
     "        else if (at.y > 0.0) r = (K - at.x) / at.y;\n"
     "        if (L[k].pos.w > 0.0) r = min(r, L[k].pos.w);\n"
     "        float b = dot(ray, L[k].pos.xyz), c = dot(L[k].pos.xyz, L[k].pos.xyz) - r * r, h = b * b - rr * c;\n"
     "        if (h <= 0.0) continue;\n"
     "        h = sqrt(h);\n"
     "        int i0 = max(int(ceil((b - h) / rr / dt - j)), 0), i1 = min(int(floor((b + h) / rr / dt - j)), steps - 1);\n"
     "        for (int i = i0; i <= i1; i++) {\n"
     "            float3 P = ray * ((float(i) + j) * dt);\n"
     "            float3 v = L[k].pos.xyz - P;\n"
     "            float d2 = max(dot(v, v), 64.0), d = sqrt(d2);\n"
     "            float3 l = v / d;\n"
     "            float f = 1.0 / (L[k].att.x + L[k].att.y * d + L[k].att.z * d2);\n"
     "            if (L[k].pos.w > 0.0) { float x = d / L[k].pos.w; f *= saturate(1.0 - x * x * x * x); }\n"
     "            if (dot(L[k].dir.xyz, L[k].dir.xyz) > 0.25) {\n"
     "                float c = dot(-l, L[k].dir.xyz), inner = L[k].color.w, outer = L[k].dir.w;\n"
     "                if (c <= outer) continue;\n"
     "                if (c < inner) f *= (c - outer) / max(inner - outer, 1e-4);\n"
     "                if (L[k].att.w > 0.0 && L[k].att.w != 1.0) f *= pow(c, L[k].att.w);\n"
     "            }\n"
     "            float ph = g1 / pow(g2 - 2.0 * g * dot(l, vd), 1.5);\n"
     "            acc += L[k].color.rgb * (f * ph);\n"
     "        }\n"
     "    }\n"
          // Rolled off so that where the lights pile up the haze nears white without passing it.
     "    return float4(1.0 - exp(-acc * (a.density * dt * rl)), exp(-0.5 * a.density * rl * T)); }\n"
     "fragment float4 fog_blur(V in [[stage_in]], texture2d<float> ft [[texture(0)]], texture2d<float> zt [[texture(1)]],\n"
     "                         constant FP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), m = int2(a.hsize) - 1;\n"
     "    float w0 = zt.read(uint2(p)).x;\n"
     "    float4 s = 0.0; float ws = 0.0;\n"
     "    for (int y = -1; y <= 1; y++)\n"
     "        for (int x = -1; x <= 1; x++) {\n"
     "            uint2 q = uint2(clamp(p + int2(x, y), int2(0), m));\n"
     "            float w = zt.read(q).x;\n"
     "            float k = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);\n"
     "            k *= w0 <= 0.0 && w <= 0.0 ? 1.0 : exp(-abs(w - w0) / max(w0, 1.0) * 20.0);\n"
     "            s += ft.read(q) * k, ws += k;\n"
     "        }\n"
     "    return s / ws; }\n"
     // The skin's normals for its shine (half resolution): from view-space positions a
     // world unit apart, wide enough to span the model's flat faces, then smoothed.
     "static float3 hpos(constant FP &a, texture2d<float> zt, int2 p) {\n"
     "    p = clamp(p, int2(0), int2(a.hsize) - 1);\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.hsize.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.hsize.y);\n"
     "    return float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w); }\n"
     "fragment float4 skin_normal(V in [[stage_in]], texture2d<float> zt [[texture(0)]], texture2d<float> info [[texture(1)]],\n"
     "                            constant FP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    float iw = info.read(uint2(min(p * 2, int2(a.full) - 1))).w;\n"
     "    float3 P = hpos(a, zt, p);\n"
     "    if (iw > -0.5 || iw < -1.5 || P.z <= 0.0) return 0.0;\n"
     "    int st = int(clamp(round(a.p00 * a.hsize.x * 0.5 / P.z), 1.0, 8.0));\n"
     "    float3 l = hpos(a, zt, p - int2(st, 0)), r = hpos(a, zt, p + int2(st, 0));\n"
     "    float3 u = hpos(a, zt, p - int2(0, st)), b = hpos(a, zt, p + int2(0, st));\n"
     "    float lim = 0.05 * P.z + 1.0;\n"
     "    float3 dx = abs(r.z - P.z) < lim && abs(l.z - P.z) < lim ? r - l : abs(r.z - P.z) < abs(l.z - P.z) ? r - P : P - l;\n"
     "    float3 dy = abs(b.z - P.z) < lim && abs(u.z - P.z) < lim ? b - u : abs(b.z - P.z) < abs(u.z - P.z) ? b - P : P - u;\n"
     "    float3 N = normalize(cross(dx, dy));\n"
     // How far the point lies behind its neighbours (a crease: beside the nose, under the
     // lips), 0..1 over half a world unit, in w as 1 + that.
     "    float cav = 0.0, cn = 0.0;\n"
     "    float3 q[4] = {l, r, u, b};\n"
     "    for (int i = 0; i < 4; i++)\n"
     "        if (abs(q[i].z - P.z) < lim) cav += P.z - q[i].z, cn += 1.0;\n"
     "    cav = cn > 0.0 ? saturate(cav / cn / 0.5) : 0.0;\n"
     "    return float4(dot(N, P) > 0.0 ? -N : N, 1.0 + cav); }\n"
     // How much a colour looks like skin, pale to dark, in YCbCr; blonde and red hair, more
     // yellow (lower Cb), are left out.
     "static float skin_tone(float3 c) {\n"
     "    float cb = 0.5 - 0.1687 * c.r - 0.3313 * c.g + 0.5 * c.b, cr = 0.5 + 0.5 * c.r - 0.4187 * c.g - 0.0813 * c.b;\n"
     "    return smoothstep(0.505, 0.53, cr) * (1.0 - smoothstep(0.68, 0.72, cr)) *\n"
     "           smoothstep(0.33, 0.37, cb) * (1.0 - smoothstep(0.50, 0.52, cb)); }\n"
     // Pass 1 (across) blurs the light alone (src: the reflection info); pass 2 (down)
     // blurs pass 1, then multiplies the blurred light by the skin's own colour (the
     // picture divided by its unblurred light), so the texture stays sharp.
     // Eyes: the eyeball's shape from depth (half resolution, from neighbours on the
     // eyeball too), a small catchlight from a light up and to the left of the camera, as
     // in film, the map's lights as tight highlights and a faint wet sheen. All scaled
     // by how lit the eye is (its own brightness, the white of an eye being about 0.6).
     "static float4 eye_shine(constant FP &a, texture2d<float> zt, texture2d<float> info, int2 p, float4 o,\n"
     "                        constant FL *L) {\n"
     "    int2 h = p / 2, fm = int2(a.full) - 1;\n"
     "    float3 P0 = hpos(a, zt, h);\n"
     "    if (P0.z <= 0.0) return o;\n"
     "    bool e[4]; float3 q[4];\n"
     "    for (int i = 0; i < 4; i++) {\n"
     "        int2 d = int2(i == 0 ? 1 : i == 1 ? -1 : 0, i == 2 ? 1 : i == 3 ? -1 : 0);\n"
     "        float w = info.read(uint2(clamp((h + d) * 2, int2(0), fm))).w;\n"
     "        q[i] = hpos(a, zt, h + d), e[i] = w < -2.5 && w > -3.5 && abs(q[i].z - P0.z) < 0.02 * P0.z + 0.5;\n"
     "    }\n"
     "    float3 dx = e[0] && e[1] ? q[0] - q[1] : e[0] ? q[0] - P0 : e[1] ? P0 - q[1] : float3(1.0, 0.0, 0.0);\n"
     "    float3 dy = e[2] && e[3] ? q[2] - q[3] : e[2] ? q[2] - P0 : e[3] ? P0 - q[3] : float3(0.0, 1.0, 0.0);\n"
     "    float3 N = normalize(cross(dx, dy));\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.full.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.full.y);\n"
     "    float3 P = float3(ndc.x * P0.z / a.p00, ndc.y * P0.z / a.p11, P0.z), V = -normalize(P);\n"
     "    if (dot(N, V) < 0.0) N = -N;\n"
     "    const float3 lw = float3(0.2126, 0.7152, 0.0722);\n"
     "    float lit = clamp(dot(o.rgb, lw) / 0.6, 0.15, 1.5);\n"
     "    float3 lc = normalize(V + float3(-0.35, 0.45, 0.0));\n"
     "    float nc = saturate(dot(N, normalize(lc + V)));\n"
     "    float3 add = float3(1.0, 0.97, 0.92) * (pow(nc, 400.0) * 1.2 + pow(nc, 40.0) * 0.05);\n"
     "    float3 sp = 0.0; float E = 0.0;\n"
     "    for (int k = 0; k < int(a.nlights); k++) {\n"
     "        float3 v = L[k].pos.xyz - P;\n"
     "        float d2 = max(dot(v, v), 64.0), d = sqrt(d2);\n"
     "        float3 l = v / d;\n"
     "        float li = dot(L[k].color.rgb, lw) / (L[k].att.x + L[k].att.y * d + L[k].att.z * d2);\n"
     "        E += li;\n"
     "        float nh = saturate(dot(N, normalize(l + V)));\n"
     "        sp += L[k].color.rgb / max(dot(L[k].color.rgb, lw), 1e-4) * li * pow(nh, 300.0) * 2.0;\n"
     "    }\n"
     "    if (E > 1e-6) add += sp / E;\n"
     "    return float4(saturate(o.rgb + lit * add), o.a); }\n"
     "fragment float4 skin_blur(V in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> info [[texture(1)]],\n"
     "                          texture2d<float> zt [[texture(2)]], texture2d<float> orig [[texture(3)]],\n"
     "                          texture2d<float> nt [[texture(4)]], constant FP &a [[buffer(0)]],\n"
     "                          constant FL *L [[buffer(1)]]) {\n"
     "    int2 p = int2(in.pos.xy), m = int2(a.full) - 1;\n"
     "    float4 f = info.read(uint2(p)), c = src.read(uint2(p));\n"
     "    bool fin = a.final > 0.5;\n"
     "    if (f.w < -2.5 && f.w > -3.5) return fin ? eye_shine(a, zt, info, p, orig.read(uint2(p)), L) : c;\n"
     "    if (f.w > -0.5 || f.w < -1.5) return fin ? orig.read(uint2(p)) : c;\n"
     "    float w = zt.read(uint2(clamp(p / 2, int2(0), int2(a.hsize) - 1))).x;\n"
     "    float3 s = c.rgb, ws = 1.0;\n"
     // Pixels for one width at this depth.
     "    float px = w > 0.0 ? a.width * (a.dir.x > 0.5 ? a.p00 * a.full.x : a.p11 * a.full.y) * 0.5 / w : 0.0;\n"
     "    if (px > 0.3) {\n"
     "        px = min(px, 12.0);\n"
     "        const float3 sigma = float3(1.0, 0.45, 0.3);\n"
     "        for (int i = -6; i <= 6; i++) {\n"
     "            if (i == 0) continue;\n"
     "            float x = float(i) / 3.0;\n"  // up to two widths either side
     "            int2 q = clamp(p + int2(round(a.dir * x * px)), int2(0), m);\n"
     "            float3 v = c.rgb;\n"
     "            float qw = info.read(uint2(q)).w;\n"
     "            float wq = zt.read(uint2(clamp(q / 2, int2(0), int2(a.hsize) - 1))).x;\n"
     "            if (qw < -0.5 && qw > -1.5 && abs(wq - w) < 0.03 * w + 2.0) v = src.read(uint2(q)).rgb;\n"
     "            float3 k = exp(-x * x / (2.0 * sigma * sigma));\n"
     "            s += v * k, ws += k;\n"
     "        }\n"
     "    }\n"
     "    s /= ws;\n"
     "    if (!fin) return float4(s, 1.0);\n"
     "    float4 o = orig.read(uint2(p));\n"
     "    if (max(max(f.r, f.g), f.b) < 0.02) return o;\n"
     "    float3 albedo = clamp(o.rgb / max(f.rgb, 1e-3), 0.0, 4.0);\n"
     // Skin by its own colour, not the light on it.
     "    float3 al = saturate(albedo);\n"
     "    float tone = skin_tone(al);\n"
     "    float3 col = mix(o.rgb, saturate(albedo * s), a.strength * tone);\n"
     // The shine: skin's two specular lobes (broad and soft, narrower and brighter;
     // lips one tight wet one), Schlick's Fresnel from skin's 2.8% head on, lit by the
     // map's lights but as bright as the game's own light here (its share among them),
     // so it follows the game's lighting. Then a little light at the edges, where skin
     // turns away from the camera.
     "    constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
     "    float4 nn = nt.sample(ls, (float2(p) + 0.5) / a.full);\n"
     "    if (a.sheen > 0.0 && nn.w > 0.5 && tone > 0.0 && f.w > -1.1) {\n"
     "        float3 N = normalize(nn.xyz);\n"
     "        float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.full.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.full.y);\n"
     "        float3 P = float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w), V = -normalize(P);\n"
     "        float cr = 0.5 + 0.5 * al.r - 0.4187 * al.g - 0.0813 * al.b;\n"
     "        float lips = smoothstep(0.60, 0.63, cr);\n"
     "        const float3 lw = float3(0.2126, 0.7152, 0.0722);\n"
     "        float3 sp = 0.0; float E = 0.0;\n"
     "        for (int k = 0; k < int(a.nlights); k++) {\n"
     "            float3 v = L[k].pos.xyz - P;\n"
     "            float d2 = max(dot(v, v), 64.0), d = sqrt(d2);\n"
     "            float3 l = v / d;\n"
     "            float e = 1.0 / (L[k].att.x + L[k].att.y * d + L[k].att.z * d2);\n"
     "            if (L[k].pos.w > 0.0) { float x = d / L[k].pos.w; e *= saturate(1.0 - x * x * x * x); }\n"
     "            if (dot(L[k].dir.xyz, L[k].dir.xyz) > 0.25) {\n"
     "                float cs = dot(-l, L[k].dir.xyz), inner = L[k].color.w, outer = L[k].dir.w;\n"
     "                if (cs <= outer) continue;\n"
     "                if (cs < inner) e *= (cs - outer) / max(inner - outer, 1e-4);\n"
     "            }\n"
     "            float li = dot(L[k].color.rgb, lw) * e;\n"
     "            E += li;\n"
     "            float ndl = saturate(dot(N, l));\n"
     "            if (ndl <= 0.0) continue;\n"
     "            float3 H = normalize(l + V);\n"
     "            float nh = saturate(dot(N, H)), vh = saturate(dot(V, H));\n"
     "            float F = 0.028 + 0.972 * pow(1.0 - vh, 5.0);\n"
     "            float lobe = mix(0.6 * pow(nh, 12.0) * 2.5 + 0.4 * pow(nh, 48.0) * 7.0, pow(nh, 128.0) * 17.0, lips);\n"
     "            sp += L[k].color.rgb / max(dot(L[k].color.rgb, lw), 1e-4) * (li * ndl * lobe * F);\n"
     "        }\n"
     "        float lum = dot(f.rgb, lw);\n"
     // Pores: the texture's own fine detail (its brightness against its neighbours'),
     // fixed to the skin, breaks the shine up; creases lose most of it.
     "        float ad = 0.0;\n"
     "        for (int i = 0; i < 4; i++) {\n"
     "            int2 q = clamp(p + int2(i == 0 ? 1 : i == 1 ? -1 : 0, i == 2 ? 1 : i == 3 ? -1 : 0), int2(0), m);\n"
     "            float4 fq = info.read(uint2(q));\n"
     "            ad += dot(clamp(orig.read(uint2(q)).rgb / max(fq.rgb, 1e-3), 0.0, 4.0), lw);\n"
     "        }\n"
     "        float pore = clamp(dot(albedo, lw) / max(ad * 0.25, 1e-3), 0.0, 2.0);\n"
     "        float crease = 1.0 - 0.8 * saturate(nn.w - 1.0);\n"
     "        float grain = mix(1.0, pore * pore, 0.6 * (1.0 - lips));\n"
     "        if (E > 1e-6) col += a.sheen * (1.0 + 2.0 * lips) * tone * lum * grain * crease * sp / E;\n"
     "        float rim = pow(1.0 - saturate(dot(N, V)), 3.0);\n"
     "        col += 0.12 * rim * tone * crease * al * s;\n"
     "    }\n"
     "    return float4(saturate(col), o.a); }\n";

// kind 0: fog_scatter, 1: fog_blur, 2: skin_blur, 3: skin_normal, 4: fog_blur again (for
// the normals).
static id<MTLRenderPipelineState> fx_pipeline(int kind, MTLPixelFormat color)
{
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:fx_source options:nil error:&error];
        if (!lib) bl_fatal("volumetric light shader: %s", error.localizedDescription.UTF8String);
    }
    NSString *key = [NSString stringWithFormat:@"%d/%lu", kind, (unsigned long)color];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    static NSString *const names[] = {@"fog_scatter", @"fog_blur", @"skin_blur", @"skin_normal", @"fog_blur"};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"fx_vs"];
    d.fragmentFunction = [lib newFunctionWithName:names[kind]];
    d.colorAttachments[0].pixelFormat = color;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("volumetric light pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

static void fx_pass(int kind, id<MTLTexture> target, id<MTLTexture> t0, id<MTLTexture> t1, id<MTLTexture> t2,
                    id<MTLTexture> t3, id<MTLTexture> t4, const struct fx_params *a, const void *lights,
                    size_t lights_len)
{
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    static const char *const stat_names[] = {"fog_scatter", "fog_blur", "skin_blur", "skin_normal", "skin_normal_blur"};
    BLRender *e = stat_render(rp, stat_names[kind]);
    [e setRenderPipelineState:fx_pipeline(kind, target.pixelFormat)];
    id<MTLTexture> t[5] = {t0, t1, t2, t3, t4};
    for (int i = 0; i < 5; i++) [e setFragmentTexture:t[i] ? t[i] : t0 atIndex:(NSUInteger)i];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    if (lights) [e setFragmentBytes:lights length:lights_len atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// The map's brightest lights for this frame's camera, in view space (bl_bsp_lights once
// a frame, which also fades lights in and out): for the haze, the first FOG_LIGHTS, as
// bright as the camera sees them; and for the characters (char_lights), as bright as they
// are in this part of the map, so that a light the camera cannot see past a fitting (the
// bar's canopy, walking up to it) still lights the people under it. Their shine and
// contact shadows take the same first FOG_LIGHTS, their light with a direction
// (detail_bind) all CHAR_LIGHTS: picked by brightness at the camera, the lights on a
// character up ahead would drop out for ones behind it as the camera came closer.
#define CHAR_LIGHTS 64
static struct fog_light frame_lights[FOG_LIGHTS], char_lights[CHAR_LIGHTS];
static int frame_nlights, frame_nchar;
static float frame_cam[3];
static int view_lights(void)
{
    static unsigned long done = ~0ul;
    if (done == frames) return frame_nlights;
    done = frames;
    // The camera's world position: the view rows are a rotation (orthonormal) and a shift.
    float *cam = frame_cam;
    for (int k = 0; k < 3; k++)
        cam[k] = -(view_rows[0][k] * view_rows[0][3] + view_rows[1][k] * view_rows[1][3] + view_rows[2][k] * view_rows[2][3]);
    struct bl_light l[CHAR_LIGHTS];
    int n = bl_bsp_lights(cam, l, CHAR_LIGHTS);
    struct fog_light fl[CHAR_LIGHTS];
    for (int i = 0; i < n; i++) {
        for (int r = 0; r < 3; r++) {
            fl[i].pos[r] = view_rows[r][0] * l[i].pos[0] + view_rows[r][1] * l[i].pos[1] + view_rows[r][2] * l[i].pos[2] +
                           view_rows[r][3];
            fl[i].dir[r] = l[i].spot ? view_rows[r][0] * l[i].dir[0] + view_rows[r][1] * l[i].dir[1] +
                                           view_rows[r][2] * l[i].dir[2]
                                     : 0;
            fl[i].color[r] = l[i].color[r] * l[i].vis;
            fl[i].att[r] = l[i].att[r];
        }
        fl[i].pos[3] = l[i].radius, fl[i].color[3] = l[i].inner, fl[i].dir[3] = l[i].outer, fl[i].att[3] = l[i].exponent;
        char_lights[i] = fl[i];
        for (int r = 0; r < 3; r++) char_lights[i].color[r] = l[i].color[r] * l[i].seen;
        if (i < FOG_LIGHTS) frame_lights[i] = fl[i];
    }
    frame_nchar = n;
    return frame_nlights = n < FOG_LIGHTS ? n : FOG_LIGHTS;
}

static void fog_run(id<MTLTexture> z, NSUInteger hw, NSUInteger hh, struct ssr_params *p)
{
    int n = view_lights();
    if (!n) return;
    const float *cam = frame_cam;
    const struct fog_light *fl = frame_lights;
    LOG_ONCE("[metal] volumetric light: %d lights, camera %g %g %g\n", n, cam[0], cam[1], cam[2]);
    struct fx_params a = {{p->full[0], p->full[1]}, {(float)hw, (float)hh}, view_proj.p00, view_proj.p11,
                          env_fog_density, env_fog_dist, 16, (float)n};
    id<MTLTexture> raw = ao_texture(9, MTLPixelFormatRGBA16Float, hw, hh);
    post_fog = ao_texture(10, MTLPixelFormatRGBA16Float, hw, hh);
    fx_pass(0, raw, z, nil, nil, nil, nil, &a, fl, sizeof fl[0] * (size_t)n);
    fx_pass(1, post_fog, raw, z, nil, nil, nil, &a, NULL, 0);
    p->fog = 1;
}

static void skin_run(id<MTLTexture> color, id<MTLTexture> z, NSUInteger hw, NSUInteger hh, struct ssr_params *p)
{
    struct fx_params a = {{p->full[0], p->full[1]}, {(float)hw, (float)hh}, view_proj.p00, view_proj.p11};
    a.width = env_sss_width, a.strength = env_sss_strength < 0 ? 0 : env_sss_strength > 1 ? 1 : env_sss_strength;
    id<MTLTexture> info = info_texture(color);
    id<MTLTexture> across = ao_texture(11, MTLPixelFormatRGBA16Float, color.width, color.height);
    post_skin = ao_texture(12, MTLPixelFormatRGBA16Float, color.width, color.height);
    // Normals for the shine, half resolution, smoothed over the model's flat faces.
    id<MTLTexture> nraw = ao_texture(13, MTLPixelFormatRGBA16Float, hw, hh);
    id<MTLTexture> normals = ao_texture(14, MTLPixelFormatRGBA16Float, hw, hh);
    int n = env_sss_sheen > 0 ? view_lights() : 0;
    a.nlights = (float)n, a.sheen = n ? env_sss_sheen : 0;
    if (n) {
        fx_pass(3, nraw, z, info, nil, nil, nil, &a, NULL, 0);
        fx_pass(4, normals, nraw, z, nil, nil, nil, &a, NULL, 0);
    }
    a.dir[0] = 1, a.dir[1] = 0, a.final = 0;
    fx_pass(2, across, info, info, z, post_base, normals, &a, char_lights, sizeof char_lights[0]);
    a.dir[0] = 0, a.dir[1] = 1, a.final = 1;
    fx_pass(2, post_skin, across, info, z, post_base, normals, &a, n ? char_lights : NULL,
            sizeof char_lights[0] * (size_t)(n ? n : 1));
    p->skin = env_sss_show ? 2 : 1;
}

// --- contact shadows -----------------------------------------------------------------------
//
// Part of BL_SHADOWS (BL_CONTACT, default on): the small, sharp shadows where a character
// touches a surface or itself, which the atlas is too coarse for. At half resolution
// after the ambient occlusion's view depth: from each pixel, 16 steps towards the light
// that gives it the most (view_lights, the light's share of all of them), up to
// BL_CONTACT_LENGTH world units; the first step behind something drawn, at most that far
// behind, is in shadow, fading with the step's distance. Only characters (marked in the
// reflection info, d3d_shader_variant skin) cast or receive them: the map's own shadows
// are baked into its lightmaps already. The result is filtered like the occlusion and
// multiplied in at full resolution (contact_apply); BL_CONTACT_STRENGTH (0..1, default 0.5)
// is the most it darkens, BL_CONTACT=show shows it alone.

struct contact_params {
    float full[2], half[2];
    float p00, p11;
    float length, strength;
    float nlights, pad;
};

static NSString *const contact_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct CP { float2 full, hsize; float p00, p11, length, strength, nlights, pad; };\n"
     "struct FL { float4 pos, color, dir, att; };\n"  // struct fog_light
     "struct V { float4 pos [[position]]; };\n"
     "vertex V contact_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     "static float3 vpos(constant CP &a, texture2d<float> zt, int2 p) {\n"
     "    p = clamp(p, int2(0), int2(a.hsize) - 1);\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    if (w <= 0.0) w = 1e6;\n"
     "    float2 ndc = float2((float(p.x) + 0.5) * 2.0 / a.hsize.x - 1.0, 1.0 - (float(p.y) + 0.5) * 2.0 / a.hsize.y);\n"
     "    return float3(ndc.x * w / a.p00, ndc.y * w / a.p11, w); }\n"
     // A character's pixel: the reflection info's alpha is -1 or -2 there.
     "static bool person(constant CP &a, texture2d<float> info, int2 p) {\n"
     "    return info.read(uint2(min(p * 2, int2(a.full) - 1))).w < -0.5; }\n"
     "static float ign(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }\n"
     "fragment float contact_main(V in [[stage_in]], texture2d<float> zt [[texture(0)]], texture2d<float> info [[texture(1)]],\n"
     "                            constant CP &a [[buffer(0)]], constant FL *L [[buffer(1)]]) {\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    if (w <= 0.0) return 1.0;\n"
     "    float3 P = vpos(a, zt, p);\n"
     "    float3 l = vpos(a, zt, p - int2(1, 0)), r = vpos(a, zt, p + int2(1, 0));\n"
     "    float3 u = vpos(a, zt, p - int2(0, 1)), b = vpos(a, zt, p + int2(0, 1));\n"
     "    float3 dx = abs(r.z - P.z) < abs(P.z - l.z) ? r - P : P - l;\n"
     "    float3 dy = abs(b.z - P.z) < abs(P.z - u.z) ? b - P : P - u;\n"
     "    float3 N = normalize(cross(dx, dy));\n"
     "    if (dot(N, P) > 0.0) N = -N;\n"
     // The light that gives this pixel the most, and its share.
     "    const float3 lw = float3(0.2126, 0.7152, 0.0722);\n"
     "    float best = 0.0, total = 0.0; float3 bl = 0.0, bv = 0.0;\n"
     "    for (int k = 0; k < int(a.nlights); k++) {\n"
     "        float3 v = L[k].pos.xyz - P;\n"
     "        float d2 = max(dot(v, v), 64.0), d = sqrt(d2);\n"
     "        float3 ld = v / d;\n"
     "        float e = 1.0 / (L[k].att.x + L[k].att.y * d + L[k].att.z * d2);\n"
     "        if (L[k].pos.w > 0.0) { float x = d / L[k].pos.w; e *= saturate(1.0 - x * x * x * x); }\n"
     "        if (dot(L[k].dir.xyz, L[k].dir.xyz) > 0.25) {\n"
     "            float cs = dot(-ld, L[k].dir.xyz), inner = L[k].color.w, outer = L[k].dir.w;\n"
     "            if (cs <= outer) continue;\n"
     "            if (cs < inner) e *= (cs - outer) / max(inner - outer, 1e-4);\n"
     "        }\n"
     // Not weighted by how the surface faces the light: N comes from the depth, so on
     // low-poly parts (a collar) each flat face would pick its own light and the shadow
     // would come and go in whole triangles as the character moves.
     "        float li = dot(L[k].color.rgb, lw) * e;\n"
     "        total += li;\n"
     "        if (li > best) best = li, bl = ld, bv = v;\n"
     "    }\n"
     "    if (best <= 0.0) return 1.0;\n"
     // Hair (-1.4) casts them but takes none: on its layered cards they come out as specks.
     "    float iw = info.read(uint2(min(p * 2, int2(a.full) - 1))).w;\n"
     "    if (iw < -1.3 && iw > -1.5) return 1.0;\n"
     "    bool me = person(a, info, p);\n"
     "    float len = min(a.length, length(bv) * 0.9);\n"
     "    float bias = 0.3 + 0.004 * w, thick = max(a.length, 0.02 * w);\n"
     "    float3 O = P + N * (0.002 * w);\n"
     // pad: a frame number under TAA, so the grain moves and the scaler averages it out.
     "    float j = ign(float2(p) + a.pad * 5.588238), occ = 0.0;\n"
     "    const int STEPS = 16;\n"
     "    for (int i = 0; i < STEPS; i++) {\n"
     "        float t = (float(i) + j) / float(STEPS);\n"
     "        float3 Q = O + bl * (len * t);\n"
     "        if (Q.z <= 1.0) break;\n"
     "        float2 ndc = float2(Q.x * a.p00, Q.y * a.p11) / Q.z;\n"
     "        float2 q = float2(ndc.x + 1.0, 1.0 - ndc.y) * 0.5 * a.hsize;\n"
     "        if (any(q < 0.0) || any(q >= a.hsize)) break;\n"
     "        int2 qi = int2(q);\n"
     "        if (all(qi == p)) continue;\n"
     // Not the surface it starts on: the next flat face of the same fold, within a
     // world unit or so, would shade it in triangles.
     "        if (len * t < 1.0 + 0.004 * w) continue;\n"
     "        float zs = zt.read(uint2(qi)).x;\n"
     "        if (zs <= 0.0) continue;\n"
     "        float diff = Q.z - zs;\n"
     "        if (diff > bias && diff < thick && (me || person(a, info, qi))) { occ = 1.0 - t * t; break; }\n"
     "    }\n"
     "    return 1.0 - a.strength * occ * best / total; }\n";

static id<MTLRenderPipelineState> contact_pipeline(void)
{
    static id<MTLRenderPipelineState> p;
    if (p) return p;
    NSError *error = nil;
    id<MTLLibrary> lib = [mtl newLibraryWithSource:contact_source options:nil error:&error];
    if (!lib) bl_fatal("contact shadow shader: %s", error.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"contact_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"contact_main"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatR16Float;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("contact shadow pipeline: %s", error.localizedDescription.UTF8String);
    return p;
}

static struct ao_params contact_result_params;

// From post_run, with the half-resolution view depth z (ao_pass kind 0) and its parameters.
static void contact_run(id<MTLTexture> color, id<MTLTexture> z, const struct ao_params *ap)
{
    int n = view_lights();
    if (!n) return;
    struct contact_params c = {{ap->full[0], ap->full[1]}, {ap->half[0], ap->half[1]}, ap->p00, ap->p11,
                               env_contact_length, env_contact_strength, (float)n, (float)(frames % 16)};
    NSUInteger hw = (NSUInteger)ap->half[0], hh = (NSUInteger)ap->half[1];
    id<MTLTexture> raw = ao_texture(15, MTLPixelFormatR16Float, hw, hh);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = raw;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:contact_pipeline()];
    [e setFragmentTexture:z atIndex:0];
    [e setFragmentTexture:info_texture(color) atIndex:1];
    [e setFragmentBytes:&c length:sizeof c atIndex:0];
    [e setFragmentBytes:char_lights length:sizeof char_lights[0] * (size_t)n atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    // The occlusion's depth-aware filter, then its multiply at full strength.
    id<MTLTexture> soft = ao_texture(16, MTLPixelFormatRG32Float, hw, hh);
    ao_pass(2, soft, raw, z, ap);
    contact_result = soft, contact_result_params = *ap;
    contact_result_params.strength = 1;
}

// Called by pass() for a new pass on the back buffer, after ao_apply.
static void contact_apply(BLRender *e, id<MTLTexture> color, int has_depth)
{
    MTLPixelFormat df = has_depth ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    [e setRenderPipelineState:ao_pipeline(env_contact_show ? 4 : 3, color.pixelFormat, df)];
    static id<MTLDepthStencilState> none;
    if (!none) none = [mtl newDepthStencilStateWithDescriptor:[MTLDepthStencilDescriptor new]];
    [e setDepthStencilState:none];
    [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){0, 0, color.width, color.height, 0, 1}];
    [e setScissorRect:(MTLScissorRect){0, 0, color.width, color.height}];
    [e setFragmentTexture:contact_result atIndex:0];
    [e setFragmentBytes:&contact_result_params length:sizeof contact_result_params atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    contact_result = nil;
}

// --- temporal anti-aliasing --------------------------------------------------------------
//
// The anti-aliasing: MetalFX's temporal scaler at the back buffer's own size (there is no
// multisampling). Each frame the world view's draws move by a
// different fraction of a pixel (a Halton 2,3 pattern of 8, added to D3D9's half-pixel
// offset in d3d_vs_params.inv_viewport), and the scaler blends the frame with the ones
// before it, following motion vectors. Those are the camera's alone (taa_motion): each
// pixel's depth taken back to a position with this frame's view-projection and forward
// with the last one's, so moving characters and props are blended as if they stood still.
// The camera is the view-projection most of the world view's draws without bones used
// (taa_note_camera): the map's brushes all share it, while each prop carries its own model
// transform. post_run makes the motion vectors and a copy of the depth (the game may clear
// its own before the view model); the next pass on the back buffer, once the effects are
// drawn in, runs the scaler on the result and copies it back (taa_resolve), so the view
// model and HUD stay out of it. The history is dropped after a frame without a world view,
// on a size change and when the camera cuts. The offset spans half a pixel by default: the
// scaler does not quite settle a full pixel's on thin, bright things (bottles shimmered).
// BL_TAA_JITTER=n sets the span (1: a whole pixel, 0: none); negative flips the sign of
// the offset handed to MetalFX (for testing which way it wants it).

#define TAA_CAMS 16
static struct { float m[4][4]; int n; } taa_cams[TAA_CAMS];
static int taa_ncams, taa_reset = 1, taa_done, taa_have_prev;
static double taa_prev[4][4];  // the last resolved frame's view-projection
static unsigned taa_phase;
static float taa_jitter_sign;
static id<MTL4FXTemporalScaler> taa_scaler;
static id<MTLTexture> taa_in, taa_out, taa_mv, taa_z;

static void taa_note_camera(const float r8[4], const float r9[4], const float r10[4], const float r11[4], float clip_y)
{
    float m[4][4];
    memcpy(m[0], r8, sizeof m[0]);
    for (int k = 0; k < 4; k++) m[1][k] = r9[k] * clip_y;
    memcpy(m[2], r10, sizeof m[2]);
    memcpy(m[3], r11, sizeof m[3]);
    for (int i = 0; i < taa_ncams; i++)
        if (!memcmp(taa_cams[i].m, m, sizeof m)) {
            taa_cams[i].n++;
            return;
        }
    if (taa_ncams < TAA_CAMS) memcpy(taa_cams[taa_ncams].m, m, sizeof m), taa_cams[taa_ncams++].n = 1;
}

// A depth clear on the back buffer before the world view (after a sky box) starts over.
static void taa_forget_camera(void) { taa_ncams = 0; }

static int invert4d(const double m[4][4], double out[4][4])
{
    double a[4][8];
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 8; j++) a[i][j] = j < 4 ? m[i][j] : (j - 4 == i);
    for (int c = 0; c < 4; c++) {
        int p = c;
        for (int i = c + 1; i < 4; i++)
            if (fabs(a[i][c]) > fabs(a[p][c])) p = i;
        if (fabs(a[p][c]) < 1e-15) return 0;
        for (int j = 0; j < 8; j++) {
            double t = a[c][j];
            a[c][j] = a[p][j], a[p][j] = t;
        }
        double d = 1 / a[c][c];
        for (int j = 0; j < 8; j++) a[c][j] *= d;
        for (int i = 0; i < 4; i++) {
            if (i == c) continue;
            double f = a[i][c];
            for (int j = 0; j < 8; j++) a[i][j] -= f * a[c][j];
        }
    }
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) out[i][j] = a[i][j + 4];
    return 1;
}

static float halton(unsigned i, unsigned b)
{
    float f = 1, r = 0;
    for (; i; i /= b) f /= (float)b, r += f * (float)(i % b);
    return r;
}

// The scaler and its textures for a w x h picture.
static void taa_setup(NSUInteger w, NSUInteger h)
{
    if (taa_scaler && taa_scaler.inputWidth == w && taa_scaler.inputHeight == h) return;
    taa_scaler = nil;
    MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
    d.colorTextureFormat = d.outputTextureFormat = MTLPixelFormatRGBA16Float;
    d.depthTextureFormat = MTLPixelFormatDepth32Float;
    d.motionTextureFormat = MTLPixelFormatRG16Float;
    d.inputWidth = d.outputWidth = w;
    d.inputHeight = d.outputHeight = h;
    static id<MTL4Compiler> compiler;
    if (!compiler) compiler = [mtl newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
    taa_scaler = [d newTemporalScalerWithDevice:mtl compiler:compiler];
    taa_scaler.fence = mtl4_fence();  // in order with the passes around it
    if (!taa_scaler) bl_fatal("TAA: MetalFX made no temporal scaler for %lux%lu", (unsigned long)w, (unsigned long)h);
    MTLTextureUsage usage[4] = {taa_scaler.colorTextureUsage, taa_scaler.outputTextureUsage,
                                taa_scaler.motionTextureUsage, taa_scaler.depthTextureUsage};
    MTLPixelFormat pf[4] = {MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA16Float, MTLPixelFormatRG16Float,
                            MTLPixelFormatDepth32Float};
    id<MTLTexture> __strong *t[4] = {&taa_in, &taa_out, &taa_mv, &taa_z};
    static NSString *const labels[4] = {@"TAA input", @"TAA output", @"TAA motion", @"TAA depth"};
    for (int i = 0; i < 4; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf[i] width:w height:h
                                                                                  mipmapped:NO];
        td.usage = usage[i] | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        *t[i] = [mtl newTextureWithDescriptor:td];
        (*t[i]).label = labels[i];
    }
    taa_reset = 1;
    LOG_ONCE("[metal] TAA: MetalFX temporal scaler at %lux%lu\n", (unsigned long)w, (unsigned long)h);
}

static NSString *const taa_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct TP { float4x4 reproj; float2 size, offset; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "struct TO { float2 motion [[color(0)]]; float depth [[depth(any)]]; };\n"
     "vertex V taa_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     // The pixel's place without this frame's offset (`offset`, what the vertex shaders
     // added), taken to the last frame's clip space: the motion vector points there, in
     // texture coordinates (scaled to pixels by the scaler).
     "fragment TO taa_motion(V in [[stage_in]], depth2d<float> z [[texture(0)]], constant TP &p [[buffer(0)]]) {\n"
     "    float d = z.read(uint2(in.pos.xy));\n"
     "    float2 ndc = float2(in.pos.x / p.size.x * 2.0 - 1.0, 1.0 - in.pos.y / p.size.y * 2.0) - p.offset;\n"
     "    float4 q = p.reproj * float4(ndc, d, 1.0);\n"
     "    float2 prev = q.w > 1e-6 ? q.xy / q.w : ndc;\n"
     "    TO o; o.motion = (prev - ndc) * float2(0.5, -0.5); o.depth = d; return o; }\n"
     // The scaler's picture back into the back buffer, colour only (taa_resolve), sharpened
     // when `sharpen` (0..1) is above 0: contrast adaptive like AMD's CAS, from the four
     // neighbours, less where they already differ a lot and not at all past white (HDR).
     "fragment float4 taa_copy(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
     "                         constant float &sharpen [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), m = int2(t.get_width(), t.get_height()) - 1;\n"
     "    float4 c = t.read(uint2(p));\n"
     "    if (sharpen <= 0.0) return c;\n"
     "    float3 n = t.read(uint2(clamp(p - int2(0, 1), int2(0), m))).rgb;\n"
     "    float3 w = t.read(uint2(clamp(p - int2(1, 0), int2(0), m))).rgb;\n"
     "    float3 e = t.read(uint2(clamp(p + int2(1, 0), int2(0), m))).rgb;\n"
     "    float3 s = t.read(uint2(clamp(p + int2(0, 1), int2(0), m))).rgb;\n"
     "    float3 mn = min(min(min(n, w), min(e, s)), c.rgb), mx = max(max(max(n, w), max(e, s)), c.rgb);\n"
     "    float3 k = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4))) * (-1.0 / mix(8.0, 5.0, sharpen));\n"
     "    return float4(max(((n + w + e + s) * k + c.rgb) / (1.0 + 4.0 * k), 0.0), c.a); }\n";

// kind 0: the motion vectors and depth copy; 1: the copy back into a `color` target.
static id<MTLRenderPipelineState> taa_pipeline(int kind, MTLPixelFormat color)
{
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:taa_source options:nil error:&error];
        if (!lib) bl_fatal("TAA shader: %s", error.localizedDescription.UTF8String);
    }
    NSNumber *key = @(color * 2 + (NSUInteger)kind);
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"taa_vs"];
    d.fragmentFunction = [lib newFunctionWithName:kind ? @"taa_copy" : @"taa_motion"];
    d.colorAttachments[0].pixelFormat = color;
    if (kind) d.colorAttachments[0].writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    else d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("TAA pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

// From post_run, with the world view's depth (single-sampled) and size; 0 when this frame
// has no camera to go by.
static int taa_motion(id<MTLTexture> depth, NSUInteger w, NSUInteger h)
{
    int best = -1;
    for (int i = 0; i < taa_ncams; i++)
        if (taa_cams[i].n >= 2 && (best < 0 || taa_cams[i].n > taa_cams[best].n)) best = i;
    if (best < 0) return 0;
    taa_setup(w, h);
    double cur[4][4], inv[4][4], reproj[4][4];
    for (int i = 0; i < 4; i++)
        for (int k = 0; k < 4; k++) cur[i][k] = taa_cams[best].m[i][k];
    if (!invert4d(cur, inv)) return 0;
    // A cut: the view turned by more than about 25 degrees, the camera jumped more than 64
    // units (its position: where x, y and w are all 0) or the field of view changed.
    int cut = !taa_have_prev;
    if (!cut) {
        double cp[2][3], fw[2][3], zoom[2];
        double inv_prev[4][4];
        if (!invert4d(taa_prev, inv_prev)) cut = 1;
        const double(*m[2])[4] = {taa_prev, cur}, (*mi[2])[4] = {inv_prev, inv};
        for (int f = 0; f < 2 && !cut; f++) {
            double hw = mi[f][3][2], lw = 0, lx = 0;
            for (int k = 0; k < 3; k++) cp[f][k] = hw != 0 ? mi[f][k][2] / hw : 0;
            for (int k = 0; k < 3; k++) lw += m[f][3][k] * m[f][3][k], lx += m[f][0][k] * m[f][0][k];
            for (int k = 0; k < 3; k++) fw[f][k] = lw > 0 ? m[f][3][k] / sqrt(lw) : 0;
            zoom[f] = lw > 0 ? sqrt(lx / lw) : 0;
        }
        if (!cut) {
            double dot = fw[0][0] * fw[1][0] + fw[0][1] * fw[1][1] + fw[0][2] * fw[1][2];
            double dx = cp[0][0] - cp[1][0], dy = cp[0][1] - cp[1][1], dz = cp[0][2] - cp[1][2];
            cut = dot < 0.9 || dx * dx + dy * dy + dz * dz > 64.0 * 64.0 || fabs(zoom[0] - zoom[1]) > 0.01 * zoom[1];
        }
    }
    const double(*from)[4] = cut ? cur : taa_prev;
    for (int i = 0; i < 4; i++)
        for (int k = 0; k < 4; k++) {
            double v = 0;
            for (int j = 0; j < 4; j++) v += from[i][j] * inv[j][k];
            reproj[i][k] = v;
        }
    struct { float reproj[4][4]; float size[2], offset[2]; } p;
    for (int i = 0; i < 4; i++)
        for (int k = 0; k < 4; k++) p.reproj[k][i] = (float)reproj[i][k];  // columns
    p.size[0] = (float)w, p.size[1] = (float)h;
    p.offset[0] = (1 + 2 * taa_jitter[0]) / (float)w, p.offset[1] = -(1 + 2 * taa_jitter[1]) / (float)h;
    memcpy(ssr_reproj.reproj, p.reproj, sizeof p.reproj), memcpy(ssr_reproj.offset, p.offset, sizeof p.offset);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = taa_mv;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = taa_z;
    rp.depthAttachment.loadAction = MTLLoadActionDontCare;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:taa_pipeline(0, MTLPixelFormatRG16Float)];
    static id<MTLDepthStencilState> always;
    if (!always) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = YES;
        always = [mtl newDepthStencilStateWithDescriptor:dd];
    }
    [e setDepthStencilState:always];
    [e setFragmentTexture:depth atIndex:0];
    [e setFragmentBytes:&p length:sizeof p atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    memcpy(taa_prev, cur, sizeof taa_prev);
    taa_have_prev = 1;
    if (cut) taa_reset = 1;
    return 1;
}

// From pass(), on the back buffer's texture once the effects are drawn in.
static void taa_resolve(id<MTLTexture> color)
{
    NSUInteger w = color.width, h = color.height;
    if (!taa_scaler || taa_in.width != w || taa_in.height != h) return;
    uint32_t r[4] = {0, 0, (uint32_t)w, (uint32_t)h};
    stretch_draw(color, r, taa_in, r, 0);
    taa_scaler.colorTexture = taa_in;
    taa_scaler.depthTexture = taa_z;
    taa_scaler.motionTexture = taa_mv;
    taa_scaler.outputTexture = taa_out;
    taa_scaler.inputContentWidth = w;
    taa_scaler.inputContentHeight = h;
    taa_scaler.jitterOffsetX = taa_jitter_sign * taa_jitter[0];
    taa_scaler.jitterOffsetY = taa_jitter_sign * taa_jitter[1];
    taa_scaler.motionVectorScaleX = (float)w;
    taa_scaler.motionVectorScaleY = (float)h;
    taa_scaler.depthReversed = NO;
    taa_scaler.reset = taa_reset;
    mtl4_track(taa_in), mtl4_track(taa_z), mtl4_track(taa_mv), mtl4_track(taa_out);
    [taa_scaler encodeToCommandBuffer:command_buffer()];
    // Colour only: the game never clears the back buffer, so its alpha (which the scaler
    // need not keep) stays the game's own for the next frame's draws.
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = color;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:taa_pipeline(1, color.pixelFormat)];
    [e setFragmentTexture:taa_out atIndex:0];
    float sharpen = env_sharpen ? fminf(fmaxf(env_sharpen_strength, 0), 1) : 0;
    [e setFragmentBytes:&sharpen length:sizeof sharpen atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    taa_reset = 0, taa_done = 1;
}

// From present: the next frame's offset; a frame the scaler did not see breaks the history.
static void taa_frame_end(void)
{
    static float scale = 2;  // BL_TAA_JITTER: the span in pixels, negative flipped for MetalFX
    static int resolved;
    if (scale == 2) scale = getenv("BL_TAA_JITTER") ? (float)atof(getenv("BL_TAA_JITTER")) : 0.5f;
    taa_jitter_sign = scale < 0 ? -1 : 1;
    resolved += taa_done;
    if (frames % 100 == 0) {
        fprintf(stderr, "[metal] TAA: %d of the last 100 frames through the scaler\n", resolved);
        resolved = 0;
    }
    if (!taa_done) taa_have_prev = 0, taa_reset = 1;
    taa_done = 0, taa_pending = 0, taa_ncams = 0;
    taa_phase = taa_phase % 8 + 1;
    taa_jitter[0] = fabsf(scale) * (halton(taa_phase, 2) - 0.5f);
    taa_jitter[1] = fabsf(scale) * (halton(taa_phase, 3) - 0.5f);
}

// --- bloom and eye adaptation ---------------------------------------------------------
//
// Both work on the world view's own colours (post_run's copy, before the HUD), with no HDR:
// - Bloom (BL_BLOOM, bloom_run): what is brighter than BL_BLOOM_THRESHOLD (by luminance,
//   with a soft knee; each pixel weighted down by its brightness against single-pixel
//   flicker) is halved in size six times and spread back up, each level adding the next
//   one's blur (dual filtering), and post_apply adds BL_BLOOM_STRENGTH of it: lamps, neon
//   and lit windows glow into the dark around them.
// - Eye adaptation (BL_EXPOSURE, exposure_run): the view's brightness, the geometric mean
//   of 64x36 points weighted to the middle, against a typical Bloodlines scene (0.095 in
//   the game's colours, measured over many views): the exposure goes some of the way
//   towards evening it out (the 0.4th power, within BL_EXPOSURE_RANGE), over about a
//   second and a half, so a dark street lifts a little and a lit room dims. It stays on
//   the GPU (a buffer post_apply reads); "show" draws it as a bar at the top.
// post_apply scales the colour by the exposure, adds the glow, and rolls off what that
// pushes past white.
static id<MTLTexture> post_glow, post_bounce;
#define BLOOM_LEVELS 6
#define EXPOSURE_REF 0.095f

static id<MTLTexture> bloom_texture(int i, NSUInteger w, NSUInteger h)
{
    static id<MTLTexture> t[2 * BLOOM_LEVELS + 1];
    MTLPixelFormat pf = i == 2 * BLOOM_LEVELS ? MTLPixelFormatR16Float : MTLPixelFormatRGBA16Float;
    if (!t[i] || t[i].width != w || t[i].height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t[i] = [mtl newTextureWithDescriptor:td];
    }
    return t[i];
}

struct bloom_params {
    float src[2];             // the source's size in pixels
    float threshold, knee;    // bright pass
    float ref, power;         // exposure: the typical brightness, how far to even it out
    float lo, hi;             // and its range
    float rate;               // the share of the way to go this frame (0: jump there)
    float pad[3];
};

static NSString *const bloom_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct BP { float2 src; float threshold, knee, ref, power, lo, hi, rate; float3 pad; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V bloom_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     "constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
     "static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }\n"
     // Half size: four bilinear reads (a 4x4 box), each the bright part of its colour,
     // weighted by 1 / (1 + luminance) so one bright pixel does not flicker as a blob.
     "fragment float4 bloom_bright(V in [[stage_in]], texture2d<float> src [[texture(0)]], constant BP &b [[buffer(0)]]) {\n"
     "    float2 uv = in.pos.xy * 2.0 / b.src, d = 1.0 / b.src;\n"
     "    float3 sum = 0.0; float ws = 0.0;\n"
     "    for (int i = 0; i < 4; i++) {\n"
     "        float3 c = src.sample(ls, uv + d * float2(i & 1 ? 1.0 : -1.0, i & 2 ? 1.0 : -1.0)).rgb;\n"
     "        float l = luma(c), x = clamp(l - b.threshold + b.knee, 0.0, 2.0 * b.knee);\n"
     "        float k = max(x * x / (4.0 * b.knee + 1e-5), l - b.threshold) / max(l, 1e-4);\n"
     "        float w = 1.0 / (1.0 + l);\n"
     "        sum += c * max(k, 0.0) * w, ws += w;\n"
     "    }\n"
     "    return float4(sum / ws, 1.0); }\n"
     // Half size again: the centre and four diagonal reads (dual filtering's down step).
     "fragment float4 bloom_down(V in [[stage_in]], texture2d<float> src [[texture(0)]], constant BP &b [[buffer(0)]]) {\n"
     "    float2 uv = in.pos.xy * 2.0 / b.src, d = 1.0 / b.src;\n"
     "    float3 c = src.sample(ls, uv).rgb * 4.0;\n"
     "    c += src.sample(ls, uv + float2(-d.x, -d.y)).rgb + src.sample(ls, uv + float2(d.x, -d.y)).rgb;\n"
     "    c += src.sample(ls, uv + float2(-d.x, d.y)).rgb + src.sample(ls, uv + float2(d.x, d.y)).rgb;\n"
     "    return float4(c / 8.0, 1.0); }\n"
     // Back up: this level plus the smaller one's blur (a tent of nine reads).
     "fragment float4 bloom_up(V in [[stage_in]], texture2d<float> here [[texture(0)]], texture2d<float> small [[texture(1)]],\n"
     "                         constant BP &b [[buffer(0)]]) {\n"
     "    float2 uv = in.pos.xy / b.src, d = 1.0 / b.src;\n"
     "    float3 c = small.sample(ls, uv).rgb * 4.0;\n"
     "    c += (small.sample(ls, uv + float2(-d.x, 0.0)).rgb + small.sample(ls, uv + float2(d.x, 0.0)).rgb +\n"
     "          small.sample(ls, uv + float2(0.0, -d.y)).rgb + small.sample(ls, uv + float2(0.0, d.y)).rgb) * 2.0;\n"
     "    c += small.sample(ls, uv - d).rgb + small.sample(ls, uv + d).rgb + small.sample(ls, uv + float2(d.x, -d.y)).rgb +\n"
     "         small.sample(ls, uv + float2(-d.x, d.y)).rgb;\n"
     "    return float4(here.read(uint2(in.pos.xy)).rgb + c / 16.0, 1.0); }\n"
     // 64x36 points of the view: the log of their luminance (four reads each).
     "fragment float bloom_lum(V in [[stage_in]], texture2d<float> src [[texture(0)]], constant BP &b [[buffer(0)]]) {\n"
     "    float2 uv = in.pos.xy / float2(64.0, 36.0), d = 0.25 / float2(64.0, 36.0);\n"
     "    float l = 0.0;\n"
     "    for (int i = 0; i < 4; i++) l += luma(src.sample(ls, uv + d * float2(i & 1 ? 1.0 : -1.0, i & 2 ? 1.0 : -1.0)).rgb);\n"
     "    return log(max(l * 0.25, 1e-3)); }\n"
     // One group: the weighted mean, the exposure it asks for, and a step towards it.
     "kernel void bloom_adapt(texture2d<float> lt [[texture(0)]], device float *eye [[buffer(1)]],\n"
     "                        constant BP &b [[buffer(0)]], uint t [[thread_index_in_threadgroup]]) {\n"
     "    threadgroup float sl[256], sw[256];\n"
     "    float l = 0.0, w = 0.0;\n"
     "    for (uint i = t; i < 64 * 36; i += 256) {\n"
     "        float2 q = (float2(i % 64, i / 64) + 0.5) / float2(64.0, 36.0) * 2.0 - 1.0;\n"
     "        float k = clamp(1.0 - 0.5 * dot(q, q), 0.25, 1.0);\n"
     "        l += k * lt.read(uint2(i % 64, i / 64)).x, w += k;\n"
     "    }\n"
     "    sl[t] = l, sw[t] = w;\n"
     "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
     "    for (uint s = 128; s > 0; s >>= 1) {\n"
     "        if (t < s) sl[t] += sl[t + s], sw[t] += sw[t + s];\n"
     "        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
     "    }\n"
     "    if (t == 0) {\n"
     "        float mean = exp(sl[0] / sw[0]), want = clamp(pow(b.ref / mean, b.power), b.lo, b.hi);\n"
     "        eye[0] = b.rate <= 0.0 || !(eye[0] > 0.0) ? want : mix(eye[0], want, b.rate);\n"
     "        eye[1] = mean;\n"
     "    }\n"
     "}\n";

static id<MTLLibrary> bloom_library(void)
{
    static id<MTLLibrary> lib;
    if (!lib) {
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:bloom_source options:nil error:&error];
        if (!lib) bl_fatal("bloom shader: %s", error.localizedDescription.UTF8String);
    }
    return lib;
}

// 0 bright, 1 down, 2 up (RGBA16Float), 3 luminance (R16Float).
static id<MTLRenderPipelineState> bloom_pipeline(int kind)
{
    static id<MTLRenderPipelineState> p[4];
    if (p[kind]) return p[kind];
    static NSString *const names[] = {@"bloom_bright", @"bloom_down", @"bloom_up", @"bloom_lum"};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [bloom_library() newFunctionWithName:@"bloom_vs"];
    d.fragmentFunction = [bloom_library() newFunctionWithName:names[kind]];
    d.colorAttachments[0].pixelFormat = kind == 3 ? MTLPixelFormatR16Float : MTLPixelFormatRGBA16Float;
    NSError *error = nil;
    p[kind] = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p[kind]) bl_fatal("bloom pipeline: %s", error.localizedDescription.UTF8String);
    return p[kind];
}

static void bloom_pass(int kind, id<MTLTexture> target, id<MTLTexture> t0, id<MTLTexture> t1, const struct bloom_params *b)
{
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:bloom_pipeline(kind)];
    [e setFragmentTexture:t0 atIndex:0];
    [e setFragmentTexture:t1 atIndex:1];
    [e setFragmentBytes:b length:sizeof *b atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

static struct bloom_params bloom_base(void)
{
    struct bloom_params b = {{0, 0}, env_bloom_threshold, 0.2f, EXPOSURE_REF, 0.4f, env_exposure_lo, env_exposure_hi, 0};
    return b;
}

// The glow at half size (post_apply adds it).
static id<MTLTexture> bloom_run(id<MTLTexture> color)
{
    struct bloom_params b = bloom_base();
    id<MTLTexture> down[BLOOM_LEVELS], src = color;
    NSUInteger w = color.width, h = color.height;
    for (int i = 0; i < BLOOM_LEVELS; i++) {
        w = (w + 1) / 2, h = (h + 1) / 2;
        down[i] = bloom_texture(i, w ? w : 1, h ? h : 1);
        b.src[0] = (float)src.width, b.src[1] = (float)src.height;
        bloom_pass(i ? 1 : 0, down[i], src, nil, &b);
        src = down[i];
    }
    id<MTLTexture> up = down[BLOOM_LEVELS - 1];
    for (int i = BLOOM_LEVELS - 2; i >= 0; i--) {
        id<MTLTexture> out = bloom_texture(BLOOM_LEVELS + i, down[i].width, down[i].height);
        b.src[0] = (float)down[i].width, b.src[1] = (float)down[i].height;
        bloom_pass(2, out, down[i], up, &b);
        up = out;
    }
    return up;
}

static id<MTLBuffer> exposure_buffer(void)
{
    static id<MTLBuffer> buf;
    if (!buf) {
        buf = [mtl newBufferWithLength:16 options:MTLResourceStorageModeShared];
        float one[4] = {1, EXPOSURE_REF, 0, 0};
        memcpy(buf.contents, one, sizeof one);
    }
    return buf;
}

// The eye's exposure for this frame, into exposure_buffer.
static void exposure_run(id<MTLTexture> color)
{
    static id<MTLComputePipelineState> adapt;
    static double last;
    if (!adapt) {
        NSError *error = nil;
        adapt = [mtl newComputePipelineStateWithFunction:[bloom_library() newFunctionWithName:@"bloom_adapt"]
                                                   error:&error];
        if (!adapt) bl_fatal("eye adaptation: %s", error.localizedDescription.UTF8String);
    }
    struct bloom_params b = bloom_base();
    double now = CFAbsoluteTimeGetCurrent(), dt = last ? now - last : 0;
    last = now;
    // About 1.5 s to adapt (63% in 0.5 s); a long gap (a load, a menu) jumps there.
    b.rate = dt > 0.5 ? 0 : (float)(1 - exp(-dt / 0.5));
    id<MTLTexture> lum = bloom_texture(2 * BLOOM_LEVELS, 64, 36);
    bloom_pass(3, lum, color, nil, &b);
    BLCompute *e = stat_compute(__func__);
    [e setComputePipelineState:adapt];
    [e setTexture:lum atIndex:0];
    [e setBytes:&b length:sizeof b atIndex:0];
    [e setBuffer:exposure_buffer() offset:0 atIndex:1];
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [e endEncoding];
}

// --- bounced light ----------------------------------------------------------------------
//
// Screen-space indirect lighting (BL_SSIL, ssil_run): light bounced off what is on screen
// onto what is near it, so the bar's green neon tints the floor and stools and a club's red
// lights the walls and people around them. The map's lightmaps already hold the light
// bounced between walls and floors; this adds what they cannot: bright things on screen and
// the characters and props among them. A port of Godot 4.4's SSIL (Intel's ASSAO turned
// into indirect light by Godot's renderer team) with kubaofc123's changes (twice the taps,
// interleaved gradient noise in place of the precomputed rotations, a smaller sampling
// disk), all MIT licensed:
//
//   Copyright (c) 2016, Intel Corporation
//   Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
//   Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this
//   software and associated documentation files (the "Software"), to deal in the Software
//   without restriction, including without limitation the rights to use, copy, modify,
//   merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to the following
//   conditions: The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
//   WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
//   WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
//   OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
//   OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Godot's "high" preset (12 taps of two samples, depth copies for the longer ones, depth
// edges, haloing reduction), with these differences: it runs at half resolution on the
// AO's view depth and its smaller copies instead of four deinterleaved quarter-resolution
// layers (each pixel takes the sample pattern of the layer it would be in, so neighbours
// differ as there); the normals are rebuilt from that depth; the colour is this frame's
// world view (Godot's runs before the frame's lighting and reads last frame's, reprojected),
// as a half-resolution copy with mipmaps read at Godot's level (1/32 of the screen); no
// adaptive pass. Godot then multiplies the result by each surface's albedo; here the
// game's shaders also write their surface's colour texture (albedo_texture, d3d_shader_variant
// albedo), and post_apply multiplies by that. Last frame's bounced light is added into the colour it
// reads (at half strength), so light bounces on again from what it lit and reaches round
// corners. The half-resolution result is brought to full resolution guided by the depth
// buffer, so it does not leak across the outlines of things in front. BL_SSIL=1 turns it
// on (the options' check box), BL_SSIL=show shows the bounced light alone and
// BL_SSIL=albedo the surfaces' colour; BL_SSIL_RADIUS
// (world units, default 128), BL_SSIL_STRENGTH (default 1), BL_SSIL_BLUR (edge-aware blur
// passes, default 2). Under TAA the noise pattern turns each frame and the result is
// blended with last frame's.

struct ssil_params {
    float hsize[2], px[2];         // half-resolution size, and one pixel of it in uv
    float p00, p11;                // projection scales in x and y
    float radius, intensity;
    float inv_radius_near_limit, neg_inv_radius;
    float fade_mul, fade_add;      // fade out with distance: saturate(depth * mul + add)
    float normal_rejection, edge_sharpness;
    float color_level, frame;      // the colour copy's mipmap level read; the noise's frame (0 without TAA)
    float alpha, beta;             // the depth buffer to view depth: beta / (d - alpha)
    float full[2];                 // full-resolution size
    float feedback, use_mv;        // last frame's bounced light added into the colour this much; reprojected
};

static NSString *const ssil_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct SLP { float2 hsize, px; float p00, p11, radius, intensity, inv_radius_near_limit, neg_inv_radius,\n"
     "             fade_mul, fade_add, normal_rejection, edge_sharpness, color_level, frame,\n"
     "             alpha, beta; float2 full; float feedback, use_mv; };\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V ssil_vs(uint id [[vertex_id]]) {\n"
     "    V v; float2 t = float2((id << 1) & 2, id & 2); v.pos = float4(t * 2.0 - 1.0, 0.0, 1.0); return v; }\n"
     "constant float4 sample_pattern[32] = {\n"
     "    float4(0.78488064, 0.56661671, 1.500000, -0.126083), float4(0.26022232, -0.29575172, 1.500000, -1.064030),\n"
     "    float4(0.10459357, 0.08372527, 1.110000, -2.730563), float4(-0.68286800, 0.04963045, 1.090000, -0.498827),\n"
     "    float4(-0.13570161, -0.64190155, 1.250000, -0.532765), float4(-0.26193795, -0.08205118, 0.670000, -1.783245),\n"
     "    float4(-0.61177456, 0.66664219, 0.710000, -0.044234), float4(0.43675563, 0.25119025, 0.610000, -1.167283),\n"
     "    float4(0.07884444, 0.86618668, 0.640000, -0.459002), float4(-0.12790935, -0.29869005, 0.600000, -1.729424),\n"
     "    float4(-0.04031125, 0.02413622, 0.600000, -4.792042), float4(0.16201244, -0.52851415, 0.790000, -1.067055),\n"
     "    float4(-0.70991218, 0.47301072, 0.640000, -0.335236), float4(0.03277707, -0.22349690, 0.600000, -1.982384),\n"
     "    float4(0.68921727, 0.36800742, 0.630000, -0.266718), float4(0.29251814, 0.37775412, 0.610000, -1.422520),\n"
     "    float4(-0.12224089, 0.96582592, 0.600000, -0.426142), float4(0.11071457, -0.16131058, 0.600000, -2.165947),\n"
     "    float4(0.46562141, -0.59747696, 0.600000, -0.189760), float4(-0.51548797, 0.11804193, 0.600000, -1.246800),\n"
     "    float4(0.89141309, -0.42090443, 0.600000, 0.028192), float4(-0.32402530, -0.01591529, 0.600000, -1.543018),\n"
     "    float4(0.60771245, 0.41635221, 0.600000, -0.605411), float4(0.02379565, -0.08239821, 0.600000, -3.809046),\n"
     "    float4(0.48951152, -0.23657045, 0.600000, -1.189011), float4(-0.17611565, -0.81696892, 0.600000, -0.513724),\n"
     "    float4(-0.33930185, -0.20732205, 0.600000, -1.698047), float4(-0.91974425, 0.05403209, 0.600000, 0.062246),\n"
     "    float4(-0.15064627, -0.14949332, 0.600000, -1.896062), float4(0.53180975, -0.35210401, 0.600000, -0.758838),\n"
     "    float4(0.41487166, 0.81442589, 0.600000, -0.505648), float4(-0.24106961, -0.32721516, 0.600000, -1.665244)};\n"
     "constant float3 luma = float3(0.299, 0.587, 0.114);\n"
     // A view-space position from a uv on the screen and its view depth (x right, y up,
     // z the depth, as the AO's).
     "static float3 view_at(constant SLP &a, float2 uv, float w) {\n"
     "    return float3((uv.x * 2.0 - 1.0) * w / a.p00, (1.0 - uv.y * 2.0) * w / a.p11, w); }\n"
     // The view depth at pixel q of the half-resolution depth or its copy m; the sky (0)
     // as very far.
     "static float depth_at(texture2d<float> z0, texture2d<float> z1, texture2d<float> z2, texture2d<float> z3,\n"
     "                      texture2d<float> z4, int m, int2 q) {\n"
     "    q = clamp(q, int2(0), int2(z0.get_width(), z0.get_height()) - 1);\n"
     "    uint2 r = uint2(q >> m);\n"
     "    float w = m == 0 ? z0.read(r).x : m == 1 ? z1.read(min(r, uint2(z1.get_width(), z1.get_height()) - 1)).x\n"
     "            : m == 2 ? z2.read(min(r, uint2(z2.get_width(), z2.get_height()) - 1)).x\n"
     "            : m == 3 ? z3.read(min(r, uint2(z3.get_width(), z3.get_height()) - 1)).x\n"
     "                     : z4.read(min(r, uint2(z4.get_width(), z4.get_height()) - 1)).x;\n"
     "    return w <= 0.0 ? 1e6 : w; }\n"
     // The normals, rebuilt from the half-resolution depth as the AO does (0 for the sky).
     "fragment float4 ssil_normal(V in [[stage_in]], texture2d<float> zt [[texture(0)]], constant SLP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), m = int2(a.hsize) - 1;\n"
     "    float w = zt.read(uint2(p)).x;\n"
     "    if (w <= 0.0) return 0.0;\n"
     "    float2 uv = (float2(p) + 0.5) * a.px;\n"
     "    float3 P = view_at(a, uv, w);\n"
     "    float wl = zt.read(uint2(clamp(p - int2(1, 0), int2(0), m))).x, wr = zt.read(uint2(clamp(p + int2(1, 0), int2(0), m))).x;\n"
     "    float wu = zt.read(uint2(clamp(p - int2(0, 1), int2(0), m))).x, wb = zt.read(uint2(clamp(p + int2(0, 1), int2(0), m))).x;\n"
     "    float3 l = view_at(a, uv - float2(a.px.x, 0.0), wl <= 0.0 ? 1e6 : wl), r = view_at(a, uv + float2(a.px.x, 0.0), wr <= 0.0 ? 1e6 : wr);\n"
     "    float3 u = view_at(a, uv - float2(0.0, a.px.y), wu <= 0.0 ? 1e6 : wu), b = view_at(a, uv + float2(0.0, a.px.y), wb <= 0.0 ? 1e6 : wb);\n"
     "    float3 dx = abs(r.z - P.z) < abs(P.z - l.z) ? r - P : P - l;\n"
     "    float3 dy = abs(b.z - P.z) < abs(P.z - u.z) ? b - P : P - u;\n"
     "    float3 N = normalize(cross(dx, dy));\n"
     "    if (dot(N, -P) < 0.0) N = -N;\n"
     "    return float4(N, 1.0); }\n"
     // The world view at half resolution (mipmapped afterwards), what the light bounces off,
     // with last frame's bounced light (prev, moved along the camera's motion under TAA) on
     // the surfaces' colour (alb) as post_apply adds it, so it bounces on.
     "fragment float4 ssil_color(V in [[stage_in]], texture2d<float> c [[texture(0)]], texture2d<float> prev [[texture(1)]],\n"
     "                           texture2d<float> mv [[texture(2)]], texture2d<float> alb [[texture(3)]],\n"
     "                           constant SLP &a [[buffer(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    float2 uv = in.pos.xy * a.px;\n"
     "    float3 col = c.sample(s, uv).rgb;\n"
     "    if (a.feedback > 0.0) {\n"
     "        float2 q = uv;\n"
     "        if (a.use_mv > 0.0) q += mv.read(uint2(min(int2(in.pos.xy) * 2, int2(mv.get_width(), mv.get_height()) - 1))).xy;\n"
     "        if (all(q >= 0.0) && all(q <= 1.0)) col += a.feedback * prev.sample(s, q).rgb * alb.sample(s, uv).rgb;\n"
     "    }\n"
     "    return float4(col, 1.0); }\n"
     // Interleaved Gradient Noise (Jimenez 2014), from kubaofc123's version.
     "static float quick_hash(float2 pos) {\n"
     "    const float3 magic = float3(0.06711056, 0.00583715, 52.9829189);\n"
     "    return fract(magic.z * fract(dot(pos, magic.xy))); }\n"
     "static float pack_edges(float4 e) {\n"
     "    e = round(saturate(e) * 3.05);\n"
     "    return dot(e, float4(64.0 / 255.0, 16.0 / 255.0, 4.0 / 255.0, 1.0 / 255.0)); }\n"
     "static float4 unpack_edges(float v, float sharpness) {\n"
     "    uint pv = uint(v * 255.5);\n"
     "    float4 e = float4(uint4(pv >> 6, pv >> 4, pv >> 2, pv) & 3u) / 3.0;\n"
     "    return saturate(e + sharpness); }\n"
     "struct SLSum { float3 color; float obscurance, weight; };\n"
     "static void tap_inner(constant SLP &a, texture2d<float> z0, texture2d<float> z1, texture2d<float> z2,\n"
     "                      texture2d<float> z3, texture2d<float> z4, texture2d<float> nt, texture2d<float> ct,\n"
     "                      thread SLSum &s, float2 uv, float mip, float3 P, float3 N, float fallof_sq, float3 own) {\n"
     "    constexpr sampler cs(filter::linear, mip_filter::linear, address::clamp_to_edge);\n"
     "    int2 q = int2(floor(uv * a.hsize));\n"
     "    float w = depth_at(z0, z1, z2, z3, z4, clamp(int(mip + 0.5), 0, 4), q);\n"
     "    float3 sn = nt.read(uint2(clamp(q, int2(0), int2(a.hsize) - 1))).xyz;\n"
     "    float3 hit_delta = view_at(a, uv, w) - P;\n"
     "    float length_sq = dot(hit_delta, hit_delta);\n"
     "    float NdotD = dot(N, hit_delta) * rsqrt(length_sq);\n"
     "    float obscurance = max(0.0, NdotD - 0.05) * max(0.0, length_sq * fallof_sq + 1.0);\n"
     // Haloing reduction: what is far in front counts less.
     "    float reduct = saturate(max(0.0, -hit_delta.z) * a.neg_inv_radius + 2.0);\n"
     "    float weight = 0.8 * reduct + 0.2;\n"
     "    s.obscurance += obscurance * weight;\n"
     // The colour at a level that grows with the sample's distance as the depth's does
     // (Godot reads 1/32 of the screen for all, which averages a thin neon strip away),
     // and only what is brighter than the light the receiving pixel has already: the
     // lightmaps hold the light bounced between the map's surfaces, so a lit wall next to
     // another adds nothing, while neon, lamps and lit places spill into darker ones.
     "    float3 c = ct.sample(cs, uv, level(clamp(mip + 1.0, 0.0, a.color_level))).rgb;\n"
     "    c = max(c - own, 0.0);\n"
     "    c /= 1.0 + dot(c, luma);\n"  // fireflies tamed before the average
     "    s.color += c * obscurance * weight * mix(1.0, smoothstep(0.0, 0.1, -dot(sn, normalize(hit_delta))), a.normal_rejection);\n"
     "    s.weight += weight; }\n"
     "struct SLOut { float4 color [[color(0)]]; float edges [[color(1)]]; };\n"
     "fragment SLOut ssil_main(V in [[stage_in]], texture2d<float> z0 [[texture(0)]], texture2d<float> z1 [[texture(1)]],\n"
     "                         texture2d<float> z2 [[texture(2)]], texture2d<float> z3 [[texture(3)]],\n"
     "                         texture2d<float> z4 [[texture(4)]], texture2d<float> nt [[texture(5)]],\n"
     "                         texture2d<float> ct [[texture(6)]], constant SLP &a [[buffer(0)]]) {\n"
     "    SLOut o; o.color = 0.0; o.edges = 1.0;\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    float pix_z = z0.read(uint2(p)).x;\n"
     "    if (pix_z <= 0.0) return o;\n"
     "    int pass = (p.x & 1) + 2 * (p.y & 1);\n"  // the deinterleaved layer this pixel would be in
     "    float zl = depth_at(z0, z1, z2, z3, z4, 0, p - int2(1, 0)), zr = depth_at(z0, z1, z2, z3, z4, 0, p + int2(1, 0));\n"
     "    float zu = depth_at(z0, z1, z2, z3, z4, 0, p - int2(0, 1)), zb = depth_at(z0, z1, z2, z3, z4, 0, p + int2(0, 1));\n"
     "    float2 uv = (float2(p) + 0.5) * a.px;\n"
     "    float3 P = view_at(a, uv, pix_z);\n"
     "    float3 N = nt.read(uint2(p)).xyz;\n"
     "    float2 pixel_size = view_at(a, uv + a.px * 2.0, pix_z).xy - P.xy;\n"
     // The radius, smaller when very near so the disk does not grow past the screen.
     "    float radius = a.radius * (saturate(length(P) * a.inv_radius_near_limit) * 0.8 + 0.2);\n"
     "    float lookup = 0.85 * radius / pixel_size.x, fallof_sq = -1.0 / (radius * radius);\n"
     "    float border = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));\n"
     "    lookup *= saturate(10.0 * border + 0.6);\n"
     // Under TAA the pattern turns from frame to frame (ssil_history blends them).
     "    float2 seed = float2(p * 2) * 0.333333333 + 5.588238 * a.frame;\n"
     "    float angle = quick_hash(seed) * 3.14159, ca = cos(angle), sa = sin(angle), r = quick_hash(seed.yx);\n"
     "    r = 0.8 + 0.4 * r * r;\n"
     "    float2x2 rot = float2x2(float2(ca, sa), float2(-sa, ca)) * (r * lookup);\n"
     "    P *= 0.99;\n"
     // Depth edges, slope-aware (1 no edge, 0 an edge).
     "    float4 e = float4(zl, zr, zu, zb) - pix_z;\n"
     "    e = min(abs(e), abs(e + e.yxwz));\n"
     "    e = saturate(1.3 - e / (pix_z * 0.040));\n"
     "    float mip_offset = log2(lookup) - 4.3;\n"
     "    constexpr sampler os(filter::linear, mip_filter::linear, address::clamp_to_edge);\n"
     "    float3 own = ct.sample(os, uv, level(1.0)).rgb;\n"
     "    SLSum s = {float3(0.0), 0.0, 0.0};\n"
     "    for (int i = 0; i < 12; i++) {\n"
     "        float4 sp = sample_pattern[(i + 8 * pass) % 32];\n"
     "        float2 off = round(sp.xy * rot);\n"
     "        float mip = sp.w + mip_offset;\n"
     "        tap_inner(a, z0, z1, z2, z3, z4, nt, ct, s, uv + off * a.px, mip, P, N, fallof_sq, own);\n"
     "        tap_inner(a, z0, z1, z2, z3, z4, nt, ct, s, uv - off * a.px, mip, P, N, fallof_sq, own);\n"
     "    }\n"
     "    float3 color = s.color / s.weight;\n"
     "    color /= max(1.0 - dot(color, luma), 1e-3);\n"
     "    float fade = saturate(P.z * a.fade_mul + a.fade_add);\n"
     "    float edge_fade = saturate((1.0 - e.x - e.y) * 0.35) + saturate((1.0 - e.z - e.w) * 0.35);\n"
     "    fade *= saturate(1.0 - edge_fade);\n"
     "    o.color = float4(a.intensity * color * fade, saturate(s.obscurance / s.weight * a.intensity));\n"
     "    o.edges = pack_edges(e);\n"
     "    return o; }\n"
     // Godot's smart blur: the 4 neighbours, each weighted by the edge between.
     "fragment float4 ssil_blur(V in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> edges [[texture(1)]],\n"
     "                          constant SLP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), m = int2(a.hsize) - 1;\n"
     "    float4 e = unpack_edges(edges.read(uint2(p)).x, a.edge_sharpness);\n"
     "    float sw = 0.5;\n"
     "    float4 sum = src.read(uint2(p)) * sw;\n"
     "    sum += src.read(uint2(clamp(p - int2(1, 0), int2(0), m))) * e.x, sw += e.x;\n"
     "    sum += src.read(uint2(clamp(p + int2(1, 0), int2(0), m))) * e.y, sw += e.y;\n"
     "    sum += src.read(uint2(clamp(p - int2(0, 1), int2(0), m))) * e.z, sw += e.z;\n"
     "    sum += src.read(uint2(clamp(p + int2(0, 1), int2(0), m))) * e.w, sw += e.w;\n"
     "    return sum / sw; }\n"
     // Under TAA: blended with last frame's, kept within the 3x3 neighbourhood's range (a
     // little wider) so that it follows when the light really changes. mv: the camera's
     // motion vectors (full resolution, texture coordinates, taa_motion).
     "fragment float4 ssil_history(V in [[stage_in]], texture2d<float> cur [[texture(0)]],\n"
     "                             texture2d<float> hist [[texture(1)]], texture2d<float> mv [[texture(2)]],\n"
     "                             constant SLP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy), hs = int2(a.hsize) - 1;\n"
     "    float4 c = cur.read(uint2(p)), lo = c, hi = c;\n"
     "    for (int j = -1; j <= 1; j++)\n"
     "        for (int i = -1; i <= 1; i++) {\n"
     "            float4 v = cur.read(uint2(clamp(p + int2(i, j), int2(0), hs)));\n"
     "            lo = min(lo, v), hi = max(hi, v);\n"
     "        }\n"
     "    float2 m = mv.read(uint2(min(p * 2, int2(mv.get_width(), mv.get_height()) - 1))).xy;\n"
     "    float2 q = (in.pos.xy * a.px + m) * a.hsize;\n"
     "    if (any(q < 0.0) || any(q >= a.hsize)) return c;\n"
     "    constexpr sampler hs_(filter::linear, address::clamp_to_edge);\n"
     "    float4 h = hist.sample(hs_, q * a.px);\n"
     "    float4 ext = (hi - lo) * 0.25;\n"
     "    return mix(clamp(h, lo - ext, hi + ext), c, 0.1); }\n"
     // To full resolution: the four half-resolution pixels around, each weighted by how
     // close its depth is to this pixel's (dt, the depth buffer), so the light of a wall
     // behind does not spill onto the edge of a character in front; where none is close,
     // the closest one.
     "fragment float4 ssil_upscale(V in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> zt [[texture(1)]],\n"
     "                             depth2d<float> dt [[texture(2)]], constant SLP &a [[buffer(0)]]) {\n"
     "    int2 p = int2(in.pos.xy);\n"
     "    float d = dt.read(uint2(p));\n"
     "    if (d >= 0.99999 || d <= 0.0) return 0.0;\n"
     "    float w = a.beta / (d - a.alpha);\n"
     "    float2 h = float2(p) * 0.5, t = fract(h);\n"  // half pixel q holds the depth of full pixel 2q
     "    int2 b = int2(floor(h)), hs = int2(a.hsize) - 1;\n"
     "    float4 sum = 0.0, nearest = 0.0;\n"
     "    float ws = 0.0, best = 1e30;\n"
     "    for (int j = 0; j < 2; j++)\n"
     "        for (int i = 0; i < 2; i++) {\n"
     "            uint2 q = uint2(clamp(b + int2(i, j), int2(0), hs));\n"
     "            float zq = zt.read(q).x;\n"
     "            float dz = abs((zq <= 0.0 ? 1e6 : zq) - w) / w;\n"
     "            float4 v = src.read(q);\n"
     "            float wt = ((i ? t.x : 1.0 - t.x) * (j ? t.y : 1.0 - t.y) + 1e-3) * exp(-dz * 20.0);\n"
     "            sum += v * wt, ws += wt;\n"
     "            if (dz < best) best = dz, nearest = v;\n"
     "        }\n"
     "    return ws > 1e-4 ? sum / ws : nearest; }\n";

// kind 0: normals; 1: colour copy; 2: the bounced light (and its edges); 3: blur;
// 4: the blend with last frame's; 5: to full resolution. All draw RGBA16Float.
static id<MTLRenderPipelineState> ssil_pipeline(int kind)
{
    static id<MTLRenderPipelineState> cache[6];
    static id<MTLLibrary> lib;
    if (cache[kind]) return cache[kind];
    if (!lib) {
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:ssil_source options:nil error:&error];
        if (!lib) bl_fatal("bounced light shader: %s", error.localizedDescription.UTF8String);
    }
    static NSString *const names[] = {@"ssil_normal", @"ssil_color", @"ssil_main", @"ssil_blur", @"ssil_history",
                                       @"ssil_upscale"};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"ssil_vs"];
    d.fragmentFunction = [lib newFunctionWithName:names[kind]];
    // The normals and the colour copy small (the trace reads them 24 times a pixel).
    d.colorAttachments[0].pixelFormat = kind == 0   ? MTLPixelFormatRGBA8Snorm
                                        : kind == 1 ? MTLPixelFormatRG11B10Float
                                                    : MTLPixelFormatRGBA16Float;
    if (kind == 2) d.colorAttachments[1].pixelFormat = MTLPixelFormatR8Unorm;
    NSError *error = nil;
    id<MTLRenderPipelineState> p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("bounced light pipeline: %s", error.localizedDescription.UTF8String);
    return cache[kind] = p;
}

static id<MTLTexture> ssil_texture(int i, MTLPixelFormat pf, NSUInteger w, NSUInteger h, int mipmapped)
{
    static id<MTLTexture> t[8];
    if (!t[i] || t[i].width != w || t[i].height != h || t[i].pixelFormat != pf) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h
                                                                                 mipmapped:mipmapped != 0];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t[i] = [mtl newTextureWithDescriptor:td];
    }
    return t[i];
}

static void ssil_pass(int kind, id<MTLTexture> target, id<MTLTexture> target2, id<MTLTexture> const *tex, int ntex,
                      const struct ssil_params *a)
{
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (target2) {
        rp.colorAttachments[1].texture = target2;
        rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[1].storeAction = MTLStoreActionStore;
    }
    static const char *const stat_names[] = {"ssil_normals", "ssil_color", "ssil_trace", "ssil_blur", "ssil_history",
                                             "ssil_upscale"};
    BLRender *e = stat_render(rp, stat_names[kind]);
    [e setRenderPipelineState:ssil_pipeline(kind)];
    for (int i = 0; i < ntex; i++) [e setFragmentTexture:tex[i] atIndex:(NSUInteger)i];
    [e setFragmentBytes:a length:sizeof *a atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// The bounced light from the world view `color`, its half-resolution view depth z (with
// the AO's smaller copies) and the depth buffer; returns it at full resolution for post_apply.
static id<MTLTexture> ssil_run(id<MTLTexture> color, id<MTLTexture> z, id<MTLTexture> depth, id<MTLTexture> albedo,
                              const struct ao_params *ap)
{
    NSUInteger hw = z.width, hh = z.height;
    ao_depth_copies(z, ap);
    // Godot's settings, in world units (about 39 to the metre): fade out from 2000 to 8000.
    float radius = env_ssil_radius, from = 2000, to = 8000;
    struct ssil_params a = {{(float)hw, (float)hh}, {1.0f / (float)hw, 1.0f / (float)hh}, view_proj.p00, view_proj.p11,
                            radius, (float)M_PI, 1 / (radius * 1.2f * view_proj.p11), -1 / radius,
                            -1 / (to - from), from / (to - from) + 1, 1, 1 - 0.98f, 0,
                            taa_pending ? (float)(frames % 64) : 0, view_proj.alpha, view_proj.beta,
                            {(float)depth.width, (float)depth.height}, 0, (float)taa_pending};
    // Last frame's result (half resolution), bounced on at half strength.
    static id<MTLTexture> before;
    static unsigned long before_frame;
    int again = before && before_frame == frames - 1 && !(taa_pending && taa_reset) && before.width == hw && before.height == hh;
    a.feedback = again ? 0.5f * env_ssil_strength : 0;
    id<MTLTexture> normals = ssil_texture(0, MTLPixelFormatRGBA8Snorm, hw, hh, 0);
    id<MTLTexture> picture = ssil_texture(1, MTLPixelFormatRG11B10Float, hw, hh, 1);
    id<MTLTexture> out = ssil_texture(2, MTLPixelFormatRGBA16Float, hw, hh, 0);
    id<MTLTexture> pong = ssil_texture(3, MTLPixelFormatRGBA16Float, hw, hh, 0);
    id<MTLTexture> edges = ssil_texture(4, MTLPixelFormatR8Unorm, hw, hh, 0);
    // Godot reads its full-resolution colour at mipmap level 5; this copy is half that.
    a.color_level = fminf(4, (float)(picture.mipmapLevelCount - 1));
    ssil_pass(0, normals, nil, &z, 1, &a);
    id<MTLTexture> color_in[4] = {color, again ? before : color, taa_pending ? taa_mv : color, albedo};
    ssil_pass(1, picture, nil, color_in, 4, &a);
    BLCompute *blit = stat_compute(__func__);
    [blit generateMipmapsForTexture:picture];
    [blit endEncoding];
    id<MTLTexture> main_in[7] = {z, ao_mips[0], ao_mips[1], ao_mips[2], ao_mips[3], normals, picture};
    ssil_pass(2, out, edges, main_in, 7, &a);
    for (int i = 0; i < env_ssil_blur; i++) {
        id<MTLTexture> blur_in[2] = {out, edges};
        ssil_pass(3, pong, nil, blur_in, 2, &a);
        id<MTLTexture> t = out;
        out = pong, pong = t;
    }
    if (taa_pending) {
        static unsigned long last;
        static int which;
        id<MTLTexture> prev = ssil_texture(5 + which, MTLPixelFormatRGBA16Float, hw, hh, 0);
        id<MTLTexture> next = ssil_texture(6 - which, MTLPixelFormatRGBA16Float, hw, hh, 0);
        if (last == frames - 1 && !taa_reset) {
            id<MTLTexture> hist_in[3] = {out, prev, taa_mv};
            ssil_pass(4, next, nil, hist_in, 3, &a);
        } else {
            blit = stat_compute(__func__);
            [blit copyFromTexture:out toTexture:next];
            [blit endEncoding];
        }
        out = next, which ^= 1, last = frames;
    }
    before = out, before_frame = frames;
    id<MTLTexture> full = ssil_texture(7, MTLPixelFormatRGBA16Float, depth.width, depth.height, 0);
    id<MTLTexture> up_in[3] = {out, z, depth};
    ssil_pass(5, full, nil, up_in, 3, &a);
    return full;
}

// --- the world view's end ----------------------------------------------------------------

// What the game's next pass on the back buffer draws first: post_apply (its copy of the
// world view and reflections), then the occlusion multiplied in (ao_apply).
static struct ao_params ao_result_params;
static struct ssr_params post_params;

static void post_run(struct d3d_state *s)
{
    view_state = 2;
    LOG_ONCE("[metal] world view: depth %g + %g / w, scales %g %g\n", view_proj.alpha, view_proj.beta, view_proj.p00,
             view_proj.p11);
    struct obj *bb = s->back_buffer, *ds = s->depth_stencil;
    if (!bb || !ds || clear_color_target == bb || clear_depth_target == ds) return;
    end_pass();
    id<MTLTexture> color = target_texture(bb);
    id<MTLTexture> depth = target_texture(ds);
    if (depth.width != color.width || depth.height != color.height) return;
    taa_pending = taa_motion(depth, color.width, color.height);
    NSUInteger hw = (color.width + 1) / 2, hh = (color.height + 1) / 2;
    int reflect = env_ssr && info_frame == frames, skin = env_sss && info_frame == frames;
    int contact = contact_on() && info_frame == frames;
    id<MTLTexture> z = ao_texture(0, MTLPixelFormatR32Float, hw, hh);
    struct ao_params a = {{(float)color.width, (float)color.height}, {(float)hw, (float)hh}, view_proj.alpha,
                          view_proj.beta, view_proj.p00, view_proj.p11, env_ao_radius,
                          1 / (env_ao_radius * env_ao_radius), 0.2f * (float)hh, env_ao_strength, env_ao_thickness, 3.3f};
    int ssil = env_ssil && albedo_frame == frames;
    if (env_ao || reflect || env_fog || skin || contact || ssil) ao_pass(0, z, depth, nil, &a);
    if (env_ao) {
        id<MTLTexture> raw = ao_texture(1, MTLPixelFormatR16Float, hw, hh);
        id<MTLTexture> soft = ao_texture(2, MTLPixelFormatRG32Float, hw, hh);
        ao_occlusion(raw, z, &a);
        ao_pass(2, soft, raw, z, &a);
        ao_result = soft, ao_result_params = a;
    }
    if (contact) contact_run(color, z, &a);
    int bloom = env_bloom && (long)frames >= env_bloom_at, eye = env_exposure && (long)frames >= env_bloom_at;
    if (!reflect && !env_tonemap && !env_hdr && !env_fog && !skin && !bloom && !eye && !ssil) return;
    post_base = ao_texture(3, color.pixelFormat, color.width, color.height);
    BLCompute *blit = stat_compute(__func__);
    [blit copyFromTexture:color toTexture:post_base];
    [blit endEncoding];
    struct ssr_params p = {{(float)color.width, (float)color.height}, {(float)hw, (float)hh}, view_proj.p00,
                           view_proj.p11, reflect ? env_ssr_strength : 0, 2000,
                           (float)env_ssr_show, env_ssr_fresnel, env_ssr_blur, (float)env_tonemap, env_tonemap_expand,
                           0, 0, 0, 0, 0, 0};
    post_ssr = post_aux = post_fog = post_skin = post_base;  // bound but unread without them
    if (reflect) {
        id<MTLTexture> raw = ao_texture(4, MTLPixelFormatRGBA16Float, hw, hh);
        post_aux = ao_texture(6, SSR_AUX_FORMAT, hw, hh);
        post_ssr = ao_texture(5, MTLPixelFormatRGBA16Float, hw, hh);
        static id<MTLTexture> none;  // 1x1, all 0: no facing known
        if (!none) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:SURFACE_FORMAT width:1
                                                                                         height:1 mipmapped:NO];
            none = [mtl newTextureWithDescriptor:td];
            uint16_t zero[4] = {0};
            [none replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:sizeof zero];
        }
        ssr_surface = surface_frame == frames ? surface_texture(color) : none;
        ssr_pass(0, raw, post_aux, z, info_texture(color), post_base, &p);
        ssr_pass(1, post_ssr, nil, raw, z, post_aux, &p);
        if (taa_pending) {
            // Blended over frames: each frame's trace starts from depth offset by the TAA
            // jitter, so thin things (the bottles on a bar) are hit on some frames and not others.
            static unsigned long last;
            static int which;
            id<MTLTexture> prev = ao_texture(17 + which, MTLPixelFormatRGBA16Float, hw, hh);
            id<MTLTexture> next = ao_texture(18 - which, MTLPixelFormatRGBA16Float, hw, hh);
            if (last == frames - 1 && !taa_reset) ssr_history_run(next, post_ssr, prev, taa_mv, z, post_aux, &p);
            else {
                blit = stat_compute(__func__);
                [blit copyFromTexture:post_ssr toTexture:next];
                [blit endEncoding];
            }
            post_ssr = next, which ^= 1, last = frames;
        }
    }
    if (env_fog) fog_run(z, hw, hh, &p);
    if (skin) skin_run(color, z, hw, hh, &p);
    post_bounce = post_base;
    if (ssil) post_bounce = ssil_run(post_base, z, depth, albedo_texture(color), &a), p.ssil = env_ssil_strength, p.ssil_show = (float)env_ssil_show;
    post_glow = post_base;
    if (bloom) post_glow = bloom_run(post_base), p.bloom = env_bloom_show ? 2 : env_bloom_strength;
    if (eye) exposure_run(post_base), p.exposure = env_exposure_show ? 2 : 1;
    post_params = p, post_result = 1;
}

// Called by pass() for a new pass on the back buffer.
static void post_apply(BLRender *e, id<MTLTexture> color, int has_depth)
{
    MTLPixelFormat df = has_depth ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    [e setRenderPipelineState:ssr_pipeline(2, color.pixelFormat, df)];
    static id<MTLDepthStencilState> none;
    if (!none) none = [mtl newDepthStencilStateWithDescriptor:[MTLDepthStencilDescriptor new]];
    [e setDepthStencilState:none];
    [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){0, 0, color.width, color.height, 0, 1}];
    [e setScissorRect:(MTLScissorRect){0, 0, color.width, color.height}];
    [e setFragmentTexture:post_base atIndex:0];
    [e setFragmentTexture:post_params.strength > 0 || post_params.skin > 0 ? info_texture(color) : post_base atIndex:1];
    [e setFragmentTexture:post_ssr atIndex:2];
    [e setFragmentTexture:post_aux atIndex:3];
    [e setFragmentTexture:post_fog atIndex:4];
    [e setFragmentTexture:post_skin atIndex:5];
    [e setFragmentTexture:post_glow atIndex:6];
    [e setFragmentTexture:post_bounce atIndex:7];
    [e setFragmentTexture:post_params.ssil > 0 || post_params.ssil_show > 0 ? albedo_texture(color) : post_base atIndex:8];
    [e setFragmentBytes:&post_params length:sizeof post_params atIndex:0];
    [e setFragmentBuffer:exposure_buffer() offset:0 atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    post_result = 0;
}

// Called by pass() for a new pass on the back buffer, after post_apply.
static void ao_apply(BLRender *e, id<MTLTexture> color, int has_depth)
{
    MTLPixelFormat df = has_depth ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    [e setRenderPipelineState:ao_pipeline(env_ao_show ? 4 : 3, color.pixelFormat, df)];
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
// view model (drawn with a narrowed depth range) or of the 2D HUD runs the effects.
static void post_before_draw(struct d3d_state *s, const struct element *el, int nel)
{
    if (view_state != 1 || s->render_target[0] != s->back_buffer) return;
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
    if (end) post_run(s);
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

// --- light probes (global illumination) ---------------------------------------------
//
// The game lights a model from the ambient cube in c21..c26 (+x -x +y -y +z -z), made of
// the lightmap under it, the same from every side, and the lights it does not pass
// on their own. With BL_GI the cube is the light from around the model instead
// (gi_probes.m: the map's surfaces and lights as seen from probes through the map, each
// a small cube map rendered at load), at the game's mean brightness: each side takes the
// colour and share of the light from that way. A model by a red wall turns red
// on that side; one under a dark ceiling is darker on top.
static const struct bl_gi *gi_frame;  // the open map's probes this frame, NULL none (yet)

static void gi_frame_start(void)
{
    gi_frame = env_gi ? bl_gi_get(1) : NULL;
}

static float gi_lum(const float c[3]) { return 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2]; }

static void gi_light(struct d3d_state *s, BLShader *vs, float vc[256][4])
{
    (void)s;
    // Models: shaders that read the cube, with the model's place (or its first bone's) in
    // c48..c50's w.
    if (!gi_frame || menu_frame || vs->ff_vertex || !(vs->info.const_read[0] & (1u << 21 | 1u << 23 | 1u << 25)))
        return;
    float p[3] = {vc[48][3], vc[49][3], vc[50][3]}, bounce[6][3], direct[6][3];
    if (!bl_gi_sample(gi_frame, p, bounce, direct)) return;
    // The probes' light from every side (the map's surfaces and its lights), at the
    // game's own mean brightness: each side takes the colour and share of the light
    // from that way.
    float total[6][3], mean = 0, game = 0;
    for (int a = 0; a < 6; a++) {
        for (int c = 0; c < 3; c++) total[a][c] = bounce[a][c] + direct[a][c];
        mean += gi_lum(total[a]) / 6, game += fmaxf(gi_lum(vc[21 + a]), 0) / 6;
    }
    if (mean < 1e-5f || game <= 0) return;
    float old[6][3];
    for (int a = 0; a < 6; a++)
        for (int c = 0; c < 3; c++) {
            old[a][c] = vc[21 + a][c];
            float now = fminf(total[a][c] / mean, 4.0f) * game;
            vc[21 + a][c] += env_gi_mix * (now - old[a][c]);
        }
    if (env_gi_log > 0) {
        env_gi_log--;
        fprintf(stderr, "[gi] at %.0f %.0f %.0f mean %.3f:", p[0], p[1], p[2], game);
        for (int a = 0; a < 6; a++)
            fprintf(stderr, " %.3f,%.3f,%.3f>%.3f,%.3f,%.3f", old[a][0], old[a][1], old[a][2], vc[21 + a][0], vc[21 + a][1],
                    vc[21 + a][2]);
        fprintf(stderr, "\n");
    }
}

// Everything a draw needs except vertex and index data; returns 0 if it cannot draw.
// Characters' detail normal maps (BL_DETAIL=0 off; BL_DETAIL_STRENGTH, default 1; the
// shine they and their roughness maps give skin and cloth, BL_SHINE, default 4; light
// with a direction across them, BL_CHARLIGHT, 0 to 1, default 1, darkening the side away
// from the lights to no less than BL_CHARLIGHT_MIN of the game's light, default 0.8): the map
// for the draw setup_draw is on, bound at [[texture(15)]] with the camera and the map's
// lights at [[buffer(3)]] (d3d9_shader.c ps_detail).
static id<MTLTexture> detail_map, detail_color;  // detail_color: the upscaled colour texture, or nil
static int detail_face;  // detail_map is a face's or a head's (bl_detail_is_face): the skin detail
static id<MTLTexture> detail_mask;  // or a body's, where its skin is (bl_detail_skin_mask), or nil
static int view_lights(void);
// Hair redrawn as strips (hair_swap_for).
struct hair_swap {
    id<MTLBuffer> vb, ib;  // vb nil: the game's vertices, ib its triangles to keep
    uint32_t nidx;
    id<MTLTexture> tex;
    id<MTLBuffer> base_ib;  // with strips: the game's triangles drawn under them (nil: all)
    uint32_t nbase_idx;
    id<MTLTexture> base_tex;  // and their colour texture, matched to the strips (nil: the game's)
};
static struct hair_swap *hair_swap;  // the draw's, while d3d_render_draw draws it
// The lightmap page the draw reads smoothly (lightmap_for), and the samplers (bit n) reading it.
static struct lightmap_page *lightmap_draw;
static uint32_t lightmap_stages;
static id<MTLTexture> lightmap_rects(struct lightmap_page *p);
// The lighting rebake (lightmap_rebake...): whether the page has rebaked surfaces to show,
// its rectangles with them marked, and the rebaked page.
static int lightmap_rebaked(struct lightmap_page *p);
static id<MTLTexture> lightmap_rebake_rects(struct lightmap_page *p);
static id<MTLTexture> lightmap_rebake_page(struct lightmap_page *p, int old);

// Hair's two passes (solid, then the blended see-through rest), except for strips: their
// blended pass, drawn in no order across thousands of layered cards, shows the dark
// behind them as specks. Alpha to coverage alone gives their edges.
static int hair_soft_on(void) { return env_hair_soft > 0 && !(hair_swap && hair_swap->vb); }
static void detail_bind(BLRender *e)
{
    // 0: depth and projection; 1: 1 / target size, bump strength, light count; 2 and 3:
    // the shine, hair and light settings; 4: the skin detail's strength (0: none), its
    // the texture's size and whether there is a skin mask (texture 18); 5: the cloth weave's
    // strength (0: none), the largest pore and thread spacing in world units; 6: texels per
    // pore and per thread; then four per light (struct fog_light: position
    // and range, colour and spot's inner cosine, spot direction and outer cosine, falloff).
    // All of char_lights: each pixel takes what reaches it, lights past a character add
    // nothing there.
    float dl[7 + 4 * CHAR_LIGHTS][4] = {{view_proj.alpha, view_proj.beta, view_proj.p00, view_proj.p11}};
    id<MTLTexture> rt = enc_color ? target_texture(enc_color) : nil;
    int n = env_sss_sheen >= 0 && view_lights() ? frame_nchar : 0;
    dl[1][0] = rt ? 1.0f / (float)rt.width : 0, dl[1][1] = rt ? 1.0f / (float)rt.height : 0;
    dl[1][2] = env_detail_strength, dl[1][3] = (float)n;
    for (int i = 0; i < n; i++) memcpy(dl[7 + 4 * i], &char_lights[i], sizeof char_lights[i]);
    if ((detail_face || detail_mask) && env_skin_detail && env_skin_detail_size > 0)
        dl[4][0] = fminf(fmaxf(env_skin_detail_strength * (detail_mask ? env_skin_detail_body : 1), 0), 2);
    dl[4][1] = (float)detail_map.width, dl[4][2] = (float)detail_map.height, dl[4][3] = detail_mask ? 1 : 0;
    if (detail_mask && env_cloth_detail && env_cloth_detail_size > 0)
        dl[5][0] = fminf(fmaxf(env_cloth_detail_strength, 0), 2);
    dl[5][1] = fmaxf(detail_mask ? env_skin_detail_max_body : env_skin_detail_max, 1e-3f);
    dl[5][2] = fmaxf(env_cloth_detail_max, 1e-3f);
    dl[6][0] = fmaxf(env_skin_detail_size, 0.5f), dl[6][1] = fmaxf(env_cloth_detail_size, 0.5f);
    dl[2][0] = env_shine, dl[2][1] = env_charlight, dl[2][2] = env_hair_u;
    // Strips made for the hair lie closer to the head than the game's hair (the fringe on
    // the forehead) and are soft already: a shorter fade, or they would fade away.
    dl[2][3] = hair_swap && hair_swap->vb ? 0.15f * env_hair_fade : env_hair_fade;
    // Strips made for the hair draw their strands in their own texture: no pattern on top.
    dl[3][0] = hair_swap && hair_swap->vb ? 0.0f : env_hair_strands;
    dl[3][1] = env_charlight_min, dl[3][2] = env_hair_root, dl[3][3] = env_hair_glow;
    // Over setFragmentBytes' 4 KB with many lights.
    NSUInteger off;
    id<MTLBuffer> b = upload(dl, sizeof dl[0] * (NSUInteger)(7 + 4 * n), &off);
    [e setFragmentBuffer:b offset:off atIndex:3];
    [e setFragmentTexture:detail_map atIndex:15];
    [e setFragmentTexture:detail_mask ? detail_mask : detail_map atIndex:18];  // read only with a mask
}
// Hair's soft edge needs the depth of what was drawn before the hair, which a pass cannot
// read of its own depth: before a character's first hair draw (alpha-tested, skinned,
// with no normal map of its own), the pass ends and its depth is copied.
static id<MTLTexture> hair_depth;
static unsigned long hair_depth_frame = ~0ul;
static int hair_others;  // draws other than hair since the copy
static void hair_before_draw(struct d3d_state *s)
{
    if (env_hair_fade <= 0 || !env_sss || env_detail <= 0 || !s->vs || !s->depth_stencil ||
        s->render_target[0] != s->back_buffer || menu_frame || view_state == 2)
        return;
    BLShader *vs = shader_of(s->vs);
    int skinned = 0;
    for (int i = 0; i < 16; i++)
        if ((vs->info.input_mask & (1u << i)) && (vs->info.input_usage[i] == 1 || vs->info.input_usage[i] == 2))
            skinned = 1;
    struct obj *t0 = s->texture[0];
    int hair = skinned && s->rs[15] && !s->rs[27] && t0 && t0->type == OBJ_TEXTURE && t0->subs[0] && t0->subs[0]->mem;
    if (hair) {
        id<MTLTexture> color = nil;
        hair = !detail_normal_timed(mtl, t0->serial, 0, t0->width, t0->height, t0->format, bl_g2h(t0->subs[0]->mem),
                                 t0->subs[0]->pitch, &color);
    }
    if (!hair) {
        hair_others = 1;
        return;
    }
    if (hair_depth_frame == frames && !hair_others) return;
    end_pass();
    struct obj *depth = s->depth_stencil;
    id<MTLTexture> src = target_texture(depth);
    if (!hair_depth || hair_depth.width != src.width || hair_depth.height != src.height ||
        hair_depth.pixelFormat != src.pixelFormat) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                     width:src.width
                                                                                    height:src.height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        hair_depth = [mtl newTextureWithDescriptor:td];
        hair_depth.label = @"depth before hair";
    }
    BLCompute *blit = stat_compute(__func__);
    [blit copyFromTexture:src toTexture:hair_depth];
    [blit endEncoding];
    hair_depth_frame = frames, hair_others = 0;
}

static uint32_t draw_prims;  // the draw setup_draw is for: its primitives
// Characters' triangles drawn tessellated (d3d_shader_variant.tess). Metal 4 has no
// tessellator: the shader first runs once on each vertex used, into a buffer (the
// pipeline's pre-pass, which draws nothing), then each triangle is drawn as an instance
// of a grid of env_tess x env_tess triangles over it (d3d9_shader.c). Set by
// d3d_render_draw for setup_draw while it can draw a triangle list that way.
#define TESS_MAX_PATCHES 65536
static int draw_tess;
static id<MTLRenderPipelineState> draw_pso, draw_pre;  // setup_draw's pipeline, and its pre-pass when tessellated

static void draw_patches(BLRender *e, id<MTLBuffer> ib, NSUInteger io, MTLIndexType it, uint32_t ic, NSInteger bv)
{
    static id<MTLBuffer> grid;
    static int grid_for, grid_count;
    int n = env_tess;
    if (grid_for != n) {
        // Grid point (i, j) is vertex i * (n + 1) + j: corner 1 at (n, 0), corner 2 at (0, n);
        // its triangles turn the way the corners do.
        uint16_t idx[16 * 16 * 3], *o = idx;
        for (int i = 0; i < n; i++)
            for (int j = 0; i + j < n; j++) {
                uint16_t a = (uint16_t)(i * (n + 1) + j), b = (uint16_t)(a + n + 1);
                *o++ = a, *o++ = b, *o++ = a + 1;
                if (i + j + 1 < n) *o++ = b, *o++ = b + 1, *o++ = a + 1;
            }
        grid_count = (int)(o - idx);
        grid = [mtl newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
        grid_for = n;
    }
    // The corners as 32-bit vertex numbers, base vertex added; the range they span.
    NSUInteger po;
    id<MTLBuffer> pb = upload(NULL, (NSUInteger)ic * 4, &po);
    uint32_t *dst = (uint32_t *)((uint8_t *)pb.contents + po);
    const uint8_t *src = (const uint8_t *)ib.contents + io;
    int64_t lo = INT64_MAX, hi = -1;
    for (uint32_t i = 0; i < ic; i++) {
        int64_t v = (int64_t)(it == MTLIndexTypeUInt32 ? ((const uint32_t *)src)[i] : ((const uint16_t *)src)[i]) + bv;
        dst[i] = (uint32_t)v;
        lo = v < lo ? v : lo, hi = v > hi ? v : hi;
    }
    if (lo < 0 || hi < lo) return;
    NSUInteger nv = (NSUInteger)(hi - lo + 1), ro;
    id<MTLBuffer> rb = upload(NULL, nv * 14 * 16, &ro);  // BLVSRaw: 14 float4
    uint32_t round;
    memcpy(&round, &env_tess_round, 4);
    uint32_t tq[4] = {(uint32_t)n, (uint32_t)lo, round, 0};
    [e setRenderPipelineState:draw_pre];
    [e setVertexBuffer:rb offset:ro atIndex:23];
    [e setVertexBytes:tq length:sizeof tq atIndex:25];
    [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:(NSUInteger)lo vertexCount:nv];
    [e vertexBarrier];
    [e setRenderPipelineState:draw_pso];
    [e setVertexBuffer:pb offset:po atIndex:24];
    [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(NSUInteger)grid_count indexType:MTLIndexTypeUInt16
                 indexBuffer:grid indexBufferOffset:0 instanceCount:ic / 3 baseVertex:0 baseInstance:0];
}

static int setup_draw(struct d3d_state *s, BLRender *e, uint32_t type, struct element *el, int nel,
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
    shadow_variant(s, ps, k);
    if (lightmap_draw && ps->code) {
        k->psv.lightmap = (uint8_t)lightmap_stages;
        k->psv.rebake = (uint8_t)lightmap_rebaked(lightmap_draw);
    }
    k->point = type == 1;
    for (int b = 0; b < 16; b++) k->stride[b] = (uint16_t)s->stream_stride[b];
    k->stride[16] = 16;
    // In the world view's passes, draws that replace the colour also replace the
    // reflection info: what their reflection cubemaps added, or nothing.
    if (enc_info) {
        k->info = !rs[27] && (rs[168] & 7) && !(ps->info.color_outputs & 2) ? 2 : 1;
        k->psv.reflection_info = k->info == 2;
        // Characters: skinned, their vertices carrying blend weights or bone indices. Contact
        // shadows alone only need them marked (skin 2).
        if ((env_sss || contact_on()) && k->info == 2 && s->vs)
            for (int i = 0; i < 16; i++)
                if ((vs->info.input_mask & (1u << i)) && (vs->info.input_usage[i] == 1 || vs->info.input_usage[i] == 2))
                    k->psv.skin = env_sss ? 1 : 2;
        // Hair strips are shaded as hair whatever the options, which needs the character
        // path (skin 1); without skin scattering nothing reads what that marks.
        if (hair_swap && hair_swap->vb && k->info == 2 && s->vs) k->psv.skin = 1;
        // Eyeballs: a few dozen triangles with a 128x128 colour texture, in a character's
        // vertex layout (with bone weights or indices, though their shader reads neither).
        if (env_sss && env_sss_eyes && k->info == 2 && draw_prims <= 64 && s->texture[0] &&
            s->texture[0]->width == 128 && s->texture[0]->height == 128)
            for (int i = 0; i < nel; i++)
                if (el[i].usage == 1 || el[i].usage == 2) k->psv.skin = 3;
        // A character's detail normal map (tex_detail.m), when one was made for its texture;
        // a flat one otherwise (hair, teeth), for the same shine and light.
        detail_map = nil, detail_color = nil, detail_face = 0, detail_mask = nil;
        struct obj *t0 = s->texture[0];
        if (k->psv.skin == 1 && env_detail > 0 && t0 && t0->type == OBJ_TEXTURE && t0->subs[0] && t0->subs[0]->mem) {
            id<MTLTexture> color = nil;
            detail_map = detail_normal_timed(mtl, t0->serial, 0, t0->width, t0->height, t0->format, bl_g2h(t0->subs[0]->mem),
                                          t0->subs[0]->pitch, &color);
            detail_color = env_upscale_off ? nil : color;
            detail_face = detail_map && bl_detail_is_face(t0->serial, t0->width, t0->height);
            if (detail_map && !detail_face) detail_mask = bl_detail_skin_mask(t0->serial, t0->width, t0->height);
            if (hair_swap && hair_swap->tex) detail_color = hair_swap->tex;
            if (hair_swap && !hair_swap->vb && hair_swap->base_tex && !env_upscale_off) detail_color = hair_swap->base_tex;
            // Hair: alpha-tested and without a map of its own (hair textures get none),
            // fading near what was drawn before it once hair_before_draw has its depth.
            if (!detail_map) {
                detail_map = bl_detail_flat(mtl);
                if (rs[15])
                    k->psv.hair = env_hair_fade > 0 && hair_depth && hair_depth_frame == frames &&
                                          hair_depth.width == target_texture(s->depth_stencil).width
                                      ? 2
                                      : 1;
            }
            k->psv.detail = 1;
            k->vsv.smooth_normal = k->psv.detail;
            k->vsv.tess = draw_tess && view_state == 1;
        }
        // Eyeballs: no map, but the upscaled colour texture when there is one.
        if (k->psv.skin == 3 && !env_upscale_off && t0 && t0->type == OBJ_TEXTURE && t0->subs[0] && t0->subs[0]->mem) {
            id<MTLTexture> color = nil;
            detail_normal_timed(mtl, t0->serial, 0, t0->width, t0->height, t0->format, bl_g2h(t0->subs[0]->mem),
                             t0->subs[0]->pitch, &color);
            detail_color = color;
        }
    }
    // The surfaces' colour likewise.
    if (enc_albedo) {
        k->albedo = !rs[27] && (rs[168] & 7) && !(ps->info.color_outputs & 4) ? 2 : 1;
        k->psv.albedo = k->albedo == 2;
    }
    // And their facing (shader draws only).
    if (enc_surface) {
        k->surface = !rs[27] && (rs[168] & 7) && ps->code && !(ps->info.color_outputs & 8) ? 2 : 1;
        k->psv.surface = k->surface == 2;
    }
    if (k->psv.hair && hair_pass >= 2) {  // SRCALPHA, INVSRCALPHA, ADD
        k->blend[0] = 1, k->blend[1] = k->blend[4] = 5, k->blend[2] = k->blend[5] = 6, k->blend[3] = k->blend[6] = 1;
        k->info = 1;
        if (k->albedo) k->albedo = 1;
        if (k->surface) k->surface = 1, k->psv.surface = 0;
    }

    id<MTLFunction> vf = shader_function(vs, &k->vsv), pf = shader_function(ps, &k->psv);
    id<MTLRenderPipelineState> pso = vf && pf ? pipeline(k, vf, pf) : nil;
    if (!pso) return 0;
    draw_pso = pso;
    draw_pre = k->vsv.tess ? objc_getAssociatedObject(pso, &tess_pre_key) : nil;
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
    gi_light(s, vs, vc);
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
    float vsc = (float)obj_scale(s->render_target[0]);  // half a pixel of what is drawn
    vp.inv_viewport[0] = s->viewport[2] ? 1.0f / (s->viewport[2] * vsc) : 0;
    vp.inv_viewport[1] = s->viewport[3] ? 1.0f / (s->viewport[3] * vsc) : 0;
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
    if (perspective && to_back_buffer && fabsf(w_row[3]) > 1e-4f && s->viewport[2] == rtt.width &&
        s->viewport[3] == rtt.height && u2f(s->viewport[4]) == 0 && u2f(s->viewport[5]) >= 0.99f) {
        const float(*r)[4] = vs->ff_vertex ? vc : vc + 8;
        note_projection(r[0], r[1], r[2], r[3], vp.clip_y);
        // The camera for the motion vectors: from draws without bones (a character's
        // constants may hold something else).
        int skinned = 0;
        for (int i = 0; i < nel; i++) skinned |= el[i].usage == 1 || el[i].usage == 2;
        if (view_state != 2 && !skinned) taa_note_camera(r[0], r[1], r[2], r[3], vp.clip_y);
    }
    // The world view's draws (not the view model's, drawn with a narrowed depth range,
    // nor a menu's) move by this frame's offset, on top of D3D9's half pixel.
    if (perspective && to_back_buffer && !menu_frame && view_state != 2 && fabsf(w_row[3]) > 1e-4f &&
        u2f(s->viewport[5]) >= 0.99f && s->viewport[2] && s->viewport[3]) {
        vp.inv_viewport[0] += 2 * taa_jitter[0] / (float)s->viewport[2];
        vp.inv_viewport[1] += 2 * taa_jitter[1] / (float)s->viewport[3];
    }
    set_viewport(s, e, (uint32_t)rtt.width, (uint32_t)rtt.height, squeeze);
    [e setVertexBytes:&vp length:sizeof vp atIndex:21];
    if (k->vsv.tess) [e setVertexBytes:&view_proj length:sizeof view_proj atIndex:22];

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
    // The most any of its textures' materials reflects (reflection info without a cubemap).
    for (int i = 0; i < 8 && env_ssr; i++)
        if ((ps->info.sampler_mask & (1u << i)) && s->texture[i] && s->texture[i]->type == OBJ_TEXTURE)
            pp.gloss = fmaxf(pp.gloss, s->texture[i]->gloss);
    pp.alpha_ref = (rs[24] & 255) / 255.0f;
    if (k->psv.hair && hair_soft_on() && (pp.alpha_func == 5 || pp.alpha_func == 7)) {  // GREATER(EQUAL)
        pp.alpha_ref = fmaxf(pp.alpha_ref, env_hair_soft);
        if (hair_pass == 2) pp.alpha_func = 2;  // LESS: what the solid pass left
    }
    if (rs[28]) {  // FOGENABLE
        uint32_t c = rs[34];
        pp.fog_color[0] = (c >> 16 & 255) / 255.0f, pp.fog_color[1] = (c >> 8 & 255) / 255.0f;
        pp.fog_color[2] = (c & 255) / 255.0f, pp.fog_color[3] = 1;
        uint32_t table = rs[35];  // FOGTABLEMODE: 0 none, 1 exp, 2 exp2, 3 linear
        pp.fog_mode = table == 3 ? 2 : table == 1 ? 3 : table == 2 ? 4 : 1;
        pp.fog_start = u2f(rs[36]), pp.fog_end = u2f(rs[37]), pp.fog_density = u2f(rs[38]);
    }
    if (k->psv.surface) {
        id<MTLTexture> pm = nil, hm = nil;
        for (int i = 0; i < 8 && !pm; i++)
            if ((ps->info.sampler_mask & (1u << i)) && s->texture[i] && s->texture[i]->type == OBJ_TEXTURE)
                if ((pm = (__bridge id<MTLTexture>)s->texture[i]->pbr))
                    pp.metal = s->texture[i]->metal, hm = (__bridge id<MTLTexture>)s->texture[i]->pom;
        pp.pbr = pm != nil;
        pp.spec = env_pbr_spec;
        pp.pom = hm ? env_pom_depth : 0, pp.pom_dist = env_pom_dist;
        [e setFragmentTexture:pm ? pm : bl_detail_flat(mtl) atIndex:12];
        [e setFragmentTexture:hm ? hm : bl_detail_flat(mtl) atIndex:19];
        id<MTLTexture> ct = target_texture(s->render_target[0]);
        pp.view[0] = view_proj.p00, pp.view[1] = view_proj.p11;
        pp.view[2] = 2.0f / (float)ct.width, pp.view[3] = 2.0f / (float)ct.height;
        pp.bump = env_pbr_bump;
        // The frame's lights for the bumps' shading (ps_surface).
        float wl[1 + 4 * FOG_LIGHTS][4] = {{(float)(pm && (env_pbr_bump > 0 || env_pbr_spec > 0) ? view_lights() : 0)}};
        for (int i = 0; i < (int)wl[0][0]; i++) memcpy(wl[1 + 4 * i], &frame_lights[i], sizeof frame_lights[i]);
        [e setFragmentBytes:wl length:sizeof wl[0] * (NSUInteger)(1 + 4 * (int)wl[0][0]) atIndex:4];
    }
    [e setFragmentBytes:&pp length:sizeof pp atIndex:1];
    if (k->psv.detail) detail_bind(e);
    if (k->psv.hair >= 2) [e setFragmentTexture:hair_depth atIndex:14];
    shadow_draw(s, e, k, vs->ff_vertex ? (const float(*)[4])vc : (const float(*)[4])vc + 8, &vp);
    if (k->psv.lightmap)
        [e setFragmentTexture:k->psv.rebake ? lightmap_rebake_rects(lightmap_draw) : lightmap_rects(lightmap_draw)
                      atIndex:13];
    if (k->psv.rebake) {
        [e setFragmentTexture:lightmap_rebake_page(lightmap_draw, 0) atIndex:16];
        [e setFragmentTexture:lightmap_rebake_page(lightmap_draw, 1) atIndex:17];
    }

    for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++) {
        if (!(ps->info.sampler_mask & (1u << i))) continue;
        struct obj *t = s->texture[i];
        id<MTLTexture> mt = t ? texture_of(t) : dummy_texture(k->psv.tex_kind[i]);
        if (tex_kind_of(t) != k->psv.tex_kind[i]) mt = dummy_texture(k->psv.tex_kind[i]);
        if (i == 0 && (k->psv.detail || k->psv.skin == 3) && detail_color) mt = detail_color;
        // Hair strips always with their own texture, even drawn plain (the game's
        // texture does not fit them).
        if (i == 0 && hair_swap && hair_swap->vb && hair_swap->tex) mt = hair_swap->tex;
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

// Hair redrawn as strips (tex_detail.h bl_detail_hair), for an indexed triangle draw of a
// skinned character whose texture has strips made for it: the strips in the draw's own
// vertex layout, each vertex a copy of the game's nearest vertex of this draw (so it
// follows the same bones) with the strip's position, normal and texture coordinates,
// placed by fitting the strips' anchors onto the draw's vertices (scale, a turn between
// axes, offset). For a texture with only a part to keep (the hair ties), the draw's
// triangles inside that part of the texture. Made once per mesh; NULL when not hair.
// Keyed by the mesh and the buffers' serials (they are dropped with the buffers, swaps_forget).
struct hair_key { const void *m; uint64_t vb, ib; uint32_t voff, start, count; int32_t base; };
static NSMutableDictionary<NSData *, NSValue *> *hair_swaps;

static struct hair_swap *hair_swap_for(struct d3d_state *s, struct element *el, int nel, uint32_t start,
                                       uint32_t count, int32_t base_vertex)
{
    if (!env_hair_mesh || view_state != 1 || !s->vs || !s->indices) return NULL;
    struct obj *t0 = s->texture[0];
    if (!t0 || t0->type != OBJ_TEXTURE || !t0->subs[0] || !t0->subs[0]->mem) return NULL;
    const struct element *pe = NULL, *ne = NULL, *te = NULL;
    int skinned = 0;
    for (int i = 0; i < nel; i++) {
        if (el[i].usage == 1 || el[i].usage == 2) skinned = 1;
        if (el[i].usage == 0 && el[i].index == 0 && el[i].type == 2) pe = &el[i];
        if (el[i].usage == 3 && el[i].index == 0 && el[i].type == 2) ne = &el[i];
        if (el[i].usage == 5 && el[i].index == 0 && el[i].type == 1) te = &el[i];
    }
    if (!skinned || !pe || !te) return NULL;
    for (int i = 0; i < nel; i++)
        if (el[i].stream != pe->stream) return NULL;
    id<MTLTexture> color;
    detail_normal_timed(mtl, t0->serial, 0, t0->width, t0->height, t0->format, bl_g2h(t0->subs[0]->mem), t0->subs[0]->pitch,
                     &color);
    const struct bl_hair_mesh *m = bl_detail_hair(mtl, t0->serial, t0->width, t0->height);
    struct obj *vbo = s->stream[pe->stream], *ibo = s->indices;
    if (!m || !vbo || !vbo->mem) return NULL;
    struct hair_key key = {m, vbo->serial, ibo->serial, s->stream_offset[pe->stream], start, count, base_vertex};
    NSData *kd = [NSData dataWithBytes:&key length:sizeof key];
    if (!hair_swaps) hair_swaps = [NSMutableDictionary new];
    NSValue *known = hair_swaps[kd];
    if (known) return known.pointerValue;
    hair_swaps[kd] = [NSValue valueWithPointer:NULL];
    int is32 = ibo->format == 102;
    uint32_t stride = s->stream_stride[pe->stream], ni = count * 3;
    if ((uint64_t)(start + ni) * (is32 ? 4 : 2) > ibo->size) return NULL;
    const uint8_t *ip = (const uint8_t *)bl_g2h(ibo->mem) + (size_t)start * (is32 ? 4 : 2);
    const uint8_t *vb = (const uint8_t *)bl_g2h(vbo->mem) + s->stream_offset[pe->stream];
    size_t vsize = vbo->size - s->stream_offset[pe->stream];
#define HAIR_INDEX(i) (is32 ? ((const uint32_t *)ip)[i] : ((const uint16_t *)ip)[i])
    for (uint32_t i = 0; i < ni; i++)
        if ((size_t)((int64_t)base_vertex + HAIR_INDEX(i) + 1) * stride > vsize) return NULL;
    struct hair_swap *hs = calloc(1, sizeof *hs);
    if (!m->nverts) {  // keep the triangles inside m->keep
        uint32_t *keep = malloc((size_t)ni * 4), nk = 0;
        for (uint32_t t = 0; t < count; t++) {
            float u = 0, v = 0;
            for (int c = 0; c < 3; c++) {
                const float *uv = (const float *)(vb + (size_t)(base_vertex + HAIR_INDEX(t * 3 + c)) * stride + te->offset);
                u += uv[0] / 3, v += uv[1] / 3;
            }
            if (u >= m->keep[0] - 0.01f && u <= m->keep[2] + 0.01f && v >= m->keep[1] - 0.01f && v <= m->keep[3] + 0.01f)
                for (int c = 0; c < 3; c++) keep[nk++] = HAIR_INDEX(t * 3 + c);
        }
        hs->nidx = nk;
        if (nk) hs->ib = [mtl newBufferWithBytes:keep length:(NSUInteger)nk * 4 options:MTLResourceStorageModeShared];
        free(keep);
        fprintf(stderr, "[metal] hair: %u of %u triangles kept\n", nk / 3, count);
        hair_swaps[kd] = [NSValue valueWithPointer:hs];
        return hs;
    }
    // The draw's vertices.
    uint32_t *ids = malloc((size_t)ni * 4), nid = 0;
    for (uint32_t i = 0; i < ni; i++) {
        uint32_t id = (uint32_t)(base_vertex + (int32_t)HAIR_INDEX(i));
        int dup = 0;
        for (uint32_t j = 0; j < nid && !dup; j++) dup = ids[j] == id;
        if (!dup) ids[nid++] = id;
    }
#undef HAIR_INDEX
    float(*mp)[3] = malloc((size_t)nid * 12);
    for (uint32_t j = 0; j < nid; j++) memcpy(mp[j], vb + (size_t)ids[j] * stride + pe->offset, 12);
    // Fit: q = sc * R a + t, R one of the 48 signed axis permutations.
    double cm[3] = {0}, ca[3] = {0}, rm = 0, ra = 0;
    for (uint32_t j = 0; j < nid; j++)
        for (int k = 0; k < 3; k++) cm[k] += mp[j][k] / nid;
    for (uint32_t j = 0; j < m->nanchors; j++)
        for (int k = 0; k < 3; k++) ca[k] += m->anchors[j * 3 + k] / m->nanchors;
    for (uint32_t j = 0; j < nid; j++)
        for (int k = 0; k < 3; k++) rm += (mp[j][k] - cm[k]) * (mp[j][k] - cm[k]) / nid;
    for (uint32_t j = 0; j < m->nanchors; j++)
        for (int k = 0; k < 3; k++) ra += (m->anchors[j * 3 + k] - ca[k]) * (m->anchors[j * 3 + k] - ca[k]) / m->nanchors;
    double sc = ra > 0 ? sqrt(rm / ra) : 1, best = 1e30, R[3][3] = {{0}}, t[3];
    static const int perm[6][3] = {{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}};
    for (int pi = 0; pi < 6; pi++)
        for (int sg = 0; sg < 8; sg++) {
            double err = 0;
            for (uint32_t j = 0; j < m->nanchors; j++) {
                const float *a = &m->anchors[j * 3];
                double q[3], dmin = 1e30;
                for (int k = 0; k < 3; k++)
                    q[k] = cm[k] + sc * ((sg >> k & 1) ? -1 : 1) * (a[perm[pi][k]] - ca[perm[pi][k]]);
                for (uint32_t i = 0; i < nid; i++) {
                    double dx = mp[i][0] - q[0], dy = mp[i][1] - q[1], dz = mp[i][2] - q[2], d = dx * dx + dy * dy + dz * dz;
                    if (d < dmin) dmin = d;
                }
                err += dmin;
            }
            if (err < best) {
                best = err;
                memset(R, 0, sizeof R);
                for (int k = 0; k < 3; k++) R[k][perm[pi][k]] = (sg >> k & 1) ? -1 : 1;
            }
        }
    for (int k = 0; k < 3; k++) t[k] = cm[k] - sc * (R[k][0] * ca[0] + R[k][1] * ca[1] + R[k][2] * ca[2]);
    // Then scale and offset refined against each anchor's nearest vertex (the two sets
    // need not cover the same parts, so their spreads only give a first guess).
    double rms = 0;
    for (int iter = 0; iter < 20; iter++) {
        double sa[3] = {0}, sm[3] = {0}, num = 0, den = 0, err = 0;
        double(*ra_)[3] = malloc((size_t)m->nanchors * 24), (*nm)[3] = malloc((size_t)m->nanchors * 24);
        for (uint32_t j = 0; j < m->nanchors; j++) {
            const float *a = &m->anchors[j * 3];
            double q[3], dmin = 1e30;
            uint32_t bi = 0;
            for (int k = 0; k < 3; k++) {
                ra_[j][k] = R[k][0] * a[0] + R[k][1] * a[1] + R[k][2] * a[2];
                q[k] = sc * ra_[j][k] + t[k];
            }
            for (uint32_t i = 0; i < nid; i++) {
                double dx = mp[i][0] - q[0], dy = mp[i][1] - q[1], dz = mp[i][2] - q[2], d = dx * dx + dy * dy + dz * dz;
                if (d < dmin) dmin = d, bi = i;
            }
            err += dmin;
            for (int k = 0; k < 3; k++) nm[j][k] = mp[bi][k], sa[k] += ra_[j][k] / m->nanchors, sm[k] += nm[j][k] / m->nanchors;
        }
        for (uint32_t j = 0; j < m->nanchors; j++)
            for (int k = 0; k < 3; k++) num += (ra_[j][k] - sa[k]) * (nm[j][k] - sm[k]), den += (ra_[j][k] - sa[k]) * (ra_[j][k] - sa[k]);
        free(ra_), free(nm);
        rms = sqrt(err / m->nanchors);
        if (den > 0) sc = num / den;
        for (int k = 0; k < 3; k++) t[k] = sm[k] - sc * sa[k];
    }
    fprintf(stderr, "[metal] hair: %u strip vertices onto %u of the game's, scale %.2f, fit %.3f (%.1f%% of its size)\n",
            m->nverts, nid, sc, rms, 100 * rms / sqrt(rm));
    if (rms > 0.05 * sqrt(rm)) {
        free(ids), free(mp), free(hs);
        return NULL;
    }
    id<MTLBuffer> out = [mtl newBufferWithLength:(NSUInteger)m->nverts * stride options:MTLResourceStorageModeShared];
    uint8_t *o = out.contents;
    for (uint32_t v = 0; v < m->nverts; v++) {
        const float *src = &m->verts[v * 8];
        float q[3], n[3];
        for (int k = 0; k < 3; k++) {
            q[k] = (float)(sc * (R[k][0] * src[0] + R[k][1] * src[1] + R[k][2] * src[2]) + t[k]);
            n[k] = (float)(R[k][0] * src[3] + R[k][1] * src[4] + R[k][2] * src[5]);
        }
        uint32_t nearest = 0;
        float dmin = 1e30f;
        for (uint32_t i = 0; i < nid; i++) {
            float dx = mp[i][0] - q[0], dy = mp[i][1] - q[1], dz = mp[i][2] - q[2], d = dx * dx + dy * dy + dz * dz;
            if (d < dmin) dmin = d, nearest = i;
        }
        uint8_t *r = o + (size_t)v * stride;
        memcpy(r, vb + (size_t)ids[nearest] * stride, stride);
        memcpy(r + pe->offset, q, 12);
        if (ne) memcpy(r + ne->offset, n, 12);
        memcpy(r + te->offset, &src[6], 8);
    }
    // The game's triangles to keep under the strips: those whose centre is one of m->base,
    // placed by the same fit (the scalp, without the locks the strips replace).
    if (m->nbase) {
        uint32_t *keep = malloc((size_t)ni * 4), nk = 0;
        float tol = 0.01f * (float)sqrt(rm);
        for (uint32_t tr = 0; tr < count; tr++) {
            float c[3] = {0};
            uint32_t vi[3];
            for (int k = 0; k < 3; k++) {
                vi[k] = is32 ? ((const uint32_t *)ip)[tr * 3 + k] : ((const uint16_t *)ip)[tr * 3 + k];
                const float *pv = (const float *)(vb + (size_t)(base_vertex + (int32_t)vi[k]) * stride + pe->offset);
                for (int j = 0; j < 3; j++) c[j] += pv[j] / 3;
            }
            int hit = 0;
            for (uint32_t b = 0; b < m->nbase && !hit; b++) {
                const float *bc = &m->base[b * 3];
                float d2 = 0;
                for (int k = 0; k < 3; k++) {
                    float q = (float)(sc * (R[k][0] * bc[0] + R[k][1] * bc[1] + R[k][2] * bc[2]) + t[k]) - c[k];
                    d2 += q * q;
                }
                hit = d2 < tol * tol;
            }
            if (hit)
                for (int k = 0; k < 3; k++) keep[nk++] = vi[k];
        }
        hs->nbase_idx = nk;
        hs->base_ib = [mtl newBufferWithBytes:keep length:(NSUInteger)(nk ? nk : 1) * 4
                                      options:MTLResourceStorageModeShared];
        free(keep);
        fprintf(stderr, "[metal] hair: %u of the game's %u triangles kept under the strips\n", nk / 3, count);
    }
    free(ids), free(mp);
    hs->vb = out, hs->nidx = m->nidx, hs->tex = m->tex, hs->base_tex = m->base_color;
    hs->ib = [mtl newBufferWithBytes:m->idx length:(NSUInteger)m->nidx * 4 options:MTLResourceStorageModeShared];
    hair_swaps[kd] = [NSValue valueWithPointer:hs];
    return hs;
}

// --- lightmaps --------------------------------------------------------------------
//
// The map's baked light: each surface reads its own rectangle of a shared lightmap page,
// low resolution and packed edge to edge, so bilinear filtering shows the texels as
// blocks and steps. With BL_LIGHTMAP_SMOOTH (default on) the shaders read it with a cubic
// (Catmull-Rom, d3d9_shader.c bl_lightmap) whose reads stay inside the surface's rectangle.
// The rectangles come from the draws: a sampler reading a one-level 32-bit texture with
// the vertices' TEXCOORD1 as it is (copied through by the vertex shader) reads a page, as
// does one reading TEXCOORD1 plus a multiple of TEXCOORD2 (bump-mapped surfaces: their
// flat lightmap and one per bump direction side by side, TEXCOORD2 apart),
// the triangles joined by shared lightmap coordinates are one surface, and the bounds
// of those coordinates its rectangle. Each range of static buffers is read once, and so
// is each set of coordinates drawn from dynamic ones (Source builds some of the world in
// a dynamic buffer every frame, somewhere new each time); every texel of the rectangle notes it (x0, y0, x1, y1 in texels, in an RGBA16Uint
// texture the size of the page; 0 where no surface is known yet, or two disagree).
struct lightmap_page {
    uint32_t w, h;
    uint16_t *rects;            // 4 per texel
    id<MTLTexture> gpu;
    uint32_t dirty[4];          // rows and columns changed since the upload: x0, y0, x1, y1
    NSMutableSet<NSData *> *ranges;  // draws already read (emptied at LIGHTMAP_MAX_RANGES)
    // The lighting rebake (BL_REBAKE), for the map rb_gen counts (bl_rebake_gen):
    int rb_gen;
    struct lightmap_surf *surfs;  // surfaces seen, not yet matched to the map's faces
    int nsurfs, capsurfs;
    struct lightmap_match *matches;  // matched, the first nfilled of them in rb_page
    int nmatches, capmatches, nfilled;
    uint8_t *matched;           // by face: matched already
    uint16_t *rb_rects;         // 4 per texel: a rebaked face's rectangle (x0 + 0x8000), else 0
    id<MTLTexture> rb_gpu;      // rects, with rb_rects over them
    id<MTLTexture> rb_page;     // the rebaked light, 4 times the size
    id<MTLTexture> rb_old;      // the map's own light it changes, encoded alike
    uint32_t rb_dirty[4];       // as dirty, for rb_gpu
};
#define LIGHTMAP_MAX_RANGES 65536
static NSMutableDictionary<NSValue *, NSValue *> *lightmap_pages;  // by page (struct obj *)
static uint32_t lightmap_surfaces, lightmap_clashes;  // surfaces that noted a new texel
static uint32_t lightmap_reads;  // draws whose coordinates were read
static int lightmap_missed;  // the draw reads a page with a sampler bl_lightmap does not (BL_DRAW_DUMP=lightmap)

// Debugging: draws that read a known page plain, logged once per pair of shaders.
static void lightmap_note_missed(struct d3d_state *s)
{
    lightmap_missed = 0;
    if (!lightmap_pages.count || !s->ps) return;
    BLShader *ps = shader_of(s->ps);
    for (int i = 0; i < 8; i++)
        if ((ps->info.sampler_mask & (1u << i)) && s->texture[i] && !(lightmap_draw && (lightmap_stages >> i & 1)) &&
            lightmap_pages[[NSValue valueWithPointer:s->texture[i]]])
            lightmap_missed = 1;
    static uint32_t seen[64][2];
    static int nseen;
    if (!lightmap_missed || nseen == 64) return;
    uint32_t vg = s->vs ? s->vs->guest : 0, pg = s->ps->guest;
    for (int i = 0; i < nseen; i++)
        if (seen[i][0] == vg && seen[i][1] == pg) return;
    seen[nseen][0] = vg, seen[nseen][1] = pg, nseen++;
    fprintf(stderr, "[metal] lightmap read plain: frame %lu draw %lu vs %#x ps %#x\n", frames, draws + 1, vg, pg);
}

static void lightmap_forget(struct obj *o)
{
    NSValue *key = [NSValue valueWithPointer:o];
    struct lightmap_page *p = lightmap_pages ? [lightmap_pages[key] pointerValue] : NULL;
    if (!p) return;
    [lightmap_pages removeObjectForKey:key];
    if (lightmap_draw == p) lightmap_draw = NULL;
    free(p->rects), free(p->surfs), free(p->matches), free(p->matched), free(p->rb_rects);
    p->gpu = nil, p->ranges = nil, p->rb_gpu = nil, p->rb_page = nil, p->rb_old = nil;
    free(p);
}

static id<MTLTexture> lightmap_rects(struct lightmap_page *p)
{
    if (!p->gpu) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Uint
                                                                                     width:p->w height:p->h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        p->gpu = [mtl newTextureWithDescriptor:d];
        p->dirty[0] = p->dirty[1] = 0, p->dirty[2] = p->w, p->dirty[3] = p->h;
    }
    if (p->dirty[2] > p->dirty[0]) {
        uint32_t x = p->dirty[0], y = p->dirty[1], w = p->dirty[2] - x, h = p->dirty[3] - y;
        [p->gpu replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:0
                    withBytes:p->rects + ((size_t)y * p->w + x) * 4 bytesPerRow:(NSUInteger)p->w * 8];
        p->dirty[0] = p->w, p->dirty[1] = p->h, p->dirty[2] = p->dirty[3] = 0;
    }
    return p->gpu;
}

static void lightmap_dirty(uint32_t d[4], int x0, int y0, int x1, int y1)
{
    if ((uint32_t)x0 < d[0]) d[0] = (uint32_t)x0;
    if ((uint32_t)y0 < d[1]) d[1] = (uint32_t)y0;
    if ((uint32_t)x1 > d[2]) d[2] = (uint32_t)x1;
    if ((uint32_t)y1 > d[3]) d[3] = (uint32_t)y1;
}

// --- the lighting rebake in the game ------------------------------------------------
//
// Shelved (2026-10-26): the bake differs from the 2004 one too much luxel by luxel, so it
// shows blotched in the game; only BL_REBAKE=1 turns it on, for working on it.
// With BL_REBAKE=1, the map baked again four times as fine
// (lm_bake.h) takes the place of the game's own lightmaps, surface by surface. Each
// surface lightmap_for finds is noted with three of its corners (their positions and
// lightmap coordinates) and matched to the map face it was made from: one that has those
// corners, and whose lightmap, placed where the coordinates say, sits on whole texels of
// the page. That face's bake goes into a page four times the size (rb_page: texel for
// texel, as lm_bake.h lays it out), and its rectangle, in a copy of the rectangles
// texture, is marked (x0 + 0x8000) so the shader reads rb_page there
// (d3d9_shader.c bl_lightmap_rebaked). The bake is linear light and the game's page holds
// it encoded (its gamma and overbright, then the colour scaled down whole where a
// channel would pass 1, keeping its hue), so the encoding is learnt from the pages: the
// map's own samples (its lighting lump) against the bytes the game wrote for them, per
// channel, from texels not scaled down (no byte at 255). The game adds dynamic lights to
// its page as it runs (the asylum's green neon), which brighten some texels past what
// their samples give, so each byte takes the upper quarter of the light seen with it. The
// rebake goes in as a change to the game's page, not in its place: the bake encoded
// (rb_page) less the old samples encoded (rb_old), added to the page as the game has it,
// so its dynamic light stays and the encoding's errors cancel. Left as the game has them: faces with a light
// style (lights that switch or flicker change their texels), displacements, and the
// light dynamic lights add to the page.
struct lightmap_surf {
    uint16_t rect[4];       // copy 0, in texels
    int16_t sx, sy;         // to the next copy (bump-mapped), in texels
    int copies;
    float pos[3][3], uv[3][2];
};
struct lightmap_match { int face, rx, ry, sx, sy, copies; };

static const struct bl_rebake *rebake_now;  // the open map's bake, once done (this frame's)
static int rebake_gen_now;
static unsigned long rebake_frame = ~0ul;
static long rebake_budget;                // luxels left to fill this frame
static uint32_t rebake_faces, rebake_missed;  // faces filled, surfaces matched to none
// Why surfaces matched none, by the furthest a candidate face got: no face has the first
// corner, none has all three, the copies disagree, not on whole texels, off the page.
static uint32_t rebake_why[5];
static int rebake_told;  // unmatched surfaces logged in full
// The encoding learnt: per channel (r, g, b), the mean linear light of each byte.
struct rebake_pair { float lin; int byte; };
static struct rebake_pair *rebake_seen[3];
static long rebake_pairs, rebake_cap;
static float rebake_lin[3][256];
static int rebake_learnt;
#define REBAKE_PAIRS 4000
// The map's corners, to the faces that have them: (position key, face), sorted.
struct rebake_vert { uint64_t key; int face; };
static struct rebake_vert *rebake_verts;
static int nrebake_verts, rebake_verts_gen = -1;

static uint64_t rebake_key(const float p[3])
{
    uint64_t k = 0;
    for (int i = 0; i < 3; i++) k = k << 21 | ((uint64_t)lroundf(p[i] * 8.0f) & 0x1fffff);
    return k;
}
static int rebake_vert_cmp(const void *a, const void *b)
{
    uint64_t x = ((const struct rebake_vert *)a)->key, y = ((const struct rebake_vert *)b)->key;
    return x < y ? -1 : x > y;
}
// A face the rebake replaces: baked, and lit by the map's steady light alone.
static int rebake_face_ok(const struct bl_rebake *rb, int fi)
{
    const struct bl_bsp_face *f = &rb->world->faces[fi];
    return rb->bake->faces[fi].offset >= 0 && f->nstyles == 1 && f->styles[0] == 0;
}
static void rebake_index(const struct bl_rebake *rb)
{
    if (rebake_verts_gen == rb->gen) return;
    const struct bl_bsp_world *w = rb->world;
    free(rebake_verts);
    nrebake_verts = 0;
    for (int i = 0; i < w->nfaces; i++)
        if (rebake_face_ok(rb, i)) nrebake_verts += w->faces[i].count;
    rebake_verts = malloc(sizeof *rebake_verts * (nrebake_verts ? nrebake_verts : 1));
    int n = 0;
    for (int i = 0; i < w->nfaces; i++) {
        if (!rebake_face_ok(rb, i)) continue;
        const struct bl_bsp_face *f = &w->faces[i];
        for (int c = 0; c < f->count; c++)
            rebake_verts[n].key = rebake_key(w->verts[w->index[f->first + c]]), rebake_verts[n++].face = i;
    }
    qsort(rebake_verts, (size_t)n, sizeof *rebake_verts, rebake_vert_cmp);
    rebake_verts_gen = rb->gen;
}

static int rebake_match(const struct bl_rebake *rb, const struct lightmap_page *p, const struct lightmap_surf *sf,
                        struct lightmap_match *out)
{
    const struct bl_bsp_world *w = rb->world;
    uint64_t k[3] = {rebake_key(sf->pos[0]), rebake_key(sf->pos[1]), rebake_key(sf->pos[2])};
    int lo = 0, hi = nrebake_verts;
    while (lo < hi) {
        int m = (lo + hi) / 2;
        if (rebake_verts[m].key < k[0]) lo = m + 1;
        else hi = m;
    }
    int why = 0;
    for (int j = lo; j < nrebake_verts && rebake_verts[j].key == k[0]; j++) {
        int fi = rebake_verts[j].face;
        const struct bl_bsp_face *f = &w->faces[fi];
        int has = 1;
        for (int c = 1; c < 3 && has; c++) {
            has = 0;
            for (int v = 0; v < f->count && !has; v++) has = rebake_key(w->verts[w->index[f->first + v]]) == k[c];
        }
        if (!has) {
            why = why > 1 ? why : 1;
            continue;
        }
        // The page holds the bump directions' copies only where the material is bump-mapped,
        // though the map has them for every face.
        if (sf->copies == 4 && !f->bumped) {
            why = why > 2 ? why : 2;
            continue;
        }
        // Where its lightmap sits on the page: the same whole texel from every corner.
        const struct bl_bsp_texinfo *ti = &w->texinfo[f->texinfo];
        float r[3][2];
        for (int c = 0; c < 3; c++)
            for (int a = 0; a < 2; a++) {
                const float *v = ti->lm[a], *q = sf->pos[c];
                float l = v[0] * q[0] + v[1] * q[1] + v[2] * q[2] + v[3] - (float)f->mins[a];
                r[c][a] = sf->uv[c][a] * (float)(a ? p->h : p->w) - l - 0.5f;
            }
        int rx = (int)lroundf(r[0][0]), ry = (int)lroundf(r[0][1]), ok = 1;
        for (int c = 0; c < 3; c++) ok &= fabsf(r[c][0] - (float)rx) < 0.05f && fabsf(r[c][1] - (float)ry) < 0.05f;
        if (!ok) {
            if (why < 3 && rebake_told < 4) {
                rebake_told++;
                fprintf(stderr, "[metal] rebake: surface at %.2f %.2f %.2f (texel %.3f %.3f) on face %d: off whole texels by"
                                " %.3f %.3f, %.3f %.3f, %.3f %.3f\n",
                        sf->pos[0][0], sf->pos[0][1], sf->pos[0][2], sf->uv[0][0] * p->w, sf->uv[0][1] * p->h, fi,
                        r[0][0], r[0][1], r[1][0], r[1][1], r[2][0], r[2][1]);
            }
            why = why > 3 ? why : 3;
            continue;
        }
        int sx = sf->sx, sy = sf->sy, n = sf->copies - 1, w0 = f->size[0] + 1, h0 = f->size[1] + 1;
        if (rx < 0 || ry < 0 || rx + n * sx < 0 || ry + n * sy < 0 || rx + n * sx + w0 > (int)p->w ||
            ry + n * sy + h0 > (int)p->h || rx + w0 > (int)p->w || ry + h0 > (int)p->h) {
            why = 4;
            continue;
        }
        *out = (struct lightmap_match){fi, rx, ry, sx, sy, sf->copies};
        return 1;
    }
    if (!why && rebake_told < 4) {
        rebake_told++;
        fprintf(stderr, "[metal] rebake: surface at %.3f %.3f %.3f, %.3f %.3f %.3f: no face has that corner\n",
                sf->pos[0][0], sf->pos[0][1], sf->pos[0][2], sf->pos[1][0], sf->pos[1][1], sf->pos[1][2]);
    }
    rebake_why[why]++;
    return 0;
}

// The game's bytes for the face's samples (the page's texels in guest memory, B G R A).
static void rebake_learn(const struct bl_bsp_world *w, const struct lightmap_match *m, const uint8_t *tx, uint32_t pitch)
{
    const struct bl_bsp_face *f = &w->faces[m->face];
    int w0 = f->size[0] + 1, h0 = f->size[1] + 1;
    for (int c = 0; c < m->copies; c++)
        for (int y = 0; y < h0; y++)
            for (int x = 0; x < w0; x++) {
                float lin[3];
                bl_bake_rgbe(w->lighting + 4 * ((size_t)f->lightofs + (size_t)(c * h0 + y) * w0 + x), lin);
                const uint8_t *b = tx + (size_t)(m->ry + c * m->sy + y) * pitch + (size_t)(m->rx + c * m->sx + x) * 4;
                if (b[0] == 255 || b[1] == 255 || b[2] == 255) continue;  // scaled down
                if (rebake_pairs == rebake_cap) {
                    rebake_cap = rebake_cap ? rebake_cap * 2 : 65536;
                    for (int ch = 0; ch < 3; ch++)
                        rebake_seen[ch] = realloc(rebake_seen[ch], sizeof *rebake_seen[ch] * (size_t)rebake_cap);
                }
                for (int ch = 0; ch < 3; ch++) rebake_seen[ch][rebake_pairs] = (struct rebake_pair){lin[ch], b[2 - ch]};
                rebake_pairs++;
            }
}

static int rebake_pair_cmp(const void *a, const void *b)
{
    const struct rebake_pair *x = a, *y = b;
    return x->byte != y->byte ? x->byte - y->byte : (x->lin > y->lin) - (x->lin < y->lin);
}
static void rebake_learn_done(void)
{
    for (int ch = 0; ch < 3; ch++) {
        float *l = rebake_lin[ch];
        struct rebake_pair *q = rebake_seen[ch];
        qsort(q, (size_t)rebake_pairs, sizeof *q, rebake_pair_cmp);
        int at[257] = {0};  // each byte's first pair
        for (long i = 0, b = 0; b <= 256; b++) {
            while (i < rebake_pairs && q[i].byte < b) i++;
            at[b] = (int)i;
        }
        int last = -1;
        for (int b = 0; b < 256; b++) {
            int n = at[b + 1] - at[b];
            if (!n && b) continue;
            l[b] = n ? q[at[b] + n * 3 / 4].lin : 0.0f;
            for (int g = last + 1; g < b; g++) l[g] = l[last] + (l[b] - l[last]) * (float)(g - last) / (float)(b - last);
            last = b;
        }
        // Past the brightest byte seen: on as gamma 2.2 would go.
        for (int g = last + 1; g < 256; g++) l[g] = l[last] * powf((float)g / (float)(last ? last : 1), 2.2f);
        for (int b = 1; b < 256; b++) l[b] = fmaxf(l[b], l[b - 1]);
    }
    rebake_learnt = 1;
    for (int ch = 0; ch < 3; ch++) free(rebake_seen[ch]), rebake_seen[ch] = NULL;
    fprintf(stderr, "[metal] rebake: the lightmaps' encoding learnt from %ld samples: bytes 64, 128, 255 are %.3f %.3f %.3f\n",
            rebake_pairs, rebake_lin[1][64], rebake_lin[1][128], rebake_lin[1][255]);
}

// Linear light to the page's value (byte / 255, between bytes where it falls between),
// before the scaling down: past 1 for light brighter than byte 255's.
static float rebake_encode(const float *l, float v)
{
    if (!(v > l[0])) return 0.0f;
    if (v >= l[255]) return powf(v / l[255], 1.0f / 2.2f);
    int lo = 0, hi = 255;  // l[lo] < v <= l[hi]
    while (hi - lo > 1) {
        int m = (lo + hi) / 2;
        if (l[m] < v) lo = m;
        else hi = m;
    }
    return ((float)lo + (v - l[lo]) / (l[hi] - l[lo])) / 255.0f;
}

static void rebake_fill(struct lightmap_page *p, const struct bl_rebake *rb, const struct lightmap_match *m,
                        const uint8_t *tx, uint32_t pitch)
{
    const struct bl_bsp_face *f = &rb->world->faces[m->face];
    const struct bl_bake_face *bf = &rb->bake->faces[m->face];
    int w0 = f->size[0] + 1, h0 = f->size[1] + 1, sc = rb->bake->scale;
    if (bf->w != w0 * sc || bf->h != h0 * sc || sc != 4) return;
    if (!p->rb_page) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                     width:p->w * 4 height:p->h * 4
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        p->rb_page = [mtl newTextureWithDescriptor:d];
        d.width = p->w, d.height = p->h;
        p->rb_old = [mtl newTextureWithDescriptor:d];
    }
    if (!p->rb_rects) {
        p->rb_rects = calloc((size_t)p->w * p->h * 4, sizeof *p->rb_rects);
        p->rb_dirty[0] = p->rb_dirty[1] = 0, p->rb_dirty[2] = p->w, p->rb_dirty[3] = p->h;
    }
    __fp16 *buf = malloc(sizeof *buf * 4 * (size_t)bf->w * bf->h);
    int n0 = w0 * h0;
    for (int c = 0; c < m->copies; c++) {
        int x0 = m->rx + c * m->sx, y0 = m->ry + c * m->sy, k = f->bumped ? c : 0;
        for (int y = 0; y < bf->h; y++)
            for (int x = 0; x < bf->w; x++) {
                const float *lin = rb->bake->light[bf->offset + y * bf->w + x][k];
                __fp16 *o = buf + 4 * ((size_t)y * bf->w + x);
                float e[3], top = 1.0f;
                for (int ch = 0; ch < 3; ch++) e[ch] = rebake_encode(rebake_lin[ch], lin[ch]), top = fmaxf(top, e[ch]);
                for (int ch = 0; ch < 3; ch++) o[ch] = (__fp16)(e[ch] / top);
                o[3] = (__fp16)(tx[(size_t)(y0 + y / sc) * pitch + (size_t)(x0 + x / sc) * 4 + 3] / 255.0f);
            }
        [p->rb_page replaceRegion:MTLRegionMake2D((NSUInteger)x0 * 4, (NSUInteger)y0 * 4, (NSUInteger)bf->w, (NSUInteger)bf->h)
                      mipmapLevel:0
                        withBytes:buf
                      bytesPerRow:(NSUInteger)bf->w * 8];
        for (int y = 0; y < h0; y++)
            for (int x = 0; x < w0; x++) {
                float lin[3], e[3], top = 1.0f;
                bl_bake_rgbe(rb->world->lighting + 4 * ((size_t)f->lightofs + (size_t)k * n0 + (size_t)y * w0 + x), lin);
                for (int ch = 0; ch < 3; ch++) e[ch] = rebake_encode(rebake_lin[ch], lin[ch]), top = fmaxf(top, e[ch]);
                __fp16 *o = buf + 4 * ((size_t)y * w0 + x);
                for (int ch = 0; ch < 3; ch++) o[ch] = (__fp16)(e[ch] / top);
                o[3] = 1;
            }
        [p->rb_old replaceRegion:MTLRegionMake2D((NSUInteger)x0, (NSUInteger)y0, (NSUInteger)w0, (NSUInteger)h0)
                     mipmapLevel:0
                       withBytes:buf
                     bytesPerRow:(NSUInteger)w0 * 8];
        uint16_t r[4] = {(uint16_t)(x0 + 0x8000), (uint16_t)y0, (uint16_t)(x0 + w0), (uint16_t)(y0 + h0)};
        for (int y = y0; y < y0 + h0; y++)
            for (int x = x0; x < x0 + w0; x++) memcpy(p->rb_rects + ((size_t)y * p->w + x) * 4, r, sizeof r);
        lightmap_dirty(p->rb_dirty, x0, y0, x0 + w0, y0 + h0);
        rebake_budget -= (long)bf->w * bf->h;
    }
    free(buf);
    rebake_faces++;
}

// Starts a page over for a map (another, or the first with the rebake on): its
// rectangles are found again as it is drawn, so its surfaces are noted for the rebake.
static void lightmap_rebake_reset(struct lightmap_page *p, int gen)
{
    p->rb_gen = gen;
    p->nsurfs = p->nmatches = p->nfilled = 0;
    free(p->matched), p->matched = NULL;
    memset(p->rects, 0, (size_t)p->w * p->h * 4 * sizeof *p->rects);
    if (p->rb_rects) memset(p->rb_rects, 0, (size_t)p->w * p->h * 4 * sizeof *p->rb_rects);
    [p->ranges removeAllObjects];
    lightmap_dirty(p->dirty, 0, 0, (int)p->w, (int)p->h);
    lightmap_dirty(p->rb_dirty, 0, 0, (int)p->w, (int)p->h);
}

// For lightmap_for, with the rebake on: matches the surfaces noted so far, once the bake is
// done, and fills in what it can this frame. Returns whether to note surfaces.
static int lightmap_rebake_begin(struct lightmap_page *p, struct obj *tex)
{
    if (!env_rebake) return 0;
    if (rebake_frame != frames) {
        rebake_frame = frames;
        rebake_now = bl_rebake_get(1), rebake_gen_now = bl_rebake_gen();
        rebake_budget = 1 << 18;
    }
    if (p->rb_gen != rebake_gen_now) lightmap_rebake_reset(p, rebake_gen_now);
    const struct bl_rebake *rb = rebake_now;
    if (!rb || rb->gen != p->rb_gen || (!p->nsurfs && p->nfilled == p->nmatches)) return 1;
    struct obj *sub = tex->subs[0];
    if (!sub->mem || sub->pitch < p->w * 4) return 1;
    const uint8_t *tx = bl_g2h(sub->mem);
    rebake_index(rb);
    if (!p->matched) p->matched = calloc((size_t)rb->world->nfaces, 1);
    for (int i = 0; i < p->nsurfs; i++) {
        struct lightmap_match m;
        if (!rebake_match(rb, p, &p->surfs[i], &m)) {
            rebake_missed++;
            continue;
        }
        if (p->matched[m.face]) continue;
        p->matched[m.face] = 1;
        if (p->nmatches == p->capmatches)
            p->capmatches = p->capmatches ? p->capmatches * 2 : 256,
            p->matches = realloc(p->matches, sizeof *p->matches * (size_t)p->capmatches);
        p->matches[p->nmatches++] = m;
        if (!rebake_learnt) rebake_learn(rb->world, &m, tx, sub->pitch);
    }
    p->nsurfs = 0;
    if (!rebake_learnt && rebake_pairs >= REBAKE_PAIRS) rebake_learn_done();
    while (rebake_learnt && p->nfilled < p->nmatches && rebake_budget > 0)
        rebake_fill(p, rb, &p->matches[p->nfilled++], tx, sub->pitch);
    return 1;
}

static void lightmap_rebake_note(struct lightmap_page *p, const uint16_t rect[4], int sx, int sy, int copies,
                                 const float (*pos)[3], const float (*uv)[2], const uint32_t corner[3])
{
    if (p->nsurfs == p->capsurfs) {
        p->capsurfs = p->capsurfs ? p->capsurfs * 2 : 256;
        p->surfs = realloc(p->surfs, sizeof *p->surfs * (size_t)p->capsurfs);
    }
    struct lightmap_surf *sf = &p->surfs[p->nsurfs++];
    memcpy(sf->rect, rect, sizeof sf->rect);
    sf->sx = (int16_t)sx, sf->sy = (int16_t)sy, sf->copies = copies;
    for (int c = 0; c < 3; c++) memcpy(sf->pos[c], pos[corner[c]], sizeof sf->pos[c]), memcpy(sf->uv[c], uv[corner[c]], 8);
}

static int lightmap_rebaked(struct lightmap_page *p)
{
    return env_rebake && p->nfilled && p->rb_gen == rebake_gen_now && p->rb_page;
}

static id<MTLTexture> lightmap_rebake_page(struct lightmap_page *p, int old) { return old ? p->rb_old : p->rb_page; }

static id<MTLTexture> lightmap_rebake_rects(struct lightmap_page *p)
{
    lightmap_rects(p);
    if (!p->rb_gpu) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Uint
                                                                                     width:p->w height:p->h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        p->rb_gpu = [mtl newTextureWithDescriptor:d];
        p->rb_dirty[0] = p->rb_dirty[1] = 0, p->rb_dirty[2] = p->w, p->rb_dirty[3] = p->h;
    }
    if (p->rb_dirty[2] > p->rb_dirty[0]) {
        uint32_t x0 = p->rb_dirty[0], y0 = p->rb_dirty[1], w = p->rb_dirty[2] - x0, h = p->rb_dirty[3] - y0;
        uint16_t *t = malloc((size_t)w * h * 8);
        for (uint32_t y = 0; y < h; y++)
            for (uint32_t x = 0; x < w; x++) {
                size_t i = ((size_t)(y0 + y) * p->w + x0 + x) * 4;
                memcpy(t + ((size_t)y * w + x) * 4, p->rb_rects[i + 2] ? p->rb_rects + i : p->rects + i, 8);
            }
        [p->rb_gpu replaceRegion:MTLRegionMake2D(x0, y0, w, h) mipmapLevel:0 withBytes:t bytesPerRow:(NSUInteger)w * 8];
        free(t);
        p->rb_dirty[0] = p->w, p->rb_dirty[1] = p->h, p->rb_dirty[2] = p->rb_dirty[3] = 0;
    }
    return p->rb_gpu;
}

// A vertex shader's input with this TEXCOORD index, or -1.
static int texcoord_input(BLShader *sh, int index)
{
    for (int i = 0; i < 16; i++)
        if ((sh->info.input_mask & (1u << i)) && sh->info.input_usage[i] == 5 && sh->info.input_index[i] == index)
            return i;
    return -1;
}

static int lightmap_reg(BLShader *sh, int n)
{
    if (!sh->lm_known) {
        for (int i = 0; i < 8; i++)
            sh->lm_reg[i] = (int8_t)(sh->info.pixel ? d3d_shader_sample_coord(sh->code, i)
                                                    : d3d_shader_lightmap_coord(sh->code, i, texcoord_input(sh, 1),
                                                                                texcoord_input(sh, 2)));
        sh->lm_known = 1;
    }
    return sh->lm_reg[n];
}

static uint64_t lightmap_uv_key(const float *uv)
{
    uint32_t u, v;
    memcpy(&u, &uv[0], 4), memcpy(&v, &uv[1], 4);
    return (uint64_t)u << 32 | v;
}
static int lightmap_corner_cmp(const void *a, const void *b)
{
    uint64_t x = ((const uint64_t *)a)[0], y = ((const uint64_t *)b)[0];
    return x < y ? -1 : x > y;
}
static uint32_t lightmap_root(uint32_t *up, uint32_t i)
{
    while (up[i] != i) i = up[i] = up[up[i]];
    return i;
}

static struct lightmap_page *lightmap_for(struct d3d_state *s, struct element *el, int nel, uint32_t start,
                                          uint32_t count, int32_t base_vertex)
{
    if (!env_lightmap_smooth || (long)frames < env_lightmap_at || !s->vs || !s->ps || !s->indices || !count) return NULL;
    BLShader *vs = shader_of(s->vs), *ps = shader_of(s->ps);
    if (!vs->code || !ps->code) return NULL;
    // TEXCOORD1 the lightmap coordinates, TEXCOORD2 (bump-mapped) the step to the next of
    // the surface's copies side by side on the page.
    int uv_el = -1, off_el = -1;
    for (int i = 0; i < nel; i++)
        if (el[i].usage == 5 && el[i].type == 1 && (el[i].index == 1 || el[i].index == 2))  // FLOAT2
            *(el[i].index == 1 ? &uv_el : &off_el) = i;
    if (uv_el < 0 || texcoord_input(vs, 1) < 0) return NULL;
    struct obj *tex = NULL;
    uint32_t stages = 0;
    int bumped = 0;
    for (int i = 0; i < 8; i++) {
        struct obj *t = s->texture[i];
        if (!(ps->info.sampler_mask & (1u << i)) || !t || t->type != OBJ_TEXTURE || t->levels != 1 || t->format != 21 ||
            (t->usage & 1) || !t->subs || !t->subs[0] || (ps->info.major == 1 && (s->tss[i][24] & 256)) ||
            (tex && t != tex))
            continue;
        int tk = lightmap_reg(ps, i), kind = tk >= 0 && tk < 8 ? lightmap_reg(vs, tk) : 0;
        if (!kind || (kind == 2 && off_el < 0)) continue;
        tex = t, stages |= 1u << i, bumped |= kind == 2;
    }
    if (!stages) return NULL;
    if (!lightmap_pages) lightmap_pages = [NSMutableDictionary new];
    NSValue *pk = [NSValue valueWithPointer:tex];
    struct lightmap_page *p = [lightmap_pages[pk] pointerValue];
    if (!p) {
        p = calloc(1, sizeof *p);
        p->w = tex->width, p->h = tex->height;
        p->rects = calloc((size_t)p->w * p->h * 4, sizeof *p->rects);
        p->dirty[0] = p->w, p->dirty[1] = p->h;
        p->rb_dirty[0] = p->w, p->rb_dirty[1] = p->h;
        p->rb_gen = -1;
        p->ranges = [NSMutableSet new];
        lightmap_pages[pk] = [NSValue valueWithPointer:p];
    }
    lightmap_stages = stages;
    int rec = lightmap_rebake_begin(p, tex);

    // This range read already?
    int b = el[uv_el].stream;
    struct obj *v = s->stream[b], *ibo = s->indices;
    uint32_t stride = s->stream_stride[b];
    if (!v || !v->mem || !stride || !ibo->mem) return p;
    int is32 = ibo->format == 102;  // D3DFMT_INDEX32
    uint32_t isz = is32 ? 4 : 2, ni = count * 3;
    if ((uint64_t)start * isz + (uint64_t)ni * isz > ibo->size) return p;
    const uint8_t *ip = (const uint8_t *)bl_g2h(ibo->mem) + (size_t)start * isz;
#define IDX(i) (is32 ? ((const uint32_t *)ip)[i] : ((const uint16_t *)ip)[i])
    struct {
        uint64_t vb, ib;  // the buffers' serials
        uint32_t off, stride, rewrites, start, count, sample[8];
        int32_t base, bumped;
    } key;
    memset(&key, 0, sizeof key);  // padding too: the key is compared as bytes
    key.vb = v->serial, key.ib = ibo->serial, key.off = s->stream_offset[b] + el[uv_el].offset, key.stride = stride;
    key.rewrites = (uint32_t)v->rewrites, key.start = start, key.count = count, key.base = base_vertex;
    key.bumped = bumped;
    // The step to the copies, read with the coordinates (same stream: Source's world vertices).
    int step = bumped && el[off_el].stream == b ? (int)el[off_el].offset - (int)el[uv_el].offset : 0;
    if (bumped && !step) return p;
    // The rebake matches surfaces to the map's faces by their corners' positions.
    int pos_off = 0;
    if (rec) {
        rec = 0;
        for (int i = 0; i < nel && !rec; i++)
            if (el[i].usage == 0 && el[i].index == 0 && el[i].type == 2 && el[i].stream == b)  // FLOAT3
                rec = 1, pos_off = (int)el[i].offset - (int)el[uv_el].offset;
    }
    // Dynamic buffers are known by the coordinates read from them instead (below).
    int dynamic = (v->usage & 0x200) || v->rewrites >= 8 || (ibo->usage & 0x200);  // D3DUSAGE_DYNAMIC
    NSData *kd = nil;
    if (!dynamic) {
        for (int i = 0; i < 8; i++) key.sample[i] = IDX((uint32_t)i * (ni - 1) / 7);
        kd = [NSData dataWithBytes:&key length:sizeof key];
        if ([p->ranges containsObject:kd]) return p;
    }

    // Corners joined within a triangle and where their lightmap coordinates are the same.
    uint64_t(*corner)[2] = malloc(sizeof *corner * ni);
    uint32_t *up = malloc(sizeof *up * ni);
    float(*uv)[2] = malloc(sizeof *uv * ni), (*dv)[2] = malloc(sizeof *dv * ni);
    float(*pos)[3] = rec ? malloc(sizeof *pos * ni) : NULL;
    const uint8_t *vd = (const uint8_t *)bl_g2h(v->mem) + key.off;
    uint32_t n = 0;
    for (uint32_t i = 0; i < ni; i++) {
        int64_t vi = (int64_t)base_vertex + IDX(i);
        if (vi < 0 || (uint64_t)vi * stride + key.off - el[uv_el].offset + stride > v->size) break;
        memcpy(uv[i], vd + (size_t)vi * stride, 8);
        if (step) memcpy(dv[i], vd + (size_t)vi * stride + step, 8);
        if (rec) memcpy(pos[i], vd + (size_t)vi * stride + pos_off, 12);
        corner[i][0] = lightmap_uv_key(uv[i]), corner[i][1] = i;
        up[i] = i - i % 3;
        n = i + 1;
    }
#undef IDX
    n -= n % 3;
    if (dynamic) {
        struct { uint64_t hash; uint32_t n; int32_t bumped; } ck = {0xcbf29ce484222325ull, n, bumped};
        for (uint32_t i = 0; i < n; i++) {
            ck.hash = (ck.hash ^ corner[i][0]) * 0x100000001b3ull, ck.hash ^= ck.hash >> 29;
            if (step) ck.hash = (ck.hash ^ lightmap_uv_key(dv[i])) * 0x100000001b3ull, ck.hash ^= ck.hash >> 29;
        }
        kd = [NSData dataWithBytes:&ck length:sizeof ck];
        if ([p->ranges containsObject:kd]) {
            free(uv), free(dv), free(pos), free(up), free(corner);
            return p;
        }
    }
    if (p->ranges.count >= LIGHTMAP_MAX_RANGES) [p->ranges removeAllObjects];
    [p->ranges addObject:kd];
    lightmap_reads++;
    qsort(corner, n, sizeof *corner, lightmap_corner_cmp);
    for (uint32_t i = 1; i < n; i++)
        if (corner[i][0] == corner[i - 1][0]) {
            uint32_t a = lightmap_root(up, (uint32_t)corner[i][1]), c = lightmap_root(up, (uint32_t)corner[i - 1][1]);
            if (a != c) up[a] = c;
        }
    // For the rebake, three corners of each surface: the first, the one furthest from it,
    // and the one furthest from the line through those (fa[root], fb[root]).
    uint32_t *fa = NULL, *fb = NULL;
    if (rec) {
        fa = malloc(sizeof *fa * (n ? n : 1)), fb = malloc(sizeof *fb * (n ? n : 1));
        float *d = malloc(sizeof *d * (n ? n : 1));
        for (uint32_t i = 0; i < n; i++) fa[i] = fb[i] = i, d[i] = -1.0f;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t r = lightmap_root(up, i);
            float e[3] = {pos[i][0] - pos[r][0], pos[i][1] - pos[r][1], pos[i][2] - pos[r][2]};
            float dd = e[0] * e[0] + e[1] * e[1] + e[2] * e[2];
            if (dd > d[r]) d[r] = dd, fa[r] = i;
        }
        for (uint32_t i = 0; i < n; i++) d[i] = -1.0f;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t r = lightmap_root(up, i);
            const float *a = pos[r], *c = pos[fa[r]];
            float e[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]}, q[3] = {pos[i][0] - a[0], pos[i][1] - a[1], pos[i][2] - a[2]};
            float x[3] = {e[1] * q[2] - e[2] * q[1], e[2] * q[0] - e[0] * q[2], e[0] * q[1] - e[1] * q[0]};
            float dd = x[0] * x[0] + x[1] * x[1] + x[2] * x[2];
            if (dd > d[r]) d[r] = dd, fb[r] = i;
        }
        free(d);
    }
    // Each surface's bounds, in texels: its coordinates are at texel centres.
    float(*box)[4] = malloc(sizeof *box * (n ? n : 1));
    for (uint32_t i = 0; i < n; i++) box[i][0] = box[i][1] = INFINITY, box[i][2] = box[i][3] = -INFINITY;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t r = lightmap_root(up, i);
        float x = uv[i][0] * (float)p->w, y = uv[i][1] * (float)p->h;
        box[r][0] = fminf(box[r][0], x), box[r][1] = fminf(box[r][1], y);
        box[r][2] = fmaxf(box[r][2], x), box[r][3] = fmaxf(box[r][3], y);
    }
    for (uint32_t i = 0; i < n; i++) {
        if (lightmap_root(up, i) != i) continue;
        float *bx = box[i];
        if (!(bx[0] >= -0.01f * p->w && bx[2] <= 1.01f * p->w && bx[1] >= -0.01f * p->h && bx[3] <= 1.01f * p->h))
            continue;  // not a page's coordinates
        int x0 = (int)floorf(bx[0] + 1e-3f), y0 = (int)floorf(bx[1] + 1e-3f);
        int x1 = (int)ceilf(bx[2] - 1e-3f), y1 = (int)ceilf(bx[3] - 1e-3f);
        x0 = x0 < 0 ? 0 : x0, y0 = y0 < 0 ? 0 : y0;
        x1 = x1 > (int)p->w ? (int)p->w : x1, y1 = y1 > (int)p->h ? (int)p->h : y1;
        if (x1 <= x0 || y1 <= y0) continue;
        int fresh = 0;
        // Bump-mapped: the flat copy and the three for the bump directions, a step apart.
        int sx = step ? (int)lroundf(dv[i][0] * (float)p->w) : 0, sy = step ? (int)lroundf(dv[i][1] * (float)p->h) : 0;
        for (int c = 0; c < (step ? 4 : 1); c++) {
            int cx0 = x0 + c * sx, cy0 = y0 + c * sy, cx1 = x1 + c * sx, cy1 = y1 + c * sy;
            if (cx0 < 0 || cy0 < 0 || cx1 > (int)p->w || cy1 > (int)p->h) break;
            uint16_t r[4] = {(uint16_t)cx0, (uint16_t)cy0, (uint16_t)cx1, (uint16_t)cy1};
            for (int y = cy0; y < cy1; y++)
                for (int x = cx0; x < cx1; x++) {
                    uint16_t *t = p->rects + ((size_t)y * p->w + x) * 4;
                    if (!t[2]) memcpy(t, r, sizeof r), fresh = 1;
                    else if (memcmp(t, r, sizeof r) && t[2] != t[0]) {
                        // Two surfaces claim the texel: neither rectangle is sure there, and
                        // it is read bilinear (x1 = x0).
                        t[0] = t[1] = t[2] = t[3] = 1;
                        lightmap_clashes++;
                    }
                }
            lightmap_dirty(p->dirty, cx0, cy0, cx1, cy1);
            lightmap_dirty(p->rb_dirty, cx0, cy0, cx1, cy1);
        }
        lightmap_surfaces += fresh;
        if (rec && fresh) {
            uint16_t r[4] = {(uint16_t)x0, (uint16_t)y0, (uint16_t)x1, (uint16_t)y1};
            uint32_t three[3] = {i, fa[i], fb[i]};
            lightmap_rebake_note(p, r, sx, sy, step ? 4 : 1, (const float(*)[3])pos, (const float(*)[2])uv, three);
        }
    }
    free(box), free(uv), free(dv), free(pos), free(fa), free(fb), free(up), free(corner);
    return p;
}

// Props smoothed (prop_smooth.c, BL_PROP_TESS): the world view's rigid models (no bones in
// their vertex shader, no lightmap coordinates: props, not the map's own surfaces), drawn
// split into BL_TESS segments per edge and rounded, by the game's own shaders. Made once
// per mesh on the CPU, from its vertex buffers (static ones only) and index range; NULL
// for anything else, or where nothing would move (boxes, flat panels).
struct prop_swap {
    id<MTLBuffer> vb[16], ib;  // per stream, in its own layout; triangles
    uint32_t nidx;
};
static struct prop_swap *prop_swap;  // the draw's, while d3d_render_draw draws it
static NSMutableDictionary<NSData *, NSValue *> *prop_swaps;
static size_t prop_bytes;  // all of them, held to PROP_MAX_BYTES
#define PROP_MAX_BYTES ((size_t)768 << 20)

// Smoothed and remodelled props' key: the buffers' serials (dropped with the buffers,
// swaps_forget), layout and range, and a sample of the indices.
struct prop_key {
    uint64_t vb[16];
    uint32_t off[16], stride[16], rewrites[16];
    uint64_t ib;
    uint32_t start, count, sample[16];
    int32_t base;
    int split;
};

static struct prop_swap *prop_swap_for(struct d3d_state *s, struct element *el, int nel, uint32_t start,
                                       uint32_t count, int32_t base_vertex)
{
    if (!env_prop_tess || env_tess < 2 || view_state != 1 || !s->vs || !s->indices || !s->render_target[0] ||
        s->render_target[0] != s->back_buffer || count < 8 || count > 20000 || nel > 32)
        return NULL;
    BLShader *vs = shader_of(s->vs);
    for (int i = 0; i < 16; i++)
        if ((vs->info.input_mask & (1u << i)) && (vs->info.input_usage[i] == 1 || vs->info.input_usage[i] == 2))
            return NULL;
    struct prop_elem pel[32];
    int has_pos = 0, has_nrm = 0;
    struct prop_key key;
    memset(&key, 0, sizeof key);
    for (int i = 0; i < nel; i++) {
        int b = el[i].stream;
        if (b >= 16 || el[i].usage == 9 || (el[i].usage == 5 && el[i].index > 0)) return NULL;  // lightmapped: the map
        if (el[i].usage == 0 && el[i].index == 0 && el[i].type == 2) has_pos = 1;
        if (el[i].usage == 3 && el[i].index == 0 && el[i].type == 2) has_nrm = 1;
        pel[i] = (struct prop_elem){el[i].stream, el[i].offset, el[i].type, el[i].usage, el[i].index};
        struct obj *v = s->stream[b];
        if (!v || !v->mem || (v->usage & 0x200) || v->rewrites >= 8 || v->dirty || !s->stream_stride[b]) return NULL;
        key.vb[b] = v->serial, key.off[b] = s->stream_offset[b], key.stride[b] = s->stream_stride[b];
        key.rewrites[b] = (uint32_t)v->rewrites;
    }
    if (!has_pos || !has_nrm) return NULL;
    struct obj *ibo = s->indices;
    int is32 = ibo->format == 102;  // D3DFMT_INDEX32
    uint32_t isz = is32 ? 4 : 2, ni = count * 3;
    if (!ibo->mem || (uint64_t)start * isz + (uint64_t)ni * isz > ibo->size) return NULL;
    const uint8_t *ip = (const uint8_t *)bl_g2h(ibo->mem) + (size_t)start * isz;
#define IDX(i) (is32 ? ((const uint32_t *)ip)[i] : ((const uint16_t *)ip)[i])
    // Index buffers are read per draw, with no note of rewrites: a sample of this range
    // in the key stands for its contents.
    for (int i = 0; i < 16; i++) key.sample[i] = IDX((uint32_t)i * (ni - 1) / 15);
    key.ib = ibo->serial, key.start = start, key.count = count, key.base = base_vertex, key.split = env_tess;
    NSData *kd = [NSData dataWithBytes:&key length:sizeof key];
    if (!prop_swaps) prop_swaps = [NSMutableDictionary new];
    NSValue *hit = prop_swaps[kd];
    if (hit) {
        struct prop_swap *p = hit.pointerValue;
        return p->nidx ? p : NULL;
    }
    struct prop_swap *p = calloc(1, sizeof *p);
    prop_swaps[kd] = [NSValue valueWithPointer:p];
    uint32_t *idx = malloc(sizeof *idx * ni);
    if (!idx) return NULL;
    for (uint32_t i = 0; i < ni; i++) idx[i] = (uint32_t)(base_vertex + (int32_t)IDX(i));
#undef IDX
    struct prop_in in = {.el = pel, .nel = nel, .idx = idx, .ntris = count, .split = env_tess};
    for (int i = 0; i < nel; i++) {
        int b = el[i].stream;
        struct obj *v = s->stream[b];
        uint32_t off = s->stream_offset[b], st = s->stream_stride[b];
        in.data[b] = (const uint8_t *)bl_g2h(v->mem) + off;
        in.stride[b] = st, in.nverts[b] = v->size > off ? (v->size - off) / st : 0;
    }
    struct prop_out o;
    int r = prop_smooth(&in, &o);
    free(idx);
    static int logged;
    size_t bytes = (size_t)o.nidx * 4;
    for (int b = 0; b < 16; b++)
        if (o.data[b]) bytes += (size_t)o.nverts * in.stride[b];
    // Moved less than a thousandth of a triangle: flat, nothing to gain.
    if (r == 0 && o.moved > 1e-3f && prop_bytes + bytes <= PROP_MAX_BYTES) {
        for (int b = 0; b < 16; b++)
            if (o.data[b])
                p->vb[b] = [mtl newBufferWithBytes:o.data[b] length:(NSUInteger)o.nverts * in.stride[b]
                                           options:MTLResourceStorageModeShared];
        p->ib = [mtl newBufferWithBytes:o.idx length:(NSUInteger)o.nidx * 4 options:MTLResourceStorageModeShared];
        p->nidx = o.nidx;
        prop_bytes += bytes;
        if (logged++ < 40)
            fprintf(stderr, "[metal] prop smoothed: %u triangles into %u, %u corners on sharp edges, moved up to %.1f%% (%zu MB in all)\n",
                    count, o.nidx / 3, o.sharp, 100 * o.moved, prop_bytes >> 20);
    } else if (r == 0 && prop_bytes + bytes > PROP_MAX_BYTES)
        LOG_ONCE("[metal] props: %zu MB smoothed, no more\n", prop_bytes >> 20);
    prop_smooth_free(&o);
    return p->nidx ? p : NULL;
}

// Props remodelled (prop_remodel.c): a mesh whose triangles are exactly one a remodel
// was made for, drawn as the remodel in any pass. Looked up once per vertex and index
// range, of static buffers only (the game rewrites dynamic ones every frame), and only
// for draws of a listed mesh's size; NULL for anything else.
static NSMutableDictionary<NSData *, NSValue *> *remodel_swaps;

static struct prop_swap *remodel_swap_for(struct d3d_state *s, struct element *el, int nel, uint32_t start,
                                          uint32_t count, int32_t base_vertex)
{
    if (env_remodel_off || !s->indices || (s->indices->usage & 0x200) || nel > 32 || !prop_remodel_listed(count))
        return NULL;
    struct prop_elem pel[32];
    struct prop_key key;
    memset(&key, 0, sizeof key);
    for (int i = 0; i < nel; i++) {
        int b = el[i].stream;
        if (b >= 16) return NULL;
        pel[i] = (struct prop_elem){el[i].stream, el[i].offset, el[i].type, el[i].usage, el[i].index};
        struct obj *v = s->stream[b];
        if (!v || !v->mem || (v->usage & 0x200) || v->rewrites >= 8 || v->dirty || !s->stream_stride[b]) return NULL;
        key.vb[b] = v->serial, key.off[b] = s->stream_offset[b], key.stride[b] = s->stream_stride[b];
        key.rewrites[b] = (uint32_t)v->rewrites;
    }
    struct obj *ibo = s->indices;
    int is32 = ibo->format == 102;  // D3DFMT_INDEX32
    uint32_t isz = is32 ? 4 : 2, ni = count * 3;
    if (!ibo->mem || (uint64_t)start * isz + (uint64_t)ni * isz > ibo->size) return NULL;
    const uint8_t *ip = (const uint8_t *)bl_g2h(ibo->mem) + (size_t)start * isz;
#define IDX(i) (is32 ? ((const uint32_t *)ip)[i] : ((const uint16_t *)ip)[i])
    for (int i = 0; i < 16; i++) key.sample[i] = IDX((uint32_t)i * (ni - 1) / 15);  // as prop_swap_for
    key.ib = ibo->serial, key.start = start, key.count = count, key.base = base_vertex;
    NSData *kd = [NSData dataWithBytes:&key length:sizeof key];
    if (!remodel_swaps) remodel_swaps = [NSMutableDictionary new];
    NSValue *hit = remodel_swaps[kd];
    if (hit) {
        struct prop_swap *p = hit.pointerValue;
        return p->nidx ? p : NULL;
    }
    struct prop_swap *p = calloc(1, sizeof *p);
    remodel_swaps[kd] = [NSValue valueWithPointer:p];
    uint32_t *idx = malloc(sizeof *idx * ni);
    if (!idx) return NULL;
    for (uint32_t i = 0; i < ni; i++) idx[i] = (uint32_t)(base_vertex + (int32_t)IDX(i));
#undef IDX
    struct prop_in in = {.el = pel, .nel = nel, .idx = idx, .ntris = count};
    for (int i = 0; i < nel; i++) {
        int b = el[i].stream;
        struct obj *v = s->stream[b];
        uint32_t off = s->stream_offset[b], st = s->stream_stride[b];
        in.data[b] = (const uint8_t *)bl_g2h(v->mem) + off;
        in.stride[b] = st, in.nverts[b] = v->size > off ? (v->size - off) / st : 0;
    }
    struct prop_out o;
    char name[256];
    if (prop_remodel(&in, &o, name, sizeof name)) {
        for (int b = 0; b < 16; b++)
            if (o.data[b])
                p->vb[b] = [mtl newBufferWithBytes:o.data[b] length:(NSUInteger)o.nverts * in.stride[b]
                                           options:MTLResourceStorageModeShared];
        p->ib = [mtl newBufferWithBytes:o.idx length:(NSUInteger)o.nidx * 4 options:MTLResourceStorageModeShared];
        p->nidx = o.nidx;
        static NSMutableSet *logged;
        if (!logged) logged = [NSMutableSet set];
        if (![logged containsObject:@(name)]) {
            [logged addObject:@(name)];
            fprintf(stderr, "[remodel] %s: %u triangles drawn as %u\n", name, count, o.nidx / 3);
        }
    }
    free(idx);
    prop_smooth_free(&o);
    return p->nidx ? p : NULL;
}

// Hair, smoothed and remodelled props of buffers the game freed (d3d_render_forget), let go
// between frames.
static void prop_swap_release(struct prop_swap *p, size_t *bytes)
{
    if (!p) return;
    size_t n = p->ib.length;
    for (int b = 0; b < 16; b++) n += p->vb[b].length, p->vb[b] = nil;
    p->ib = nil;
    if (bytes) *bytes -= n < *bytes ? n : *bytes;
    free(p);
}

static void swaps_forget(void)
{
    if (!dead_buffers.count) return;
    NSMutableArray<NSData *> *gone = [NSMutableArray new];
    for (NSData *kd in hair_swaps) {
        const struct hair_key *k = kd.bytes;
        if ([dead_buffers containsObject:@(k->vb)] || [dead_buffers containsObject:@(k->ib)]) [gone addObject:kd];
    }
    for (NSData *kd in gone) {
        struct hair_swap *hs = hair_swaps[kd].pointerValue;
        if (hs) hs->vb = hs->ib = hs->base_ib = nil, hs->tex = hs->base_tex = nil, free(hs);
        [hair_swaps removeObjectForKey:kd];
    }
    NSMutableDictionary<NSData *, NSValue *> *props[2] = {prop_swaps, remodel_swaps};
    for (int d = 0; d < 2; d++) {
        [gone removeAllObjects];
        for (NSData *kd in props[d]) {
            const struct prop_key *k = kd.bytes;
            int dead = [dead_buffers containsObject:@(k->ib)];
            for (int b = 0; b < 16 && !dead; b++) dead = k->vb[b] && [dead_buffers containsObject:@(k->vb[b])];
            if (dead) [gone addObject:kd];
        }
        for (NSData *kd in gone) {
            prop_swap_release(props[d][kd].pointerValue, d == 0 ? &prop_bytes : NULL);
            [props[d] removeObjectForKey:kd];
        }
    }
    [dead_buffers removeAllObjects];
}

static void render_draw(struct d3d_state *s, uint32_t type, int32_t base_vertex, uint32_t min_index, uint32_t nverts,
                        uint32_t start, uint32_t count, int indexed);

void d3d_render_draw(struct d3d_state *s, uint32_t type, int32_t base_vertex, uint32_t min_index, uint32_t nverts,
                     uint32_t start, uint32_t count, int indexed, uint32_t unused0, uint32_t unused1)
{
    (void)unused0, (void)unused1;
    ensure_device();
    struct hair_swap *hs = NULL;
    struct prop_swap *ps = NULL;
    if (indexed && type == 4) {
        struct element el[64];
        int nel = vertex_elements(s, el, 64);
        hs = hair_swap_for(s, el, nel, start, count, base_vertex);
        if (!hs) ps = remodel_swap_for(s, el, nel, start, count, base_vertex);
        if (!hs && !ps) ps = prop_swap_for(s, el, nel, start, count, base_vertex);
        if (!hs && !ps) lightmap_draw = lightmap_for(s, el, nel, start, count, base_vertex);
    }
    lightmap_note_missed(s);
    if (!hs) {
        prop_swap = ps;
        render_draw(s, type, base_vertex, min_index, nverts, start, count, indexed);
        prop_swap = NULL, lightmap_draw = NULL;
        return;
    }
    if (!hs->nidx) {  // nothing of it kept
        draws++, frame_draws++;
        return;
    }
    // Strips: over the game's own hair (a base where they leave gaps), alpha-tested and
    // blended as hair (both sides), whatever the game set.
    if (hs->vb && hs->base_ib) {
        // The base pushed a little behind, as the strips lie on it (the fringe's on its locks).
        struct hair_swap base = {.ib = hs->base_ib, .nidx = hs->nbase_idx, .base_tex = hs->base_tex};
        uint32_t *rs = s->rs, bias[2] = {rs[195], rs[175]};
        float b = 64.0f / 16777215.0f, sl = 2.0f;
        memcpy(&rs[195], &b, 4), memcpy(&rs[175], &sl, 4);
        hair_swap = &base;
        if (base.nidx) render_draw(s, type, base_vertex, min_index, nverts, start, count, indexed);
        hair_swap = NULL;
        rs[195] = bias[0], rs[175] = bias[1];
    } else if (hs->vb)
        render_draw(s, type, base_vertex, min_index, nverts, start, count, indexed);
    uint32_t *rs = s->rs, saved[5] = {rs[15], rs[24], rs[25], rs[27], rs[22]};
    if (hs->vb) rs[15] = 1, rs[24] = 0x60, rs[25] = 7, rs[27] = 0, rs[22] = 1;
    hair_swap = hs;
    render_draw(s, type, base_vertex, min_index, nverts, start, count, indexed);
    hair_swap = NULL;
    rs[15] = saved[0], rs[24] = saved[1], rs[25] = saved[2], rs[27] = saved[3], rs[22] = saved[4];
}

static void render_draw(struct d3d_state *s, uint32_t type, int32_t base_vertex, uint32_t min_index, uint32_t nverts,
                        uint32_t start, uint32_t count, int indexed)
{
    ensure_device();
    draws++, frame_draws++;
    log_draw(s, indexed ? "drawindexed" : "draw", type, count);
    if (draw_stats && (long)frames >= draw_stats_frame && (long)frames < draw_stats_frame + draw_stats_count)
        fprintf(stderr, "[drawsrc] f%lu #%lu vb %#x+%u ib %#x start %u base %d min %u n %u vs %#x c11 %g %g %g %g zw %u at %g %g %g\n", frames,
                draws, s->stream[0] ? s->stream[0]->guest : 0, s->stream_offset[0], s->indices ? s->indices->guest : 0, start,
                base_vertex, min_index, nverts, s->vs ? s->vs->guest : 0, u2f(s->vs_f[11][0]), u2f(s->vs_f[11][1]),
                u2f(s->vs_f[11][2]), u2f(s->vs_f[11][3]), s->rs[14], u2f(s->vs_f[48][3]), u2f(s->vs_f[49][3]),
                u2f(s->vs_f[50][3]));  // at: the model's place, or its first bone's (c48..c50's w)
    if (!s->render_target[0] || !count) return;
    struct element el[64];
    int nel = vertex_elements(s, el, 64);
    post_before_draw(s, el, nel);
    hair_before_draw(s);
    BLRender *e = pass(s);
    struct pipe_key k;
    draw_prims = count;
    draw_tess = env_tess > 1 && env_round && env_tess_round > 0 && indexed && type == 4 && count <= TESS_MAX_PATCHES && s->indices && !hair_swap && !prop_swap;
    int ok = setup_draw(s, e, type, el, nel, &k);
    draw_tess = 0;
    if (!ok) return;
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
    static int dumped_shadow, dumped_caster, dumped_lightmap;
    int dump = dd && !strcmp(dd, "lightmap") ? (long)frames == draw_stats_frame && lightmap_missed && !dumped_lightmap++
             : dd && !strcmp(dd, "shadow")
                   ? (long)frames == draw_stats_frame &&
                         ((draw_reads_atlas(s) && !dumped_shadow++) ||
                          (s->render_target[0] && s->render_target[0]->owner == shadow_atlas && !dumped_caster++))
                   :
               dd && (dd[0] == 'p' ? (long)frames == draw_stats_frame &&
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
    uint32_t in_place = 0;  // streams bound as the static buffer itself (bit n), by stream_data
    struct stream_src src[16];
    for (int b = 0; b < 16; b++) {
        int used = 0;
        for (int i = 0; i < 16; i++)
            if (k.attr[i].format && k.attr[i].buffer == b) used = 1;
        if (!used) continue;
        int rebased;
        if (hair_swap && hair_swap->vb) {
            [e setVertexBuffer:hair_swap->vb offset:0 atIndex:(NSUInteger)b];
            continue;
        }
        if (prop_swap && prop_swap->vb[b]) {
            [e setVertexBuffer:prop_swap->vb[b] offset:0 atIndex:(NSUInteger)b];
            continue;
        }
        src[b] = stream_data(s->stream[b], s->stream_offset[b], s->stream_stride[b], first, nv, &rebased);
        if (!src[b].buf) {
            LOG_ONCE("[metal] draw without a vertex buffer on stream %d\n", b);
            return;
        }
        any_rebased |= rebased, all_rebased &= rebased;
        if (!rebased) in_place |= 1u << b;
        [e setVertexBuffer:src[b].buf offset:src[b].offset atIndex:(NSUInteger)b];
    }
    if (any_rebased && !all_rebased) {
        // Mixed static and dynamic streams: express everything relative to `first`. Only
        // the streams bound in place move; copies (dynamic or often rewritten buffers)
        // already start at `first`.
        for (int b = 0; b < 16; b++) {
            if (!(in_place & 1u << b)) continue;
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
    if (hair_swap) {
        ib = hair_swap->ib, io = 0, it = MTLIndexTypeUInt32, ic = hair_swap->nidx;
        if (hair_swap->vb) bv = 0;
    }
    if (prop_swap) ib = prop_swap->ib, io = 0, it = MTLIndexTypeUInt32, ic = prop_swap->nidx, bv = 0;
    for (int pass = 0; pass < 2; pass++) {
        if (pass) {  // hair's blended pass
            if (!k.psv.hair || !hair_soft_on() || !s->rs[15]) break;
            hair_pass = 2, draw_tess = k.vsv.tess;
            ok = setup_draw(s, e, type, el, nel, &k);
            hair_pass = 0, draw_tess = 0;
            if (!ok) break;
        }
        if (k.vsv.tess && draw_pre)
            draw_patches(e, ib, io, it, ic, bv);
        else
            [e drawIndexedPrimitives:primitive(type) indexCount:ic indexType:it indexBuffer:ib indexBufferOffset:io
                       instanceCount:1 baseVertex:bv baseInstance:0];
    }
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
    post_before_draw(s, el, nel);
    hair_before_draw(s);
    BLRender *e = pass(s);
    struct pipe_key k;
    // UP draws read stream 0 with the given stride.
    uint32_t saved_stride = s->stream_stride[0];
    s->stream_stride[0] = stride;
    draw_prims = count;
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
    BLCompute *blit = stat_compute(__func__);
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0
      destinationBytesPerRow:row destinationBytesPerImage:row * t.height];
    [blit endEncoding];
    static id<MTLSharedEvent> done;
    static uint64_t n;
    if (!done) done = [mtl newSharedEvent];
    commit(nil);
    [queue signalEvent:done value:++n];
    [done waitUntilSignaledValue:n timeoutMS:UINT64_MAX];
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
    // GetRenderTargetData: the guest copy of a render target after GPU rendering. The
    // game's copy is 32-bit (A8R8G8B8, X8R8G8B8); ours may be deeper (the back buffer in
    // 16-bit float with BL_DEEP_COLOR), which read_target converts. Not the shadow atlas.
    id<MTLTexture> t = (__bridge id<MTLTexture>)rt->gpu;
    if (!t || !rt->mem || (rt->format != 21 && rt->format != 22) || rt == shadow_atlas || obj_scale(rt) > 1 ||
        t.width != rt->width || t.height != rt->height || rt->pitch < rt->width * 4)
        return;
    end_pass();
    id<MTLBuffer> b = read_target(t);
    for (uint32_t y = 0; y < rt->height; y++)
        memcpy((uint8_t *)bl_g2h(rt->mem) + y * rt->pitch, (uint8_t *)b.contents + y * rt->width * 4, rt->width * 4);
}

// The frame's drawable, shown by next_frame once its commands are committed.
static id<CAMetalDrawable> present_drawable;
static int present_paced;

static void next_frame(void)
{
    __block dispatch_semaphore_t sem = in_flight;
    static int gpu_stats = -1;
    if (gpu_stats < 0) gpu_stats = getenv("BL_GPU_STATS") != NULL;
    int stats = gpu_stats;
    unsigned long frame = frames;
    int slot = frame_slot, pstats = gpu_pass_stats > 0;
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> b) {
      if (b.error) LOG_ONCE("[metal] frame %lu failed on the GPU: %s\n", frame, b.error.localizedDescription.UTF8String);
      if (pstats) pass_stats_done(slot, frame);
      if (stats) {  // BL_GPU_STATS=1: mean GPU time per frame, every 100 frames
          static double sum;
          static int n;
          sum += b.GPUEndTime - b.GPUStartTime;
          if (++n == 100) fprintf(stderr, "[gpu] %.2f ms a frame (to frame %lu)\n", sum * 10, frame), sum = 0, n = 0;
      }
      dispatch_semaphore_signal(sem);
    }];
    // The drawable (present): drawn into once the display has let go of it, shown once drawn.
    id<CAMetalDrawable> drawable = present_drawable;
    present_drawable = nil;
    if (drawable) [queue waitForDrawable:drawable];
    commit(options);
    if (drawable) {
        [queue signalDrawable:drawable];
        if (present_paced) [drawable presentAfterMinimumDuration:1.0 / fps_max];
        else [drawable present];
    }
    uint64_t t0 = hitch_now();
    dispatch_semaphore_wait(in_flight, DISPATCH_TIME_FOREVER);
    hitch_wait_ns += hitch_now() - t0;
    frame_slot = (frame_slot + 1) % FRAMES_IN_FLIGHT;
    [allocators[frame_slot] reset];
    mtl4_end_frame(frames);
    chunk_index = chunk_used = 0;
    pass_count[frame_slot] = 0;
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

// HDR output (BL_HDR): hdr_present from `pic` into `out`, brightening what is still the
// world view (`world`, nil for none).
static void hdr_draw(id<MTLTexture> pic, id<MTLTexture> world, id<MTLTexture> out, int preview)
{
    float headroom = env_hdr_headroom > 0 ? env_hdr_headroom : layer ? bl_cocoa_edr_headroom() : 4;
    LOG_ONCE("[metal] HDR: headroom %g\n", headroom);
    float hp[8] = {headroom, env_hdr_peak, env_hdr_knee, world ? 1.0f : 0.0f, (float)preview};
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = out;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    BLRender *e = stat_render(rp, __func__);
    [e setRenderPipelineState:ssr_pipeline(3, out.pixelFormat, MTLPixelFormatInvalid)];
    [e setFragmentTexture:pic atIndex:0];
    [e setFragmentTexture:world ? world : pic atIndex:1];
    [e setFragmentBytes:hp length:sizeof hp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// The drawable is 10-bit with deep colour: a blit needs equal formats, a draw converts.
static void copy_to_drawable(id<MTLTexture> t, id<MTLTexture> world, id<CAMetalDrawable> drawable)
{
    end_pass();
    mtl4_untracked(drawable.texture);
    if (drawable.texture.pixelFormat == MTLPixelFormatRGBA16Float) {
        hdr_draw(t, world, drawable.texture, 0);
    } else if (t.pixelFormat == drawable.texture.pixelFormat) {
        BLCompute *blit = stat_compute(__func__);
        [blit copyFromTexture:t toTexture:drawable.texture];
        [blit endEncoding];
    } else {
        uint32_t r[4] = {0, 0, (uint32_t)t.width, (uint32_t)t.height};
        stretch_draw(t, r, drawable.texture, r, 0);
    }
    end_pass();
    mtl4_untracked(nil);
}

static void present(id<CAMetalDrawable> drawable)
{
    if (env_pacing_stats) count_presented(drawable);
    present_drawable = drawable;
    present_paced = paced_present();
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
    swaps_forget();
    hitch_present_start = hitch_now();
    static uint32_t lightmap_logged;
    if (lightmap_reads != lightmap_logged && frames % 300 == 0) {
        fprintf(stderr, "[metal] lightmaps: %lu pages, %u surfaces, %u texels claimed twice, %u draws read\n",
                (unsigned long)lightmap_pages.count, lightmap_surfaces, lightmap_clashes, lightmap_reads);
        if (env_rebake)
            fprintf(stderr,
                    "[metal] rebake: %s, %u faces in, %u surfaces matched to none (%u no face with the corner, %u not all"
                    " three corners, %u copies, %u off whole texels, %u off the page); encoding %s\n",
                    rebake_now ? "baked" : "not baked yet", rebake_faces, rebake_missed, rebake_why[0], rebake_why[1],
                    rebake_why[2], rebake_why[3], rebake_why[4], rebake_learnt ? "learnt" : "not learnt");
        lightmap_logged = lightmap_reads;
    }
    ensure_device();
    if (env_exposure && frames % 300 == 0 && frames && (long)frames >= env_bloom_at) {
        const float *eye = exposure_buffer().contents;
        fprintf(stderr, "[metal] eye: exposure %.2f, view brightness %.3f (typical %.3f)\n", eye[0], eye[1], EXPOSURE_REF);
    }
    bl_vgui_poll();  // the options' check box
    if (view_state == 1) {  // a frame with no view model or HUD
        post_run(s);
        if ((ao_result || post_result || taa_pending) && s->render_target[0] == s->back_buffer) pass(s);
    }
    view_state = 0, ao_result = nil, post_result = 0;
    taa_frame_end();
    flush_clears(s);
    shadow_frame_start();
    gi_frame_start();
    frames++;
    bl_cocoa_script_input(frames, game_window);
    struct obj *bb = s->back_buffer;
    id<MTLTexture> back = bb ? target_texture(bb) : nil;
    if (back && frame_squeeze < 1) menu_bars(back, frame_squeeze);
    id<MTLTexture> world = hdr_world_frame + 1 == frames && hdr_world && back && hdr_world.width == back.width &&
                                   hdr_world.height == back.height
                               ? hdr_world
                               : nil;
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
        if (env_hdr) {
            id<MTLTexture> pv = ao_texture(8, MTLPixelFormatBGRA8Unorm, back.width, back.height);
            hdr_draw(back, world, pv, 1);
            snprintf(path, sizeof path, "%s/frame_%lu_hdr.png", dir, frames);
            write_png(read_target(pv), back.width, back.height, path);
        }
        id<MTLTexture> off = last_offscreen_target ? target_texture(last_offscreen_target) : nil;
        if (off && off.pixelFormat == MTLPixelFormatRGBA16Unorm) {  // the shadow atlas (shadows)
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:off.width
                                                                                         height:off.height
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> c = [mtl newTextureWithDescriptor:td];
            uint32_t r[4] = {0, 0, (uint32_t)off.width, (uint32_t)off.height};
            stretch_draw(off, r, c, r, 0);
            off = c;
        }
        if (off && off.pixelFormat == MTLPixelFormatBGRA8Unorm) {
            snprintf(path, sizeof path, "%s/frame_%lu_rt.png", dir, frames);
            write_png(read_target(off), off.width, off.height, path);
        }
    }
    if (layer && back) {
        @autoreleasepool {
            layer_format();
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (drawable && drawable.texture.width == back.width && drawable.texture.height == back.height) {
                copy_to_drawable(back, world, drawable);
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
    if (env_hitch > 0) {
        static uint64_t last;
        uint64_t now = hitch_now();
        double ms = last ? (now - last) / 1e6 : 0;
        // And every 100 frames, the mean frame and the part of it not waiting for the GPU.
        static double sum_ms, sum_wait;
        static int counted;
        sum_ms += ms, sum_wait += hitch_wait_ns / 1e6, counted++;
        if (frames % 100 == 0) {
            fprintf(stderr, "[cpu] frames to %lu: %.2f ms a frame, %.2f of it not waiting for the GPU\n", frames,
                    sum_ms / counted, (sum_ms - sum_wait) / counted);
            sum_ms = sum_wait = 0, counted = 0;
        }
        if (ms > env_hitch)
            fprintf(stderr,
                    "[hitch] frame %lu: %.1f ms (shaders %.1f, textures %.1f of which PBR maps %.1f, normal maps %.1f; "
                    "waiting for the GPU %.1f, present %.1f; %lu draws)\n",
                    frames, ms, frame_build_ns / 1e6, hitch_tex_ns / 1e6, hitch_pbr_ns / 1e6, hitch_detail_ns / 1e6,
                    hitch_wait_ns / 1e6, (now - hitch_present_start) / 1e6, frame_draws);
        last = now;
    }
    hitch_tex_ns = hitch_pbr_ns = hitch_detail_ns = hitch_wait_ns = 0;
    void bl_hitch_frame(unsigned long frame);
    bl_hitch_frame(frames);
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
        MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
        rp.colorAttachments[0].texture = screen;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        [stat_render(rp, __func__) endEncoding];
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
        layer_format();
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable && drawable.texture.width == sw && drawable.texture.height == sh) {
            copy_to_drawable(screen, nil, drawable);
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
    if (src_rect) {
        memcpy(sr, bl_g2h(src_rect), 16);
        for (int i = 0; i < 4; i++) sr[i] *= (uint32_t)obj_scale(src);
    }
    if (dst_rect) {
        memcpy(dr, bl_g2h(dst_rect), 16);
        for (int i = 0; i < 4; i++) dr[i] *= (uint32_t)obj_scale(dst);
    }
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
    BLCompute *blit = stat_compute(__func__);
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
    struct obj *tex = surface->owner;
    if (tex && tex->type != OBJ_DEVICE) tex->dirty = 1;
    // A texture's top level, filled while the map loads: its upscale and normal map start
    // loading now on other threads, not one by one when first drawn. Only its first fill: one
    // filled again and again (a texture the game draws into) is not one of the files.
    if (mtl && tex && tex->type == OBJ_TEXTURE && tex->nsubs && tex->subs[0] == surface && !(tex->usage & 0x200) &&
        surface->mem && !env_prefetch_off && !tex->prefetched++) {
        const uint8_t *data = bl_g2h(surface->mem);
        if (!env_upscale_off) bl_hires_prefetch(mtl, tex->width, tex->height, tex->format, data, surface->pitch);
        pbr_prefetch(tex->width, tex->height, tex->format, data, surface->pitch);
        if (env_detail > 0) bl_detail_prefetch(mtl, tex->width, tex->height, tex->format, data, surface->pitch);
    }
}

void d3d_buffer_changed(struct obj *buffer) { buffer->dirty = 1; }
