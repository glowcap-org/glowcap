//! A promise that settled to data counts at the depth it sits when it rides a
//! C send: lowering replaces it with that data, so data that holds items does
//! not fit at the ceiling. The settlement is real: a deferred answer fulfills,
//! the client's vow settles, and `glowcap_host_vow_capability` turns the settled
//! vow into a reference that the Host stages as settled data. A failure means
//! the call admits a send whose lowering later fails, or refuses one that fits.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const rig_owner = @import("capability_free_deliver_test.zig");

const model = glowcap.ocapn.model;
const Arg = c.GlowcapArgument;
const Rig = rig_owner.Rig;
const listOf = rig_owner.listOf;

/// The server's `ask` verb defers its answer and keeps the resolver, so the
/// test settles it from outside any turn.
const Asks = struct {
    resolvers: [4]u64 = @splat(0),
    count: usize = 0,
};

fn askBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    _: ?[*]const u8,
    _: usize,
    _: ?[*]const Arg,
    _: usize,
    out_reply: *Arg,
) callconv(.c) i32 {
    const asks: *Asks = @ptrCast(@alignCast(ctx.?));
    var resolver: u64 = 0;
    const code = cd.glowcap_host_turn_defer(turn, &resolver);
    if (code != c.GLOWCAP_OK) return code;
    asks.resolvers[asks.count] = resolver;
    asks.count += 1;
    out_reply.* = h.argBase();
    return c.GLOWCAP_OK;
}

const Question = struct { vow: u64, resolver: u64 };

const Fixture = struct {
    rig: Rig = undefined,
    asks: Asks = .{},
    later: c.GlowcapReference = undefined,
    captures: [4]h.CapturedSettle = @splat(.{}),

    fn open(self: *Fixture, seed: u8, designator: []const u8) !void {
        self.* = .{};
        try self.rig.open(c.GLOWCAP_CODEC_SYRUP, seed, designator, .forward);
        var local: c.GlowcapReference = undefined;
        try h.expectOk(cd.glowcap_host_session_publish(self.rig.pair.b, "later", 5, askBehavior, &self.asks, null, &local));
        var ticket: u64 = undefined;
        var fetched = h.CapturedSettle{};
        try h.expectOk(cd.glowcap_host_session_fetch(self.rig.pair.a, "later", 5, &ticket));
        self.rig.watches.add(self.rig.client(), ticket, &fetched);
        try self.pump();
        self.later = try fetched.requireRef();
    }

    fn deinit(self: *Fixture) void {
        self.rig.deinit();
    }

    fn pump(self: *Fixture) !void {
        try h.pump(&self.rig.hosts, &.{self.rig.pair}, &self.rig.dials, &self.rig.watches);
    }

    /// Ask the server, which defers: the answer stays pending.
    fn ask(self: *Fixture) !Question {
        const index = self.asks.count;
        var vow: u64 = undefined;
        try h.expectOk(cd.glowcap_host_session_send(self.rig.pair.a, &self.later, "ask", 3, null, 0, &vow));
        self.rig.watches.add(self.rig.client(), vow, &self.captures[index]);
        try self.pump();
        try std.testing.expectEqual(index + 1, self.asks.count);
        return .{ .vow = vow, .resolver = self.asks.resolvers[index] };
    }

    /// A reference to a vow that settled to `data`, asked after the settlement.
    fn settledReference(self: *Fixture, data: Arg) !c.GlowcapReference {
        const question = try self.ask();
        const capture = &self.captures[self.asks.count - 1];
        try h.expectOk(cd.glowcap_host_resolver_fulfill(self.rig.server(), question.resolver, &data));
        try self.pump();
        try std.testing.expect(capture.fired);
        try std.testing.expectEqual(.fulfilled, capture.kind);
        var reference: c.GlowcapReference = undefined;
        try h.expectOk(cd.glowcap_host_vow_capability(self.rig.client(), question.vow, &reference));
        try self.pump();
        return reference;
    }

    /// Settle a pending vow to the server's tap, so what queued behind it runs.
    fn settleToTap(self: *Fixture, question: Question) !void {
        const tap = h.argRef(self.rig.tap_local);
        try h.expectOk(cd.glowcap_host_resolver_fulfill_value(self.rig.server(), question.resolver, &tap));
        try self.pump();
    }
};

/// The reference at depth `containers`: that many single-item lists around it.
fn referenceTree(arena: std.mem.Allocator, reference: c.GlowcapReference, containers: usize) !Arg {
    var tree = h.argRef(reference);
    for (0..containers) |_| tree = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{tree});
    return tree;
}

fn settledData(arena: std.mem.Allocator, leaf: bool) !Arg {
    return if (leaf) h.argInt(7) else try listOf(arena, c.GLOWCAP_ARG_LIST, &.{});
}

