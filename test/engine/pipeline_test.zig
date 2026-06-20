const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;

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
    try std.testing.expectEqual(@as(?model.AnswerId, .from(9)), rewritten.deliver.answer);
    try std.testing.expectEqual(@as(usize, 1), rewritten.deliver.args.len);
    try std.testing.expectEqualStrings("x", rewritten.deliver.args[0].bytes);
}

test "synthesizeListenerFire builds the fulfill resolver-method call" {
    const allocator = std.testing.allocator;
    const fire = try pipeline.synthesizeListenerFire(
        allocator,
        .{ .far = .{ .import_position = .from(1) } },
        .{ .fulfill = .{ .bytes = "v" } },
    );
    defer model.freeMessage(allocator, fire);

    try std.testing.expect(fire.deliver.target == .far);
    try std.testing.expectEqual(@as(?model.AnswerId, null), fire.deliver.answer);
    try std.testing.expectEqual(@as(usize, 2), fire.deliver.args.len);
    try std.testing.expectEqualStrings("fulfill", fire.deliver.args[0].symbol);
    try std.testing.expectEqualStrings("v", fire.deliver.args[1].bytes);
}

test "synthesizeListenerFire builds the break resolver-method call" {
    const allocator = std.testing.allocator;
    const fire = try pipeline.synthesizeListenerFire(
        allocator,
        .{ .far = .{ .import_position = .from(1) } },
        .{ .@"break" = .{ .message = "boom" } },
    );
    defer model.freeMessage(allocator, fire);

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

test "decomposeOutboundDeliver expands a single call step into one intermediate plus terminal" {
    const allocator = std.testing.allocator;
    var sess = session.Session.init(allocator);
    defer sess.deinit();

    // promise{42}.call(["x"]) with outer args ["z"], answer 100.
    const call_args = try allocator.alloc(model.Argument, 1);
    call_args[0] = .{ .bytes = try allocator.dupe(u8, "x") };
    const ops = try allocator.alloc(model.PipelineOp, 1);
    ops[0] = .{ .call = call_args };
    const outer_args = try allocator.alloc(model.Argument, 1);
    outer_args[0] = .{ .bytes = try allocator.dupe(u8, "z") };
    const message = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42), .path = .{ .ops = ops } } },
        .args = outer_args,
        .answer = .from(100),
    } };

    const chain = try pipeline.decomposeOutboundDeliver(allocator, &sess, message);
    defer {
        for (chain.intermediates) |link| model.freeMessage(allocator, link);
        allocator.free(chain.intermediates);
        model.freeMessage(allocator, chain.terminal);
    }

    try std.testing.expectEqual(@as(usize, 1), chain.intermediates.len);
    const step0 = chain.intermediates[0].deliver;
    try std.testing.expect(step0.target == .promise);
    try std.testing.expectEqual(@as(u64, 42), step0.target.promise.answer_position.int());
    try std.testing.expect(step0.target.promise.path.isEmpty());
    try std.testing.expectEqualStrings("x", step0.args[0].bytes);

    const term = chain.terminal.deliver;
    try std.testing.expect(term.target == .promise);
    try std.testing.expectEqual(step0.answer.?, term.target.promise.answer_position);
    try std.testing.expect(term.target.promise.path.isEmpty());
    try std.testing.expectEqualStrings("z", term.args[0].bytes);
    try std.testing.expectEqual(@as(?model.AnswerId, .from(100)), term.answer);
}

