//! Inspect the held control's own target without invoking or restoring use.
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");

/// One bounded descriptive snapshot in the retained call arena. Labels and
/// policy values copy out of the operation's reusable decode window; inspection
/// neither restores a use endpoint nor retains another authority record.
pub const Inspection = struct {
    policy: core.Policy,
    item: storage.GrantInventory.Item,

    pub fn prepare(operation: *storage.Operation) !Inspection {
        const grant = try operation.inspectGrant(null);
        const description = try operation.describeControl();
        return .{
            .policy = description.policy,
            .item = .{
                .id = grant.id,
                .revision = grant.revision,
                .label = grant.label,
                .status = grant.status,
                .effective_status = description.grant_status,
                .ceiling = grant.ceiling.policy,
                .configured = grant.configured.policy,
                .delegation_depth = grant.delegation_depth,
            },
        };
    }
};
