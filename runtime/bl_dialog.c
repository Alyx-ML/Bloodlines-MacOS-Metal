// The dialogue screen in the gothic style of the menus (bl_menu.c, bl_options.c), to the
// approved mockup (1920x1080 pixels, scaled to the screen's height): over a dark fade at the
// bottom of the screen, the character's line in Cormorant Garamond, and under it the
// answers, numbered in small gold Cinzel figures, a social skill or discipline answer
// marked with its name in spaced gold capitals. The chosen answer is bright, with the blood
// drop and the red-to-gold underline: the first at the start, the one the mouse moves onto,
// or one the up and down arrows (a gamepad's d-pad or left stick, bl_gamecontroller.m) step
// to; a click, Enter (the pad's A) or its number key picks it. No name, frame or box.
//
// The client's CHudDialog keeps doing all the work: the lines, the answers, the number keys,
// the fades and the history. Hooks in client (modules/client/instruction_replacements
// .manual.sci) change its look:
//   - CHudDialog::Paint, after its checks (0x100535A7): bl_dialog_Paint draws the screen,
//     then the game's ComputeSizes runs as before and its frame, box and text are left out;
//   - ComputeSizes' SetPos and SetSize (0x100531D8, 0x100531ED): the panel covers the
//     screen, so nothing is clipped to the game's box;
//   - CHudDialog::Key_Event, after its first instruction (0x10055265): bl_dialog_Key takes
//     the click, the arrows and Enter. The game's click shows or hides the line; here the
//     line always shows, as the game's own flag starts each conversation hidden.
//
// CHudDialog fields: +0x178 the history (8-byte entries: a kind and the text; 0 the
// character's current line, 2 the character's older ones, 3 the player's answers, each line
// cut to the game's box width), +0x184 its count, +0x18c how far it is scrolled back, +0x190
// "lay out again", +0x1a4, +0x1a8 and +0x1ac the box's, the answers' and the line's fades
// (0 to 192; the box's is the larger of the others), +0x1b1 answers shown, +0x1b3 only the picked answer shown (+0x1bc its number,
// +0x1c0 its text, +0x9c0 and +0x9c4 its kind), +0x1228 the answer count (up to 4), +0x122c
// their texts (0x800 bytes each), +0x322c and +0x323c their kinds: bit 2 a social skill (7
// Persuasion, 6 Intimidation, 8 Seduction), bit 1 a discipline (6 Dominate, else Dementation).
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "bl_gothic.h"
#include "bl_vm.h"
#include "llasm_cpu.h"

extern char client_Surface[], client_DialogPick[], GameUI_Input[];
int bl_window_cursor_hidden(void);

#define field gothic_field

enum { IN_CURSOR_POS = 0x6c, MAX_ANSWERS = 4 };
// The engine's key numbers.
enum { K_ENTER = 13, K_UP = 128, K_DOWN = 129, K_KP_UP = 161, K_KP_DOWN = 167, K_KP_ENTER = 169, MOUSE1 = 0xf1 };

// The mockup, in its pixels: the block 160 from the left and 96 from the bottom, 1180 wide;
// the line (33-pixel Cormorant, 1.32 apart) 40 above the answers; each answer (27-pixel,
// 1.25 apart) 8 and 10 inside its row, its number (15-pixel Cinzel) 44 in, its text 82 in
// after its skill (13-pixel Cinzel, 12 after); the fade 620 tall.
enum { LEFT = 160, BOTTOM = 96, WIDTH = 1180, LINE_EM = 33, LINE_GAP = 40, ANSWER_EM = 27, ROW_TOP = 8,
       ROW_BOTTOM = 10, NUM_X = 44, NUM_EM = 15, TEXT_X = 82, FEAT_EM = 13, FEAT_GAP = 12, UNDERLINE_W = 520,
       SHADE_H = 620 };

static const int IVORY[3] = { 236, 226, 207 }, GOLD[3] = { 176, 143, 88 }, GOLD_HI[3] = { 230, 201, 143 },
                 MUTED[3] = { 166, 153, 132 };

