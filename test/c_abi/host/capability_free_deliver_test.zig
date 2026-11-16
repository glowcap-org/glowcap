//! A wire deliver that session validation counted no capability in reaches a
//! C-hosted object in one walk: its views project straight onto the C
//! arguments with no Host value tree, no receipts, and no lease. A deliver
//! that carries one, or whose count is unknown, is lifted first. A tap
//! published in front of the C bridge sees the delivery and measures the turn
//! arena, shapes the count, or compares the two projections.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const behaviors = @import("behaviors.zig");
const fixtures = @import("../../support/view_fixtures.zig");
const shared = @import("c_abi_shared");
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const argInt = h.argInt;
const argStr = h.argStr;
const argBase = h.argBase;

const Arg = c.GlowcapArgument;

/// What the C callback saw: how many times it ran, the arguments it got
/// copied out of the borrowed call, the bytes the turn arena had handed out
/// when it entered, and the Host's live capability count at entry.
const Probe = struct {
    calls: usize = 0,
    arg_count: usize = 0,
    args_null: bool = false,
    verb_null: bool = false,
    verb_len: usize = 0,
    arena_bytes: usize = 0,
    live: usize = 0,
    counter: ?*const FailingOnce = null,
    host: ?*cd.GlowcapHost = null,
    keep: std.heap.ArenaAllocator = undefined,
    tree: []const Arg = &.{},
};

fn copyList(alloc: std.mem.Allocator, items: []const Arg) error{OutOfMemory}![]Arg {
    const out = try alloc.alloc(Arg, items.len);
    for (items, out) |item, *slot| slot.* = try copyArg(alloc, item);
    return out;
}

/// A deep copy, for a tree the callback or the lift only borrows for a call.
fn copyArg(alloc: std.mem.Allocator, arg: Arg) error{OutOfMemory}!Arg {
    var out = arg;
    if (arg.bytes_len > 0) out.bytes = (try alloc.dupe(u8, arg.bytes.?[0..arg.bytes_len])).ptr;
    if (arg.items_len > 0) out.items = (try copyList(alloc, arg.items.?[0..arg.items_len])).ptr;
    return out;
}

fn probeBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const Arg,
    count: usize,
    _: *Arg,
) callconv(.c) i32 {
    const probe: *Probe = @ptrCast(@alignCast(ctx.?));
    _ = turn;
    probe.calls += 1;
    probe.args_null = args == null;
    probe.verb_null = verb == null;
    probe.verb_len = verb_len;
    probe.arg_count = count;
    probe.arena_bytes = (probe.counter orelse return c.GLOWCAP_ERR_BROKEN).allocated_bytes;
    probe.live = cd.testing.liveCapabilityCount(probe.host) catch return c.GLOWCAP_ERR_BROKEN;
    probe.tree = copyList(probe.keep.allocator(), if (count == 0) &.{} else args.?[0..count]) catch return c.GLOWCAP_ERR_BROKEN;
    return c.GLOWCAP_OK;
}

/// How the tap hands a delivery to the C bridge behind it.
const Mode = enum {
    /// As the wire delivered it.
    forward,
    /// With the capability count unknown.
    forward_unknown,
    /// Claiming no capability whatever the arguments carry, to reach the
    /// views route with a reference on it.
    forward_claimed_free,
};

