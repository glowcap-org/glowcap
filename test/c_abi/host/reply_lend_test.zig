//! A served C reply reaches the answer store through one copy of its byte
//! leaves: the bridge lends them from the consumer's reply storage and the
//! store copies them before any behavior callback runs. A tap published in front
//! of the bridge measures the turn arena the reply takes, and a plain
//! publication carries the cases that need no measure.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const shared = @import("c_abi_shared");
const glowcap = @import("glowcap");
const actors = glowcap.actors;
const model = glowcap.ocapn.model;
const h = @import("harness.zig");
const behaviors = @import("behaviors.zig");
const args_support = @import("../../support/c_abi_args.zig");
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;

const Arg = c.GlowcapArgument;

const big_bytes = 256 * 1024;

/// The consumer's reply storage and the objects a reply names. Every reply
/// is written into storage this struct owns, the way a binding's keep slot
/// does, and the rich reply reuses one text buffer so a reader that held a
/// pointer past the next call would see the next reply.
const Reply = struct {
    calls: usize = 0,
    rich_calls: usize = 0,
    big: []const u8 = &.{},
    text: [slot_bytes * 12]u8 = undefined,
    words: [3]i64 = undefined,
    expected: [2][768]u8 = undefined,
    expected_len: [2]usize = .{ 0, 0 },
    widget: c.GlowcapReference = .{ .id = 0 },
    forward_to: c.GlowcapReference = .{ .id = 0 },
    items: [3]Arg = undefined,
    fields: [2]Arg = undefined,
    rich: [11]Arg = undefined,
    set_items: [1]Arg = undefined,
    tag_items: [1]Arg = undefined,
    record: [2]Arg = undefined,
    nest_outer: [1]Arg = undefined,
    nest_inner: [1]Arg = undefined,
    pair: [2]Arg = undefined,

    /// Reply `index` (0-based) as its writer saw it.
    fn expectedText(self: *const Reply, index: usize) []const u8 {
        return self.expected[index][0..self.expected_len[index]];
    }
};

const slot_bytes = 24;

/// Write `label-<call>` into slot `slot` of the reply's one text buffer.
fn put(reply: *Reply, slot: usize, comptime label: []const u8) []const u8 {
    const dst = reply.text[slot * slot_bytes ..][0..slot_bytes];
    return std.mem.print(dst, label ++ "-{d}", .{reply.rich_calls}) catch unreachable;
}

fn container(kind: u32, items: []const Arg) Arg {
    var arg = h.argBase();
    arg.kind = kind;
    arg.items = items.ptr;
    arg.items_len = items.len;
    return arg;
}

fn leaf(kind: u32, bytes: []const u8) Arg {
    var arg = args_support.argBytes(bytes);
    arg.kind = kind;
    return arg;
}

/// Record how the reply reads as it is written, before the next call
/// rewrites the buffers it points into.
fn finish(reply: *Reply, arg: Arg) Arg {
    var writer = std.Io.Writer.fixed(&reply.expected[reply.rich_calls - 1]);
    args_support.render(&writer, arg) catch unreachable;
    reply.expected_len[reply.rich_calls - 1] = writer.buffered().len;
    return arg;
}

