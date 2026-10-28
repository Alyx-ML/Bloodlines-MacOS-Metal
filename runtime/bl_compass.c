// The quest compass: a strip across the top of the screen, as in later open-world games,
// drawn in the game's own colours (black, blood red, bone), with the directions as the
// player turns and a marker for each quest the player has something left to do in.
//
// Where a quest sends the player is not in the game's data (its quest files hold only
// text): runtime/compass_quests_*.py say it, per quest and state, as a map and an entity
// name (or an origin). runtime/compass.py runs in the game's Python and reports, a few
// times a second, the quests the player has at those states and where those entities
// stand now (bl_compass_draw calls it on the game's thread, between frames). On another
// map, the marker shows the way: the level change on this map that starts the shortest
// chain of them there, read from every map's entities when the first map loads.
//
// The strip is drawn here with Core Graphics into a premultiplied BGRA image;
// metal_render.m lays it over the back buffer (compass_overlay). The Quest Compass box on
// the options' Gameplay tab turns it off (bl_vgui.c; saved like the Enhanced tab's).
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ctype.h>
#include <dirent.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#include "bl_vm.h"
#include "compass_py.h"  // the Python above, made by tools/build_runtime.sh

extern char vampire_python21_PyRun__SimpleString[], vampire_python21_PyImport__AddModule[],
    vampire_python21_PyObject__GetAttrString[], vampire_python21_PyString__AsString[], vampire_python21_PyErr__Clear[];

// --- what the strip shows: the quests' places, from the game's Python ---

#define MAX_MARKS 16
struct mark {
    float pos[3];
    int main, away;  // the main story's quest; the way to another map
};
static struct mark marks[MAX_MARKS];
static int nmarks;
static char quests[4096];  // _blc_out as last read

// --- the maps: named entities and the level changes between maps ---

struct ent {
    char name[64];  // targetname, lower case
    char dest[64];  // a trigger_changelevel's map, lower case; "" for others
    int to;         // that map's number in maps[], -1 none (link_maps)
    float pos[3];
};
struct mapinfo {
    char name[64];  // lower case, without .bsp
    struct ent *e;
    int n;
};
static struct mapinfo *maps;
static int nmaps, cur = -1;
// Per map: the first step from `cur` on the shortest way there (-2 not worked out yet,
// -1 none), so the search runs once per map change, not every frame.
static int *first_step;
// The game's Python is set up again after a load: the compass's tables are given to it
// a few times per map at most (their own errors would otherwise repeat for ever).
static int given;
static int map_changed;  // set by bl_compass_note_map; the 2-second wait starts over

static void lower(char *s)
{
    for (; *s; s++) *s = (char)tolower((unsigned char)*s);
}

static int find_map(const char *name)
{
    for (int i = 0; i < nmaps; i++)
        if (!strcmp(maps[i].name, name)) return i;
    return -1;
}

static int rd32(const uint8_t *p) { return (int)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24); }

// Value of key in one entity's text [b, e), into out.
static int value(const char *b, const char *e, const char *key, char *out, int len)
{
    size_t kl = strlen(key);
    for (const char *k = b; k < e;) {
        const char *q[4];
        int n = 0;
        for (const char *c = k; c < e && n < 4; c++)
            if (*c == '"') q[n++] = c;
        if (n < 4) return 0;
        if ((size_t)(q[1] - q[0] - 1) == kl && !strncasecmp(q[0] + 1, key, kl)) {
            int vl = (int)(q[3] - q[2] - 1);
            if (vl >= len) vl = len - 1;
            memcpy(out, q[2] + 1, (size_t)vl), out[vl] = 0;
            return 1;
        }
        k = q[3] + 1;
    }
    return 0;
}

