const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.codec;
const foundation = pancake.foundation;
const model = pancake.model;
const runtime = pancake.runtime;
const session = pancake.session;

const FailAfterAllocator = struct {
    backing: std.mem.Allocator,
    fail_after: usize,
    allocation_count: usize = 0,

    fn allocator(self: *FailAfterAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        if (self.allocation_count >= self.fail_after) return null;
        self.allocation_count += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.allocation_count >= self.fail_after) return null;
        if (new_len > memory.len) self.allocation_count += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count_size: usize = 0,
    matching_allocs: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (len == self.count_size) self.matching_allocs += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "owned inbound frame moves into the surfaced event without copying its bytes" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    const storage = try allocator.dupe(u8, deliver_bytes);
    const fed_ptr = @intFromPtr(storage.ptr);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try peer.feedInbound(frame);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(fed_ptr, @intFromPtr(event.bytes().ptr));
}

test "borrowed inbound retains its own copy of the wire bytes exactly once" {
    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = runtime.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    counter.count_size = deliver_bytes.len;
    try peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte });
    try std.testing.expectEqual(@as(usize, 1), counter.matching_allocs);

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expect(@intFromPtr(event.bytes().ptr) != @intFromPtr(deliver_bytes.ptr));
    try std.testing.expectEqualStrings(deliver_bytes, event.bytes());
}

test "sendCopying copies caller argument bytes exactly once" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = runtime.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(7);

    counter.count_size = "hello".len;
    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), counter.matching_allocs);
}

test "peer step encodes pending outbound message" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(7);

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
        },
    });

    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+f>",
        outbound.bytes(),
    );
}

test "peer step uses session wire profile for outbound encoding" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.wire_profile = model.WireProfile.v1_0;
    try peer.session_state.registerImport(7);
    try peer.session_state.registerExport(99);

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
            .resolve_me_desc = .{ .near = .{ .export_id = 99 } },
        },
    });

    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<18'desc:import-object99+>>",
        outbound.bytes(),
    );
}

test "V1_0 runtime translation synthesizes resolve-me-desc for answered deliver" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.wire_profile = model.WireProfile.v1_0;
    try peer.session_state.registerImport(7);

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
        },
    });

    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<19'desc:import-promise0+>>",
        outbound.bytes(),
    );
    try std.testing.expect(peer.session_state.hasExport(0));
    try std.testing.expectEqual(@as(?u64, 42), peer.session_state.answerForResolverExport(0));
}

test "peer sendCopying owns queued argument bytes before caller mutation" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(7);

    var arg_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const args = [_]model.Argument{.{ .bytes = arg_bytes[0..] }};

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = args[0..],
            .answer = 42,
        },
    });
    arg_bytes[0] = 'j';

    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+f>",
        outbound.bytes(),
    );
}

test "peer sendCopying deep-copies rich argument payloads" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(7);

    var keyword_bytes = [_]u8{ 'n', 'a', 'm', 'e' };
    var tag_bytes = [_]u8{ 'p', 'o', 'i', 'n', 't' };
    const tagged_values = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const set_values = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const args = [_]model.Argument{
        .{ .keyword = keyword_bytes[0..] },
        .{ .tagged = .{ .tag = tag_bytes[0..], .value = tagged_values[0..] } },
        .{ .set = set_values[0..] },
    };

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = args[0..],
            .answer = 42,
        },
    });
    keyword_bytes[0] = 'X';
    tag_bytes[0] = 'Y';

    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[<2'kw4'name><11'user-record5'point[1+2+]>#1+2+3+$]42+f>",
        outbound.bytes(),
    );
}

test "peer sendCopying does not advance session state when clone allocation fails" {
    var buffer: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
    var peer = runtime.Peer.init(fixed.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(7);

    const too_large = [_]u8{'x'} ** 4096;
    const args = [_]model.Argument{.{ .bytes = too_large[0..] }};

    try std.testing.expectError(error.OutOfMemory, peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = args[0..],
            .answer = 42,
        },
    }));
    try std.testing.expect(peer.session_state.outboundAnswer(42) == null);
    try std.testing.expectEqual(runtime.StepOutcome.idle, try peer.step());
}

