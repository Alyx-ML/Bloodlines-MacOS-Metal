// D3D9 shader bytecode (vs_1_1-vs_2_x, ps_1_1-ps_2_x) to Metal Shading Language.
//
// Every vertex shader writes the same varyings (struct BLVarying) and every pixel
// shader reads them, so any pair links. Buffer and texture slots:
//   vertex:   [[buffer(0..15)]] vertex streams, [[buffer(16)]] constant zero stream,
//             [[buffer(20)]] float constants c[256], [[buffer(21)]] struct BLVSParams
//   fragment: [[buffer(0)]] float constants c[224], [[buffer(1)]] struct BLPSParams,
//             [[texture(n)]] / [[sampler(n)]] for sampler n
#pragma once
#include <stdint.h>

#define D3D_SHADER_MAX_INPUTS 16
#define D3D_SHADER_MAX_SAMPLERS 16

enum d3d_input_kind { D3D_IN_FLOAT, D3D_IN_UINT, D3D_IN_SINT };  // shader-side attribute type
enum d3d_tex_kind { D3D_TEX_2D = 2, D3D_TEX_CUBE = 3, D3D_TEX_3D = 4 };  // D3DSAMPLER_TEXTURE_TYPE

struct d3d_shader_info {
    int pixel, major, minor;
    // Vertex shaders: declared inputs v<n> by usage and usage index.
    uint32_t input_mask;
    uint8_t input_usage[D3D_SHADER_MAX_INPUTS], input_index[D3D_SHADER_MAX_INPUTS];
    // Pixel shaders: samplers read, and their declared type (0 if not declared, ps_1_x).
    uint32_t sampler_mask;
    uint8_t sampler_type[D3D_SHADER_MAX_SAMPLERS];
    int writes_depth;
    uint32_t color_outputs;  // pixel: oC<n> written (ps_1_x: bit 0)
    // Constants the shader defines. D3D applies them over the constants the game sets,
    // for relative addressing too, so the renderer writes them into the uploaded copy.
    int ndefs, ndefis, ndefbs;
    struct { uint32_t reg; uint32_t value[4]; } defs[64], defis[16];
    struct { uint32_t reg, value; } defbs[16];
};

// What the generated code depends on beyond the bytecode.
struct d3d_shader_variant {
    uint8_t input_kind[D3D_SHADER_MAX_INPUTS];   // vertex: enum d3d_input_kind per v<n>
    uint8_t tex_kind[D3D_SHADER_MAX_SAMPLERS];   // pixel: enum d3d_tex_kind per sampler (0 = 2D)
    uint8_t projected[D3D_SHADER_MAX_SAMPLERS];  // ps_1_x: divide texcoords by component 3 or 4 (0 = no)
    // Pixel: also write [[color(1)]] for screen-space reflections (metal_render.m ssr_run):
    // rgb what the shader's reflection cubemaps added to oc0, a how much a white cubemap
    // would add (the mean over rgb); zero for shaders without one.
    uint8_t reflection_info;
    // Pixel, with reflection_info: a character (metal_render.m skin_run) writes
    // [[color(1)]] as its light alone (the colour texture read as white) and -1, or
    // without a colour texture 0 0 0 -2. Skin 2 only marks the character: 0 0 0 -2 always.
    // 3: an eyeball, 0 0 0 -3 (for its highlight).
    uint8_t skin;
    // With skin 1: a normal map for the colour texture at [[texture(15)]] and the
    // camera and lights at [[buffer(3)]] (metal_render.m detail_lights): the light is
    // scaled by how the map's bumps turn towards the lights (tex_detail.m).
    uint8_t detail;
    // Vertex: also output the clip-space step to the position nudged along the normal
    // (BLVSOut.bln), the smooth normal detail maps are laid on.
    uint8_t smooth_normal;
    // Vertex, with smooth_normal: a post-tessellation function over the draw's triangles
    // ([[patch(triangle, 3)]]), each split finer and its points pushed out onto the curve
    // the three corners' normals describe (Phong tessellation), so round shapes (heads,
    // arms) lose their facets. Needs the view's projection at [[buffer(22)]]:
    // {alpha, beta, p00, p11}, clip z = alpha * w + beta.
    uint8_t tess;
    // Pixel, with detail: hair, whose shine is a band across the strands (ps_detail). 2
    // also fades it near what was drawn before it, whose depth is at [[texture(14)]].
    uint8_t hair;
    // Pixel: samplers (bit n) that read the shadow atlas (metal_render.m, shadows). Their
    // reads become one soft-shadow lookup, bl_shadow_soft, with its parameters (struct
    // d3d_shadow_params) in [[buffer(2)]].
    uint8_t shadow_receiver;
    // Pixel: a shadow caster drawn into the atlas. Its alpha becomes 1 - depth, how near
    // to the light the caster is, which those lookups read.
    uint8_t shadow_caster;
};

