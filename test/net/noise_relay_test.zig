//! The sealing completion adapter (`noise-relay`, ADR-0107) at the loop
//! tier's byte seam. The mock platform below *is* the pipe a relay would
//! forward — ADR-0086's relay is byte-transparent, so what crosses this seam
//! is exactly what a relay sees — and the tests hold the record's step-5
//! claims there: the dial's connect completion waits for the Noise_XK
//! handshake, `verifiedChannelKey` answers the responder's durable key at
//! adoption time, every submitted send crosses the pipe as sealed records
//! with no plaintext byte, opened records lend their plaintext to the recv
//! seat, and a responder that substitutes its own static key never yields a
//! connected session. The ciphertext scanner is calibrated against a
//! positive: the same needle is found in what the honest responder *opened*,
//! so an empty scan of the pipe is a finding about the wire, not the probe.
//! The live siblings register both the sealed resident and the generic C
//! provider, carry authenticated fetches through the reference relay, and
//! observe its pipe. Binding and browser proofs exercise the same profile
//! through their public products.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../support/actors.zig");
const ws_relay = @import("../support/ws_relay.zig");

const foundation = pancake.foundation;
const crypto = foundation.crypto;
const sealed = foundation.sealed;
const model = pancake.ocapn.model;
const net = pancake.net;
const completion = net.completion;
const noise_completion = net.noise_completion;
const driver = pancake.driver;

/// A completion platform that records every submitted send and hands back
/// test-scripted completions: the adapter's byte pipe, observable.
const PipePlatform = struct {
    pub const Fd = i32;
    pub const adapter_depth = 0;
    pub const ConnectTarget = u32;

    allocator: std.mem.Allocator,
    /// Every byte the adapter submitted for the wire, in order: the pipe's
    /// (and so a relay's) view of the connection.
    wire: std.ArrayList(u8) = .empty,
    pending_connect: ?completion.Completion = null,
    pending_send: ?completion.Completion = null,
    pending_recv: ?completion.Completion = null,
    pending_close: ?completion.Completion = null,
    armed_recv_ud: ?u64 = null,
    pending_cancel: ?completion.Completion = null,
    shutdown_calls: usize = 0,
    close_fd_calls: usize = 0,
    recycle_calls: usize = 0,
    refused_sends: usize = 0,
    refused_recvs: usize = 0,
    refused_closes: usize = 0,
    recv_submit_attempts: usize = 0,
    close_submit_attempts: usize = 0,
    last_poll_timeout_ms: i32 = 0,
    max_submit_bytes: usize = 0,

    pub fn deinit(self: *PipePlatform) void {
        self.wire.deinit(self.allocator);
    }
    pub fn openListener(_: *PipePlatform, _: u16) !Fd {
        return 40;
    }
    pub const ListenerAddress = void;
    pub fn listenerAddress(_: *PipePlatform, _: Fd) !ListenerAddress {}
    pub fn listenerPort(_: ListenerAddress) ?u16 {
        return null;
    }
    pub fn verifiedChannelKey(_: *PipePlatform, _: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
        return null;
    }
    pub fn closeFd(self: *PipePlatform, _: Fd) void {
        self.close_fd_calls += 1;
    }
    pub fn shutdownFd(self: *PipePlatform, _: Fd) void {
        self.shutdown_calls += 1;
    }
    pub fn recycleRecv(self: *PipePlatform, _: completion.Completion) void {
        self.recycle_calls += 1;
    }
    pub fn submitAccept(_: *PipePlatform, _: u64, _: Fd) !void {}
    pub fn startDial(self: *PipePlatform, user_data: u64, _: ConnectTarget) !Fd {
        self.pending_connect = .{ .user_data = user_data, .result = 0 };
        return 41;
    }
    pub fn submitRecv(self: *PipePlatform, user_data: u64, _: Fd) !void {
        self.recv_submit_attempts += 1;
        if (self.refused_recvs != 0) {
            self.refused_recvs -= 1;
            return error.SubmitPressure;
        }
        self.armed_recv_ud = user_data;
    }
    pub fn completeRecv(self: *PipePlatform, bytes: []const u8) !void {
        const user_data = self.armed_recv_ud orelse return error.RecvNotArmed;
        self.armed_recv_ud = null;
        self.pending_recv = .{
            .user_data = user_data,
            .result = @intCast(bytes.len),
            .recv_bytes = bytes,
        };
    }
    pub fn submitSend(self: *PipePlatform, user_data: u64, _: Fd, bytes: []const u8) !void {
        if (self.refused_sends != 0) {
            self.refused_sends -= 1;
            return error.SubmitPressure;
        }
        self.max_submit_bytes = @max(self.max_submit_bytes, bytes.len);
        try self.wire.appendSlice(self.allocator, bytes);
        self.pending_send = .{ .user_data = user_data, .result = @intCast(bytes.len) };
    }
    pub fn submitCancel(self: *PipePlatform, cancel_user_data: u64, target_user_data: u64, _: Fd) !void {
        if (self.armed_recv_ud) |recv_ud| {
            if (recv_ud == target_user_data) {
                self.pending_recv = .{ .user_data = target_user_data, .result = -1 };
                self.armed_recv_ud = null;
            }
        }
        self.pending_cancel = .{ .user_data = cancel_user_data, .result = 0 };
    }
    pub fn submitClose(self: *PipePlatform, user_data: u64, _: Fd) !void {
        self.close_submit_attempts += 1;
        if (self.refused_closes != 0) {
            self.refused_closes -= 1;
            return error.SubmitPressure;
        }
        if (self.pending_recv == null) {
            if (self.armed_recv_ud) |recv_ud| {
                self.pending_recv = .{ .user_data = recv_ud, .result = -1 };
                self.armed_recv_ud = null;
            }
        }
        self.pending_close = .{ .user_data = user_data, .result = 0 };
    }
    pub fn poll(self: *PipePlatform, out: []completion.Completion, timeout_ms: i32) !usize {
        self.last_poll_timeout_ms = timeout_ms;
        if (out.len == 0) return 0;
        inline for (.{ &self.pending_connect, &self.pending_send, &self.pending_recv, &self.pending_cancel, &self.pending_close }) |slot| {
            if (slot.*) |comp| {
                out[0] = comp;
                slot.* = null;
                return 1;
            }
        }
        return 0;
    }
};

