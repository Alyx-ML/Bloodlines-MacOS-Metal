#!/bin/sh
# Build and run tests/runtime_unit.c: runtime checks that need no game files, linked
# with the runtime's own objects (tools/build_runtime.sh builds them first).
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/build_lock.sh"  # one build at a time in build/
OBJ="$HERE/build/runtime/obj"
OUT="$HERE/build/tests"
mkdir -p "$OUT"
cd "$HERE/build/runtime"
clang -std=c2x -O1 -arch arm64 -mmacosx-version-min=26.0 -Wall -DPTROFS_64BIT=1 -I. \
    -I"$HERE/runtime" -I"$HERE/runtime/d3d9" "$HERE/tests/runtime_unit.c" \
    "$OBJ/bl_codepage.o" "$OBJ/bl_thread.o" "$OBJ/dinput8.o" "$OBJ/d3d9_shader.o" -o "$OUT/runtime_unit"
"$OUT/runtime_unit"
