//! Bounded local grant ancestry and lifecycle for a trusted resource owner.
//! The owner creates its own use and control references for committed grants.
//! Holders exercise those references. ID-based methods remain owner operations.
//! The graph must outlive the ledger at a stable address. Its mutations and
//! these calls are synchronous and serialized by the embedding application.
//! Successful mutations return committed change events. Event delivery is a
//! hosting effect. It never substitutes for evaluating current access.

const std = @import("std");
const identity = @import("identity.zig");
const Graph = @import("graph.zig").Graph;
const Policy = @import("policy.zig").Policy;
const Terms = @import("terms.zig").Terms;
const Revision = identity.Revision;
const GrantId = identity.GrantId;
const types = @import("grant_types.zig");
const transaction = @import("grant_transaction.zig");
const capability = @import("grant_capability.zig");
const GrantView = @import("grant_view.zig").GrantView;

const Entry = types.Entry;

pub const GrantLedger = struct {
    allocator: std.mem.Allocator,
    graph: *Graph,
    policy: Policy,
    limits: Limits,
    entries: []Entry,
    used: u32 = 0,
    current_revision: Revision = @fromBackingInt(0),
    pending: ?transaction.Pending = null,
    transaction_sequence: u64 = 0,
    live_capabilities: u32 = 0,

    pub const Status = types.Status;
    pub const InitialStatus = types.InitialStatus;
    pub const Limits = types.Limits;
    pub const Version = types.Version;
    pub const Change = types.Change;
    pub const Issue = types.Issue;
    pub const Label = types.Label;
    pub const Record = types.Record;
    pub const Error = types.Error;

    /// Reserves grant records and copies the runtime policy descriptor. A fresh
    /// ledger requires a fresh authority store. An empty old owner is not restore.
    pub fn init(allocator: std.mem.Allocator, graph: *Graph, descriptor: Policy.Descriptor, limits: Limits) Error!GrantLedger {
        if (limits.capacity == 0) return error.InvalidLimits;
        const policy = try Policy.init(descriptor);
        return .{
            .allocator = allocator,
            .graph = graph,
            .policy = policy,
            .limits = limits,
            .entries = try allocator.alloc(Entry, limits.capacity),
        };
    }

    pub fn deinit(self: *GrantLedger) error{Busy}!void {
        if (self.pending != null or self.live_capabilities != 0) return error.Busy;
        for (self.entries[0..self.used]) |*entry| {
            entry.ceiling.deinit(self.allocator);
            entry.configured.deinit(self.allocator);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// The trusted owner allocates its own use reference to a committed grant.
    /// The reference carries authority. Recipients need no additional credential.
    pub fn createUse(self: *GrantLedger, id: GrantId) Error!*capability.GrantUse {
        return capability.createUse(self, id);
    }

    /// The trusted owner allocates separate management authority and copies its
    /// ceiling. Holding a use reference does not expose this factory or control.
    pub fn createControlCopying(self: *GrantLedger, id: GrantId, powers: capability.GrantControl.Powers) Error!*capability.GrantControl {
        return capability.createControlCopying(self, id, powers);
    }

    /// Both revisions participate in mutation preconditions. This is a current
    /// read stamp, not an admission token or a durable transaction receipt.
    pub fn version(self: *const GrantLedger) Version {
        return .{ .resources = self.graph.revision(), .grants = self.current_revision };
    }

    pub fn count(self: *const GrantLedger) u32 {
        return self.used;
    }

    pub fn get(self: *const GrantLedger, id: GrantId) Error!Record {
        try self.checkReadable();
        return transaction.recordOf(id, (try self.lookup(id)).*);
    }

    pub fn readView(self: *const GrantLedger) GrantView {
        return GrantView.init(.{ .owner = self.graph.owner, .revisions = self.version() }, self.limits.max_depth, self, readRecord);
    }

    fn readRecord(context: *const anyopaque, id: GrantId) GrantView.SourceError!GrantView.Reply {
        const self: *const GrantLedger = @ptrCast(@alignCast(context));
        if (self.pending) |pending| if (pending.phase == .uncertain) return error.RecoveryRequired;
        const version_: GrantView.Version = .{ .owner = self.graph.owner, .revisions = self.version() };
        if (id.slot >= self.used or id.generation == 0) return .{ .version = version_, .value = .{ .absent = .unknown } };
        if (id.generation != 1) return .{ .version = version_, .value = .{ .absent = .gone } };
        return .{ .version = version_, .value = .{ .present = transaction.recordOf(id, self.entries[id.slot]) } };
    }

    /// Trusted issuance of independent access. The volatile convenience path
    /// uses the same preparation and commit logic as a storage-backed change.
    pub fn issueRootCopying(self: *GrantLedger, base: Version, request: Issue) Error!Change {
        return (try self.applyVolatile(base, .{ .issue_root = request })).?;
    }

    pub fn deriveCopying(self: *GrantLedger, base: Version, parent: GrantId, request: Issue) Error!Change {
        return (try self.applyVolatile(base, .{ .derive = .{ .parent = parent, .request = request } })).?;
    }

    /// Trusted owner edit. Actual management authority must be admitted before
    /// this model is called. Paused state and the issuance ceiling are preserved.
    pub fn setPolicyCopying(self: *GrantLedger, base: Version, id: GrantId, replacement: Terms) Error!?Change {
        return self.applyVolatile(base, .{ .set_policy = .{ .grant = id, .terms = replacement } });
    }

    pub fn pause(self: *GrantLedger, base: Version, id: GrantId) Error!?Change {
        return self.applyVolatile(base, .{ .pause = id });
    }

    pub fn @"resume"(self: *GrantLedger, base: Version, id: GrantId) Error!?Change {
        return self.applyVolatile(base, .{ .resume_access = id });
    }

    pub fn revoke(self: *GrantLedger, base: Version, id: GrantId) Error!?Change {
        return self.applyVolatile(base, .{ .revoke = id });
    }

    /// Revocation anywhere in the chain wins over any temporary pause. Local
    /// descendant records need no rewrite for this result to become terminal.
    pub fn effectiveStatus(self: *const GrantLedger, id: GrantId) Error!Status {
        var grants = self.readView();
        return grants.effectiveStatus(id);
    }

    /// Evaluates one selected local grant path at the current graph revision.
    /// It creates no reusable admission and grants no Host invocation authority.
    /// Reads, lifecycle changes, and ancestry traversal perform no allocation.
    pub fn require(self: *const GrantLedger, id: GrantId, target: identity.ResourceId, requirement: Policy.Requirement) Error!void {
        var grants = self.readView();
        var resources = self.graph.readView();
        return grants.require(&resources, &self.policy, id, target, requirement);
    }

    pub fn describe(self: *const GrantLedger, id: GrantId, target: identity.ResourceId) Error!GrantView.Access {
        var grants = self.readView();
        var resources = self.graph.readView();
        return grants.describe(&resources, &self.policy, id, target);
    }

    pub const Command = transaction.Command;
    pub const Ticket = transaction.Ticket;
    pub const Write = transaction.Write;
    pub const Outcome = transaction.Outcome;
    pub const Resolution = transaction.Resolution;
    pub const Completion = transaction.Completion;

    /// Validates and copies one bounded delta without changing committed grants
    /// or emitting an event. Null denotes a validated, unchanged request.
    pub fn prepareCopying(self: *GrantLedger, base: Version, command: Command) Error!?Ticket {
        return transaction.prepareCopying(self, base, command);
    }

    /// Starts storage use of the immutable write view. Its borrows remain live
    /// until a known outcome completes, including through uncertain recovery.
    pub fn beginWrite(self: *GrantLedger, ticket: Ticket) Error!Write {
        return transaction.beginWrite(self, ticket);
    }

    /// A trusted storage adapter reports the outcome of this exact write. It
    /// must retire its I/O before reporting. Uncertainty keeps the model fenced.
    pub fn finishWrite(self: *GrantLedger, ticket: Ticket, outcome: Outcome) Error!Completion {
        return transaction.finishWrite(self, ticket, outcome);
    }

    pub fn resolveWrite(self: *GrantLedger, ticket: Ticket, resolution: Resolution) Error!Completion {
        return transaction.resolveWrite(self, ticket, resolution);
    }

    /// Cancellation is possible only before beginWrite. A running or uncertain
    /// write retains its state until a matching outcome or recovery resolution.
    pub fn cancel(self: *GrantLedger, ticket: Ticket) Error!void {
        return transaction.cancel(self, ticket);
    }

    pub fn commitVolatile(self: *GrantLedger, ticket: Ticket) Error!Change {
        return transaction.commitVolatile(self, ticket);
    }

    fn applyVolatile(self: *GrantLedger, base: Version, command: Command) Error!?Change {
        const ticket = try self.prepareCopying(base, command) orelse return null;
        return try self.commitVolatile(ticket);
    }

    fn checkReadable(self: *const GrantLedger) Error!void {
        if (self.pending) |pending| if (pending.phase == .uncertain) return error.RecoveryRequired;
    }

    fn lookup(self: *const GrantLedger, id: GrantId) Error!*const Entry {
        return transaction.lookup(self, id);
    }
};
