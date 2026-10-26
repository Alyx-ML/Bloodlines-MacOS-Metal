// D3D9 shader bytecode to MSL (see d3d9_shader.h).
//
// The bytecode is a stream of 32-bit tokens: a version token, then instructions (an
// opcode token followed by a destination and source parameter tokens), comments, and
// the end token 0x0000FFFF. Shader model 1 opcode tokens carry no length, so parameter
// counts come from a table. Each instruction becomes one MSL statement on float4
// registers; constants are read from buffers, which the renderer fills with the game's
// values overlaid with the shader's own def instructions.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "d3d9_shader.h"

enum {
    OP_NOP = 0, OP_MOV, OP_ADD, OP_SUB, OP_MAD, OP_MUL, OP_RCP, OP_RSQ, OP_DP3, OP_DP4, OP_MIN, OP_MAX, OP_SLT,
    OP_SGE, OP_EXP, OP_LOG, OP_LIT, OP_DST, OP_LRP, OP_FRC, OP_M4x4, OP_M4x3, OP_M3x4, OP_M3x3, OP_M3x2, OP_CALL,
    OP_CALLNZ, OP_LOOP, OP_RET, OP_ENDLOOP, OP_LABEL, OP_DCL, OP_POW, OP_CRS, OP_SGN, OP_ABS, OP_NRM, OP_SINCOS,
    OP_REP, OP_ENDREP, OP_IF, OP_IFC, OP_ELSE, OP_ENDIF, OP_BREAK, OP_BREAKC, OP_MOVA, OP_DEFB, OP_DEFI,
    OP_TEXCOORD = 64, OP_TEXKILL, OP_TEX, OP_TEXBEM, OP_TEXBEML, OP_TEXREG2AR, OP_TEXREG2GB, OP_TEXM3x2PAD,
    OP_TEXM3x2TEX, OP_TEXM3x3PAD, OP_TEXM3x3TEX, OP_RESERVED0, OP_TEXM3x3SPEC, OP_TEXM3x3VSPEC, OP_EXPP, OP_LOGP,
    OP_CND, OP_DEF, OP_TEXREG2RGB, OP_TEXDP3TEX, OP_TEXM3x2DEPTH, OP_TEXDP3, OP_TEXM3x3, OP_TEXDEPTH, OP_CMP,
    OP_BEM, OP_DP2ADD, OP_DSX, OP_DSY, OP_TEXLDD, OP_SETP, OP_TEXLDL, OP_BREAKP,
    OP_PHASE = 0xFFFD, OP_COMMENT = 0xFFFE, OP_END = 0xFFFF,
};

enum {
    REG_TEMP = 0, REG_INPUT, REG_CONST, REG_ADDR, REG_TEXTURE = 3, REG_RASTOUT, REG_ATTROUT, REG_TEXCRDOUT,
    REG_OUTPUT = 6, REG_CONSTINT, REG_COLOROUT, REG_DEPTHOUT, REG_SAMPLER, REG_CONST2, REG_CONST3, REG_CONST4,
    REG_CONSTBOOL, REG_LOOP, REG_TEMPFLOAT16, REG_MISCTYPE, REG_LABEL, REG_PREDICATE,
};

// Parameter tokens (destination + sources) for shader model 1, by opcode.
static int sm1_params(int op, int pixel, int minor)
{
    switch (op) {
    case OP_NOP: case OP_PHASE: return 0;
    case OP_TEXCOORD: case OP_TEX: return pixel && minor == 4 ? 2 : 1;
    case OP_TEXKILL: case OP_TEXDEPTH: return 1;
    case OP_MOV: case OP_RCP: case OP_RSQ: case OP_EXP: case OP_LOG: case OP_LIT: case OP_FRC: case OP_EXPP:
    case OP_LOGP: case OP_DCL: case OP_TEXBEM: case OP_TEXBEML: case OP_TEXREG2AR: case OP_TEXREG2GB:
    case OP_TEXM3x2PAD: case OP_TEXM3x2TEX: case OP_TEXM3x3PAD: case OP_TEXM3x3TEX: case OP_TEXM3x3VSPEC:
    case OP_TEXREG2RGB: case OP_TEXDP3TEX: case OP_TEXM3x2DEPTH: case OP_TEXDP3: case OP_TEXM3x3: return 2;
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DP3: case OP_DP4: case OP_MIN: case OP_MAX: case OP_SLT:
    case OP_SGE: case OP_DST: case OP_M4x4: case OP_M4x3: case OP_M3x4: case OP_M3x3: case OP_M3x2:
    case OP_TEXM3x3SPEC: case OP_BEM: return 3;
    case OP_MAD: case OP_LRP: case OP_CND: case OP_CMP: return 4;
    case OP_DEF: return 5;
    default: return -1;
    }
}

static int reg_type(uint32_t t) { return (int)(((t >> 28) & 7) | ((t >> 8) & 0x18)); }
static uint32_t reg_num(uint32_t t) { return t & 0x7FF; }

// --- output buffer -------------------------------------------------------------

struct out {
    char *s;
    size_t n, cap;
    int indent;
};

static void put(struct out *o, const char *fmt, ...)
{
    va_list ap;
    for (;;) {
        va_start(ap, fmt);
        size_t room = o->cap - o->n;
        int k = vsnprintf(o->s + o->n, room, fmt, ap);
        va_end(ap);
        if ((size_t)k < room) {
            o->n += (size_t)k;
            return;
        }
        o->cap = o->cap * 2 + (size_t)k + 256;
        o->s = realloc(o->s, o->cap);
    }
}

static void line(struct out *o, const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    put(o, "%*s%s\n", 4 * o->indent, "", buf);
}

// --- parsing ---------------------------------------------------------------------

struct insn {
    int op, control, coissue;
    int nparams;
    const uint32_t *p;  // parameter tokens (relative-address tokens inline for SM2+)
};

struct parser {
    const uint32_t *code, *pc;
    int pixel, major, minor;
    char *err;
    int errlen;
};

static int fail(struct parser *ps, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(ps->err, (size_t)ps->errlen, fmt, ap);
    va_end(ap);
    return -1;
}

static int start(struct parser *ps, const uint32_t *code, char *err, int errlen)
{
    ps->code = code, ps->pc = code + 1, ps->err = err, ps->errlen = errlen;
    uint32_t v = code[0];
    ps->pixel = v >> 16 == 0xFFFF;
    if (!ps->pixel && v >> 16 != 0xFFFE) return fail(ps, "bad version token 0x%08x", v);
    ps->major = (int)(v >> 8 & 0xFF), ps->minor = (int)(v & 0xFF);
    if (ps->major < 1 || ps->major > 2) return fail(ps, "unsupported shader model %d.%d", ps->major, ps->minor);
    return 0;
}

// 1 and the next instruction, 0 at the end, -1 on error.
static int next(struct parser *ps, struct insn *in)
{
    for (;;) {
        uint32_t t = *ps->pc;
        int op = (int)(t & 0xFFFF);
        if (op == OP_END) return 0;
        if (op == OP_COMMENT) {
            ps->pc += 1 + (t >> 16 & 0x7FFF);
            continue;
        }
        in->op = op;
        in->control = (int)(t >> 16 & 0xFF);
        in->coissue = (t >> 30) & 1;
        int n = ps->major >= 2 ? (int)(t >> 24 & 0xF) : sm1_params(op, ps->pixel, ps->minor);
        if (op == OP_DEFI) n = 5;
        else if (op == OP_DEFB) n = 2;
        else if (op == OP_DEF) n = 5;
        if (n < 0) return fail(ps, "unknown opcode %d", op);
        in->nparams = n;
        in->p = ps->pc + 1;
        ps->pc += 1 + n;
        return 1;
    }
}

int d3d_shader_parse(const uint32_t *code, struct d3d_shader_info *info, char *err, int errlen)
{
    struct parser ps;
    memset(info, 0, sizeof *info);
    if (start(&ps, code, err, errlen)) return -1;
    info->pixel = ps.pixel, info->major = ps.major, info->minor = ps.minor;
    if (ps.pixel && ps.major == 1) info->color_outputs = 1;
    struct insn in;
    int r;
    while ((r = next(&ps, &in)) > 0) {
        const uint32_t *p = in.p;
        if (in.op == OP_DCL) {
            uint32_t d = p[0], reg = p[1];
            int type = reg_type(reg);
            uint32_t n = reg_num(reg);
            if (!ps.pixel && type == REG_INPUT && n < D3D_SHADER_MAX_INPUTS) {
                info->input_mask |= 1u << n;
                info->input_usage[n] = (uint8_t)(d & 0x1F);
                info->input_index[n] = (uint8_t)(d >> 16 & 0xF);
            } else if (type == REG_SAMPLER && n < D3D_SHADER_MAX_SAMPLERS) {
                info->sampler_mask |= 1u << n;
                info->sampler_type[n] = (uint8_t)(d >> 27 & 0xF);
            }
            continue;
        }
        if (in.op == OP_DEF && info->ndefs < 64) {
            info->defs[info->ndefs].reg = reg_num(p[0]);
            memcpy(info->defs[info->ndefs++].value, p + 1, 16);
            continue;
        }
        if (in.op == OP_DEFI && info->ndefis < 16) {
            info->defis[info->ndefis].reg = reg_num(p[0]);
            memcpy(info->defis[info->ndefis++].value, p + 1, 16);
            continue;
        }
        if (in.op == OP_DEFB && info->ndefbs < 16) {
            info->defbs[info->ndefbs].reg = reg_num(p[0]);
            info->defbs[info->ndefbs++].value = p[1];
            continue;
        }
        if (in.nparams == 0) continue;
        int dtype = reg_type(p[0]);
        if (ps.pixel && dtype == REG_DEPTHOUT) info->writes_depth = 1;
        if (ps.pixel && dtype == REG_COLOROUT) info->color_outputs |= 1u << reg_num(p[0]);
        if (ps.pixel && in.op == OP_TEXDEPTH) info->writes_depth = 1;
        // Shader model 1 pixel shaders sample stage n through t<n> (or r<n> in ps_1_4).
        if (ps.pixel && ps.major == 1) {
            switch (in.op) {
            case OP_TEX: case OP_TEXBEM: case OP_TEXBEML: case OP_TEXREG2AR: case OP_TEXREG2GB: case OP_TEXREG2RGB:
            case OP_TEXM3x2TEX: case OP_TEXM3x3TEX: case OP_TEXM3x3SPEC: case OP_TEXM3x3VSPEC: case OP_TEXDP3TEX:
                info->sampler_mask |= 1u << reg_num(p[0]);
                break;
            }
        }
        if (ps.pixel && ps.major == 2 && in.op == OP_TEX) info->sampler_mask |= 1u << reg_num(p[2]);
    }
    return r < 0 ? -1 : 0;
}

// The sampler an instruction reads, or -1.
static int sampled_stage(const struct parser *ps, const struct insn *in)
{
    if (!ps->pixel || !in->nparams) return -1;
    if (ps->major == 2) return in->op == OP_TEX ? (int)reg_num(in->p[2]) : -1;
    switch (in->op) {
    case OP_TEX: case OP_TEXBEM: case OP_TEXBEML: case OP_TEXREG2AR: case OP_TEXREG2GB: case OP_TEXREG2RGB:
    case OP_TEXM3x2TEX: case OP_TEXM3x3TEX: case OP_TEXM3x3SPEC: case OP_TEXM3x3VSPEC: case OP_TEXDP3TEX:
        return (int)reg_num(in->p[0]);
    default: return -1;
    }
}

