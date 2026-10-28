#!/bin/sh
# Builds the checks in tests/ besides boot (tools/link_boot.sh) and runtime_unit
# (tools/runtime_unit.sh) into native/build/tests/. Building runs none of them; each
# test's header says how to run it.
#
#   shader_test, bsp_check, bake_view, gi_view   from the runtime's sources and objects
#   zlib_pilot, fs_smoke                         with the recompiled modules, linked as boot
#                                                is (left out, with a note, when a module
#                                                is not built)
#
#   tools/build_tests.sh          (after tools/build_runtime.sh)
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/build_lock.sh"  # one build at a time in build/
cd "$HERE/build"
mkdir -p tests
CC="clang -std=c2x -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -fobjc-arc -I../runtime -I../runtime/d3d9 -I runtime"
R=../runtime
# The map hooks bl_bsp.c calls when they are linked in (weak; the game has them, the tools not).
HOOKS="-Wl,-U,_bl_compass_note_map -Wl,-U,_bl_shadow_note_map"
# shellcheck disable=SC2086
$CC ../tests/shader_test.m runtime/libbl_runtime.a -framework Metal -framework Foundation -o tests/shader_test
# shellcheck disable=SC2086
$CC ../tests/bsp_check.c $R/bl_bsp.c $R/bl_props.c $HOOKS -o tests/bsp_check
# shellcheck disable=SC2086
$CC ../tests/bake_view.m $R/d3d9/lm_bake.m $R/d3d9/mtl4.m $R/bl_bsp.c $R/bl_props.c $HOOKS -framework Metal -framework Foundation \
    -framework CoreGraphics -framework ImageIO -o tests/bake_view
# shellcheck disable=SC2086
$CC ../tests/gi_view.m $R/d3d9/gi_probes.m $R/d3d9/lm_bake.m $R/d3d9/mtl4.m $R/bl_bsp.c $R/bl_props.c $HOOKS -framework Metal \
    -framework Foundation -o tests/gi_view
echo "built: shader_test bsp_check bake_view gi_view in $HERE/build/tests"

objs=""
for m in $(grep -v '^#' "$HERE/modules/modules.txt"); do
    if [ ! -f "$m/$m.o" ] || [ ! -f "$m/${m}_exports.o" ]; then
        echo "build_tests: $m is not built (build/$m/$m.o): zlib_pilot and fs_smoke left out" >&2
        exit 0
    fi
    objs="$objs $m/$m.o $m/${m}_exports.o"
done
: > tests/pilot_aliases.txt
for m in $(grep -v '^#' "$HERE/modules/modules.txt"); do
    [ -f "$m/${m}_aliases.txt" ] && cat "$m/${m}_aliases.txt" >> tests/pilot_aliases.txt
done
for t in zlib_pilot fs_smoke; do
    # shellcheck disable=SC2086
    clang -std=c2x -g -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -I../runtime -I runtime ../tests/$t.c $objs \
        -Wl,-export_dynamic -Wl,-force_load,runtime/libbl_runtime.a -Wl,-alias_list,tests/pilot_aliases.txt \
        -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework CoreGraphics \
        -framework CoreText -framework AudioToolbox -framework GameController -framework ImageIO \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo -o tests/$t 2>&1 | grep -v xcrun_db || true
    test -x tests/$t
done
echo "built: zlib_pilot fs_smoke in $HERE/build/tests"
