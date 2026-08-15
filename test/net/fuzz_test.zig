//! Hostile-bytes fuzzing of blocking frame reads, spill and all.
//!
//! `readFrameFrom` is what the blocking session calls to get one frame off a
//! stream. It has a job the frame parsers do not: a frame bigger than the read
//! buffer cannot be decoded in place, so it accumulates in a spill and is
//! decoded from there instead, and the spill is freed again when it drains
//! (ADR-0041). That handover between two supplies is the part worth fuzzing.
//!
//! Reaching it takes a particular geometry, and getting the geometry wrong is
//! silent. Over a reader whose buffer already holds the whole input, a frame is
//! always decoded straight out of that buffer: the spill absorbs once when the
//! bytes run short and then can never be topped up, so it is never decoded from
//! and never drained. The path looks exercised and is not. So the read buffer
//! here is small and bounded, and the stream arrives in pieces the fuzzer
//! chooses, which is what makes a frame cross the boundary and go through the
//! spill for real.
//!
//! What is asserted beyond not crashing and not leaking: a spill that is not
//! accumulating anything has freed its storage, not merely emptied it. That is
//! the whole reason this is a spill rather than a buffer per connection, and it
//! is the kind of property that stays true until one refactor makes it false
//! and nothing says so.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const net = pancake.net;

/// Every shape in the checked-in corpus, so the search starts from bytes that
/// decode instead of rediscovering what a frame looks like.
const seeds = @import("../support/corpus_seeds.zig");

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

/// Upper bound on one fuzz input, matching the sibling targets.
const max_input = 4096;

/// Frames past this are refused rather than decoded. It is what bounds how far
/// the spill can grow.
const frame_cap = 1024;

fn readOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    // The geometry comes out of the drawn bytes, not from separate draws.
    // A draw made after `smith.slice` has consumed the input returns the low
    // end of its range on every replay, so a saved crash would replay under a
    // one-byte read buffer and one-byte reads whatever geometry the fuzzer
    // actually found it with — which for a target whose whole subject is the
    // handover between two supplies is the wrong geometry every time.
    var read_buf: [64]u8 = undefined;
    const read_len: usize = 1 + @as(usize, if (input.len > 0) input[0] % 63 else 0);

    // The stream in pieces. Sized so the pieces can span the whole input: a
    // fixed small piece silently truncates anything past `calls.len` bytes.
    var calls: [64]std.testing.Reader.Call = undefined;
    const min_piece = std.math.divCeil(usize, input.len, calls.len) catch 1;
    const piece: usize = @max(min_piece, 1 + @as(usize, if (input.len > 1) input[1] % 127 else 0));
    var call_count: usize = 0;
    var at: usize = 0;
    while (at < input.len and call_count < calls.len) : (call_count += 1) {
        const end = @min(at + piece, input.len);
        calls[call_count] = .{ .buffer = input[at..end] };
        at = end;
    }

    // Both codecs, because the framing decision is per codec and only one of
    // them is length-prefixed.
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        var test_reader = std.testing.Reader.init(read_buf[0..read_len], calls[0..call_count]);
        const reader = &test_reader.interface;
        var spill: net.Spill = .{};
        var scan: net.StreamScan = .{};
        defer spill.deinit(gpa);

        // Keep reading until the stream refuses or runs out. A frame that ends
        // part-way through the buffer leaves the rest for the next read, which
        // is the case that builds and drains the spill. The count is a bound on
        // this harness, not on the code: a stream of tiny valid frames would
        // otherwise spend the whole budget in one input.
        var frames: usize = 0;
        while (frames < 64) : (frames += 1) {
            var frame = net.readFrameFrom(reader, gpa, codec_id, frame_cap, &spill, &scan) catch break;
            frame.deinit();

            // A drained spill has freed its storage, not merely emptied it.
            if (!spill.isActive()) {
                try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
            }
            // And an active one stays inside what it holds and inside the cap
            // that admitted it. This is ADR-0041's boundedness, checked while
            // the spill is live rather than assumed.
            try std.testing.expect(spill.len <= spill.buf.len);
            try std.testing.expect(spill.len <= frame_cap + 32 + read_len);
        }
    }
}

test "fuzz: arbitrary stream bytes never crash or leak a blocking frame read" {
    // Every shape in the corpus, not a hand-picked few: a shape the search
    // never starts from is a shape it will almost certainly never build.
    try std.testing.fuzz({}, readOne, .{ .corpus = (seeds.all ++ regression_seeds)[0..] });
}

// ── The completion loop's lifecycle accounting, under arbitrary schedules ────
//
// This target exists because of how the loop's bugs kept being found. The same
// class surfaced over and over: a counter released on one path and not another,
// a stamp that had to survive a state change and did not, an identity cleared
// by the assignment that handed the slot to somebody else. Every one was found
// by a person reading carefully, and every fix added one more site that has to
// remember.
//
// Reading does not scale to the combinations. The loop's derived state — how
// many connections carry a deadline, how many sit over the outbound mark, how
// many closes it still owes, which slots are free — is maintained across dozens
// of mutation sites, and what breaks it is an *ordering*: a close arriving
// between a park and a drain, a partial write on a slot already draining, a
// teardown while a slot is being adopted. A fuzzer chooses orderings for free.
//
// So the backend below is driven entirely by the fuzzer: it decides which
// outstanding operation completes next, whether it succeeds, how much of a
// write went out, how many complete together, and whether the loop is even
// allowed to queue a close or re-arm an accept. After the schedule runs out the
// loop is drained and every derived count is compared against a walk of the
// slots. A count that drifts is exactly the defect these reviews kept catching,
// and here it fails the build instead.
//
// A property test that passes proves nothing on its own, so this one was built
// against defects rather than against the passing tree. Each of these was
// injected into the loop and the search asked to find it, and each was found:
// a batch abandoned after a failing completion; a deadline release skipped on
// one path; a retried close that forgets
// its counter; a closing connection that keeps its deadline stamp; one that
// keeps its outbound over-mark; a reclaimed slot that never returns to the free
// list; and a slot adopted without advancing its generation. Two of those had
// escaped an earlier version of this file, and the escapes are what shaped it:
// the backend hands back several completions at once because a batch of one can
// never show the batch contract failing, and the closing-connection properties
// are stated outright because a count compared against a walk of the same field
// agrees with itself even when both have drifted.
//
// What it reaches and what it does not, counted rather than assumed. Per
// fifteen hundred schedules: the sink park fires about four thousand times, the
// single-connection un-park twelve hundred, the deadline reaper six hundred,
// connect completions a thousand, the park hook forty-five hundred, and a
// terminal failure leaves a connection draining about four thousand. Every one
// of those was zero at some point, each because of one decision the backend
// kept to itself — an infallible submit, a refused dial, a null hook, a peer
// with nothing to send.
//
// Two remain at zero, and the reason is the same for both: they need a
// connection that is simultaneously waiting to read and mid-write, and this
// harness's traffic never produces one. `onRecvConsume`'s draining arm needs a
// terminal failure to arrive on a connection with a recv already armed *and*
// something to flush — armed alone goes straight to closing, where the liveness
// guard drops the late recv first. `onSend`'s terminal back-swap needs the same
// overlap from the other side. `test/net/completion_cross_arm_test.zig` holds
// the first of them with a scripted backend, which is the right tool: a
// schedule that has to arrange an overlap is a worse instrument than a script
// that simply states it.
//
// `deinit`'s release of a live connection's contributions is a third, and it is
// structurally unreachable rather than unlucky: an over-mark or a deadline
// stamp implies queued outbound, which implies a write in flight, so the run is
// not quiescent and the branch is never entered.
//
// `max_conns`, `read_buffers`, and the high-water mark stay fixed. And under
// `zig build test` this target runs no loop at all — its corpus is empty, so
// the one empty input returns early. Every count above is `zig build fuzz`.