/// One reply holding every leaf kind a reply can carry, one nesting level
/// deep, with every byte slice pointing into the reused text buffer.
fn richReply(reply: *Reply) Arg {
    reply.rich_calls += 1;
    std.debug.assert(reply.rich_calls <= reply.expected.len);
    const n: i64 = @intCast(reply.rich_calls);
    reply.words = .{ n, n * 10, -n };
    const tag = put(reply, 4, "tag");
    reply.tag_items = .{h.argStr(put(reply, 5, "inner"))};
    var tagged = container(c.GLOWCAP_ARG_TAGGED, &reply.tag_items);
    tagged.bytes = tag.ptr;
    tagged.bytes_len = tag.len;
    reply.record = .{ h.argStr(put(reply, 6, "key")), h.argStr(put(reply, 7, "val")) };
    const digits = std.mem.print(reply.text[8 * slot_bytes ..][0..slot_bytes], "1234567890123456789{d}", .{n}) catch unreachable;
    var big = leaf(c.GLOWCAP_ARG_BIG_INTEGER, digits);
    big.boolean = @intFromBool(n == 2);
    const run = leaf(c.GLOWCAP_ARG_INTEGERS, std.mem.sliceAsBytes(&reply.words));
    reply.set_items = .{h.argStr(put(reply, 11, "member"))};
    reply.nest_inner = .{h.argStr(put(reply, 10, "deep"))};
    reply.nest_outer = .{container(c.GLOWCAP_ARG_LIST, &reply.nest_inner)};
    reply.rich = .{
        args_support.argBytes(put(reply, 0, "bytes")),
        h.argStr(put(reply, 1, "string")),
        leaf(c.GLOWCAP_ARG_SYMBOL, put(reply, 2, "symbol")),
        leaf(c.GLOWCAP_ARG_KEYWORD, put(reply, 3, "keyword")),
        tagged,
        container(c.GLOWCAP_ARG_STRUCT, &reply.record),
        big,
        run,
        leaf(c.GLOWCAP_ARG_ERROR, put(reply, 9, "error")),
        container(c.GLOWCAP_ARG_LIST, &reply.nest_outer),
        container(c.GLOWCAP_ARG_SET, &reply.set_items),
    };
    return finish(reply, container(c.GLOWCAP_ARG_LIST, &reply.rich));
}

