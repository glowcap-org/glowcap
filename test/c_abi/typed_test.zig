//! Typed OCapN driving surface — proves a C consumer can *construct* a call and
//! *inspect* a delivery as structured values, not just shuttle opaque frames.
//! This is the surface that turns a binding from "observes that a message
//! arrived" into "calls a remote method and reads the reply."

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

fn argInt(value: i64) c.PancakeArgument {
    var a = std.mem.zeroes(c.PancakeArgument);
    a.kind = c.PANCAKE_ARG_INTEGER;
    a.integer = value;
    return a;
}

fn argBytes(bytes: []const u8) c.PancakeArgument {
    var a = std.mem.zeroes(c.PancakeArgument);
    a.kind = c.PANCAKE_ARG_BYTES;
    a.bytes = bytes.ptr;
    a.bytes_len = bytes.len;
    return a;
}

fn farRef(import_position: u64) c.PancakeReference {
    return .{ .kind = c.PANCAKE_REF_FAR, .sub_kind = c.PANCAKE_REF_SUB_OBJECT, .id = import_position };
}

test "C ABI typed surface carries set, tagged, and keyword arguments" {
    // Inspect: a delivery whose args are a set, a tagged record, and a keyword
    // projects to the full passable tree.
    var receiver: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&receiver));
    defer c.pancake_peer_release(receiver);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(receiver, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[#1+2+$<11'user-record5'Point[3+4+]><2'kw5'color>]11+f>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(receiver, &frame));

    var deliver: c.PancakeDeliver = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event_deliver(receiver, &deliver));
    defer c.pancake_deliver_release(&deliver);

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
    var set_arg = std.mem.zeroes(c.PancakeArgument);
    set_arg.kind = c.PANCAKE_ARG_SET;
    set_arg.items = set_items[0..].ptr;
    set_arg.items_len = set_items.len;

    const tagged_items = [_]c.PancakeArgument{argInt(3)};
    var tagged_arg = std.mem.zeroes(c.PancakeArgument);
    tagged_arg.kind = c.PANCAKE_ARG_TAGGED;
    tagged_arg.bytes = "Point".ptr;
    tagged_arg.bytes_len = "Point".len;
    tagged_arg.items = tagged_items[0..].ptr;
    tagged_arg.items_len = tagged_items.len;

    var kw_arg = std.mem.zeroes(c.PancakeArgument);
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
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(receiver, &frame));

    var deliver: c.PancakeDeliver = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event_deliver(receiver, &deliver));
    defer c.pancake_deliver_release(&deliver);
    const big_arg = deliver.args.?[0];
    try std.testing.expectEqual(c.PANCAKE_ARG_BIG_INTEGER, big_arg.kind);
    try std.testing.expectEqual(@as(u8, 1), big_arg.boolean);
    try std.testing.expectEqualStrings(digits, big_arg.bytes.?[0..big_arg.bytes_len]);

    // Construct: an outbound send carries the same value back to the wire.
    var sender: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&sender));
    defer c.pancake_peer_release(sender);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(sender, 5));

    var arg = std.mem.zeroes(c.PancakeArgument);
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
    var small = std.mem.zeroes(c.PancakeArgument);
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

test "C ABI poll_event_deliver reads an inbound delivery's target, args, and answer" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(peer, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(peer, &frame));

    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_DELIVER)), c.pancake_peer_peek_event(peer));

    var deliver: c.PancakeDeliver = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event_deliver(peer, &deliver));
    defer c.pancake_deliver_release(&deliver);

    try std.testing.expectEqual(@as(u64, 7), deliver.target.id);
    try std.testing.expectEqual(@as(usize, 1), deliver.args_len);
    try std.testing.expectEqual(@as(u32, 1), deliver.has_answer);
    try std.testing.expectEqual(@as(u64, 11), deliver.answer);

    const arg0 = deliver.args.?[0];
    try std.testing.expectEqual(c.PANCAKE_ARG_BYTES, arg0.kind);
    try std.testing.expectEqualStrings("hello", arg0.bytes.?[0..arg0.bytes_len]);
}

test "C ABI typed poll routes by kind and leaves a mismatched event queued" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    const wire = "<8'op:abort3\"bye>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(peer, &frame));

    // The next event is an abort, so a deliver poll refuses without consuming it.
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_ABORT)), c.pancake_peer_peek_event(peer));
    var deliver: c.PancakeDeliver = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WRONG_EVENT, c.pancake_peer_poll_event_deliver(peer, &deliver));

    // The abort is still there for the generic poll.
    var event: c.PancakeEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event(peer, &event));
    defer c.pancake_event_release(&event);
    try std.testing.expectEqual(c.PANCAKE_EVENT_ABORT, event.kind);
}

test "C ABI server flow: receive a call, then send_resolve its answer" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(peer, 7));

    const wire = "<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
    const frame = c.PancakeFrame{ .bytes = wire.ptr, .len = wire.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(peer, &frame));

    var deliver: c.PancakeDeliver = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event_deliver(peer, &deliver));
    const answer = deliver.answer;
    try std.testing.expectEqual(@as(u64, 11), answer);
    c.pancake_deliver_release(&deliver);

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

test "C ABI typed poll leaves a handoff deliver queued and the opaque poll drains it" {
    // The loop-survives contract: a legitimate three-party handoff arrives as a
    // deliver whose argument the typed projection cannot carry. The typed poll
    // refuses with UNSUPPORTED_VALUE and leaves the event queued; the opaque
    // poll drains it (interpreted via pancake_peer_codec), and the next poll
    // proceeds instead of failing identically forever.
    const model = pancake.ocapn.model;
    const engine = pancake.ocapn.engine;

    // A native sender encodes the handoff-carrying deliver so the receiver sees
    // the real wire shape rather than a hand-crafted string.
    var sender = engine.Peer.initRawOpenFixture(std.testing.allocator);
    defer sender.deinit();
    try sender.importObject(7);
    var handoff = model.Handoff{ .give = .{
        .recipient_key = &([_]u8{0x42} ** 32),
        .exporter_location = "memory:exporter",
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
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(receiver, &borrowed));

    // The typed poll refuses the handoff argument and leaves the event queued.
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_DELIVER)), c.pancake_peer_peek_event(receiver));
    var deliver: c.PancakeDeliver = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_UNSUPPORTED_VALUE, c.pancake_peer_poll_event_deliver(receiver, &deliver));
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_DELIVER)), c.pancake_peer_peek_event(receiver));

    // The session codec names how to read the opaque frame.
    var codec_id: u32 = 99;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_codec(receiver, &codec_id));
    try std.testing.expectEqual(c.PANCAKE_CODEC_SYRUP, codec_id);

    // The opaque poll drains the refused event with its original wire bytes.
    var event: c.PancakeEvent = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event(receiver, &event));
    defer c.pancake_event_release(&event);
    try std.testing.expectEqual(c.PANCAKE_EVENT_DELIVER, event.kind);
    try std.testing.expect(std.mem.indexOf(u8, event.frame.bytes.?[0..event.frame.len], "desc:handoff-give") != null);

    // The queue advanced: the loop survives.
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
