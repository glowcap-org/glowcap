//! What a far listener's value borrows: a wire resolve lends its byte leaves
//! from the event's frame, `settleFar` hands a tree that owns its bytes, and
//! the settle arena keeps a tree's spines across nested serves.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Delivery = actors.Delivery;
const cross_peer = @import("../../support/cross_peer.zig");
const promise_capture = @import("../../support/capture.zig");
const CapturedBytes = promise_capture.CapturedBytes;
const CapturedString = promise_capture.CapturedString;

/// Replies to every call with `reply`.
const Replier = struct {
    reply: model.Argument,

    pub fn handle(self: *Replier, _: *Turn, _: Delivery) !model.Argument {
        return self.reply;
    }
};

/// What `withResolveEvent` hands its `run`: the caller's Vat and Port, the
/// vow of the call, the resolve event the caller has not yet served, and the
/// allocator under the caller's Vat, so a test can refuse its next allocation.
const Fixture = struct {
    vat: *actors.Vat,
    port: *actors.Port,
    vow: actors.Vow,
    event: *engine.Event,
    failing: *std.testing.FailingAllocator,
};

/// Runs one call whose handler replies `reply` across a pair built by
/// `pair_fn`, then hands `run` a `Fixture` holding the resolve event.
fn withResolveEvent(
    comptime pair_fn: anytype,
    reply: model.Argument,
    context: anytype,
    comptime run: fn (@TypeOf(context), Fixture) anyerror!void,
) !void {
    const allocator = std.testing.allocator;
    var pair = try pair_fn(allocator);
    defer pair.deinit();

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, &pair.p1);
    defer host_port.deinit(&host_vat);
    const replier = try host_vat.spawn(Replier, .{ .reply = reply });
    try host_port.bindExport(&host_vat, replier, 5);
    try pair.p1.exportObject(5);

    try pair.p2.importObject(5);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var caller_vat = actors.Vat.init(failing.allocator());
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, &pair.p2);
    defer caller_port.deinit(&caller_vat);
    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "ask" });

    try cross_peer.pumpAll(&pair.p2, &pair.p1);
    while (pair.p1.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    try cross_peer.pumpAll(&pair.p1, &pair.p2);

    var resolve: ?engine.Event = null;
    defer if (resolve) |*held| held.deinit();
    while (pair.p2.pollEvent()) |event| {
        if (event.kind() == .resolve and resolve == null) {
            resolve = event;
        } else {
            var other = event;
            other.deinit();
        }
    }
    try run(context, .{ .vat = &caller_vat, .port = &caller_port, .vow = vow, .event = &resolve.?, .failing = &failing });
}

/// Records, inside the listener call, every byte leaf the value holds and
/// whether each one lies inside `frame`. The value is borrowed for the call,
/// so the contents are copied here, each followed by `|`.
const Probe = struct {
    frame: []const u8 = &.{},
    fired: usize = 0,
    leaves: usize = 0,
    all_inside: bool = true,
    text: [512]u8 = undefined,
    text_len: usize = 0,

    fn note(self: *Probe, leaf: []const u8) void {
        const start = @intFromPtr(self.frame.ptr);
        const at = @intFromPtr(leaf.ptr);
        if (at < start or at + leaf.len > start + self.frame.len) self.all_inside = false;
        self.leaves += 1;
        @memcpy(self.text[self.text_len..][0..leaf.len], leaf);
        self.text_len += leaf.len;
        self.text[self.text_len] = '|';
        self.text_len += 1;
    }

    fn walk(self: *Probe, value: model.Argument) void {
        switch (value) {
            .string => |v| self.note(v),
            .bytes => |v| self.note(v),
            .symbol => |v| self.note(v),
            .keyword => |v| self.note(v),
            .@"error" => |v| self.note(v.message),
            .big_integer => |v| self.note(v.digits),
            .list, .set => |items| for (items) |item| self.walk(item),
            .tagged => |tagged| {
                self.note(tagged.tag);
                for (tagged.value) |item| self.walk(item);
            },
            .@"struct" => |entries| for (entries) |entry| {
                self.note(entry.key);
                self.walk(entry.value);
            },
            .integer, .boolean, .void, .float64, .reference, .handoff => {},
        }
    }

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Probe = @ptrCast(@alignCast(ctx.?));
        self.fired += 1;
        self.walk(resolution.fulfilled);
    }

    fn expectText(self: *const Probe, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, self.text[0..self.text_len]);
    }
};