const Tap = struct {
    bridge: actors.HostedActor,
    mode: Mode,
    host: ?*cd.GlowcapHost,
    session: ?*cd.GlowcapHostSession = null,
    /// Also lift a capability-free deliver, for the test to compare with.
    lift_copy: bool = false,
    keep: std.heap.ArenaAllocator,
    lifted: []const Arg = &.{},
    delivers: usize = 0,
    slots: ?u32 = null,
    /// Counts the bytes the bridge takes from the turn arena.
    counter: FailingOnce = undefined,

    fn handle(erased: *anyopaque, turn: *actors.Turn, msg: actors.Delivery) actors.HostedActor.Result {
        const self: *Tap = @ptrCast(@alignCast(erased));
        self.delivers += 1;
        self.slots = msg.reference_slots;
        if (self.lift_copy and msg.reference_slots == 0) {
            const lifted = cd.testing.projectLifted(self.host, self.session, turn.arena, msg.args) catch |err| return .{ .refused = actors.HostedActor.Failure.behavior(err) };
            self.lifted = copyList(self.keep.allocator(), lifted) catch |err| return .{ .refused = actors.HostedActor.Failure.behavior(err) };
        }
        var shaped = msg;
        if (self.mode == .forward_unknown) shaped.reference_slots = null;
        if (self.mode == .forward_claimed_free) shaped.reference_slots = 0;
        // The bridge reads the arena at entry, so it allocates through the
        // counter, which never refuses.
        const outer = turn.arena;
        self.counter = FailingOnce.init(outer, std.math.maxInt(usize));
        turn.arena = self.counter.allocator();
        defer turn.arena = outer;
        return self.bridge.handle(self.bridge.ctx, turn, shaped);
    }

    fn free(erased: *anyopaque) void {
        const self: *Tap = @ptrCast(@alignCast(erased));
        self.bridge.discard();
        self.keep.deinit();
        std.testing.allocator.destroy(self);
    }
};

/// Two projections of one tree are equal field by field. A tree a callback or
/// the lift lent from the frame also shares its leaf bytes, which a copy does
/// not, so `lent` asks for the pointer as well as the content.
fn expectSame(a: Arg, b: Arg, lent: bool, nodes: *usize) error{TestExpectedEqual}!void {
    nodes.* += 1;
    try std.testing.expectEqual(b.kind, a.kind);
    try std.testing.expectEqual(b.boolean, a.boolean);
    try std.testing.expectEqual(b.integer, a.integer);
    try std.testing.expectEqual(@as(u64, @bitCast(b.float64)), @as(u64, @bitCast(a.float64)));
    try std.testing.expectEqual(b.reference.id, a.reference.id);
    try std.testing.expectEqual(b.bytes_len, a.bytes_len);
    if (b.bytes_len > 0) {
        if (lent) try std.testing.expectEqual(b.bytes, a.bytes);
        try std.testing.expectEqualSlices(u8, b.bytes.?[0..b.bytes_len], a.bytes.?[0..a.bytes_len]);
    }
    try std.testing.expectEqual(b.items_len, a.items_len);
    if (b.items_len > 0) try expectSameList(a.items.?[0..a.items_len], b.items.?[0..b.items_len], lent, nodes);
}

fn expectSameList(a: []const Arg, b: []const Arg, lent: bool, nodes: *usize) error{TestExpectedEqual}!void {
    try std.testing.expectEqual(b.len, a.len);
    for (a, b) |x, y| try expectSame(x, y, lent, nodes);
}

/// Nodes the callback receives for a sent tree: a run of integers arrives as a
/// list with one integer per word.
fn countNodes(args: []const Arg) usize {
    var total: usize = 0;
    for (args) |arg| {
        total += 1;
        if (arg.kind == c.GLOWCAP_ARG_INTEGERS) {
            total += arg.bytes_len / @sizeOf(i64);
        } else if (arg.items_len > 0) {
            total += countNodes(arg.items.?[0..arg.items_len]);
        }
    }
    return total;
}

