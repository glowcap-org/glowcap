/* Generated from the shared transport provider ABI in
   src/c_abi/shared/transport_provider.zig and
   src/c_abi/shared/multiplexed_transport.zig.
   Do not edit by hand: run `zig build gen-header-transport-provider`.
   This standalone layout-only contract is shared by the driver and
   every transport archive. Provider retain/release is the
   transport lifetime authority.
   Handle-producing callbacks transfer outputs only on GLOWCAP_OK.
   On every other status the provider cleans partial work and leaves
   output slots untouched. finish_connect and finish_listen consume
   their input operation on every return. A listener completion pair
   is complete or absent; without both callbacks, listen must return
   READY. An asynchronous cancel/close returns success after transfer,
   emits the subject's terminal readiness after joining, and exposes
   its claim-once cleanup outcome through the owning callback. */
#ifndef GLOWCAP_TRANSPORT_PROVIDER_H
#define GLOWCAP_TRANSPORT_PROVIDER_H

#include <stddef.h>
#include <stdint.h>
#include "glowcap_locator.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Stream and multiplexed try_read and try_write result when the operation cannot progress without blocking. */
#define GLOWCAP_TRANSPORT_WOULD_BLOCK (-2)
/* GlowcapMultiplexedReadyEvent.events: subject has readable bytes. */
#define GLOWCAP_MULTIPLEXED_EV_READABLE 1
/* GlowcapMultiplexedReadyEvent.events: subject can resume writing. */
#define GLOWCAP_MULTIPLEXED_EV_WRITABLE 2
/* GlowcapMultiplexedReadyEvent.events: subject closed. */
#define GLOWCAP_MULTIPLEXED_EV_CLOSED 4
/* GlowcapMultiplexedReadyEvent.events: a listener has an accepted connection to claim. */
#define GLOWCAP_MULTIPLEXED_EV_ACCEPT 8
/* GlowcapMultiplexedReadyEvent.events: a dial request completed. */
#define GLOWCAP_MULTIPLEXED_EV_CONNECT 16
/* GlowcapMultiplexedReadyEvent.events: listener construction completed. */
#define GLOWCAP_MULTIPLEXED_EV_LISTEN 32
/* GlowcapMultiplexedTransport.abi_version. */
#define GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION 1
/* GlowcapTransportProfile.designator_scheme: designators are addresses. */
#define GLOWCAP_DESIGNATOR_SCHEME_ADDRESS 0
/* GlowcapTransportProfile.designator_scheme: designators are peer keys. */
#define GLOWCAP_DESIGNATOR_SCHEME_KEY 1
/* GlowcapTransportProfile.sealed_channel: no Host-provided sealing. */
#define GLOWCAP_SEALED_CHANNEL_NONE 0
/* GlowcapTransportProfile.sealed_channel: Host composes Noise_XK. */
#define GLOWCAP_SEALED_CHANNEL_NOISE_XK 1
/* GlowcapTransportProfile.wire_framing: packets are byte-stream chunks with ADR-0012 envelopes. */
#define GLOWCAP_WIRE_FRAMING_BYTE_STREAM 0
/* GlowcapTransportProfile.wire_framing: each packet is one bare codec frame. */
#define GLOWCAP_WIRE_FRAMING_MESSAGE 1
/* GlowcapProviderFailure.carrier_phase: no carrier phase is available. */
#define GLOWCAP_CARRIER_PHASE_NONE 0
/* Carrier failure occurred during name resolution. */
#define GLOWCAP_CARRIER_PHASE_RESOLVE 1
/* Carrier failure occurred during byte-transport connect. */
#define GLOWCAP_CARRIER_PHASE_CONNECT 2
/* Carrier failure occurred during the secure handshake. */
#define GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE 3
/* Carrier failure occurred during WebSocket upgrade. */
#define GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE 4
/* Carrier failure occurred during relay registration. */
#define GLOWCAP_CARRIER_PHASE_REGISTRATION 5
/* Carrier failure occurred while receiving bytes. */
#define GLOWCAP_CARRIER_PHASE_RECEIVE 6
/* Carrier failure occurred while transmitting bytes. */
#define GLOWCAP_CARRIER_PHASE_TRANSMIT 7
/* Carrier failure occurred during shutdown. */
#define GLOWCAP_CARRIER_PHASE_SHUTDOWN 8
/* GlowcapProviderFailure.carrier_detail_flags: peer alert is present. */
#define GLOWCAP_CARRIER_DETAIL_PEER_ALERT 1
/* GlowcapProviderFailure.carrier_detail_flags: engine code is present. */
#define GLOWCAP_CARRIER_DETAIL_ENGINE_CODE 2
/* GlowcapTransportProvider ABI version. */
#define GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION 1
/* GlowcapTransportProfile ABI version. */
#define GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION 1
/* GlowcapStreamTransport ABI version. */
#define GLOWCAP_STREAM_TRANSPORT_ABI_VERSION 1
/* GlowcapListenResult.state: listener construction completed. */
#define GLOWCAP_LISTEN_READY 0
/* GlowcapListenResult.state: listener construction is pending. */
#define GLOWCAP_LISTEN_PENDING 1
/* Provider entry points to GlowcapStreamTransport. */
#define GLOWCAP_TRANSPORT_EXEC_STREAM 1
/* Provider entry points to GlowcapMultiplexedTransport. */
#define GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED 2
typedef struct GlowcapTransportOperationOptions {
    /* Borrowed provider-owned payload; null with size zero inherits provider defaults. */
    const void *data;
    /* Exact payload size; the selected provider validates its type. */
    size_t size;
} GlowcapTransportOperationOptions;

