//! The sealed channel's ingest and park contract, at the unit level.
//!
//! `foundation.sealed.SealedChannel` is driven live by the byte-fed host and
//! the completion-loop adapter, and those tiers' tests cover the composed
//! behavior. What they cannot pin is the channel's own staging arithmetic:
//! `park` hands the channel an arbitrary unread wire suffix, and that suffix
//! is allowed to hold whole records, not just the front of one. A partner
//! that pipelines deliveries behind its hello in one segment produces exactly
//! that shape at the host's hello pause boundary. The scratch a record opens
//! into is also pinned here: a record body shorter than its tag retires the
//! channel, and the wipe before the next open covers the previous plaintext
//! exactly.

const std = @import("std");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const sealed = glowcap.foundation.sealed;

const transport = "noise-tcp";

fn openPair(a: *sealed.SealedChannel, b: *sealed.SealedChannel) !void {
    const gpa = std.testing.allocator;

    var msg1 = (try a.takeWire(gpa)).?;
    defer msg1.deinit();
    const step1 = try b.ingest(gpa, msg1.bytes());
    try std.testing.expectEqual(msg1.bytes().len, step1.consumed);
    try std.testing.expect(step1.event == .handshake);

    var msg2 = (try b.takeWire(gpa)).?;
    defer msg2.deinit();
    const step2 = try a.ingest(gpa, msg2.bytes());
    try std.testing.expectEqual(msg2.bytes().len, step2.consumed);
    try std.testing.expect(step2.event == .completed);

    var msg3 = (try a.takeWire(gpa)).?;
    defer msg3.deinit();
    const step3 = try b.ingest(gpa, msg3.bytes());
    try std.testing.expectEqual(msg3.bytes().len, step3.consumed);
    try std.testing.expect(step3.event == .completed);
}

test "a parked suffix holding complete records drains through ingest" {
    const gpa = std.testing.allocator;

    const initiator_identity = crypto.SecretKey.fromSeed(@splat(1));
    const responder_identity = crypto.SecretKey.fromSeed(@splat(2));

    var initiator = try sealed.SealedChannel.initInitiator(
        &initiator_identity,
        responder_identity.publicKey(),
        @splat(3),
        transport,
    );
    defer initiator.deinit(gpa);
    var responder = try sealed.SealedChannel.initResponder(
        &responder_identity,
        @splat(4),
        transport,
    );
    defer responder.deinit(gpa);
    try openPair(&initiator, &responder);

    // Two whole records in one wire span, the shape a partner produces by
    // pipelining a second write behind its first in a single segment.
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try initiator.sealBytes(gpa, &wire, "first record");
    try initiator.sealBytes(gpa, &wire, "second record");

    // The host's hello pause parks the whole unread suffix; the resume feeds
    // no fresh bytes. The staged prefix must drain one record per step.
    try responder.park(gpa, wire.items);
    const first = try responder.ingest(gpa, &.{});
    try std.testing.expectEqual(@as(usize, 0), first.consumed);
    try std.testing.expectEqualStrings("first record", first.event.plaintext);
    responder.releasePlaintext();

    const second = try responder.ingest(gpa, &.{});
    try std.testing.expectEqual(@as(usize, 0), second.consumed);
    try std.testing.expectEqualStrings("second record", second.event.plaintext);
    responder.releasePlaintext();

    try std.testing.expect(!responder.hasStagedInbound());
}

test "a parked suffix ending mid-record finishes from fresh bytes" {
    const gpa = std.testing.allocator;

    const initiator_identity = crypto.SecretKey.fromSeed(@splat(5));
    const responder_identity = crypto.SecretKey.fromSeed(@splat(6));

    var initiator = try sealed.SealedChannel.initInitiator(
        &initiator_identity,
        responder_identity.publicKey(),
        @splat(7),
        transport,
    );
    defer initiator.deinit(gpa);
    var responder = try sealed.SealedChannel.initResponder(
        &responder_identity,
        @splat(8),
        transport,
    );
    defer responder.deinit(gpa);
    try openPair(&initiator, &responder);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try initiator.sealBytes(gpa, &wire, "whole record");
    try initiator.sealBytes(gpa, &wire, "split record");

    // Park past the first record's end so the staged prefix holds one whole
    // record plus the front of the next; the rest arrives as a fresh chunk.
    const split_at = wire.items.len - 4;
    try responder.park(gpa, wire.items[0..split_at]);

    const first = try responder.ingest(gpa, wire.items[split_at..]);
    try std.testing.expectEqual(@as(usize, 0), first.consumed);
    try std.testing.expectEqualStrings("whole record", first.event.plaintext);
    responder.releasePlaintext();

    const second = try responder.ingest(gpa, wire.items[split_at..]);
    try std.testing.expectEqual(@as(usize, 4), second.consumed);
    try std.testing.expectEqualStrings("split record", second.event.plaintext);
    responder.releasePlaintext();

    try std.testing.expect(!responder.hasStagedInbound());
}

