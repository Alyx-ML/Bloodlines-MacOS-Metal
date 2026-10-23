// IDirect3D9: one adapter reporting a DirectX 9 class GPU (shader model 2.0, like the
// Radeon 9800 the game was tuned on), its display modes, formats and caps.
#include <string.h>

#include "bl_win32.h"
#include "com_gen.h"
#include "d3d9_objects.h"

#define D3DFMT_X8R8G8B8 22u
#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

static struct obj *d3d;

uint32_t bl_d3d9_Direct3DCreate9_c(uint32_t sdk_version)
{
    (void)sdk_version;
    if (!d3d) d3d = obj_new(OBJ_D3D, bl_vtbl_IDirect3D9());
    else obj_addref(d3d);
    return d3d->guest;
}

uint32_t d3d_guest(void) { return d3d->guest; }

// Display modes: the Mac display's own sizes plus the common ones that fit
// (bl_display.c); the desktop mode is the display's current size in pixels.

uint32_t bl_IDirect3D9_RegisterSoftwareDevice_c(uint32_t self, uint32_t f) { (void)self, (void)f; return D3D_OK; }
uint32_t bl_IDirect3D9_GetAdapterCount_c(uint32_t self) { (void)self; return 1; }

uint32_t bl_IDirect3D9_GetAdapterIdentifier_c(uint32_t self, uint32_t adapter, uint32_t flags, uint32_t id)
{
    (void)self, (void)flags;
    if (adapter) return D3DERR_INVALIDCALL;
    char *p = bl_g2h(id);
    memset(p, 0, 1100);
    strcpy(p, "ati2dvag.dll");                      // Driver[512]
    strcpy(p + 512, "RADEON 9800 PRO");             // Description[512]
    strcpy(p + 1024, "\\\\.\\DISPLAY1");            // DeviceName[32]
    G32(id + 1056) = 0x000a193a;                    // DriverVersion 6.14.10.6458: low part
    G32(id + 1060) = 0x0006000e;                    // high part
    G32(id + 1064) = 0x1002;                        // VendorId: ATI
    G32(id + 1068) = 0x4e48;                        // DeviceId: Radeon 9800 Pro
    G32(id + 1072) = 0;                             // SubSysId
    G32(id + 1076) = 0;                             // Revision
    G32(id + 1096) = 1;                             // WHQLLevel
    return D3D_OK;
}

uint32_t bl_IDirect3D9_GetAdapterModeCount_c(uint32_t self, uint32_t adapter, uint32_t format)
{
    (void)self;
    return adapter == 0 && format == D3DFMT_X8R8G8B8 ? (uint32_t)bl_display_mode_count() : 0;
}

static void put_mode(uint32_t m, uint32_t w, uint32_t h)
{
    G32(m) = w;
    G32(m + 4) = h;
    G32(m + 8) = 60;
    G32(m + 12) = D3DFMT_X8R8G8B8;
}

uint32_t bl_IDirect3D9_EnumAdapterModes_c(uint32_t self, uint32_t adapter, uint32_t format, uint32_t i, uint32_t mode)
{
    (void)self;
    uint32_t w, h;
    if (adapter || format != D3DFMT_X8R8G8B8 || !bl_display_mode((int)i, &w, &h)) return D3DERR_INVALIDCALL;
    put_mode(mode, w, h);
    return D3D_OK;
}

uint32_t bl_IDirect3D9_GetAdapterDisplayMode_c(uint32_t self, uint32_t adapter, uint32_t mode)
{
    (void)self;
    if (adapter) return D3DERR_INVALIDCALL;
    uint32_t w, h;
    bl_screen_size(&w, &h);
    put_mode(mode, w, h);
    return D3D_OK;
}

uint32_t bl_IDirect3D9_CheckDeviceType_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t adapter_fmt,
                                        uint32_t back_fmt, uint32_t windowed)
{
    (void)self, (void)type, (void)windowed;
    if (adapter || adapter_fmt != D3DFMT_X8R8G8B8) return D3DERR_NOTAVAILABLE;
    return back_fmt == D3DFMT_X8R8G8B8 || back_fmt == 21 || back_fmt == 0 ? D3D_OK : D3DERR_NOTAVAILABLE;
}

static int is_depth(uint32_t f) { return f == 70 || f == 71 || f == 73 || f == 75 || f == 77 || f == 79 || f == 80 || f == 82 || f == 83; }

