// user32 window manager: window classes, windows with their window procedures and long
// values, one message queue, focus/capture/cursor state. Windows are bookkeeping only;
// with BL_WINDOW the renderer shows the D3D device window as an NSWindow, whose input
// bl_cocoa.m posts to the queue from the message pumps below. Messages reach window
// procedures only through SendMessage/DispatchMessage/CallWindowProc, as on Windows;
// the system itself generates WM_NCCREATE/WM_CREATE, WM_SIZE on resizes and
// WM_DESTROY/WM_NCDESTROY.
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#include "bl_cocoa.h"
#include "bl_input.h"
#include "bl_win32.h"

#define U32(addr) (*(uint32_t *)bl_g2h(addr))

enum {
    WM_CREATE = 0x01, WM_DESTROY = 0x02, WM_MOVE = 0x03, WM_SIZE = 0x05, WM_CLOSE = 0x10, WM_QUIT = 0x12,
    WM_ERASEBKGND = 0x14, WM_NCCREATE = 0x81, WM_NCDESTROY = 0x82,
};

// The desktop: the Mac display's size in pixels.
static uint32_t screen_dim(int which)
{
    uint32_t w, h;
    bl_screen_size(&w, &h);
    return which ? h : w;
}
#define SCREEN_W ((int32_t)screen_dim(0))
#define SCREEN_H ((int32_t)screen_dim(1))
#define DESKTOP_WINDOW 0x10010u
#define CW_USEDEFAULT 0x80000000u
#define WS_VISIBLE 0x10000000u

struct wclass {
    char name[64];
    uint32_t atom, style, wndproc, cls_extra, wnd_extra, instance, icon, cursor, background;
};

#define MAX_EXTRA 64
struct window {
    int used, visible;
    uint32_t wndproc, style, exstyle, parent, id, instance, userdata;
    int32_t x, y, w, h;
    char text[256];
    struct wclass *cls;
    uint8_t extra[MAX_EXTRA];
};

#define MAX_CLASSES 64
#define MAX_WINDOWS 256
#define WINDOW_BASE 0x10020u
static struct wclass classes[MAX_CLASSES];
static int nclasses;
static struct window windows[MAX_WINDOWS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t focus, active, capture, cursor;
static int32_t cursor_x = 512, cursor_y = 384;

static struct window *get(uint32_t h)
{
    uint32_t i = (h - WINDOW_BASE) / 4;
    if (h < WINDOW_BASE || (h - WINDOW_BASE) % 4 || i >= MAX_WINDOWS || !windows[i].used) return NULL;
    return &windows[i];
}

static uint32_t handle_of(struct window *w) { return WINDOW_BASE + 4 * (uint32_t)(w - windows); }

uint32_t bl_u32_DestroyWindow_c(uint32_t h);

static uint32_t now_ms(void) { return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000); }

static uint32_t call_wndproc(uint32_t proc, uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp)
{
    if (!proc) return 0;
    uint32_t args[4] = { h, msg, wp, lp };
    return bl_call_guest(bl_thread_cpu, proc, BL_STDCALL, 0, 4, args);
}

uint32_t bl_u32_SendMessageA_c(uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp)
{
    struct window *w = get(h);
    return w ? call_wndproc(w->wndproc, h, msg, wp, lp) : 0;
}

uint32_t bl_u32_CallWindowProcA_c(uint32_t proc, uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp)
{
    return call_wndproc(proc, h, msg, wp, lp);
}

// Classes

static struct wclass *find_class(uint32_t name)
{
    for (int i = 0; i < nclasses; i++) {
        if (name < 0x10000 ? classes[i].atom == name : !strcasecmp(classes[i].name, bl_g2h(name))) return &classes[i];
    }
    return NULL;
}