static void read_map(const char *path, const char *name)
{
    FILE *f = fopen(path, "rb");
    if (!f) return;
    uint8_t hdr[8 + 64 * 16];
    if (fread(hdr, 1, sizeof hdr, f) != sizeof hdr || memcmp(hdr, "VBSP", 4)) return (void)fclose(f);
    int eo = rd32(hdr + 8), el = rd32(hdr + 12), mo = rd32(hdr + 8 + 14 * 16), ml = rd32(hdr + 12 + 14 * 16);
    long size = fseek(f, 0, SEEK_END) ? -1 : ftell(f);
    // a damaged or odd map: its lumps must lie inside the file (as bl_bsp.c's load)
    if (size < 0 || eo < 0 || el < 0 || mo < 0 || ml < 0 || (long)eo + el > size || (long)mo + ml > size) {
        fprintf(stderr, "[compass] %s: its lumps don't fit the file; left out\n", path);
        return (void)fclose(f);
    }
    char *ents = malloc((size_t)el + 1);
    uint8_t *models = malloc((size_t)ml + 1);
    int ok = ents && models && !fseek(f, eo, SEEK_SET) && fread(ents, 1, (size_t)el, f) == (size_t)el &&
             !fseek(f, mo, SEEK_SET) && fread(models, 1, (size_t)ml, f) == (size_t)ml;
    fclose(f);
    if (!ok) return free(ents), free(models);
    ents[el] = 0;
    struct mapinfo m = {0};
    snprintf(m.name, sizeof m.name, "%s", name);
    int cap = 0;
    for (const char *e = ents, *end = ents + el;;) {
        const char *open = memchr(e, '{', (size_t)(end - e)), *close = open ? memchr(open, '}', (size_t)(end - open)) : NULL;
        if (!close) break;
        e = close + 1;
        char tn[64] = "", cls[64] = "", dest[64] = "", org[64] = "", model[16] = "";
        value(open + 1, close, "targetname", tn, sizeof tn);
        value(open + 1, close, "classname", cls, sizeof cls);
        int change = !strcasecmp(cls, "trigger_changelevel") && value(open + 1, close, "map", dest, sizeof dest);
        if (!tn[0] && !change) continue;
        float p[3] = {0};
        if (value(open + 1, close, "origin", org, sizeof org)) sscanf(org, "%f %f %f", &p[0], &p[1], &p[2]);
        // a brush entity: the middle of its model, which stands at its origin
        if (value(open + 1, close, "model", model, sizeof model) && model[0] == '*') {
            int k = atoi(model + 1);
            if (k > 0 && k < ml / 48)
                for (int a = 0; a < 3; a++) {
                    float lo, hi;
                    memcpy(&lo, models + 48 * k + 4 * a, 4), memcpy(&hi, models + 48 * k + 12 + 4 * a, 4);
                    p[a] += (lo + hi) / 2;
                }
        }
        if (m.n == cap) m.e = realloc(m.e, sizeof *m.e * (size_t)(cap = cap ? cap * 2 : 64));
        struct ent *x = &m.e[m.n++];
        memset(x, 0, sizeof *x);
        snprintf(x->name, sizeof x->name, "%s", tn), lower(x->name);
        if (change) snprintf(x->dest, sizeof x->dest, "%s", dest), lower(x->dest);
        memcpy(x->pos, p, sizeof p);
    }
    free(ents), free(models);
    maps = realloc(maps, sizeof *maps * (size_t)(nmaps + 1));
    maps[nmaps++] = m;
}

static void read_dir(const char *dir)
{
    DIR *d = opendir(dir);
    if (!d) return;
    for (struct dirent *de; (de = readdir(d));) {
        size_t n = strlen(de->d_name);
        if (n < 5 || n > 60 || strcasecmp(de->d_name + n - 4, ".bsp")) continue;
        char name[64], path[2048];
        memcpy(name, de->d_name, n - 4), name[n - 4] = 0, lower(name);
        if (find_map(name) >= 0) continue;  // the mod's own copy came first
        snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
        read_map(path, name);
    }
    closedir(d);
}

