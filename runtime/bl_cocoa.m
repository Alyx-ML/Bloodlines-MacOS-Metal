// AppKit window and input for the game (see bl_cocoa.h).
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>  // kVK_* key codes
#import <QuartzCore/CAMetalLayer.h>

#include <math.h>
#include <pthread.h>

#include "bl_cocoa.h"
#include "bl_input.h"
#include "bl_win32.h"

uint32_t bl_u32_PostMessageA_c(uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp);
// bl_window.c: the cursor in client coordinates of the main window.
void bl_window_set_cursor(uint32_t h, int32_t x, int32_t y);
void bl_window_move_cursor(int32_t dx, int32_t dy);
void bl_window_get_cursor(uint32_t h, int32_t *x, int32_t *y);
int bl_window_cursor_hidden(void);

enum {
    WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_CHAR = 0x102, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105,
    WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202, WM_RBUTTONDOWN = 0x204, WM_RBUTTONUP = 0x205,
    WM_MBUTTONDOWN = 0x207, WM_MBUTTONUP = 0x208, WM_MOUSEWHEEL = 0x20A, WM_CLOSE = 0x10, WM_ACTIVATEAPP = 0x1C,
    WM_ACTIVATE = 0x06, WM_SETFOCUS = 0x07, WM_KILLFOCUS = 0x08,
    MK_LBUTTON = 1, MK_RBUTTON = 2, MK_SHIFT = 4, MK_CONTROL = 8, MK_MBUTTON = 0x10,
};

