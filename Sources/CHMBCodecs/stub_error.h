// WP0 stub helper (private to CHMBCodecs). WP1 deletes this file with the stubs.
#ifndef HMB_STUB_ERROR_H
#define HMB_STUB_ERROR_H
#include <cstdio>
#include <cstddef>
static inline int hmb_stub_error(const char *function, char *err, size_t err_len) {
    if (err != nullptr && err_len > 0) std::snprintf(err, err_len, "%s: not implemented (WP0 stub; WP1 implements it)", function);
    return -1;
}
#endif