const completion = net.completion;
const engine = pancake.ocapn.engine;
const no_dial = @import("../support/no_dial_locator.zig");

/// A real client `op:start-session`, built once per run and handed to the
/// backend as inbound bytes when the schedule asks for it.
///
/// Without this every recv carried garbage, so the frame reader returned
/// refuse-or-close on every single one and *no frame ever applied*. That left
/// the whole success half of the recv handler dead: no event ever surfaced, so
/// the serve hook was never called, so its error arm was unreachable, so the
/// read re-arm behind it was never exercised. The harness had a serve hook
/// wired and inert, which is worse than not having one, because the header
/// claimed it was covered.
var hello: []const u8 = &.{};
var hello_buf: [512]u8 = undefined;

/// Encode one client hello into `hello_buf`. Fails soft: a run without it is
/// the old garbage-only behaviour, not a broken test.
fn buildHello(allocator: std.mem.Allocator) void {
    hello = &.{};
    var client = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    defer client.deinit();
    client.session_state.limits.max_frame_bytes = frame_cap;
    client.sendCopying(handshake.startSession(net.tcp.plain.transport_name, "client")) catch return;
    var at: usize = 0;
    while ((client.step() catch return) != .idle) {}
    while (client.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const bytes = frame.bytes();
        if (at + bytes.len > hello_buf.len) return;
        @memcpy(hello_buf[at..][0..bytes.len], bytes);
        at += bytes.len;
    }
    hello = hello_buf[0..at];
}

/// A locator that resolves, so the loop's dial half is reachable. The shared
/// `no_dial.Unsupported` refuses every transport, which left `onConnect`, the
/// connect completion, a dialed connection's `opened == false` teardown, and
/// the whole slot-exhaustion path with no input that could run them.
const DialAnything = struct {
    pub fn resolve(locator: model.PeerLocator) error{UnsupportedTransport}!void {
        _ = locator;
    }
};
const handshake = @import("../support/handshake.zig");

/// Completion schedules the fuzzer found here, replayed by the ordinary suite
/// so a lifecycle bug it caught cannot come back quietly. Separate from the
/// frame-shaped `regression_seeds` above because the two targets read their
/// input differently: a saved schedule means nothing to a frame reader, and a
/// saved frame means nothing to the loop.
const schedule_regression_seeds = [_][]const u8{};

/// The schedule, as a flat byte string the backend reads decisions from.
///
/// It is drawn once, as a slice, rather than a value per decision. The fuzzer
/// keys each drawn value on the return address of the call that drew it, so
/// asking for one byte at a time from inside the backend gives every decision
/// in the whole run the same identity, and the search cannot tell one from
/// another. Measured: a byte at a time explored around two hundred distinct
/// paths per two hundred thousand runs. A slice is a string the mutator can
/// splice, and the position in it is what distinguishes the decisions.
var schedule: []const u8 = &.{};

/// Storage behind `schedule`, at file scope because the backend reads it from
/// callbacks the loop makes, not from the test body.
var schedule_buf: [max_input]u8 = undefined;

/// How many completions one input drives before the loop is drained. A bound,
/// not a policy: without it a schedule that keeps accepting connections never
/// reaches the assertions.
const max_steps = 96;

/// Most completions the backend hands back from one poll. More than one is the
/// point: the loop's batch contract only exists because a failure part-way
/// through a batch must not abandon the completions behind it.
const max_batch = 4;

/// Connection slots the loop is built with. Small on purpose: reuse is what
/// makes slot identity and free-list bookkeeping matter, and four slots reuse
/// constantly where a thousand would never wrap.
const max_slots = 4;