// Mac virtual key code -> DirectInput scan code (DIK_*, which is the PC set-1 scan code
// with 0x80 for extended keys) and Windows virtual key (VK_*).
static const struct { uint16_t mac; uint8_t dik, vk; } keymap[] = {
    {kVK_ANSI_A, 0x1E, 'A'}, {kVK_ANSI_B, 0x30, 'B'}, {kVK_ANSI_C, 0x2E, 'C'}, {kVK_ANSI_D, 0x20, 'D'},
    {kVK_ANSI_E, 0x12, 'E'}, {kVK_ANSI_F, 0x21, 'F'}, {kVK_ANSI_G, 0x22, 'G'}, {kVK_ANSI_H, 0x23, 'H'},
    {kVK_ANSI_I, 0x17, 'I'}, {kVK_ANSI_J, 0x24, 'J'}, {kVK_ANSI_K, 0x25, 'K'}, {kVK_ANSI_L, 0x26, 'L'},
    {kVK_ANSI_M, 0x32, 'M'}, {kVK_ANSI_N, 0x31, 'N'}, {kVK_ANSI_O, 0x18, 'O'}, {kVK_ANSI_P, 0x19, 'P'},
    {kVK_ANSI_Q, 0x10, 'Q'}, {kVK_ANSI_R, 0x13, 'R'}, {kVK_ANSI_S, 0x1F, 'S'}, {kVK_ANSI_T, 0x14, 'T'},
    {kVK_ANSI_U, 0x16, 'U'}, {kVK_ANSI_V, 0x2F, 'V'}, {kVK_ANSI_W, 0x11, 'W'}, {kVK_ANSI_X, 0x2D, 'X'},
    {kVK_ANSI_Y, 0x15, 'Y'}, {kVK_ANSI_Z, 0x2C, 'Z'},
    {kVK_ANSI_1, 0x02, '1'}, {kVK_ANSI_2, 0x03, '2'}, {kVK_ANSI_3, 0x04, '3'}, {kVK_ANSI_4, 0x05, '4'},
    {kVK_ANSI_5, 0x06, '5'}, {kVK_ANSI_6, 0x07, '6'}, {kVK_ANSI_7, 0x08, '7'}, {kVK_ANSI_8, 0x09, '8'},
    {kVK_ANSI_9, 0x0A, '9'}, {kVK_ANSI_0, 0x0B, '0'},
    {kVK_ANSI_Minus, 0x0C, 0xBD}, {kVK_ANSI_Equal, 0x0D, 0xBB}, {kVK_Delete, 0x0E, 0x08}, {kVK_Tab, 0x0F, 0x09},
    {kVK_ANSI_LeftBracket, 0x1A, 0xDB}, {kVK_ANSI_RightBracket, 0x1B, 0xDD}, {kVK_Return, 0x1C, 0x0D},
    {kVK_Control, 0x1D, 0x11}, {kVK_ANSI_Semicolon, 0x27, 0xBA}, {kVK_ANSI_Quote, 0x28, 0xDE},
    {kVK_ANSI_Grave, 0x29, 0xC0}, {kVK_Shift, 0x2A, 0x10}, {kVK_ANSI_Backslash, 0x2B, 0xDC},
    {kVK_ANSI_Comma, 0x33, 0xBC}, {kVK_ANSI_Period, 0x34, 0xBE}, {kVK_ANSI_Slash, 0x35, 0xBF},
    {kVK_RightShift, 0x36, 0x10}, {kVK_ANSI_KeypadMultiply, 0x37, 0x6A}, {kVK_Option, 0x38, 0x12},
    {kVK_Space, 0x39, 0x20}, {kVK_CapsLock, 0x3A, 0x14}, {kVK_Escape, 0x01, 0x1B},
    {kVK_F1, 0x3B, 0x70}, {kVK_F2, 0x3C, 0x71}, {kVK_F3, 0x3D, 0x72}, {kVK_F4, 0x3E, 0x73}, {kVK_F5, 0x3F, 0x74},
    {kVK_F6, 0x40, 0x75}, {kVK_F7, 0x41, 0x76}, {kVK_F8, 0x42, 0x77}, {kVK_F9, 0x43, 0x78}, {kVK_F10, 0x44, 0x79},
    {kVK_F11, 0x57, 0x7A}, {kVK_F12, 0x58, 0x7B},
    {kVK_ANSI_Keypad7, 0x47, 0x67}, {kVK_ANSI_Keypad8, 0x48, 0x68}, {kVK_ANSI_Keypad9, 0x49, 0x69},
    {kVK_ANSI_KeypadMinus, 0x4A, 0x6D}, {kVK_ANSI_Keypad4, 0x4B, 0x64}, {kVK_ANSI_Keypad5, 0x4C, 0x65},
    {kVK_ANSI_Keypad6, 0x4D, 0x66}, {kVK_ANSI_KeypadPlus, 0x4E, 0x6B}, {kVK_ANSI_Keypad1, 0x4F, 0x61},
    {kVK_ANSI_Keypad2, 0x50, 0x62}, {kVK_ANSI_Keypad3, 0x51, 0x63}, {kVK_ANSI_Keypad0, 0x52, 0x60},
    {kVK_ANSI_KeypadDecimal, 0x53, 0x6E}, {kVK_ANSI_KeypadEnter, 0x9C, 0x0D}, {kVK_RightControl, 0x9D, 0x11},
    {kVK_ANSI_KeypadDivide, 0xB5, 0x6F}, {kVK_RightOption, 0xB8, 0x12}, {kVK_Home, 0xC7, 0x24},
    {kVK_UpArrow, 0xC8, 0x26}, {kVK_PageUp, 0xC9, 0x21}, {kVK_LeftArrow, 0xCB, 0x25}, {kVK_RightArrow, 0xCD, 0x27},
    {kVK_End, 0xCF, 0x23}, {kVK_DownArrow, 0xD0, 0x28}, {kVK_PageDown, 0xD1, 0x22}, {kVK_Help, 0xD2, 0x2D},
    {kVK_ForwardDelete, 0xD3, 0x2E}, {kVK_Command, 0xDB, 0x5B}, {kVK_RightCommand, 0xDC, 0x5C},
};

// bl_gamecontroller.m
void bl_gc_init(void);
void bl_gc_poll(int captured);
int bl_gc_raw_mouse(void);
void bl_gc_release(void);

static NSWindow *window;
static CAMetalLayer *metal_layer;
static uint32_t game_hwnd, client_w = 1024, client_h = 768;
static int captured, mouse_buttons;
static int buttons_down;          // the game's buttons 0-7 it saw go down (bit n)
static uint8_t mac_down[128];     // keys the game saw go down, by Mac key code
static NSEventModifierFlags mod_flags;  // the modifiers as last seen (modifiers)
static double became_key_at;      // when the window last became key (system uptime)

@interface BLView : NSView
@end

@implementation BLView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return metal_layer; }
@end

@interface BLWindowDelegate : NSObject <NSWindowDelegate>
@end

static void release_all(void);

