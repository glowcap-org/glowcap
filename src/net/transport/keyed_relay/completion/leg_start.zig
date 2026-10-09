//! Admission of one relay leg: reserve its row, render its upgrade request,
//! and start the bounded address race that picks its socket.
//!
//! A caller's dial and the listener's registration admit legs the same way.
//! They differ only in the request they render and in who waits on the
//! result: a dial leg owns the caller's connect seat, while a registration
//! leg has no seat and answers to the registration that started it.

const std = @import("std");

const route = @import("../route.zig");

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Machines: type,
    comptime DialRace: type,
    comptime resolver_wake_ud: u64,
) type {
    return struct {
        const RelayConn = Types.RelayConn;
        const PendingDial = Types.PendingDial;
        const Identity = Types.Identity;
        const Tls = Machines.Tls;
        const Dispatch = Machines.Dispatch;
        const Lifecycle = Machines.Lifecycle;

        pub const Request = struct {
            url: route.RelayUrl,
            leg: route.Leg,
            /// The designator a dial names, or the hex id a registration holds.
            query_value: []const u8,
            /// The caller's connect seat; a registration leg has none.
            connect_ud: ?u64,
        };

        /// A row id is held by the admitted table, by the still-opening table,
        /// and by the registration while it tracks a leg it started;
        /// reservation must skip all three.
        const RowOccupancy = struct {
            backend: *const Backend,

            pub fn contains(occupancy: RowOccupancy, id: Types.ConnId) bool {
                return occupancy.backend.conns.contains(id) or
                    occupancy.backend.pending_dials.contains(id) or
                    occupancy.backend.registration.holds(id);
            }
        };

        /// Admit one leg and return its synthetic handle.
        pub fn start(backend: *Backend, request: Request) !Backend.Fd {
            const relay_url = request.url;
            const secure_lease = if (relay_url.scheme.secure())
                if (backend.relay) |relay| relay.tls orelse
                    return error.SecureCarrierUnavailable else return error.SecureCarrierUnavailable
            else
                null;
            const id = try Identity.reserveId(&backend.next_id, RowOccupancy{ .backend = backend });
            errdefer backend.next_id = id;
            const fd = try Identity.fdFromId(id);
            try backend.conns.ensureUnusedCapacity(backend.allocator, 1);
            try backend.pending_dials.ensureUnusedCapacity(backend.allocator, 1);
            try backend.ready.ensureUnusedCapacity(backend.allocator, 2);
            const c = try backend.allocator.create(RelayConn);
            errdefer backend.allocator.destroy(c);
            c.* = .{
                .id = id,
                .inner_fd = undefined,
                .external_connect_ud = request.connect_ud,
                .expected_accept = undefined,
            };
            errdefer c.deinit(backend.allocator);
            if (secure_lease != null) try Tls.prepare(backend, c);
            errdefer Tls.destroy(backend, c);
            // Rendering completes synchronously, so no query copy belongs in
            // the admitted connection's scale footprint.
            try Dispatch.buildUpgrade(backend, c, relay_url, request.leg, request.query_value);
            const pending = try backend.allocator.create(PendingDial);
            pending.* = .{ .id = id, .conn = c };
            backend.pending_dials.putAssumeCapacity(id, pending);
            var admitted = true;
            errdefer if (admitted) {
                std.debug.assert(backend.pending_dials.remove(id));
                backend.allocator.destroy(pending);
            };
            if (std.Io.net.IpAddress.parse(relay_url.host, relay_url.port)) |address| {
                try DialRace.startLiteral(backend, pending, address);
            } else |_| {
                const resolver = backend.resolver orelse return error.ResolverUnavailable;
                pending.resolver_job = try resolver.start(id, relay_url.host, relay_url.port);
                resolver.maintainWake(backend, resolver_wake_ud);
            }
            if (secure_lease) |lease| switch (lease.open(relay_url.host)) {
                .client => |client| Tls.adoptClient(backend, c, client),
                .failed => |failure| {
                    Tls.abandonPending(backend, c);
                    DialRace.failAdmitted(
                        backend,
                        pending,
                        Types.TlsState.fromTlsFailure(failure),
                    );
                    admitted = false;
                    return fd;
                },
            };
            admitted = false;
            return fd;
        }

        /// Hand the race's sole surviving socket to the leg and continue it.
        pub fn adoptWinner(backend: *Backend, pending: *PendingDial, winner_fd: Backend.Fd) void {
            const c = pending.conn;
            c.inner_fd = winner_fd;
            backend.conns.putAssumeCapacity(c.id, c);
            backend.allocator.destroy(pending);
            Dispatch.connected(backend, c) catch |err| {
                Lifecycle.failWith(backend, c, .websocket_upgrade, err);
                Lifecycle.beginPlatformClose(backend, c);
            };
        }

        pub fn destroyPending(backend: *Backend, pending: *PendingDial) void {
            Tls.destroy(backend, pending.conn);
            pending.conn.deinit(backend.allocator);
            backend.allocator.destroy(pending.conn);
            backend.allocator.destroy(pending);
        }
    };
}
