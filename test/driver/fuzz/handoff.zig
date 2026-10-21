//! The third-party handoff under a program of honest and damaged
//! certificates, for the driver's fuzz target.
//!
//! Three hosts stand where a gifter, an exporter, and a recipient stand: the
//! gifter holds a capability the exporter published, introduces it to the
//! recipient, and the recipient redeems the signed give at the exporter with
//! a signed receive. Every leg is the product's own: the hosts' interceptors
//! mint the give and the receive, the recipient's router redeems, and the
//! exporter's bootstrap withdraws. The program stops the one frame that
//! carries the receive to the exporter and feeds it as many times as it
//! likes: verbatim, with a few bytes of the certificate flipped, or with a
//! few bytes of its signature flipped and everything else intact. Each feed
//! is a fresh request, with its own answer position and resolver, the way a peer that
//! kept a certificate would resend it. The exporter's replies reach the
//! recipient only for the first feed, since a reply to a request the
//! recipient never made would close the session from its side and end the
//! program early.
//!
//! A damaged certificate never withdraws: the gift stays live, the accepted
//! count stays where it was, no withdrawal parks, and the exporter answers a
//! break or retires the session. The verbatim certificate withdraws exactly
//! once, as long as the exporter's session is still open to receive it, and
//! a second one is a replay. Every table the six sessions declare a bound
//! for stays inside it, nothing crashes or leaks, and the allocation failure
//! a run asks for ends it clean.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const harness = @import("../core_host/harness.zig");
const bounds = @import("../../support/session_bounds.zig");

const driver = glowcap.driver;
const stream_framing = glowcap.foundation.stream_framing;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const Pair = harness.Pair;
const ParkedDial = harness.ParkedDial;
const CapturedRef = harness.CapturedRef;

pub const max_steps = 8;
/// How far into a run the drawn allocation failure may land: three hosts,
/// three open sessions, and the handoff between them.
pub const span: u16 = 16384;
/// The most bytes one flip arm changes.
pub const max_flips = 3;

/// The gift id `harness.drainActions` answers every request with.
const gift_id = @as([32]u8, @splat(0x5a));

/// The actions a step draws.
pub const act_honest: u64 = 0;
pub const act_damaged: u64 = 1;
pub const act_forge: u64 = 2;

/// Where an Ed25519 signature's two halves lie in the frame.
const Signature = struct {
    r: usize,
    s: usize,

    /// The first `sig-val` record at or after `from`.
    fn find(bytes: []const u8, from: usize) ?Signature {
        const record = std.mem.indexOfPos(u8, bytes, from, "[7'sig-val[5'eddsa[1'r32:") orelse return null;
        const r = record + "[7'sig-val[5'eddsa[1'r32:".len;
        const s_label = std.mem.indexOfPos(u8, bytes, r + 32, "[1's32:") orelse return null;
        const s = s_label + "[1's32:".len;
        if (s + 32 > bytes.len) return null;
        return .{ .r = r, .s = s };
    }

    /// The byte at `pos` of the 64 the signature holds.
    fn at(self: Signature, pos: u16) usize {
        const i = pos % 64;
        return if (i < 32) self.r + i else self.s + (i - 32);
    }
};

