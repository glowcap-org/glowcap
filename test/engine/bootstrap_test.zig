const std = @import("std");
const glowcap = @import("glowcap");
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const session = glowcap.ocapn.session;
const cross_peer = @import("../support/cross_peer.zig");

test "resolveForSwissnum fulfills with the mapped export, breaks on a miss" {
    var sess = glowcap.ocapn.session.Session.init(std.testing.allocator);
    defer sess.deinit();
    const export_position = try sess.registerBootstrapCap("k");

    // Fulfill is a POD NearRef. The miss diagnostic is a named string dupe
    // `send` owns on the wire path; this test must free it.
    const hit = try engine.bootstrap.resolveForSwissnum(&sess, null, null, .{ .swissnum = "k", .answer = .fromWire(.from(7)) });
    defer model.freeResolution(std.testing.allocator, hit);
    try std.testing.expectEqual(model.NearRef.object(export_position.int()), hit.fulfill.reference.near);

    const miss = try engine.bootstrap.resolveForSwissnum(&sess, null, null, .{ .swissnum = "nope", .answer = .fromWire(.from(9)) });
    defer model.freeResolution(std.testing.allocator, miss);
    try std.testing.expectEqualStrings("unknown swissnum", miss.@"break".message);
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
    const action = try engine.bootstrap.pendingBootstrapAction(view.deliver, null);
    try std.testing.expect(action != null);
    try std.testing.expect(action.? == .fetch);
    try std.testing.expectEqualStrings("swiss", action.?.fetch.swissnum);
    try std.testing.expectEqual(model.AnswerName.fromWire(prepared.answer_position), action.?.fetch.answer);

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
        try std.testing.expect((try engine.bootstrap.pendingBootstrapAction(miss_view.deliver, null)) == null);
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
        try std.testing.expect((try engine.bootstrap.pendingBootstrapAction(miss_view.deliver, null)) == null);
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
    try std.testing.expect((try engine.bootstrap.pendingBootstrapAction(view.deliver, null)) == null);
}

test "responder auto-resolves an inbound bootstrap fetch (no manual reply)" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();

    // p2 exposes a cap behind a swissnum.
    const export_position = try pair.p2.registerBootstrapCap("thermostat");

    // p1 fetches it.
    const prepared = try engine.fetch.prepareFetchSwissnum(std.testing.allocator, &pair.p1.session_state, "thermostat");
    try pair.p1.send(prepared.message);
    // Next answered operations travel with their mandatory listener. Deliver
    // both before the responder settles so its callback has a destination.
    try cross_peer.pumpAll(&pair.p1, &pair.p2);
    var saw_deliver = false;
    while (pair.p2.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        saw_deliver = event.kind() == .deliver or saw_deliver;
    }
    try std.testing.expect(saw_deliver);

    // Shuttle the settlement back to p1 and match it.
    try cross_peer.pumpAll(&pair.p2, &pair.p1);
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
            // the reference's *position* equals that export position; stay agnostic to
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