uint32_t bl_u32_RegisterClassA_c(uint32_t wc)
{
    const uint32_t *f = bl_g2h(wc);  // WNDCLASSA
    pthread_mutex_lock(&lock);
    uint32_t atom = 0;
    if (nclasses < MAX_CLASSES && f[9] && !find_class(f[9])) {
        struct wclass *c = &classes[nclasses++];
        memset(c, 0, sizeof *c);
        c->atom = 0xC000 + (uint32_t)nclasses;
        c->style = f[0], c->wndproc = f[1], c->cls_extra = f[2], c->wnd_extra = f[3], c->instance = f[4];
        c->icon = f[5], c->cursor = f[6], c->background = f[7];
        if (f[9] < 0x10000)
            snprintf(c->name, sizeof c->name, "#%u", f[9]);
        else
            snprintf(c->name, sizeof c->name, "%s", (const char *)bl_g2h(f[9]));
        atom = c->atom;
    }
    pthread_mutex_unlock(&lock);
    if (!atom) bl_set_last_error(1410);  // ERROR_CLASS_ALREADY_EXISTS
    return atom;
}

uint32_t bl_u32_UnregisterClassA_c(uint32_t name, uint32_t inst)
{
    (void)inst;
    pthread_mutex_lock(&lock);
    struct wclass *c = find_class(name);
    if (c) c->name[0] = 0, c->atom = 0;
    pthread_mutex_unlock(&lock);
    return c != NULL;
}

uint32_t bl_u32_GetClassNameA_c(uint32_t h, uint32_t buf, uint32_t n)
{
    struct window *w = get(h);
    if (!w || !n) return 0;
    snprintf(bl_g2h(buf), n, "%s", w->cls->name);
    return (uint32_t)strlen(bl_g2h(buf));
}

uint32_t bl_u32_GetClassLongA_c(uint32_t h, uint32_t index)
{
    struct window *w = get(h);
    if (!w) return 0;
    switch ((int32_t)index) {
    case -24: return w->cls->wndproc;   // GCL_WNDPROC
    case -26: return w->cls->style;     // GCL_STYLE
    case -12: return w->cls->cursor;    // GCL_HCURSOR
    case -14: return w->cls->icon;      // GCL_HICON
    case -10: return w->cls->background;
    case -32: return w->cls->atom;      // GCW_ATOM
    default: return 0;
    }
}

// Windows

uint32_t bl_u32_CreateWindowExA_c(uint32_t exstyle, uint32_t cls_name, uint32_t name, uint32_t style, uint32_t x,
                                  uint32_t y, uint32_t cx, uint32_t cy, uint32_t parent, uint32_t menu, uint32_t inst,
                                  uint32_t param)
{
    pthread_mutex_lock(&lock);
    struct wclass *c = find_class(cls_name);
    struct window *w = NULL;
    for (int i = 0; c && i < MAX_WINDOWS && !w; i++)
        if (!windows[i].used) w = &windows[i];
    if (w) {
        memset(w, 0, sizeof *w);
        w->used = 1;
        w->cls = c;
        w->wndproc = c->wndproc, w->style = style, w->exstyle = exstyle, w->parent = parent;
        w->id = menu, w->instance = inst;
        w->x = x == CW_USEDEFAULT ? 0 : (int32_t)x;
        w->y = x == CW_USEDEFAULT ? 0 : (int32_t)y;
        w->w = cx == CW_USEDEFAULT ? 640 : (int32_t)cx;
        w->h = cx == CW_USEDEFAULT ? 480 : (int32_t)cy;
        if (name) snprintf(w->text, sizeof w->text, "%s", (const char *)bl_g2h(name));
    }
    pthread_mutex_unlock(&lock);
    if (!c) {
        fprintf(stderr, "[user32] CreateWindowExA: unknown class\n");
        bl_set_last_error(1407);  // ERROR_CANNOT_FIND_WND_CLASS
        return 0;
    }
    if (!w) bl_fatal("CreateWindowExA: window table full");
    uint32_t h = handle_of(w);

    uint32_t cs = bl_guest_malloc(48);  // CREATESTRUCTA
    uint32_t *f = bl_g2h(cs);
    f[0] = param, f[1] = inst, f[2] = menu, f[3] = parent;
    f[4] = (uint32_t)w->h, f[5] = (uint32_t)w->w, f[6] = (uint32_t)w->y, f[7] = (uint32_t)w->x;
    f[8] = style, f[9] = name, f[10] = cls_name, f[11] = exstyle;
    int ok = call_wndproc(w->wndproc, h, WM_NCCREATE, 0, cs) != 0 &&
             call_wndproc(w->wndproc, h, WM_CREATE, 0, cs) != 0xffffffffu;
    bl_guest_free(cs);
    if (!ok) {
        bl_u32_DestroyWindow_c(h);
        return 0;
    }
    if (style & WS_VISIBLE) w->visible = 1;
    return h;
}

