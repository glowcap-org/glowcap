//! One grant's portrait for a held control: its row scalars, both policy
//! values, and its effective status, copied out of the lent row so the result
//! survives every later lookup.
const core = @import("loam_access_core");
const op = @import("capability_operation.zig");

pub const InspectedGrant = struct {
    id: core.GrantId,
    revision: core.Revision,
    label: core.GrantLedger.Label,
    status: core.GrantLedger.Status,
    effective_status: core.GrantLedger.Status,
    ceiling: core.Policy.Value,
    configured: core.Policy.Value,
    delegation_depth: u16,

    /// Copy a row's scalars. `inherited` is the status its ancestry imposes.
    pub fn of(record: *const core.GrantView.Record, inherited: core.GrantLedger.Status) InspectedGrant {
        return .{
            .id = record.id,
            .revision = record.revision,
            .label = record.label,
            .status = record.status,
            .effective_status = inherited.worse(record.status),
            .ceiling = record.ceiling.policy,
            .configured = record.configured.policy,
            .delegation_depth = record.delegation_depth,
        };
    }
};

/// Inspect is independent of editing, issuance and use. The held control's
/// own ancestry must be unrevoked, and `target` must sit on a path under it.
/// One walk from `target` proves containment and folds in every status
/// between it and the control's grant.
pub fn inspect(operation: *op.Operation, target: ?core.GrantId) !InspectedGrant {
    const value = op.state(operation);
    try op.requireControl(value);
    if (!value.descriptor.powers.inspect) return error.Denied;
    var grants = try value.read.grantView();
    const inherited = try grants.effectiveStatus(value.descriptor.grant);
    if (inherited == .revoked) return error.Revoked;
    var path = grants.ancestry(target orelse value.descriptor.grant);
    defer path.close();
    var inspected: ?InspectedGrant = null;
    var status = inherited;
    while (try path.next()) |record| {
        status = status.worse(record.status);
        if (inspected == null) inspected = InspectedGrant.of(record, .active);
        if (record.id.eql(value.descriptor.grant)) {
            var result = inspected.?;
            result.effective_status = status;
            return result;
        }
    }
    return error.OutOfScope;
}
