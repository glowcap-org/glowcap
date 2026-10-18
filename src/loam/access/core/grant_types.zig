//! Grant value types shared by mutation preparation and the committed ledger.
const std = @import("std");
const identity = @import("identity.zig");
const Terms = @import("terms.zig").Terms;
const Revision = identity.Revision;
const GrantId = identity.GrantId;
pub const Label = @import("grant_label.zig").Label;
const grant_view = @import("grant_view.zig");
const graph = @import("graph.zig");
const bounds = @import("bounds.zig");

pub const Status = enum {
    active,
    paused,
    revoked,

    /// Revocation on either side wins, then a pause.
    pub fn worse(self: Status, other: Status) Status {
        if (self == .revoked or other == .revoked) return .revoked;
        if (self == .paused or other == .paused) return .paused;
        return .active;
    }
};
pub const InitialStatus = enum { active, paused };
pub const Limits = struct {
    /// Includes revoked records. Slots are never reclaimed by this model.
    capacity: u32,
    max_depth: u16 = bounds.max_depth,
    max_children: u32 = 256,
    /// Live owner-minted use/control objects. Retained aliases share one object.
    max_capabilities: u32 = 256,
};
pub const Version = struct { resources: Revision, grants: Revision };
/// An owned, allocation-free event for one committed mutation. Policy and
/// status changes affect the named grant's entire dependent branch. They
/// do not enumerate descendants or disclose their policies. Issuance also
/// changes the optional parent's child inventory. This trusted model event
/// must be scoped before hosting delivers it to a remote observer.
pub const Change = struct {
    version: Version,
    grant: GrantId,
    kind: Kind,

    pub const Kind = union(enum) {
        issued: ?GrantId,
        policy_changed,
        label_changed,
        status_changed: struct { before: Status, after: Status },
    };
};
pub const Issue = struct {
    label: Label = .{},
    ceiling: Terms,
    configured: Terms,
    /// The number of further delegation edges this grant can issue.
    delegation_depth: u16 = 0,
    initial_status: InitialStatus = .active,
};
/// One grant row. A view lends it from its source for one lookup. The
/// ledger and a prepared issuance own their rows' selections and free them
/// with `Terms.deinitOwned`.
pub const Record = struct {
    label: Label = .{},
    id: GrantId,
    parent: ?GrantId,
    ceiling: Terms,
    configured: Terms,
    /// This grant's own status. Use effectiveStatus for ancestor effects.
    status: Status,
    revision: Revision,
    delegation_depth: u16,
    child_count: u32,
};
pub const Error = grant_view.GrantView.Error || graph.Graph.Error || std.mem.Allocator.Error || error{
    UnknownGrant,
    InvalidLabel,
    CeilingExceeded,
    DelegationDenied,
    ChildLimit,
    Paused,
    Revoked,
    OutOfScope,
    Denied,
    InvalidTransaction,
    TransactionExhausted,
    WrongPhase,
    RecoveryRequired,
};
