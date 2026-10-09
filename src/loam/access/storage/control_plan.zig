//! Prepared management terms own bounded copied selections.
const std = @import("std");
const core = @import("loam_access_core");

pub const PowerCopy = struct {
    powers: core.Control.Powers,
    ceiling: ?core.StoredTerms = null,
    issuance: ?core.StoredTerms = null,
    pub fn init(allocator: std.mem.Allocator, powers: core.Control.Powers) !PowerCopy {
        var value: PowerCopy = .{ .powers = powers };
        errdefer value.deinit(allocator);
        if (powers.policy_ceiling) |terms| {
            value.ceiling = try core.StoredTerms.initCopying(allocator, terms);
            value.powers.policy_ceiling = value.ceiling.?.terms;
        }
        if (powers.issue_ceiling) |terms| {
            value.issuance = try core.StoredTerms.initCopying(allocator, terms);
            value.powers.issue_ceiling = value.issuance.?.terms;
        }
        return value;
    }
    pub fn deinit(self: *PowerCopy, allocator: std.mem.Allocator) void {
        if (self.ceiling) |*ceiling| ceiling.deinit(allocator);
        if (self.issuance) |*ceiling| ceiling.deinit(allocator);
    }
};
pub const Plan = union(enum) {
    attenuation: PowerCopy,
    revocation: bool,
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        if (self.* == .attenuation) self.attenuation.deinit(allocator);
    }
};
pub const Description = struct { available: bool, grant_status: core.GrantLedger.Status, powers: core.Control.Powers, policy: core.Policy, revision: core.Revision };