uint32_t bl_IDirect3D9_CheckDeviceFormat_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t adapter_fmt,
                                          uint32_t usage, uint32_t rtype, uint32_t fmt)
{
    (void)self, (void)type, (void)adapter_fmt, (void)rtype;
    if (adapter) return D3DERR_INVALIDCALL;
    int color_rt = fmt == 21 || fmt == 22 || fmt == 23 || fmt == 113 || fmt == 114 || fmt == 116 || fmt == 36 || fmt == 34;
    switch (fmt) {
    case 21: case 22: case 23: case 24: case 25: case 26: case 28: case 50: case 51: case 60: case 63:
    case 34: case 36: case 113: case 114: case 116: case 111: case 112:
    case FOURCC('D', 'X', 'T', '1'): case FOURCC('D', 'X', 'T', '3'): case FOURCC('D', 'X', 'T', '5'):
        break;
    case 75: case 77: case 80:
        return (usage & 1) ? D3DERR_NOTAVAILABLE : D3D_OK;  // not as render targets
    default:
        return D3DERR_NOTAVAILABLE;
    }
    if ((usage & 2) && !is_depth(fmt)) return D3DERR_NOTAVAILABLE;  // DEPTHSTENCIL
    if ((usage & 1) && !color_rt) return D3DERR_NOTAVAILABLE;       // RENDERTARGET
    return D3D_OK;
}

uint32_t bl_IDirect3D9_CheckDeviceMultiSampleType_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t fmt,
                                                   uint32_t windowed, uint32_t ms, uint32_t quality)
{
    (void)self, (void)adapter, (void)type, (void)fmt, (void)windowed;
    if (quality) G32(quality) = 1;
    return ms == 0 ? D3D_OK : D3DERR_NOTAVAILABLE;
}

uint32_t bl_IDirect3D9_CheckDepthStencilMatch_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t adapter_fmt,
                                               uint32_t rt_fmt, uint32_t ds_fmt)
{
    (void)self, (void)adapter, (void)type, (void)adapter_fmt, (void)rt_fmt;
    return is_depth(ds_fmt) ? D3D_OK : D3DERR_NOTAVAILABLE;
}

uint32_t bl_IDirect3D9_CheckDeviceFormatConversion_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t src, uint32_t dst)
{
    (void)self, (void)adapter, (void)type, (void)src, (void)dst;
    return D3D_OK;
}

