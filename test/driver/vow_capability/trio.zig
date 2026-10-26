//! The three-Host fixture `vow_capability_test.zig` runs on: `a` asks `b`
//! and passes the answer on, over its session to `b` and over a second
//! session to `c`. Readers on `b` and `c` take a capability argument, send
//! to it, and listen on it, so a test reads what each peer saw.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const Host = driver.core.Host;
const test_host = @import("../../support/core_host.zig");
const capture = @import("../../support/capture.zig");
const harness = @import("../core_host/harness.zig");
const Pair = harness.Pair;

/// Reads its first argument as a capability, sends to it, listens on it, and
/// releases it unless the test asked it to keep the capability. One
/// instantiation per Host, so each keeps its own record: the tag is read so
/// the compiler mints a type per Host instead of sharing one.
pub fn ReaderOf(comptime which: u8) type {
    return struct {
        pub const tag = which;
        pub var ran: usize = 0;
        pub var send_vow: u64 = 0;
        pub var send_refusal: ?anyerror = null;
        pub var listen_vow: u64 = 0;
        pub var promise_id: ?u64 = null;
        pub var keep: bool = false;
        pub var kept: ?driver.Capability = null;
        /// Hears the listen vow from inside the receiving turn, before any
        /// pump can settle it, for a promise that arrives already settled.
        pub var listen_into: ?*capture.CapturedString = null;
        /// The string a read carried instead of a capability: a promise that
        /// settled to data before it was passed arrives as that data.
        pub var text_buf: [32]u8 = undefined;
        pub var text_len: usize = 0;

        pub fn text() []const u8 {
            return text_buf[0..text_len];
        }

        pub fn reset() void {
            ran = 0;
            send_vow = 0;
            send_refusal = null;
            listen_vow = 0;
            promise_id = null;
            keep = false;
            kept = null;
            listen_into = null;
            text_len = 0;
        }

        pub fn handle(_: *@This(), ht: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
            ran += 1;
            const cap = args.capability(0) catch |err| {
                const string = args.string(0) catch return err;
                text_len = @min(string.len, text_buf.len);
                @memcpy(text_buf[0..text_len], string[0..text_len]);
                return .{ .void = {} };
            };
            promise_id = switch (ht.host.capabilities.resolve(cap).?) {
                .deferred => |id| @backingInt(id),
                .local, .remote => null,
            };
            send_vow = ht.send(cap, "greet", &.{}) catch |err| blk: {
                send_refusal = err;
                break :blk 0;
            };
            listen_vow = switch (try ht.host.resolveCapability(ht.session.?, cap)) {
                .pending => |vow| vow,
                .resolved => 0,
            };
            if (listen_into) |captured| try listenOn(ht.host, listen_vow, captured);
            if (keep) kept = cap else ht.releaseValues(&.{.{ .capability = cap }});
            return .{ .void = {} };
        }
    };
}

pub const ReaderA = ReaderOf('a');
pub const ReaderB = ReaderOf('b');
pub const ReaderC = ReaderOf('c');

/// Defers every answer and parks the resolver for the test to settle. One
/// instantiation per Host, as with the readers.
pub fn GreeterOf(comptime which: u8) type {
    return struct {
        pub const tag = which;
        pub var ran: usize = 0;
        pub var resolver: u64 = 0;

        pub fn reset() void {
            ran = 0;
            resolver = 0;
        }

        pub fn handle(_: *@This(), ht: *driver.HostTurn, _: []const u8, _: driver.Args) !driver.Value {
            ran += 1;
            resolver = try ht.deferAnswer();
            return .{ .void = {} };
        }
    };
}

pub const GreeterA = GreeterOf('a');
pub const GreeterB = GreeterOf('b');

/// Replies with the capability the reader on `b` kept.
pub const Keeper = struct {
    pub fn handle(_: *@This(), _: *driver.HostTurn, _: []const u8, _: driver.Args) !driver.Value {
        return .{ .capability = ReaderB.kept orelse return error.NothingKept };
    }
};

/// The object a reference settlement names.
pub const Target = struct {
    pub var ran: usize = 0;
    pub fn handle(_: *@This(), _: *driver.HostTurn, _: []const u8, _: driver.Args) !driver.Value {
        ran += 1;
        return .{ .string = "from the target" };
    }
};

