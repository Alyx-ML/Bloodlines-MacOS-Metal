// DirectInput 8: the system keyboard and mouse, fed by the window layer through
// bl_input.h. Both immediate (GetDeviceState) and buffered (GetDeviceData) reads work.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_input.h"
#include "com_gen.h"
#include "d3d9_objects.h"

#define DI_OK 0u
#define DI_BUFFEROVERFLOW 1u
#define DIERR_INVALIDPARAM 0x80070057u
#define DIERR_DEVICENOTREG 0x80040154u
#define DIERR_NOTACQUIRED 0x8007000Cu
#define DIERR_UNSUPPORTED 0x80004001u

enum { KIND_KEYBOARD = 1, KIND_MOUSE };

// GUID_SysMouse and GUID_SysKeyboard differ only in Data1.
#define GUID_SYSMOUSE_DATA1 0x6F1D2B60u
#define GUID_SYSKEYBOARD_DATA1 0x6F1D2B61u
static const uint8_t guid_sys_tail[12] = {0xA0, 0xD5, 0xCF, 0x11, 0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};

// Mouse buffered-data offsets (DIMOFS_*).
#define DIMOFS_X 0
#define DIMOFS_Y 4
#define DIMOFS_Z 8
#define DIMOFS_BUTTON0 12

static uint8_t keys[256];
static int32_t mouse_dx, mouse_dy, mouse_dz;
static uint8_t buttons[8];

// One buffered event queue per kind, as DirectInput keeps one per device.
#define QUEUE 512
struct event { uint32_t ofs, data, time; };
static struct queue { struct event e[QUEUE]; uint32_t head, count, seq; int overflow; } queues[3];
static uint32_t clock_ms;
static int acquired[3];
static uint32_t coop_flags[3];
static const char *const kind_name[3] = {"?", "keyboard", "mouse"};

// BL_INPUT_TRACE=1 logs device setup, acquisition and the events the game reads.
int bl_input_trace(void)
{
    static int on = -1;
    if (on < 0) on = getenv("BL_INPUT_TRACE") != NULL;
    return on;
}
#define TRACE(...) do { if (bl_input_trace()) fprintf(stderr, "[input] " __VA_ARGS__); } while (0)

// The game holds the mouse exclusively (DISCL_EXCLUSIVE) and has it acquired: the window
// layer hides the cursor and keeps it in the window.
int bl_input_mouse_exclusive(void) { return acquired[KIND_MOUSE] && (coop_flags[KIND_MOUSE] & 1); }

static void push(int kind, uint32_t ofs, uint32_t data)
{
    if (!acquired[kind]) {
        static unsigned dropped;
        if (!(dropped++ & 63)) TRACE("%s not acquired: event %#x dropped (%u so far)\n", kind_name[kind], ofs, dropped);
        return;
    }
    struct queue *q = &queues[kind];
    if (q->count == QUEUE) {
        q->overflow = 1;
        return;
    }
    q->e[(q->head + q->count++) % QUEUE] = (struct event){ofs, data, clock_ms};
}

void bl_input_key(int dik, int down)
{
    if (dik <= 0 || dik > 255) return;
    keys[dik] = down ? 0x80 : 0;
    push(KIND_KEYBOARD, (uint32_t)dik, down ? 0x80 : 0);
}

// Motion and wheel add up only while the game has the mouse: moved in a menu, it is not
// applied all at once when play resumes.
void bl_input_mouse_move(int dx, int dy)
{
    if (!acquired[KIND_MOUSE]) return;
    mouse_dx += dx, mouse_dy += dy;
    if (dx) push(KIND_MOUSE, DIMOFS_X, (uint32_t)dx);
    if (dy) push(KIND_MOUSE, DIMOFS_Y, (uint32_t)dy);
}

void bl_input_mouse_wheel(int dz)
{
    if (!acquired[KIND_MOUSE]) return;
    mouse_dz += dz;
    if (dz) push(KIND_MOUSE, DIMOFS_Z, (uint32_t)dz);
}

void bl_input_mouse_button(int button, int down)
{
    if (button < 0 || button >= 8) return;
    buttons[button] = down ? 0x80 : 0;
    push(KIND_MOUSE, DIMOFS_BUTTON0 + (uint32_t)button, down ? 0x80 : 0);
}

void bl_input_tick(uint32_t ms) { clock_ms = ms; }

// --- IDirectInput8A ------------------------------------------------------------

