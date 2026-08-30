#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lispal.h"

static int fail(void *runtime, const char *message) {
    const char *detail = runtime ? lfp_last_error(runtime) : NULL;
    fprintf(stderr, "c api test: %s", message);
    if (detail && *detail) fprintf(stderr, ": %s", detail);
    fputc('\n', stderr);
    if (runtime) lfp_destroy(runtime);
    return 1;
}

static long execution_count(const char *status) {
    const char *suffix;
    const char *start;
    char *end;
    long value;

    if (!status) return -1;
    suffix = strstr(status, " execution(s)");
    if (!suffix) return -1;
    start = suffix;
    while (start > status && start[-1] >= '0' && start[-1] <= '9') --start;
    if (start == suffix) return -1;
    value = strtol(start, &end, 10);
    return end == suffix ? value : -1;
}

int main(void) {
    void *runtime = lfp_create();
    const char *text;
    int64_t value = 0;
    double real_value = 0.0;
    int bool_value = 0;
    int jit_available;
    long executions_before;
    long executions_after;

    if (!runtime) return fail(NULL, "create failed");
    if (strcmp(lfp_version(), "1.0.0") != 0)
        return fail(runtime, "wrong version");
    if (!lfp_set_jit(runtime, LFP_JIT_AUTO))
        return fail(runtime, "could not select automatic jit mode");
    text = lfp_jit_status(runtime);
    if (!text || strncmp(text, "auto", 4) != 0)
        return fail(runtime, "wrong jit status");
    jit_available = strstr(text, "fallback") == NULL;

    if (jit_available) {
        if (!lfp_set_jit(runtime, LFP_JIT_ON))
            return fail(runtime, "could not enable available jit");
    } else {
        if (lfp_set_jit(runtime, LFP_JIT_ON))
            return fail(runtime, "unavailable jit was enabled");
        if (!lfp_last_error(runtime) || !*lfp_last_error(runtime))
            return fail(runtime, "unavailable jit did not set an error");
        if (!lfp_set_jit(runtime, LFP_JIT_AUTO))
            return fail(runtime, "could not restore automatic jit mode");
    }
    text = lfp_jit_status(runtime);
    executions_before = execution_count(text);
    if (executions_before < 0)
        return fail(runtime, "invalid jit execution status");

    if (!lfp_set_integer(runtime, "host_value", 21))
        return fail(runtime, "set integer failed");
    if (!lfp_get_integer(runtime, "host_value", &value) || value != 21)
        return fail(runtime, "get integer failed");
    if (!lfp_set_string(runtime, "host_name", "lispal"))
        return fail(runtime, "set string failed");
    text = lfp_get_string(runtime, "host_name");
    if (!text || strcmp(text, "lispal") != 0)
        return fail(runtime, "get string failed");
    if (!lfp_set_real(runtime, "host_real", 3.5) ||
        !lfp_get_real(runtime, "host_real", &real_value) || real_value != 3.5)
        return fail(runtime, "real round trip failed");
    if (!lfp_set_boolean(runtime, "host_bool", 1) ||
        !lfp_get_boolean(runtime, "host_bool", &bool_value) || !bool_value)
        return fail(runtime, "boolean round trip failed");
    if (!lfp_add_search_path(runtime, "."))
        return fail(runtime, "add search path failed");

    text = lfp_eval(runtime, "(+ host_value 21)", "<c-test>");
    if (!text || strcmp(text, "42") != 0)
        return fail(runtime, "eval failed");
    text = lfp_jit_status(runtime);
    executions_after = execution_count(text);
    if (executions_after < 0)
        return fail(runtime, "invalid post-eval jit execution status");
    if (jit_available && executions_after <= executions_before)
        return fail(runtime, "jit execution was not counted");
    if (!jit_available && executions_after != executions_before)
        return fail(runtime, "fallback execution was counted as jit");

    if (!lfp_set_jit(runtime, LFP_JIT_OFF))
        return fail(runtime, "could not disable jit");
    text = lfp_jit_status(runtime);
    if (!text || strncmp(text, "off", 3) != 0)
        return fail(runtime, "jit did not report disabled status");

    if (lfp_get_integer(runtime, "host_value", NULL))
        return fail(runtime, "null output was accepted");
    if (!lfp_last_error(runtime) || !*lfp_last_error(runtime))
        return fail(runtime, "null output did not set an error");
    if (lfp_set_jit(runtime, 7))
        return fail(runtime, "invalid jit mode was accepted");
    if (lfp_eval(runtime, NULL, NULL) != NULL)
        return fail(runtime, "null source was accepted");

    lfp_destroy(runtime);
    puts("c-api-ok");
    return 0;
}
