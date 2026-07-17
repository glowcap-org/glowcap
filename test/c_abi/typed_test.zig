//! Typed OCapN driving surface, proves a C consumer can *construct* a call and
//! *inspect* a delivery as structured values, not just shuttle opaque frames.
//! This is the surface that turns a binding from "observes that a message
//! arrived" into "calls a remote method and reads the reply."

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

const c_args = @import("../support/c_abi_args.zig");
const argBase = c_args.argBase;
const argInt = c_args.argInt;
const argBytes = c_args.argBytes;
const farRef = c_args.farRef;

test "C ABI typed surface carries set, tagged, and keyword arguments" {
    // Inspect: a delivery whose args are a set, a tagged record, and a keyword
    // projects to the full passable tree.
    var receiver: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&receiver));
    defer c.pancake_peer_release(receiver);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(receiver, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[#1+2+$<11'user-record5'Point[3+4+]><2'kw5'color>]11+f>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(receiver, &frame));

    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(receiver, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_DELIVER, polled.projection);
    const deliver = polled.deliver;

    try std.testing.expectEqual(@as(usize, 3), deliver.args_len);
    const set_arg = deliver.args.?[0];
    try std.testing.expectEqual(c.PANCAKE_ARG_SET, set_arg.kind);
    try std.testing.expectEqual(@as(usize, 2), set_arg.items_len);
    try std.testing.expectEqual(@as(i64, 1), set_arg.items.?[0].integer);

    const tagged_arg = deliver.args.?[1];
    try std.testing.expectEqual(c.PANCAKE_ARG_TAGGED, tagged_arg.kind);
    try std.testing.expectEqualStrings("Point", tagged_arg.bytes.?[0..tagged_arg.bytes_len]);
    try std.testing.expectEqual(@as(usize, 2), tagged_arg.items_len);
    try std.testing.expectEqual(@as(i64, 3), tagged_arg.items.?[0].integer);

    const kw_arg = deliver.args.?[2];
    try std.testing.expectEqual(c.PANCAKE_ARG_KEYWORD, kw_arg.kind);
    try std.testing.expectEqualStrings("color", kw_arg.bytes.?[0..kw_arg.bytes_len]);
}

test "C ABI send_deliver encodes set, tagged, and keyword arguments" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(peer, 5));

    const set_items = [_]c.PancakeArgument{ argInt(1), argInt(2) };
    var set_arg = argBase();
    set_arg.kind = c.PANCAKE_ARG_SET;
    set_arg.items = set_items[0..].ptr;
    set_arg.items_len = set_items.len;

    const tagged_items = [_]c.PancakeArgument{argInt(3)};
    var tagged_arg = argBase();
    tagged_arg.kind = c.PANCAKE_ARG_TAGGED;
    tagged_arg.bytes = "Point".ptr;
    tagged_arg.bytes_len = "Point".len;
    tagged_arg.items = tagged_items[0..].ptr;
    tagged_arg.items_len = tagged_items.len;

    var kw_arg = argBase();
    kw_arg.kind = c.PANCAKE_ARG_KEYWORD;
    kw_arg.bytes = "color".ptr;
    kw_arg.bytes_len = "color".len;

    const args = [_]c.PancakeArgument{ set_arg, tagged_arg, kw_arg };
    const target = farRef(5);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_deliver(peer, &target, args[0..].ptr, args.len, 0, 0),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));

    var frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &frame));
    defer c.pancake_managed_frame_release(&frame);
    const wire = frame.bytes.?[0..frame.len];
    try std.testing.expect(std.mem.indexOf(u8, wire, "#1+2+$") != null); // set
    try std.testing.expect(std.mem.indexOf(u8, wire, "user-record5'Point") != null); // tagged
    try std.testing.expect(std.mem.indexOf(u8, wire, "2'kw5'color") != null); // keyword
}

