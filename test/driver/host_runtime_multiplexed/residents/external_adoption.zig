//! The external-adoption fixtures the lifecycle and parked-input scenarios
//! share: a resident that claims one connection the embedder hands in, and a
//! recorder for the open and close outcomes the runtime publishes.
//! `residents.zig` re-exports them.

const std = @import("std");
const glowcap = @import("glowcap");
const residents = @import("../residents.zig");

const driver = glowcap.driver;
const driver_core = driver.core;
const net = glowcap.net;

const opts = residents.opts;

/// A resident that claims one external connection. A read hands over the
/// next `inbound` packet. With none left it ends the stream, unless
/// `read_result` holds the connection open. A close stays pending until
/// `close_ready`, then fails with a cleanup consequence.
///
/// A scenario that watches the write side closes the window with
/// `write_open = false`: a write answers `would_block` and the next opening
/// reports one writable record. Setting `record_writes` keeps every byte
/// written in `written`. With `edge_reads`, a read record is reported once
/// per `offer`, as a real resident reports a drained record once, while
/// the packets it did not hand over stay in `inbound`. Without it, every
/// drain reports a read record while `inbound` holds a packet. `signal_closed`
/// adds one closed bit to the next drained record, with the readable bit when
/// a read record is due, even with nothing left to read, because a clean end
/// of stream stays readable until a read reaches it. `written_target`
/// raises `written_reached` once that many bytes were written, and
/// `close_completes` has a close finish within its verb. With
/// `departs_on_close`, the closed bit also ends the partner for good: every
/// later write answers would-block and no writable record follows, as a
/// transport that lost its peer reports. `write_attempts` counts every write
/// and `write_fails` answers each with a fault.
pub const ExternalAdoptionResident = struct {
    wake: net.wake_channel.WakeChannel,
    close_calls: usize = 0,
    close_ready: bool = false,
    read_result: isize = 0,
    inbound: []const []const u8 = &.{},
    write_open: bool = true,
    want_write: bool = false,
    write_blocks: usize = 0,
    record_writes: ?std.mem.Allocator = null,
    written: std.ArrayList(u8) = .empty,
    /// The length of `written` after each write, so a message-framed wire's
    /// packets can be cut again.
    write_ends: std.ArrayList(usize) = .empty,
    edge_reads: bool = false,
    read_armed: bool = false,
    signal_closed: bool = false,
    close_completes: bool = false,
    written_target: usize = 0,
    written_reached: bool = false,
    departs_on_close: bool = false,
    departed: bool = false,
    write_attempts: usize = 0,
    write_fails: bool = false,

    pub const transport = "external-close";
    pub const conn_id: usize = 9;

    pub fn multiplexedResident(self: *ExternalAdoptionResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// The same resident reading through the borrowed-read group: a lent
    /// packet stays at the head of `inbound` until its release.
    pub fn lendingResident(self: *ExternalAdoptionResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &lending_vtable };
    }

    /// Release what `record_writes` kept.
    pub fn deinit(self: *ExternalAdoptionResident) void {
        if (self.record_writes) |allocator| {
            self.written.deinit(allocator);
            self.write_ends.deinit(allocator);
        }
        self.wake.deinit();
    }

    /// Hand the connection `packets` to read and report one read record.
    pub fn offer(self: *ExternalAdoptionResident, packets: []const []const u8) void {
        self.inbound = packets;
        self.read_armed = true;
    }

    const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .external_claim = .{ .claim_external = claimExternal },
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_remote_key = connRemoteKey,
    };

    const lending_vtable = lending: {
        var lending = vtable;
        lending.borrowed_read = .{ .lend = lend, .release = release };
        break :lending lending;
    };

    fn lend(ctx: *anyopaque, _: usize) net.multiplexed_resident.borrowed_read.Lend {
        const self = of(ctx);
        if (self.inbound.len != 0) return .{ .bytes = self.inbound[0] };
        if (self.read_result == net.multiplexed_resident.would_block) return .would_block;
        return if (self.read_result == 0) .end_of_stream else .dead;
    }

    fn release(ctx: *anyopaque, _: usize) void {
        const self = of(ctx);
        if (self.inbound.len != 0) self.inbound = self.inbound[1..];
    }

    fn of(ctx: *anyopaque) *ExternalAdoptionResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).wake.read;
    }

    fn drainReady(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        self.wake.drain() catch return error.ProviderContract;
        if (out.len == 0) return 0;
        var events: u32 = 0;
        if (self.close_ready) {
            events = net.multiplexed_resident.ev_closed;
        } else {
            if ((self.inbound.len > 0 or self.signal_closed) and (!self.edge_reads or self.read_armed)) {
                events |= net.multiplexed_resident.ev_readable;
                self.read_armed = false;
            }
            if (self.want_write and self.write_open) {
                events |= net.multiplexed_resident.ev_writable;
                self.want_write = false;
            }
        }
        if (self.signal_closed) {
            events |= net.multiplexed_resident.ev_closed;
            self.signal_closed = false;
            self.departed = self.departs_on_close;
        }
        if (events == 0) return 0;
        out[0] = .{ .subject = conn_id, .events = events };
        return 1;
    }

    fn claimExternal(_: *anyopaque, subject: usize) net.MultiplexedExternalClaimRawOutcome {
        if (subject != conn_id) return .{ .failed = .init(error.InvalidAddress) };
        return .{ .claimed = conn_id };
    }

    fn tryRead(ctx: *anyopaque, _: usize, into: []u8) isize {
        const self = of(ctx);
        if (self.inbound.len == 0) return self.read_result;
        const packet = self.inbound[0];
        self.inbound = self.inbound[1..];
        @memcpy(into[0..packet.len], packet);
        return @intCast(packet.len);
    }

    fn tryWrite(ctx: *anyopaque, _: usize, bytes: []const u8) isize {
        const self = of(ctx);
        self.write_attempts += 1;
        if (self.write_fails) return -1;
        if (self.departed) {
            self.write_blocks += 1;
            return net.multiplexed_resident.would_block;
        }
        if (!self.write_open) {
            self.write_blocks += 1;
            self.want_write = true;
            return net.multiplexed_resident.would_block;
        }
        const allocator = self.record_writes orelse return @intCast(bytes.len);
        // tolerant: a failed append is reported as a resident write fault,
        // which the runtime closes the wire for, so no byte is lost silently.
        self.written.appendSlice(allocator, bytes) catch return -1;
        // tolerant: the same resident write fault as the append above.
        self.write_ends.append(allocator, self.written.items.len) catch return -1;
        if (self.written_target != 0 and self.written.items.len >= self.written_target) self.written_reached = true;
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        std.debug.assert(conn == conn_id);
        const self = of(ctx);
        self.close_calls += 1;
        if (self.close_completes) return .complete;
        if (!self.close_ready) return .pending;
        var failure = glowcap.foundation.FailureChain.init(error.ResidentCloseFailed);
        failure.note(error.ResidentCloseCleanupFailed);
        return .{ .failed = failure };
    }

    fn connRemoteKey(_: *anyopaque, conn: usize) net.multiplexed_resident.ContractError!?glowcap.foundation.crypto.PeerKey {
        std.debug.assert(conn == conn_id);
        return glowcap.foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x5d))).publicKey();
    }
};

