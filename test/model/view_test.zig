//! Codec-neutral view round-trips: owned → `view.Body.fromOwned` → `toOwned`.
//!
//! These exercise the owned-fallback (slice) backings of `Args` /
//! `PositionList` / `PipelinePath` and the full materialization tree. The
//! testing allocator's leak detection guards `toOwned`'s fail-loud cleanup.
//! Codec-wire backings are exercised by the per-codec view tests.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const view = model.view;

/// Round-trip one owned message through the neutral view and assert the
/// materialized copy is structurally equal, with no leak.
fn expectRoundTrip(message: model.Message) !void {
    const allocator = std.testing.allocator;
    const body = view.Body.fromOwned(&message);
    try std.testing.expectEqualStrings(@tagName(message), @tagName(body));

    const owned = try body.toOwned(allocator);
    defer model.freeMessage(allocator, owned);

    try std.testing.expect(messagesEqual(message, owned));
}

fn messagesEqual(a: model.Message, b: model.Message) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .deliver => |x| blk: {
            const y = b.deliver;
            if (!model.referencesEqual(x.target, y.target)) break :blk false;
            if (x.answer != y.answer) break :blk false;
            if ((x.resolve_me_desc == null) != (y.resolve_me_desc == null)) break :blk false;
            if (x.resolve_me_desc) |xr| {
                if (!model.referencesEqual(xr, y.resolve_me_desc.?)) break :blk false;
            }
            break :blk argumentSlicesEqual(x.args, y.args);
        },
        .resolve => |x| resolutionsEqual(x.resolution, b.resolve.resolution) and x.answer == b.resolve.answer,
        .gc_export => |x| std.mem.eql(u64, x.positions, b.gc_export.positions) and std.mem.eql(u64, x.deltas, b.gc_export.deltas),
        .gc_answer => |x| std.mem.eql(u64, x.positions, b.gc_answer.positions),
        .abort => |x| x.kind == b.abort.kind and std.mem.eql(u8, x.message, b.abort.message),
        .listen => |x| model.referencesEqual(x.target, b.listen.target) and
            model.referencesEqual(x.listener, b.listen.listener) and x.wants_partial == b.listen.wants_partial,
        .get => |x| model.referencesEqual(x.receiver, b.get.receiver) and
            std.mem.eql(u8, x.field, b.get.field) and x.answer == b.get.answer,
        .index => |x| model.referencesEqual(x.receiver, b.index.receiver) and
            x.index == b.index.index and x.answer == b.index.answer,
        .start_session => |x| blk: {
            const y = b.start_session;
            break :blk x.captp_version == y.captp_version and
                std.mem.eql(u8, x.session_pubkey.bytes, y.session_pubkey.bytes) and
                model.peerLocatorsEqual(x.acceptable_location, y.acceptable_location) and
                std.mem.eql(u8, x.acceptable_location_sig.bytes, y.acceptable_location_sig.bytes);
        },
        .handoff => |x| handoffsEqual(x, b.handoff),
    };
}

fn argumentSlicesEqual(a: []const model.Argument, b: []const model.Argument) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!model.argumentsEqual(x, y)) return false;
    return true;
}

fn resolutionsEqual(a: model.Resolution, b: model.Resolution) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .fulfill => |x| model.argumentsEqual(x, b.fulfill),
        .break_ => |x| std.mem.eql(u8, x.message, b.break_.message),
    };
}

fn givesEqual(a: model.HandoffGive, b: model.HandoffGive) bool {
    return std.mem.eql(u8, a.recipient_key, b.recipient_key) and
        std.mem.eql(u8, a.exporter_location, b.exporter_location) and
        std.mem.eql(u8, a.gifter_exporter_session, b.gifter_exporter_session) and
        std.mem.eql(u8, a.gifter_side, b.gifter_side) and
        std.mem.eql(u8, a.gift_id, b.gift_id) and
        std.mem.eql(u8, a.signature, b.signature);
}

