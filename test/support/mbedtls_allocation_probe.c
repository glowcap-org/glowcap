#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "mbedtls_allocation_probe.h"

typedef union {
    max_align_t alignment;
    struct {
        size_t bytes;
    } value;
} AllocationHeader;

static _Atomic size_t current_bytes;
static _Atomic size_t peak_bytes;
static _Atomic size_t allocation_count;

static void retain_peak(size_t candidate)
{
    size_t peak = atomic_load_explicit(&peak_bytes, memory_order_relaxed);
    while (candidate > peak &&
           !atomic_compare_exchange_weak_explicit(
               &peak_bytes, &peak, candidate,
               memory_order_relaxed, memory_order_relaxed)) {
    }
}

void *pancake_mbedtls_probe_calloc(size_t count, size_t size)
{
    if (size != 0 && count > (SIZE_MAX - sizeof(AllocationHeader)) / size)
        return NULL;
    const size_t bytes = count * size;
    AllocationHeader *header = calloc(1, sizeof(*header) + bytes);
    if (header == NULL)
        return NULL;
    header->value.bytes = bytes;
    const size_t current = atomic_fetch_add_explicit(
        &current_bytes, bytes, memory_order_relaxed) + bytes;
    atomic_fetch_add_explicit(&allocation_count, 1, memory_order_relaxed);
    retain_peak(current);
    return header + 1;
}

void pancake_mbedtls_probe_free(void *ptr)
{
    if (ptr == NULL)
        return;
    AllocationHeader *header = (AllocationHeader *)ptr - 1;
    atomic_fetch_sub_explicit(
        &current_bytes, header->value.bytes, memory_order_relaxed);
    free(header);
}

void pancake_mbedtls_probe_reset_window(void)
{
    atomic_store_explicit(
        &peak_bytes,
        atomic_load_explicit(&current_bytes, memory_order_relaxed),
        memory_order_relaxed);
    atomic_store_explicit(&allocation_count, 0, memory_order_relaxed);
}

size_t pancake_mbedtls_probe_current_bytes(void)
{
    return atomic_load_explicit(&current_bytes, memory_order_relaxed);
}

size_t pancake_mbedtls_probe_peak_bytes(void)
{
    return atomic_load_explicit(&peak_bytes, memory_order_relaxed);
}

size_t pancake_mbedtls_probe_allocation_count(void)
{
    return atomic_load_explicit(&allocation_count, memory_order_relaxed);
}
