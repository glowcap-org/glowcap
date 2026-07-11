const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const peer_fixture = @import("../support/peer_fixture.zig");

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

test "raw-open fixture peer is already open on v1.0, not PreSpec" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initRawOpenFixture(allocator);
    defer peer.deinit();

    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.v1_0, peer.session_state.wire_profile.captp_version);
}

test "raw-open fixture records v1.0 resolver callback imports" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initRawOpenFixture(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
    try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });

    try std.testing.expectEqual(@as(?model.ImportPosition, .from(99)), peer.session_state.resolverForInboundAnswer(.from(11)));

    try peer.sendCopying(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .integer = 7 } },
    } });
    try std.testing.expectEqual(.progress, try peer.step());
    var out = peer.takeOutbound().?;
    defer out.deinit();
    try std.testing.expect(std.mem.indexOf(u8, out.storage, "op:deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.storage, "fulfill") != null);
}

test "raw-open v1.0 fixture rejects raw inbound op:resolve" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initRawOpenFixture(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(11),
    } });

    const wire = "<10'op:resolve11+<15'resolve:fulfill7+>>";
    try std.testing.expectError(session.Error.UnexpectedMessage, peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }));
}

test "owned inbound frame moves into the surfaced event without copying its bytes" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    const storage = try allocator.dupe(u8, deliver_bytes);
    const fed_ptr = @intFromPtr(storage.ptr);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try peer.feedOwned(frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(fed_ptr, @intFromPtr(event.bytes().ptr));
}

test "borrowed inbound retains its own copy of the wire bytes exactly once" {
    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

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
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    counter.count_size = "hello".len;
    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(@as(usize, 1), counter.matching_allocs);
}

test "peer step encodes pending outbound message" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

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
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.wire_profile = model.WireProfile.v1_0;
    try peer.session_state.registerImport(.from(7));
    try peer.session_state.registerExport(.from(99));

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
            .resolve_me_desc = .{ .near = .{ .export_position = .from(99) } },
        },
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

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
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.wire_profile = model.WireProfile.v1_0;
    try peer.session_state.registerImport(.from(7));

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var outbound = peer.takeOutbound().?;
    defer outbound.deinit();

    // The synthesized resolver export is 1, not 0: export 0 is reserved for the
    // bootstrap object from session construction, so a locally-allocated export
    // never aliases it (even on this un-opened raw peer).
    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<19'desc:import-promise1+>>",
        outbound.bytes(),
    );
    try std.testing.expect(peer.session_state.hasExport(.from(1)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), peer.session_state.answerForResolverExport(.from(1)));
}

test "V1_0 resolver-callback resolving to a container registers the introduced import" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.wire_profile = model.WireProfile.v1_0;
    try peer.session_state.registerImport(.from(7));

    // An answered deliver installs outbound answer 42 and our resolver export 1
    // (export 0 is the reserved bootstrap id).
    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hi" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var outbound = peer.takeOutbound().?;
        outbound.deinit();
    }
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), peer.session_state.answerForResolverExport(.from(1)));

    // The partner resolves answer 42 by delivering to our resolver export 1 a
    // `fulfill` whose payload is a *list containing a capability*, a far ref the
    // resolution introduces. On the wire the target is <desc:export 1> and the
    // payload <desc:import-object 9> sits inside a list; decode flips them to
    // .near{1} (our resolver) and .far{9} (the introduced import). Encoded via
    // the codec so the wire shape is exact.
    const callback = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(1) } },
            .args = &.{
                .{ .symbol = "fulfill" },
                .{ .list = &.{.{ .reference = .{ .near = model.NearRef.object(9) } }} },
            },
        },
    };
    const frame = try codec.syrup.encodeMessage(allocator, callback);
    try peer.feedOwned(frame); // takes ownership of frame
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    }

    // The capability nested in the container resolution was registered as an
    // import. Before the fix, borrowedArgument collapsed the container to void
    // and the introduced-import walk never saw the far ref, so the import was
    // silently dropped and a later message naming it would have failed.
    try std.testing.expect(peer.session_state.hasImport(.from(9)));
}

