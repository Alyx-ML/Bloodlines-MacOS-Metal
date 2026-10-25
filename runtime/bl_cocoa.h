// The game's window on macOS: an NSWindow with a CAMetalLayer, and the AppKit event
// pump that turns keyboard and mouse events into window messages and DirectInput
// data (bl_cocoa.m). Without BL_WINDOW the runtime stays headless and the pump is a
// no-op.
#pragma once
#include <stdint.h>

#ifdef __OBJC__
@class CAMetalLayer;
// Opens the window for the game window `hwnd`; returns its layer (NULL on failure).
CAMetalLayer *bl_cocoa_open_window(uint32_t width, uint32_t height, const char *title, uint32_t hwnd);
#endif

void bl_cocoa_set_content_size(uint32_t width, uint32_t height);
// Handles pending AppKit events; returns nonzero if any arrived. Main thread only.
int bl_cocoa_pump(void);
void bl_cocoa_pump_if_idle(void);  // main thread, at most every 100 ms
// Mouse-look: hide the cursor and report only relative motion while on.
void bl_cocoa_capture_mouse(int on);
void bl_cocoa_set_fullscreen(int on);
// The game image drawn narrowed to this share of its width about the centre (menus at
// 4:3 on a wider mode; 1 = full width): mouse positions are mapped to match.
void bl_cocoa_set_squeeze(float squeeze);
int bl_cocoa_refresh_rate(void);  // the window's screen, in Hz (0 = no window)
float bl_cocoa_edr_headroom(void);  // how far above normal white the window's screen can show now (1 = none)
// Synthetic input from bl_gamecontroller.m: a key by Mac key code, a mouse button
// (0 left, 1 right, 2 middle), a wheel step (120 = one notch up) and relative motion.
void bl_cocoa_key(uint16_t mac, int down);
void bl_cocoa_button(int b, int down);
void bl_cocoa_wheel(int dz);
void bl_cocoa_motion(int dx, int dy);
void bl_cocoa_script_input(unsigned long frame, uint32_t hwnd);  // BL_CLICKS