test "C ABI carries a big integer argument in both directions" {
    // PANCAKE_ARG_BIG_INTEGER reuses bytes/bytes_len for the canonical decimal
    // magnitude and boolean for the sign (1 = negative).
    const digits = "1267650600228229401496703205376"; // 2^100

    // Inspect: an inbound delivery carrying a wire bignum projects the arm.
    var receiver: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&receiver));
    defer c.pancake_peer_release(receiver);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(receiver, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[1267650600228229401496703205376-]11+f>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(receiver, &frame));

    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(receiver, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_DELIVER, polled.projection);
    const deliver = polled.deliver;
    const big_arg = deliver.args.?[0];
    try std.testing.expectEqual(c.PANCAKE_ARG_BIG_INTEGER, big_arg.kind);
    try std.testing.expectEqual(@as(u8, 1), big_arg.boolean);
    try std.testing.expectEqualStrings(digits, big_arg.bytes.?[0..big_arg.bytes_len]);

    // Construct: an outbound send carries the same value back to the wire.
    var sender: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&sender));
    defer c.pancake_peer_release(sender);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(sender, 5));

    var arg = argBase();
    arg.kind = c.PANCAKE_ARG_BIG_INTEGER;
    arg.boolean = 1;
    arg.bytes = digits.ptr;
    arg.bytes_len = digits.len;
    const target = farRef(5);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_deliver(sender, &target, @as([*]const c.PancakeArgument, @ptrCast(&arg)), 1, 0, 0),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(sender));
    var out: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(sender, &out));
    defer c.pancake_managed_frame_release(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes.?[0..out.len], "1267650600228229401496703205376-") != null);

    // Fail closed: a magnitude that fits int64_t is refused, not re-tagged.
    var small = argBase();
    small.kind = c.PANCAKE_ARG_BIG_INTEGER;
    small.boolean = 0;
    small.bytes = "7".ptr;
    small.bytes_len = 1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_UNSUPPORTED_VALUE,
        c.pancake_peer_send_deliver(sender, &target, @as([*]const c.PancakeArgument, @ptrCast(&small)), 1, 1, 0),
    );
}

test "C ABI send_deliver constructs a real op:deliver carrying typed args" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    // A real caller delivers to an import it holds; register the one we call.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(peer, 5));

    const target = farRef(5);
    const args = [_]c.PancakeArgument{ argInt(42), argBytes("hi") };
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_deliver(peer, &target, args[0..].ptr, args.len, 1, 9),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));

    var frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &frame));
    defer c.pancake_managed_frame_release(&frame);

    const wire = frame.bytes.?[0..frame.len];
    // A real op:deliver with the integer and the bytes argument both encoded.
    try std.testing.expect(std.mem.startsWith(u8, wire, "<10'op:deliver"));
    try std.testing.expect(std.mem.indexOf(u8, wire, "42+") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "2:hi") != null);
}