/// A backend whose every choice is the fuzzer's. Submissions are recorded and
/// completed in whatever order the schedule asks for, with whatever result it
/// asks for, which is the part a hand-written script cannot cover.
const LifecycleBackend = struct {
    pub const Fd = i32;
    pub const ConnectTarget = void;

    pub fn applyKeepalive(_: *LifecycleBackend, _: Fd, _: net.completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    const Kind = enum { accept, recv, send, close, connect, cancel };
    /// `len` is the submitted byte count, carried so a send can complete as a
    /// *full* write. Without it every send reported a short count, so a queued
    /// connection could only ever shrink toward the outbound mark and never
    /// cross back under it while still open — which is the exact transition
    /// that releases the fan-in throttle, and it was unreachable.
    const Op = struct { user_data: u64, kind: Kind, len: usize = 0 };

    ops: [128]Op = undefined,
    ops_len: usize = 0,
    steps: usize = 0,
    /// How far into `schedule` the decisions have read.
    at: usize = 2,
    next_fd: Fd = 100,
    /// Set before the drain: completions stop being fuzzer-chosen and every
    /// outstanding operation retires, so teardown always terminates.
    draining: bool = false,
    /// Handed out as inbound bytes, one buffer per completion in a batch: the
    /// loop borrows every recv's bytes until it has consumed the whole batch,
    /// so two in one batch cannot share storage. Garbage is the point — a
    /// refused frame is the shortest path to the close-while-busy orderings.
    junk: [max_batch][512]u8 = @splat(@splat(0)),

    /// The next decision. A spent schedule reads as zero, which is a valid
    /// (and quiet) choice everywhere it is consulted. `at` starts past the
    /// configuration bytes: `schedule[0]` chose the throttle and whether a peer
    /// opens with outbound queued, and `schedule[1]` chose how the run ends, so
    /// letting the backend read them too would correlate its first decision
    /// with those.
    fn draw(self: *LifecycleBackend) u8 {
        if (self.at >= schedule.len) return 0;
        defer self.at += 1;
        return schedule[self.at];
    }

    /// Whether the schedule still has decisions left. Running dry is how one
    /// input ends, alongside the step bound.
    fn spent(self: *const LifecycleBackend) bool {
        return self.at >= schedule.len;
    }

    fn record(self: *LifecycleBackend, user_data: u64, kind: Kind, len: usize) void {
        if (self.ops_len == self.ops.len) return;
        self.ops[self.ops_len] = .{ .user_data = user_data, .kind = kind, .len = len };
        self.ops_len += 1;
    }

    fn takeOp(self: *LifecycleBackend, at: usize) Op {
        const op = self.ops[at];
        std.mem.copyForwards(Op, self.ops[at .. self.ops_len - 1], self.ops[at + 1 .. self.ops_len]);
        self.ops_len -= 1;
        return op;
    }

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !LifecycleBackend {
        _ = .{ allocator, queue_entries, read_buffers, read_buffer_bytes };
        return .{};
    }

    pub fn deinit(self: *LifecycleBackend) void {
        self.* = .{};
    }

    pub fn openListener(self: *@This(), port: u16) !Fd {
        _ = port;
        self.next_fd += 1;
        return self.next_fd;
    }

    pub const ListenerAddress = u16;
    pub fn listenerAddress(_: *@This(), _: Fd) !ListenerAddress {
        return 1;
    }
    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address;
    }

    pub fn closeFd(self: *@This(), fd: Fd) void {
        _ = .{ self, fd };
    }

    /// A no-op, like iroh's. That is the harder contract: nothing here cancels
    /// a pending operation, so a close the backend refuses is the only thing
    /// that ever retires one.
    pub fn shutdownFd(self: *@This(), fd: Fd) void {
        _ = .{ self, fd };
    }

    pub fn startDial(self: *LifecycleBackend, user_data: u64, target: ConnectTarget) !Fd {
        _ = target;
        // Refusable too: a dial the backend cannot start is the arm the loop
        // answers by returning the slot to the free list.
        if (self.draining or self.draw() % 6 == 3) return error.SubmissionQueueFull;
        self.next_fd += 1;
        self.record(user_data, .connect, 0);
        return self.next_fd;
    }

    pub fn submitAccept(self: *LifecycleBackend, user_data: u64, listen_fd: Fd) !void {
        _ = listen_fd;
        // A re-arm the backend cannot admit is the one per-connection handler
        // failure that is loop-global, and so the only thing that can fail a
        // completion part-way through a batch. Without it the loop's rule that
        // a batch is consumed whatever any one completion does has nothing to
        // prove itself against.
        if (!self.draining and self.draw() % 16 == 5) return error.SubmissionQueueFull;
        self.record(user_data, .accept, 0);
    }

    pub fn submitRecv(self: *LifecycleBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        // Refusable, like every other submit here. A backend out of completion
        // capacity is a state the loop has five `catch` arms for — an arm-failed
        // close, a resume-failed close, a fan-in release that closes instead of
        // re-arming — and an infallible submit leaves all of them dead.
        if (!self.draining and self.draw() % 12 == 4) return error.SubmissionQueueFull;
        self.record(user_data, .recv, 0);
    }

    pub fn submitSend(self: *LifecycleBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = fd;
        // Same. This one reaches the partial-write resubmit and the draining
        // back-swap, neither of which had ever run.
        if (!self.draining and self.draw() % 12 == 7) return error.SubmissionQueueFull;
        self.record(user_data, .send, bytes.len);
    }

    pub fn submitCancel(
        self: *LifecycleBackend,
        cancel_user_data: u64,
        target_user_data: u64,
        fd: Fd,
    ) !void {
        _ = .{ target_user_data, fd };
        // The target operation remains in the schedule and therefore still
        // yields its own completion; this records the second required seat.
        self.record(cancel_user_data, .cancel, 0);
    }

    pub fn submitClose(self: *LifecycleBackend, user_data: u64, fd: Fd) !void {
        _ = fd;
        // The refusal the loop has to survive: it cannot queue the close, and
        // its `shutdownFd` above cancels nothing, so the operations already
        // outstanding on this connection retire only if the loop comes back
        // and retries. Never refused during the drain, which must terminate.
        if (!self.draining and self.draw() % 8 == 3) return error.SubmissionQueueFull;
        self.record(user_data, .close, 0);
    }

    pub fn verifiedChannelKey(self: *LifecycleBackend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleRecv(self: *LifecycleBackend, comp: completion.Completion) void {
        _ = .{ self, comp };
    }

    pub fn poll(self: *LifecycleBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        // Nothing outstanding means a real loop would sleep forever, which for
        // this backend is the end of the input rather than a hang.
        if (self.ops_len == 0) return error.ScheduleIdle;
        if (!self.draining) {
            if (self.steps >= max_steps or self.spent()) return error.ScheduleDone;
            self.steps += 1;
        }

        // How many complete together. Batches of one would leave the whole
        // batch contract untested, and that contract is load-bearing: the loop
        // must consume every completion behind a failing one, because each is
        // the only chance to retire its operation. A backend that hands out one
        // at a time can never show that going wrong.
        const want = if (self.draining) 1 else 1 + @as(usize, self.draw()) % max_batch;
        var filled: usize = 0;
        while (filled < @min(want, @min(out.len, self.junk.len)) and self.ops_len > 0) : (filled += 1) {
            out[filled] = self.completeOne(filled);
        }
        return filled;
    }

    /// Retire one outstanding operation, with the result the schedule chooses.
    /// `slot` indexes this batch's inbound scratch: two recv completions in one
    /// batch are both borrowed by the loop until the batch is consumed, so they
    /// cannot share a buffer.
    fn completeOne(self: *LifecycleBackend, slot: usize) completion.Completion {
        const at: usize = if (self.draining) 0 else @as(usize, self.draw()) % self.ops_len;
        const op = self.takeOp(at);
        const verdict = if (self.draining) @as(u8, 0) else self.draw();
        const junk = &self.junk[slot];

        return switch (op.kind) {
            // A refused accept is as ordinary as an accepted one, and the loop
            // has to re-arm through both.
            .accept => blk: {
                self.next_fd += 1;
                break :blk .{
                    .user_data = op.user_data,
                    .result = if (self.draining or verdict % 4 == 0) -1 else self.next_fd,
                };
            },
            // Zero is a clean end of stream; a failure is a reset; anything
            // else is that many bytes of garbage, which the session refuses.
            .recv => blk: {
                if (self.draining or verdict % 3 == 0) break :blk .{ .user_data = op.user_data, .result = 0 };
                if (verdict % 7 == 1) break :blk .{ .user_data = op.user_data, .result = -1, .recv_no_buffer = verdict % 2 == 0 };
                // Sometimes the real hello, so the frame reader returns `.ok`
                // and a frame actually applies. Everything downstream of a
                // successful apply — the surfaced event, the serve hook, the
                // read re-arm — has no other way to run.
                if (verdict % 4 == 2 and hello.len != 0 and hello.len <= junk.len) {
                    @memcpy(junk[0..hello.len], hello);
                    break :blk .{
                        .user_data = op.user_data,
                        .result = @intCast(hello.len),
                        .recv_bytes = junk[0..hello.len],
                    };
                }
                const len = @as(usize, verdict % 32) + 1;
                for (junk[0..len], 0..) |*b, i| b.* = verdict +% @as(u8, @intCast(i));
                break :blk .{
                    .user_data = op.user_data,
                    .result = @intCast(len),
                    .recv_bytes = junk[0..len],
                };
            },
            // Three shapes, and the loop answers each differently: a failure
            // ends the connection, a short write leaves a tail queued and is
            // what puts a connection over the outbound mark, and a full write
            // is what takes it back under — the transition that releases every
            // connection the fan-in throttle was holding.
            .send => .{
                .user_data = op.user_data,
                .result = if (verdict % 5 == 0)
                    -1
                else if (verdict % 3 == 0)
                    @intCast(op.len)
                else
                    @min(@as(i32, verdict % 24) + 1, @as(i32, @intCast(op.len))),
            },
            .close, .cancel => .{ .user_data = op.user_data, .result = 0 },
            // A connect either fails, succeeds carrying no fd (the socket
            // backends' shape, where the fd came back from `startDial`), or
            // succeeds carrying one (iroh's, where the resident assigns it
            // late).
            .connect => .{
                .user_data = op.user_data,
                .result = if (self.draining or verdict % 3 == 0)
                    -1
                else if (verdict % 2 == 0)
                    0
                else blk: {
                    self.next_fd += 1;
                    break :blk self.next_fd;
                },
            },
        };
    }
};

fn makeLifecyclePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    // Whether a connection opens with outbound already queued is a schedule
    // choice, and it decides whether the loop's central mechanism is exercised
    // at all. Without a queued frame an open connection's `pendingOut` is zero
    // for its whole life, so it can never cross the outbound high-water mark,
    // so the ADR-0042 sink park never fires — and neither does anything behind
    // it: the single-connection un-park, the park deadline, the park-to-drain
    // restamp. Measured over four thousand schedules, all of those ran zero
    // times before this line and thousands of times after.
    //
    // Conditional rather than always, because always is worse in the other
    // direction: a peer with something to flush never reaches `teardown`
    // inline from `failConn`, which is the path the adoption-teardown deferral
    // needs, and that dropped to zero when it was unconditional.
    if (schedule.len > 0 and schedule[0] & 2 != 0) {
        try peer.sendCopying(handshake.startSession(net.tcp.plain.transport_name, "fuzz"));
    }
    return peer;
}