fn handoffsEqual(a: model.Handoff, b: model.Handoff) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .give => |x| givesEqual(x, b.give),
        .receive => |x| givesEqual(x.signed_give, b.receive.signed_give) and
            x.handoff_count == b.receive.handoff_count and
            std.mem.eql(u8, x.receiving_session, b.receive.receiving_session) and
            std.mem.eql(u8, x.receiving_side, b.receive.receiving_side) and
            std.mem.eql(u8, x.signature, b.receive.signature),
    };
}

test "deliver with nested args, promise path target, and resolve_me_desc round-trips" {
    const inner = [_]model.Argument{ .{ .integer = 7 }, .{ .boolean = true } };
    const call_args = [_]model.Argument{.{ .string = "hi" }};
    const ops = [_]model.PipelineOp{ .{ .field = "field0" }, .{ .call = &call_args } };
    const args = [_]model.Argument{
        .{ .bytes = "raw" },
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.object(3) } },
        .{ .list = &inner },
        .{ .tagged = .{ .tag = "rec", .value = &inner } },
    };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_id = 9, .path = .{ .ops = &ops } } },
        .args = &args,
        .answer = 11,
        .resolve_me_desc = .{ .near = model.NearRef.promise(4) },
    } });
}

test "resolve fulfill with a reference payload round-trips" {
    try expectRoundTrip(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(5) } } },
    } });
}

test "resolve break round-trips" {
    try expectRoundTrip(.{ .resolve = .{
        .answer = 1,
        .resolution = .{ .break_ = .{ .message = "boom" } },
    } });
}

test "gc_export and gc_answer position lists round-trip" {
    const positions = [_]u64{ 5, 6, 7 };
    const deltas = [_]u64{ 1, 1, 2 };
    try expectRoundTrip(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
    try expectRoundTrip(.{ .gc_answer = .{ .positions = &positions } });
}

test "abort round-trips with typed kind and message" {
    try expectRoundTrip(.{ .abort = .{ .kind = .protocol_error, .message = "bye" } });
}

test "listen, get, index round-trip" {
    try expectRoundTrip(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(7) },
        .listener = .{ .near = model.NearRef.object(9) },
        .wants_partial = true,
    } });
    try expectRoundTrip(.{ .get = .{ .receiver = .{ .far = model.FarRef.object(2) }, .field = "name", .answer = 3 } });
    try expectRoundTrip(.{ .index = .{ .receiver = .{ .far = model.FarRef.object(2) }, .index = 5, .answer = 4 } });
}

test "start_session round-trips" {
    try expectRoundTrip(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = "pubkey-bytes" },
        .acceptable_location = .{ .transport = "memory", .designator = "host" },
        .acceptable_location_sig = .{ .bytes = "sig-bytes" },
    } });
}

test "handoff give and receive round-trip" {
    const give = model.HandoffGive{
        .recipient_key = "rk",
        .exporter_location = "el",
        .gifter_exporter_session = "ges",
        .gifter_side = "gs",
        .gift_id = "gid",
        .signature = "sig",
    };
    try expectRoundTrip(.{ .handoff = .{ .give = give } });
    try expectRoundTrip(.{ .handoff = .{ .receive = .{
        .receiving_session = "rs",
        .receiving_side = "rside",
        .handoff_count = 2,
        .signed_give = give,
        .signature = "rsig",
    } } });
}

test "Args slice backing reports len and projects each element" {
    const args = [_]model.Argument{ .{ .integer = 1 }, .{ .symbol = "x" } };
    const a = view.Args.fromOwnedSlice(&args);
    try std.testing.expectEqual(@as(usize, 2), try a.len());
    try std.testing.expectEqual(@as(i64, 1), (try a.at(0)).integer);
    try std.testing.expectEqualStrings("x", (try a.at(1)).symbol);
}
