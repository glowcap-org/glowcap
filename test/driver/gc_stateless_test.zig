//! Stateless-GC emission balance (ADR-0004): the driver's post-event
//! `op:gc-exports` walk must release exactly what the session's import-install
//! walk recorded. The install walk recurses through nested argument trees, so
//! the emission walk must too, a top-level-only walk strands every nested
//! introduction's refcount until teardown.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const session = glowcap.ocapn.session;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;

test "stateless GC releases a far introduced inside a nested argument" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p2 hosts the deliver target; p1 holds it as an import.
    try p1.session_state.registerImport(.from(1));
    try p2.session_state.registerExport(.from(1));
    // p1 hosts the object it introduces inside the nested arg, a reservation
    // whose first marshal below is what grants it.
    try p1.session_state.reserveExport(.from(7));

    // The deliver's args nest the introduction one level down, a list holding
    // p1's export 7, decoded by p2 (post perspective-flip) as the introduced
    // import 7.
    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(1) } },
        .args = &.{
            .{ .list = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }} },
        },
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    // p1's export 7 now carries two refs: the reserved baseline plus the wire
    // mention the partner owes a release for.
    try std.testing.expectEqual(@as(u64, 2), p1.session_state.exports.count(.from(7)));
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // The session installed the nested introduction.
    try std.testing.expect(p2.session_state.hasImport(.from(7)));

    {
        var event = p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
        try driver.core.testing.emitStatelessAfter(&p2, &event);
    }

    // The emission released the nested import on p2's own table.
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(!p2.session_state.hasImport(.from(7)));

    // And the wire half balances: the release returns exactly the mention's
    // ref, leaving p1's export held by its local baseline alone.
    const gc_frame = p2.takeOutbound().?;
    try p1.feedOwned(gc_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(@as(u64, 1), p1.session_state.exports.count(.from(7)));
}

test "stateless GC's fallback walk matches the threaded record for the same nested introduction" {
    // The session's validate walk threads its introduced-import record onto
    // an ordinary deliver's event (`Event.introduced_far_imports`), so `gc`
    // reads it directly instead of re-walking the deliver's args, but a
    // deliver surfaced by a path that does not thread one (such as a
    // pipelined call redirected to a local export,
    // `engine.pipeline.deliverDrainedCallLocally`) still needs the walk.
    // This forces that fallback explicitly, on the exact same nested
    // introduction the first test above threads, so the two paths are
    // proven to agree rather than merely both passing on different inputs.
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(1));
    try p2.session_state.registerExport(.from(1));
    try p1.session_state.reserveExport(.from(7));

    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(1) } },
        .args = &.{
            .{ .list = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }} },
        },
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(p2.session_state.hasImport(.from(7)));

    {
        var event = p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
        // Threaded by the ordinary inbound path; free it and null it out to
        // force `gc` down the re-walk it must still carry.
        try std.testing.expect(event.introduced_far_imports != null);
        event.allocator.free(event.introduced_far_imports.?);
        event.introduced_far_imports = null;
        try driver.core.testing.emitStatelessAfter(&p2, &event);
    }

    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(!p2.session_state.hasImport(.from(7)));

    const gc_frame = p2.takeOutbound().?;
    try p1.feedOwned(gc_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(@as(u64, 1), p1.session_state.exports.count(.from(7)));
}

test "stateless GC skips a before-serve-claimed event" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var served = driver.Served.over(allocator, &p2);
    defer served.deinit(&vat);
    served.serve_options = .{
        .gc_stateless = true,
        .before_serve = struct {
            fn hook(ctx: ?*anyopaque, s: *driver.Served, event: *engine.Event) driver.core.BeforeServeError!bool {
                _ = s;
                _ = event;
                const claimed: *bool = @ptrCast(@alignCast(ctx.?));
                claimed.* = true;
                return true;
            }
        }.hook,
    };

    try p1.session_state.registerImport(.from(1));
    try p2.session_state.registerExport(.from(1));
    try p1.session_state.reserveExport(.from(7));

    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(1) } },
        .args = &.{
            .{ .reference = .{ .near = .{ .export_position = .from(7) } } },
        },
        .answer = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(p2.session_state.hasImport(.from(7)));

    var claimed = false;
    served.serve_options.hook_ctx = &claimed;
    {
        var event = p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
        try served.serveEvent(&vat, &event);
    }

    try std.testing.expect(claimed);
    try std.testing.expectEqual(engine.StepOutcome.idle, try p2.step());
    try std.testing.expect(!p2.hasOutbound());
    try std.testing.expect(p2.session_state.hasImport(.from(7)));
}

