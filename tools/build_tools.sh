#!/bin/sh
# Build SRW (llasm output) and llasm from native/third_party/SR into native/build/tools.
# Paths are kept relative inside $OUT because the project path contains spaces.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/build_lock.sh"  # one build at a time in build/
SR="$HERE/third_party/SR"
OUT="$HERE/build/tools"
mkdir -p "$OUT"
cd "$OUT"

# SRW: copy sources so SR_defs.h can be switched to OUT_LLASM without touching upstream.
rm -rf srw-src srw-obj
cp -R "$SR/SRW" srw-src
cp -R "$HERE/tools/compat" srw-src/compat
sed -i '' 's/^#define OUTPUT_TYPE  OUT_X86$/#define OUTPUT_TYPE  OUT_LLASM/' srw-src/SR_defs.h
grep -q '^#define OUTPUT_TYPE  OUT_LLASM$' srw-src/SR_defs.h
# Local SRW changes (ordinal imports get <dll>_ord<N> names).
patch -s -d srw-src -p2 < "$HERE/tools/srw-macos.patch"
# Code-section data keeps its original offsets (see the patch).
patch -s -d srw-src -p2 < "$HERE/tools/srw-layout.patch"
# x87 stores to [base + index*scale] keep the value out of tmp0, which the address uses.
patch -s -d srw-src -p2 < "$HERE/tools/srw-x87-store.patch"
mkdir -p srw-obj
cd srw-src
INC="-DHAVE_STRING_H=1 -Iudis86-1.7.2 -Icompat"
for f in *.c udis86-1.7.2/libudis86/*.c; do
    clang -O2 -w $INC -c "$f" -o "../srw-obj/$(echo "$f" | tr / _).o"
done
clang++ -O2 -std=c++20 -w $INC -c container_helpers.cpp -o ../srw-obj/container_helpers.o
cd ..
clang++ -o SRW srw-obj/*.o

# llasm (D, LDC)
ldc2 -O2 "$SR/llasm/llasm.d" --of=llasm --od=llasm-obj
echo "built: $OUT/SRW $OUT/llasm"