const b_designator = "127.0.0.1:9002";

/// Three Hosts: `a` asks `b`'s greeter and passes the answer on, `b` serves
/// the greeter and a reader on the same session, and `c` serves a reader on
/// a second session. `a` serves an echo reader so `c` can pass a promise
/// back, and a greeter of its own so `b` can hold a pending question. A
/// settlement that hands `c` a capability homed on `b` makes `c` dial `b`,
/// which the test completes as a third pair.
pub const Trio = struct {
    a: Host,
    b: Host,
    c: Host,
    ab: Pair,
    ac: Pair,
    hosts: [3]*Host,
    pair_buf: [3]Pair,
    pair_len: usize,
    dials: std.ArrayList(harness.ParkedDial),
    greeter: driver.Capability,
    b_reader: driver.Capability,
    c_reader: driver.Capability,
    arena: std.heap.ArenaAllocator,

    pub fn init(self: *Trio) !void {
        ReaderA.reset();
        ReaderB.reset();
        ReaderC.reset();
        GreeterA.reset();
        GreeterB.reset();
        Target.ran = 0;
        const gpa = std.testing.allocator;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        self.a = test_host.init(gpa, @as([32]u8, @splat(0x44)), Host.Options.withFrameCap(harness.frame_cap));
        self.b = test_host.init(gpa, @as([32]u8, @splat(0x55)), Host.Options.withFrameCap(harness.frame_cap));
        self.c = test_host.init(gpa, @as([32]u8, @splat(0x66)), Host.Options.withFrameCap(harness.frame_cap));
        self.hosts = .{ &self.a, &self.b, &self.c };
        self.dials = .empty;
        self.ab = try harness.openPair(gpa, &self.a, &self.b, b_designator, &self.dials);
        self.ac = try harness.openPair(gpa, &self.a, &self.c, "127.0.0.1:9003", &self.dials);
        self.pair_buf[0] = self.ab;
        self.pair_buf[1] = self.ac;
        self.pair_len = 2;
        _ = try self.ab.b.served.publish(&self.b.vat, "greeter", driver.core.Hosting(GreeterB), .{ .inner = .{} });
        _ = try self.ab.a.served.publish(&self.a.vat, "greeter", driver.core.Hosting(GreeterA), .{ .inner = .{} });
        _ = try self.ab.b.served.publish(&self.b.vat, "reader", driver.core.Hosting(ReaderB), .{ .inner = .{} });
        _ = try self.ac.b.served.publish(&self.c.vat, "reader", driver.core.Hosting(ReaderC), .{ .inner = .{} });
        _ = try self.ac.a.served.publish(&self.a.vat, "echo", driver.core.Hosting(ReaderA), .{ .inner = .{} });
        self.greeter = try self.fetchHeld(self.ab.a, "greeter");
        self.b_reader = try self.fetchHeld(self.ab.a, "reader");
        self.c_reader = try self.fetchHeld(self.ac.a, "reader");
    }

    pub fn deinit(self: *Trio) void {
        self.a.deinit();
        self.b.deinit();
        self.c.deinit();
        self.clearDials();
        self.dials.deinit(std.testing.allocator);
        self.arena.deinit();
    }

    pub fn clearDials(self: *Trio) void {
        for (self.dials.items) |parked| std.testing.allocator.free(parked.designator);
        self.dials.clearRetainingCapacity();
    }

    pub fn pairs(self: *const Trio) []const Pair {
        return self.pair_buf[0..self.pair_len];
    }

    pub fn pump(self: *Trio) !void {
        try harness.pumpToQuiescence(std.testing.allocator, &self.hosts, self.pairs(), &self.dials);
    }

    /// Fetch `name` over `hs`, a session of `a`, and hold it as a capability.
    pub fn fetchHeld(self: *Trio, hs: *driver.core.HostSession, name: []const u8) !driver.Capability {
        return self.fetchHeldOn(&self.a, hs, name);
    }

    /// Fetch `name` over `hs`, a session of `host`, and hold it as a capability.
    pub fn fetchHeldOn(self: *Trio, host: *Host, hs: *driver.core.HostSession, name: []const u8) !driver.Capability {
        const vow = try host.fetch(hs, name);
        var captured: capture.CapturedRef = .{};
        try host.vowOn(vow, .{ .ctx = &captured, .func = capture.CapturedRef.record });
        try self.pump();
        const reference = captured.ref orelse return error.FetchUnsettled;
        return host.liftCapability(hs, reference);
    }

    /// Complete the one dial `c` parked toward `b` to redeem a handoff, as
    /// the third pair of the network.
    pub fn redeemAtB(self: *Trio) !void {
        try std.testing.expectEqual(@as(usize, 1), self.dials.items.len);
        const parked = self.dials.items[0];
        try std.testing.expect(parked.host == &self.c);
        try std.testing.expectEqualStrings(b_designator, parked.designator);
        const accepted = try harness.publishAndOpenAccepted(&self.b, "tcp", b_designator, &.{});
        const pending = self.c.pendingDial(parked.ticket, parked.route_index) orelse return error.MissingPendingDial;
        const dialed = try self.c.openDialedLocator(.{
            .transport = pending.locator.transport,
            .designator = pending.locator.designator,
            .hints = model.Hints.emptyFalse(),
        });
        self.pair_buf[2] = .{ .ah = &self.c, .a = dialed, .bh = &self.b, .b = accepted };
        self.pair_len = 3;
        try self.pump();
        _ = try self.c.exporterDialed(parked.ticket, parked.route_index, dialed);
        self.clearDials();
        try self.pump();
    }

    /// Ask the greeter and hold the pending answer as a vow.
    pub fn ask(self: *Trio) !u64 {
        const vow = try self.a.sendValues(self.ab.a, self.greeter, "greet", &.{}, self.arena.allocator());
        try self.pump();
        try std.testing.expectEqual(@as(usize, 1), GreeterB.ran);
        return vow;
    }

    /// Pass `cap` to the reader `b` serves, on the greeter's session.
    pub fn passToB(self: *Trio, cap: driver.Capability) !void {
        try self.pass(self.ab.a, self.b_reader, cap);
    }

    /// Pass `cap` to the reader `c` serves, on the other session.
    pub fn passToC(self: *Trio, cap: driver.Capability) !void {
        try self.pass(self.ac.a, self.c_reader, cap);
    }

    /// Call `reader` with `cap`, and let the call's own vow go once it
    /// settles, so the fixture's vow table holds only what a test asks about.
    pub fn pass(self: *Trio, hs: *driver.core.HostSession, reader: driver.Capability, cap: driver.Capability) !void {
        const read = try self.a.sendValues(hs, reader, "read", &.{.{ .capability = cap }}, self.arena.allocator());
        try self.pump();
        try self.a.vowRelease(read);
    }

    pub fn fulfill(self: *Trio, text: []const u8) !void {
        try self.b.resolverFulfill(GreeterB.resolver, .{ .string = text });
        try self.pump();
    }

    /// Answers `b` lifted to promises on the greeter's session.
    pub fn liftedAnswersAtB(self: *Trio) u32 {
        return self.ab.b.served.port.peer.session_state.inbound_answers.host_promises;
    }

    /// The state of the promise row `cap` names on `a`.
    pub fn expectState(self: *Trio, cap: driver.Capability, expected: anytype) !void {
        const id = self.a.capabilities.resolve(cap).?.deferred;
        const row = self.a.capability_promises.get(id) orelse return error.NoPromiseRow;
        try std.testing.expectEqual(expected, std.meta.activeTag(row.state));
    }

    /// Every Host serves on, no promise row or reserved seat outlives its
    /// use, and every projected answer on `a` is accounted for.
    pub fn expectClean(self: *Trio) !void {
        for ([_]*Host{ &self.a, &self.b, &self.c }) |host| {
            try std.testing.expectEqual(@as(usize, 0), host.capability_promises.count());
            try std.testing.expectEqual(@as(usize, 0), host.node.actions.promise_settlements);
        }
        for (self.pairs()) |pair| {
            try std.testing.expectEqual(.active, pair.a.lifecyclePhase());
            try std.testing.expectEqual(.active, pair.b.lifecyclePhase());
            try std.testing.expect(pair.a.lastAbort() == null);
            try std.testing.expect(pair.b.lastAbort() == null);
        }
    }
};

pub fn listenOn(host: *Host, vow: u64, captured: *capture.CapturedString) !void {
    try host.vowOn(vow, .{ .ctx = captured, .func = capture.CapturedString.record });
}
