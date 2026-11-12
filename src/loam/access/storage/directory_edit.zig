//! One sparse index path stages insertions and removals in the owner transaction.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Page = records.DirectoryPage;
const read = @import("read.zig");
const Load = @import("load.zig").Load;
const record = @import("record.zig");

pub const DirectoryEdit = struct {
    view: *read.Read,
    family: Page.Family,
    slot: u32,
    cursor: ?loam.ObjectId,
    frames: [Page.levels]Frame = undefined,
    count: Count = 0,
    load: Load = .{},
    staged: bool = false,
    cancelled: bool = false,

    const Frame = struct { object: ?loam.ObjectId, revision: ?u64, page: Page };
    const Count = std.math.IntFittingRange(0, Page.levels);

    pub fn init(view: *read.Read, family: Page.Family, root: ?loam.ObjectId, slot: u32) DirectoryEdit {
        return .{ .view = view, .family = family, .slot = slot, .cursor = root };
    }

    pub fn cancel(self: *DirectoryEdit) !void {
        try self.load.cancel(self.view.store);
        self.cancelled = true;
    }

    pub fn completeRead(self: *DirectoryEdit, ticket: loam.Ticket, result: loam.ReadResult) !void {
        try self.load.complete(self.view.store, ticket, result);
    }

    pub fn advance(self: *DirectoryEdit) !read.Step {
        try self.view.current();
        if (self.cancelled) return error.Cancelled;
        if (self.staged) return error.WrongPhase;
        while (self.count < Page.levels) {
            const level: u2 = @intCast(self.count);
            var frame: Frame = .{ .object = self.cursor, .revision = null, .page = .{ .header = .{ .owner = self.view.header.owner, .family = self.family, .level = level, .prefix = Page.prefixFor(self.slot, level) } } };
            if (self.cursor) |object| {
                if (try self.view.store.proposed(object)) |staged| {
                    // A composed transaction may have staged this page already:
                    // walk the composed directory and keep the staged page's
                    // expectation so staging re-proposes it in place.
                    frame.revision = staged.expected;
                    frame.page = try Page.decode(staged.view);
                } else {
                    const lease = switch (try self.load.acquire(self.view.store, object)) {
                        .ready => |lease| lease,
                        .read => |request| return .{ .read = request },
                        .waiting => return .waiting,
                    };
                    defer self.view.store.release(lease) catch unreachable;
                    const row = try self.view.store.currentView(lease);
                    frame.revision = row.revision;
                    frame.page = try Page.decode(row);
                }
                try frame.page.header.expect(self.view.header.owner, self.family, level, Page.prefixFor(self.slot, level));
            }
            self.frames[self.count] = frame;
            self.cursor = frame.page.get(Page.digit(self.slot, level));
            self.count += 1;
        }

        return .ready;
    }

    /// Membership preparations may share a root with earlier minting in this
    /// transaction. Adopt only proposed paths or the exact prepared pages.
    /// Never introduce storage work after staging begins.
    pub fn rebaseProposed(self: *DirectoryEdit, root: ?loam.ObjectId) !void {
        try self.view.current();
        if (self.staged or self.cancelled or self.count != Page.levels or self.load.pending != null) return error.WrongPhase;
        var cursor = root;
        for (&self.frames, 0..) |*frame, index| {
            const level: u2 = @intCast(index);
            if (cursor) |object| {
                if (try self.view.store.proposed(object)) |proposal| {
                    frame.* = .{ .object = object, .revision = proposal.expected, .page = try Page.decode(proposal.view) };
                } else if (frame.object == null or !frame.object.?.eql(object)) return error.RevisionConflict;
            } else frame.* = .{ .object = null, .revision = null, .page = .{ .header = .{ .owner = self.view.header.owner, .family = self.family, .level = level, .prefix = Page.prefixFor(self.slot, level) } } };
            try frame.page.header.expect(self.view.header.owner, self.family, level, Page.prefixFor(self.slot, level));
            cursor = frame.page.get(Page.digit(self.slot, level));
        }
        self.cursor = cursor;
    }

    /// Called by the managed staging path inside an existing Loam transaction.
    /// Failures require aborting that transaction, including its content changes.
    /// Existing pages keep their identity. Only a changed child mapping needs
    /// encoding and staging. An in-place leaf edit does not rewrite its parents.
    /// Each changed page owns one temporary payload and one Store proposal.
    pub fn stage(self: *DirectoryEdit, target: ?loam.ObjectId) !?loam.ObjectId {
        try self.view.current();
        if (self.cancelled or self.staged or self.count != Page.levels or self.load.pending != null) return error.WrongPhase;
        self.staged = true;
        var child = target;
        var remaining: usize = Page.levels;
        while (remaining != 0) {
            remaining -= 1;
            const frame = &self.frames[remaining];
            const digit = Page.digit(self.slot, @intCast(remaining));
            if (std.meta.eql(frame.page.get(digit), child)) {
                child = frame.object;
                continue;
            }
            if (child) |value| frame.page.set(digit, value) else frame.page.remove(digit);
            if (frame.page.count() == 0) {
                // Disconnected index pages become ordinary unrooted records.
                // Shared tracing reclaims them, including a page created by
                // an earlier participant in this same composed transaction.
                child = null;
                continue;
            }
            const object = frame.object orelse try self.view.store.allocateId();
            const payload = try frame.page.encodeAlloc(self.view.store.allocator);
            defer self.view.store.allocator.free(payload);
            try record.put(self.view.store, object, records.profile.directory, payload, frame.page.targets[0..frame.page.count()], frame.revision, .reachable);
            child = object;
        }
        return child;
    }
};