uint32_t bl_u32_DestroyWindow_c(uint32_t h)
{
    struct window *w = get(h);
    if (!w) return 0;
    call_wndproc(w->wndproc, h, WM_DESTROY, 0, 0);
    call_wndproc(w->wndproc, h, WM_NCDESTROY, 0, 0);
    pthread_mutex_lock(&lock);
    w->used = 0;
    if (focus == h) focus = 0;
    if (active == h) active = 0;
    if (capture == h) capture = 0;
    pthread_mutex_unlock(&lock);
    return 1;
}

uint32_t bl_u32_DefWindowProcA_c(uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp)
{
    (void)wp, (void)lp;
    switch (msg) {
    case WM_NCCREATE: return 1;
    case WM_CLOSE: bl_u32_DestroyWindow_c(h); return 0;
    case WM_ERASEBKGND: return 1;
    default: return 0;
    }
}

uint32_t bl_u32_IsWindow_c(uint32_t h) { return get(h) != NULL; }
uint32_t bl_u32_IsWindowVisible_c(uint32_t h) { struct window *w = get(h); return w && w->visible; }
uint32_t bl_u32_IsIconic_c(uint32_t h) { (void)h; return 0; }
uint32_t bl_u32_GetDesktopWindow_c(void) { return DESKTOP_WINDOW; }
uint32_t bl_u32_GetParent_c(uint32_t h) { struct window *w = get(h); return w ? w->parent : 0; }

uint32_t bl_u32_SetParent_c(uint32_t h, uint32_t parent)
{
    struct window *w = get(h);
    if (!w) return 0;
    uint32_t old = w->parent;
    w->parent = parent;
    return old ? old : DESKTOP_WINDOW;
}

uint32_t bl_u32_ShowWindow_c(uint32_t h, uint32_t cmd)
{
    struct window *w = get(h);
    if (!w) return 0;
    int was = w->visible;
    w->visible = cmd != 0;  // SW_HIDE
    return (uint32_t)was;
}

static void set_rect(uint32_t h, struct window *w, int32_t x, int32_t y, int32_t cx, int32_t cy)
{
    int moved = x != w->x || y != w->y, sized = cx != w->w || cy != w->h;
    w->x = x, w->y = y, w->w = cx, w->h = cy;
    if (moved) call_wndproc(w->wndproc, h, WM_MOVE, 0, ((uint32_t)y << 16) | ((uint32_t)x & 0xffff));
    if (sized) call_wndproc(w->wndproc, h, WM_SIZE, 0, ((uint32_t)cy << 16) | ((uint32_t)cx & 0xffff));
}

uint32_t bl_u32_SetWindowPos_c(uint32_t h, uint32_t after, uint32_t x, uint32_t y, uint32_t cx, uint32_t cy,
                               uint32_t flags)
{
    (void)after;
    struct window *w = get(h);
    if (!w) return h == DESKTOP_WINDOW;
    int32_t nx = flags & 2 ? w->x : (int32_t)x, ny = flags & 2 ? w->y : (int32_t)y;  // SWP_NOMOVE
    int32_t ncx = flags & 1 ? w->w : (int32_t)cx, ncy = flags & 1 ? w->h : (int32_t)cy;  // SWP_NOSIZE
    set_rect(h, w, nx, ny, ncx, ncy);
    if (flags & 0x40) w->visible = 1;  // SWP_SHOWWINDOW
    if (flags & 0x80) w->visible = 0;  // SWP_HIDEWINDOW
    return 1;
}