// Called with each map the game opens (bl_bsp.c): the first reads every map's entities
// (the mod's maps folder, then the base game's, which it overrides).
void bl_compass_note_map(const char *host_path)
{
    const char *slash = strrchr(host_path, '/');
    if (!slash) return;
    if (!nmaps) {
        char dir[2048];
        snprintf(dir, sizeof dir, "%.*s", (int)(slash - host_path), host_path);
        read_dir(dir);
        char *up = strrchr(dir, '/');  // .../<mod>/maps -> .../Vampire/maps
        if (up) {
            *up = 0;
            char *mod = strrchr(dir, '/');
            if (mod) snprintf(mod + 1, sizeof dir - (size_t)(mod + 1 - dir), "Vampire/maps"), read_dir(dir);
        }
        int links = 0;
        for (int i = 0; i < nmaps; i++)
            for (int j = 0; j < maps[i].n; j++) links += maps[i].e[j].dest[0] != 0;
        fprintf(stderr, "[compass] %d maps, %d level changes between them\n", nmaps, links);
        for (int i = 0; i < nmaps; i++)
            for (int j = 0; j < maps[i].n; j++) maps[i].e[j].to = maps[i].e[j].dest[0] ? find_map(maps[i].e[j].dest) : -1;
        free(first_step);
        first_step = malloc(sizeof *first_step * (size_t)(nmaps + 1));
    }
    char name[64];
    snprintf(name, sizeof name, "%s", slash + 1);
    char *dot = strrchr(name, '.');
    if (dot) *dot = 0;
    lower(name);
    cur = find_map(name);
    quests[0] = 0, nmarks = 0;  // the last map's, until the game's Python is asked again
    for (int i = 0; i < nmaps; i++) first_step[i] = -2;
    given = 0, map_changed = 1;
}

static const struct ent *named(int map, const char *name)
{
    if (map < 0 || !name[0]) return NULL;
    for (int j = 0; j < maps[map].n; j++)
        if (!strcasecmp(maps[map].e[j].name, name)) return &maps[map].e[j];
    return NULL;
}

// Two versions of one place (sm_hub_1, sm_hub_2: the street at different points of the
// story): hub maps with the same name but for the number at the end. Only hubs: other
// numbered maps are different places (ch_temple_1 and ch_temple_4 are separate floors).
static int same_place(const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b);
    while (la && isdigit((unsigned char)a[la - 1])) la--;
    while (lb && isdigit((unsigned char)b[lb - 1])) lb--;
    return la == lb && la > 5 && !strncmp(a + la - 5, "_hub_", 5) && !strncmp(a, b, la);
}

// The level change on map `from` that starts the shortest way to map `to` (nearest
// the camera of those that do), or NULL.
static const struct ent *way(int from, int to, const float cam[3])
{
    if (from < 0 || to < 0 || to == from) return NULL;
    if (from == cur && first_step[to] == -2) {
        int *prev = malloc(sizeof *prev * (size_t)nmaps), *queue = malloc(sizeof *queue * (size_t)nmaps), qh = 0, qt = 0;
        for (int i = 0; i < nmaps; i++) prev[i] = -2;
        prev[from] = -1, queue[qt++] = from;
        while (qh < qt && prev[to] == -2) {
            int m = queue[qh++];
            for (int j = 0; j < maps[m].n; j++) {
                int d = maps[m].e[j].to;
                if (d >= 0 && prev[d] == -2) prev[d] = m, queue[qt++] = d;
            }
        }
        int step = prev[to] == -2 ? -1 : to;
        while (step >= 0 && prev[step] != from) step = prev[step];
        first_step[to] = step;
        free(prev), free(queue);
    }
    int step = from == cur ? first_step[to] : -1;
    const struct ent *best = NULL;
    float bd = INFINITY;
    for (int j = 0; step >= 0 && j < maps[from].n; j++) {
        const struct ent *e = &maps[from].e[j];
        if (e->to != step) continue;
        float d = hypotf(hypotf(e->pos[0] - cam[0], e->pos[1] - cam[1]), e->pos[2] - cam[2]);
        if (d < bd) bd = d, best = e;
    }
    return best;
}

// --- the game's Python ---


static uint32_t py(void *cpu, const char *fn, int n, const uint32_t *a)
{
    return bl_call_guest(cpu, bl_h2g(fn), BL_CDECL, 0, n, a);
}

// Runs one Python statement (in __main__), from a guest copy.
static void py_run(void *cpu, const char *src)
{
    static uint32_t buf, cap;
    uint32_t n = (uint32_t)strlen(src) + 1;
    if (n > cap) {
        if (buf) bl_guest_free(buf);
        buf = bl_guest_malloc(cap = n + 256);
        if (!buf) return (void)(cap = 0);
    }
    memcpy(bl_g2h(buf), src, n);
    py(cpu, vampire_python21_PyRun__SimpleString, 1, &buf);
}