uint32_t d3d_shader_env_maps(const uint32_t *code)
{
    struct parser ps;
    struct insn in;
    char err[128];
    uint32_t sampled = 0, vector = 0, dst[D3D_SHADER_MAX_SAMPLERS];
    if (start(&ps, code, err, sizeof err) || !ps.pixel) return 0;
    while (next(&ps, &in) > 0) {
        int stage = sampled_stage(&ps, &in);
        if (stage < 0 || stage >= D3D_SHADER_MAX_SAMPLERS) continue;
        sampled |= 1u << stage;
        dst[stage] = in.p[0];
    }
    // A sample read with _bias or _bx2 (signed or not) is a vector, not a colour.
    start(&ps, code, err, sizeof err);
    while (next(&ps, &in) > 0) {
        if (in.op == OP_DCL || in.op == OP_DEF || in.op == OP_DEFI || in.op == OP_DEFB) continue;
        for (int i = 1; i < in.nparams; i++) {
            uint32_t t = in.p[i], mod = t >> 24 & 0xF;
            if (mod < 2 || mod > 5) continue;
            for (int k = 0; k < D3D_SHADER_MAX_SAMPLERS; k++)
                if ((sampled & (1u << k)) && reg_type(t) == reg_type(dst[k]) && reg_num(t) == reg_num(dst[k]))
                    vector |= 1u << k;
        }
    }
    return sampled & ~vector;
}

// A source token read as it is: no modifier, no relative address, x and y unswizzled.
static int plain_source(uint32_t t) { return !(t >> 24 & 0xF) && !(t & 0x2000) && (t >> 16 & 0xF) == 0x4; }

int d3d_shader_sample_coord(const uint32_t *code, int stage)
{
    struct parser ps;
    struct insn in;
    char err[128];
    int coord = -1;
    if (start(&ps, code, err, sizeof err) || !ps.pixel) return -1;
    while (next(&ps, &in) > 0) {
        if (sampled_stage(&ps, &in) != stage) continue;
        int k;
        if (ps.major == 1 && ps.minor < 4) k = in.op == OP_TEX ? stage : -1;
        else if (in.op != OP_TEX || (ps.major == 2 && in.control)) k = -1;  // texldp, texldb
        else k = reg_type(in.p[1]) == REG_TEXTURE && plain_source(in.p[1]) ? (int)reg_num(in.p[1]) : -1;
        if (k < 0 || (coord >= 0 && coord != k)) return -1;
        coord = k;
    }
    return coord;
}

int d3d_shader_lightmap_coord(const uint32_t *code, int out, int lm, int off)
{
    struct parser ps;
    struct insn in;
    char err[128];
    int kind = 0;
    uint32_t is_off = 0;  // temporaries holding a copy of v<off>
    if (start(&ps, code, err, sizeof err) || ps.pixel) return 0;
    while (next(&ps, &in) > 0) {
        if (in.op == OP_DCL || in.op == OP_DEF || in.op == OP_DEFI || in.op == OP_DEFB || !in.nparams) continue;
        for (int i = 1; i < in.nparams; i++)
            if (in.p[i] & 0x2000) return 0;  // relative addressing (SM2 inserts its token)
        uint32_t d = in.p[0];
        int dt = reg_type(d), dn = (int)reg_num(d);
#define IS_IN(t, n) (reg_type(t) == REG_INPUT && (int)reg_num(t) == (n) && plain_source(t))
#define IS_OFF(t) (off >= 0 && (IS_IN(t, off) || (reg_type(t) == REG_TEMP && reg_num(t) < 32 && \
                                                     (is_off >> reg_num(t) & 1) && plain_source(t))))
        if (dt == REG_TEMP && dn < 32) {
            if (in.op == OP_MOV && IS_IN(in.p[1], off) && off >= 0) is_off |= 1u << dn;
            else is_off &= ~(1u << dn);
            continue;
        }
        if (dt != REG_TEXCRDOUT || dn != out) continue;
        if (d >> 20 & 0xF) return 0;  // result modifier
        int k = 0;
        if (in.op == OP_MOV && IS_IN(in.p[1], lm)) k = 1;
        else if (in.op == OP_ADD && ((IS_IN(in.p[1], lm) && IS_OFF(in.p[2])) || (IS_OFF(in.p[1]) && IS_IN(in.p[2], lm))))
            k = 2;
        else if (in.op == OP_MAD && IS_IN(in.p[3], lm) &&
                 ((IS_OFF(in.p[1]) && reg_type(in.p[2]) == REG_CONST) ||
                  (reg_type(in.p[1]) == REG_CONST && IS_OFF(in.p[2]))))
            k = 2;
#undef IS_OFF
#undef IS_IN
        if (!k || (kind && kind != k)) return 0;
        kind = k;
    }
    return kind;
}

// --- code generation -------------------------------------------------------------

struct gen {
    struct parser ps;
    struct out o;
    const struct d3d_shader_variant *v;
    struct d3d_shader_info info;
    // Deferred writes of a co-issued pair (ps_1_x).
    char pending[2][512];
    int npending;
    int nco;  // co-issue temporaries so far: each gets its own name
    // Reflection cubemaps (variant reflection_info) and what they read for now: 0 the
    // texture, 1 black, 2 white.
    uint32_t env;
    int env_value;
    // Skin (variant skin): stage 0, the colour texture, read as white for now (its alpha
    // kept, which may mask the shine).
    int white_base;
    char base_coord[96];  // what stage 0's 2D texture is read with (for the detail normal map)
};

static const char comp[] = "xyzw";

// Name of a register for reading or writing (without swizzle or modifiers).
static int reg_name(struct gen *g, uint32_t tok, const uint32_t *rel, char *buf, size_t len)
{
    int type = reg_type(tok);
    uint32_t n = reg_num(tok);
    int pixel = g->ps.pixel;
    switch (type) {
    case REG_TEMP: snprintf(buf, len, "r%u", n); return 0;
    case REG_INPUT:
        if (pixel) snprintf(buf, len, "v%u", n);
        else snprintf(buf, len, "v%u", n);
        return 0;
    case REG_CONST: case REG_CONST2: case REG_CONST3: case REG_CONST4: {
        uint32_t base = n + (type == REG_CONST2 ? 2048 : type == REG_CONST3 ? 4096 : type == REG_CONST4 ? 6144 : 0);
        int size = pixel ? 224 : 256;
        if (tok & 0x2000) {  // relative
            char idx[64];
            if (g->ps.major == 1 || !rel) {
                snprintf(idx, sizeof idx, "a0.x");
            } else {
                int rt = reg_type(*rel);
                int c = (int)(*rel >> 16 & 3);
                snprintf(idx, sizeof idx, "%s.%c", rt == REG_LOOP ? "int4(aL)" : "a0", comp[c]);
            }
            snprintf(buf, len, "bl_c(c, %s + %u, %d)", idx, base, size);
        } else {
            snprintf(buf, len, "c[%u]", base);
        }
        return 0;
    }
    case REG_TEXTURE:  // vertex: a0
        if (!pixel) snprintf(buf, len, "float4(a0)");
        else snprintf(buf, len, "t%u", n);
        return 0;
    case REG_RASTOUT:
        snprintf(buf, len, "%s", n == 0 ? "opos" : n == 1 ? "ofog" : "opts");
        return 0;
    case REG_ATTROUT: snprintf(buf, len, "od%u", n); return 0;
    case REG_TEXCRDOUT:  // pixel: REG_OUTPUT is shader model 3 only
        snprintf(buf, len, "ot%u", n);
        return 0;
    case REG_CONSTINT: snprintf(buf, len, "float4(p.i[%u])", n); return 0;
    case REG_COLOROUT: snprintf(buf, len, "oc%u", n); return 0;
    case REG_DEPTHOUT: snprintf(buf, len, "odepth"); return 0;
    case REG_CONSTBOOL: snprintf(buf, len, "p.b[%u]", n); return 0;
    case REG_LOOP: snprintf(buf, len, "float4(aL)"); return 0;
    default: return fail(&g->ps, "register type %d not supported", type);
    }
}

// Source operand as a float4 expression.
static int src(struct gen *g, const uint32_t **pp, char *buf, size_t len)
{
    uint32_t tok = *(*pp)++;
    const uint32_t *rel = NULL;
    if ((tok & 0x2000) && g->ps.major >= 2) rel = (*pp)++;
    char name[128];
    if (reg_name(g, tok, rel, name, sizeof name)) return -1;
    uint32_t sw = tok >> 16 & 0xFF;
    char swz[8] = "";
    if (sw != 0xE4 && reg_type(tok) != REG_CONSTBOOL) {
        swz[0] = '.';
        for (int i = 0; i < 4; i++) swz[1 + i] = comp[sw >> (2 * i) & 3];
        swz[5] = 0;
    }
    int mod = (int)(tok >> 24 & 0xF);
    char x[200];
    snprintf(x, sizeof x, "%s%s", name, swz);
    switch (mod) {
    case 0: snprintf(buf, len, "%s", x); break;
    case 1: snprintf(buf, len, "(-%s)", x); break;
    case 2: snprintf(buf, len, "(%s - 0.5)", x); break;
    case 3: snprintf(buf, len, "(0.5 - %s)", x); break;
    case 4: snprintf(buf, len, "(2.0 * %s - 1.0)", x); break;
    case 5: snprintf(buf, len, "(1.0 - 2.0 * %s)", x); break;
    case 6: snprintf(buf, len, "(1.0 - %s)", x); break;
    case 7: snprintf(buf, len, "(2.0 * %s)", x); break;
    case 8: snprintf(buf, len, "(-2.0 * %s)", x); break;
    case 9: snprintf(buf, len, "(%s / %s.z)", x, name); break;
    case 10: snprintf(buf, len, "(%s / %s.w)", x, name); break;
    case 11: snprintf(buf, len, "abs(%s)", x); break;
    case 12: snprintf(buf, len, "(-abs(%s))", x); break;
    default: return fail(&g->ps, "source modifier %d not supported", mod);
    }
    return 0;
}

// The component a scalar instruction reads: the last one of the swizzle.
static int scalar_src(struct gen *g, const uint32_t **pp, char *buf, size_t len)
{
    char x[256];
    if (src(g, pp, x, sizeof x)) return -1;
    snprintf(buf, len, "(%s).w", x);
    return 0;
}

