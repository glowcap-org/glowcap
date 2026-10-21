//! Untrusted-bytes fuzzing of the whole inbound path, against live session state.
//!
//! The codec fuzzers next door stop at decode. This one starts where a
//! transport hands over a frame: bytes go into `Peer.recvBorrowed`, which
//! copies them behind a frame head, decodes once into it, runs session
//! validation, applies to the session tables, and surfaces events. Every layer
//! the protocol has is downstream of that call. The owned door takes its turn
//! as well: a shuttled frame enters through `Peer.feedOwned` on every second
//! frame, and an injected chunk is lifted into an owned frame first when its
//! first byte is even. Stream boundaries are the envelope's, and
//! `test/net/fuzz_test.zig` searches those.
//!
//! What makes it worth more than a decode fuzzer is the state underneath. A
//! cold peer has empty tables, so untrusted bytes meet almost no code: they are
//! refused for being out of order and the run ends. The interesting bugs live
//! where a message is *plausible*, an answer position that exists, an import
//! that was just released, a promise with listeners already queued on it, and
//! none of those states exist until real traffic has built them.
//!
//! So the fuzzer drives a program rather than a buffer. Each step it chooses
//! either to run a legitimate operation between two paired peers, which grows
//! the tables, or to inject a chunk of its own bytes into whichever peer it
//! likes. Over a few dozen steps that reaches sessions with live answers,
//! exports, imports, and listeners, and then feeds them untrusted bytes.
//!
//! Three properties are checked, and only the first is about crashing.
//!
//! Nothing crashes and nothing leaks, whatever the program was. Everything runs
//! under `std.testing.allocator`, which fails the test on either.
//!
//! A refusal leaves the session in one terminal state with nothing further
//! to apply, and a chunk the peer accepted surfaces through events that read
//! the retained frame, never the injected buffer.
//!
//! And every table the session declares a bound for stays inside it. This is
//! the property worth the most here. A partner's whole goal is to make the
//! process hold memory it should not, and a table that grows past its declared
//! cap does exactly that without ever crashing, a "no crash" fuzzer will run
//! past it forever. `test/support/session_bounds.zig` owns both the caps and
//! the check, and this reads the counts back after every step.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const pairing = engine.pairing;

/// An allocator that runs out of memory where the fuzzer says. A session's
/// tables, queues, and answer rows are built a step at a time, and every one of
/// those steps has an unwind that only runs when an allocation fails. The span
/// covers a whole open session, so the failure can land during the handshake,
/// during a legitimate operation, or halfway through applying a damaged frame.
const Budget = @import("../support/fuzz_budget.zig").Budget;

/// The caps this target holds the session to, and the check that holds it.
const bounds = @import("../support/session_bounds.zig");
const session_span: u16 = 4096;

/// Every shape in the checked-in corpus, so the search starts from bytes that
/// decode instead of rediscovering what a frame looks like.
const seeds = @import("../support/corpus_seeds.zig");

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one. A finding is kept as the program written out in draws rather
/// than the bytes the fuzzer saved: the bytes mean a program only under the
/// exact draws the operations make, and one added draw silently turns a saved
/// crash into a program that does something else.
const regression_seeds = [_][]const u8{
    resolverRetainReleasedProgram(),
};

/// A program written out draw by draw, for a state the search is not owed to
/// find on its own. `step` opens one loop iteration (an empty chunk, then
/// "not the end"). The draws after it are the iteration's own, in the order
/// `programOne` and `legitimateOp` make them.
const Program = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,

    fn draw(self: *Program, value: u64) void {
        std.mem.writeInt(u64, self.bytes[self.len..][0..8], value, .little);
        self.len += 8;
    }

    fn step(self: *Program) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], 0, .little);
        self.bytes[self.len + 4] = 0;
        self.len += 5;
    }

    fn end(self: *Program) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], 0, .little);
        self.bytes[self.len + 4] = 1;
        self.len += 5;
    }
};