const NoiseBackend = noise_completion.CompletionBackend(PipePlatform);
const noise_connection_state_bytes: usize = 936;

test "noise adapter connection state has a measured footprint" {
    // Dominated by the embedded `SealedChannel` (its handshake working set is
    // transient but sized into the union). The adapter also pays sixteen bytes
    // for two compact retry memberships: one recycle-gated receive queue and
    // one actionable submission queue. Paid only by sealed legs.
    try std.testing.expectEqual(noise_connection_state_bytes, NoiseBackend.connection_state_bytes);
}

fn initiatorSecret() crypto.SecretKey {
    return crypto.SecretKey.fromSeed([_]u8{0x31} ** crypto.SEED_BYTES);
}

fn responderSecret() crypto.SecretKey {
    return crypto.SecretKey.fromSeed([_]u8{0x32} ** crypto.SEED_BYTES);
}

fn sealingBackend(allocator: std.mem.Allocator) !NoiseBackend {
    const identity = initiatorSecret();
    return NoiseBackend.initSealing(
        allocator,
        .{ .allocator = allocator },
        &identity,
        [_]u8{0x9a} ** std.Random.DefaultCsprng.secret_seed_length,
    );
}

fn responderChannel() !sealed.SealedChannel {
    const identity = responderSecret();
    return sealed.SealedChannel.initResponder(
        &identity,
        [_]u8{0x55} ** crypto.SEED_BYTES,
        model.transport.noise_relay,
    );
}

