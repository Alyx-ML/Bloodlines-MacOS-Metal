// Captures a map's light probes (gi_probes.m) as the game would at load and prints how
// long it took and what the light is like: how bright the probes in the open are, from
// the map's surfaces and from its lights, and a few probes in full.
//   gi_view <map.bsp>
//   clang -std=c2x -O2 -Wall -fobjc-arc -Iruntime -Iruntime/d3d9 tests/gi_view.m runtime/d3d9/gi_probes.m
//     runtime/d3d9/lm_bake.m runtime/bl_bsp.c runtime/bl_props.c -framework Metal -framework Foundation
//     -o build/tests/gi_view
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

#include "gi_probes.h"

static int by_value(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

static float lum(const float c[3]) { return 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2]; }

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: gi_view <map.bsp>\n");
        return 2;
    }
    char err[256];
    struct bl_bsp_world *w = bl_bsp_world_load(argv[1], err, sizeof err);
    if (!w) {
        fprintf(stderr, "%s: %s\n", argv[1], err);
        return 1;
    }
    struct bl_gi *g = bl_gi_capture(MTLCreateSystemDefaultDevice(), w, err, sizeof err);
    if (!g) {
        fprintf(stderr, "capture: %s\n", err);
        return 1;
    }
    printf("%s\n", g->summary);
    int np = g->nprobes, m = 0;
    float *b = malloc(sizeof(float) * (size_t)np), *d = malloc(sizeof(float) * (size_t)np);
    for (int i = 0; i < np; i++) {
        if (!g->valid[i]) continue;
        float sb = 0, sd = 0;
        for (int a = 0; a < 6; a++) sb += lum(g->bounce[i][a]) / 6, sd += lum(g->direct[i][a]) / 6;
        b[m] = sb, d[m] = sd, m++;
    }
    if (!m) return 1;
    qsort(b, (size_t)m, sizeof *b, by_value), qsort(d, (size_t)m, sizeof *d, by_value);
    printf("brightness of the probes clear of walls (mean of the six directions), 10th / 50th / 90th / 99th percentile:\n");
    printf("  from surfaces %.4f %.4f %.4f %.4f\n", b[m / 10], b[m / 2], b[m * 9 / 10], b[m * 99 / 100]);
    printf("  from lights   %.4f %.4f %.4f %.4f\n", d[m / 10], d[m / 2], d[m * 9 / 10], d[m * 99 / 100]);
    static const char *ax[6] = {"+x", "-x", "+y", "-y", "+z", "-z"};
    for (int k = 1, shown = 0; k <= 9 && shown < 5; k += 2) {
        // Probes a tenth, three tenths... through the grid, clear of walls.
        int cells = g->n[0] * g->n[1] * g->n[2];
        for (int c = (int)((long)cells * k / 10), tries = 0; tries < cells; c = (c + 1) % cells, tries++) {
            int i = g->slot[c];
            if (i < 0 || !g->valid[i]) continue;
            int x = c % g->n[0], y = c / g->n[0] % g->n[1], z = c / (g->n[0] * g->n[1]);
            printf("probe at %.0f %.0f %.0f:\n", g->origin[0] + x * g->step, g->origin[1] + y * g->step,
                   g->origin[2] + z * g->step);
            for (int a = 0; a < 6; a++)
                printf("  %s surfaces %.3f %.3f %.3f  lights %.3f %.3f %.3f\n", ax[a], g->bounce[i][a][0],
                       g->bounce[i][a][1], g->bounce[i][a][2], g->direct[i][a][0], g->direct[i][a][1], g->direct[i][a][2]);
            shown++;
            break;
        }
    }
    bl_gi_free(g);
    bl_bsp_world_free(w);
    return 0;
}