static uint32_t buf;                    // guest scratch for the cursor position
static int screen_w, screen_h;
static int rows[MAX_ANSWERS][4], nrows;  // the answers' rows on screen, for the mouse
static uint32_t row_answer[MAX_ANSWERS];
static int chosen, last_x = -1, last_y = -1;  // the bright answer; where the mouse was
static uint32_t answers_seen;                // which answers are up, to start again at the first
static volatile uint64_t asking_ns;          // when answers to choose were last painted
static volatile uint64_t talking_ns;         // when the screen was last painted with its fade up

static uint32_t surface(void *cpu) { return gothic_call(cpu, bl_h2g(client_Surface), 0, 0, NULL); }
static double unit(void) { return screen_h / 1080.0; }
static int px(double v) { return (int)lround(v * unit()); }
static uint8_t byte_at(uint32_t a) { return *(const uint8_t *)bl_g2h(a); }
static float float_at(uint32_t a) { return *(const float *)bl_g2h(a); }

// The game's text is Windows-1252: its quotes and dashes, which the fonts' 0-255 range
// lacks, become plain ones.
static int add_text(char *out, int n, int size, const char *t)
{
    for (; *t && n < size - 4; t++) {
        uint8_t c = (uint8_t)*t;
        const char *r = c == 0x91 || c == 0x92 ? "'" : c == 0x93 || c == 0x94 ? "\"" : c == 0x96 || c == 0x97 ? "-"
                      : c == 0x85                ? "..."
                      : c == '\n' || c == '\r'   ? " "
                                                 : NULL;
        if (r) {
            while (*r) out[n++] = *r++;
        } else {
            out[n++] = (char)c;
        }
    }
    out[n] = 0;
    return n;
}

// Words wrapped to `width`, into up to `max` lines.
static int wrap(void *cpu, uint32_t s, uint32_t font, const char *t, int width, char lines[][256], int max)
{
    int n = 0;
    char line[256] = "";
    while (*t && n < max) {
        while (*t == ' ') t++;
        const char *e = t;
        while (*e && *e != ' ') e++;
        if (e == t) break;
        char trial[512];
        int wl = (int)(e - t) < 200 ? (int)(e - t) : 200;
        snprintf(trial, sizeof trial, "%s%s%.*s", line, line[0] ? " " : "", wl, t);
        if (line[0] && gothic_text_width(cpu, s, font, trial, 0) > width) {
            strcpy(lines[n++], line);
            snprintf(line, sizeof line, "%.*s", wl, t);
        } else {
            snprintf(line, sizeof line, "%s", trial);
        }
        t = e;
    }
    if (line[0] && n < max) strcpy(lines[n++], line);
    return n;
}

// The skill an answer's kind names, or NULL.
static const char *skill(uint32_t kind, uint32_t which)
{
    if (kind & 2) return which == 7 ? "PERSUASION" : which == 6 ? "INTIMIDATION" : which == 8 ? "SEDUCTION" : NULL;
    if (kind & 1) return which == 6 ? "DOMINATE" : "DEMENTATION";
    return NULL;
}

static double fade(uint32_t dlg, uint32_t off)
{
    double a = float_at(dlg + off) / 192;
    return a < 0 ? 0 : a > 1 ? 1 : a;
}

// The lines shown, joined into paragraphs, one per speaker in turn: the character's
// current line, or, scrolled back, the game's window of as many older pieces. `npc` says
// whose each is.
static int history(uint32_t dlg, char paras[][2048], int *npc, int max)
{
    int count = (int)field(dlg, 0x184), shown = 0, n = 0, scroll = (int)field(dlg, 0x18c);
    uint32_t list = field(dlg, 0x178);
    for (int i = 0; i < count; i++) shown += field(list, i * 8) == 0;
    int start = count - scroll - shown;
    if (start < 0) start = 0;
    int last = -1, len = 0;
    for (int i = start; i < start + shown && i < count; i++) {
        uint32_t kind = field(list, i * 8), text = field(list, i * 8 + 4);
        if (!text || (!scroll && kind != 0)) continue;  // the player's answer is shown below
        int speaker = (kind & 1) == 0;
        if (speaker != last) {
            if (n == max) break;
            last = speaker, npc[n] = speaker, paras[n][0] = 0, len = 0, n++;
        } else if (len && paras[n - 1][len - 1] != ' ' && paras[n - 1][len - 1] != '-') {
            paras[n - 1][len++] = ' ';  // the game cut it at a space it kept, or between two lines
        }
        len = add_text(paras[n - 1], len, 2048, (const char *)bl_g2h(text));
    }
    return n;
}

