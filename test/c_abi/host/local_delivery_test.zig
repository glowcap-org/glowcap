//! Foreign callbacks share the owning local Host-turn boundary.
const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const driver = glowcap.driver.core;
const h = @import("harness.zig");
const a = std.testing.allocator;

const Context = struct {
    host: *driver.Host,
    ref: driver.Capability,
    target: ?driver.Capability = null,
    resolver: u64 = 0,
    calls: usize = 0,
};

fn behavior(ctx: ?*anyopaque, turn: ?*cd.GlowcapHostTurn, verb: ?[*]const u8, len: usize, args: ?[*]const c.GlowcapArgument, _: usize, reply: ?*c.GlowcapArgument) callconv(.c) i32 {
    const state: *Context = @ptrCast(@alignCast(ctx.?));
    state.calls += 1;
    var session: ?*cd.GlowcapHostSession = undefined;
    const status = cd.glowcap_host_turn_session(turn, &session);
    std.debug.assert(status == c.GLOWCAP_OK and session == null);
    const method = verb.?[0..len];
    if (std.mem.eql(u8, method, "send") or std.mem.eql(u8, method, "tell")) {
        defer state.host.releaseCapabilityTerminal(state.ref, null);
        defer state.host.releaseCapabilityTerminal(state.ref, null);
        const target: c.GlowcapReference = .{ .id = (state.target orelse state.ref).raw() };
        reply.?.* = h.argBase();
        return if (std.mem.eql(u8, method, "send"))
            cd.glowcap_host_turn_send(turn, &target, "echo", 4, args, 1, &state.resolver)
        else
            cd.glowcap_host_turn_tell(turn, &target, "echo", 4, args, 1);
    }
    if (std.mem.eql(u8, method, "forward")) {
        defer state.host.releaseCapabilityTerminal(state.ref, null);
        defer state.host.releaseCapabilityTerminal(state.ref, null);
        const target: c.GlowcapReference = .{ .id = (state.target orelse state.ref).raw() };
        return cd.glowcap_host_turn_forward(turn, &target, "echo", 4, args, 1, reply);
    }
    if (std.mem.eql(u8, method, "wait"))
        return cd.glowcap_host_turn_defer(turn, &state.resolver);
    if (std.mem.eql(u8, method, "spawn")) {
        var child: c.GlowcapReference = undefined;
        const code = cd.glowcap_host_turn_spawn(turn, emptyBehavior, null, null, &child);
        if (code != c.GLOWCAP_OK) return code;
        reply.?.* = h.argRef(child);
        return c.GLOWCAP_OK;
    }
    // Both mentions were acquired as callback observations. Returning the
    // aliased input remains safe because the queue has independent keepers.
    defer state.host.releaseCapabilityTerminal(state.ref, null);
    defer state.host.releaseCapabilityTerminal(state.ref, null);
    reply.?.* = args.?[0];
    return c.GLOWCAP_OK;
}

fn emptyBehavior(_: ?*anyopaque, _: ?*cd.GlowcapHostTurn, _: ?[*]const u8, _: usize, _: ?[*]const c.GlowcapArgument, _: usize, reply: ?*c.GlowcapArgument) callconv(.c) i32 {
    reply.?.* = h.argBase();
    return c.GLOWCAP_OK;
}

fn countFree(ctx: ?*anyopaque) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(ctx.?));
    count.* += 1;
}

test "libglowcap_host spawn transfers one local root without publishing or opening a session" {
    const raw = try h.newHost(0x75);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var freed: usize = 0;
    var reference: c.GlowcapReference = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, cd.glowcap_host_spawn(raw, emptyBehavior, &freed, countFree, null));
    try std.testing.expectEqual(@as(usize, 0), freed);
    try h.expectOk(cd.glowcap_host_spawn(raw, emptyBehavior, &freed, countFree, &reference));
    try std.testing.expectEqual(@as(usize, 0), host.publications.count());
    try std.testing.expectEqual(@as(usize, 1), host.capabilities.liveCount());
    const call = try host.callLocalCapability(a, host.capabilityFromRaw(reference.id), "echo", &.{}, 512);
    while (try host.nextAction()) |_| {}
    try std.testing.expect(call.result() == .ready);
    call.deinit();
    try h.expectOk(cd.glowcap_host_ref_release(raw, &reference, 1));
    try std.testing.expectEqual(@as(usize, 0), host.capabilities.liveCount());
    // Releasing the root retires the actor immediately. Its box survives until
    // the next outermost turn because the last borrowed reply may still use it.
    try std.testing.expect(host.vat.hasRetiredState());
    var next: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_spawn(raw, emptyBehavior, null, null, &next));
    const boundary = try host.callLocalCapability(a, host.capabilityFromRaw(next.id), "echo", &.{}, 512);
    defer boundary.deinit();
    while (try host.nextAction()) |_| {}
    try h.expectOk(cd.glowcap_host_ref_release(raw, &next, 1));
    try std.testing.expectEqual(@as(usize, 1), freed);
}