test "recvBorrowed dispatches abort without retaining inbound bytes" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();

    var inbound_bytes = [_]u8{ '<', '8', '\'', 'o', 'p', ':', 'a', 'b', 'o', 'r', 't', '3', '"', 'b', 'y', 'e', '>' };
    const view = foundation.FrameView{
        .bytes = inbound_bytes[0..],
        .shape = .byte,
    };

    try peer.recvBorrowed(view);
    inbound_bytes[14] = 'x';

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(runtime.EventKind.abort, event.kind());
    try std.testing.expectEqualStrings("bye", (try event.view()).abort.message);
}

test "feedInbound transfers an owned frame and defers dispatch until step" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();

    const storage = try allocator.dupe(u8, "<8'op:abort3\"bye>");
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try peer.feedInbound(frame);
    try std.testing.expect(peer.pollEvent() == null);

    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(runtime.EventKind.abort, event.kind());
    try std.testing.expectEqualStrings("bye", (try event.view()).abort.message);
}

test "feedInbound and recvBorrowed apply decoded messages through the same session path" {
    const allocator = std.testing.allocator;
    var borrowed_peer = runtime.Peer.init(allocator);
    defer borrowed_peer.deinit();
    try borrowed_peer.session_state.registerExport(7);

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try borrowed_peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte });
    try std.testing.expect(borrowed_peer.session_state.inboundAnswer(11) != null);

    var owned_peer = runtime.Peer.init(allocator);
    defer owned_peer.deinit();
    try owned_peer.session_state.registerExport(7);
    const storage = try allocator.dupe(u8, deliver_bytes);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try owned_peer.feedInbound(frame);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try owned_peer.step());
    try std.testing.expect(owned_peer.session_state.inboundAnswer(11) != null);
}

test "recvBorrowed surfaces inbound deliver as an application event" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    var inbound_bytes = [_]u8{
        '<', '1', '0', '\'', 'o', 'p', ':', 'd', 'e', 'l', 'i', 'v', 'e', 'r',
        '<', '1', '1', '\'', 'd', 'e', 's', 'c', ':', 'e', 'x', 'p', 'o', 'r',
        't', '7', '+', '>',  '[', '5', ':', 'h', 'e', 'l', 'l', 'o', ']', '1',
        '1', '+', 'f', '>',
    };
    try peer.recvBorrowed(.{ .bytes = inbound_bytes[0..], .shape = .byte });
    inbound_bytes[35] = 'j';

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(runtime.EventKind.deliver, event.kind());
    const deliver = (try event.view()).deliver;
    // `<desc:export 7>` (deliver to our export) decodes to `.near` post-flip.
    try std.testing.expectEqual(@as(u64, 7), deliver.target.near.export_id);
    try std.testing.expectEqualStrings("hello", (try deliver.args.at(0)).bytes);
    try std.testing.expectEqual(@as(u64, 11), deliver.answer.?);
}

test "recvBorrowed does not advance session state when event allocation fails" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = runtime.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(7);
    failing.fail_after = failing.allocation_count + 1;

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try std.testing.expectError(
        error.OutOfMemory,
        peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte }),
    );
    try std.testing.expect(peer.session_state.inboundAnswer(11) == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "feedInbound step does not advance session state when event allocation fails" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = runtime.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    const storage = try std.testing.allocator.dupe(u8, deliver_bytes);
    const frame = try foundation.Frame.initOwned(
        std.testing.allocator,
        storage,
        .byte,
        .fromByteUnits(1),
    );
    try peer.feedInbound(frame);
    failing.fail_after = failing.allocation_count + 1;

    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.session_state.inboundAnswer(11) == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "recvBorrowed surfaces inbound get index listen and resolve events" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(7);
    try peer.session_state.registerImport(9);
    try peer.session_state.registerImport(99);

    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:export7+>4'name11+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(runtime.EventKind.get, event.kind());
        try std.testing.expectEqualStrings("name", (try event.view()).get.field);
    }

    try peer.recvBorrowed(.{ .bytes = "<8'op:index<11'desc:export7+>5+12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(runtime.EventKind.index, event.kind());
        try std.testing.expectEqual(@as(i64, 5), (try event.view()).index.index);
    }

    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(runtime.EventKind.listen, event.kind());
        // `<desc:import-object 9>` listener decodes to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), (try event.view()).listen.listener.far.import_id);
    }

    try peer.session_state.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 99 } },
            .args = &.{},
            .answer = 42,
        },
    });
    try peer.recvBorrowed(.{ .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(runtime.EventKind.resolve, event.kind());
        try std.testing.expectEqual(@as(u64, 42), (try event.view()).resolve.answer);
    }
}

