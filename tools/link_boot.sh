#!/bin/sh
# Link the boot test (tests/boot.c) with every recompiled module that has been built
# into native/build/<module>/, plus the runtime. A module missing from build/ stops the
# link, unless SKIP names it.
#
#   tools/link_boot.sh            -> native/build/tests/boot
#   SKIP="Mss32 binkw32" tools/link_boot.sh   leaves those modules out
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/build_lock.sh"  # one build at a time in build/
cd "$HERE/build"
objs=""
mkdir -p tests
: > tests/aliases.txt
for m in $(grep -v '^#' "$HERE/modules/modules.txt"); do
    case " $SKIP " in *" $m "*) echo "link_boot: $m skipped" >&2; continue ;; esac
    if [ -f "$m/$m.o" ] && [ -f "$m/${m}_exports.o" ]; then
        objs="$objs $m/$m.o $m/${m}_exports.o"
        [ -f "$m/${m}_aliases.txt" ] && cat "$m/${m}_aliases.txt" >> tests/aliases.txt
    else
        echo "link_boot: $m is not built (build/$m/$m.o); build it, or name it in SKIP to leave it out" >&2
        exit 1
    fi
done
rm -f tests/boot
# shellcheck disable=SC2086
clang -std=c2x -g -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -I../runtime -I runtime \
    ../tests/boot.c $objs -Wl,-export_dynamic -Wl,-force_load,runtime/libbl_runtime.a -Wl,-alias_list,tests/aliases.txt \
    -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework CoreGraphics -framework CoreText -framework AudioToolbox -framework GameController -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo -o tests/boot 2>&1 | grep -v xcrun_db || true
test -x tests/boot
echo "built: $HERE/build/tests/boot"