/// The generation each slot carried the last time it was adopted, and whether
/// it has been adopted at all.
var last_generation: [max_slots]u32 = @splat(0);
var slot_used: [max_slots]bool = @splat(false);
/// Set when a slot was re-adopted carrying a generation it had already used.
var generation_repeated = false;

/// Adopting a slot is where its identity has to advance. A connection's slot
/// number is reused; the generation is what tells a holder of a stale reference
/// that the slot became somebody else's, and the loop's own bridge relies on
/// that to route a flush to the right connection. Checked at adoption because
/// that is the moment the previous occupant's identity must already be spent.
///
/// The hook also condemns and fails, on the schedule's say-so, because this is
/// the one moment a slot can be torn down while it is being adopted. A real
/// bridge condemns from right here — it drains its host's actions inside this
/// hook, and one of them can be a close — and the loop answers by deferring
/// the teardown until the hook returns. A hook that only ever reads and
/// returns null leaves that whole deferral unreachable, so the header's claim
/// to drive "a teardown while a slot is being adopted" would be a claim about
/// code no input can run.
fn watchAdoption(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
    const loop: *completion.Loop(LifecycleBackend, DialAnything) = @ptrCast(@alignCast(ctx.?));
    _ = peer;
    const generation = loop.conns[slot].generation;
    if (slot_used[slot] and generation == last_generation[slot]) generation_repeated = true;
    slot_used[slot] = true;
    last_generation[slot] = generation;

    const decision = loop.backend.draw();
    if (decision % 8 == 1) loop.closeSlot(slot);
    // And sometimes a *different* slot. `armOutbound` and `closeSlot` are the
    // loop's public re-entry surface, and a real bridge reaches them from here
    // by draining its host's actions — one of which can close some other
    // connection entirely. Closing only this slot exercises the deferral and
    // nothing else; closing a sibling is what walks a list the caller above is
    // in the middle of.
    const other = (slot + 1 + @as(usize, decision % max_slots)) % max_slots;
    if (decision % 5 == 2 and other != slot) loop.closeSlot(other);
    // Drawn from a different residue than the condemn above, which is `% 8 == 1`:
    // `7 % 8` is 7, so `% 16 == 7` could never coincide with it, and the arm
    // where a slot is condemned *and* the hook then fails — the one that defers
    // a teardown across an adoption error — was arithmetically unreachable.
    if (decision % 8 == 1 and decision % 3 == 1) return error.AdoptionRefused;
    if (decision % 16 == 7) return error.AdoptionRefused;
    // A real context, so `free_conn_ctx` has something to free — including on
    // the arm where the slot was condemned while this hook ran, which releases
    // the context before tearing the peer down.
    return makeConnCtx();
}

/// A per-connection context, so `free_conn_ctx` has something to free and the
/// condemned-while-adopting release runs. One byte on the gpa, freed by the
/// hook below or leaked loudly by the testing allocator if the loop forgets.
var ctx_allocator: ?std.mem.Allocator = null;
var contexts_built: usize = 0;
var contexts_seen_on_close: usize = 0;
var contexts_freed: usize = 0;

fn makeConnCtx() ?*anyopaque {
    const a = ctx_allocator orelse return null;
    const cell = a.create(u8) catch return null;
    cell.* = 1;
    contexts_built += 1;
    return @ptrCast(cell);
}

fn freeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
    _ = ctx;
    const a = ctx_allocator orelse return;
    const cell: *u8 = @ptrCast(@alignCast(conn_ctx orelse return));
    contexts_freed += 1;
    a.destroy(cell);
}

/// The serve hook, which the loop calls for every surfaced event. Refusing on
/// the schedule's say-so reaches `onRecvFinish`'s hook-error arm, which closes
/// the connection rather than the loop.
fn serveEvent(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    _ = .{ conn_ctx, peer, event };
    if (serve_backend) |b| {
        if (b.draw() % 16 == 9) return error.ServeRefused;
    }
}

/// The park hook. It fires from inside `markParked`, after the state is
/// settled, and it is public — so what it does here is what a real embedder
/// may do: reach back into the loop.
fn onParked(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, reason: completion.ParkReason) void {
    _ = .{ conn_ctx, reason };
    const loop: *completion.Loop(LifecycleBackend, DialAnything) = @ptrCast(@alignCast(ctx orelse return));
    const decision = loop.backend.draw();
    if (decision % 10 == 6) loop.closeSlot(slot);
    // The loop names `armOutbound` and `closeSlot` together as its public
    // re-entry surface, and only `closeSlot` was ever called from a hook. This
    // is the other one: a bridge flushes a sibling's queue from here, which is
    // what pushes a connection over the outbound mark while its own recv is
    // still armed.
    if (decision % 9 == 5) {
        for (loop.conns, 0..) |*other, other_slot| {
            if (other_slot == slot or other.state != .open) continue;
            loop.armOutbound(other_slot);
            break;
        }
    }
    // And sometimes a sibling, which is the case worth reaching: a parked slot
    // has no armed recv and nothing in flight, so condemning it goes straight
    // to closed. A sibling is mid-conversation, so condemning it lands on
    // `.draining` with a recv still armed and bytes still queued — which is
    // where `onRecvConsume`'s draining arm and `onSend`'s terminal back-swap
    // live, and neither had ever run.
    if (decision % 7 == 4) {
        // A slot that is actually mid-conversation, not an arbitrary index.
        // With four slots and usually one or two live, picking blind mostly
        // picked a free slot and closed nothing.
        for (loop.conns, 0..) |*other, other_slot| {
            // Specifically one with a recv already armed. That is the race the
            // loop's `.draining` recv arm exists for — a terminal failure
            // arriving on a connection that is waiting to read — and picking
            // any open slot mostly picked the one being dispatched, whose seat
            // is idle, so the arm never ran.
            if (other_slot == slot or other.state != .open or other.read != .armed) continue;
            // And with a write still outstanding, so the terminal flush has
            // something to wait on. Without that, condemning it finds nothing
            // to send and goes straight to closing, where a late recv is
            // dropped by the liveness guard instead of reaching the draining
            // arm this is trying to exercise.
            if (!other.write_in_flight) continue;
            loop.closeSlot(other_slot);
            break;
        }
    }
}

/// The backend the serve hook draws from. File scope because the hook's
/// signature carries the connection context, not the loop.
var serve_backend: ?*LifecycleBackend = null;

/// Fires once per connection the loop actually reclaims, which makes it an
/// independent count of the thing `closed_count` claims to hold. Derived
/// counters compared against a walk of the state they summarize cannot see a
/// count incremented twice for one connection; a second, separately-sourced
/// tally can.
var close_hook_fires: usize = 0;

fn countClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: completion.CloseReport) void {
    _ = .{ ctx, slot, report };
    if (conn_ctx != null) contexts_seen_on_close += 1;
    close_hook_fires += 1;
}

