//! Native references carry access to one grant. The trusted ledger creates
//! them; holders call them without another credential or a grant selector.
//! Host actors can retain these references when hosting is implemented.

const std = @import("std");
const Ledger = @import("grants.zig").GrantLedger;
const identity = @import("identity.zig");
const StoredTerms = @import("terms.zig").StoredTerms;
const Policy = @import("policy.zig").Policy;
const Control = @import("control.zig").Control;

const Binding = struct {
    ledger: *Ledger,
    grant: identity.GrantId,
    references: u32 = 1,

    fn acquire(ledger: *Ledger, grant: identity.GrantId) Ledger.Error!Binding {
        _ = try ledger.get(grant);
        if (ledger.live_capabilities == ledger.limits.max_capabilities) return error.CapacityExceeded;
        ledger.live_capabilities += 1;
        return .{ .ledger = ledger, .grant = grant };
    }

    fn retain(self: *Binding) Ledger.Error!void {
        if (self.references == std.math.maxInt(u32)) return error.CapacityExceeded;
        self.references += 1;
    }

    fn release(self: *Binding) bool {
        self.references -= 1;
        if (self.references != 0) return false;
        self.ledger.live_capabilities -= 1;
        return true;
    }
};
const UseState = struct { binding: Binding };
const ControlState = struct {
    binding: Binding,
    policy_ceiling: ?StoredTerms,
    pause: bool,
    resume_access: bool,
    revoke: bool,
};

/// Possession conveys use and the grant's permitted delegation. Retain when
/// sharing an owned reference; each owned reference must be released once.
/// The ledger stays at a stable address until all references are released.
/// Calls are serialized with that ledger by the embedding application.
pub const GrantUse = opaque {
    pub fn retain(self: *GrantUse) Ledger.Error!*GrantUse {
        try self.state().binding.retain();
        return self;
    }

    pub fn release(self: *GrantUse) void {
        const value = self.state();
        if (value.binding.release()) value.binding.ledger.allocator.destroy(value);
    }

    /// The application supplies operation requirements and committed facts.
    /// Success covers this synchronous check; it is not a reusable admission
    /// for a later content effect. Every invocation must check current state.
    pub fn require(self: *const GrantUse, target: identity.ResourceId, requirement: Policy.Requirement) Ledger.Error!void {
        const binding = &self.state().binding;
        return binding.ledger.require(binding.grant, target, requirement);
    }

    pub fn describe(self: *const GrantUse, target: identity.ResourceId) Ledger.Error!@import("grant_view.zig").GrantView.Access {
        const binding = &self.state().binding;
        return binding.ledger.describe(binding.grant, target);
    }

    /// Prepare a child of this held grant. The owner completes storage and
    /// creates child references only after commit. No child authority is
    /// returned by preparation, cancellation, or an uncertain completion.
    pub fn prepareDeriveCopying(self: *GrantUse, base: Ledger.Version, request: Ledger.Issue) Ledger.Error!Ledger.Ticket {
        const binding = &self.state().binding;
        return (try binding.ledger.prepareCopying(base, .{ .derive = .{
            .parent = binding.grant,
            .request = request,
        } })).?;
    }

    fn state(self: *const GrantUse) *UseState {
        return @ptrCast(@alignCast(@constCast(self)));
    }
};

/// Possession conveys only the configured management powers over one grant.
/// It conveys no use reference, parent control, or ledger access. Releasing
/// this native reference does not revoke the separately held use capability.
pub const GrantControl = opaque {
    /// A policy ceiling permits replacements within these terms. Null grants
    /// no policy editing. Lifecycle powers are independent and default off.
    pub const Powers = Control.Powers;
    pub const Edit = Control.Edit;

    pub fn retain(self: *GrantControl) Ledger.Error!*GrantControl {
        try self.state().binding.retain();
        return self;
    }

    pub fn release(self: *GrantControl) void {
        const value = self.state();
        if (!value.binding.release()) return;
        const allocator = value.binding.ledger.allocator;
        if (value.policy_ceiling) |*ceiling| ceiling.deinit(allocator);
        allocator.destroy(value);
    }

    /// Prepare an edit to this control's grant. The same ledger path enforces
    /// issuance ceilings, lifecycle, revisions, reservations, and recovery.
    /// Use pause does not disable control: a held resume power can resume it.
    pub fn prepareCopying(self: *GrantControl, base: Ledger.Version, edit: Edit) Ledger.Error!?Ledger.Ticket {
        const value = self.state();
        const ledger = value.binding.ledger;
        const grant = value.binding.grant;
        var resources = ledger.graph.readView();
        const command = try Control.command(&resources, &ledger.policy, grant, .{
            .policy_ceiling = if (value.policy_ceiling) |ceiling| ceiling.terms else null,
            .pause = value.pause,
            .resume_access = value.resume_access,
            .revoke = value.revoke,
        }, edit);
        return ledger.prepareCopying(base, command);
    }

    fn state(self: *const GrantControl) *ControlState {
        return @ptrCast(@alignCast(@constCast(self)));
    }
};

pub fn createUse(ledger: *Ledger, grant: identity.GrantId) Ledger.Error!*GrantUse {
    const binding = try Binding.acquire(ledger, grant);
    errdefer ledger.live_capabilities -= 1;
    const value = try ledger.allocator.create(UseState);
    value.* = .{ .binding = binding };
    return @ptrCast(value);
}

pub fn createControlCopying(ledger: *Ledger, grant: identity.GrantId, powers: GrantControl.Powers) Ledger.Error!*GrantControl {
    const binding = try Binding.acquire(ledger, grant);
    errdefer ledger.live_capabilities -= 1;
    var ceiling: ?StoredTerms = null;
    if (powers.policy_ceiling) |terms| {
        const record = try ledger.get(grant);
        var resources = ledger.graph.readView();
        try Control.validate(&resources, &ledger.policy, record.ceiling, powers);
        ceiling = try StoredTerms.initCopying(ledger.allocator, terms);
    }
    errdefer if (ceiling) |*value| value.deinit(ledger.allocator);
    const value = try ledger.allocator.create(ControlState);
    value.* = .{
        .binding = binding,
        .policy_ceiling = ceiling,
        .pause = powers.pause,
        .resume_access = powers.resume_access,
        .revoke = powers.revoke,
    };
    return @ptrCast(value);
}
