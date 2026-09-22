//! Appending an identity loads a bounded path and stages only changed pages.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Page = records.DirectoryPage;
const read = @import("read.zig");
const Load = @import("load.zig").Load;
const record = @import("record.zig");

pub const Append = struct {
    view: *read.Read,
    family: Page.Family,
    slot: u32,
    cursor: ?loam.ObjectId,
    frames: [4]Frame = undefined,
    count: u3 = 0,
    load: Load = .{},
    staged: bool = false,
    cancelled: bool = false,

    const Frame = struct { object: ?loam.ObjectId, revision: ?u64, page: Page };

    pub fn init(view: *read.Read, family: Page.Family) !Append {
        try view.opened();
        if (view.appending) return error.Busy;
        const next = switch (family) {
            .resource => view.header.next_resource,
            .grant => view.header.next_grant,
        };
        if (next >= records.OwnerRecord.max_slots) return error.CapacityExceeded;
        view.appending = true;
        return .{ .view = view, .family = family, .slot = @intCast(next), .cursor = switch (family) {
            .resource => view.header.resources,
            .grant => view.header.grants,
        } };
    }

    pub fn deinit(self: *Append) !void {
        if (self.load.pending != null) return error.Busy;
        self.view.appending = false;
        self.* = undefined;
    }

    pub fn cancel(self: *Append) !void {
        try self.load.cancel(self.view.store);
        self.cancelled = true;
    }

    pub fn completeRead(self: *Append, ticket: loam.Ticket, result: loam.ReadResult) !void {
        try self.load.complete(self.view.store, ticket, result);
    }

    pub fn advance(self: *Append) !read.Step {
        try self.view.current();
        if (self.cancelled) return error.Cancelled;
        if (self.staged) return error.WrongPhase;
        while (self.count < 4) {
            const level: u2 = @intCast(self.count);
            var frame: Frame = .{ .object = self.cursor, .revision = null, .page = .{ .owner = self.view.header.owner, .family = self.family, .level = level, .prefix = Page.prefixFor(self.slot, level) } };
            if (self.cursor) |object| {
                if (try self.view.store.proposed(object)) |staged| {
                    // A composed transaction may have staged this page already:
                    // walk the composed directory and keep the staged page's
                    // expectation so stageDirectory re-proposes it in place.
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
                if (frame.page.owner != self.view.header.owner or frame.page.family != self.family or frame.page.level != level or frame.page.prefix != Page.prefixFor(self.slot, level)) return error.InvalidRecord;
            }
            self.frames[self.count] = frame;
            self.cursor = frame.page.get(Page.digit(self.slot, level));
            self.count += 1;
        }
        if (self.cursor != null) return error.IdentityCollision;
        return .ready;
    }

    /// Called by the managed staging path inside an existing Loam transaction.
    /// Failures require aborting that transaction, including its content changes.
    pub fn stageDirectory(self: *Append, target: loam.ObjectId) !loam.ObjectId {
        try self.view.current();
        if (self.cancelled or self.staged or self.count != 4 or self.load.pending != null) return error.WrongPhase;
        self.staged = true;
        var child = target;
        var remaining: usize = 4;
        while (remaining != 0) {
            remaining -= 1;
            const frame = &self.frames[remaining];
            const digit = Page.digit(self.slot, @intCast(remaining));
            if (frame.page.get(digit)) |existing| if (existing.eql(child)) break;
            frame.page.set(digit, child);
            const object = frame.object orelse try self.view.store.allocateId();
            const payload = try frame.page.encodeAlloc(self.view.store.allocator);
            defer self.view.store.allocator.free(payload);
            try record.put(self.view.store, object, records.profile.directory, payload, frame.page.targets[0..frame.page.count()], frame.revision, false);
            child = object;
        }
        return self.frames[0].object orelse child;
    }
};