/// One client and one server host over a wired pair, with a tap published on
/// the server and fetched by the client.
const Rig = struct {
    hosts: [2]?*cd.GlowcapHost = undefined,
    dials: h.Dials = .{},
    watches: h.Watches = .{},
    pair: h.Pair = undefined,
    target: c.GlowcapReference = undefined,
    tap_local: c.GlowcapReference = undefined,
    tap: *Tap = undefined,
    probe: Probe = .{},

    fn open(self: *Rig, codec: u32, seed: u8, designator: []const u8, mode: Mode, nesting_limit: ?usize) !void {
        self.* = .{};
        const dialer = try h.newHostWith(seed, codec);
        const acceptor = try h.newHostWith(seed + 1, codec);
        self.hosts = .{ dialer, acceptor };
        self.probe = .{ .host = acceptor, .keep = .init(std.testing.allocator) };
        if (nesting_limit) |limit| try cd.testing.setNestingLimit(acceptor, limit);
        self.pair = try h.openPair(&self.hosts, dialer, acceptor, designator, &self.dials, &self.watches);
        const bridge = try cd.testing.hostedBridge(std.testing.allocator, probeBehavior, &self.probe, null);
        self.tap = std.testing.allocator.create(Tap) catch |err| {
            bridge.discard();
            return err;
        };
        self.tap.* = .{ .bridge = bridge, .mode = mode, .host = acceptor, .session = self.pair.b, .keep = .init(std.testing.allocator) };
        self.probe.counter = &self.tap.counter;
        self.tap_local = try cd.testing.publishHosted(self.pair.b, "tap", .{ .ctx = self.tap, .handle = Tap.handle, .free = Tap.free });
        var fetched = h.CapturedSettle{};
        var ticket: u64 = undefined;
        try h.expectOk(cd.glowcap_host_session_fetch(self.pair.a, "tap", 3, &ticket));
        self.watches.add(dialer, ticket, &fetched);
        try h.pump(&self.hosts, &.{self.pair}, &self.dials, &self.watches);
        self.target = try fetched.requireRef();
    }

    fn deinit(self: *Rig) void {
        for (self.hosts) |host| _ = cd.glowcap_host_release(host);
        self.probe.keep.deinit();
    }

    fn client(self: *Rig) ?*cd.GlowcapHost {
        return self.hosts[0];
    }

    fn server(self: *Rig) ?*cd.GlowcapHost {
        return self.hosts[1];
    }

    fn send(self: *Rig, args: []const Arg) !h.CapturedSettle {
        return self.sendVerb("call", args);
    }

    fn sendVerb(self: *Rig, verb: ?[]const u8, args: []const Arg) !h.CapturedSettle {
        var settled = h.CapturedSettle{};
        var vow: u64 = undefined;
        const verb_ptr: ?[*]const u8 = if (verb) |name| name.ptr else null;
        const verb_len = if (verb) |name| name.len else 0;
        const args_ptr: ?[*]const Arg = if (args.len == 0) null else args.ptr;
        try h.expectOk(cd.glowcap_host_session_send(self.pair.a, &self.target, verb_ptr, verb_len, args_ptr, args.len, &vow));
        self.watches.add(self.client(), vow, &settled);
        try h.pump(&self.hosts, &.{self.pair}, &self.dials, &self.watches);
        return settled;
    }
};

fn expectFulfilled(settled: h.CapturedSettle) !void {
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(.fulfilled, settled.kind);
}

fn listOf(arena: std.mem.Allocator, kind: u32, items: []const Arg) !Arg {
    var arg = argBase();
    arg.kind = kind;
    if (items.len > 0) {
        const owned = try arena.dupe(Arg, items);
        arg.items = owned.ptr;
        arg.items_len = owned.len;
    }
    return arg;
}

fn leaf(kind: u32, bytes: []const u8) Arg {
    var arg = argBase();
    arg.kind = kind;
    arg.bytes = bytes.ptr;
    arg.bytes_len = bytes.len;
    return arg;
}

/// A list of 12 integers, a struct of 3 string fields, and a last argument:
/// 21 `GlowcapArgument` slots in three arrays.
fn spineShape(arena: std.mem.Allocator, last: Arg) ![]const Arg {
    const ints = try arena.alloc(Arg, 12);
    for (ints, 0..) |*slot, i| slot.* = argInt(@intCast(i));
    const fields = [_]Arg{ argStr("a"), argStr("one"), argStr("b"), argStr("two"), argStr("c"), argStr("three") };
    return arena.dupe(Arg, &.{
        try listOf(arena, c.GLOWCAP_ARG_LIST, ints),
        try listOf(arena, c.GLOWCAP_ARG_STRUCT, &fields),
        last,
    });
}

const spine_bytes = (3 + 12 + 6) * @sizeOf(Arg);

/// Bytes the bridge took from the turn arena before the callback ran.
fn growth(rig: *const Rig) usize {
    return rig.probe.arena_bytes;
}

