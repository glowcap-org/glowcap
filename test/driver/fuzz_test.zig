//! Untrusted-bytes fuzzing of the byte-fed host, against a working application.
//!
//! A language binding and a browser peer do not hand glowcap frames. They hand
//! it whatever came back from a socket read: part of a frame, several frames, or
//! nothing that will ever be a frame. `Host.feedBytes` turns that into sessions,
//! and it is the only owner of the leftover tail between reads, so it carries
//! state across calls that a single-frame decoder never has.
//!
//! Two things make this worth more than feeding a cold session.
//!
//! The read boundaries are the fuzzer's to choose. The same bytes cut in a
//! different place take a different path through the tail coalescing, and a
//! fuzzer that only ever hands over whole buffers never exercises it at all.
//!
//! And the session is doing something. A published capability, a fetch that
//! settled, and calls in flight mean the host has vows, an action queue, and
//! actor state to corrupt. Those tables do not exist until an application has
//! used the connection, which is exactly the state a peer finds in
//! practice and a cold-start fuzzer never reaches.
//!
//! Two properties are checked on every program, and only the first is about
//! crashing. The sealed program adds a third, below.
//!
//! Nothing crashes and nothing leaks, whatever the read boundaries were and
//! whatever the application was in the middle of. Each mutation runs under a
//! fresh `DebugAllocator`, whose teardown fails the mutation on a leak.
//!
//! And every table the session declares a bound for stays inside it. That is
//! the property worth the most: a partner's goal is to make the process hold
//! memory it should not, and a table growing past its declared cap does exactly
//! that without ever crashing. A "no crash" fuzzer would run past it forever.
//!
//! The same application also runs over a sealed channel, which is the wire a
//! production peer sees. There the bytes arrive as records, and a record
//! with any byte changed ends in a refusal that retires the session, or the
//! channel stages the inbound bytes and waits, as a changed length does.
//! `foundation/fuzz_test.zig` holds the property that a changed record never
//! opens at the channel.
//! Validated by injecting a refusal that leaves the session live, which the
//! regression seed catches. It cannot reach a changed record whose tag still
//! verifies, which `foundation/fuzz_test.zig` holds at the channel.
//!
//! A second target, at the end of the file, runs the third-party handoff as a
//! program of honest and damaged receive certificates between three hosts,
//! with `fuzz/handoff.zig` holding the program. Validated by injecting a
//! withdrawal that skips the receive's signature check, which the forged
//! seed caught with a withdrawn gift, and a replay check that accepts a
//! repeated count, which the repeated honest seed caught as a crash of the
//! registry's own invariant. It cannot reach a give forged under an intact
//! receive signature, which takes the recipient's own key and which
//! `engine/cross_peer/authority_test.zig` holds, a give damaged on its way to
//! the recipient, which the recipient's own router refuses before any
//! receive exists, or a receive for a gift whose deposit has not arrived,
//! which the parked-withdraw tests hold.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../support/core_host.zig");
const host_pair = @import("../support/host_pair.zig");
const promise_capture = @import("../support/capture.zig");

/// The caps this target holds the session to, and the check that holds it.
const bounds = @import("../support/session_bounds.zig");
const sealed_pair = @import("../support/sealed_pair.zig");

/// An allocator that runs out of memory where the fuzzer says. The host builds
/// session shells, vows, an action queue, and the stream tail, each with an
/// unwind that only runs when an allocation fails. The span covers a whole open
/// session with an application on it.
const Budget = @import("../support/fuzz_budget.zig").Budget;
const session_span: u16 = 4096;

const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

/// Every shape in the checked-in corpus, so the search starts from bytes that
/// decode instead of rediscovering what a frame looks like.
const seeds = @import("../support/corpus_seeds.zig");
const support_actors = @import("../support/actors.zig");

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{
    // The sealed regime's damaged arm, three flips in a record's body: the
    // search found the session's CapTP state still open after the channel
    // refused, which is the host's retirement rather than a close.
    seeds.seed("") ++ draws(&.{ 0, 0, 0, 1, 3, 0x30, 0x3f, 0x37, 0x26, 0x1e, 0x41 }),
};

