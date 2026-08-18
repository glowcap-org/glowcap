#ifndef PANCAKE_MBEDTLS_PROBE_CONFIG_H
#define PANCAKE_MBEDTLS_PROBE_CONFIG_H

/* Test-only allocation interception shared by Mbed TLS and TF-PSA-Crypto.
 * Production never defines the guard and retains the upstream allocator. */
#if defined(PANCAKE_MBEDTLS_ALLOCATION_PROBE)
#include <stddef.h>
void *pancake_mbedtls_probe_calloc(size_t count, size_t size);
void pancake_mbedtls_probe_free(void *ptr);
#define MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_MEMORY
#define MBEDTLS_PLATFORM_CALLOC_MACRO pancake_mbedtls_probe_calloc
#define MBEDTLS_PLATFORM_FREE_MACRO pancake_mbedtls_probe_free
#endif

#endif
