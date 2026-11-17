//! `driver.Server` over a real 127.0.0.1 listener while its allocator refuses
//! one allocation per run: a refusal inside an arrival's admission retires
//! that arrival, releases its queue reservation once, and leaves the next
//! partner accepted on the same listener. `Server.close` asserts the
//! reservation balance, so a double or missed release fails here.

const std = @import("std");
const glowcap = @import("glowcap");
const FailingOnce = @import("../support/failing_once.zig").FailingOnce;
const wait = @import("../support/wait.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 2_000 },
    .settle = .{ .ms = 2_000 },
};

/// A partner that completes the keyed handshake, or is refused: the server's
/// refusal is what the test reads, not this dial's result. A dial that
/// completes holds its session open until `Dial.finish`, so its own teardown
/// cannot reach the server while the server is still admitting it.
fn dialOnce(io: std.Io, address: std.Io.net.IpAddress, allocator: std.mem.Allocator, dial: *Dial) void {
    var buf: [64]u8 = undefined;
    const started = std.Io.Timestamp.now(io, .real);
    var session = driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, opts) catch |err| {
        dial.connect_error = err;
        dial.connect_ms = started.untilNow(io, .real).toMilliseconds();
        return;
    };
    defer session.deinit();
    dial.connected = true;
    dial.connect_ms = started.untilNow(io, .real).toMilliseconds();
    wait.untilFlag(io, wait.default_deadline_ms, &dial.hold) catch return; // tolerant: the deadline only bounds this fixture's own wait; the server-side asserts decide the test
}

/// One concurrent dial. `finish` releases the partner and joins it, once, so
/// an assertion that unwinds the test cannot leave the dial running. The dial
/// thread writes its outcome fields, and they are read only after `finish`.
const Dial = struct {
    hold: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(void) = undefined,
    joined: bool = true,
    connected: bool = false,
    connect_error: ?anyerror = null,
    connect_ms: i64 = -1,

    fn start(self: *Dial, io: std.Io, address: std.Io.net.IpAddress) !void {
        self.future = try io.concurrent(dialOnce, .{ io, address, std.testing.allocator, self });
        self.joined = false;
    }

    fn finish(self: *Dial, io: std.Io) void {
        if (self.joined) return;
        self.joined = true;
        self.hold.store(true, .release);
        self.future.await(io);
    }
};

/// What one sweep run saw, printed only when the run fails: which allocation
/// the injection refused (index, size and the stack that asked for it, saved
/// when the refusal landed so later runs and disabled injection cannot
/// replace it), how each accept ended and how long it took, and how each dial
/// ended. It separates a handshake that timed out from one that lost progress
/// before the deadline.
const Observed = struct {
    index: usize,
    induced: bool = false,
    refused_len: usize = 0,
    stack: [16]usize = @splat(0),
    stack_len: usize = 0,
    stack_skipped: @FieldType(std.debug.StackTrace, "skipped") = .none,
    arrival_ms: i64 = -1,
    arrival_error: ?anyerror = null,
    next_ms: i64 = -1,
    next_error: ?anyerror = null,
    first: ?*const Dial = null,
    second: ?*const Dial = null,

    fn captureRefusal(self: *Observed, failing: *FailingOnce) void {
        self.induced = failing.induced;
        if (!self.induced) return;
        self.refused_len = failing.refused_len;
        const trace = failing.stackTrace();
        self.stack_len = trace.return_addresses.len;
        @memcpy(self.stack[0..self.stack_len], trace.return_addresses);
        self.stack_skipped = trace.skipped;
    }

    fn report(self: *const Observed) void {
        std.debug.print("sweep index {d}: refused={} len={d}\n", .{ self.index, self.induced, self.refused_len });
        std.debug.print("  first accept: {s} after {d} ms\n", .{ if (self.arrival_error) |err| @errorName(err) else "session", self.arrival_ms });
        std.debug.print("  next accept: {s} after {d} ms\n", .{ if (self.next_error) |err| @errorName(err) else "session", self.next_ms });
        inline for (.{ .{ "first", self.first }, .{ "second", self.second } }) |entry| {
            if (entry[1]) |dial| std.debug.print("  {s} dial: {s} after {d} ms\n", .{ entry[0], if (dial.connect_error) |err| @errorName(err) else if (dial.connected) "connected" else "not finished", dial.connect_ms });
        }
        if (self.stack_len != 0) {
            std.debug.print("  refused allocation requested at:\n", .{});
            var saved = self.stack;
            const trace: std.debug.StackTrace = .{ .return_addresses = saved[0..self.stack_len], .skipped = self.stack_skipped };
            std.debug.dumpStackTrace(&trace);
        }
    }
};