/* Where one dial came from, borrowed for the start callback. A handoff dial
   follows a reference an open session handed over, and introducer is the
   designator that session's partner signed in its hello. A provider whose
   connect needs an outside party, as WebRTC signaling does, routes by it.
   The driver passes a null origin for a dial the application started
   itself, for a handoff whose introducing session has closed, and for a
   partner that signed no designator. */
typedef struct GlowcapDialOrigin {
    /* Borrowed UTF-8 designator of the introducing session's partner, or null. */
    const uint8_t *introducer;
    /* Introducer byte length; zero when null. */
    size_t introducer_len;
} GlowcapDialOrigin;
typedef struct GlowcapProviderFailure {
    /* Returned GLOWCAP_ERR_* status; zero on success. */
    int32_t result;
    /* GLOWCAP_CARRIER_PHASE_* or NONE when the provider cannot name a phase. */
    uint32_t carrier_phase;
    /* GLOWCAP_CARRIER_DETAIL_* presence bits. */
    uint32_t carrier_detail_flags;
    /* Neutral certificate-verification flags; zero when unavailable. */
    uint32_t carrier_verification_flags;
    /* Peer TLS alert byte when its presence bit is set. */
    uint32_t carrier_peer_alert;
    /* Private engine failure code when its presence bit is set. */
    int32_t carrier_engine_code;
    /* Immutable process-lifetime UTF-8 primary cause name. */
    const uint8_t *primary_name;
    /* Primary name byte length. */
    size_t primary_name_len;
    /* First secondary GLOWCAP_ERR_* status; zero when absent. */
    int32_t secondary_result;
    /* Immutable process-lifetime UTF-8 first secondary cause name. */
    const uint8_t *secondary_name;
    /* First secondary name byte length. */
    size_t secondary_name_len;
    /* Total secondary failure count. */
    uint32_t secondary_count;
} GlowcapProviderFailure;

typedef struct GlowcapListenResult GlowcapListenResult;
typedef struct GlowcapMultiplexedReadyEvent GlowcapMultiplexedReadyEvent;
typedef int32_t (*GlowcapMultiplexedReadinessFdFn)(void *ctx);
/* On GLOWCAP_OK, writes at most cap records and their count, with an empty
   failure. On error, leaves out_count untouched and returns the exact
   provider cause and cleanup chain through out_failure. */
