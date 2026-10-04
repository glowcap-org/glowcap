//! Backend-independent scoped observation proofs.
const h = @import("hosting_fixture.zig");
const cases = @import("observation_cases.zig");

test "access observation preserves opaque scoped cursors across hidden overflow and visible reversal" {
    var fixture = try h.f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try cases.scoped(&fixture.store, &fixture.backend);
}

test "access observation bounds retained contexts and cancellation frees authority and quota" {
    var fixture = try h.f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try cases.quota(&fixture.store, &fixture.backend);
}

test "access observation joins submitted cancellation and refuses stale prepared snapshots" {
    var fixture = try h.f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try cases.submitted(&fixture.store, &fixture.backend);
}

test "access observation registration replay and cancellation unwind every allocation refusal" {
    try @import("std").testing.checkAllAllocationFailures(h.a, cases.allocation, .{});
}

test "access observation filters control inventory and follows management and grant ancestors" {
    var fixture = try h.f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try cases.controlInventory(&fixture.store, &fixture.backend);
}

test "access observation registrations compose with subsequent owner content changes" {
    var fixture = try h.f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try cases.composed(&fixture.store, &fixture.backend);
}

test "access observation resolves a warm maximum depth path without a spurious wait" {
    const std = @import("std");
    const f = h.f;
    const storage = h.c.storage;
    var fixture = try f.Fixture.init(h.a, @import("history_stamp_cases.zig").depth_limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(42));
    const root = try f.resource(store, backend, owner, null);
    var target = root;
    for (0..64) |_| target = try @import("history_stamp_cases.zig").appendDepthResource(store, backend, owner, target);
    const terms = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?;
    var caps = try storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    const descriptor = try h.c.descriptor(&caps, backend, owner, grant.grant, null, false);
    const held = try h.c.use(&caps, backend, descriptor);
    defer held.release();
    var context: h.loam.core.ObjectId = undefined;
    {
        const source = try held.begin(70);
        defer source.deinit() catch unreachable;
        _ = try f.pump(source, backend);
        const registration = for (0..256) |_| {
            const value = storage.ObservationRegistration.init(source, target, @splat(64)) catch |err| {
                if (err != error.RecordUnloaded) return err;
                _ = try f.pump(source, backend);
                continue;
            };
            break value;
        } else return error.NoProgress;
        defer registration.deinit() catch unreachable;
        _ = try f.pump(registration, backend);
        try store.begin();
        context = try registration.stage(@splat(null));
        try f.commit(store, backend);
    }
    const lease = try h.c.load(store, backend, context);
    const observation = try storage.Observation.init(&caps, lease, null, 70);
    try store.release(lease);
    defer observation.deinit() catch unreachable;
    _ = try f.pump(observation, backend);
    try std.testing.expect((try observation.result()).snapshot.use.access == .active);
}
