//! The shared spine of the byte-fed Host suite: the wired pair and its
//! shuttles (re-exported from test/support/host_pair.zig), the widget every
//! scenario pokes, the vendor and introducer behaviors, locator and
//! sturdyref builders, the action pump, session retirement, and the trace
//! log the trace tests read back.

const std = @import("std");
const glowcap = @import("glowcap");
const promise_capture = @import("../../support/capture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

pub const frame_cap = 4096;

pub fn nextRouteOptions() Host.Options {
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = .next;
    options.features = model.FeatureSet.full().forCaptpVersion(.next);
    return options;
}

/// The gifted object, published by the exporter.
pub const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked over fed bytes" };
    }
};

pub const FairCounter = struct {
    hits: *usize,

    pub fn handle(self: *FairCounter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits.* += 1;
        return .{ .integer = @intCast(self.hits.*) };
    }
};

/// The exporter's vendor: replies with a capability to an object it hosts, so
/// a caller comes by that capability through an ordinary call instead of
/// through `fetch`. `fetch` is the one path that enrolls its result on its
/// own, so this is how a test gets a capability that has no routing token yet.
pub const Vendor = struct {
    widget: model.Reference,
    pub fn handle(self: *Vendor, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// The gifter's introducer: replies with the foreign capability it fetched.
/// The host's own origination interceptor turns that reply into a give.
pub const Introducer = struct {
    widget: model.Reference,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// A wired pair: one host's connection whose outbound is the other's inbound.
pub const host_pair = @import("../../support/host_pair.zig");

pub const handshake_support = @import("../../support/handshake.zig");

pub const Pair = host_pair.Pair;

pub const shuttle = host_pair.shuttle;

pub const shuttleAll = host_pair.shuttleAll;

pub const tcpLocator = host_pair.tcpLocator;

pub const publishAndOpenAccepted = host_pair.publishAndOpenAccepted;

pub const publishAndOpenAcceptedOver = host_pair.publishAndOpenAcceptedOver;

pub fn tcpSturdyref(designator: []const u8, swissnum: []const u8) model.SturdyRef {
    return .{ .peer = tcpLocator(designator), .swissnum = swissnum };
}

pub fn onionLocator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = model.transport.onion,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
}

pub fn onionSturdyref(designator: []const u8, swissnum: []const u8) model.SturdyRef {
    return .{ .peer = onionLocator(designator), .swissnum = swissnum };
}

/// One dial request parked for the test to execute, designator duped clear of
/// the action queue's popped-view lifetime.
pub const ParkedDial = struct {
    host: *Host,
    ticket: glowcap.ocapn.engine.Node.PendingId,
    route_index: usize,
    designator: []u8,
};

/// Drain every host's action queue: gift-id requests are answered inline with
/// deterministic bytes (entropy is the embedder's job), flush notices are
/// no-ops here (the shuttle polls every queue anyway), and dial requests park
/// on `dials` for the test to execute explicitly.
pub fn drainActions(allocator: std.mem.Allocator, hosts: []const *Host, dials: *std.ArrayList(ParkedDial)) !bool {
    var did_work = false;
    for (hosts) |host| {
        while (try host.nextAction()) |action| {
            // `nextAction` drives dirty Host work before returning an effect.
            // Consuming even a no-op test effect can therefore make fresh wire
            // output visible for the next shuttle round.
            did_work = true;
            switch (action) {
                .flush => {},
                .need_gift_id => |n| {
                    const gift_id = @as([32]u8, @splat(0x5a));
                    try host.provideGiftId(n.ticket, &gift_id);
                },
                .dial => |d| {
                    // Ticket-only action: pending row owns the dial view (no re-parse).
                    const view = host.pendingDial(d.ticket, d.route_index) orelse return error.MissingPendingDial;
                    try std.testing.expect(view.locator.designator.len != 0);
                    try dials.append(allocator, .{
                        .host = host,
                        .ticket = d.ticket,
                        .route_index = d.route_index,
                        .designator = try allocator.dupe(u8, view.locator.designator),
                    });
                },
                .cancel_dial => |d| {
                    try host.dialCancelled(d.ticket, d.route_index);
                },
                // An unlistened vow's completion; the tests in this file that
                // route completions drain `nextAction` by hand instead.
                .settled, .failed => {},
                // Tests that close a session assert its consequences directly.
                // A session the Host condemned for amplification is a real
                // failure; the Host applies the local-turn budget by default.
                .close => |peer_handle| if (host.sessionForPeer(peer_handle)) |session| {
                    if (session.served.port.peer.lastAbort()) |abort| {
                        if (std.mem.eql(u8, abort.error_name, "LocalTurnLimitExceeded"))
                            return error.LocalTurnLimitExceeded;
                    }
                },
                // A finite host quantum can yield internal work without an
                // external effect; the next action drain is the continuation.
                .resume_work => {},
            }
        }
    }
    return did_work;
}

/// Pump shuttles and action drains until the whole network is quiescent.
pub fn pumpToQuiescence(
    allocator: std.mem.Allocator,
    hosts: []const *Host,
    pairs: []const Pair,
    dials: *std.ArrayList(ParkedDial),
) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(pairs);
        const acted = try drainActions(allocator, hosts, dials);
        if (!moved and !acted) return;
    }
    return error.PumpDidNotQuiesce;
}

