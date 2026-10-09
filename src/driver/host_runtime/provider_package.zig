//! Provider registration values and the installed package lease.
//!
//! Package overlap and lifetime are composition facts. Concrete provider
//! callbacks remain borrowed adapter plumbing and never become Host policy.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const runtime_contract = @import("contract.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

pub const Selected = struct {
    transport: []const u8,
    designator_scheme: net.netlayer.DesignatorScheme,
    resident: usize,
};

/// One transport profile served by a multiplexed resident. Several profiles
/// may name the same resident; the runtime polls each resident once.
pub const Registration = struct {
    profile: model.transport.Metadata,
    resident: net.MultiplexedResident,
};

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

    pub fn overlaps(self: Installed, candidate: []const Registration) !bool {
        for (self.profiles) |installed| for (candidate) |registration| {
            const profile = try runtime_contract.canonicalProviderProfile(registration.profile);
            if (std.mem.eql(u8, installed.symbol, profile.symbol)) return true;
        };
        return false;
    }

    pub fn hasSameProfiles(self: Installed, candidate: []const Registration) !bool {
        if (self.profiles.len != candidate.len) return false;
        for (self.profiles) |installed| {
            for (candidate) |registration| {
                if (installed.eql(try runtime_contract.canonicalProviderProfile(registration.profile))) break;
            } else return false;
        }
        return true;
    }

    pub fn deinit(self: *Installed, allocator: std.mem.Allocator) ?OperationFailure {
        allocator.free(self.profiles);
        const failure = self.owner.release(self.owner.ctx);
        self.* = undefined;
        return failure;
    }
};
