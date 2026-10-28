#!/usr/bin/env python3
"""Rewrite llasm's @initialize_pointers in a module's .ll as a table and a loop.

llasm emits the relocation of every pointer in the module's data as two
instructions in one basic block:

    %N = sub i32 ptrtoint (<type>* @sym to i32), %1
    store i32 %N, i32* <address in the module's sections>, align A

The big modules have ~150,000 of these. LLVM's instruction selection works per basic
block and is far from linear, so llc spends tens of minutes on this one function. The
rewrite keeps the same stores, in the same order, as a loop over two constant arrays:
the pointers and the addresses they are stored to.

usage: table_init_pointers.py <module.ll>   (rewritten in place)
"""
import os
import re
import sys

HEAD = "define private ccc void @initialize_pointers(i64 %ptrofs) nounwind {"
SUB = re.compile(r"^%(\d+) = sub i32 ptrtoint \((.+?) (@[\w.$]+) to i32\), %1$")
STORE = re.compile(r"^store i32 %(\d+), i32\* (.+), align \d+$")


def main():
    path = sys.argv[1]
    lines = open(path).read().split("\n")
    try:
        start = lines.index(HEAD)
    except ValueError:
        return 0  # no data pointers in this module
    end = next(i for i in range(start, len(lines)) if lines[i] == "}")
    body = lines[start + 1:end]
    if body[0] == "entry:":
        return 0  # already rewritten
    if body[0] != "%1 = trunc i64 %ptrofs to i32":
        sys.exit("table_init_pointers: unexpected first line: " + body[0])

    values, pairs, k = {}, [], 1
    while k < len(body):
        if m := SUB.match(body[k]):
            values[m.group(1)] = m.group(3)
        elif m := STORE.match(body[k]):
            if m.group(1) not in values:
                sys.exit("table_init_pointers: store of unknown value: " + body[k])
            pairs.append((values.pop(m.group(1)), m.group(2)))
        else:
            break  # the tail: chaining to the previous initializer
        k += 1
    if values:
        sys.exit(f"table_init_pointers: {len(values)} values never stored")
    if not pairs:
        return 0
    tail = [re.sub(r"%(\d+)", r"%t\1", line) for line in body[k:]]

    n = len(pairs)
    out = [
        f"@bl_ptrinit_src = private constant [{n} x ptr] [" + ", ".join(f"ptr {s}" for s, _ in pairs) + "]",
        f"@bl_ptrinit_dst = private constant [{n} x ptr] [" + ", ".join(f"ptr {d}" for _, d in pairs) + "]",
        "define private ccc void @initialize_pointers(i64 %ptrofs) nounwind {",
        "entry:",
        "%ofs = trunc i64 %ptrofs to i32",
        "br label %loop",
        "loop:",
        "%i = phi i64 [0, %entry], [%next, %loop]",
        f"%sp = getelementptr [{n} x ptr], ptr @bl_ptrinit_src, i64 0, i64 %i",
        "%s = load ptr, ptr %sp, align 8",
        f"%dp = getelementptr [{n} x ptr], ptr @bl_ptrinit_dst, i64 0, i64 %i",
        "%d = load ptr, ptr %dp, align 8",
        "%si = ptrtoint ptr %s to i32",
        "%v = sub i32 %si, %ofs",
        "store i32 %v, ptr %d, align 1",
        "%next = add i64 %i, 1",
        f"%done = icmp eq i64 %next, {n}",
        "br i1 %done, label %tail, label %loop",
        "tail:",
    ] + tail + ["}"]
    lines[start:end + 1] = out
    # Write a temporary file, then rename: an interrupted run leaves the .ll intact.
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.replace(tmp, path)
    print(f"initialize_pointers: {n} pointers as a table")
    return 0


if __name__ == "__main__":
    sys.exit(main())
