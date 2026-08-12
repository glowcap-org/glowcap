const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const peer_fixture = @import("../support/peer_fixture.zig");

test "originated handoff transaction requires distinct peer sessions" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();

    try std.testing.expectError(error.AliasedHandoffPeers, engine.handoff_gifter.queueOriginatedGive(
        &peer,
        &peer,
        "gift",
        .{ .far = model.FarRef.object(1) },
        "give",
        .{ .answer = .from(1) },
    ));
}

test "failed withdraw construction does not consume its handoff count" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    const recipient_secret = foundation.crypto.SecretKey.fromSeed([_]u8{0x35} ** foundation.crypto.SEED_BYTES);

    try std.testing.expectError(
        codec.syrup.Error.MalformedFrame,
        pair.p1.sendWithdrawGift(recipient_secret, "not a signed give", .from(1)),
    );
    try std.testing.expectEqual(@as(u64, 0), pair.p1.giftRegistry().next_emitted_handoff_count);

    const exporter_location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9000",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(exporter_location);
    const gifter_secret = foundation.crypto.SecretKey.fromSeed([_]u8{0x36} ** foundation.crypto.SEED_BYTES);
    const give = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_secret.publicKey().asBytes(),
        exporter_location,
        &([_]u8{0x37} ** 32),
        &([_]u8{0x38} ** 32),
        "gift",
    );
    defer allocator.free(give);

    try pair.p1.sendWithdrawGift(recipient_secret, give, .from(1));
    try std.testing.expectEqual(@as(u64, 1), pair.p1.giftRegistry().next_emitted_handoff_count);
    try pair.p1.stepToIdle();
    var frame = pair.p1.takeOutbound().?;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
    const receive = (try body.deliver.args.at(1)).handoff.receive;
    try std.testing.expectEqual(@as(u64, 0), receive.handoff_count);
}

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

test "raw-open fixture peer is already open on v1.0, not next" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initRawOpenFixture(allocator);
    defer peer.deinit();

    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.v1_0, peer.session_state.captp_version);
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

test "malformed V1.0 deliver cannot install its advertised resolver" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initRawOpenFixture(allocator);
    defer peer.deinit();

    // Export 404 was never granted to the partner. The resolver descriptor is
    // otherwise valid, but no authority from this refused deliver may survive.
    const wire = "<10'op:deliver<11'desc:export404+>[]f<19'desc:import-promise99+>>";
    try std.testing.expectError(
        session.Error.InvalidReference,
        peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }),
    );

    try std.testing.expect(!peer.session_state.hasImport(.from(99)));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, null),
        peer.session_state.answerForResolverImport(.from(99)),
    );
}

test "settled-answer encode OOM leaves its carrier queued and emits exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = engine.Peer.initRawOpenFixture(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Queue 130 store-backed carriers, then consume 64. The next encode runs
    // with a long dead prefix, proving the borrowed-front path does not need to
    // mutate or compact the FIFO before its fallible consequence succeeds.
    for (0..130) |offset| {
        const answer = 1_000 + offset;
        const wire = try std.fmt.allocPrint(
            std.testing.allocator,
            "<10'op:deliver<11'desc:export7+>[]{d}+<19'desc:import-promise{d}+>>",
            .{ answer, 2_000 + offset },
        );
        defer std.testing.allocator.free(wire);
        try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });
        var event = peer.pollEvent().?;
        event.deinit();
        try peer.sendCopying(.{ .resolve = .{
            .answer = .from(answer),
            .resolution = .{ .fulfill = .{ .integer = @intCast(offset) } },
        } });
    }
    for (0..64) |_| {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var outbound = peer.takeOutbound().?;
        outbound.deinit();
    }

    // Fail before the 65th POD carrier is consumed. The answer store still
    // owns the resolution, and the FIFO must still own the same front carrier.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var outbound = peer.takeOutbound() orelse return error.MissingRetriedResolve;
    outbound.deinit();

    // Drain the suffix and prove the retained carrier neither duplicated nor
    // displaced anything after the retry.
    var remaining: usize = 65;
    while (remaining != 0) : (remaining -= 1) {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var next = peer.takeOutbound() orelse return error.MissingQueuedResolve;
        next.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "V1.0 answered-deliver encode OOM rolls back resolver authority and retries" {
    var saw_post_mint_oom = false;
    var saw_success = false;

    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.Peer.initRawOpenFixture(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);
        try peer.session_state.registerImport(.from(7));

        const answer = model.AnswerPosition.from(42);
        const first_resolver = peer.session_state.next_export_position;
        try peer.sendCopying(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{.{ .bytes = "payload" }},
            .answer = answer,
        } });

        failing.fail_index = failing.alloc_index + offset;
        const attempt = peer.step();
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |outcome| {
            saw_success = true;
            try std.testing.expectEqual(engine.StepOutcome.progress, outcome);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(peer.takeOutbound() == null);
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }),
            );
            if (peer.session_state.next_export_position > first_resolver)
                saw_post_mint_oom = true;

            // The same staged carrier remains authoritative. Retrying mints one
            // fresh resolver and publishes exactly one answered deliver.
            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        }

        const resolver = peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }) orelse
            return error.MissingRetriedResolver;
        try std.testing.expect(peer.session_state.exportRefcount(resolver) != 0);
        var frame = peer.takeOutbound() orelse return error.MissingRetriedDeliver;
        frame.deinit();
        try std.testing.expect(peer.takeOutbound() == null);
        try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    }

    try std.testing.expect(saw_post_mint_oom);
    try std.testing.expect(saw_success);
}

