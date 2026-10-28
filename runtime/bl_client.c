// Native replacements for routines in the client (see native/modules/README.md).
// Each takes the guest CPU, like bl_vgui.c.
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bl_vm.h"
#include "llasm_cpu.h"
#include "bl_win32.h"

int bl_window_cursor_hidden(void);

extern char client_ScreenWide[], client_ScreenTall[];

// The scheme font name for the screen size (client 0x1018C870, cdecl, one argument):
// "<name>_<size>" with the largest size whose 4:3 area fits the screen, as the game
// does. The game's list stops at 1600; Unofficial Patch's trackerscheme.res also has
// fonts for 1920, 2400 and 2880 (bitmap fonts in its materials/fonts), which its
// loader adds the same way. Callers use the answer at once, like the game's one buffer.
void bl_client_FontName_c(_cpu *cpu)
{
    static const int sizes[] = { 640, 800, 1024, 1280, 1600, 1920, 2400, 2880 };
    static uint32_t buf;
    if (!buf) buf = bl_guest_malloc(128);
    const uint32_t *args = REG2PTR(esp + 4);
    int wide = (int)bl_call_guest(cpu, bl_h2g(client_ScreenWide), BL_CDECL, 0, 0, NULL);
    int tall = (int)bl_call_guest(cpu, bl_h2g(client_ScreenTall), BL_CDECL, 0, 0, NULL);
    int size = sizes[0];
    for (unsigned i = 0; i < sizeof sizes / sizeof *sizes && sizes[i] <= wide && sizes[i] * 3 / 4 <= tall; i++)
        size = sizes[i];
    snprintf(bl_g2h(buf), 128, "%s_%d", (const char *)bl_g2h(args[0]), size);
    eax = buf;
}

// The player's field of view, the Gameplay tab's "Field of View" slider (bl_vgui.c), saved
// with the other native settings.
#define CAMERA_KEY "HKCU\\Software\\Troika\\Vampire\\Native"
// The game's own field of view: default_fov's default, "75" (client 0x102CCDA8).
#define FOV_GAME 75
#define FOV_MIN 65
#define FOV_MAX 110
static int fov_setting = -1;

int bl_camera_fov(void)
{
    if (fov_setting < 0) {
        int f = (int)bl_reg_get_dword(CAMERA_KEY, "FieldOfView", FOV_GAME);
        fov_setting = f < FOV_MIN ? FOV_MIN : f > FOV_MAX ? FOV_MAX : f;
    }
    return fov_setting;
}

void bl_camera_fov_set(int degrees)
{
    fov_setting = degrees < FOV_MIN ? FOV_MIN : degrees > FOV_MAX ? FOV_MAX : degrees;
    bl_reg_set_dword(CAMERA_KEY, "FieldOfView", (uint32_t)fov_setting);
}

static int body_setting = -1;

int bl_camera_body(void)
{
    if (body_setting < 0) body_setting = bl_reg_get_dword(CAMERA_KEY, "FirstPersonBody", 1) != 0;
    return body_setting;
}

void bl_camera_body_set(int on)
{
    body_setting = on != 0;
    bl_reg_set_dword(CAMERA_KEY, "FirstPersonBody", (uint32_t)body_setting);
}

// Where the view was last drawn from and which way it looked (bl_client_HorPlus), before
// the breathing.
static float view_origin[3], view_angles[3];
static int view_seen;

// Idle breathing: while the player stands still the view rises and falls with a slow
// breath (in a little quicker than out) and drifts faintly from side to side, at most a
// fifth of a degree, so a still view is never frozen. It fades in over a second or two of
// standing and out as soon as the view moves; the menus (the cursor shown) hold it where
// it is. Only the picture moves: the view setup is the renderer's copy, so where the
// player aims stays where it was. view: the view setup, +0x48 its origin, +0x60 its
// angles (pitch, yaw, roll; the game passes them to AngleVectors just after).
static void breathe(uint8_t *view)
{
    static double phase, still, last_t;
    static float last[3];
    static int seen;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = ts.tv_sec + ts.tv_nsec * 1e-9, dt = seen ? t - last_t : 0;
    if (dt < 0 || dt > 0.25) dt = 0;  // a pause, a load
    last_t = t;
    float *origin = (float *)(view + 0x48), *angles = (float *)(view + 0x60);
    double moved = seen ? sqrt((origin[0] - last[0]) * (origin[0] - last[0]) + (origin[1] - last[1]) * (origin[1] - last[1]) +
                               (origin[2] - last[2]) * (origin[2] - last[2]))
                        : 1e9;
    memcpy(last, origin, sizeof last), seen = 1;
    if (!bl_window_cursor_hidden()) dt = 0;
    if (dt > 0) {
        // Still: under 4 units a second (the view settling after a step, a crouch).
        double target = moved < 4 * dt ? 1 : 0;
        still += (target - still) * (1 - exp(-dt / (target > still ? 0.8 : 0.15)));
        phase += dt;
    }
    if (still < 1e-3) return;
    double b = 2 * M_PI * phase / 4.2;  // a breath every 4.2 seconds
    double breath = sin(b) + 0.25 * sin(2 * b);
    double k = still * still * (3 - 2 * still);
    angles[0] += (float)(k * (-0.12 * breath + 0.04 * sin(2 * M_PI * phase / 9.7 + 0.6)));
    angles[1] += (float)(k * 0.08 * sin(2 * M_PI * phase / 12.3 + 1.3));
    angles[2] += (float)(k * 0.05 * sin(2 * M_PI * phase / 8.1 + 2.1));
    origin[2] += (float)(k * 0.3 * breath);
}

