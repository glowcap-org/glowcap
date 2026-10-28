//! Stored-resolution ownership against ADR-0070, with a live-session endpoint.
//! Agreement alone permits both peers to retain an object forever. This
//! program releases every owner and requires the import and its wire holds
//! to disappear before either session closes. It varies repeated mentions,
//! independent answer owners, and where the application's release occurs.
//! Omitting the whole resolution-hold release makes the deterministic run
//! fail its remaining-owner count and the fuzz corpus fail its zero-import
//! endpoint, even though local counters and peer wire counts still agree.
//! This target keeps both peers open and does not inject allocation failures.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const agreement = @import("oracle").agreement;
const program = @import("../../support/fuzz_program.zig");

fn settle(pair: *engine.pairing.Pair) !void {
    try program.settle(&pair.p1, &pair.p2);
    try std.testing.expect(pair.p1.sessionIsOpen() and pair.p2.sessionIsOpen());
    try agreement.check(&pair.p1, &pair.p2);
}
fn run(profile: model.CaptpVersion, codec: model.CodecId, owners: u8, mentions: u8, release_after: u8) !void {
    var pair = try engine.pairing.pairedNegotiated(std.testing.allocator, .{
        .captp_version = profile,
        .codec = codec,
        .features = model.FeatureSet.full(),
    });
    defer pair.deinit();
    const position = try pair.p1.exportNextObject();
    var values: [4]model.Argument = undefined;
    for (values[0..mentions]) |*value| value.* = .{ .reference = .{ .far = model.FarRef.object(position) } };

    // The first question introduces exactly one import. Every answer stores
    // its own hold on that same import, including repeated mentions in data.
    for (0..owners) |i| {
        try pair.p1.sendBorrowed(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = if (i == 0) &.{.{ .reference = .{ .near = model.NearRef.object(position) } }} else &.{},
            .answer = .from(i + 1),
        } });
    }
    try settle(&pair);
    for (0..owners) |i| {
        try pair.p2.sendBorrowed(.{ .resolve = .{
            .answer = .from(i + 1),
            .resolution = .{ .fulfill = .{ .list = values[0..mentions] } },
        } });
    }
    try settle(&pair);
    const imports = &pair.p2.session_state.imports;
    try std.testing.expectEqual(@as(u64, owners) * mentions, imports.rows.get(position).?.resolution_holds);

    for (0..@as(usize, owners) + 1) |i| {
        if (i == release_after) {
            try pair.p2.sendBorrowed(.{ .gc_export = .{ .positions = &.{position}, .deltas = &.{1} } });
            try settle(&pair);
        }
        if (i == owners) break;
        try pair.p1.sendBorrowed(.{ .gc_answer = .{ .positions = &.{i + 1} } });
        try settle(&pair);
        if (i + 1 < owners) {
            const row = imports.rows.get(position) orelse return error.ImportReleasedBeforeLastOwner;
            try std.testing.expectEqual(@as(u64, owners - i - 1) * mentions, row.resolution_holds);
        }
    }
    try std.testing.expectEqual(@as(u64, 0), imports.count(.from(position)));
    try std.testing.expectEqual(@as(u64, 0), pair.p1.session_state.exports.wireHeld(.from(position)));
    try std.testing.expectEqual(@as(u64, 0), imports.held_rows);
    try std.testing.expectEqual(@as(usize, 0), pair.p2.session_state.retained_sent_answer_bytes);
    try std.testing.expectEqual(@as(usize, 0), pair.p2.session_state.import_release_outbox.?.active_batches);
}

pub fn everyOrder() !void {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec| {
            for (0..3) |release_after| try run(profile, codec, 2, 2, @intCast(release_after));
        }
    }
}

pub fn one(_: void, smith: *std.testing.Smith) !void {
    const profile: model.CaptpVersion = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .v1_0 else .next;
    const codec: model.CodecId = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .syrup else .capnp;
    const owners = smith.valueRangeAtMost(u8, 1, 4);
    const mentions = smith.valueRangeAtMost(u8, 1, 4);
    try run(profile, codec, owners, mentions, smith.valueRangeAtMost(u8, 0, owners));
}
