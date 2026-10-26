// Native replacements for FileSystem_Stdio routines (see native/modules/README.md). Each
// takes the guest CPU, like bl_crt.c.
#include <stdint.h>
#include <string.h>
#include <strings.h>

#include "llasm_cpu.h"
#include "bl_vm.h"

extern char FileSystem_SymbolTable[];  // 0x1000CB20: the global CUtlSymbolTable, made on first use

// The file search's matcher (FileSystem_Stdio 0x10007C40, stdcall: this, pattern, start):
// from element `start` of the file system's tree of pack file entries (this + 0x2C, a
// CUtlRBTree), in order, the first whose name matches "<prefix>[*].<ext>" (ext "*": any),
// or -1. Called for every FindFirst and FindNext over the packs, it walks the tree one
// entry at a time, and the game searches a lot when it starts and opens a map: in
// translated code that was most of the 6 s before the intro movies and of a map's
// loading. The same walk, natively.
//
// Tree elements, 28 bytes: left, right, parent child indices (-1 none), a tag, then the
// entry, whose first field is its name as a CUtlSymbol. A free element's left is its own
// index (returned as it is, like the original). Symbol table: +0x04 its elements (20
// bytes, string offset at +0x10), +0x20 the string pool.
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

    static uint32_t symtab;
    if (!symtab) symtab = bl_call_guest(cpu, bl_h2g(FileSystem_SymbolTable), BL_CDECL, 0, 0, NULL);
    const uint8_t *elems = REG2PTR(*(const uint32_t *)(self + 0x30));
#define E(k) ((const int32_t *)(elems + 28 * (size_t)(k)))
    while (i != -1 && E(i)[0] != i) {
        uint32_t sym = (uint32_t)E(i)[4];
        const char *name = "";
        if (sym != 0xFFFFFFFFu && symtab) {
            const uint8_t *st = REG2PTR(symtab);
            const uint8_t *se = REG2PTR(*(const uint32_t *)(st + 4));
            name = REG2PTR(*(const uint32_t *)(se + 20 * (size_t)sym + 0x10) + *(const uint32_t *)(st + 0x20));
        }
        if (!len || !strncasecmp(name, buf, len)) {
            if (ext[0] == '*') break;
            const char *d = strchr(name, '.');
            if (d && !strcasecmp(d + 1, ext)) break;
        }
        // The next element in order.
        if (E(i)[1] != -1) {
            i = E(i)[1];
            while (E(i)[0] != -1) i = E(i)[0];
        } else {
            int32_t p = E(i)[2];
            while (p != -1 && E(p)[1] == i) i = p, p = E(p)[2];
            i = p;
        }
    }
#undef E
    eax = (uint32_t)i;
}