/// The three hosts, their three sessions, and the stopped receive.
pub const Trio = struct {
    gpa: std.mem.Allocator,
    exporter: Host,
    gifter: Host,
    recipient: Host,
    dials: std.ArrayList(ParkedDial),
    g_to_e: Pair,
    r_to_g: Pair,
    r_to_e: Pair,
    redeemed: CapturedRef,
    /// The `withdraw-gift` frame the recipient sent, owned here.
    withdraw: []u8,
    /// Where the receive's envelope lies in it, and the receive's signature.
    envelope_start: usize,
    envelope_end: usize,
    signature: Signature,
    /// How many times the stopped frame has been fed, which with the digit
    /// the recipient chose is also the answer position the next feed takes.
    feeds: u8 = 0,
    answer_base: u8,
    resolver_start: usize,
    resolver_end: usize,
    resolver_base: u64,
    withdrawn: bool = false,
    attacked: bool = false,

    pub fn init(gpa: std.mem.Allocator) !*Trio {
        const self = try gpa.create(Trio);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.dials = .empty;
        self.redeemed = .{};
        self.feeds = 0;
        self.withdrawn = false;
        self.attacked = false;
        self.withdraw = &.{};
        const options = Host.Options.withFrameCap(harness.frame_cap);
        self.exporter = test_host.init(gpa, @as([32]u8, @splat(0x0e)), options);
        errdefer self.exporter.deinit();
        self.gifter = test_host.init(gpa, @as([32]u8, @splat(0x06)), options);
        errdefer self.gifter.deinit();
        self.recipient = test_host.init(gpa, @as([32]u8, @splat(0x0c)), options);
        errdefer self.recipient.deinit();
        errdefer self.freeDials();
        errdefer gpa.free(self.withdraw);
        try self.introduce();
        return self;
    }

    pub fn deinit(self: *Trio) void {
        self.freeDials();
        self.recipient.deinit();
        self.gifter.deinit();
        self.exporter.deinit();
        self.gpa.free(self.withdraw);
        self.gpa.destroy(self);
    }

    fn freeDials(self: *Trio) void {
        for (self.dials.items) |parked| self.gpa.free(parked.designator);
        self.dials.deinit(self.gpa);
    }

    fn hosts(self: *Trio) [3]*Host {
        return .{ &self.exporter, &self.gifter, &self.recipient };
    }

    /// Up to the receive: the gifter fetches the widget, the recipient fetches
    /// the introducer and already holds a session to the exporter, and the
    /// introduction runs until the recipient's withdraw sits unsent.
    fn introduce(self: *Trio) !void {
        const gpa = self.gpa;
        const all = self.hosts();
        self.g_to_e = try harness.openPair(gpa, &self.gifter, &self.exporter, "127.0.0.1:7001", &self.dials);
        _ = try self.g_to_e.b.served.publish(&self.g_to_e.b.host.vat, "widget", harness.Widget, .{});
        var widget = CapturedRef{};
        try self.gifter.vowOn(try self.gifter.fetch(self.g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
        try harness.pumpToQuiescence(gpa, &all, &.{self.g_to_e}, &self.dials);

        self.r_to_g = try harness.openPair(gpa, &self.recipient, &self.gifter, "127.0.0.1:7002", &self.dials);
        _ = try self.r_to_g.b.served.publish(&self.r_to_g.b.host.vat, "introducer", harness.Introducer, .{ .widget = try widget.require() });
        var introducer = CapturedRef{};
        try self.recipient.vowOn(try self.recipient.fetch(self.r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
        try harness.pumpToQuiescence(gpa, &all, &.{ self.g_to_e, self.r_to_g }, &self.dials);

        // A live session to the exporter, so the redeem rides it instead of
        // surfacing a dial, and one the recipient's application already uses,
        // so a refused redeem does not retire it and a later receive can
        // still land.
        self.r_to_e = try harness.openPair(gpa, &self.recipient, &self.exporter, "127.0.0.1:7001", &self.dials);
        _ = try self.r_to_e.b.served.publish(&self.r_to_e.b.host.vat, "widget", harness.Widget, .{});
        var owned = CapturedRef{};
        try self.recipient.vowOn(try self.recipient.fetch(self.r_to_e.a, "widget"), .{ .ctx = &owned, .func = CapturedRef.record });
        try harness.pumpToQuiescence(gpa, &all, &.{ self.g_to_e, self.r_to_g, self.r_to_e }, &self.dials);
        _ = try owned.require();

        const vow = try self.recipient.send(self.r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
        try self.recipient.vowOn(vow, .{ .ctx = &self.redeemed, .func = CapturedRef.record });
        // Everything but the recipient-to-exporter wire moves, so the
        // deposit lands, the give lands, and the withdraw stays queued.
        try harness.pumpToQuiescence(gpa, &all, &.{ self.g_to_e, self.r_to_g }, &self.dials);
        if (!self.giftLive()) return error.GiftNotDeposited;
        if (self.dials.items.len != 0) return error.UnexpectedDial;

        while (try self.r_to_e.a.takeOutbound()) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            if (std.mem.indexOf(u8, frame.bytes(), "withdraw-gift") != null and self.withdraw.len == 0) {
                self.withdraw = try gpa.dupe(u8, frame.bytes());
            } else {
                try self.exporter.feed(self.r_to_e.b, frame.view());
            }
        }
        if (self.withdraw.len == 0) return error.NoWithdrawFrame;
        self.envelope_start = std.mem.indexOf(u8, self.withdraw, "<17'desc:sig-envelope") orelse return error.NoEnvelope;
        self.envelope_end = valueEnd(self.withdraw, self.envelope_start) orelse return error.NoEnvelope;
        // The give's signature closes the inner envelope and the receive's
        // closes the outer, so the second found is the receive's.
        const give_signature = Signature.find(self.withdraw, self.envelope_start) orelse return error.NoEnvelope;
        self.signature = Signature.find(self.withdraw, give_signature.s + 32) orelse return error.NoEnvelope;
        if (self.signature.s + 32 > self.envelope_end) return error.NoEnvelope;
        // The answer position follows the argument list, one digit the feeds
        // count up from in place, past every position the recipient used.
        const answer = self.withdraw[self.envelope_end..];
        if (answer.len < 3 or answer[0] != ']' or answer[2] != '+') return error.NoAnswerPosition;
        self.answer_base = answer[1];
        if (self.answer_base < '0' or self.answer_base + max_steps > '9' + 1) return error.NoAnswerPosition;
        const resolver_label = "<18'desc:import-object";
        self.resolver_start = (std.mem.indexOfPos(u8, self.withdraw, self.envelope_end, resolver_label) orelse return error.NoResolver) + resolver_label.len;
        self.resolver_end = std.mem.indexOfScalarPos(u8, self.withdraw, self.resolver_start, '+') orelse return error.NoResolver;
        self.resolver_base = try std.fmt.parseInt(u64, self.withdraw[self.resolver_start..self.resolver_end], 10);
        if (self.resolver_base > std.math.maxInt(u64) - max_steps) return error.NoResolver;
    }

    /// Whether the gift still waits at the exporter, in the registry of the
    /// gifter's session, which is where a withdrawal takes it from.
    pub fn giftLive(self: *Trio) bool {
        return self.g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id);
    }

    fn acceptedCount(self: *Trio) ?u64 {
        return self.g_to_e.b.served.port.peer.giftRegistry().acceptedHandoffCount();
    }

    fn sessions(self: *Trio) [6]*HostSession {
        return .{ self.g_to_e.a, self.g_to_e.b, self.r_to_g.a, self.r_to_g.b, self.r_to_e.a, self.r_to_e.b };
    }

    fn checkBounds(self: *Trio) !void {
        for (self.sessions()) |session| try bounds.checkDeclared(&session.served.port.peer.session_state);
        const peer = self.g_to_e.b.served.port.peer;
        try std.testing.expect(peer.giftRegistry().retainedBytes() <= peer.limits().max_deposited_gift_bytes);
        // The gift is deposited before the first feed, so nothing this
        // program sends has a deposit to wait for.
        try std.testing.expectEqual(@as(usize, 0), self.r_to_e.b.served.port.peer.pendingWithdrawCount());
    }

    /// Feed one copy of the stopped frame to the exporter the way a socket
    /// read would, under the next answer position and resolver, then let the network
    /// settle.
    fn feedToExporter(self: *Trio, copy: []u8) !void {
        copy[self.envelope_end + 1] = self.answer_base + self.feeds;
        // A fresh question also needs a fresh resolver capability. A refused
        // certificate can leave its answer pending; reusing its resolver then
        // violates the protocol before the next certificate is examined.
        var resolver_buf: [20]u8 = undefined;
        const resolver = try std.fmt.bufPrint(&resolver_buf, "{d}", .{self.resolver_base + self.feeds});
        self.feeds += 1;
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        const frame_len = copy.len - (self.resolver_end - self.resolver_start) + resolver.len;
        const prefix = stream_framing.renderPrefix(&prefix_buf, frame_len);
        const stream_bytes = try self.gpa.alloc(u8, prefix.len + frame_len);
        defer self.gpa.free(stream_bytes);
        @memcpy(stream_bytes[0..prefix.len], prefix);
        const resolver_at = prefix.len + self.resolver_start;
        @memcpy(stream_bytes[prefix.len..resolver_at], copy[0..self.resolver_start]);
        @memcpy(stream_bytes[resolver_at..][0..resolver.len], resolver);
        @memcpy(stream_bytes[resolver_at + resolver.len ..], copy[self.resolver_end..]);
        self.exporter.feedBytes(self.r_to_e.b, stream_bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A refusal retires the session, which the properties below read.
            else => {},
        };
        try self.settle();
    }

    /// Pump until quiescent. The exporter's replies on the stopped wire are
    /// relayed only during the first feed, and dropped after.
    fn settle(self: *Trio) !void {
        const all = self.hosts();
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            var moved = try harness.shuttleAll(&.{ self.g_to_e, self.r_to_g });
            if (try moveOneWay(self.r_to_e.a, &self.exporter, self.r_to_e.b, true)) moved = true;
            if (try moveOneWay(self.r_to_e.b, &self.recipient, self.r_to_e.a, self.feeds <= 1)) moved = true;
            if (try harness.drainActions(self.gpa, &all, &self.dials)) moved = true;
            if (!moved) return;
        }
        return error.PumpDidNotQuiesce;
    }
};

/// Move every frame queued on `from` into `to`, or drop them when `deliver`
/// is off. Returns whether anything moved.
fn moveOneWay(from: *HostSession, to_host: *Host, to: *HostSession, deliver: bool) !bool {
    var moved = false;
    while (try from.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        moved = true;
        if (!deliver) continue;
        switch (to.lifecyclePhase()) {
            .active, .finishing => try to_host.feed(to, frame.view()),
            .cancel_pending, .terminating => {},
        }
    }
    return moved;
}

/// The end of the Syrup value that starts at `at`, by syntax alone, or null
/// when the bytes are not one whole value.
fn valueEnd(bytes: []const u8, at: usize) ?usize {
    var i = at;
    var depth: usize = 0;
    while (i < bytes.len) {
        switch (bytes[i]) {
            '<', '[', '{' => {
                depth += 1;
                i += 1;
            },
            '>', ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                i += 1;
                if (depth == 0) return i;
            },
            't', 'f' => {
                i += 1;
                if (depth == 0) return i;
            },
            'F' => {
                i += 5;
                if (depth == 0) return i;
            },
            'D' => {
                i += 9;
                if (depth == 0) return i;
            },
            '0'...'9' => {
                var n: usize = 0;
                while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
                    n = n * 10 + (bytes[i] - '0');
                    if (n > bytes.len) return null;
                }
                if (i >= bytes.len) return null;
                switch (bytes[i]) {
                    ':', '\'', '"' => i += 1 + n,
                    '+', '-' => i += 1,
                    else => return null,
                }
                if (depth == 0) return i;
            },
            else => return null,
        }
    }
    return null;
}

