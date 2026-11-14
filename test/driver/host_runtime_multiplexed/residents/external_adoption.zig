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
pub const ExternalAdoptionResident = struct {
    wake: net.wake_channel.WakeChannel,
    close_calls: usize = 0,
    close_ready: bool = false,
    read_result: isize = 0,
    inbound: []const []const u8 = &.{},

    pub const transport = "external-close";
    pub const conn_id: usize = 9;

    pub fn multiplexedResident(self: *ExternalAdoptionResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
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
        const events = if (self.close_ready)
            net.multiplexed_resident.ev_closed
        else if (self.inbound.len > 0)
            net.multiplexed_resident.ev_readable
        else
            return 0;
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

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        std.debug.assert(conn == conn_id);
        const self = of(ctx);
        self.close_calls += 1;
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
    failure: ?anyerror = null,
    failure_detail: ?driver.OperationFailure = null,
    close_events: usize = 0,

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

    pub fn opened(ctx: *anyopaque, _: u64, _: *driver_core.HostSession) !void {
        const self = of(ctx);
        release(ctx, 0);
        self.did_open = true;
    }

    pub fn failed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self = of(ctx);
        release(ctx, 0);
        self.failure = failure.chain.cause;
        self.failure_detail = failure;
    }

    fn closed(ctx: *anyopaque, _: *driver_core.HostSession, _: ?driver.OperationFailure) void {
        const self = of(ctx);
        releaseClose(ctx);
        self.close_events += 1;
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
