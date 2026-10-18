//! References and operations release partial allocations and bound warm costs.
const std = @import("std");
const c = @import("capability_fixture.zig");
const f = c.f;
const a = c.a;

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var fixture = try f.Fixture.init(allocator, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    var caps = try c.storage.Capabilities.init(allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?.grant;
    const id = try c.descriptor(&caps, backend, owner, grant, null, .rooted);
    const use = try c.use(&caps, backend, id);
    defer use.release();
    store.evict();
    const op = try use.begin(4);
    defer op.deinit() catch unreachable;
    try c.derive(op, backend, f.vocabulary.issue(terms, 0));
    try store.begin();
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    _ = try caps.stage(op, .rooted);
    try f.commit(store, backend);
}

test "access stored capability allocation failures release bindings operations and derived batches" {
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{});
}

test "access stored loaded checks allocate nothing and operation quotas recover" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var fixture = try f.Fixture.init(failing.allocator(), f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    var caps = try c.storage.Capabilities.init(failing.allocator(), store, .{ .max_references = 1, .max_operations = 1 });
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    const id = try c.descriptor(&caps, backend, owner, grant, null, .rooted);
    const reference_bytes = failing.allocated_bytes;
    const use = try c.use(&caps, backend, id);
    defer use.release();
    // Loading a descriptor may reserve a maximum-size read buffer and then keep
    // a copy of the record at its real size.
    try std.testing.expect(failing.allocated_bytes - reference_bytes <= 2 * f.limits.records.max_record_bytes + 96);
    const operation_bytes = failing.allocated_bytes;
    const op = try use.begin(4);
    // Independent Issue and Edit ceilings each retain 256 selected IDs in
    // fixed decoder storage. The second selection adds 12 KiB on 64-bit;
    // metadata and the embedded grant-read scratch fit the remaining bound.
    try std.testing.expect(failing.allocated_bytes - operation_bytes <= 48 * 1024);
    const req: c.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };
    try c.require(op, backend, resource, req);
    const count = failing.alloc_index;
    failing.fail_index = count;
    for (0..32) |_| try op.require(resource, req);
    try std.testing.expectEqual(count, failing.alloc_index);
    try op.deinit();
    try std.testing.expectEqual(@as(usize, 0), caps.operations);
    failing.fail_index = std.math.maxInt(usize);
    const next = try use.begin(4);
    try next.deinit();
}
