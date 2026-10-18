const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const foundation = glowcap.foundation;
const dispatch = glowcap.ocapn.codec.dispatch;
const registry = glowcap.ocapn.codec.registry;

// A throwaway third codec, the kind a consumer would bring. It only needs the
// shape `dispatch` resolves against: an `Error` set and the entry points `dispatch` calls.
// This one reports every buffer as one over-large frame, so the test can prove
// dispatch routed to *it* and not a built-in.
const FixtureCodec = struct {
    pub const Error = error{Unused};

    pub fn decodeBodyInto(profile: model.CaptpVersion, frame: foundation.FrameView, slab: *model.view.ValueSlab, body: *model.view.Body) Error!void {
        _ = .{ profile, frame, slab, body };
        // Answer with the fixture's own typed error, so a test can prove the
        // body decode dispatched to *this* codec and not a built-in.
        return Error.Unused;
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
    const custom_id: model.CodecId = @fromBackingInt(@intCast(0xC0DE));
    const specs = [_]registry.Spec{
        .{ .id = custom_id, .frame_shape = .byte, .module = FixtureCodec },
    };

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
    const unclaimed: model.CodecId = @fromBackingInt(@intCast(0xFFFF));
    const frame = foundation.FrameView{ .bytes = "ignored", .shape = .byte };
    // Resolution short-circuits to the error before the frame is ever read.
    try std.testing.expectError(error.UnknownCodec, dispatch.decodeBody(unclaimed, frame));
}

test "registry membership distinguishes open wire ids from built implementations" {
    try std.testing.expect(registry.contains(.syrup));
    try std.testing.expect(registry.contains(.capnp));
    try std.testing.expect(!registry.contains(@fromBackingInt(@intCast(0xfffe))));
}

test "an unregistered codec frames as malformed and has no shape, never an unreachable" {
    // `CodecId` is non-exhaustive (open registry, ADR-0026), so an unregistered
    // id is a representable input. The prefix framer and shape lookup must fail
    // closed exactly like `decodeBody` does, not reach an `unreachable`.
    const unclaimed: model.CodecId = @fromBackingInt(@intCast(0xBEEF));
    try std.testing.expect(dispatch.frameShape(unclaimed) == null);
}
