// advapi32 registry: keys and values in memory, saved to <data dir>/registry.txt after
// every change, so the game's settings (its video mode among them) survive a restart.
// Without a data directory (BL_DATA_DIR=off) the registry lasts for the run only.
//
// registry.txt has one line per key ("K\t<path>") and per value
// ("V\t<path>\t<name>\t<type>\t<hex bytes>"). Paths start with HKCR, HKCU, HKLM or HKU
// and compare without regard to case, like Windows. BL_REG_TRACE=1 logs every call.
#include <ctype.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "bl_win32.h"

#define U32(a) (*(uint32_t *)bl_g2h(a))
#define ERROR_MORE_DATA 234
#define ERROR_NO_MORE_ITEMS 259

struct value { char key[260], name[128]; uint32_t type, size; uint8_t *data; };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static char (*keys)[260];
static int nkeys, cap_keys;
static struct value *values;
static int nvalues, cap_values;
static char open_keys[256][260];  // handle 0x710000 + 4 * i; "" when free
static int loaded, trace = -1;

static void add_key(const char *path)
{
    for (int i = 0; i < nkeys; i++)
        if (!strcasecmp(keys[i], path)) return;
    // Parents first, so enumeration finds every level.
    char parent[260];
    snprintf(parent, sizeof parent, "%s", path);
    char *s = strrchr(parent, '\\');
    if (s) *s = 0, add_key(parent);
    if (nkeys == cap_keys) keys = realloc(keys, sizeof *keys * (size_t)(cap_keys = cap_keys ? cap_keys * 2 : 64));
    snprintf(keys[nkeys++], sizeof *keys, "%s", path);
}

static int key_exists(const char *path)
{
    if (!strchr(path, '\\')) return 1;  // the roots
    for (int i = 0; i < nkeys; i++)
        if (!strcasecmp(keys[i], path)) return 1;
    return 0;
}

static struct value *find_value(const char *key, const char *name)
{
    for (int i = 0; i < nvalues; i++)
        if (!strcasecmp(values[i].key, key) && !strcasecmp(values[i].name, name)) return &values[i];
    return NULL;
}

static void file_path(char *out, size_t cap)
{
    const char *d = bl_data_dir();
    if (d[0]) snprintf(out, cap, "%s/registry.txt", d);
    else out[0] = 0;
}

static void save(void)
{
    char path[1100], tmp[1110];
    file_path(path, sizeof path);
    if (!path[0]) return;
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    for (int i = 0; i < nkeys; i++) fprintf(f, "K\t%s\n", keys[i]);
    for (int i = 0; i < nvalues; i++) {
        fprintf(f, "V\t%s\t%s\t%u\t", values[i].key, values[i].name, values[i].type);
        for (uint32_t j = 0; j < values[i].size; j++) fprintf(f, "%02x", values[i].data[j]);
        fputc('\n', f);
    }
    if (fclose(f) == 0) rename(tmp, path);
}

static void load(void)
{
    if (loaded) return;
    loaded = 1;
    const char *t = getenv("BL_REG_TRACE");
    trace = t && t[0] == '1';
    char path[1100], *line = NULL;
    size_t line_cap = 0;
    file_path(path, sizeof path);
    FILE *f = path[0] ? fopen(path, "r") : NULL;
    if (!f) return;
    while (getline(&line, &line_cap, f) > 0) {  // any length: a value's hex may be long
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "K\t", 2)) add_key(line + 2);
        if (!strncmp(line, "V\t", 2)) {
            // Split by hand: a value's name may be empty ("V\tkey\t\ttype\thex").
            char *k = line + 2, *nm = strchr(k, '\t');
            if (!nm) continue;
            *nm++ = 0;
            char *ty = strchr(nm, '\t');
            if (!ty) continue;
            *ty++ = 0;
            char *hex = strchr(ty, '\t');
            hex = hex ? (*hex = 0, hex + 1) : ty + strlen(ty);
            if (nvalues == cap_values)
                values = realloc(values, sizeof *values * (size_t)(cap_values = cap_values ? cap_values * 2 : 64));
            struct value *v = &values[nvalues++];
            memset(v, 0, sizeof *v);
            snprintf(v->key, sizeof v->key, "%s", k);
            snprintf(v->name, sizeof v->name, "%s", nm);
            v->type = (uint32_t)strtoul(ty, NULL, 10);
            v->size = (uint32_t)(strlen(hex) / 2);
            v->data = malloc(v->size ? v->size : 1);
            for (uint32_t j = 0; j < v->size; j++) sscanf(hex + 2 * j, "%2hhx", &v->data[j]);
        }
    }
    free(line);
    fclose(f);
}

