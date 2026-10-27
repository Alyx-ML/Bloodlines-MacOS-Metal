// GameController input: unaccelerated mouse motion for mouse-look, and gamepads,
// which the game does not support, mapped onto its default keyboard and mouse
// bindings (Vampire/cfg/config.cfg).
//
// Raw mouse. While the mouse is captured, GCMouse deltas replace the AppKit ones,
// which carry the system's pointer acceleration. BL_RAW_MOUSE=0 turns this off.
//
// Gamepad (any extended gamepad: Xbox, PlayStation, MFi), in play:
//   left stick      W A S D (move)          right stick     look
//   A / Cross       Space (jump)            B / Circle      Ctrl (crouch)
//   X / Square      E (use)                 Y / Triangle    F (feed)
//   right trigger   left mouse (attack)     left trigger    right mouse (last discipline)
//   right shoulder  wheel down (next item)  left shoulder   wheel up (previous item)
//   left stick in   Shift (walk)            right stick in  Z (camera)
//   d-pad           up R (reload), down Tab (secondary attack), left L (quest log),
//                   right C (character sheet)
//   Menu            Escape                  Options         K (hotkeys)
// In dialogue, while answers are up (bl_dialog.c): the d-pad or left stick steps through
// them (the up and down arrows), A picks one (Enter), Menu is Escape; nothing else.
// In menus (cursor shown): either stick moves the cursor, A clicks, B is Escape, the
// d-pad gives the arrow keys and Menu is Escape.
// BL_PAD_LOOK sets the look speed in mouse counts a second at full tilt (default 1400).
#import <Carbon/Carbon.h>  // kVK_* key codes
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <math.h>
#include <os/lock.h>
#include <stdlib.h>
#include <time.h>

#include "bl_cocoa.h"

int bl_dialog_active(void);

static os_unfair_lock raw_lock = OS_UNFAIR_LOCK_INIT;
static double raw_dx, raw_dy;
static GCMouse *raw_mouse;
static dispatch_queue_t raw_queue;
static int raw_enabled = 1;
static double look_speed = 1400;

void bl_gc_init(void)
{
    const char *r = getenv("BL_RAW_MOUSE");
    raw_enabled = !(r && r[0] == '0');
    if (getenv("BL_PAD_LOOK")) look_speed = atof(getenv("BL_PAD_LOOK"));
    raw_queue = dispatch_queue_create("bl.rawmouse", DISPATCH_QUEUE_SERIAL);
}

// The current GCMouse, with a motion handler on it. Mice connect after start-up, so
// this is checked on every poll.
static GCMouse *current_mouse(void)
{
    if (!raw_enabled) return nil;
    GCMouse *m = GCMouse.current;
    if (m != raw_mouse) {
        raw_mouse = m;
        if (m) {
            m.handlerQueue = raw_queue;
            m.mouseInput.mouseMovedHandler = ^(GCMouseInput *in, float dx, float dy) {
              (void)in;
              os_unfair_lock_lock(&raw_lock);
              raw_dx += dx, raw_dy -= dy;  // GameController's y points up
              os_unfair_lock_unlock(&raw_lock);
            };
        }
    }
    return m;
}

int bl_gc_raw_mouse(void) { return current_mouse() != nil; }

static void drain_raw(int captured)
{
    os_unfair_lock_lock(&raw_lock);
    double dx = raw_dx, dy = raw_dy;
    int ix = (int)dx, iy = (int)dy;
    raw_dx = dx - ix, raw_dy = dy - iy;  // keep the fraction so slow motion is not lost
    if (!captured) raw_dx = raw_dy = 0;  // AppKit moves the visible cursor
    os_unfair_lock_unlock(&raw_lock);
    if (captured) bl_cocoa_motion(ix, iy);
}

// --- gamepad ---------------------------------------------------------------------

enum out {
    O_W, O_A, O_S, O_D, O_SPACE, O_CTRL, O_E, O_F, O_SHIFT, O_Z, O_R, O_TAB, O_L, O_C, O_ESC, O_K,
    O_UP, O_DOWN, O_LEFT, O_RIGHT, O_ENTER, O_LMB, O_RMB, O_COUNT
};
static const uint16_t out_key[O_COUNT] = {
    kVK_ANSI_W, kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_Space, kVK_Control, kVK_ANSI_E, kVK_ANSI_F,
    kVK_Shift, kVK_ANSI_Z, kVK_ANSI_R, kVK_Tab, kVK_ANSI_L, kVK_ANSI_C, kVK_Escape, kVK_ANSI_K,
    kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Return,
};
static int held[O_COUNT];

