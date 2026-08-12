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

    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "PANCAKE_MULTIPLEXED_WOULD_BLOCK", .doc = "try_read and try_write result when the operation cannot progress without blocking." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_READABLE", .doc = "PancakeMultiplexedReadyEvent.events: subject has readable bytes." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_WRITABLE", .doc = "PancakeMultiplexedReadyEvent.events: subject can resume writing." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_CLOSED", .doc = "PancakeMultiplexedReadyEvent.events: subject closed." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_ACCEPT", .doc = "PancakeMultiplexedReadyEvent.events: a listener has an accepted connection to claim." },
        .{ .name = "PANCAKE_MULTIPLEXED_EV_CONNECT", .doc = "PancakeMultiplexedReadyEvent.events: a dial request completed." },
        .{ .name = "PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION", .doc = "PancakeMultiplexedTransport.abi_version." },
        .{ .name = "PANCAKE_DESIGNATOR_SCHEME_ADDRESS", .doc = "PancakeTransportProfile.designator_scheme: designators are addresses." },
        .{ .name = "PANCAKE_DESIGNATOR_SCHEME_KEY", .doc = "PancakeTransportProfile.designator_scheme: designators are peer keys." },
        .{ .name = "PANCAKE_SEALED_CHANNEL_NONE", .doc = "PancakeTransportProfile.sealed_channel: no Host-provided sealing." },
        .{ .name = "PANCAKE_SEALED_CHANNEL_NOISE_XK", .doc = "PancakeTransportProfile.sealed_channel: Host composes Noise_XK." },
        .{ .name = "PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION", .doc = "PancakeTransportProvider ABI version." },
        .{ .name = "PANCAKE_TRANSPORT_PROFILE_ABI_VERSION", .doc = "PancakeTransportProfile ABI version." },
        .{ .name = "PANCAKE_STREAM_TRANSPORT_ABI_VERSION", .doc = "PancakeStreamTransport ABI version." },
        .{ .name = "PANCAKE_TRANSPORT_EXEC_STREAM", .doc = "Provider entry points to PancakeStreamTransport." },
        .{ .name = "PANCAKE_TRANSPORT_EXEC_MULTIPLEXED", .doc = "Provider entry points to PancakeMultiplexedTransport." },
    };

    pub fn special(comptime T: type) ?[]const u8 {
        inline for (.{
            .{ cp.PancakeMultiplexedReadinessFdFn, "PancakeMultiplexedReadinessFdFn" },
            .{ cp.PancakeMultiplexedDrainReadyFn, "PancakeMultiplexedDrainReadyFn" },
            .{ cp.PancakeMultiplexedStartConnectFn, "PancakeMultiplexedStartConnectFn" },
            .{ cp.PancakeMultiplexedFinishConnectFn, "PancakeMultiplexedFinishConnectFn" },
            .{ cp.PancakeMultiplexedClaimExternalFn, "PancakeMultiplexedClaimExternalFn" },
            .{ cp.PancakeMultiplexedStartListenFn, "PancakeMultiplexedStartListenFn" },
            .{ cp.PancakeMultiplexedFinishAcceptFn, "PancakeMultiplexedFinishAcceptFn" },
            .{ cp.PancakeMultiplexedStopListenFn, "PancakeMultiplexedStopListenFn" },
            .{ cp.PancakeMultiplexedSubjectFn, "PancakeMultiplexedSubjectFn" },
            .{ cp.PancakeMultiplexedTryReadFn, "PancakeMultiplexedTryReadFn" },
            .{ cp.PancakeMultiplexedTryWriteFn, "PancakeMultiplexedTryWriteFn" },
            .{ cp.PancakeMultiplexedConnRemoteKeyFn, "PancakeMultiplexedConnRemoteKeyFn" },
            .{ cp.PancakeStreamStartConnectFn, "PancakeStreamStartConnectFn" },
            .{ cp.PancakeStreamFinishConnectFn, "PancakeStreamFinishConnectFn" },
            .{ cp.PancakeStreamCancelConnectFn, "PancakeStreamCancelConnectFn" },
            .{ cp.PancakeStreamListenFn, "PancakeStreamListenFn" },
            .{ cp.PancakeStreamListenerWaitFn, "PancakeStreamListenerWaitFn" },
            .{ cp.PancakeStreamListenerReadinessFdFn, "PancakeStreamListenerReadinessFdFn" },
            .{ cp.PancakeLocatorSinkFn, "PancakeLocatorSinkFn" },
            .{ cp.PancakeTransportListenerLocatorFn, "PancakeTransportListenerLocatorFn" },
            .{ cp.PancakeTransportListenerAdvertiseFn, "PancakeTransportListenerAdvertiseFn" },
            .{ cp.PancakeStreamAcceptFn, "PancakeStreamAcceptFn" },
            .{ cp.PancakeStreamListenerCloseFn, "PancakeStreamListenerCloseFn" },
            .{ cp.PancakeStreamReadFn, "PancakeStreamReadFn" },
            .{ cp.PancakeStreamWriteAllFn, "PancakeStreamWriteAllFn" },
            .{ cp.PancakeStreamConnCloseFn, "PancakeStreamConnCloseFn" },
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
        \\   transport lifetime authority. */
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
        "PANCAKE_MULTIPLEXED_WOULD_BLOCK",           "PANCAKE_MULTIPLEXED_EV_READABLE",
        "PANCAKE_MULTIPLEXED_EV_WRITABLE",           "PANCAKE_MULTIPLEXED_EV_CLOSED",
        "PANCAKE_MULTIPLEXED_EV_ACCEPT",             "PANCAKE_MULTIPLEXED_EV_CONNECT",
        "PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION", "PANCAKE_DESIGNATOR_SCHEME_ADDRESS",
        "PANCAKE_DESIGNATOR_SCHEME_KEY",             "PANCAKE_SEALED_CHANNEL_NONE",
        "PANCAKE_SEALED_CHANNEL_NOISE_XK",           "PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION",
        "PANCAKE_TRANSPORT_PROFILE_ABI_VERSION",     "PANCAKE_STREAM_TRANSPORT_ABI_VERSION",
        "PANCAKE_TRANSPORT_EXEC_STREAM",             "PANCAKE_TRANSPORT_EXEC_MULTIPLEXED",
    }) |name| try E.emitConst(&b, gpa, name);

    try b.appendSlice(gpa,
        \\
        \\typedef struct PancakeMultiplexedReadyEvent PancakeMultiplexedReadyEvent;
        \\typedef int32_t (*PancakeMultiplexedReadinessFdFn)(void *ctx);
        \\typedef size_t (*PancakeMultiplexedDrainReadyFn)(void *ctx, PancakeMultiplexedReadyEvent *out, size_t cap);
        \\typedef int32_t (*PancakeMultiplexedStartConnectFn)(void *ctx, uint64_t request_id, const PancakeLocatorView *locator);
        \\typedef int32_t (*PancakeMultiplexedFinishConnectFn)(void *ctx, uint64_t request_id, uint64_t *out_conn);
        \\typedef int32_t (*PancakeMultiplexedClaimExternalFn)(void *ctx, uint64_t subject, uint64_t *out_conn);
        \\typedef int32_t (*PancakeMultiplexedStartListenFn)(void *ctx, uint64_t route_id, const uint8_t *transport, size_t transport_len, const uint8_t *requested_designator, size_t requested_designator_len, void **out_listener);
        \\typedef int32_t (*PancakeTransportListenerLocatorFn)(void *listener_ctx, void *sink_ctx, PancakeLocatorSinkFn sink);
        \\typedef int32_t (*PancakeTransportListenerAdvertiseFn)(void *listener_ctx, const PancakeLocatorView *locator, void *sink_ctx, PancakeLocatorSinkFn sink);
        \\typedef int32_t (*PancakeMultiplexedFinishAcceptFn)(void *listener_ctx, uint64_t *out_conn);
        \\typedef void (*PancakeMultiplexedStopListenFn)(void *listener_ctx);
        \\typedef void (*PancakeMultiplexedSubjectFn)(void *ctx, uint64_t subject);
        \\typedef intptr_t (*PancakeMultiplexedTryReadFn)(void *ctx, uint64_t conn, uint8_t *buf, size_t cap);
        \\typedef intptr_t (*PancakeMultiplexedTryWriteFn)(void *ctx, uint64_t conn, const uint8_t *bytes, size_t len);
        \\typedef int32_t (*PancakeMultiplexedConnRemoteKeyFn)(void *ctx, uint64_t conn, uint8_t *out_key);
        \\
    );
    try E.emitStruct(&b, gpa, cp.PancakeMultiplexedReadyEvent, "PancakeMultiplexedReadyEvent", &.{ "Connection, connect request, or listener route id.", "PANCAKE_MULTIPLEXED_EV_* bits." });
    try E.emitStruct(&b, gpa, cp.PancakeMultiplexedTransport, "PancakeMultiplexedTransport", &.{
        "PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION.",                                      "sizeof(PancakeMultiplexedTransport).",
        "Provider-owned context; must outlive registration.",                              "Level-shaped readiness descriptor; remains ready while records are pending.",
        "Drain at most the supplied capacity of ready records.",                           "Start a non-blocking connect.",
        "Finish connect.",                                                                 "Claim externally established connection.",
        "Cancel connect.",                                                                 "Start listener.",
        "Query canonical listener locator.",                                               "Validate and canonicalize advertised locator.",
        "Finish accept.",                                                                  "Stop listener.",
        "Read: 0..cap bytes, 0 at EOF, -1 when dead, or PANCAKE_MULTIPLEXED_WOULD_BLOCK.", "Write: 0..len bytes consumed, -1 when dead, or PANCAKE_MULTIPLEXED_WOULD_BLOCK.",
        "Close connection.",                                                               "Copy proved remote key and return 1, or return 0; other statuses violate the contract.",
    });

    try b.appendSlice(gpa,
        \\
        \\typedef int32_t (*PancakeStreamStartConnectFn)(void *ctx, const PancakeLocatorView *locator, void **out_attempt, int32_t *out_readiness_fd);
        \\typedef int32_t (*PancakeStreamFinishConnectFn)(void *attempt, void **out_conn, int32_t *out_readiness_fd);
        \\typedef void (*PancakeStreamCancelConnectFn)(void *attempt);
        \\typedef int32_t (*PancakeStreamListenFn)(void *ctx, const uint8_t *requested_designator, size_t requested_designator_len, const uint8_t *identity_designator, size_t identity_designator_len, void **out_listener);
        \\typedef int32_t (*PancakeStreamListenerWaitFn)(void *ctx, void *listener, int32_t timeout_ms);
        \\typedef int32_t (*PancakeStreamListenerReadinessFdFn)(void *ctx, void *listener);
        \\typedef int32_t (*PancakeStreamAcceptFn)(void *ctx, void *listener, void **out_conn, int32_t *out_readiness_fd);
        \\typedef void (*PancakeStreamListenerCloseFn)(void *ctx, void *listener);
        \\typedef intptr_t (*PancakeStreamReadFn)(void *ctx, void *conn, uint8_t *out, size_t cap);
        \\typedef int32_t (*PancakeStreamWriteAllFn)(void *ctx, void *conn, const uint8_t *bytes, size_t len);
        \\typedef void (*PancakeStreamConnCloseFn)(void *ctx, void *conn);
        \\typedef int32_t (*PancakeTransportRetainFn)(void *ctx);
        \\typedef void (*PancakeTransportReleaseFn)(void *ctx);
        \\
    );
    try E.emitStruct(&b, gpa, cp.PancakeTransportProfile, "PancakeTransportProfile", &.{
        "PANCAKE_TRANSPORT_PROFILE_ABI_VERSION.", "sizeof(PancakeTransportProfile).",
        "Borrowed transport symbol.",             "",
        "PANCAKE_DESIGNATOR_SCHEME_*.",           "PANCAKE_SEALED_CHANNEL_*.",
    });
    try E.emitStructWithTypes(&b, gpa, cp.PancakeStreamTransport, "PancakeStreamTransport", &.{
        "PANCAKE_STREAM_TRANSPORT_ABI_VERSION.",              "sizeof(PancakeStreamTransport).",
        "Provider-owned context; must outlive registration.", "Start a non-blocking stream connect.",
        "Finish and consume a ready connect attempt.",        "Cancel and consume a connect attempt.",
        "Start listener.",                                    "Wait for listener metadata.",
        "Wait for acceptable connection.",                    "Listener readiness descriptor.",
        "Query canonical listener locator.",                  "Validate and canonicalize advertised locator.",
        "Accept raw stream.",                                 "Close listener.",
        "Read bytes.",                                        "Write all bytes.",
        "Close connection.",
    }, &.{
        "",                                   "",                                  "",
        "PancakeStreamStartConnectFn",        "PancakeStreamFinishConnectFn",      "PancakeStreamCancelConnectFn",
        "PancakeStreamListenFn",              "PancakeStreamListenerWaitFn",       "PancakeStreamListenerWaitFn",
        "PancakeStreamListenerReadinessFdFn", "PancakeTransportListenerLocatorFn", "PancakeTransportListenerAdvertiseFn",
        "PancakeStreamAcceptFn",              "PancakeStreamListenerCloseFn",      "PancakeStreamReadFn",
        "PancakeStreamWriteAllFn",            "PancakeStreamConnCloseFn",
    });
    try E.emitStruct(&b, gpa, cp.PancakeTransportProviderEntry, "PancakeTransportProviderEntry", &.{
        "Copied semantic profile.",                                                            "PANCAKE_TRANSPORT_EXEC_*.",
        "Execution table; equal multiplexed-table pointers in one package share one runtime.",
    });
    try E.emitStruct(&b, gpa, cp.PancakeTransportProvider, "PancakeTransportProvider", &.{
        "PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION.",                    "sizeof(PancakeTransportProvider).",
        "Borrowed entries; tables are copied during registration.",   "Nonzero entry count.",
        "Package-owned lease context.",                               "Acquire one registration lease.",
        "Release the registration lease after all callbacks retire.",
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
