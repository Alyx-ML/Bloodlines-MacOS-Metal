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
# FSR 4 (third_party/fsr4metal, kept out of git: FSR4Metal's code is GPL and its model AMD's)
# goes into the game only, never the runtime library, and its model to build/fsr4_assets.
# Without it the game is linked with its functions null (-U, weak in metal_render.m).
FSR4="$HERE/third_party/fsr4metal"
FSR4_U="-Wl,-U,_fsr4mtl_create -Wl,-U,_fsr4mtl_encode -Wl,-U,_fsr4mtl_error -Wl,-U,_fsr4mtl_describe"
if [ -f "$FSR4/src/FSR4Metal.mm" ]; then
    mkdir -p fsr4
    if [ ! -f fsr4/FSR4Metal.o ] || [ "$FSR4/src/FSR4Metal.mm" -nt fsr4/FSR4Metal.o ]; then
        clang++ -std=c++20 -O2 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -w -I"$FSR4/include" \
            -c "$FSR4/src/FSR4Metal.mm" -o fsr4/FSR4Metal.o
    fi
    rsync -a --delete "$FSR4/assets/" fsr4_assets/
    objs="$objs fsr4/FSR4Metal.o -lc++"
else
    echo "link_boot: no third_party/fsr4metal, so the game has no FSR 4" >&2
fi
rm -f tests/boot
# shellcheck disable=SC2086
clang -std=c2x -g -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -I../runtime -I runtime \
    ../tests/boot.c $objs $FSR4_U -Wl,-export_dynamic -Wl,-force_load,runtime/libbl_runtime.a -Wl,-alias_list,tests/aliases.txt \
    -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework CoreGraphics -framework CoreText -framework AudioToolbox -framework GameController -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo -lcompression -lz -o tests/boot 2>&1 | grep -v xcrun_db || true
test -x tests/boot
echo "built: $HERE/build/tests/boot"