/// The fuzzer's first finding here, kept as the program that reaches it. The
/// pair speaks V1.0, so p1's question carries a resolver p2 imports and holds
/// for its settlement. p2 releases that import as if it were the
/// application's, then answers: the callback still addresses the row, and
/// `importRequiresWireRelease` asserts it is there. The release has to be
/// refused instead. Validated against the defect by returning
/// `ImportTable.releasable` and `ImportTable.decrement` to the bare count,
/// which lets the release through and lands the callback on the assertion.
///
/// The listener's retain has the same shape and the same fix, but its fire is
/// refused with a typed `InvalidReference` rather than a crash, which this
/// target's properties cannot see. `test/engine/listener_fire_budget_test.zig`
/// pins that case directly.
fn resolverRetainReleasedProgram() []const u8 {
    const entry = comptime blk: {
        var p: Program = .{};
        // No allocation failure this run.
        p.draw(0);
        // p1 asks p2's bootstrap a question, opening answer 3 on p2 with the
        // resolver p1 minted for it.
        p.step();
        p.draw(0);
        p.draw(0);
        p.draw(0);
        p.draw(3);
        // p2 takes the question.
        p.step();
        p.draw(1);
        p.draw(0);
        p.draw(6);
        // p2 releases its lowest import, releasable or not: the resolver.
        p.step();
        p.draw(1);
        p.draw(0);
        p.draw(5);
        p.draw(0);
        p.draw(0);
        // p2 answers 3, and the callback addresses the resolver's row.
        p.step();
        p.draw(1);
        p.draw(0);
        p.draw(1);
        p.draw(3);
        p.end();
        break :blk p.bytes[0..p.len].*;
    };
    return &entry;
}

/// Upper bound on one injected chunk.
const max_chunk = 1024;
/// How many operations one program runs. Enough to build real tables. Bounded so
/// a single input cannot spend the whole budget.
const max_steps = 48;

/// The draw that injects the fuzzer's own bytes, out of `0...4`.
const inject_draw: u8 = 3;
/// The draw that injects a real frame with a few bytes broken.
const damaged_draw: u8 = 4;

/// One corpus frame turned into a one-step program: inject these bytes into p1.
///
/// A seed is read as the draws the loop makes, in order, so it has to carry all
/// of them. Handing over only the frame leaves nothing for the draws after it,
/// and the end-of-input check answers "stop", a seed that looks like a frame
/// and runs no steps at all.
fn programSeed(comptime frame: []const u8) []const u8 {
    const entry = comptime blk: {
        var out: [8 + 4 + frame.len + 1 + 8 + 8]u8 = undefined;
        // The out-of-memory point the run opens with, before the loop starts.
        // Leaving it out shifted every draw below by eight bytes, which is how
        // a seed stops encoding the program its comment describes.
        std.mem.writeInt(u64, out[0..8], 0, .little);
        // The chunk: a length, then the bytes.
        std.mem.writeInt(u32, out[8..][0..4], @as(u32, @intCast(frame.len)), .little);
        @memcpy(out[12..][0..frame.len], frame);
        var at = 12 + frame.len;
        // Not the end of the program.
        out[at] = 0;
        at += 1;
        // Act on p1.
        std.mem.writeInt(u64, out[at..][0..8], 0, .little);
        at += 8;
        // Inject, rather than run a legitimate operation.
        std.mem.writeInt(u64, out[at..][0..8], inject_draw, .little);
        break :blk out;
    };
    return &entry;
}

/// Every corpus frame as a one-step injection program.
const program_seeds = blk: {
    var built: [seeds.message_seeds.len][]const u8 = undefined;
    for (seeds.message_seeds, 0..) |entry, i| {
        // A corpus seed is already a length then the frame; the frame is what
        // this rebuilds around.
        built[i] = programSeed(entry[4..]);
    }
    break :blk built;
};

/// Which end of the import table a release addresses. The table iterates in
/// hash order, so "the first row" would name a different import from one
/// build to the next. The lowest and highest positions are the same rows every
/// time, and a program that needs one of them can say which.
const ImportPick = enum { lowest, highest };