static const float underline[3][5] = { { 0, 224, 40, 58, .9f }, { .4f, 176, 143, 88, .5f }, { 1, 176, 143, 88, 0 } };

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Whether the answers are up to choose from (painted in the last third of a second), for
// the gamepad's dialogue buttons.
int bl_dialog_active(void) { return now_ns() - asking_ns < 300000000ull; }

// Whether a conversation is on screen (painted in the last third of a second), for the
// renderer's depth of field (dof_step in metal_render.m): 1 or 0.
float bl_dialog_focus(void) { return now_ns() - talking_ns < 300000000ull ? 1.0f : 0.0f; }

// The answer under the mouse, from the last paint, or -1; `moved` says whether the mouse
// moved since the last look.
static int hovered_row(void *cpu, int *moved)
{
    *moved = 0;
    if (bl_window_cursor_hidden() || !nrows) return -1;
    if (!buf) buf = bl_guest_calloc(1, 16);
    uint32_t input = gothic_call(cpu, bl_h2g(GameUI_Input), 0, 0, NULL), a[2] = { buf, buf + 4 };
    gothic_scall(cpu, input, IN_CURSOR_POS, 2, a);
    int x = (int)field(buf, 0), y = (int)field(buf, 4);
    *moved = x != last_x || y != last_y;
    last_x = x, last_y = y;
    for (int i = 0; i < nrows; i++)
        if (x >= rows[i][0] && x < rows[i][2] && y >= rows[i][1] && y < rows[i][3]) return i;
    return -1;
}

