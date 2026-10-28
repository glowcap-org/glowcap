//! A promise received as an argument: a `desc:answer` for the partner's own
//! live question inside a deliver to a served object (ADR-0068). The Host
//! lifts it to a capability promise that settles with the answer. The actor
//! runs, sends to the promise and listens on it before the answer exists, the
//! same question passed twice is one capability, and the session keeps
//! serving through every settlement: data, a reference, and a break.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const driver = glowcap.driver;
const Host = driver.core.Host;
const test_host = @import("../support/core_host.zig");
const host_pair = @import("../support/host_pair.zig");
const capture = @import("../support/capture.zig");

/// Reads its first argument as a capability, sends to it, listens on it, and
/// releases it unless the test asked it to keep the capability. The promise
/// identity each run saw lets a test compare two lifts.
const Reader = struct {
    var ran: usize = 0;
    var send_vow: u64 = 0;
    var send_refusal: ?anyerror = null;
    var listen_vow: u64 = 0;
    var listen_refusal: ?anyerror = null;
    var promise_id: ?u64 = null;
    var keep: bool = false;
    var kept: ?driver.Capability = null;

    fn reset() void {
        ran = 0;
        send_vow = 0;
        send_refusal = null;
        listen_vow = 0;
        listen_refusal = null;
        promise_id = null;
        keep = false;
        kept = null;
    }

    pub fn handle(_: *@This(), ht: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        ran += 1;
        const cap = try args.capability(0);
        promise_id = switch (ht.host.capabilities.resolve(cap).?) {
            .deferred => |id| @backingInt(id),
            .local, .remote => null,
        };
        // A promise already settled to data refuses a send as any non-object
        // target does. One still pending queues it, and the vow breaks later.
        send_vow = ht.send(cap, "greet", &.{}) catch |err| blk: {
            send_refusal = err;
            break :blk 0;
        };
        // A promise already broken refuses the listen outright.
        listen_vow = if (ht.host.resolveCapability(ht.session.?, cap)) |resolution| switch (resolution) {
            .pending => |vow| vow,
            .resolved => 0,
        } else |err| blk: {
            listen_refusal = err;
            break :blk 0;
        };
        // The queued send and listen outlive the capability: the actor owns
        // its argument and gives it back before the turn ends.
        if (keep) kept = cap else ht.releaseValues(&.{.{ .capability = cap }});
        return .{ .void = {} };
    }
};

/// Defers every answer and parks the resolver for the test to settle.
const Greeter = struct {
    var ran: usize = 0;
    var resolver: u64 = 0;

    pub fn handle(_: *@This(), ht: *driver.HostTurn, _: []const u8, _: driver.Args) !driver.Value {
        ran += 1;
        resolver = try ht.deferAnswer();
        return .{ .void = {} };
    }
};

/// The object a reference settlement names.
const Target = struct {
    var ran: usize = 0;
    pub fn handle(_: *@This(), _: *driver.HostTurn, _: []const u8, _: driver.Args) !driver.Value {
        ran += 1;
        return .{ .string = "from the target" };
    }
};

/// Fetch `name` and return the import the fetch added to the client session.
/// A fetch settles to a routed reference, so the import position is read from
/// the session table: the one position held after the fetch and not before.
fn importOf(host: *Host, hs: *driver.core.HostSession, name: []const u8, pair: host_pair.Pair) !u64 {
    const before = heldImports(hs.served.port.peer);
    const vow = try host.fetch(hs, name);
    var captured: capture.CapturedRef = .{};
    try host.vowOn(vow, .{ .ctx = &captured, .func = capture.CapturedRef.record });
    try host_pair.pumpToQuiescence(&.{pair});
    if (captured.ref == null) return error.FetchUnsettled;
    const after = heldImports(hs.served.port.peer);
    for (after.items[0..after.len]) |position| {
        if (std.mem.indexOfScalar(u64, before.items[0..before.len], position) == null) return position;
    }
    return error.NoNewImport;
}

const Held = struct {
    items: [8]u64 = undefined,
    len: usize = 0,
    fn take(self: *@This(), view: session.ImportView) void {
        if (view.refcount == 0 or self.len == self.items.len) return;
        self.items[self.len] = view.position.int();
        self.len += 1;
    }
};

fn heldImports(peer: *const glowcap.ocapn.engine.Peer) Held {
    var held: Held = .{};
    session.inspect.forEachImport(&peer.session_state, &held, Held.take);
    return held;
}

