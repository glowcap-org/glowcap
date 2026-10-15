//! The two-way link's invariants: every pair appears and leaves on both
//! sides together, and a value that names its own key lives in its forward
//! row alone.

const std = @import("std");
const glowcap = @import("glowcap");

const session = glowcap.ocapn.session;
const model = glowcap.ocapn.model;

const Purpose = session.ResolverPurpose;
const Link = @FieldType(session.Session, "outbound_resolver_link");

fn retired(export_position: model.ExportPosition) Purpose {
    return .{ .retired = .{ .resolver_export = export_position, .state = .complete } };
}

fn answer(position: u64) Purpose {
    return .{ .application_answer = .from(position) };
}

test "a value that names its own key holds no reverse row and is found from either side" {
    const allocator = std.testing.allocator;
    var link: Link = .empty;
    defer link.deinit(allocator);

    try link.put(allocator, .from(7), retired(.from(7)));
    try std.testing.expectEqual(@as(usize, 1), link.len());
    try std.testing.expectEqual(@as(usize, 0), link.reverse.count());
    try std.testing.expectEqual(retired(.from(7)), link.getByKey(.from(7)).?);
    try std.testing.expectEqual(@as(?model.ExportPosition, .from(7)), link.getByValue(retired(.from(7))));
    // A self-named value for a key the map does not hold, or holds under
    // another value, is paired with nothing.
    try std.testing.expect(link.getByValue(retired(.from(8))) == null);
    try link.put(allocator, .from(8), answer(1));
    try std.testing.expect(link.getByValue(retired(.from(8))) == null);
    try std.testing.expectEqual(@as(?model.ExportPosition, .from(8)), link.getByValue(answer(1)));
}

test "a transition into a self-named value drops the reverse row and a transition out restores it" {
    const allocator = std.testing.allocator;
    var link: Link = .empty;
    defer link.deinit(allocator);

    try link.put(allocator, .from(3), answer(1));
    try std.testing.expectEqual(@as(usize, 1), link.reverse.count());

    link.replaceValueForKey(.from(3), retired(.from(3)));
    try std.testing.expectEqual(@as(usize, 0), link.reverse.count());
    try std.testing.expect(link.getByValue(answer(1)) == null);
    try std.testing.expectEqual(@as(?model.ExportPosition, .from(3)), link.getByValue(retired(.from(3))));

    link.replaceValueForKey(.from(3), answer(2));
    try std.testing.expectEqual(@as(usize, 1), link.reverse.count());
    try std.testing.expectEqual(@as(?model.ExportPosition, .from(3)), link.getByValue(answer(2)));
    try std.testing.expect(link.getByValue(retired(.from(3))) == null);

    try std.testing.expect(link.removeByKey(.from(3)));
    try std.testing.expectEqual(@as(usize, 0), link.len());
    try std.testing.expectEqual(@as(usize, 0), link.reverse.count());
}

test "a pair sharing a new key or value is evicted whole" {
    const allocator = std.testing.allocator;
    var link: Link = .empty;
    defer link.deinit(allocator);

    try link.put(allocator, .from(1), answer(1));
    try link.put(allocator, .from(2), answer(2));
    // The same answer bound to a new export evicts the old export's pair.
    try link.put(allocator, .from(3), answer(1));
    try std.testing.expect(link.getByKey(.from(1)) == null);
    try std.testing.expectEqual(@as(?model.ExportPosition, .from(3)), link.getByValue(answer(1)));
    try std.testing.expectEqual(@as(usize, 2), link.len());
    try std.testing.expectEqual(@as(usize, 2), link.reverse.count());

    // A replacement that takes another pair's value evicts that pair.
    link.replaceValueForKey(.from(2), answer(1));
    try std.testing.expect(link.getByKey(.from(3)) == null);
    try std.testing.expectEqual(@as(?model.ExportPosition, .from(2)), link.getByValue(answer(1)));
    try std.testing.expectEqual(@as(usize, 1), link.len());
    try std.testing.expectEqual(@as(usize, 1), link.reverse.count());

    // Re-binding a key to a self-named value leaves no reverse row behind.
    try link.put(allocator, .from(2), retired(.from(2)));
    try std.testing.expectEqual(@as(usize, 1), link.len());
    try std.testing.expectEqual(@as(usize, 0), link.reverse.count());
    try std.testing.expect(link.getByValue(answer(1)) == null);
}
