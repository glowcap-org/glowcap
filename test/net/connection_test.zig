//! Connection framing-core tests, driven over `Reader.fixed` / `Writer.fixed`
//! with a real `*engine.Peer`, with no sockets. These prove the byte-stream half of
//! the one-parser contract: bytes in, frames out, and every termination
//! condition (graceful close, truncation, malformed, oversize) surfaced as the
//! right typed outcome rather than swallowed.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;

const zero_pubkey = @as([32]u8, @splat(0));
const zero_sig = @as([64]u8, @splat(0));

/// These tests prove byte-stream framing, not handshake authentication, and the
/// `op:start-session` they feed carries the stub zero signature, so the peers
/// run with partner-signature verification off (a verifying peer would, rightly,
/// refuse the unsigned handshake). The keyed path is covered in `pairing_test`.
fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

/// Encode the stub-key `op:start-session` a negotiating peer admits. The caller
/// owns the returned frame (it backs the inbound byte stream).
fn startSessionFrame(allocator: std.mem.Allocator, designator: []const u8) !glowcap.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey },
            .acceptable_location = .{
                .transport = "memory",
                .designator = designator,
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &zero_sig },
        },
    });
}

fn appendStreamFrame(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    _ = try net.appendFrameBytes(list, allocator, bytes);
}

test "pumpOver frames one buffered frame, applies it, then reports graceful close" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, frame.bytes());
    var reader = std.Io.Reader.fixed(stream_bytes.items);
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    const first = try net.pumpOver(&peer, &reader, &writer, &spill);
    try std.testing.expect(first == .received);
    try std.testing.expectEqual(stream_bytes.items.len, first.received);

    var event = peer.pollEvent() orelse return error.TestExpectedEvent;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.start_session, event.kind());

    // Buffer drained, stream ended on a frame boundary → graceful close.
    const second = try net.pumpOver(&peer, &reader, &writer, &spill);
    try std.testing.expect(second == .closed);
}

test "pumpOver frames each frame of a concatenation in order" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    var f1 = try startSessionFrame(allocator, "a");
    defer f1.deinit();
    var f2 = try startSessionFrame(allocator, "a");
    defer f2.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, f1.bytes());
    try appendStreamFrame(&stream_bytes, allocator, f2.bytes());

    var reader = std.Io.Reader.fixed(stream_bytes.items);
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    const p1 = try net.pumpOver(&peer, &reader, &writer, &spill);
    try std.testing.expect(p1 == .received);
    const first_outer = net.outerPrefix(stream_bytes.items, peer.limits().max_frame_bytes).decoded;
    try std.testing.expectEqual(first_outer.consumed, p1.received);

    // The duplicate start-session is a protocol violation (already received one),
    // so the second frame is *framed* (one parse) but refused by authority,
    // surfaced as a protocol abort, not swallowed.
    try std.testing.expectError(error.ProtocolAbort, net.pumpOver(&peer, &reader, &writer, &spill));

    // `ProtocolAbort` names only the family; the typed member stays readable on
    // the peer, so a consumer diagnoses the refusal without bypassing the adapter.
    const cause = peer.lastAbort().?;
    try std.testing.expectEqual(engine.abort_projection.Domain.session, cause.domain);
    try std.testing.expect(cause.kind != null);
    try std.testing.expect(cause.error_name.len > 0);
}

test "pumpOver surfaces a mid-frame EOF as TruncatedFrame" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    // One whole frame followed by the first half of another.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, frame.bytes());
    const half = framed.items[0 .. framed.items.len / 2];
    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, frame.bytes());
    try stream_bytes.appendSlice(allocator, half);

    var reader = std.Io.Reader.fixed(stream_bytes.items);
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    const first = try net.pumpOver(&peer, &reader, &writer, &spill);
    try std.testing.expect(first == .received);

    // The trailing partial frame cannot complete: EOF mid-frame.
    try std.testing.expectError(error.TruncatedFrame, net.pumpOver(&peer, &reader, &writer, &spill));
}

test "pumpOver surfaces structurally invalid bytes as MalformedFrame" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    var reader = std.Io.Reader.fixed("1:x");
    var write_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try std.testing.expectError(error.MalformedFrame, net.pumpOver(&peer, &reader, &writer, &spill));
}

test "pumpOver surfaces an over-cap frame as FrameTooLarge" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    // A cap far below the start-session frame: cap-on-parse rejects it.
    peer.session_state.limits.max_frame_bytes = 8;

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    var stream_bytes: std.ArrayList(u8) = .empty;
    defer stream_bytes.deinit(allocator);
    try appendStreamFrame(&stream_bytes, allocator, frame.bytes());
    var reader = std.Io.Reader.fixed(stream_bytes.items);
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try std.testing.expectError(error.FrameTooLarge, net.pumpOver(&peer, &reader, &writer, &spill));
}

