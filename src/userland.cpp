// This file is a shim for zig1. The real implementations of these are in
// src-self-hosted/stage1.zig

#include "userland.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void stage2_attach_segv_handler(void) {
    // do nothing in stage0
}

void stage2_translate_c(void) {
    const char *msg = "stage0 called stage2_translate_c";
    stage2_panic(msg, strlen(msg));
}

void stage2_zen(const char **ptr, size_t *len) {
    const char *msg = "stage0 called stage2_zen";
    stage2_panic(msg, strlen(msg));
}

void stage2_panic(const char *ptr, size_t len) {
    fwrite(ptr, 1, len, stderr);
    fprintf(stderr, "\n");
    fflush(stderr);
    abort();
}
