#!/bin/sh
# Build the native runtime (C helpers, SR llasm support, import thunks) into
# native/build/runtime/libbl_runtime.a. Contains no game code.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/build_lock.sh"  # one build at a time in build/
OUT="$HERE/build/runtime"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"  # set LLVM to use another LLVM install
if [ ! -x "$LLVM/opt" ]; then
    echo "error: no LLVM opt at $LLVM/opt (install Homebrew llvm, or set LLVM to its bin folder)" >&2
    exit 1
fi
ARM64_DL='e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32'
SUPPORT="$HERE/third_party/SR/SR/llasm-support"
mkdir -p "$OUT/obj"
cd "$OUT"
rm -f obj/*.o libbl_runtime.a

python3 -I "$HERE/tools/gen_imports.py" "$HERE/runtime/imports.def" imports.llasm imports_names.h
python3 -I "$HERE/tools/gen_com.py" "$HERE/runtime/d3d9/com.def" com.llasm com_gen.c com_gen.h
# The quest compass's Python (bl_compass.c): its quest tables, then the code that reads them.
# json.dumps makes a valid C string only from printable ASCII, tabs and newlines (its
# \uXXXX escapes are not C), so any other character in these files stops the build.
python3 -I -c 'import sys, json
src = "".join(open(f, encoding="utf-8").read() + "\n" for f in sys.argv[1:])
if any(not (" " <= c <= "~" or c in "\t\n\r") for c in src):
    sys.exit("error: the compass Python files must be plain ASCII text (json.dumps cannot make a C string of the rest)")
print("static const char compass_py[] = %s;" % json.dumps(src))' \
    "$HERE"/runtime/compass_quests_*.py "$HERE/runtime/compass.py" > compass_py.h

# Relative include path: the project path contains spaces.
# C23 because SR's llasm_cpu.h uses nullptr.
CFLAGS="-std=c2x -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -DPTROFS_64BIT=1 -I. -I../../third_party/SR/SR/llasm-support"
for f in "$HERE"/runtime/*.c "$HERE"/runtime/d3d9/*.c com_gen.c; do
    clang $CFLAGS -I"$HERE/runtime" -I"$HERE/runtime/d3d9" -c "$f" -o "obj/$(basename "$f" .c).o"
done
for f in "$HERE"/runtime/*.m "$HERE"/runtime/d3d9/*.m; do
    clang $CFLAGS -fobjc-arc -I"$HERE/runtime" -I"$HERE/runtime/d3d9" -c "$f" -o "obj/$(basename "$f" .m).o"
done
# SR's x86 helper routines (division, x87, string instructions, ...), with our fixes.
rm -rf sr-src && mkdir sr-src && cp "$SUPPORT"/llasm_*.c sr-src/
# The x87 condition codes survive the instructions between fcom and fnstsw.
patch -s -d sr-src -p1 < "$HERE/tools/sr-x87-flags.patch"
for f in sr-src/llasm_*.c; do
    clang $CFLAGS -w -c "$f" -o "obj/sr_$(basename "$f" .c).o"
done
# The x87 helpers again as bitcode, for recompile_module.sh with SR_INLINE=1 (inlined
# into each module; measured slower, so not the default).
python3 -I "$HERE/tools/sr_inline_prep.py" sr-src/llasm_float.c sr-src/llasm_float_inline.c
"$LLVM/clang" $CFLAGS -w -isysroot "$(xcrun --show-sdk-path)" -I"$SUPPORT" -emit-llvm -c sr-src/llasm_float_inline.c -o sr_inline.bc

# llasm thunks: generated import table plus hand-written runtime entry points.
cp "$HERE"/runtime/llasm/*.llasm .  # com.llasm is generated above
for f in *.llasm; do
    b="${f%.llasm}"
    "$HERE/build/tools/llasm" -m64 -ptrofs -O -I "$SUPPORT" -I "$HERE/runtime/llasm" "$f" -o "$b.ll"
    "$LLVM/opt" -O2 -mtriple=arm64-apple-macos26 --data-layout="$ARM64_DL" "$b.ll" -o "$b.bc"
    "$LLVM/llc" -O2 -mtriple=arm64-apple-macos26 -filetype=obj "$b.bc" -o "obj/llasm_$b.o"
done

rm -f libbl_runtime.a.tmp
ar rcs libbl_runtime.a.tmp obj/*.o
mv libbl_runtime.a.tmp libbl_runtime.a
echo "built: $OUT/libbl_runtime.a"
