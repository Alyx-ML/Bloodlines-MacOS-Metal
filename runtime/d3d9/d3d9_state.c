// D3D9's documented default device state.
#include <string.h>

#include "d3d9_state.h"

void d3d_state_defaults(struct d3d_state *s)
{
    uint32_t *rs = s->rs;
    memset(rs, 0, sizeof s->rs);
    rs[7] = s->pp[9] ? 1 : 0;  // ZENABLE: on with an automatic depth buffer
    rs[8] = 3;                 // FILLMODE: SOLID
    rs[9] = 2;                 // SHADEMODE: GOURAUD
    rs[14] = 1;                // ZWRITEENABLE
    rs[16] = 1;                // LASTPIXEL
    rs[19] = 2;                // SRCBLEND: ONE
    rs[20] = 1;                // DESTBLEND: ZERO
    rs[22] = 3;                // CULLMODE: CCW
    rs[23] = 4;                // ZFUNC: LESSEQUAL
    rs[25] = 8;                // ALPHAFUNC: ALWAYS
    rs[37] = f2u(1.0f);        // FOGEND
    rs[38] = f2u(1.0f);        // FOGDENSITY
    rs[53] = rs[54] = rs[55] = 1;  // STENCILFAIL/ZFAIL/PASS: KEEP
    rs[56] = 8;                // STENCILFUNC: ALWAYS
    rs[58] = rs[59] = 0xFFFFFFFF;  // STENCILMASK, STENCILWRITEMASK
    rs[60] = 0xFFFFFFFF;       // TEXTUREFACTOR
    rs[136] = 1;               // CLIPPING
    rs[137] = 1;               // LIGHTING
    rs[141] = 1;               // COLORVERTEX
    rs[142] = 1;               // LOCALVIEWER
    rs[145] = 1;               // DIFFUSEMATERIALSOURCE: COLOR1
    rs[146] = 2;               // SPECULARMATERIALSOURCE: COLOR2
    rs[154] = f2u(1.0f);       // POINTSIZE
    rs[155] = f2u(1.0f);       // POINTSIZE_MIN
    rs[158] = f2u(1.0f);       // POINTSCALE_A
    rs[161] = 1;               // MULTISAMPLEANTIALIAS
    rs[162] = 0xFFFFFFFF;      // MULTISAMPLEMASK
    rs[166] = f2u(64.0f);      // POINTSIZE_MAX
    rs[168] = 0xF;             // COLORWRITEENABLE
    rs[171] = 1;               // BLENDOP: ADD
    rs[172] = 3;               // POSITIONDEGREE: CUBIC
    rs[173] = 1;               // NORMALDEGREE: LINEAR
    rs[178] = rs[179] = f2u(1.0f);  // MIN/MAXTESSELLATIONLEVEL
    rs[182] = f2u(1.0f);       // ADAPTIVETESS_Z
    rs[186] = rs[187] = rs[188] = 1;  // CCW_STENCIL*: KEEP
    rs[189] = 8;               // CCW_STENCILFUNC: ALWAYS
    rs[190] = rs[191] = rs[192] = 0xF;  // COLORWRITEENABLE1-3
    rs[193] = 0xFFFFFFFF;      // BLENDFACTOR
    rs[207] = 2;               // SRCBLENDALPHA: ONE
    rs[208] = 1;               // DESTBLENDALPHA: ZERO
    rs[209] = 1;               // BLENDOPALPHA: ADD

    memset(s->tss, 0, sizeof s->tss);
    for (uint32_t i = 0; i < 8; i++) {
        uint32_t *t = s->tss[i];
        t[1] = i == 0 ? 4 : 1;  // COLOROP: MODULATE on stage 0, else DISABLE
        t[2] = 2;               // COLORARG1: TEXTURE
        t[3] = 1;               // COLORARG2: CURRENT
        t[4] = i == 0 ? 2 : 1;  // ALPHAOP: SELECTARG1 on stage 0, else DISABLE
        t[5] = 2;               // ALPHAARG1: TEXTURE
        t[6] = 1;               // ALPHAARG2: CURRENT
        t[11] = i;              // TEXCOORDINDEX
        t[26] = t[27] = t[28] = 1;  // COLORARG0, ALPHAARG0, RESULTARG: CURRENT
    }

    memset(s->ss, 0, sizeof s->ss);
    for (int i = 0; i < 20; i++) {
        uint32_t *t = s->ss[i];
        t[1] = t[2] = t[3] = 1;  // ADDRESSU/V/W: WRAP
        t[5] = t[6] = 1;         // MAGFILTER, MINFILTER: POINT
        t[10] = 1;               // MAXANISOTROPY
    }

    memset(s->transform, 0, sizeof s->transform);
    for (int i = 0; i < 28; i++)
        for (int k = 0; k < 4; k++) s->transform[i][5 * k] = f2u(1.0f);
    for (int i = 0; i < 16; i++) s->stream_freq[i] = 1;
    for (int c = 0; c < 3; c++)
        for (int i = 0; i < 256; i++) s->gamma[c][i] = (uint16_t)(i * 257);
}