test "peer sendCopying owns queued argument bytes before caller mutation" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    var arg_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const args = [_]model.Argument{.{ .bytes = arg_bytes[0..] }};

    try peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        },
    });
    arg_bytes[0] = 'j';

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

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
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

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
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        },
    });
    keyword_bytes[0] = 'X';
    tag_bytes[0] = 'Y';

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

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
    var peer = engine.Peer.init(fixed.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    const too_large = [_]u8{'x'} ** 4096;
    const args = [_]model.Argument{.{ .bytes = too_large[0..] }};

    try std.testing.expectError(error.OutOfMemory, peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        },
    }));
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "recvBorrowed dispatches abort without retaining inbound bytes" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
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
    try std.testing.expectEqual(engine.EventKind.abort, event.kind());
    try std.testing.expectEqualStrings("bye", (try event.view()).abort.message);
}

test "feedOwned transfers an owned frame and defers dispatch until step" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const storage = try allocator.dupe(u8, "<8'op:abort3\"bye>");
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try peer.feedOwned(frame);
    try std.testing.expect(peer.pollEvent() == null);

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.abort, event.kind());
    try std.testing.expectEqualStrings("bye", (try event.view()).abort.message);
}

test "feedOwned and recvBorrowed apply decoded messages through the same session path" {
    const allocator = std.testing.allocator;
    var borrowed_peer = engine.Peer.init(allocator);
    defer borrowed_peer.deinit();
    try borrowed_peer.session_state.registerExport(.from(7));

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try borrowed_peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte });
    try std.testing.expect(borrowed_peer.session_state.inboundAnswer(.from(11)) != null);

    var owned_peer = engine.Peer.init(allocator);
    defer owned_peer.deinit();
    try owned_peer.session_state.registerExport(.from(7));
    const storage = try allocator.dupe(u8, deliver_bytes);
    const frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));

    try owned_peer.feedOwned(frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try owned_peer.step());
    try std.testing.expect(owned_peer.session_state.inboundAnswer(.from(11)) != null);
}

test "recvBorrowed surfaces inbound deliver as an application event" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

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
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    const deliver = (try event.view()).deliver;
    // `<desc:export 7>` (deliver to our export) decodes to `.near` post-flip.
    try std.testing.expectEqual(@as(u64, 7), deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("hello", (try deliver.args.at(0)).bytes);
    try std.testing.expectEqual(@as(u64, 11), deliver.answer.?.int());
}

test "recvBorrowed does not advance session state when event allocation fails" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    failing.fail_after = failing.allocation_count + 1;

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    try std.testing.expectError(
        error.OutOfMemory,
        peer.recvBorrowed(.{ .bytes = deliver_bytes, .shape = .byte }),
    );
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "feedOwned step does not advance session state when event allocation fails" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const deliver_bytes = "<10'op:deliver<11'desc:export7+>[]11+f>";
    const storage = try std.testing.allocator.dupe(u8, deliver_bytes);
    const frame = try foundation.Frame.initOwned(
        std.testing.allocator,
        storage,
        .byte,
        .fromByteUnits(1),
    );
    try peer.feedOwned(frame);
    failing.fail_after = failing.allocation_count + 1;

    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "recvBorrowed surfaces inbound get index listen and resolve events" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.registerImport(.from(99));

    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:export7+>4\"name11+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.get, event.kind());
        try std.testing.expectEqualStrings("name", (try event.view()).get.field);
    }
    // The responder (ADR-0050) exports the projected answer immediately. The
    // receiver here is a plain export, which can never settle to a value, so
    // the projection breaks rather than hanging the requester.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) != null);

    try peer.recvBorrowed(.{ .bytes = "<8'op:index<11'desc:export7+>5+12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.index, event.kind());
        try std.testing.expectEqual(@as(i64, 5), (try event.view()).index.index);
    }
    // Likewise op:index is surfaced and its projected answer exported.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);

    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
        // `<desc:import-object 9>` listener decodes to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), (try event.view()).listen.listener.far.import_position.int());
    }

    try peer.session_state.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(99) } },
            .args = &.{},
            .answer = .from(42),
        },
    });
    try peer.recvBorrowed(.{ .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
        try std.testing.expectEqual(@as(u64, 42), (try event.view()).resolve.answer.int());
    }
}

