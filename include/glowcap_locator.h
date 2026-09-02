/* Generated from src/c_abi/shared/locator.zig.
   Do not edit by hand: run `zig build gen-header-locator`.
   This header defines the borrowed locator layout shared by OCapN,
   the driver, and independently linked transport providers. */
#ifndef GLOWCAP_LOCATOR_H
#define GLOWCAP_LOCATOR_H

#include <stddef.h>
#include <stdint.h>
/* GlowcapLocatorHintView.kind: UTF-8 string bytes. */
#define GLOWCAP_HINT_STRING 1
/* GlowcapLocatorHintView.kind: opaque bytes. */
#define GLOWCAP_HINT_BYTES 2
/* GlowcapLocatorHintView.kind: boolean_value. */
#define GLOWCAP_HINT_BOOLEAN 3
/* GlowcapLocatorHintView.kind: integer_value. */
#define GLOWCAP_HINT_INTEGER 4
/* GlowcapLocatorView.hint_wire_form: map spelling. */
#define GLOWCAP_HINTS_MAP 0
/* GlowcapLocatorView.hint_wire_form: boolean-false spelling. */
#define GLOWCAP_HINTS_BOOLEAN_FALSE 1
/* GlowcapLocatorView ABI version. */
#define GLOWCAP_LOCATOR_VIEW_ABI_VERSION 1

typedef struct GlowcapLocatorHintView {
    /* Borrowed hint name. */
    const uint8_t *name;
    size_t name_len;
    /* GLOWCAP_HINT_*. */
    uint32_t kind;
    /* Borrowed STRING/BYTES value. */
    const uint8_t *bytes;
    size_t bytes_len;
    /* BOOLEAN value. */
    uint8_t boolean_value;
    /* INTEGER value. */
    int64_t integer_value;
} GlowcapLocatorHintView;
typedef struct GlowcapLocatorView {
    /* GLOWCAP_LOCATOR_VIEW_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapLocatorView). */
    size_t struct_size;
    /* Borrowed transport symbol. */
    const uint8_t *transport;
    size_t transport_len;
    /* Borrowed designator. */
    const uint8_t *designator;
    size_t designator_len;
    /* Borrowed hint array. */
    const GlowcapLocatorHintView *hints;
    size_t hint_count;
    /* GLOWCAP_HINTS_*. */
    uint32_t hint_wire_form;
} GlowcapLocatorView;

/* Consume one callback-scoped complete locator view. Copy anything retained. */
typedef int32_t (*GlowcapLocatorSinkFn)(void *sink_ctx, const GlowcapLocatorView *locator);
#endif /* GLOWCAP_LOCATOR_H */
