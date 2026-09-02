//! Generates the archive-neutral transport provider contract.

const std = @import("std");
const cp = @import("c_abi_shared");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_transport_provider.h", .generate = generate },
};
pub const step_name = "gen-header-transport-provider";

const Spec = struct {
    pub const c = cp;
    pub const emitted_fns: []const []const u8 = &.{};

    pub fn constant(comptime name: []const u8) i64 {
        if (comptime std.mem.startsWith(u8, name, "GLOWCAP_CARRIER_"))
            return @intCast(@field(cp.transport_provider, name));
        return @intCast(@field(cp, name));
    }

    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "GLOWCAP_MULTIPLEXED_WOULD_BLOCK", .doc = "try_read and try_write result when the operation cannot progress without blocking." },
        .{ .name = "GLOWCAP_MULTIPLEXED_EV_READABLE", .doc = "GlowcapMultiplexedReadyEvent.events: subject has readable bytes." },
        .{ .name = "GLOWCAP_MULTIPLEXED_EV_WRITABLE", .doc = "GlowcapMultiplexedReadyEvent.events: subject can resume writing." },
        .{ .name = "GLOWCAP_MULTIPLEXED_EV_CLOSED", .doc = "GlowcapMultiplexedReadyEvent.events: subject closed." },
        .{ .name = "GLOWCAP_MULTIPLEXED_EV_ACCEPT", .doc = "GlowcapMultiplexedReadyEvent.events: a listener has an accepted connection to claim." },
        .{ .name = "GLOWCAP_MULTIPLEXED_EV_CONNECT", .doc = "GlowcapMultiplexedReadyEvent.events: a dial request completed." },
        .{ .name = "GLOWCAP_MULTIPLEXED_EV_LISTEN", .doc = "GlowcapMultiplexedReadyEvent.events: listener construction completed." },
        .{ .name = "GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION", .doc = "GlowcapMultiplexedTransport.abi_version." },
        .{ .name = "GLOWCAP_DESIGNATOR_SCHEME_ADDRESS", .doc = "GlowcapTransportProfile.designator_scheme: designators are addresses." },
        .{ .name = "GLOWCAP_DESIGNATOR_SCHEME_KEY", .doc = "GlowcapTransportProfile.designator_scheme: designators are peer keys." },
        .{ .name = "GLOWCAP_SEALED_CHANNEL_NONE", .doc = "GlowcapTransportProfile.sealed_channel: no Host-provided sealing." },
        .{ .name = "GLOWCAP_SEALED_CHANNEL_NOISE_XK", .doc = "GlowcapTransportProfile.sealed_channel: Host composes Noise_XK." },
        .{ .name = "GLOWCAP_WIRE_FRAMING_BYTE_STREAM", .doc = "GlowcapTransportProfile.wire_framing: packets are byte-stream chunks with ADR-0110 envelopes." },
        .{ .name = "GLOWCAP_WIRE_FRAMING_MESSAGE", .doc = "GlowcapTransportProfile.wire_framing: each packet is one bare codec frame." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_NONE", .doc = "GlowcapProviderFailure.carrier_phase: no carrier phase is available." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_RESOLVE", .doc = "Carrier failure occurred during name resolution." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_CONNECT", .doc = "Carrier failure occurred during byte-transport connect." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE", .doc = "Carrier failure occurred during the secure handshake." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE", .doc = "Carrier failure occurred during WebSocket upgrade." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_REGISTRATION", .doc = "Carrier failure occurred during relay registration." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_RECEIVE", .doc = "Carrier failure occurred while receiving bytes." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_TRANSMIT", .doc = "Carrier failure occurred while transmitting bytes." },
        .{ .name = "GLOWCAP_CARRIER_PHASE_SHUTDOWN", .doc = "Carrier failure occurred during shutdown." },
        .{ .name = "GLOWCAP_CARRIER_DETAIL_PEER_ALERT", .doc = "GlowcapProviderFailure.carrier_detail_flags: peer alert is present." },
        .{ .name = "GLOWCAP_CARRIER_DETAIL_ENGINE_CODE", .doc = "GlowcapProviderFailure.carrier_detail_flags: engine code is present." },
        .{ .name = "GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION", .doc = "GlowcapTransportProvider ABI version." },
        .{ .name = "GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION", .doc = "GlowcapTransportProfile ABI version." },
        .{ .name = "GLOWCAP_STREAM_TRANSPORT_ABI_VERSION", .doc = "GlowcapStreamTransport ABI version." },
        .{ .name = "GLOWCAP_LISTEN_READY", .doc = "GlowcapListenResult.state: listener construction completed." },
        .{ .name = "GLOWCAP_LISTEN_PENDING", .doc = "GlowcapListenResult.state: listener construction is pending." },
        .{ .name = "GLOWCAP_TRANSPORT_EXEC_STREAM", .doc = "Provider entry points to GlowcapStreamTransport." },
        .{ .name = "GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED", .doc = "Provider entry points to GlowcapMultiplexedTransport." },
    };

    pub fn special(comptime T: type) ?[]const u8 {
        @setEvalBranchQuota(8000);
        inline for (.{
            .{ cp.GlowcapMultiplexedReadinessFdFn, "GlowcapMultiplexedReadinessFdFn" },
            .{ cp.GlowcapMultiplexedDrainReadyFn, "GlowcapMultiplexedDrainReadyFn" },
            .{ cp.GlowcapMultiplexedStartConnectFn, "GlowcapMultiplexedStartConnectFn" },
            .{ cp.GlowcapMultiplexedFinishConnectFn, "GlowcapMultiplexedFinishConnectFn" },
            .{ cp.GlowcapMultiplexedClaimExternalFn, "GlowcapMultiplexedClaimExternalFn" },
            .{ cp.GlowcapMultiplexedListenFn, "GlowcapMultiplexedListenFn" },
            .{ cp.GlowcapMultiplexedFinishListenFn, "GlowcapMultiplexedFinishListenFn" },
            .{ cp.GlowcapMultiplexedFinishAcceptFn, "GlowcapMultiplexedFinishAcceptFn" },
            .{ cp.GlowcapMultiplexedStopListenFn, "GlowcapMultiplexedStopListenFn" },
            .{ cp.GlowcapMultiplexedSubjectFn, "GlowcapMultiplexedSubjectFn" },
            .{ cp.GlowcapMultiplexedConnTakeFailureFn, "GlowcapMultiplexedConnTakeFailureFn" },
            .{ cp.GlowcapMultiplexedTryReadFn, "GlowcapMultiplexedTryReadFn" },
            .{ cp.GlowcapMultiplexedTryWriteFn, "GlowcapMultiplexedTryWriteFn" },
            .{ cp.GlowcapMultiplexedConnRemoteKeyFn, "GlowcapMultiplexedConnRemoteKeyFn" },
            .{ cp.GlowcapStreamStartConnectFn, "GlowcapStreamStartConnectFn" },
            .{ cp.GlowcapStreamFinishConnectFn, "GlowcapStreamFinishConnectFn" },
            .{ cp.GlowcapStreamCancelConnectFn, "GlowcapStreamCancelConnectFn" },
            .{ cp.GlowcapStreamListenFn, "GlowcapStreamListenFn" },
            .{ cp.GlowcapStreamFinishListenFn, "GlowcapStreamFinishListenFn" },
            .{ cp.GlowcapStreamCancelListenFn, "GlowcapStreamCancelListenFn" },
            .{ cp.GlowcapStreamListenerWaitFn, "GlowcapStreamListenerWaitFn" },
            .{ cp.GlowcapStreamListenerReadinessFdFn, "GlowcapStreamListenerReadinessFdFn" },
            .{ cp.GlowcapLocatorSinkFn, "GlowcapLocatorSinkFn" },
            .{ cp.GlowcapTransportListenerLocatorFn, "GlowcapTransportListenerLocatorFn" },
            .{ cp.GlowcapTransportListenerAdvertiseFn, "GlowcapTransportListenerAdvertiseFn" },
            .{ cp.GlowcapTransportListenerRestorationStateFn, "GlowcapTransportListenerRestorationStateFn" },
            .{ cp.GlowcapStreamAcceptFn, "GlowcapStreamAcceptFn" },
            .{ cp.GlowcapStreamListenerCloseFn, "GlowcapStreamListenerCloseFn" },
            .{ cp.GlowcapStreamReadFn, "GlowcapStreamReadFn" },
            .{ cp.GlowcapStreamWriteAllFn, "GlowcapStreamWriteAllFn" },
            .{ cp.GlowcapStreamConnCloseFn, "GlowcapStreamConnCloseFn" },
            .{ cp.GlowcapStreamConnTakeFailureFn, "GlowcapStreamConnTakeFailureFn" },
            .{ cp.GlowcapTransportProviderSameConfigurationFn, "GlowcapTransportProviderSameConfigurationFn" },
        }) |entry| if (T == entry[0]) return entry[1];
        return null;
    }

    pub fn specialField(comptime Owner: type, comptime field: []const u8) ?[]const u8 {
        if (Owner == cp.GlowcapMultiplexedTransport) {
            if (std.mem.eql(u8, field, "claim_external")) return "GlowcapMultiplexedClaimExternalFn";
        }
        if (Owner == cp.GlowcapStreamTransport) {
            if (std.mem.eql(u8, field, "read")) return "GlowcapStreamReadFn";
            if (std.mem.eql(u8, field, "conn_close")) return "GlowcapStreamConnCloseFn";
        }
        if (Owner == cp.GlowcapTransportProvider) {
            if (std.mem.eql(u8, field, "same_configuration")) return "GlowcapTransportProviderSameConfigurationFn";
            if (std.mem.eql(u8, field, "retain")) return "GlowcapTransportRetainFn";
            if (std.mem.eql(u8, field, "release")) return "GlowcapTransportReleaseFn";
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
        \\   Handle-producing callbacks transfer outputs only on GLOWCAP_OK.
        \\   On every other status the provider cleans partial work and leaves
        \\   output slots untouched. finish_connect and finish_listen consume
        \\   their input operation on every return. A listener completion pair
        \\   is complete or absent; without both callbacks, listen must return
        \\   READY. An asynchronous cancel/close returns success after transfer,
        \\   emits the subject's terminal readiness after joining, and exposes
        \\   its claim-once cleanup outcome through the owning callback. */
        \\#ifndef GLOWCAP_TRANSPORT_PROVIDER_H
        \\#define GLOWCAP_TRANSPORT_PROVIDER_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_locator.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    inline for (.{
        "GLOWCAP_MULTIPLEXED_WOULD_BLOCK",         "GLOWCAP_MULTIPLEXED_EV_READABLE",
        "GLOWCAP_MULTIPLEXED_EV_WRITABLE",         "GLOWCAP_MULTIPLEXED_EV_CLOSED",
        "GLOWCAP_MULTIPLEXED_EV_ACCEPT",           "GLOWCAP_MULTIPLEXED_EV_CONNECT",
        "GLOWCAP_MULTIPLEXED_EV_LISTEN",           "GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION",
        "GLOWCAP_DESIGNATOR_SCHEME_ADDRESS",       "GLOWCAP_DESIGNATOR_SCHEME_KEY",
        "GLOWCAP_SEALED_CHANNEL_NONE",             "GLOWCAP_SEALED_CHANNEL_NOISE_XK",
        "GLOWCAP_WIRE_FRAMING_BYTE_STREAM",        "GLOWCAP_WIRE_FRAMING_MESSAGE",
        "GLOWCAP_CARRIER_PHASE_NONE",              "GLOWCAP_CARRIER_PHASE_RESOLVE",
        "GLOWCAP_CARRIER_PHASE_CONNECT",           "GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE",
        "GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE", "GLOWCAP_CARRIER_PHASE_REGISTRATION",
        "GLOWCAP_CARRIER_PHASE_RECEIVE",           "GLOWCAP_CARRIER_PHASE_TRANSMIT",
        "GLOWCAP_CARRIER_PHASE_SHUTDOWN",          "GLOWCAP_CARRIER_DETAIL_PEER_ALERT",
        "GLOWCAP_CARRIER_DETAIL_ENGINE_CODE",      "GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION",
        "GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION",   "GLOWCAP_STREAM_TRANSPORT_ABI_VERSION",
        "GLOWCAP_LISTEN_READY",                    "GLOWCAP_LISTEN_PENDING",
        "GLOWCAP_TRANSPORT_EXEC_STREAM",           "GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED",
    }) |name| try E.emitConst(&b, gpa, name);

    try E.emitStruct(&b, gpa, cp.GlowcapTransportOperationOptions, "GlowcapTransportOperationOptions", &.{
        "Borrowed provider-owned payload; null with size zero inherits provider defaults.",
        "Exact payload size; the selected provider validates its type.",
    });
    try E.emitStruct(&b, gpa, cp.GlowcapProviderFailure, "GlowcapProviderFailure", &.{
        "Returned GLOWCAP_ERR_* status; zero on success.",
        "GLOWCAP_CARRIER_PHASE_* or NONE when the provider cannot name a phase.",
        "GLOWCAP_CARRIER_DETAIL_* presence bits.",
        "Neutral certificate-verification flags; zero when unavailable.",
        "Peer TLS alert byte when its presence bit is set.",
        "Private engine failure code when its presence bit is set.",
        "Immutable process-lifetime UTF-8 primary cause name.",
        "Primary name byte length.",
        "First secondary GLOWCAP_ERR_* status; zero when absent.",
        "Immutable process-lifetime UTF-8 first secondary cause name.",
        "First secondary name byte length.",
        "Total secondary failure count.",
    });

    try b.appendSlice(gpa,
        \\
        \\typedef struct GlowcapListenResult GlowcapListenResult;
        \\typedef struct GlowcapMultiplexedReadyEvent GlowcapMultiplexedReadyEvent;
        \\typedef int32_t (*GlowcapMultiplexedReadinessFdFn)(void *ctx);
        \\/* On GLOWCAP_OK, writes at most cap records and their count, with an empty
        \\   failure. On error, leaves out_count untouched and returns the exact
        \\   provider cause and cleanup chain through out_failure. */
        \\typedef int32_t (*GlowcapMultiplexedDrainReadyFn)(void *ctx, GlowcapMultiplexedReadyEvent *out, size_t cap, size_t *out_count, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedStartConnectFn)(void *ctx, uint64_t request_id, const GlowcapLocatorView *locator, const GlowcapTransportOperationOptions *options, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedFinishConnectFn)(void *ctx, uint64_t request_id, uint64_t *out_conn, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedClaimExternalFn)(void *ctx, uint64_t subject, uint64_t *out_conn, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedListenFn)(void *ctx, uint64_t route_id, const uint8_t *transport, size_t transport_len, const uint8_t *requested_designator, size_t requested_designator_len, const GlowcapTransportOperationOptions *options, GlowcapListenResult *out_result, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedFinishListenFn)(void *ctx, uint64_t route_id, void **out_listener, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapTransportListenerLocatorFn)(void *listener_ctx, void *sink_ctx, GlowcapLocatorSinkFn sink, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapTransportListenerAdvertiseFn)(void *listener_ctx, const GlowcapLocatorView *locator, void *sink_ctx, GlowcapLocatorSinkFn sink, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapTransportListenerRestorationStateFn)(void *listener_ctx, uint8_t *out, size_t cap, size_t *out_len, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedFinishAcceptFn)(void *listener_ctx, uint64_t *out_conn, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedStopListenFn)(void *listener_ctx, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapMultiplexedSubjectFn)(void *ctx, uint64_t subject, GlowcapProviderFailure *out_failure);
        \\typedef void (*GlowcapMultiplexedConnTakeFailureFn)(void *ctx, uint64_t conn, GlowcapProviderFailure *out_failure);
        \\typedef intptr_t (*GlowcapMultiplexedTryReadFn)(void *ctx, uint64_t conn, uint8_t *buf, size_t cap);
        \\typedef intptr_t (*GlowcapMultiplexedTryWriteFn)(void *ctx, uint64_t conn, const uint8_t *bytes, size_t len);
        \\typedef int32_t (*GlowcapMultiplexedConnRemoteKeyFn)(void *ctx, uint64_t conn, uint8_t *out_key);
        \\
    );
    try E.emitStruct(&b, gpa, cp.GlowcapMultiplexedReadyEvent, "GlowcapMultiplexedReadyEvent", &.{ "Connection, connect request, or listener route id.", "GLOWCAP_MULTIPLEXED_EV_* bits." });
    try E.emitStruct(&b, gpa, cp.GlowcapMultiplexedTransport, "GlowcapMultiplexedTransport", &.{
        "GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION.",                                                  "sizeof(GlowcapMultiplexedTransport).",
        "Provider-owned context; must outlive registration.",                                          "Level-shaped readiness descriptor; remains ready while records are pending.",
        "Drain at most the supplied capacity of ready records.",                                       "Start a non-blocking connect.",
        "Finish connect.",                                                                             "Claim externally established connection.",
        "Cancel connect; asynchronous retirement emits CONNECT, then a repeated call claims cleanup.", "Begin listener construction; PENDING requires the completion pair.",
        "Consume pending listener construction on every return; present exactly with cancel_listen.",  "Cancel pending setup or claim an asynchronously stopped listener after LISTEN.",
        "Query canonical listener locator.",                                                           "Validate and canonicalize advertised locator.",
        "Query or copy opaque listener restoration state.",                                            "Finish accept.",
        "Stop listener; asynchronous retirement emits LISTEN, then cancel_listen claims cleanup.",     "Read: 0..cap bytes, 0 at EOF, -1 when dead, or GLOWCAP_MULTIPLEXED_WOULD_BLOCK.",
        "Write: 0..len bytes consumed, -1 when dead, or GLOWCAP_MULTIPLEXED_WOULD_BLOCK.",             "Close connection; asynchronous retirement emits CLOSED, then a repeated call claims cleanup.",
        "Atomically claim the connection's retained read/write failure.",                              "Copy proved remote key and return 1, or return 0; other statuses violate the contract.",
    });

    try b.appendSlice(gpa,
        \\
        \\typedef int32_t (*GlowcapStreamStartConnectFn)(void *ctx, const GlowcapLocatorView *locator, const GlowcapTransportOperationOptions *options, void **out_attempt, int32_t *out_readiness_fd, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamFinishConnectFn)(void *attempt, void **out_conn, int32_t *out_readiness_fd, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamCancelConnectFn)(void *attempt, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamFinishListenFn)(void *attempt, void **out_listener, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamCancelListenFn)(void *attempt, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamListenFn)(void *ctx, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, const GlowcapTransportOperationOptions *options, GlowcapListenResult *out_result, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamListenerWaitFn)(void *ctx, void *listener, int32_t timeout_ms, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamListenerReadinessFdFn)(void *ctx, void *listener);
        \\typedef int32_t (*GlowcapStreamAcceptFn)(void *ctx, void *listener, void **out_conn, int32_t *out_readiness_fd, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapStreamListenerCloseFn)(void *ctx, void *listener, GlowcapProviderFailure *out_failure);
        \\typedef intptr_t (*GlowcapStreamReadFn)(void *ctx, void *conn, uint8_t *out, size_t cap);
        \\typedef int32_t (*GlowcapStreamWriteAllFn)(void *ctx, void *conn, const uint8_t *bytes, size_t len);
        \\typedef int32_t (*GlowcapStreamConnCloseFn)(void *ctx, void *conn, GlowcapProviderFailure *out_failure);
        \\typedef void (*GlowcapStreamConnTakeFailureFn)(void *ctx, void *conn, GlowcapProviderFailure *out_failure);
        \\typedef uint8_t (*GlowcapTransportProviderSameConfigurationFn)(void *ctx, void *other_ctx);
        \\typedef int32_t (*GlowcapTransportRetainFn)(void *ctx, GlowcapProviderFailure *out_failure);
        \\typedef int32_t (*GlowcapTransportReleaseFn)(void *ctx, GlowcapProviderFailure *out_failure);
        \\
    );
    try E.emitStruct(&b, gpa, cp.GlowcapListenResult, "GlowcapListenResult", &.{
        "GLOWCAP_LISTEN_*; PENDING requires both completion callbacks.", "READY listener handle.", "Stream PENDING attempt handle.",
        "Stream PENDING attempt readiness descriptor; -1 otherwise.",
    });
    try E.emitStruct(&b, gpa, cp.GlowcapTransportProfile, "GlowcapTransportProfile", &.{
        "GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION.", "sizeof(GlowcapTransportProfile).",
        "Borrowed transport symbol.",             "",
        "GLOWCAP_DESIGNATOR_SCHEME_*.",           "GLOWCAP_SEALED_CHANNEL_*.",
        "GLOWCAP_WIRE_FRAMING_*.",                "Maximum packet payload bytes, or 0 for no transport cap.",
    });
    try E.emitStructWithTypes(&b, gpa, cp.GlowcapStreamTransport, "GlowcapStreamTransport", &.{
        "GLOWCAP_STREAM_TRANSPORT_ABI_VERSION.",                              "sizeof(GlowcapStreamTransport).",
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
        "GlowcapStreamStartConnectFn",         "GlowcapStreamFinishConnectFn",               "GlowcapStreamCancelConnectFn",
        "GlowcapStreamListenFn",               "GlowcapStreamFinishListenFn",                "GlowcapStreamCancelListenFn",
        "GlowcapStreamListenerWaitFn",         "GlowcapStreamListenerReadinessFdFn",         "GlowcapTransportListenerLocatorFn",
        "GlowcapTransportListenerAdvertiseFn", "GlowcapTransportListenerRestorationStateFn", "GlowcapStreamAcceptFn",
        "GlowcapStreamListenerCloseFn",        "GlowcapStreamReadFn",                        "GlowcapStreamWriteAllFn",
        "GlowcapStreamConnCloseFn",            "GlowcapStreamConnTakeFailureFn",
    });
    try E.emitStruct(&b, gpa, cp.GlowcapTransportProviderEntry, "GlowcapTransportProviderEntry", &.{
        "Copied semantic profile.",                                                            "GLOWCAP_TRANSPORT_EXEC_*.",
        "Execution table; equal multiplexed-table pointers in one package share one runtime.",
    });
    try E.emitStruct(&b, gpa, cp.GlowcapTransportProvider, "GlowcapTransportProvider", &.{
        "GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION.",                  "sizeof(GlowcapTransportProvider).",
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
        \\#endif /* GLOWCAP_TRANSPORT_PROVIDER_H */
        \\
    );
    return b.toOwnedSlice(gpa);
}