/// A V1.0 resolver-callback deliver as the engine surfaces it: a real
/// `op:deliver` frame decoded once, tagged `.resolve` on the answer it settles.
fn resolverCallbackEvent(allocator: std.mem.Allocator, answer: engine.OutboundAnswerTarget) !engine.Event {
    var args = [_]model.Argument{ .{ .symbol = "fulfill" }, .{ .integer = 1 } };
    var frame = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &args,
    } });
    errdefer frame.deinit();
    const parse = try engine.events.Parse.decode(allocator, &frame, .syrup, .next);
    return .{
        .frame = frame,
        .parse = parse,
        .tag = .resolve,
        .codec = .syrup,
        .captp_version = .next,
        .answer_override = .{ .resolve = answer },
        .allocator = allocator,
    };
}

test "stateless GC releases every answer sharing a resolve callback" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
        .captp_version = .next,
    }));
    defer peer.deinit();
    try peer.session_state.installOutboundAnswer(.from(5));
    try peer.session_state.installOutboundAnswer(.from(6));
    try peer.session_state.installOutboundAnswer(.from(7));

    var event = try resolverCallbackEvent(allocator, peer.session_state.outboundAnswerTarget(.from(5)).?);
    defer event.deinit();
    try event.resolve_aliases.append(allocator, peer.session_state.outboundAnswerTarget(.from(6)).?);
    try event.resolve_aliases.append(allocator, peer.session_state.outboundAnswerTarget(.from(7)).?);

    try driver.core.testing.emitStatelessAfter(&peer, &event);
    try std.testing.expect(peer.session_state.outboundAnswer(.from(5)) == null);
    try std.testing.expect(peer.session_state.outboundAnswer(.from(6)) == null);
    try std.testing.expect(peer.session_state.outboundAnswer(.from(7)) == null);

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var gc_frame = peer.takeOutbound().?;
    defer gc_frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, gc_frame.view());
    try std.testing.expectEqual(@as(usize, 3), try body.gc_answer.positions.len());
    try std.testing.expectEqual(@as(u64, 5), try body.gc_answer.positions.at(0));
    try std.testing.expectEqual(@as(u64, 6), try body.gc_answer.positions.at(1));
    try std.testing.expectEqual(@as(u64, 7), try body.gc_answer.positions.at(2));
}

test "stateless GC reports an enqueue allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = engine.Peer.init(failing.allocator());
    defer {
        failing.fail_index = std.math.maxInt(usize);
        peer.deinit();
    }
    peer.session_state.captp_version = .next;
    try peer.session_state.installOutboundAnswer(.from(5));

    var event = try resolverCallbackEvent(std.testing.allocator, peer.session_state.outboundAnswerTarget(.from(5)).?);
    defer event.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        driver.core.testing.emitStatelessAfter(&peer, &event),
    );
}

test "stateless GC refuses a resolve for a question already released" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
        .captp_version = .next,
    }));
    defer peer.deinit();
    try peer.session_state.installOutboundAnswer(.from(5));
    var event = try resolverCallbackEvent(allocator, peer.session_state.outboundAnswerTarget(.from(5)).?);
    defer event.deinit();

    try peer.session_state.releaseOutboundAnswer(.from(5));
    try std.testing.expectError(error.GcUnderflow, driver.core.testing.emitStatelessAfter(&peer, &event));

    // The position asked again is a different question, and the old resolve status-allow: replacement state identity
    // cannot release it.
    try peer.session_state.installOutboundAnswer(.from(5));
    try std.testing.expectError(error.GcUnderflow, driver.core.testing.emitStatelessAfter(&peer, &event));
    try std.testing.expect(peer.session_state.outboundAnswer(.from(5)) != null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}
