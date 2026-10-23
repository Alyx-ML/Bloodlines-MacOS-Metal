#!/bin/sh
# Recompile one game PE module to an arm64 object.
#   recompile_module.sh <game-file.dll> <name>
# CODEGEN_ONLY=1 reuses the existing <name>.ll and _exports.c and redoes only opt/llc.
# Output: native/build/<name>/<name>.o (contains the game's code: never distribute).
# Hand-written fixes go in native/modules/<name>/*.manual.sci and are merged in.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"  # absolute: the script changes directory
NAME="$2"
OUT="$HERE/build/$NAME"
LLVM=/opt/homebrew/opt/llvm/bin
ARM64_DL='e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32'

# Only the pinned game files are supported (native/modules/hashes.txt).
SUM="$(shasum -a 256 "$SRC" | cut -d' ' -f1)"
if ! grep -q "^$SUM  $NAME\$" "$HERE/modules/hashes.txt"; then
    echo "error: $SRC is not a supported $NAME (sha256 $SUM)" >&2
    exit 2
fi

mkdir -p "$OUT"
cd "$OUT"
if [ -z "$CODEGEN_ONLY" ]; then
rm -f ./*.sci seg*.llinc extern.llinc "$NAME.llasm" "$NAME.ll" "$NAME.o" "${NAME}_exports".*
cp "$SRC" "$NAME.pe"
python3 -I "$HERE/tools/widen_sections.py" "$NAME.pe"
if [ -d "$HERE/modules/$NAME" ]; then
    for f in "$HERE/modules/$NAME"/*.sci; do [ -e "$f" ] && cp "$f" .; done
fi

# DLL entry point as global proc <name>_DllEntry, for the loader (bl_call_guest).
python3 -I -c 'import struct,sys
d=open(sys.argv[1],"rb").read(); pe=struct.unpack_from("<I",d,0x3C)[0]
rva,base=struct.unpack_from("<I",d,pe+40)[0],struct.unpack_from("<I",d,pe+52)[0]
rva and print(f"loc_{base+rva:X},{sys.argv[2]}_DllEntry")' "$NAME.pe" "$NAME" >> global_aliases.manual.sci

echo "PROGRESS 5 CRT signatures $NAME"
python3 -I "$HERE/tools/crt_sigs.py" scan "$NAME.pe" .

echo "PROGRESS 10 SRW $NAME"
# SRW, then seed code pointers it emitted as data; repeat until no new seeds.
pass=1
while :; do
    status=0
    python3 -I "$HERE/tools/fix_region_flags.py" "$HERE/build/tools/SRW" "$NAME.pe" "$NAME.llasm" . > srw-fix.log 2> srw.err || status=$?
    tail -1 srw-fix.log
    if [ "$status" -ne 0 ]; then grep -m3 'Error' srw.err; exit "$status"; fi
    python3 -I "$HERE/tools/seed_code_pointers.py" "$NAME.pe" . || status=$?
    [ "$status" -eq 0 ] && break
    [ "$status" -ne 10 ] && exit "$status"
    pass=$((pass + 1))
    [ "$pass" -gt 16 ] && { echo "code pointer seeding did not converge"; exit 1; }
done

python3 -I "$HERE/tools/append_section_tail.py" "$NAME.pe" .

echo "PROGRESS 40 imports $NAME"
python3 -I "$HERE/tools/gen_extern.py" . "$NAME.llasm" "$NAME" "$NAME.pe"

echo "PROGRESS 50 llasm $NAME"
"$HERE/build/tools/llasm" -m64 -ptrofs -O -I . -I "$HERE/third_party/SR/SR/llasm-support" \
    -I "$HERE/runtime/llasm" "$NAME.llasm" -o "$NAME.ll" 2>&1 | grep -v '^Replacing datasegment' || true
test -s "$NAME.ll"
fi

echo "PROGRESS 70 opt+llc $NAME"
# opt and llc are single-threaded: split the module and compile the parts on every core.
JOBS=$(getconf _NPROCESSORS_ONLN)
rm -f "$NAME".part*
python3 -I "$HERE/tools/table_init_pointers.py" "$NAME.ll"
# Keep a local symbol per translated proc (loc_<original VA>) so crash reports and
# traces name the original code; private symbols leave the object entirely.
sed -i '' 's/^define private fastcc void @loc_/define internal fastcc void @loc_/' "$NAME.ll"
"$LLVM/llvm-split" -j "$JOBS" -o "$NAME.part" "$NAME.ll"
# SR_INLINE=1 links in the x87 helpers (build_runtime.sh) as internal copies for opt to
# inline. Off by default: measured on sp_theatre it was about 6% slower than calls,
# since the cost is in the helpers' memory-based x87 stack, not the call.
INLINE="$HERE/build/runtime/sr_inline.bc"
[ -z "$SR_INLINE" ] || test -s "$INLINE"
export LLVM ARM64_DL INLINE SR_INLINE
ls "$NAME".part* | xargs -P "$JOBS" -I{} sh -c 'if [ -z "$SR_INLINE" ]; then cp "$1" "$1.linked.bc"; else
    "$LLVM/llvm-link" --only-needed --internalize "$1" "$INLINE" -o "$1.linked.bc"; fi &&
    "$LLVM/opt" -O2 -mtriple=arm64-apple-macos14 --data-layout="$ARM64_DL" "$1.linked.bc" -o "$1.bc" &&
    "$LLVM/llc" -O2 -mtriple=arm64-apple-macos14 -filetype=obj "$1.bc" -o "$1.o"' sh {}
ld -r -arch arm64 -o "$NAME.o" "$NAME".part*.o
rm -f "$NAME".part*
clang -std=c2x -O2 -arch arm64 -mmacosx-version-min=14.0 -Wall -I../../runtime -I../../third_party/SR/SR/llasm-support \
    -DPTROFS_64BIT=1 -c "${NAME}_exports.c" -o "${NAME}_exports.o"
echo "PROGRESS 100 $OUT/$NAME.o"