// Hor+ field of view, in CViewRender::Render (client 0x10191FD5, ebp = the view setup):
// where the game multiplies the field of view by 4/3 when its hidden r_anamorphic is on,
// both fields of view (+0x38 the view's, +0x3c the first-person hands') are widened
// so that a screen wider than 4:3 shows the 4:3 picture's full height and more at the
// sides. The game's projection stays 4:3 and metal_render.m crops its top and bottom to
// the screen's shape, so the result is the 4:3 view's height. The game culls with the
// widened field of view, so nothing at the sides is missing. Every camera passes here
// (the player's, dialogue and cutscenes), as do zooms, which stay in proportion.
// The player's own view is the one at exactly 75 (the game's): it takes the Field of View
// setting (as a 4:3 field of view) and the idle breathing; zooms and dialogue cameras
// keep theirs.
//   BL_WIDESCREEN=stretch   turns the widening off, with the projection correction
void bl_client_HorPlus(_cpu *cpu)
{
    static int on = -1;
    if (on < 0) {
        const char *w = getenv("BL_WIDESCREEN");
        on = !(w && !strcmp(w, "stretch"));
    }
    float *fov = REG2PTR(ebp + 0x38);
    int player = fov[0] == FOV_GAME;
    memcpy(view_origin, REG2PTR(ebp + 0x48), sizeof view_origin), view_seen = 1;
    memcpy(view_angles, REG2PTR(ebp + 0x60), sizeof view_angles);
    if (player) breathe(REG2PTR(ebp));
    if (player) fov[0] = (float)bl_camera_fov();
    if (!on) return;
    int wide = (int)bl_call_guest(cpu, bl_h2g(client_ScreenWide), BL_CDECL, 0, 0, NULL);
    int tall = (int)bl_call_guest(cpu, bl_h2g(client_ScreenTall), BL_CDECL, 0, 0, NULL);
    double widen = tall > 0 ? fmax(1.0, (double)wide / tall * 0.75) : 1.0;  // over 4:3
    for (int i = 0; i < 2; i++) {
        double deg = fov[i];
        if (deg <= 0 || deg >= 179) continue;
        fov[i] = (float)(2 * atan(tan(deg * M_PI / 360) * widen) * 180 / M_PI);
    }
}

// The player's body in first person ("First-person body", the Gameplay tab). The game
// draws the local player only with the camera in third person (melee): in
// C_BasePlayer::ShouldDraw (0x100A7A50; esi the player, eax CAM_IsThirdPerson's answer)
// the test at 0x100A7AA0 asks bl_client_BodyShown, which answers 1 (draw) in first
// person too. The model is then placed under the camera rather than where the player's
// interpolated origin is (which trails the camera by a step when moving), and set back
// along the way the view looks: BODY_BACK units level, BODY_DOWN more looking straight
// down. The camera at the eyes is then in front of the face, and looking down it sees
// the chest, legs and feet from in front rather than from inside the shoulders. That is
// C_BaseAnimating::GetRenderOrigin (0x10094040, ecx the entity's renderable, the entity
// + 4: its origin at +0x238, angles at +0x244), which the bones are built from, so the
// held weapon and the shadow follow. While the view is somewhere else (a scripted
// camera) the model is put far below, out of sight, as the game left it undrawn.
#define BODY_BACK 10.0
#define BODY_DOWN 10.0
static uint32_t body_entity;
static uint32_t body_index;
static int body_placed;  // the last GetRenderOrigin of the body put it under the camera

void bl_client_BodyShown(_cpu *cpu)
{
    uint32_t draw = eax != 0;
    if (!draw && bl_camera_body()) draw = 1, body_entity = esi, body_index = *(const uint32_t *)REG2PTR(esi + 0x44);
    else if (draw) body_entity = 0;  // third person: as the game draws it
    *(uint32_t *)REG2PTR(esp) = draw;
}

