const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const foundation = pancake.foundation;
const dispatch = pancake.ocapn.codec.dispatch;
const registry = pancake.ocapn.codec.registry;

// A throwaway third codec, the kind a consumer would bring. It only needs the
// shape `dispatch` resolves against: an `Error` set and the three entry points.
// This one reports every buffer as one over-large frame, so the test can prove
// dispatch routed to *it* and not a built-in.
const FixtureCodec = struct {
    pub const Error = error{Unused};

    pub fn decodeBody(frame: foundation.FrameView) Error!model.view.Body {
        _ = frame;
        // Answer with the fixture's own typed error, so a test can prove the
        // body decode dispatched to *this* codec and not a built-in.
        return Error.Unused;
    }

    pub fn decodePrefix(bytes: []const u8, max_frame_bytes: usize) dispatch.Prefix {
        _ = bytes;
        _ = max_frame_bytes;
        return .too_large;
    }

    pub fn encodeMessageForProfile(
        allocator: std.mem.Allocator,
        profile: model.CaptpVersion,
        message: model.Message,
    ) Error!foundation.Frame {
        _ = allocator;
        _ = profile;
        _ = message;
        unreachable; // not exercised by this test
    }
};

test "a consumer codec registered past the built-ins routes through dispatch" {
    const custom_id: model.CodecId = @enumFromInt(0xC0DE);
    const specs = [_]registry.Spec{
        .{ .id = custom_id, .frame_shape = .byte, .module = FixtureCodec },
    };

    // The custom id resolves to the fixture's decodePrefix (always `.too_large`),
    // proving a third codec dispatches with zero changes to the built-in set.
    const verdict = dispatch.decodePrefixWith(&specs, custom_id, "anything at all", 4096);
    try std.testing.expect(verdict == .too_large);

    // The body decode routes through the same injected registry: the fixture
    // answers with its own typed error, not a built-in's.
    const frame = foundation.FrameView{ .bytes = "ignored", .shape = .byte };
    try std.testing.expectError(error.Unused, dispatch.decodeBodyWith(&specs, custom_id, frame));
}

test "the built-in registry carries exactly syrup and capnp, both addressable" {
    var saw_syrup = false;
    var saw_capnp = false;
    inline for (registry.builtin) |spec| {
        if (spec.id == .syrup) saw_syrup = true;
        if (spec.id == .capnp) saw_capnp = true;
    }
    try std.testing.expect(saw_syrup and saw_capnp);
    try std.testing.expectEqual(@as(usize, 2), registry.builtin.len);
}

test "an id no registered codec claims fails closed with UnknownCodec" {
    const unclaimed: model.CodecId = @enumFromInt(0xFFFF);
    const frame = foundation.FrameView{ .bytes = "ignored", .shape = .byte };
    // Resolution short-circuits to the error before the frame is ever read.
    try std.testing.expectError(error.UnknownCodec, dispatch.decodeBody(unclaimed, frame));
}

test "an unregistered codec frames as malformed and has no shape, never an unreachable" {
    // `CodecId` is non-exhaustive (open registry, ADR-0026), so an unregistered
    // id is a representable input. The prefix framer and shape lookup must fail
    // closed exactly like `decodeBody` does, not reach an `unreachable`.
    const unclaimed: model.CodecId = @enumFromInt(0xBEEF);
    try std.testing.expect(dispatch.decodePrefix(unclaimed, "anything at all", 4096) == .malformed);
    try std.testing.expect(dispatch.frameShape(unclaimed) == null);
}
