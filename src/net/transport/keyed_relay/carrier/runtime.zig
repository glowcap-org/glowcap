//! Shared lifetime for one pollable relay carrier runtime.
//!
//! Residents, listeners, and admitted channels each own one lease. The last
//! release occurs only after listener workers and channel I/O are terminal, so
//! future shared trust and TLS configuration has one deterministic owner.

const std = @import("std");
const tls_runtime = @import("../../../tls/runtime.zig");
const tls_runtime_owner = @import("../../../tls/runtime_owner.zig");

const foundation = @import("foundation");

const State = struct {
    refs: std.atomic.Value(usize) = .init(1),
    owners: std.atomic.Value(usize) = .init(1),
    allocator: std.mem.Allocator,
    io: std.Io,
    tls: ?tls_runtime_owner.Owner = null,
};

pub const Lease = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, host_io: std.Io) std.mem.Allocator.Error!Lease {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = host_io };
        return .{ .state = state };
    }

    /// Adopt one initialized TLS runtime. Initialization refusal leaves the
    /// caller's runtime untouched. Success transfers it to the carrier state.
    pub fn initSecure(
        allocator: std.mem.Allocator,
        host_io: std.Io,
        tls: *tls_runtime.Runtime,
    ) std.mem.Allocator.Error!Lease {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .io = host_io,
            .tls = try tls_runtime_owner.Owner.init(allocator, tls),
        };
        return .{ .state = state };
    }

    pub fn retain(self: Lease) Lease {
        const previous = self.state.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
        return .{ .state = self.state };
    }

    /// Add another resident profile view. Unlike a child channel, this lease
    /// remains eligible to own the final runtime barrier.
    pub fn retainOwner(self: Lease) Lease {
        _ = self.state.owners.fetchAdd(1, .monotonic);
        return self.retain();
    }

    pub fn releaseOutcome(self: *Lease) ?foundation.FailureChain {
        const state = self.state;
        const previous = state.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) {
            self.* = undefined;
            return null;
        }
        if (state.tls) |*tls| switch (tls.release()) {
            .released => {},
            .busy => {
                state.refs.store(1, .release);
                return .init(error.RelayCarrierBusy);
            },
            .failed => |failure| {
                state.refs.store(1, .release);
                return failure;
            },
        };
        self.* = undefined;
        state.allocator.destroy(state);
        return null;
    }

    /// Release the runtime owner. A secure owner cannot retire ahead of child
    /// channels: the final TLS barrier must stay attached to a process-owned
    /// handle rather than migrate into an abortive channel destructor.
    pub fn releaseOwnerOutcome(self: *Lease) ?foundation.FailureChain {
        const state = self.state;
        const previous_owners = state.owners.fetchSub(1, .acq_rel);
        if (previous_owners == 0) {
            _ = state.owners.fetchAdd(1, .release);
            return .init(error.RelayCarrierOwnerRetired);
        }
        if (previous_owners > 1) return self.releaseOutcome();
        if (state.tls != null and state.refs.load(.acquire) != 1) {
            state.owners.store(1, .release);
            return .init(error.RelayCarrierBusy);
        }
        const failure = self.releaseOutcome();
        if (failure != null) state.owners.store(1, .release);
        return failure;
    }

    /// Release the keyed and Noise owners as one transaction. A secure
    /// refusal leaves both handles live, so provider close remains retryable.
    pub fn releaseOwnerPairOutcome(first: *Lease, second: *Lease) ?foundation.FailureChain {
        const state = first.state;
        if (state != second.state or state.owners.load(.acquire) != 2)
            return .init(error.RelayCarrierOwnershipMismatch);
        if (state.tls) |*tls| {
            if (state.refs.load(.acquire) != 2)
                return .init(error.RelayCarrierBusy);
            switch (tls.release()) {
                .released => {},
                .busy => return .init(error.RelayCarrierBusy),
                .failed => |failure| return failure,
            }
            state.owners.store(0, .release);
            state.refs.store(0, .release);
            first.* = undefined;
            second.* = undefined;
            state.allocator.destroy(state);
            return null;
        }
        state.owners.store(0, .release);
        const allocator = state.allocator;
        const previous = state.refs.fetchSub(2, .acq_rel);
        first.* = undefined;
        second.* = undefined;
        if (previous == 2) allocator.destroy(state);
        return null;
    }

    pub fn io(self: Lease) std.Io {
        return self.state.io;
    }

    pub fn stateAllocator(self: Lease) std.mem.Allocator {
        return self.state.allocator;
    }

    pub fn openTls(self: Lease, hostname: []const u8) ?tls_runtime.OpenOutcome {
        const tls = self.state.tls orelse return null;
        return tls.open(hostname);
    }

    pub fn hasTls(self: Lease) bool {
        return self.state.tls != null;
    }

    /// Compare the carrier behavior that can change whether the same relay
    /// route is reachable. Runtime leases and active channels are state, while
    /// the selected TLS engine and its immutable trust snapshot are policy.
    pub fn sameConfiguration(self: Lease, other: Lease) bool {
        const left = self.state.tls;
        const right = other.state.tls;
        if (left == null or right == null) return left == null and right == null;
        return left.?.sameConfiguration(right.?);
    }
};