/// One of every byte-leaf kind, nested in a list, a tagged value, and a
/// struct. Eleven leaves, in walk order.
fn compoundReply() model.Argument {
    const tagged_value = comptime [_]model.Argument{.{ .bytes = "tagged-value" }};
    const entries = comptime [_]model.StructEntry{.{ .key = "entry-key", .value = .{ .bytes = "entry-value" } }};
    const nested = comptime [_]model.Argument{.{ .string = "nested" }};
    const items = comptime [_]model.Argument{
        .{ .string = "string" },
        .{ .bytes = "bytes" },
        .{ .symbol = "symbol" },
        .{ .keyword = "keyword" },
        .{ .@"error" = .{ .message = "error-message" } },
        .{ .big_integer = .{ .negative = false, .digits = "123456789012345678901234567890" } },
        .{ .tagged = .{ .tag = "tag", .value = &tagged_value } },
        .{ .@"struct" = &entries },
        .{ .list = &nested },
    };
    return .{ .list = &items };
}

const compound_leaves = "string|bytes|symbol|keyword|error-message|123456789012345678901234567890|tag|tagged-value|entry-key|entry-value|nested|";

test "a wire fulfillment lends every byte-leaf kind from the event's frame on both codecs" {
    const Run = struct {
        fn run(probe: *Probe, fixture: Fixture) !void {
            probe.frame = fixture.event.bytes();
            try fixture.port.on(fixture.vat, fixture.vow, .{ .ctx = probe, .func = Probe.record });
            try std.testing.expect(try fixture.port.serve(fixture.vat, fixture.event));
        }
    };
    inline for (.{ engine.pairing.paired, engine.pairing.pairedV1_0Syrup }) |pair_fn| {
        var probe: Probe = .{};
        try withResolveEvent(pair_fn, compoundReply(), &probe, Run.run);
        try std.testing.expectEqual(@as(usize, 1), probe.fired);
        try std.testing.expectEqual(@as(usize, 11), probe.leaves);
        try probe.expectText(compound_leaves);
        try std.testing.expect(probe.all_inside);
    }
}

test "a wire fulfillment of one string allocates nothing in the settle arena" {
    const Run = struct {
        fn run(captured: *CapturedString, fixture: Fixture) !void {
            try fixture.port.on(fixture.vat, fixture.vow, .{ .ctx = captured, .func = CapturedString.record });
            try std.testing.expectEqual(@as(usize, 0), fixture.vat.settle_arena.queryCapacity());
            try std.testing.expect(try fixture.port.serve(fixture.vat, fixture.event));
            try std.testing.expectEqual(@as(usize, 0), fixture.vat.settle_arena.queryCapacity());
        }
    };
    var captured: CapturedString = .{};
    try withResolveEvent(engine.pairing.paired, .{ .string = "lent-string" }, &captured, Run.run);
    try std.testing.expectEqualStrings("lent-string", captured.buf[0..captured.len]);
}

test "a refused tree build leaves the listener parked and the same event serves again" {
    const nested = comptime [_]model.Argument{.{ .bytes = "inner" }};
    const items = comptime [_]model.Argument{ .{ .string = "outer" }, .{ .list = &nested } };
    const Run = struct {
        fn run(probe: *Probe, fixture: Fixture) !void {
            probe.frame = fixture.event.bytes();
            try fixture.port.on(fixture.vat, fixture.vow, .{ .ctx = probe, .func = Probe.record });
            // The settle arena's first chunk is the first allocation the Vat
            // makes while serving, and the spine of the list needs it.
            fixture.failing.fail_index = fixture.failing.alloc_index;
            try std.testing.expectError(error.OutOfMemory, fixture.port.serve(fixture.vat, fixture.event));
            try std.testing.expect(fixture.failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 0), probe.fired);
            try std.testing.expect(fixture.port.far_listeners.count() == 1);

            fixture.failing.fail_index = std.math.maxInt(usize);
            try std.testing.expect(try fixture.port.serve(fixture.vat, fixture.event));
            try std.testing.expectEqual(@as(usize, 1), probe.fired);
            try std.testing.expect(fixture.port.far_listeners.count() == 0);
        }
    };
    var probe: Probe = .{};
    try withResolveEvent(engine.pairing.paired, .{ .list = &items }, &probe, Run.run);
    try probe.expectText("outer|inner|");
    try std.testing.expect(probe.all_inside);
}

test "settleFar hands the listener leaves that are not the caller's" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    try pair.p2.importObject(5);
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &pair.p2);
    defer port.deinit(&vat);

    const Copy = struct {
        source: []const u8,
        distinct: bool = false,
        same_bytes: bool = false,

        fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const leaf = resolution.fulfilled.bytes;
            self.distinct = leaf.ptr != self.source.ptr;
            self.same_bytes = std.mem.eql(u8, leaf, self.source);
        }
    };
    const source = try allocator.dupe(u8, "settle-me");
    defer allocator.free(source);
    var copy: Copy = .{ .source = source };
    const vow = try port.send(&vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "ask" });
    try port.on(&vat, vow, .{ .ctx = &copy, .func = Copy.record });
    try port.settleFar(&vat, vow.far, .{ .fulfilled = .{ .bytes = source } });
    try std.testing.expect(copy.distinct);
    try std.testing.expect(copy.same_bytes);
}