@implementation BLWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    (void)sender;
    bl_u32_PostMessageA_c(game_hwnd, WM_CLOSE, 0, 0);
    return NO;  // the game destroys its window itself
}
- (void)windowDidBecomeKey:(NSNotification *)n
{
    (void)n;
    became_key_at = NSProcessInfo.processInfo.systemUptime;
    bl_u32_PostMessageA_c(game_hwnd, WM_ACTIVATEAPP, 1, 0);
    bl_u32_PostMessageA_c(game_hwnd, WM_ACTIVATE, 1, 0);
    bl_u32_PostMessageA_c(game_hwnd, WM_SETFOCUS, 0, 0);
}
- (void)windowDidResignKey:(NSNotification *)n
{
    (void)n;
    bl_cocoa_capture_mouse(0);
    release_all();
    bl_u32_PostMessageA_c(game_hwnd, WM_KILLFOCUS, 0, 0);
    bl_u32_PostMessageA_c(game_hwnd, WM_ACTIVATE, 0, 0);
    bl_u32_PostMessageA_c(game_hwnd, WM_ACTIVATEAPP, 0, 0);
}
@end

static BLWindowDelegate *delegate;

// Window content size for a game resolution: one point per pixel, shrunk to fit the
// screen for modes bigger than it (a Retina display's native size, say).
static NSSize fit_size(uint32_t width, uint32_t height)
{
    NSRect avail = NSScreen.mainScreen.visibleFrame;
    double k = fmin(1.0, fmin((avail.size.width - 16) / width, (avail.size.height - 48) / height));
    return NSMakeSize(floor(width * k), floor(height * k));
}

