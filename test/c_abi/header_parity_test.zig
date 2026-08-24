//! Header parity, proves the generated `include/pancake_ocapn.h`, the byte-fed
//! driver header (`pancake_host.h`), and the two transport headers
//! (`pancake_net_transport_tcp.h`, `pancake_net_transport_inproc.h`) agree with
//! the Zig C ABI sources they mirror, so the two cannot silently drift. The
//! headers keep their prose (they are the C consumer's contract documents); this
//! test is the compiler-checked guarantee that their layouts and constants match
//! the source.
//!
//! The build translates the headers into the `c_headers` module; every assertion
//! compares a C declaration against the Zig `extern struct` / constant /
//! function it is supposed to equal. The shared vocabulary (frame/context types,
//! codes) is declared once in `pancake_ocapn.h`, which the transport headers
//! include, so struct and constant parity is checked against the `c_abi` (ocapn)
//! source; each transport module's functions are checked separately (ADR-0059).

const std = @import("std");
const pancake = @import("pancake");

const cabi = @import("c_abi");
const cabi_driver = @import("c_abi_host");
const cabi_loop = @import("c_abi_driver");
const cabi_tcp = @import("c_abi_net_transport_tcp");
const cabi_relay = @import("c_abi_net_transport_relay");
const cabi_inproc = @import("c_abi_net_transport_inproc");
const c = @import("c_headers");

/// Every field of the Zig struct sits at the same offset in the C struct, and
/// the structs are the same total size.
fn expectLayoutParity(comptime C: type, comptime Z: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
    try std.testing.expectEqual(@alignOf(C), @alignOf(Z));
    inline for (@typeInfo(Z).@"struct".field_names) |field_name| {
        try std.testing.expectEqual(@offsetOf(C, field_name), @offsetOf(Z, field_name));
    }
}

fn expectConst(c_value: anytype, zig_value: anytype) !void {
    try std.testing.expectEqual(@as(i64, @intCast(c_value)), @as(i64, @intCast(zig_value)));
}

fn isFunction(comptime value: anytype) bool {
    return @typeInfo(@TypeOf(value)) == .@"fn";
}

fn expectFunctionsDeclared(comptime Mod: type, comptime header: []const u8) void {
    // A `pancake_*` function added to the Zig source but forgotten in its header
    // (or removed from one side only) fails to compile here.
    @setEvalBranchQuota(40000);
    inline for (@typeInfo(Mod).@"struct".decl_names) |decl_name| {
        if (comptime std.mem.startsWith(u8, decl_name, "pancake_")) {
            if (comptime isFunction(@field(Mod, decl_name))) {
                if (!@hasDecl(c, decl_name)) {
                    @compileError("exported function missing from " ++ header ++ ": " ++ decl_name);
                }
            }
        }
    }
}

test "every exported C ABI function is declared in its header" {
    expectFunctionsDeclared(cabi, "pancake_ocapn.h");
    expectFunctionsDeclared(cabi_driver, "pancake_host.h");
    expectFunctionsDeclared(cabi_loop, "pancake_driver.h");
    expectFunctionsDeclared(cabi_tcp, "pancake_net_transport_tcp.h");
    expectFunctionsDeclared(cabi_relay, "pancake_net_transport_relay.h");
    expectFunctionsDeclared(cabi_inproc, "pancake_net_transport_inproc.h");
}

test "C header struct layouts match the Zig c_abi source" {
    try expectLayoutParity(c.PancakeFrame, cabi.PancakeFrame);
    try expectLayoutParity(c.PancakeManagedFrame, cabi.PancakeManagedFrame);
    try expectLayoutParity(c.PancakeAllocator, cabi.PancakeAllocator);
    try expectLayoutParity(c.PancakeReference, cabi.PancakeReference);
    try expectLayoutParity(c.PancakeArgument, cabi.PancakeArgument);
    try expectLayoutParity(c.PancakeDriverEvent, cabi_loop.PancakeDriverEvent);
    try expectLayoutParity(c.PancakeMultiplexedReadyEvent, cabi_loop.PancakeMultiplexedReadyEvent);
    try expectLayoutParity(c.PancakeMultiplexedTransport, cabi_loop.PancakeMultiplexedTransport);
    try expectLayoutParity(c.PancakeTransportProfile, cabi_loop.PancakeTransportProfile);
    try expectLayoutParity(c.PancakeStreamTransport, cabi_loop.PancakeStreamTransport);
    try expectLayoutParity(c.PancakeTransportProviderEntry, cabi_loop.PancakeTransportProviderEntry);
    try expectLayoutParity(c.PancakeTransportProvider, cabi_loop.PancakeTransportProvider);
    try expectLayoutParity(c.PancakeRelayConfig, cabi_relay.PancakeRelayConfig);
    try expectLayoutParity(c.PancakeRelayTrustSummary, cabi_relay.PancakeRelayTrustSummary);
}