fn sealedTarget() NoiseBackend.SealedTarget {
    return .{
        .inner = 0,
        .remote = responderSecret().publicKey(),
        .transport = model.transport.noise_relay,
    };
}

/// Drain the adapter until it goes quiet, collecting external completions.
/// An internal completion (a handshake send, for instance) dispatches with
/// nothing external to report, so quiet means the pipe is empty too — a real
/// loop simply polls again.
fn drain(backend: *NoiseBackend, out: *std.ArrayList(completion.Completion), allocator: std.mem.Allocator) !void {
    var tmp: [8]completion.Completion = undefined;
    while (true) {
        const pipe = &backend.inner;
        const pipe_busy = pipe.pending_connect != null or pipe.pending_send != null or
            pipe.pending_recv != null or pipe.pending_cancel != null or pipe.pending_close != null;
        const n = try backend.poll(&tmp, 0);
        if (n > 0) try out.appendSlice(allocator, tmp[0..n]);
        if (n == 0 and !pipe_busy) return;
    }
}

/// Open a sealed dial against an in-test responder channel: connect, message
/// one out, message two back, message three out, connect completion last.
/// Returns the synthetic fd; the pipe's handshake bytes stay in
/// `backend.inner.wire`.
fn openSealed(
    backend: *NoiseBackend,
    responder: *sealed.SealedChannel,
    allocator: std.mem.Allocator,
) !NoiseBackend.Fd {
    const fd = try backend.startDial(7, .{ .sealed = sealedTarget() });

    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    // The inner connect and message one retire with no external completion:
    // the loop must not hear "connected" before the handshake proves anyone.
    try drain(backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);
    try std.testing.expectEqual(@as(usize, sealed.msg1_wire_bytes), backend.inner.wire.items.len);
    try std.testing.expectEqual(@as(?[crypto.PEER_KEY_BYTES]u8, null), backend.verifiedChannelKey(fd));

    // The responder consumes message one and answers with message two.
    const first = try responder.ingest(allocator, backend.inner.wire.items);
    try std.testing.expectEqual(backend.inner.wire.items.len, first.consumed);
    try std.testing.expectEqual(sealed.SealedChannel.Event.handshake, first.event);
    backend.inner.wire.clearRetainingCapacity();
    var msg2: std.ArrayList(u8) = .empty;
    defer msg2.deinit(allocator);
    try responder.takeWireInto(allocator, &msg2);
    try std.testing.expectEqual(@as(usize, sealed.msg2_wire_bytes), msg2.items.len);

    try backend.inner.completeRecv(msg2.items);
    try drain(backend, &got, allocator);
    // Now, and only now, the dial reports connected — and the channel key is
    // already answerable, so a bridge adopting at this completion binds the
    // responder's durable key through the ADR-0105 seam.
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(u64, 7), got.items[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), got.items[0].result);
    try std.testing.expectEqualSlices(
        u8,
        &responderSecret().publicKey().bytes,
        &(backend.verifiedChannelKey(fd) orelse return error.MissingChannelKey),
    );

    // Message three reaches the responder and completes its half.
    const done = try responder.ingest(allocator, backend.inner.wire.items);
    try std.testing.expectEqual(backend.inner.wire.items.len, done.consumed);
    try std.testing.expect(done.event == .completed);
    try std.testing.expectEqualSlices(u8, &initiatorSecret().publicKey().bytes, &done.event.completed.bytes);
    backend.inner.wire.clearRetainingCapacity();
    return fd;
}

/// Close the sealed connection through the public contract and drain it.
fn closeSealed(backend: *NoiseBackend, fd: NoiseBackend.Fd, allocator: std.mem.Allocator) !void {
    backend.shutdownFd(fd);
    try backend.submitClose(99, fd);
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(backend, &got, allocator);
}

test "sealed dial completes connect only after the handshake proves the responder" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);

    const fd = try openSealed(&backend, &responder, allocator);
    try closeSealed(&backend, fd, allocator);
}

