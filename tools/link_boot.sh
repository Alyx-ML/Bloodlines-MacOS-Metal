#!/bin/sh
# Link the boot test (tests/boot.c) with every recompiled module that has been built
# into native/build/<module>/, plus the runtime. Modules missing from build/ are
# skipped with a note; the boot then stops where the game loads them.
#
#   tools/link_boot.sh            -> native/build/tests/boot
#   SKIP="Mss32 binkw32" tools/link_boot.sh   leaves those modules out
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
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
        echo "link_boot: $m not built, skipped" >&2
    fi
done
rm -f tests/boot
# shellcheck disable=SC2086
clang -std=c2x -g -O2 -arch arm64 -mmacosx-version-min=14.0 -Wall -I../runtime -I runtime \
    ../tests/boot.c $objs -Wl,-export_dynamic -Wl,-force_load,runtime/libbl_runtime.a -Wl,-alias_list,tests/aliases.txt \
    -framework Metal -framework QuartzCore -framework AppKit -framework CoreGraphics -framework CoreText -framework AudioToolbox -framework GameController -framework ImageIO -o tests/boot 2>&1 | grep -v xcrun_db || true
test -x tests/boot
echo "built: $HERE/build/tests/boot"