test "the generated WebRTC header exposes its control and provider surface" {
    try std.testing.expect(@hasDecl(c, "pancake_webrtc_peer_authorize_remote"));
    try std.testing.expect(@hasDecl(c, "pancake_webrtc_transport_provider"));
    try std.testing.expect(@hasDecl(c, "PancakeWebrtcReadyEvent"));
    try std.testing.expect(@hasDecl(c, "PancakeWebrtcConfig"));
}

test "C header return codes match the Zig c_abi source" {
    try expectConst(c.PANCAKE_OK, cabi.PANCAKE_OK);
    try expectConst(c.PANCAKE_ERR_NULL_POINTER, cabi.PANCAKE_ERR_NULL_POINTER);
    try expectConst(c.PANCAKE_ERR_INVALID_ARGUMENT, cabi.PANCAKE_ERR_INVALID_ARGUMENT);
    try expectConst(c.PANCAKE_ERR_SESSION, cabi.PANCAKE_ERR_SESSION);
    try expectConst(c.PANCAKE_ERR_CODEC, cabi.PANCAKE_ERR_CODEC);
    try expectConst(c.PANCAKE_ERR_INTERNAL, cabi.PANCAKE_ERR_INTERNAL);
    try expectConst(c.PANCAKE_ERR_WOULD_BLOCK, cabi.PANCAKE_ERR_WOULD_BLOCK);
    try expectConst(c.PANCAKE_ERR_CLOSED, cabi.PANCAKE_ERR_CLOSED);
    try expectConst(c.PANCAKE_ERR_IO, cabi.PANCAKE_ERR_IO);
    try expectConst(c.PANCAKE_ERR_MALFORMED, cabi.PANCAKE_ERR_MALFORMED);
    try expectConst(c.PANCAKE_ERR_FRAME_TOO_LARGE, cabi.PANCAKE_ERR_FRAME_TOO_LARGE);
    try expectConst(c.PANCAKE_ERR_UNSUPPORTED_VALUE, cabi.PANCAKE_ERR_UNSUPPORTED_VALUE);
    try expectConst(c.PANCAKE_ERR_BROKEN, cabi.PANCAKE_ERR_BROKEN);
    try expectConst(c.PANCAKE_ERR_NOT_FOUND, cabi.PANCAKE_ERR_NOT_FOUND);
    try expectConst(c.PANCAKE_RELAY_CONFIG_ABI_VERSION, cabi_relay.PANCAKE_RELAY_CONFIG_ABI_VERSION);
    try expectConst(c.PANCAKE_RELAY_TRUST_SYSTEM, cabi_relay.PANCAKE_RELAY_TRUST_SYSTEM);
    try expectConst(c.PANCAKE_RELAY_TRUST_COPIED_PEM, cabi_relay.PANCAKE_RELAY_TRUST_COPIED_PEM);
}