// D3DCAPS9 (304 bytes). Limitation bits (POW2, SQUAREONLY, ...) are left clear.
void d3d_fill_caps(uint32_t c)
{
    memset(bl_g2h(c), 0, 304);
    G32(c + 0) = 1;                       // DeviceType: HAL
    G32(c + 8) = 0x00020000;              // Caps: READ_SCANLINE
    G32(c + 12) = 0x60020000;             // Caps2: FULLSCREENGAMMA, DYNAMICTEXTURES, CANAUTOGENMIPMAP
    G32(c + 16) = 0x00000320;             // Caps3: ALPHA_FULLSCREEN_FLIP_OR_DISCARD, COPY_TO_VIDMEM/SYSTEMMEM
    G32(c + 20) = 0x80000001;             // PresentationIntervals: ONE, IMMEDIATE
    G32(c + 24) = 1;                      // CursorCaps: COLOR
    G32(c + 28) = 0x001BBE50;             // DevCaps: HW T&L, pure device, draw primitives 2/2EX, ...
    G32(c + 32) = 0x000ECCF2;             // PrimitiveMiscCaps: MASKZ, culls, color write, blend op, separate alpha
    G32(c + 36) = 0x07732191;             // RasterCaps: dither, ztest, fog, mip LOD bias, anisotropy, scissor, depth bias
    G32(c + 40) = 0xFF;                   // ZCmpCaps
    G32(c + 44) = 0x1FFF;                 // SrcBlendCaps
    G32(c + 48) = 0x1FFF;                 // DestBlendCaps
    G32(c + 52) = 0xFF;                   // AlphaCmpCaps
    G32(c + 56) = 0x00084208;             // ShadeCaps
    G32(c + 60) = 0x0001EC05;             // TextureCaps: perspective, alpha, projected, cube, volume, mipmaps
    G32(c + 64) = 0x07030700;             // TextureFilterCaps
    G32(c + 68) = 0x07030700;             // CubeTextureFilterCaps
    G32(c + 72) = 0x03030300;             // VolumeTextureFilterCaps
    G32(c + 76) = 0x3F;                   // TextureAddressCaps
    G32(c + 80) = 0x3F;                   // VolumeTextureAddressCaps
    G32(c + 84) = 0x1F;                   // LineCaps
    G32(c + 88) = 4096;                   // MaxTextureWidth
    G32(c + 92) = 4096;                   // MaxTextureHeight
    G32(c + 96) = 512;                    // MaxVolumeExtent
    G32(c + 100) = 8192;                  // MaxTextureRepeat
    G32(c + 104) = 4096;                  // MaxTextureAspectRatio
    G32(c + 108) = 16;                    // MaxAnisotropy
    G32(c + 112) = f2u(1e10f);            // MaxVertexW
    G32(c + 116) = f2u(-1e8f);            // GuardBandLeft
    G32(c + 120) = f2u(-1e8f);            // GuardBandTop
    G32(c + 124) = f2u(1e8f);             // GuardBandRight
    G32(c + 128) = f2u(1e8f);             // GuardBandBottom
    G32(c + 136) = 0x1FF;                 // StencilCaps incl. TWOSIDED
    G32(c + 140) = 0x00100008;            // FVFCaps: 8 texture coordinates, point size
    G32(c + 144) = 0x03FFFFFF;            // TextureOpCaps
    G32(c + 148) = 8;                     // MaxTextureBlendStages
    G32(c + 152) = 8;                     // MaxSimultaneousTextures
    G32(c + 156) = 0x3B;                  // VertexProcessingCaps
    G32(c + 160) = 8;                     // MaxActiveLights
    G32(c + 164) = 6;                     // MaxUserClipPlanes
    G32(c + 168) = 4;                     // MaxVertexBlendMatrices
    G32(c + 172) = 0;                     // MaxVertexBlendMatrixIndex
    G32(c + 176) = f2u(256.0f);           // MaxPointSize
    G32(c + 180) = 0x000FFFFF;            // MaxPrimitiveCount
    G32(c + 184) = 0x00FFFFFF;            // MaxVertexIndex
    G32(c + 188) = 16;                    // MaxStreams
    G32(c + 192) = 512;                   // MaxStreamStride
    G32(c + 196) = 0xFFFE0200;            // VertexShaderVersion 2.0
    G32(c + 200) = 256;                   // MaxVertexShaderConst
    G32(c + 204) = 0xFFFF0200;            // PixelShaderVersion 2.0
    G32(c + 208) = f2u(8.0f);             // PixelShader1xMaxValue
    G32(c + 212) = 0x51;                  // DevCaps2: STREAMOFFSET, VERTEXELEMENTSCANSHARESTREAMOFFSET, CAN_STRETCHRECT_FROM_TEXTURES
    G32(c + 232) = 1;                     // NumberOfAdaptersInGroup
    G32(c + 236) = 0x30F;                 // DeclTypes: UBYTE4N, SHORT2N/4N, USHORT2N/4N, FLOAT16_2/4
    G32(c + 240) = 4;                     // NumSimultaneousRTs
    G32(c + 244) = 0x03000300;            // StretchRectFilterCaps
    G32(c + 248) = 1;                     // VS20Caps.Caps: PREDICATION
    G32(c + 256) = 12;                    // VS20Caps.NumTemps
    G32(c + 260) = 1;                     // VS20Caps.StaticFlowControlDepth
    G32(c + 272) = 12;                    // PS20Caps.NumTemps
    G32(c + 280) = 96;                    // PS20Caps.NumInstructionSlots
    G32(c + 288) = 65535;                 // MaxVShaderInstructionsExecuted
    G32(c + 292) = 65535;                 // MaxPShaderInstructionsExecuted
}

uint32_t bl_IDirect3D9_GetDeviceCaps_c(uint32_t self, uint32_t adapter, uint32_t type, uint32_t caps)
{
    (void)self, (void)type;
    if (adapter) return D3DERR_INVALIDCALL;
    d3d_fill_caps(caps);
    return D3D_OK;
}

uint32_t bl_IDirect3D9_GetAdapterMonitor_c(uint32_t self, uint32_t adapter)
{
    (void)self;
    return adapter ? 0 : 0x00010001;  // HMONITOR of the one screen
}