fn replyBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: ?[*]const u8,
    verb_len: usize,
    _: ?[*]const Arg,
    _: usize,
    out: *Arg,
) callconv(.c) i32 {
    const reply: *Reply = @ptrCast(@alignCast(ctx.?));
    const name = (verb orelse return shared.GLOWCAP_ERR_BROKEN)[0..verb_len];
    reply.calls += 1;
    if (std.mem.eql(u8, name, "big")) {
        out.* = args_support.argBytes(reply.big);
    } else if (std.mem.eql(u8, name, "rich")) {
        out.* = richReply(reply);
    } else if (std.mem.eql(u8, name, "spine")) {
        reply.fields = .{ h.argStr("key"), h.argStr("value") };
        reply.items = .{ h.argStr("first"), container(c.GLOWCAP_ARG_STRUCT, &reply.fields), args_support.argBytes("third") };
        out.* = container(c.GLOWCAP_ARG_LIST, &reply.items);
    } else if (std.mem.eql(u8, name, "ref")) {
        out.* = h.argRef(reply.widget);
    } else if (std.mem.eql(u8, name, "ref-bytes")) {
        reply.rich_calls += 1;
        reply.pair = .{ h.argRef(reply.widget), args_support.argBytes(put(reply, 0, "bytes")) };
        out.* = finish(reply, container(c.GLOWCAP_ARG_LIST, &reply.pair));
    } else if (std.mem.eql(u8, name, "bad-big")) {
        // A byte leaf converts first, then a big integer with a leading zero
        // is refused, so the refusal lands after a leaf was lent.
        reply.pair = .{ args_support.argBytes("lent before the refusal"), leaf(c.GLOWCAP_ARG_BIG_INTEGER, "007") };
        out.* = container(c.GLOWCAP_ARG_LIST, &reply.pair);
    } else if (std.mem.eql(u8, name, "bad-struct")) {
        // A struct holding a key and no value is refused after the leaf.
        reply.fields[0] = h.argStr("key");
        reply.pair = .{ args_support.argBytes("lent before the refusal"), container(c.GLOWCAP_ARG_STRUCT, reply.fields[0..1]) };
        out.* = container(c.GLOWCAP_ARG_LIST, &reply.pair);
    } else if (std.mem.eql(u8, name, "forward")) {
        const code = cd.glowcap_host_turn_forward(turn, &reply.forward_to, "poke", 4, null, 0, out);
        // The forwarded answer rides the forwarded vow, so what this reply
        // holds is not read. Poison it to prove that.
        out.kind = 0xdead;
        out.bytes = @ptrFromInt(8);
        out.bytes_len = 1 << 20;
        return code;
    } else {
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    return c.GLOWCAP_OK;
}

/// A hosted object in front of the bridge. It hands the bridge a counting
/// turn arena, optionally one that refuses its `fail_index`th allocation.
const Tap = struct {
    bridge: actors.HostedActor,
    fail_index: usize = std.math.maxInt(usize),
    counter: FailingOnce = undefined,
    arena_bytes: usize = 0,
    arena_allocs: usize = 0,
    delivers: usize = 0,

    fn handle(erased: *anyopaque, turn: *actors.Turn, msg: actors.Delivery) actors.HostedActor.Result {
        const self: *Tap = @ptrCast(@alignCast(erased));
        self.delivers += 1;
        const outer = turn.arena;
        self.counter = FailingOnce.init(outer, self.fail_index);
        turn.arena = self.counter.allocator();
        defer turn.arena = outer;
        const result = self.bridge.handle(self.bridge.ctx, turn, msg);
        self.arena_bytes = self.counter.allocated_bytes;
        self.arena_allocs = self.counter.alloc_index;
        return result;
    }

    fn free(erased: *anyopaque) void {
        const self: *Tap = @ptrCast(@alignCast(erased));
        self.bridge.discard();
        std.testing.allocator.destroy(self);
    }
};

/// A Zig hosted object that makes two near calls into the C behavior, which
/// the C ABI has no verb for: each runs the behavior in a `.local` turn, and
/// the second rewrites the buffer the first reply pointed into. The first
/// value is read after the second call.
const Caller = struct {
    target: actors.Ref,
    first_intact: bool = false,
    second_intact: bool = false,

    fn text(arg: model.Argument) ?[]const u8 {
        return switch (arg) {
            .bytes, .string, .symbol, .keyword => |leaf_text| leaf_text,
            else => null,
        };
    }

    fn leafIs(arg: model.Argument, comptime label: []const u8, n: usize) bool {
        var buf: [32]u8 = undefined;
        const want = std.mem.print(&buf, label ++ "-{d}", .{n}) catch return false;
        return std.mem.eql(u8, text(arg) orelse return false, want);
    }

    /// The first four leaves of a rich reply, which are the lent ones.
    fn intact(reply: model.Argument, n: usize) bool {
        const items = switch (reply) {
            .list => |list| list,
            else => return false,
        };
        return items.len == 11 and leafIs(items[0], "bytes", n) and leafIs(items[1], "string", n) and
            leafIs(items[2], "symbol", n) and leafIs(items[3], "keyword", n);
    }

    fn run(self: *Caller, turn: *actors.Turn) anyerror!model.Argument {
        const first = try turn.near(self.target, .{ .verb = "rich", .args = &.{} });
        const second = try turn.near(self.target, .{ .verb = "rich", .args = &.{} });
        self.first_intact = intact(first, 1);
        self.second_intact = intact(second, 2);
        return .{ .void = {} };
    }

    fn handle(erased: *anyopaque, turn: *actors.Turn, _: actors.Delivery) actors.HostedActor.Result {
        const self: *Caller = @ptrCast(@alignCast(erased));
        return actors.HostedActor.Result.fromResult(self.run(turn));
    }

    fn free(erased: *anyopaque) void {
        const self: *Caller = @ptrCast(@alignCast(erased));
        std.testing.allocator.destroy(self);
    }
};

/// A Host whose frame cap admits the largest reply here, where the
/// harness's own cap is a few kilobytes.
fn newHost(seed_byte: u8) !?*cd.GlowcapHost {
    var host: ?*cd.GlowcapHost = null;
    const seed = h.hostSeed(seed_byte);
    try h.expectOk(cd.glowcap_host_new(&seed, seed.len, 2 * big_bytes, 1, c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CAPTP_V1_0, c.GLOWCAP_FEATURE_FULL, 0, 1, &host));
    return host;
}

const Rig = struct {
    hosts: [2]?*cd.GlowcapHost = undefined,
    dials: h.Dials = .{},
    watches: h.Watches = .{},
    pair: h.Pair = undefined,
    reply: Reply = .{},
    counter: behaviors.Counter = .{},
    tap: *Tap = undefined,
    plain_target: c.GlowcapReference = undefined,
    tap_target: c.GlowcapReference = undefined,
    caller: *Caller = undefined,
    caller_target: c.GlowcapReference = undefined,

    fn open(self: *Rig, seed: u8, designator: []const u8) !void {
        self.* = .{};
        const dialer = try newHost(seed);
        const acceptor = try newHost(seed + 1);
        self.hosts = .{ dialer, acceptor };
        self.pair = try h.openPair(&self.hosts, dialer, acceptor, designator, &self.dials, &self.watches);
        const big = try std.testing.allocator.alloc(u8, big_bytes);
        @memset(big, 0x5a);
        self.reply.big = big;
        try h.expectOk(cd.glowcap_host_session_spawn(self.pair.b, behaviors.widgetBehavior, &self.counter, null, &self.reply.widget));
        try h.expectOk(cd.glowcap_host_session_spawn(self.pair.b, behaviors.widgetBehavior, &self.counter, null, &self.reply.forward_to));
        var plain_local: c.GlowcapReference = undefined;
        try h.expectOk(cd.glowcap_host_session_publish(self.pair.b, "plain", 5, replyBehavior, &self.reply, null, &plain_local));
        const bridge = try cd.testing.hostedBridge(std.testing.allocator, replyBehavior, &self.reply, null);
        self.tap = std.testing.allocator.create(Tap) catch |err| {
            bridge.discard();
            return err;
        };
        self.tap.* = .{ .bridge = bridge };
        _ = try cd.testing.publishHosted(self.pair.b, "tap", .{ .ctx = self.tap, .handle = Tap.handle, .free = Tap.free });
        try h.expectOk(cd.glowcap_host_publish(self.hosts[1], "near", 4, replyBehavior, &self.reply, null));
        self.caller = try std.testing.allocator.create(Caller);
        {
            var borrow = try cd.embedding.borrowForAttachment(self.hosts[1]);
            defer borrow.release();
            const host = borrow.core();
            self.caller.* = .{ .target = host.publications.get(host.publication_secret, "near").?.actor };
        }
        _ = try cd.testing.publishHosted(self.pair.b, "caller", .{ .ctx = self.caller, .handle = Caller.handle, .free = Caller.free });
        self.caller_target = try self.fetch("caller");
        self.plain_target = try self.fetch("plain");
        self.tap_target = try self.fetch("tap");
    }

    fn deinit(self: *Rig) void {
        for (self.hosts) |host| _ = cd.glowcap_host_release(host);
        std.testing.allocator.free(self.reply.big);
    }

    fn server(self: *Rig) ?*cd.GlowcapHost {
        return self.hosts[1];
    }

    fn fetch(self: *Rig, name: []const u8) !c.GlowcapReference {
        var fetched = h.CapturedSettle{};
        var ticket: u64 = undefined;
        try h.expectOk(cd.glowcap_host_session_fetch(self.pair.a, name.ptr, name.len, &ticket));
        self.watches.add(self.hosts[0], ticket, &fetched);
        try h.pump(&self.hosts, &.{self.pair}, &self.dials, &self.watches);
        return fetched.requireRef();
    }

    /// Send without pumping, so several calls can ride one burst.
    fn start(self: *Rig, target: *const c.GlowcapReference, verb: []const u8, settled: *h.CapturedSettle) !void {
        var vow: u64 = undefined;
        try h.expectOk(cd.glowcap_host_session_send(self.pair.a, target, verb.ptr, verb.len, null, 0, &vow));
        self.watches.add(self.hosts[0], vow, settled);
    }

    fn pump(self: *Rig) !void {
        try h.pump(&self.hosts, &.{self.pair}, &self.dials, &self.watches);
    }

    /// Hand every frame the dialer holds to the acceptor in one
    /// `feed_bytes` call, and return how many behavior callbacks that one
    /// call ran.
    fn feedOnce(self: *Rig) !usize {
        var stream: [8192]u8 = undefined;
        var len: usize = 0;
        while (true) {
            var frame: c.GlowcapManagedFrame = undefined;
            var prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
            var prefix_len: usize = undefined;
            const rc = cd.glowcap_host_session_take_outbound(self.pair.a, &frame, &prefix, prefix.len, &prefix_len);
            if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
            try h.expectOk(rc);
            defer c.glowcap_managed_frame_release(&frame);
            @memcpy(stream[len..][0..prefix_len], prefix[0..prefix_len]);
            len += prefix_len;
            @memcpy(stream[len..][0..frame.len], frame.bytes.?[0..frame.len]);
            len += frame.len;
        }
        const before = self.reply.calls;
        try h.expectOk(cd.glowcap_host_session_feed_bytes(self.pair.b, &stream, len));
        return self.reply.calls - before;
    }

    fn call(self: *Rig, target: *const c.GlowcapReference, verb: []const u8) !h.CapturedSettle {
        var settled = h.CapturedSettle{};
        try self.start(target, verb, &settled);
        try self.pump();
        return settled;
    }
};

/// A retained application reference to the object published as `name` on a
/// local host, returned with `glowcap_host_ref_release`.
fn retainLocal(raw: ?*cd.GlowcapHost, name: []const u8) !c.GlowcapReference {
    var borrow = try cd.embedding.borrowForAttachment(raw);
    defer borrow.release();
    const host = borrow.core();
    const held = try host.retainLocalCapability(host.publications.get(host.publication_secret, name).?.actor);
    return .{ .id = held.raw() };
}

/// Send each verb to `target` on a local host and write every settled value
/// into the matching `out` slot as `render` writes it. `calls_at_first_settle`
/// receives the callback count when the first settlement is popped.
fn settleLocal(raw: ?*cd.GlowcapHost, target: *const c.GlowcapReference, verbs: []const []const u8, out: [][]u8, calls: *const usize, calls_at_first_settle: *usize) !void {
    var tickets: [2]u64 = undefined;
    for (verbs, 0..) |verb, i| try h.expectOk(cd.glowcap_host_send(raw, target, verb.ptr, verb.len, null, 0, &tickets[i]));
    var seen: usize = 0;
    var action: cd.GlowcapHostAction = undefined;
    while (seen < verbs.len) {
        try h.expectOk(cd.glowcap_host_next_action(raw, &action));
        if (action.kind != cd.GLOWCAP_HOST_ACTION_SETTLE) continue;
        if (seen == 0) calls_at_first_settle.* = calls.*;
        const index: usize = if (action.ticket == tickets[0]) 0 else 1;
        var writer = std.Io.Writer.fixed(out[index]);
        try args_support.render(&writer, action.value);
        out[index] = writer.buffered();
        seen += 1;
    }
    for (tickets[0..verbs.len]) |ticket| try h.expectOk(cd.glowcap_host_vow_release(raw, ticket));
}

test "a served reply's turn arena holds no copy of the leaf and the peer receives the whole reply" {
    var rig: Rig = undefined;
    try rig.open(0x80, "127.0.0.1:7992");
    defer rig.deinit();
    const settled = try rig.call(&rig.tap_target, "big");
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqual(c.GLOWCAP_ARG_BYTES, settled.value.kind);
    try std.testing.expectEqual(big_bytes, settled.value.bytes_len);
    try std.testing.expectEqual(@as(usize, 1), rig.tap.delivers);
    // The turn arena holds the reply's own tree and nothing the size of the leaf.
    try std.testing.expect(rig.tap.arena_bytes < 4096);
}

test "two rich replies written into one buffer by one feed both reach the peer field by field" {
    var rig: Rig = undefined;
    try rig.open(0x84, "127.0.0.1:7993");
    defer rig.deinit();
    var first = h.CapturedSettle{};
    var second = h.CapturedSettle{};
    try rig.start(&rig.plain_target, "rich", &first);
    try rig.start(&rig.plain_target, "rich", &second);
    // Both delivers ride one feed_bytes call, so the second callback runs in
    // the host call that ran the first and rewrites the buffer the first
    // reply pointed into.
    try std.testing.expectEqual(@as(usize, 2), try rig.feedOnce());
    try rig.pump();
    try std.testing.expectEqual(@as(usize, 2), rig.reply.rich_calls);
    const one = rig.reply.expectedText(0);
    const two = rig.reply.expectedText(1);
    try std.testing.expect(!std.mem.eql(u8, one, two));
    try std.testing.expect(std.mem.find(u8, one, "bytes-1") != null and std.mem.find(u8, two, "bytes-2") != null);
    try std.testing.expectEqualStrings(one, first.rendered[0..first.rendered_len]);
    try std.testing.expectEqualStrings(two, second.rendered[0..second.rendered_len]);
}

test "a reply that carries a reference still delivers it" {
    var rig: Rig = undefined;
    try rig.open(0x88, "127.0.0.1:7994");
    defer rig.deinit();
    const settled = try rig.call(&rig.plain_target, "ref");
    _ = try settled.requireRef();
    const live = try cd.testing.liveCapabilityCount(rig.server());
    try std.testing.expect(live > 0);
}

test "a reply holding a reference and a lent byte leaf delivers both" {
    var rig: Rig = undefined;
    try rig.open(0x98, "127.0.0.1:7997");
    defer rig.deinit();
    const settled = try rig.call(&rig.plain_target, "ref-bytes");
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings(rig.reply.expectedText(0), settled.rendered[0..settled.rendered_len]);
    try std.testing.expectEqualStrings("[r x\"bytes-1\"]", settled.rendered[0..settled.rendered_len]);
}

test "a tell to a behavior that writes a reply succeeds and retains nothing" {
    var rig: Rig = undefined;
    try rig.open(0x9c, "127.0.0.1:7998");
    defer rig.deinit();
    const live_before = try cd.testing.liveCapabilityCount(rig.server());
    try h.expectOk(cd.glowcap_host_session_tell(rig.pair.a, &rig.tap_target, "big", 3, null, 0));
    try rig.pump();
    try std.testing.expectEqual(@as(usize, 1), rig.reply.calls);
    try std.testing.expectEqual(@as(usize, 1), rig.tap.delivers);
    // No answer position reads the reply, and the lent leaf is never copied.
    try std.testing.expect(rig.tap.arena_bytes < 4096);
    try std.testing.expectEqual(live_before, try cd.testing.liveCapabilityCount(rig.server()));
    try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
}

test "a forwarded served turn reads nothing from its out_reply and settles on the forwarded vow" {
    var rig: Rig = undefined;
    try rig.open(0x8c, "127.0.0.1:7995");
    defer rig.deinit();
    const settled = try rig.call(&rig.plain_target, "forward");
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), rig.counter.pokes);
    try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
}