test "pumpOver carries an admissible frame larger than the read buffer through the spill" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();
    try std.testing.expect(frame.bytes().len > 16);

    // A 16-byte read buffer streams the frame in slices, so the frame must
    // assemble in the spill before it can decode.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, frame.bytes());
    var read_buf: [16]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = framed.items }});
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    while (true) {
        const progress = try net.pumpOver(&peer, &small.interface, &writer, &spill);
        if (progress == .received) {
            try std.testing.expectEqual(framed.items.len, progress.received);
            break;
        }
        try std.testing.expect(progress == .idle);
    }

    var event = peer.pollEvent() orelse return error.TestExpectedEvent;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.start_session, event.kind());

    // The spill frees itself the moment it drains: steady state is the read
    // buffer again.
    try std.testing.expect(!spill.isActive());
    try std.testing.expectEqual(@as(usize, 0), spill.buf.len);

    const last = try net.pumpOver(&peer, &small.interface, &writer, &spill);
    try std.testing.expect(last == .closed);
}

test "pumpOver surfaces a mid-frame EOF as TruncatedFrame while the spill is active" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();

    // Most of a frame, then EOF: the prefix outgrows the 16-byte buffer (so it
    // is mid-assembly in the spill) and can never complete.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, frame.bytes());
    const partial = framed.items[0 .. framed.items.len - 8];
    var read_buf: [16]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = partial }});
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    while (true) {
        const progress = net.pumpOver(&peer, &small.interface, &writer, &spill) catch |err| {
            try std.testing.expectEqual(error.TruncatedFrame, err);
            try std.testing.expect(spill.isActive());
            return;
        };
        try std.testing.expect(progress == .idle);
    }
}

test "pumpOver surfaces an over-cap frame as FrameTooLarge while spilling" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    // The frame is admissible for the buffer-size question (it outgrows the
    // 16-byte buffer) but crosses the session cap during the scan.
    peer.session_state.limits.max_frame_bytes = 64;

    var frame = try startSessionFrame(allocator, "remote");
    defer frame.deinit();
    try std.testing.expect(frame.bytes().len > 64);

    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    try appendStreamFrame(&framed, allocator, frame.bytes());
    var read_buf: [16]u8 = undefined;
    var small = std.testing.Reader.init(&read_buf, &.{.{ .buffer = framed.items }});
    var write_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    while (true) {
        const progress = net.pumpOver(&peer, &small.interface, &writer, &spill) catch |err| {
            try std.testing.expectEqual(error.FrameTooLarge, err);
            return;
        };
        try std.testing.expect(progress == .idle);
    }
}

test "pumpOver flushes the peer's queued outbound frames" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    // A negotiating peer may send its own op:start-session.
    try peer.sendBorrowed(.{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey },
            .acceptable_location = .{
                .transport = "memory",
                .designator = "local",
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &zero_sig },
        },
    });

    var reader = std.Io.Reader.fixed(&.{}); // nothing inbound
    var write_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    const progress = try net.pumpOver(&peer, &reader, &writer, &spill);
    try std.testing.expect(progress == .sent);
    try std.testing.expect(progress.sent > 0);
    try std.testing.expectEqual(progress.sent, writer.buffered().len);
    const outer = net.outerPrefix(writer.buffered(), peer.limits().max_frame_bytes).decoded;
    try std.testing.expectEqual(writer.buffered().len, outer.consumed);
    try std.testing.expect(outer.body.len > 0);
}

// R2 apex: the write-half abort-flush contract `Connection.flush` and `pumpOver`
// share through `encodeAndFlush`. When `stepToIdle` fails it has already
// projected the fail-loud `op:abort` onto outbound; the catch drains that abort
// to the wire and surfaces either the classified cause or an explicit terminal
// delivery failure. Previously only the read-half apply abort was pinned.
test "encodeAndFlush drains the projected abort to the wire when stepToIdle fails, then surfaces the cause" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();

    // Queue two start-sessions for dispatch: the first establishes the session,
    // the second is a duplicate session authority refuses, so the engine
    // projects an `op:abort` onto outbound. Both ride the dispatch path, so it
    // is `stepToIdle` that fails, exercising encodeAndFlush's abort-flush catch,
    // not the read-half `recvOuterPrefix` path.
    try peer.feedOwned(try startSessionFrame(allocator, "remote"));
    try peer.feedOwned(try startSessionFrame(allocator, "remote"));

    var empty = std.Io.Reader.fixed("");
    var write_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buf);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    // pumpOver runs encodeAndFlush first: stepToIdle fails on the duplicate, the
    // catch drains the projected abort to `w`, then classifies it.
    try std.testing.expectError(error.ProtocolAbort, net.pumpOver(&peer, &empty, &writer, &spill));

    // The fail-loud `op:abort` reached the wire (the contract's whole point), and
    // the typed session-domain cause stays readable through `lastAbort`.
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "op:abort") != null);
    const cause = peer.lastAbort().?;
    try std.testing.expectEqual(engine.abort_projection.Domain.session, cause.domain);
}