fn openedPair(initiator: *sealed.SealedChannel, responder: *sealed.SealedChannel, seeds: [4]u8) !void {
    const initiator_identity = crypto.SecretKey.fromSeed(@splat(seeds[0]));
    const responder_identity = crypto.SecretKey.fromSeed(@splat(seeds[1]));
    initiator.* = try sealed.SealedChannel.initInitiator(
        &initiator_identity,
        responder_identity.publicKey(),
        @splat(seeds[2]),
        transport,
    );
    responder.* = try sealed.SealedChannel.initResponder(
        &responder_identity,
        @splat(seeds[3]),
        transport,
    );
    try openPair(initiator, responder);
}

test "a record body shorter than its tag retires the channel" {
    const gpa = std.testing.allocator;
    var initiator: sealed.SealedChannel = undefined;
    var responder: sealed.SealedChannel = undefined;
    try openedPair(&initiator, &responder, .{ 9, 10, 11, 12 });
    defer initiator.deinit(gpa);
    defer responder.deinit(gpa);

    // A header claiming five body bytes: no room for the sixteen-byte tag,
    // so there is nothing to authenticate and the open is refused before
    // any cipher state moves.
    const wire = [_]u8{ 0, 5, 1, 2, 3, 4, 5 };
    try std.testing.expectError(error.MessageTooShort, responder.ingest(gpa, &wire));
    try std.testing.expect(!responder.isOpen());
}

test "the wipe before the next open covers the previous plaintext exactly" {
    const gpa = std.testing.allocator;
    var initiator: sealed.SealedChannel = undefined;
    var responder: sealed.SealedChannel = undefined;
    try openedPair(&initiator, &responder, .{ 13, 14, 15, 16 });
    defer initiator.deinit(gpa);
    defer responder.deinit(gpa);

    const long_len = 300;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try initiator.sealBytes(gpa, &wire, &(@as([long_len]u8, @splat('a'))));
    const first = try responder.ingest(gpa, wire.items);
    try std.testing.expectEqual(wire.items.len, first.consumed);
    try std.testing.expectEqual(@as(usize, long_len), first.event.plaintext.len);
    try std.testing.expectEqual(@as(u32, long_len), responder.plain_used);
    responder.releasePlaintext();

    wire.clearRetainingCapacity();
    try initiator.sealBytes(gpa, &wire, "tiny");
    const second = try responder.ingest(gpa, wire.items);
    try std.testing.expectEqualStrings("tiny", second.event.plaintext);
    responder.releasePlaintext();

    // The long record's bytes past the short one are gone, and the written
    // span now names only the short record.
    try std.testing.expectEqual(@as(u32, 4), responder.plain_used);
    for (responder.plain[4..long_len]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a transport symbol past the prologue bound is refused before any key work" {
    const identity = crypto.SecretKey.fromSeed(@splat(5));
    const long_symbol: [sealed.max_transport_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.TransportTooLong, sealed.SealedChannel.initResponder(
        &identity,
        @splat(6),
        &long_symbol,
    ));
    try std.testing.expectError(error.TransportTooLong, sealed.SealedChannel.initInitiator(
        &identity,
        crypto.SecretKey.fromSeed(@splat(7)).publicKey(),
        @splat(8),
        &long_symbol,
    ));
    var at_bound = try sealed.SealedChannel.initResponder(&identity, @splat(9), long_symbol[1..]);
    at_bound.deinit(std.testing.allocator);
}

test "a suffix park cannot keep fails the channel" {
    const gpa = std.testing.allocator;

    const initiator_identity = crypto.SecretKey.fromSeed(@splat(9));
    const responder_identity = crypto.SecretKey.fromSeed(@splat(10));

    var initiator = try sealed.SealedChannel.initInitiator(
        &initiator_identity,
        responder_identity.publicKey(),
        @splat(11),
        transport,
    );
    defer initiator.deinit(gpa);
    var responder = try sealed.SealedChannel.initResponder(
        &responder_identity,
        @splat(12),
        transport,
    );
    defer responder.deinit(gpa);
    try openPair(&initiator, &responder);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try initiator.sealBytes(gpa, &wire, "lost record");

    // The caller's buffer expires after a refused park, so the record is
    // gone and no later one can open behind it.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, responder.park(failing.allocator(), wire.items));
    try std.testing.expect(!responder.isOpen());
    try std.testing.expect(!responder.hasStagedInbound());
}
