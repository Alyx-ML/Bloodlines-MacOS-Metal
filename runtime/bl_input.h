// Keyboard and mouse events from the window layer, delivered to DirectInput devices
// (runtime/d3d9/dinput8.c).
#pragma once
#include <stdint.h>

void bl_input_key(int dik, int down);  // DIK_* scan code
void bl_input_mouse_move(int dx, int dy);
void bl_input_mouse_wheel(int dz);     // WHEEL_DELTA (120) per notch
void bl_input_mouse_button(int button, int down);
void bl_input_tick(uint32_t ms);       // timestamp for the events that follow
int bl_input_mouse_exclusive(void);   // the game holds the mouse exclusively right now
int bl_input_trace(void);             // BL_INPUT_TRACE is set
void bl_input_vk(int vk, int down);   // Windows virtual key state for GetKeyState (bl_user32.c)
