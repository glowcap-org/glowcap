//! The listening half of the completion relay: one registration leg held at
//! the relay for this backend's identity, replaced whenever it is promoted,
//! refused, or lost.
//!
//! A registration leg is an ordinary relay leg (`leg_start.zig`) that renders
//! a `register` request and owns no connect seat. Once upgraded it parks
//! (`Receive.serviceParked`), answering the relay's controls, until the first
//! application frame says a dialer arrived. It is then promoted to an open
//! connection that the listener's accept hands to the Loop.
//!
//! The registration tracks every leg it started until that leg leaves the
//! backend's tables, and row reservation skips a tracked id, so a retired id
//! cannot be reissued while this module still names it. Its legs retire only
//! inside a poll turn, from platform completions or from the release this
//! module makes for a leg that ended with no seat to close it. `service` runs
//! at both ends of every turn, so it observes each retirement in the turn
//! that caused it and starts the replacement before the turn sleeps.
//!
//! A relay that refuses or drops registration is retried every
//! `registration_retry_ms` for as long as the listener is open.

const std = @import("std");

const foundation = @import("foundation");
const clock = @import("../../../clock.zig");
const options = @import("options.zig");
const route = @import("../route.zig");

const crypto = foundation.crypto;
const max_unaccepted = options.max_unaccepted_registrations;

pub const ConnId = u32;

const Tracked = struct {
    id: ConnId,
    /// This module asked the backend to close the leg's handle.
    released: bool = false,
};

