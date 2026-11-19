//! A delivery lent as views and bound for a local actor reaches the queue as a
//! message whose spines sit in a scratch arena and whose bytes still lie in
//! the views, so the queue's clone is the one copy of the payload. The queued
//! message owns its bytes, a malformed view or a refused allocation enqueues
//! nothing, and admission charges it what the same owned message is charged.

const std = @import("std");
const glowcap = @import("glowcap");
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const view = model.view;

const payload: [2048]u8 = @splat('p');
const inner = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
const nested = [_]model.Argument{ .{ .integer = 1 }, .{ .bytes = "ab" } };
const entries = [_]model.StructEntry{.{ .key = "key", .value = .{ .string = "value" } }};
const sturdy: model.SturdyRef = .{
    .peer = .{
        .transport = "tcp",
        .designator = "host",
        .hints = .{ .entries = &.{.{ .name = "port", .value = .{ .string = "9" } }} },
    },
    .swissnum = "swiss",
};

/// A payload of 2 KiB, a short list, and one value of every other shape a
/// delivery carries without naming a reference.
const values = [_]model.Argument{
    .{ .bytes = &payload },
    .{ .list = &inner },
    .{ .symbol = "sym" },
    .{ .string = "str" },
    .{ .keyword = "kw" },
    .{ .integer = 7 },
    .{ .boolean = true },
    .{ .void = {} },
    .{ .float64 = 1.5 },
    .{ .set = &nested },
    .{ .tagged = .{ .tag = "tag", .value = &nested } },
    .{ .@"struct" = &entries },
    .{ .big_integer = .{ .negative = true, .digits = "123456789012345678901" } },
    .{ .@"error" = .{ .message = "boom" } },
};

/// `values` and one reference of each ownership: a broken one owns its
/// message, a sturdy one owns its locator, and a near one owns nothing.
const tree = values ++ [_]model.Argument{
    .{ .reference = .{ .broken = .{ .message = "gone" } } },
    .{ .reference = .{ .sturdy = &sturdy } },
    .{ .reference = .{ .near = model.NearRef.object(3) } },
};

/// `items` as views over a backing that is not an owned slice, so a send of
/// it takes the views path.
fn viewsOf(comptime items: []const model.Argument, out: *[items.len]view.Argument) actors.Delivery {
    for (items, out) |*owned, *slot| slot.* = view.Argument.fromOwned(owned);
    return .{ .verb = "record", .args = .fromViews(out), .reference_slots = null };
}

const owned_message: actors.Message = .{ .verb = "record", .args = &tree };

const Recorder = struct {
    seen: *usize,
    pub fn handle(self: *Recorder, _: *actors.Turn, msg: actors.Delivery) !model.Argument {
        try std.testing.expect(msg.is("record"));
        try std.testing.expectEqualSlices(u8, &payload, try msg.argBytes(0));
        const list = (try msg.arg(1)).list;
        try std.testing.expectEqual(@as(usize, 2), try list.len());
        try std.testing.expectEqual(@as(i64, 2), (try list.at(1)).integer);
        const count = try msg.args.len();
        try std.testing.expect(count >= values.len);
        if (count == tree.len) {
            try std.testing.expectEqualStrings("gone", (try msg.arg(values.len)).reference.broken.message);
            const kept = try (try msg.arg(values.len + 1)).reference.sturdy.project();
            try std.testing.expectEqualStrings("swiss", kept.swissnum);
            try std.testing.expectEqual(model.NearRef.object(3), (try msg.arg(values.len + 2)).reference.near);
        }
        self.seen.* += 1;
        return .{ .void = {} };
    }
};