test "decomposeOutboundDeliver chains intermediate answers across two call steps" {
    const allocator = std.testing.allocator;
    var sess = session.Session.init(allocator);
    defer sess.deinit();

    const ops = try allocator.alloc(model.PipelineOp, 2);
    inline for (.{ "a", "b" }, 0..) |label, i| {
        const step_args = try allocator.alloc(model.Argument, 1);
        step_args[0] = .{ .bytes = try allocator.dupe(u8, label) };
        ops[i] = .{ .call = step_args };
    }
    const outer_args = try allocator.alloc(model.Argument, 1);
    outer_args[0] = .{ .bytes = try allocator.dupe(u8, "c") };
    const message = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42), .path = .{ .ops = ops } } },
        .args = outer_args,
        .answer = .from(100),
    } };

    const chain = try pipeline.decomposeOutboundDeliver(allocator, &sess, message);
    defer {
        for (chain.intermediates) |link| model.freeMessage(allocator, link);
        allocator.free(chain.intermediates);
        model.freeMessage(allocator, chain.terminal);
    }

    try std.testing.expectEqual(@as(usize, 2), chain.intermediates.len);
    const step0 = chain.intermediates[0].deliver;
    const step1 = chain.intermediates[1].deliver;
    // Each step targets the prior answer: 42 → step0.answer → step1.answer → terminal.
    try std.testing.expectEqual(@as(u64, 42), step0.target.promise.answer_position.int());
    try std.testing.expectEqual(step0.answer.?, step1.target.promise.answer_position);
    try std.testing.expectEqual(step1.answer.?, chain.terminal.deliver.target.promise.answer_position);
    try std.testing.expectEqualStrings("a", step0.args[0].bytes);
    try std.testing.expectEqualStrings("b", step1.args[0].bytes);
    try std.testing.expectEqualStrings("c", chain.terminal.deliver.args[0].bytes);
    try std.testing.expectEqual(@as(?model.AnswerId, .from(100)), chain.terminal.deliver.answer);
}

test "decomposeOutboundDeliver rejects a field step on the Syrup path" {
    const allocator = std.testing.allocator;
    var sess = session.Session.init(allocator);
    defer sess.deinit();

    const ops = try allocator.alloc(model.PipelineOp, 1);
    ops[0] = .{ .field = try allocator.dupe(u8, "manager") };
    const message = model.Message{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42), .path = .{ .ops = ops } } },
        .args = &.{},
        .answer = .from(100),
    } };

    try std.testing.expectError(
        error.UnsupportedPipelineOp,
        pipeline.decomposeOutboundDeliver(allocator, &sess, message),
    );
    // Rejection leaves `message` whole, the caller releases it.
    model.freeMessage(allocator, message);
}

test "classifyListenerDrain fires once on a non-promise fulfillment" {
    const allocator = std.testing.allocator;
    const entry = session.ListenerEntry{ .listener = .{ .far = .{ .import_position = .from(2) } }, .wants_partial = false };
    const action = try pipeline.classifyListenerDrain(allocator, entry, .{ .fulfill = .{ .bytes = "v" } });
    try std.testing.expect(action == .fire);
    model.freeMessage(allocator, action.fire);
}

test "classifyListenerDrain re-anchors (no fire) on a partial-promise without wants_partial" {
    const allocator = std.testing.allocator;
    const entry = session.ListenerEntry{ .listener = .{ .far = .{ .import_position = .from(2) } }, .wants_partial = false };
    const action = try pipeline.classifyListenerDrain(
        allocator,
        entry,
        .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(8) } } } },
    );
    try std.testing.expect(action == .reinstall);
    try std.testing.expectEqual(@as(u64, 8), action.reinstall.next_answer.int());
    model.freeReference(allocator, action.reinstall.entry.listener);
}

test "classifyListenerDrain fires and re-anchors on a partial-promise with wants_partial" {
    const allocator = std.testing.allocator;
    const entry = session.ListenerEntry{ .listener = .{ .far = .{ .import_position = .from(2) } }, .wants_partial = true };
    const action = try pipeline.classifyListenerDrain(
        allocator,
        entry,
        .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(8) } } } },
    );
    try std.testing.expect(action == .fire_and_reinstall);
    try std.testing.expectEqual(@as(u64, 8), action.fire_and_reinstall.next_answer.int());
    model.freeMessage(allocator, action.fire_and_reinstall.fire);
    model.freeReference(allocator, action.fire_and_reinstall.entry.listener);
}
