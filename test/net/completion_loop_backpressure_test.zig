//! What the completion loop does when a backend arm refuses or a partner
//! stops reading, proven deterministically on scripted backends: accept and
//! keepalive failures surface typed and close cleanly, a per-connection drive
//! failure closes that connection and not the loop, and outbound past the
//! high-water mark parks reads until the partner drains, the exact
//! park/resume order ADR-0042 promises, read from the fake's journal.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const Loop = glowcap.net.TcpLoop;
const completion = glowcap.net.completion;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");
const no_dial = @import("../support/no_dial_locator.zig");

const frame_cap = fixtures.frame_cap;
const fixtures = @import("../support/completion_loop_fixtures.zig");
const startSession = fixtures.startSession;
const makeServerPeer = fixtures.makeServerPeer;
const drainOutboundBytes = fixtures.drainOutboundBytes;
const drainOutboundStreamBytes = fixtures.drainOutboundStreamBytes;
const FakeBackend = fixtures.FakeBackend;
const FakeEvent = fixtures.FakeEvent;

test "completion loop supported surface and footprint stay exact" {
    const LoopType = completion.Loop(FakeBackend, no_dial.Unsupported);

    const expected_names = .{
        "initWithBackend",
        "init",
        "initWithBackendOptions",
        "listenerAddress",
        "port",
        "deinit",
        "run",
        "runUntil",
        "closeAndDrain",
        "dialLocator",
        "dialLocatorReserved",
        "armOutbound",
        "verifiedChannelKey",
        "closeSlot",
        "armWake",
    };
    try std.testing.expectEqual(
        expected_names.len,
        @typeInfo(LoopType).@"struct".decl_names.len,
    );
    inline for (expected_names) |name| try std.testing.expect(@hasDecl(LoopType, name));

    comptime {
        expectSignature(@TypeOf(LoopType.initWithBackend), &.{
            std.mem.Allocator,
            FakeBackend,
            completion.MakePeer,
            ?*anyopaque,
            completion.Options,
        }, LoopType);
        expectSignature(@TypeOf(LoopType.init), &.{
            std.mem.Allocator,
            completion.MakePeer,
            ?*anyopaque,
            completion.Options,
        }, LoopType);
        expectSignature(@TypeOf(LoopType.initWithBackendOptions), &.{
            std.mem.Allocator,
            completion.BackendOptions,
            completion.MakePeer,
            ?*anyopaque,
            completion.Options,
        }, LoopType);
        expectSignature(@TypeOf(LoopType.listenerAddress), &.{*const LoopType}, ?FakeBackend.ListenerAddress);
        expectSignature(@TypeOf(LoopType.port), &.{*const LoopType}, ?u16);
        expectSignature(@TypeOf(LoopType.deinit), &.{*LoopType}, void);
        expectSignature(@TypeOf(LoopType.run), &.{ *LoopType, completion.Stop }, void);
        expectSignature(@TypeOf(LoopType.runUntil), &.{ *LoopType, *const std.atomic.Value(bool), i32 }, void);
        expectSignature(@TypeOf(LoopType.closeAndDrain), &.{*LoopType}, void);
        expectSignature(@TypeOf(LoopType.dialLocator), &.{ *LoopType, model.PeerLocator }, usize);
        expectSignature(@TypeOf(LoopType.dialLocatorReserved), &.{ *LoopType, model.PeerLocator }, usize);
        expectSignature(@TypeOf(LoopType.armOutbound), &.{ *LoopType, usize }, void);
        expectSignature(@TypeOf(LoopType.verifiedChannelKey), &.{ *LoopType, usize }, ?[32]u8);
        expectSignature(@TypeOf(LoopType.closeSlot), &.{ *LoopType, usize }, void);
        expectSignature(@TypeOf(LoopType.armWake), &.{
            *LoopType,
            FakeBackend.Fd,
            ?*anyopaque,
            *const fn (?*anyopaque) void,
        }, void);
    }
    // Stated under runtime safety, where the loop's own hash map carries
    // std's one-word `pointer_stability` lock.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 880), @sizeOf(LoopType));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(LoopType));
}

fn expectSignature(comptime Function: type, comptime Params: []const type, comptime Payload: type) void {
    const info = @typeInfo(Function).@"fn";
    if (info.param_types.len != Params.len) @compileError("completion Loop method arity drifted");
    inline for (Params, 0..) |expected, index| {
        if (info.param_types[index] != expected) @compileError("completion Loop parameter type drifted");
    }
    const return_type = info.return_type.?;
    const payload = switch (@typeInfo(return_type)) {
        .error_union => |error_union| error_union.payload,
        else => return_type,
    };
    if (payload != Payload) @compileError("completion Loop return shape drifted");
}