uint32_t bl_u32_MoveWindow_c(uint32_t h, uint32_t x, uint32_t y, uint32_t cx, uint32_t cy, uint32_t repaint)
{
    (void)repaint;
    struct window *w = get(h);
    if (!w) return 0;
    set_rect(h, w, (int32_t)x, (int32_t)y, (int32_t)cx, (int32_t)cy);
    return 1;
}

static void write_rect(uint32_t rect, int32_t l, int32_t t, int32_t r, int32_t b)
{
    int32_t v[4] = { l, t, r, b };
    memcpy(bl_g2h(rect), v, sizeof v);
}

uint32_t bl_u32_GetWindowRect_c(uint32_t h, uint32_t rect)
{
    struct window *w = get(h);
    if (!w) {
        if (h != DESKTOP_WINDOW) return 0;
        write_rect(rect, 0, 0, SCREEN_W, SCREEN_H);
        return 1;
    }
    write_rect(rect, w->x, w->y, w->x + w->w, w->y + w->h);
    return 1;
}

uint32_t bl_u32_GetClientRect_c(uint32_t h, uint32_t rect)
{
    struct window *w = get(h);
    if (!w) {
        if (h != DESKTOP_WINDOW) return 0;
        write_rect(rect, 0, 0, SCREEN_W, SCREEN_H);
        return 1;
    }
    write_rect(rect, 0, 0, w->w, w->h);  // windows have no frame here
    return 1;
}

uint32_t bl_u32_AdjustWindowRectEx_c(uint32_t rect, uint32_t style, uint32_t menu, uint32_t exstyle)
{
    (void)rect, (void)style, (void)menu, (void)exstyle;  // no frame: client rect == window rect
    return 1;
}

uint32_t bl_u32_ClientToScreen_c(uint32_t h, uint32_t pt)
{
    struct window *w = get(h);
    if (w) U32(pt) += (uint32_t)w->x, U32(pt + 4) += (uint32_t)w->y;
    return 1;
}

uint32_t bl_u32_ScreenToClient_c(uint32_t h, uint32_t pt)
{
    struct window *w = get(h);
    if (w) U32(pt) -= (uint32_t)w->x, U32(pt + 4) -= (uint32_t)w->y;
    return 1;
}

uint32_t bl_u32_GetWindowLongA_c(uint32_t h, uint32_t index)
{
    struct window *w = get(h);
    if (!w) return 0;
    switch ((int32_t)index) {
    case -4: return w->wndproc;
    case -6: return w->instance;
    case -8: return w->parent;
    case -12: return w->id;
    case -16: return w->style | (w->visible ? WS_VISIBLE : 0);
    case -20: return w->exstyle;
    case -21: return w->userdata;
    default:
        if ((int32_t)index >= 0 && index <= MAX_EXTRA - 4) {  // the window's extra bytes
            uint32_t v;
            memcpy(&v, w->extra + index, 4);
            return v;
        }
        return 0;
    }
}

uint32_t bl_u32_SetWindowLongA_c(uint32_t h, uint32_t index, uint32_t value)
{
    struct window *w = get(h);
    if (!w) return 0;
    uint32_t old = bl_u32_GetWindowLongA_c(h, index);
    switch ((int32_t)index) {
    case -4: w->wndproc = value; break;
    case -6: w->instance = value; break;
    case -8: w->parent = value; break;
    case -12: w->id = value; break;
    case -16: w->style = value & ~WS_VISIBLE; w->visible = (value & WS_VISIBLE) != 0; break;
    case -20: w->exstyle = value; break;
    case -21: w->userdata = value; break;
    default:
        if ((int32_t)index >= 0 && index <= MAX_EXTRA - 4) memcpy(w->extra + index, &value, 4);
        break;
    }
    return old;
}

uint32_t bl_u32_SetWindowTextA_c(uint32_t h, uint32_t text)
{
    struct window *w = get(h);
    if (!w) return 0;
    snprintf(w->text, sizeof w->text, "%s", text ? (const char *)bl_g2h(text) : "");
    return 1;
}