CAMetalLayer *bl_cocoa_open_window(uint32_t width, uint32_t height, const char *title, uint32_t hwnd)
{
    if (!pthread_main_np()) {
        fprintf(stderr, "[cocoa] the window needs the main thread; staying headless\n");
        return NULL;
    }
    game_hwnd = hwnd, client_w = width, client_h = height;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    metal_layer = [CAMetalLayer layer];
    metal_layer.opaque = YES;
    // The drawable keeps the game's resolution; a bigger window or full screen scales
    // it up with black bars instead of stretching it.
    metal_layer.contentsGravity = kCAGravityResizeAspect;
    metal_layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    NSSize size = fit_size(width, height);
    NSRect frame = NSMakeRect(0, 0, size.width, size.height);
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    window.title = [NSString stringWithUTF8String:title];
    BLView *view = [[BLView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    window.contentView = view;
    delegate = [BLWindowDelegate new];
    window.delegate = delegate;
    window.acceptsMouseMovedEvents = YES;
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    window.contentAspectRatio = NSMakeSize(width, height);
    metal_layer.contentsScale = window.backingScaleFactor;
    [window center];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
    bl_gc_init();
    return metal_layer;
}

static int fullscreen(void) { return window && (window.styleMask & NSWindowStyleMaskFullScreen) != 0; }

void bl_cocoa_set_content_size(uint32_t width, uint32_t height)
{
    client_w = width, client_h = height;
    if (!window) return;
    window.contentAspectRatio = NSMakeSize(width, height);
    if (!fullscreen()) {
        [window setContentSize:fit_size(width, height)];
        [window center];
    }
}

// The highest refresh rate of the screen the window is on (120 on ProMotion), 0 without
// a window.
int bl_cocoa_refresh_rate(void)
{
    NSScreen *screen = window.screen ? window.screen : NSScreen.mainScreen;
    return window && screen ? (int)screen.maximumFramesPerSecond : 0;
}

// The current EDR headroom of the window's screen: it changes with the brightness and
// rises once HDR content is on screen.
float bl_cocoa_edr_headroom(void)
{
    NSScreen *screen = window.screen ? window.screen : NSScreen.mainScreen;
    return window && screen ? (float)screen.maximumExtendedDynamicRangeColorComponentValue : 1;
}

// Cmd+Ctrl+F, Cmd+Return or the green button. A game started without -window asks
// for full screen when it creates its device.
void bl_cocoa_set_fullscreen(int on)
{
    if (window && fullscreen() != (on != 0)) [window toggleFullScreen:nil];
}

// Where the game image sits in the view: scaled to fit, centred (contentsGravity).
static NSRect image_rect(void)
{
    NSSize v = window.contentView.bounds.size;
    double k = fmin(v.width / client_w, v.height / client_h), w = client_w * k, h = client_h * k;
    return NSMakeRect((v.width - w) / 2, (v.height - h) / 2, w, h);
}

// Game x for a position in the drawn image, and back, with the menu squeeze.
static float squeeze = 1;
void bl_cocoa_set_squeeze(float s) { squeeze = s > 0 && s <= 1 ? s : 1; }
static double unsqueeze_x(double x) { return client_w / 2.0 + (x - client_w / 2.0) / squeeze; }
static double squeeze_x(double x) { return client_w / 2.0 + (x - client_w / 2.0) * squeeze; }

void bl_cocoa_capture_mouse(int on)
{
    if (!window || on == captured) return;
    captured = on;
    if (bl_input_trace()) fprintf(stderr, "[input] mouse %s\n", on ? "captured" : "released");
    if (on) {
        // Park the real pointer in the middle of the window so clicks land on it.
        NSRect r = [window convertRectToScreen:window.contentView.frame];
        CGFloat top = NSMaxY(NSScreen.screens[0].frame);
        CGWarpMouseCursorPosition(CGPointMake(NSMidX(r), top - NSMidY(r)));
        [NSCursor hide];
        CGAssociateMouseAndMouseCursorPosition(false);
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
    }
}

static uint32_t key_lparam(uint8_t dik, int up, int repeat)
{
    uint32_t lp = 1 | (uint32_t)(dik & 0x7F) << 16 | (dik & 0x80 ? 1u << 24 : 0);
    if (repeat) lp |= 1u << 30;
    if (up) lp |= 3u << 30;
    return lp;
}

static int find_key(uint16_t mac)
{
    for (size_t i = 0; i < sizeof keymap / sizeof keymap[0]; i++)
        if (keymap[i].mac == mac) return (int)i;
    return -1;
}

static void key(uint16_t mac, int down, int repeat, NSString *chars)
{
    int i = find_key(mac);
    if (i < 0) {
        if (bl_input_trace()) fprintf(stderr, "[input] unmapped mac key %u\n", mac);
        return;
    }
    uint8_t dik = keymap[i].dik, vk = keymap[i].vk;
    int alt = vk == 0x12;
    if (mac < 128) mac_down[mac] = (uint8_t)(down != 0);
    if (!repeat) bl_input_key(dik, down);
    bl_input_vk(vk, down);
    if (bl_input_trace() && !repeat) fprintf(stderr, "[input] key mac %u dik %#x vk %#x %s\n", mac, dik, vk, down ? "down" : "up");
    uint32_t msg = alt ? (down ? WM_SYSKEYDOWN : WM_SYSKEYUP) : (down ? WM_KEYDOWN : WM_KEYUP);
    bl_u32_PostMessageA_c(game_hwnd, msg, vk, key_lparam(dik, !down, repeat));
    if (down && chars.length) {
        unichar c = [chars characterAtIndex:0];
        if (c == 0x7F) c = 8;  // backspace
        if (c == 0x0D || c == 8 || c == 9 || c == 0x1B || (c >= 0x20 && c < 0x7F) || (c >= 0xA0 && c < 0x100))
            bl_u32_PostMessageA_c(game_hwnd, WM_CHAR, c, key_lparam(dik, 0, repeat));
    }
}

// Modifier keys arrive as flag changes.
static void modifiers(NSEvent *e)
{
    NSEventModifierFlags now = e.modifierFlags;
    static const struct { NSEventModifierFlags flag; uint16_t mac; } mods[] = {
        {NSEventModifierFlagShift, kVK_Shift}, {NSEventModifierFlagControl, kVK_Control},
        {NSEventModifierFlagOption, kVK_Option}, {NSEventModifierFlagCapsLock, kVK_CapsLock},
    };
    for (size_t i = 0; i < sizeof mods / sizeof mods[0]; i++)
        if ((now ^ mod_flags) & mods[i].flag) key(mods[i].mac, (now & mods[i].flag) != 0, 0, nil);
    mod_flags = now;
}

static uint32_t mouse_wparam(void)
{
    NSEventModifierFlags f = [NSEvent modifierFlags];
    return (uint32_t)mouse_buttons | (f & NSEventModifierFlagShift ? MK_SHIFT : 0) |
           (f & NSEventModifierFlagControl ? MK_CONTROL : 0);
}

static void button(int b, int down, uint32_t lp)
{
    buttons_down = down ? buttons_down | 1 << b : buttons_down & ~(1 << b);
    bl_input_mouse_button(b, down);
    static const uint32_t flag[3] = {MK_LBUTTON, MK_RBUTTON, MK_MBUTTON};
    static const uint32_t msg[3][2] = {{WM_LBUTTONUP, WM_LBUTTONDOWN}, {WM_RBUTTONUP, WM_RBUTTONDOWN},
                                       {WM_MBUTTONUP, WM_MBUTTONDOWN}};
    if (b < 3) {
        mouse_buttons = down ? mouse_buttons | (int)flag[b] : mouse_buttons & ~(int)flag[b];
        bl_u32_PostMessageA_c(game_hwnd, msg[b][down], mouse_wparam(), lp);
    }
}

// BL_CLICKS="frame:x,y ..." clicks the left button at x,y (game pixels) on those
// frames, for testing menus without a window: the cursor moves there on the frame,
// the button goes down three frames later and up three after that.
// BL_KEYS="frame:key:frames ..." holds a key (macOS key code, e.g. 13 for W) down from
// that frame for that many frames; "frame:m:dx,dy" moves the mouse by dx,dy then (turning
// the view in a level); "frame:t:text|" types the text, a character a frame, with ~ for
// Return (for the console: 50 is its key).
void bl_cocoa_motion(int dx, int dy);
static void script_keys(unsigned long frame)
{
    static const char *script;
    static int init;
    if (!init) init = 1, script = getenv("BL_KEYS");
    for (const char *p = script; p && *p;) {
        char *end;
        unsigned long f = strtoul(p, &end, 10);
        if (*end != ':') break;
        if (end[1] == 't') {
            const char *t = end + 3, *stop = strchr(t, '|');
            size_t n = stop ? (size_t)(stop - t) : strlen(t);
            if (frame >= f && frame < f + n) {
                char c = t[frame - f];
                if (c == '~') key(36, 1, 0, nil), key(36, 0, 0, nil);
                else bl_u32_PostMessageA_c(game_hwnd, WM_CHAR, (uint8_t)c, 1);
            }
            end = (char *)(stop ? stop + 1 : t + n);
        } else if (end[1] == 'm') {
            int dx = (int)strtol(end + 3, &end, 10), dy = *end == ',' ? (int)strtol(end + 1, &end, 10) : 0;
            if (frame == f) bl_cocoa_motion(dx, dy);
        } else {
            int k = (int)strtol(end + 1, &end, 10), n = *end == ':' ? (int)strtol(end + 1, &end, 10) : 1;
            if (frame == f || frame == f + (unsigned long)n) {
                fprintf(stderr, "[input] frame %lu: key %d %s\n", frame, k, frame == f ? "down" : "up");
                key((uint16_t)k, frame == f, 0, nil);
            }
        }
        p = end;
        while (*p == ' ') p++;
        if (p == end && *p) break;
    }
}

void bl_cocoa_script_input(unsigned long frame, uint32_t hwnd)
{
    static const char *script;
    static int init;
    if (!init) init = 1, script = getenv("BL_CLICKS");
    if (!game_hwnd) game_hwnd = hwnd;
    script_keys(frame);
    if (!script) return;
    for (const char *p = script; *p;) {
        char *end;
        unsigned long f = strtoul(p, &end, 10);
        int x = 0, y = 0;
        if (*end == ':') x = (int)strtol(end + 1, &end, 10);
        if (*end == ',') y = (int)strtol(end + 1, &end, 10);
        uint32_t lp = (uint32_t)(x & 0xFFFF) | (uint32_t)(y & 0xFFFF) << 16;
        if (frame == f) {
            bl_window_set_cursor(game_hwnd, x, y);
            bl_u32_PostMessageA_c(game_hwnd, WM_MOUSEMOVE, mouse_wparam(), lp);
        }
        if (frame == f + 3 || frame == f + 6) {
            fprintf(stderr, "[input] frame %lu: click %s at %d,%d\n", frame, frame == f + 3 ? "down" : "up", x, y);
            button(0, frame == f + 3, lp);
        }
        p = end;
        while (*p == ' ') p++;
        if (p == end && *p) break;  // not a frame:x,y entry
    }
}

static void wheel(int dz, uint32_t lp)
{
    bl_input_mouse_wheel(dz);
    bl_u32_PostMessageA_c(game_hwnd, WM_MOUSEWHEEL, mouse_wparam() | (uint32_t)(dz & 0xFFFF) << 16, lp);
}

static uint32_t cursor_lparam(void)
{
    int32_t x, y;
    bl_window_get_cursor(game_hwnd, &x, &y);
    return (uint32_t)(x & 0xFFFF) | (uint32_t)(y & 0xFFFF) << 16;
}

// Input that does not come from AppKit events: unaccelerated mouse motion and
// controllers (bl_gamecontroller.m).
void bl_cocoa_key(uint16_t mac, int down) { key(mac, down, 0, nil); }
void bl_cocoa_button(int b, int down) { button(b, down, cursor_lparam()); }

// The window lost focus: what is held goes up, since the releases happen in another app
// and would never reach the game (it would keep walking after Cmd+Tab). Caps Lock is a
// state, not a held key: it stays.
static void release_all(void)
{
    bl_gc_release();
    for (uint16_t m = 0; m < 128; m++)
        if (mac_down[m] && m != kVK_CapsLock) key(m, 0, 0, nil);
    mod_flags &= NSEventModifierFlagCapsLock;
    for (int b = 0; b < 8; b++)
        if (buttons_down & 1 << b) button(b, 0, cursor_lparam());
}
void bl_cocoa_wheel(int dz) { wheel(dz, cursor_lparam()); }

void bl_cocoa_motion(int dx, int dy)
{
    if (!dx && !dy) return;
    bl_input_mouse_move(dx, dy);
    bl_window_move_cursor(dx, dy);
    if (!captured && window) {
        // A visible cursor is the real pointer: move it to where the game's cursor is now.
        int32_t x, y;
        bl_window_get_cursor(game_hwnd, &x, &y);
        NSRect r = image_rect();
        NSPoint p = NSMakePoint(r.origin.x + squeeze_x(x + 0.5) * r.size.width / client_w,
                                NSMaxY(r) - (y + 0.5) * r.size.height / client_h);
        p = [window convertPointToScreen:[window.contentView convertPoint:p toView:nil]];
        CGWarpMouseCursorPosition(CGPointMake(p.x, NSMaxY(NSScreen.screens[0].frame) - p.y));
        CGAssociateMouseAndMouseCursorPosition(true);
    }
    bl_u32_PostMessageA_c(game_hwnd, WM_MOUSEMOVE, mouse_wparam(), cursor_lparam());
}

static void mouse(NSEvent *e)
{
    NSView *v = window.contentView;
    NSPoint p = [v convertPoint:e.locationInWindow fromView:nil];
    NSRect r = image_rect();
    int moved = e.type == NSEventTypeMouseMoved || e.type == NSEventTypeLeftMouseDragged ||
                e.type == NSEventTypeRightMouseDragged || e.type == NSEventTypeOtherMouseDragged;
    int32_t x, y;
    int raw = captured && bl_gc_raw_mouse();
    if (captured) {
        // The pointer is frozen: the cursor only moves by the motion deltas (whole pixels,
        // the remainder carried to the next event). With a GCMouse those come unaccelerated
        // from bl_gamecontroller.m instead.
        static double fx, fy;
        if (moved && !raw) {
            fx += e.deltaX, fy += e.deltaY;
            int32_t dx = (int32_t)fx, dy = (int32_t)fy;
            fx -= dx, fy -= dy;
            bl_window_move_cursor(dx, dy);
        }
        bl_window_get_cursor(game_hwnd, &x, &y);
    } else {
        x = (int32_t)unsqueeze_x((p.x - r.origin.x) * client_w / r.size.width);
        y = (int32_t)((NSMaxY(r) - p.y) * client_h / r.size.height);
        x = x < 0 ? 0 : x >= (int32_t)client_w ? (int32_t)client_w - 1 : x;
        y = y < 0 ? 0 : y >= (int32_t)client_h ? (int32_t)client_h - 1 : y;
        bl_window_set_cursor(game_hwnd, x, y);
    }
    uint32_t lp = (uint32_t)(x & 0xFFFF) | (uint32_t)(y & 0xFFFF) << 16;
    bl_input_tick((uint32_t)(e.timestamp * 1000));
    switch (e.type) {
    case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged: {
        if (raw) break;
        // DirectInput reports raw counts; keep the fraction so slow motion is not lost.
        static double rx, ry;
        rx += e.deltaX, ry += e.deltaY;
        int dx = (int)rx, dy = (int)ry;
        rx -= dx, ry -= dy;
        bl_input_mouse_move(dx, dy);
        bl_u32_PostMessageA_c(game_hwnd, WM_MOUSEMOVE, mouse_wparam(), lp);
        break;
    }
    case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: {
        int down = e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown ||
                   e.type == NSEventTypeOtherMouseDown;
        int b = e.type <= NSEventTypeLeftMouseUp ? 0 : e.type <= NSEventTypeRightMouseUp ? 1 : (int)e.buttonNumber;
        if (b <= 7) button(b, down, lp);
        break;
    }
    case NSEventTypeScrollWheel: {
        int dz = (int)(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 4 : 120));
        if (dz) wheel(dz, lp);
        break;
    }
    default: break;
    }
}

// Whether a mouse event over the window is the game's: a press only inside the picture
// (not on the title bar, whose drag AppKit tracks and keeps the release of) and not the
// click that brings the window back to the front; a release only of a press the game saw.
static int mouse_for_game(NSEvent *e)
{
    switch (e.type) {
    case NSEventTypeLeftMouseDown: case NSEventTypeRightMouseDown: case NSEventTypeOtherMouseDown: {
        NSView *v = window.contentView;
        return window.isKeyWindow && e.timestamp > became_key_at &&
               NSPointInRect([v convertPoint:e.locationInWindow fromView:nil], v.bounds);
    }
    case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseUp: case NSEventTypeOtherMouseUp: {
        int b = e.type == NSEventTypeLeftMouseUp ? 0 : e.type == NSEventTypeRightMouseUp ? 1 : (int)e.buttonNumber;
        return b <= 7 && (buttons_down & 1 << b);
    }
    default:
        return 1;
    }
}

static uint64_t last_pump_ns;

// Called from the timer imports: while the game goes a long time without reading its
// message queue (loading a map), keep draining AppKit events so macOS does not mark the
// app "Not Responding". Messages are only queued here; the game handles them later.
void bl_cocoa_pump_if_idle(void)
{
    if (!window || !pthread_main_np()) return;
    if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last_pump_ns >= 100000000ull) bl_cocoa_pump();
}