fn drainEffects(raw: ?*cd.GlowcapHost, context: *Context, verb: []const u8) !usize {
    var completed: usize = 0;
    while (true) {
        var action: cd.GlowcapHostAction = undefined;
        const code = cd.glowcap_host_next_action(raw, &action);
        if (code == c.GLOWCAP_ERR_WOULD_BLOCK) return completed;
        try h.expectOk(code);
        try std.testing.expect(action.kind != cd.GLOWCAP_HOST_ACTION_FAIL);
        if (action.kind != cd.GLOWCAP_HOST_ACTION_SETTLE) continue;
        try std.testing.expectEqualStrings("send", verb);
        try std.testing.expectEqual(context.resolver, action.ticket);
        try std.testing.expectEqual(@as(usize, 2), action.value.items_len);
        for (action.value.items.?[0..action.value.items_len]) |item| {
            try std.testing.expectEqual(context.ref.raw(), item.reference.id);
            try h.expectOk(cd.glowcap_host_ref_release(raw, &item.reference, 1));
        }
        try h.expectOk(cd.glowcap_host_vow_release(raw, context.resolver));
        completed += 1;
    }
}

test "libglowcap_host owning local callback preserves identities and has no fabricated session" {
    const raw = try h.newHost(0x74);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var context: Context = .{ .host = host, .ref = undefined };
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
    context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
    defer host.releaseCapabilityTerminal(context.ref, null);
    const call = try host.callLocalCapability(a, context.ref, "echo", &.{.{ .list = &.{ .{ .capability = context.ref }, .{ .capability = context.ref } } }}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqual(context.ref, call.result().ready.list[0].capability);
    try std.testing.expectEqual(context.ref, call.result().ready.list[1].capability);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(@as(usize, 0), host.sessions.count());
}

test "libglowcap_host application send owns nested identities without a session and survives observer release" {
    const raw = try h.newHost(0x73);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var context: Context = .{ .host = host, .ref = undefined };
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
    context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
    defer host.releaseCapabilityTerminal(context.ref, null);
    const target: c.GlowcapReference = .{ .id = context.ref.raw() };
    const fields = [_]c.GlowcapArgument{ h.argRef(target), h.argRef(target) };
    var list = h.argBase();
    list.kind = c.GLOWCAP_ARG_LIST;
    list.items = &fields;
    list.items_len = fields.len;
    var vow: u64 = 0;
    try h.expectOk(cd.glowcap_host_send(raw, &target, "echo", 4, @ptrCast(&list), 1, &vow));
    var action: cd.GlowcapHostAction = undefined;
    try h.expectOk(cd.glowcap_host_next_action(raw, &action));
    try std.testing.expectEqual(cd.GLOWCAP_HOST_ACTION_SETTLE, action.kind);
    try std.testing.expectEqual(vow, action.ticket);
    try std.testing.expectEqual(@as(usize, 2), action.value.items_len);
    for (action.value.items.?[0..action.value.items_len]) |item| {
        try std.testing.expectEqual(target.id, item.reference.id);
        try h.expectOk(cd.glowcap_host_ref_release(raw, &item.reference, 1));
    }
    try h.expectOk(cd.glowcap_host_vow_release(raw, vow));
    try h.expectOk(cd.glowcap_host_send(raw, &target, "echo", 4, @ptrCast(&list), 1, &vow));
    try h.expectOk(cd.glowcap_host_vow_release(raw, vow));
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), host.sessions.count());
}