/// Sums the bytes an allocator is asked for, growth included.
const Requested = struct {
    backing: std.mem.Allocator,
    bytes: usize = 0,

    fn allocator(self: *Requested) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Requested = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.bytes += len;
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Requested = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok and new_len > memory.len) self.bytes += new_len - memory.len;
        return ok;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Requested = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.bytes += new_len - memory.len;
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Requested = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "views sent through a Port to a local actor are copied only by the queue" {
    var requested = Requested{ .backing = std.testing.allocator };
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(requested.allocator());
    defer vat.deinit();
    var port = actors.Port.init(std.testing.allocator, &pair.p1);
    defer port.deinit(&vat);
    var seen: usize = 0;
    const recorder = try vat.spawn(Recorder, .{ .seen = &seen });
    var slots: [values.len]view.Argument = undefined;
    const delivery = viewsOf(&values, &slots);

    // Warm the queue's spare chunk, which retains more than the payload, so a
    // measured send's queue clone asks the vat allocator for nothing.
    try port.tellDelivery(&vat, recorder, delivery);
    try vat.drive();

    requested.bytes = 0;
    try port.tellDelivery(&vat, recorder, delivery);
    const tell_bytes = requested.bytes;
    try vat.drive();
    requested.bytes = 0;
    _ = try port.sendDelivery(&vat, recorder, delivery);
    const send_bytes = requested.bytes;
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 3), seen);

    // The vat allocator was asked for spines only, less than the payload.
    try std.testing.expect(tell_bytes < payload.len);
    try std.testing.expect(send_bytes < payload.len);
}

const Forwarder = struct {
    target: actors.Ref,
    arena_growth: *usize,
    pub fn handle(self: *Forwarder, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        const before = turn.vat.turn_arena.queryCapacity();
        try turn.tellDelivery(self.target, msg);
        self.arena_growth.* = turn.vat.turn_arena.queryCapacity() - before;
        return .{ .void = {} };
    }
};

test "a wire deliver forwarded to a local actor grows the turn arena by less than its payload" {
    const a = std.testing.allocator;
    const wire = [_]model.Argument{ .{ .symbol = "record" }, .{ .bytes = &payload }, .{ .list = &inner } } ++ values[2..];
    for ([_]bool{ false, true }) |syrup| {
        var pair = try if (syrup) engine.pairing.pairedV1_0Syrup(a) else engine.pairing.paired(a);
        defer pair.deinit();
        try pair.p1.importObject(5);
        try pair.p2.exportObject(5);
        var vat = actors.Vat.init(a);
        defer vat.deinit();
        var port = actors.Port.init(a, &pair.p2);
        defer port.deinit(&vat);
        var seen: usize = 0;
        var growth: usize = std.math.maxInt(usize);
        const recorder = try vat.spawn(Recorder, .{ .seen = &seen });
        const forwarder = try vat.spawn(Forwarder, .{ .target = recorder, .arena_growth = &growth });
        try port.bindExport(&vat, forwarder, 5);

        try pair.p1.sendBorrowed(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(5) }, .args = wire } });
        try std.testing.expectEqual(engine.pairing.ShuttleOutcome.quiescent, try engine.pairing.shuttleUntilQuiescent(&pair.p1, &pair.p2));
        {
            var incoming = pair.p2.pollEvent() orelse return error.MissingDelivery;
            defer incoming.deinit();
            _ = try port.serve(&vat, &incoming);
        }
        try std.testing.expect(growth < payload.len);
        // The frame is released before the queued turn runs, so the recorder
        // reads the queue's own copy.
        try vat.drive();
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

/// Reads every leaf kind from the text the views were lent, after the sender
/// has overwritten and freed it.
const Owner = struct {
    seen: *usize,
    pub fn handle(self: *Owner, _: *actors.Turn, msg: actors.Delivery) !model.Argument {
        try std.testing.expectEqualStrings("a long enough byte string to see it overwritten", try msg.argBytes(0));
        const tree_args = msg.args;
        var it = tree_args.iterator();
        _ = (try it.next()).?;
        try std.testing.expectEqualStrings("symbol", (try it.next()).?.symbol);
        try std.testing.expectEqualStrings("string", (try it.next()).?.string);
        try std.testing.expectEqualStrings("keyword", (try it.next()).?.keyword);
        try std.testing.expectEqualStrings("failure", (try it.next()).?.@"error".message);
        const big = (try it.next()).?.big_integer;
        try std.testing.expectEqualStrings("123456789012345678901", big.digits);
        const tagged = (try it.next()).?.tagged;
        try std.testing.expectEqualStrings("tagname", tagged.tag);
        try std.testing.expectEqualStrings("inner", (try tagged.value.at(0)).bytes);
        const entry = (try (try it.next()).?.@"struct".at(0));
        try std.testing.expectEqualStrings("field", entry.key);
        try std.testing.expectEqualStrings("entry value", entry.value.string);
        self.seen.* += 1;
        return .{ .void = {} };
    }
};

