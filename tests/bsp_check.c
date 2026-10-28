// Reads each .bsp given (the player's own maps) as the lighting rebake will
// (bl_bsp_world_load) and prints bl_bsp_world_check's summary; exits 1 when any map's
// lightmap layout is not as expected.
//   (built by tools/build_tests.sh into build/tests/)
//   build/tests/bsp_check <game>/Vampire/maps/*.bsp
#include "bl_bsp.h"
#include <stdio.h>

int main(int argc, char **argv)
{
    char err[512], summary[1024];
    int bad = 0;
    for (int i = 1; i < argc; i++) {
        struct bl_bsp_world *w = bl_bsp_world_load(argv[i], err, sizeof err);
        if (!w) {
            printf("FAIL %s\n", err);
            bad++;
            continue;
        }
        int n = bl_bsp_world_check(w, summary, sizeof summary);
        printf("%s%s\n", n ? "FAIL " : "", summary);
        bad += n != 0;
        bl_bsp_world_free(w);
    }
    printf("%d of %d maps as expected\n", argc - 1 - bad, argc - 1);
    return bad != 0;
}
