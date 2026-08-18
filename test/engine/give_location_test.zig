//! The give's exporter-location form (ADR-0118): a `desc:handoff-give`
//! embeds the exporter's hello location in the form its recipient can use.
//! `handoff_gifter.dialableExporterLocation` strips exactly the `pancake/*`
//! profile entries and nothing else, so a Goblins recipient can dial the
//! result and match it against the bare hello a deferred onion exporter
//! answers strangers with, while routing hints a receiver needs stay.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const codec = pancake.ocapn.codec;

fn recordBytes(allocator: std.mem.Allocator, locator: model.PeerLocator) ![]u8 {
    return codec.signed.encodeLocatorRecord(allocator, locator);
}

test "a bare exporter location needs no stripping and allocates nothing" {
    const allocator = std.testing.allocator;
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = "a" ** 56,
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(raw);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try engine.handoff_gifter.dialableExporterLocation(allocator, raw),
    );
}

test "profile hints strip to the bare onion form" {
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = "pancake-next" } },
        .{ .name = model.transport.hint_codec, .value = .{ .string = "1" } },
    };
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = "a" ** 56,
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    const stripped = (try engine.handoff_gifter.dialableExporterLocation(allocator, raw)).?;
    defer allocator.free(stripped);
    const bare = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = "a" ** 56,
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(bare);
    try std.testing.expectEqualSlices(u8, bare, stripped);
}

test "routing hints a receiver needs survive the onion profile strip" {
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "192.0.2.7:9045" } },
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = "pancake-next" } },
    };
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = "a" ** 56,
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    const stripped = (try engine.handoff_gifter.dialableExporterLocation(allocator, raw)).?;
    defer allocator.free(stripped);
    const routing_only = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "192.0.2.7:9045" } },
    };
    const expected = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = "a" ** 56,
        .hints = .{ .entries = &routing_only },
    });
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, stripped);
}

test "a non-onion give keeps the exporter's hello verbatim, profile hints and all" {
    // On every transport but onion the exporter's hello is hinted toward
    // everyone alike, and the pinned Goblins keys withdrawal lookups by the
    // full node value — `zig build goblins-gift-hints` observes the verbatim
    // match live — so the give must not shed a byte.
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "192.0.2.7:9045" } },
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = "pancake-next" } },
    };
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.iroh,
        .designator = "b" ** 52,
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try engine.handoff_gifter.dialableExporterLocation(allocator, raw),
    );
}
