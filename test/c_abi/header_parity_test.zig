//! Header parity, proves the generated `include/glowcap_ocapn.h`, the byte-fed
//! driver header (`glowcap_host.h`), and the two transport headers
//! (`glowcap_net_transport_tcp.h`, `glowcap_net_transport_inproc.h`) agree with
//! the Zig C ABI sources they mirror, so the two cannot silently drift. The
//! headers keep their prose (they are the C consumer's contract documents). This
//! test is the compiler-checked guarantee that their layouts and constants match
//! the source.
//!
//! The build translates the headers into the `c_headers` module. Every assertion
//! compares a C declaration against the Zig `extern struct` / constant /
//! function it is supposed to equal. The shared vocabulary (frame/context types,
//! codes) is declared once in `glowcap_ocapn.h`, which the transport headers
//! include, so struct and constant parity is checked against the `c_abi` (ocapn)
//! source. Each transport module's functions are checked separately (ADR-0059).

const std = @import("std");
const glowcap = @import("glowcap");

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
    // A `glowcap_*` function added to the Zig source but forgotten in its header
    // (or removed from one side only) fails to compile here.
    @setEvalBranchQuota(40000);
    inline for (@typeInfo(Mod).@"struct".decl_names) |decl_name| {
        if (comptime std.mem.startsWith(u8, decl_name, "glowcap_")) {
            if (comptime isFunction(@field(Mod, decl_name))) {
                if (!@hasDecl(c, decl_name)) {
                    @compileError("exported function missing from " ++ header ++ ": " ++ decl_name);
                }
            }
        }
    }
}

test "every exported C ABI function is declared in its header" {
    expectFunctionsDeclared(cabi, "glowcap_ocapn.h");
    expectFunctionsDeclared(cabi_driver, "glowcap_host.h");
    expectFunctionsDeclared(cabi_loop, "glowcap_driver.h");
    expectFunctionsDeclared(cabi_tcp, "glowcap_net_transport_tcp.h");
    expectFunctionsDeclared(cabi_relay, "glowcap_net_transport_relay.h");
    expectFunctionsDeclared(cabi_inproc, "glowcap_net_transport_inproc.h");
}

test "C header struct layouts match the Zig c_abi source" {
    try expectLayoutParity(c.GlowcapFrame, cabi.GlowcapFrame);
    try expectLayoutParity(c.GlowcapManagedFrame, cabi.GlowcapManagedFrame);
    try expectLayoutParity(c.GlowcapAllocator, cabi.GlowcapAllocator);
    try expectLayoutParity(c.GlowcapReference, cabi.GlowcapReference);
    try expectLayoutParity(c.GlowcapArgument, cabi.GlowcapArgument);
    try expectLayoutParity(c.GlowcapDriverEvent, cabi_loop.GlowcapDriverEvent);
    try expectLayoutParity(c.GlowcapMultiplexedReadyEvent, cabi_loop.GlowcapMultiplexedReadyEvent);
    try expectLayoutParity(c.GlowcapMultiplexedTransport, cabi_loop.GlowcapMultiplexedTransport);
    try expectLayoutParity(c.GlowcapTransportProfile, cabi_loop.GlowcapTransportProfile);
    try expectLayoutParity(c.GlowcapStreamTransport, cabi_loop.GlowcapStreamTransport);
    try expectLayoutParity(c.GlowcapTransportProviderEntry, cabi_loop.GlowcapTransportProviderEntry);
    try expectLayoutParity(c.GlowcapTransportProvider, cabi_loop.GlowcapTransportProvider);
    try expectLayoutParity(c.GlowcapRelayConfig, cabi_relay.GlowcapRelayConfig);
}

test "the generated WebRTC header exposes its control and provider surface" {
    try std.testing.expect(@hasDecl(c, "glowcap_webrtc_peer_authorize_remote"));
    try std.testing.expect(@hasDecl(c, "glowcap_webrtc_transport_provider"));
    try std.testing.expect(@hasDecl(c, "GlowcapWebrtcReadyEvent"));
    try std.testing.expect(@hasDecl(c, "GlowcapWebrtcConfig"));
}