/// Two Hosts over one pair, the acceptor serving a reader and a deferring
/// greeter the dialer has imported.
const Fixture = struct {
    dialer: Host,
    acceptor: Host,
    pair: host_pair.Pair,
    reader: u64,
    greeter: u64,

    fn init(self: *Fixture, acceptor_options: Host.Options) !void {
        Reader.reset();
        Greeter.ran = 0;
        Greeter.resolver = 0;
        Target.ran = 0;
        const gpa = std.testing.allocator;
        self.dialer = test_host.init(gpa, @as([32]u8, @splat(0x22)), .{ .verify_partner = false });
        self.acceptor = test_host.init(gpa, @as([32]u8, @splat(0x33)), acceptor_options);
        self.pair = try host_pair.openPair(&self.dialer, &self.acceptor, "127.0.0.1:9001");
        _ = try self.pair.b.served.publish(&self.acceptor.vat, "reader", driver.core.Hosting(Reader), .{ .inner = .{} });
        _ = try self.pair.b.served.publish(&self.acceptor.vat, "greeter", driver.core.Hosting(Greeter), .{ .inner = .{} });
        self.reader = try importOf(&self.dialer, self.pair.a, "reader", self.pair);
        self.greeter = try importOf(&self.dialer, self.pair.a, "greeter", self.pair);
    }

    fn deinit(self: *Fixture) void {
        self.dialer.deinit();
        self.acceptor.deinit();
    }

    fn client(self: *Fixture) *glowcap.ocapn.engine.Peer {
        return self.pair.a.served.port.peer;
    }

    /// Ask the greeter a question the client holds open at `answer`.
    fn ask(self: *Fixture, answer: u64) !void {
        try self.client().sendBorrowed(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(self.greeter) },
            .args = &.{.{ .symbol = "greet" }},
            .answer = .from(answer),
        } });
        try self.pump();
    }

    /// Pass the open question at `answer` to the reader as an argument.
    fn passPromise(self: *Fixture, answer: u64) !void {
        try self.passPromises(&.{answer});
    }

    /// Pass several open questions to the reader in one call.
    fn passPromises(self: *Fixture, answers: []const u64) !void {
        var args: [4]model.Argument = undefined;
        args[0] = .{ .symbol = "read" };
        for (answers, args[1..][0..answers.len]) |answer, *arg| arg.* = .{ .reference = .{ .promise = .{ .answer_position = .from(answer) } } };
        try self.client().sendBorrowed(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(self.reader) },
            .args = args[0 .. answers.len + 1],
        } });
        try self.pump();
    }

    fn liftedAnswers(self: *Fixture) u32 {
        return self.pair.b.served.port.peer.session_state.inbound_answers.host_promises;
    }

    fn pump(self: *Fixture) !void {
        try self.client().stepToIdle();
        try host_pair.pumpToQuiescence(&.{self.pair});
    }

    fn expectServing(self: *Fixture) !void {
        try std.testing.expectEqual(.active, self.pair.b.lifecyclePhase());
        try std.testing.expectEqual(.active, self.pair.a.lifecyclePhase());
        try std.testing.expect(self.pair.b.lastAbort() == null);
    }
};

test "a pending answer passed as an argument reaches the actor and settles with the data" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();

    try f.ask(7);
    try std.testing.expectEqual(@as(usize, 1), Greeter.ran);
    try std.testing.expect(Greeter.resolver != 0);

    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 1), Reader.ran);
    const first_promise = Reader.promise_id orelse return error.NoPromise;
    try std.testing.expectEqual(@as(u32, 1), f.liftedAnswers());
    // The actor let the capability go at the end of its turn, so the row
    // lives on its subscription alone and leaves with the settlement.
    try std.testing.expectEqual(@as(usize, 1), f.acceptor.capability_promises.count());
    var sent: capture.CapturedString = .{};
    try f.acceptor.vowOn(Reader.send_vow, .{ .ctx = &sent, .func = capture.CapturedString.record });
    var listened: capture.CapturedString = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &listened, .func = capture.CapturedString.record });

    // The same question passed again is the same capability.
    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 2), Reader.ran);
    try std.testing.expectEqual(first_promise, Reader.promise_id orelse return error.NoPromise);
    try std.testing.expectEqual(@as(u32, 1), f.liftedAnswers());

    try f.acceptor.resolverFulfill(Greeter.resolver, .{ .string = "hello" });
    try f.pump();
    try std.testing.expectEqualStrings("hello", listened.text());
    try std.testing.expect(sent.broken);
    try std.testing.expectEqual(@as(u32, 0), f.liftedAnswers());
    try std.testing.expectEqual(@as(usize, 0), f.acceptor.capability_promises.count());
    try f.expectServing();

    // A settled answer passed again lifts settled: the actor runs, its send is
    // refused as a message to data, its listen settles, and the row leaves
    // with the actor's release.
    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 3), Reader.ran);
    try std.testing.expect(Reader.promise_id != first_promise);
    try std.testing.expectEqual(@as(anyerror, error.UncallableTarget), Reader.send_refusal orelse return error.SendAccepted);
    try std.testing.expect(Reader.listen_vow != 0);
    try std.testing.expectEqual(@as(usize, 0), f.acceptor.capability_promises.count());
    try f.expectServing();
}

