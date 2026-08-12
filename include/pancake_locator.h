/* Generated from src/c_abi/shared/locator.zig.
   Do not edit by hand: run `zig build gen-header-locator`.
   This header defines the borrowed locator layout shared by OCapN,
   the driver, and independently linked transport providers. */
#ifndef PANCAKE_LOCATOR_H
#define PANCAKE_LOCATOR_H

#include <stddef.h>
#include <stdint.h>
/* PancakeLocatorHintView.kind: UTF-8 string bytes. */
#define PANCAKE_HINT_STRING 1
/* PancakeLocatorHintView.kind: opaque bytes. */
#define PANCAKE_HINT_BYTES 2
/* PancakeLocatorHintView.kind: boolean_value. */
#define PANCAKE_HINT_BOOLEAN 3
/* PancakeLocatorHintView.kind: integer_value. */
#define PANCAKE_HINT_INTEGER 4
/* PancakeLocatorView.hint_wire_form: map spelling. */
#define PANCAKE_HINTS_MAP 0
/* PancakeLocatorView.hint_wire_form: boolean-false spelling. */
#define PANCAKE_HINTS_BOOLEAN_FALSE 1
/* PancakeLocatorView ABI version. */
#define PANCAKE_LOCATOR_VIEW_ABI_VERSION 1

typedef struct PancakeLocatorHintView {
    /* Borrowed hint name. */
    const uint8_t *name;
    size_t name_len;
    /* PANCAKE_HINT_*. */
    uint32_t kind;
    /* Borrowed STRING/BYTES value. */
    const uint8_t *bytes;
    size_t bytes_len;
    /* BOOLEAN value. */
    uint8_t boolean_value;
    /* INTEGER value. */
    int64_t integer_value;
} PancakeLocatorHintView;
typedef struct PancakeLocatorView {
    /* PANCAKE_LOCATOR_VIEW_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeLocatorView). */
    size_t struct_size;
    /* Borrowed transport symbol. */
    const uint8_t *transport;
    size_t transport_len;
    /* Borrowed designator. */
    const uint8_t *designator;
    size_t designator_len;
    /* Borrowed hint array. */
    const PancakeLocatorHintView *hints;
    size_t hint_count;
    /* PANCAKE_HINTS_*. */
    uint32_t hint_wire_form;
} PancakeLocatorView;

/* Consume one callback-scoped complete locator view. Copy anything retained. */
typedef int32_t (*PancakeLocatorSinkFn)(void *sink_ctx, const PancakeLocatorView *locator);
#endif /* PANCAKE_LOCATOR_H */