/// Settled leaf data fits wherever the leaf does. Settled container data holds
/// items one level deeper, so it fits only where a container does.
fn fits(leaf: bool, depth: usize) bool {
    return if (leaf) depth <= model.max_value_depth else depth < model.max_value_depth;
}

fn expectNoOutbound(session: ?*cd.GlowcapHostSession) !void {
    var frame: c.GlowcapManagedFrame = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, h.takeOutbound(session, &frame));
}

const depths = [_]usize{ model.max_value_depth - 1, model.max_value_depth, model.max_value_depth + 1 };

test "a C far send carries a settled promise at the ceiling when its data is a leaf and refuses it when its data holds items" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ true, false }) |leaf| for (depths) |depth| {
        var fixture: Fixture = undefined;
        try fixture.open(0x60, "127.0.0.1:7991");
        defer fixture.deinit();
        const reference = try fixture.settledReference(try settledData(arena, leaf));
        const tree = try referenceTree(arena, reference, depth);
        const live = try cd.testing.liveCapabilityCount(fixture.rig.client());
        var vow: u64 = std.math.maxInt(u64);
        const code = cd.glowcap_host_session_send(fixture.rig.pair.a, &fixture.rig.target, "call", 4, &[_]Arg{tree}, 1, &vow);
        if (fits(leaf, depth)) {
            try h.expectOk(code);
            try fixture.pump();
            try std.testing.expectEqual(@as(usize, 1), fixture.rig.tap.delivers);
        } else {
            try std.testing.expect(code != c.GLOWCAP_OK);
            try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), vow);
            try expectNoOutbound(fixture.rig.pair.a);
            try fixture.pump();
            try std.testing.expectEqual(@as(usize, 0), fixture.rig.tap.delivers);
            try std.testing.expectEqual(live, try cd.testing.liveCapabilityCount(fixture.rig.client()));
        }
    };
}

test "a C send to an unsettled Host promise queues a settled promise at the ceiling by the same rule and runs it on settlement" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ true, false }) |leaf| for (depths) |depth| {
        var fixture: Fixture = undefined;
        try fixture.open(0x62, "127.0.0.1:7992");
        defer fixture.deinit();
        const reference = try fixture.settledReference(try settledData(arena, leaf));
        // The target is a promise this Host exports, still pending, so the send
        // queues in the Host and clones its arguments there.
        const pending = try fixture.ask();
        var target: c.GlowcapReference = undefined;
        try h.expectOk(cd.glowcap_host_vow_capability(fixture.rig.client(), pending.vow, &target));
        const tree = try referenceTree(arena, reference, depth);
        const live = try cd.testing.liveCapabilityCount(fixture.rig.client());
        var vow: u64 = std.math.maxInt(u64);
        const code = cd.glowcap_host_session_send(fixture.rig.pair.a, &target, "call", 4, &[_]Arg{tree}, 1, &vow);
        try expectNoOutbound(fixture.rig.pair.a);
        if (fits(leaf, depth)) {
            try h.expectOk(code);
            try std.testing.expect(vow != std.math.maxInt(u64));
            try std.testing.expectEqual(@as(usize, 0), fixture.rig.tap.delivers);
        } else {
            try std.testing.expect(code != c.GLOWCAP_OK);
            try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), vow);
            try std.testing.expectEqual(live, try cd.testing.liveCapabilityCount(fixture.rig.client()));
        }
        try fixture.settleToTap(pending);
        try std.testing.expectEqual(@as(usize, @intFromBool(fits(leaf, depth))), fixture.rig.tap.delivers);
    };
}

test "a queued send whose pending promise later settles to data that does not fit breaks its own result and runs the next send" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = undefined;
    try fixture.open(0x64, "127.0.0.1:7993");
    defer fixture.deinit();
    // The data promise and the target promise are both pending at the sends.
    const data = try fixture.ask();
    const live = try cd.testing.liveCapabilityCount(fixture.rig.client());
    var data_reference: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_vow_capability(fixture.rig.client(), data.vow, &data_reference));
    const target_question = try fixture.ask();
    var target: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_vow_capability(fixture.rig.client(), target_question.vow, &target));
    // Admission cannot know what the data will be, so the send at the ceiling
    // queues, and so does the plain one behind it.
    const tree = try referenceTree(arena, data_reference, model.max_value_depth);
    var doomed_vow: u64 = undefined;
    var doomed = h.CapturedSettle{};
    try h.expectOk(cd.glowcap_host_session_send(fixture.rig.pair.a, &target, "call", 4, &[_]Arg{tree}, 1, &doomed_vow));
    fixture.rig.watches.add(fixture.rig.client(), doomed_vow, &doomed);
    var next_vow: u64 = undefined;
    var next = h.CapturedSettle{};
    try h.expectOk(cd.glowcap_host_session_send(fixture.rig.pair.a, &target, "call", 4, &[_]Arg{h.argInt(1)}, 1, &next_vow));
    fixture.rig.watches.add(fixture.rig.client(), next_vow, &next);
    try expectNoOutbound(fixture.rig.pair.a);
    // The data settles to a container, which holds items one level past the
    // ceiling, then the target settles and the queue runs.
    var container = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{});
    try h.expectOk(cd.glowcap_host_resolver_fulfill(fixture.rig.server(), data.resolver, &container));
    try fixture.pump();
    try fixture.settleToTap(target_question);
    try std.testing.expect(doomed.fired);
    try std.testing.expectEqual(.failed, doomed.kind);
    try std.testing.expect(next.fired);
    try std.testing.expectEqual(.fulfilled, next.kind);
    try std.testing.expectEqual(@as(usize, 1), fixture.rig.tap.delivers);
    try expectNoOutbound(fixture.rig.pair.a);
    // The queued sends' retains are gone, the refused one's included: once
    // the application drops its own two references, nothing is left over.
    try h.expectOk(cd.glowcap_host_ref_release(fixture.rig.client(), &data_reference, 1));
    try h.expectOk(cd.glowcap_host_ref_release(fixture.rig.client(), &target, 1));
    try fixture.pump();
    try std.testing.expectEqual(live, try cd.testing.liveCapabilityCount(fixture.rig.client()));
}