/// Ranged draws as the fuzzer reads them: each one is eight little-endian
/// bytes, and a value outside its range falls to the range's low end.
fn draws(comptime values: []const u64) []const u8 {
    const out: [values.len * 8]u8 = comptime blk: {
        var buf: [values.len * 8]u8 = undefined;
        for (values, 0..) |value, i| std.mem.writeInt(u64, buf[i * 8 ..][0..8], value, .little);
        break :blk buf;
    };
    return &out;
}

/// Upper bound on one fuzz input, matching the sibling targets.
const max_input = 4096;

const Counter = support_actors.Counter;

/// Collect everything the embedder owes a release on. A host that is never
/// drained reports as a leak, which would be this harness's bug and not the
/// code's.
/// Every bound the session declares, after any read. A sealed session also
/// never stages more than one record's worth of wire, whatever length a
/// damaged header claims.
fn checkSession(session: *HostSession) !void {
    try bounds.checkDeclared(&session.served.port.peer.session_state);
    if (session.sealed) |channel| {
        try std.testing.expect(channel.staged.len <= max_sealed_unit_bytes);
    }
}

/// The largest unit a sealed channel may hold while waiting for the rest of
/// it: one record header plus the longest body the header can name.
const max_sealed_unit_bytes = glowcap.foundation.noise.record_header_bytes + glowcap.foundation.noise.max_record_bytes;

/// How a session's wire is delimited: an outer stream prefix around each
/// frame, or the sealed channel's own records.
const Wire = enum { stream, sealed };

fn drainHost(host: *Host, session: *HostSession) void {
    while (host.takeAction() catch null) |action| {
        host.freeAction(action);
    }
    while (session.takeOutbound() catch null) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
}

/// Damage a frame the far side really did send, and feed that instead.
///
/// The published capability is only reachable by a frame naming the export
/// position it was actually given, and neither the corpus nor blind mutation
/// ever names it: the corpus hardcodes positions from when it was recorded, and
/// the search space between noise and a valid delivery is the whole wire
/// grammar. A real frame off the dialer names the right positions by
/// construction, so breaking a few of its bytes lands in the near-miss region
/// around a delivery the host would have accepted, which is where a refusal has
/// something to get wrong.
///
/// On a sealed session the frame off the dialer is a record, and the host
/// holds one property more: a record with any byte changed is never opened.
/// Either the channel refuses it and the host retires the session, or a
/// changed length leaves the channel waiting for bytes that never come. The
/// retirement is the host's, not CapTP's: no abort is manufactured, so the
/// session's protocol state is not what closes.
fn feedDamaged(smith: *std.testing.Smith, host: *Host, session: *HostSession, from: *HostSession, wire: Wire) !void {
    var frame = (from.takeOutbound() catch null) orelse return;
    defer frame.deinit();

    const bytes = frame.bytes();
    if (bytes.len == 0 or bytes.len > max_input) return;
    var damaged: [max_input]u8 = undefined;
    @memcpy(damaged[0..bytes.len], bytes);

    // Zero flips is a valid frame arriving out of turn, which is its own case.
    var flips = smith.valueRangeAtMost(u8, 0, 4);
    const changed = flips > 0;
    while (flips > 0) : (flips -= 1) {
        const at = smith.valueRangeAtMost(u16, 0, @intCast(bytes.len - 1));
        damaged[at] ^= smith.valueRangeAtMost(u8, 1, 255);
    }
    switch (wire) {
        .stream => {
            var stream_bytes: [max_input + glowcap.foundation.stream_framing.prefix_buffer_bytes]u8 = undefined;
            var prefix_buf: [glowcap.foundation.stream_framing.prefix_buffer_bytes]u8 = undefined;
            const prefix = glowcap.foundation.stream_framing.renderPrefix(&prefix_buf, bytes.len);
            @memcpy(stream_bytes[0..prefix.len], prefix);
            @memcpy(stream_bytes[prefix.len..][0..bytes.len], damaged[0..bytes.len]);
            host.feedBytes(session, stream_bytes[0 .. prefix.len + bytes.len]) catch {};
        },
        .sealed => host.feedBytes(session, damaged[0..bytes.len]) catch {},
    }
    drainHost(host, session);
    try checkSession(session);
    if (wire == .sealed and changed) {
        const channel = session.sealed.?;
        const refused = !channel.isOpen() and session.isTerminating();
        try std.testing.expect(refused or channel.hasStagedInbound());
    }
}

