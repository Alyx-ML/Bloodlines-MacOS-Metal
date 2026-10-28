// Drawing for the gothic menus (bl_menu.c, the pause menu; bl_options.c, the options
// dialog), through a vgui surface: Cinzel text, letter-spaced, fills, gradient hairlines,
// diamonds and the blood drop. `s` is the surface (client and GameUI each hold the same
// one); colours are 0-255 with alpha 0-1.
#ifndef BL_GOTHIC_H
#define BL_GOTHIC_H

#include <stdint.h>

uint32_t gothic_field(uint32_t a, uint32_t off);
float gothic_ffield(uint32_t a, uint32_t off);
uint32_t gothic_call(void *cpu, uint32_t fn, uint32_t self, int n, const uint32_t *a);  // thiscall when self
uint32_t gothic_scall(void *cpu, uint32_t s, uint32_t slot, int n, const uint32_t *a);  // a surface method
double gothic_clamp01(double v);

void gothic_color(void *cpu, uint32_t s, int r, int g, int b, double a);
void gothic_rect(void *cpu, uint32_t s, int x0, int y0, int x1, int y1);
void gothic_screen(void *cpu, uint32_t s, int *w, int *h);

// A face whose em is `em` pixels; vgui's tall is the cell, gothic_face_tall(face, em).
// GOTHIC_CAPS is Cinzel, GOTHIC_BODY Cormorant Garamond; gothic_font and gothic_tall are
// Cinzel's.
enum { GOTHIC_CAPS, GOTHIC_BODY };
uint32_t gothic_face_font(void *cpu, uint32_t s, int face, double em);
int gothic_face_tall(int face, double em);
uint32_t gothic_font(void *cpu, uint32_t s, double em);
// `face` at the height of the game's `font`.
uint32_t gothic_like_font(void *cpu, uint32_t s, int face, uint32_t font);
int gothic_tall(double em);
// Text from x, y (the top of the cell), `track` pixels between letters.
void gothic_text(void *cpu, uint32_t s, uint32_t font, const char *str, int x, int y, int track, int r, int g, int b,
                 double a);
int gothic_text_width(void *cpu, uint32_t s, uint32_t font, const char *str, int track);
void gothic_caps(const char *in, char *out, int size);

// A 1-pixel line from x0 to x1 whose colour runs through `n` stops {place 0-1, r, g, b, a}.
void gothic_line(void *cpu, uint32_t s, int x0, int x1, int y, const float (*stops)[5], int n, double fade);
// A diamond outline (half-diagonal r) and a filled dot of radius r.
void gothic_diamond(void *cpu, uint32_t s, int cx, int cy, int r, int cr, int cg, int cb, double a);
void gothic_dot(void *cpu, uint32_t s, int cx, int cy, int r, int cr, int cg, int cb, double a);
// A blood drop w wide and h tall, its point at the top.
void gothic_drop(void *cpu, uint32_t s, int cx, int top, int w, int h, double a);

// The game's 2D draws may still wait in the material system's buffer until the material
// changes: a dot of text and a dot of fill, two materials, push them out first, so what
// the renderer draws next goes over them.
void gothic_flush(void *cpu, uint32_t s);

// The renderer's backdrop (d3d9/metal_render.m): the last world view when `world`, under
// the darkening overlay `style` (0 the pause menu, 1 the options dialog, 2 none: the
// start-up menu) with a red glow behind each of `n` boxes (in pixels of the sw x sh
// screen), drawn now over everything so far. Its frames stay full width.
void bl_metal_backdrop(int style, int world, const int (*glows)[4], int n, int sw, int sh);

// An image of the HUD's (bl_hud.c), `slot` 0 or 1: w x h pixels of premultiplied BGRA,
// drawn now on the back buffer at x, y of the sw x sh screen, as the game's HUD is.
// `version` (from 1) changes when the pixels do.
void bl_metal_hud_image(int slot, const void *bgra, uint32_t w, uint32_t h, int x, int y, int sw, int sh,
                        unsigned long version);

// Whether a level is loaded, from the client's menu (bl_menu.c).
int bl_menu_in_level(void *cpu);

#endif