// Soft shadows from the atlas (variant shadow_receiver): the atlas is seen as 8x8 cells
// of 128 texels, each pointing at the caster drawn over it.
struct d3d_shadow_cell {
    float z[4];     // the caster's light-space depth row: depth = dot(z.xyz, world) + z.w
    float rect[4];  // its viewport in the atlas, in texture coordinates (x0, y0, x1, y1)
    float k[4];     // world units per unit of depth, texture units per world unit, 1 if set, 0
};
struct d3d_shadow_params {
    float inv[4][4];  // the receiver's clip space to world, as rows
    float vp[4];      // its viewport: x, y, 1/width, 1/height
    float ndc[4];     // clip_y, half-pixel offsets x and y, penumbra per world unit of distance
    float lim[4];     // smallest penumbra (texture units), largest and search radius (world units), texel
    float show[4];    // x: 1 shows the blocker distance (red, 64 units), blockers found (green), penumbra (blue)
    struct d3d_shadow_cell cell[64];
};

// Pixel shader samplers that read a reflection cubemap: cube samplers whose result is
// not used as a vector (normalisation cubemaps are read with _bx2).
uint32_t d3d_shader_env_maps(const uint32_t *code);
// Returns 0 on success, else fills err.
int d3d_shader_parse(const uint32_t *code, struct d3d_shader_info *info, char *err, int errlen);
// MSL source (malloc'd) with entry point bl_main; NULL and err on failure.
char *d3d_shader_msl(const uint32_t *code, const struct d3d_shader_variant *v, char *err, int errlen);

// Uniforms besides the float constants. Layouts match the MSL structs the
// translator emits (BL_PARAMS_MSL in d3d9_shader.c).
struct d3d_vs_params {
    int32_t i[16][4];
    uint32_t b[16];
    float inv_viewport[2];  // 1/width, 1/height: D3D9's half-pixel offset
    float clip_y;           // scale of the output y (widescreen correction; 1 = none)
    float pad;
};

struct d3d_ps_params {
    int32_t i[16][4];
    uint32_t b[16];
    float bumpenv[8][4];      // BUMPENVMAT00, 01, 10, 11 per stage
    float bumpenv_l[8][4];    // BUMPENVLSCALE, BUMPENVLOFFSET
    float fog_color[4];
    float fog_start, fog_end, fog_density;
    uint32_t fog_mode;        // 0 off, 1 vertex (oFog), 2 linear, 3 exp, 4 exp2 (per pixel)
    float alpha_ref;
    uint32_t alpha_func;      // D3DCMPFUNC; 8 (ALWAYS) when alpha test is off
    float pad[2];
};

// Fixed-function pixel stages (draws with no pixel shader): the texture stage states
// that select the MSL d3d_ff_ps_msl emits. colorop 0 or 1 (DISABLE) ends the cascade.
struct d3d_ff_ps {
    uint8_t colorop[8], colorarg[8][3];  // arguments in D3D order: ARG0, ARG1, ARG2
    uint8_t alphaop[8], alphaarg[8][3];
    uint8_t resultarg[8], texcoord[8];
    uint8_t specular;  // SPECULARENABLE: add d1 at the end
};
uint32_t d3d_ff_ps_samplers(const struct d3d_ff_ps *k);  // stages that sample their texture
char *d3d_ff_ps_msl(const struct d3d_ff_ps *k, const struct d3d_shader_variant *v, char *err, int errlen);

// Fixed-function vertex stage (draws with no vertex shader); see d3d_ff_vs_msl.
struct d3d_ff_vs {
    uint8_t positiont;  // POSITIONT (already transformed, with RHW)
    uint8_t color[2];   // diffuse and specular present
    uint8_t tex_mask;   // texture coordinate sets present
};
char *d3d_ff_vs_msl(const struct d3d_ff_vs *k, char *err, int errlen);