uint32_t bl_dinput_DirectInput8Create_c(uint32_t inst, uint32_t ver, uint32_t iid, uint32_t out, uint32_t outer)
{
    (void)inst, (void)ver, (void)iid, (void)outer;
    G32(out) = obj_new(OBJ_DINPUT, bl_vtbl_IDirectInput8A())->guest;
    return DI_OK;
}

uint32_t bl_IDirectInput8A_CreateDevice_c(uint32_t self, uint32_t guid, uint32_t out, uint32_t outer)
{
    (void)self, (void)outer;
    const uint8_t *g = bl_g2h(guid);
    uint32_t data1 = G32(guid);
    int kind = data1 == GUID_SYSKEYBOARD_DATA1 ? KIND_KEYBOARD : data1 == GUID_SYSMOUSE_DATA1 ? KIND_MOUSE : 0;
    if (!kind || memcmp(g + 4, guid_sys_tail, 12)) {
        G32(out) = 0;
        return DIERR_DEVICENOTREG;
    }
    struct obj *o = obj_new(OBJ_DINPUT_DEVICE, bl_vtbl_IDirectInputDevice8A());
    o->input_kind = (uint32_t)kind;
    o->input_state_size = kind == KIND_KEYBOARD ? 256 : 16;
    G32(out) = o->guest;
    TRACE("CreateDevice %s\n", kind_name[kind]);
    return DI_OK;
}

uint32_t bl_IDirectInput8A_EnumDevices_c(uint32_t self, uint32_t type, uint32_t callback, uint32_t ref, uint32_t flags)
{
    (void)self, (void)type, (void)callback, (void)ref, (void)flags;
    return DI_OK;  // no game controllers
}

uint32_t bl_IDirectInput8A_GetDeviceStatus_c(uint32_t self, uint32_t guid)
{
    (void)self;
    uint32_t data1 = G32(guid);
    return data1 == GUID_SYSKEYBOARD_DATA1 || data1 == GUID_SYSMOUSE_DATA1 ? DI_OK : DIERR_DEVICENOTREG;
}

uint32_t bl_IDirectInput8A_Initialize_c(uint32_t self, uint32_t inst, uint32_t ver)
{
    (void)self, (void)inst, (void)ver;
    return DI_OK;
}

// --- IDirectInputDevice8A ------------------------------------------------------

static struct obj *dev(uint32_t self) { return obj_of(self); }

uint32_t bl_IDirectInputDevice8A_SetDataFormat_c(uint32_t self, uint32_t format)
{
    // DIDATAFORMAT: dwSize, dwObjSize, dwFlags, dwDataSize, dwNumObjs, rgodf.
    struct obj *o = dev(self);
    uint32_t size = G32(format + 12);
    if (o->input_kind == KIND_KEYBOARD && size != 256) return DIERR_INVALIDPARAM;
    if (o->input_kind == KIND_MOUSE && size != 16 && size != 20) return DIERR_INVALIDPARAM;
    o->input_state_size = size;
    TRACE("SetDataFormat %s: %u bytes\n", kind_name[o->input_kind], size);
    return DI_OK;
}

uint32_t bl_IDirectInputDevice8A_SetCooperativeLevel_c(uint32_t self, uint32_t hwnd, uint32_t flags)
{
    struct obj *o = dev(self);
    coop_flags[o->input_kind] = flags;
    TRACE("SetCooperativeLevel %s: hwnd %#x flags %#x\n", kind_name[o->input_kind], hwnd, flags);
    return DI_OK;
}

uint32_t bl_IDirectInputDevice8A_SetProperty_c(uint32_t self, uint32_t prop, uint32_t header)
{
    (void)self;
    TRACE("SetProperty %s: prop %#x value %#x\n", kind_name[dev(self)->input_kind], prop, G32(header + 16));
    return DI_OK;  // buffer size, axis mode: the queue is fixed and axes are relative
}

uint32_t bl_IDirectInputDevice8A_GetProperty_c(uint32_t self, uint32_t prop, uint32_t header)
{
    (void)self, (void)prop, (void)header;
    return DIERR_UNSUPPORTED;
}

uint32_t bl_IDirectInputDevice8A_Acquire_c(uint32_t self)
{
    int kind = (int)dev(self)->input_kind;
    if (!acquired[kind]) TRACE("Acquire %s\n", kind_name[kind]);
    if (!acquired[kind] && kind == KIND_MOUSE) mouse_dx = mouse_dy = mouse_dz = 0;
    acquired[kind] = 1;
    return DI_OK;
}