// Writes a float4 expression to the destination with mask, shift and saturate.
static int emit_dst(struct gen *g, uint32_t tok, const char *expr, int coissue)
{
    char name[128];
    if (reg_name(g, tok, NULL, name, sizeof name)) return -1;
    int type = reg_type(tok);
    uint32_t mask = tok >> 16 & 0xF;
    int mod = (int)(tok >> 20 & 0xF);
    int shift = (int)(tok >> 24 & 0xF);
    if (shift & 8) shift -= 16;
    char e[640];
    if (shift > 0) snprintf(e, sizeof e, "((%s) * %d.0)", expr, 1 << shift);
    else if (shift < 0) snprintf(e, sizeof e, "((%s) * %g)", expr, 1.0 / (1 << -shift));
    else snprintf(e, sizeof e, "(%s)", expr);
    char f[700];
    if (mod & 1) snprintf(f, sizeof f, "saturate%s", e);
    else snprintf(f, sizeof f, "%s", e);
    char stmt[900];
    if (type == REG_ADDR && !g->ps.pixel) {
        // a0: round to nearest (vs_1_1 mov and vs_2_0 mova).
        char m[8] = ".";
        int k = 1;
        for (int i = 0; i < 4; i++)
            if (mask & (1u << i)) m[k++] = comp[i];
        m[k] = 0;
        snprintf(stmt, sizeof stmt, "a0%s = int4(floor(%s + 0.5))%s;", mask == 0xF ? "" : m, f, mask == 0xF ? "" : m);
    } else if (type == REG_DEPTHOUT) {
        snprintf(stmt, sizeof stmt, "odepth = (%s).x;", f);
    } else if (mask == 0xF || mask == 0) {
        snprintf(stmt, sizeof stmt, "%s = %s;", name, f);
    } else {
        char m[8] = ".";
        int k = 1;
        for (int i = 0; i < 4; i++)
            if (mask & (1u << i)) m[k++] = comp[i];
        m[k] = 0;
        snprintf(stmt, sizeof stmt, "%s%s = (%s)%s;", name, m, f, m);
    }
    if (!coissue && !g->npending) {
        line(&g->o, "%s", stmt);
        return 0;
    }
    // Co-issued instructions read their sources before either writes.
    int t = g->nco++;
    line(&g->o, "float4 _co%d = %s;", t, f);
    char *at = strstr(stmt, f);
    if (!at) return fail(&g->ps, "internal: co-issue rewrite");
    snprintf(g->pending[g->npending], sizeof g->pending[0], "%.*s_co%d%s", (int)(at - stmt), stmt, t,
             at + strlen(f));
    g->npending++;
    return 0;
}

static void flush_pending(struct gen *g)
{
    for (int i = 0; i < g->npending; i++) line(&g->o, "%s", g->pending[i]);
    g->npending = 0;
}

static const char *tex_type(int kind)
{
    return kind == D3D_TEX_CUBE ? "texturecube<float>" : kind == D3D_TEX_3D ? "texture3d<float>" : "texture2d<float>";
}

static int tex_kind(struct gen *g, uint32_t stage)
{
    int k = g->info.sampler_type[stage];
    if (!k && g->v) k = g->v->tex_kind[stage];
    return k ? k : D3D_TEX_2D;
}

// Sample expression for a stage with float4 coordinates.
static void sample(struct gen *g, uint32_t stage, const char *coord, const char *extra, char *buf, size_t len)
{
    if (g->env_value && stage < 32 && (g->env & (1u << stage))) {
        snprintf(buf, len, "float4(%s)", g->env_value == 1 ? "0.0" : "1.0");
        return;
    }
    int k = tex_kind(g, stage);
    if (g->v && stage < 8 && (g->v->shadow_receiver & (1u << stage)) && k == D3D_TEX_2D) {
        snprintf(buf, len, "bl_shadow_once(_sh, _shd, tex%u, smp%u, (%s).xy, in.pos, sp)", stage, stage, coord);
        return;
    }
    if (g->v && stage < 8 && (g->v->lightmap & (1u << stage)) && k == D3D_TEX_2D) {
        snprintf(buf, len, "bl_lightmap(tex%u, smp%u, bl_lr, (%s).xy)", stage, stage, coord);
        return;
    }
    if (g->white_base && stage == 0 && k == D3D_TEX_2D) {
        snprintf(buf, len, "float4(1.0, 1.0, 1.0, tex0.sample(smp0, (%s).xy%s).w)", coord, extra ? extra : "");
        return;
    }
    if (stage == 0 && k == D3D_TEX_2D && !g->base_coord[0]) snprintf(g->base_coord, sizeof g->base_coord, "%s", coord);
    snprintf(buf, len, "tex%u.sample(smp%u, (%s).%s%s)", stage, stage, coord, k == D3D_TEX_2D ? "xy" : "xyz",
             extra ? extra : "");
}

// ps_1_x texture coordinate of stage n, with the projection the game set up.
static void ps1_coord(struct gen *g, uint32_t n, char *buf, size_t len)
{
    int proj = g->v ? g->v->projected[n] : 0;
    if (proj == 3) snprintf(buf, len, "(in.t%u / in.t%u.z)", n, n);
    else if (proj == 4) snprintf(buf, len, "(in.t%u / in.t%u.w)", n, n);
    else snprintf(buf, len, "in.t%u", n);
}

static const char *const header =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BLVSParams { int4 i[16]; uint b[16]; float2 inv_viewport; float clip_y; float pad; };\n"
    "struct BLPSParams { int4 i[16]; uint b[16]; float4 bumpenv[8]; float4 bumpenv_l[8]; float4 fog_color;\n"
    "    float fog_start, fog_end, fog_density; uint fog_mode; float alpha_ref; uint alpha_func; float pad0, pad1; };\n"
    "struct BLVSOut {\n"
    "    float4 pos [[position]]; float psize [[point_size]];\n"
    "    float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];\n"
    "    float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]]; float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]];\n"
    "    float4 t4 [[user(t4)]]; float4 t5 [[user(t5)]]; float4 t6 [[user(t6)]]; float4 t7 [[user(t7)]];\n"
    "    float fog [[user(fog)]]; float fogz [[user(fogz)]];\n"
    "    float4 bln [[user(bln)]];\n"
    "};\n"
    "struct BLPSIn {\n"
    "    float4 pos [[position]];\n"
    "    float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];\n"
    "    float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]]; float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]];\n"
    "    float4 t4 [[user(t4)]]; float4 t5 [[user(t5)]]; float4 t6 [[user(t6)]]; float4 t7 [[user(t7)]];\n"
    "    float fog [[user(fog)]]; float fogz [[user(fogz)]];\n"
    "    float4 bln [[user(bln)]];\n"
    "};\n"
    "static inline float4 bl_c(constant float4 *c, int i, int n) { return uint(i) < uint(n) ? c[i] : float4(0.0); }\n"
    "static inline float4 bl_lit(float4 s) {\n"
    "    float4 d = float4(1.0, 0.0, 0.0, 1.0);\n"
    "    if (s.x > 0.0) { d.y = s.x; d.z = s.y > 0.0 ? pow(s.y, clamp(s.w, -128.0, 128.0)) : 0.0; }\n"
    "    return d;\n"
    "}\n"
    "static inline float bl_log(float x) { return x == 0.0 ? -INFINITY : log2(abs(x)); }\n"
    "static inline float bl_rcp(float x) { return x == 0.0 ? INFINITY : 1.0 / x; }\n"
    "static inline float bl_rsq(float x) { return x == 0.0 ? INFINITY : rsqrt(abs(x)); }\n"
    "static inline bool bl_cmp(uint f, float a, float b) {\n"
    "    switch (f) { case 1: return false; case 2: return a < b; case 3: return a == b; case 4: return a <= b;\n"
    "    case 5: return a > b; case 6: return a != b; case 7: return a >= b; default: return true; }\n"
    "}\n";

// Lightmaps read smoothly (variant lightmap; metal_render.m, lightmaps): Catmull-Rom over
// 4x4 texels, which passes through each texel (small shadows keep their depth, unlike a
// B-spline's blur) without bilinear's creases, held within the four nearest texels so it
// cannot ring. Every texel read is kept inside the surface's own rectangle of the page
// (the rectangle of the texel the coordinate falls in; none known: bilinear), so no light
// comes in from the surfaces packed next to it.
static const char *const lightmap_msl =
    "static float4 bl_lightmap(texture2d<float> t, sampler s, texture2d<ushort> lr, float2 uv) {\n"
    "    float2 sz = float2(t.get_width(), t.get_height()), p = uv * sz;\n"
    "    int4 r = int4(lr.read(uint2(clamp(p, float2(0.0), sz - 1.0))));\n"
    "    if (r.z <= r.x) return t.sample(s, uv);\n"
    "    float2 q = p - 0.5, f = q - floor(q);\n"
    "    float2 w[4] = {f * (-0.5 + f * (1.0 - 0.5 * f)), 1.0 + f * f * (-2.5 + 1.5 * f),\n"
    "                   f * (0.5 + f * (2.0 - 1.5 * f)), f * f * (-0.5 + 0.5 * f)};\n"
    "    int2 b = int2(floor(q)) - 1, lo = r.xy, hi = r.zw - 1;\n"
    "    float4 sum = 0.0, mn = INFINITY, mx = -INFINITY;\n"
    "    for (int y = 0; y < 4; y++)\n"
    "        for (int x = 0; x < 4; x++) {\n"
    "            float4 c = t.read(uint2(clamp(b + int2(x, y), lo, hi)));\n"
    "            sum += w[x].x * w[y].y * c;\n"
    "            if ((x == 1 || x == 2) && (y == 1 || y == 2)) mn = min(mn, c), mx = max(mx, c);\n"
    "        }\n"
    "    return clamp(sum, mn, mx);\n"
    "}\n";

// Soft shadows (variant shadow_receiver; metal_render.m, shadows): percentage-closer
// soft shadows from the atlas. The receiver's world position comes back from its pixel's
// depth; the cell under the texture coordinate gives the caster's light-space depth row
// and size. A blocker search (24 point taps) averages the depth of the casters around, the
// penumbra grows with the distance from them, and 24 filtered taps over a disc of that
// size give the shadow (a fixed pattern: turning it per pixel showed as grain, with no
// temporal filter to smooth it). Taps stay inside the caster's own viewport.
static const char *const shadow_msl =
    "struct BLShadowCell { float4 z, rect, k; };\n"
    "struct BLShadowParams { float4 inv[4]; float4 vp, ndc, lim, show; BLShadowCell cell[64]; };\n"
    "static float4 bl_shadow_soft(texture2d<float> t, sampler s, float2 uv, float4 fpos, constant BLShadowParams &sp) {\n"
    "    int2 ci = clamp(int2(floor(uv * 8.0)), int2(0), int2(7));\n"
    "    BLShadowCell cl = sp.cell[ci.y * 8 + ci.x];\n"
    "    if (cl.k.z == 0.0) return t.sample(s, uv);\n"
    "    float2 m = float2((fpos.x - sp.vp.x) * sp.vp.z * 2.0 - 1.0, 1.0 - (fpos.y - sp.vp.y) * sp.vp.w * 2.0);\n"
    "    float4 h = float4(m.x - sp.ndc.y, (m.y + sp.ndc.z) / sp.ndc.x, fpos.z, 1.0);\n"
    "    float4 w = float4(dot(sp.inv[0], h), dot(sp.inv[1], h), dot(sp.inv[2], h), dot(sp.inv[3], h));\n"
    "    float zr = dot(cl.z.xyz, w.xyz / w.w) + cl.z.w;\n"
    "    float2 lo = cl.rect.xy + sp.lim.w, hi = cl.rect.zw - sp.lim.w;\n"
    "    constexpr sampler ns(filter::nearest, address::clamp_to_edge);  // depths do not filter\n"
    "    constexpr sampler ls(filter::linear, address::clamp_to_edge);\n"
    "    float zb = 0.0, nb = 0.0, rs = sp.lim.z * cl.k.y;\n"
    "    for (int i = 0; i < 24; i++) {\n"
    "        float d = sqrt(float(i) / 24.0), b = float(i) * 2.3999632;\n"
    "        float2 o = float2(cos(b), sin(b)) * d;\n"
    "        float4 c = t.sample(ns, clamp(uv + o * rs, lo, hi), level(0.0));\n"
    "        if (max(c.x, max(c.y, c.z)) > 0.002) { zb += cl.k.w > 0.5 ? c.w : 1.0 - c.w; nb += 1.0; }\n"
    "    }\n"
    "    if (nb == 0.0) return sp.show.x > 0.0 ? float4(0.0, 0.0, 1.0, 0.0) : t.sample(s, uv);\n"
    "    float dist = abs(zr - zb / nb) * cl.k.x;\n"
    "    float pen = max(min(dist * sp.ndc.w, sp.lim.y) * cl.k.y, sp.lim.x);\n"
    "    if (sp.show.x > 0.0) return float4(saturate(dist / 64.0), nb / 24.0, saturate(pen * 100.0), 0.0);\n"
    "    float4 sum = 0.0;\n"
    "    for (int i = 0; i < 24; i++) {\n"
    "        float d = sqrt((float(i) + 0.5) / 24.0), b = float(i) * 2.3999632;\n"
    "        float2 o = float2(cos(b), sin(b)) * d;\n"
    "        sum += t.sample(ls, clamp(uv + o * pen, lo, hi), level(0.0));\n"
    "    }\n"
    "    return sum / 24.0;\n"
    "}\n"
    "static inline float4 bl_shadow_once(thread float4 &sh, thread bool &done, texture2d<float> t, sampler s, float2 uv,\n"
    "                                    float4 fpos, constant BLShadowParams &sp) {\n"
    "    if (!done) sh = bl_shadow_soft(t, s, uv, fpos, sp), done = true;\n"
    "    return sh;\n"
    "}\n";