pub const State = struct {
    config: ?Config = null,
    listening: bool = false,
    /// The leg waiting at the relay, from admission until promotion.
    leg: ?Tracked = null,
    /// Promoted legs the Loop has not accepted, oldest first.
    unaccepted: [max_unaccepted]Tracked = undefined,
    unaccepted_len: usize = 0,
    accept_ud: ?u64 = null,
    close_ud: ?u64 = null,
    /// Monotonic time before which no replacement leg starts.
    retry_at_ms: i64 = 0,
    /// A turn could not reserve its completion seats. The next turn retries.
    owed: bool = false,

    pub const Config = struct {
        /// Sole owner of every slice in `url`.
        url_bytes: []u8,
        url: route.RelayUrl,
        /// The listening Host's key as a designator, set when the listener
        /// opens.
        id: [crypto.PeerKey.designator_len]u8 = undefined,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        registration: ?options.Registration,
    ) !State {
        const configured = registration orelse return .{};
        const url_bytes = try allocator.dupe(u8, configured.url);
        errdefer allocator.free(url_bytes);
        return .{ .config = .{
            .url_bytes = url_bytes,
            .url = try route.RelayUrl.parse(url_bytes),
        } };
    }

    /// The owning Loop closed the listener and drained it first.
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        std.debug.assert(!self.listening and self.leg == null and self.unaccepted_len == 0);
        std.debug.assert(self.accept_ud == null and self.close_ud == null);
        if (self.config) |config| allocator.free(config.url_bytes);
    }

    pub fn holds(self: *const State, id: ConnId) bool {
        if (self.isLeg(id)) return true;
        for (self.unaccepted[0..self.unaccepted_len]) |tracked|
            if (tracked.id == id) return true;
        return false;
    }

    pub fn isLeg(self: *const State, id: ConnId) bool {
        const leg = self.leg orelse return false;
        return leg.id == id;
    }

    fn rowCount(self: *const State) usize {
        return self.unaccepted_len + @intFromBool(self.leg != null);
    }
};

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Namespace: type,
    comptime LegStart: type,
    comptime operation_retry_ms: i32,
) type {
    return struct {
        const Fd = Backend.Fd;
        const Identity = Types.Identity;

        /// The listener handle. Row ids start at one, so it names no leg.
        pub const listen_fd: Fd = Namespace.fdFromComptimeId(0);

        /// Start registering `identity` at the next turn.
        pub fn open(backend: *Backend, identity: crypto.PeerKey) !Fd {
            const reg = &backend.registration;
            if (reg.listening or reg.close_ud != null) return error.AddressInUse;
            reg.config.?.id = identity.toDesignator();
            reg.listening = true;
            reg.retry_at_ms = 0;
            return listen_fd;
        }

        pub fn submitAccept(backend: *Backend, user_data: u64) !void {
            const reg = &backend.registration;
            if (!reg.listening) return error.ListenerClosed;
            if (reg.accept_ud != null) return error.AlreadyAccepting;
            try backend.ready.ensureUnusedCapacity(backend.allocator, 1);
            reg.accept_ud = user_data;
            handOff(backend);
        }

        /// Stop registering and publish the close once every leg retires.
        pub fn submitClose(backend: *Backend, user_data: u64) !void {
            const reg = &backend.registration;
            if (reg.close_ud != null) return error.AlreadyClosing;
            try backend.ready.ensureUnusedCapacity(backend.allocator, 2);
            if (reg.accept_ud) |ud| {
                backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                reg.accept_ud = null;
            }
            reg.close_ud = user_data;
            stop(backend);
            finishClose(backend);
        }

        /// Release the listener with nothing waiting on it.
        pub fn release(backend: *Backend) void {
            std.debug.assert(backend.registration.accept_ud == null);
            stop(backend);
        }

        /// The current leg's first application frame arrived.
        pub fn promote(backend: *Backend, c: *Types.RelayConn) void {
            const reg = &backend.registration;
            std.debug.assert(reg.isLeg(c.id) and reg.unaccepted_len < max_unaccepted);
            c.state = .open;
            reg.unaccepted[reg.unaccepted_len] = reg.leg.?;
            reg.unaccepted_len += 1;
            reg.leg = null;
            reg.retry_at_ms = 0;
        }

        /// Reap retired legs, hand promoted legs to a waiting accept, publish
        /// a finished close, and start the replacement leg that is due.
        pub fn service(backend: *Backend) void {
            const reg = &backend.registration;
            if (reg.config == null) return;
            if (!reg.listening and reg.close_ud == null and reg.rowCount() == 0) return;
            backend.ready.ensureUnusedCapacity(backend.allocator, 2) catch {
                // tolerant: the next turn retries within `operation_retry_ms`.
                reg.owed = true;
                return;
            };
            reg.owed = false;
            if (reg.leg) |*leg| if (!track(backend, leg)) {
                reg.leg = null;
                reg.retry_at_ms = clock.nowMonotonicMs() + options.registration_retry_ms;
            };
            var kept: usize = 0;
            for (0..reg.unaccepted_len) |index| {
                var tracked = reg.unaccepted[index];
                if (!track(backend, &tracked)) continue;
                reg.unaccepted[kept] = tracked;
                kept += 1;
            }
            reg.unaccepted_len = kept;
            finishClose(backend);
            handOff(backend);
            startDue(backend);
        }

        /// How long a turn may sleep before this module owes work.
        pub fn waitMs(backend: *const Backend) ?i32 {
            const reg = &backend.registration;
            if (reg.owed) return operation_retry_ms;
            if (!reg.listening or reg.leg != null or reg.unaccepted_len == max_unaccepted)
                return null;
            const remaining = reg.retry_at_ms - clock.nowMonotonicMs();
            return @intCast(std.math.clamp(remaining, 0, std.math.maxInt(i32)));
        }

        fn stop(backend: *Backend) void {
            const reg = &backend.registration;
            reg.listening = false;
            if (reg.leg) |*leg| releaseTracked(backend, leg);
            for (reg.unaccepted[0..reg.unaccepted_len]) |*tracked| releaseTracked(backend, tracked);
        }

        /// Whether the leg is still in the backend's tables. A leg that ended
        /// has no Loop seat to close it, so this module releases its handle.
        fn track(backend: *Backend, tracked: *Tracked) bool {
            if (backend.conns.get(tracked.id)) |c| {
                if (c.state == .closing) releaseTracked(backend, tracked);
            }
            return backend.conns.contains(tracked.id) or
                backend.pending_dials.contains(tracked.id);
        }

        fn releaseTracked(backend: *Backend, tracked: *Tracked) void {
            if (tracked.released) return;
            tracked.released = true;
            backend.closeFd(Identity.fdFromId(tracked.id) catch unreachable);
        }

        fn finishClose(backend: *Backend) void {
            const reg = &backend.registration;
            const ud = reg.close_ud orelse return;
            if (reg.rowCount() != 0) return;
            backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
            reg.close_ud = null;
        }

        fn handOff(backend: *Backend) void {
            const reg = &backend.registration;
            const ud = reg.accept_ud orelse return;
            if (reg.unaccepted_len == 0) return;
            const accepted = reg.unaccepted[0];
            std.mem.copyForwards(
                Tracked,
                reg.unaccepted[0 .. reg.unaccepted_len - 1],
                reg.unaccepted[1..reg.unaccepted_len],
            );
            reg.unaccepted_len -= 1;
            reg.accept_ud = null;
            backend.ready.appendAssumeCapacity(.{
                .user_data = ud,
                .result = 0,
                .accepted_fd = Identity.fdFromId(accepted.id) catch unreachable,
            });
        }

        fn startDue(backend: *Backend) void {
            const reg = &backend.registration;
            if (!reg.listening or reg.leg != null or reg.unaccepted_len == max_unaccepted) return;
            const now = clock.nowMonotonicMs();
            if (now < reg.retry_at_ms) return;
            const config = &reg.config.?;
            const fd = LegStart.start(backend, .{
                .url = config.url,
                .leg = .register,
                .query_value = &config.id,
                .connect_ud = null,
            }) catch {
                // tolerant: a refused admission is pressure on this turn;
                // the leg is retried after the registration delay.
                reg.retry_at_ms = now + options.registration_retry_ms;
                return;
            };
            reg.leg = .{ .id = Identity.idFromFd(fd).? };
        }
    };
}