test "two peers exchange deliver, resolve, and gc-export frames" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p2 introduces its export 7 to p1 on the wire (an answer-less deliver
    // carrying the near mention), so p1's later release is a legal wire-delta
    // and p1 holds the import the introduction installed.
    try p1.session_state.registerExport(.from(9));
    try p2.session_state.registerImport(.from(9));
    try p2.session_state.registerExport(.from(7));
    try p2.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(9) } },
            .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
            .answer = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expect(p1.session_state.hasImport(.from(7)));
    const granted = p2.session_state.exportRefcount(.from(7));

    try p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const deliver_frame = p1.takeOutbound().?;
    try p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(p2.session_state.inboundAnswer(.from(42)) != null);

    try p2.sendCopying(.{
        .resolve = .{
            .answer = .from(42),
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    const resolve_frame = p2.takeOutbound().?;
    try p1.feedOwned(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, p1.session_state.outboundAnswer(.from(42)).?.status);

    // p1 releases its import of p2's export@7 via op:gc-exports; the inbound
    // gc-exports on p2 returns the wire mention, and the export row survives
    // at its local baseline for re-export.
    try p1.sendCopying(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{1} } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const gc_frame = p1.takeOutbound().?;
    try p2.feedOwned(gc_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(!p1.session_state.hasImport(.from(7)));
    try std.testing.expect(p2.session_state.hasExport(.from(7)));
    try std.testing.expectEqual(granted - 1, p2.session_state.exportRefcount(.from(7)));
}

test "a second inbound op:resolve for an already-settled outbound answer is refused" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 sends an answered deliver, installing outbound answer 42.
    try p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const deliver_frame = p1.takeOutbound().?;
    try p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // The partner resolves answer 42 once; p1's outbound answer settles.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    const resolve_frame = p2.takeOutbound().?;
    try p1.feedOwned(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(
        session.AnswerStatus.fulfilled,
        p1.session_state.outboundAnswer(.from(42)).?.status,
    );

    // A second op:resolve for the same already-settled answer is a partner
    // protocol violation. It must be refused (a protocol_error abort), not
    // re-settle the answer or re-introduce the fulfill payload's imports.
    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        p1.recvBorrowed(.{ .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>", .shape = .byte }),
    );
    try std.testing.expectEqual(
        session.AnswerStatus.fulfilled,
        p1.session_state.outboundAnswer(.from(42)).?.status,
    );
}

test "op:listen fires the registered listener when the answer resolves" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    // p1's listener object is its own export 9; p2 reaches it when it fires.
    try p1.session_state.registerExport(.from(9));

    // p1 delivers to p2's export, allocating answer 42 (p2 owes its resolution).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expect(p2.session_state.inboundAnswer(.from(42)) != null);

    // p1 listens on the promise (answer 42), nominating its export 9 as listener.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p2 resolves answer 42; step 1 encodes the resolve and queues the
    // synthesized listener-fire, step 2 encodes the fire deliver.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .bytes = "ok" } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);

    // p1 processes the inbound resolve, then the listener-fire deliver.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    {
        var event = p1.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();

    try std.testing.expectEqual(engine.EventKind.deliver, fire_event.kind());
    const view = try fire_event.view();
    try std.testing.expect(view == .deliver);
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings("ok", (try view.deliver.args.at(1)).bytes);
}

test "cross-peer relayed resolution fires a handoff-imported promise listener" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p2 holds a promise imported from a third party (import 5). p1 reaches its
    // listener (p1's export 9) when the relayed resolution fires.
    try p2.session_state.installThirdPartyImport(.from(5), "exporter");
    try p1.session_state.registerExport(.from(5));
    try p1.session_state.registerExport(.from(9));

    // p1 listens on the imported promise (desc:import-promise 5), nominating its
    // export 9 as the listener.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_position = .from(5), .kind = .promise } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // The introducing session forwards the third party's resolution; the
    // cross-peer drain fires the installed listener.
    try p2.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "done") } });
    try std.testing.expect(try engine.cross_peer.drainRelayedResolutions(&p2));

    // The synthesized fire deliver encodes and reaches p1's export 9.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());

    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, fire_event.kind());
    const view = try fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings("done", (try view.deliver.args.at(1)).bytes);
}

