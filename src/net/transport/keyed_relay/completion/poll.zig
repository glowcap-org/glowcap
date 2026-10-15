//! One completion turn for the keyed-relay adapter.
//!
//! The backend owns state and public verbs. This module owns the turn-level
//! order: drain resolver completions, retry owed internal submissions, service
//! the registration, poll the wrapped platform, dispatch each returned
//! completion, service the registration again, then drain ready external
//! completions.

const completion = @import("../../../completion/loop.zig");

/// The most records one pass of the wrapped platform hands up at once, the
/// bound the ready reserve projects from. The resident asks for fewer.
const pass_records = 256;

pub fn Machine(
    comptime Backend: type,
    comptime Access: type,
    comptime operation_retry_ms: i32,
    comptime resolver_wake_ud: u64,
) type {
    return struct {
        pub fn poll(backend: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
            return collect(backend, out, timeout_ms);
        }

        pub fn peek(backend: *Backend, out: []completion.Completion) !usize {
            return collect(backend, out, null);
        }

        /// `wait_ms` null reaps what the platform already completed and
        /// submits nothing.
        fn collect(backend: *Backend, out: []completion.Completion, wait_ms: ?i32) !usize {
            if (idle(backend)) return completion.passThrough(&backend.platform, out, wait_ms);
            serviceResolver(backend);
            Access.retryPendingDialCloses(backend);
            Access.retryPendingSecureSends(backend);
            Access.retryPendingCloses(backend);
            Access.serviceRegistration(backend);
            // Pool starvation is an owed platform arm, but polling does not
            // create capacity. Retry only after a wrapped buffer is recycled.
            if (backend.recv_recycle_progress) {
                backend.recv_recycle_progress = false;
                retryPlatformRecvStarvation(backend);
            }

            const has_ready = backend.ready.len() > 0;
            // One consumed platform completion can fail a pending connect,
            // recv, and send together. Reserve the complete projection of a
            // full pass before asking the platform to surrender any terminal
            // record.
            backend.ready.ensureUnusedCapacity(backend.allocator, pass_records * 3) catch {
                if (has_ready) return backend.ready.drain(out);
                return error.OutOfMemory;
            };

            const owed = backend.ready.drain(out);
            const room = out[owed..];
            const n = if (wait_ms) |timeout_ms|
                try backend.platform.poll(room, effectiveTimeout(backend, has_ready, timeout_ms))
            else
                try backend.platform.peek(room);
            const kept = try completion.keepForeign(room, n, @This(), backend);
            // A completion may have promoted or retired a registration leg.
            Access.serviceRegistration(backend);
            return owed + kept + backend.ready.drain(room[kept..]);
        }

        /// Nothing open, armed, or owed. Every completion this adapter owns
        /// belongs to a connection, a pending dial, the registration, or the
        /// resolver wake, and every chore serves one of those or a retry
        /// queue, so with all of them empty the pass is the platform's alone.
        /// The resolver's live count is read last because it takes a lock.
        fn idle(backend: *const Backend) bool {
            return backend.conns.count() == 0 and backend.pending_dials.count() == 0 and
                backend.registration.config == null and backend.ready.len() == 0 and
                !backend.resolver_wake_armed and backend.close_retries.count == 0 and
                backend.tls_send_retries.count == 0 and backend.recv_retries.count == 0 and
                backend.dial_close_retry_count == 0 and
                (backend.resolver == null or !backend.resolver.?.hasLiveJobs());
        }

        pub fn ownsCompletion(user_data: u64) bool {
            return user_data == resolver_wake_ud or Access.isDialInternal(user_data) or Access.isInternal(user_data);
        }

        pub fn dispatchOwned(backend: *Backend, comp: completion.Completion) !void {
            if (comp.user_data == resolver_wake_ud) {
                try resolverWake(backend, comp);
            } else if (Access.isDialInternal(comp.user_data)) {
                Access.dispatchDial(backend, comp);
            } else {
                Access.dispatchInternal(backend, comp);
            }
        }

        fn serviceResolver(backend: *Backend) void {
            const resolver = backend.resolver orelse return;
            while (resolver.takeCompleted()) |job|
                Access.resolverCompleted(backend, job);
            if (resolver.hasLiveJobs() and !backend.resolver_wake_armed)
                resolver.maintainWake(backend, resolver_wake_ud);
        }

        fn resolverWake(backend: *Backend, comp: completion.Completion) !void {
            backend.resolver_wake_armed = false;
            if (comp.borrowed.active()) backend.platform.recycleBorrowed(comp);
            const resolver = backend.resolver orelse unreachable;
            try resolver.drainWake();
            while (resolver.takeCompleted()) |job|
                Access.resolverCompleted(backend, job);
            if (resolver.hasLiveJobs()) resolver.maintainWake(backend, resolver_wake_ud);
        }

        /// Re-arm the receives the platform pool starved. A refused re-arm
        /// leaves that seat owed for the next recycle edge rather than
        /// failing the poll: the onion leg owes it the same way,
        /// and a poll error would retire every connection on the loop for one
        /// leg's transient submission pressure.
        fn retryPlatformRecvStarvation(backend: *Backend) void {
            const attempts = backend.recv_retries.count;
            for (0..attempts) |_| {
                const c = backend.recv_retries.pop(&backend.conns) orelse unreachable;
                if (c.state == .closing or c.external_recv_ud == null) continue;
                Access.armPlatformRecv(backend, c) catch backend.recv_retries.push(&backend.conns, c);
            }
        }

        /// How long a caller may wait before this backend's timers need it.
        pub fn waitBound(backend: *const Backend, requested: i32) i32 {
            return effectiveTimeout(backend, backend.ready.len() > 0, requested);
        }

        fn effectiveTimeout(backend: *const Backend, has_ready: bool, requested: i32) i32 {
            if (has_ready) return 0;
            const bounded = if (Access.registrationWaitMs(backend)) |limit|
                if (requested < 0) limit else @min(requested, limit)
            else
                requested;
            return retryTimeout(backend, bounded);
        }

        fn retryTimeout(backend: *const Backend, requested: i32) i32 {
            const resolver_unarmed = if (backend.resolver) |resolver|
                resolver.hasLiveJobs() and !backend.resolver_wake_armed
            else
                false;
            if (backend.close_retries.count == 0 and
                backend.tls_send_retries.count == 0 and
                backend.dial_close_retry_count == 0 and
                !resolver_unarmed)
            {
                return requested;
            }
            if (requested < 0) return operation_retry_ms;
            return @min(requested, operation_retry_ms);
        }
    };
}