static int gen_body(struct gen *g)
{
    struct insn in;
    int r;
    char a[512], b[512], c[512], e[1600];
    int m3x2_row = 0;  // texm3x2pad/texm3x3pad rows seen
    while ((r = next(&g->ps, &in)) > 0) {
        if (!in.coissue && g->npending) flush_pending(g);
        const uint32_t *p = in.p;
        uint32_t dst = in.nparams ? p[0] : 0;
        const uint32_t *s = p + 1;
        switch (in.op) {
        case OP_NOP: case OP_PHASE: case OP_DCL: case OP_DEF: case OP_DEFI: case OP_DEFB: continue;
        case OP_MOV: case OP_MOVA:
            if (src(g, &s, a, sizeof a)) return -1;
            snprintf(e, sizeof e, "%s", a);
            break;
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_MIN: case OP_MAX: case OP_SLT: case OP_SGE: case OP_DP3:
        case OP_DP4: case OP_DST: case OP_CRS:
            if (src(g, &s, a, sizeof a) || src(g, &s, b, sizeof b)) return -1;
            switch (in.op) {
            case OP_ADD: snprintf(e, sizeof e, "%s + %s", a, b); break;
            case OP_SUB: snprintf(e, sizeof e, "%s - %s", a, b); break;
            case OP_MUL: snprintf(e, sizeof e, "%s * %s", a, b); break;
            case OP_MIN: snprintf(e, sizeof e, "min(%s, %s)", a, b); break;
            case OP_MAX: snprintf(e, sizeof e, "max(%s, %s)", a, b); break;
            case OP_SLT: snprintf(e, sizeof e, "select(float4(0.0), float4(1.0), %s < %s)", a, b); break;
            case OP_SGE: snprintf(e, sizeof e, "select(float4(0.0), float4(1.0), %s >= %s)", a, b); break;
            case OP_DP3: snprintf(e, sizeof e, "float4(dot((%s).xyz, (%s).xyz))", a, b); break;
            case OP_DP4: snprintf(e, sizeof e, "float4(dot(%s, %s))", a, b); break;
            case OP_DST: snprintf(e, sizeof e, "float4(1.0, (%s).y * (%s).y, (%s).z, (%s).w)", a, b, a, b); break;
            case OP_CRS: snprintf(e, sizeof e, "float4(cross((%s).xyz, (%s).xyz), 0.0)", a, b); break;
            }
            break;
        case OP_MAD: case OP_LRP: case OP_CMP: case OP_CND: case OP_DP2ADD:
            if (src(g, &s, a, sizeof a) || src(g, &s, b, sizeof b) || src(g, &s, c, sizeof c)) return -1;
            switch (in.op) {
            case OP_MAD: snprintf(e, sizeof e, "%s * %s + %s", a, b, c); break;
            case OP_LRP: snprintf(e, sizeof e, "mix(%s, %s, %s)", c, b, a); break;
            case OP_CMP: snprintf(e, sizeof e, "select(%s, %s, %s >= 0.0)", c, b, a); break;
            case OP_CND:
                if (g->ps.minor < 4) snprintf(e, sizeof e, "((%s).w > 0.5 ? %s : %s)", a, b, c);
                else snprintf(e, sizeof e, "select(%s, %s, %s > 0.5)", c, b, a);
                break;
            case OP_DP2ADD: snprintf(e, sizeof e, "float4(dot((%s).xy, (%s).xy) + (%s).w)", a, b, c); break;
            }
            break;
        case OP_RCP: case OP_RSQ: case OP_EXP: case OP_EXPP: case OP_LOG: case OP_LOGP: case OP_FRC: case OP_LIT:
        case OP_ABS: case OP_SGN: case OP_NRM:
            if (in.op == OP_FRC || in.op == OP_LIT || in.op == OP_ABS || in.op == OP_SGN || in.op == OP_NRM) {
                if (src(g, &s, a, sizeof a)) return -1;
            } else if (scalar_src(g, &s, a, sizeof a)) {
                return -1;
            }
            switch (in.op) {
            case OP_RCP: snprintf(e, sizeof e, "float4(bl_rcp(%s))", a); break;
            case OP_RSQ: snprintf(e, sizeof e, "float4(bl_rsq(%s))", a); break;
            case OP_EXP: case OP_EXPP: snprintf(e, sizeof e, "float4(exp2(%s))", a); break;
            case OP_LOG: case OP_LOGP: snprintf(e, sizeof e, "float4(bl_log(%s))", a); break;
            case OP_FRC: snprintf(e, sizeof e, "fract(%s)", a); break;
            case OP_LIT: snprintf(e, sizeof e, "bl_lit(%s)", a); break;
            case OP_ABS: snprintf(e, sizeof e, "abs(%s)", a); break;
            case OP_SGN: snprintf(e, sizeof e, "sign(%s)", a); break;
            case OP_NRM: snprintf(e, sizeof e, "(%s) * rsqrt(max(dot((%s).xyz, (%s).xyz), 1e-30))", a, a, a); break;
            }
            break;
        case OP_POW:
            if (scalar_src(g, &s, a, sizeof a) || scalar_src(g, &s, b, sizeof b)) return -1;
            snprintf(e, sizeof e, "float4(pow(abs(%s), %s))", a, b);
            break;
        case OP_SINCOS:
            if (scalar_src(g, &s, a, sizeof a)) return -1;
            snprintf(e, sizeof e, "float4(cos(%s), sin(%s), 0.0, 0.0)", a, a);
            break;
        case OP_M4x4: case OP_M4x3: case OP_M3x4: case OP_M3x3: case OP_M3x2: {
            if (src(g, &s, a, sizeof a)) return -1;
            int rows = in.op == OP_M4x4 || in.op == OP_M3x4 ? 4 : in.op == OP_M3x2 ? 2 : 3;
            int four = in.op == OP_M4x4 || in.op == OP_M4x3;
            char rowexpr[4][300];
            for (int k = 0; k < rows; k++) {
                // The matrix rows are consecutive registers from the second source.
                uint32_t mt[2] = {s[0] + (uint32_t)k, s[1]};
                const uint32_t *mp = mt;
                if (src(g, &mp, b, sizeof b)) return -1;
                if (four) snprintf(rowexpr[k], sizeof rowexpr[k], "dot(%s, %s)", a, b);
                else snprintf(rowexpr[k], sizeof rowexpr[k], "dot((%s).xyz, (%s).xyz)", a, b);
            }
            if (rows == 4) snprintf(e, sizeof e, "float4(%s, %s, %s, %s)", rowexpr[0], rowexpr[1], rowexpr[2], rowexpr[3]);
            else if (rows == 3) snprintf(e, sizeof e, "float4(%s, %s, %s, 0.0)", rowexpr[0], rowexpr[1], rowexpr[2]);
            else snprintf(e, sizeof e, "float4(%s, %s, 0.0, 0.0)", rowexpr[0], rowexpr[1]);
            break;
        }
        // Flow control (vertex shader model 2).
        case OP_REP:
            if (src(g, &s, a, sizeof a)) return -1;
            line(&g->o, "for (int _rep%d = 0; _rep%d < int((%s).x); _rep%d++) {", g->o.indent, g->o.indent, a,
                 g->o.indent);
            g->o.indent++;
            continue;
        case OP_LOOP: {
            uint32_t it = s[1];
            line(&g->o, "aL = p.i[%u].y;", reg_num(it));
            line(&g->o, "for (int _n%d = 0; _n%d < p.i[%u].x; _n%d++, aL += p.i[%u].z) {", g->o.indent, g->o.indent,
                 reg_num(it), g->o.indent, reg_num(it));
            g->o.indent++;
            continue;
        }
        case OP_ENDREP: case OP_ENDLOOP: case OP_ENDIF:
            g->o.indent--;
            line(&g->o, "}");
            continue;
        case OP_ELSE:
            g->o.indent--;
            line(&g->o, "} else {");
            g->o.indent++;
            continue;
        case OP_IF:
            if (src(g, &p, a, sizeof a)) return -1;
            line(&g->o, "if (%s) {", a);
            g->o.indent++;
            continue;
        case OP_IFC: case OP_BREAKC: {
            static const char *const ops[] = {"", ">", "==", ">=", "<", "!=", "<="};
            if (src(g, &p, a, sizeof a) || src(g, &p, b, sizeof b)) return -1;
            if (in.control < 1 || in.control > 6) return fail(&g->ps, "bad comparison %d", in.control);
            if (in.op == OP_IFC) {
                line(&g->o, "if ((%s).x %s (%s).x) {", a, ops[in.control], b);
                g->o.indent++;
            } else {
                line(&g->o, "if ((%s).x %s (%s).x) break;", a, ops[in.control], b);
            }
            continue;
        }
        case OP_BREAK: line(&g->o, "break;"); continue;
        // Pixel shader texture instructions.
        case OP_TEXCOORD:
            if (g->ps.minor < 4) {
                uint32_t n = reg_num(dst);
                snprintf(e, sizeof e, "float4(saturate(in.t%u.xyz), 1.0)", n);
            } else {  // texcrd
                if (src(g, &s, a, sizeof a)) return -1;
                snprintf(e, sizeof e, "float4((%s).xyz, 1.0)", a);
            }
            break;
        case OP_TEXKILL: {
            char reg[128];
            if (reg_name(g, dst, NULL, reg, sizeof reg)) return -1;
            if (g->ps.major == 1 && reg_type(dst) == REG_TEXTURE && g->ps.minor == 4)
                snprintf(reg, sizeof reg, "in.t%u", reg_num(dst));
            line(&g->o, "if (any((%s).%s < 0.0)) discard_fragment();", reg, g->ps.major == 1 ? "xyz" : "xyzw");
            continue;
        }
        case OP_TEX: {
            if (g->ps.major == 2) {
                if (src(g, &s, a, sizeof a)) return -1;
                uint32_t stage = reg_num(*s);
                if (in.control == 1) {  // texldp
                    snprintf(b, sizeof b, "((%s) / (%s).w)", a, a);
                    sample(g, stage, b, NULL, e, sizeof e);
                } else if (in.control == 2) {  // texldb
                    snprintf(c, sizeof c, ", bias((%s).w)", a);
                    sample(g, stage, a, c, e, sizeof e);
                } else {
                    sample(g, stage, a, NULL, e, sizeof e);
                }
            } else if (g->ps.minor == 4) {  // texld rN, src: stage N
                if (src(g, &s, a, sizeof a)) return -1;
                // A texture coordinate source reads the interpolated texcoord.
                uint32_t st = s[-1];
                if (reg_type(st) == REG_TEXTURE) {
                    char co[128];
                    ps1_coord(g, reg_num(st), co, sizeof co);
                    int mod = (int)(st >> 24 & 0xF);
                    if (mod == 9) snprintf(a, sizeof a, "(%s / %s.z)", co, co);
                    else if (mod == 10) snprintf(a, sizeof a, "(%s / %s.w)", co, co);
                    else snprintf(a, sizeof a, "%s", co);
                }
                sample(g, reg_num(dst), a, NULL, e, sizeof e);
            } else {
                uint32_t n = reg_num(dst);
                ps1_coord(g, n, a, sizeof a);
                sample(g, n, a, NULL, e, sizeof e);
            }
            break;
        }
        case OP_TEXBEM: case OP_TEXBEML: {
            uint32_t n = reg_num(dst);
            if (src(g, &s, a, sizeof a)) return -1;
            ps1_coord(g, n, c, sizeof c);
            snprintf(b, sizeof b,
                     "float4((%s).xy + float2(p.bumpenv[%u].x * (%s).x + p.bumpenv[%u].z * (%s).y, "
                     "p.bumpenv[%u].y * (%s).x + p.bumpenv[%u].w * (%s).y), 0.0, 1.0)",
                     c, n, a, n, a, n, a, n, a);
            sample(g, n, b, NULL, e, sizeof e);
            if (in.op == OP_TEXBEML) {
                char t[1600];
                snprintf(t, sizeof t, "(%s * saturate((%s).z * p.bumpenv_l[%u].x + p.bumpenv_l[%u].y))", e, a, n, n);
                snprintf(e, sizeof e, "%s", t);
            }
            break;
        }
        case OP_TEXREG2AR: case OP_TEXREG2GB: case OP_TEXREG2RGB: {
            if (src(g, &s, a, sizeof a)) return -1;
            const char *sw = in.op == OP_TEXREG2AR ? "wxxx" : in.op == OP_TEXREG2GB ? "yzzz" : "xyzz";
            snprintf(b, sizeof b, "(%s).%s", a, sw);
            sample(g, reg_num(dst), b, NULL, e, sizeof e);
            break;
        }
        case OP_TEXM3x2PAD: case OP_TEXM3x3PAD: {
            if (src(g, &s, a, sizeof a)) return -1;
            line(&g->o, "_m.%c = dot(in.t%u.xyz, (%s).xyz);", comp[m3x2_row], reg_num(dst), a);
            m3x2_row++;
            continue;
        }
        case OP_TEXM3x2TEX: case OP_TEXM3x2DEPTH: case OP_TEXM3x3TEX: case OP_TEXM3x3: case OP_TEXM3x3SPEC:
        case OP_TEXM3x3VSPEC: case OP_TEXDP3TEX: case OP_TEXDP3: {
            uint32_t n = reg_num(dst);
            if (src(g, &s, a, sizeof a)) return -1;
            if (in.op == OP_TEXDP3TEX || in.op == OP_TEXDP3) {
                snprintf(b, sizeof b, "float4(dot(in.t%u.xyz, (%s).xyz))", n, a);
                if (in.op == OP_TEXDP3) snprintf(e, sizeof e, "%s", b);
                else {
                    snprintf(c, sizeof c, "float4((%s).x, 0.0, 0.0, 1.0)", b);
                    sample(g, n, c, NULL, e, sizeof e);
                }
                break;
            }
            line(&g->o, "_m.%c = dot(in.t%u.xyz, (%s).xyz);", comp[m3x2_row], n, a);
            m3x2_row = 0;
            if (in.op == OP_TEXM3x2TEX) {
                sample(g, n, "float4(_m.xy, 0.0, 1.0)", NULL, e, sizeof e);
            } else if (in.op == OP_TEXM3x2DEPTH) {
                line(&g->o, "odepth = _m.y == 0.0 ? 1.0 : _m.x / _m.y;");
                continue;
            } else if (in.op == OP_TEXM3x3) {
                snprintf(e, sizeof e, "float4(_m.xyz, 1.0)");
            } else if (in.op == OP_TEXM3x3TEX) {
                sample(g, n, "float4(_m.xyz, 1.0)", NULL, e, sizeof e);
            } else {
                // Reflect the eye vector about the normal _m (spec: eye in a constant;
                // vspec: eye in the w components of the three texture coordinates).
                char eye[256];
                if (in.op == OP_TEXM3x3SPEC) {
                    if (src(g, &s, c, sizeof c)) return -1;
                    snprintf(eye, sizeof eye, "(%s).xyz", c);
                } else {
                    snprintf(eye, sizeof eye, "float3(in.t%u.w, in.t%u.w, in.t%u.w)", n - 2, n - 1, n);
                }
                line(&g->o, "float3 _e = %s;", eye);
                sample(g, n, "float4(2.0 * _m.xyz * dot(_m.xyz, _e) / dot(_m.xyz, _m.xyz) - _e, 1.0)", NULL, e,
                       sizeof e);
            }
            break;
        }
        case OP_TEXDEPTH:
            line(&g->o, "odepth = r5.y == 0.0 ? 1.0 : r5.x / r5.y;");
            continue;
        case OP_BEM: {
            uint32_t n = reg_num(dst);
            if (src(g, &s, a, sizeof a) || src(g, &s, b, sizeof b)) return -1;
            snprintf(e, sizeof e,
                     "float4((%s).x + p.bumpenv[%u].x * (%s).x + p.bumpenv[%u].z * (%s).y, "
                     "(%s).y + p.bumpenv[%u].y * (%s).x + p.bumpenv[%u].w * (%s).y, 0.0, 0.0)",
                     a, n, b, n, b, a, n, b, n, b);
            break;
        }
        default:
            return fail(&g->ps, "opcode %d not supported", in.op);
        }
        if (emit_dst(g, dst, e, in.coissue)) return -1;
    }
    if (g->npending) flush_pending(g);
    return r;
}

