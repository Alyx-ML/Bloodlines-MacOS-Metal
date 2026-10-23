"""Prepare SR's x87 helpers for inlining into translated modules.

The translated code calls helpers that take a float_int union with an i32 argument, but
clang passes a 4-byte union as i64 on arm64, and LLVM does not inline calls whose
type differs from the callee's. Take the bits as uint32_t instead.
    sr_inline_prep.py <llasm_float.c> <out.c>
"""
import re
import sys

src = open(sys.argv[1]).read()
pattern = re.compile(r'(EXTERNC [^\n(]+\(CPU, )float_int num\)\n\{\n')
out, n = pattern.subn(r'\1uint32_t num_bits)\n{\n    float_int num;\n    num.i = (int32_t)num_bits;\n', src)
if n == 0 or 'float_int num)' in out:
    sys.exit('sr_inline_prep: unexpected llasm_float.c layout')
open(sys.argv[2], 'w').write(out)
