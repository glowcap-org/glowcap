/* Generated from the shared transport provider ABI in
   src/c_abi/shared/transport_provider.zig and
   src/c_abi/shared/multiplexed_transport.zig.
   Do not edit by hand: run `zig build gen-header-transport-provider`.
   This standalone layout-only contract is shared by the driver and
   every transport archive. Provider retain/release is the native
   transport lifetime authority.
   Handle-producing callbacks transfer outputs only on PANCAKE_OK.
   On every other status the provider cleans partial work and leaves
   output slots untouched. finish_connect and finish_listen consume
   their input operation on every return; cancel applies only before
   finish. A listener completion pair is complete or absent; without
   both finish_listen and cancel_listen, listen must return READY. */
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
/* PancakeMultiplexedReadyEvent.events: listener construction completed. */
#define PANCAKE_MULTIPLEXED_EV_LISTEN 32
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
/* PancakeListenResult.state: listener construction completed. */
#define PANCAKE_LISTEN_READY 0
/* PancakeListenResult.state: listener construction is pending. */
#define PANCAKE_LISTEN_PENDING 1
/* Provider entry points to PancakeStreamTransport. */
#define PANCAKE_TRANSPORT_EXEC_STREAM 1
/* Provider entry points to PancakeMultiplexedTransport. */
#define PANCAKE_TRANSPORT_EXEC_MULTIPLEXED 2
typedef struct PancakeTransportOperationOptions {
    /* Borrowed provider-owned payload; null with size zero inherits provider defaults. */
    const void *data;
    /* Exact payload size; the selected provider validates its type. */
    size_t size;
} PancakeTransportOperationOptions;
typedef struct PancakeProviderFailure {
    /* Returned PANCAKE_ERR_* status; zero on success. */
    int32_t result;
    /* Immutable process-lifetime UTF-8 primary cause name. */
    const uint8_t *primary_name;
    /* Primary name byte length. */
    size_t primary_name_len;
    /* First secondary PANCAKE_ERR_* status; zero when absent. */
    int32_t secondary_result;
    /* Immutable process-lifetime UTF-8 first secondary cause name. */
    const uint8_t *secondary_name;
    /* First secondary name byte length. */
    size_t secondary_name_len;
    /* Total secondary failure count. */
    uint32_t secondary_count;
} PancakeProviderFailure;

typedef struct PancakeListenResult PancakeListenResult;
typedef struct PancakeMultiplexedReadyEvent PancakeMultiplexedReadyEvent;
typedef int32_t (*PancakeMultiplexedReadinessFdFn)(void *ctx);
/* On PANCAKE_OK, writes at most cap records and their count, with an empty
   failure. On error, leaves out_count untouched and returns the exact
   provider cause and cleanup chain through out_failure. */
typedef int32_t (*PancakeMultiplexedDrainReadyFn)(void *ctx, PancakeMultiplexedReadyEvent *out, size_t cap, size_t *out_count, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeMultiplexedStartConnectFn)(void *ctx, uint64_t request_id, const PancakeLocatorView *locator, const PancakeTransportOperationOptions *options, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeMultiplexedFinishConnectFn)(void *ctx, uint64_t request_id, uint64_t *out_conn, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeMultiplexedClaimExternalFn)(void *ctx, uint64_t subject, uint64_t *out_conn, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeMultiplexedListenFn)(void *ctx, uint64_t route_id, const uint8_t *transport, size_t transport_len, const uint8_t *requested_designator, size_t requested_designator_len, const PancakeTransportOperationOptions *options, PancakeListenResult *out_result);
typedef int32_t (*PancakeMultiplexedFinishListenFn)(void *ctx, uint64_t route_id, void **out_listener);
typedef int32_t (*PancakeTransportListenerLocatorFn)(void *listener_ctx, void *sink_ctx, PancakeLocatorSinkFn sink);
typedef int32_t (*PancakeTransportListenerAdvertiseFn)(void *listener_ctx, const PancakeLocatorView *locator, void *sink_ctx, PancakeLocatorSinkFn sink);
typedef int32_t (*PancakeTransportListenerRestorationStateFn)(void *listener_ctx, uint8_t *out, size_t cap, size_t *out_len);
typedef int32_t (*PancakeMultiplexedFinishAcceptFn)(void *listener_ctx, uint64_t *out_conn, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeMultiplexedStopListenFn)(void *listener_ctx, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeMultiplexedSubjectFn)(void *ctx, uint64_t subject, PancakeProviderFailure *out_failure);
typedef void (*PancakeMultiplexedConnTakeFailureFn)(void *ctx, uint64_t conn, PancakeProviderFailure *out_failure);
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
    /* Begin listener construction; PENDING requires the completion pair. */
    PancakeMultiplexedListenFn listen;
    /* Consume pending listener construction on every return; present exactly with cancel_listen. */
    PancakeMultiplexedFinishListenFn finish_listen;
    /* Cancel pending listener construction; present exactly with finish_listen. */
    PancakeMultiplexedSubjectFn cancel_listen;
    /* Query canonical listener locator. */
    PancakeTransportListenerLocatorFn listener_locator;
    /* Validate and canonicalize advertised locator. */
    PancakeTransportListenerAdvertiseFn listener_advertise;
    /* Query or copy opaque listener restoration state. */
    PancakeTransportListenerRestorationStateFn listener_restoration_state;
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
    /* Atomically claim the connection's retained read/write failure. */
    PancakeMultiplexedConnTakeFailureFn conn_take_failure;
    /* Copy proved remote key and return 1, or return 0; other statuses violate the contract. */
    PancakeMultiplexedConnRemoteKeyFn conn_remote_key;
} PancakeMultiplexedTransport;

