//! The shared WebRTC interop signaling core (ADR-0089): the one signaling-inbox
//! actor and the one channel-bring-up client that `webrtc-signaling-captp` and
//! the WebRTC CapTP signaling drivers share. It lives here so those drivers
//! are thin callers of one spine rather than two byte-identical copies of it.
//!
//! The inbox holds an exporter's sidecar peer and answers three verbs so a
//! recipient can bring up the DataChannel through capability calls before the
//! keyed handshake: `offer(sdp)` returns the exporter's SDP answer, `candidate`
//! applies one trickled ICE candidate, and `poll` returns the exporter's next
//! locally gathered candidate (or ""). Channel establishment is driven through
//! the resident readiness fd; no native driver uses the old parked open wait.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const crypto = foundation.crypto;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

/// The CapTP signaling session must carry one bounded WebRTC SDP or ICE string.
pub const signaling_frame_bytes: usize = webrtc.max_signal_bytes;

pub fn hostFromSeed(allocator: std.mem.Allocator, durable_seed: [crypto.SEED_BYTES]u8, frame_cap: usize) !Host {
    var root: [crypto.SEED_BYTES]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("pancake webrtc interop session root v1", .{});
    hasher.update(&durable_seed);
    hasher.final(&root);
    return Host.init(allocator, durable_seed, root, Host.Options.withFrameCap(frame_cap));
}

pub fn locator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = webrtc.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
}

pub fn bindAuthorizedChannel(host: *Host, session: *HostSession, peer: *const webrtc.Peer) !void {
    if (peer.authorized_remote) |key| {
        const designator = key.toDesignator();
        try host.bindVerifiedChannelKey(session, designator[0..]);
    }
}

pub fn pollOpen(resident: *webrtc.Resident, peer: *webrtc.Peer, timeout_ms: i32) !bool {
    var events: [16]webrtc.ReadyEvent = undefined;
    const count = try resident.pollReady(&events, timeout_ms);
    for (events[0..count]) |event| {
        if (event.subject != @backingInt(peer.id())) return error.UnexpectedReadySubject;
    }
    peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => false,
        error.Closed => error.ChannelClosed,
        error.Failed => error.ChannelFailed,
    };
    return true;
}

pub fn waitOpen(resident: *webrtc.Resident, peer: *webrtc.Peer, timeout_ms: usize) !void {
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        if (try pollOpen(resident, peer, 50)) return;
    }
    return error.ChannelBringUpTimeout;
}

pub const CapturedRef = struct {
    const State = enum { pending, fulfilled, broken, wrong_type };

    ref: ?model.Reference = null,
    state: State = .pending,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedRef = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference) {
                    self.ref = value.reference;
                    self.state = .fulfilled;
                } else {
                    self.state = .wrong_type;
                }
            },
            .broken, .give => self.state = .broken,
        }
    }

    pub fn require(self: CapturedRef) !model.Reference {
        return switch (self.state) {
            .pending => error.VowDidNotSettle,
            .broken => error.VowBroke,
            .wrong_type => error.WrongResolution,
            .fulfilled => self.ref orelse error.WrongResolution,
        };
    }
};

pub const CapturedString = struct {
    const State = enum { pending, fulfilled, broken, wrong_type, too_large };

    buf: [128]u8 = undefined,
    len: usize = 0,
    state: State = .pending,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedString = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .string) {
                    if (value.string.len > self.buf.len) {
                        self.state = .too_large;
                        return;
                    }
                    self.len = value.string.len;
                    @memcpy(self.buf[0..self.len], value.string[0..self.len]);
                    self.state = .fulfilled;
                } else {
                    self.state = .wrong_type;
                }
            },
            .broken, .give => self.state = .broken,
        }
    }

    pub fn text(self: *const CapturedString) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn require(self: *const CapturedString) ![]const u8 {
        return switch (self.state) {
            .pending => error.VowDidNotSettle,
            .broken => error.VowBroke,
            .wrong_type => error.WrongResolution,
            .too_large => error.ResponseTooLarge,
            .fulfilled => self.text(),
        };
    }
};

