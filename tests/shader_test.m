// Translates D3D9 shader bytecode files (vs_*.bin / ps_*.bin, as BL_DUMP_SHADERS
// writes them) to MSL and compiles each with Metal, in the default variant and the
// variants the renderer can ask for: every sampler cube or volume, ps_1_x texcoords
// projected, vertex inputs integer, sampler 0 reading a lightmap page (smooth, and from the
// lighting rebake's page). Needs GPU access.
//   shader_test <dir> [-v]     -v prints the MSL of failures
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "d3d9_shader.h"

static uint32_t *load(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint32_t *t = malloc((size_t)n + 4);
    if (fread(t, 1, (size_t)n, f) != (size_t)n) n = 0;
    fclose(f);
    t[n / 4] = 0x0000FFFF;
    return t;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dir> [-v]\n", argv[0]);
        return 2;
    }
    int verbose = argc > 2 && !strcmp(argv[2], "-v");
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        fprintf(stderr, "no Metal device\n");
        return 1;
    }
    DIR *d = opendir(argv[1]);
    if (!d) return 1;
    int ok = 0, bad = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strstr(e->d_name, ".bin")) continue;
        char path[2048], err[256] = "";
        snprintf(path, sizeof path, "%s/%s", argv[1], e->d_name);
        uint32_t *code = load(path);
        struct d3d_shader_variant vars[8];
        memset(vars, 0, sizeof vars);
        for (int i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++) {
            vars[1].tex_kind[i] = D3D_TEX_CUBE, vars[2].tex_kind[i] = D3D_TEX_3D;
            vars[3].projected[i] = 3, vars[4].projected[i] = 4;
        }
        for (int i = 0; i < D3D_SHADER_MAX_INPUTS; i++) vars[1].input_kind[i] = D3D_IN_UINT, vars[2].input_kind[i] = D3D_IN_SINT;
        vars[5].reflection_info = vars[5].albedo = vars[5].surface = 1;
        vars[6].lightmap = vars[7].lightmap = 1, vars[7].rebake = 1;
        static const char *const names[] = {"default", "cube/uint", "volume/sint", "projected3", "projected4",
                                            "info/albedo/surface", "lightmap", "lightmap/rebake"};
        for (int k = 0; k < 8; k++) {
            char *msl = d3d_shader_msl(code, k ? &vars[k] : NULL, err, sizeof err);
            if (!msl) {
                printf("FAIL translate %s (%s): %s\n", e->d_name, names[k], err);
                bad++;
                continue;
            }
            @autoreleasepool {
                NSError *error = nil;
                MTLCompileOptions *opt = [MTLCompileOptions new];  // as the renderer compiles
                opt.mathMode = MTLMathModeSafe;
                id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:opt
                                                         error:&error];
                if (!lib || ![lib newFunctionWithName:@"bl_main"]) {
                    printf("FAIL compile %s (%s): %s\n", e->d_name, names[k], error.localizedDescription.UTF8String);
                    if (verbose) printf("%s\n", msl);
                    bad++;
                } else {
                    ok++;
                }
            }
            free(msl);
        }
        free(code);
    }
    closedir(d);
    printf("%d compiled, %d failed\n", ok, bad);
    return bad != 0;
}