test "a listen on an already-resolved handoff-imported promise fires immediately" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p2.session_state.installThirdPartyImport(.from(5), "exporter");
    try p1.session_state.registerExport(.from(5));
    try p1.session_state.registerExport(.from(9));

    // Relay the resolution before any listener exists: it is stored, nothing fires.
    try p2.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "early") } });
    try std.testing.expect(try engine.cross_peer.drainRelayedResolutions(&p2));
    try std.testing.expect(p2.takeOutbound() == null);

    // p1 listens; p2 installs the listener and fires it immediately from the
    // stored resolution.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_position = .from(5), .kind = .promise } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    // Step 1 processes the listen and enqueues the immediate fire; step 2 encodes it.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    var fire_event = p1.pollEvent().?;
    defer fire_event.deinit();
    const view = try fire_event.view();
    // The fire targets our own export 9, so it arrives as `.near` post-flip.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("early", (try view.deliver.args.at(1)).bytes);
}

test "a second relayed resolution is refused — a handoff-imported promise resolves once" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });

    // First relay fires the listener (far 9) and stores the resolution.
    try peer.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });
    try std.testing.expect(try engine.cross_peer.drainRelayedResolutions(&peer));
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        // Decoding our own outbound frame applies the receiver-perspective flip:
        // the fire's `far` import 9 was encoded `<desc:export 9>`, which decodes
        // to `.near{export_position=9}` (the partner's view of its own export).
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }

    // A second relay for the already-settled promise is refused (a promise
    // resolves once, mirroring the answer-side rule), the refused resolution
    // is freed (the testing allocator holds the no-leak contract), and the
    // stored value is untouched. A listener installed after the settlement
    // never fires from the refused relay.
    try peer.session_state.registerImport(.from(10));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(10) }, .wants_partial = false });
    try peer.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } });
    try std.testing.expectError(error.UnexpectedMessage, engine.cross_peer.drainRelayedResolutions(&peer));
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expectEqualStrings("first", peer.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes);
}

test "a second relay before the first fire encodes is refused and every listener hears the one settled value" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p2.session_state.installThirdPartyImport(.from(5), "exporter");
    try p2.session_state.registerImport(.from(9));
    try p2.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });
    try p1.session_state.registerExport(.from(5));
    try p1.session_state.registerExport(.from(9));

    // First relay queues listener 9's fire carrier — nothing steps yet, so
    // the fire has not encoded.
    try p2.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "first") } });
    try std.testing.expect(try engine.cross_peer.drainRelayedResolutions(&p2));

    // A second relay in the queue→encode window is refused before anything
    // fires: the store still holds "first", the queued carrier's accounting
    // still matches the payload that will ship.
    try p2.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "second") } });
    try std.testing.expectError(error.UnexpectedMessage, engine.cross_peer.drainRelayedResolutions(&p2));

    // The queued fire encodes the stored "first".
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var frame = p2.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }

    // A late wire `op:listen` (installed after both relays) converges on the
    // same settled value: it fires immediately from the store with "first".
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .near = .{ .export_position = .from(5), .kind = .promise } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var frame = p2.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("first", (try view.deliver.args.at(1)).bytes);
    }
    try std.testing.expect(p2.takeOutbound() == null);
    try std.testing.expectEqualStrings("first", p2.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes);
}

test "a fire staled by row teardown and re-registration at the same import position drops instead of leaking the new promise's value" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    try peer.session_state.installThirdPartyImport(.from(5), "exporter");
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.installImportedPromiseListener(.from(5), .{ .listener = .{ .import_position = .from(9) }, .wants_partial = false });

    // The relay queues listener 9's fire, stamped with this row instance's
    // identity; nothing steps yet.
    try peer.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "old-promise") } });
    try std.testing.expect(try engine.cross_peer.drainRelayedResolutions(&peer));

    // Sending `op:gc-exports` for import 5 releases it fully; the imported-
    // promise row (and its stored payload) is co-evicted at record time,
    // while listener 9's carrier still sits in the send queue.
    try peer.sendCopying(.{ .gc_export = .{ .positions = &.{5}, .deltas = &.{1} } });

    // A *different* third-party promise is then registered at the reused
    // position and relays its own value before the stale carrier encodes.
    try peer.session_state.installThirdPartyImport(.from(5), "other-exporter");
    try peer.relayResolution(5, .{ .fulfill = .{ .bytes = try allocator.dupe(u8, "new-promise") } });
    try std.testing.expect(try engine.cross_peer.drainRelayedResolutions(&peer));

    // Draining emits only the gc frame: the stale fire's row-identity stamp
    // misses the re-registered row, so listener 9 — a listener on the dead
    // promise, not this one — never receives "new-promise".
    while ((try peer.step()) != .idle) {}
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .gc_export);
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
    try std.testing.expectEqualStrings("new-promise", peer.session_state.importedPromiseResolution(.from(5)).?.fulfill.bytes);
}