// esp[0] the answer (1: eax holds the place), esp[1] the address of the client's `input`.
void bl_client_BodyOrigin(_cpu *cpu)
{
    static uint32_t place;
    uint32_t r = ecx, use = 0;
    if (body_entity && r - 4 == body_entity && *(const uint32_t *)REG2PTR(body_entity + 0x44) == body_index &&
        bl_camera_body()) {
        uint32_t input = *(const uint32_t *)REG2PTR(*(const uint32_t *)REG2PTR(esp + 4));
        uint32_t sa = eax, sc = ecx, sd = edx;
        int third = input && (uint8_t)bl_call_guest(cpu, *(const uint32_t *)REG2PTR(*(const uint32_t *)REG2PTR(input) + 0x74),
                                                    BL_THISCALL, input, 0, NULL);
        eax = sa, ecx = sc, edx = sd;
        if (!third) {
            if (!place) place = bl_guest_malloc(12);
            const float *o = REG2PTR(r + 0x238);
            float *v = bl_g2h(place);
            double dx = view_origin[0] - o[0], dy = view_origin[1] - o[1], dz = view_origin[2] - o[2];
            int at_eyes = view_seen && dx * dx + dy * dy < 64 * 64 && dz > 0 && dz < 96;
            double yaw = view_angles[1] * M_PI / 180, down = fmin(fmax(view_angles[0] / 89.0, 0.0), 1.0);
            double back = BODY_BACK + BODY_DOWN * down;
            v[0] = view_origin[0] - (float)(back * cos(yaw)), v[1] = view_origin[1] - (float)(back * sin(yaw));
            v[2] = at_eyes ? o[2] : o[2] - 10000;
            eax = place, use = 1;
            body_placed = at_eyes;
        } else {
            body_placed = 0;
        }
    }
    *(uint32_t *)REG2PTR(esp) = use;
}

// The head hidden: set back from the camera, the body still leans its head into view
// when running. In C_BaseAnimating::SetupBones, just after BuildTransformations (vtable
// +0x1ec) has filled the entity's bone-to-world matrices (entity +0x6e8, 0x30 bytes each)
// for this frame (0x10091C64: esi the entity, ebx its studio header), the body's head
// bone and every bone under it (jaw, teeth, eyes, hair) are shrunk to the point where the
// head meets the neck, so nothing of the head is drawn. The header: +0xf0 the bone
// count, +0xf4 where the bones are (0xa0 bytes each: +0 the name's offset from the bone,
// +4 the parent's index; parents come before their children).
#define MAX_BONES 256
void bl_client_BodyBones(_cpu *cpu)
{
    static uint32_t hdr_seen;
    static int nhead;
    static uint16_t head[MAX_BONES];
    uint32_t ent = esi, hdr = ebx;
    if (!body_placed || ent != body_entity || !hdr || !bl_camera_body()) return;
    if (hdr != hdr_seen) {
        hdr_seen = hdr, nhead = 0;
        int n = *(const int32_t *)REG2PTR(hdr + 0xf0);
        uint32_t bones = hdr + *(const uint32_t *)REG2PTR(hdr + 0xf4);
        uint8_t hidden[MAX_BONES] = { 0 };
        for (int i = 0; i < n && i < MAX_BONES; i++) {
            uint32_t b = bones + (uint32_t)i * 0xa0;
            const char *name = REG2PTR(b + *(const uint32_t *)REG2PTR(b));
            int parent = *(const int32_t *)REG2PTR(b + 4);
            char low[64];
            size_t k = 0;
            for (; name[k] && k < sizeof low - 1; k++) low[k] = (char)(name[k] | 0x20);
            low[k] = 0;
            hidden[i] = (parent >= 0 && parent < i && hidden[parent]) || (strstr(low, "head") && !strstr(low, "nub"));
            if (hidden[i]) head[nhead++] = (uint16_t)i;
        }
        fprintf(stderr, "[body] %d of %d bones hidden as the head\n", nhead, n);
    }
    uint32_t m = *(const uint32_t *)REG2PTR(ent + 0x6e8);
    if (!m || !nhead) return;
    const float *root = REG2PTR(m + head[0] * 0x30u);
    float at[3] = { root[3], root[7], root[11] };
    for (int i = 0; i < nhead; i++) {
        float *b = REG2PTR(m + head[i] * 0x30u);
        for (int r = 0; r < 3; r++) b[r * 4] = b[r * 4 + 1] = b[r * 4 + 2] = 0, b[r * 4 + 3] = at[r];
    }
}

// protean-improved's Filter Load Fix: the Protean filter's level (edi) matching the one
// last set (eax) skips setting the filter (0x1019DA7D), so after loading a save it kept
// the wrong brightness. It is skipped only when the filter's material is already in that
// state. The replacement pushes the filter global (0x10619928); 1 on the stack skips.
void bl_client_FilterSame(_cpu *cpu)
{
    uint32_t filter = *(const uint32_t *)REG2PTR(esp), skip = 0;
    esp += 4;
    if (edi == eax) {
        uint32_t sa = eax, sc = ecx, sd = edx, m = *(const uint32_t *)REG2PTR(*(const uint32_t *)REG2PTR(filter) + 4);
        uint32_t vt = *(const uint32_t *)REG2PTR(m);
        int changed = (uint8_t)bl_call_guest(cpu, *(const uint32_t *)REG2PTR(vt + 4), BL_THISCALL, m, 0, NULL);
        eax = sa, ecx = sc, edx = sd;
        skip = !changed && *(const uint32_t *)REG2PTR(m + 0x2c) == 1;
    }
    esp -= 4;
    *(uint32_t *)REG2PTR(esp) = skip;
}