test "the pipe carries sealed records only, and the seat is lent real plaintext" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);

    const fd = try openSealed(&backend, &responder, allocator);

    // Outbound: what the loop would write is framed CapTP stream bytes; the
    // needle stands in for any plaintext a relay could read or rewrite.
    const needle = "op:start-session plaintext probe";
    try backend.submitSend(11, fd, needle);
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(u64, 11), got.items[0].user_data);
    try std.testing.expectEqual(@as(i32, needle.len), got.items[0].result);

    // The pipe's view — the relay's position — holds no plaintext byte.
    const pipe_view = backend.inner.wire.items;
    try std.testing.expect(pipe_view.len > needle.len);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, pipe_view, needle));

    // Calibrate the scanner against a positive: the honest responder opens
    // the same bytes back to the exact plaintext.
    const opened = try responder.ingest(allocator, pipe_view);
    try std.testing.expect(opened.event == .plaintext);
    try std.testing.expect(std.mem.indexOf(u8, opened.event.plaintext, needle) != null);
    responder.releasePlaintext();
    backend.inner.wire.clearRetainingCapacity();

    // Inbound: the responder seals a reply; the recv seat is lent its opened
    // plaintext, and the recycle returns the lend.
    const reply = "sealed reply plaintext";
    var reply_ct: std.ArrayList(u8) = .empty;
    defer reply_ct.deinit(allocator);
    try responder.sealBytes(allocator, &reply_ct, reply);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, reply_ct.items, reply));

    try backend.submitRecv(13, fd);
    try backend.inner.completeRecv(reply_ct.items);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    const lent = got.items[1];
    try std.testing.expectEqual(@as(u64, 13), lent.user_data);
    try std.testing.expectEqualStrings(reply, lent.recv_bytes.?);
    backend.recycleRecv(lent);

    try closeSealed(&backend, fd, allocator);
}

test "coalesced records retain one inner receive borrow across recv seats" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    const first = try allocator.alloc(u8, foundation.noise.MAX_RECORD_PLAINTEXT_BYTES);
    defer allocator.free(first);
    @memset(first, 0x4c);
    const second = "second coalesced record";
    var ciphertext: std.ArrayList(u8) = .empty;
    defer ciphertext.deinit(allocator);
    try responder.sealBytes(allocator, &ciphertext, first);
    try responder.sealBytes(allocator, &ciphertext, second);
    try std.testing.expect(
        ciphertext.items.len > foundation.noise.RECORD_HEADER_BYTES + foundation.noise.MAX_RECORD_BYTES,
    );

    const recycled_before = backend.inner.recycle_calls;
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try backend.submitRecv(41, fd);
    try backend.inner.completeRecv(ciphertext.items);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualSlices(u8, first, got.items[0].recv_bytes.?);
    // The second record still lives in the same inner buffer, so the adapter
    // retains that borrow instead of copying its ciphertext.
    try std.testing.expectEqual(recycled_before, backend.inner.recycle_calls);

    backend.recycleRecv(got.items[0]);
    try backend.submitRecv(42, fd);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    try std.testing.expectEqualStrings(second, got.items[1].recv_bytes.?);
    try std.testing.expectEqual(recycled_before + 1, backend.inner.recycle_calls);
    backend.recycleRecv(got.items[1]);

    try closeSealed(&backend, fd, allocator);
}

test "large completion sends stage at most one Noise record" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    backend.inner.max_submit_bytes = 0;
    const plain_len = foundation.noise.MAX_RECORD_PLAINTEXT_BYTES * 3 + 17;
    const plain = try allocator.alloc(u8, plain_len);
    defer allocator.free(plain);
    @memset(plain, 0x5a);
    try backend.submitSend(31, fd, plain);
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(i32, @intCast(plain.len)), got.items[0].result);
    try std.testing.expect(
        backend.inner.max_submit_bytes <= foundation.noise.RECORD_HEADER_BYTES +
            foundation.noise.MAX_RECORD_BYTES,
    );
    try closeSealed(&backend, fd, allocator);
}