/// Release an accepted session, if the accept produced one.
fn release(result: anyerror!*driver.Session) void {
    const session = result catch return; // tolerant: a refused accept holds nothing
    session.deinit();
}

/// An arrival the listener could not survive: the provider's own accept latched
/// (`ProviderContract`) or the listener closed (`ServerClosed`), the two ways
/// `Server.accept` reports an ended listener. A timeout or any other error fails.
fn expectListenerEnded(err: anyerror, losses: *usize) !void {
    try expectOneOf(err, &.{ error.ServerClosed, error.ProviderContract });
    losses.* += 1;
}

/// Fail unless `err` is one of `allowed`, and name it when it is not.
fn expectOneOf(err: anyerror, allowed: []const anyerror) !void {
    for (allowed) |one| if (err == one) return;
    std.debug.print("unexpected accept error: {s}\n", .{@errorName(err)});
    return error.TestUnexpectedResult;
}

test "Server: a refused allocation retires that arrival and the next partner is accepted" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session_sized_refusals: usize = 0;
    var other_refusals: usize = 0;
    var listener_losses: usize = 0;
    var index: usize = 0;
    while (index < 200) : (index += 1) {
        var failing = FailingOnce.init(std.testing.allocator, std.math.maxInt(usize));
        var clean = false;
        {
            const server = try driver.listen(failing.allocator(), io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
            defer server.deinit();
            var addr_buf: [64]u8 = undefined;
            const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

            var seen: Observed = .{ .index = index };
            errdefer seen.report();
            failing.fail_index = failing.alloc_index + index;
            var first: Dial = .{};
            try first.start(io, address);
            defer first.finish(io);
            const arrival_started = std.Io.Timestamp.now(io, .real);
            const arrival = server.accept();
            seen.arrival_ms = arrival_started.untilNow(io, .real).toMilliseconds();
            seen.arrival_error = if (arrival) |_| null else |err| err;
            defer release(arrival);
            seen.captureRefusal(&failing);
            const induced = seen.induced;
            const refused_len = seen.refused_len;
            failing.fail_index = std.math.maxInt(usize);
            first.finish(io);
            seen.first = &first;
            var second: Dial = .{};
            try second.start(io, address);
            defer second.finish(io);
            seen.second = &second;
            const next_started = std.Io.Timestamp.now(io, .real);
            const next = server.accept();
            seen.next_ms = next_started.untilNow(io, .real).toMilliseconds();
            seen.next_error = if (next) |_| null else |err| err;
            defer release(next);

            if (!induced) {
                // Nothing was refused: both arrivals are accepted.
                clean = true;
                _ = try arrival;
                _ = try next;
            } else if (arrival) |_| {
                // The refusal landed outside this arrival's admission.
                if (next) |_| {} else |next_err| try expectListenerEnded(next_err, &listener_losses);
                other_refusals += 1;
            } else |err| {
                if (refused_len == @sizeOf(driver.Session)) {
                    // A refusal of this size is a Session-sized probe: several
                    // allocations share it, so it attributes nothing alone.
                    // The mutation run on `Server.opened` shows the adopt
                    // path is among them. Whatever the site, the arrival
                    // retires as `OutOfMemory` and the listener serves the
                    // next partner.
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    _ = try next;
                    session_sized_refusals += 1;
                } else {
                    // Other sites are owned by the runtime's admission stages,
                    // the stream provider's accept (`ProviderContract` once it
                    // latches) and the handshake read (`ConnectionClosed`).
                    try expectOneOf(err, &.{ error.OutOfMemory, error.ProviderContract, error.ConnectionClosed });
                    if (next) |_| {} else |next_err| try expectListenerEnded(next_err, &listener_losses);
                    other_refusals += 1;
                }
            }
            second.finish(io);
            // `close` asserts the reservation balance in every run.
            const closed = server.close();
            if (clean or refused_len == @sizeOf(driver.Session)) try std.testing.expect(closed == null);
        }
        try std.testing.expect(failing.balanced());
        if (clean) break;
    }
    try std.testing.expect(index < 200);
    try std.testing.expect(session_sized_refusals >= 1);
    try std.testing.expect(listener_losses < other_refusals);
}