test "a pipelined call queues until its answer resolves, then delivers locally" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 delivers to p2's export, allocating answer 42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against the unresolved answer (a promise target).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // The pipelined call is held on the answer's queue, not surfaced as an event.
    try std.testing.expect(p2.pollEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);

    // p2 resolves answer 42 to a local export (#9); the queued call drains into
    // a local delivery against that export, carrying its original args + answer.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, local_event.kind());
    const view = try local_event.view();
    // A local delivery to our export is wire-shaped as `<desc:export>`, which
    // decodes (receiver perspective, ADR-0010) to `.near{export_position=9}` — exactly
    // the shape a deliver to our export 9 carries when it arrives off the wire.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(43)), view.deliver.answer);
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);

    // p2 now owes the forwarded call's answer (#43) as a fresh inbound answer.
    try std.testing.expect(p2.session_state.inboundAnswer(.from(43)) != null);
}

test "a multi-hop pipelined deliver decomposes into a chain of single-hop frames" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // Pipeline a 2-hop call: promise{42}.call(["a"]).call(["b"]) with outer
    // args ["c"], answer 100. Syrup has no path operand on `desc:answer`, so this
    // must drain as two intermediate single-hop frames plus the terminal.
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42), .path = .{ .ops = &.{
            .{ .call = &.{.{ .bytes = "a" }} },
            .{ .call = &.{.{ .bytes = "b" }} },
        } } } },
        .args = &.{.{ .bytes = "c" }},
        .answer = .from(100),
    } });

    // Each frame targets the prior step's answer; the terminal carries the
    // caller's outer answer (100), the intermediates the freshly-allocated ones.
    var prev_answer: model.AnswerPosition = .from(42);
    const expected_args = [_][]const u8{ "a", "b", "c" };
    for (expected_args, 0..) |arg, idx| {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .deliver);
        try std.testing.expect(view.deliver.target == .promise);
        try std.testing.expectEqual(prev_answer, view.deliver.target.promise.answer_position);
        try std.testing.expectEqualStrings(arg, (try view.deliver.args.at(0)).bytes);
        if (idx < expected_args.len - 1) {
            prev_answer = view.deliver.answer.?;
        } else {
            try std.testing.expectEqual(@as(?model.AnswerPosition, .from(100)), view.deliver.answer);
        }
    }

    // Chain fully drained, nothing further to encode.
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a pipelined call re-queues when its answer resolves to another promise" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // Two inbound answers p2 owes (#42 and #50), each from a delivery.
    for ([_]u64{ 42, 50 }) |answer| {
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against #42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // p2 resolves #42 to promise #50; the queued call re-queues onto #50.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(50) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    try std.testing.expect(p2.pollEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(50)).?.queued_calls);

    // Resolving #50 to a local export finally drains the re-queued call.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(50),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    const view = try local_event.view();
    // Local delivery to our export 9 decodes as `.near` post-flip (ADR-0010).
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);
}

test "an inbound protocol violation emits a typed op:abort and closes the session" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
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
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.protocol_error, decoded.abort.kind);
    // Exactly one outbound frame, the abort.
    try std.testing.expect(pair.p2.takeOutbound() == null);
}

test "a malformed inbound frame emits a malformed-frame abort and closes" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // Garbage that is not a decodable Syrup frame.
    const garbage = "this is not a syrup frame";
    try std.testing.expectEqual(@as(?engine.AbortInfo, null), pair.p1.lastAbort());
    try std.testing.expectError(
        error.MalformedFrame,
        pair.p1.recvBorrowed(.{ .bytes = garbage, .shape = .byte }),
    );

    try std.testing.expectEqual(session.State.closed, pair.p1.session_state.state);

    // The typed cause stays readable on the peer after the error propagated.
    const cause = pair.p1.lastAbort().?;
    try std.testing.expectEqual(engine.abort_projection.Domain.codec, cause.domain);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, cause.kind.?);
    try std.testing.expectEqualStrings("MalformedFrame", cause.error_name);

    var abort_frame = pair.p1.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, decoded.abort.kind);
}