// A character's detail normal map: the surface's view-space position from the pixel's
// distance (bl_dl[0]: z, w the projection's scales; bl_dl[1]: 1 / target size,
// strength, light count), its tangent frame from how position and texture
// coordinates change across the pixel ("normal mapping without precomputed tangents"),
// laid on the model's smooth normal. The light (oc0 and _l together, so the skin pass's colour
// stays the texture's) is scaled by how far the bumps tilt towards the map's lights
// (bl_dl[4 + 4k] to [7 + 4k]: metal_render.m's struct fog_light), and the shine added
// (bl_dl[2].x its strength; the map's alpha is the roughness), and the light given a direction.
static void ps_detail(struct out *o, const char *coord, int hair)
{
    line(o, "{");
    o->indent++;
    line(o, "constexpr sampler bl_ds(filter::linear, mip_filter::linear, address::repeat);");
    // Distance from the rasteriser's 1/w: the depth, near 1 up close, has too few bits left
    // for its change across a pixel.
    line(o, "float _zw = 1.0 / in.pos.w;");
    line(o, "float2 _ndc = float2(in.pos.x * bl_dl[1].x * 2.0 - 1.0, 1.0 - in.pos.y * bl_dl[1].y * 2.0);");
    line(o, "float3 _P = float3(_ndc.x * _zw / bl_dl[0].z, _ndc.y * _zw / bl_dl[0].w, _zw);");
    line(o, "float2 _uv = (%s).xy;", coord);
    line(o, "float3 _px = dfdx(_P), _py = dfdy(_P); float2 _ux = dfdx(_uv), _uy = dfdy(_uv);");
    line(o, "float3 _N = normalize(cross(_px, _py));");
    line(o, "if (dot(_N, _P) > 0.0) _N = -_N;");
    line(o, "float3 _r1 = cross(_py, _N), _r2 = cross(_N, _px);");
    line(o, "float3 _T = _r1 * _ux.x + _r2 * _uy.x, _B = _r1 * _ux.y + _r2 * _uy.y;");
    // The model's smooth normal from the vertex shader (in.bln, a clip-space step), or
    // the triangle's.
    line(o, "float3 _Ns = float3(in.bln.x / bl_dl[0].z, in.bln.y / bl_dl[0].w, in.bln.w);");
    line(o, "_Ns = dot(_Ns, _Ns) > 1e-12 ? normalize(_Ns) : _N;");
    // Hair is drawn on both sides: lit from the side that faces the camera, as the
    // triangle's normal is, or its back shows dark streaks.
    if (hair) line(o, "if (dot(_Ns, _P) > 0.0) _Ns = -_Ns;");
    line(o, "_T = normalize(_T - _Ns * dot(_T, _Ns) + 1e-12); _B = normalize(_B - _Ns * dot(_B, _Ns) + 1e-12);");
    line(o, "float3 _nm = bl_dn.sample(bl_ds, _uv).xyz * 2.0 - 1.0;");
    line(o, "float3 _n = normalize(_T * _nm.x - _B * _nm.y + _Ns * max(_nm.z, 0.05));");
    // Half-Lambert light on the bumps over the same on the smooth surface: 1 where the
    // map is flat, so the game's own lighting is kept and only the bumps are added.
    // The shine, from the same lights (each its share of the game's light here, so it
    // follows the game's lighting): GGX specular with the roughness map's roughness
    // (skin's 2.8% head on, Schlick's Fresnel), and on rough cloth a soft sheen at the
    // edges ("Charlie" sheen), tinted by the cloth's colour.
    line(o, "float4 _ms = bl_dn.sample(bl_ds, _uv);");
    line(o, "float _rg = clamp(_ms.w, 0.22, 1.0), _a2 = _rg * _rg * _rg * _rg;");
    line(o, "float _cloth = smoothstep(0.6, 0.85, _rg);");
    line(o, "float3 _V = -normalize(_P); float _nv = saturate(dot(_n, _V)) + 1e-4;");
    line(o, "float _f = 0.0, _E = 0.0, _S = 0.0, _Sh = 0.0, _Et = 0.0, _Dl = 0.0, _Tr = 0.0, _hs = 0.0;");
    if (hair) {
        // Strands (bl_dl[3].x their strength): a pattern across the strands, about 420 to
        // the texture's width, each strand its own brightness and its normal turned a
        // little across, so the shine breaks up into strands. It fades out where strands
        // get thinner than a pixel.
        line(o, "float _ac = bl_dl[2].z > 0.5 ? _uv.y : _uv.x;");
        line(o, "float _sf = 420.0 * _ac, _sa = saturate(1.5 - fwidth(_sf)) * bl_dl[3].x;");
        line(o, "float _si = floor(_sf), _sx = fract(_sf);");
        line(o, "float _hr0 = fract(sin(_si * 12.9898) * 43758.5453), _hr1 = fract(sin((_si + 1.0) * 12.9898) * 43758.5453);");
        line(o, "_hs = (mix(_hr0, _hr1, smoothstep(0.0, 1.0, _sx)) - 0.5) * _sa;");
        line(o, "_n = normalize(_n + (bl_dl[2].z > 0.5 ? _B : _T) * (_hr1 - _hr0) * 6.0 * _sx * (1.0 - _sx) * 0.3 * _sa);");
    }
    line(o, "for (int _k = 0; _k < int(bl_dl[1].w); _k++) {");
    line(o, "    float4 _lp = bl_dl[4 + 4 * _k], _lc = bl_dl[5 + 4 * _k], _ld = bl_dl[6 + 4 * _k], _at = bl_dl[7 + 4 * _k];");
    line(o, "    float3 _v = _lp.xyz - _P;");
    line(o, "    float _d2 = max(dot(_v, _v), 64.0), _dd = sqrt(_d2);");
    line(o, "    float3 _L = _v / _dd;");
    line(o, "    float _e = dot(_lc.xyz, float3(0.2126, 0.7152, 0.0722)) / (_at.x + _at.y * _dd + _at.z * _d2);");
    line(o, "    if (_lp.w > 0.0) { float _x = _dd / _lp.w; _e *= saturate(1.0 - _x * _x * _x * _x); }");
    line(o, "    if (dot(_ld.xyz, _ld.xyz) > 0.25) {");
    line(o, "        float _cs = dot(-_L, _ld.xyz);");
    line(o, "        _e *= _cs <= _ld.w ? 0.0 : saturate((_cs - _ld.w) / max(_lc.w - _ld.w, 1e-4));");
    line(o, "    }");
    line(o, "    _E += _e * (dot(_Ns, _L) * 0.5 + 0.5), _f += _e * (dot(_n, _L) * 0.5 + 0.5);");
    line(o, "    _Et += _e, _Dl += _e * saturate((dot(_n, _L) + 0.2) / 1.2);");
    line(o, "    float _nl = saturate(dot(_n, _L));");
    if (hair) {
        // Hair (Kajiya-Kay, two lobes as in Scheuermann's hair shading): light off the
        // strands, which run along the texture (bl_dl[2].z: 0 along v, 1 along u), in a
        // band across them; a white one shifted towards the tips, a wider one tinted
        // by the hair's colour towards the roots. Lit also from a little behind.
        line(o, "    if (_e <= 0.0) continue;");
        line(o, "    float3 _H = normalize(_L + _V);");
        line(o, "    float3 _st = bl_dl[2].z > 0.5 ? _T : _B;");
        line(o, "    float3 _t1 = normalize(_st - (0.08 + 0.12 * _hs) * _n), _t2 = normalize(_st + (0.12 + 0.12 * _hs) * _n);");
        line(o, "    float _h1 = dot(_t1, _H), _h2 = dot(_t2, _H);");
        line(o, "    float _w = smoothstep(-0.3, 0.3, dot(_Ns, _L));");
        line(o, "    _S += _e * _w * pow(sqrt(saturate(1.0 - _h1 * _h1)), 90.0);");
        line(o, "    _Sh += _e * _w * pow(sqrt(saturate(1.0 - _h2 * _h2)), 22.0);");
        // Light from behind, through the strands towards the camera.
        line(o, "    _Tr += _e * pow(saturate(dot(_L, -_V)), 4.0);");
        line(o, "}");
        line(o, "oc0.xyz *= 1.0 + 0.4 * _hs;");
    } else {
    line(o, "    if (_nl <= 0.0 || _e <= 0.0) continue;");
    line(o, "    float3 _H = normalize(_L + _V);");
    line(o, "    float _nh = saturate(dot(_n, _H)), _vh = saturate(dot(_V, _H));");
    line(o, "    float _dn = _nh * _nh * (_a2 - 1.0) + 1.0, _D = _a2 / (3.14159 * _dn * _dn);");
    line(o, "    float _vis = 0.5 / (_nl * sqrt(_nv * _nv * (1.0 - _a2) + _a2) + _nv * sqrt(_nl * _nl * (1.0 - _a2) + _a2));");
    line(o, "    float _F = 0.028 + 0.972 * pow(1.0 - _vh, 5.0);");
    line(o, "    _S += _e * _D * _vis * _F * _nl;");
    line(o, "    float _sr = 1.0 / max(_rg * _rg, 0.05), _sn = sqrt(saturate(1.0 - _nh * _nh));");
    line(o, "    _Sh += _e * (2.0 + _sr) * pow(_sn, _sr) / 6.28318 / (4.0 * (_nl + _nv - _nl * _nv)) * _nl;");
    line(o, "}");
    }
    line(o, "float _q = _E > 1e-6 ? clamp(1.0 + 2.0 * bl_dl[1].z * (_f / _E - 1.0), 0.6, 1.5) : 1.0;");
    // Light with a direction (bl_dl[2].y its strength): the game lights characters per
    // vertex, mostly from an even ambient, so faces look flat. Its light here is shared
    // out again per pixel: a third stays even, the rest by how the surface (smooth
    // normal and bumps) faces each light, with a little wrap for skin's soft edge:
    // brighter towards the lights and darker away from them, but only a little darker
    // (bl_dl[3].y the least, 0.8 by default), or a character seen from the side away from
    // the lights (walking up to the barman, the bar's lights behind him) goes dark.
    line(o, "if (_Et > 1e-6 && bl_dl[2].y > 0.0) {");
    line(o, "    float _amb = 0.35 * _Et;");
    line(o, "    _q = mix(_q, clamp((_amb + _Dl) / (_amb + 0.5 * _Et), bl_dl[3].y, 1.8), saturate(bl_dl[2].y));");
    line(o, "}");
    line(o, "if (_E > 1e-6 && bl_dl[2].x > 0.0) {");
    line(o, "    float3 _alb = clamp(oc0.xyz / max(_l, float3(1e-3)), 0.0, 1.0);");
    if (hair) {
        line(o, "    float3 _sh = _l * (bl_dl[2].x / _E) * (0.15 * _S + 0.18 * _Sh * _alb) * smoothstep(0.1, 0.5, oc0.w);");
        // The glow of light through hair from behind (bl_dl[3].w), in the hair's colour.
        line(o, "    _sh += _l * _alb * (0.6 * bl_dl[3].w * _Tr / max(_Et, 1e-6));");
    } else
        line(o, "    float3 _sh = _l * (3.14159 * bl_dl[2].x / _E) * (_S * (1.0 - 0.7 * _cloth) + 0.35 * _cloth * _Sh * _alb);");
    line(o, "    oc0.xyz += min(_sh, float3(1.0));");
    line(o, "}");
    line(o, "oc0.xyz *= _q; _l *= _q;");
    if (hair >= 2) {
        // Hair's soft edge (bl_dl[2].w world units): fades where it comes near what was
        // drawn before it (the head, the body, clothes; bl_hd, the depth then), so where
        // it passes into them shows no hard line. Depth is alpha + beta / w.
        line(o, "float _db = bl_hd.read(uint2(in.pos.xy));");
        line(o, "float _wb = bl_dl[0].y / min(_db - bl_dl[0].x, -1e-7);");
        // Darker where it lies on the head or body (bl_dl[3].z): the roots, the hair's
        // underside, in shadow from the hair over them.
        line(o, "oc0.xyz *= mix(1.0 - 0.45 * bl_dl[3].z, 1.0, saturate((_wb - _zw) / 3.0));");
        line(o, "oc0.w *= saturate((_wb - _zw) / bl_dl[2].w);");
    }
    o->indent--;
    line(o, "}");
}