/// Feed `input` to `session` in `chunk` sized pieces, draining after each, the
/// way an embedder's read loop does. A chunk of zero means the whole buffer at
/// once.
fn feedChunked(host: *Host, session: *HostSession, input: []const u8, chunk: usize) !void {
    if (chunk == 0) {
        host.feedBytes(session, input) catch {};
        drainHost(host, session);
        try checkSession(session);
        return;
    }
    var at: usize = 0;
    while (at < input.len) {
        const end = @min(at + chunk, input.len);
        host.feedBytes(session, input[at..end]) catch {
            // A refusal condemns the session; there is nothing more to feed.
            drainHost(host, session);
            return;
        };
        drainHost(host, session);
        // After every read, not only at the end: a table that overflows and is
        // then trimmed back would slip past an end-of-program check, and the
        // window where it was over the cap is the window a peer holds the
        // memory.
        try checkSession(session);
        at = end;
    }
}

fn hostFeedOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    // Let the fuzzer choose where the read boundaries fall. Small sizes are the
    // interesting ones, because that is where a frame straddles two feeds.
    const chunk: usize = smith.valueRangeAtMost(u8, 0, 64);
    var backing: std.heap.DebugAllocator(.{
        .stack_trace_frames = 0,
        .resize_stack_traces = false,
    }) = .init;
    var budget = Budget.drawWith(smith, session_span, backing.allocator());
    const gpa = budget.allocator();

    const result = hostFeedOneWithAllocator(smith, input, chunk, gpa);
    if (backing.deinit() == .leak) return error.FuzzAllocatorLeak;
    return result;
}

fn hostFeedOneWithAllocator(
    smith: *std.testing.Smith,
    input: []const u8,
    chunk: usize,
    gpa: std.mem.Allocator,
) !void {

    // Accepted but still negotiating: the handshake regime, where almost
    // everything is refused.
    {
        var host = test_host.init(gpa, @as([32]u8, @splat(0x11)), .{ .limits = bounds.tight });
        defer host.deinit();
        const session = host_pair.publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9000", &.{}) catch return;
        drainHost(&host, session);
        try feedChunked(&host, session, input, chunk);
    }

    // Open, with an application on it. This is the regime with vows, an action
    // queue, and actor state that untrusted bytes can find in an awkward moment.
    {
        // Partner verification is off here and on in the block above. Up there
        // the session is still negotiating, so the fuzzed bytes can reach the
        // hello and its signature check. Down here they arrive after the
        // handshake, so the two verifications are unreachable from the input,
        // and they were most of what each iteration spent its time on.
        var dialer = test_host.init(gpa, @as([32]u8, @splat(0x22)), .{ .limits = bounds.tight, .verify_partner = false });
        defer dialer.deinit();
        var acceptor = test_host.init(gpa, @as([32]u8, @splat(0x33)), .{ .limits = bounds.tight, .verify_partner = false });
        defer acceptor.deinit();
        const pair = host_pair.openPair(&dialer, &acceptor, "127.0.0.1:9001") catch return;

        _ = pair.b.served.publish(&pair.b.host.vat, "counter", Counter, .{}) catch return;
        const fetched = dialer.fetch(pair.a, "counter") catch return;
        var captured = promise_capture.CapturedRef{};
        dialer.vowOn(fetched, .{ .ctx = &captured, .func = promise_capture.CapturedRef.record }) catch return;
        host_pair.pumpToQuiescence(&.{pair}) catch return;

        // Leave a call in flight: sent, not pumped. The vow is
        // unsettled when the untrusted bytes arrive, so the settle path and the
        // refusal path meet in whatever order the fuzzer picks rather than the
        // tidy one. Its frame is also what `feedDamaged` breaks, and that
        // frame carries a delivery as far as the published capability.
        if (captured.ref) |cap| {
            _ = dialer.send(pair.a, cap, .{ .verb = "hit", .args = &.{} }) catch {};
        }
        drainHost(&acceptor, pair.b);

        if (smith.valueRangeAtMost(u8, 0, 1) == 1) {
            try feedDamaged(smith, &acceptor, pair.b, pair.a, .stream);
        } else {
            try feedChunked(&acceptor, pair.b, input, chunk);
        }
        drainHost(&dialer, pair.a);
    }

    // The same open application over a sealed channel, which is the wire a
    // production peer sees. The bytes arrive as records, so the cleartext
    // parsers above are unreachable until the channel has opened a record,
    // and what is under test is the host's handling of a channel that refuses
    // in the middle of an application.
    {
        var dialer = sealed_pair.sealedHost(gpa, @splat(0x44), 0x45, .{ .limits = bounds.tight });
        defer dialer.deinit();
        var acceptor = sealed_pair.sealedHost(gpa, @splat(0x55), 0x56, .{ .limits = bounds.tight });
        defer acceptor.deinit();
        const pair = sealed_pair.openSealedPair(gpa, &dialer, @splat(0x44), &acceptor, @splat(0x55), null, null) catch return;

        _ = pair.b.served.publish(&pair.b.host.vat, "counter", Counter, .{}) catch return;
        const fetched = dialer.fetch(pair.a, "counter") catch return;
        var captured = promise_capture.CapturedRef{};
        dialer.vowOn(fetched, .{ .ctx = &captured, .func = promise_capture.CapturedRef.record }) catch return;
        sealed_pair.pumpSealedPair(gpa, pair, null, null) catch return;

        if (captured.ref) |cap| {
            _ = dialer.send(pair.a, cap, .{ .verb = "hit", .args = &.{} }) catch {};
        }
        drainHost(&acceptor, pair.b);

        if (smith.valueRangeAtMost(u8, 0, 1) == 1) {
            try feedDamaged(smith, &acceptor, pair.b, pair.a, .sealed);
        } else {
            try feedChunked(&acceptor, pair.b, input, chunk);
        }
        drainHost(&dialer, pair.a);
    }
}

