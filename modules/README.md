# Per-module SRW inputs

`<module>/*.sci` files are copied into `build/<module>/` before SRW runs.
Write hand-made fixes here; the pipeline generates the rest.

- `external_procedures.sci`: `loc_<addr>,bl_crt_<name>` replaces a statically linked
  MSVC C-runtime routine with the runtime's native version (`runtime/bl_crt.c`,
  `runtime/llasm/crt.llasm`). Used for hand-written CRT assembly SRW cannot
  translate, such as math helpers that return results in CPU flags across a call.
- `ignored_areas.sci`: `loc_<addr>,<length>` bytes SRW must not translate (the
  replaced routine's body).

## vstdlib
- `0x100048D0` `_CIsqrt`, `0x100048E4` `sqrt` and their shared worker up to
  `0x10004989` (186 bytes).