pub const PacketPump = struct {
    const SendStep = enum { sent, would_block, empty };

    pending: ?foundation.Frame = null,
    read_buf: []u8,

    pub fn deinit(self: *PacketPump) void {
        if (self.pending) |*frame| frame.deinit();
        self.pending = null;
    }

    pub fn drive(self: *PacketPump, host: *Host, session: *HostSession, peer: *webrtc.Peer) !bool {
        var moved = false;
        while (true) {
            var round_moved = false;
            while (true) switch (try self.sendNext(session, peer)) {
                .sent => round_moved = true,
                .would_block, .empty => break,
            };
            while (true) {
                const n = peer.tryReceivePacket(self.read_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.Closed => return error.ChannelClosed,
                    error.BufferTooSmall => return error.PacketBufferTooSmall,
                    error.Failed => return error.ChannelFailed,
                };
                try host.feedTransportPacket(session, self.read_buf[0..n]);
                round_moved = true;
            }
            if (try drainHostActions(host, session)) round_moved = true;
            if (!round_moved) return moved;
            moved = true;
        }
    }

    fn sendNext(self: *PacketPump, session: *HostSession, peer: *webrtc.Peer) !SendStep {
        if (self.pending == null) {
            const value = (try session.takeTransportOutbound()) orelse return .empty;
            var outbound = value;
            if (outbound.prefix_len != 0) {
                outbound.payload.deinit();
                return error.UnexpectedStreamPrefix;
            }
            self.pending = outbound.payload;
        }
        const frame = &self.pending.?;
        const bytes = frame.bytes();
        const n = peer.trySendPacket(bytes) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            error.BufferTooSmall => {
                frame.deinit();
                self.pending = null;
                return error.PacketTooLarge;
            },
            error.Closed => {
                frame.deinit();
                self.pending = null;
                return error.ChannelClosed;
            },
            error.Failed => {
                frame.deinit();
                self.pending = null;
                return error.ChannelFailed;
            },
        };
        if (n != bytes.len) {
            frame.deinit();
            self.pending = null;
            return error.ShortPacketSend;
        }
        frame.deinit();
        self.pending = null;
        return .sent;
    }

    pub fn flushOutbound(self: *PacketPump, resident: *webrtc.Resident, peer: *webrtc.Peer, session: *HostSession, timeout_ms: usize) !void {
        var elapsed: usize = 0;
        while (true) {
            const acted = try drainHostActions(session.host, session);
            switch (try self.sendNext(session, peer)) {
                .sent => elapsed = 0,
                .empty => if (!acted) return,
                .would_block => {
                    try pollPeer(resident, peer, 50);
                    elapsed += 50;
                    if (elapsed >= timeout_ms) return error.PacketFlushTimeout;
                },
            }
        }
    }
};

fn drainHostActions(host: *Host, session: *HostSession) !bool {
    var moved = false;
    while (try host.nextAction()) |action| {
        switch (action) {
            .flush => |peer_handle| {
                if (peer_handle != session.peer_handle) return error.UnexpectedHostAction;
                moved = true;
            },
            .need_gift_id => |n| {
                const gift_id = @as([32]u8, @splat(0x5a));
                try host.provideGiftId(n.ticket, &gift_id);
                moved = true;
            },
            .resume_work => moved = true,
            .close => |peer_handle| {
                if (peer_handle != session.peer_handle) return error.UnexpectedHostAction;
                moved = true;
            },
            .dial, .cancel_dial, .settled, .failed => return error.UnexpectedHostAction,
        }
    }
    return moved;
}

fn pollPeer(resident: *webrtc.Resident, peer: *webrtc.Peer, timeout_ms: i32) !void {
    var events: [16]webrtc.ReadyEvent = undefined;
    const count = try resident.pollReady(&events, timeout_ms);
    for (events[0..count]) |event| {
        if (event.subject != @backingInt(peer.id())) return error.UnexpectedReadySubject;
    }
}

pub fn sessionOpenDone(ctx: *anyopaque) bool {
    const session: *HostSession = @ptrCast(@alignCast(ctx));
    return session.sessionOpen();
}

pub fn refDone(ctx: *anyopaque) bool {
    const captured: *CapturedRef = @ptrCast(@alignCast(ctx));
    return captured.state != .pending;
}

pub fn stringDone(ctx: *anyopaque) bool {
    const captured: *CapturedString = @ptrCast(@alignCast(ctx));
    return captured.state != .pending;
}

pub fn waitFor(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    pump: *PacketPump,
    host: *Host,
    session: *HostSession,
    done_ctx: *anyopaque,
    done: *const fn (*anyopaque) bool,
    timeout_ms: usize,
) !void {
    var elapsed: usize = 0;
    var rounds: usize = 0;
    while (!done(done_ctx)) : (rounds += 1) {
        if (rounds >= 10_000) return error.PacketPumpDidNotSettle;
        if (try pump.drive(host, session, peer)) {
            elapsed = 0;
            continue;
        }
        try pollPeer(resident, peer, 50);
        elapsed += 50;
        if (elapsed >= timeout_ms) return error.PacketPumpTimeout;
    }
}

pub fn fetchRef(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    pump: *PacketPump,
    host: *Host,
    session: *HostSession,
    name: []const u8,
    timeout_ms: usize,
) !model.Reference {
    var captured = CapturedRef{};
    const vow = try host.fetch(session, name);
    try host.vowOn(vow, .{ .ctx = &captured, .func = CapturedRef.record });
    try waitFor(resident, peer, pump, host, session, &captured, refDone, timeout_ms);
    return captured.require();
}

pub fn sendAndExpectString(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    pump: *PacketPump,
    host: *Host,
    session: *HostSession,
    target: model.Reference,
    msg: actors.Message,
    expected: []const u8,
    timeout_ms: usize,
) !void {
    var captured = CapturedString{};
    const vow = try host.send(session, target, msg);
    try host.vowOn(vow, .{ .ctx = &captured, .func = CapturedString.record });
    try waitFor(resident, peer, pump, host, session, &captured, stringDone, timeout_ms);
    if (!std.mem.eql(u8, try captured.require(), expected)) return error.WrongReply;
}

