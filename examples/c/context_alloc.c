#include "pancake_ocapn.h"

#include <stdalign.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* A C embedder owning every pancake allocation: a trivial bump arena behind the
   PancakeContext host-allocator callbacks. Over-aligned so any alignment pancake
   asks for (peer object, session tables) lands aligned. Frees are counted, not
   reclaimed — enough to assert the context balances alloc against free. */
static alignas(64) unsigned char arena[1u << 20];
static size_t arena_used;
static size_t alloc_calls;
static size_t free_calls;

static size_t align_up(size_t n, size_t alignment) {
    return (n + (alignment - 1u)) & ~(alignment - 1u);
}

static void *host_alloc(void *user_data, size_t size, size_t alignment) {
    (void)user_data;
    size_t base = align_up(arena_used, alignment);
    if (base + size > sizeof(arena)) {
        return NULL;
    }
    arena_used = base + size;
    alloc_calls += 1u;
    return arena + base;
}

static void host_free(void *user_data, void *ptr, size_t size, size_t alignment) {
    (void)user_data;
    (void)ptr;
    (void)size;
    (void)alignment;
    free_calls += 1u;
}

int main(void) {
    const PancakeAllocator host = {
        .alloc = host_alloc,
        .free = host_free,
        .user_data = NULL,
    };

    PancakeContext *ctx = NULL;
    if (pancake_context_new_with_allocator(&host, &ctx) != PANCAKE_OK) {
        return 1;
    }

    PancakePeer *peer = NULL;
    if (pancake_peer_new_in(ctx, &peer) != PANCAKE_OK) {
        pancake_context_release(ctx);
        return 1;
    }

    pancake_peer_release(peer);
    pancake_context_release(ctx);

    printf("c-context alloc_calls=%zu free_calls=%zu\n", alloc_calls, free_calls);
    return (alloc_calls > 0u && alloc_calls == free_calls) ? 0 : 1;
}