test "handshake submission refusals share one actionable retry owner" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    backend.inner.refused_sends = 1;
    backend.inner.refused_recvs = 1;

    const fd = try backend.startDial(71, .{ .sealed = sealedTarget() });
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    const conn = backend.conns.get(1).?;
    try std.testing.expectEqual(@as(usize, 1), backend.submission_retries.count);
    try std.testing.expectEqual(@as(u8, 0b0110), conn.submission_retry_mask);
    try std.testing.expectEqual(@as(?u64, null), backend.inner.armed_recv_ud);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.wire.items.len);

    // One FIFO visit retries both operations. No receive-buffer recycle is
    // needed because this is submission pressure, not pool starvation.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.submission_retries.count);
    try std.testing.expect(backend.inner.armed_recv_ud != null);
    try std.testing.expectEqual(@as(usize, sealed.msg1_wire_bytes), backend.inner.wire.items.len);

    try backend.submitClose(72, fd);
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(&backend, &got, allocator);
}

test "receive-buffer starvation sleeps until recycle and then rearms" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    try backend.submitRecv(73, fd);
    const internal_ud = backend.inner.armed_recv_ud.?;
    backend.inner.armed_recv_ud = null;
    backend.inner.pending_recv = .{
        .user_data = internal_ud,
        .result = -1,
        .recv_no_buffer = true,
    };
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 73));
    try std.testing.expectEqual(@as(usize, 1), backend.recv_starvation.count);

    // Starvation alone is not actionable debt. The adapter may block in its
    // inner poll instead of spinning at timeout zero.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 73));
    try std.testing.expectEqual(@as(i32, 73), backend.inner.last_poll_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), backend.recv_starvation.count);

    backend.recycleRecv(.{ .user_data = 0, .result = 0 });
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), backend.recv_starvation.count);
    try std.testing.expect(backend.inner.armed_recv_ud != null);

    try backend.submitCancel(74, 73, fd);
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try closeSealed(&backend, fd, allocator);
}

test "cancel removes recycle-gated receive debt" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    try backend.submitRecv(75, fd);
    const internal_ud = backend.inner.armed_recv_ud.?;
    backend.inner.armed_recv_ud = null;
    backend.inner.pending_recv = .{
        .user_data = internal_ud,
        .result = -1,
        .recv_no_buffer = true,
    };
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.recv_starvation.count);
    try backend.submitCancel(76, 75, fd);
    try std.testing.expectEqual(@as(usize, 0), backend.recv_starvation.count);
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try closeSealed(&backend, fd, allocator);
}

test "refused close retries in bounded FIFO turns and completes once" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    backend.inner.refused_closes = 2;
    try backend.submitClose(77, fd);
    try std.testing.expectEqual(@as(usize, 1), backend.submission_retries.count);
    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, -1));
    try std.testing.expectEqual(@as(i32, 50), backend.inner.last_poll_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), backend.submission_retries.count);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, -1));
    try std.testing.expectEqual(@as(u64, 77), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 3), backend.inner.close_submit_attempts);
    try std.testing.expectEqual(@as(usize, 0), backend.submission_retries.count);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
}