test "two peers exchange deliver, resolve, and gc-export frames" {
    const allocator = std.testing.allocator;
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(7);
    try p2.session_state.registerExport(7);

    try p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = 42,
        },
    });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    const deliver_frame = p1.takeOutbound().?;
    try p2.feedInbound(deliver_frame);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    try std.testing.expect(p2.session_state.inboundAnswer(42) != null);

    try p2.sendCopying(.{
        .resolve = .{
            .answer = 42,
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    const resolve_frame = p2.takeOutbound().?;
    try p1.feedInbound(resolve_frame);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, p1.session_state.outboundAnswer(42).?.status);

    // p1 releases its import of p2's export@7 via op:gc-exports; the inbound
    // gc-exports on p2 decrements its export refcount to zero.
    try p1.sendCopying(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{1} } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    const gc_frame = p1.takeOutbound().?;
    try p2.feedInbound(gc_frame);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    try std.testing.expect(!p1.session_state.hasImport(7));
    try std.testing.expect(!p2.session_state.hasExport(7));
}

test "op:listen fires the registered listener when the answer resolves" {
    const allocator = std.testing.allocator;
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(7);
    try p2.session_state.registerExport(7);
    // p1's listener object is its own export 9; p2 reaches it when it fires.
    try p1.session_state.registerExport(9);

    // p1 delivers to p2's export, allocating answer 42 (p2 owes its resolution).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = 7 } },
        .args = &.{},
        .answer = 42,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expect(p2.session_state.inboundAnswer(42) != null);

    // p1 listens on the promise (answer 42), nominating its export 9 as listener.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .promise = .{ .answer_id = 42 } },
        .listener = .{ .near = .{ .export_id = 9 } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p2 resolves answer 42; step 1 encodes the resolve and queues the
    // synthesized listener-fire, step 2 encodes the fire deliver.
    try p2.sendCopying(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .bytes = "ok" } },
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    try p1.feedInbound(p2.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    try p1.feedInbound(p2.takeOutbound().?);

    // p1 processes the inbound resolve, then the listener-fire deliver.
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    {
        var event = p1.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();

    try std.testing.expectEqual(runtime.EventKind.deliver, fire_event.kind());
    const view = try fire_event.view();
    try std.testing.expect(view == .deliver);
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_id);
    try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings("ok", (try view.deliver.args.at(1)).bytes);
}

test "cross-peer relayed resolution fires a handoff-imported promise listener" {
    const allocator = std.testing.allocator;
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    // p2 holds a promise imported from a third party (import 5). p1 reaches its
    // listener (p1's export 9) when the relayed resolution fires.
    try p2.session_state.installThirdPartyImport(5, "exporter");
    try p1.session_state.registerExport(5);
    try p1.session_state.registerExport(9);

    // p1 listens on the imported promise (desc:import-promise 5), nominating its
    // export 9 as the listener.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_id = 5, .kind = .promise } },
        .listener = .{ .near = .{ .export_id = 9 } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // The introducing session forwards the third party's resolution; the
    // cross-peer drain fires the installed listener.
    try p2.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "done") } });
    try std.testing.expect(try runtime.cross_peer.drainRelayedResolutions(&p2));

    // The synthesized fire deliver encodes and reaches p1's export 9.
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    try p1.feedInbound(p2.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());

    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    try std.testing.expectEqual(runtime.EventKind.deliver, fire_event.kind());
    const view = try fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_id);
    try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings("done", (try view.deliver.args.at(1)).bytes);
}