/// The server's `echo` verb answers with `max_value_depth` single-item lists
/// around the one reference it was sent, a leaf at the ceiling.
const Echo = struct {
    nodes: [model.max_value_depth + 1]Arg = undefined,
};

fn echoBehavior(
    ctx: ?*anyopaque,
    _: ?*cd.GlowcapHostTurn,
    _: ?[*]const u8,
    _: usize,
    args: ?[*]const Arg,
    count: usize,
    out_reply: *Arg,
) callconv(.c) i32 {
    const echo: *Echo = @ptrCast(@alignCast(ctx.?));
    if (count != 1 or args.?[0].kind != c.GLOWCAP_ARG_REFERENCE) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    echo.nodes[model.max_value_depth] = h.argRef(args.?[0].reference);
    var level: usize = model.max_value_depth;
    while (level != 0) {
        level -= 1;
        var list = h.argBase();
        list.kind = c.GLOWCAP_ARG_LIST;
        list.items = @ptrCast(&echo.nodes[level + 1]);
        list.items_len = 1;
        echo.nodes[level] = list;
    }
    out_reply.* = echo.nodes[0];
    return c.GLOWCAP_OK;
}

test "a held reply keeps a promise identity that later settles to data too deep for its place, and a send of it still refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = undefined;
    try fixture.open(0x66, "127.0.0.1:7994");
    defer fixture.deinit();
    const rig = &fixture.rig;
    // The client exports a promise for a pending vow, and the server hands it
    // back inside a reply at the ceiling: the client lifts the identity it
    // already holds, still pending.
    const question = try fixture.ask();
    var promise: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_vow_capability(rig.client(), question.vow, &promise));
    var echo: Echo = .{};
    var echo_local: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_session_publish(rig.pair.b, "echo", 4, echoBehavior, &echo, null, &echo_local));
    var ticket: u64 = undefined;
    var fetched = h.CapturedSettle{};
    try h.expectOk(cd.glowcap_host_session_fetch(rig.pair.a, "echo", 4, &ticket));
    rig.watches.add(rig.client(), ticket, &fetched);
    try fixture.pump();
    const echo_target = try fetched.requireRef();
    var echo_vow: u64 = undefined;
    var echoed = h.CapturedSettle{};
    try h.expectOk(cd.glowcap_host_session_send(rig.pair.a, &echo_target, "echo", 4, &[_]Arg{h.argRef(promise)}, 1, &echo_vow));
    rig.watches.add(rig.client(), echo_vow, &echoed);
    try fixture.pump();
    try std.testing.expect(echoed.fired);
    try std.testing.expectEqual(.fulfilled, echoed.kind);
    // The promise settles to a container: valid as a root, too deep at the
    // ceiling where the reply holds it.
    var container = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{});
    try h.expectOk(cd.glowcap_host_resolver_fulfill(rig.server(), question.resolver, &container));
    try fixture.pump();
    // Asking for the held reply as a promise keeps the identity the reply
    // holds, so the promise settles to the reply and not to a break.
    var held_promise: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_vow_capability(rig.client(), echo_vow, &held_promise));
    try fixture.pump();
    // Sending that promise lowers the data it settled to, which places the
    // container at the ceiling, so the call refuses and queues nothing.
    var sent: u64 = std.math.maxInt(u64);
    const code = cd.glowcap_host_session_send(rig.pair.a, &rig.target, "call", 4, &[_]Arg{h.argRef(held_promise)}, 1, &sent);
    try std.testing.expect(code != c.GLOWCAP_OK);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), sent);
    try expectNoOutbound(rig.pair.a);
    try fixture.pump();
    try std.testing.expectEqual(@as(usize, 0), rig.tap.delivers);
}
