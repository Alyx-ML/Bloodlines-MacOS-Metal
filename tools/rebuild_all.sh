#!/bin/sh
# Re-translate game modules from their DLLs (full pipeline, SRW included).
#   rebuild_all.sh <game dir> [module ...]     default: every module in modules/modules.txt
# The DLL for each module is the file of that name (.dll, or .asi for the Miles
# providers) under <game dir> whose SHA-256 is
# pinned in modules/hashes.txt (the Unofficial Patch replaces some of the originals).
# Prints one line per module with its time; stops at the first failure.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GAME="$(cd "$1" && pwd)"
shift
MODULES="$*"
[ -n "$MODULES" ] || MODULES="$(grep -v '^#' "$HERE/modules/modules.txt")"
mkdir -p "$HERE/build/logs"
for m in $MODULES; do
    want="$(awk -v m="$m" '$2 == m { print $1 }' "$HERE/modules/hashes.txt")"
    src=""
    for f in $(find "$GAME" -path "$HERE" -prune -o \( -iname "$m.dll" -o -iname "$m.asi" \) -print | tr ' ' '\001'); do
        f="$(printf '%s' "$f" | tr '\001' ' ')"
        [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$want" ] && { src="$f"; break; }
    done
    if [ -z "$src" ]; then echo "$m: no DLL with the pinned hash under $GAME"; exit 1; fi
    start=$(date +%s)
    if sh "$HERE/tools/recompile_module.sh" "$src" "$m" > "$HERE/build/logs/$m.log" 2>&1; then
        echo "$m: ok, $(( $(date +%s) - start )) s"
    else
        echo "$m: FAILED after $(( $(date +%s) - start )) s (build/logs/$m.log)"
        grep -v xcrun "$HERE/build/logs/$m.log" | tail -5
        exit 1
    fi
done