test "libglowcap_host owning local forwarding preserves nested exact C identities" {
    const raw = try h.newHost(0x77);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var context: Context = .{ .host = host, .ref = undefined };
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
    context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
    defer host.releaseCapabilityTerminal(context.ref, null);
    const call = try host.callLocalCapability(a, context.ref, "forward", &.{.{ .list = &.{ .{ .capability = context.ref }, .{ .capability = context.ref } } }}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqual(context.ref, call.result().ready.list[0].capability);
    try std.testing.expectEqual(context.ref, call.result().ready.list[1].capability);
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
}

test "libglowcap_host owning local C forwarding and effects preserve exact replies through actual homes" {
    const support = @import("../../support/core_host.zig");
    const pairs = @import("../../support/host_pair.zig");
    const CapturedRef = @import("../../support/capture.zig").CapturedRef;
    const Echo = struct {
        pub fn handle(_: *@This(), turn: *glowcap.actors.Turn, msg: glowcap.actors.Delivery) !glowcap.ocapn.model.Argument {
            return (try msg.arg(0)).toOwned(turn.arena);
        }
    };
    for ([_][]const u8{ "forward", "send", "tell" }) |verb| for ([_]bool{ false, true }) |remote| {
        const raw = try h.newHost(0x79);
        defer _ = cd.glowcap_host_release(raw);
        var borrow = try cd.embedding.borrowForAttachment(raw);
        defer borrow.release();
        const host = borrow.core();
        var exporter = support.init(a, @splat(0x7a), driver.Host.Options.withFrameCap(4096));
        defer exporter.deinit();
        const actor = try exporter.vat.spawn(Echo, .{});
        const target = try exporter.retainLocalCapability(actor);
        defer exporter.releaseCapabilityTerminal(target, null);
        const swiss = try exporter.publishDurableCapability(@splat(0x55), target);
        const pair = try pairs.openPair(host, &exporter, "127.0.0.1:7935");
        var fetched: CapturedRef = .{};
        try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
        try pairs.pumpToQuiescence(&.{pair});
        const imported = try host.liftCapability(pair.a, try fetched.require());
        defer host.releaseCapabilityTerminal(imported, null);
        var context: Context = .{ .host = host, .ref = undefined, .target = if (remote) imported else null };
        try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
        context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
        defer host.releaseCapabilityTerminal(context.ref, null);
        const call = try host.callLocalCapability(a, context.ref, verb, &.{.{ .list = &.{ .{ .capability = context.ref }, .{ .capability = context.ref } } }}, 4096);
        defer call.deinit();
        var completed = try drainEffects(raw, &context, verb);
        try pairs.pumpToQuiescence(&.{pair});
        completed += try drainEffects(raw, &context, verb);
        try std.testing.expect(call.result() == .ready);
        if (std.mem.eql(u8, verb, "forward")) {
            try std.testing.expectEqual(context.ref, call.result().ready.list[0].capability);
            try std.testing.expectEqual(context.ref, call.result().ready.list[1].capability);
        }
        try std.testing.expectEqual(@as(usize, if (remote) 1 else 2), context.calls);
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, verb, "send")) 1 else 0), completed);
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
    };
}

test "libglowcap_host owning local callback defers a nested capability result through the C resolver" {
    const raw = try h.newHost(0x75);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var context: Context = .{ .host = host, .ref = undefined };
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
    context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
    defer host.releaseCapabilityTerminal(context.ref, null);
    const call = try host.callLocalCapability(a, context.ref, "wait", &.{}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    try std.testing.expect(call.result() == .pending);
    const child = h.argRef(.{ .id = context.ref.raw() });
    var result = h.argBase();
    result.kind = c.GLOWCAP_ARG_LIST;
    const items = [_]c.GlowcapArgument{ child, child };
    result.items = &items;
    result.items_len = items.len;
    try h.expectOk(cd.glowcap_host_resolver_fulfill_value(raw, context.resolver, &result));
    try std.testing.expectEqual(context.ref, call.result().ready.list[0].capability);
    try std.testing.expectEqual(context.ref, call.result().ready.list[1].capability);
    try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
}

test "libglowcap_host owning local callback can spawn the exact reply capability" {
    const raw = try h.newHost(0x76);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var context: Context = .{ .host = host, .ref = undefined };
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
    context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
    defer host.releaseCapabilityTerminal(context.ref, null);
    const call = try host.callLocalCapability(a, context.ref, "spawn", &.{}, 512);
    defer call.deinit();
    while (try host.nextAction()) |_| {}
    const child = call.result().ready.capability;
    try std.testing.expect(!std.meta.eql(context.ref, child));
    try std.testing.expect(host.localActorFor(child) != null);
    try std.testing.expectEqual(@as(usize, 0), host.sessions.count());
    // The spawned callback owns its initial application retain; the reply
    // owner acquires another. This fixture relinquishes the factory retain.
    host.releaseCapabilityTerminal(child, null);
}

test "libglowcap_host owning local C projection refusal retires unexposed observations" {
    const raw = try h.newHost(0x78);
    defer _ = cd.glowcap_host_release(raw);
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    var context: Context = .{ .host = host, .ref = undefined };
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, behavior, &context, null));
    context.ref = try host.retainLocalCapability(host.publications.get("local").?.actor);
    defer host.releaseCapabilityTerminal(context.ref, null);
    const items: [64]driver.Value = @splat(.{ .capability = context.ref });
    const call = try host.callLocalCapability(a, context.ref, "echo", &.{.{ .list = &items }}, 512);
    defer call.deinit();
    // The first arena block holds observations. Refuse the next block needed
    // by the C projection, after retains were acquired but before callback entry.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    failing.resize_fail_index = 0;
    host.vat.turn_arena.deinit();
    host.vat.turn_arena = .init(failing.allocator());
    while (try host.nextAction()) |_| {}
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), context.calls);
    try std.testing.expectEqualStrings("OutOfMemory", call.result().failed.message);
    try std.testing.expectEqual(@as(?u64, 1), host.capabilities.retainCount(context.ref));
    // The allocator lives through its arena's teardown, before Host release.
    host.vat.turn_arena.deinit();
    host.vat.turn_arena = .init(a);
}