test "a lifted answer that settles with a reference shortens to that capability" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();
    const target = try f.acceptor.spawn(f.pair.b, driver.core.Hosting(Target), .{ .inner = .{} });
    defer f.acceptor.releaseCapabilityTerminal(target, null);

    try f.ask(7);
    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 1), Reader.ran);
    var sent: capture.CapturedString = .{};
    try f.acceptor.vowOn(Reader.send_vow, .{ .ctx = &sent, .func = capture.CapturedString.record });
    var listened: capture.CapturedRef = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &listened, .func = capture.CapturedRef.record });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try f.acceptor.resolverFulfillValue(Greeter.resolver, .{ .capability = target }, arena.allocator());
    try f.pump();
    try std.testing.expectEqual(@as(usize, 1), Target.ran);
    try std.testing.expectEqualStrings("from the target", sent.text());
    _ = try listened.require();
    try f.expectServing();
}

/// Serve a dialer object and fetch it from the acceptor, so the acceptor
/// holds a partner object its own resolutions can name.
fn fetchPartnerTarget(f: *Fixture) !driver.Capability {
    _ = try f.pair.a.served.publish(&f.dialer.vat, "target", driver.core.Hosting(Target), .{ .inner = .{} });
    const position = try importOf(&f.acceptor, f.pair.b, "target", f.pair);
    return f.acceptor.liftCapability(f.pair.b, .{ .far = model.FarRef.object(position) });
}

fn dataNaming(target: driver.Capability) driver.Value {
    return .{ .@"struct" = &.{
        .{ .key = "owner", .value = .{ .capability = target } },
        .{ .key = "count", .value = .{ .string = "three" } },
    } };
}

test "a settled answer holds the partner object it names until the answer is released" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();
    const target = try fetchPartnerTarget(&f);

    try f.ask(7);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try f.acceptor.resolverFulfillValue(Greeter.resolver, dataNaming(target), arena.allocator());
    try f.pump();
    // The stored resolution holds the partner object, so the application's
    // release stays with the session and the import stays held.
    const held_before = heldImports(f.pair.b.served.port.peer).len;
    try f.acceptor.releaseCapability(target, 1);
    try f.pump();
    try std.testing.expectEqual(held_before, heldImports(f.pair.b.served.port.peer).len);

    // The actor receives the settled data, with the partner object inside it
    // lifted again, and the row leaves with the actor's release.
    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 1), Reader.ran);
    try std.testing.expectEqual(@as(anyerror, error.UncallableTarget), Reader.send_refusal orelse return error.SendAccepted);
    try std.testing.expect(Reader.listen_vow != 0);
    try std.testing.expectEqual(@as(usize, 0), f.acceptor.capability_promises.count());
    try f.expectServing();

    // Releasing the answer releases the hold, and the partner object with it.
    // The listen vow's completion carries the data's capability until the
    // embedder drains it. The hold alone keeps the import after that.
    while (try f.acceptor.nextAction()) |_| {}
    try f.pump();
    try std.testing.expectEqual(held_before, heldImports(f.pair.b.served.port.peer).len);
    try f.client().sendBorrowed(.{ .gc_answer = .{ .positions = &.{7} } });
    try f.pump();
    try std.testing.expectEqual(held_before - 1, heldImports(f.pair.b.served.port.peer).len);
    try f.expectServing();
}

