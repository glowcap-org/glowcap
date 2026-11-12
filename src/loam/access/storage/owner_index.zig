//! Resident facts about recently used owners at one committed header revision.
//!
//! Every operation on an owner decodes the owner header, walks a four-level
//! directory for each record it demands, and decodes each resource row its
//! policy walk visits. All three are exact functions of the header's
//! committed revision, because a directory edit or a resource change
//! re-proposes the header. The index keeps the last few owners' decoded
//! headers and resolved targets, each with the resource reply decoded from
//! its leaf, so a repeat operation at the same revision copies the header,
//! seeds each walk at its leaf, and binds the leaf already decoded. A Read
//! consults it only while the transaction has no proposal for the owner: a
//! staged directory edit is reachable only through the proposed header, and
//! the index never learns from one.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Target = @import("read.zig").Target;

pub const OwnerIndex = struct {
    /// Owners resident at once. Every operation on a further owner evicts the
    /// oldest admission, so a Host serving more owners than this concurrently
    /// decodes and walks as if there were no index.
    pub const resident_owners = 4;
    /// Resolved targets kept per owner, replaced oldest first.
    pub const resident_targets = 32;

    /// Owns each `GrantMemo`, the one heap state the index keeps.
    allocator: std.mem.Allocator,
    owners: [resident_owners]Owner = undefined,
    count: usize = 0,
    next: usize = 0,

    pub const Owner = struct {
        object: loam.ObjectId,
        revision: u64,
        header: records.OwnerRecord,
        targets: [resident_targets]Resolved = undefined,
        count: usize = 0,
        next: usize = 0,

        /// The directory's answer for `target` at this revision, with null
        /// meaning the directory has no entry for the slot.
        pub fn resolve(self: *Owner, target: Target) ?*const Resolved {
            return self.find(target);
        }

        fn find(self: *Owner, target: Target) ?*Resolved {
            for (self.targets[0..self.count]) |*entry| if (entry.target.eql(target)) return entry;
            return null;
        }

        /// Record the directory's answer for a target this owner has no slot
        /// for yet. The oldest slot gives way, with its grant memo.
        pub fn record(self: *Owner, allocator: std.mem.Allocator, target: Target, node: ?loam.ObjectId) void {
            const slot = if (self.count < self.targets.len) self.count else self.next;
            if (self.count < self.targets.len) self.count += 1 else {
                self.targets[slot].release(allocator);
                self.next = (self.next + 1) % self.targets.len;
            }
            self.targets[slot] = .{ .target = target, .node = node };
        }

        /// Keeps the reply decoded from a resolved resource target's committed
        /// leaf, while the target is still resident.
        pub fn recordResource(self: *Owner, target: Target, value: core.ResourceView.Reply.Value) void {
            if (self.find(target)) |entry| entry.resource = value;
        }

        /// Keeps the grant record a Read decoded from a resolved grant
        /// target's committed row `object` at row revision `revision`, while
        /// the target is still resident. Costs one block for the record and
        /// one per object list its terms own, freed with the slot.
        pub fn recordGrant(
            self: *Owner,
            allocator: std.mem.Allocator,
            target: Target,
            object: loam.ObjectId,
            revision: u64,
            decoded: *const records.GrantRecord,
        ) std.mem.Allocator.Error!void {
            const entry = self.find(target) orelse return;
            const memo = try allocator.create(GrantMemo);
            errdefer allocator.destroy(memo);
            memo.object = object;
            memo.revision = revision;
            try memo.record.copyOwned(allocator, decoded);
            if (entry.grant) |old| old.destroy(allocator);
            entry.grant = memo;
        }

        fn release(self: *Owner, allocator: std.mem.Allocator) void {
            for (self.targets[0..self.count]) |*entry| entry.release(allocator);
        }
    };
    pub const Resolved = struct {
        target: Target,
        node: ?loam.ObjectId,
        /// The reply decoded from the leaf's committed row, once a Read has
        /// decoded it at this revision.
        resource: ?core.ResourceView.Reply.Value = null,
        /// The grant record decoded from the slot's committed row, once a Read
        /// has decoded it at this revision.
        grant: ?*GrantMemo = null,

        fn release(self: *Resolved, allocator: std.mem.Allocator) void {
            if (self.grant) |memo| memo.destroy(allocator);
            self.grant = null;
        }
    };
    /// A decoded grant row the index owns, with the committed row it came
    /// from so a Read that adopts it keys its own row cache the same way.
    pub const GrantMemo = struct {
        object: loam.ObjectId,
        revision: u64,
        record: records.GrantRecord,

        fn destroy(self: *GrantMemo, allocator: std.mem.Allocator) void {
            self.record.deinit(allocator);
            allocator.destroy(self);
        }
    };

    pub fn deinit(self: *OwnerIndex) void {
        for (self.owners[0..self.count]) |*owner| owner.release(self.allocator);
        self.* = undefined;
    }

    /// The resident owner at exactly this committed revision.
    pub fn find(self: *OwnerIndex, object: loam.ObjectId, revision: u64) ?*Owner {
        for (self.owners[0..self.count]) |*owner| {
            if (owner.object.eql(object)) return if (owner.revision == revision) owner else null;
        }
        return null;
    }

    /// Admit a header decoded from the owner's committed row. An older
    /// revision of the same owner is replaced in place, and a new owner takes
    /// the oldest admission's place.
    pub fn admit(self: *OwnerIndex, object: loam.ObjectId, revision: u64, header: *const records.OwnerRecord) void {
        const owner = for (self.owners[0..self.count]) |*owner| {
            if (owner.object.eql(object)) break owner;
        } else slot: {
            const slot = if (self.count < self.owners.len) self.count else self.next;
            if (self.count < self.owners.len) {
                self.count += 1;
                // A slot admitted for the first time holds nothing to release.
                self.owners[slot].count = 0;
            } else self.next = (self.next + 1) % self.owners.len;
            break :slot &self.owners[slot];
        };
        owner.release(self.allocator);
        owner.* = .{ .object = object, .revision = revision, .header = header.* };
    }
};