test "fuzz: arbitrary read boundaries never crash or leak a working host session" {
    const gpa = std.testing.allocator;

    // The application has to really be running, otherwise this target quietly
    // becomes the cold-start one and nothing says so.
    {
        var dialer = test_host.init(gpa, @as([32]u8, @splat(0x22)), .{ .limits = bounds.tight });
        defer dialer.deinit();
        var acceptor = test_host.init(gpa, @as([32]u8, @splat(0x33)), .{ .limits = bounds.tight });
        defer acceptor.deinit();
        const pair = try host_pair.openPair(&dialer, &acceptor, "127.0.0.1:9001");
        _ = try pair.b.served.publish(&pair.b.host.vat, "counter", Counter, .{});
        const fetched = try dialer.fetch(pair.a, "counter");
        var captured = promise_capture.CapturedRef{};
        try dialer.vowOn(fetched, .{ .ctx = &captured, .func = promise_capture.CapturedRef.record });
        try host_pair.pumpToQuiescence(&.{pair});

        // The fetch has to actually hand back the capability, otherwise the
        // call below never happens and no frame ever names the published
        // object, which is the one frame that reaches the vat at all.
        try std.testing.expect(captured.ref != null);
        _ = try dialer.send(pair.a, captured.ref.?, .{ .verb = "hit", .args = &.{} });
        const outbound = try pair.a.takeOutbound();
        try std.testing.expect(outbound != null);
        if (outbound) |f_in| {
            var f = f_in;
            f.deinit();
        }
        drainHost(&dialer, pair.a);
        drainHost(&acceptor, pair.b);
    }

    // Every shape in the corpus, not a hand-picked few: a shape the search
    // never starts from is a shape it will almost certainly never build.
    try std.testing.fuzz({}, hostFeedOne, .{ .corpus = (seeds.all ++ regression_seeds)[0..] });
}

const handoff = @import("fuzz/handoff.zig");

