const std = @import("std");
const pancake = @import("pancake");
const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const session = pancake.ocapn.session;

test "resolveForSwissnum fulfills with the mapped export, breaks on a miss" {
    var sess = pancake.ocapn.session.Session.init(std.testing.allocator);
    defer sess.deinit();
    const export_position = try sess.registerBootstrapCap("k");

    // no free: fulfill is a POD NearRef and the break reason is static, never
    // route these through `freeMessage` (only `Peer.sendCopying`, which clones).
    const hit = engine.bootstrap.resolveForSwissnum(&sess, .{ .swissnum = "k", .answer = .from(7) });
    try std.testing.expectEqual(@as(u64, 7), hit.resolve.answer.int());
    try std.testing.expectEqual(model.NearRef.object(export_position.int()), hit.resolve.resolution.fulfill.reference.near);

    const miss = engine.bootstrap.resolveForSwissnum(&sess, .{ .swissnum = "nope", .answer = .from(9) });
    try std.testing.expectEqualStrings("unknown swissnum", miss.resolve.resolution.@"break".message);
}

test "pendingBootstrapAction recognizes a real bootstrap-fetch, misses otherwise" {
    const allocator = std.testing.allocator;
    var sess = session.Session.init(allocator);
    defer sess.deinit();

    // Happy path: encode the canonical bootstrap-fetch deliver `prepareFetchSwissnum`
    // builds, decode it back to a borrowed view, and recognize it.
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &sess, "swiss");
    defer model.freeMessage(allocator, prepared.message);

    var frame = try codec.syrup.encodeMessage(allocator, prepared.message);
    defer frame.deinit();
    const view = try codec.syrup.decodeBody(frame.view());
    const action = try engine.bootstrap.pendingBootstrapAction(view.deliver, &sess);
    try std.testing.expect(action != null);
    try std.testing.expect(action.? == .fetch);
    try std.testing.expectEqualStrings("swiss", action.?.fetch.swissnum);
    try std.testing.expectEqual(prepared.answer_position, action.?.fetch.answer);

    // Miss: a deliver whose method symbol is not "fetch" falls through (null, no error).
    {
        const args = try allocator.alloc(model.Argument, 2);
        args[0] = .{ .symbol = try allocator.dupe(u8, "frob") };
        args[1] = .{ .bytes = try allocator.dupe(u8, "swiss") };
        const msg = model.Message{ .deliver = .{
            .target = .{ .far = model.FarRef.object(session.BOOTSTRAP_POSITION) },
            .args = args,
            .answer = .from(4),
        } };
        defer model.freeMessage(allocator, msg);
        var miss_frame = try codec.syrup.encodeMessage(allocator, msg);
        defer miss_frame.deinit();
        const miss_view = try codec.syrup.decodeBody(miss_frame.view());
        try std.testing.expect((try engine.bootstrap.pendingBootstrapAction(miss_view.deliver, &sess)) == null);
    }

    // Miss: a fetch-shaped deliver to a non-bootstrap target falls through too.
    {
        const args = try allocator.alloc(model.Argument, 2);
        args[0] = .{ .symbol = try allocator.dupe(u8, "fetch") };
        args[1] = .{ .bytes = try allocator.dupe(u8, "swiss") };
        const msg = model.Message{ .deliver = .{
            .target = .{ .far = model.FarRef.object(5) },
            .args = args,
            .answer = .from(4),
        } };
        defer model.freeMessage(allocator, msg);
        var miss_frame = try codec.syrup.encodeMessage(allocator, msg);
        defer miss_frame.deinit();
        const miss_view = try codec.syrup.decodeBody(miss_frame.view());
        try std.testing.expect((try engine.bootstrap.pendingBootstrapAction(miss_view.deliver, &sess)) == null);
    }
}

test "a deliver to .far import 0 is not auto-served as a bootstrap fetch" {
    const allocator = std.testing.allocator;
    var sess = session.Session.init(allocator);
    defer sess.deinit();

    // The bootstrap object is one of *our* exports, which an inbound deliver
    // names as `<desc:export 0>` (decoding to `.near 0`). A partner-named
    // `.far` import that happens to be 0 lives in a different integer space:
    // on the wire it is `<desc:import-object 0>`, which decodes to exactly
    // that `.far` import 0 and must fall through to ordinary handling.
    const wire = "<10'op:deliver<18'desc:import-object0+>[5'fetch5:swiss]4+f>";
    const view = try codec.syrup.decodeBody(.{ .bytes = wire, .shape = .byte });
    try std.testing.expect(view.deliver.target == .far);
    try std.testing.expectEqual(session.BOOTSTRAP_POSITION, view.deliver.target.far.import_position.int());
    try std.testing.expect((try engine.bootstrap.pendingBootstrapAction(view.deliver, &sess)) == null);
}

test "responder auto-resolves an inbound bootstrap fetch (no manual reply)" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();

    // p2 exposes a cap behind a swissnum.
    const export_position = try pair.p2.registerBootstrapCap("thermostat");

    // p1 fetches it.
    const prepared = try engine.fetch.prepareFetchSwissnum(std.testing.allocator, &pair.p1.session_state, "thermostat");
    try pair.p1.send(prepared.message);
    _ = try pair.p1.step();

    // Shuttle the fetch deliver to p2; p2 dispatches (surfaces the deliver event)
    // and then encodes its synthesized resolve.
    {
        const frame = pair.p1.takeOutbound().?;
        try pair.p2.feedInbound(frame);
    }
    _ = try pair.p2.step(); // dispatch inbound: recognize + enqueue resolve
    {
        var ev = pair.p2.pollEvent().?; // the deliver event still surfaces
        defer ev.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, ev.kind());
    }
    _ = try pair.p2.step(); // drain pending_send: encode the resolve (V1.0 resolver-callback)

    // Shuttle the settlement back to p1 and match it.
    {
        const frame = pair.p2.takeOutbound().?;
        try pair.p1.feedInbound(frame);
    }
    _ = try pair.p1.step();
    var settle = pair.p1.pollEvent().?;
    defer settle.deinit();
    const owned = try settle.decodeOwned(std.testing.allocator);
    const match = try engine.fetch.tryMatchFetchOutcome(
        std.testing.allocator,
        prepared.resolver_export,
        prepared.answer_position,
        owned,
    );
    switch (match.settled) {
        .fulfilled => |ref| {
            defer model.freeReference(std.testing.allocator, ref);
            // The fetch fulfilled with the responder's bootstrap export. Assert
            // the reference's *position* equals that export id; stay agnostic to
            // the near/far wire-perspective discriminator (matcher returns the
            // reference as decoded — `fetch.tryMatchFetchOutcome` does not flip —
            // and the codec round-trips `Near`↔`desc:import-object` symmetrically).
            const position: u64 = switch (ref) {
                .near => |near| near.export_position.int(),
                .far => |far| far.import_position.int(),
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(export_position, position);
        },
        else => return error.TestUnexpectedResult,
    }
}