fn driveLifecycle(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;
    schedule = schedule_buf[0..smith.slice(&schedule_buf)];
    defer schedule = &.{};
    // A schedule too short to accept a connection cannot reach anything worth
    // asserting, and a run that ends there is a run the search wasted. The
    // first byte configures the loop, so the backend reads decisions from the
    // rest.
    if (schedule.len < 8) return;

    var loop = completion.Loop(LifecycleBackend, DialAnything).initWithBackendOptions(
        allocator,
        .{ .read_buffers = 2 },
        makeLifecyclePeer,
        null,
        .{
            .max_conns = max_slots,
            .listen = 0,
            // Small enough that an ordinary short write puts a connection over
            // it, so the fan-in accounting is actually reached.
            .outbound_high_water_bytes = 48,
            // The throttle is a schedule choice, not a constant. With it on,
            // the fan-in release sweep is what un-parks a connection, and the
            // one-connection un-park in `resumeIfDrained` is unreachable —
            // measured: zero times in four hundred runs. That branch is the
            // whole un-park path when the throttle is off, so pinning the
            // option pinned half the code out of the search.
            .fan_in_throttle = schedule[0] % 2 == 0,
            // Both reapers armed and short, so the deadline sweeps run rather
            // than being dead code under the fuzzer.
            .park_kill_ms = 1,
            .drain_kill_ms = 1,
            .make_conn_ctx = watchAdoption,
            .free_conn_ctx = freeConnCtx,
            .serve = serveEvent,
            .on_park = onParked,
            .on_close = countClose,
        },
    ) catch return;
    // The adoption hook reads the loop it is called from, and the loop is what
    // it is passed as the shared context.
    loop.make_ctx = &loop;
    ctx_allocator = allocator;
    serve_backend = &loop.backend;
    buildHello(allocator);
    defer {
        ctx_allocator = null;
        serve_backend = null;
    }
    last_generation = @splat(0);
    slot_used = @splat(false);
    generation_repeated = false;
    close_hook_fires = 0;
    contexts_built = 0;
    contexts_seen_on_close = 0;
    contexts_freed = 0;
    var deinited = false;
    defer if (!deinited) {
        loop.backend.draining = true;
        loop.closeAndDrain() catch {};
        loop.deinit();
    };

    // Dial before running, on the schedule's say-so. Without a dial the loop's
    // outbound half — the connect completion, the late fd assignment, a refused
    // dial's `opened == false` teardown, slot exhaustion — has no input that
    // reaches it.
    var dials: usize = 0;
    while (dials < max_slots and schedule[1] >> @intCast(dials) & 1 != 0) : (dials += 1) {
        _ = loop.dialLocator(.{
            .transport = "fuzz",
            .designator = "peer",
            .hints = model.Hints.emptyFalse(),
        }) catch break;
    }

    loop.run(.forever) catch {};

    try std.testing.expect(!generation_repeated);

    // The live loop, wherever the schedule left it. This is the strongest
    // place to look: connections are still open, still parked, still holding
    // whatever the schedule built, and a count that has drifted has not yet
    // been washed out by a teardown that resets everything anyway.
    try expectAccountingExact(&loop);
    // `deinit` on a live loop is a call the API allows, and it is the only
    // route to the branch that releases an *open* connection's contributions:
    // every other teardown comes through `closeConn`, which has already
    // cleared them. Its precondition is that nothing is in flight, so take
    // the branch only when that holds, and let the schedule decide when.
    //
    // From the schedule, not a separate `smith.boolWeighted` draw. The draw
    // happens after `smith.slice` has consumed the input, so outside the
    // fuzzer it always returned the same answer, and this branch ran zero
    // times in four hundred runs while looking like a coin flip. Read from a
    // schedule byte it runs about one run in ten, and — the part that matters
    // — a probe can measure which.
    if (schedule[1] % 3 == 0 and quiescent(&loop)) {
        // Its two assertions — every deadline stamp and every over-mark
        // released — are the check here.
        loop.deinit();
        deinited = true;
        try std.testing.expectEqual(contexts_built, contexts_seen_on_close);
        try std.testing.expectEqual(contexts_built, contexts_freed);
        return;
    }

    // Otherwise drain on a backend that no longer refuses anything, so every
    // outstanding operation retires and teardown is reached from wherever the
    // schedule left the loop.
    loop.backend.draining = true;
    loop.closeAndDrain() catch {};
    try expectAccountingExact(&loop);

    // `closed_count` against a tally taken somewhere else entirely. The walk
    // above compares each count to the state it summarizes, which cannot see a
    // count incremented twice for one connection — both sides move together.
    // The close hook fires once per reclaim, from inside the reclaim, so it is
    // the independent witness that catches exactly that.
    try std.testing.expectEqual(close_hook_fires, loop.closed_count);
    try std.testing.expectEqual(contexts_built, contexts_seen_on_close);
    try std.testing.expectEqual(contexts_built, contexts_freed);
}

/// Whether every live connection has retired its operations, which is what
/// `Loop.deinit` requires of a caller that has not drained.
fn quiescent(loop: anytype) bool {
    for (loop.conns) |*c| {
        if (c.state != .free and c.ops_in_flight != 0) return false;
    }
    return true;
}

/// Every derived count against a walk of the slots. These are maintained
/// edge-triggered across dozens of mutation sites, and each drift a review
/// found was one path forgetting to release.
fn expectAccountingExact(loop: anytype) !void {
    var stamped: usize = 0;
    var over: usize = 0;
    var owed: usize = 0;
    var free_slots: usize = 0;
    var live: usize = 0;
    for (loop.conns) |*c| {
        if (c.state != .free) live += 1;
        if (c.waiting_since_ms != 0) stamped += 1;
        if (c.over_mark) over += 1;
        if (c.owns_fd_close) owed += 1;
        if (c.state == .free) {
            free_slots += 1;
            // A reclaimed slot owns nothing. Its reset is what returns the
            // counts, so a field that survives it is a leak into the next
            // connection to take the slot.
            try std.testing.expectEqual(@as(i64, 0), c.waiting_since_ms);
            try std.testing.expect(!c.over_mark);
            try std.testing.expect(!c.owns_fd_close);
            try std.testing.expectEqual(@as(usize, 0), c.ops_in_flight);
        }
        // A closing connection is on its way out and must not be holding the
        // loop's attention. A stamp left behind here is a wake per poll for a
        // connection nothing will ever reap, and an over-mark left behind
        // throttles other connections on behalf of one that is already gone.
        // Both are stated rather than derived: a count compared against a walk
        // of the same field agrees with itself even when both have drifted, so
        // it cannot see a release that was skipped everywhere at once.
        if (c.state == .closing) {
            try std.testing.expectEqual(@as(i64, 0), c.waiting_since_ms);
            try std.testing.expect(!c.over_mark);
        }
    }
    try std.testing.expectEqual(stamped, loop.waiting_count);
    try std.testing.expectEqual(over, loop.over_mark_count);
    try std.testing.expectEqual(owed, loop.pending_close_submits);
    try std.testing.expectEqual(live, loop.live_count);

    // The throttle bounds itself. A connection over the outbound mark parks
    // every other read, so one of them must be carrying the deadline that ends
    // it — otherwise the loop waits on a completion that cannot arrive, which
    // is a hang and not backpressure.
    if (loop.fan_in_throttle and loop.over_mark_count > 0) {
        try std.testing.expect(loop.waiting_count > 0);
    }

    // The two admission-partitioned free lists hold every reclaimed slot
    // exactly once. A slot pushed twice hands one connection to two adopters;
    // one never pushed is capacity the loop can never use again.
    var listed: usize = 0;
    var walk = loop.ordinary_free_head;
    while (walk < loop.conns.len) : (listed += 1) {
        try std.testing.expect(listed <= loop.conns.len);
        try std.testing.expect(walk < loop.ordinary_capacity);
        try std.testing.expect(loop.conns[walk].state == .free);
        walk = loop.conns[walk].next_link;
    }
    walk = loop.reserved_free_head;
    while (walk < loop.conns.len) : (listed += 1) {
        try std.testing.expect(listed <= loop.conns.len);
        try std.testing.expect(walk >= loop.ordinary_capacity);
        try std.testing.expect(loop.conns[walk].state == .free);
        walk = loop.conns[walk].next_link;
    }
    try std.testing.expectEqual(free_slots, listed);

    // The other two lists, walked the same way. All four thread one `next_link`
    // word, and that is valid because their states are disjoint: a free slot's
    // seat is idle, and starved and parked are two values of one enum. Walking
    // each list and checking its member state catches duplicate membership,
    // stale membership, and cycles.
    var starved: usize = 0;
    var s = loop.starved_head;
    while (s < loop.conns.len) : (starved += 1) {
        try std.testing.expect(starved <= loop.conns.len);
        try std.testing.expect(loop.conns[s].state != .free);
        try std.testing.expect(loop.conns[s].read == .starved);
        s = loop.conns[s].next_link;
    }

    var parked: usize = 0;
    var p = loop.parked_head;
    while (p < loop.conns.len) : (parked += 1) {
        try std.testing.expect(parked <= loop.conns.len);
        try std.testing.expect(loop.conns[p].state != .free);
        try std.testing.expect(loop.conns[p].read == .parked);
        p = loop.conns[p].next_link;
    }
    // And every parked or starved connection is on its list. A seat marked but
    // never linked is a connection the resume can no longer find: it corrupts
    // nothing, it just strands a reader forever, so only counting the two
    // directions against each other catches it.
    var parked_seats: usize = 0;
    var starved_seats: usize = 0;
    for (loop.conns) |*c| {
        if (c.state == .free) continue;
        if (c.read == .parked) parked_seats += 1;
        if (c.read == .starved) starved_seats += 1;
    }
    try std.testing.expectEqual(parked_seats, parked);
    try std.testing.expectEqual(starved_seats, starved);
}