test "V1.0 projection encode OOM publishes neither half and retries atomically" {
    var saw_post_mint_oom = false;
    var saw_success = false;

    for (0..40) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.Peer.initRawOpenFixture(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);
        try peer.session_state.registerImport(.from(9));

        const answer = model.AnswerPosition.from(5);
        const first_resolver = peer.session_state.next_export_position;
        try peer.sendCopying(.{ .get = .{
            .receiver = .{ .far = model.FarRef.object(9) },
            .field = "name",
            .answer = answer,
        } });

        failing.fail_index = failing.alloc_index + offset;
        const attempt = peer.step();
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |outcome| {
            saw_success = true;
            try std.testing.expectEqual(engine.StepOutcome.progress, outcome);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            // The projection and mandatory listener are one publication: an
            // allocator failure may expose neither, and no resolver link may
            // survive for a mention the partner never received.
            try std.testing.expect(peer.takeOutbound() == null);
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }),
            );
            if (peer.session_state.next_export_position > first_resolver)
                saw_post_mint_oom = true;

            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        }

        _ = peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }) orelse
            return error.MissingProjectionResolver;
        var projection = peer.takeOutbound() orelse return error.MissingProjectionFrame;
        projection.deinit();
        var listener = peer.takeOutbound() orelse return error.MissingProjectionListener;
        listener.deinit();
        try std.testing.expect(peer.takeOutbound() == null);
        try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    }

    try std.testing.expect(saw_post_mint_oom);
    try std.testing.expect(saw_success);
}

test "outbound waterline refuses one arbitrarily large producer before authority moves" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initRawOpenFixture(allocator);
    defer peer.deinit();
    peer.outbound_budget = 256;
    try peer.session_state.registerImport(.from(7));

    const oversized = [_]u8{0x5a} ** 512;
    try std.testing.expectError(error.OutboundBackpressure, peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = &oversized }},
        .answer = .from(19),
    } }));

    try std.testing.expect(peer.session_state.outboundAnswer(.from(19)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "one inbound frame admits its maintenance carriers as one outbound producer" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));
    try peer.session_state.registerExport(.from(7));

    // Park an older producer immediately below the waterline. The incoming
    // frame introduces two promises, so next owes two shortening listeners.
    // They are one consequence of one accepted frame: the first may cross the
    // line, but the second must not be mistaken for a new producer and refuse
    // the otherwise atomic inbound transaction.
    const ballast = [_]u8{0x5a} ** 512;
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(9) },
        .args = &.{.{ .bytes = &ballast }},
    } });
    peer.outbound_budget = peer.queuedOutboundBytes() + 1;

    var inbound = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{
            .{ .reference = .{ .near = model.NearRef.promise(5) } },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } });
    defer inbound.deinit();
    try peer.recvBorrowed(inbound.view());
    var event = peer.pollEvent() orelse return error.MissingDeliverEvent;
    defer event.deinit();

    var shortening_listens: usize = 0;
    while (true) {
        const outcome = try peer.step();
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            defer frame.deinit();
            const body = try codec.syrup.decodeBodyForProfile(.next, frame.view());
            if (body == .listen and body.listen.mode == .shortening_only)
                shortening_listens += 1;
        }
        if (outcome == .idle) break;
    }
    try std.testing.expectEqual(@as(usize, 2), shortening_listens);
}

test "queued inbound backpressure aborts instead of dropping the frame" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));
    peer.outbound_budget = 1;

    const inbound = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .reference = .{ .near = model.NearRef.promise(5) } }},
    } });
    try peer.feedOwned(inbound);

    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expect(!peer.sessionIsOpen());
    var abort_frame = peer.takeOutbound() orelse return error.MissingAbort;
    defer abort_frame.deinit();
    const abort = try codec.syrup.decodeBodyForProfile(.next, abort_frame.view());
    try std.testing.expect(abort == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.abort.kind);
    try std.testing.expect(peer.takeOutbound() == null);
}

test "queued local encode backpressure remains retryable and does not abort" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "retry" }},
    } });
    peer.outbound_budget = 0;
    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expect(peer.lastAbort() == null);
    try std.testing.expect(peer.takeOutbound() == null);

    peer.outbound_budget = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound() orelse return error.MissingDeliverFrame;
    frame.deinit();
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
        "<10'op:deliver<11'desc:export7+>[5:hello]42+>",
        outbound.bytes(),
    );
}