static void ask_python(void)
{
    void *cpu = bl_thread_cpu;
    if (!cpu || cur < 0) return;
    static uint32_t main_name, out_name;
    if (!main_name) main_name = bl_guest_strdup("__main__"), out_name = bl_guest_strdup("_blc_out");
    char call[160];
    snprintf(call, sizeof call, "try:\n    _blc_tick('%s')\nexcept NameError:\n    _blc_out = '?'\nexcept:\n    _blc_out = ''\n", maps[cur].name);
    py_run(cpu, call);
    uint32_t mod = py(cpu, vampire_python21_PyImport__AddModule, 1, &main_name);
    uint32_t a[2] = {mod, out_name};
    uint32_t s = mod ? py(cpu, vampire_python21_PyObject__GetAttrString, 2, a) : 0;
    if (!s) {
        py(cpu, vampire_python21_PyErr__Clear, 0, NULL);
        quests[0] = 0;
        return;
    }
    uint32_t text = py(cpu, vampire_python21_PyString__AsString, 1, &s);
    snprintf(quests, sizeof quests, "%s", text ? (const char *)bl_g2h(text) : "");
    if (!text) py(cpu, vampire_python21_PyErr__Clear, 0, NULL);
    (*(int32_t *)bl_g2h(s))--;  // GetAttrString's reference (__main__ keeps its own)
    if (!strcmp(quests, "?") && given < 3) {  // __main__ is new (the game started or loaded): give it the compass
        given++;
        py_run(cpu, compass_py);
        fprintf(stderr, "[compass] quest tables given to the game's Python\n");
        quests[0] = 0;
    }
}

// Where each quest line points, from this map and camera.
static void place_marks(const float cam[3])
{
    nmarks = 0;
    static char copy[sizeof quests];  // cut up below: `quests` is read again every frame
    memcpy(copy, quests, sizeof copy);
    for (char *line = copy; *line && nmarks < MAX_MARKS;) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = 0;
        char map[64] = "", name[64] = "";
        int main = 0;
        float p[3];
        int have = 0;
        char *f[4] = {line, NULL, NULL, NULL};
        for (int i = 1; i < 4 && f[i - 1]; i++) {
            char *t = strchr(f[i - 1], '\t');
            if (t) *t = 0, f[i] = t + 1;
        }
        if (f[3]) {
            main = atoi(f[0]);
            snprintf(map, sizeof map, "%s", f[1]), lower(map);
            snprintf(name, sizeof name, "%s", f[2]);
            have = sscanf(f[3], "%f %f %f", &p[0], &p[1], &p[2]) == 3;
        }
        if (nl) *nl = '\n', line = nl + 1;
        else line += strlen(line);
        if (!map[0]) continue;
        struct mark *m = &marks[nmarks];
        m->main = main, m->away = 0;
        int here = !strcmp(map, maps[cur].name) ||
                   (same_place(map, maps[cur].name) && (!name[0] || named(cur, name)));
        if (here) {
            const struct ent *e = named(cur, name);
            if (!have && e) memcpy(p, e->pos, sizeof p), have = 1;
            if (!have) continue;
            memcpy(m->pos, p, sizeof p);
        } else {
            const struct ent *e = way(cur, find_map(map), cam);
            if (!e) continue;
            memcpy(m->pos, e->pos, sizeof m->pos);
            m->away = 1;
        }
        nmarks++;
    }
}

// --- the strip ---

static CTFontRef font(double size)
{
    CTFontRef f = CTFontCreateWithName(CFSTR("Copperplate-Bold"), size, NULL);
    return f ? f : CTFontCreateWithName(CFSTR("Times-Bold"), size, NULL);
}

static CTLineRef text_line(const char *s, CTFontRef f, CGColorRef col)
{
    CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *vals[] = {f, col};
    CFDictionaryRef attr = CFDictionaryCreate(NULL, keys, vals, col ? 2 : 1, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attr);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFRelease(as), CFRelease(attr), CFRelease(str);
    return line;
}

static double text_width(const char *s, CTFontRef f)
{
    CTLineRef line = text_line(s, f, NULL);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return w;
}

// Text centred on x with its baseline at y; its width.
static double text(CGContextRef g, const char *s, CTFontRef f, CGColorRef col, double x, double y)
{
    CTLineRef line = text_line(s, f, col);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGContextSetTextPosition(g, x - w / 2, y);
    CTLineDraw(line, g);
    CFRelease(line);
    return w;
}

#define SPAN 180.0  // degrees across the strip