// Alpha test and fog on oc0, as the fixed-function back end does after any pixel shader.
// _fog: the share of the colour the fog leaves.
static void ps_alpha_and_fog(struct out *o)
{
    line(o, "if (!bl_cmp(p.alpha_func, oc0.w, p.alpha_ref)) discard_fragment();");
    line(o, "float _fog = 1.0;");
    line(o, "if (p.fog_mode != 0) {");
    line(o, "    float z = in.fogz, f = in.fog;");
    line(o, "    if (p.fog_mode == 2) f = (p.fog_end - z) / (p.fog_end - p.fog_start);");
    line(o, "    else if (p.fog_mode == 3) f = exp(-p.fog_density * z);");
    line(o, "    else if (p.fog_mode == 4) f = exp(-(p.fog_density * z) * (p.fog_density * z));");
    line(o, "    _fog = saturate(f);");
    line(o, "    oc0.xyz = mix(p.fog_color.xyz, oc0.xyz, _fog);");
    line(o, "}");
}

// A pixel shader's registers, before its body.
static void ps_locals(struct gen *g)
{
    struct out *o = &g->o;
    line(o, "float4 v0 = in.d0, v1 = in.d1;");
    line(o, "float4 r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 0, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 0, "
            "r11 = 0, r12 = 0, r13 = 0, r14 = 0, r15 = 0;");
    if (g->ps.major == 1 && g->ps.minor < 4)
        line(o, "float4 t0 = in.t0, t1 = in.t1, t2 = in.t2, t3 = in.t3;");
    else
        line(o, "float4 t0 = in.t0, t1 = in.t1, t2 = in.t2, t3 = in.t3, t4 = in.t4, t5 = in.t5, t6 = in.t6, "
                "t7 = in.t7;");
    line(o, "float4 oc0 = 0, oc1 = 0, oc2 = 0, oc3 = 0; float odepth = in.pos.z; float3 _m = 0;");
    if (g->v && g->v->shadow_receiver) line(o, "float4 _sh = 0; bool _shd = false;");
}

// The tessellated vertex shader's main function (v->tess): the shader run on the three
// corners, then Phong tessellation in view space (Boubekeur and Alexa 2008): the point is
// projected onto each corner's tangent plane, the three weighted like the point itself,
// and moved three quarters of the way there. Everything else is interpolated.
static const char *const tess_main =
    "#define BL_I(f) (bc.x * r[0].f + bc.y * r[1].f + bc.z * r[2].f)\n"
    "[[patch(triangle, 3)]] vertex BLVSOut bl_main(patch_control_point<BLVSIn> cp [[stage_in]],\n"
    "        float3 bc [[position_in_patch]], constant float4 *c [[buffer(20)]],\n"
    "        constant BLVSParams &p [[buffer(21)]], constant float4 &tp [[buffer(22)]]) {\n"
    "    BLVSRaw r[3] = {bl_vs(cp[0], c, p), bl_vs(cp[1], c, p), bl_vs(cp[2], c, p)};\n"
    "    float3 _P[3], _N[3];\n"
    "    for (int i = 0; i < 3; i++) {\n"
    "        _P[i] = float3(r[i].pos.x / tp.z, r[i].pos.y / tp.w, r[i].pos.w);\n"
    "        float4 d = r[i].p2 - r[i].pos;\n"
    "        float3 n = float3(d.x / tp.z, d.y / tp.w, d.w);\n"
    "        float l = dot(n, n);\n"
    "        _N[i] = l > 1e-12 ? n * rsqrt(l) : float3(0.0);\n"
    "    }\n"
    "    float3 _X = bc.x * _P[0] + bc.y * _P[1] + bc.z * _P[2], _Q = 0.0;\n"
    "    for (int i = 0; i < 3; i++) _Q += bc[i] * (_X - dot(_X - _P[i], _N[i]) * _N[i]);\n"
    "    float3 _D = 0.75 * (_Q - _X);\n"
    "    float4 opos = BL_I(pos) + float4(_D.x * tp.z, _D.y * tp.w, _D.z * tp.x, _D.z);\n"
    "    BLVSOut out;\n"
    "    out.bln = BL_I(p2) - BL_I(pos); out.bln.y *= p.clip_y;\n"
    "    out.pos = opos;\n"
    "    out.pos.y *= p.clip_y;\n"
    "    out.pos.xy += float2(p.inv_viewport.x, -p.inv_viewport.y) * opos.w;\n"
    "    out.psize = BL_I(pts.x);\n"
    "    out.d0 = BL_I(d0); out.d1 = BL_I(d1);\n"
    "    out.t0 = BL_I(t0); out.t1 = BL_I(t1); out.t2 = BL_I(t2); out.t3 = BL_I(t3);\n"
    "    out.t4 = BL_I(t4); out.t5 = BL_I(t5); out.t6 = BL_I(t6); out.t7 = BL_I(t7);\n"
    "    out.fog = BL_I(fog.x); out.fogz = opos.w;\n"
    "    return out;\n"
    "}\n";