// The full path of handle `h` plus `sub` (which may be 0 or ""); 0 for a bad handle.
static int resolve(uint32_t h, uint32_t sub, char *out, size_t cap)
{
    const char *base;
    switch (h) {
    case 0x80000000u: base = "HKCR"; break;
    case 0x80000001u: base = "HKCU"; break;
    case 0x80000002u: base = "HKLM"; break;
    case 0x80000003u: base = "HKU"; break;
    default: {
        uint32_t i = (h - 0x710000u) / 4;
        if (h < 0x710000u || i >= 256 || !open_keys[i][0]) return 0;
        base = open_keys[i];
    }
    }
    const char *s = sub ? (const char *)bl_g2h(sub) : "";
    while (*s == '\\') s++;
    snprintf(out, cap, "%s%s%s", base, *s ? "\\" : "", s);
    size_t n = strlen(out);
    while (n && out[n - 1] == '\\') out[--n] = 0;
    return 1;
}

static uint32_t new_handle(const char *path)
{
    for (int i = 0; i < 256; i++)
        if (!open_keys[i][0]) {
            snprintf(open_keys[i], sizeof open_keys[i], "%s", path);
            return 0x710000u + 4u * (uint32_t)i;
        }
    return 0;
}

static uint32_t open_key(uint32_t key, uint32_t sub, uint32_t out, int create, uint32_t disp)
{
    pthread_mutex_lock(&lock);
    load();
    char path[260];
    uint32_t r = BL_ERROR_SUCCESS, h = 0;
    if (!resolve(key, sub, path, sizeof path)) {
        r = BL_ERROR_INVALID_HANDLE;
    } else if (!key_exists(path) && !create) {
        r = BL_ERROR_FILE_NOT_FOUND;
    } else {
        int existed = key_exists(path);
        if (!existed) add_key(path), save();
        if (disp) U32(disp) = existed ? 2 : 1;  // REG_OPENED_EXISTING_KEY, REG_CREATED_NEW_KEY
        h = new_handle(path);
        if (!h) r = BL_ERROR_NOT_ENOUGH_MEMORY;
    }
    if (out) U32(out) = h;
    if (trace) fprintf(stderr, "[reg] %s %s -> %u\n", create ? "create" : "open", path, r);
    pthread_mutex_unlock(&lock);
    return r;
}

uint32_t bl_adv_RegOpenKeyExA_c(uint32_t key, uint32_t sub, uint32_t opts, uint32_t sam, uint32_t out)
{
    (void)opts, (void)sam;
    return open_key(key, sub, out, 0, 0);
}

uint32_t bl_adv_RegOpenKeyA_c(uint32_t key, uint32_t sub, uint32_t out) { return open_key(key, sub, out, 0, 0); }

uint32_t bl_adv_RegCreateKeyExA_c(uint32_t key, uint32_t sub, uint32_t res, uint32_t cls, uint32_t opts,
                                  uint32_t sam, uint32_t sec, uint32_t out, uint32_t disp)
{
    (void)res, (void)cls, (void)opts, (void)sam, (void)sec;
    return open_key(key, sub, out, 1, disp);
}

uint32_t bl_adv_RegCloseKey_c(uint32_t key)
{
    if (key >= 0x80000000u && key <= 0x80000006u) return BL_ERROR_SUCCESS;  // HKEY_CLASSES_ROOT etc.
    uint32_t i = (key - 0x710000u) / 4;
    if (key < 0x710000u || (key & 3) || i >= 256) return BL_ERROR_INVALID_HANDLE;
    pthread_mutex_lock(&lock);
    uint32_t r = open_keys[i][0] ? BL_ERROR_SUCCESS : BL_ERROR_INVALID_HANDLE;
    open_keys[i][0] = 0;
    pthread_mutex_unlock(&lock);
    return r;
}

// Copies value `v` out the way RegQueryValueEx does: the size alone when there is no
// buffer, ERROR_MORE_DATA when the buffer is too small.
static uint32_t copy_out(const struct value *v, uint32_t type, uint32_t data, uint32_t size)
{
    if (type) U32(type) = v->type;
    if (!size) return data ? BL_ERROR_INVALID_PARAMETER : BL_ERROR_SUCCESS;
    uint32_t room = U32(size);
    U32(size) = v->size;
    if (!data) return BL_ERROR_SUCCESS;
    if (room < v->size) return ERROR_MORE_DATA;
    memcpy(bl_g2h(data), v->data, v->size);
    return BL_ERROR_SUCCESS;
}

uint32_t bl_adv_RegQueryValueExA_c(uint32_t key, uint32_t name, uint32_t res, uint32_t type, uint32_t data,
                                   uint32_t size)
{
    (void)res;
    pthread_mutex_lock(&lock);
    load();
    char path[260];
    const char *nm = name ? (const char *)bl_g2h(name) : "";
    uint32_t r;
    struct value *v = NULL;
    if (!resolve(key, 0, path, sizeof path)) r = BL_ERROR_INVALID_HANDLE;
    else if (!(v = find_value(path, nm))) r = BL_ERROR_FILE_NOT_FOUND;
    else r = copy_out(v, type, data, size);
    if (trace) fprintf(stderr, "[reg] query %s\\%s -> %u\n", path, nm, r);
    pthread_mutex_unlock(&lock);
    return r;
}