test "peer step uses session CapTP version for outbound encoding" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
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

test "V1.0 resolver-only registration rolls back its virtual answer on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var peer = engine.Peer.init(failing.allocator());
    defer {
        failing.fail_index = std.math.maxInt(usize);
        peer.deinit();
    }
    peer.session_state.captp_version = .v1_0;

    const message: model.Message = .{ .deliver = .{
        .target = .{ .near = model.NearRef.object(session.BOOTSTRAP_POSITION) },
        .args = &.{},
        .resolve_me_desc = .{ .far = model.FarRef.object(7) },
    } };
    const deliver = model.view.Body.fromOwned(&message).deliver;
    const virtual = model.AnswerPosition.from(session.VIRTUAL_INBOUND_ANSWER_BASE);

    // The answer-table allocation succeeds; the following import-table
    // allocation fails. Neither half of the resolver-only authority may remain.
    try std.testing.expectError(error.OutOfMemory, engine.v1_0.registerPartnerResolver(&peer, deliver));
    try std.testing.expect(!peer.session_state.hasInboundAnswer(virtual));
    try std.testing.expect(!peer.session_state.holdsImport(.from(7)));
    try std.testing.expect(peer.session_state.resolverForInboundAnswer(virtual) == null);

    // Monotonic positions are not reused after rollback. A clean retry installs
    // exactly one complete answer/resolver pair at the next virtual position.
    failing.fail_index = std.math.maxInt(usize);
    const retried = (try engine.v1_0.registerPartnerResolver(&peer, deliver)).?;
    try std.testing.expectEqual(virtual.int() + 1, retried.int());
    try std.testing.expect(peer.session_state.hasInboundAnswer(retried));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(7)),
        peer.session_state.resolverForInboundAnswer(retried),
    );
}

test "a rejected next answer reuse preserves the original resolver" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try std.testing.expectError(session.Error.UnexpectedMessage, peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } }));
    try std.testing.expectEqual(
        @as(?model.AnswerPosition, .from(42)),
        peer.session_state.answerForResolverExport(resolver),
    );

    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const resolved = try event.view();
    try std.testing.expectEqual(@as(u64, 42), resolved.resolve.answer.int());
}

test "a next answered operation publishes no partial pair on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = peer_fixture.openPeer(failing.allocator());
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try peer.session_state.registerImport(.from(7));

    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "answer me" }},
        .answer = .from(42),
    } });

    // Let the operation frame allocate, then fail before the pair can be
    // published. The retry must still own and emit both messages.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var operation = peer.takeOutbound().?;
    defer operation.deinit();
    var listener = peer.takeOutbound().?;
    defer listener.deinit();
    try std.testing.expect(peer.takeOutbound() == null);

    const operation_body = try codec.syrup.decodeBodyForProfile(.next, operation.view());
    const listener_body = try codec.syrup.decodeBodyForProfile(.next, listener.view());
    try std.testing.expect(operation_body == .deliver);
    try std.testing.expect(listener_body == .listen);
    try std.testing.expectEqual(@as(u64, 42), operation_body.deliver.answer.?.int());
    try std.testing.expectEqual(@as(u64, 42), listener_body.listen.target.promise.answer_position.int());
}

test "V1_0 runtime translation synthesizes resolve-me-desc for answered deliver" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
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
        "<10'op:deliver<11'desc:export7+>[5:hello]42+<18'desc:import-object1+>>",
        outbound.bytes(),
    );
    try std.testing.expect(peer.session_state.hasExport(.from(1)));
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), peer.session_state.answerForResolverExport(.from(1)));
}

test "V1_0 resolve for an answer whose deliver carried no resolver emits nothing" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
    try peer.session_state.registerExport(.from(7));

    // Inbound V1.0 deliver naming answer 11 with `f` where a resolve-me-desc
    // would ride: the partner asked for no callback.
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]11+f>", .shape = .byte });
    var event = peer.pollEvent().?;
    event.deinit();

    // The application answers anyway. V1.0 has no `op:resolve` wire shape,
    // and no resolver was advertised, so there is nobody to notify: the
    // resolve settles the answer locally and puts nothing on the wire. The
    // drop is the contract (the guard in `outbound.emitOutboundMessage`),
    // pinned here so it stays a decision rather than an accident.
    try peer.sendCopying(.{ .resolve = .{
        .answer = .from(11),
        .resolution = .{ .fulfill = .{ .integer = 1 } },
    } });
    _ = try peer.step();
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.pollEvent() == null);
}

test "V1_0 resolver-callback resolving to a container registers the introduced import" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
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
        "<10'op:deliver<11'desc:export7+>[5:hello]42+>",
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
        "<10'op:deliver<11'desc:export7+>[<2'kw4'name><11'user-record5'point[1+2+]>#1+2+3+$]42+>",
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