test "a pipelined call whose arg references an unheld export is rejected, like a direct deliver" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    // p1 claims to hold import 99, which p2 never exported, a desynced or
    // hostile partner naming a capability that does not exist on p2's side.
    try p1.session_state.registerImport(.from(99));

    // p1 calls p2's export, allocating answer 42 (now pending on p2).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against answer 42 whose arg references far import 99.
    // On p2 that decodes (perspective flip, ADR-0010) to near export 99, which p2
    // does not hold. A direct deliver carrying that arg is rejected as
    // InvalidReference; the pipelined call must be rejected the same way instead
    // of slipping past validation onto the answer's queue.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .reference = .{ .far = .{ .import_position = .from(99) } } }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);

    // p2 dispatches the pipelined frame and rejects it at validation, the call
    // never reaches the queue.
    try std.testing.expectError(error.InvalidReference, p2.step());
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);
}

test "local-delivery depth bounds one resolution and resets, so a long-lived peer never wedges" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // Tighten the cap so the test exercises the per-resolution reset without
    // 4096 iterations. With the cap at 1, each resolution may drive exactly one
    // local delivery; before the fix `local_delivery_depth` was a peer-lifetime
    // counter, so the *second* resolution aborted with LocalDeliveryCapExceeded.
    p2.session_state.limits.max_local_deliveries = 1;

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    try p2.session_state.registerExport(.from(9));

    var answer: u64 = 100;
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        // p1 calls p2's export, allocating `answer` (pending on p2).
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        {
            var event = p2.pollEvent().?;
            event.deinit();
        }

        // p1 pipelines a call against the unresolved answer.
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(answer) } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = .from(answer + 1),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

        // p2 resolves `answer` to a local export: one local delivery. This must
        // not exceed the cap on any cycle, the depth resets per resolution.
        try p2.sendCopying(.{ .resolve = .{
            .answer = .from(answer),
            .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        {
            var resolve_frame = p2.takeOutbound().?;
            resolve_frame.deinit();
        }
        var local_event = p2.pollEvent().?;
        local_event.deinit();

        answer += 2;
    }
}

test "a closed session refuses a pipelined deliver instead of queuing it (fail closed)" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 calls p2's export, allocating answer 42 (pending on p2).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // A fatal abort closes p2's session. close() flips state but does not clear
    // the pending answer table, so answer 42 still exists.
    p2.session_state.close();
    try std.testing.expect(p2.session_state.inboundAnswer(.from(42)) != null);

    // p1 pipelines a call against answer 42. A closed session admits nothing,
    // the engine must refuse it at the state gate, before the pipelined-enqueue
    // pre-mutation, rather than queuing a call onto a dead session.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectError(error.SessionClosed, p2.step());

    // Nothing was queued onto the closed session.
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);
}

test "a multi-hop pipeline cycle terminates: a batch cannot be requeued onto an already-resolved answer" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 makes two calls to p2's export, allocating answers 1 and 2 (both pending
    // on p2).
    inline for (.{ 1, 2 }) |answer| {
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against promise(answer 1).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(1) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(99),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(1)).?.queued_calls);

    // p2 resolves answer 1 to promise(2): the queued call moves onto answer 2.
    // Resolving answer 1 settles it.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(2), .path = .{ .ops = &.{} } } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var f = p2.takeOutbound().?;
        f.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(2)).?.queued_calls);

    // p2 now resolves answer 2 back to promise(1) — the cycle's back-edge. Answer 1
    // is already resolved, so the batch cannot be requeued onto it: the drain fails
    // closed with InvalidReference and frees the batch (no infinite bounce, no leak,
    // no amplification). This is why a multi-hop cycle terminates without a
    // chain-history guard — resolving an answer settles it, and a settled answer
    // refuses a requeue.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(1), .path = .{ .ops = &.{} } } } } },
    } });
    try std.testing.expectError(error.InvalidReference, p2.step());
}

test "exceeding the local-delivery cap fails closed with a resource_exhausted abort" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // A cap of zero makes the very first local delivery the overflow.
    p2.session_state.limits.max_local_deliveries = 0;

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    try p2.session_state.registerExport(.from(9));

    // p1 calls p2's export, allocating answer 42 (pending on p2), then
    // pipelines a call against it.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // Resolving answer 42 to a local export drives one local delivery, past
    // the cap. The bound is partner-drivable, so the refusal must fail closed
    // like an inbound violation: typed abort on the wire, session closed.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try std.testing.expectError(error.LocalDeliveryCapExceeded, p2.step());
    try std.testing.expectEqual(session.State.closed, p2.session_state.state);

    // The resolve frame was encoded before the drain refused; the abort follows.
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    var abort_frame = p2.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, decoded.abort.kind);
}

