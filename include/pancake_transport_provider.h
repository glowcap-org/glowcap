/* Generated from the shared transport provider ABI in
   src/c_abi/shared/transport_provider.zig and
   src/c_abi/shared/multiplexed_transport.zig.
   Do not edit by hand: run `zig build gen-header-transport-provider`.
   This standalone layout-only contract is shared by the driver and
   every transport archive. Provider retain/release is the native
   transport lifetime authority. */
#ifndef PANCAKE_TRANSPORT_PROVIDER_H
#define PANCAKE_TRANSPORT_PROVIDER_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_locator.h"

#ifdef __cplusplus
extern "C" {
#endif
/* try_read and try_write result when the operation cannot progress without blocking. */
#define PANCAKE_MULTIPLEXED_WOULD_BLOCK (-2)
/* PancakeMultiplexedReadyEvent.events: subject has readable bytes. */
#define PANCAKE_MULTIPLEXED_EV_READABLE 1
/* PancakeMultiplexedReadyEvent.events: subject can resume writing. */
#define PANCAKE_MULTIPLEXED_EV_WRITABLE 2
/* PancakeMultiplexedReadyEvent.events: subject closed. */
#define PANCAKE_MULTIPLEXED_EV_CLOSED 4
/* PancakeMultiplexedReadyEvent.events: a listener has an accepted connection to claim. */
#define PANCAKE_MULTIPLEXED_EV_ACCEPT 8
/* PancakeMultiplexedReadyEvent.events: a dial request completed. */
#define PANCAKE_MULTIPLEXED_EV_CONNECT 16
/* PancakeMultiplexedTransport.abi_version. */
#define PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION 1
/* PancakeTransportProfile.designator_scheme: designators are addresses. */
#define PANCAKE_DESIGNATOR_SCHEME_ADDRESS 0
/* PancakeTransportProfile.designator_scheme: designators are peer keys. */
#define PANCAKE_DESIGNATOR_SCHEME_KEY 1
/* PancakeTransportProfile.sealed_channel: no Host-provided sealing. */
#define PANCAKE_SEALED_CHANNEL_NONE 0
/* PancakeTransportProfile.sealed_channel: Host composes Noise_XK. */
#define PANCAKE_SEALED_CHANNEL_NOISE_XK 1
/* PancakeTransportProvider ABI version. */
#define PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION 1
/* PancakeTransportProfile ABI version. */
#define PANCAKE_TRANSPORT_PROFILE_ABI_VERSION 1
/* PancakeStreamTransport ABI version. */
#define PANCAKE_STREAM_TRANSPORT_ABI_VERSION 1
/* Provider entry points to PancakeStreamTransport. */
#define PANCAKE_TRANSPORT_EXEC_STREAM 1
/* Provider entry points to PancakeMultiplexedTransport. */
#define PANCAKE_TRANSPORT_EXEC_MULTIPLEXED 2

typedef struct PancakeMultiplexedReadyEvent PancakeMultiplexedReadyEvent;
typedef int32_t (*PancakeMultiplexedReadinessFdFn)(void *ctx);
typedef size_t (*PancakeMultiplexedDrainReadyFn)(void *ctx, PancakeMultiplexedReadyEvent *out, size_t cap);
typedef int32_t (*PancakeMultiplexedStartConnectFn)(void *ctx, uint64_t request_id, const PancakeLocatorView *locator);
typedef int32_t (*PancakeMultiplexedFinishConnectFn)(void *ctx, uint64_t request_id, uint64_t *out_conn);
typedef int32_t (*PancakeMultiplexedClaimExternalFn)(void *ctx, uint64_t subject, uint64_t *out_conn);
typedef int32_t (*PancakeMultiplexedStartListenFn)(void *ctx, uint64_t route_id, const uint8_t *transport, size_t transport_len, const uint8_t *requested_designator, size_t requested_designator_len, void **out_listener);
typedef int32_t (*PancakeTransportListenerLocatorFn)(void *listener_ctx, void *sink_ctx, PancakeLocatorSinkFn sink);
typedef int32_t (*PancakeTransportListenerAdvertiseFn)(void *listener_ctx, const PancakeLocatorView *locator, void *sink_ctx, PancakeLocatorSinkFn sink);
typedef int32_t (*PancakeMultiplexedFinishAcceptFn)(void *listener_ctx, uint64_t *out_conn);
typedef void (*PancakeMultiplexedStopListenFn)(void *listener_ctx);
typedef void (*PancakeMultiplexedSubjectFn)(void *ctx, uint64_t subject);
typedef intptr_t (*PancakeMultiplexedTryReadFn)(void *ctx, uint64_t conn, uint8_t *buf, size_t cap);
typedef intptr_t (*PancakeMultiplexedTryWriteFn)(void *ctx, uint64_t conn, const uint8_t *bytes, size_t len);
typedef int32_t (*PancakeMultiplexedConnRemoteKeyFn)(void *ctx, uint64_t conn, uint8_t *out_key);
typedef struct PancakeMultiplexedReadyEvent {
    /* Connection, connect request, or listener route id. */
    uint64_t subject;
    /* PANCAKE_MULTIPLEXED_EV_* bits. */
    uint32_t events;
} PancakeMultiplexedReadyEvent;
typedef struct PancakeMultiplexedTransport {
    /* PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeMultiplexedTransport). */
    size_t struct_size;
    /* Provider-owned context; must outlive registration. */
    void *ctx;
    /* Level-shaped readiness descriptor; remains ready while records are pending. */
    PancakeMultiplexedReadinessFdFn readiness_fd;
    /* Drain at most the supplied capacity of ready records. */
    PancakeMultiplexedDrainReadyFn drain_ready;
    /* Start a non-blocking connect. */
    PancakeMultiplexedStartConnectFn start_connect;
    /* Finish connect. */
    PancakeMultiplexedFinishConnectFn finish_connect;
    /* Claim externally established connection. */
    PancakeMultiplexedClaimExternalFn claim_external;
    /* Cancel connect. */
    PancakeMultiplexedSubjectFn cancel_connect;
    /* Start listener. */
    PancakeMultiplexedStartListenFn start_listen;
    /* Query canonical listener locator. */
    PancakeTransportListenerLocatorFn listener_locator;
    /* Validate and canonicalize advertised locator. */
    PancakeTransportListenerAdvertiseFn listener_advertise;
    /* Finish accept. */
    PancakeMultiplexedFinishAcceptFn finish_accept;
    /* Stop listener. */
    PancakeMultiplexedStopListenFn stop_listen;
    /* Read: 0..cap bytes, 0 at EOF, -1 when dead, or PANCAKE_MULTIPLEXED_WOULD_BLOCK. */
    PancakeMultiplexedTryReadFn try_read;
    /* Write: 0..len bytes consumed, -1 when dead, or PANCAKE_MULTIPLEXED_WOULD_BLOCK. */
    PancakeMultiplexedTryWriteFn try_write;
    /* Close connection. */
    PancakeMultiplexedSubjectFn conn_close;
    /* Copy proved remote key and return 1, or return 0; other statuses violate the contract. */
    PancakeMultiplexedConnRemoteKeyFn conn_remote_key;
} PancakeMultiplexedTransport;

typedef int32_t (*PancakeStreamStartConnectFn)(void *ctx, const PancakeLocatorView *locator, void **out_attempt, int32_t *out_readiness_fd);
typedef int32_t (*PancakeStreamFinishConnectFn)(void *attempt, void **out_conn, int32_t *out_readiness_fd);
typedef void (*PancakeStreamCancelConnectFn)(void *attempt);
typedef int32_t (*PancakeStreamListenFn)(void *ctx, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, void **out_listener);
typedef int32_t (*PancakeStreamListenerWaitFn)(void *ctx, void *listener, int32_t timeout_ms);
typedef int32_t (*PancakeStreamListenerReadinessFdFn)(void *ctx, void *listener);
typedef int32_t (*PancakeStreamAcceptFn)(void *ctx, void *listener, void **out_conn, int32_t *out_readiness_fd);
typedef void (*PancakeStreamListenerCloseFn)(void *ctx, void *listener);
typedef intptr_t (*PancakeStreamReadFn)(void *ctx, void *conn, uint8_t *out, size_t cap);
typedef int32_t (*PancakeStreamWriteAllFn)(void *ctx, void *conn, const uint8_t *bytes, size_t len);
typedef void (*PancakeStreamConnCloseFn)(void *ctx, void *conn);
typedef int32_t (*PancakeTransportRetainFn)(void *ctx);
typedef void (*PancakeTransportReleaseFn)(void *ctx);
typedef struct PancakeTransportProfile {
    /* PANCAKE_TRANSPORT_PROFILE_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeTransportProfile). */
    size_t struct_size;
    /* Borrowed transport symbol. */
    const uint8_t *transport_name;
    size_t transport_name_len;
    /* PANCAKE_DESIGNATOR_SCHEME_*. */
    uint32_t designator_scheme;
    /* PANCAKE_SEALED_CHANNEL_*. */
    uint32_t sealed_channel;
} PancakeTransportProfile;
typedef struct PancakeStreamTransport {
    /* PANCAKE_STREAM_TRANSPORT_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeStreamTransport). */
    size_t struct_size;
    /* Provider-owned context; must outlive registration. */
    void *ctx;
    /* Start a non-blocking stream connect. */
    PancakeStreamStartConnectFn start_connect;
    /* Finish and consume a ready connect attempt. */
    PancakeStreamFinishConnectFn finish_connect;
    /* Cancel and consume a connect attempt. */
    PancakeStreamCancelConnectFn cancel_connect;
    /* Start listener. */
    PancakeStreamListenFn listen;
    /* Wait for listener metadata. */
    PancakeStreamListenerWaitFn listener_wait_ready;
    /* Wait for acceptable connection. */
    PancakeStreamListenerWaitFn listener_wait_acceptable;
    /* Listener readiness descriptor. */
    PancakeStreamListenerReadinessFdFn listener_readiness_fd;
    /* Query canonical listener locator. */
    PancakeTransportListenerLocatorFn listener_locator;
    /* Validate and canonicalize advertised locator. */
    PancakeTransportListenerAdvertiseFn listener_advertise;
    /* Accept raw stream. */
    PancakeStreamAcceptFn accept;
    /* Close listener. */
    PancakeStreamListenerCloseFn listener_close;
    /* Read bytes. */
    PancakeStreamReadFn read;
    /* Write all bytes. */
    PancakeStreamWriteAllFn write_all;
    /* Close connection. */
    PancakeStreamConnCloseFn conn_close;
} PancakeStreamTransport;
typedef struct PancakeTransportProviderEntry {
    /* Copied semantic profile. */
    const PancakeTransportProfile *profile;
    /* PANCAKE_TRANSPORT_EXEC_*. */
    uint32_t execution_model;
    /* Execution table; equal multiplexed-table pointers in one package share one runtime. */
    const void *implementation;
} PancakeTransportProviderEntry;
typedef struct PancakeTransportProvider {
    /* PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(PancakeTransportProvider). */
    size_t struct_size;
    /* Borrowed entries; tables are copied during registration. */
    const PancakeTransportProviderEntry *entries;
    /* Nonzero entry count. */
    size_t entry_count;
    /* Package-owned lease context. */
    void *lease_ctx;
    /* Acquire one registration lease. */
    PancakeTransportRetainFn retain;
    /* Release the registration lease after all callbacks retire. */
    PancakeTransportReleaseFn release;
} PancakeTransportProvider;

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_TRANSPORT_PROVIDER_H */