/// The position of some import this peer holds, or null when it holds
/// none. A release for a position nobody holds is refused before it reaches any
/// of the accounting worth exercising. With `releasable_only`, a row the
/// session holds entirely for a release of its own, a pending listener's, is
/// skipped, so the release lands where a caller's may. Without it, that row
/// is exactly the one a release has to be refused on.
fn heldImport(peer: *engine.Peer, releasable_only: bool, pick: ImportPick) ?u64 {
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
fn heldOutboundAnswer(peer: *engine.Peer) ?u64 {
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
const drain_step_cap: usize = 256;

/// Step a peer until it has nothing left to do, or say it is stuck.
fn stepBounded(peer: *engine.Peer) !void {
    var steps: usize = 0;
    while (steps < drain_step_cap) : (steps += 1) {
        const outcome = peer.step() catch return;
        if (outcome == .idle) return;
    }
    return error.PeerDidNotReachIdle;
}

/// Collect everything the application side owes a release on. A real embedder
/// polls events and drains outbound after every read. Skipping it would report a
/// leak the contract does not have.
fn drainApplication(peer: *engine.Peer) !void {
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try stepBounded(peer);
}

/// Move one peer's queued frames into the other, the way a connection would.
/// This is what builds real state: the partner's answers, imports, and listeners
/// only exist because legitimate traffic created them.
fn shuttle(from: *engine.Peer, to: *engine.Peer) void {
    // A send only queues; the frames exist once the sender has stepped. Draining
    // without stepping takes nothing, which quietly means no traffic ever
    // reaches the partner and no state is built on either side.
    stepBounded(from) catch return;
    var shuttled: usize = 0;
    while (from.takeOutbound()) |frame_in| : (shuttled += 1) {
        var frame = frame_in;
        if (shuttled % 2 == 1) {
            // The owned door consumes the frame on every outcome.
            to.feedOwned(frame) catch return;
        } else {
            defer frame.deinit();
            to.recvPacket(frame.bytes()) catch return;
        }
        drainApplication(to) catch return;
    }
}

/// Feed the fuzzer's own bytes in as one frame, through whichever door its
/// first byte picks.
fn inject(peer: *engine.Peer, bytes: []const u8) !void {
    var scratch: [max_chunk]u8 = undefined;
    const valid: usize = @min(bytes.len, scratch.len);
    @memcpy(scratch[0..valid], bytes[0..valid]);
    if (valid == 0) return;

    if (scratch[0] & 1 == 1) {
        // The borrowed door takes the chunk as one whole frame and copies it
        // behind a head before it decodes. A refusal is a legitimate answer to
        // untrusted bytes; the session is condemned and there is nothing
        // further to apply.
        peer.recvBorrowed(.{ .bytes = scratch[0..valid], .shape = .byte }) catch {};
    } else {
        // The owned door consumes the frame on every outcome.
        const frame = engine.ownedFrameFromView(std.testing.allocator, .{ .bytes = scratch[0..valid], .shape = .byte }) catch return;
        peer.feedOwned(frame) catch {};
    }
    // The transport's buffer is gone before the application drains.
    @memset(scratch[0..valid], 'x');
    try drainApplication(peer);
}

/// A frame the session really would have accepted, with a few bytes broken.
///
/// This is the only way past validation. The corpus names fixed positions,
/// export seven, answer eleven, and a live session holds whatever it happened
/// to mint, so a corpus frame is refused for naming a table row that does not
/// exist, every time, however the bytes are mutated around it. Blind mutation
/// will not build a valid frame naming a live position either: the search space
/// is the whole grammar, and the signal for "this position exists" is one branch
/// behind a lookup.
///
/// So the frame is produced by the partner, which means it names positions this
/// session actually holds, and then damaged. The near-miss region around a valid
/// frame is where the interesting refusals live, and it is unreachable from
/// noise.
fn injectDamagedFrame(smith: *std.testing.Smith, actor: *engine.Peer, partner: *engine.Peer) !void {
    // Make the partner say something first. Waiting for it to have traffic
    // queued would mean this arm usually found nothing and did nothing.
    try legitimateOp(smith, partner, actor);
    try stepBounded(partner);
    var frame = partner.takeOutbound() orelse return;
    defer frame.deinit();

    const bytes = frame.bytes();
    if (bytes.len == 0 or bytes.len > max_chunk) return;
    var damaged: [max_chunk]u8 = undefined;
    @memcpy(damaged[0..bytes.len], bytes);

    // Zero flips is a legitimate frame arriving out of turn, which is its own
    // interesting case; a handful is a near miss.
    var flips = smith.valueRangeAtMost(u8, 0, 4);
    while (flips > 0) : (flips -= 1) {
        const at = smith.valueRangeAtMost(u16, 0, @intCast(bytes.len - 1));
        damaged[at] ^= smith.valueRangeAtMost(u8, 1, 255);
    }
    try inject(actor, damaged[0..bytes.len]);
}

/// One legitimate operation, chosen by the fuzzer. These are what build the
/// tables the injected bytes then meet.
fn legitimateOp(smith: *std.testing.Smith, actor: *engine.Peer, partner: *engine.Peer) !void {
    switch (smith.valueRangeAtMost(u8, 0, 7)) {
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
                actor.session_state.registerExport(model.ExportPosition.from(position)) catch return;
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
            // Allocating a position only reserves it. The partner cannot be
            // handed a reference to it until the export row exists, so grant it
            // here, otherwise every send below is refused as an unknown
            // reference and the import table never grows at all.
            const position = actor.exportNextObject() catch return;
            actor.session_state.registerExport(model.ExportPosition.from(position)) catch return;
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
        else => {
            const answer = heldOutboundAnswer(actor) orelse return;
            const positions = [_]u64{answer};
            actor.sendBorrowed(.{ .gc_answer = .{ .positions = positions[0..] } }) catch {};
        },
    }
    try drainApplication(actor);
}

fn programOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var budget = Budget.draw(smith, session_span);
    const gpa = budget.allocator();

    // The handshake itself allocates, so a low failure point ends the run right
    // here. That case is worth running too: a half-built pair still has to tear
    // down without leaking.
    //
    // Syrup, because that is what the seed corpus is written in. A pair that
    // negotiated the other codec refuses every seed at its first byte, and the
    // whole corpus becomes noise with nothing to say so.
    var pair = pairing.pairedWithLimits(gpa, .syrup, bounds.tight) catch return;
    defer pair.deinit();

    var chunk: [max_chunk]u8 = undefined;
    var step: usize = 0;
    while (step < max_steps) : (step += 1) {
        // The chunk is drawn first because that is how a seed is framed: a
        // length then the bytes. Draw anything else first and a corpus entry is
        // read as that instead, which quietly turns every seed into a program
        // that does nothing at all.
        const len = smith.slice(&chunk);
        if (smith.eos()) break;

        // Which peer this step acts on. Driving untrusted bytes into both sides
        // of one session reaches states neither side reaches alone.
        const on_p1 = smith.valueRangeAtMost(u8, 0, 1) == 0;
        const actor = if (on_p1) &pair.p1 else &pair.p2;
        const partner = if (on_p1) &pair.p2 else &pair.p1;

        // Untrusted bytes condemn a session, and every later operation on a
        // condemned pair is refused and swallowed. Stopping there spends the
        // rest of the budget on building state somewhere else instead of on
        // forty no-op steps.
        if (!pair.p1.sessionIsOpen() and !pair.p2.sessionIsOpen()) break;

        // Weighted towards legitimate traffic: bytes injected into an empty
        // session are refused immediately and teach the fuzzer nothing, so the
        // state has to get built before injection teaches anything.
        //
        // The two injection draws are the top of the range, not the bottom.
        // When a draw runs past the input the generator falls back to the low
        // end, so putting injection at zero would have made the fallback
        // inject, the opposite of what the weighting is for.
        switch (smith.valueRangeAtMost(u8, 0, 4)) {
            damaged_draw => try injectDamagedFrame(smith, actor, partner),
            inject_draw => try inject(actor, chunk[0..len]),
            else => try legitimateOp(smith, actor, partner),
        }

        // After every step, not only at the end: a table that overflows and is
        // then trimmed back would slip past an end-of-program check, and the
        // window where it was over the cap is exactly the window a peer
        // holds the memory.
        try bounds.checkDeclared(&pair.p1.session_state);
        try bounds.checkDeclared(&pair.p2.session_state);
    }

    shuttle(&pair.p1, &pair.p2);
    shuttle(&pair.p2, &pair.p1);
    try drainApplication(&pair.p1);
    try drainApplication(&pair.p2);
    while (pair.p1.takeOutbound()) |f_in| {
        var f = f_in;
        f.deinit();
    }
    while (pair.p2.takeOutbound()) |f_in| {
        var f = f_in;
        f.deinit();
    }
}

test "fuzz: no program of operations and untrusted bytes crashes or leaks a session" {
    // The pair has to really open, otherwise every program runs against a cold
    // peer and the whole point of this target is gone with no failing test to
    // say so.
    {
        var pair = try pairing.pairedWithLimits(std.testing.allocator, .syrup, bounds.tight);
        defer pair.deinit();
        try std.testing.expect(pair.p1.session_state.handshakeComplete());
    }

    // The operations have to do what their comments claim. Handing the partner
    // a reference is the only one that grows an import table, and the release
    // after it is refused as an underflow unless that worked, which is how it
    // behaved before, silently, on every single step.
    {
        var pair = try pairing.pairedWithLimits(std.testing.allocator, .syrup, bounds.tight);
        defer pair.deinit();

        // A resolve answers a question somebody asked, so the question comes
        // first: p2 calls p1's bootstrap, which opens an answer on p1.
        try pair.p2.sendBorrowed(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{.{ .integer = 1 }},
            .answer = model.AnswerPosition.from(1),
        } });
        shuttle(&pair.p2, &pair.p1);

        // Now p1 can answer it with a reference to something it holds, and that
        // reference is what becomes an import row on p2.
        const position = try pair.p1.exportNextObject();
        try pair.p1.session_state.registerExport(model.ExportPosition.from(position));
        try pair.p1.sendBorrowed(.{ .resolve = .{
            .answer = model.AnswerPosition.from(1),
            .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(position) } } },
        } });
        shuttle(&pair.p1, &pair.p2);

        try drainApplication(&pair.p1);
        try drainApplication(&pair.p2);
        while (pair.p1.takeOutbound()) |f_in| {
            var f = f_in;
            f.deinit();
        }
        while (pair.p2.takeOutbound()) |f_in| {
            var f = f_in;
            f.deinit();
        }
        try std.testing.expect(heldImport(&pair.p2, true, .lowest) != null);
    }

    // The damaged-frame arm has to produce a frame. If the partner never has
    // anything queued the arm silently does nothing, which is the same shape as
    // an operation that is always refused: invisible, and worth nothing.
    {
        var pair = try pairing.pairedWithLimits(std.testing.allocator, .syrup, bounds.tight);
        defer pair.deinit();
        pair.p2.sendBorrowed(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(0) },
            .args = &.{.{ .integer = 1 }},
            .answer = model.AnswerPosition.from(1),
        } }) catch unreachable;
        pair.p2.stepToIdle() catch unreachable;
        var frame = pair.p2.takeOutbound() orelse return error.PartnerQueuedNothing;
        defer frame.deinit();
        try std.testing.expect(frame.bytes().len > 0);
    }

    // A seed that does not carry a whole step runs a program of length zero.
    // Checking only that the chunk draw succeeds is not enough, and looked
    // enough: the chunk draw eats the entire entry, and the end-of-input check
    // right after it answers "stop" for an input with nothing left. Replay the
    // real loop head instead, and require a step out of every seed.
    // Replayed through the real loop head, in the order `programOne` draws it.
    // A guard that names the draws by hand goes stale the moment one is added
    // above it.
    for (&program_seeds, 0..) |entry, i| {
        var reader: std.testing.Smith = .{ .in = entry };
        var probe: [max_chunk]u8 = undefined;
        _ = Budget.draw(&reader, session_span);
        _ = reader.slice(&probe);
        std.testing.expect(!reader.eos()) catch |err| {
            std.debug.print("seed {d} stops before its first step\n", .{i});
            return err;
        };
    }

    try std.testing.fuzz({}, programOne, .{ .corpus = (program_seeds ++ regression_seeds)[0..] });
}
