//! Hostile-bytes fuzzing of the byte-fed host, against a working application.
//!
//! A language binding and a browser peer do not hand pancake frames. They hand
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
//! used the connection, which is exactly the state an attacker finds in
//! practice and a cold-start fuzzer never reaches.
//!
//! Two properties are checked, and only the first is about crashing.
//!
//! Nothing crashes and nothing leaks, whatever the read boundaries were and
//! whatever the application was in the middle of. Each mutation runs under a
//! fresh `DebugAllocator`, whose teardown fails the mutation on a leak.
//!
//! And every table the session declares a bound for stays inside it. That is
//! the property worth the most: a partner's goal is to make the process hold
//! memory it should not, and a table growing past its declared cap does exactly
//! that without ever crashing. A "no crash" fuzzer would run past it forever.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");
const host_pair = @import("../support/host_pair.zig");
const promise_capture = @import("../support/capture.zig");

/// The caps this target holds the session to, and the check that holds it.
const bounds = @import("../support/session_bounds.zig");

/// An allocator that runs out of memory where the fuzzer says. The host builds
/// session shells, vows, an action queue, and the stream tail, each with an
/// unwind that only runs when an allocation fails. The span covers a whole open
/// session with an application on it.
const Budget = @import("../support/fuzz_budget.zig").Budget;
const session_span: u16 = 4096;

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

/// Every shape in the checked-in corpus, so the search starts from bytes that
/// decode instead of rediscovering what a frame looks like.
const seeds = @import("../support/corpus_seeds.zig");

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

/// Upper bound on one fuzz input, matching the sibling targets.
const max_input = 4096;

/// Something for the far side to call, so the session carries real work rather
/// than an empty handshake.
const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};

/// Collect everything the embedder owes a release on. A host that is never
/// drained reports as a leak, which would be this harness's bug and not the
/// code's.
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
fn feedDamaged(smith: *std.testing.Smith, host: *Host, session: *HostSession, from: *HostSession) !void {
    var frame = (from.takeOutbound() catch null) orelse return;
    defer frame.deinit();

    const bytes = frame.bytes();
    if (bytes.len == 0 or bytes.len > max_input) return;
    var damaged: [max_input]u8 = undefined;
    @memcpy(damaged[0..bytes.len], bytes);

    // Zero flips is a valid frame arriving out of turn, which is its own case.
    var flips = smith.valueRangeAtMost(u8, 0, 4);
    while (flips > 0) : (flips -= 1) {
        const at = smith.valueRangeAtMost(u16, 0, @intCast(bytes.len - 1));
        damaged[at] ^= smith.valueRangeAtMost(u8, 1, 255);
    }
    var stream_bytes: [max_input + pancake.foundation.stream_framing.prefix_buffer_bytes]u8 = undefined;
    var prefix_buf: [pancake.foundation.stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = pancake.foundation.stream_framing.renderPrefix(&prefix_buf, bytes.len);
    @memcpy(stream_bytes[0..prefix.len], prefix);
    @memcpy(stream_bytes[prefix.len..][0..bytes.len], damaged[0..bytes.len]);
    host.feedBytes(session, stream_bytes[0 .. prefix.len + bytes.len]) catch {};
    drainHost(host, session);
    try bounds.checkDeclared(&session.served.port.peer.session_state);
}

/// Feed `input` to `session` in `chunk` sized pieces, draining after each, the
/// way an embedder's read loop does. A chunk of zero means the whole buffer at
/// once.
fn feedChunked(host: *Host, session: *HostSession, input: []const u8, chunk: usize) !void {
    if (chunk == 0) {
        host.feedBytes(session, input) catch {};
        drainHost(host, session);
        try bounds.checkDeclared(&session.served.port.peer.session_state);
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
        // window where it was over the cap is the window an attacker holds the
        // memory.
        try bounds.checkDeclared(&session.served.port.peer.session_state);
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
        var host = test_host.init(gpa, [_]u8{0x11} ** 32, .{ .limits = bounds.tight });
        defer host.deinit();
        const session = host_pair.publishAndOpenAccepted(&host, "tcp", "127.0.0.1:9000", &.{}) catch return;
        drainHost(&host, session);
        try feedChunked(&host, session, input, chunk);
    }

    // Open, with an application on it. This is the regime with vows, an action
    // queue, and actor state that hostile bytes can find in an awkward moment.
    {
        // Partner verification is off here and on in the block above. Up there
        // the session is still negotiating, so the fuzzed bytes can reach the
        // hello and its signature check. Down here they arrive after the
        // handshake, so the two verifications are unreachable from the input —
        // and they were most of what each iteration spent its time on.
        var dialer = test_host.init(gpa, [_]u8{0x22} ** 32, .{ .limits = bounds.tight, .verify_partner = false });
        defer dialer.deinit();
        var acceptor = test_host.init(gpa, [_]u8{0x33} ** 32, .{ .limits = bounds.tight, .verify_partner = false });
        defer acceptor.deinit();
        const pair = host_pair.openPair(&dialer, &acceptor, "127.0.0.1:9001") catch return;

        _ = pair.b.served.publish(&pair.b.host.vat, "counter", Counter, .{}) catch return;
        const fetched = dialer.fetch(pair.a, "counter") catch return;
        var captured = promise_capture.CapturedRef{};
        dialer.vowOn(fetched, .{ .ctx = &captured, .func = promise_capture.CapturedRef.record }) catch return;
        host_pair.pumpToQuiescence(&.{pair}) catch return;

        // Leave a call genuinely in flight: sent, not pumped. The vow is
        // unsettled when the hostile bytes arrive, so the settle path and the
        // refusal path meet in whatever order the fuzzer picks rather than the
        // tidy one. Its frame is also what `feedDamaged` breaks, which is what
        // carries a delivery as far as the published capability.
        if (captured.ref) |cap| {
            _ = dialer.send(pair.a, cap, .{ .verb = "hit", .args = &.{} }) catch {};
        }
        drainHost(&acceptor, pair.b);

        if (smith.valueRangeAtMost(u8, 0, 1) == 1) {
            try feedDamaged(smith, &acceptor, pair.b, pair.a);
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
        var dialer = test_host.init(gpa, [_]u8{0x22} ** 32, .{ .limits = bounds.tight });
        defer dialer.deinit();
        var acceptor = test_host.init(gpa, [_]u8{0x33} ** 32, .{ .limits = bounds.tight });
        defer acceptor.deinit();
        const pair = try host_pair.openPair(&dialer, &acceptor, "127.0.0.1:9001");
        _ = try pair.b.served.publish(&pair.b.host.vat, "counter", Counter, .{});
        const fetched = try dialer.fetch(pair.a, "counter");
        var captured = promise_capture.CapturedRef{};
        try dialer.vowOn(fetched, .{ .ctx = &captured, .func = promise_capture.CapturedRef.record });
        try host_pair.pumpToQuiescence(&.{pair});

        // The fetch has to actually hand back the capability, otherwise the
        // call below never happens and no frame ever names the published
        // object — which is the one frame that reaches the vat at all.
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
