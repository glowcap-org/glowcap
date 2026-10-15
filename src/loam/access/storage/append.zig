//! Identity allocation and child membership share the composed owner transaction.
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const read = @import("read.zig");
const DirectoryEdit = @import("directory_edit.zig").DirectoryEdit;

pub const Append = struct {
    view: *read.Read,
    directory: DirectoryEdit,
    child: ?*DirectoryEdit = null,
    parent: ?core.ResourceId = null,
    grant_parent: ?core.GrantId = null,
    resource_ready: bool = false,

    pub fn init(view: *read.Read, family: records.DirectoryPage.Family) !Append {
        try view.opened();
        if (view.header.lifecycle != .active) return error.OwnerRetired;
        if (view.exclusive != .none) return error.Busy;
        const next = switch (family) {
            .resource => view.header.next_resource,
            .grant => view.header.next_grant,
            .identity => return error.WrongFamily,
        };
        if (next >= records.OwnerRecord.max_slots) return error.CapacityExceeded;
        view.exclusive = .append;
        const root = switch (family) {
            .resource => view.header.resources,
            .grant => view.header.grants,
            .identity => unreachable,
        };
        return .{ .view = view, .directory = DirectoryEdit.init(view, family, root, @intCast(next)) };
    }

    pub fn deinit(self: *Append) !void {
        if (self.view.load.pending != null or self.directory.load.pending != null) return error.Busy;
        if (self.child) |child| if (child.load.pending != null) return error.Busy;
        if (self.child) |child| self.view.allocator.destroy(child);
        self.view.exclusive = .none;
        self.* = undefined;
    }

    pub fn cancel(self: *Append) !void {
        if (self.view.load.pending != null) try self.view.load.cancel(self.view.store);
        try self.directory.cancel();
        if (self.child) |child| try child.cancel();
    }

    pub fn completeRead(self: *Append, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.view.load.pending != null) return self.view.completeRead(ticket, result);
        if (self.directory.load.pending != null) return self.directory.completeRead(ticket, result);
        if (self.child) |child| if (child.load.pending != null) return child.completeRead(ticket, result);
        return error.StaleCompletion;
    }

    pub fn advance(self: *Append) !read.Step {
        self.view.history_requested = true;
        if (!self.view.history_ready) {
            const step = try self.view.advance();
            if (step != .ready) return step;
        }
        const step = try self.directory.advance();
        if (step != .ready) return step;
        if (self.directory.family == .grant) if (self.grant_parent) |parent| {
            if (self.child == null) {
                var grants = try self.view.grantView();
                _ = try grants.borrow(parent);
                defer grants.release();
                const child = try self.view.allocator.create(DirectoryEdit);
                child.* = DirectoryEdit.init(self.view, .grant, self.view.heldRow().children, self.directory.slot);
                self.child = child;
            }
            return self.child.?.advance();
        };
        return .ready;
    }

    /// Prepare the child-index path before staging a resource append. A model
    /// miss is driven through Read. Directory faults use this append's completion.
    pub fn prepareResource(self: *Append, parent: ?core.ResourceId) !read.Step {
        if (self.directory.family != .resource or self.directory.count != 4) return error.WrongPhase;
        try self.view.prepareHistory();
        if (parent) |id| _ = try @import("history.zig").resourcePath(self.view, id);
        var resources = try self.view.resourceView();
        var root = self.view.header.roots;
        if (parent) |target| {
            if (resources.max_depth == 0) return error.DepthLimit;
            resources.max_depth -= 1;
            _ = try resources.isDescendant(target, target);
            const binding = (try self.view.binding(.{ .resource = target })).?;
            const row = (try read.Read.rowFor(self.view.store, binding)).?.view;
            root = (try records.ResourceRecord.decode(row)).children;
        }
        if (self.child == null) {
            self.parent = parent;
            const child = try self.view.allocator.create(DirectoryEdit);
            child.* = DirectoryEdit.init(self.view, .resource, root, self.directory.slot);
            self.child = child;
        } else if (!@import("std").meta.eql(self.parent, parent)) return error.WrongPhase;
        const step = try self.child.?.advance();
        self.resource_ready = step == .ready;
        return step;
    }

    pub fn stageDirectory(self: *Append, target: loam.ObjectId) !loam.ObjectId {
        if (self.directory.cursor != null) return error.IdentityCollision;
        return (try self.directory.stage(target)).?;
    }
};