pub const CapturedRef = promise_capture.CapturedRef;

pub const CapturedString = promise_capture.CapturedString;

/// Open a dialed/accepted pair between two hosts and drive the keyed
/// handshake open over fed bytes.
pub fn openPair(
    allocator: std.mem.Allocator,
    dialer: *Host,
    acceptor: *Host,
    designator: []const u8,
    dials: *std.ArrayList(ParkedDial),
) !Pair {
    try dialer.ensureAdvertisedLocator("tcp");
    try acceptor.setAdvertisedLocator(tcpLocator(designator));
    const accepted = try acceptor.openAcceptedAdvertised("tcp");
    const dialed = try dialer.openDialedLocator(tcpLocator(designator));
    const pair = Pair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpToQuiescence(allocator, &.{ dialer, acceptor }, &.{pair}, dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
    return pair;
}

/// Drive a finishing/closing Host through one session's terminal FLUSH/CLOSE
/// actions and prove their order.
/// The sans-I/O core names the effects. This helper is the tiny embedding that
/// drains bytes and releases the shell after the transport-close notice.
pub fn retireClosingSession(host: *Host, session: *HostSession) !void {
    var saw_flush = false;
    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .flush => |peer_handle| {
            try std.testing.expectEqual(session.peer_handle, peer_handle);
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }
            saw_flush = true;
        },
        .close => |peer_handle| {
            try std.testing.expect(saw_flush);
            try std.testing.expectEqual(session.peer_handle, peer_handle);
            try host.releaseSession(session);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

/// Drain one session's terminal effects without requiring its Host to close.
/// Sibling sessions remain owned by the same Host.
pub fn retireClosedSession(host: *Host, session: *HostSession) !void {
    const closing_peer = session.peer_handle;
    var saw_flush = false;
    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .flush => |peer_handle| if (peer_handle == closing_peer) {
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }
            saw_flush = true;
        },
        .close => |peer_handle| if (peer_handle == closing_peer) {
            try std.testing.expect(saw_flush);
            try host.releaseSession(session);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

/// One generation of a Host publication. The reply is the tag its row carries,
/// so a call says *which* registration answered rather than only that one did.
pub const Tagged = struct {
    row: *TaggedRow,

    pub fn clone(self: *const Tagged, allocator: std.mem.Allocator) !Tagged {
        _ = allocator;
        return .{ .row = self.row };
    }

    pub fn handle(self: *Tagged, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "mutate")) {
            self.row.tag = "mutated-original";
        } else if (!std.mem.eql(u8, msg.verb, "tag")) return error.NoSuchMethod;
        return .{ .string = self.row.tag };
    }

    pub fn deinit(self: *Tagged, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.row.freed.* = true;
    }
};

/// The `ctx` behind one Host publication, which every actor it published
/// borrows. `free` records the release instead of doing one, so a test can say
/// when the host let go.
/// `Host.partnerIdentity` keeps three facts distinct: the session key verified
/// by the `op:start-session` signature, the designator claimed by the partner's
/// acceptable location, and the provenance of any durable identity proof.
/// Success means the handshake signature was verified. It does not make the
/// advertised designator an authenticated durable identity. Only provenance
/// from an authenticated channel establishes that stronger fact.
///
/// The tests below cover the verified-session requirement, the claimed locator
/// representation, and the provenance distinction. Transport-specific channel
/// proof is covered separately by the verified-channel tests.
///
/// The designator for the host built on `seed`: that host's Ed25519 public key
/// in canonical hexadecimal form.
pub fn keyedDesignator(seed: [32]u8) [crypto.PeerKey.designator_len]u8 {
    return crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
}

pub const TraceLog = struct {
    /// Compact rows: kind letter + detail, enough to assert order and facts.
    buf: [16][96]u8 = undefined,
    lens: [16]usize = @splat(0),
    n: usize = 0,
    /// Each open's wire name, kept whole rather than folded into the row
    /// above: the claim it carries is an equality between two hosts, not an
    /// order or a spelling.
    wires: [8][64]u8 = undefined,
    wire_lens: [8]usize = @splat(0),
    wire_n: usize = 0,

    pub fn emit(ctx: ?*anyopaque, event: driver.core.trace.Event) void {
        const self: *TraceLog = @ptrCast(@alignCast(ctx.?));
        if (event == .session_open and self.wire_n < self.wires.len) {
            const wire = event.session_open.session_id;
            if (wire.len <= self.wires[self.wire_n].len) {
                @memcpy(self.wires[self.wire_n][0..wire.len], wire);
                self.wire_lens[self.wire_n] = wire.len;
                self.wire_n += 1;
            }
        }
        if (self.n == self.buf.len) return;
        const line = switch (event) {
            .session_open => |open| std.fmt.bufPrint(
                &self.buf[self.n],
                "open codec={s} captp={s} designator={s} transport={s} provenance={s}",
                .{
                    @tagName(open.codec),
                    @tagName(open.captp_version),
                    open.designator,
                    open.transport,
                    @tagName(open.provenance),
                },
            ) catch return,
            .message => |msg| std.fmt.bufPrint(
                &self.buf[self.n],
                "msg {s} {s}",
                .{ if (msg.outbound) "out" else "in", msg.verb },
            ) catch return,
            .session_close => std.fmt.bufPrint(&self.buf[self.n], "close", .{}) catch return,
        };
        self.lens[self.n] = line.len;
        self.n += 1;
    }

    pub fn row(self: *const TraceLog, i: usize) []const u8 {
        return self.buf[i][0..self.lens[i]];
    }

    pub fn contains(self: *const TraceLog, needle: []const u8) bool {
        for (0..self.n) |i| {
            if (std.mem.indexOf(u8, self.row(i), needle) != null) return true;
        }
        return false;
    }

    /// The one wire name this log saw, for a host holding exactly one session.
    pub fn onlyWire(self: *const TraceLog) []const u8 {
        std.debug.assert(self.wire_n == 1);
        return self.wires[0][0..self.wire_lens[0]];
    }

    pub fn sawWire(self: *const TraceLog, needle: []const u8) bool {
        for (0..self.wire_n) |i| {
            if (std.mem.eql(u8, self.wires[i][0..self.wire_lens[i]], needle)) return true;
        }
        return false;
    }
};

pub const SessionOpenFailingAllocator = struct {
    backing: std.mem.Allocator,
    host: ?*Host = null,
    phase: Phase = .unarmed,
    induced_failure: bool = false,

    pub const Phase = enum { unarmed, before_enrollment, after_enrollment };

    pub fn allocator(self: *SessionOpenFailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    pub fn arm(self: *SessionOpenFailingAllocator, phase: Phase) void {
        self.phase = phase;
        self.induced_failure = false;
    }

    pub fn shouldFail(self: *SessionOpenFailingAllocator) bool {
        if (self.phase == .unarmed) return false;
        const enrolled = if (self.host) |host| host.sessions.count() != 0 else false;
        const matches = switch (self.phase) {
            .unarmed => false,
            .before_enrollment => !enrolled,
            .after_enrollment => enrolled,
        };
        if (!matches) return false;
        self.phase = .unarmed;
        self.induced_failure = true;
        return true;
    }

    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SessionOpenFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    pub fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *SessionOpenFailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.shouldFail()) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    pub fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *SessionOpenFailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.shouldFail()) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    pub fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SessionOpenFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

pub const TaggedRow = struct {
    tag: []const u8,
    freed: *bool,
};

pub const PublicationProbe = struct {
    host: *Host,
    refused: *bool,

    pub fn handle(self: *PublicationProbe, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "publish")) return error.NoSuchMethod;
        _ = self.host.publish("nested", Widget, .{}) catch |err| {
            if (err == driver.core.HostError.ReenteredHost) {
                self.refused.* = true;
                return .{ .boolean = true };
            }
            return err;
        };
        return .{ .boolean = false };
    }
};