uint32_t bl_IDirectInputDevice8A_Unacquire_c(uint32_t self)
{
    struct obj *o = dev(self);
    if (acquired[o->input_kind]) TRACE("Unacquire %s\n", kind_name[o->input_kind]);
    acquired[o->input_kind] = 0;
    queues[o->input_kind].count = 0;
    if (o->input_kind == KIND_MOUSE) mouse_dx = mouse_dy = mouse_dz = 0;
    return DI_OK;
}

uint32_t bl_IDirectInputDevice8A_Poll_c(uint32_t self)
{
    (void)self;
    return 1;  // DI_NOEFFECT: not a polled device
}

uint32_t bl_IDirectInputDevice8A_GetDeviceState_c(uint32_t self, uint32_t size, uint32_t data)
{
    struct obj *o = dev(self);
    static unsigned calls[3];
    if (!calls[o->input_kind]++) TRACE("first GetDeviceState %s (%u bytes)\n", kind_name[o->input_kind], size);
    if (!acquired[o->input_kind]) return DIERR_NOTACQUIRED;
    uint8_t *p = bl_g2h(data);
    memset(p, 0, size);
    if (o->input_kind == KIND_KEYBOARD) {
        memcpy(p, keys, size < 256 ? size : 256);
    } else {
        // DIMOUSESTATE(2): lX, lY, lZ, then 4 (or 8) buttons; axes are motion since the last read.
        int32_t axes[3] = {mouse_dx, mouse_dy, mouse_dz};
        memcpy(p, axes, size < 12 ? size : 12);
        if (size > 12) memcpy(p + 12, buttons, size - 12 < 8 ? size - 12 : 8);
        mouse_dx = mouse_dy = mouse_dz = 0;
    }
    return DI_OK;
}

uint32_t bl_IDirectInputDevice8A_GetDeviceData_c(uint32_t self, uint32_t objsize, uint32_t out, uint32_t inout,
                                                 uint32_t flags)
{
    struct obj *o = dev(self);
    if (!acquired[o->input_kind]) return DIERR_NOTACQUIRED;
    struct queue *q = &queues[o->input_kind];
    uint32_t want = G32(inout), n = 0;
    int peek = flags & 1;  // DIGDD_PEEK
    // DIDEVICEOBJECTDATA: dwOfs, dwData, dwTimeStamp, dwSequence, uAppData (DI8).
    for (; n < want && n < q->count; n++) {
        const struct event *e = &q->e[(q->head + n) % QUEUE];
        if (out) {
            uint32_t *d = bl_g2h(out + n * objsize);
            memset(d, 0, objsize);
            d[0] = e->ofs, d[1] = e->data, d[2] = e->time, d[3] = q->seq + n;
        }
    }
    if (!peek) {
        q->head = (q->head + n) % QUEUE;
        q->count -= n;
        q->seq += n;
    }
    G32(inout) = n;
    static unsigned calls[3];
    if (!calls[o->input_kind]++) TRACE("first GetDeviceData %s (room for %u)\n", kind_name[o->input_kind], want);
    if (n && !peek && o->input_kind == KIND_KEYBOARD) TRACE("GetDeviceData keyboard: %u events, first %#x=%#x\n", n,
        q->e[(q->head + QUEUE - n) % QUEUE].ofs, q->e[(q->head + QUEUE - n) % QUEUE].data);
    uint32_t hr = q->overflow ? DI_BUFFEROVERFLOW : DI_OK;
    if (!peek) q->overflow = 0;
    return hr;
}

uint32_t bl_IDirectInputDevice8A_GetCapabilities_c(uint32_t self, uint32_t caps)
{
    // DIDEVCAPS: dwSize, dwFlags, dwDevType, dwAxes, dwButtons, dwPOVs, ...
    struct obj *o = dev(self);
    uint32_t size = G32(caps);
    memset(bl_g2h(caps + 4), 0, size > 4 ? size - 4 : 0);
    G32(caps + 4) = 1;  // DIDC_ATTACHED
    if (o->input_kind == KIND_KEYBOARD) {
        G32(caps + 8) = 0x13 | 4 << 8;  // DI8DEVTYPE_KEYBOARD, DI8DEVTYPEKEYBOARD_PCENH
        G32(caps + 16) = 128;
    } else {
        G32(caps + 8) = 0x12 | 2 << 8;  // DI8DEVTYPE_MOUSE, DI8DEVTYPEMOUSE_TRADITIONAL
        G32(caps + 12) = 3;
        G32(caps + 16) = o->input_state_size == 20 ? 8 : 4;
    }
    return DI_OK;
}

uint32_t bl_IDirectInputDevice8A_SetEventNotification_c(uint32_t self, uint32_t event)
{
    (void)self, (void)event;
    return DI_OK;
}