test "the queued message owns its bytes after the source of the views is gone" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var port = actors.Port.init(std.testing.allocator, &pair.p1);
    defer port.deinit(&vat);
    var seen: usize = 0;
    const owner = try vat.spawn(Owner, .{ .seen = &seen });

    const text = "a long enough byte string to see it overwritten" ++ "symbol" ++ "string" ++ "keyword" ++ "failure" ++
        "123456789012345678901" ++ "tagname" ++ "inner" ++ "field" ++ "entry value";
    const source = try std.testing.allocator.dupe(u8, text);
    var offset: usize = 0;
    const take = struct {
        fn at(buffer: []u8, at_offset: *usize, len: usize) []const u8 {
            defer at_offset.* += len;
            return buffer[at_offset.*..][0..len];
        }
    }.at;
    const tag_inner = [_]model.Argument{.{ .bytes = undefined }};
    var inner_items = tag_inner;
    var entry_items = [_]model.StructEntry{.{ .key = undefined, .value = .{ .string = undefined } }};
    var items: [9]model.Argument = undefined;
    items[0] = .{ .bytes = take(source, &offset, 47) };
    items[1] = .{ .symbol = take(source, &offset, 6) };
    items[2] = .{ .string = take(source, &offset, 6) };
    items[3] = .{ .keyword = take(source, &offset, 7) };
    items[4] = .{ .@"error" = .{ .message = take(source, &offset, 7) } };
    items[5] = .{ .big_integer = .{ .negative = false, .digits = take(source, &offset, 21) } };
    const tag = take(source, &offset, 7);
    inner_items[0] = .{ .bytes = take(source, &offset, 5) };
    items[6] = .{ .tagged = .{ .tag = tag, .value = &inner_items } };
    entry_items[0] = .{ .key = take(source, &offset, 5), .value = .{ .string = take(source, &offset, 11) } };
    items[7] = .{ .@"struct" = &entry_items };
    items[8] = .{ .integer = 1 };
    try std.testing.expectEqual(text.len, offset);

    var slots: [items.len]view.Argument = undefined;
    for (&items, &slots) |*owned, *slot| slot.* = view.Argument.fromOwned(owned);
    const delivery: actors.Delivery = .{ .verb = "record", .args = .fromViews(&slots), .reference_slots = null };
    try port.tellDelivery(&vat, owner, delivery);
    _ = try port.sendDelivery(&vat, owner, delivery);

    @memset(source, 0xAA);
    std.testing.allocator.free(source);
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 2), seen);
}

/// A backing whose `len` promises three elements and whose walk yields one.
const Lying = struct {
    const vtable: view.Args.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };
    fn len(_: view.Args.Ctx) view.ProjectError!usize {
        return 3;
    }
    fn at(_: view.Args.Ctx, _: usize) view.ProjectError!view.Argument {
        return error.MalformedView;
    }
    fn next(_: view.Args.Ctx, cursor: *u64, out: *view.Argument) view.ProjectError!bool {
        if (cursor.* != 0) return false;
        cursor.* = 1;
        out.* = .{ .integer = 1 };
        return true;
    }
    fn tail(_: view.Args.Ctx, _: usize) view.ProjectError!view.Args.Ctx {
        return error.MalformedView;
    }
};

