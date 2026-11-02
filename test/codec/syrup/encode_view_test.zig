//! The Syrup encoder over a borrowed body: every message fixture in the
//! corpus decodes to views that re-encode to the bytes its owned copy
//! produces, a signed give and receive re-encode from their decoded views
//! byte for byte, and a decoded sturdyref keeps its hints.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");
const view_round_trip = @import("../../support/view_round_trip.zig");
const handoff_fixtures = @import("../../support/handoff_fixtures.zig");

/// The borrowed walk and the owned walk are one encoder with two sources, so
/// they agree on every fixture: the same bytes, or the same refusal (a
/// decoded `Far` target is a `Near` target to the sender, which the encoder
/// refuses on either source).
fn expectViewMatchesOwned(profile: model.CaptpVersion, bytes: []const u8) !bool {
    const allocator = std.testing.allocator;
    const body = try syrup.decodeBodyForProfile(profile, .{ .bytes = bytes, .shape = .byte });
    const owned = try body.toOwned(allocator);
    defer model.freeMessage(allocator, owned);

    var via_owned = syrup.encodeMessageForProfile(allocator, profile, owned) catch |err| {
        try std.testing.expectError(err, syrup.encodeBodyForProfile(allocator, profile, &body, null));
        return false;
    };
    defer via_owned.deinit();
    var via_view = try syrup.encodeBodyForProfile(allocator, profile, &body, null);
    defer via_view.deinit();
    try std.testing.expectEqualSlices(u8, via_owned.bytes(), via_view.bytes());
    return true;
}

test "borrowed body re-encodes every corpus message as its owned copy does" {
    for (protocol_oracle.corpus) |fixture| {
        if (!std.mem.startsWith(u8, fixture.name, "op_")) continue;
        _ = try expectViewMatchesOwned(.v1_0, fixture.bytes());
    }
    // A message with no reference reads the same from either side, so these
    // fixtures encode on both sources and the walk above was not all refusals.
    for ([_][]const u8{
        "op_abort.bin",
        "op_abort_typed.bin",
        "op_gc_exports.bin",
        "op_gc_answers.bin",
        "op_resolve_break.bin",
        "op_start_session_v1_0.bin",
    }) |name| {
        const fixture = protocol_oracle.fixtureByName(name).?;
        try std.testing.expect(try expectViewMatchesOwned(.v1_0, fixture.bytes()));
    }
}

test "decoded signed give and receive re-encode from their views byte for byte" {
    var give: model.Handoff = .{ .give = handoff_fixtures.give() };
    try view_round_trip.expectArgumentViewRoundTrip(syrup, .{ .handoff = &give });
    var receive: model.Handoff = .{ .receive = handoff_fixtures.receive() };
    try view_round_trip.expectArgumentViewRoundTrip(syrup, .{ .handoff = &receive });
}

test "decoded sturdyref with hints re-encodes from its view byte for byte" {
    const hints = [_]model.HintEntry{
        .{ .name = "relay", .value = .{ .string = "relay.example" } },
        .{ .name = "ttl", .value = .{ .integer = 30 } },
    };
    const sturdy: model.SturdyRef = .{
        .peer = .{ .transport = "tcp", .designator = "exporter.example", .hints = .{ .entries = &hints } },
        .swissnum = "swiss-number",
    };
    try view_round_trip.expectArgumentViewRoundTrip(syrup, .{ .reference = .{ .sturdy = &sturdy } });
}

test "decoded set and struct re-encode from their views in canonical order" {
    const members = [_]model.Argument{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    try view_round_trip.expectArgumentViewRoundTrip(syrup, .{ .set = &members });
    const entries = [_]model.StructEntry{
        .{ .key = "b", .value = .{ .integer = 2 } },
        .{ .key = "a", .value = .{ .string = "one" } },
    };
    try view_round_trip.expectArgumentViewRoundTrip(syrup, .{ .@"struct" = &entries });
}