// The strip fades out towards its ends.
static double fade(double x, double w)
{
    double t = fmin(x, w - x) / (w * 0.16);
    return t >= 1 ? 1 : t <= 0 ? 0 : t * t * (3 - 2 * t);
}

static CGColorRef rgba(double r, double g, double b, double a) { return CGColorCreateSRGB(r, g, b, a); }

// A diamond centred at (x, y), half-size r: filled for a place on this map, an outline
// for the way to another.
static void diamond(CGContextRef g, double x, double y, double r, int main, int away, double a)
{
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, x, y + r);
    CGPathAddLineToPoint(p, NULL, x + r * 0.72, y);
    CGPathAddLineToPoint(p, NULL, x, y - r);
    CGPathAddLineToPoint(p, NULL, x - r * 0.72, y);
    CGPathCloseSubpath(p);
    CGContextSetLineJoin(g, kCGLineJoinMiter);
    // a dark edge so it reads over bright scenes
    CGContextSetRGBStrokeColor(g, 0, 0, 0, 0.85 * a);
    CGContextSetLineWidth(g, r * 0.42);
    CGContextAddPath(g, p), CGContextStrokePath(g);
    if (!away) {
        CGContextSetRGBFillColor(g, main ? 0.72 : 0.5, main ? 0.06 : 0.05, main ? 0.05 : 0.05, a);
        CGContextAddPath(g, p), CGContextFillPath(g);
    }
    CGContextSetRGBStrokeColor(g, 0.86, 0.78, 0.62, (away ? 0.95 : 0.8) * a);
    CGContextSetLineWidth(g, r * (away ? 0.22 : 0.12));
    CGContextAddPath(g, p), CGContextStrokePath(g);
    CGPathRelease(p);
}