test "a lifted stored import survives either order of answer and Host capability release" {
    for ([_]bool{ false, true }) |answer_first| {
        var f: Fixture = undefined;
        try f.init(.{ .verify_partner = false });
        defer f.deinit();
        const original = try fetchPartnerTarget(&f);
        const far = f.acceptor.capabilities.resolve(original).?.remote.far;
        const position = far.import_position;
        const holder = &f.pair.b.served.port.peer.session_state;
        const granter = &f.client().session_state;

        try f.ask(7);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try f.acceptor.resolverFulfillValue(Greeter.resolver, dataNaming(original), arena.allocator());
        try f.pump();
        try f.acceptor.releaseCapability(original, 1);
        try f.pump();
        try std.testing.expectEqual(@as(u64, 1), holder.imports.resolutionHolds(position));
        try std.testing.expectEqual(@as(u64, 1), holder.imports.rows.get(position.int()).?.held_back);

        // Lifting a stored reference takes the parked retain back from the
        // session. Its Host handle must survive retirement of the answer.
        const lifted = try f.acceptor.liftCapability(f.pair.b, .{ .far = far });
        try std.testing.expectEqual(@as(u64, 0), holder.imports.rows.get(position.int()).?.held_back);
        if (answer_first) {
            try f.client().sendBorrowed(.{ .gc_answer = .{ .positions = &.{7} } });
        } else {
            try f.acceptor.releaseCapability(lifted, 1);
        }
        try f.pump();
        try std.testing.expectEqual(@as(u64, 1), holder.importRefcount(position));
        try std.testing.expectEqual(@as(u64, 1), granter.exports.wireHeld(.from(position.int())));
        try std.testing.expectEqual(@as(u64, if (answer_first) 0 else 1), holder.imports.resolutionHolds(position));

        if (answer_first) {
            try f.acceptor.releaseCapability(lifted, 1);
        } else {
            try f.client().sendBorrowed(.{ .gc_answer = .{ .positions = &.{7} } });
        }
        try f.pump();
        try std.testing.expectEqual(@as(u64, 0), holder.importRefcount(position));
        try std.testing.expectEqual(@as(u64, 0), holder.imports.resolutionHolds(position));
        try std.testing.expectEqual(@as(u64, 0), granter.exports.wireHeld(.from(position.int())));
        try std.testing.expectEqual(@as(usize, 0), holder.import_release_outbox.?.active_batches);
        try f.expectServing();
    }
}

test "a lifted answer that breaks breaks what was queued on it" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();

    try f.ask(7);
    try f.passPromise(7);
    var sent: capture.CapturedRef = .{};
    try f.acceptor.vowOn(Reader.send_vow, .{ .ctx = &sent, .func = capture.CapturedRef.record });
    var listened: capture.CapturedRef = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &listened, .func = capture.CapturedRef.record });

    try f.acceptor.resolverBreak(Greeter.resolver, "no greeting");
    try f.pump();
    try std.testing.expect(sent.broken);
    try std.testing.expectEqualStrings("no greeting", listened.reason_buf[0..listened.reason_len]);
    try f.expectServing();
}

test "a lifted answer survives the partner releasing the question before it settles" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();

    try f.ask(7);
    try f.passPromise(7);
    var listened: capture.CapturedString = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &listened, .func = capture.CapturedString.record });

    const positions = [_]u64{7};
    try f.client().sendBorrowed(.{ .gc_answer = .{ .positions = &positions } });
    try f.pump();
    try f.acceptor.resolverFulfill(Greeter.resolver, .{ .string = "hello" });
    try f.pump();
    try std.testing.expectEqualStrings("hello", listened.text());
    try std.testing.expectEqual(@as(u32, 0), f.liftedAnswers());
    try f.expectServing();
}

test "lifted answers past the session's bound fail the one call and keep the session" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false, .limits = .{ .max_lifted_answers = 1 } });
    defer f.deinit();

    try f.ask(7);
    const first_resolver = Greeter.resolver;
    try f.ask(8);
    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 1), Reader.ran);
    try f.passPromise(8);
    try std.testing.expectEqual(@as(usize, 1), Reader.ran);
    try std.testing.expectEqual(@as(u32, 1), f.liftedAnswers());
    try f.expectServing();

    // The first settlement frees the seat.
    try f.acceptor.resolverFulfill(first_resolver, .{ .string = "hello" });
    try f.pump();
    try f.passPromise(8);
    try std.testing.expectEqual(@as(usize, 2), Reader.ran);
    try std.testing.expectEqual(@as(u32, 1), f.liftedAnswers());
    try f.expectServing();
}