char *d3d_shader_msl(const uint32_t *code, const struct d3d_shader_variant *v, char *err, int errlen)
{
    struct gen g;
    memset(&g, 0, sizeof g);
    g.v = v;
    if (d3d_shader_parse(code, &g.info, err, errlen)) return NULL;
    if (start(&g.ps, code, err, errlen)) return NULL;
    struct out *o = &g.o;
    if (g.ps.pixel && !g.info.color_outputs) g.info.color_outputs = 1;
    put(o, "%s", header);
    if (g.ps.pixel && v && v->shadow_receiver) put(o, "%s", shadow_msl);
    if (g.ps.pixel && v && v->lightmap) put(o, "%s", lightmap_msl);
    if (!g.ps.pixel) {
        if (g.info.input_mask) put(o, "struct BLVSIn {\n");
        for (int i = 0; i < D3D_SHADER_MAX_INPUTS; i++) {
            if (!(g.info.input_mask & (1u << i))) continue;
            int k = v ? v->input_kind[i] : D3D_IN_FLOAT;
            put(o, "    %s v%d [[attribute(%d)]];\n", k == D3D_IN_UINT ? "uint4" : k == D3D_IN_SINT ? "int4" : "float4",
                i, i);
        }
        if (g.info.input_mask) put(o, "};\n");
        // Tessellated (v->tess): the shader is a function run on each corner of a triangle.
        int tess = v && v->tess && v->smooth_normal && g.info.input_mask;
        if (tess)
            put(o, "struct BLVSRaw { float4 pos, p2, d0, d1, t0, t1, t2, t3, t4, t5, t6, t7, fog, pts; };\n"
                   "static inline BLVSRaw bl_vs(BLVSIn in, constant float4 *c, constant BLVSParams &p) {\n");
        else
            put(o, "vertex BLVSOut bl_main(%sconstant float4 *c [[buffer(20)]],\n"
                   "                       constant BLVSParams &p [[buffer(21)]]) {\n",
                g.info.input_mask ? "BLVSIn in [[stage_in]], " : "");
        o->indent = 1;
        for (int i = 0; i < D3D_SHADER_MAX_INPUTS; i++)
            if (g.info.input_mask & (1u << i)) line(o, "float4 v%d = float4(in.v%d);", i, i);
        line(o, "float4 r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 0, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 0, "
                "r11 = 0, r12 = 0, r13 = 0, r14 = 0, r15 = 0;");
        line(o, "int4 a0 = 0; int aL = 0;");
        // Colors the shader does not write read as white (diffuse) and black (specular), as on D3D9.
        line(o, "float4 opos = 0, ofog = float4(1.0), opts = float4(1.0), od0 = float4(1.0), od1 = 0;");
        line(o, "float4 ot0 = 0, ot1 = 0, ot2 = 0, ot3 = 0, ot4 = 0, ot5 = 0, ot6 = 0, ot7 = 0;");
        if (gen_body(&g)) goto failed;
        // A smooth normal (v->smooth_normal): the body again on the position nudged along
        // the model's normal, through the same bones; the step between the two clip
        // positions is the normal (ps_detail).
        int vp = -1, vn = -1;
        for (int i = 0; v && v->smooth_normal && i < D3D_SHADER_MAX_INPUTS; i++)
            if ((g.info.input_mask & (1u << i)) && !g.info.input_index[i] && v->input_kind[i] == D3D_IN_FLOAT) {
                if (g.info.input_usage[i] == 0) vp = i;
                if (g.info.input_usage[i] == 3) vn = i;
            }
        line(o, "float4 _p1 = opos, _p2 = opos;");
        if (vp >= 0 && vn >= 0) {
            line(o, "float4 _vp = v%d + float4(normalize(v%d.xyz + 1e-9) * 0.5, 0.0);", vp, vn);
            line(o, "{");
            line(o, "float4 v%d = _vp;", vp);
            line(o, "float4 r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 0, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 0, "
                    "r11 = 0, r12 = 0, r13 = 0, r14 = 0, r15 = 0;");
            line(o, "int4 a0 = 0; int aL = 0;");
            line(o, "float4 opos = 0, ofog = float4(1.0), opts = float4(1.0), od0 = float4(1.0), od1 = 0;");
            line(o, "float4 ot0 = 0, ot1 = 0, ot2 = 0, ot3 = 0, ot4 = 0, ot5 = 0, ot6 = 0, ot7 = 0;");
            if (start(&g.ps, code, err, errlen) || gen_body(&g)) goto failed;
            line(o, "_p2 = opos;");
            line(o, "}");
        }
        if (tess) {
            line(o, "BLVSRaw r = {_p1, _p2, saturate(od0), saturate(od1), ot0, ot1, ot2, ot3, ot4, ot5, ot6, ot7, ofog, opts};");
            line(o, "return r;");
            put(o, "}\n");
            put(o, "%s", tess_main);
            return o->s;
        }
        line(o, "BLVSOut out;");
        line(o, "out.bln = _p2 - _p1; out.bln.y *= p.clip_y;");
        // D3D9 samples pixel centers at integer window coordinates, Metal at +0.5.
        line(o, "out.pos = opos;");
        line(o, "out.pos.y *= p.clip_y;");
        line(o, "out.pos.xy += float2(p.inv_viewport.x, -p.inv_viewport.y) * opos.w;");
        line(o, "out.psize = opts.x;");
        line(o, "out.d0 = saturate(od0); out.d1 = saturate(od1);");
        line(o, "out.t0 = ot0; out.t1 = ot1; out.t2 = ot2; out.t3 = ot3;");
        line(o, "out.t4 = ot4; out.t5 = ot5; out.t6 = ot6; out.t7 = ot7;");
        line(o, "out.fog = ofog.x; out.fogz = opos.w;");
        line(o, "return out;");
        put(o, "}\n");
    } else {
        int info = v && v->reflection_info && !(g.info.color_outputs & 2);
        if (info) {
            uint32_t maps = d3d_shader_env_maps(code);
            for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++)
                if ((maps & (1u << i)) && tex_kind(&g, i) == D3D_TEX_CUBE) g.env |= 1u << i;
        }
        put(o, "struct BLPSOut {\n");
        for (int i = 0; i < 4; i++)
            if (g.info.color_outputs & (1u << i)) put(o, "    float4 c%d [[color(%d)]];\n", i, i);
        if (info) put(o, "    float4 c1 [[color(1)]];\n");
        if (g.info.writes_depth) put(o, "    float depth [[depth(any)]];\n");
        put(o, "};\n");
        put(o, "fragment BLPSOut bl_main(BLPSIn in [[stage_in]], constant float4 *c [[buffer(0)]],\n"
               "                         constant BLPSParams &p [[buffer(1)]]");
        for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++)
            if (g.info.sampler_mask & (1u << i))
                put(o, ",\n                         %s tex%u [[texture(%u)]], sampler smp%u [[sampler(%u)]]",
                    tex_type(tex_kind(&g, i)), i, i, i, i);
        int detail = info && v->skin == 1 && v->detail && (g.info.sampler_mask & 1);
        if (detail)
            put(o, ",\n                         texture2d<float> bl_dn [[texture(15)]], constant float4 *bl_dl [[buffer(3)]]");
        if (detail && v->hair >= 2)
            put(o, ",\n                         depth2d<float> bl_hd [[texture(14)]]");
        if (v && v->shadow_receiver) put(o, ",\n                         constant BLShadowParams &sp [[buffer(2)]]");
        if (v && v->lightmap) put(o, ",\n                         texture2d<ushort> bl_lr [[texture(13)]]");
        put(o, ") {\n");
        o->indent = 1;
        if (g.env) {
            // The body again with the reflection cubemaps read as black, then as white:
            // the colour without them (_e0) and with white ones (_e1).
            line(o, "float3 _e0, _e1;");
            for (int k = 1; k <= 2; k++) {
                line(o, "{");
                o->indent++;
                ps_locals(&g);
                start(&g.ps, code, err, errlen);
                g.env_value = k;
                if (gen_body(&g)) goto failed;
                if (g.ps.major == 1) line(o, "oc0 = r0;");
                line(o, "_e%d = oc0.xyz;", k - 1);
                o->indent--;
                line(o, "}");
            }
            start(&g.ps, code, err, errlen);
            g.env_value = 0;
        }
        int skin = info && v->skin == 1 && (g.info.sampler_mask & 1);
        if (skin) {
            // The body again with the colour texture white: the light alone (_l), for the
            // light under the skin (metal_render.m skin_run).
            line(o, "float3 _l;");
            line(o, "{");
            o->indent++;
            ps_locals(&g);
            g.white_base = 1;
            if (gen_body(&g)) goto failed;
            g.white_base = 0;
            if (g.ps.major == 1) line(o, "oc0 = r0;");
            line(o, "_l = oc0.xyz;");
            o->indent--;
            line(o, "}");
            start(&g.ps, code, err, errlen);
        }
        ps_locals(&g);
        g.base_coord[0] = 0;
        if (gen_body(&g)) goto failed;
        if (g.ps.major == 1) line(o, "oc0 = r0;");
        if (g.env) line(o, "float3 _d = oc0.xyz - _e0, _w = _e1 - _e0;");
        if (detail && skin && g.base_coord[0]) ps_detail(o, g.base_coord, v->hair);
        ps_alpha_and_fog(o);
        if (v && v->shadow_caster) line(o, v->shadow_caster == 2 ? "oc0.w = in.pos.z;" : "oc0.w = 1.0 - in.pos.z;");
        line(o, "BLPSOut out;");
        for (int i = 0; i < 4; i++)
            if (g.info.color_outputs & (1u << i)) line(o, "out.c%d = oc%d;", i, i);
        // -1.25: shone here (ps_detail), so the skin pass does not add its own shine; -1.4:
        // hair, shone here too.
        if (skin)
            line(o, "out.c1 = float4(max(_l, 0.0), %s);",
                 detail && g.base_coord[0] ? (v->hair ? "-1.4" : "-1.25") : "-1.0");
        else if (info && v->skin) line(o, v->skin == 3 ? "out.c1 = float4(0.0, 0.0, 0.0, -3.0);" : "out.c1 = float4(0.0, 0.0, 0.0, -2.0);");
        else if (info && g.env) line(o, "out.c1 = float4(_d * _fog, (_w.x + _w.y + _w.z) * _fog / 3.0);");
        else if (info) line(o, "out.c1 = 0;");
        if (g.info.writes_depth) line(o, "out.depth = odepth;");
        line(o, "return out;");
        put(o, "}\n");
    }
    return o->s;
failed:
    free(o->s);
    return NULL;
}

// --- fixed-function pixel stages ------------------------------------------------------
//
// The D3D9 texture stage cascade (COLOROP/ALPHAOP with their arguments, per stage until
// the first disabled one) as a pixel shader, for draws without a pixel shader. Colors
// come from the vertex stage outputs d0 (diffuse) and d1 (specular), texture coordinates
// from t<TEXCOORDINDEX>; TEXTUREFACTOR arrives in c[0].