/// Certificate programs the fuzzer found here, separate from the read-boundary
/// `regression_seeds` above because a saved program means nothing to the
/// byte-feeding target and saved bytes mean nothing to the program.
const handoff_regression_seeds = [_][]const u8{
    // Two flips of the same bit, which is the verbatim receive again: the
    // program once judged it as damaged.
    handoffSeed(&.{&.{ handoff.act_damaged, 2, 0, 1, 0, 1, 0, 1 }}),
};

/// A handoff seed: the opening allocation draw, then rows of action, flip
/// count, and three position and mask pairs.
fn handoffSeed(comptime rows: []const []const u64) []const u8 {
    return &(comptime [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }) ++ seeds.program(rows);
}

const handoff_seeds = [_][]const u8{
    // The verbatim receive, then the same receive again: a replay.
    handoffSeed(&.{ &.{ handoff.act_honest, 1, 0, 1, 0, 1, 0, 1 }, &.{ handoff.act_honest, 1, 0, 1, 0, 1, 0, 1 } }),
    // A bit of the receive's signature, then two more, each with the rest
    // of the certificate intact, then the verbatim receive.
    handoffSeed(&.{ &.{ handoff.act_forge, 1, 7, 1, 0, 1, 0, 1 }, &.{ handoff.act_forge, 2, 3, 0x80, 40, 1, 0, 1 }, &.{ handoff.act_honest, 1, 0, 1, 0, 1, 0, 1 } }),
    // A byte of the envelope's syntax, which tears the session down, then
    // the verbatim receive the exporter can no longer take. status-allow: lifecycle transition
    handoffSeed(&.{ &.{ handoff.act_damaged, 1, 120, 1, 0, 1, 0, 1 }, &.{ handoff.act_honest, 1, 0, 1, 0, 1, 0, 1 } }),
};

test "fuzz: no program of honest and damaged receive certificates withdraws a gift without the exact honest one" {
    // Each seed is judged by where it leaves the gift, in the order the
    // program draws it, so a row whose draws drift from its arm is noticed.
    const gpa = std.testing.allocator;
    const replayed = try handoff.replay(gpa, handoff_seeds[0]);
    defer replayed.deinit();
    try std.testing.expect(replayed.withdrawn and !replayed.giftLive());
    try std.testing.expect(replayed.redeemed.ref != null);
    try std.testing.expect(replayed.r_to_e.b.sessionOpen());
    const guarded = try handoff.replay(gpa, handoff_seeds[1]);
    defer guarded.deinit();
    try std.testing.expect(guarded.attacked and guarded.withdrawn and !guarded.giftLive());
    try std.testing.expect(guarded.redeemed.ref == null and guarded.redeemed.broken);
    const torn = try handoff.replay(gpa, handoff_seeds[2]);
    defer torn.deinit();
    try std.testing.expect(torn.attacked and !torn.withdrawn and torn.giftLive());
    try std.testing.expect(torn.redeemed.ref == null);

    try std.testing.fuzz({}, handoffOne, .{ .corpus = (handoff_seeds ++ handoff_regression_seeds)[0..] });
}

fn handoffOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var backing: std.heap.DebugAllocator(.{
        .stack_trace_frames = 0,
        .resize_stack_traces = false,
    }) = .init;
    var budget = Budget.drawWith(smith, handoff.span, backing.allocator());
    const gpa = budget.allocator();
    const result = handoffOneWithAllocator(smith, &budget, gpa);
    if (backing.deinit() == .leak) return error.FuzzAllocatorLeak;
    return result;
}

fn handoffOneWithAllocator(smith: *std.testing.Smith, budget: *Budget, gpa: std.mem.Allocator) !void {
    // Every error out of the build or a step is a property that did not
    // hold, unless the allocation failure this run asked for has happened:
    // a host under pressure keeps its work queued rather than failing the
    // verb, so from then on the frames and effects a property reads may
    // simply not have happened yet. status-allow: pending state or quoted runtime label
    const trio = handoff.Trio.init(gpa) catch |err| return afterInducedFailure(budget, err);
    defer trio.deinit();
    handoff.run(smith, trio) catch |err| return afterInducedFailure(budget, err);
}

fn afterInducedFailure(budget: *Budget, err: anyerror) anyerror!void {
    if (budget.failed()) return;
    return err;
}