/// Records what the runtime tells a pending open's owner and the close
/// observer, and counts the publication seats each holds.
pub const ObservedOpen = struct {
    reservations: usize = 0,
    did_open: bool = false,
    session: ?*driver_core.HostSession = null,
    failure: ?anyerror = null,
    failure_detail: ?driver.OperationFailure = null,
    close_events: usize = 0,
    close_failure: ?anyerror = null,
    close_tail: usize = 0,
    /// The answers the session had accepted from its partner when the close
    /// arrived: one per request dispatched.
    close_inbound_answers: usize = 0,

    fn of(ctx: *anyopaque) *ObservedOpen {
        return @ptrCast(@alignCast(ctx));
    }

    pub fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
        of(ctx).reservations += 1;
    }

    pub fn release(ctx: *anyopaque, _: u64) void {
        const self = of(ctx);
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    fn reserveClose(ctx: *anyopaque) anyerror!void {
        of(ctx).reservations += 1;
    }

    fn releaseClose(ctx: *anyopaque) void {
        const self = of(ctx);
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    pub fn opened(ctx: *anyopaque, _: u64, session: *driver_core.HostSession) !void {
        const self = of(ctx);
        release(ctx, 0);
        self.did_open = true;
        self.session = session;
    }

    pub fn failed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self = of(ctx);
        release(ctx, 0);
        self.failure = failure.chain.cause;
        self.failure_detail = failure;
    }

    fn closed(ctx: *anyopaque, session: *driver_core.HostSession, failure: ?driver.OperationFailure) void {
        const self = of(ctx);
        releaseClose(ctx);
        self.close_events += 1;
        self.close_failure = if (failure) |f| f.chain.cause else null;
        self.close_tail = session.feed_tail.len;
        self.close_inbound_answers = session.served.port.peer.session_state.inbound_answers.len();
    }

    /// Completions are not under test here: refuse each, so the drain frees it.
    fn discard(_: *anyopaque, _: driver_core.HostAction) bool {
        return false;
    }

    /// `opts` on the stepped face, publishing closes to this recorder.
    pub fn steppedOpts(self: *ObservedOpen) driver.SessionOptions {
        var options = opts;
        options.drive = .{ .stepped = .{
            .completion_sink = .{ .ctx = self, .take = discard },
            .close_observer = .{
                .ctx = self,
                .reserve = reserveClose,
                .release = releaseClose,
                .closed = closed,
            },
        } };
        return options;
    }
};