/// Feed one copy of the stopped frame and hold the property its bytes
/// earn. The verbatim receive withdraws the gift exactly when the exporter's
/// session can still take it and the gift is still there, and a second one
/// is a replay that moves nothing. Any other bytes never withdraw, whichever
/// they are, and no capability reaches the recipient.
fn feedCopy(trio: *Trio, copy: []u8) !void {
    const exact = std.mem.eql(u8, copy, trio.withdraw);
    const open = trio.r_to_e.b.sessionOpen();
    const live = trio.giftLive();
    const count = trio.acceptedCount();
    const first = trio.feeds == 0;
    if (!exact) trio.attacked = true;
    try trio.feedToExporter(copy);
    if (exact and open and live) {
        if (trio.giftLive()) return error.HonestCertificateRefused;
        if (first and trio.redeemed.ref == null) return error.RedeemDidNotSettle;
        trio.withdrawn = true;
        return;
    }
    try std.testing.expectEqual(live, trio.giftLive());
    try std.testing.expectEqual(count, trio.acceptedCount());
    if (!exact and first) try std.testing.expect(trio.redeemed.ref == null);
}

/// The receive as the recipient sent it.
fn honest(trio: *Trio) !void {
    const copy = try trio.gpa.dupe(u8, trio.withdraw);
    defer trio.gpa.free(copy);
    try feedCopy(trio, copy);
}