pub fn serveUntilClosed(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    pump: *PacketPump,
    host: *Host,
    session: *HostSession,
    timeout_ms: usize,
) !void {
    var elapsed: usize = 0;
    var rounds: usize = 0;
    while (rounds < 10_000) : (rounds += 1) {
        const moved = pump.drive(host, session, peer) catch |err| switch (err) {
            error.ChannelClosed => {
                try host.transportClosed(session, "webrtc channel closed");
                return;
            },
            else => return err,
        };
        if (moved) {
            elapsed = 0;
            continue;
        }
        try pollPeer(resident, peer, 50);
        elapsed += 50;
        if (elapsed >= timeout_ms) return error.PacketServeTimeout;
    }
    return error.PacketServeDidNotSettle;
}

pub fn atomicFlagDone(ctx: *anyopaque) bool {
    const done: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx));
    return done.load(.acquire);
}

pub fn serveUntil(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    pump: *PacketPump,
    host: *Host,
    session: *HostSession,
    done_ctx: *anyopaque,
    done: *const fn (*anyopaque) bool,
    timeout_ms: usize,
) !void {
    var elapsed: usize = 0;
    var rounds: usize = 0;
    while (!done(done_ctx) and rounds < 10_000) : (rounds += 1) {
        const moved = pump.drive(host, session, peer) catch |err| switch (err) {
            error.ChannelClosed => {
                if (done(done_ctx)) return;
                try host.transportClosed(session, "webrtc channel closed");
                return error.ChannelClosed;
            },
            else => return err,
        };
        if (moved) {
            elapsed = 0;
            continue;
        }
        try pollPeer(resident, peer, 50);
        elapsed += 50;
        if (elapsed >= timeout_ms) return error.PacketServeTimeout;
    }
    if (!done(done_ctx)) return error.PacketServeDidNotSettle;
    try pump.flushOutbound(resident, peer, session, timeout_ms);
}

pub fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

/// The exporter's signaling inbox, hosted over CapTP: it holds the exporter's
/// sidecar peer and answers `offer` / `candidate` / `poll` by driving it. The
/// answer and candidate bytes are returned from buffers the actor owns, so they
/// outlive the turn that produced them (the serve path copies the reply onto the
/// wire before the next turn overwrites the buffer).
pub const SignalingInbox = struct {
    peer: *webrtc.Peer,
    response_buf: [signaling_frame_bytes]u8 = undefined,

    pub fn handle(self: *SignalingInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "offer")) {
            if (msg.args.len != 1) return error.BadSignalingCall;
            const sdp = strArg(msg.args[0]) orelse return error.BadSignalingCall;
            try self.peer.setRemoteOffer(sdp);
            var len: usize = 0;
            return .{ .string = try self.peer.createAnswer(&self.response_buf, &len) };
        }
        if (std.mem.eql(u8, msg.verb, "candidate")) {
            if (msg.args.len != 1) return error.BadSignalingCall;
            try self.peer.addRemoteCandidate(strArg(msg.args[0]) orelse return error.BadSignalingCall);
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, msg.verb, "poll")) {
            var len: usize = 0;
            if (try self.peer.nextLocalCandidate(&self.response_buf, &len)) |ice| return .{ .string = ice };
            return .{ .string = "" };
        }
        return error.NoSuchMethod;
    }
};

/// Bring the offerer's DataChannel up through the exporter's signaling inbox over
/// CapTP: send the offer, set the answer, then trickle local candidates with
/// `candidate` and pull the exporter's with `poll` until the channel opens.
pub fn bringUpViaCapTP(sig: *driver.BlockingSession, inbox: actors.Ref, resident: *webrtc.Resident, offerer: *webrtc.Peer, allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signal_buf: [signaling_frame_bytes]u8 = undefined;
    var len: usize = 0;

    const offer_sdp = try offerer.createOffer(&signal_buf, &len);
    const answered = try sig.call(inbox, .{ .verb = "offer", .args = &.{.{ .string = offer_sdp }} }, arena);
    switch (answered) {
        .fulfilled => |arg| try offerer.setRemoteAnswer(strArg(arg) orelse return error.NoAnswer),
        .broken, .give => return error.OfferBroke,
    }

    var rounds: usize = 0;
    while (rounds < 400) : (rounds += 1) {
        _ = arena_state.reset(.retain_capacity);
        while (try offerer.nextLocalCandidate(&signal_buf, &len)) |ice| {
            _ = try sig.call(inbox, .{ .verb = "candidate", .args = &.{.{ .string = ice }} }, arena);
        }
        const polled = try sig.call(inbox, .{ .verb = "poll", .args = &.{} }, arena);
        switch (polled) {
            .fulfilled => |arg| {
                const ice = strArg(arg) orelse "";
                if (ice.len > 0) try offerer.addRemoteCandidate(ice);
            },
            .broken, .give => return error.PollBroke,
        }
        if (try pollOpen(resident, offerer, 50)) return;
    }
    return error.ChannelBringUpTimeout;
}
