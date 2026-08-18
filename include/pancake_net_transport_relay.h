/* Generated from src/c_abi/net_transport/relay/mod.zig by tools/gen/header/net_relay.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-relay`.
   Function signatures and configuration layout are reflected from Zig. */
#ifndef PANCAKE_NET_TRANSPORT_RELAY_H
#define PANCAKE_NET_TRANSPORT_RELAY_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"
#include "pancake_transport_provider.h"

#ifdef __cplusplus
extern "C" {
#endif
/* The relay archive owns one shared runtime for keyed-relay and noise-relay.
   The relay moves opaque WebSocket bytes and proves no peer identity;
   noise-relay is sealed and authenticated by the Host above this provider.
   Install the returned package into libpancake_driver. Generic driver and
   binding code never names either profile's concrete implementation. */

typedef struct PancakeRelayRuntime PancakeRelayRuntime;
#define PANCAKE_RELAY_CONFIG_ABI_VERSION 1u
#define PANCAKE_RELAY_TRUST_SYSTEM 0u
#define PANCAKE_RELAY_TRUST_COPIED_PEM 1u

typedef struct PancakeRelayConfig {
    /* Must equal PANCAKE_RELAY_CONFIG_ABI_VERSION. */
    uint32_t abi_version;
    /* Must equal sizeof(PancakeRelayConfig). */
    size_t struct_size;
    /* Borrowed dial URL copied by the constructor. */
    const uint8_t *relay_url;
    /* Byte length of relay_url. */
    size_t relay_url_len;
    /* Borrowed registration URL copied by the constructor; NULL/empty makes the package dial-only. */
    const uint8_t *register_url;
    /* Byte length of register_url. */
    size_t register_url_len;
    /* PANCAKE_RELAY_TRUST_* policy; system roots are the default. */
    uint32_t trust;
    /* Borrowed PEM bytes copied during construction; only valid with COPIED_PEM. */
    const uint8_t *trust_pem;
    /* Byte length of trust_pem. */
    size_t trust_pem_len;
} PancakeRelayConfig;

typedef struct PancakeRelayTrustSummary {
    /* Roots loaded into the native TLS engine. */
    size_t loaded;
    /* Platform roots the native TLS engine could not consume. */
    size_t skipped_by_engine;
    /* Exact first engine code for a skipped root; zero when none were skipped. */
    int32_t first_skipped_engine_code;
} PancakeRelayTrustSummary;

/* Return the exact callable-surface fingerprint. Compare it with the binding-generated PANCAKE_RELAY_ARCHIVE_FINGERPRINT before any other call. */
uint64_t pancake_relay_archive_fingerprint(void);
/* Create a relay runtime with the library allocator. Configuration bytes are
   copied. Release the runtime after every driver holding its provider lease. */
int32_t pancake_relay_runtime_new(const PancakeRelayConfig *config, PancakeRelayRuntime **out_runtime);
/* Create a relay runtime whose owned state uses `context`. */
int32_t pancake_relay_runtime_new_in(PancakeContext *context, const PancakeRelayConfig *config, PancakeRelayRuntime **out_runtime);
/* Copy the immutable trust-load result retained by this runtime. */
int32_t pancake_relay_runtime_trust_summary(PancakeRelayRuntime *runtime, PancakeRelayTrustSummary *out_summary);
/* Fill `out_provider` with the shared keyed-relay/noise-relay multiplexed package.
   Install it once with pancake_driver_add_provider; the driver retains its lease. */
int32_t pancake_relay_transport_provider(PancakeRelayRuntime *runtime, PancakeTransportProvider *out_provider);
/* Release the caller's runtime reference. The provider lease keeps the runtime
   alive until its driver is released. out_error/out_error_len optionally capture
   this call's diagnostic before an off-thread runtime regains control: omit all
   three diagnostic arguments, or provide out_error_len. */
int32_t pancake_relay_runtime_release(PancakeRelayRuntime *runtime, uint8_t *out_error, size_t error_cap, size_t *out_error_len);
/* Copy this archive's calling-thread diagnostic, NUL-terminating when cap is
   nonzero. NULL or zero capacity queries the full length. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t pancake_relay_last_error(uint8_t *out_buf, size_t cap);
/* Clear this archive's calling-thread diagnostic. */
void pancake_relay_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_RELAY_H */
