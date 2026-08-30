#include <stdio.h>
#include "lispal.h"

int main(void) {
    void *lfp = lfp_create();
    const char *result;
    if (!lfp) return 1;

    if (!lfp_set_jit(lfp, LFP_JIT_AUTO)) {
        fprintf(stderr, "Lispal error: %s\n", lfp_last_error(lfp));
        lfp_destroy(lfp);
        return 1;
    }
    lfp_set_integer(lfp, "host_value", 21);
    result = lfp_eval(lfp, "(+ host_value 21)", "<c-demo>");
    if (!result) {
        fprintf(stderr, "Lispal error: %s\n", lfp_last_error(lfp));
        lfp_destroy(lfp);
        return 1;
    }

    printf("lispal %s (%s)\n", lfp_version(), lfp_jit_status(lfp));
    printf("result = %s\n", result);
    lfp_destroy(lfp);
    return 0;
}
