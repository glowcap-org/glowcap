//! The word-run form of a Cap'n Proto list (ADR-0243): a non-empty list of
//! integers crosses as one `List(Int64)` run that the view reads in place and
//! a host reads as a typed slice, while every other list keeps its composite
//! form. The malformed arms hold the run to the segment, refuse an empty run,
//! and refuse a run anywhere but under a list.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;
const wire = capnp.wire;
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;

test "a list of integers rides as a word run the view reads in place" {
    const allocator = std.testing.allocator;
    const samples = [_]model.Argument{ .{ .integer = 100 }, .{ .integer = -200 }, .{ .integer = 1 << 40 } };
    const mixed = [_]model.Argument{ .{ .integer = 1 }, .{ .string = "x" } };
    const args = [_]model.Argument{
        .{ .symbol = "report" },
        .{ .list = &samples },
        .{ .set = &samples },
        .{ .list = &mixed },
        .{ .list = &.{} },
        .{ .tagged = .{ .tag = "t", .value = &samples } },
    };
    const original = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } };
    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    var views: [16]model.view.Argument = undefined;
    var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    var body: model.view.Body = undefined;
    try capnp.decodeBodyInto(.v1_0, frame.view(), &slab, &body);
    const run = (try body.deliver.args.at(1)).list;
    try std.testing.expect(run.backingViews() == null);
    try std.testing.expectEqualSlices(i64, &.{ 100, -200, 1 << 40 }, run.typedRun().?);
    try std.testing.expectEqual(@as(i64, -200), (try run.at(1)).integer);
    // Only a non-empty list of integers takes the run form: a set, a mixed
    // list, the empty list, and a tagged value keep their composite lists.
    try std.testing.expect((try body.deliver.args.at(2)).set.wordRun() == null);
    try std.testing.expect((try body.deliver.args.at(3)).list.wordRun() == null);
    try std.testing.expect((try body.deliver.args.at(4)).list.wordRun() == null);
    try std.testing.expect((try body.deliver.args.at(5)).tagged.value.wordRun() == null);

    // The slab walk and the lazy walk materialize the same message, and the
    // run comes back as the integers it carried. (The set's members come
    // back in canonical order, so the whole message is not compared to the
    // original.)
    const owned = try body.toOwned(allocator);
    defer model.freeMessage(allocator, owned);
    const lazy = try capnp.decodeBody(frame.view());
    const again = try lazy.toOwned(allocator);
    defer model.freeMessage(allocator, again);
    try std.testing.expect(messagesEqual(owned, again));
    try std.testing.expectEqual(@as(usize, 3), owned.deliver.args[1].list.len);
    try std.testing.expectEqual(@as(i64, -200), owned.deliver.args[1].list[1].integer);
    try std.testing.expectEqual(@as(i64, 1 << 40), owned.deliver.args[1].list[2].integer);
    try std.testing.expectEqualStrings("x", owned.deliver.args[3].list[1].string);
    try std.testing.expectEqual(@as(usize, 0), owned.deliver.args[4].list.len);
}

/// A deliver carrying one `list` argument of two integers, as the encoder
/// writes it: the list's pointer names a run of eight-byte words.
fn integerRunFrame(allocator: std.mem.Allocator) !glowcap.foundation.Frame {
    const samples = [_]model.Argument{ .{ .integer = 100 }, .{ .integer = -200 } };
    const args = [_]model.Argument{.{ .list = &samples }};
    return capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } });
}

/// The byte offset of the one word in `bytes` that `accept` picks.
fn findWord(bytes: []const u8, accept: *const fn (u64) bool) !usize {
    var found: ?usize = null;
    var offset: usize = 0;
    while (offset + wire.word_bytes <= bytes.len) : (offset += wire.word_bytes) {
        if (accept(std.mem.readInt(u64, bytes[offset..][0..wire.word_bytes], .little))) {
            if (found != null) return error.TestUnexpectedResult;
            found = offset;
        }
    }
    return found orelse error.TestUnexpectedResult;
}

fn isRunPointer(word: u64) bool {
    return word != 0 and wire.pointerKind(word) == .list and wire.decodeListPointer(word).elem == .eight_bytes;
}