test "recvBorrowed surfaces inbound get, index, and listen events" {
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
        try std.testing.expectEqual(@as(i64, 5), (try event.view()).index.index.integer);
    }
    // Likewise op:index is surfaced and its projected answer exported.
    try std.testing.expect(peer.session_state.inboundAnswer(.from(12)) != null);

    try peer.recvBorrowed(.{ .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>3+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.listen, event.kind());
        // `<desc:import-object 9>` listener decodes to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), (try event.view()).listen.listener.far.import_position.int());
    }
    // Live object export 7 has no inbound answer row: CapTP already-settled
    // target fires fulfill(near 7) to the listener immediately.
    while ((try peer.step()) != .idle) {}
    {
        const out = try peer_fixture.drainOutbound(&peer, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "fulfill") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "desc:import-object") != null or std.mem.indexOf(u8, out, "desc:export") != null);
    }
}

test "next refuses wire op:resolve" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(99));
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(99) } },
        .args = &.{},
        .answer = .from(42),
    } });

    try std.testing.expectError(
        codec.syrup.Error.UnsupportedMessage,
        peer.recvBorrowed(.{ .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>", .shape = .byte }),
    );
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.outboundAnswer(.from(42)).?.status);
    try std.testing.expect(peer.pollEvent() == null);
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

    // Open question 42 through the normal send path. A pipeline target is an
    // answer we actually hold, not merely an integer with answer syntax.
    try peer.session_state.registerImport(.from(7));
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var opening_frame = peer.takeOutbound().?;
    opening_frame.deinit();

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
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
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

test "an app-queued op:abort commits outbound then closes the CapTP session" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);
    // recordSend must not close — the partner still needs to take the frame
    // after step encodes it.
    try pair.p1.sendCopying(.{ .abort = .{ .kind = .graceful_shutdown, .message = "done" } });
    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);

    _ = try pair.p1.step();
    try std.testing.expectEqual(session.State.closed, pair.p1.session_state.state);

    var abort_frame = pair.p1.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.graceful_shutdown, decoded.abort.kind);
    try std.testing.expectEqualStrings("done", decoded.abort.message);

    try std.testing.expectError(
        session.Error.SessionClosed,
        pair.p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &.{},
        } }),
    );
}

test "a closing projected abort still closes when the abort frame cannot allocate" {
    var failing = FailAfterAllocator{
        .backing = std.testing.allocator,
        .fail_after = std.math.maxInt(usize),
    };
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try std.testing.expectEqual(session.State.open, peer.session_state.state);

    // Own the garbage with the real testing allocator so feed does not touch
    // the failing peer allocator; the next peer alloc is abort encode/push.
    const storage = try std.testing.allocator.dupe(u8, "this is not a syrup frame");
    const frame = try foundation.Frame.initOwned(
        std.testing.allocator,
        storage,
        .byte,
        .fromByteUnits(1),
    );
    try peer.feedOwned(frame);
    failing.fail_after = failing.allocation_count;
    try std.testing.expectError(error.MalformedFrame, peer.step());

    try std.testing.expectEqual(session.State.closed, peer.session_state.state);
    try std.testing.expect(peer.takeOutbound() == null);
    const cause = peer.lastAbort().?;
    try std.testing.expectEqual(model.AbortKind.malformed_frame, cause.kind.?);
}

test "a malformed inbound frame emits a malformed-frame abort and closes" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
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
    // resolver export at encode time (`v1_0.prepareOutboundDeliver`) and puts
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
    // count to zero and remove the row while `outbound_resolver_link` still
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
    // answer side of the `outbound_resolver_link` BiMap, two O(1) keyed
    // removals per position instead of a scan of every outstanding link. This
    // pins the correctness half of that shape: after a full release wave every
    // link — and only the released links — is gone, and both map directions
    // agree. The linear-vs-quadratic win itself is a bench concern.
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));

    // Send a wave of answered delivers; encoding each mints its resolver
    // export in order (`v1_0.prepareOutboundDeliver`).
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

test "inbound op:listen export matrix: refuse, fire live object, refuse bare promise" {
    // One table for the export-side listen chokepoint (validate → installExportListener).
    const allocator = std.testing.allocator;
    const wire = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>3+>";

    {
        var features = model.FeatureSet.full();
        features.pipelining = false;
        var peer = peer_fixture.openPeerWith(allocator, .{ .features = features });
        defer peer.deinit();
        try peer.session_state.registerExport(.from(7));
        try peer.session_state.installInboundAnswer(.from(7));
        try std.testing.expectError(
            session.Error.FeatureNotNegotiated,
            peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }),
        );
        try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(7)).?.listeners);
        try std.testing.expect(!peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.pollEvent() == null);
    }
    {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        try peer.session_state.installInboundAnswer(.from(7));
        try std.testing.expectError(
            session.Error.InvalidReference,
            peer.recvBorrowed(.{ .bytes = wire, .shape = .byte }),
        );
        try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(7)).?.listeners);
        try std.testing.expect(!peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.pollEvent() == null);
    }
    {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        try peer.session_state.registerExport(.from(7));
        try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });
        {
            var event = peer.pollEvent().?;
            defer event.deinit();
            try std.testing.expectEqual(engine.EventKind.listen, event.kind());
        }
        try std.testing.expect(peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.session_state.inboundAnswer(.from(7)) == null);
        while ((try peer.step()) != .idle) {}
        const out = try peer_fixture.drainOutbound(&peer, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "op:deliver") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fulfill") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "desc:import-object") != null);
    }
    {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        const promise_export = try peer.session_state.allocatePromiseExport();
        try peer.session_state.registerExport(promise_export);
        const listen_bytes = try std.fmt.allocPrint(
            allocator,
            "<9'op:listen<11'desc:export{d}+><18'desc:import-object9+>3+>",
            .{promise_export.int()},
        );
        defer allocator.free(listen_bytes);
        try std.testing.expectError(
            session.Error.InvalidReference,
            peer.recvBorrowed(.{ .bytes = listen_bytes, .shape = .byte }),
        );
        try std.testing.expect(!peer.session_state.hasImport(.from(9)));
        try std.testing.expect(peer.pollEvent() == null);
    }
}

