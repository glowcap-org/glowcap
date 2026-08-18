//! Generates the archive-neutral transport provider contract.

const std = @import("std");
const cp = @import("c_abi_shared");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_transport_provider.h", .generate = generate },
};
pub const step_name = "gen-header-transport-provider";

const Spec = struct {
    pub const c = cp;
    pub const emitted_fns: []const []const u8 = &.{};

    pub fn constant(comptime name: []const u8) i64 {
        if (comptime std.mem.startsWith(u8, name, "PANCAKE_CARRIER_"))
            return @intCast(@field(cp.transport_provider, name));
        return @intCast(@field(cp, name));
    }

    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "PANCAKE_MULTIPLEXED_WOULD_BLOCK", .doc = "try_read and try_write result when the operation cannot progress without blocking." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_READABLE", .doc = "PancakeMultiplexedReadyEvent.events: subject has readable bytes." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_WRITABLE", .doc = "PancakeMultiplexedReadyEvent.events: subject can resume writing." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_CLOSED", .doc = "PancakeMultiplexedReadyEvent.events: subject closed." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_ACCEPT", .doc = "PancakeMultiplexedReadyEvent.events: a listener has an accepted connection to claim." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_CONNECT", .doc = "PancakeMultiplexedReadyEvent.events: a dial request completed." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_LISTEN", .doc = "PancakeMultiplexedReadyEvent.events: listener construction completed." },
        .{ .name = "PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION", .doc = "PancakeMultiplexedTransport.abi_version." },
        .{ .name = "PANCAKE_DESIGNATOR_SCHEME_ADDRESS", .doc = "PancakeTransportProfile.designator_scheme: designators are addresses." },
        .{ .name = "PANCAKE_DESIGNATOR_SCHEME_KEY", .doc = "PancakeTransportProfile.designator_scheme: designators are peer keys." },
        .{ .name = "PANCAKE_SEALED_CHANNEL_NONE", .doc = "PancakeTransportProfile.sealed_channel: no Host-provided sealing." },
        .{ .name = "PANCAKE_SEALED_CHANNEL_NOISE_XK", .doc = "PancakeTransportProfile.sealed_channel: Host composes Noise_XK." },
        .{ .name = "PANCAKE_CARRIER_PHASE_NONE", .doc = "PancakeProviderFailure.carrier_phase: no carrier phase is available." },
        .{ .name = "PANCAKE_CARRIER_PHASE_RESOLVE", .doc = "Carrier failure occurred during name resolution." },
        .{ .name = "PANCAKE_CARRIER_PHASE_CONNECT", .doc = "Carrier failure occurred during byte-transport connect." },
        .{ .name = "PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE", .doc = "Carrier failure occurred during the secure handshake." },
        .{ .name = "PANCAKE_CARRIER_PHASE_WEBSOCKET_UPGRADE", .doc = "Carrier failure occurred during WebSocket upgrade." },
        .{ .name = "PANCAKE_CARRIER_PHASE_REGISTRATION", .doc = "Carrier failure occurred during relay registration." },
        .{ .name = "PANCAKE_CARRIER_PHASE_RECEIVE", .doc = "Carrier failure occurred while receiving bytes." },
        .{ .name = "PANCAKE_CARRIER_PHASE_TRANSMIT", .doc = "Carrier failure occurred while transmitting bytes." },
        .{ .name = "PANCAKE_CARRIER_PHASE_SHUTDOWN", .doc = "Carrier failure occurred during shutdown." },
        .{ .name = "PANCAKE_CARRIER_DETAIL_PEER_ALERT", .doc = "PancakeProviderFailure.carrier_detail_flags: peer alert is present." },
        .{ .name = "PANCAKE_CARRIER_DETAIL_ENGINE_CODE", .doc = "PancakeProviderFailure.carrier_detail_flags: engine code is present." },
        .{ .name = "PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION", .doc = "PancakeTransportProvider ABI version." },
        .{ .name = "PANCAKE_TRANSPORT_PROFILE_ABI_VERSION", .doc = "PancakeTransportProfile ABI version." },
        .{ .name = "PANCAKE_STREAM_TRANSPORT_ABI_VERSION", .doc = "PancakeStreamTransport ABI version." },
        .{ .name = "PANCAKE_LISTEN_READY", .doc = "PancakeListenResult.state: listener construction completed." },
        .{ .name = "PANCAKE_LISTEN_PENDING", .doc = "PancakeListenResult.state: listener construction is pending." },
        .{ .name = "PANCAKE_TRANSPORT_EXEC_STREAM", .doc = "Provider entry points to PancakeStreamTransport." },
        .{ .name = "PANCAKE_TRANSPORT_EXEC_MULTIPLEXED", .doc = "Provider entry points to PancakeMultiplexedTransport." },
    };

    pub fn special(comptime T: type) ?[]const u8 {
        @setEvalBranchQuota(8000);
        inline for (.{
            .{ cp.PancakeMultiplexedReadinessFdFn, "PancakeMultiplexedReadinessFdFn" },
            .{ cp.PancakeMultiplexedDrainReadyFn, "PancakeMultiplexedDrainReadyFn" },
            .{ cp.PancakeMultiplexedStartConnectFn, "PancakeMultiplexedStartConnectFn" },
            .{ cp.PancakeMultiplexedFinishConnectFn, "PancakeMultiplexedFinishConnectFn" },
            .{ cp.PancakeMultiplexedClaimExternalFn, "PancakeMultiplexedClaimExternalFn" },
            .{ cp.PancakeMultiplexedListenFn, "PancakeMultiplexedListenFn" },
            .{ cp.PancakeMultiplexedFinishListenFn, "PancakeMultiplexedFinishListenFn" },
            .{ cp.PancakeMultiplexedFinishAcceptFn, "PancakeMultiplexedFinishAcceptFn" },
            .{ cp.PancakeMultiplexedStopListenFn, "PancakeMultiplexedStopListenFn" },
            .{ cp.PancakeMultiplexedSubjectFn, "PancakeMultiplexedSubjectFn" },
            .{ cp.PancakeMultiplexedConnTakeFailureFn, "PancakeMultiplexedConnTakeFailureFn" },
            .{ cp.PancakeMultiplexedTryReadFn, "PancakeMultiplexedTryReadFn" },
            .{ cp.PancakeMultiplexedTryWriteFn, "PancakeMultiplexedTryWriteFn" },
            .{ cp.PancakeMultiplexedConnRemoteKeyFn, "PancakeMultiplexedConnRemoteKeyFn" },
            .{ cp.PancakeStreamStartConnectFn, "PancakeStreamStartConnectFn" },
            .{ cp.PancakeStreamFinishConnectFn, "PancakeStreamFinishConnectFn" },
            .{ cp.PancakeStreamCancelConnectFn, "PancakeStreamCancelConnectFn" },
            .{ cp.PancakeStreamListenFn, "PancakeStreamListenFn" },
            .{ cp.PancakeStreamFinishListenFn, "PancakeStreamFinishListenFn" },
            .{ cp.PancakeStreamCancelListenFn, "PancakeStreamCancelListenFn" },
            .{ cp.PancakeStreamListenerWaitFn, "PancakeStreamListenerWaitFn" },
            .{ cp.PancakeStreamListenerReadinessFdFn, "PancakeStreamListenerReadinessFdFn" },
            .{ cp.PancakeLocatorSinkFn, "PancakeLocatorSinkFn" },
            .{ cp.PancakeTransportListenerLocatorFn, "PancakeTransportListenerLocatorFn" },
            .{ cp.PancakeTransportListenerAdvertiseFn, "PancakeTransportListenerAdvertiseFn" },
            .{ cp.PancakeTransportListenerRestorationStateFn, "PancakeTransportListenerRestorationStateFn" },
            .{ cp.PancakeStreamAcceptFn, "PancakeStreamAcceptFn" },
            .{ cp.PancakeStreamListenerCloseFn, "PancakeStreamListenerCloseFn" },
            .{ cp.PancakeStreamReadFn, "PancakeStreamReadFn" },
            .{ cp.PancakeStreamWriteAllFn, "PancakeStreamWriteAllFn" },
            .{ cp.PancakeStreamConnCloseFn, "PancakeStreamConnCloseFn" },
            .{ cp.PancakeStreamConnTakeFailureFn, "PancakeStreamConnTakeFailureFn" },
            .{ cp.PancakeTransportProviderSameConfigurationFn, "PancakeTransportProviderSameConfigurationFn" },
        }) |entry| if (T == entry[0]) return entry[1];
        return null;
    }

    pub fn specialField(comptime Owner: type, comptime field: []const u8) ?[]const u8 {
        if (Owner == cp.PancakeMultiplexedTransport) {
            if (std.mem.eql(u8, field, "claim_external")) return "PancakeMultiplexedClaimExternalFn";
        }
        if (Owner == cp.PancakeStreamTransport) {
            if (std.mem.eql(u8, field, "read")) return "PancakeStreamReadFn";
            if (std.mem.eql(u8, field, "conn_close")) return "PancakeStreamConnCloseFn";
        }
        if (Owner == cp.PancakeTransportProvider) {
            if (std.mem.eql(u8, field, "same_configuration")) return "PancakeTransportProviderSameConfigurationFn";
            if (std.mem.eql(u8, field, "retain")) return "PancakeTransportRetainFn";
            if (std.mem.eql(u8, field, "release")) return "PancakeTransportReleaseFn";
        }
        return null;
    }
};