test "a listen on an already-resolved handoff-imported promise fires immediately" {
    const allocator = std.testing.allocator;
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    try p2.session_state.installThirdPartyImport(5, "exporter");
    try p1.session_state.registerExport(5);
    try p1.session_state.registerExport(9);

    // Relay the resolution before any listener exists: it is stored, nothing fires.
    try p2.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "early") } });
    try std.testing.expect(try runtime.cross_peer.drainRelayedResolutions(&p2));
    try std.testing.expect(p2.takeOutbound() == null);

    // p1 listens; p2 installs the listener and fires it immediately from the
    // stored resolution.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_id = 5, .kind = .promise } },
        .listener = .{ .near = .{ .export_id = 9 } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    // Step 1 processes the listen and enqueues the immediate fire; step 2 encodes it.
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());

    try p1.feedInbound(p2.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    const view = try fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_id);
    try std.testing.expectEqualStrings("early", (try view.deliver.args.at(1)).bytes);
}

test "a second relayed resolution overwrites the stored value and re-drains new listeners" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(5, "exporter");
    try peer.session_state.registerImport(9);
    try peer.session_state.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_id = 9 } }, .wants_partial = false });

    // First relay fires the listener (far 9) and stores the resolution.
    try peer.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });
    try std.testing.expect(try runtime.cross_peer.drainRelayedResolutions(&peer));
    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());
    {
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        // Decoding our own outbound frame applies the receiver-perspective flip:
        // the fire's `far` import 9 was encoded `<desc:export 9>`, which decodes
        // to `.near{export_id=9}` (the partner's view of its own export).
        const view = try codec.syrup.decodeView(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_id);
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }

    // A new listener (far 10) installed after the first relay; the second relay
    // overwrites the stored value and fires the new listener with it.
    try peer.session_state.registerImport(10);
    try peer.session_state.installImportedPromiseListener(5, .{ .target = .{ .far = .{ .import_id = 10 } }, .wants_partial = false });
    try peer.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } });
    try std.testing.expect(try runtime.cross_peer.drainRelayedResolutions(&peer));
    try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());
    {
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeView(frame.view());
        try std.testing.expectEqual(@as(u64, 10), view.deliver.target.near.export_id);
        try std.testing.expectEqualStrings("second", (try view.deliver.args.at(1)).bytes);
    }
    try std.testing.expectEqualStrings("second", peer.session_state.importedPromiseResolution(5).?.fulfill.bytes);
}

test "a pipelined call queues until its answer resolves, then delivers locally" {
    const allocator = std.testing.allocator;
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(7);
    try p2.session_state.registerExport(7);

    // p1 delivers to p2's export, allocating answer 42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = 7 } },
        .args = &.{},
        .answer = 42,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against the unresolved answer (a promise target).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_id = 42 } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = 43,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());

    // The pipelined call is held on the answer's queue, not surfaced as an event.
    try std.testing.expect(p2.pollEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(42).?.queued_calls);

    // p2 resolves answer 42 to a local export (#9); the queued call drains into
    // a local delivery against that export, carrying its original args + answer.
    try p2.sendCopying(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_id = 9 } } } },
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(42).?.queued_calls);

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    try std.testing.expectEqual(runtime.EventKind.deliver, local_event.kind());
    const view = try local_event.view();
    // A local delivery to our export is wire-shaped as `<desc:export>`, which
    // decodes (receiver perspective, ADR-0010) to `.near{export_id=9}` — exactly
    // the shape a deliver to our export 9 carries when it arrives off the wire.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_id);
    try std.testing.expectEqual(@as(?u64, 43), view.deliver.answer);
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);

    // p2 now owes the forwarded call's answer (#43) as a fresh inbound answer.
    try std.testing.expect(p2.session_state.inboundAnswer(43) != null);
}

