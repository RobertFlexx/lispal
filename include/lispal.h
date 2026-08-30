#ifndef LISPAL_H
#define LISPAL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LFP_VERSION_MAJOR 1
#define LFP_VERSION_MINOR 0
#define LFP_VERSION_PATCH 0

void *lfp_create(void);
void lfp_destroy(void *handle);
const char *lfp_version(void);

const char *lfp_eval(void *handle, const char *source, const char *filename);
const char *lfp_eval_file(void *handle, const char *filename);
const char *lfp_last_error(void *handle);

int lfp_set_integer(void *handle, const char *name, int64_t value);
int lfp_get_integer(void *handle, const char *name, int64_t *value);
int lfp_set_real(void *handle, const char *name, double value);
int lfp_get_real(void *handle, const char *name, double *value);
int lfp_set_boolean(void *handle, const char *name, int value);
int lfp_get_boolean(void *handle, const char *name, int *value);
int lfp_set_string(void *handle, const char *name, const char *value);
const char *lfp_get_string(void *handle, const char *name);
int lfp_add_search_path(void *handle, const char *path);

enum {
    LFP_JIT_AUTO = -1,
    LFP_JIT_OFF = 0,
    LFP_JIT_ON = 1
};

int lfp_set_jit(void *handle, int mode);
const char *lfp_jit_status(void *handle);

#ifdef __cplusplus
}
#endif

#endif