test "fuzz: arbitrary completion schedules keep the loop's lifecycle accounting exact" {
    // No shaped seeds: a schedule is an arbitrary byte string with no shape to
    // start from, unlike the frame corpus the target above seeds with. But the
    // regressions still replay here, so a schedule that broke the loop once
    // runs on every ordinary suite from then on.
    try std.testing.fuzz({}, driveLifecycle, .{ .corpus = schedule_regression_seeds[0..] });
}

// ── A frame stream's bytes, across arbitrary chunk splits ────────────────────
//
// The first target in this file feeds hostile bytes and asks whether anything
// crashes. This one feeds frames it already knows and asks whether they come
// back: the same frames, whole, in order, once each. That question needs a
// reference to check against, so the stream is built here rather than drawn,
// and what the fuzzer
// chooses is the geometry — how big the read buffer is, how much one read is
// allowed to return, where the chunk boundaries fall, which frames arrive, and
// how the stream ends.
//
// Geometry is the whole subject, because it is what decides which of the two
// byte supplies a frame is decoded from. A frame that fits the read buffer is
// decoded where it landed and the spill never opens. A frame larger than the
// buffer cannot be, so returning it whole is itself the evidence the spill
// carried it (ADR-0041). And past `codec.framing.scan_threshold_bytes` pending
// bytes the codec stops decoding on every read and walks a resumable scan
// instead, which withholds the decoder — and with it the decoder's own refusal —
// so `codec.dispatch.framePrefix` owes the frame cap in its place. One
// synthesized frame and the open-record tail both reach past that threshold, so
// a stream here crosses every one of those handovers.
//
// What is asserted, beyond not crashing and not leaking:
//
//   - Every frame fed comes back byte-identical, in order, exactly once. That
//     is the coalesce contract stated as an equality rather than as an absence
//     of crashes: a byte dropped, duplicated, or read twice fails here.
//   - The read after the last frame gives the verdict the tail earned: a clean
//     end is `Closed`, a record opened and never closed is `FrameTooLarge`, and
//     a frame cut short mid-way is `TruncatedFrame`.
//   - The spill stays inside the cap that admitted it plus the one read that
//     carried it there, and a spill that is not accumulating has freed its
//     storage rather than merely emptied it (`net.spill_retain_bytes` is zero at
//     this tier). The sibling target above states the same retention property
//     over hostile bytes; this one reaches it on every frame of every stream,
//     because a stream of known frames actually drains.
//
// The harness's own claims are checked before the search runs, in
// `ratifyStreamShapes`: every corpus frame is one whole admissible frame, the
// synthesized frame crosses the scan threshold at every argument count the plan
// can choose and stays under the cap, and the open-record tail is refused at the
// cap rather than at the end of the stream. A geometry claim nobody checks is
// how the first target in this file spent a while never touching the spill it
// exists for.
//
// Validated against defects rather than against a passing tree. Each of these
// was injected into the production path, one at a time, and the search asked to
// find it, and each was found: bytes lost on the way into the spill
// (`net.absorbFrom` absorbing one byte fewer than it tosses); bytes duplicated
// on the way in (tossing one fewer than it absorbs); a consumed frame's last
// byte left in the spill for the next frame to trip over; a drained spill
// retaining its storage instead of freeing it; the cap refusal removed from the
// withheld-decode arm of `codec.dispatch.framePrefix`; and the resumable scan
// letting a length-prefixed leaf's payload move its depth.
//
// Two of those are worth spelling out, because of what caught them.
//
// The missing cap refusal was caught by the spill bound, not by the tail's
// verdict — the verdict still came back `FrameTooLarge`, because the scan settles
// once its own cursor passes the cap and the decoder then refuses. What had
// changed was how much had piled up first. Asserting boundedness separately from
// the verdict is the whole reason that was visible.
//
// The scan defect is why the synthesized frame carries byte-string arguments
// whose payload spells `<`. Two earlier attempts at the same defect class
// escaped: dropping the scan's digit arm and dropping its symbol arm both make
// the walk fail *early*, and failing early hands the question straight to the
// decoder, which is the safe direction. So this target can only see a scan defect
// that keeps the walk going while miscounting depth, and it needs a frame with a
// payload that can be miscounted to see even that. The escape shaped the frame;
// without those arguments the whole class was invisible here.
//
// What it does not reach, measured rather than assumed:
//
//   - A scan that gives up too early, per the escape above. By design that costs
//     a wasted decode and nothing observable, so nothing here can judge it;
//     `test/codec` drives `scanStream` directly, which is the right instrument
//     for the walk itself.
//   - Which of the two cap mirrors refused an over-cap prefix. The decoder
//     refuses one byte later than `framePrefix` does, and one read buffer is
//     wider than the byte between them.
//   - `net.drainWholeFrames`, the other spill consumer at this tier. It carries a
//     chunk tail into the same spill for the readiness loops, but it drives a
//     `Peer` rather than returning frames, so the target below it is the
//     completion-loop one above.
//   - Cap'n Proto, on purpose. Its frames declare their length up front, so it
//     has no scan and no self-delimiting grammar to resume, and the corpus this
//     target checks streams against is Syrup.
//
// Reachability was measured the same way as the defects, by asserting a state
// unreachable and letting the search refute it: a stream carrying two or more
// frames, one of them past the scan threshold, under the large cap, ending in an
// open record turns up within a few dozen runs.
//
// Under `zig build test` the search does not run: the corpus is the regression
// seeds alone, so the ratification is what the ordinary suite gets from this
// target. It is not a small part — a scan that miscounts a leaf's payload fails
// it outright, with no fuzzer involved.

/// Streams the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. Its own list, separate from the two above,
/// because a saved stream plan is neither a frame nor a completion schedule.
const stream_regression_seeds = [_][]const u8{};