test "completion loop: accept completion preserves its typed failure" {
    FakeBackend.chunks = &.{};
    FakeBackend.first_accept_failure = error.TestAcceptFailure;
    defer FakeBackend.first_accept_failure = null;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(
        std.testing.allocator,
        makeServerPeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    try std.testing.expectError(error.TestAcceptFailure, loop.run(.{ .after_closed = 1 }));
    // The accept was re-armed before the failure reached the owner, so a caller
    // that resumes the loop does not lose listener readiness.
    try std.testing.expect(loop.accept_armed);
}

fn failMakePeer(_: ?*anyopaque, _: std.mem.Allocator) !engine.Peer {
    return error.TestPeerCreateFailure;
}

test "completion loop surfaces accepted-peer construction failure" {
    FakeBackend.chunks = &.{};

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(
        std.testing.allocator,
        failMakePeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    try std.testing.expectError(error.TestPeerCreateFailure, loop.run(.{ .after_closed = 1 }));
}

const KeepaliveFailureWatch = struct {
    var report: ?completion.CloseReport = null;

    fn onClose(_: ?*anyopaque, _: usize, _: ?*anyopaque, close_report: completion.CloseReport) void {
        report = close_report;
    }
};

test "completion loop reports backend keepalive refusal before serving connection" {
    FakeBackend.chunks = &.{};
    KeepaliveFailureWatch.report = null;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(std.testing.allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
        .keepalive = .{ .idle_sec = 30, .interval_sec = 10, .count = 3 },
        .on_close = KeepaliveFailureWatch.onClose,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    const report = KeepaliveFailureWatch.report orelse return error.MissingCloseReport;
    try std.testing.expect(report.opened);
    try std.testing.expectEqual(completion.CloseReason.ordinary, report.reason);
    try std.testing.expectEqualStrings("OperationUnsupported", report.failure.?.error_name);
}

test "completion loop reports a send submission failure through close" {
    FakeBackend.chunks = &.{};
    FakeBackend.first_send_submission_failure = error.TestSendSubmissionFailure;
    defer FakeBackend.first_send_submission_failure = null;
    KeepaliveFailureWatch.report = null;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(std.testing.allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
        .on_close = KeepaliveFailureWatch.onClose,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    const report = KeepaliveFailureWatch.report orelse return error.MissingCloseReport;
    try std.testing.expectEqualStrings("TestSendSubmissionFailure", report.failure.?.error_name);
}

test "completion loop: listener close retries instead of abandoning an armed accept" {
    const allocator = std.testing.allocator;
    FakeBackend.chunks = &.{};
    FakeBackend.refuse_listener_close_once = true;
    defer FakeBackend.refuse_listener_close_once = false;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
    });
    defer loop.deinit();

    // `runUntil` arms the accept even when the stop flag is already set. The
    // first close submit then fails under injected backend pressure. The drain
    // reports that exact refusal while retaining the listener, and a retry
    // completes without falling back to an unsafe descriptor-only close.
    var done = std.atomic.Value(bool).init(true);
    try loop.runUntil(&done, 0);
    try std.testing.expectError(error.OutOfMemory, loop.closeAndDrain());
    try loop.closeAndDrain();

    try std.testing.expectEqual(@as(usize, 2), loop.backend.listener_close_attempts);
    try std.testing.expectEqual(@as(usize, 0), loop.backend.listener_close_fallbacks);
}

test "completion loop: listener shutdown drains a canceled accept after close completion" {
    const allocator = std.testing.allocator;
    FakeBackend.chunks = &.{};
    FakeBackend.defer_listener_accept_cancel = true;
    defer FakeBackend.defer_listener_accept_cancel = false;

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 1,
        .listen = 0,
    });
    defer loop.deinit();

    // The scripted connection closes on its first recv, after onAccept has
    // armed a second accept. Listener close completes first; the backend does
    // not surface the canceled accept until the following poll.
    try loop.run(.{ .after_closed = 1 });
    try std.testing.expect(loop.accept_armed);
    try loop.closeAndDrain();

    try std.testing.expect(!loop.accept_armed);
    try std.testing.expect(loop.backend.deferred_accept_cancel_ud == null);
}