test "C header discriminants match the Zig c_abi source" {
    try expectConst(c.PANCAKE_CODEC_UNKNOWN, cabi.PANCAKE_CODEC_UNKNOWN);
    try expectConst(c.PANCAKE_CODEC_SYRUP, cabi.PANCAKE_CODEC_SYRUP);
    try expectConst(c.PANCAKE_CODEC_CAPNP, cabi.PANCAKE_CODEC_CAPNP);
    try expectConst(c.PANCAKE_CODEC_UNKNOWN, 0);
    try expectConst(c.PANCAKE_CODEC_SYRUP, 1);
    try expectConst(c.PANCAKE_CODEC_CAPNP, 2);
    try std.testing.expect(c.PANCAKE_CODEC_SYRUP != c.PANCAKE_CODEC_UNKNOWN);
    try std.testing.expect(c.PANCAKE_CODEC_CAPNP != c.PANCAKE_CODEC_UNKNOWN);
    try std.testing.expectEqual(@as(?pancake.ocapn.model.CodecId, null), cabi.codecFromC(cabi.PANCAKE_CODEC_UNKNOWN));
    try std.testing.expectEqual(cabi.PANCAKE_CODEC_UNKNOWN, cabi.codecToC(@fromBackingInt(@intCast(42))));
    try expectConst(c.PANCAKE_FRAME_SHAPE_BYTE, cabi.PANCAKE_FRAME_SHAPE_BYTE);
    try expectConst(c.PANCAKE_FRAME_SHAPE_WORD, cabi.PANCAKE_FRAME_SHAPE_WORD);

    try expectConst(c.PANCAKE_ARG_INTEGER, cabi.PANCAKE_ARG_INTEGER);
    try expectConst(c.PANCAKE_ARG_FLOAT64, cabi.PANCAKE_ARG_FLOAT64);
    try expectConst(c.PANCAKE_ARG_BOOLEAN, cabi.PANCAKE_ARG_BOOLEAN);
    try expectConst(c.PANCAKE_ARG_BYTES, cabi.PANCAKE_ARG_BYTES);
    try expectConst(c.PANCAKE_ARG_STRING, cabi.PANCAKE_ARG_STRING);
    try expectConst(c.PANCAKE_ARG_SYMBOL, cabi.PANCAKE_ARG_SYMBOL);
    try expectConst(c.PANCAKE_ARG_VOID, cabi.PANCAKE_ARG_VOID);
    try expectConst(c.PANCAKE_ARG_REFERENCE, cabi.PANCAKE_ARG_REFERENCE);
    try expectConst(c.PANCAKE_ARG_LIST, cabi.PANCAKE_ARG_LIST);
    try expectConst(c.PANCAKE_ARG_SET, cabi.PANCAKE_ARG_SET);
    try expectConst(c.PANCAKE_ARG_TAGGED, cabi.PANCAKE_ARG_TAGGED);
    try expectConst(c.PANCAKE_ARG_KEYWORD, cabi.PANCAKE_ARG_KEYWORD);
    try expectConst(c.PANCAKE_ARG_BIG_INTEGER, cabi.PANCAKE_ARG_BIG_INTEGER);
    try expectConst(c.PANCAKE_ARG_STRUCT, cabi.PANCAKE_ARG_STRUCT);
    try expectConst(c.PANCAKE_ARG_ERROR, cabi.PANCAKE_ARG_ERROR);

    try expectConst(c.PANCAKE_RESOLUTION_FULFILL, cabi.PANCAKE_RESOLUTION_FULFILL);
    try expectConst(c.PANCAKE_RESOLUTION_BREAK, cabi.PANCAKE_RESOLUTION_BREAK);

    try expectConst(c.PANCAKE_VERSION_MAJOR, cabi.PANCAKE_VERSION_MAJOR);
    try expectConst(c.PANCAKE_VERSION_MINOR, cabi.PANCAKE_VERSION_MINOR);
    try expectConst(c.PANCAKE_VERSION_PATCH, cabi.PANCAKE_VERSION_PATCH);
}

test "C header resource limits match the Zig c_abi source" {
    try expectConst(c.PANCAKE_RAW_TRANSPORT_DEFAULT_FRAME_CAP, cabi.PANCAKE_RAW_TRANSPORT_DEFAULT_FRAME_CAP);
}

test "C feature mask names every model feature exactly once" {
    const full = pancake.ocapn.model.FeatureSet.full();
    const baseline = pancake.ocapn.model.FeatureSet.baseline();
    const minimum = pancake.ocapn.model.FeatureSet.minimum();
    try expectConst(c.PANCAKE_FEATURE_UNTAG, cabi.PANCAKE_FEATURE_UNTAG);
    try expectConst(c.PANCAKE_FEATURE_MULTI_LOCATION, cabi.PANCAKE_FEATURE_MULTI_LOCATION);
    try expectConst(c.PANCAKE_FEATURE_BASELINE, cabi.PANCAKE_FEATURE_BASELINE);
    try expectConst(c.PANCAKE_FEATURE_FULL, cabi.PANCAKE_FEATURE_FULL);
    try std.testing.expectEqual(cabi.PANCAKE_FEATURE_FULL, cabi.featureSetToC(full));
    try std.testing.expectEqual(cabi.PANCAKE_FEATURE_MINIMUM, cabi.featureSetToC(minimum));
    try std.testing.expectEqual(full, cabi.featureSetFromC(cabi.PANCAKE_FEATURE_FULL).?);
    try std.testing.expect(!baseline.untag);
    try std.testing.expect(!pancake.ocapn.model.Preference.default_offer.features.multi_location);
    try std.testing.expectEqual(cabi.PANCAKE_FEATURE_BASELINE, cabi.featureSetToC(baseline));
    try std.testing.expectEqual(minimum, cabi.featureSetFromC(cabi.PANCAKE_FEATURE_MINIMUM).?);
    const unused_feature_bits = ~cabi.PANCAKE_FEATURE_FULL;
    if (unused_feature_bits != 0) {
        const invalid_feature_bit = unused_feature_bits & (0 -% unused_feature_bits);
        try std.testing.expectEqual(@as(?pancake.ocapn.model.FeatureSet, null), cabi.featureSetFromC(cabi.PANCAKE_FEATURE_FULL | invalid_feature_bit));
    }
}