test "C ABI send_get/index/untag construct real projection ops on the wire" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    // A projection names a receiver like a deliver target; register the import.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(peer, 5));
    const receiver = farRef(5);

    // op:get against a held far receiver carries the String field and answer.
    var get_answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(peer, &get_answer));
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_get(peer, &receiver, "name", "name".len, get_answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var f1: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &f1));
    defer c.pancake_managed_frame_release(&f1);
    const w1 = f1.bytes.?[0..f1.len];
    try std.testing.expect(std.mem.startsWith(u8, w1, "<6'op:get"));
    try std.testing.expect(std.mem.indexOf(u8, w1, "4\"name") != null); // field is a String
    // V1.0 has no pushed op:resolve, so the projection trails an op:listen that
    // carries the projected answer's resolution back through a resolver export.
    try expectProjectionListener(peer);

    // op:index against the same receiver carries the (signed) element index.
    var index_answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(peer, &index_answer));
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_index(peer, &receiver, 2, index_answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var f2: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &f2));
    defer c.pancake_managed_frame_release(&f2);
    const w2 = f2.bytes.?[0..f2.len];
    try std.testing.expect(std.mem.startsWith(u8, w2, "<8'op:index"));
    try std.testing.expect(std.mem.indexOf(u8, w2, "2+") != null); // index 2
    try expectProjectionListener(peer);

    // op:untag against the same receiver carries the expected tag as a String.
    var untag_answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(peer, &untag_answer));
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_untag(peer, &receiver, "Point", "Point".len, untag_answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var f3: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &f3));
    defer c.pancake_managed_frame_release(&f3);
    const w3 = f3.bytes.?[0..f3.len];
    try std.testing.expect(std.mem.startsWith(u8, w3, "<8'op:untag"));
    try std.testing.expect(std.mem.indexOf(u8, w3, "5\"Point") != null); // tag is a String
    try expectProjectionListener(peer);

    // Pipelined: a projection against a promise receiver (an unresolved answer)
    // rides a desc:answer target, the promise.get(...) shape on the wire.
    const promise_receiver = c.PancakeReference{
        .kind = c.PANCAKE_REF_PROMISE,
        .sub_kind = c.PANCAKE_REF_SUB_OBJECT,
        .id = get_answer,
    };
    var pipe_answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(peer, &pipe_answer));
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_get(peer, &promise_receiver, "rows", "rows".len, pipe_answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var f4: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &f4));
    defer c.pancake_managed_frame_release(&f4);
    const w4 = f4.bytes.?[0..f4.len];
    try std.testing.expect(std.mem.startsWith(u8, w4, "<6'op:get"));
    try std.testing.expect(std.mem.indexOf(u8, w4, "desc:answer") != null);
    try expectProjectionListener(peer);
}

/// Drain and assert the `op:listen` the engine emits after a projection under a
/// V1.0 session: it is the carrier that brings the projected answer's
/// resolution back (V1.0 has no pushed `op:resolve`).
fn expectProjectionListener(peer: ?*c.PancakePeer) !void {
    var frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &frame));
    defer c.pancake_managed_frame_release(&frame);
    const wire = frame.bytes.?[0..frame.len];
    try std.testing.expect(std.mem.startsWith(u8, wire, "<9'op:listen"));
}

test "C ABI send_abort commits op:abort then closes the CapTP session" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(peer));
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_abort(peer, "GracefulShutdown", "GracefulShutdown".len, "done", "done".len),
    );
    // Queued, not yet committed — still open until step.
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(peer));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    try std.testing.expectEqual(@as(i32, 0), c.pancake_peer_session_is_open(peer));

    var frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &frame));
    defer c.pancake_managed_frame_release(&frame);
    const wire = frame.bytes.?[0..frame.len];
    try std.testing.expect(std.mem.startsWith(u8, wire, "<8'op:abort"));
    try std.testing.expect(std.mem.indexOf(u8, wire, "GracefulShutdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "done") != null);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_peer_send_abort(peer, "NotARealKind", "NotARealKind".len, "", 0),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_peer_send_abort(peer, "", 0, "", 0),
    );
}

test "C ABI send projection refuses a null receiver" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        c.pancake_peer_send_get(peer, null, "name", "name".len, 1),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        c.pancake_peer_send_index(peer, null, 0, 1),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        c.pancake_peer_send_untag(peer, null, "Point", "Point".len, 1),
    );
}

test "C ABI any-poll reads an inbound delivery's target, args, and answer" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(peer, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(peer, &frame));

    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_DELIVER)), c.pancake_peer_peek_event(peer));

    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(peer, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_DELIVER, polled.projection);
    const deliver = polled.deliver;

    try std.testing.expectEqual(@as(u64, 7), deliver.target.id);
    try std.testing.expectEqual(@as(usize, 1), deliver.args_len);
    try std.testing.expectEqual(@as(u32, 1), deliver.has_answer);
    try std.testing.expectEqual(@as(u64, 11), deliver.answer);

    const arg0 = deliver.args.?[0];
    try std.testing.expectEqual(c.PANCAKE_ARG_BYTES, arg0.kind);
    try std.testing.expectEqualStrings("hello", arg0.bytes.?[0..arg0.bytes_len]);
}