uint32_t bl_u32_GetWindowTextA_c(uint32_t h, uint32_t buf, uint32_t n)
{
    struct window *w = get(h);
    if (!n) return 0;
    snprintf(bl_g2h(buf), n, "%s", w ? w->text : "");
    return (uint32_t)strlen(bl_g2h(buf));
}

uint32_t bl_u32_FindWindowA_c(uint32_t cls, uint32_t name)
{
    pthread_mutex_lock(&lock);
    uint32_t found = 0;
    for (int i = 0; i < MAX_WINDOWS && !found; i++) {
        struct window *w = &windows[i];
        if (!w->used) continue;
        if (cls && (cls < 0x10000 ? w->cls->atom != cls : strcasecmp(w->cls->name, bl_g2h(cls)))) continue;
        if (name && strcmp(w->text, bl_g2h(name))) continue;
        found = handle_of(w);
    }
    pthread_mutex_unlock(&lock);
    return found;
}

uint32_t bl_u32_GetTopWindow_c(uint32_t h) { (void)h; return 0; }
uint32_t bl_u32_GetWindow_c(uint32_t h, uint32_t cmd) { (void)h, (void)cmd; return 0; }
uint32_t bl_u32_EnumChildWindows_c(uint32_t h, uint32_t fn, uint32_t p) { (void)h, (void)fn, (void)p; return 1; }
uint32_t bl_u32_WindowFromPoint_c(uint32_t x, uint32_t y) { (void)x, (void)y; return 0; }
uint32_t bl_u32_FlashWindow_c(uint32_t h, uint32_t invert) { (void)h, (void)invert; return 0; }

// Focus, activation, capture, cursor

uint32_t bl_u32_SetFocus_c(uint32_t h) { uint32_t old = focus; focus = h; return old; }
uint32_t bl_u32_GetFocus_c(void) { return focus; }
uint32_t bl_u32_SetActiveWindow_c(uint32_t h) { uint32_t old = active; active = h; return old; }
uint32_t bl_u32_GetActiveWindow_c(void) { return active; }
uint32_t bl_u32_SetForegroundWindow_c(uint32_t h) { active = h; return 1; }
uint32_t bl_u32_GetForegroundWindow_c(void) { return active; }
uint32_t bl_u32_SetCapture_c(uint32_t h) { uint32_t old = capture; capture = h; return old; }
uint32_t bl_u32_ReleaseCapture_c(void) { capture = 0; return 1; }
// The cursor counts as hidden after SetCursor(NULL) (before the first SetCursor it is the
// class cursor) or while the ShowCursor count is negative. The window layer then captures
// the mouse and moves the cursor position by relative motion only, so the game's
// recentring with SetCursorPos gives it the deltas it expects.
static int cursor_set, show_count;

uint32_t bl_u32_SetCursor_c(uint32_t c)
{
    uint32_t old = cursor;
    if (bl_input_trace() && (!cursor_set || !c != !cursor)) fprintf(stderr, "[input] SetCursor %#x\n", c);
    cursor = c, cursor_set = 1;
    return old;
}

uint32_t bl_u32_ShowCursor_c(uint32_t show)
{
    show_count += show ? 1 : -1;
    if (bl_input_trace()) fprintf(stderr, "[input] ShowCursor(%u): count %d\n", show, show_count);
    return (uint32_t)show_count;
}

int bl_window_cursor_hidden(void) { return show_count < 0 || (cursor_set && !cursor); }

uint32_t bl_u32_SetCursorPos_c(uint32_t x, uint32_t y)
{
    static unsigned n;
    if (bl_input_trace() && !(n++ & 255)) fprintf(stderr, "[input] SetCursorPos %d,%d (call %u)\n", x, y, n);
    cursor_x = (int32_t)x, cursor_y = (int32_t)y;
    return 1;
}