test "a multi-hop pipelined deliver decomposes into a chain of single-hop frames" {
    const allocator = std.testing.allocator;
    var peer = runtime.Peer.init(allocator);
    defer peer.deinit();

    // Pipeline a 2-hop call: promise{42}.call(["a"]).call(["b"]) with outer
    // args ["c"], answer 100. Syrup has no path operand on `desc:answer`, so this
    // must drain as two intermediate single-hop frames plus the terminal.
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_id = 42, .path = .{ .ops = &.{
            .{ .call = &.{.{ .bytes = "a" }} },
            .{ .call = &.{.{ .bytes = "b" }} },
        } } } },
        .args = &.{.{ .bytes = "c" }},
        .answer = 100,
    } });

    // Each frame targets the prior step's answer; the terminal carries the
    // caller's outer answer (100), the intermediates the freshly-allocated ones.
    var prev_answer: u64 = 42;
    const expected_args = [_][]const u8{ "a", "b", "c" };
    for (expected_args, 0..) |arg, idx| {
        try std.testing.expectEqual(runtime.StepOutcome.progress, try peer.step());
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeView(frame.view());
        try std.testing.expect(view == .deliver);
        try std.testing.expect(view.deliver.target == .promise);
        try std.testing.expectEqual(prev_answer, view.deliver.target.promise.answer_id);
        try std.testing.expectEqualStrings(arg, (try view.deliver.args.at(0)).bytes);
        if (idx < expected_args.len - 1) {
            prev_answer = view.deliver.answer.?;
        } else {
            try std.testing.expectEqual(@as(?u64, 100), view.deliver.answer);
        }
    }

    // Chain fully drained — nothing further to encode.
    try std.testing.expectEqual(runtime.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a pipelined call re-queues when its answer resolves to another promise" {
    const allocator = std.testing.allocator;
    var p1 = runtime.Peer.init(allocator);
    defer p1.deinit();
    var p2 = runtime.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(7);
    try p2.session_state.registerExport(7);

    // Two inbound answers p2 owes (#42 and #50), each from a delivery.
    for ([_]u64{ 42, 50 }) |answer| {
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = &.{},
            .answer = answer,
        } });
        try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
        try p2.feedInbound(p1.takeOutbound().?);
        try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against #42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_id = 42 } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = 43,
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p1.step());
    try p2.feedInbound(p1.takeOutbound().?);
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());

    // p2 resolves #42 to promise #50; the queued call re-queues onto #50.
    try p2.sendCopying(.{ .resolve = .{
        .answer = 42,
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_id = 50 } } } },
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    try std.testing.expect(p2.pollEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(50).?.queued_calls);

    // Resolving #50 to a local export finally drains the re-queued call.
    try p2.sendCopying(.{ .resolve = .{
        .answer = 50,
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_id = 9 } } } },
    } });
    try std.testing.expectEqual(runtime.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    const view = try local_event.view();
    // Local delivery to our export 9 decodes as `.near` post-flip (ADR-0010).
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_id);
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);
}

test "an inbound protocol violation emits a typed op:abort and closes the session" {
    const allocator = std.testing.allocator;
    var pair = try runtime.factories.paired(allocator);
    defer pair.deinit();

    // An inbound `op:deliver` to `<desc:export 7>` — an export this open peer
    // never installed (only the bootstrap export 0 exists) — is a protocol
    // violation (`InvalidReference`). The runtime must emit a typed abort and
    // close rather than silently bubbling the error.
    const deliver_to_unknown_export = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try std.testing.expectError(
        session.Error.InvalidReference,
        pair.p2.recvBorrowed(.{ .bytes = deliver_to_unknown_export, .shape = .byte }),
    );

    // The session closed and no application event surfaced for the rejected frame.
    try std.testing.expectEqual(session.State.closed, pair.p2.session_state.state);
    try std.testing.expect(pair.p2.pollEvent() == null);

    // A typed `op:abort` (ProtocolError) is queued outbound for the partner.
    var abort_frame = pair.p2.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeView(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.protocol_error, decoded.abort.kind);
    // Exactly one outbound frame — the abort.
    try std.testing.expect(pair.p2.takeOutbound() == null);
}

test "a malformed inbound frame emits a malformed-frame abort and closes" {
    const allocator = std.testing.allocator;
    var pair = try runtime.factories.paired(allocator);
    defer pair.deinit();

    // Garbage that is not a decodable Syrup frame.
    const garbage = "this is not a syrup frame";
    try std.testing.expectError(
        error.MalformedFrame,
        pair.p1.recvBorrowed(.{ .bytes = garbage, .shape = .byte }),
    );

    try std.testing.expectEqual(session.State.closed, pair.p1.session_state.state);

    var abort_frame = pair.p1.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeView(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, decoded.abort.kind);
}