test "C ABI any-poll projects a non-typed kind as its opaque frame" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    const wire = "<8'op:abort3\"bye>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(peer, &frame));

    // The next event is an abort: no typed projection, so the any-poll routes
    // it to the frame arm carrying the originating wire bytes, in one call.
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_ABORT)), c.pancake_peer_peek_event(peer));
    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(peer, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_EVENT_ABORT, polled.kind);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_FRAME, polled.projection);
    try std.testing.expect(std.mem.indexOf(u8, polled.frame.bytes.?[0..polled.frame.len], "op:abort") != null);

    // Exactly one event was consumed.
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_peer_peek_event(peer));
}

test "C ABI server flow: receive a call, then send_resolve its answer" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(peer, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(peer, &frame));

    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(peer, &polled));
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_DELIVER, polled.projection);
    const answer = polled.deliver.answer;
    try std.testing.expectEqual(@as(u64, 11), answer);
    c.pancake_any_event_release(&polled);

    // Reply to the call we just received.
    const result = argInt(7);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_resolve(peer, answer, c.PANCAKE_RESOLUTION_FULFILL, &result, null, 0),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));

    var out: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &out));
    defer c.pancake_managed_frame_release(&out);
    const out_wire = out.bytes.?[0..out.len];
    try std.testing.expect(std.mem.indexOf(u8, out_wire, "op:deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_wire, "fulfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_wire, "7+") != null);
}

test "C ABI send_deliver refuses an unsupported reference target loudly" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    const target = c.PancakeReference{ .kind = c.PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 };
    try std.testing.expectEqual(
        c.PANCAKE_ERR_UNSUPPORTED_VALUE,
        c.pancake_peer_send_deliver(peer, &target, null, 0, 0, 0),
    );
}

test "C ABI any-poll falls back to the frame arm for a handoff deliver" {
    // The loop-survives contract, owned by the waist: a legitimate three-party
    // handoff arrives as a deliver whose argument the typed projection cannot
    // carry. The any-poll routes it to the frame arm (interpreted via
    // pancake_peer_codec) in the same call, so the queue always advances and no
    // consumer re-derives a leave-queued fallback.
    const model = pancake.ocapn.model;
    const engine = pancake.ocapn.engine;

    // A native sender encodes the handoff-carrying deliver so the receiver sees
    // the real wire shape rather than a hand-crafted string.
    var sender = engine.Peer.initRawOpenFixture(std.testing.allocator);
    defer sender.deinit();
    try sender.importObject(7);
    var handoff = model.Handoff{ .give = .{
        .recipient_key = &([_]u8{0x42} ** 32),
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = &([_]u8{0xcc} ** 32),
        .gifter_side = &([_]u8{0x11} ** 32),
        .gift_id = &([_]u8{0x01} ** 32),
        .signature = &([_]u8{0xaa} ** 64),
    } };
    try sender.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .handoff = &handoff }},
        .answer = null,
    } });
    _ = try sender.step();
    var wire_frame = sender.takeOutbound().?;
    defer wire_frame.deinit();
    const wire = wire_frame.bytes();

    var receiver: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&receiver));
    defer c.pancake_peer_release(receiver);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(receiver, 7));

    const borrowed = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(receiver, &borrowed));

    // The session codec names how to read the frame arm.
    var codec_id: u32 = 99;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_codec(receiver, &codec_id));
    try std.testing.expectEqual(c.PANCAKE_CODEC_SYRUP, codec_id);

    // One call: the typed projection refuses the handoff argument internally
    // and the same event comes back as its original wire bytes.
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_DELIVER)), c.pancake_peer_peek_event(receiver));
    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(receiver, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_EVENT_DELIVER, polled.kind);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_FRAME, polled.projection);
    try std.testing.expect(std.mem.indexOf(u8, polled.frame.bytes.?[0..polled.frame.len], "desc:handoff-give") != null);

    // The queue advanced: the loop survives.
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_peer_peek_event(receiver));
}

