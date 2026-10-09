//! Shared management powers and command admission for resident and stored grants.
const identity = @import("identity.zig");
const Terms = @import("terms.zig").Terms;
const ResourceView = @import("resource_view.zig").ResourceView;
const Policy = @import("policy.zig").Policy;
const Plan = @import("grant_plan.zig").GrantPlan;
const Error = @import("grant_types.zig").Error;

pub const Control = struct {
    pub const Powers = struct {
        inspect: bool = false,
        issue_ceiling: ?Terms = null,
        policy_ceiling: ?Terms = null,
        delegate_control: bool = false,
        pause: bool = false,
        resume_access: bool = false,
        revoke: bool = false,

        pub fn empty(self: Powers) bool {
            return self.policy_ceiling == null and self.issue_ceiling == null and !self.inspect and !self.delegate_control and !self.pause and !self.resume_access and !self.revoke;
        }
    };
    pub const Edit = union(enum) { set_policy: Terms, set_label: @import("grant_label.zig").Label, pause, resume_access, revoke };

    pub fn validate(resources: *ResourceView, policy: *const Policy, issuance: Terms, powers: Powers) Error!void {
        if (powers.policy_ceiling) |terms| if (!try terms.isSubsetOf(resources, policy, issuance)) return error.CeilingExceeded;
        if (powers.issue_ceiling) |terms| if (!try terms.isSubsetOf(resources, policy, issuance)) return error.CeilingExceeded;
    }

    /// Management can narrow powers but cannot acquire a missing permission.
    pub fn attenuate(resources: *ResourceView, policy: *const Policy, source: Powers, requested: Powers) Error!void {
        if ((requested.inspect and !source.inspect) or (requested.delegate_control and !source.delegate_control) or (requested.pause and !source.pause) or (requested.resume_access and !source.resume_access) or (requested.revoke and !source.revoke)) return error.Denied;
        if (requested.issue_ceiling) |ceiling| {
            const parent = source.issue_ceiling orelse return error.Denied;
            if (!try ceiling.isSubsetOf(resources, policy, parent)) return error.CeilingExceeded;
        }
        if (requested.policy_ceiling) |ceiling| {
            const parent = source.policy_ceiling orelse return error.Denied;
            if (!try ceiling.isSubsetOf(resources, policy, parent)) return error.CeilingExceeded;
        }
    }

    pub fn command(resources: *ResourceView, policy: *const Policy, grant: identity.GrantId, powers: Powers, edit: Edit) Error!Plan.Command {
        return switch (edit) {
            .set_label => |label| if (powers.policy_ceiling != null) .{ .set_label = .{ .grant = grant, .label = label } } else error.Denied,
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
