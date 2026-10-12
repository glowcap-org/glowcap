//! Hermetic TLS-engine projection for clear-relay and ABI checks.
//!
//! The production module injects Mbed TLS at the same seam. This test owner
//! lets `ws` exercise the complete relay lifecycle without fetching a network
//! dependency. Any attempted `wss` open fails closed and is never mistaken for
//! secure evidence.

const std = @import("std");

const foundation = @import("foundation");
const net = @import("net");

pub const max_trust_bytes: usize = 8 * 1024 * 1024;

pub const Trust = union(enum) {
    system,
    copied_pem: []const u8,
};

pub const TrustSummary = struct {
    loaded: usize,
    skipped_by_engine: usize = 0,
    first_skipped_engine_code: ?i32 = null,
};

pub const Ready = struct {
    runtime: net.tls.runtime.Runtime,
    trust: TrustSummary,
};

pub const InitOutcome = union(enum) {
    ready: Ready,
    failed: net.tls.engine.Failure,
};

const Owner = struct {
    allocator: std.mem.Allocator,
    trust: TrustSnapshot,
};

const TrustSnapshot = union(enum) {
    system,
    copied_pem: []u8,

    fn deinit(self: *TrustSnapshot, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .system => {},
            .copied_pem => |pem| allocator.free(pem),
        }
        self.* = undefined;
    }

    fn same(self: TrustSnapshot, other: TrustSnapshot) bool {
        return switch (self) {
            .system => switch (other) {
                .system => true,
                .copied_pem => false,
            },
            .copied_pem => |left| switch (other) {
                .copied_pem => |right| std.mem.eql(u8, left, right),
                .system => false,
            },
        };
    }
};

const runtime_vtable: net.tls.runtime.Runtime.VTable = .{
    .open = open,
    .same_configuration = sameConfiguration,
    .deinit_outcome = deinitOutcome,
};

pub fn init(
    _: std.Io,
    allocator: std.mem.Allocator,
    trust: Trust,
) InitOutcome {
    const snapshot: TrustSnapshot = switch (trust) {
        .system => .system,
        .copied_pem => |pem| .{ .copied_pem = allocator.dupe(u8, pem) catch
            return .{ .failed = .init(.handshake, error.OutOfMemory) } },
    };
    const owner = allocator.create(Owner) catch {
        var owned = snapshot;
        owned.deinit(allocator);
        return .{ .failed = .init(.handshake, error.OutOfMemory) };
    };
    owner.* = .{ .allocator = allocator, .trust = snapshot };
    return .{ .ready = .{
        .runtime = .{ .ctx = owner, .vtable = &runtime_vtable },
        .trust = .{ .loaded = switch (trust) {
            .system => 1,
            .copied_pem => |pem| @intFromBool(pem.len != 0),
        } },
    } };
}

fn open(_: *anyopaque, _: []const u8) net.tls.runtime.OpenOutcome {
    return .{ .failed = .init(.handshake, error.SecureCarrierUnavailable) };
}

fn sameConfiguration(left_raw: *anyopaque, right_raw: *anyopaque) bool {
    const left: *Owner = @ptrCast(@alignCast(left_raw));
    const right: *Owner = @ptrCast(@alignCast(right_raw));
    return left.trust.same(right.trust);
}

fn deinitOutcome(raw: *anyopaque) ?foundation.FailureChain {
    const owner: *Owner = @ptrCast(@alignCast(raw));
    const allocator = owner.allocator;
    owner.trust.deinit(allocator);
    allocator.destroy(owner);
    return null;
}
