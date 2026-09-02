#ifndef GLOWCAP_MBEDTLS_ALLOCATION_PROBE_H
#define GLOWCAP_MBEDTLS_ALLOCATION_PROBE_H

#include <stddef.h>

void glowcap_mbedtls_probe_reset_window(void);
size_t glowcap_mbedtls_probe_current_bytes(void);
size_t glowcap_mbedtls_probe_peak_bytes(void);
size_t glowcap_mbedtls_probe_allocation_count(void);

#endif