const E = header_emit.Emit(Spec);

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: header_emit.Buf = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa,
        \\/* Generated from the shared transport provider ABI in
        \\   src/c_abi/shared/transport_provider.zig and
        \\   src/c_abi/shared/multiplexed_transport.zig.
        \\   Do not edit by hand: run `zig build gen-header-transport-provider`.
        \\   This standalone layout-only contract is shared by the driver and
        \\   every transport archive. Provider retain/release is the native
        \\   transport lifetime authority.
        \\   Handle-producing callbacks transfer outputs only on PANCAKE_OK.
        \\   On every other status the provider cleans partial work and leaves
        \\   output slots untouched. finish_connect and finish_listen consume
        \\   their input operation on every return. A listener completion pair
        \\   is complete or absent; without both callbacks, listen must return
        \\   READY. An asynchronous cancel/close returns success after transfer,
        \\   emits the subject's terminal readiness after joining, and exposes
        \\   its claim-once cleanup outcome through the owning callback. */
        \\#ifndef PANCAKE_TRANSPORT_PROVIDER_H
        \\#define PANCAKE_TRANSPORT_PROVIDER_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_locator.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    inline for (.{
        "PANCAKE_MULTIPLEXED_WOULD_BLOCK",         "PANCAKE_MULTIPLEXED_EV_READABLE",
        "PANCAKE_MULTIPLEXED_EV_WRITABLE",         "PANCAKE_MULTIPLEXED_EV_CLOSED",
        "PANCAKE_MULTIPLEXED_EV_ACCEPT",           "PANCAKE_MULTIPLEXED_EV_CONNECT",
        "PANCAKE_MULTIPLEXED_EV_LISTEN",           "PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION",
        "PANCAKE_DESIGNATOR_SCHEME_ADDRESS",       "PANCAKE_DESIGNATOR_SCHEME_KEY",
        "PANCAKE_SEALED_CHANNEL_NONE",             "PANCAKE_SEALED_CHANNEL_NOISE_XK",
        "PANCAKE_CARRIER_PHASE_NONE",              "PANCAKE_CARRIER_PHASE_RESOLVE",
        "PANCAKE_CARRIER_PHASE_CONNECT",           "PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE",
        "PANCAKE_CARRIER_PHASE_WEBSOCKET_UPGRADE", "PANCAKE_CARRIER_PHASE_REGISTRATION",
        "PANCAKE_CARRIER_PHASE_RECEIVE",           "PANCAKE_CARRIER_PHASE_TRANSMIT",
        "PANCAKE_CARRIER_PHASE_SHUTDOWN",          "PANCAKE_CARRIER_DETAIL_PEER_ALERT",
        "PANCAKE_CARRIER_DETAIL_ENGINE_CODE",      "PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION",
        "PANCAKE_TRANSPORT_PROFILE_ABI_VERSION",   "PANCAKE_STREAM_TRANSPORT_ABI_VERSION",
        "PANCAKE_LISTEN_READY",                    "PANCAKE_LISTEN_PENDING",
        "PANCAKE_TRANSPORT_EXEC_STREAM",           "PANCAKE_TRANSPORT_EXEC_MULTIPLEXED",
    }) |name| try E.emitConst(&b, gpa, name);

    try E.emitStruct(&b, gpa, cp.PancakeTransportOperationOptions, "PancakeTransportOperationOptions", &.{
        "Borrowed provider-owned payload; null with size zero inherits provider defaults.",
        "Exact payload size; the selected provider validates its type.",
    });
    try E.emitStruct(&b, gpa, cp.PancakeProviderFailure, "PancakeProviderFailure", &.{
        "Returned PANCAKE_ERR_* status; zero on success.",
        "PANCAKE_CARRIER_PHASE_* or NONE when the provider cannot name a phase.",
        "PANCAKE_CARRIER_DETAIL_* presence bits.",
        "Neutral certificate-verification flags; zero when unavailable.",
        "Peer TLS alert byte when its presence bit is set.",
        "Private engine failure code when its presence bit is set.",
        "Immutable process-lifetime UTF-8 primary cause name.",
        "Primary name byte length.",
        "First secondary PANCAKE_ERR_* status; zero when absent.",
        "Immutable process-lifetime UTF-8 first secondary cause name.",
        "First secondary name byte length.",
        "Total secondary failure count.",
    });

    try b.appendSlice(gpa,
        \\
        \\typedef struct PancakeListenResult PancakeListenResult;
        \\typedef struct PancakeMultiplexedReadyEvent PancakeMultiplexedReadyEvent;
        \\typedef int32_t (*PancakeMultiplexedReadinessFdFn)(void *ctx);
        \\/* On PANCAKE_OK, writes at most cap records and their count, with an empty
        \\   failure. On error, leaves out_count untouched and returns the exact
        \\   provider cause and cleanup chain through out_failure. */
        \\typedef int32_t (*PancakeMultiplexedDrainReadyFn)(void *ctx, PancakeMultiplexedReadyEvent *out, size_t cap, size_t *out_count, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedStartConnectFn)(void *ctx, uint64_t request_id, const PancakeLocatorView *locator, const PancakeTransportOperationOptions *options, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedFinishConnectFn)(void *ctx, uint64_t request_id, uint64_t *out_conn, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedClaimExternalFn)(void *ctx, uint64_t subject, uint64_t *out_conn, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedListenFn)(void *ctx, uint64_t route_id, const uint8_t *transport, size_t transport_len, const uint8_t *requested_designator, size_t requested_designator_len, const PancakeTransportOperationOptions *options, PancakeListenResult *out_result, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedFinishListenFn)(void *ctx, uint64_t route_id, void **out_listener, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeTransportListenerLocatorFn)(void *listener_ctx, void *sink_ctx, PancakeLocatorSinkFn sink, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeTransportListenerAdvertiseFn)(void *listener_ctx, const PancakeLocatorView *locator, void *sink_ctx, PancakeLocatorSinkFn sink, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeTransportListenerRestorationStateFn)(void *listener_ctx, uint8_t *out, size_t cap, size_t *out_len, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedFinishAcceptFn)(void *listener_ctx, uint64_t *out_conn, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedStopListenFn)(void *listener_ctx, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeMultiplexedSubjectFn)(void *ctx, uint64_t subject, PancakeProviderFailure *out_failure);
        \\typedef void (*PancakeMultiplexedConnTakeFailureFn)(void *ctx, uint64_t conn, PancakeProviderFailure *out_failure);
        \\typedef intptr_t (*PancakeMultiplexedTryReadFn)(void *ctx, uint64_t conn, uint8_t *buf, size_t cap);
        \\typedef intptr_t (*PancakeMultiplexedTryWriteFn)(void *ctx, uint64_t conn, const uint8_t *bytes, size_t len);
        \\typedef int32_t (*PancakeMultiplexedConnRemoteKeyFn)(void *ctx, uint64_t conn, uint8_t *out_key);
        \\
    );
    try E.emitStruct(&b, gpa, cp.PancakeMultiplexedReadyEvent, "PancakeMultiplexedReadyEvent", &.{ "Connection, connect request, or listener route id.", "PANCAKE_MULTIPLEXED_EV_* bits." });
    try E.emitStruct(&b, gpa, cp.PancakeMultiplexedTransport, "PancakeMultiplexedTransport", &.{
        "PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION.",                                                  "sizeof(PancakeMultiplexedTransport).",
        "Provider-owned context; must outlive registration.",                                          "Level-shaped readiness descriptor; remains ready while records are pending.",
        "Drain at most the supplied capacity of ready records.",                                       "Start a non-blocking connect.",
        "Finish connect.",                                                                             "Claim externally established connection.",
        "Cancel connect; asynchronous retirement emits CONNECT, then a repeated call claims cleanup.", "Begin listener construction; PENDING requires the completion pair.",
        "Consume pending listener construction on every return; present exactly with cancel_listen.",  "Cancel pending setup or claim an asynchronously stopped listener after LISTEN.",
        "Query canonical listener locator.",                                                           "Validate and canonicalize advertised locator.",
        "Query or copy opaque listener restoration state.",                                            "Finish accept.",
        "Stop listener; asynchronous retirement emits LISTEN, then cancel_listen claims cleanup.",     "Read: 0..cap bytes, 0 at EOF, -1 when dead, or PANCAKE_MULTIPLEXED_WOULD_BLOCK.",
        "Write: 0..len bytes consumed, -1 when dead, or PANCAKE_MULTIPLEXED_WOULD_BLOCK.",             "Close connection; asynchronous retirement emits CLOSED, then a repeated call claims cleanup.",
        "Atomically claim the connection's retained read/write failure.",                              "Copy proved remote key and return 1, or return 0; other statuses violate the contract.",
    });

    try b.appendSlice(gpa,
        \\
        \\typedef int32_t (*PancakeStreamStartConnectFn)(void *ctx, const PancakeLocatorView *locator, const PancakeTransportOperationOptions *options, void **out_attempt, int32_t *out_readiness_fd, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamFinishConnectFn)(void *attempt, void **out_conn, int32_t *out_readiness_fd, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamCancelConnectFn)(void *attempt, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamFinishListenFn)(void *attempt, void **out_listener, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamCancelListenFn)(void *attempt, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamListenFn)(void *ctx, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, const PancakeTransportOperationOptions *options, PancakeListenResult *out_result, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamListenerWaitFn)(void *ctx, void *listener, int32_t timeout_ms, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamListenerReadinessFdFn)(void *ctx, void *listener);
        \\typedef int32_t (*PancakeStreamAcceptFn)(void *ctx, void *listener, void **out_conn, int32_t *out_readiness_fd, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeStreamListenerCloseFn)(void *ctx, void *listener, PancakeProviderFailure *out_failure);
        \\typedef intptr_t (*PancakeStreamReadFn)(void *ctx, void *conn, uint8_t *out, size_t cap);
        \\typedef int32_t (*PancakeStreamWriteAllFn)(void *ctx, void *conn, const uint8_t *bytes, size_t len);
        \\typedef int32_t (*PancakeStreamConnCloseFn)(void *ctx, void *conn, PancakeProviderFailure *out_failure);
        \\typedef void (*PancakeStreamConnTakeFailureFn)(void *ctx, void *conn, PancakeProviderFailure *out_failure);
        \\typedef uint8_t (*PancakeTransportProviderSameConfigurationFn)(void *ctx, void *other_ctx);
        \\typedef int32_t (*PancakeTransportRetainFn)(void *ctx, PancakeProviderFailure *out_failure);
        \\typedef int32_t (*PancakeTransportReleaseFn)(void *ctx, PancakeProviderFailure *out_failure);
        \\
    );
    try E.emitStruct(&b, gpa, cp.PancakeListenResult, "PancakeListenResult", &.{
        "PANCAKE_LISTEN_*; PENDING requires both completion callbacks.", "READY listener handle.", "Stream PENDING attempt handle.",
        "Stream PENDING attempt readiness descriptor; -1 otherwise.",
    });
    try E.emitStruct(&b, gpa, cp.PancakeTransportProfile, "PancakeTransportProfile", &.{
        "PANCAKE_TRANSPORT_PROFILE_ABI_VERSION.", "sizeof(PancakeTransportProfile).",
        "Borrowed transport symbol.",             "",
        "PANCAKE_DESIGNATOR_SCHEME_*.",           "PANCAKE_SEALED_CHANNEL_*.",
    });
    try E.emitStructWithTypes(&b, gpa, cp.PancakeStreamTransport, "PancakeStreamTransport", &.{
        "PANCAKE_STREAM_TRANSPORT_ABI_VERSION.",                              "sizeof(PancakeStreamTransport).",
        "Provider-owned context; must outlive registration.",                 "Start a non-blocking stream connect.",
        "Finish and consume a ready connect attempt.",                        "Cancel and consume a connect attempt.",
        "Begin listener construction; PENDING requires the completion pair.", "Finish and consume a pending listener attempt on every return.",
        "Cancel a pending listener attempt before finish.",                   "Wait for acceptable connection.",
        "Listener readiness descriptor.",                                     "Query canonical listener locator.",
        "Validate and canonicalize advertised locator.",                      "Query or copy opaque listener restoration state.",
        "Accept raw stream.",                                                 "Close listener.",
        "Read bytes.",                                                        "Write all bytes.",
        "Close connection.",                                                  "Atomically claim the connection's retained read/write failure.",
    }, &.{
        "",                                    "",                                           "",
        "PancakeStreamStartConnectFn",         "PancakeStreamFinishConnectFn",               "PancakeStreamCancelConnectFn",
        "PancakeStreamListenFn",               "PancakeStreamFinishListenFn",                "PancakeStreamCancelListenFn",
        "PancakeStreamListenerWaitFn",         "PancakeStreamListenerReadinessFdFn",         "PancakeTransportListenerLocatorFn",
        "PancakeTransportListenerAdvertiseFn", "PancakeTransportListenerRestorationStateFn", "PancakeStreamAcceptFn",
        "PancakeStreamListenerCloseFn",        "PancakeStreamReadFn",                        "PancakeStreamWriteAllFn",
        "PancakeStreamConnCloseFn",            "PancakeStreamConnTakeFailureFn",
    });
    try E.emitStruct(&b, gpa, cp.PancakeTransportProviderEntry, "PancakeTransportProviderEntry", &.{
        "Copied semantic profile.",                                                            "PANCAKE_TRANSPORT_EXEC_*.",
        "Execution table; equal multiplexed-table pointers in one package share one runtime.",
    });
    try E.emitStruct(&b, gpa, cp.PancakeTransportProvider, "PancakeTransportProvider", &.{
        "PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION.",                  "sizeof(PancakeTransportProvider).",
        "Borrowed entries; tables are copied during registration.", "Nonzero entry count.",
        "Package-owned lease context.",                             "Compare complete effective configuration.",
        "Acquire one registration lease.",                          "Release the registration lease after all callbacks retire.",
    });

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_TRANSPORT_PROVIDER_H */
        \\
    );
    return b.toOwnedSlice(gpa);
}
