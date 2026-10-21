//! The two-way link's invariants: every pair appears and leaves on both
//! sides together, and a pair that collides with a new one on either side
//! is evicted whole.

const std = @import("std");
const glowcap = @import("glowcap");

const session = glowcap.ocapn.session;
const model = glowcap.ocapn.model;

const Link = @FieldType(session.Session, "v1_0_inbound_resolver_link");

fn wire(position: u64) model.AnswerName {
    return .{ .wire = .from(position) };
}

fn virtual(position: u64) model.AnswerName {
    return .{ .virtual = .from(position) };
}

test "a pair is found from either side and leaves from both" {
    const allocator = std.testing.allocator;
    var link: Link = .empty;
    defer link.deinit(allocator);

    try link.put(allocator, wire(7), .from(70));
    try link.put(allocator, virtual(7), .from(71));
    try std.testing.expectEqual(@as(usize, 2), link.len());
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(70)), link.getByKey(wire(7)));
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(71)), link.getByKey(virtual(7)));
    try std.testing.expectEqual(@as(?model.AnswerName, wire(7)), link.getByValue(.from(70)));
    try std.testing.expectEqual(@as(?model.AnswerName, virtual(7)), link.getByValue(.from(71)));
    try std.testing.expect(link.getByValue(.from(72)) == null);

    try std.testing.expect(link.removeByKey(wire(7)));
    try std.testing.expect(!link.removeByKey(wire(7)));
    try std.testing.expectEqual(@as(usize, 1), link.len());
    try std.testing.expect(link.getByKey(wire(7)) == null);
    try std.testing.expect(link.getByValue(.from(70)) == null);
    try std.testing.expectEqual(@as(?model.AnswerName, virtual(7)), link.getByValue(.from(71)));
}

test "a pair sharing a new key or value is evicted whole" {
    const allocator = std.testing.allocator;
    var link: Link = .empty;
    defer link.deinit(allocator);

    try link.put(allocator, wire(1), .from(10));
    try link.put(allocator, wire(2), .from(20));
    // The same import bound to a new answer evicts the old answer's pair. status-allow: replacement state identity
    try link.put(allocator, wire(3), .from(10));
    try std.testing.expect(link.getByKey(wire(1)) == null);
    try std.testing.expectEqual(@as(?model.AnswerName, wire(3)), link.getByValue(.from(10)));
    try std.testing.expectEqual(@as(usize, 2), link.len());

    // The same answer bound to a new import evicts the old import's pair. status-allow: replacement state identity
    try link.put(allocator, wire(2), .from(21));
    try std.testing.expect(link.getByValue(.from(20)) == null);
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(21)), link.getByKey(wire(2)));
    try std.testing.expectEqual(@as(usize, 2), link.len());
    try std.testing.expectEqual(link.len(), link.reverse.count());
}