uint32_t bl_u32_GetCursorPos_c(uint32_t pt)
{
    U32(pt) = (uint32_t)cursor_x;
    U32(pt + 4) = (uint32_t)cursor_y;
    return 1;
}

// Painting: there is no surface; device contexts are tokens.

uint32_t bl_u32_GetDC_c(uint32_t h) { return 0x40000 + (h & 0xffff); }
uint32_t bl_u32_ReleaseDC_c(uint32_t h, uint32_t dc) { (void)h, (void)dc; return 1; }

uint32_t bl_u32_BeginPaint_c(uint32_t h, uint32_t ps)
{
    memset(bl_g2h(ps), 0, 64);  // PAINTSTRUCT
    U32(ps) = bl_u32_GetDC_c(h);
    return U32(ps);
}

uint32_t bl_u32_EndPaint_c(uint32_t h, uint32_t ps) { (void)h, (void)ps; return 1; }
uint32_t bl_u32_InvalidateRect_c(uint32_t h, uint32_t r, uint32_t erase) { (void)h, (void)r, (void)erase; return 1; }
uint32_t bl_u32_ValidateRect_c(uint32_t h, uint32_t r) { (void)h, (void)r; return 1; }
uint32_t bl_u32_RedrawWindow_c(uint32_t h, uint32_t r, uint32_t rgn, uint32_t f) { (void)h, (void)r, (void)rgn, (void)f; return 1; }
uint32_t bl_u32_FillRect_c(uint32_t dc, uint32_t r, uint32_t brush) { (void)dc, (void)r, (void)brush; return 1; }
uint32_t bl_u32_DrawTextA_c(uint32_t dc, uint32_t s, uint32_t n, uint32_t r, uint32_t f) { (void)dc, (void)s, (void)n, (void)r, (void)f; return 0; }

uint32_t bl_u32_IntersectRect_c(uint32_t dst, uint32_t a, uint32_t b)
{
    int32_t ra[4], rb[4], r[4];
    memcpy(ra, bl_g2h(a), 16);
    memcpy(rb, bl_g2h(b), 16);
    r[0] = ra[0] > rb[0] ? ra[0] : rb[0];
    r[1] = ra[1] > rb[1] ? ra[1] : rb[1];
    r[2] = ra[2] < rb[2] ? ra[2] : rb[2];
    r[3] = ra[3] < rb[3] ? ra[3] : rb[3];
    int empty = r[0] >= r[2] || r[1] >= r[3];
    if (empty) memset(r, 0, sizeof r);
    memcpy(bl_g2h(dst), r, 16);
    return !empty;
}

// Message queue (one for the process; the game pumps it from its main thread).

struct msg { uint32_t hwnd, message, wparam, lparam, time, x, y; };
#define QUEUE_LEN 1024
static struct msg queue[QUEUE_LEN];
static int qhead, qcount;
static pthread_cond_t qcond = PTHREAD_COND_INITIALIZER;

uint32_t bl_u32_PostMessageA_c(uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp)
{
    pthread_mutex_lock(&lock);
    // Windows folds mouse moves into one pending WM_MOUSEMOVE; without that a fast mouse
    // fills the queue and later key messages are lost.
    if (msg == 0x200 && qcount) {
        struct msg *last = &queue[(qhead + qcount - 1) % QUEUE_LEN];
        if (last->message == 0x200 && last->hwnd == h) {
            *last = (struct msg){ h, msg, wp, lp, now_ms(), (uint32_t)cursor_x, (uint32_t)cursor_y };
            pthread_mutex_unlock(&lock);
            return 1;
        }
    }
    int ok = qcount < QUEUE_LEN;
    if (!ok && bl_input_trace()) fprintf(stderr, "[input] message queue full: %#x dropped\n", msg);
    if (ok) {
        queue[(qhead + qcount++) % QUEUE_LEN] =
            (struct msg){ h, msg, wp, lp, now_ms(), (uint32_t)cursor_x, (uint32_t)cursor_y };
        pthread_cond_broadcast(&qcond);
    }
    pthread_mutex_unlock(&lock);
    return ok;
}