test "a capability-free deliver grows the turn arena by the C argument spine only" {
    for ([_]u32{ c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CODEC_CAPNP }) |codec| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var rig: Rig = undefined;
        try rig.open(codec, 0x40, "127.0.0.1:7981", .forward, null);
        defer rig.deinit();
        const shape = try spineShape(arena, argStr("last"));

        // Validation counted no capability, and the C callback ran once.
        try expectFulfilled(try rig.send(shape));
        try std.testing.expectEqual(@as(?u32, 0), rig.tap.slots);
        try std.testing.expectEqual(@as(usize, 3), rig.probe.arg_count);
        try std.testing.expectEqual(spine_bytes, growth(&rig));

        // An unknown count lifts first: the Host values add their own arrays.
        rig.tap.mode = .forward_unknown;
        try expectFulfilled(try rig.send(shape));
        try std.testing.expectEqual(@as(?u32, 0), rig.tap.slots);
        try std.testing.expect(growth(&rig) > spine_bytes);
        try std.testing.expectEqual(@as(usize, 3), rig.probe.arg_count);

        // So does a deliver that carries a capability.
        rig.tap.mode = .forward;
        var local: c.GlowcapReference = undefined;
        try h.expectOk(cd.glowcap_host_spawn(rig.client(), probeBehavior, &rig.probe, null, &local));
        try expectFulfilled(try rig.send(try spineShape(arena, h.argRef(local))));
        try std.testing.expectEqual(@as(?u32, 1), rig.tap.slots);
        try std.testing.expect(growth(&rig) > spine_bytes);
    }
}

/// Every argument kind, nested, with a run of integers.
fn everyKind(arena: std.mem.Allocator) ![]const Arg {
    var scalar = argBase();
    scalar.kind = c.GLOWCAP_ARG_FLOAT64;
    scalar.float64 = -0.0;
    var flag = argBase();
    flag.kind = c.GLOWCAP_ARG_BOOLEAN;
    flag.boolean = 1;
    const big = leaf(c.GLOWCAP_ARG_BIG_INTEGER, "123456789012345678901234567890");
    var negative = leaf(c.GLOWCAP_ARG_BIG_INTEGER, "98765432109876543210");
    negative.boolean = 1;
    var words: [40]i64 = undefined;
    for (&words, 0..) |*word, i| word.* = @as(i64, @intCast(i)) * 1_000_000_007 - 5;
    const run = leaf(c.GLOWCAP_ARG_INTEGERS, std.mem.sliceAsBytes(try arena.dupe(i64, &words)));
    const nested = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{
        try listOf(arena, c.GLOWCAP_ARG_LIST, &.{
            try listOf(arena, c.GLOWCAP_ARG_LIST, &.{ argInt(1), argStr("deep") }),
        }),
    });
    const mixed = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{ argInt(1), argStr("two"), scalar, nested, negative });
    const set = try listOf(arena, c.GLOWCAP_ARG_SET, &.{ argStr("a"), argStr("b"), argInt(3) });
    var tagged = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{ argInt(1), mixed });
    tagged.kind = c.GLOWCAP_ARG_TAGGED;
    tagged.bytes = "tag".ptr;
    tagged.bytes_len = 3;
    var empty_tagged = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{});
    empty_tagged.kind = c.GLOWCAP_ARG_TAGGED;
    empty_tagged.bytes = "none".ptr;
    empty_tagged.bytes_len = 4;
    const inner = try listOf(arena, c.GLOWCAP_ARG_STRUCT, &.{ argStr("x"), argInt(9), argStr("y"), try listOf(arena, c.GLOWCAP_ARG_STRUCT, &.{}) });
    const record = try listOf(arena, c.GLOWCAP_ARG_STRUCT, &.{
        argStr("alpha"), argInt(7),
        argStr("beta"),  nested,
        argStr("gamma"), run,
        argStr("delta"), inner,
    });
    return arena.dupe(Arg, &.{
        argInt(-5),
        scalar,
        flag,
        leaf(c.GLOWCAP_ARG_BYTES, "bytes"),
        argStr("string"),
        leaf(c.GLOWCAP_ARG_SYMBOL, "symbol"),
        argBase(),
        leaf(c.GLOWCAP_ARG_KEYWORD, "keyword"),
        leaf(c.GLOWCAP_ARG_ERROR, "an error"),
        big,
        negative,
        mixed,
        set,
        try listOf(arena, c.GLOWCAP_ARG_SET, &.{}),
        tagged,
        empty_tagged,
        record,
        try listOf(arena, c.GLOWCAP_ARG_STRUCT, &.{}),
        run,
        try listOf(arena, c.GLOWCAP_ARG_LIST, &.{}),
        nested,
    });
}

