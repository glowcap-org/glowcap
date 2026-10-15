//! Exercise configured custody through the actual C-created attachment.
const std = @import("std");
const c = @import("c_abi_loam");
const shared = @import("c_abi_shared");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const backend = @import("c_abi_loam_lmdb");

const Custody = struct {
    canceled: usize = 0,
    fn activate(_: ?*anyopaque, _: *hosting.Continuation) void {
        @panic("uncommitted reservation activated");
    }
    fn cancel(context: ?*anyopaque) void {
        const self: *Custody = @ptrCast(@alignCast(context.?));
        self.canceled += 1;
    }
};

pub fn check(owner: *c.embedding.Attachment, reference: shared.GlowcapReference, object: c.GlowcapLoamObject, storage: *backend.GlowcapLoamLmdb) !void {
    const host = owner.host_borrow.core();
    const capability = host.capabilityFromRaw(reference.id);
    const baseline = host.capabilities.retainCount(capability).?;
    const lease = (try owner.store.value.acquire(try c.embedding.object(object))).ready;
    defer owner.store.value.release(lease) catch unreachable;
    const view = try owner.store.value.currentView(lease);
    var memory: hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, 4096);
    defer memory.deinit();
    var custody: Custody = .{};
    const activation: hosting.Continuation.Activation = .{ .context = &custody, .activate = Custody.activate, .cancel = Custody.cancel };
    var calls: [3]hosting.Call = @splat(.{ .memory = &memory, .attachment = owner.value, .view = view });
    defer for (&calls) |*call| call.release();
    const targets: [4]@import("driver_core").Capability = @splat(capability);
    // Target refusal occurs while count and byte capacity are available.
    try std.testing.expectError(error.ContinuationCapacity, hosting.Continuation.reserveCopying(&calls[0], .{ .verb = "get", .args = &.{} }, &targets, activation));
    // This fits the former 64 KiB default but exceeds the configured 4 KiB.
    try std.testing.expectError(error.OutOfMemory, hosting.Continuation.reserveCopying(&calls[0], .{ .verb = &@as([8192]u8, @splat('v')), .args = &.{} }, &.{}, activation));
    try std.testing.expectEqual(baseline, host.capabilities.retainCount(capability).?);
    try std.testing.expectEqual(@as(usize, 0), owner.value.continuations);
    for (calls[0..2]) |*call| {
        const reserved = try hosting.Continuation.reserveCopying(call, .{ .verb = "get", .args = &.{} }, targets[0..3], activation);
        try std.testing.expect(reserved.source().eql(capability));
        try std.testing.expect((try reserved.target(2)).eql(capability));
    }
    try std.testing.expectError(error.ContinuationCapacity, hosting.Continuation.reserveCopying(&calls[2], .{ .verb = "get", .args = &.{} }, &.{}, activation));
    try std.testing.expectEqual(baseline + 8, host.capabilities.retainCount(capability).?);
    for (&calls) |*call| call.release();
    try std.testing.expectEqual(@as(usize, 2), custody.canceled);
    try std.testing.expectEqual(@as(usize, 0), owner.value.continuations);
    try std.testing.expectEqual(baseline, host.capabilities.retainCount(capability).?);
    try checkForwardReply(owner, &calls[0], storage);
}

const Forward = struct {
    continuation: ?*hosting.Continuation = null,
    invocations: usize = 0,
    fn activate(context: ?*anyopaque, continuation: *hosting.Continuation) void {
        const self: *Forward = @ptrCast(@alignCast(context.?));
        self.continuation = continuation;
    }
    fn cancel(_: ?*anyopaque) void {
        @panic("confirmed reservation canceled");
    }
};
const Target = struct {
    invocations: *usize,
    pub fn handle(self: *Target, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.invocations.* += 1;
        return .{ .list = &.{ .{ .bytes = &@as([4096]u8, @splat('r')) }, .{ .boolean = true } } };
    }
};

fn checkForwardReply(owner: *c.embedding.Attachment, call: *hosting.Call, storage: *backend.GlowcapLoamLmdb) !void {
    const host = owner.host_borrow.core();
    var forward: Forward = .{};
    const actor = try host.vat.spawn(driver.Hosting(Target), .{ .inner = .{ .invocations = &forward.invocations } });
    const target = try host.liftLocalActor(actor);
    defer host.releaseCapabilityTerminal(target, null);
    _ = try hosting.Continuation.reserveCopying(call, .{ .verb = "get", .args = &.{} }, &.{target}, .{ .context = &forward, .activate = Forward.activate, .cancel = Forward.cancel });
    // This configuration witness transfers an already tested confirmation
    // directly, like the CPU continuation suite. Storage recovery is separate.
    const confirmation = call.confirmation.?;
    call.confirmation = null;
    confirmation.apply(confirmation.context);
    defer forward.continuation.?.release();
    const execution = try forward.continuation.?.execute(std.testing.allocator, 0, "get", &.{}, 16 * 1024);
    defer execution.deinit();
    const raw: *c.GlowcapLoamAttachment = @ptrCast(owner);
    for (0..64) |_| {
        _ = try host.vat.driveIngressBudgeted(.local, 64);
        try owner.value.advance();
        var work: ?*c.GlowcapLoamWork = null;
        try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(raw, 0, &work));
        while (work != null) {
            try std.testing.expectEqual(shared.GLOWCAP_OK, backend.glowcap_loam_lmdb_work_run(storage, work));
            var completed: u32 = 0;
            try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_complete(work, &completed));
            try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));
            try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(raw, 0, &work));
        }
        if (execution.result() != .pending) break;
    }
    // The outer observer fits this value; the configured 3072-byte forwarded
    // Call does not. A lost reply after target admission is unknown, never unsent.
    try std.testing.expect(execution.result() == .unknown);
    try std.testing.expectEqualStrings("ReplyCapacity", execution.result().unknown.message);
    try std.testing.expectEqual(@as(usize, 1), forward.invocations);
}