test "live object export listen: OOM during enqueue does not leak" {
    var fail_index: usize = 0;
    var saw_oom = false;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var peer = peer_fixture.openPeer(failing.allocator());
        defer peer.deinit();
        peer.session_state.registerExport(.from(7)) catch {
            saw_oom = true;
            continue;
        };
        const listen = peer.recvBorrowed(.{
            .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>3+>",
            .shape = .byte,
        });
        if (listen) |_| {
            while (peer.pollEvent()) |event_value| {
                var event = event_value;
                event.deinit();
            }
            while (true) {
                const step = peer.step() catch {
                    saw_oom = true;
                    break;
                };
                if (step == .idle) break;
            }
        } else |_| {
            saw_oom = true;
        }
    }
    try std.testing.expect(saw_oom);
}

test "view and decodeOwned agree on a V1.0 resolver-callback deliver" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    peer.session_state.captp_version = model.CaptpVersion.v1_0;
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

test "a private shortening callback rewrites future sends and subscribes to the returned promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expect(peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    var recursive = peer.takeOutbound().?;
    defer recursive.deinit();
    const recursive_body = try codec.syrup.decodeBodyForProfile(.next, recursive.view());
    try std.testing.expect(recursive_body == .listen);
    try std.testing.expectEqual(@as(u64, 6), recursive_body.listen.target.near.export_position.int());
    try std.testing.expectEqual(model.ListenMode.shortening_only, recursive_body.listen.mode);
    try std.testing.expect(peer.takeOutbound() == null);

    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &.{.{ .integer = 1 }},
    } });
    while ((try peer.step()) != .idle) {}
    var forwarded = peer.takeOutbound().?;
    defer forwarded.deinit();
    const forwarded_body = try codec.syrup.decodeBodyForProfile(.next, forwarded.view());
    try std.testing.expect(forwarded_body == .deliver);
    try std.testing.expectEqual(@as(u64, 6), forwarded_body.deliver.target.near.export_position.int());
    try std.testing.expect(peer.takeOutbound() == null);

    try std.testing.expectError(session.Error.UnexpectedMessage, peer.recvBorrowed(callback.view()));
}

test "an application settling listener follows a remote promise shortening" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const settling_resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());

    while ((try peer.step()) != .idle) {}
    var private = peer.takeOutbound().?;
    defer private.deinit();
    var rearmed = peer.takeOutbound().?;
    defer rearmed.deinit();
    const private_body = try codec.syrup.decodeBodyForProfile(.next, private.view());
    const rearmed_body = try codec.syrup.decodeBodyForProfile(.next, rearmed.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, private_body.listen.mode);
    try std.testing.expectEqual(model.ListenMode.settling_only, rearmed_body.listen.mode);
    try std.testing.expectEqual(@as(u64, 6), rearmed_body.listen.target.near.export_position.int());
    try std.testing.expectEqual(settling_resolver.int(), rearmed_body.listen.listener.far.import_position.int());

    const settlement_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .integer = 17 },
    };
    var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(settling_resolver.int()) },
        .args = &settlement_args,
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    const resolved = try event.view();
    try std.testing.expectEqual(answer, resolved.resolve.answer);
}

test "converging remote promises share one settling callback across local answers" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));
    try peer.session_state.registerImport(.from(6));

    const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    const shortening_six = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(6));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const answer_five = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const resolver_five = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?;
    const answer_six = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(6) });
    const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_five.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    try std.testing.expect(peer.pollEvent() == null);
    while ((try peer.step()) != .idle) {}
    // Promise 6 already owns both permitted wire listeners. Convergence is a
    // local fan-out change and emits no second settling listener.
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(shortening_six) != null);
    try std.testing.expect(peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }) == null);
    try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?);
    try std.testing.expect(peer.session_state.exportSlot(resolver_five) != null);

    const settlement_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .integer = 17 },
    };
    var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver_six.int()) },
        .args = &settlement_args,
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    const resolved = try event.view();
    try std.testing.expectEqual(answer_six, resolved.resolve.answer);
    try std.testing.expectEqualSlices(model.AnswerPosition, &.{answer_five}, event.resolveAliases());
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(answer_five).?.status);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.outboundAnswer(answer_six).?.status);
    try std.testing.expect(peer.pollEvent() == null);
}

