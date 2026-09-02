#ifndef GLOWCAP_MBEDTLS_PROBE_CONFIG_H
#define GLOWCAP_MBEDTLS_PROBE_CONFIG_H

/* Test-only allocation interception shared by Mbed TLS and TF-PSA-Crypto.
 * Production never defines the guard and retains the upstream allocator. */
#if defined(GLOWCAP_MBEDTLS_ALLOCATION_PROBE)
#include <stddef.h>
void *glowcap_mbedtls_probe_calloc(size_t count, size_t size);
void glowcap_mbedtls_probe_free(void *ptr);
#define MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_MEMORY
#define MBEDTLS_PLATFORM_CALLOC_MACRO glowcap_mbedtls_probe_calloc
#define MBEDTLS_PLATFORM_FREE_MACRO glowcap_mbedtls_probe_free
#endif

#endif
