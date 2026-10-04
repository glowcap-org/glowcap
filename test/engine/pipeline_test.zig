const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;

const pipeline = engine.pipeline;

test "rewriteDeliverTarget swaps the target and preserves args/answer" {
    const allocator = std.testing.allocator;
    const args = try allocator.alloc(model.Argument, 1);
    args[0] = .{ .bytes = try allocator.dupe(u8, "x") };
    const message = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(5) } },
        .args = args,
        .answer = .from(9),
    } };

    const rewritten = pipeline.rewriteDeliverTarget(allocator, message.deliver, .{ .far = .{ .import_position = .from(3) } });
    defer model.freeMessage(allocator, rewritten);

    try std.testing.expect(rewritten.deliver.target == .far);
    try std.testing.expectEqual(@as(u64, 3), rewritten.deliver.target.far.import_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(9)), rewritten.deliver.answer);
    try std.testing.expectEqual(@as(usize, 1), rewritten.deliver.args.len);
    try std.testing.expectEqualStrings("x", rewritten.deliver.args[0].bytes);
}

test "borrowedListenerFire builds the fulfill resolver-method call without owning heap" {
    var args: [2]model.Argument = undefined;
    const fire = pipeline.borrowedListenerFire(1, .{ .fulfill = .{ .bytes = "v" } }, &args);

    try std.testing.expect(fire.deliver.target == .far);
    try std.testing.expectEqual(@as(u64, 1), fire.deliver.target.far.import_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), fire.deliver.answer);
    try std.testing.expectEqual(@as(usize, 2), fire.deliver.args.len);
    try std.testing.expectEqualStrings("fulfill", fire.deliver.args[0].symbol);
    try std.testing.expectEqualStrings("v", fire.deliver.args[1].bytes);
    // The args ride in the caller's stack array; nothing was allocated, so
    // there is nothing to free (the message must never reach freeMessage).
    try std.testing.expectEqual(@as([*]const model.Argument, &args), fire.deliver.args.ptr);
}

test "borrowedListenerFire builds the break resolver-method call" {
    var args: [2]model.Argument = undefined;
    const fire = pipeline.borrowedListenerFire(1, .{ .@"break" = .{ .message = "boom" } }, &args);

    // The break reason rides as a bare Symbol, NOT an `<error>` record. The
    // upstream OCapN suite (test_op_listen_to_promise_and_break) asserts exactly
    // `[Symbol("break"), Symbol(reason)]` for the listen notification, do not
    // "align" this with the `<error>` shape `v1_0.encodeResolveAsCallback` uses for
    // op:resolve; the two wire paths legitimately differ and the suite is the
    // authority here.
    try std.testing.expectEqualStrings("break", fire.deliver.args[0].symbol);
    try std.testing.expect(fire.deliver.args[1] == .symbol);
    try std.testing.expectEqualStrings("boom", fire.deliver.args[1].symbol);
}

test "classifyListenerDrain fires once on a non-promise fulfillment" {
    const entry = session.ListenerEntry{ .listener = .{ .import_position = .from(2) }, .mode = .settling_only };
    const action = pipeline.classifyListenerDrain(entry, .{ .fulfill = .{ .bytes = "v" } }, .next);
    try std.testing.expect(action == .fire);
    try std.testing.expectEqual(@as(u64, 2), action.fire);
}

test "classifyListenerDrain keeps a settling listener on a same-peer promise" {
    const entry = session.ListenerEntry{ .listener = .{ .import_position = .from(2) }, .mode = .settling_only };
    const action = pipeline.classifyListenerDrain(
        entry,
        .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(8) } } } },
        .next,
    );
    try std.testing.expect(action == .reinstall);
    try std.testing.expectEqual(@as(u64, 8), action.reinstall.next_answer.int());
}

test "classifyListenerDrain keeps a combined listener on a same-peer promise" {
    const entry = session.ListenerEntry{ .listener = .{ .import_position = .from(2) }, .mode = .shortening_or_settling };
    const action = pipeline.classifyListenerDrain(
        entry,
        .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(8) } } } },
        .next,
    );
    try std.testing.expect(action == .reinstall);
    try std.testing.expectEqual(@as(u64, 8), action.reinstall.next_answer.int());
}

test "classifyListenerDrain concludes listeners on a far promise by profile" {
    const far_promise: model.Resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.promise(12) } } };
    const settling = session.ListenerEntry{ .listener = .{ .import_position = .from(2) }, .mode = .settling_only };
    const shortening = session.ListenerEntry{ .listener = .{ .import_position = .from(3) }, .mode = .shortening_only };
    const combined = session.ListenerEntry{ .listener = .{ .import_position = .from(4) }, .mode = .shortening_or_settling };

    // V1.0 has no paired shortening listener, so every mode hears the far promise.
    try std.testing.expectEqual(@as(u64, 2), pipeline.classifyListenerDrain(settling, far_promise, .v1_0).fire);
    try std.testing.expectEqual(@as(u64, 4), pipeline.classifyListenerDrain(combined, far_promise, .v1_0).fire);

    // On next a settling listener is reissued by its paired shortening listener.
    try std.testing.expect(pipeline.classifyListenerDrain(settling, far_promise, .next) == .discard);
    try std.testing.expectEqual(@as(u64, 3), pipeline.classifyListenerDrain(shortening, far_promise, .next).fire);
    try std.testing.expectEqual(@as(u64, 4), pipeline.classifyListenerDrain(combined, far_promise, .next).fire);
}
