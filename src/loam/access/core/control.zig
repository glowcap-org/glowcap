//! Shared management powers and command admission for resident and stored grants.
const identity = @import("identity.zig");
const Terms = @import("terms.zig").Terms;
const ResourceView = @import("resource_view.zig").ResourceView;
const Policy = @import("policy.zig").Policy;
const Plan = @import("grant_plan.zig").GrantPlan;
const Error = @import("grant_types.zig").Error;

pub const Control = struct {
    pub const Powers = struct {
        policy_ceiling: ?Terms = null,
        pause: bool = false,
        resume_access: bool = false,
        revoke: bool = false,
    };
    pub const Edit = union(enum) { set_policy: Terms, pause, resume_access, revoke };

    pub fn validate(resources: *ResourceView, policy: *const Policy, issuance: Terms, powers: Powers) Error!void {
        if (powers.policy_ceiling) |terms| if (!try terms.isSubsetOf(resources, policy, issuance)) return error.CeilingExceeded;
    }

    pub fn command(resources: *ResourceView, policy: *const Policy, grant: identity.GrantId, powers: Powers, edit: Edit) Error!Plan.Command {
        return switch (edit) {
            .set_policy => |terms| blk: {
                const ceiling = powers.policy_ceiling orelse return error.Denied;
                if (!try terms.isSubsetOf(resources, policy, ceiling)) return error.CeilingExceeded;
                break :blk .{ .set_policy = .{ .grant = grant, .terms = terms } };
            },
            .pause => if (powers.pause) .{ .pause = grant } else error.Denied,
            .resume_access => if (powers.resume_access) .{ .resume_access = grant } else error.Denied,
            .revoke => if (powers.revoke) .{ .revoke = grant } else error.Denied,
        };
    }
};