typedef int32_t (*GlowcapMultiplexedDrainReadyFn)(void *ctx, GlowcapMultiplexedReadyEvent *out, size_t cap, size_t *out_count, GlowcapProviderFailure *out_failure);
/* origin names the session that introduced a handoff dial, or is null. */
typedef int32_t (*GlowcapMultiplexedStartConnectFn)(void *ctx, uint64_t request_id, const GlowcapLocatorView *locator, const GlowcapTransportOperationOptions *options, const GlowcapDialOrigin *origin, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedFinishConnectFn)(void *ctx, uint64_t request_id, uint64_t *out_conn, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedClaimExternalFn)(void *ctx, uint64_t subject, uint64_t *out_conn, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedListenFn)(void *ctx, uint64_t route_id, const uint8_t *transport, size_t transport_len, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, const GlowcapTransportOperationOptions *options, GlowcapListenResult *out_result, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedFinishListenFn)(void *ctx, uint64_t route_id, void **out_listener, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapTransportListenerLocatorFn)(void *listener_ctx, void *sink_ctx, GlowcapLocatorSinkFn sink, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapTransportListenerAdvertiseFn)(void *listener_ctx, const GlowcapLocatorView *locator, void *sink_ctx, GlowcapLocatorSinkFn sink, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapTransportListenerRestorationStateFn)(void *listener_ctx, uint8_t *out, size_t cap, size_t *out_len, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedFinishAcceptFn)(void *listener_ctx, uint64_t *out_conn, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedStopListenFn)(void *listener_ctx, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapMultiplexedSubjectFn)(void *ctx, uint64_t subject, GlowcapProviderFailure *out_failure);
typedef void (*GlowcapMultiplexedConnTakeFailureFn)(void *ctx, uint64_t conn, GlowcapProviderFailure *out_failure);
typedef intptr_t (*GlowcapMultiplexedTryReadFn)(void *ctx, uint64_t conn, uint8_t *buf, size_t cap);
typedef intptr_t (*GlowcapMultiplexedTryWriteFn)(void *ctx, uint64_t conn, const uint8_t *bytes, size_t len);
typedef int32_t (*GlowcapMultiplexedConnRemoteKeyFn)(void *ctx, uint64_t conn, uint8_t *out_key);
typedef struct GlowcapMultiplexedReadyEvent {
    /* Connection, connect request, or listener route id. */
    uint64_t subject;
    /* GLOWCAP_MULTIPLEXED_EV_* bits. */
    uint32_t events;
} GlowcapMultiplexedReadyEvent;
typedef struct GlowcapMultiplexedTransport {
    /* GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapMultiplexedTransport). */
    size_t struct_size;
    /* Provider-owned context; must outlive registration. */
    void *ctx;
    /* Level-shaped readiness descriptor; remains ready while records are pending. */
    GlowcapMultiplexedReadinessFdFn readiness_fd;
    /* Drain at most the supplied capacity of ready records. */
    GlowcapMultiplexedDrainReadyFn drain_ready;
    /* Start a non-blocking connect. */
    GlowcapMultiplexedStartConnectFn start_connect;
    /* Finish connect. */
    GlowcapMultiplexedFinishConnectFn finish_connect;
    /* Claim externally established connection. */
    GlowcapMultiplexedClaimExternalFn claim_external;
    /* Cancel connect; asynchronous retirement emits CONNECT, then a repeated call claims cleanup. */
    GlowcapMultiplexedSubjectFn cancel_connect;
    /* Begin listener construction; PENDING requires the completion pair. */
    GlowcapMultiplexedListenFn listen;
    /* Consume pending listener construction on every return; present exactly with cancel_listen. */
    GlowcapMultiplexedFinishListenFn finish_listen;
    /* Cancel pending setup or claim an asynchronously stopped listener after LISTEN. */
    GlowcapMultiplexedSubjectFn cancel_listen;
    /* Query canonical listener locator. */
    GlowcapTransportListenerLocatorFn listener_locator;
    /* Validate and canonicalize advertised locator. */
    GlowcapTransportListenerAdvertiseFn listener_advertise;
    /* Query or copy opaque listener restoration state. */
    GlowcapTransportListenerRestorationStateFn listener_restoration_state;
    /* Finish accept. */
    GlowcapMultiplexedFinishAcceptFn finish_accept;
    /* Stop listener; asynchronous retirement emits LISTEN, then cancel_listen claims cleanup. */
    GlowcapMultiplexedStopListenFn stop_listen;
    /* Read: 1..cap bytes, 0 at EOF, -1 when dead, or GLOWCAP_TRANSPORT_WOULD_BLOCK. */
    GlowcapMultiplexedTryReadFn try_read;
    /* Write: 0..len bytes consumed, -1 when dead, or GLOWCAP_TRANSPORT_WOULD_BLOCK. */
    GlowcapMultiplexedTryWriteFn try_write;
    /* Close connection; asynchronous retirement emits CLOSED, then a repeated call claims cleanup. */
    GlowcapMultiplexedSubjectFn conn_close;
    /* Atomically claim the connection's retained read/write failure. */
    GlowcapMultiplexedConnTakeFailureFn conn_take_failure;
    /* Copy proved remote key and return 1, or return 0; other statuses violate the contract. */
    GlowcapMultiplexedConnRemoteKeyFn conn_remote_key;
} GlowcapMultiplexedTransport;