test "the callback receives the lifted projection's tree for every kind under both codecs" {
    for ([_]u32{ c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CODEC_CAPNP }) |codec| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var rig: Rig = undefined;
        try rig.open(codec, 0x44, "127.0.0.1:7982", .forward, null);
        defer rig.deinit();
        rig.tap.lift_copy = true;
        const args = try everyKind(arena_state.allocator());
        try expectFulfilled(try rig.send(args));
        try std.testing.expectEqual(@as(usize, 1), rig.tap.delivers);
        try std.testing.expectEqual(@as(?u32, 0), rig.tap.slots);
        try std.testing.expectEqual(@as(usize, 1), rig.probe.calls);
        try std.testing.expectEqual(args.len, rig.probe.arg_count);
        var nodes: usize = 0;
        try expectSameList(rig.probe.tree, rig.tap.lifted, false, &nodes);
        try std.testing.expectEqual(countNodes(args), nodes);
        // The views route: the arena holds the C spine and nothing else.
        try std.testing.expectEqual(countNodes(args) * @sizeOf(Arg), growth(&rig));
    }
}

test "the views projection admits exactly the depth the lift admits, and only the lift condemns its session" {
    // Pins the depth both routes admit, and that an over-deep tree leaves the
    // session open on the views walk and closed on the lift.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The innermost argument decides where the lift's two thresholds meet: a
    // leaf and an empty struct sit at the node's depth, an empty list one
    // level past it.
    const innermosts = [_]model.Argument{ .{ .void = {} }, .{ .list = &.{} }, .{ .@"struct" = &.{} } };
    for (innermosts) |innermost| {
        for (model.max_value_depth - 2..model.max_value_depth + 3) |containers| {
            // A fresh rig per case: a refused lift condemns its session.
            var rig: Rig = undefined;
            try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x48, "127.0.0.1:7983", .forward, null);
            defer rig.deinit();
            const nested = try fixtures.Nested.build(arena, containers, innermost);
            const viewed = shared.viewsToC(arena, nested.args());
            try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
            const lifted = cd.testing.projectLifted(rig.server(), rig.pair.b, arena, nested.args());
            if (viewed) |v| {
                var nodes: usize = 0;
                try expectSameList(v, try lifted, true, &nodes);
                try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
            } else |err| {
                try std.testing.expectEqual(error.NestingTooDeep, err);
                try std.testing.expectError(error.NestingTooDeep, lifted);
                try std.testing.expectEqual(@as(c_int, 0), cd.glowcap_host_session_is_open(rig.pair.b));
            }
        }
    }
}

test "a view whose count and cursor disagree refuses the lift with MalformedView and leaves the session open" {
    // The views projection takes no session, so its refusals are tested with
    // the walk in `views_to_c_test.zig`. The lift has a session to leave open.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rig: Rig = undefined;
    try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x4c, "127.0.0.1:7984", .forward, null);
    defer rig.deinit();
    for ([_]model.view.Args.Ctx{ fixtures.Lying.shorter, fixtures.Lying.longer }) |ctx| {
        const args = model.view.Args.fromBacking(ctx, &fixtures.Lying.table);
        try std.testing.expectError(error.MalformedView, cd.testing.projectLifted(rig.server(), rig.pair.b, arena, args));
        try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
    }
}