static void set_out(int o, int down)
{
    if (held[o] == down) return;
    held[o] = down;
    if (o == O_LMB || o == O_RMB)
        bl_cocoa_button(o == O_LMB ? 0 : 1, down);
    else
        bl_cocoa_key(out_key[o], down);
}

// The window lost focus (bl_cocoa.m release_all): the pad's keys and buttons go up.
void bl_gc_release(void)
{
    for (int o = 0; o < O_COUNT; o++) set_out(o, 0);
}

// Stick deflection past a dead zone, rescaled to 0..1 and squared for fine aim.
static double curve(double v)
{
    const double dead = 0.12;
    double a = fabs(v);
    if (a < dead) return 0;
    a = (a - dead) / (1 - dead);
    return copysign(a * a, v);
}

void bl_gc_poll(int captured)
{
    current_mouse();
    drain_raw(captured);

    GCController *c = GCController.current;
    GCExtendedGamepad *p = c.extendedGamepad;
    if (!c && GCController.controllers.count) p = GCController.controllers[0].extendedGamepad;
    static uint64_t last_ns;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double dt = last_ns ? (now - last_ns) / 1e9 : 0;
    last_ns = now;
    if (dt > 0.1) dt = 0.1;  // after a long frame or a load, do not jump
    int want[O_COUNT] = {0};
    if (p) {
        float lx = p.leftThumbstick.xAxis.value, ly = p.leftThumbstick.yAxis.value;
        float rx = p.rightThumbstick.xAxis.value, ry = p.rightThumbstick.yAxis.value;
        int dialog = bl_dialog_active();
        if (dialog) {
            want[O_UP] = p.dpad.up.pressed || ly > 0.5f, want[O_DOWN] = p.dpad.down.pressed || ly < -0.5f;
            want[O_ENTER] = p.buttonA.pressed, want[O_ESC] = p.buttonMenu.pressed;
            rx = ry = 0;
        } else if (captured) {
            want[O_W] = ly > 0.5f, want[O_S] = ly < -0.5f, want[O_A] = lx < -0.5f, want[O_D] = lx > 0.5f;
            want[O_SPACE] = p.buttonA.pressed, want[O_CTRL] = p.buttonB.pressed;
            want[O_E] = p.buttonX.pressed, want[O_F] = p.buttonY.pressed;
            want[O_LMB] = p.rightTrigger.value > 0.5f, want[O_RMB] = p.leftTrigger.value > 0.5f;
            want[O_SHIFT] = p.leftThumbstickButton.pressed, want[O_Z] = p.rightThumbstickButton.pressed;
            want[O_R] = p.dpad.up.pressed, want[O_TAB] = p.dpad.down.pressed;
            want[O_L] = p.dpad.left.pressed, want[O_C] = p.dpad.right.pressed;
            want[O_ESC] = p.buttonMenu.pressed, want[O_K] = p.buttonOptions.pressed;
        } else {
            want[O_LMB] = p.buttonA.pressed;
            want[O_ESC] = p.buttonB.pressed || p.buttonMenu.pressed;
            want[O_UP] = p.dpad.up.pressed, want[O_DOWN] = p.dpad.down.pressed;
            want[O_LEFT] = p.dpad.left.pressed, want[O_RIGHT] = p.dpad.right.pressed;
            // Either stick moves the cursor.
            if (fabsf(lx) > fabsf(rx)) rx = lx;
            if (fabsf(ly) > fabsf(ry)) ry = ly;
        }
        // Look (or cursor) motion, fractions carried between polls.
        static double fx, fy;
        double speed = captured ? look_speed : 700;
        fx += curve(rx) * speed * dt, fy -= curve(ry) * speed * dt;
        int dx = (int)fx, dy = (int)fy;
        fx -= dx, fy -= dy;
        bl_cocoa_motion(dx, dy);
        // The shoulders step through the inventory, once per press.
        static int lb, rb;
        if (captured && !dialog && p.leftShoulder.pressed && !lb) bl_cocoa_wheel(120);
        if (captured && !dialog && p.rightShoulder.pressed && !rb) bl_cocoa_wheel(-120);
        lb = p.leftShoulder.pressed, rb = p.rightShoulder.pressed;
    }
    // Releases first, so switching between play and menus never leaves a key down.
    for (int o = 0; o < O_COUNT; o++)
        if (!want[o]) set_out(o, 0);
    for (int o = 0; o < O_COUNT; o++)
        if (want[o]) set_out(o, 1);
}