typedef int32_t (*GlowcapStreamStartConnectFn)(void *ctx, const GlowcapLocatorView *locator, const GlowcapTransportOperationOptions *options, void **out_attempt, int32_t *out_readiness_fd, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamFinishConnectFn)(void *attempt, void **out_conn, int32_t *out_readiness_fd, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamCancelConnectFn)(void *attempt, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamFinishListenFn)(void *attempt, void **out_listener, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamCancelListenFn)(void *attempt, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamListenFn)(void *ctx, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, const GlowcapTransportOperationOptions *options, GlowcapListenResult *out_result, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamListenerWaitFn)(void *ctx, void *listener, int32_t timeout_ms, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamListenerReadinessFdFn)(void *ctx, void *listener);
typedef int32_t (*GlowcapStreamAcceptFn)(void *ctx, void *listener, void **out_conn, int32_t *out_readiness_fd, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapStreamListenerCloseFn)(void *ctx, void *listener, GlowcapProviderFailure *out_failure);
typedef intptr_t (*GlowcapStreamTryReadFn)(void *ctx, void *conn, uint8_t *out, size_t cap);
typedef intptr_t (*GlowcapStreamTryWriteFn)(void *ctx, void *conn, const uint8_t *bytes, size_t len);
typedef int32_t (*GlowcapStreamConnCloseFn)(void *ctx, void *conn, GlowcapProviderFailure *out_failure);
typedef void (*GlowcapStreamConnTakeFailureFn)(void *ctx, void *conn, GlowcapProviderFailure *out_failure);
typedef uint8_t (*GlowcapTransportProviderSameConfigurationFn)(void *ctx, void *other_ctx);
typedef int32_t (*GlowcapTransportRetainFn)(void *ctx, GlowcapProviderFailure *out_failure);
typedef int32_t (*GlowcapTransportReleaseFn)(void *ctx, GlowcapProviderFailure *out_failure);
typedef struct GlowcapListenResult {
    /* GLOWCAP_LISTEN_*; PENDING requires both completion callbacks. */
    uint32_t state;
    /* READY listener handle. */
    void *listener;
    /* Stream PENDING attempt handle. */
    void *attempt;
    /* Stream PENDING attempt readiness descriptor; -1 otherwise. */
    int32_t readiness_fd;
} GlowcapListenResult;
typedef struct GlowcapTransportProfile {
    /* GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapTransportProfile). */
    size_t struct_size;
    /* Borrowed transport symbol. */
    const uint8_t *transport_name;
    size_t transport_name_len;
    /* GLOWCAP_DESIGNATOR_SCHEME_*. */
    uint32_t designator_scheme;
    /* GLOWCAP_SEALED_CHANNEL_*. */
    uint32_t sealed_channel;
    /* GLOWCAP_WIRE_FRAMING_*. */
    uint32_t wire_framing;
    /* Maximum packet payload bytes, or 0 for no transport cap. */
    size_t max_packet_bytes;
} GlowcapTransportProfile;
typedef struct GlowcapStreamTransport {
    /* GLOWCAP_STREAM_TRANSPORT_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapStreamTransport). */
    size_t struct_size;
    /* Provider-owned context; must outlive registration. */
    void *ctx;
    /* Start a non-blocking stream connect. */
    GlowcapStreamStartConnectFn start_connect;
    /* Finish and consume a ready connect attempt. */
    GlowcapStreamFinishConnectFn finish_connect;
    /* Cancel and consume a connect attempt. */
    GlowcapStreamCancelConnectFn cancel_connect;
    /* Begin listener construction; PENDING requires the completion pair. */
    GlowcapStreamListenFn listen;
    /* Finish and consume a pending listener attempt on every return. */
    GlowcapStreamFinishListenFn finish_listen;
    /* Cancel a pending listener attempt before finish. */
    GlowcapStreamCancelListenFn cancel_listen;
    /* Wait for acceptable connection. */
    GlowcapStreamListenerWaitFn listener_wait_acceptable;
    /* Listener readiness descriptor. */
    GlowcapStreamListenerReadinessFdFn listener_readiness_fd;
    /* Query canonical listener locator. */
    GlowcapTransportListenerLocatorFn listener_locator;
    /* Validate and canonicalize advertised locator. */
    GlowcapTransportListenerAdvertiseFn listener_advertise;
    /* Query or copy opaque listener restoration state. */
    GlowcapTransportListenerRestorationStateFn listener_restoration_state;
    /* Accept raw stream. */
    GlowcapStreamAcceptFn accept;
    /* Close listener. */
    GlowcapStreamListenerCloseFn listener_close;
    /* Read: 1..cap bytes, 0 at EOF, -1 when dead, or GLOWCAP_TRANSPORT_WOULD_BLOCK. */
    GlowcapStreamTryReadFn try_read;
    /* Write: 1..len bytes consumed, -1 when dead, or GLOWCAP_TRANSPORT_WOULD_BLOCK. */
    GlowcapStreamTryWriteFn try_write;
    /* Close connection. */
    GlowcapStreamConnCloseFn conn_close;
    /* Atomically claim the connection's retained read/write failure. */
    GlowcapStreamConnTakeFailureFn conn_take_failure;
} GlowcapStreamTransport;
typedef struct GlowcapTransportProviderEntry {
    /* Copied semantic profile. */
    const GlowcapTransportProfile *profile;
    /* GLOWCAP_TRANSPORT_EXEC_*. */
    uint32_t execution_model;
    /* Execution table; equal multiplexed-table pointers in one package share one runtime. */
    const void *implementation;
} GlowcapTransportProviderEntry;
typedef struct GlowcapTransportProvider {
    /* GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapTransportProvider). */
    size_t struct_size;
    /* Borrowed entries; tables are copied during registration. */
    const GlowcapTransportProviderEntry *entries;
    /* Nonzero entry count. */
    size_t entry_count;
    /* Package-owned lease context. */
    void *lease_ctx;
    /* Compare complete effective configuration. */
    GlowcapTransportProviderSameConfigurationFn same_configuration;
    /* Acquire one registration lease. */
    GlowcapTransportRetainFn retain;
    /* Release the registration lease after all callbacks retire. */
    GlowcapTransportReleaseFn release;
} GlowcapTransportProvider;

#ifdef __cplusplus
}
#endif

#endif /* GLOWCAP_TRANSPORT_PROVIDER_H */