/// Upper bound on one stream plan. Smaller than `max_input`: the input picks
/// frames and a geometry rather than carrying frame bytes itself, so a long
/// input only ever names more frames than the byte budget below admits.
const max_stream_input = 512;

/// The two caps a plan may admit frames under, and the fuzzer picks which. The
/// small one is where the ordinary traffic lives: frames cross the read buffer
/// and nothing else. The large one is above
/// `codec.framing.scan_threshold_bytes`, so a frame or an open record can grow
/// past the point where the codec stops decoding on every read and walks a
/// resumable scan instead.
///
/// Both, rather than only the large one, because the large cap is what a run
/// costs. Below the threshold the decoder re-walks the pending prefix on every
/// read, which is quadratic in the frame size over the read size, and that is
/// the very cost the scan exists to end. Every input paying it would buy the
/// scan-side arms at roughly twenty times the price per input, which the search
/// pays for in inputs it never gets to try.
const small_frame_cap: usize = 1024;
const large_frame_cap: usize = 8192;

/// How often a plan takes the large cap: one input in this many.
const large_cap_in: u8 = 8;

/// Smallest the synthesized frame is built, in bytes. Above the scan threshold
/// with room to spare, so every argument count the plan can choose still crosses
/// it; `ratifyStreamShapes` holds that at both ends.
const big_frame_floor: usize = 4224;

/// Largest read buffer the plan hands the reader, and the most one read may
/// return. Both are drawn from the whole range, so the search reaches
/// byte-at-a-time reads as well as ones that swallow a corpus frame whole; every
/// corpus frame is longer than this, so a frame always crosses the buffer
/// boundary and goes through the spill for real.
const max_read_len: usize = 96;

/// Chunk boundaries one plan can place. The per-read limit below is what makes
/// reads short, so these only have to be plentiful enough to land at odd
/// offsets.
const max_calls: usize = 128;

/// Frames one stream can carry, and the bytes they may occupy. The budget is
/// what stops a stream of tiny frames from spending the whole run in one input.
const max_stream_frames: usize = 32;
const frames_budget: usize = 8192;

/// The stream one plan feeds, and the synthesized frame it may include. At file
/// scope because a plan hands out slices of them that outlive the builder.
var stream_buf: [frames_budget + large_frame_cap + 32]u8 = undefined;
var big_frame_buf: [large_frame_cap]u8 = undefined;
var frame_spans: [max_stream_frames][]const u8 = undefined;

/// Configuration bytes at the front of an input, before the frame selectors.
const stream_config_bytes: usize = 6;

/// How a stream ends after its last whole frame.
const Tail = enum {
    /// Nothing follows, so the reader meets a clean end on a frame boundary.
    clean,
    /// An outer length larger than the frame cap, refused before its body.
    oversize_length,
    /// A whole frame cut off part-way. The stream ends inside a frame, which is
    /// a different condition from ending between two.
    truncated_frame,

    /// What the read after the last whole frame must answer.
    fn verdict(self: Tail) anyerror {
        return switch (self) {
            .clean => error.Closed,
            .oversize_length => error.FrameTooLarge,
            .truncated_frame => error.TruncatedFrame,
        };
    }
};

/// One stream: the geometry the fuzzer chose, the frames it asked for, and the
/// bytes those add up to.
const StreamPlan = struct {
    /// Bytes of read buffer the frame reader is given.
    read_len: usize,
    /// Most bytes one read may return, however much room the buffer has. This is
    /// what makes a frame arrive over many short reads.
    per_read: usize,
    /// Bytes per chunk boundary in the stream.
    piece: usize,
    /// The cap frames are admitted under, and so the bound on what the spill may
    /// hold.
    frame_cap: usize,
    tail: Tail,
    /// The bare frames fed, in order; `bytes` carries their outer envelopes.
    frames: []const []const u8,
    /// The whole stream: those frames, then the tail.
    bytes: []const u8,
};

/// The frame part of a corpus seed. `corpus_seeds.seed` prefixes each frame with
/// a little-endian length for the fuzzer's replay framing, so the frame is what
/// follows that prefix.
fn corpusFrame(index: usize) []const u8 {
    return seeds.message_seeds[index % seeds.message_seeds.len][4..];
}

fn appendOuterFrame(dest: []u8, frame: []const u8) ?usize {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}:", .{frame.len}) catch return null;
    const total = prefix.len + frame.len;
    if (total > dest.len) return null;
    @memcpy(dest[0..prefix.len], prefix);
    @memcpy(dest[prefix.len..total], frame);
    return total;
}

/// An `op:deliver` whose argument list fills about `want` bytes: one whole
/// admissible frame, far larger than any read buffer and larger than the scan
/// threshold, so it is decoded from the spill after a resumable scan has walked
/// it.
///
/// Every fourth argument is a byte string whose payload spells `<`, and that is
/// the point rather than decoration. The scan steps over a length-prefixed leaf
/// by its declared length precisely so a payload byte cannot move its depth; a
/// walk that loses that property counts opens it can never close, withholds the
/// decoder for good, and the frame is refused at the cap instead of returned.
/// Without such a payload the frame cannot tell a correct walk from that one.
fn synthesizeDeliver(out: []u8, want: usize) []const u8 {
    const opener = "<10'op:deliver<11'desc:export7+>[";
    const closer = "]42+f>";
    const integer = "1+";
    const opens = "4:<<<<";
    @memcpy(out[0..opener.len], opener);
    var at = opener.len;
    const room = @min(want, out.len);
    var written: usize = 0;
    while (true) : (written += 1) {
        const element = if (written % 4 == 3) opens else integer;
        if (at + element.len + closer.len > room) break;
        @memcpy(out[at..][0..element.len], element);
        at += element.len;
    }
    @memcpy(out[at..][0..closer.len], closer);
    return out[0 .. at + closer.len];
}

/// Read one stream plan out of the drawn input, or null when the input is too
/// short to describe one.
///
/// Every choice comes out of these bytes rather than from a separate draw. A
/// draw made after `smith.slice` has consumed the input answers the same way on
/// every replay, so a saved finding would replay under a geometry the fuzzer
/// never found it with — and for a target whose whole subject is geometry that
/// is the wrong one every time.
fn planStream(input: []const u8) ?StreamPlan {
    if (input.len <= stream_config_bytes) return null;

    const read_len = 1 + @as(usize, input[0]) % max_read_len;
    const per_read = 1 + @as(usize, input[1]) % max_read_len;
    const tail: Tail = switch (input[2] % 3) {
        0 => .clean,
        1 => .oversize_length,
        else => .truncated_frame,
    };
    // One byte carries both halves of the large-cap choice, because they only
    // mean anything together: the synthesized frame is admissible under the
    // large cap alone, and the large cap has nothing above the scan threshold to
    // show without it. The argument count keeps the frame over the threshold at
    // the low end and under the cap at the high end; `ratifyStreamShapes` holds
    // both.
    const large = input[3] % large_cap_in == 0;
    const cap = if (large) large_frame_cap else small_frame_cap;
    const big = synthesizeDeliver(&big_frame_buf, big_frame_floor + @as(usize, input[3] / large_cap_in) * 128);

    var at: usize = 0;
    var count: usize = 0;
    for (input[stream_config_bytes..]) |selector| {
        if (count == max_stream_frames) break;
        // One past the corpus selects the synthesized frame, so a stream can
        // mix a frame that crosses every boundary with frames that cross only
        // the read buffer.
        const pick = selector % (seeds.message_seeds.len + 1);
        const synthesized = pick == seeds.message_seeds.len;
        if (synthesized and !large) continue;
        const frame = if (synthesized) big else corpusFrame(pick);
        const framed_len = appendOuterFrame(stream_buf[at..frames_budget], frame) orelse break;
        frame_spans[count] = frame;
        at += framed_len;
        count += 1;
    }

    switch (tail) {
        .clean => {},
        .oversize_length => {
            const prefix = std.fmt.bufPrint(stream_buf[at..], "{d}:", .{cap + 1}) catch return null;
            at += prefix.len;
        },
        .truncated_frame => {
            const frame = corpusFrame(input[4]);
            const keep = 1 + @as(usize, input[5]) % (frame.len - 1);
            var prefix_buf: [32]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "{d}:", .{frame.len}) catch return null;
            @memcpy(stream_buf[at..][0..prefix.len], prefix);
            at += prefix.len;
            @memcpy(stream_buf[at..][0..keep], frame[0..keep]);
            at += keep;
        },
    }

    return .{
        .read_len = read_len,
        .per_read = per_read,
        .piece = 1 + @as(usize, input[1] ^ input[2]) % 251,
        .frame_cap = cap,
        .tail = tail,
        .frames = frame_spans[0..count],
        .bytes = stream_buf[0..at],
    };
}