test "session validation refuses an over-deep deliver before the C bridge sees it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The server validates at three levels, the client sends five.
    var rig: Rig = undefined;
    try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x50, "127.0.0.1:7985", .forward, 3);
    defer rig.deinit();
    var tree = argInt(1);
    for (0..5) |_| tree = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{tree});
    var vow: u64 = undefined;
    try h.expectOk(cd.glowcap_host_session_send(rig.pair.a, &rig.target, "call", 4, &[_]Arg{tree}, 1, &vow));
    var frame: c.GlowcapManagedFrame = undefined;
    try h.expectOk(h.takeOutbound(rig.pair.a, &frame));
    defer c.glowcap_managed_frame_release(&frame);
    const borrowed: c.GlowcapFrame = .{ .bytes = frame.bytes, .len = frame.len, .shape = frame.shape };
    // Validation refuses the frame at the feed, so the bridge never runs.
    try std.testing.expect(cd.glowcap_host_session_feed(rig.pair.b, &borrowed) != c.GLOWCAP_OK);
    try std.testing.expectEqual(@as(usize, 0), rig.tap.delivers);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.calls);
}

test "a C host validates nesting well inside the depth the views projection reads" {
    const host = try h.newHost(0x54);
    defer _ = cd.glowcap_host_release(host);
    const limits = try cd.testing.configuredSessionLimits(host);
    try std.testing.expect(limits.max_nesting_depth <= model.max_value_depth);
}

test "a turn arena that refuses an allocation breaks the call before the callback and leaves the session open" {
    // Holds on either route, since the refusal lands in whichever projection runs.
    // `views_to_c_test.zig` sweeps the views walk's own allocation points.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shape = try spineShape(arena, argStr("last"));
    var refusals: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var rig: Rig = undefined;
        try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x58, "127.0.0.1:7986", .forward, null);
        defer rig.deinit();
        var borrow = try cd.embedding.borrowForAttachment(rig.server());
        defer borrow.release();
        const core = borrow.core();
        const live_before = try cd.testing.liveCapabilityCount(rig.server());
        var failing = FailingOnce.init(std.testing.allocator, fail_index);
        core.vat.turn_arena.deinit();
        core.vat.turn_arena = .init(failing.allocator());
        const settled = try rig.send(shape);
        const induced = failing.induced;
        // The allocator lives through its arena's teardown, before Host release.
        core.vat.turn_arena.deinit();
        core.vat.turn_arena = .init(std.testing.allocator);
        try std.testing.expect(failing.balanced());
        try std.testing.expectEqual(live_before, try cd.testing.liveCapabilityCount(rig.server()));
        if (rig.probe.calls == 0) {
            // The refusal landed before the callback: the call broke and the
            // session carried on.
            try std.testing.expect(induced);
            try std.testing.expect(settled.fired);
            try std.testing.expectEqual(.failed, settled.kind);
            try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
            refusals += 1;
        }
    }
    try std.testing.expect(refusals > 0);
}

test "a capability nested below the top level takes the lift and reaches the callback as a reference" {
    for ([_]u32{ c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CODEC_CAPNP }) |codec| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var rig: Rig = undefined;
        try rig.open(codec, 0x5c, "127.0.0.1:7987", .forward, null);
        defer rig.deinit();
        var local: c.GlowcapReference = undefined;
        try h.expectOk(cd.glowcap_host_spawn(rig.client(), probeBehavior, &rig.probe, null, &local));
        // A reference inside a list inside a struct.
        const list = try listOf(arena, c.GLOWCAP_ARG_LIST, &.{ argInt(1), h.argRef(local) });
        const record = try listOf(arena, c.GLOWCAP_ARG_STRUCT, &.{ argStr("held"), list });
        const live_before = try cd.testing.liveCapabilityCount(rig.server());
        try expectFulfilled(try rig.send(&.{record}));
        try std.testing.expectEqual(@as(?u32, 1), rig.tap.slots);
        try std.testing.expectEqual(@as(usize, 1), rig.probe.calls);
        const held = rig.probe.tree[0].items.?[1].items.?[1];
        try std.testing.expectEqual(c.GLOWCAP_ARG_REFERENCE, held.kind);
        // The lift's lease holds the capability while the callback runs.
        try std.testing.expect(rig.probe.live > live_before);
    }
}