test "C ABI resolve fulfilled with a handoff give projects to PANCAKE_RESOLUTION_HANDOFF" {
    // The recipient half of a three-party handoff: an answer the recipient asked
    // resolves not to a value but to a `desc:handoff-give` it must redeem. The
    // typed resolve poll projects it as `PANCAKE_RESOLUTION_HANDOFF`, surfacing
    // the verbatim give (for pancake_peer_send_withdraw_gift) and the exporter's
    // dialable locator, the binding never sees the opaque frame.
    const model = pancake.ocapn.model;
    const engine = pancake.ocapn.engine;

    // Receiver (C) calls a partner-hosted object with an answer, recording an
    // outbound answer the partner can resolve. A plain export (not bootstrap)
    // keeps the partner from auto-answering, so the give-resolution is ours.
    var receiver: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&receiver));
    defer c.pancake_peer_release(receiver);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(receiver, 9));

    var answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(receiver, &answer));
    const target = farRef(9);
    const args = [_]c.PancakeArgument{argBytes("get-greeter")};
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_deliver(receiver, &target, &args, args.len, 1, answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(receiver));
    var question: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(receiver, &question));
    defer c.pancake_managed_frame_release(&question);

    // A native partner hosts object 9, receives the call, and resolves the answer
    // to a give, gifter origination the C ABI cannot yet do, so a Zig peer
    // stands in. The exporter is a structural PeerLocator that the projection
    // formats as an `ocapn://` URI.
    var sender = engine.Peer.initRawOpenFixture(std.testing.allocator);
    defer sender.deinit();
    try sender.exportObject(9);
    try sender.recvBorrowed(.{ .bytes = question.bytes.?[0..question.len], .shape = .byte });
    _ = try sender.step();

    var handoff = model.Handoff{ .give = .{
        .recipient_key = &([_]u8{0x42} ** 32),
        .exporter = .{ .transport = "tcp", .designator = "127.0.0.1:9099" },
        .gifter_exporter_session = &([_]u8{0xcc} ** 32),
        .gifter_side = &([_]u8{0x11} ** 32),
        .gift_id = &([_]u8{0x01} ** 32),
        .signature = &([_]u8{0xaa} ** 64),
    } };
    try sender.sendCopying(.{ .resolve = .{
        .answer = .from(answer),
        .resolution = .{ .fulfill = .{ .handoff = &handoff } },
    } });
    _ = try sender.step();
    var rframe = sender.takeOutbound().?;
    defer rframe.deinit();
    const rwire = rframe.bytes();

    const borrowed = c.PancakeFrame{ .bytes = rwire.ptr, .len = rwire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(receiver, &borrowed));

    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_RESOLVE)), c.pancake_peer_peek_event(receiver));
    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(receiver, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_RESOLVE, polled.projection);
    const resolve = polled.resolve;

    try std.testing.expectEqual(answer, resolve.answer);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_HANDOFF, resolve.resolution_kind);

    const give = resolve.handoff;
    try std.testing.expect(give.give != null);
    const give_bytes = give.give.?[0..give.give_len];
    // The verbatim signed envelope the binding relays to the exporter.
    try std.testing.expect(std.mem.indexOf(u8, give_bytes, "desc:sig-envelope") != null);
    try std.testing.expect(std.mem.indexOf(u8, give_bytes, "desc:handoff-give") != null);
    try std.testing.expect(give.exporter_locator != null);
    // Formatted through the core URI grammar, so the designator's `:` is
    // percent-encoded, the locator round-trips through `pancake_uri_parse_peer`.
    try std.testing.expectEqualStrings(
        "ocapn://127.0.0.1%3A9099.tcp",
        give.exporter_locator.?[0..give.exporter_locator_len],
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0x42} ** 32),
        give.recipient_key.?[0..give.recipient_key_len],
    );

    // The event was consumed: the loop advanced.
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_peer_peek_event(receiver));
}