// Index in the queue of the first message matching the filter, or -1. Lock held.
static int find_msg(uint32_t h, uint32_t lo, uint32_t hi)
{
    for (int i = 0; i < qcount; i++) {
        struct msg *m = &queue[(qhead + i) % QUEUE_LEN];
        if (h && m->hwnd != h) continue;
        if ((lo || hi) && (m->message < lo || m->message > hi)) continue;
        return i;
    }
    return -1;
}

static void take_msg(int i, uint32_t out, int remove)
{
    struct msg *m = &queue[(qhead + i) % QUEUE_LEN];
    memcpy(bl_g2h(out), m, sizeof *m);
    if (!remove) return;
    for (int k = i; k > 0; k--) queue[(qhead + k) % QUEUE_LEN] = queue[(qhead + k - 1) % QUEUE_LEN];
    qhead = (qhead + 1) % QUEUE_LEN;
    qcount--;
}

// Client size of a window (D3D9 sizes windowed back buffers from it); 0 if unknown.
int bl_window_client_size(uint32_t h, uint32_t *w, uint32_t *hgt)
{
    struct window *win = get(h);
    if (!win) return 0;
    *w = (uint32_t)win->w, *hgt = (uint32_t)win->h;
    return 1;
}

// The cursor is kept in screen coordinates, as GetCursorPos/SetCursorPos use them; the
// window layer works in client coordinates of window `h`.
void bl_window_set_cursor(uint32_t h, int32_t x, int32_t y)
{
    struct window *w = get(h);
    cursor_x = x + (w ? w->x : 0), cursor_y = y + (w ? w->y : 0);
}

void bl_window_get_cursor(uint32_t h, int32_t *x, int32_t *y)
{
    struct window *w = get(h);
    *x = cursor_x - (w ? w->x : 0), *y = cursor_y - (w ? w->y : 0);
}

// Relative motion while the mouse is captured, kept on the virtual screen.
void bl_window_move_cursor(int32_t dx, int32_t dy)
{
    cursor_x += dx, cursor_y += dy;
    cursor_x = cursor_x < 0 ? 0 : cursor_x >= SCREEN_W ? SCREEN_W - 1 : cursor_x;
    cursor_y = cursor_y < 0 ? 0 : cursor_y >= SCREEN_H ? SCREEN_H - 1 : cursor_y;
}

uint32_t bl_u32_PeekMessageA_c(uint32_t out, uint32_t h, uint32_t lo, uint32_t hi, uint32_t remove)
{
    bl_cocoa_pump();
    pthread_mutex_lock(&lock);
    int i = find_msg(h, lo, hi);
    if (i >= 0) take_msg(i, out, remove & 1);  // PM_REMOVE
    pthread_mutex_unlock(&lock);
    return i >= 0;
}

uint32_t bl_u32_GetMessageA_c(uint32_t out, uint32_t h, uint32_t lo, uint32_t hi)
{
    pthread_mutex_lock(&lock);
    int i;
    while ((i = find_msg(h, lo, hi)) < 0) {
        // With a window, wake every millisecond to pump AppKit events.
        pthread_mutex_unlock(&lock);
        int any = bl_cocoa_pump();
        pthread_mutex_lock(&lock);
        if (any || find_msg(h, lo, hi) >= 0) continue;
        struct timespec now, ts;
        clock_gettime(CLOCK_REALTIME, &now);
        ts = (struct timespec){ now.tv_sec, now.tv_nsec + 1000000 };
        if (ts.tv_nsec >= 1000000000) ts.tv_sec++, ts.tv_nsec -= 1000000000;
        pthread_cond_timedwait(&qcond, &lock, &ts);
    }
    take_msg(i, out, 1);
    pthread_mutex_unlock(&lock);
    return U32(out + 4) != WM_QUIT;
}

uint32_t bl_u32_TranslateMessage_c(uint32_t msg) { (void)msg; return 0; }  // no keyboard input yet

