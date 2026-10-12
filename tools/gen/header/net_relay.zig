//! Generates the relay provider archive's public C header from its Zig ABI.

const std = @import("std");
const c = @import("c_abi_net_transport_relay");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_net_transport_relay.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-relay";

const emitted_fn_names = [_][]const u8{
    "glowcap_relay_archive_fingerprint",
    "glowcap_relay_runtime_new",
    "glowcap_relay_runtime_new_in",
    "glowcap_relay_transport_provider",
    "glowcap_relay_runtime_release",
    "glowcap_relay_last_error",
    "glowcap_relay_clear_last_error",
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
    E.guardFns("c_abi_net_transport_relay", "glowcap_relay_");
}

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/relay/mod.zig by tools/gen/header/net_relay.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-relay`.
        \\   Function signatures and configuration layout are reflected from Zig. */
        \\#ifndef GLOWCAP_NET_TRANSPORT_RELAY_H
        \\#define GLOWCAP_NET_TRANSPORT_RELAY_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_ocapn.h"
        \\#include "glowcap_transport_provider.h"
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
        \\Install the returned package into libglowcap_driver. Generic driver and
        \\binding code never names either profile's concrete implementation.
    );
    try b.appendSlice(gpa,
        \\
        \\typedef struct GlowcapRelayRuntime GlowcapRelayRuntime;
        \\
    );
    try b.print(gpa, "#define GLOWCAP_RELAY_CONFIG_ABI_VERSION {d}u\n", .{c.GLOWCAP_RELAY_CONFIG_ABI_VERSION});
    try b.print(gpa, "#define GLOWCAP_RELAY_TRUST_SYSTEM {d}u\n", .{c.GLOWCAP_RELAY_TRUST_SYSTEM});
    try b.print(gpa, "#define GLOWCAP_RELAY_TRUST_COPIED_PEM {d}u\n", .{c.GLOWCAP_RELAY_TRUST_COPIED_PEM});
    try b.print(gpa, "#define GLOWCAP_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES {d}u\n\n", .{c.GLOWCAP_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES});
    try E.emitStruct(&b, gpa, c.GlowcapRelayConfig, "GlowcapRelayConfig", &.{
        "Must equal GLOWCAP_RELAY_CONFIG_ABI_VERSION.",
        "Must equal sizeof(GlowcapRelayConfig).",
        "Borrowed dial URL copied by the constructor.",
        "Byte length of relay_url.",
        "Borrowed registration URL copied by the constructor; NULL/empty makes the package dial-only.",
        "Byte length of register_url.",
        "GLOWCAP_RELAY_TRUST_* policy; system roots are the default.",
        "Borrowed PEM bytes copied during construction; only valid with COPIED_PEM.",
        "Byte length of trust_pem.",
        "Borrowed advertised dial route redirected to relay_url; both must reach the same registry. NULL/empty disables the alias. Other peer hints retain their routes.",
        "Byte length of relay_alias_url.",
    });
    try b.append(gpa, '\n');

    try emitFn(&b, gpa, "glowcap_relay_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_RELAY_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "glowcap_relay_runtime_new", &.{ "config", "out_runtime" }, "Create a relay runtime with the library allocator. Configuration bytes are\ncopied. Release the runtime after every driver holding its provider lease.");
    try emitFn(&b, gpa, "glowcap_relay_runtime_new_in", &.{ "context", "config", "out_runtime" }, "Create a relay runtime whose owned state uses `context`.");
    try emitFn(&b, gpa, "glowcap_relay_transport_provider", &.{ "runtime", "out_provider" }, "Fill `out_provider` with the shared keyed-relay/noise-relay multiplexed package.\nInstall it once with glowcap_driver_add_provider; the driver retains its lease.");
    try emitFn(&b, gpa, "glowcap_relay_runtime_release", &.{ "runtime", "out_error", "error_cap", "out_error_len" }, "Release the caller's runtime reference. The provider lease keeps the runtime\nalive until its driver is released. out_error/out_error_len optionally capture\nthis call's diagnostic before an off-thread runtime regains control: omit all\nthree diagnostic arguments, or provide out_error_len.");
    try emitFn(&b, gpa, "glowcap_relay_last_error", &.{ "out_buf", "cap" }, "Copy this archive's calling-thread diagnostic, NUL-terminating when cap is\nnonzero. NULL or zero capacity queries the full length." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_relay_clear_last_error", &.{}, "Clear this archive's calling-thread diagnostic.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_NET_TRANSPORT_RELAY_H */
        \\
    );
    try E.assertAllEmitted(&b, "gen-header-net-transport-relay");
    return b.toOwnedSlice(gpa);
}