test "a malformed view refused at enqueue leaves the queue and the vow table as they were" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var port = actors.Port.init(std.testing.allocator, &pair.p1);
    defer port.deinit(&vat);
    var seen: usize = 0;
    const recorder = try vat.spawn(Recorder, .{ .seen = &seen });
    const lying: actors.Delivery = .{ .verb = "record", .args = .fromBacking(.{}, &Lying.vtable) };
    try std.testing.expectError(actors.Error.MalformedView, port.tellDelivery(&vat, recorder, lying));
    try std.testing.expectError(actors.Error.MalformedView, port.sendDelivery(&vat, recorder, lying));
    try std.testing.expectEqual(@as(u32, 0), vat.pending_local_vows.count());
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 0), seen);

    // The refusal consumed no vow id: the next send is the vat's first.
    var slots: [tree.len]view.Argument = undefined;
    const vow = try port.sendDelivery(&vat, recorder, viewsOf(&tree, &slots));
    try std.testing.expectEqual(@as(u32, 1), vat.pending_local_vows.count());
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 1), seen);
    try std.testing.expectEqual(@as(u64, 1), vow.local);
}

/// Sends a malformed delivery on from inside its turn.
const Liar = struct {
    target: actors.Ref,
    refusal: *?actors.Error,
    pub fn handle(self: *Liar, turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        const lying: actors.Delivery = .{ .verb = "record", .args = .fromBacking(.{}, &Lying.vtable) };
        turn.tellDelivery(self.target, lying) catch |err| {
            self.refusal.* = err;
        };
        return .{ .void = {} };
    }
};

test "a malformed view sent on from a handler turn is refused and enqueues nothing" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var seen: usize = 0;
    var refusal: ?actors.Error = null;
    const recorder = try vat.spawn(Recorder, .{ .seen = &seen });
    const liar = try vat.spawn(Liar, .{ .target = recorder, .refusal = &refusal });
    try vat.tell(liar, .{});
    try vat.drive();
    try std.testing.expectEqual(@as(?actors.Error, actors.Error.MalformedView), refusal);
    try std.testing.expectEqual(@as(usize, 0), seen);
    try std.testing.expectEqual(@as(u32, 0), vat.pending_local_vows.count());
}

test "a refused allocation at any index enqueues nothing" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    var induced: usize = 0;
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        var failing = FailingOnce.init(std.testing.allocator, std.math.maxInt(usize));
        var vat = actors.Vat.init(failing.allocator());
        defer vat.deinit();
        var port = actors.Port.init(std.testing.allocator, &pair.p1);
        defer port.deinit(&vat);
        var seen: usize = 0;
        const recorder = try vat.spawn(Recorder, .{ .seen = &seen });
        var slots: [tree.len]view.Argument = undefined;
        const delivery = viewsOf(&tree, &slots);
        failing.fail_index = failing.alloc_index + k;
        const outcome = port.tellDelivery(&vat, recorder, delivery);
        if (failing.induced) {
            induced += 1;
            try std.testing.expectError(actors.Error.OutOfMemory, outcome);
            try std.testing.expectEqual(@as(u32, 0), vat.pending_local_vows.count());
            failing.fail_index = std.math.maxInt(usize);
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 0), seen);
            // The refusal left the queue usable.
            try port.tellDelivery(&vat, recorder, delivery);
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 1), seen);
        } else {
            try outcome;
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 1), seen);
            break;
        }
    }
    try std.testing.expect(induced > 4);
    try std.testing.expect(k < 200);
}

test "a views delivery is admitted at exactly the limit the same owned message is" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &pair.p1);
    defer port.deinit(&vat);
    var seen: usize = 0;
    const recorder = try vat.spawn(Recorder, .{ .seen = &seen });
    var slots: [tree.len]view.Argument = undefined;

    try port.tell(&vat, recorder, owned_message);
    const charge = vat.local_ingress.pending_bytes;
    try vat.drive();
    inline for (.{ owned_message, viewsOf(&tree, &slots) }) |message| {
        const tell = if (@TypeOf(message) == actors.Message) actors.Port.tell else actors.Port.tellDelivery;
        vat.queue_limits.max_pending_bytes = charge - 1;
        try std.testing.expectError(error.ResourceExhausted, tell(&port, &vat, recorder, message));
        try std.testing.expectEqual(@as(u32, 0), vat.local_ingress.pending_turns);
        vat.queue_limits.max_pending_bytes = charge;
        try tell(&port, &vat, recorder, message);
        try std.testing.expectEqual(charge, vat.local_ingress.pending_bytes);
        try vat.drive();
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}