test "a forwarded eventual turn reads nothing from its out_reply and settles on the forwarded vow" {
    const raw = try h.newHost(0xa0);
    defer _ = cd.glowcap_host_release(raw);
    var reply = Reply{};
    var counter = behaviors.Counter{};
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, replyBehavior, &reply, null));
    try h.expectOk(cd.glowcap_host_publish(raw, "widget", 6, behaviors.widgetBehavior, &counter, null));
    var target = try retainLocal(raw, "local");
    reply.forward_to = try retainLocal(raw, "widget");
    var storage: [768]u8 = undefined;
    var out = [_][]u8{storage[0..]};
    var at_first: usize = 0;
    try settleLocal(raw, &target, &.{"forward"}, &out, &reply.calls, &at_first);
    try std.testing.expectEqualStrings("s\"poked over the C surface\"", out[0]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);
    try h.expectOk(cd.glowcap_host_ref_release(raw, &target, 1));
    try h.expectOk(cd.glowcap_host_ref_release(raw, &reply.forward_to, 1));
}

test "an eventual turn's reply copies its leaves, so they survive the behavior overwriting its buffer" {
    // An eventual caller keeps the value past the next callback. The first
    // settlement is read only after the second callback has rewritten the
    // buffer, which the callback count asserts, so a lent route would show the
    // second reply in the first.
    const raw = try h.newHost(0x90);
    defer _ = cd.glowcap_host_release(raw);
    var reply = Reply{};
    try h.expectOk(cd.glowcap_host_publish(raw, "local", 5, replyBehavior, &reply, null));
    var target = try retainLocal(raw, "local");
    var first: [768]u8 = undefined;
    var second: [768]u8 = undefined;
    var out = [_][]u8{ first[0..], second[0..] };
    var at_first: usize = 0;
    try settleLocal(raw, &target, &.{ "rich", "rich" }, &out, &reply.calls, &at_first);
    try std.testing.expectEqual(@as(usize, 2), at_first);
    try std.testing.expectEqualStrings(reply.expectedText(0), out[0]);
    try std.testing.expectEqualStrings(reply.expectedText(1), out[1]);
    try h.expectOk(cd.glowcap_host_ref_release(raw, &target, 1));
}