fn isListKindWord(word: u64) bool {
    return word == @backingInt(capnp.shared.ArgKind.list);
}

test "a word run's count is held to the segment, and an empty run is refused" {
    const allocator = std.testing.allocator;
    var frame = try integerRunFrame(allocator);
    defer frame.deinit();
    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const mutable_view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    const at = try findWord(bytes, isRunPointer);
    const pointer = wire.decodeListPointer(std.mem.readInt(u64, bytes[at..][0..wire.word_bytes], .little));
    try std.testing.expectEqual(@as(u29, 2), pointer.count);

    // A count past the segment's end is refused before any word is read.
    std.mem.writeInt(u64, bytes[at..][0..wire.word_bytes], wire.encodeListPointer(pointer.offset, .eight_bytes, 1000), .little);
    try std.testing.expectError(error.Truncated, capnp.decodeBody(mutable_view));
    try std.testing.expectError(error.Truncated, capnp.decodeOwned(allocator, mutable_view));

    // The encoder writes the empty list as a composite list, so an empty run
    // would be a second form of one value.
    std.mem.writeInt(u64, bytes[at..][0..wire.word_bytes], wire.encodeListPointer(pointer.offset, .eight_bytes, 0), .little);
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(mutable_view));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, mutable_view));
}

test "a word run is a list's form only: under a set it is refused" {
    const allocator = std.testing.allocator;
    var frame = try integerRunFrame(allocator);
    defer frame.deinit();
    const bytes = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(bytes);
    const mutable_view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .word };
    const at = try findWord(bytes, isListKindWord);
    std.mem.writeInt(u64, bytes[at..][0..wire.word_bytes], @backingInt(capnp.shared.ArgKind.set), .little);
    try std.testing.expectError(error.InvalidPointer, capnp.decodeBody(mutable_view));
    try std.testing.expectError(error.InvalidPointer, capnp.decodeOwned(allocator, mutable_view));
}

test "an unaligned integer run re-encodes as the same canonical word bytes" {
    var bytes: [25]u8 align(8) = undefined;
    const numbers = [_]i64{ std.math.minInt(i64), -1, std.math.maxInt(i64) };
    for (numbers, 0..) |number, i| std.mem.writeInt(i64, bytes[1 + i * 8 ..][0..8], number, .little);
    const run = model.view.Args.fromRun(bytes[1..]);
    try std.testing.expect(run.typedRun() == null);
    const views = [_]model.view.Argument{.{ .list = run }};
    var borrowed = try capnp.encodeBody(std.testing.allocator, &.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = .fromViews(&views),
    } });
    defer borrowed.deinit();
    var elements: [3]model.Argument = undefined;
    for (&elements, numbers) |*arg, value| arg.* = .{ .integer = value };
    const args = [_]model.Argument{.{ .list = &elements }};
    var owned = try capnp.encodeMessage(std.testing.allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } });
    defer owned.deinit();
    try std.testing.expectEqualSlices(u8, owned.bytes(), borrowed.bytes());
}

test "packing byte fields preserves every tail and its neighboring words" {
    var storage: [34]u8 align(8) = undefined;
    for (&storage, 0..) |*byte, i| byte.* = @intCast(i);
    for (0..33) |length| {
        const input = storage[1..][0..length];
        var b = try wire.Builder.init(std.testing.allocator);
        defer b.deinit(std.testing.allocator);
        const count = wire.wordsForBytes(length);
        const start = try b.allocWords(std.testing.allocator, count + 2);
        b.set(start, 0xdeadbeef);
        b.set(start + count + 1, 0xcafebabe);
        b.setBytes(start + 1, input);
        try std.testing.expectEqual(@as(u64, 0xdeadbeef), b.words.items[start]);
        try std.testing.expectEqual(@as(u64, 0xcafebabe), b.words.items[start + count + 1]);
        var expected: [32]u8 = @splat(0);
        @memcpy(expected[0..length], input);
        for (0..count) |i| {
            try std.testing.expectEqual(std.mem.readInt(u64, expected[i * 8 ..][0..8], .little), b.words.items[start + 1 + i]);
        }
    }
}