int bl_cocoa_pump(void)
{
    if (!window) return 0;
    last_pump_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int any = 0;
    // Capture the mouse while the game hides the cursor or holds the mouse exclusively,
    // and only while the window has focus.
    bl_cocoa_capture_mouse(window.isKeyWindow && (bl_window_cursor_hidden() || bl_input_mouse_exclusive()));
    if (window.isKeyWindow) bl_gc_poll(captured);
    @autoreleasepool {
        NSEvent *e;
        while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode
                                         dequeue:YES])) {
            any = 1;
            switch (e.type) {
            case NSEventTypeKeyDown:
                if ((e.modifierFlags & NSEventModifierFlagCommand) &&
                    (e.keyCode == kVK_Return ||
                     (e.keyCode == kVK_ANSI_F && (e.modifierFlags & NSEventModifierFlagControl)))) {
                    if (!e.isARepeat) [window toggleFullScreen:nil];
                    continue;
                }
                if (e.modifierFlags & NSEventModifierFlagCommand) break;  // Cmd+Q etc. go to AppKit
                key(e.keyCode, 1, e.isARepeat, e.characters);
                bl_input_tick((uint32_t)(e.timestamp * 1000));
                continue;  // the game handles keys; AppKit would beep
            case NSEventTypeKeyUp:
                key(e.keyCode, 0, 0, nil);
                continue;
            case NSEventTypeFlagsChanged:
                modifiers(e);
                break;
            case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged:
            case NSEventTypeOtherMouseDragged: case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp:
            case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp: case NSEventTypeOtherMouseDown:
            case NSEventTypeOtherMouseUp: case NSEventTypeScrollWheel:
                if (captured || (e.window == window && mouse_for_game(e))) mouse(e);
                break;
            default: break;
            }
            [NSApp sendEvent:e];
        }
    }
    return any;
}