test "converged settling callback promotes or removes a released local answer" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |release_primary| {
        var peer = peer_fixture.openPeer(allocator);
        defer peer.deinit();
        try peer.session_state.registerImport(.from(5));
        try peer.session_state.registerImport(.from(6));

        const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
        try engine.listen.ensureShorteningListener(&peer, .from(5));
        try engine.listen.ensureShorteningListener(&peer, .from(6));
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }

        const answer_five = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
        const answer_six = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(6) });
        const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
            .application_answer = answer_six,
        }).?;
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }

        var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(shortening_five.int()) },
            .args = &.{
                .{ .symbol = "fulfill" },
                .{ .reference = .{ .near = model.NearRef.promise(6) } },
            },
        } });
        defer shortening.deinit();
        try peer.recvBorrowed(shortening.view());
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }

        const released = if (release_primary) answer_six else answer_five;
        const survivor = if (release_primary) answer_five else answer_six;
        try peer.sendCopying(.{ .gc_answer = .{ .positions = &.{released.int()} } });
        while ((try peer.step()) != .idle) {}
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        try std.testing.expect(peer.session_state.outboundAnswer(released) == null);
        try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
            .application_answer = survivor,
        }).?);

        var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(resolver_six.int()) },
            .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
        } });
        defer settlement.deinit();
        try peer.recvBorrowed(settlement.view());
        var event = peer.pollEvent().?;
        defer event.deinit();
        const resolved = try event.view();
        try std.testing.expectEqual(survivor, resolved.resolve.answer);
        try std.testing.expectEqual(@as(usize, 0), event.resolveAliases().len);
    }
}

test "a settling callback racing answer release is consumed and its imports are released" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendCopying(.{ .gc_answer = .{ .positions = &.{answer.int()} } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expectEqual(session.RetiredResolverState.pending, peer.session_state.retiredResolverState(resolver).?);

    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.object(77) } },
        },
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expectEqual(session.RetiredResolverState.complete, peer.session_state.retiredResolverState(resolver).?);
    while ((try peer.step()) != .idle) {}
    var release = peer.takeOutbound().?;
    defer release.deinit();
    const release_body = try codec.syrup.decodeBodyForProfile(.next, release.view());
    try std.testing.expectEqual(@as(usize, 1), try release_body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 77), try release_body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(usize, 1), try release_body.gc_export.deltas.len());
    try std.testing.expectEqual(@as(u64, 1), try release_body.gc_export.deltas.at(0));
    try std.testing.expect(peer.takeOutbound() == null);

    try std.testing.expectError(session.Error.UnexpectedMessage, peer.recvBorrowed(callback.view()));
}

test "settling convergence OOM leaves both subscriptions retryable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = peer_fixture.openPeer(failing.allocator());
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try peer.session_state.registerImport(.from(5));
    try peer.session_state.registerImport(.from(6));

    const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    try engine.listen.ensureShorteningListener(&peer, .from(6));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    const answer_five = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const resolver_five = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?;
    const answer_six = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(6) });
    const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_five.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } };
    var failed_frame = try codec.syrup.encodeMessageForProfile(std.testing.allocator, .next, shortening_message);
    defer failed_frame.deinit();
    // The borrowed-frame ownership copy succeeds; the next allocation belongs
    // to callback validation or the precommitted merged follower list.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, peer.recvBorrowed(failed_frame.view()));
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(resolver_five, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }).?);
    try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?);
    try std.testing.expectEqual(
        model.ImportPosition.from(5),
        peer.session_state.shortenedPromiseTarget(.from(5)),
    );

    try peer.recvBorrowed(failed_frame.view());
    try std.testing.expect(peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_five,
    }) == null);
    try std.testing.expectEqual(resolver_six, peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?);
}

test "an application settling listener starts at an already-shortened promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    _ = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    while ((try peer.step()) != .idle) {}
    var settling = peer.takeOutbound().?;
    defer settling.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, settling.view());
    try std.testing.expectEqual(model.ListenMode.settling_only, body.listen.mode);
    try std.testing.expectEqual(@as(u64, 6), body.listen.target.near.export_position.int());
}