test "a pipelined capability-free deliver carries its count through the queue and takes the views route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rig: Rig = undefined;
    try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x60, "127.0.0.1:7988", .forward, null);
    defer rig.deinit();
    rig.tap.lift_copy = true;
    // "make" answers with the tap, and the client sends to that answer before
    // any frame moves, so the deliver rides the answer's position.
    var kitchen = behaviors.KitchenCtx{ .widget_local_ref = rig.tap_local };
    var kitchen_local: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_session_publish(rig.pair.b, "kitchen", 7, behaviors.kitchenBehavior, &kitchen, null, &kitchen_local));
    var fetched = h.CapturedSettle{};
    var fetched_vow: u64 = undefined;
    try h.expectOk(cd.glowcap_host_session_fetch(rig.pair.a, "kitchen", 7, &fetched_vow));
    rig.watches.add(rig.client(), fetched_vow, &fetched);
    try h.pump(&rig.hosts, &.{rig.pair}, &rig.dials, &rig.watches);
    const kitchen_ref = try fetched.requireRef();
    var make_vow: u64 = undefined;
    try h.expectOk(cd.glowcap_host_session_send(rig.pair.a, &kitchen_ref, "make", 4, null, 0, &make_vow));
    const shape = try spineShape(arena, argStr("last"));
    var call_vow: u64 = undefined;
    try h.expectOk(cd.glowcap_host_vow_send(rig.client(), make_vow, "call", 4, shape.ptr, shape.len, &call_vow));
    var settled = h.CapturedSettle{};
    rig.watches.add(rig.client(), call_vow, &settled);
    try h.pump(&rig.hosts, &.{rig.pair}, &rig.dials, &rig.watches);
    try expectFulfilled(settled);
    // The count survives the answer queue, so the deliver is capability-free.
    try std.testing.expectEqual(@as(usize, 1), rig.tap.delivers);
    try std.testing.expectEqual(@as(?u32, 0), rig.tap.slots);
    var nodes: usize = 0;
    try expectSameList(rig.probe.tree, rig.tap.lifted, false, &nodes);
    try std.testing.expectEqual(countNodes(shape), nodes);
}

test "a reference on the views route breaks the turn without calling the callback or retaining it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rig: Rig = undefined;
    try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x64, "127.0.0.1:7989", .forward_claimed_free, null);
    defer rig.deinit();
    var local: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_spawn(rig.client(), probeBehavior, &rig.probe, null, &local));
    const live_before = try cd.testing.liveCapabilityCount(rig.server());
    const record = try listOf(arena, c.GLOWCAP_ARG_STRUCT, &.{ argStr("held"), h.argRef(local) });
    const settled = try rig.send(&.{record});
    // The delivery claims no capability while its arguments carry one: the
    // projection refuses, and the turn breaks with that refusal.
    try std.testing.expectEqual(@as(usize, 1), rig.tap.delivers);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.calls);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(.failed, settled.kind);
    try std.testing.expect(std.mem.find(u8, settled.msg[0..settled.msg_len], "UnsupportedValue") != null);
    try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
    try std.testing.expectEqual(live_before, try cd.testing.liveCapabilityCount(rig.server()));
}

test "a deliver with no arguments reaches the callback with a null array and length zero" {
    var rig: Rig = undefined;
    try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x68, "127.0.0.1:7990", .forward, null);
    defer rig.deinit();
    try expectFulfilled(try rig.send(&.{}));
    try std.testing.expectEqual(@as(?u32, 0), rig.tap.slots);
    try std.testing.expectEqual(@as(usize, 1), rig.probe.calls);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.arg_count);
    try std.testing.expect(rig.probe.args_null);
    try std.testing.expectEqual(@as(usize, 0), growth(&rig));
}

test "a deliver with no verb reaches the callback with a null verb and length zero" {
    var rig: Rig = undefined;
    try rig.open(c.GLOWCAP_CODEC_SYRUP, 0x6c, "127.0.0.1:7991", .forward, null);
    defer rig.deinit();
    try expectFulfilled(try rig.sendVerb(null, &.{argInt(7)}));
    try std.testing.expectEqual(@as(?u32, 0), rig.tap.slots);
    try std.testing.expectEqual(@as(usize, 1), rig.probe.calls);
    try std.testing.expect(rig.probe.verb_null);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.verb_len);
    try std.testing.expectEqual(@as(usize, 1), rig.probe.arg_count);
}