typedef int32_t (*PancakeStreamStartConnectFn)(void *ctx, const PancakeLocatorView *locator, const PancakeTransportOperationOptions *options, void **out_attempt, int32_t *out_readiness_fd, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamFinishConnectFn)(void *attempt, void **out_conn, int32_t *out_readiness_fd, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamCancelConnectFn)(void *attempt, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamFinishListenFn)(void *attempt, void **out_listener, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamCancelListenFn)(void *attempt, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamListenFn)(void *ctx, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, const PancakeTransportOperationOptions *options, PancakeListenResult *out_result, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamListenerWaitFn)(void *ctx, void *listener, int32_t timeout_ms, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamListenerReadinessFdFn)(void *ctx, void *listener);
typedef int32_t (*PancakeStreamAcceptFn)(void *ctx, void *listener, void **out_conn, int32_t *out_readiness_fd, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeStreamListenerCloseFn)(void *ctx, void *listener, PancakeProviderFailure *out_failure);
typedef intptr_t (*PancakeStreamReadFn)(void *ctx, void *conn, uint8_t *out, size_t cap);
typedef int32_t (*PancakeStreamWriteAllFn)(void *ctx, void *conn, const uint8_t *bytes, size_t len);
typedef int32_t (*PancakeStreamConnCloseFn)(void *ctx, void *conn, PancakeProviderFailure *out_failure);
typedef void (*PancakeStreamConnTakeFailureFn)(void *ctx, void *conn, PancakeProviderFailure *out_failure);
typedef uint8_t (*PancakeTransportProviderSameConfigurationFn)(void *ctx, void *other_ctx);
typedef int32_t (*PancakeTransportRetainFn)(void *ctx, PancakeProviderFailure *out_failure);
typedef int32_t (*PancakeTransportReleaseFn)(void *ctx, PancakeProviderFailure *out_failure);
typedef struct PancakeListenResult {
    /* PANCAKE_LISTEN_*; PENDING requires both completion callbacks. */
    uint32_t state;
    /* READY listener handle. */
    void *listener;
    /* Stream PENDING attempt handle. */
    void *attempt;
    /* Stream PENDING attempt readiness descriptor; -1 otherwise. */
    int32_t readiness_fd;
} PancakeListenResult;
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
    /* Begin listener construction; PENDING requires the completion pair. */
    PancakeStreamListenFn listen;
    /* Finish and consume a pending listener attempt on every return. */
    PancakeStreamFinishListenFn finish_listen;
    /* Cancel a pending listener attempt before finish. */
    PancakeStreamCancelListenFn cancel_listen;
    /* Wait for acceptable connection. */
    PancakeStreamListenerWaitFn listener_wait_acceptable;
    /* Listener readiness descriptor. */
    PancakeStreamListenerReadinessFdFn listener_readiness_fd;
    /* Query canonical listener locator. */
    PancakeTransportListenerLocatorFn listener_locator;
    /* Validate and canonicalize advertised locator. */
    PancakeTransportListenerAdvertiseFn listener_advertise;
    /* Query or copy opaque listener restoration state. */
    PancakeTransportListenerRestorationStateFn listener_restoration_state;
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
    /* Atomically claim the connection's retained read/write failure. */
    PancakeStreamConnTakeFailureFn conn_take_failure;
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
    /* Compare complete effective configuration. */
    PancakeTransportProviderSameConfigurationFn same_configuration;
    /* Acquire one registration lease. */
    PancakeTransportRetainFn retain;
    /* Release the registration lease after all callbacks retire. */
    PancakeTransportReleaseFn release;
} PancakeTransportProvider;

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_TRANSPORT_PROVIDER_H */
