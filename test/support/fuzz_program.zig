//! The legitimate program a fuzzer drives between two paired peers.
//!
//! Untrusted bytes meet almost no code in a cold session: the tables are
//! empty, so a frame is refused for being out of order and the run ends. The
//! states worth searching, an answer that exists, an import just released, a
//! promise with listeners queued on it, exist only once real traffic has built
//! them. These operations are that traffic. The first target in
//! `engine/fuzz_test.zig` interleaves them with injected bytes and holds each
//! session to its declared bounds, and the second runs them alone and holds
//! the two sessions to each other.
//!
//! Every operation picks its positions from the live tables where that matters,
//! so a release lands on a row the peer holds and a question is one it asked,
//! and swallows a refused send, because a program is free to ask for something
//! the session will not do.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;

/// Which end of the import table a release addresses. The table iterates in
/// hash order, so "the first row" would name a different import from one
/// build to the next. The lowest and highest positions are the same rows every
/// time, and a program that needs one of them can say which.
pub const ImportPick = enum { lowest, highest };

/// The position of some import this peer holds, or null when it holds
/// none. A release for a position nobody holds is refused before it reaches any
/// of the accounting worth exercising. With `releasable_only`, a row the
/// session holds entirely for a release of its own, a pending listener's, is
/// skipped, so the release lands where a caller's may. Without it, that row
/// is exactly the one a release has to be refused on.
pub fn heldImport(peer: *engine.Peer, releasable_only: bool, pick: ImportPick) ?u64 {
    const Found = struct {
        releasable_only: bool,
        pick: ImportPick,
        position: ?u64 = null,
        fn take(self: *@This(), view: glowcap.ocapn.session.ImportView) void {
            if (view.refcount == 0) return;
            if (self.releasable_only and view.session_held == view.refcount) return;
            const candidate = view.position.int();
            const current = self.position orelse {
                self.position = candidate;
                return;
            };
            self.position = switch (self.pick) {
                .lowest => @min(current, candidate),
                .highest => @max(current, candidate),
            };
        }
    };
    var found: Found = .{ .releasable_only = releasable_only, .pick = pick };
    glowcap.ocapn.session.inspect.forEachImport(&peer.session_state, &found, Found.take);
    return found.position;
}

/// The lowest wire position of a question this peer asked and still holds, or
/// null when it holds none. Lowest, for the same reason `heldImport` picks by
/// position rather than table order.
pub fn heldOutboundAnswer(peer: *engine.Peer) ?u64 {
    const Found = struct {
        position: ?u64 = null,
        fn take(self: *@This(), view: glowcap.ocapn.session.AnswerRowView) void {
            const candidate = switch (view.position) {
                .wire => |wire| wire.int(),
                .virtual => return,
            };
            self.position = if (self.position) |current| @min(current, candidate) else candidate;
        }
    };
    var found: Found = .{};
    glowcap.ocapn.session.inspect.forEachOutboundAnswer(&peer.session_state, &found, Found.take);
    return found.position;
}

/// How many steps one drain may take before the peer is treated as stuck.
///
/// `stepToIdle` loops until the peer says idle, and a dispatcher that never says
/// idle would spin here forever. Under a fuzzer that is the worst outcome
/// available: not a finding, not a failure, just a sweep that stops making
/// progress and looks like a slow one. `pairing` bounds its own shuttle for the
/// same reason.
pub const drain_step_cap: usize = 256;

/// Step a peer until it has nothing left to do, or say it is stuck.
///
/// A step refused for memory leaves its work queued for the next step, so
/// the embedder's action is to come back, which the next drain does. Under an
/// allocator that keeps refusing, the peer stays where it is, which is the
/// state those runs then judge.
pub fn stepBounded(peer: *engine.Peer) !void {
    var steps: usize = 0;
    while (steps < drain_step_cap) : (steps += 1) {
        const outcome = peer.step() catch return;
        if (outcome == .idle) return;
    }
    return error.PeerDidNotReachIdle;
}

