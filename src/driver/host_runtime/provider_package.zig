//! Provider registration values and the installed package lease.
//!
//! Package overlap and lifetime are composition facts. Concrete provider
//! callbacks remain borrowed adapter plumbing and never become Host policy.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

pub const Selected = struct {
    transport: []const u8,
    designator_scheme: net.netlayer.DesignatorScheme,
    resident: usize,
};

/// One transport profile served by a multiplexed resident. Several profiles
/// may name the same resident. The runtime polls each resident once.
///
/// The caller owns endpoint identity configuration. When a provider such as
/// iroh authenticates the key in its locator, its endpoint and the Host must
/// use the same identity seed, including for dial-only use. Registration
/// validates profiles and readiness, but cannot inspect an endpoint's local
/// key. A separately keyed endpoint cannot authenticate the Host identity
/// advertised in its hello.
pub const Registration = struct {
    profile: model.transport.Metadata,
    resident: net.MultiplexedResident,
};

/// The installed package's owner callbacks. Implementors are unknown at this
/// declaration, so `same_configuration` keeps an `anyerror` return set.
pub const Owner = struct {
    ctx: *anyopaque,
    same_configuration: *const fn (installed: *anyopaque, candidate: *anyopaque) anyerror!bool,
    release: *const fn (ctx: *anyopaque) ?OperationFailure,
};

pub const Package = struct {
    registrations: []const Registration,
    owner: Owner,
};

pub const Installed = struct {
    profiles: []model.transport.Metadata,
    owner: Owner,

    /// The profile this package serves under `symbol`, when it serves one.
    pub fn profileNamed(self: Installed, symbol: []const u8) ?model.transport.Metadata {
        for (self.profiles) |installed| if (std.mem.eql(u8, installed.symbol, symbol)) return installed;
        return null;
    }

    pub fn deinit(self: *Installed, allocator: std.mem.Allocator) ?OperationFailure {
        allocator.free(self.profiles);
        const failure = self.owner.release(self.owner.ctx);
        self.* = undefined;
        return failure;
    }
};