test "a shortened deliver moves to the new position and stays on one wire" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const before_args = [_]model.Argument{.{ .symbol = "before" }};
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &before_args,
    } });
    while ((try peer.step()) != .idle) {}
    var before = peer.takeOutbound() orelse return error.MissingDeliverBeforeShortening;
    defer before.deinit();

    // The partner shortens promise 5 onto promise 6.
    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expectEqual(
        model.ImportPosition.from(6),
        peer.session_state.shortenedPromiseTarget(.from(5)),
    );

    const after_args = [_]model.Argument{.{ .symbol = "after" }};
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &after_args,
    } });
    while ((try peer.step()) != .idle) {}
    var after = peer.takeOutbound() orelse return error.MissingDeliverAfterShortening;
    defer after.deinit();

    // The send chokepoint retargets the later deliver onto the shortened
    // position, and that position is an import of this same session. Both
    // frames therefore leave on one wire in send order, the local half of the
    // end-to-end reference FIFO order OCapN PR 281 asks to survive shortening.
    // An edge naming another session would split the pair across two wires.
    const before_body = try codec.syrup.decodeBodyForProfile(.next, before.view());
    const after_body = try codec.syrup.decodeBodyForProfile(.next, after.view());
    try std.testing.expectEqual(@as(u64, 5), before_body.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(u64, 6), after_body.deliver.target.near.export_position.int());
    try std.testing.expect(peer.session_state.holdsImport(.from(6)));
    try std.testing.expect(std.mem.indexOf(u8, before.storage, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.storage, "after") != null);
}

test "a delayed shortening callback cannot rewrite a reused import position" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const stale_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const positions = [_]u64{5};
    const deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

    // The partner may now reuse position 5 for a distinct promise. Its private
    // listener carries a fresh row stamp even though the wire integer is the
    // same.
    try peer.session_state.registerImport(.from(5));
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(stale_resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expect(peer.session_state.holdsImport(.from(5)));
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(5) },
        .args = &.{},
    } });
    while ((try peer.step()) != .idle) {}
    var sent = peer.takeOutbound().?;
    defer sent.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, sent.view());
    try std.testing.expectEqual(@as(u64, 5), body.deliver.target.near.export_position.int());
}

test "shortening callback OOM leaves protocol maintenance uncommitted" {
    const allocator = std.testing.allocator;
    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &callback_args,
    } });
    defer callback.deinit();

    var saw_callback_oom = false;
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 128 and !reached_success) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var peer = peer_fixture.openPeer(failing.allocator());
        defer peer.deinit();
        // Teardown may allocate after an injected failure leaves the counter
        // parked, so disarm before the peer's defer runs.
        defer failing.fail_index = std.math.maxInt(usize);

        peer.session_state.registerImport(.from(5)) catch continue;
        engine.listen.ensureShorteningListener(&peer, .from(5)) catch continue;
        while (true) {
            const outcome = peer.step() catch break;
            if (outcome == .idle) break;
        }
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        if (peer.session_state.sourceForShorteningResolver(.from(1)) == null) continue;

        if (peer.recvBorrowed(callback.view())) |_| {
            reached_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_callback_oom = true;
            try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
            switch (peer.session_state.sourceForShorteningResolver(.from(1)).?) {
                .pending => |source| try std.testing.expectEqual(model.ImportPosition.from(5), source.position),
                .complete => return error.TestExpectedPendingShortening,
            }
            try std.testing.expect(peer.session_state.findImportedPromise(.from(6)) == null);
        }
    }
    try std.testing.expect(saw_callback_oom);
    try std.testing.expect(reached_success);
}

test "late shortening callback OOM does not retain its introduced promise" {
    const allocator = std.testing.allocator;
    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &callback_args,
    } });
    defer callback.deinit();

    var saw_callback_oom = false;
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 128 and !reached_success) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var peer = peer_fixture.openPeer(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);

        peer.session_state.registerImport(.from(5)) catch continue;
        engine.listen.ensureShorteningListener(&peer, .from(5)) catch continue;
        while (true) {
            const outcome = peer.step() catch break;
            if (outcome == .idle) break;
        }
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        if (peer.session_state.sourceForShorteningResolver(.from(1)) == null) continue;

        const positions = [_]u64{5};
        const deltas = [_]u64{1};
        peer.session_state.recordSend(.{ .gc_export = .{
            .positions = @constCast(&positions),
            .deltas = @constCast(&deltas),
        } }) catch continue;
        try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

        if (peer.recvBorrowed(callback.view())) |_| {
            reached_success = true;
            try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_callback_oom = true;
            try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
            switch (peer.session_state.sourceForShorteningResolver(.from(1)).?) {
                .pending => |source| try std.testing.expectEqual(model.ImportPosition.from(5), source.position),
                .complete => return error.TestExpectedPendingShortening,
            }
        }
    }
    try std.testing.expect(saw_callback_oom);
    try std.testing.expect(reached_success);
}