/// What an embedder does when an inbound door refuses a frame for memory and
/// the frame cannot be offered again: the frame's authority is lost, so the
/// session ends with the cause named, the way the Host condemns under
/// `resource_exhausted`. The abort itself may fail to encode under the same
/// shortage, and then the session still closes.
pub fn condemnForMemory(peer: *engine.Peer) void {
    if (!peer.sessionIsOpen()) return;
    peer.recordFailure(error.OutOfMemory);
    peer.commitAbortOutbound(.{
        .kind = .resource_exhausted,
        .message = "inbound frame refused under memory pressure",
    }) catch peer.closeSession();
}

/// Collect everything the application side owes a release on. A real embedder
/// polls events and drains outbound after every read. Skipping it would report a
/// leak the contract does not have.
pub fn drainApplication(peer: *engine.Peer) !void {
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try stepBounded(peer);
}

/// Move one peer's queued frames into the other, the way a connection would.
/// This is what builds real state: the partner's answers, imports, and listeners
/// only exist because legitimate traffic created them. A frame the receiver
/// refuses is gone, as on a connection, and the ones behind it are still
/// offered: after an abort they meet a closed session and are dropped.
pub fn shuttle(from: *engine.Peer, to: *engine.Peer) void {
    // A send only queues; the frames exist once the sender has stepped.
    // Draining without stepping takes nothing, which quietly means no traffic
    // ever reaches the partner and no state is built on either side. A step
    // the sender cannot finish still leaves the frames it did encode, a closed
    // sender's abort among them, so the drain goes on.
    stepBounded(from) catch {};
    var shuttled: usize = 0;
    while (from.takeOutbound()) |frame_in| : (shuttled += 1) {
        var frame = frame_in;
        if (shuttled % 2 == 1) {
            // The owned door consumes the frame on every outcome, so a
            // refusal for memory has lost it, and the embedder condemns.
            to.feedOwned(frame) catch |err| switch (err) {
                error.OutOfMemory => condemnForMemory(to),
                else => {},
            };
        } else {
            defer frame.deinit();
            // The borrowed door commits nothing when it refuses for memory,
            // so the same bytes are offered once more, the Host's retry. A
            // second refusal is the lasting shortage, and the frame is lost.
            to.recvPacket(frame.bytes()) catch |err| switch (err) {
                error.OutOfMemory => to.recvPacket(frame.bytes()) catch |again| switch (again) {
                    error.OutOfMemory => condemnForMemory(to),
                    else => {},
                },
                else => {},
            };
        }
        drainApplication(to) catch {};
    }
}