static void paint(void *cpu, uint32_t dlg)
{
    uint32_t s = surface(cpu);
    gothic_screen(cpu, s, &screen_w, &screen_h);
    double a_answers = fade(dlg, 0x1a8), a_shade = fade(dlg, 0x1a4), a_line = a_shade;
    nrows = 0;
    if (a_shade <= 0) return;
    talking_ns = now_ns();

    // The fade: clear at its top, near black at the bottom.
    int sh = px(SHADE_H), band = px(6) > 1 ? px(6) : 1;
    for (int y = 0; y < sh; y += band) {
        double t = (y + band / 2.0) / sh;
        double a = t < .32 ? .62 * t / .32 : t < .66 ? .62 + .26 * (t - .32) / .34 : .88 + .07 * (t - .66) / .34;
        gothic_color(cpu, s, 8, 3, 4, a * a_shade);
        gothic_rect(cpu, s, 0, screen_h - sh + y, screen_w, screen_h - sh + y + band);
    }

    // The answers, from the bottom up: all of them, or only the one picked.
    uint32_t afont = gothic_face_font(cpu, s, GOTHIC_BODY, ANSWER_EM * unit());
    uint32_t nfont = gothic_font(cpu, s, NUM_EM * unit()), ffont = gothic_font(cpu, s, FEAT_EM * unit());
    int atall = gothic_face_tall(GOTHIC_BODY, ANSWER_EM * unit()), aline = px(ANSWER_EM * 1.25);
    int x0 = px(LEFT), width = px(WIDTH), bottom = screen_h - px(BOTTOM);
    struct { uint32_t number, kind, which; const char *text; } ans[MAX_ANSWERS];
    int n = 0, picked = byte_at(dlg + 0x1b3) != 0;
    if (picked) {
        ans[0].number = field(dlg, 0x1bc), ans[0].text = (const char *)bl_g2h(dlg + 0x1c0);
        ans[0].kind = field(dlg, 0x9c0), ans[0].which = field(dlg, 0x9c4), n = 1;
    } else if (byte_at(dlg + 0x1b1)) {
        n = (int)field(dlg, 0x1228);
        n = n < 0 ? 0 : n > MAX_ANSWERS ? MAX_ANSWERS : n;
        for (int i = 0; i < n; i++) {
            ans[i].number = (uint32_t)i, ans[i].text = (const char *)bl_g2h(dlg + 0x122c + i * 0x800);
            ans[i].kind = field(dlg, 0x322c + i * 4), ans[i].which = field(dlg, 0x323c + i * 4);
        }
    }
    char lines[MAX_ANSWERS][6][256];
    int nl[MAX_ANSWERS], text_x[MAX_ANSWERS], h[MAX_ANSWERS], total = 0;
    for (int i = 0; i < n; i++) {
        const char *sk = skill(ans[i].kind, ans[i].which);
        text_x[i] = px(TEXT_X) + (sk ? gothic_text_width(cpu, s, ffont, sk, px(FEAT_EM * .3)) + px(FEAT_GAP) : 0);
        char t[2048];
        add_text(t, 0, sizeof t, ans[i].text);
        nl[i] = wrap(cpu, s, afont, t, width - text_x[i], lines[i], 6);
        if (!nl[i]) nl[i] = 1, lines[i][0][0] = 0;
        h[i] = px(ROW_TOP) + nl[i] * aline + px(ROW_BOTTOM);
        total += h[i];
    }
    int top = bottom - total, y = top;
    for (int i = 0; i < n; i++) {
        rows[nrows][0] = x0, rows[nrows][1] = y, rows[nrows][2] = x0 + width, rows[nrows][3] = y + h[i];
        row_answer[nrows++] = ans[i].number;
        y += h[i];
    }
    // The bright answer: the first of a new set, else where the mouse moves, else as it was.
    uint32_t seen = (uint32_t)n * 2 + (uint32_t)picked;
    for (int i = 0; i < n; i++)
        for (const char *t = ans[i].text; *t; t++) seen = seen * 31 + (uint8_t)*t;
    if (seen != answers_seen) answers_seen = seen, chosen = 0;
    int moved, hover = picked ? -1 : hovered_row(cpu, &moved);
    if (hover >= 0 && moved) chosen = hover;
    if (chosen >= n) chosen = n ? n - 1 : 0;
    int over = picked ? 0 : chosen;
    if (!picked && n && a_answers > 0) asking_ns = now_ns();
    y = top;
    for (int i = 0; i < n && a_answers > 0; i++) {
        int on = i == over, ty = y + px(ROW_TOP);
        const char *sk = skill(ans[i].kind, ans[i].which);
        char num[8];
        snprintf(num, sizeof num, "%u", ans[i].number + 1);
        int ny = ty + (aline - gothic_tall(NUM_EM * unit())) / 2 + px(2);
        gothic_text(cpu, s, nfont, num, x0 + px(NUM_X), ny, px(1.5), (on ? GOLD_HI : GOLD)[0], (on ? GOLD_HI : GOLD)[1],
                    (on ? GOLD_HI : GOLD)[2], a_answers);
        if (sk) {
            int fy = ty + (aline - gothic_tall(FEAT_EM * unit())) / 2 + px(1);
            gothic_text(cpu, s, ffont, sk, x0 + px(TEXT_X), fy, px(FEAT_EM * .3), GOLD[0], GOLD[1], GOLD[2], a_answers);
        }
        for (int k = 0; k < nl[i]; k++)
            gothic_text(cpu, s, afont, lines[i][k], x0 + text_x[i], ty + k * aline + (aline - atall) / 2, 0, IVORY[0],
                        IVORY[1], IVORY[2], a_answers * (on ? 1 : .62));
        if (on) {
            gothic_drop(cpu, s, x0 + px(13), ty + aline / 2 - px(10), px(14), px(20), a_answers);
            gothic_line(cpu, s, x0 + px(NUM_X), x0 + px(NUM_X + UNDERLINE_W), y + h[i] - 1, underline, 3, a_answers);
        }
        y += h[i];
    }
    if (picked) nrows = 0;  // nothing to click while the character answers

    // The line, above the answers.
    if (a_line <= 0) return;
    static char paras[8][2048];
    int npc[8], np = history(dlg, paras, npc, 8);
    uint32_t lfont = gothic_face_font(cpu, s, GOTHIC_BODY, LINE_EM * unit());
    int ltall = gothic_face_tall(GOTHIC_BODY, LINE_EM * unit()), lline = px(LINE_EM * 1.32);
    static char wrapped[24][256];
    int count = 0, first[9];
    for (int p = 0; p < np; p++) {
        first[p] = count;
        count += wrap(cpu, s, lfont, paras[p], px(WIDTH - 80), wrapped + count, 24 - count);
    }
    first[np] = count;
    int ly = (n ? top - px(LINE_GAP) : bottom) - count * lline - (np > 1 ? (np - 1) * px(14) : 0);
    for (int p = 0; p < np; p++)
        for (int k = first[p]; k < first[p + 1]; k++) {
            const int *c = npc[p] ? IVORY : MUTED;
            gothic_text(cpu, s, lfont, wrapped[k], x0, ly + k * lline + p * px(14) + (lline - ltall) / 2, 0, c[0], c[1],
                        c[2], a_line);
        }
}

