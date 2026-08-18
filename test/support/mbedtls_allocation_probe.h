#ifndef PANCAKE_MBEDTLS_ALLOCATION_PROBE_H
#define PANCAKE_MBEDTLS_ALLOCATION_PROBE_H

#include <stddef.h>

void pancake_mbedtls_probe_reset_window(void);
size_t pancake_mbedtls_probe_current_bytes(void);
size_t pancake_mbedtls_probe_peak_bytes(void);
size_t pancake_mbedtls_probe_allocation_count(void);

#endif
