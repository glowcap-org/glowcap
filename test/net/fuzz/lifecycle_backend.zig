//! The completion backend whose every choice is the fuzzer's, for the
//! lifecycle-accounting target in `test/net/fuzz_test.zig`: submissions are
//! recorded and completed in whatever order the drawn schedule asks for, with
//! whatever result it asks for. The schedule storage lives here because the
//! backend reads it from callbacks the loop makes, not from the test body.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const net = glowcap.net;
const engine = glowcap.ocapn.engine;
const completion = net.completion;
const bounds = @import("bounds.zig");
const max_input = bounds.max_input;
const frame_cap = bounds.frame_cap;
const handshake = @import("../../support/handshake.zig");

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
pub fn buildHello(allocator: std.mem.Allocator) void {
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
pub const DialAnything = struct {
    pub fn resolve(locator: model.PeerLocator) error{UnsupportedTransport}!void {
        _ = locator;
    }
};

/// The schedule, as a flat byte string the backend reads decisions from.
///
/// It is drawn once, as a slice, rather than a value per decision. The fuzzer
/// keys each drawn value on the return address of the call that drew it, so
/// asking for one byte at a time from inside the backend gives every decision
/// in the whole run the same identity, and the search cannot tell one from
/// another. Measured: a byte at a time explored around two hundred distinct
/// paths per two hundred thousand runs. A slice is a string the mutator can
/// splice, and the position in it is what distinguishes the decisions.
pub var schedule: []const u8 = &.{};

/// Storage behind `schedule`, at file scope because the backend reads it from
/// callbacks the loop makes, not from the test body.
pub var schedule_buf: [max_input]u8 = undefined;

/// How many completions one input drives before the loop is drained. A bound,
/// not a policy: without it a schedule that keeps accepting connections never
/// reaches the assertions.
pub const max_steps = 96;

/// Most completions the backend hands back from one poll. More than one is the
/// point: the loop's batch contract only exists because a failure part-way
/// through a batch must not abandon the completions behind it.
pub const max_batch = 4;

/// Connection slots the loop is built with. Small on purpose: reuse is what
/// makes slot identity and free-list bookkeeping matter, and four slots reuse
/// constantly where a thousand would never wrap.
pub const max_slots = 4;

/// A backend whose every choice is the fuzzer's. Submissions are recorded and
/// completed in whatever order the schedule asks for, with whatever result it
/// asks for, which is the part a hand-written script cannot cover.
pub const LifecycleBackend = struct {
    pub const Fd = i32;
    pub const ConnectTarget = void;

    pub fn applyKeepalive(_: *LifecycleBackend, _: Fd, _: net.completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn wireFraming(_: *LifecycleBackend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
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
    pub fn draw(self: *LifecycleBackend) u8 {
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

    pub const ListenTarget = u16;

    pub fn loopListenTarget(port: u16) ListenTarget {
        return port;
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

    pub fn recycleBorrowed(self: *LifecycleBackend, comp: completion.Completion) void {
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
                        .borrowed = .recv(junk[0..hello.len], 0),
                    };
                }
                const len = @as(usize, verdict % 32) + 1;
                for (junk[0..len], 0..) |*b, i| b.* = verdict +% @as(u8, @intCast(i));
                break :blk .{
                    .user_data = op.user_data,
                    .result = @intCast(len),
                    .borrowed = .recv(junk[0..len], 0),
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