// bl_dialog_Key's replacement pushes a word; it writes 1 there to skip the game's code.
// Calls into the game change eax, ecx and edx, so each native reads them first.
static void answer(_cpu *cpu, uint32_t v) { *(uint32_t *)REG2PTR(esp) = v; }

// CHudDialog::Paint once it has decided to draw (esi = the panel): the whole screen. The
// replacement then runs ComputeSizes and leaves, past the game's frame, box and text.
void bl_dialog_Paint(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, dlg = esi;
    paint(cpu, dlg);
    *(uint8_t *)bl_g2h(dlg + 0x190) = 0;
    eax = sa, ecx = sc, edx = sd;
}

// ComputeSizes' SetPos and SetSize (x or width, then y or height, on the stack): the panel
// covers the screen.
void bl_dialog_Pos(_cpu *cpu)
{
    uint32_t *a = (uint32_t *)REG2PTR(esp);
    a[0] = 0, a[1] = 0;
}

void bl_dialog_Size(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx;
    uint32_t *a = (uint32_t *)REG2PTR(esp);
    gothic_screen(cpu, surface(cpu), &screen_w, &screen_h);
    a[0] = (uint32_t)screen_w, a[1] = (uint32_t)screen_h;
    eax = sa, ecx = sc, edx = sd;
}

// CHudDialog::Key_Event after its first instruction (ecx = the panel; on the stack under
// the pushed word: the return address, then the key's state and its number). While answers
// are up, a click on one, or Enter, picks it, and the arrows step through them; each acts
// on the state the game's number keys act on (0), and the game sees neither state: the
// skip returns 0 in eax, "handled". A click elsewhere does nothing (the game's shows or
// hides the line).
void bl_dialog_Key(_cpu *cpu)
{
    uint32_t sa = eax, sc = ecx, sd = edx, dlg = ecx, skip = 0;
    const uint32_t *st = (const uint32_t *)REG2PTR(esp);
    uint32_t key = st[3];
    int act = st[2] == 0, pick = -1;
    if (key == MOUSE1) {
        int moved, r = hovered_row(cpu, &moved);
        if (r >= 0) chosen = r, pick = r;
        skip = 1;
    } else if (nrows && bl_dialog_active()) {
        if (key == K_UP || key == K_KP_UP || key == K_DOWN || key == K_KP_DOWN) {
            if (act) chosen = (chosen + (key == K_UP || key == K_KP_UP ? nrows - 1 : 1)) % nrows;
            skip = 1;
        } else if (key == K_ENTER || key == K_KP_ENTER) {
            pick = chosen < nrows ? chosen : -1;
            skip = 1;
        }
    }
    if (act && pick >= 0) {
        uint32_t a[2] = { row_answer[pick], 0 };
        bl_call_guest(cpu, bl_h2g(client_DialogPick), BL_THISCALL, dlg, 2, a);
    }
    eax = skip ? 0 : sa, ecx = sc, edx = sd;
    answer(cpu, skip);
}