/// Encode `peer`'s queued sends and append their bare frame bytes to `sink`.
/// This is the intrinsic message-framed path used to prepare a peer directly.
const OneBadPartnerBackend = struct {
    pub const Fd = i32;

    pub fn applyKeepalive(_: *OneBadPartnerBackend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *OneBadPartnerBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    const refused_fd: Fd = 100;
    const ok_fd: Fd = 200;

    /// The healthy connection's inbound wire script, set before `Loop.init`.
    var chunks: []const []const u8 = &.{};

    accepts: usize = 0,
    chunk_idx: usize = 0,
    sends_ok: usize = 0,
    sends_refused: usize = 0,
    pool_free: usize = 0,
    handed: usize = 0,
    recycles: usize = 0,
    ready: [16]completion.Completion = undefined,
    ready_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !OneBadPartnerBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffer_bytes;
        return .{ .pool_free = read_buffers };
    }

    pub fn deinit(self: *OneBadPartnerBackend) void {
        self.* = .{ .pool_free = 0 };
    }

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
    }

    /// A scripted listener binds at `openListener`; nothing pends here; a
    /// wrapped adapter's pending setup reports through the adapter itself.
    pub fn listenerPending(_: *@This(), _: Fd) bool {
        return false;
    }

    pub fn openListener(self: *@This(), port: u16) !Fd {
        _ = self;
        _ = port;
        return 1;
    }

    pub const ListenerAddress = u16;
    pub fn listenerAddress(_: *@This(), _: Fd) !ListenerAddress {
        return 1;
    }
    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address;
    }

    pub fn closeFd(self: *@This(), fd: Fd) void {
        _ = self;
        _ = fd;
    }

    pub const ConnectTarget = void;

    pub fn startDial(self: *@This(), user_data: u64, target: ConnectTarget) !Fd {
        _ = self;
        _ = user_data;
        _ = target;
        return error.UnsupportedTransport;
    }

    pub fn shutdownFd(self: *@This(), fd: Fd) void {
        _ = self;
        _ = fd;
    }

    fn push(self: *OneBadPartnerBackend, c: completion.Completion) void {
        self.ready[self.ready_len] = c;
        self.ready_len += 1;
    }

    pub fn submitAccept(self: *OneBadPartnerBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        // Two scripted connections; the loop's later re-arms pend forever.
        if (self.accepts >= 2) return;
        self.accepts += 1;
        const fd: Fd = if (self.accepts == 1) refused_fd else ok_fd;
        self.push(.{ .user_data = user_data, .result = fd });
    }

    pub fn submitRecv(self: *OneBadPartnerBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        if (self.chunk_idx < chunks.len) {
            if (self.pool_free == 0) {
                self.push(.{ .user_data = user_data, .result = -1, .recv_no_buffer = true });
                return;
            }
            self.pool_free -= 1;
            self.handed += 1;
            const chunk = chunks[self.chunk_idx];
            self.chunk_idx += 1;
            self.push(.{ .user_data = user_data, .result = @intCast(chunk.len), .borrowed = .recv(chunk, 0) });
        } else {
            self.push(.{ .user_data = user_data, .result = 0 }); // clean EOF
        }
    }

    pub fn verifiedChannelKey(self: *OneBadPartnerBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleBorrowed(self: *OneBadPartnerBackend, comp: completion.Completion) void {
        _ = comp;
        self.recycles += 1;
        self.pool_free += 1;
    }

    pub fn submitSend(self: *OneBadPartnerBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        if (fd == refused_fd) {
            self.sends_refused += 1;
            return error.SendRefused;
        }
        self.sends_ok += 1;
        self.push(.{ .user_data = user_data, .result = @intCast(bytes.len) });
    }

    pub fn submitCancel(self: *OneBadPartnerBackend, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
        _ = .{ target_user_data, fd };
        self.push(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *OneBadPartnerBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        self.push(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *OneBadPartnerBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        // The loop stalled with no completion to deliver: a loop bug, fail loud.
        if (self.ready_len == 0) return error.FakeBackendStalled;
        const n = @min(out.len, self.ready_len);
        @memcpy(out[0..n], self.ready[0..n]);
        std.mem.copyForwards(completion.Completion, self.ready[0 .. self.ready_len - n], self.ready[n..self.ready_len]);
        self.ready_len -= n;
        return n;
    }
};

test "completion loop: a per-connection drive failure closes that connection, not the loop" {
    const allocator = std.testing.allocator;

    // Precompute the healthy partner's script: its start-session, then a fetch
    // of the shared bootstrap cap (prepared against the same start-session the
    // loop's server peer sends, so the fetch is admissible).
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    _ = try client.recvStreamPrefix(server_ss.items);
    fetch_pump.drainEvents(&client);

    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundStreamBytes(&client, allocator, &fetch_bytes);

    OneBadPartnerBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    defer OneBadPartnerBackend.chunks = &.{};

    var loop = try completion.Loop(OneBadPartnerBackend, no_dial.Unsupported).init(allocator, makeServerPeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    // The first connection's opening start-session send fails at submit; the
    // loop must close only that connection and fully serve the second one.
    // Before the per-connection isolation fix, the first drive failure
    // propagated out of `run` and tore down every connection.
    try loop.run(.{ .after_closed = 2 });

    try std.testing.expectEqual(@as(usize, 2), loop.closed_count);
    // The bad partner's send was refused at least once.
    try std.testing.expect(loop.backend.sends_refused >= 1);
    // The healthy partner consumed its whole script (handshake and fetch) and
    // received replies: it was served to completion after the failure.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.chunk_idx);
    try std.testing.expect(loop.backend.sends_ok >= 2);
    // Every successful recv's pool buffer was recycled exactly once.
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

test "completion loop: outbound past the high-water mark parks reads until the partner drains" {
    const allocator = std.testing.allocator;

    // Precompute the wire script: the client's start-session, then a fetch of
    // the shared bootstrap cap, whose auto-resolve reply outgrows the mark.
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;

    var client_ss: std.ArrayList(u8) = .empty;
    defer client_ss.deinit(allocator);
    try client.sendCopying(startSession("client"));
    try drainOutboundStreamBytes(&client, allocator, &client_ss);

    // Open the client's session against the same start-session the loop's
    // server peer sends, so the fetch it prepares is admissible.
    var server_twin = try makeServerPeer(null, allocator);
    defer server_twin.deinit();
    var server_ss: std.ArrayList(u8) = .empty;
    defer server_ss.deinit(allocator);
    try drainOutboundBytes(&server_twin, allocator, &server_ss);
    _ = try client.recvStreamPrefix(server_ss.items);
    fetch_pump.drainEvents(&client);

    var fetch_bytes: std.ArrayList(u8) = .empty;
    defer fetch_bytes.deinit(allocator);
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, "thermostat");
    try client.send(prepared.message);
    try drainOutboundStreamBytes(&client, allocator, &fetch_bytes);

    // The mark sits far below one frame, so both the handshake reply and the
    // fetch reply must park the read, observable from the very first write.
    const high_water: usize = 16;
    try std.testing.expect(server_ss.items.len > high_water);

    var park_hits: usize = 0;
    const ParkCount = struct {
        fn onPark(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, reason: completion.ParkReason) void {
            _ = reason;
            _ = slot;
            _ = conn_ctx;
            const n: *usize = @ptrCast(@alignCast(ctx.?));
            n.* += 1;
        }
    };

    FakeBackend.chunks = &.{ client_ss.items, fetch_bytes.items };
    defer FakeBackend.chunks = &.{};

    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).init(allocator, makeServerPeer, &park_hits, .{
        .max_conns = 4,
        .listen = 0,
        .outbound_high_water_bytes = high_water,
        .on_park = ParkCount.onPark,
    });
    defer loop.deinit();

    try loop.run(.{ .after_closed = 1 });

    try std.testing.expect(park_hits >= 1);
    try std.testing.expectEqualSlices(FakeEvent, &[_]FakeEvent{
        .send_submitted, // accept: the server's start-session crosses the mark → read parks
        .send_released, // the partner drains; only now…
        .recv_armed, // …does the first read arm (delivers the client start-session)
        .recv_armed, // nothing pending → the next read arms (delivers the fetch)
        .send_submitted, // the fetch's auto-resolve crosses the mark → read parks again
        .send_released, // the partner drains again
        .recv_armed, // the read resumes; the script is spent → clean EOF → close
    }, loop.backend.journal[0..loop.backend.journal_len]);
    // Every successful recv's pool buffer was recycled exactly once.
    try std.testing.expectEqual(@as(usize, 2), loop.backend.handed);
    try std.testing.expectEqual(loop.backend.handed, loop.backend.recycles);
}

test "completion loop: outbound high-water has an independent default and explicit override" {
    const defaults: completion.Options = .{};
    try std.testing.expectEqual(completion.default_outbound_high_water_bytes, defaults.outbound_high_water_bytes);

    const overridden: completion.Options = .{ .outbound_high_water_bytes = 333 };
    try std.testing.expectEqual(@as(usize, 333), overridden.outbound_high_water_bytes);
}

test "completion loop: exact read-buffer bytes reach the constructed backend" {
    var loop = try completion.Loop(FakeBackend, no_dial.Unsupported).initWithBackendOptions(
        std.testing.allocator,
        .{ .read_buffers = 1, .read_buffer_bytes = 12_345 },
        makeServerPeer,
        null,
        .{ .max_conns = 1 },
    );
    defer loop.deinit();
    try std.testing.expectEqual(@as(u32, 12_345), loop.backend.read_buffer_bytes);
}

test "completion loop: an empty shared read buffer is refused" {
    try std.testing.expectError(
        error.InvalidReadBufferBytes,
        completion.Loop(FakeBackend, no_dial.Unsupported).initWithBackendOptions(
            std.testing.allocator,
            .{ .read_buffer_bytes = 0 },
            makeServerPeer,
            null,
            .{},
        ),
    );
}

test "completion buffer pool refuses zero-sized buffers at its ownership boundary" {
    try std.testing.expectError(
        error.InvalidBufferBytes,
        completion.BufferPool.init(std.testing.allocator, 1, 0),
    );
}
