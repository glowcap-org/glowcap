//! Portable resource structure, policy algebra, and managed grant lifecycle.
//! Owners create their own use and control references to committed grants.
//! Holding a reference conveys its authority. Shared views own evaluation.

const identity = @import("identity.zig");
pub const OwnerId = identity.OwnerId;
pub const ResourceId = identity.ResourceId;
pub const GrantId = identity.GrantId;
pub const KindId = identity.KindId;
pub const Revision = identity.Revision;
pub const validParent = identity.validParent;
pub const first_generation = identity.first_generation;
pub const max_depth = @import("bounds.zig").max_depth;
pub const Graph = @import("graph.zig").Graph;
pub const Scope = @import("scope.zig").Scope;
pub const max_scope_objects = @import("scope.zig").max_scope_objects;
pub const Policy = @import("policy.zig").Policy;
pub const StoredTerms = @import("terms.zig").StoredTerms;
pub const Terms = @import("terms.zig").Terms;
pub const GrantLedger = @import("grants.zig").GrantLedger;
pub const GrantUse = @import("grant_capability.zig").GrantUse;
pub const GrantControl = @import("grant_capability.zig").GrantControl;
pub const Control = @import("control.zig").Control;
pub const ResourceView = @import("resource_view.zig").ResourceView;
pub const GrantView = @import("grant_view.zig").GrantView;
pub const GrantPlan = @import("grant_plan.zig").GrantPlan;