test "C header return codes match the Zig c_abi source" {
    try expectConst(c.GLOWCAP_OK, cabi.GLOWCAP_OK);
    try expectConst(c.GLOWCAP_ERR_NULL_POINTER, cabi.GLOWCAP_ERR_NULL_POINTER);
    try expectConst(c.GLOWCAP_ERR_INVALID_ARGUMENT, cabi.GLOWCAP_ERR_INVALID_ARGUMENT);
    try expectConst(c.GLOWCAP_ERR_SESSION, cabi.GLOWCAP_ERR_SESSION);
    try expectConst(c.GLOWCAP_ERR_CODEC, cabi.GLOWCAP_ERR_CODEC);
    try expectConst(c.GLOWCAP_ERR_INTERNAL, cabi.GLOWCAP_ERR_INTERNAL);
    try expectConst(c.GLOWCAP_ERR_WOULD_BLOCK, cabi.GLOWCAP_ERR_WOULD_BLOCK);
    try expectConst(c.GLOWCAP_ERR_CLOSED, cabi.GLOWCAP_ERR_CLOSED);
    try expectConst(c.GLOWCAP_ERR_IO, cabi.GLOWCAP_ERR_IO);
    try expectConst(c.GLOWCAP_ERR_MALFORMED, cabi.GLOWCAP_ERR_MALFORMED);
    try expectConst(c.GLOWCAP_ERR_FRAME_TOO_LARGE, cabi.GLOWCAP_ERR_FRAME_TOO_LARGE);
    try expectConst(c.GLOWCAP_ERR_UNSUPPORTED_VALUE, cabi.GLOWCAP_ERR_UNSUPPORTED_VALUE);
    try expectConst(c.GLOWCAP_ERR_BROKEN, cabi.GLOWCAP_ERR_BROKEN);
    try expectConst(c.GLOWCAP_ERR_NOT_FOUND, cabi.GLOWCAP_ERR_NOT_FOUND);
    try expectConst(c.GLOWCAP_RELAY_CONFIG_ABI_VERSION, cabi_relay.GLOWCAP_RELAY_CONFIG_ABI_VERSION);
    try expectConst(c.GLOWCAP_RELAY_TRUST_SYSTEM, cabi_relay.GLOWCAP_RELAY_TRUST_SYSTEM);
    try expectConst(c.GLOWCAP_RELAY_TRUST_COPIED_PEM, cabi_relay.GLOWCAP_RELAY_TRUST_COPIED_PEM);
}