test "a drain-time protocol violation in step fails closed like the inbound path" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 calls p2's export, allocating answer 42 (pending on p2), then
    // pipelines a call against it so the resolve below has a queue to drain.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // p2 resolves answer 42 to promise(42) itself: requeueing the drained call
    // back onto the resolving answer is a resolution cycle. The violation
    // surfaces at drain time — inside `step`, not on the inbound boundary —
    // and must still leave the session closed with the typed abort queued.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(42), .path = .{ .ops = &.{} } } } } },
    } });
    try std.testing.expectError(error.ResolutionCycle, p2.step());
    try std.testing.expectEqual(session.State.closed, p2.session_state.state);

    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    var abort_frame = p2.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.protocol_error, decoded.abort.kind);
}

test "a V1.0 resolver export survives the partner's gc of its wire mention" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    try p1.session_state.registerImport(.from(7));

    // Sending a deliver that wants an answer on a v1.0 session mints the
    // resolver export at encode time (`v1_0.installResolverForOutboundDeliver`) and puts
    // its mention on the wire, which must carry the same wire-delta retain
    // `recordSend` would have added: local reference + one wire mention.
    const resolver_export = p1.session_state.next_export_position;
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    {
        var deliver_frame = p1.takeOutbound().?;
        deliver_frame.deinit();
    }
    try std.testing.expectEqual(@as(u64, 2), p1.session_state.exportRefcount(.from(resolver_export)));

    // The partner releases the one wire mention. The local reference keeps the
    // export row alive, without the encode-time retain this gc would drive the
    // count to zero and remove the row while `v1_0_outbound_resolvers` still
    // points at it.
    {
        const positions = [_]u64{resolver_export};
        const deltas = [_]u64{1};
        const gc = try codec.syrup.encodeMessage(allocator, .{ .gc_export = .{
            .positions = &positions,
            .deltas = &deltas,
        } });
        try p1.feedOwned(gc);
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    {
        var gc_event = p1.pollEvent().?;
        gc_event.deinit();
    }
    try std.testing.expect(p1.session_state.hasExport(.from(resolver_export)));
    try std.testing.expectEqual(@as(u64, 1), p1.session_state.exportRefcount(.from(resolver_export)));

    // The partner's resolver callback still settles answer 42: the V1.0
    // translation seam routes a deliver to a known resolver export through
    // the resolver link (`answerForResolverExport`), not through the ADR-0074
    // near-target admission an ordinary export answers to, and the link's
    // whole point is surviving the released wire mention above. The callback
    // can only settle the answer we minted the resolver for, so no broader
    // authority rides on it.
    {
        const callback = try codec.syrup.encodeMessage(allocator, .{ .deliver = .{
            .target = .{ .far = model.FarRef.promise(resolver_export) },
            .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
            .answer = null,
        } });
        try p1.feedOwned(callback);
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    var resolve_event = p1.pollEvent().?;
    defer resolve_event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, resolve_event.kind());
}

test "a gc wave over many answered delivers drops every V1.0 resolver link" {
    // The outbound resolver link map is pruned per released answer through its
    // answer-keyed inverse (`v1_0_outbound_resolver_answers`), two O(1) keyed
    // removals per position instead of a scan of every outstanding link. This
    // pins the correctness half of that shape: after a full release wave every
    // link — and only the released links — is gone, and both map directions
    // agree. The linear-vs-quadratic win itself is a bench concern.
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    // Send a wave of answered delivers; encoding each mints its resolver
    // export in order (`v1_0.installResolverForOutboundDeliver`).
    const wave = 64;
    const first_resolver = peer.session_state.next_export_position;
    for (0..wave) |i| {
        try peer.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(i),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var frame = peer.takeOutbound().?;
        frame.deinit();
    }
    for (0..wave) |i| {
        try std.testing.expectEqual(
            @as(?model.AnswerPosition, .from(i)),
            peer.session_state.answerForResolverExport(.from(first_resolver + i)),
        );
    }

    // Release every answer but the last in one `op:gc-answers` wave: each
    // released answer's resolver link drops with its row, the survivor keeps
    // both directions of its link.
    var positions: [wave - 1]u64 = undefined;
    for (&positions, 0..) |*position, i| position.* = i;
    try peer.sendCopying(.{ .gc_answer = .{ .positions = &positions } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var frame = peer.takeOutbound().?;
        frame.deinit();
    }
    for (0..wave - 1) |i| {
        try std.testing.expectEqual(
            @as(?model.AnswerPosition, null),
            peer.session_state.answerForResolverExport(.from(first_resolver + i)),
        );
    }
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, .from(wave - 1)),
        peer.session_state.answerForResolverExport(.from(first_resolver + wave - 1)),
    );
}