uint32_t bl_adv_RegQueryValueA_c(uint32_t key, uint32_t sub, uint32_t data, uint32_t size)
{
    // The default (unnamed) value of a subkey; REG_SZ.
    pthread_mutex_lock(&lock);
    load();
    char path[260];
    uint32_t r;
    struct value *v = NULL;
    if (!resolve(key, sub, path, sizeof path)) r = BL_ERROR_INVALID_HANDLE;
    else if (!key_exists(path)) r = BL_ERROR_FILE_NOT_FOUND;
    else if (!(v = find_value(path, ""))) {  // an empty string
        uint32_t room = size ? U32(size) : 0;
        if (size) U32(size) = 1;
        if (!data) r = BL_ERROR_SUCCESS;
        else if (!size) r = BL_ERROR_INVALID_PARAMETER;
        else if (room < 1) r = ERROR_MORE_DATA;
        else *(char *)bl_g2h(data) = 0, r = BL_ERROR_SUCCESS;
    } else {
        r = copy_out(v, 0, data, size);
    }
    if (trace) fprintf(stderr, "[reg] query %s (default) -> %u\n", path, r);
    pthread_mutex_unlock(&lock);
    return r;
}

uint32_t bl_adv_RegSetValueExA_c(uint32_t key, uint32_t name, uint32_t res, uint32_t type, uint32_t data,
                                 uint32_t size)
{
    (void)res;
    pthread_mutex_lock(&lock);
    load();
    char path[260];
    const char *nm = name ? (const char *)bl_g2h(name) : "";
    uint32_t r = BL_ERROR_SUCCESS;
    if (!resolve(key, 0, path, sizeof path)) {
        r = BL_ERROR_INVALID_HANDLE;
    } else {
        struct value *v = find_value(path, nm);
        if (!v) {
            if (nvalues == cap_values)
                values = realloc(values, sizeof *values * (size_t)(cap_values = cap_values ? cap_values * 2 : 64));
            v = &values[nvalues++];
            memset(v, 0, sizeof *v);
            snprintf(v->key, sizeof v->key, "%s", path);
            snprintf(v->name, sizeof v->name, "%s", nm);
        }
        free(v->data);
        v->type = type, v->size = size;
        v->data = malloc(size ? size : 1);
        if (size && data) memcpy(v->data, bl_g2h(data), size);
        add_key(path);
        save();
    }
    if (trace) fprintf(stderr, "[reg] set %s\\%s type %u size %u -> %u\n", path, nm, type, size, r);
    pthread_mutex_unlock(&lock);
    return r;
}

uint32_t bl_adv_RegEnumKeyExA_c(uint32_t key, uint32_t i, uint32_t name, uint32_t nlen, uint32_t r, uint32_t cls,
                                uint32_t clen, uint32_t ft)
{
    (void)r, (void)ft;
    pthread_mutex_lock(&lock);
    load();
    char path[260];
    uint32_t result = ERROR_NO_MORE_ITEMS;
    if (!resolve(key, 0, path, sizeof path)) {
        result = BL_ERROR_INVALID_HANDLE;
    } else {
        size_t pl = strlen(path);
        uint32_t seen = 0;
        for (int k = 0; k < nkeys; k++) {
            const char *p = keys[k];
            if (strncasecmp(p, path, pl) || p[pl] != '\\' || strchr(p + pl + 1, '\\')) continue;  // direct children
            if (seen++ != i) continue;
            const char *child = p + pl + 1;
            uint32_t room = nlen ? U32(nlen) : 0, n = (uint32_t)strlen(child);
            if (room <= n) {
                result = ERROR_MORE_DATA;
            } else {
                memcpy(bl_g2h(name), child, n + 1);
                U32(nlen) = n;
                if (cls && clen && U32(clen)) *(char *)bl_g2h(cls) = 0, U32(clen) = 0;
                result = BL_ERROR_SUCCESS;
            }
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    return result;
}

uint32_t bl_reg_get_dword(const char *path, const char *name, uint32_t def)
{
    pthread_mutex_lock(&lock);
    load();
    const struct value *v = find_value(path, name);
    uint32_t r = def;
    if (v && v->type == 4 && v->size == 4) memcpy(&r, v->data, 4);  // REG_DWORD
    pthread_mutex_unlock(&lock);
    return r;
}

void bl_reg_set_dword(const char *path, const char *name, uint32_t value)
{
    pthread_mutex_lock(&lock);
    load();
    struct value *v = find_value(path, name);
    if (!v) {
        if (nvalues == cap_values)
            values = realloc(values, sizeof *values * (size_t)(cap_values = cap_values ? cap_values * 2 : 64));
        v = &values[nvalues++];
        memset(v, 0, sizeof *v);
        snprintf(v->key, sizeof v->key, "%s", path);
        snprintf(v->name, sizeof v->name, "%s", name);
    }
    free(v->data);
    v->type = 4, v->size = 4;
    v->data = malloc(4);
    memcpy(v->data, &value, 4);
    add_key(path);
    save();
    pthread_mutex_unlock(&lock);
}