/// Where a flip arm lands: anywhere in the envelope, or inside the
/// receive's signature with the rest of the certificate intact.
const Where = enum { envelope, signature };

/// The receive with `flips` bytes changed. Flips that cancel leave the
/// verbatim receive, which `feedCopy` judges as such.
fn damaged(trio: *Trio, where: Where, flips: u8, at: *const [max_flips]u16, mask: *const [max_flips]u8) !void {
    const copy = try trio.gpa.dupe(u8, trio.withdraw);
    defer trio.gpa.free(copy);
    const width = trio.envelope_end - trio.envelope_start;
    for (at[0..flips], mask[0..flips]) |pos, bit| {
        const index = switch (where) {
            .envelope => trio.envelope_start + pos % width,
            .signature => trio.signature.at(pos),
        };
        copy[index] ^= bit;
    }
    try feedCopy(trio, copy);
}

/// Run one program over a trio the caller owns. Every step draws an action,
/// a flip count, and `max_flips` positions and masks, so a row is always the
/// same width whichever arm reads it.
pub fn run(smith: *std.testing.Smith, trio: *Trio) !void {
    var step: usize = 0;
    while (step < max_steps) : (step += 1) {
        if (smith.eos()) break;
        const action = smith.valueRangeAtMost(u8, 0, 2);
        const flips = smith.valueRangeAtMost(u8, 1, max_flips);
        var at: [max_flips]u16 = undefined;
        var mask: [max_flips]u8 = undefined;
        for (&at, &mask) |*pos, *bit| {
            pos.* = smith.valueRangeAtMost(u16, 0, 2047);
            bit.* = smith.valueRangeAtMost(u8, 1, 255);
        }
        switch (action) {
            act_honest => try honest(trio),
            act_damaged => try damaged(trio, .envelope, flips, &at, &mask),
            else => try damaged(trio, .signature, flips, &at, &mask),
        }
        try trio.checkBounds();
    }
}

/// Run a seed as the target would, over a trio the caller keeps, so a seed
/// is judged by where it leaves the gift.
pub fn replay(gpa: std.mem.Allocator, seed: []const u8) !*Trio {
    var reader: std.testing.Smith = .{ .in = seed };
    _ = @import("../../support/fuzz_budget.zig").Budget.draw(&reader, span);
    const trio = try Trio.init(gpa);
    errdefer trio.deinit();
    try run(&reader, trio);
    return trio;
}