/// Cut `bytes` into chunk-sized reader calls, returning how many were filled.
/// The pieces are sized so they can span the whole stream: a fixed small piece
/// silently truncates everything past `calls.len` bytes.
fn splitStream(bytes: []const u8, calls: []std.testing.Reader.Call, piece: usize) usize {
    const min_piece = std.math.divCeil(usize, bytes.len, calls.len) catch 1;
    const use = @max(piece, @max(min_piece, 1));
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len and count < calls.len) : (count += 1) {
        const end = @min(at + use, bytes.len);
        calls[count] = .{ .buffer = bytes[at..end] };
        at = end;
    }
    return count;
}

/// The spill's boundedness and retention, checked where a caller can see them:
/// between frames.
fn expectSpillBounded(spill: *const net.Spill, plan: StreamPlan) !void {
    // A spill that is not accumulating has freed its storage, not merely
    // emptied it. That is the whole reason this is a spill rather than a buffer
    // per connection.
    if (!spill.isActive()) try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
    try std.testing.expect(spill.len <= spill.buf.len);
    // What waits here is one in-flight frame, and the codec refuses a prefix
    // that reaches the cap, so the most that can be waiting is the cap plus the
    // single read that carried the prefix over it.
    const bound = plan.frame_cap + 32 + plan.read_len;
    try std.testing.expect(spill.len <= bound);
    // Capacity doubles when it grows, so it can overshoot what is waiting by up
    // to one doubling and no more.
    try std.testing.expect(spill.buf.len <= 2 * bound);
}

fn driveStream(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var raw: [max_stream_input]u8 = undefined;
    const input = raw[0..smith.slice(&raw)];
    const plan = planStream(input) orelse return;

    var read_buf: [max_read_len]u8 = undefined;
    var calls: [max_calls]std.testing.Reader.Call = undefined;
    const call_count = splitStream(plan.bytes, &calls, plan.piece);
    var test_reader = std.testing.Reader.init(read_buf[0..plan.read_len], calls[0..call_count]);
    test_reader.artificial_limit = .limited(plan.per_read);
    const reader = &test_reader.interface;

    var spill: net.Spill = .{};
    defer spill.deinit(gpa);
    var scan: net.StreamScan = .{};

    for (plan.frames, 1..) |expected, nth| {
        var frame = net.readFrameFrom(reader, gpa, .syrup, plan.frame_cap, &spill, &scan) catch |err| {
            // Every frame in the plan is whole and admissible, so a refusal here
            // means bytes went missing between the stream and the parser.
            std.debug.print(
                "frame {d} of {d} was fed whole and came back as {s}\n",
                .{ nth, plan.frames.len, @errorName(err) },
            );
            return err;
        };
        defer frame.deinit();
        try std.testing.expectEqualSlices(u8, expected, frame.bytes());
        try expectSpillBounded(&spill, plan);
    }

    // The read past the last frame. A frame here is a byte the reader invented
    // or read twice, which is why the tail's verdict is asserted rather than
    // merely the absence of a crash.
    if (net.readFrameFrom(reader, gpa, .syrup, plan.frame_cap, &spill, &scan)) |extra| {
        var frame = extra;
        frame.deinit();
        std.debug.print(
            "the stream held {d} frames and a {t} tail, and a further frame was read\n",
            .{ plan.frames.len, plan.tail },
        );
        return error.FrameAfterStreamEnd;
    } else |err| {
        try std.testing.expectEqual(plan.tail.verdict(), err);
    }
    try expectSpillBounded(&spill, plan);
}

/// The geometry this target claims for itself, checked rather than asserted in
/// prose.
///
/// Each of these was wrong at some point in some target's life, and every one of
/// them fails silently: a corpus frame that no longer decodes, a synthesized
/// frame that stops crossing the threshold it exists to cross, or a tail the
/// stream ends before the cap can refuse it, all leave a target that passes
/// while searching a smaller space than its header claims.
fn ratifyStreamShapes() !void {
    for (seeds.message_seeds) |entry| {
        const frame = entry[4..];
        // Two bytes at least, so a truncated tail has somewhere to cut, and
        // inside the smaller of the two caps, so every corpus frame is
        // admissible under either.
        try std.testing.expect(frame.len >= 2);
        try std.testing.expect(frame.len <= small_frame_cap);
        var scan: net.StreamScan = .{};
        const prefix = codec.dispatch.framePrefix(.syrup, frame, &scan, small_frame_cap);
        try std.testing.expect(prefix == .complete);
        try std.testing.expectEqual(frame.len, prefix.complete);
    }

    // The synthesized frame, at both ends of the argument count the plan can
    // choose: one whole frame, over the scan threshold, under the large cap.
    for ([_]u8{ 0, 31 }) |step| {
        const big = synthesizeDeliver(&big_frame_buf, big_frame_floor + @as(usize, step) * 128);
        try std.testing.expect(big.len > codec.framing.scan_threshold_bytes);
        try std.testing.expect(big.len <= large_frame_cap);
        var scan: net.StreamScan = .{};
        const prefix = codec.dispatch.framePrefix(.syrup, big, &scan, large_frame_cap);
        try std.testing.expect(prefix == .complete);
        try std.testing.expectEqual(big.len, prefix.complete);
    }

    // The outer length is the byte-stream allocation bound: a declaration over
    // the frame cap is refused before any body bytes arrive.
    for ([_]usize{ small_frame_cap, large_frame_cap }) |cap| {
        var prefix_buf: [32]u8 = undefined;
        const at_cap = try std.fmt.bufPrint(&prefix_buf, "{d}:", .{cap});
        try std.testing.expect(pancake.net.outerPrefix(at_cap, cap) == .incomplete);
        const over_cap = try std.fmt.bufPrint(&prefix_buf, "{d}:", .{cap + 1});
        try std.testing.expect(pancake.net.outerPrefix(over_cap, cap) == .too_large);
    }
}

test "fuzz: a frame stream returns every frame fed to it whole, in order, once" {
    try ratifyStreamShapes();
    // No shaped seeds: an input here is a stream plan, not a frame, so a corpus
    // frame would be read as a geometry and a list of indices. The regressions
    // still replay, so a stream that broke the reader once runs on every
    // ordinary suite from then on.
    try std.testing.fuzz({}, driveStream, .{ .corpus = stream_regression_seeds[0..] });
}