int bl_compass_draw(uint32_t w, uint32_t h, const float rows[3][4], void *bgra)
{
    if (cur < 0) return 0;
    // The game's Python is only asked once play has gone on steadily for a while: during a
    // level change or a load the player's entity is not ready, and asking it then crashed.
    // Any gap in the strip being drawn (a loading screen, a menu, dialogue) starts it over,
    // and so does a new map, however quickly it loaded.
    static double last, steady, asked;
    double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-9;
    if (now - last > 0.25 || map_changed) steady = now, map_changed = 0;
    last = now;
    if (now - steady > 2 && now - asked > 0.25) asked = now, ask_python();  // four times a second
    float cam[3];
    for (int k = 0; k < 3; k++) cam[k] = -(rows[0][k] * rows[0][3] + rows[1][k] * rows[1][3] + rows[2][k] * rows[2][3]);
    place_marks(cam);
    double heading = atan2(rows[2][1], rows[2][0]) * 180 / M_PI;  // the way the camera looks; 90 north (+y)

    memset(bgra, 0, (size_t)w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(bgra, w, h, 8, w * 4, cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!g) return 0;
    double W = w, H = h, top = H * 0.97, bot = H * 0.42, mid = (top + bot) / 2, bh = top - bot;
    // where a bearing falls on the strip; |x - W/2| > W/2 is off it
    #define AT(b) (W / 2 - remainder((b) - heading, 360.0) / SPAN * W)

    // the band: black, fading out at the ends
    {
        CGColorRef c[4] = {rgba(0, 0, 0, 0), rgba(0.03, 0, 0, 0.62), rgba(0.03, 0, 0, 0.62), rgba(0, 0, 0, 0)};
        CFArrayRef arr = CFArrayCreate(NULL, (const void **)c, 4, &kCFTypeArrayCallBacks);
        CGFloat loc[4] = {0, 0.16, 0.84, 1};
        CGGradientRef gr = CGGradientCreateWithColors(NULL, arr, loc);
        CGContextSaveGState(g);
        CGContextClipToRect(g, CGRectMake(0, bot, W, bh));
        CGContextDrawLinearGradient(g, gr, CGPointMake(0, 0), CGPointMake(W, 0), 0);
        CGContextRestoreGState(g);
        CGGradientRelease(gr), CFRelease(arr);
        for (int i = 0; i < 4; i++) CGColorRelease(c[i]);
    }
    // its edges: a blood-red line with a thin bone one inside, fading the same way
    for (int s = 0; s < 96; s++) {
        double x0 = W * s / 96, x1 = W * (s + 1) / 96, a = fade((x0 + x1) / 2, W);
        if (a <= 0) continue;
        CGContextSetRGBFillColor(g, 0.55, 0.04, 0.04, 0.95 * a);
        CGContextFillRect(g, CGRectMake(x0, top - H * 0.035, x1 - x0, H * 0.035));
        CGContextFillRect(g, CGRectMake(x0, bot, x1 - x0, H * 0.035));
        CGContextSetRGBFillColor(g, 0.86, 0.78, 0.62, 0.45 * a);
        CGContextFillRect(g, CGRectMake(x0, top - H * 0.06, x1 - x0, H * 0.012));
        CGContextFillRect(g, CGRectMake(x0, bot + H * 0.048, x1 - x0, H * 0.012));
    }
    // the directions: letters at the points, ticks between
    CTFontRef big = font(bh * 0.52), small = font(bh * 0.34), tiny = font(H * 0.26);
    static const char *const names[8] = {"E", "NE", "N", "NW", "W", "SW", "S", "SE"};
    for (int d = 0; d < 360; d += 15) {
        double x = AT(d), a = fade(x, W);
        if (x < 0 || x > W || a <= 0) continue;
        if (d % 45 == 0) {
            int cardinal = d % 90 == 0;
            CGColorRef col = d == 90 ? rgba(0.82, 0.1, 0.07, a) : rgba(0.86, 0.78, 0.62, (cardinal ? 1 : 0.75) * a);
            text(g, names[d / 45], cardinal ? big : small, col, x, mid - (cardinal ? bh * 0.19 : bh * 0.12));
            CGColorRelease(col);
        } else {
            CGContextSetRGBFillColor(g, 0.86, 0.78, 0.62, 0.55 * a);
            CGContextFillRect(g, CGRectMake(x - H * 0.012, mid - bh * 0.14, H * 0.024, bh * 0.28));
        }
    }
    // where the camera looks: a small bone notch hanging from the top edge
    CGContextSetRGBFillColor(g, 0.86, 0.78, 0.62, 0.95);
    CGContextMoveToPoint(g, W / 2 - H * 0.07, top - H * 0.035);
    CGContextAddLineToPoint(g, W / 2 + H * 0.07, top - H * 0.035);
    CGContextAddLineToPoint(g, W / 2, top - H * 0.15);
    CGContextFillPath(g);
    // the quests: the main one last, on top; off the strip they wait at its ends
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < nmarks; i++) {
            const struct mark *m = &marks[i];
            if (m->main != pass) continue;
            double dx = m->pos[0] - cam[0], dy = m->pos[1] - cam[1], dz = m->pos[2] - cam[2];
            double x = AT(atan2(dy, dx) * 180 / M_PI), edge = H * 0.3;
            if (x < edge) x = edge;
            if (x > W - edge) x = W - edge;
            double r = bh * (m->main ? 0.4 : 0.3);
            diamond(g, x, mid, r, m->main, m->away, 1);
            // how far, in metres (a unit is an inch), with a small arrow when it is a floor
            // up or down; kept inside the image at the ends
            double metres = sqrt(dx * dx + dy * dy + dz * dz) * 0.0254, t = H * 0.07;
            int updown = dz > 120 ? 1 : dz < -120 ? -1 : 0;
            char s[32];
            snprintf(s, sizeof s, "%.0f m", metres);
            CGColorRef col = rgba(0.86, 0.78, 0.62, m->main ? 0.95 : 0.7);
            double tw = text_width(s, tiny) + (updown ? 3 * t : 0);
            double tx = fmin(fmax(x, tw / 2 + 2), W - tw / 2 - 2) - (updown ? 1.5 * t : 0);
            double sw = text(g, s, tiny, col, tx, H * 0.08);
            if (updown) {
                double ax = tx + sw / 2 + 1.6 * t, ay = H * 0.08 + H * 0.085;
                CGContextSetFillColorWithColor(g, col);
                CGContextMoveToPoint(g, ax - t, ay - updown * t * 0.8);
                CGContextAddLineToPoint(g, ax + t, ay - updown * t * 0.8);
                CGContextAddLineToPoint(g, ax, ay + updown * t * 0.8);
                CGContextFillPath(g);
            }
            CGColorRelease(col);
        }
    #undef AT
    CFRelease(big), CFRelease(small), CFRelease(tiny);
    CGContextRelease(g);
    return 1;
}