/// Replies with a list holding a turn-arena byte string naming the verb and a
/// nested list holding it again, so the settled tree has spines to guard.
const EchoVerb = struct {
    pub fn handle(self: *EchoVerb, turn: *Turn, msg: Delivery) !model.Argument {
        _ = self;
        const text: model.Argument = .{ .bytes = try turn.arena.print("reply-{s}", .{msg.verb orelse return error.NoSuchMethod}) };
        const inner = try turn.arena.dupe(model.Argument, &.{text});
        return .{ .list = try turn.arena.dupe(model.Argument, &.{ text, .{ .list = inner } }) };
    }
};

/// Both byte strings of an `EchoVerb` reply, joined by `|`, copied into `out`.
fn copyEcho(value: model.Argument, out: []u8) usize {
    const joined = std.mem.print(out, "{s}|{s}", .{ value.list[0].bytes, value.list[1].list[0].bytes }) catch unreachable;
    return joined.len;
}

fn recordEcho(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const capture: *CapturedBytes = @ptrCast(@alignCast(ctx.?));
    capture.len = copyEcho(resolution.fulfilled, &capture.buf);
}

/// A far listener that re-enters `serve` with a second resolve event while
/// its own resolution is live, then reads its bytes. The vat's settle-depth
/// guard is what keeps a nested settle from resetting the settle arena, where
/// the next nested settle would overwrite the outer value's spines.
const NestedServeCapture = struct {
    vat: *actors.Vat,
    port: *actors.Port,
    inner_events: [2]*engine.Event,
    buf: [64]u8 = undefined,
    len: usize = 0,
    broke: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *NestedServeCapture = @ptrCast(@alignCast(ctx.?));
        const value = switch (resolution) {
            .fulfilled => |value| value,
            .broken, .give => {
                self.broke = true;
                return;
            },
        };
        // Pump two more resolves through nested serves, the shape a driver's
        // `step` → `drainEvents` re-entry has, before reading the spines.
        for (self.inner_events) |event| _ = self.port.serve(self.vat, event) catch {
            self.broke = true;
            return;
        };
        self.len = copyEcho(value, &self.buf);
    }
};

test "a far listener that pumps more resolves through nested serves reads intact bytes" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);
    const echo = try host_vat.spawn(EchoVerb, .{});
    try host_port.bindExport(&host_vat, echo, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    const first = try caller_port.send(&caller_vat, remote, .{ .verb = "one" });
    const second = try caller_port.send(&caller_vat, remote, .{ .verb = "two" });
    const third = try caller_port.send(&caller_vat, remote, .{ .verb = "three" });

    // Shuttle the delivers over, run the turns, shuttle the resolves back.
    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    try cross_peer.pumpAll(host_peer, caller_peer);

    var resolves: [3]?engine.Event = @splat(null);
    var resolve_count: usize = 0;
    while (caller_peer.pollEvent()) |event| {
        if (event.kind() == .resolve) {
            if (resolve_count == resolves.len) {
                var extra = event;
                extra.deinit();
                return error.UnexpectedResolve;
            }
            resolves[resolve_count] = event;
            resolve_count += 1;
        } else {
            var bookkeeping = event;
            bookkeeping.deinit();
        }
    }
    try std.testing.expectEqual(resolves.len, resolve_count);
    var first_event = resolves[0] orelse return error.ExpectedResolve;
    defer first_event.deinit();
    var second_event = resolves[1] orelse return error.ExpectedResolve;
    defer second_event.deinit();
    var third_event = resolves[2] orelse return error.ExpectedResolve;
    defer third_event.deinit();

    var outer = NestedServeCapture{ .vat = &caller_vat, .port = &caller_port, .inner_events = .{ &second_event, &third_event } };
    try caller_port.on(&caller_vat, first, .{ .ctx = &outer, .func = NestedServeCapture.record });
    var inner: [2]CapturedBytes = @splat(.{});
    for ([_]actors.Vow{ second, third }, &inner) |vow, *capture| try caller_port.on(&caller_vat, vow, .{ .ctx = capture, .func = recordEcho });

    try std.testing.expect(try caller_port.serve(&caller_vat, &first_event));

    // Every resolution reads intact: no nested settle reset the arena.
    try std.testing.expect(!outer.broke);
    try std.testing.expectEqualStrings("reply-one|reply-one", outer.buf[0..outer.len]);
    try std.testing.expectEqualStrings("reply-two|reply-two", inner[0].buf[0..inner[0].len]);
    try std.testing.expectEqualStrings("reply-three|reply-three", inner[1].buf[0..inner[1].len]);
}