test "C header discriminants match the Zig c_abi source" {
    try expectConst(c.GLOWCAP_CODEC_UNKNOWN, cabi.GLOWCAP_CODEC_UNKNOWN);
    try expectConst(c.GLOWCAP_CODEC_SYRUP, cabi.GLOWCAP_CODEC_SYRUP);
    try expectConst(c.GLOWCAP_CODEC_CAPNP, cabi.GLOWCAP_CODEC_CAPNP);
    try expectConst(c.GLOWCAP_CODEC_UNKNOWN, 0);
    try expectConst(c.GLOWCAP_CODEC_SYRUP, 1);
    try expectConst(c.GLOWCAP_CODEC_CAPNP, 2);
    try std.testing.expect(c.GLOWCAP_CODEC_SYRUP != c.GLOWCAP_CODEC_UNKNOWN);
    try std.testing.expect(c.GLOWCAP_CODEC_CAPNP != c.GLOWCAP_CODEC_UNKNOWN);
    try std.testing.expectEqual(@as(?glowcap.ocapn.model.CodecId, null), cabi.codecFromC(cabi.GLOWCAP_CODEC_UNKNOWN));
    try std.testing.expectEqual(cabi.GLOWCAP_CODEC_UNKNOWN, cabi.codecToC(@fromBackingInt(@intCast(42))));
    try expectConst(c.GLOWCAP_FRAME_SHAPE_BYTE, cabi.GLOWCAP_FRAME_SHAPE_BYTE);
    try expectConst(c.GLOWCAP_FRAME_SHAPE_WORD, cabi.GLOWCAP_FRAME_SHAPE_WORD);

    try expectConst(c.GLOWCAP_ARG_INTEGER, cabi.GLOWCAP_ARG_INTEGER);
    try expectConst(c.GLOWCAP_ARG_FLOAT64, cabi.GLOWCAP_ARG_FLOAT64);
    try expectConst(c.GLOWCAP_ARG_BOOLEAN, cabi.GLOWCAP_ARG_BOOLEAN);
    try expectConst(c.GLOWCAP_ARG_BYTES, cabi.GLOWCAP_ARG_BYTES);
    try expectConst(c.GLOWCAP_ARG_STRING, cabi.GLOWCAP_ARG_STRING);
    try expectConst(c.GLOWCAP_ARG_SYMBOL, cabi.GLOWCAP_ARG_SYMBOL);
    try expectConst(c.GLOWCAP_ARG_VOID, cabi.GLOWCAP_ARG_VOID);
    try expectConst(c.GLOWCAP_ARG_REFERENCE, cabi.GLOWCAP_ARG_REFERENCE);
    try expectConst(c.GLOWCAP_ARG_LIST, cabi.GLOWCAP_ARG_LIST);
    try expectConst(c.GLOWCAP_ARG_SET, cabi.GLOWCAP_ARG_SET);
    try expectConst(c.GLOWCAP_ARG_TAGGED, cabi.GLOWCAP_ARG_TAGGED);
    try expectConst(c.GLOWCAP_ARG_KEYWORD, cabi.GLOWCAP_ARG_KEYWORD);
    try expectConst(c.GLOWCAP_ARG_BIG_INTEGER, cabi.GLOWCAP_ARG_BIG_INTEGER);
    try expectConst(c.GLOWCAP_ARG_STRUCT, cabi.GLOWCAP_ARG_STRUCT);
    try expectConst(c.GLOWCAP_ARG_ERROR, cabi.GLOWCAP_ARG_ERROR);

    try expectConst(c.GLOWCAP_RESOLUTION_FULFILL, cabi.GLOWCAP_RESOLUTION_FULFILL);
    try expectConst(c.GLOWCAP_RESOLUTION_BREAK, cabi.GLOWCAP_RESOLUTION_BREAK);

    try expectConst(c.GLOWCAP_VERSION_MAJOR, cabi.GLOWCAP_VERSION_MAJOR);
    try expectConst(c.GLOWCAP_VERSION_MINOR, cabi.GLOWCAP_VERSION_MINOR);
    try expectConst(c.GLOWCAP_VERSION_PATCH, cabi.GLOWCAP_VERSION_PATCH);
}

test "C header resource limits match the Zig c_abi source" {
    try expectConst(c.GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP, cabi.GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP);
}

test "C feature mask names every model feature exactly once" {
    const full = glowcap.ocapn.model.FeatureSet.full();
    const baseline = glowcap.ocapn.model.FeatureSet.baseline();
    const minimum = glowcap.ocapn.model.FeatureSet.minimum();
    try expectConst(c.GLOWCAP_FEATURE_UNTAG, cabi.GLOWCAP_FEATURE_UNTAG);
    try expectConst(c.GLOWCAP_FEATURE_MULTI_LOCATION, cabi.GLOWCAP_FEATURE_MULTI_LOCATION);
    try expectConst(c.GLOWCAP_FEATURE_BASELINE, cabi.GLOWCAP_FEATURE_BASELINE);
    try expectConst(c.GLOWCAP_FEATURE_FULL, cabi.GLOWCAP_FEATURE_FULL);
    try std.testing.expectEqual(cabi.GLOWCAP_FEATURE_FULL, cabi.featureSetToC(full));
    try std.testing.expectEqual(cabi.GLOWCAP_FEATURE_MINIMUM, cabi.featureSetToC(minimum));
    try std.testing.expectEqual(full, cabi.featureSetFromC(cabi.GLOWCAP_FEATURE_FULL).?);
    try std.testing.expect(!baseline.untag);
    try std.testing.expect(!glowcap.ocapn.model.Preference.default_offer.features.multi_location);
    try std.testing.expectEqual(cabi.GLOWCAP_FEATURE_BASELINE, cabi.featureSetToC(baseline));
    try std.testing.expectEqual(minimum, cabi.featureSetFromC(cabi.GLOWCAP_FEATURE_MINIMUM).?);
    const unused_feature_bits = ~cabi.GLOWCAP_FEATURE_FULL;
    if (unused_feature_bits != 0) {
        const invalid_feature_bit = unused_feature_bits & (0 -% unused_feature_bits);
        try std.testing.expectEqual(@as(?glowcap.ocapn.model.FeatureSet, null), cabi.featureSetFromC(cabi.GLOWCAP_FEATURE_FULL | invalid_feature_bit));
    }
}
