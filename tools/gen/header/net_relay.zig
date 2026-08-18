//! Generates the relay provider archive's public C header from its Zig ABI.

const std = @import("std");
const c = @import("c_abi_net_transport_relay");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_net_transport_relay.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-relay";

const emitted_fn_names = [_][]const u8{
    "pancake_relay_archive_fingerprint",
    "pancake_relay_runtime_new",
    "pancake_relay_runtime_new_in",
    "pancake_relay_runtime_trust_summary",
    "pancake_relay_transport_provider",
    "pancake_relay_runtime_release",
    "pancake_relay_last_error",
    "pancake_relay_clear_last_error",
};

const Spec = struct {
    pub const c = @import("c_abi_net_transport_relay");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

comptime {
    E.guardFns("c_abi_net_transport_relay", "pancake_relay_");
}

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/relay/mod.zig by tools/gen/header/net_relay.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-relay`.
        \\   Function signatures and configuration layout are reflected from Zig. */
        \\#ifndef PANCAKE_NET_TRANSPORT_RELAY_H
        \\#define PANCAKE_NET_TRANSPORT_RELAY_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_ocapn.h"
        \\#include "pancake_transport_provider.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );
    try emitDoc(&b, gpa,
        \\The relay archive owns one shared runtime for keyed-relay and noise-relay.
        \\The relay moves opaque WebSocket bytes and proves no peer identity;
        \\noise-relay is sealed and authenticated by the Host above this provider.
        \\Install the returned package into libpancake_driver. Generic driver and
        \\binding code never names either profile's concrete implementation.
    );
    try b.appendSlice(gpa,
        \\
        \\typedef struct PancakeRelayRuntime PancakeRelayRuntime;
        \\
    );
    try b.print(gpa, "#define PANCAKE_RELAY_CONFIG_ABI_VERSION {d}u\n", .{c.PANCAKE_RELAY_CONFIG_ABI_VERSION});
    try b.print(gpa, "#define PANCAKE_RELAY_TRUST_SYSTEM {d}u\n", .{c.PANCAKE_RELAY_TRUST_SYSTEM});
    try b.print(gpa, "#define PANCAKE_RELAY_TRUST_COPIED_PEM {d}u\n\n", .{c.PANCAKE_RELAY_TRUST_COPIED_PEM});
    try E.emitStruct(&b, gpa, c.PancakeRelayConfig, "PancakeRelayConfig", &.{
        "Must equal PANCAKE_RELAY_CONFIG_ABI_VERSION.",
        "Must equal sizeof(PancakeRelayConfig).",
        "Borrowed dial URL copied by the constructor.",
        "Byte length of relay_url.",
        "Borrowed registration URL copied by the constructor; NULL/empty makes the package dial-only.",
        "Byte length of register_url.",
        "PANCAKE_RELAY_TRUST_* policy; system roots are the default.",
        "Borrowed PEM bytes copied during construction; only valid with COPIED_PEM.",
        "Byte length of trust_pem.",
    });
    try b.append(gpa, '\n');
    try E.emitStruct(&b, gpa, c.PancakeRelayTrustSummary, "PancakeRelayTrustSummary", &.{
        "Roots loaded into the native TLS engine.",
        "Platform roots the native TLS engine could not consume.",
        "Exact first engine code for a skipped root; zero when none were skipped.",
    });
    try b.append(gpa, '\n');

    try emitFn(&b, gpa, "pancake_relay_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated PANCAKE_RELAY_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "pancake_relay_runtime_new", &.{ "config", "out_runtime" }, "Create a relay runtime with the library allocator. Configuration bytes are\ncopied. Release the runtime after every driver holding its provider lease.");
    try emitFn(&b, gpa, "pancake_relay_runtime_new_in", &.{ "context", "config", "out_runtime" }, "Create a relay runtime whose owned state uses `context`.");
    try emitFn(&b, gpa, "pancake_relay_runtime_trust_summary", &.{ "runtime", "out_summary" }, "Copy the immutable trust-load result retained by this runtime.");
    try emitFn(&b, gpa, "pancake_relay_transport_provider", &.{ "runtime", "out_provider" }, "Fill `out_provider` with the shared keyed-relay/noise-relay multiplexed package.\nInstall it once with pancake_driver_add_provider; the driver retains its lease.");
    try emitFn(&b, gpa, "pancake_relay_runtime_release", &.{ "runtime", "out_error", "error_cap", "out_error_len" }, "Release the caller's runtime reference. The provider lease keeps the runtime\nalive until its driver is released. out_error/out_error_len optionally capture\nthis call's diagnostic before an off-thread runtime regains control: omit all\nthree diagnostic arguments, or provide out_error_len.");
    try emitFn(&b, gpa, "pancake_relay_last_error", &.{ "out_buf", "cap" }, "Copy this archive's calling-thread diagnostic, NUL-terminating when cap is\nnonzero. NULL or zero capacity queries the full length." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "pancake_relay_clear_last_error", &.{}, "Clear this archive's calling-thread diagnostic.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_NET_TRANSPORT_RELAY_H */
        \\
    );
    try E.assertAllEmitted(&b, "gen-header-net-transport-relay");
    return b.toOwnedSlice(gpa);
}