static void ff_arg(uint8_t arg, int alpha, char *buf, size_t len)
{
    static const char *const src[] = {"in.d0", "cur", "tex", "c[0]", "in.d1", "tmp", "c[0]"};
    const char *b = src[(arg & 7) < 7 ? arg & 7 : 1];
    char v[64];
    if (arg & 0x20 || alpha) snprintf(v, sizeof v, "%s.wwww", b);  // ALPHAREPLICATE (alpha reads .w anyway)
    else snprintf(v, sizeof v, "%s", b);
    if (arg & 0x10) snprintf(buf, len, "(1.0 - %s)", v);  // COMPLEMENT
    else snprintf(buf, len, "%s", v);
}

// One stage operation on float4 arguments a1, a2, a0; alpha selects the alpha form.
static int ff_op(uint8_t op, const char *a1, const char *a2, const char *a0, char *buf, size_t len)
{
    switch (op) {
    case 2: snprintf(buf, len, "%s", a1); break;                                    // SELECTARG1
    case 3: snprintf(buf, len, "%s", a2); break;                                    // SELECTARG2
    case 4: snprintf(buf, len, "%s * %s", a1, a2); break;                           // MODULATE
    case 5: snprintf(buf, len, "%s * %s * 2.0", a1, a2); break;                     // MODULATE2X
    case 6: snprintf(buf, len, "%s * %s * 4.0", a1, a2); break;                     // MODULATE4X
    case 7: snprintf(buf, len, "%s + %s", a1, a2); break;                           // ADD
    case 8: snprintf(buf, len, "%s + %s - 0.5", a1, a2); break;                     // ADDSIGNED
    case 9: snprintf(buf, len, "(%s + %s - 0.5) * 2.0", a1, a2); break;             // ADDSIGNED2X
    case 10: snprintf(buf, len, "%s - %s", a1, a2); break;                          // SUBTRACT
    case 11: snprintf(buf, len, "%s + %s - %s * %s", a1, a2, a1, a2); break;        // ADDSMOOTH
    case 12: snprintf(buf, len, "mix(%s, %s, in.d0.w)", a2, a1); break;             // BLENDDIFFUSEALPHA
    case 13: snprintf(buf, len, "mix(%s, %s, tex.w)", a2, a1); break;               // BLENDTEXTUREALPHA
    case 14: snprintf(buf, len, "mix(%s, %s, c[0].w)", a2, a1); break;              // BLENDFACTORALPHA
    case 15: snprintf(buf, len, "%s + %s * (1.0 - tex.w)", a1, a2); break;          // BLENDTEXTUREALPHAPM
    case 16: snprintf(buf, len, "mix(%s, %s, cur.w)", a2, a1); break;               // BLENDCURRENTALPHA
    case 18: snprintf(buf, len, "%s + %s.wwww * %s", a1, a1, a2); break;            // MODULATEALPHA_ADDCOLOR
    case 19: snprintf(buf, len, "%s * %s + %s.wwww", a1, a2, a1); break;            // MODULATECOLOR_ADDALPHA
    case 20: snprintf(buf, len, "%s + (1.0 - %s.wwww) * %s", a1, a1, a2); break;    // MODULATEINVALPHA_ADDCOLOR
    case 21: snprintf(buf, len, "(1.0 - %s) * %s + %s.wwww", a1, a2, a1); break;    // MODULATEINVCOLOR_ADDALPHA
    case 24:                                                                        // DOTPRODUCT3
        snprintf(buf, len, "float4(saturate(dot((%s).xyz - 0.5, (%s).xyz - 0.5) * 4.0))", a1, a2);
        break;
    case 25: snprintf(buf, len, "%s + %s * %s", a0, a1, a2); break;                 // MULTIPLYADD
    case 26: snprintf(buf, len, "mix(%s, %s, %s)", a2, a1, a0); break;              // LERP
    default: return -1;  // PREMODULATE and the bump map operations
    }
    return 0;
}

static int ff_uses_texture(const struct d3d_ff_ps *k, int i)
{
    for (int j = 0; j < 3; j++)
        if ((k->colorarg[i][j] & 7) == 2 || (k->alphaop[i] > 1 && (k->alphaarg[i][j] & 7) == 2)) return 1;
    uint8_t op = k->colorop[i];
    return op == 13 || op == 15 || (k->alphaop[i] == 13 || k->alphaop[i] == 15);
}

uint32_t d3d_ff_ps_samplers(const struct d3d_ff_ps *k)
{
    uint32_t mask = 0;
    for (int i = 0; i < 8 && k->colorop[i] > 1; i++)
        if (ff_uses_texture(k, i)) mask |= 1u << i;
    return mask;
}

char *d3d_ff_ps_msl(const struct d3d_ff_ps *k, const struct d3d_shader_variant *v, char *err, int errlen)
{
    struct out out = {0}, *o = &out;
    put(o, "%s", header);
    int info = v && v->reflection_info;
    put(o, "struct BLPSOut { float4 c0 [[color(0)]];%s };\n", info ? " float4 c1 [[color(1)]];" : "");
    put(o, "fragment BLPSOut bl_main(BLPSIn in [[stage_in]], constant float4 *c [[buffer(0)]],\n"
           "                         constant BLPSParams &p [[buffer(1)]]");
    uint32_t samplers = d3d_ff_ps_samplers(k);
    for (int i = 0; i < 8; i++) {
        if (!(samplers & (1u << i))) continue;
        int kind = v && v->tex_kind[i] ? v->tex_kind[i] : D3D_TEX_2D;
        put(o, ",\n                         %s tex%d [[texture(%d)]], sampler smp%d [[sampler(%d)]]", tex_type(kind),
            i, i, i, i);
    }
    put(o, ") {\n");
    o->indent = 1;
    line(o, "float4 cur = in.d0, tmp = 0, tex = 0;");
    for (int i = 0; i < 8 && k->colorop[i] > 1; i++) {
        if (samplers & (1u << i)) {
            int kind = v && v->tex_kind[i] ? v->tex_kind[i] : D3D_TEX_2D;
            int tc = k->texcoord[i] & 7, proj = v ? v->projected[i] : 0;
            char coord[64];
            if (proj == 3) snprintf(coord, sizeof coord, "(in.t%d / in.t%d.z)", tc, tc);
            else if (proj == 4) snprintf(coord, sizeof coord, "(in.t%d / in.t%d.w)", tc, tc);
            else snprintf(coord, sizeof coord, "in.t%d", tc);
            line(o, "tex = tex%d.sample(smp%d, %s.%s);", i, i, coord, kind == D3D_TEX_2D ? "xy" : "xyz");
        }
        char a[3][80], rgb[400], alpha[400];
        for (int j = 0; j < 3; j++) ff_arg(k->colorarg[i][j], 0, a[j], sizeof a[j]);
        if (ff_op(k->colorop[i], a[1], a[2], a[0], rgb, sizeof rgb)) {
            snprintf(err, (size_t)errlen, "stage %d color op %u not supported", i, k->colorop[i]);
            free(o->s);
            return NULL;
        }
        if (k->alphaop[i] > 1) {
            for (int j = 0; j < 3; j++) ff_arg(k->alphaarg[i][j], 1, a[j], sizeof a[j]);
            if (ff_op(k->alphaop[i], a[1], a[2], a[0], alpha, sizeof alpha)) {
                snprintf(err, (size_t)errlen, "stage %d alpha op %u not supported", i, k->alphaop[i]);
                free(o->s);
                return NULL;
            }
        } else {
            snprintf(alpha, sizeof alpha, "cur");
        }
        const char *dst = k->resultarg[i] == 5 ? "tmp" : "cur";  // RESULTARG: TEMP or CURRENT
        line(o, "%s = saturate(float4((%s).xyz, (%s).w));", dst, rgb, alpha);
    }
    if (k->specular) line(o, "cur.xyz = saturate(cur.xyz + in.d1.xyz);");
    if (getenv("BL_FF_HIGHLIGHT")) line(o, "cur.xyz = float3(1.0, 0.0, 1.0);");  // debugging: show these draws
    line(o, "float4 oc0 = cur;");
    ps_alpha_and_fog(o);
    if (v && v->shadow_caster) line(o, v->shadow_caster == 2 ? "oc0.w = in.pos.z;" : "oc0.w = 1.0 - in.pos.z;");
    line(o, "BLPSOut out;");
    line(o, "out.c0 = oc0;");
    if (info) line(o, v->skin == 3 ? "out.c1 = float4(0.0, 0.0, 0.0, -3.0);" : v->skin ? "out.c1 = float4(0.0, 0.0, 0.0, -2.0);" : "out.c1 = 0;");
    line(o, "return out;");
    put(o, "}\n");
    return o->s;
}

// --- fixed-function vertex stage --------------------------------------------------
//
// For draws without a vertex shader: attribute 0 is the position (untransformed, or
// POSITIONT screen coordinates with RHW), 1 and 2 the diffuse and specular colors, 3 + n
// texture coordinate set n. Untransformed positions use c[0..3], the columns of
// world * view * projection; POSITIONT uses c[0] = (viewport x, y, 1/width, 1/height).
// No lighting: the colors pass through (white and black when absent).

char *d3d_ff_vs_msl(const struct d3d_ff_vs *k, char *err, int errlen)
{
    (void)err, (void)errlen;
    struct out out = {0}, *o = &out;
    put(o, "%s", header);
    put(o, "struct BLVSIn {\n    float4 v0 [[attribute(0)]];\n");
    if (k->color[0]) put(o, "    float4 v1 [[attribute(1)]];\n");
    if (k->color[1]) put(o, "    float4 v2 [[attribute(2)]];\n");
    for (int n = 0; n < 8; n++)
        if (k->tex_mask & (1u << n)) put(o, "    float4 v%d [[attribute(%d)]];\n", 3 + n, 3 + n);
    put(o, "};\n");
    put(o, "vertex BLVSOut bl_main(BLVSIn in [[stage_in]], constant float4 *c [[buffer(20)]],\n"
           "                       constant BLVSParams &p [[buffer(21)]]) {\n");
    o->indent = 1;
    line(o, "BLVSOut out;");
    if (k->positiont) {
        // D3D9 pixel centers are at integer screen coordinates, Metal's at +0.5.
        line(o, "float w = in.v0.w != 0.0 ? 1.0 / in.v0.w : 1.0;");
        line(o, "float2 ndc = float2(2.0, -2.0) * (in.v0.xy + 0.5 - c[0].xy) * c[0].zw + float2(-1.0, 1.0);");
        line(o, "out.pos = float4(ndc * w, in.v0.z * w, w);");
    } else {
        line(o, "float4 P = float4(in.v0.xyz, 1.0);");
        line(o, "float4 opos = float4(dot(P, c[0]), dot(P, c[1]), dot(P, c[2]), dot(P, c[3]));");
        line(o, "out.pos = opos;");
        line(o, "out.pos.y *= p.clip_y;");
        line(o, "out.pos.xy += float2(p.inv_viewport.x, -p.inv_viewport.y) * opos.w;");
    }
    line(o, "out.psize = 1.0;");
    line(o, "out.d0 = %s; out.d1 = %s;", k->color[0] ? "in.v1" : "float4(1.0)", k->color[1] ? "in.v2" : "float4(0.0)");
    for (int n = 0; n < 8; n++) {
        if (k->tex_mask & (1u << n)) line(o, "out.t%d = in.v%d;", n, 3 + n);
        else line(o, "out.t%d = 0;", n);
    }
    line(o, "out.fog = 1.0; out.fogz = out.pos.w; out.bln = 0;");
    line(o, "return out;");
    put(o, "}\n");
    return o->s;
}