test "C ABI send_bootstrap_fetch queues the canonical fetch deliver" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    var answer: u64 = std.math.maxInt(u64);
    const name = "calc";
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_bootstrap_fetch(peer, name.ptr, name.len, &answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));

    var frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &frame));
    defer c.pancake_managed_frame_release(&frame);
    const wire = frame.bytes.?[0..frame.len];

    // The canonical bootstrap fetch: an op:deliver to the bootstrap export
    // carrying ['fetch, <name bytes>].
    try std.testing.expect(std.mem.startsWith(u8, wire, "<10'op:deliver"));
    try std.testing.expect(std.mem.indexOf(u8, wire, "5'fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "4:calc") != null);

    // The answer comes from the session's one allocator: a second fetch gets a
    // fresh question id.
    var second: u64 = answer;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_bootstrap_fetch(peer, name.ptr, name.len, &second),
    );
    try std.testing.expect(second != answer);
}

fn pumpFrames(from: ?*c.PancakePeer, to: ?*c.PancakePeer) !void {
    while (true) {
        var frame: c.PancakeManagedFrame = undefined;
        const rc = c.pancake_peer_take_outbound(from, &frame);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try std.testing.expectEqual(c.PANCAKE_OK, rc);
        defer c.pancake_managed_frame_release(&frame);
        const borrowed = c.PancakeFrame{ .bytes = frame.bytes, .len = frame.len, .shape = frame.shape };
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_recv_borrowed(to, &borrowed));
    }
}

fn drainEvents(peer: ?*c.PancakePeer) void {
    while (true) {
        var event: c.PancakeEvent = undefined;
        if (c.pancake_peer_poll_event(peer, &event) != c.PANCAKE_OK) break;
        c.pancake_event_release(&event);
    }
}

test "C ABI enliven round-trips over the wire, then a repeat enliven hits the cache" {
    // The requester half of sturdyref enliven over the C ABI (ADR-0012): a fresh
    // enliven queues a bootstrap-fetch, the partner auto-serves the swissnum, and
    // `record_enlivenment` caches the far import so a repeat short-circuits with
    // no wire traffic. Two raw-open peers stand in for a keyed session: both
    // carry the full feature set, so the sturdyref precondition holds.
    var requester: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&requester));
    defer c.pancake_peer_release(requester);
    var responder: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&responder));
    defer c.pancake_peer_release(responder);

    // The responder hosts its bootstrap object (export 0) and publishes a cap
    // behind "swiss"; the auto-serve fulfills the inbound fetch from that table.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(responder, c.PANCAKE_BOOTSTRAP_POSITION));
    var cap_export: u64 = 0;
    const swiss = "swiss";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_bootstrap_cap(responder, swiss.ptr, swiss.len, &cap_export));

    var start: c.PancakeEnlivenStart = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_prepare_enliven(requester, swiss.ptr, swiss.len, &start));
    try std.testing.expectEqual(c.PANCAKE_ENLIVEN_FRESH, start.status);
    const answer = start.answer;

    // Drive the bootstrap-fetch to settlement: the requester emits the fetch, the
    // responder auto-serves it (a deliver event plus a synthesized resolve), and
    // the resolve lands back on the requester as a fulfilled far reference.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(requester));
    try pumpFrames(requester, responder);
    drainEvents(responder);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(responder));
    try pumpFrames(responder, requester);

    var polled: c.PancakeAnyEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(requester, &polled));
    defer c.pancake_any_event_release(&polled);
    try std.testing.expectEqual(c.PANCAKE_PROJECTION_RESOLVE, polled.projection);
    const resolve = polled.resolve;
    try std.testing.expectEqual(answer, resolve.answer);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, resolve.resolution_kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, resolve.fulfill.kind);
    const enlivened = resolve.fulfill.reference;
    try std.testing.expectEqual(c.PANCAKE_REF_FAR, enlivened.kind);
    try std.testing.expectEqual(cap_export, enlivened.id);

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_record_enlivenment(
        requester,
        swiss.ptr,
        swiss.len,
        c.PANCAKE_ENLIVEN_OUTCOME_FULFILLED,
        enlivened.id,
        enlivened.sub_kind,
    ));

    // A repeat enliven now short-circuits to the cached far reference: no wire.
    var cached: c.PancakeEnlivenStart = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_prepare_enliven(requester, swiss.ptr, swiss.len, &cached));
    try std.testing.expectEqual(c.PANCAKE_ENLIVEN_CACHED, cached.status);
    try std.testing.expectEqual(cap_export, cached.import_position);
    try std.testing.expectEqual(enlivened.sub_kind, cached.kind);
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_peer_peek_event(requester));
}

