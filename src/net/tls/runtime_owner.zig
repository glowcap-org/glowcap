//! Shared ownership for one TLS runtime and its deterministic final barrier.
//!
//! A process-facing carrier keeps the `Owner`; completion adapters and other
//! runtime children receive `Lease`s. The owner cannot retire while a child is
//! live, so an adapter's infallible destructor never becomes the last place a
//! TLS runtime failure could be observed.

const std = @import("std");
const tls_runtime = @import("runtime.zig");

const foundation = @import("foundation");

const retiring_bit: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
const refs_mask: usize = ~retiring_bit;

const State = struct {
    refs: std.atomic.Value(usize) = .init(1),
    allocator: std.mem.Allocator,
    runtime: tls_runtime.Runtime,
};

pub const ReleaseOutcome = union(enum) {
    released,
    busy,
    failed: foundation.FailureChain,
};

pub const Owner = struct {
    state: *State,

    /// Adopt `runtime` only after the shared state allocation succeeds.
    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *tls_runtime.Runtime,
    ) std.mem.Allocator.Error!Owner {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .runtime = runtime.* };
        runtime.* = undefined;
        return .{ .state = state };
    }

    pub fn lease(self: Owner) error{TlsRuntimeOwnerRetired}!Lease {
        var current = self.state.refs.load(.acquire);
        while (true) {
            if (current & retiring_bit != 0) return error.TlsRuntimeOwnerRetired;
            const count = current & refs_mask;
            if (count == refs_mask) return error.TlsRuntimeOwnerRetired;
            if (self.state.refs.cmpxchgWeak(
                current,
                current + 1,
                .acq_rel,
                .acquire,
            )) |observed| {
                current = observed;
                continue;
            }
            return .{ .state = self.state };
        }
    }

    pub fn open(self: Owner, hostname: []const u8) tls_runtime.OpenOutcome {
        return self.state.runtime.open(hostname);
    }

    pub fn sameConfiguration(self: Owner, other: Owner) bool {
        return self.state.runtime.sameConfiguration(other.state.runtime);
    }

    /// Consume the owner only after every child lease has retired. Runtime
    /// refusal is non-consuming and remains available for an exact retry.
    pub fn release(self: *Owner) ReleaseOutcome {
        const state = self.state;
        if (state.refs.cmpxchgStrong(1, retiring_bit | 1, .acq_rel, .acquire) != null)
            return .busy;
        if (state.runtime.deinitOutcome()) |failure| {
            state.refs.store(1, .release);
            return .{ .failed = failure };
        }
        state.refs.store(retiring_bit, .release);
        self.* = undefined;
        state.allocator.destroy(state);
        return .released;
    }
};

pub const Lease = struct {
    state: *State,

    pub fn retain(self: Lease) Lease {
        const previous = self.state.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous & retiring_bit == 0);
        std.debug.assert((previous & refs_mask) > 1);
        std.debug.assert((previous & refs_mask) < refs_mask);
        return .{ .state = self.state };
    }

    pub fn open(self: Lease, hostname: []const u8) tls_runtime.OpenOutcome {
        return self.state.runtime.open(hostname);
    }

    pub fn sameConfiguration(self: Lease, other: Lease) bool {
        return self.state.runtime.sameConfiguration(other.state.runtime);
    }

    /// Child release is deliberately infallible: the surviving `Owner` is the
    /// only final barrier and therefore the only recipient for runtime failure.
    pub fn release(self: *Lease) void {
        const previous = self.state.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous & retiring_bit == 0);
        std.debug.assert((previous & refs_mask) > 1);
        self.* = undefined;
    }
};
