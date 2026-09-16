//! Local graph reservations preserve prepared scope decisions. Tokens are
//! incarnation-checked data; they are not capabilities or transport handles.
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;

test "access graph reservations retain reads and reject every mutation" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), f.kind, null);
    const b = try graph.create(graph.revision(), f.kind, a);
    const before = graph.revision();
    const token = try graph.reserve(before);
    try std.testing.expectError(error.Busy, graph.reserve(before));
    try std.testing.expectError(error.Busy, graph.create(before, f.kind, a));
    try std.testing.expectError(error.Busy, graph.reparent(before, b, null));
    try std.testing.expectError(error.Busy, graph.destroy(before, b));
    try std.testing.expectError(error.Busy, graph.deinit());
    try std.testing.expect(try graph.isDescendant(b, a));
    try std.testing.expectEqual(before, graph.revision());
    var wrong = token;
    wrong.owner = @fromBackingInt(99);
    try std.testing.expectError(error.InvalidReservation, graph.release(wrong));
    try graph.release(token);
    const next = try graph.reserve(before);
    try std.testing.expect(!graph.ownsReservation(token));
    try std.testing.expectError(error.InvalidReservation, graph.release(token));
    try std.testing.expect(graph.ownsReservation(next));
    try graph.release(next);
    try graph.reparent(before, b, null);
    try std.testing.expectError(error.RevisionConflict, graph.reserve(before));
    try graph.destroy(graph.revision(), a);
}

test "access reservations do not block independent owners" {
    var a = try f.graphInit(std.testing.allocator);
    defer a.deinit() catch unreachable;
    var b = try core.Graph.init(std.testing.allocator, @fromBackingInt(2), .{ .capacity = 2 });
    defer b.deinit() catch unreachable;
    const reserved = try a.reserve(a.revision());
    _ = try b.create(b.revision(), f.kind, null);
    const other = try b.reserve(b.revision());
    try std.testing.expectError(error.InvalidReservation, a.release(other));
    try a.release(reserved);
    try b.release(other);
}