test "a V1.0 break carrying a tagged record resolves to the tag name" {
    // Goblins marshals a thrown exception or a severed-session condition as a
    // tagged record, not a `desc:error`; the resolver-callback translation
    // keeps the tag as the break message instead of dropping to the generic
    // fallback.
    const tagged_args = [_]model.Argument{
        .{ .symbol = "break" },
        .{ .tagged = .{ .tag = "captp-session-severed", .value = &.{} } },
    };
    const tagged = try engine.events.resolutionFromResolverCallback(
        model.view.Args.fromOwnedSlice(&tagged_args),
    );
    try std.testing.expectEqualStrings("captp-session-severed", tagged.@"break".message);

    // The generic fallback still catches a payload with no usable text.
    const opaque_args = [_]model.Argument{
        .{ .symbol = "break" },
        .{ .integer = 7 },
    };
    const fallback = try engine.events.resolutionFromResolverCallback(
        model.view.Args.fromOwnedSlice(&opaque_args),
    );
    try std.testing.expectEqualStrings("remote promise broken", fallback.@"break".message);
}

test "an inbound listen without negotiated pipelining is refused before any install" {
    const allocator = std.testing.allocator;
    var features = model.FeatureSet.full();
    features.pipelining = false;
    var peer = peer_fixture.openPeerWith(allocator, .{ .features = features });
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    try peer.session_state.installInboundAnswer(.from(7));

    try std.testing.expectError(
        session.Error.FeatureNotNegotiated,
        peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>>", .shape = .byte }),
    );
    // The refusal ran before the engine's listener install mutated anything:
    // no listener row on the answer, no import of the nominated listener, and
    // nothing surfaced.
    try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(7)).?.listeners);
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));
    try std.testing.expect(peer.pollEvent() == null);
}

test "an inbound listen naming an unheld export is refused before any install" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    // Answer 7 exists — so an install-before-validate engine would have hung a
    // listener on it — but export 7 was never registered, so the listen names
    // an unheld target and session validation refuses it.
    try peer.session_state.installInboundAnswer(.from(7));

    try std.testing.expectError(
        session.Error.InvalidReference,
        peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>>", .shape = .byte }),
    );
    try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(7)).?.listeners);
    try std.testing.expect(!peer.session_state.hasImport(.from(9)));
    try std.testing.expect(peer.pollEvent() == null);
}

test "view and decodeOwned agree on a V1.0 resolver-callback deliver" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.wire_profile = model.WireProfile.v1_0;
    try peer.session_state.registerImport(.from(7));

    // An answered deliver mints resolver export 1 at encode time.
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .bytes = "hi" }},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var outbound = peer.takeOutbound().?;
        outbound.deinit();
    }

    // The partner settles answer 42 through the resolver callback.
    const callback = try codec.syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
        .answer = null,
    } });
    try peer.feedOwned(callback);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());

    // The two projections may not disagree about what this frame is: both the
    // borrowed view and the owned materialization surface the translated
    // semantic Resolve, never the raw callback deliver.
    const view = try event.view();
    try std.testing.expect(view == .resolve);
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());

    const owned = try event.decodeOwned(allocator);
    defer model.freeMessage(allocator, owned);
    try std.testing.expect(owned == .resolve);
    try std.testing.expectEqual(@as(u64, 42), owned.resolve.answer.int());
    try std.testing.expect(owned.resolve.resolution == .fulfill);
    try std.testing.expectEqual(@as(i64, 17), owned.resolve.resolution.fulfill.integer);
}
