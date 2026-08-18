//! Bounded parallel TCP acquisition for one completion-backed relay dial.
//!
//! DNS runs through `resolver.zig`; every returned address is attempted by the
//! wrapped completion platform. A synthetic relay handle owns at most eight
//! physical descriptors, publishes nothing until every loser has retired, and
//! retains the first address failure plus later cleanup/attempt consequences.

const std = @import("std");

const carrier_failure = @import("../../../carrier_failure.zig");
const completion = @import("../../../completion/loop.zig");

pub fn WhiteBox(comptime Backend: type, comptime Types: type, comptime Race: type) type {
    if (!@import("builtin").is_test) return struct {};
    return struct {
        pub fn replacePendingWithAddresses(
            backend: *Backend,
            id: Types.ConnId,
            addresses: []const std.Io.net.IpAddress,
        ) void {
            const pending = backend.pending_dials.get(id) orelse unreachable;
            std.debug.assert(pending.resolver_job == null);
            std.debug.assert(pending.legs[0].state == .connecting);
            backend.platform.closeFd(pending.legs[0].fd);
            pending.legs[0] = .{};
            pending.address_count = 0;
            pending.next_address = 0;
            pending.attempt_failures = .{};
            Race.startAddresses(backend, pending, addresses);
        }
    };
}

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
) type {
    return struct {
        const PendingDial = Types.PendingDial;
        const DialLeg = Types.DialLeg;

        pub fn startAddresses(
            backend: *Backend,
            pending: *PendingDial,
            addresses: []const std.Io.net.IpAddress,
        ) void {
            std.debug.assert(addresses.len <= pending.addresses.len);
            if (comptime @hasDecl(@TypeOf(backend.platform), "beginAddressRace"))
                backend.platform.beginAddressRace();
            @memcpy(pending.addresses[0..addresses.len], addresses);
            pending.address_count = @intCast(addresses.len);
            service(backend, pending);
        }

        /// An IP literal has one address and no asynchronous resolution edge.
        /// Preserve the backend contract that refusing its initial connect
        /// submission refuses `startDial` and publishes no completion.
        pub fn startLiteral(
            backend: *Backend,
            pending: *PendingDial,
            address: std.Io.net.IpAddress,
        ) !void {
            pending.addresses[0] = address;
            pending.address_count = 1;
            pending.next_address = 1;
            const fd = try backend.platform.startDial(
                Access.dialUserData(.connect, pending.id, 0),
                address,
            );
            pending.legs[0] = .{
                .fd = fd,
                .state = .connecting,
                .connect_pending = true,
                .address_index = 0,
            };
        }

        pub fn resolverCompleted(backend: *Backend, job: anytype) void {
            const pending = backend.pending_dials.get(job.owner_id) orelse {
                backend.resolver.?.release(job);
                return;
            };
            std.debug.assert(pending.resolver_job == job);
            pending.resolver_job = null;
            switch (job.result) {
                .addresses => |resolved| startAddresses(
                    backend,
                    pending,
                    resolved.values[0..resolved.len],
                ),
                .failed => |failure| {
                    noteFailure(pending, failure);
                    maybeSettle(backend, pending);
                },
            }
            backend.resolver.?.release(job);
        }

        pub fn dispatch(backend: *Backend, comp: completion.Completion) void {
            const id = Access.dialId(comp.user_data);
            const pending = backend.pending_dials.get(id) orelse {
                if (comp.borrowed.active()) backend.platform.recycleBorrowed(comp);
                return;
            };
            const slot = Access.dialSlot(comp.user_data);
            const leg = &pending.legs[slot];
            switch (Access.dialOp(comp.user_data)) {
                .connect => onConnect(backend, pending, slot, leg, comp),
                .close => onClose(backend, pending, slot, leg, comp),
            }
            if (comp.borrowed.active()) backend.platform.recycleBorrowed(comp);
            service(backend, pending);
        }

        pub fn requestClose(
            backend: *Backend,
            pending: *PendingDial,
            close_user_data: ?u64,
        ) void {
            if (close_user_data) |ud| pending.external_close_ud = ud;
            if (pending.terminal_published) {
                if (pending.external_close_ud) |ud| {
                    backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                    pending.external_close_ud = null;
                }
                maybeDestroy(backend, pending);
                return;
            }
            if (!pending.close_requested) {
                pending.close_requested = true;
                var canceled = carrier_failure.Failure.init(.shutdown, error.Canceled);
                if (pending.failure) |earlier| canceled.chain.noteChain(earlier.chain);
                pending.failure = canceled;
                if (pending.resolver_job) |job| backend.resolver.?.cancel(job);
                for (&pending.legs, 0..) |*leg, slot| switch (leg.state) {
                    .idle => {},
                    .connecting => beginClose(backend, pending, @intCast(slot), leg),
                    .closing => {},
                };
            }
            maybeSettle(backend, pending);
        }

        /// Retry exactly the rows that owe a refused platform-close
        /// submission. Snapshot the count so a still-refused row rotates to a
        /// later poll instead of spinning in this one.
        pub fn retryPendingCloses(backend: *Backend) void {
            var remaining = backend.dial_close_retry_count;
            while (remaining != 0) : (remaining -= 1) {
                const pending = popCloseRetry(backend);
                service(backend, pending);
            }
        }

        pub fn recycleFailure(backend: *Backend, pending: *PendingDial) void {
            std.debug.assert(pending.failure_borrowed);
            pending.failure_borrowed = false;
            maybeDestroy(backend, pending);
        }

        /// Fail after DNS or a platform connect has accepted ownership. The
        /// admitted work is canceled/closed under this transaction without
        /// replacing the initiating failure with a synthetic cancellation.
        pub fn failAdmitted(
            backend: *Backend,
            pending: *PendingDial,
            failure: carrier_failure.Failure,
        ) void {
            noteFailure(pending, failure);
            pending.close_requested = true;
            if (pending.resolver_job) |job| backend.resolver.?.cancel(job);
            for (&pending.legs, 0..) |*leg, slot| if (leg.state == .connecting)
                beginClose(backend, pending, @intCast(slot), leg);
            maybeSettle(backend, pending);
        }

        fn onConnect(
            backend: *Backend,
            pending: *PendingDial,
            slot: u3,
            leg: *DialLeg,
            comp: completion.Completion,
        ) void {
            if (!leg.connect_pending) return;
            leg.connect_pending = false;
            if (comp.result < 0) {
                noteCompletionAttempt(pending, leg.address_index, comp, error.ConnectFailed);
                if (leg.state == .connecting) {
                    backend.platform.closeFd(leg.fd);
                    leg.* = .{};
                }
                return;
            }
            if (pending.close_requested or pending.winner != null) {
                beginClose(backend, pending, slot, leg);
                return;
            }
            pending.winner = slot;
            // A winner is not externally visible until every other descriptor
            // has retired, so no late completion can alias reused storage.
            for (&pending.legs, 0..) |*other, other_slot| {
                if (other_slot == slot) continue;
                if (other.state == .connecting)
                    beginClose(backend, pending, @intCast(other_slot), other);
            }
        }

        fn onClose(
            backend: *Backend,
            pending: *PendingDial,
            slot: u3,
            leg: *DialLeg,
            comp: completion.Completion,
        ) void {
            _ = slot;
            if (!leg.close_pending) return;
            leg.close_pending = false;
            if (comp.result < 0) {
                noteCompletionCleanup(pending, comp, error.CloseFailed);
                backend.platform.shutdownFd(leg.fd);
            } else {
                leg.closed = true;
            }
            retireClosedLeg(leg);
        }

        fn service(backend: *Backend, pending: *PendingDial) void {
            for (&pending.legs, 0..) |*leg, slot| {
                retireClosedLeg(leg);
                if (leg.state == .closing and !leg.close_pending and !leg.closed and
                    !pending.close_retry_queued)
                    beginClose(backend, pending, @intCast(slot), leg);
            }
            if (!pending.close_requested and pending.winner == null) {
                for (&pending.legs, 0..) |*leg, slot| {
                    if (pending.next_address == pending.address_count) break;
                    if (leg.state != .idle) continue;
                    const address_index = pending.next_address;
                    const address = pending.addresses[address_index];
                    pending.next_address += 1;
                    const fd = backend.platform.startDial(
                        Access.dialUserData(.connect, pending.id, @intCast(slot)),
                        address,
                    ) catch |err| {
                        noteAttempt(pending, address_index, .init(.connect, err));
                        continue;
                    };
                    leg.* = .{
                        .fd = fd,
                        .state = .connecting,
                        .connect_pending = true,
                        .address_index = address_index,
                    };
                }
            }
            maybeSettle(backend, pending);
        }

        fn beginClose(
            backend: *Backend,
            pending: *PendingDial,
            slot: u3,
            leg: *DialLeg,
        ) void {
            if (leg.state == .idle or leg.closed or leg.close_pending) return;
            leg.state = .closing;
            backend.platform.submitClose(
                Access.dialUserData(.close, pending.id, slot),
                leg.fd,
            ) catch {
                if (!leg.connect_pending) {
                    backend.platform.closeFd(leg.fd);
                    leg.closed = true;
                    retireClosedLeg(leg);
                    return;
                }
                backend.platform.shutdownFd(leg.fd);
                queueCloseRetry(backend, pending);
                return;
            };
            leg.close_pending = true;
        }

        fn queueCloseRetry(backend: *Backend, pending: *PendingDial) void {
            if (pending.close_retry_queued) return;
            pending.close_retry_queued = true;
            pending.close_retry_next = null;
            if (backend.dial_close_retry_tail) |tail|
                tail.close_retry_next = pending
            else
                backend.dial_close_retry_head = pending;
            backend.dial_close_retry_tail = pending;
            backend.dial_close_retry_count += 1;
        }

        fn popCloseRetry(backend: *Backend) *PendingDial {
            const pending = backend.dial_close_retry_head orelse unreachable;
            backend.dial_close_retry_head = pending.close_retry_next;
            if (backend.dial_close_retry_head == null) backend.dial_close_retry_tail = null;
            pending.close_retry_next = null;
            pending.close_retry_queued = false;
            backend.dial_close_retry_count -= 1;
            return pending;
        }

        fn retireClosedLeg(leg: *DialLeg) void {
            if (leg.state != .closing or !leg.closed or
                leg.connect_pending or leg.close_pending) return;
            leg.* = .{};
        }

        fn maybeSettle(backend: *Backend, pending: *PendingDial) void {
            if (pending.terminal_published or pending.resolver_job != null) return;
            if (!pending.close_requested) if (pending.winner) |winner_slot| {
                for (pending.legs, 0..) |leg, slot| {
                    if (slot == winner_slot) {
                        if (leg.state != .connecting or leg.connect_pending or
                            leg.close_pending or leg.closed) return;
                    } else if (leg.state != .idle) return;
                }
                if (pending.cleanup_failure) |cleanup| {
                    pending.failure = cleanup;
                    pending.cleanup_failure = null;
                    pending.winner = null;
                    pending.close_requested = true;
                    beginClose(backend, pending, winner_slot, &pending.legs[winner_slot]);
                    return;
                }
                const winner_fd = pending.legs[winner_slot].fd;
                pending.legs[winner_slot] = .{};
                const removed = backend.pending_dials.fetchRemove(pending.id) orelse unreachable;
                std.debug.assert(removed.value == pending);
                Access.adoptWinner(backend, pending, winner_fd);
                return;
            };
            for (pending.legs) |leg| if (leg.state != .idle) return;
            if (!pending.close_requested and
                pending.next_address < pending.address_count) return;

            completeFailureChain(pending);
            if (Access.retirePending(backend, pending)) |cleanup|
                noteFailure(pending, cleanup);
            publishFailure(backend, pending);
        }

        fn publishFailure(backend: *Backend, pending: *PendingDial) void {
            if (pending.failure == null) {
                pending.failure = .init(
                    if (pending.close_requested) .shutdown else .connect,
                    if (pending.close_requested) error.Canceled else error.NetworkUnreachable,
                );
            }
            const failure = &pending.failure.?;
            if (pending.conn.external_connect_ud) |ud| {
                backend.ready.appendAssumeCapacity(.{
                    .user_data = ud,
                    .result = -1,
                    .failure = failure.chain.cause,
                    .borrowed = .carrierFailure(failure, Access.failureToken(pending.id)),
                });
                pending.conn.external_connect_ud = null;
                pending.failure_borrowed = true;
            }
            if (pending.external_close_ud) |ud| {
                backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                pending.external_close_ud = null;
            }
            pending.terminal_published = true;
            maybeDestroy(backend, pending);
        }

        fn maybeDestroy(backend: *Backend, pending: *PendingDial) void {
            if (!pending.terminal_published or pending.failure_borrowed or
                pending.external_close_ud != null) return;
            std.debug.assert(!pending.close_retry_queued);
            const removed = backend.pending_dials.fetchRemove(pending.id) orelse unreachable;
            std.debug.assert(removed.value == pending);
            Access.destroyPending(backend, pending);
        }

        fn noteCompletionAttempt(
            pending: *PendingDial,
            address_index: u8,
            comp: completion.Completion,
            fallback: anyerror,
        ) void {
            if (comp.borrowed.carrierFailureValue()) |failure| {
                noteAttempt(pending, address_index, failure.*);
            } else if (comp.borrowed.failureChain()) |chain| {
                noteAttempt(pending, address_index, .{
                    .phase = comp.borrowed.carrierPhase() orelse .connect,
                    .chain = chain.*,
                });
            } else {
                noteAttempt(pending, address_index, .init(.connect, comp.failure orelse fallback));
            }
        }

        fn noteCompletionCleanup(
            pending: *PendingDial,
            comp: completion.Completion,
            fallback: anyerror,
        ) void {
            const failure: carrier_failure.Failure = if (comp.borrowed.carrierFailureValue()) |value|
                value.*
            else if (comp.borrowed.failureChain()) |chain|
                .{ .phase = comp.borrowed.carrierPhase() orelse .shutdown, .chain = chain.* }
            else
                .init(.shutdown, comp.failure orelse fallback);
            if (pending.cleanup_failure) |*first|
                first.chain.noteChain(failure.chain)
            else
                pending.cleanup_failure = failure;
        }

        fn noteAttempt(
            pending: *PendingDial,
            address_index: u8,
            failure: carrier_failure.Failure,
        ) void {
            pending.attempt_failures.note(address_index, failure);
        }

        fn completeFailureChain(pending: *PendingDial) void {
            pending.attempt_failures.appendTo(&pending.failure, pending.address_count);
            if (pending.cleanup_failure) |cleanup| noteFailure(pending, cleanup);
            pending.cleanup_failure = null;
        }

        fn noteFailure(pending: *PendingDial, failure: carrier_failure.Failure) void {
            if (pending.failure) |*first|
                first.chain.noteChain(failure.chain)
            else
                pending.failure = failure;
        }
    };
}