test "encodeAndFlush reports a refused projected-abort write without losing its protocol cause" {
    const allocator = std.testing.allocator;

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    try peer.feedOwned(try startSessionFrame(allocator, "remote"));
    try peer.feedOwned(try startSessionFrame(allocator, "remote"));

    var empty = std.Io.Reader.fixed("");
    var no_space: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&no_space);
    var spill: net.Spill = .{};
    defer spill.deinit(allocator);

    try std.testing.expectError(error.AbortFlushFailed, net.pumpOver(&peer, &empty, &writer, &spill));
    const cause = peer.lastAbort().?;
    try std.testing.expectEqual(engine.abort_projection.Domain.session, cause.domain);
    try std.testing.expectEqualStrings("DuplicateStartSession", cause.error_name);
}

test "a connection-owned transport failure is claimed exactly once" {
    const Fixture = struct {
        failure: ?glowcap.foundation.FailureChain,

        fn close(_: *anyopaque) void {}
        fn socket(_: *anyopaque) ?std.Io.net.Socket.Handle {
            return null;
        }
        fn take(ctx: *anyopaque) ?glowcap.foundation.FailureChain {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const failure = self.failure;
            self.failure = null;
            return failure;
        }
    };

    var fixture = Fixture{ .failure = .init(error.ReadFailed) };
    var peer = stubNegotiatingPeer(std.testing.allocator);
    defer peer.deinit();
    var reader = std.Io.Reader.fixed("");
    var storage: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var conn = net.Connection.init(undefined, &peer, &reader, &writer, .{
        .ctx = &fixture,
        .close_fn = Fixture.close,
        .socket_handle_fn = Fixture.socket,
        .take_failure_fn = Fixture.take,
    });
    const failure = conn.takeFailure().?;
    try std.testing.expectEqual(error.ReadFailed, failure.cause);
    try std.testing.expect(conn.takeFailure() == null);
}

test "connection cleanup owns its allocator independently of the retired peer" {
    const Fixture = struct {
        closed: bool = false,
        fn close(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.closed = true;
        }
        fn socket(_: *anyopaque) ?std.Io.net.Socket.Handle {
            return null;
        }
    };
    const allocator = std.testing.allocator;
    var fixture = Fixture{};
    var peer = stubNegotiatingPeer(allocator);
    var reader = std.Io.Reader.fixed("");
    var storage: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var conn = net.Connection.init(undefined, &peer, &reader, &writer, .{
        .ctx = &fixture,
        .close_fn = Fixture.close,
        .socket_handle_fn = Fixture.socket,
    });
    conn.spill.absorbBytes(allocator, "retained frame prefix") catch |err| {
        conn.deinit();
        peer.deinit();
        return err;
    };
    // Host session release may consume the peer before the physical carrier
    // finishes closing. No pump may run now, but owned storage must still free.
    peer.deinit();
    peer = undefined;
    conn.deinit();
    try std.testing.expect(fixture.closed);
}

test "a connection close barrier retains its exact transport chain" {
    const Fixture = struct {
        advances: usize = 0,
        failure: ?glowcap.foundation.FailureChain,

        fn close(_: *anyopaque) void {}
        fn tryClose(ctx: *anyopaque) net.ConnectionCloseProgress {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.advances += 1;
            return if (self.advances == 1) .wait_read else .failed;
        }
        fn socket(_: *anyopaque) ?std.Io.net.Socket.Handle {
            return null;
        }
        fn take(ctx: *anyopaque) ?glowcap.foundation.FailureChain {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const failure = self.failure;
            self.failure = null;
            return failure;
        }
    };

    var failure = glowcap.foundation.FailureChain.init(error.TlsCloseFailed);
    failure.note(error.SocketCloseFailed);
    var fixture = Fixture{ .failure = failure };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var peer = stubNegotiatingPeer(std.testing.allocator);
    defer peer.deinit();
    var reader = std.Io.Reader.fixed("");
    var storage: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var conn = net.Connection.init(threaded.io(), &peer, &reader, &writer, .{
        .ctx = &fixture,
        .close_fn = Fixture.close,
        .try_close_fn = Fixture.tryClose,
        .socket_handle_fn = Fixture.socket,
        .take_failure_fn = Fixture.take,
    });

    const reported = conn.closeGracefully(100).?;
    try std.testing.expectEqual(error.TlsCloseFailed, reported.cause);
    try std.testing.expectEqual(error.SocketCloseFailed, reported.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 1), reported.secondary_count);
    try std.testing.expectEqual(@as(usize, 2), fixture.advances);
    try std.testing.expect(conn.takeFailure() == null);
}