uint32_t bl_u32_DispatchMessageA_c(uint32_t msg)
{
    const uint32_t *m = bl_g2h(msg);
    return bl_u32_SendMessageA_c(m[0], m[1], m[2], m[3]);
}

// Waits on handles or for a posted message; QS_* masks are not distinguished.
uint32_t bl_k32_WaitForMultipleObjects_c(uint32_t n, uint32_t handles, uint32_t all, uint32_t ms);
uint32_t bl_u32_MsgWaitForMultipleObjects_c(uint32_t n, uint32_t handles, uint32_t all, uint32_t ms, uint32_t mask)
{
    (void)mask;
    uint32_t start = now_ms();
    for (;;) {
        bl_cocoa_pump();
        pthread_mutex_lock(&lock);
        int pending = qcount > 0;
        pthread_mutex_unlock(&lock);
        if (pending) return n;  // WAIT_OBJECT_0 + n: input available
        if (n) {
            uint32_t r = bl_k32_WaitForMultipleObjects_c(n, handles, all, 0);
            if (r != 258) return r;
        }
        if (ms != 0xffffffffu && now_ms() - start >= ms) return 258;  // WAIT_TIMEOUT
        struct timespec ts = { 0, 1000000 };
        nanosleep(&ts, NULL);
    }
}

// Registered messages, timers

static char registered[64][64];
static int nregistered;

uint32_t bl_u32_RegisterWindowMessageA_c(uint32_t name)
{
    pthread_mutex_lock(&lock);
    int i;
    for (i = 0; i < nregistered; i++)
        if (!strcasecmp(registered[i], bl_g2h(name))) break;
    if (i == nregistered && nregistered < 64) snprintf(registered[nregistered++], 64, "%s", (const char *)bl_g2h(name));
    pthread_mutex_unlock(&lock);
    return i < 64 ? 0xC100u + (uint32_t)i : 0;
}

// Timers are accepted but never fire (no WM_TIMER yet).
static uint32_t next_timer = 1;
uint32_t bl_u32_SetTimer_c(uint32_t h, uint32_t id, uint32_t ms, uint32_t fn)
{
    (void)ms, (void)fn;
    return h ? id : next_timer++;
}

uint32_t bl_u32_KillTimer_c(uint32_t h, uint32_t id) { (void)h, (void)id; return 1; }

// Display settings and resources

uint32_t bl_u32_ChangeDisplaySettingsA_c(uint32_t mode, uint32_t flags) { (void)mode, (void)flags; return 0; }

uint32_t bl_u32_SystemParametersInfoA_c(uint32_t action, uint32_t ui, uint32_t pv, uint32_t ini)
{
    (void)ui, (void)ini;
    if (action == 0x30 && pv) write_rect(pv, 0, 0, SCREEN_W, SCREEN_H);  // SPI_GETWORKAREA
    return 1;
}

uint32_t bl_u32_LoadStringA_c(uint32_t inst, uint32_t id, uint32_t buf, uint32_t n)
{
    (void)inst, (void)id;
    if (n) *(char *)bl_g2h(buf) = 0;
    return 0;
}

static uint32_t next_resource = 0x50000;
uint32_t bl_u32_LoadImageA_c(uint32_t inst, uint32_t name, uint32_t type, uint32_t cx, uint32_t cy, uint32_t f)
{
    (void)inst, (void)name, (void)type, (void)cx, (void)cy, (void)f;
    return next_resource += 4;
}

uint32_t bl_u32_CreateIconIndirect_c(uint32_t info) { (void)info; return next_resource += 4; }

// Clipboard: unavailable.
uint32_t bl_u32_OpenClipboard_c(uint32_t h) { (void)h; return 0; }
uint32_t bl_u32_CloseClipboard_c(void) { return 1; }
uint32_t bl_u32_EmptyClipboard_c(void) { return 0; }
uint32_t bl_u32_GetClipboardData_c(uint32_t fmt) { (void)fmt; return 0; }
uint32_t bl_u32_SetClipboardData_c(uint32_t fmt, uint32_t h) { (void)fmt, (void)h; return 0; }