test "a shortening callback crossing source release returns its introduced promise" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const source_positions = [_]u64{5};
    const source_deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &source_positions, .deltas = &source_deltas } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.pollEvent() == null);
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    var released_target = peer.takeOutbound().?;
    defer released_target.deinit();
    const released_body = try codec.syrup.decodeBodyForProfile(.next, released_target.view());
    try std.testing.expect(released_body == .gc_export);
    try std.testing.expectEqual(@as(usize, 1), try released_body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 6), try released_body.gc_export.positions.at(0));
    try std.testing.expect(peer.takeOutbound() == null);

    const resolver_positions = [_]u64{resolver.int()};
    const resolver_deltas = [_]u64{1};
    var release_resolver = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .gc_export = .{
        .positions = &resolver_positions,
        .deltas = &resolver_deltas,
    } });
    defer release_resolver.deinit();
    try peer.recvBorrowed(release_resolver.view());
    var gc_event = peer.pollEvent().?;
    gc_event.deinit();
    try std.testing.expect(peer.session_state.exportSlot(resolver) == null);
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(resolver) == null);
    try std.testing.expect(peer.session_state.findImportedPromise(.from(5)) == null);
}

test "a settling listener follows shortening after its source import is released" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const settling_resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendCopying(.{ .gc_export = .{
        .positions = &.{5},
        .deltas = &.{1},
    } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));

    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    try std.testing.expect(peer.pollEvent() == null);
    while ((try peer.step()) != .idle) {}

    var shortening_listen = peer.takeOutbound().?;
    defer shortening_listen.deinit();
    var settling_listen = peer.takeOutbound().?;
    defer settling_listen.deinit();
    var release_target = peer.takeOutbound().?;
    defer release_target.deinit();
    const shortening_body = try codec.syrup.decodeBodyForProfile(.next, shortening_listen.view());
    const settling_body = try codec.syrup.decodeBodyForProfile(.next, settling_listen.view());
    const release_body = try codec.syrup.decodeBodyForProfile(.next, release_target.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, shortening_body.listen.mode);
    try std.testing.expectEqual(model.ListenMode.settling_only, settling_body.listen.mode);
    try std.testing.expectEqual(settling_resolver.int(), settling_body.listen.listener.far.import_position.int());
    try std.testing.expectEqual(@as(u64, 6), try release_body.gc_export.positions.at(0));
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));
    try std.testing.expect(peer.takeOutbound() == null);

    var settlement = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(settling_resolver.int()) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .integer = 17 } },
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    const resolved = try event.view();
    try std.testing.expectEqual(answer, resolved.resolve.answer);
    try std.testing.expectEqual(@as(i64, 17), resolved.resolve.resolution.fulfill.integer);
}

test "shortening does not rearm a settling listener after its answer is released" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    const answer = try engine.listen.listenOnFar(&peer, .{ .far = model.FarRef.promise(5) });
    const settling_resolver = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer,
    }).?;
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    try peer.sendCopying(.{ .gc_answer = .{ .positions = &.{answer.int()} } });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
    try std.testing.expectEqual(session.RetiredResolverState.pending, peer.session_state.retiredResolverState(settling_resolver).?);

    var shortening = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &.{
            .{ .symbol = "fulfill" },
            .{ .reference = .{ .near = model.NearRef.promise(6) } },
        },
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());
    while ((try peer.step()) != .idle) {}

    var only_shortening = peer.takeOutbound().?;
    defer only_shortening.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, only_shortening.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, body.listen.mode);
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expectEqual(session.RetiredResolverState.complete, peer.session_state.retiredResolverState(settling_resolver).?);
}

test "releasing a shortened source also releases the callback-introduced target" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const callback_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var callback = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver.int()) },
        .args = &callback_args,
    } });
    defer callback.deinit();
    try peer.recvBorrowed(callback.view());
    try std.testing.expect(peer.session_state.holdsImport(.from(6)));

    // Drain the recursive shortening subscription before observing the GC.
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const source_positions = [_]u64{5};
    const source_deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &source_positions, .deltas = &source_deltas } });
    try std.testing.expect(!peer.session_state.holdsImport(.from(5)));
    try std.testing.expect(!peer.session_state.holdsImport(.from(6)));

    while ((try peer.step()) != .idle) {}
    var release = peer.takeOutbound().?;
    defer release.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, release.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(usize, 2), try body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 5), try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(u64, 6), try body.gc_export.positions.at(1));
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a discarded shortening listener remains deduplicated until source release" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(5));

    const resolver = model.ExportPosition.from(peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(&peer, .from(5));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const resolver_positions = [_]u64{resolver.int()};
    const resolver_deltas = [_]u64{1};
    var release_resolver = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .gc_export = .{
        .positions = &resolver_positions,
        .deltas = &resolver_deltas,
    } });
    defer release_resolver.deinit();
    try peer.recvBorrowed(release_resolver.view());
    var gc_event = peer.pollEvent().?;
    gc_event.deinit();
    try std.testing.expect(peer.session_state.exportSlot(resolver) == null);
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(resolver).? == .complete);

    try engine.listen.ensureShorteningListener(&peer, .from(5));
    try std.testing.expect((try peer.step()) == .idle);
    try std.testing.expect(peer.takeOutbound() == null);

    const source_positions = [_]u64{5};
    const source_deltas = [_]u64{1};
    try peer.sendCopying(.{ .gc_export = .{ .positions = &source_positions, .deltas = &source_deltas } });
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(resolver) == null);
}
