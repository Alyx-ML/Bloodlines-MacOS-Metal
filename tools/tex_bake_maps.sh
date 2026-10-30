#!/bin/sh
# Bake the surfaces' PBRify maps for the GPU (tools/tex_bake_maps.m): every <name>_n.png
# and <name>_h.png under build/textures/maps gets its <name>_n.tex / <name>_h.tex. Run it
# after making or changing maps; only the ones whose PNGs changed are baked again.
#   tex_bake_maps.sh [--force] [--only <png>]
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build/tools"
BIN="$OUT/tex_bake_maps"
mkdir -p "$OUT"
SRC="$HERE/tools/tex_bake_maps.m $HERE/runtime/d3d9/map_levels.m $HERE/runtime/d3d9/map_levels.h $HERE/tools/bc7_encode.c"
stale=0
[ -x "$BIN" ] || stale=1
for f in $SRC; do [ "$f" -nt "$BIN" ] && stale=1; done
if [ $stale = 1 ]; then
    clang -O3 -fobjc-arc -I"$HERE/runtime/d3d9" -framework Foundation -framework ImageIO -framework CoreGraphics \
        "$HERE/tools/tex_bake_maps.m" "$HERE/runtime/d3d9/map_levels.m" "$HERE/tools/bc7_encode.c" -o "$BIN"
fi
exec "$BIN" "$@" "$HERE/build/textures/maps"