test "a near call into a C behavior copies its leaves, so the first reply survives the second call" {
    var rig: Rig = undefined;
    try rig.open(0xa4, "127.0.0.1:7999");
    defer rig.deinit();
    const settled = try rig.call(&rig.caller_target, "go");
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqual(@as(usize, 2), rig.reply.rich_calls);
    try std.testing.expect(rig.caller.first_intact);
    try std.testing.expect(rig.caller.second_intact);
}

test "a reply refused in mid-conversion breaks the answer, retains nothing, and the next call succeeds" {
    var rig: Rig = undefined;
    try rig.open(0xa8, "127.0.0.1:8000");
    defer rig.deinit();
    const live_before = try cd.testing.liveCapabilityCount(rig.server());
    for ([_][]const u8{ "bad-big", "bad-struct" }) |verb| {
        const refused = try rig.call(&rig.plain_target, verb);
        try std.testing.expect(refused.fired);
        try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_BREAK, refused.kind);
        try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
        try std.testing.expectEqual(live_before, try cd.testing.liveCapabilityCount(rig.server()));
        const next = try rig.call(&rig.plain_target, "rich");
        try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, next.kind);
        try std.testing.expectEqualStrings(rig.reply.expectedText(rig.reply.rich_calls - 1), next.rendered[0..next.rendered_len]);
    }
}

