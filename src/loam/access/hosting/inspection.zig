//! Inspect the held control's own target without invoking or restoring use.
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");

/// One bounded descriptive snapshot in the retained call arena. Labels and
/// policy values copy out of the operation's reusable decode window. Inspection
/// neither restores a use endpoint nor retains another authority record.
pub const Inspection = struct {
    policy: core.Policy,
    item: storage.GrantInventory.Item,

    pub fn prepare(operation: *storage.Operation) !Inspection {
        return .{ .item = try operation.inspectGrant(null), .policy = (try operation.describeControl()).policy };
    }
};
