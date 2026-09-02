//! Stable C projection of codec, CapTP-version, and feature negotiation.

const std = @import("std");
const model = @import("model");
const last_error = @import("last_error.zig");

pub const GLOWCAP_CODEC_UNKNOWN: u32 = 0;
pub const GLOWCAP_CODEC_SYRUP: u32 = 1;
pub const GLOWCAP_CODEC_CAPNP: u32 = 2;

pub const GLOWCAP_CAPTP_V1_0: u32 = 0;
pub const GLOWCAP_CAPTP_NEXT: u32 = 1;

pub const GLOWCAP_FEATURE_PIPELINING: u32 = 1 << 0;
pub const GLOWCAP_FEATURE_HANDOFF: u32 = 1 << 1;
pub const GLOWCAP_FEATURE_WIRE_DELTA: u32 = 1 << 2;
pub const GLOWCAP_FEATURE_STURDYREF: u32 = 1 << 3;
pub const GLOWCAP_FEATURE_UNTAG: u32 = 1 << 4;
pub const GLOWCAP_FEATURE_MULTI_LOCATION: u32 = 1 << 5;
pub const GLOWCAP_FEATURE_MINIMUM: u32 = 0;

const FeatureSpec = struct {
    field: []const u8,
    bit: u32,
};

const feature_specs = [_]FeatureSpec{
    .{ .field = "pipelining", .bit = GLOWCAP_FEATURE_PIPELINING },
    .{ .field = "handoff", .bit = GLOWCAP_FEATURE_HANDOFF },
    .{ .field = "wire_delta", .bit = GLOWCAP_FEATURE_WIRE_DELTA },
    .{ .field = "sturdyref", .bit = GLOWCAP_FEATURE_STURDYREF },
    .{ .field = "untag", .bit = GLOWCAP_FEATURE_UNTAG },
    .{ .field = "multi_location", .bit = GLOWCAP_FEATURE_MULTI_LOCATION },
};

fn featureFullMask() u32 {
    var out: u32 = 0;
    inline for (feature_specs) |spec| out |= spec.bit;
    return out;
}

pub const GLOWCAP_FEATURE_FULL: u32 = featureFullMask();
pub const GLOWCAP_FEATURE_BASELINE: u32 = featureSetToC(model.FeatureSet.baseline());
pub const GLOWCAP_DEFAULT_CODEC: u32 = codecToC(model.Preference.default_offer.codec);
pub const GLOWCAP_DEFAULT_CAPTP_VERSION: u32 = captpVersionToC(model.Preference.default_offer.captp_version);
pub const GLOWCAP_DEFAULT_FEATURES: u32 = featureSetToC(model.Preference.default_offer.features);
pub const GLOWCAP_INTEROP_CODEC: u32 = codecToC(model.Preference.baseline.codec);
pub const GLOWCAP_INTEROP_CAPTP_VERSION: u32 = captpVersionToC(model.Preference.baseline.captp_version);
pub const GLOWCAP_NATIVE_CODEC: u32 = codecToC(model.Preference.native.codec);
pub const GLOWCAP_NATIVE_CAPTP_VERSION: u32 = captpVersionToC(model.Preference.native.captp_version);

comptime {
    const fields = @typeInfo(model.FeatureSet).@"struct".field_names;
    if (fields.len != feature_specs.len) {
        @compileError("model.FeatureSet changed; update the C ABI GLOWCAP_FEATURE_* table and binding mirrors");
    }
    var bits_seen: u32 = 0;
    for (feature_specs) |spec| {
        if (!@hasField(model.FeatureSet, spec.field)) {
            @compileError("GLOWCAP_FEATURE_* table names a field missing from model.FeatureSet: " ++ spec.field);
        }
        if (spec.bit == 0 or spec.bit & (spec.bit - 1) != 0) {
            @compileError("GLOWCAP_FEATURE_* bit must name exactly one nonzero bit: " ++ spec.field);
        }
        if (bits_seen & spec.bit != 0) {
            @compileError("GLOWCAP_FEATURE_* table reuses a bit: " ++ spec.field);
        }
        bits_seen |= spec.bit;
    }
    for (fields) |field_name| {
        var matches = 0;
        for (feature_specs) |spec| {
            if (std.mem.eql(u8, spec.field, field_name)) matches += 1;
        }
        if (matches != 1) {
            @compileError("model.FeatureSet field must have exactly one GLOWCAP_FEATURE_* bit: " ++ field_name);
        }
    }
}

pub fn captpVersionToC(version: model.CaptpVersion) u32 {
    return switch (version) {
        .v1_0 => GLOWCAP_CAPTP_V1_0,
        .next => GLOWCAP_CAPTP_NEXT,
    };
}

pub fn captpVersionFromC(version: u32) ?model.CaptpVersion {
    return switch (version) {
        GLOWCAP_CAPTP_V1_0 => .v1_0,
        GLOWCAP_CAPTP_NEXT => .next,
        else => null,
    };
}

pub fn codecToC(codec: model.CodecId) u32 {
    return switch (codec) {
        .syrup => GLOWCAP_CODEC_SYRUP,
        .capnp => GLOWCAP_CODEC_CAPNP,
        _ => GLOWCAP_CODEC_UNKNOWN,
    };
}

pub fn codecFromC(codec: u32) ?model.CodecId {
    return switch (codec) {
        GLOWCAP_CODEC_SYRUP => .syrup,
        GLOWCAP_CODEC_CAPNP => .capnp,
        else => null,
    };
}

/// Validate the framing pair shared by explicit blocking transport fronts.
pub fn framingOptionsFromC(codec: u32, max_frame_bytes: usize, operation: []const u8) error{ InvalidCodec, InvalidFrameCap }!model.CodecId {
    const codec_id = codecFromC(codec) orelse {
        last_error.set("{s}: codec must be a GLOWCAP_CODEC_* value", .{operation});
        return error.InvalidCodec;
    };
    if (max_frame_bytes == 0) {
        last_error.set("{s}: max_frame_bytes must not be zero", .{operation});
        return error.InvalidFrameCap;
    }
    return codec_id;
}

pub fn featureSetToC(features: model.FeatureSet) u32 {
    var out: u32 = 0;
    inline for (feature_specs) |spec| {
        if (@field(features, spec.field)) out |= spec.bit;
    }
    return out;
}

pub fn featureSetFromC(features: u32) ?model.FeatureSet {
    if (features & ~GLOWCAP_FEATURE_FULL != 0) return null;
    var out = model.FeatureSet.minimum();
    inline for (feature_specs) |spec| {
        @field(out, spec.field) = features & spec.bit != 0;
    }
    return out;
}