test "a tell that writes a reply and a call that rewrites its buffer in one feed leave the call's reply whole" {
    var rig: Rig = undefined;
    try rig.open(0xac, "127.0.0.1:8001");
    defer rig.deinit();
    try h.expectOk(cd.glowcap_host_session_tell(rig.pair.a, &rig.plain_target, "rich", 4, null, 0));
    var settled = h.CapturedSettle{};
    try rig.start(&rig.plain_target, "rich", &settled);
    try std.testing.expectEqual(@as(usize, 2), try rig.feedOnce());
    try rig.pump();
    try std.testing.expectEqual(@as(usize, 2), rig.reply.rich_calls);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings(rig.reply.expectedText(1), settled.rendered[0..settled.rendered_len]);
}

test "an allocation refusal at every index of the reply conversion breaks the answer and retains nothing" {
    // The spine reply is a list holding a struct, and the bridge allocates one
    // array per container: the list's three items and the struct's one entry.
    // Its leaves are lent and allocate nothing, so two refusal points exist.
    const containers = 2;
    var refusals: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < containers + 2) : (fail_index += 1) {
        var rig: Rig = undefined;
        try rig.open(0x94, "127.0.0.1:7996");
        defer rig.deinit();
        rig.tap.fail_index = fail_index;
        const live_before = try cd.testing.liveCapabilityCount(rig.server());
        const settled = try rig.call(&rig.tap_target, "spine");
        try std.testing.expect(settled.fired);
        try std.testing.expectEqual(live_before, try cd.testing.liveCapabilityCount(rig.server()));
        if (fail_index < containers) {
            // The refusal landed before commit: the call broke and the session carried on.
            try std.testing.expect(rig.tap.counter.induced);
            try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_BREAK, settled.kind);
            try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
            refusals += 1;
        } else {
            try std.testing.expect(!rig.tap.counter.induced);
            try std.testing.expectEqual(containers, rig.tap.arena_allocs);
            try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
            try std.testing.expectEqual(@as(usize, 3), settled.value.items_len);
        }
    }
    try std.testing.expectEqual(@as(usize, containers), refusals);
}