/// One legitimate operation, chosen by the fuzzer. These are what build the
/// tables the injected bytes then meet.
pub fn legitimateOp(smith: *std.testing.Smith, actor: *engine.Peer, partner: *engine.Peer) !void {
    switch (smith.valueRangeAtMost(u8, 0, 8)) {
        // Call the partner's bootstrap, which mints an answer on both sides.
        0 => {
            const answer = smith.valueRangeAtMost(u8, 1, 40);
            actor.sendBorrowed(.{ .deliver = .{
                .target = .{ .far = model.FarRef.object(0) },
                .args = &.{.{ .integer = 1 }},
                .answer = model.AnswerPosition.from(answer),
            } }) catch {};
        },
        // Answer one, so the partner grows a resolved answer with listeners.
        1 => {
            const answer = smith.valueRangeAtMost(u8, 1, 40);
            actor.sendBorrowed(.{ .resolve = .{
                .answer = model.AnswerPosition.from(answer),
                .resolution = .{ .fulfill = .{ .integer = 7 } },
            } }) catch {};
        },
        // Watch a promise, the act that queues listener fires. Half the time
        // the listener is an object of this peer's own, so the partner takes a
        // retain it must release beside the fire: the row a release from that
        // side may never spend.
        2 => {
            const answer = smith.valueRangeAtMost(u8, 1, 40);
            const listener: model.Reference = if (smith.valueRangeAtMost(u8, 0, 1) == 1) blk: {
                const position = actor.exportNextObject() catch return;
                break :blk .{ .near = model.NearRef.object(position) };
            } else .{ .far = model.FarRef.object(0) };
            actor.sendBorrowed(.{ .listen = .{
                .target = .{ .promise = .{ .answer_position = model.AnswerPosition.from(answer) } },
                .listener = listener,
                .mode = if (smith.valueRangeAtMost(u8, 0, 1) == 1)
                    .shortening_or_settling
                else
                    .settling_only,
            } }) catch {};
        },
        // Publish an object, so there is something live to deliver to.
        3 => _ = actor.exportNextObject() catch {},
        // Hand the partner a reference. This is the only operation that makes
        // the partner's import table grow, and without it the release below has
        // nothing to release: a `gc-exports` for a position nobody holds is
        // refused as an underflow every single time.
        4 => {
            const answer = smith.valueRangeAtMost(u8, 1, 40);
            // The fresh export can marshal at once. Its first mention is the
            // resolve below, and only a mention the partner receives makes it
            // hold the import: a retain taken here by hand would be a mention
            // the partner never saw, which the agreement check reports.
            const position = actor.exportNextObject() catch return;
            actor.sendBorrowed(.{ .resolve = .{
                .answer = model.AnswerPosition.from(answer),
                .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(position) } } },
            } }) catch {};
        },
        // Release an import the peer actually holds. Picking a position out of
        // the live table is what makes this the real release path, where the
        // refcount and the wire delta have to agree, rather than a refusal.
        5 => {
            const releasable_only = smith.valueRangeAtMost(u8, 0, 3) != 0;
            const pick: ImportPick = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .lowest else .highest;
            const held = heldImport(actor, releasable_only, pick) orelse return;
            const positions = [_]u64{held};
            const deltas = [_]u64{1};
            actor.sendBorrowed(.{ .gc_export = .{
                .positions = positions[0..],
                .deltas = deltas[0..],
            } }) catch {};
        },
        // Let the partner's queued traffic land. This is what turns the
        // reference sent above into an import row on the other side.
        6 => shuttle(partner, actor),
        // Release a question this peer asked, while whatever the engine
        // queued against its answer may still be pending: the same shape as
        // the import release above, one table over.
        7 => {
            const answer = heldOutboundAnswer(actor) orelse return;
            const positions = [_]u64{answer};
            actor.sendBorrowed(.{ .gc_answer = .{ .positions = positions[0..] } }) catch {};
        },
        // A stored resolution naming a partner object keeps that import
        // alive across the application's release, until the answer leaves.
        else => {
            const answer = smith.valueRangeAtMost(u8, 1, 40);
            const position = heldImport(actor, true, .lowest) orelse return;
            actor.sendBorrowed(.{ .resolve = .{
                .answer = model.AnswerPosition.from(answer),
                .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(position) } } },
            } }) catch {};
        },
    }
    try drainApplication(actor);
}

/// Drive the pair until no frame is in flight and neither peer has work, the
/// state every cross-peer comparison is made in. Each round moves both
/// directions and lets the application side release what it was handed,
/// because a release is itself traffic. A pair that is still producing frames
/// after the cap is a dispatcher that never settles, which is a finding, and a
/// peer whose step keeps failing is one that cannot settle, which the caller
/// judges by the allocator it gave the pair.
pub fn settle(p1: *engine.Peer, p2: *engine.Peer) !void {
    var rounds: usize = 0;
    while (rounds < settle_round_cap) : (rounds += 1) {
        shuttle(p1, p2);
        shuttle(p2, p1);
        try drainApplication(p1);
        try drainApplication(p2);
        if (quiescent(p1) and quiescent(p2)) return;
    }
    return error.PairDidNotSettle;
}

/// Whether a peer has nothing left to do: it stepped to idle with no frame
/// queued, or its session is closed and every frame it encoded was taken. A
/// step that fails is work the peer still owes.
pub fn quiescent(peer: *engine.Peer) bool {
    if (peer.sessionIsClosed()) return !peer.hasOutbound();
    var steps: usize = 0;
    while (steps < drain_step_cap) : (steps += 1) {
        const outcome = peer.step() catch return false;
        if (outcome == .idle) return !peer.hasOutbound();
    }
    return false;
}

/// Rounds `settle` allows. Each legitimate operation produces a bounded
/// number of frames, and each reply to one produces fewer, so a pair that
/// has not settled in this many rounds is ping-ponging.
const settle_round_cap: usize = 64;