test "C ABI prepare_enliven collapses a concurrent enliven and clears a broken marker" {
    var requester: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&requester));
    defer c.pancake_peer_release(requester);

    const swiss = "swiss";
    var first: c.PancakeEnlivenStart = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_prepare_enliven(requester, swiss.ptr, swiss.len, &first));
    try std.testing.expectEqual(c.PANCAKE_ENLIVEN_FRESH, first.status);

    // A second enliven for the same swissnum collapses onto the outstanding answer.
    var second: c.PancakeEnlivenStart = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_prepare_enliven(requester, swiss.ptr, swiss.len, &second));
    try std.testing.expectEqual(c.PANCAKE_ENLIVEN_IN_FLIGHT, second.status);
    try std.testing.expectEqual(first.answer, second.answer);

    // A broken settlement clears the in-flight marker, so a later enliven is fresh.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_record_enlivenment(
        requester,
        swiss.ptr,
        swiss.len,
        c.PANCAKE_ENLIVEN_OUTCOME_BROKEN,
        0,
        0,
    ));
    var third: c.PancakeEnlivenStart = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_prepare_enliven(requester, swiss.ptr, swiss.len, &third));
    try std.testing.expectEqual(c.PANCAKE_ENLIVEN_FRESH, third.status);
}

test "C ABI gc verbs queue op:gc-export and op:gc-answer" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(peer, 5));

    // Ask a question first, so there is an answer row to release later. The
    // question must be a real recorded send: the session refuses a gc for an
    // answer it never saw.
    var answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(peer, &answer));
    const target = farRef(5);
    const args = [_]c.PancakeArgument{argInt(1)};
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_deliver(peer, &target, args[0..].ptr, args.len, 1, answer),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var question_frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &question_frame));
    c.pancake_managed_frame_release(&question_frame);

    // Release the import this peer holds (op:gc-export, wire-delta 1).
    const positions = [_]u64{5};
    const deltas = [_]u64{1};
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_send_gc_export(peer, &positions, &deltas, positions.len),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var gc_export_frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &gc_export_frame));
    defer c.pancake_managed_frame_release(&gc_export_frame);
    try std.testing.expect(std.mem.indexOf(u8, gc_export_frame.bytes.?[0..gc_export_frame.len], "op:gc-export") != null);

    // An empty release is a caller bug, refused loudly.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        c.pancake_peer_send_gc_export(peer, &positions, &deltas, 0),
    );

    // Release the answer (op:gc-answer).
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_gc_answer(peer, answer));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(peer));
    var gc_answer_frame: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(peer, &gc_answer_frame));
    defer c.pancake_managed_frame_release(&gc_answer_frame);
    try std.testing.expect(std.mem.indexOf(u8, gc_answer_frame.bytes.?[0..gc_answer_frame.len], "op:gc-answer") != null);
}