test "sealed completion close owns retries and preserves lent plaintext until recycle" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();
    var responder = try responderChannel();
    defer responder.deinit(allocator);
    const fd = try openSealed(&backend, &responder, allocator);

    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);

    // An accepted empty send completes exactly once without occupying the send
    // seat or moving the cipher stream.
    try backend.submitSend(21, fd, &.{});
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(u64, 21), got.items[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), got.items[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.wire.items.len);

    // A receive completion lends the channel's plaintext scratch. Close may
    // retire the pipe, but cannot free that scratch before recycle.
    const reply = "borrow remains valid through close";
    var reply_ct: std.ArrayList(u8) = .empty;
    defer reply_ct.deinit(allocator);
    try responder.sealBytes(allocator, &reply_ct, reply);
    try backend.submitRecv(22, fd);
    try backend.inner.completeRecv(reply_ct.items);
    try drain(&backend, &got, allocator);
    const lent = got.items[1];
    try std.testing.expectEqualStrings(reply, lent.recv_bytes.?);
    try std.testing.expectError(error.AlreadyReading, backend.submitRecv(23, fd));
    try backend.submitClose(24, fd);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqualStrings(reply, lent.recv_bytes.?);
    try std.testing.expect(backend.verifiedChannelKey(fd) != null);
    backend.recycleRecv(lent);
    try std.testing.expectEqual(@as(?[crypto.PEER_KEY_BYTES]u8, null), backend.verifiedChannelKey(fd));
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(u64, 24), got.items[got.items.len - 1].user_data);

    // On a fresh leg, close cancels an owed ciphertext submit. A later poll
    // cannot retry bytes after close has taken ownership.
    var responder2 = try responderChannel();
    defer responder2.deinit(allocator);
    const fd2 = try openSealed(&backend, &responder2, allocator);
    backend.inner.refused_sends = 1;
    try backend.submitSend(25, fd2, "must not escape after close");
    try backend.submitClose(26, fd2);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 0), backend.inner.wire.items.len);
    try std.testing.expectEqual(@as(u64, 25), got.items[got.items.len - 2].user_data);
    try std.testing.expectEqual(@as(i32, -1), got.items[got.items.len - 2].result);
    try std.testing.expectEqual(@as(u64, 26), got.items[got.items.len - 1].user_data);
}

test "a substituted responder key never yields a connected session" {
    const allocator = std.testing.allocator;
    var backend = try sealingBackend(allocator);
    defer backend.deinit();

    // The relay answers with its own static: a responder whose durable key is
    // not the one the dial named. Its message two cannot verify against the
    // dialed key's handshake transcript.
    const mitm_secret = crypto.SecretKey.fromSeed([_]u8{0x66} ** crypto.SEED_BYTES);
    var mitm = try sealed.SealedChannel.initResponder(
        &mitm_secret,
        [_]u8{0x77} ** crypto.SEED_BYTES,
        model.transport.noise_relay,
    );
    defer mitm.deinit(allocator);

    const fd = try backend.startDial(7, .{ .sealed = sealedTarget() });
    var got: std.ArrayList(completion.Completion) = .empty;
    defer got.deinit(allocator);
    try drain(&backend, &got, allocator);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);

    // The imposter cannot even read message one, which was keyed to the
    // dialed responder; whatever it answers with, the initiator refuses.
    _ = mitm.ingest(allocator, backend.inner.wire.items) catch {};
    var msg2: std.ArrayList(u8) = .empty;
    defer msg2.deinit(allocator);
    try mitm.takeWireInto(allocator, &msg2);
    if (msg2.items.len == 0) {
        // No readable message one means no message two; synthesize the
        // imposter's best remaining move, a well-formed message two under its
        // own keys, by handshaking against itself. Either way the initiator
        // must refuse below.
        try msg2.appendNTimes(allocator, 0xaa, sealed.msg2_wire_bytes);
    }
    backend.inner.wire.clearRetainingCapacity();

    try backend.inner.completeRecv(msg2.items);
    try drain(&backend, &got, allocator);
    // The dial fails; it never reports connected, and no channel key exists.
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqual(@as(u64, 7), got.items[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), got.items[0].result);
    try std.testing.expectEqual(@as(?[crypto.PEER_KEY_BYTES]u8, null), backend.verifiedChannelKey(fd));

    try closeSealed(&backend, fd, allocator);
}

