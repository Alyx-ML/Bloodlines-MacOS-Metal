// Native replacements for FileSystem_Stdio routines (see native/modules/README.md). Each
// takes the guest CPU, like bl_crt.c.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "llasm_cpu.h"
#include "bl_vm.h"

extern char FileSystem_SymbolTable[];  // 0x1000CB20: the global CUtlSymbolTable, made on first use

// The file search's matcher (FileSystem_Stdio 0x10007C40, stdcall: this, pattern, start):
// from element `start` of the file system's tree of pack file entries (this + 0x2C, a
// CUtlRBTree), in order, the first whose name matches "<prefix>[*].<ext>" (ext "*": any),
// or -1. Called for every FindFirst and FindNext over the packs, once per pack file (about
// a hundred), and the game searches a lot when it starts and opens a map (some 86,000
// calls for a start and one load).
//
// The tree isn't in name order, so the original walks a whole pack's tree, up to 14,000
// entries, for each call: 188 million steps for a start and one load, over a second of the
// load itself. Instead each tree gets an index once (its entries in tree order, and their
// names lowercased and sorted), and each pattern its matches once per tree: their places in
// tree order, sorted, so a call is a binary search. The index is made again when the tree's
// header (its elements' memory, root and counts) changes.
//
// Tree elements, 28 bytes: left, right, parent child indices (-1 none), a tag, then the
// entry, whose first field is its name as a CUtlSymbol. A free element's left is its own
// index (returned as it is, like the original). Symbol table: +0x04 its elements (20
// bytes, string offset at +0x10), +0x20 the string pool.
#define TREE_HEADER 0x30  // this + 0x30: the elements' memory (pointer, count, grow), root, counts
#define TREE_HEADER_SIZE 28

struct fm_name {
    const char *name;  // lowercased, in the index's pool
    int32_t at;        // its place in tree order
};

struct fm_tree {
    const uint8_t *self;
    uint8_t header[TREE_HEADER_SIZE];
    int32_t n, cap;         // entries; elements covered by `place`
    int32_t *order;         // tree order -> element
    int32_t *place;         // element -> place in tree order (-1: not in the tree)
    struct fm_name *names;  // sorted by name
    char *pool;
    char *pattern;    // the last pattern's
    int32_t *hits, nhits;  // places in tree order, ascending
};

static struct fm_tree *trees;
static int ntrees, trees_cap;

#define E(k) ((const int32_t *)(elems + 28 * (size_t)(k)))

static const char *entry_name(_cpu *cpu, uint32_t symtab, const uint8_t *elems, int32_t k)
{
    uint32_t sym = (uint32_t)E(k)[4];
    if (sym == 0xFFFFFFFFu || !symtab) return "";
    const uint8_t *st = REG2PTR(symtab);
    const uint8_t *se = REG2PTR(*(const uint32_t *)(st + 4));
    return REG2PTR(*(const uint32_t *)(se + 20 * (size_t)sym + 0x10) + *(const uint32_t *)(st + 0x20));
}

static int by_name(const void *a, const void *b)
{
    return strcmp(((const struct fm_name *)a)->name, ((const struct fm_name *)b)->name);
}

static int by_place(const void *a, const void *b)
{
    int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
    return (x > y) - (x < y);
}

// The tree in order from any element in it: up to the root, down to the first, then on.
static void index_tree(_cpu *cpu, struct fm_tree *t, uint32_t symtab, const uint8_t *elems, int32_t any)
{
    free(t->order), free(t->place), free(t->names), free(t->pool), free(t->pattern), free(t->hits);
    t->order = t->place = t->hits = NULL, t->names = NULL, t->pool = t->pattern = NULL;
    t->n = t->cap = t->nhits = 0;
    memcpy(t->header, t->self + TREE_HEADER, TREE_HEADER_SIZE);

    int32_t i = any;
    while (E(i)[2] != -1) i = E(i)[2];
    while (E(i)[0] != -1) i = E(i)[0];
    int32_t cap = 0, n = 0;
    size_t pool = 0;
    for (int32_t k = i; k != -1;) {  // count first
        n++, pool += strlen(entry_name(cpu, symtab, elems, k)) + 1;
        if (k >= cap) cap = k + 1;
        if (E(k)[1] != -1) {
            k = E(k)[1];
            while (E(k)[0] != -1) k = E(k)[0];
        } else {
            int32_t p = E(k)[2];
            while (p != -1 && E(p)[1] == k) k = p, p = E(p)[2];
            k = p;
        }
    }
    t->n = n, t->cap = cap;
    t->order = malloc(sizeof *t->order * (size_t)n);
    t->place = malloc(sizeof *t->place * (size_t)cap);
    t->names = malloc(sizeof *t->names * (size_t)n);
    t->pool = malloc(pool);
    memset(t->place, 0xFF, sizeof *t->place * (size_t)cap);
    char *s = t->pool;
    int32_t at = 0;
    for (int32_t k = i; k != -1; at++) {
        t->order[at] = k, t->place[k] = at;
        const char *name = entry_name(cpu, symtab, elems, k);
        t->names[at].name = s, t->names[at].at = at;
        while (*name) *s++ = (char)(*name >= 'A' && *name <= 'Z' ? *name + 32 : *name), name++;
        *s++ = 0;
        if (E(k)[1] != -1) {
            k = E(k)[1];
            while (E(k)[0] != -1) k = E(k)[0];
        } else {
            int32_t p = E(k)[2];
            while (p != -1 && E(p)[1] == k) k = p, p = E(p)[2];
            k = p;
        }
    }
    qsort(t->names, (size_t)n, sizeof *t->names, by_name);
}