test "closing the session breaks its lifted answers" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();

    try f.ask(7);
    try f.passPromise(7);
    var listened: capture.CapturedRef = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &listened, .func = capture.CapturedRef.record });

    try f.acceptor.releaseSession(f.pair.b);
    try std.testing.expect(listened.broken);
    try std.testing.expectEqual(@as(usize, 0), f.acceptor.pending_inline_gives.count());
}

test "an answer that resolves to another lifted answer follows it to the data" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try f.ask(7);
    const first = Greeter.resolver;
    try f.ask(8);
    const second = Greeter.resolver;
    try f.passPromise(7);
    var first_listened: capture.CapturedString = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &first_listened, .func = capture.CapturedString.record });
    Reader.keep = true;
    try f.passPromise(8);
    const second_promise = Reader.kept orelse return error.NoPromise;
    defer f.acceptor.releaseCapabilityTerminal(second_promise, null);
    try std.testing.expectEqual(@as(u32, 2), f.liftedAnswers());

    // The first answer resolves to the second's promise, which reaches the
    // partner as a projection. The first promise follows the chain onto it.
    try f.acceptor.resolverFulfillValue(first, .{ .capability = second_promise }, arena.allocator());
    try f.pump();
    try std.testing.expect(first_listened.len == 0);
    try std.testing.expectEqual(@as(u32, 2), f.liftedAnswers());
    try f.expectServing();

    // A third answer resolving to the same promise settles to the first
    // promise, which already stands for it.
    try f.ask(9);
    const third = Greeter.resolver;
    try f.passPromise(9);
    var third_listened: capture.CapturedString = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &third_listened, .func = capture.CapturedString.record });
    const third_promise = Reader.kept orelse return error.NoPromise;
    defer f.acceptor.releaseCapabilityTerminal(third_promise, null);
    try f.acceptor.resolverFulfillValue(third, .{ .capability = second_promise }, arena.allocator());
    try f.pump();
    try std.testing.expectEqual(@as(u32, 2), f.liftedAnswers());

    try f.acceptor.resolverFulfill(second, .{ .string = "hello" });
    try f.pump();
    try std.testing.expectEqualStrings("hello", first_listened.text());
    try std.testing.expectEqualStrings("hello", third_listened.text());
    try std.testing.expectEqual(@as(u32, 0), f.liftedAnswers());
    try f.expectServing();

    // The third promise, settled to a promise settled to data, lowers as the data.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var prepared = try f.acceptor.prepareValues(f.pair.b, scratch.allocator(), &.{.{ .capability = third_promise }});
    defer prepared.deinit();
    try std.testing.expectEqualStrings("hello", prepared.values[0].string);
}

test "an answer that resolves to its own lifted promise breaks as a cycle" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false });
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try f.ask(7);
    Reader.keep = true;
    try f.passPromise(7);
    var listened: capture.CapturedRef = .{};
    try f.acceptor.vowOn(Reader.listen_vow, .{ .ctx = &listened, .func = capture.CapturedRef.record });
    const promise = Reader.kept orelse return error.NoPromise;
    defer f.acceptor.releaseCapabilityTerminal(promise, null);

    try f.acceptor.resolverFulfillValue(Greeter.resolver, .{ .capability = promise }, arena.allocator());
    try f.pump();
    try std.testing.expect(listened.broken);
    try std.testing.expectEqualStrings(
        glowcap.ocapn.engine.resolution_chain.cycle_message,
        listened.reason_buf[0..listened.reason_len],
    );
    try std.testing.expectEqual(@as(u32, 0), f.liftedAnswers());
    try f.expectServing();
}

test "a call refused after lifting an answer leaves no lifted answer behind" {
    var f: Fixture = undefined;
    try f.init(.{ .verify_partner = false, .limits = .{ .max_lifted_answers = 1 } });
    defer f.deinit();

    try f.ask(7);
    try f.ask(8);
    try f.passPromises(&.{ 7, 8 });
    try std.testing.expectEqual(@as(usize, 0), Reader.ran);
    try std.testing.expectEqual(@as(u32, 0), f.liftedAnswers());
    try std.testing.expectEqual(@as(usize, 0), f.acceptor.capability_promises.count());
    try f.expectServing();

    // The seat the refused call gave back serves the next.
    try f.passPromise(7);
    try std.testing.expectEqual(@as(usize, 1), Reader.ran);
    try std.testing.expectEqual(@as(u32, 1), f.liftedAnswers());
}