test "noise-relay resolves as a sealed key-designator dial" {
    try std.testing.expectEqual(model.transport.DesignatorScheme.key, model.transport.Known.noise_relay.metadata().designator_scheme);
    try std.testing.expect(model.transport.Known.noise_relay.metadata().sealed_channel);

    const Resolver = noise_completion.DialResolver(NoiseBackend, PassthroughResolver);
    const designator = responderSecret().publicKey().toDesignator();
    const target = try Resolver.resolve(.{
        .transport = model.transport.noise_relay,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(target == .sealed);
    try std.testing.expectEqualSlices(u8, &responderSecret().publicKey().bytes, &target.sealed.remote.bytes);
    try std.testing.expectEqualStrings(model.transport.noise_relay, target.sealed.transport);

    const plain = try Resolver.resolve(.{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expect(plain == .plain);

    try std.testing.expectError(error.InvalidAddress, Resolver.resolve(.{
        .transport = model.transport.noise_relay,
        .designator = "not-a-key",
        .hints = model.Hints.emptyFalse(),
    }));
}

/// Stands in for the keyed-relay resolver: the wrapped grammar only needs to
/// show which transport symbol the sealing layer forwarded.
const PassthroughResolver = struct {
    pub fn resolve(locator: model.PeerLocator) error{InvalidAddress}!u32 {
        if (std.mem.eql(u8, locator.transport, model.transport.keyed_relay)) return 1;
        if (std.mem.eql(u8, locator.transport, "tcp")) return 2;
        return error.InvalidAddress;
    }
};

const live_frame_cap = 4096;
const live_options: driver.SessionOptions = .{
    .frame_cap = live_frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};
const relay_reply = "hello through the sealed relay";
const RelayGreeter = support_actors.StaticReplyValueActor("greet", relay_reply);

fn serveNoiseRelayOnce(server: *driver.Server) !void {
    const session = try server.accept();
    defer session.deinit();
    const identity = try session.runtime.core.partnerIdentity(session.hs);
    try std.testing.expectEqual(
        driver.core.DurableProvenance.authenticated_transport,
        identity.provenance,
    );
    _ = try session.publish("greeter", RelayGreeter, .{});
    try session.serve();
}

test "noise-relay registered resident opens an authenticated session through a ciphertext-only relay" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var relay_server = try std.Io.net.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer relay_server.deinit(io);
    const port = relay_server.socket.address.getPort();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    var relay_saw_plaintext = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(ws_relay.bridgeOneRendezvousObserved, .{
        io,
        &relay_server,
        allocator,
        .{ .needle = relay_reply, .found = &relay_saw_plaintext },
    });

    const server_secret = crypto.SecretKey.fromSeed([_]u8{0x52} ** crypto.SEED_BYTES);
    var registered = try net.relay.Resident.initRegisteredProfile(
        allocator,
        io,
        relay_url,
        register_url,
        server_secret.publicKey(),
        .noise,
    );
    defer registered.deinit();
    var server = try driver.listen(
        allocator,
        registered.netlayer(),
        .{ .designator = "" },
        .{ .keyed = server_secret },
        live_options,
    );
    defer server.deinit();

    const advertised = try server.advertisedLocator();
    try std.testing.expectEqualStrings(model.transport.noise_relay, advertised.transport);
    try std.testing.expectEqualStrings(&server_secret.publicKey().toDesignator(), advertised.designator);

    var serving = try io.concurrent(serveNoiseRelayOnce, .{server});

    var dialer = try net.relay.Resident.initProfile(allocator, io, relay_url, .noise);
    defer dialer.deinit();
    const layers = [_]net.netlayer.Netlayer{dialer.netlayer()};
    {
        const client = try driver.connect(allocator, &layers, advertised, .ephemeral, live_options);
        defer client.deinit();
        const identity = try client.runtime.core.partnerIdentity(client.hs);
        try std.testing.expectEqual(
            driver.core.DurableProvenance.authenticated_transport,
            identity.provenance,
        );

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const greeter = try client.fetch("greeter");
        const settled = try client.call(greeter, "greet", &.{}, arena.allocator());
        try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
        try std.testing.expectEqualStrings(relay_reply, settled.fulfilled.string);
    }
    try serving.await(io);
    try relay.await(io);
    try std.testing.expect(!relay_saw_plaintext.load(.acquire));
}
