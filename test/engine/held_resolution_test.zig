//! Release stored resolution holds while both peers remain open. Assert
//! agreement at each step and keep checking until every retain is gone.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const agreement = @import("scenarios").agreement;
const program = @import("../support/fuzz_program.zig");

fn settle(pair: *engine.pairing.Pair) !void {
    try program.settle(&pair.p1, &pair.p2);
    try std.testing.expect(pair.p1.sessionIsOpen() and pair.p2.sessionIsOpen());
    try agreement.check(&pair.p1, &pair.p2);
}
fn run(profile: model.CaptpVersion, codec: model.CodecId, owners: usize, mentions: usize, release_after: usize) !void {
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

    for (0..owners + 1) |i| {
        if (i == release_after) {
            try pair.p2.sendBorrowed(.{ .gc_export = .{ .positions = &.{position}, .deltas = &.{1} } });
            try settle(&pair);
            if (i < owners) {
                try std.testing.expectEqual(@as(u64, 1), imports.rows.get(position).?.held_back);
                try std.testing.expectEqual(@as(u64, 1), pair.p1.session_state.exports.wireHeld(.from(position)));
            }
        }
        if (i == owners) break;
        try pair.p1.sendBorrowed(.{ .gc_answer = .{ .positions = &.{i + 1} } });
        try settle(&pair);
        if (i + 1 < owners) {
            const row = imports.rows.get(position) orelse return error.ImportReleasedBeforeLastOwner;
            try std.testing.expectEqual(@as(u64, owners - i - 1) * mentions, row.resolution_holds);
        } else if (release_after < owners) {
            try std.testing.expectEqual(@as(u64, 0), pair.p1.session_state.exports.wireHeld(.from(position)));
        }
    }
    try std.testing.expectEqual(@as(u64, 0), imports.count(.from(position)));
    try std.testing.expectEqual(@as(u64, 0), pair.p1.session_state.exports.wireHeld(.from(position)));
    try std.testing.expectEqual(@as(u64, 0), imports.held_rows);
    try std.testing.expectEqual(@as(usize, 0), pair.p2.session_state.retained_sent_answer_bytes);
    try std.testing.expectEqual(@as(usize, 0), pair.p2.session_state.import_release_outbox.?.active_batches);
}

test "stored resolutions pay back the last wire retain for every bounded schedule" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
            for (1..5) |owners| {
                for (1..5) |mentions| {
                    for (0..owners + 1) |release_after| {
                        try run(profile, codec, owners, mentions, release_after);
                    }
                }
            }
        }
    }
}