// The places in tree order of the names starting with `prefix` (lowercase, `len` long)
// whose extension (after the name's first dot) is `ext`, or any with "*".
static void find_hits(struct fm_tree *t, const char *pattern, const char *prefix, size_t len, const char *ext)
{
    free(t->pattern), free(t->hits);
    t->pattern = strdup(pattern), t->hits = NULL, t->nhits = 0;
    int32_t lo = 0, hi = t->n;  // the first name not below the prefix
    while (lo < hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (strncmp(t->names[mid].name, prefix, len) < 0) lo = mid + 1;
        else hi = mid;
    }
    int32_t cap = 0;
    for (int32_t k = lo; k < t->n && !strncmp(t->names[k].name, prefix, len); k++) {
        if (ext[0] != '*') {
            const char *d = strchr(t->names[k].name, '.');
            if (!d || strcasecmp(d + 1, ext)) continue;
        }
        if (t->nhits == cap) t->hits = realloc(t->hits, sizeof *t->hits * (size_t)(cap = cap ? 2 * cap : 16));
        t->hits[t->nhits++] = t->names[k].at;
    }
    qsort(t->hits, (size_t)t->nhits, sizeof *t->hits, by_place);
}

void bl_fs_FindMatch_c(_cpu *cpu)
{
    const uint32_t *args = REG2PTR(esp + 4);
    const uint8_t *self = REG2PTR(args[0]);
    const char *pattern = REG2PTR(args[1]);
    int32_t i = (int32_t)args[2];

    char buf[1024];
    size_t n = strlen(pattern);
    if (n >= sizeof buf) n = sizeof buf - 1;
    memcpy(buf, pattern, n), buf[n] = 0;
    char *dot = strchr(buf, '.');
    if (!dot) {
        eax = 0xFFFFFFFFu;
        return;
    }
    *dot = 0;
    const char *ext = dot + 1;
    char *star = strchr(buf, '*');
    if (star) *star = 0;
    size_t len = strlen(buf);
    if (!len && ext[0] == '*') {
        eax = (uint32_t)i;
        return;
    }
    const uint8_t *elems = REG2PTR(*(const uint32_t *)(self + 0x30));
    if (i == -1 || E(i)[0] == i) {
        eax = (uint32_t)i;
        return;
    }

    static uint32_t symtab;
    if (!symtab) symtab = bl_call_guest(cpu, bl_h2g(FileSystem_SymbolTable), BL_CDECL, 0, 0, NULL);
    struct fm_tree *t = NULL;
    for (int k = 0; k < ntrees && !t; k++)
        if (trees[k].self == self) t = &trees[k];
    if (!t) {
        if (ntrees == trees_cap) trees = realloc(trees, sizeof *trees * (size_t)(trees_cap = trees_cap ? 2 * trees_cap : 128));
        t = &trees[ntrees++];
        memset(t, 0, sizeof *t);
        t->self = self;
        index_tree(cpu, t, symtab, elems, i);
    } else if (memcmp(t->header, self + TREE_HEADER, TREE_HEADER_SIZE) || i >= t->cap || t->place[i] < 0) {
        index_tree(cpu, t, symtab, elems, i);
    }
    if (!t->pattern || strcmp(t->pattern, pattern)) {
        for (char *c = buf; *c; c++)
            if (*c >= 'A' && *c <= 'Z') *c += 32;
        find_hits(t, pattern, buf, len, ext);
    }
    int32_t from = t->place[i], lo = 0, hi = t->nhits;  // the first hit at or after `from`
    while (lo < hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (t->hits[mid] < from) lo = mid + 1;
        else hi = mid;
    }
    eax = lo < t->nhits ? (uint32_t)t->order[t->hits[lo]] : 0xFFFFFFFFu;
}
#undef E
