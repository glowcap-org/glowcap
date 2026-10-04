//! Weak owner membership is prepared before minting and staged with the object.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const Step = @import("read.zig").Step;
const DirectoryEdit = @import("directory_edit.zig").DirectoryEdit;
const record = @import("record.zig");

pub const Registry = struct {
    view: *Read,
    paths: []DirectoryEdit,
    floor: u64,
    consumed: usize = 0,
    preparing: usize = 0,
    pub const max_registration = 4;

    pub fn init(view: *Read, count: usize) !Registry {
        if (count == 0 or count > max_registration) return error.InvalidLimits;
        if (view.header.next_identity > records.OwnerRecord.max_slots - count) return error.CapacityExceeded;
        const paths = try view.allocator.alloc(DirectoryEdit, count);
        for (paths, 0..) |*path, offset| path.* = DirectoryEdit.init(view, .identity, view.header.identities, @intCast(view.header.next_identity + offset));
        return .{ .view = view, .paths = paths, .floor = view.header.next_identity };
    }
    pub fn pending(self: *const Registry) bool {
        for (self.paths) |path| if (path.load.pending != null) return true;
        return false;
    }
    pub fn deinit(self: *Registry) !void {
        if (self.pending()) return error.Busy;
        self.view.allocator.free(self.paths);
    }
    pub fn cancel(self: *Registry) !void {
        for (self.paths) |*path| try path.cancel();
    }
    pub fn completeRead(self: *Registry, ticket: loam.Ticket, result: loam.ReadResult) !void {
        for (self.paths) |*path| if (path.load.pending != null) return path.completeRead(ticket, result);
        return error.StaleCompletion;
    }
    pub fn advance(self: *Registry) !Step {
        while (self.preparing < self.paths.len) {
            const step = try self.paths[self.preparing].advance();
            if (step != .ready) return step;
            self.preparing += 1;
        }
        return .ready;
    }
    pub fn available(self: *const Registry, count: usize) bool {
        return self.floor + self.consumed == self.view.header.next_identity and self.paths.len - self.consumed >= count;
    }
    pub fn stage(self: *Registry, object: loam.ObjectId) !u32 {
        try self.view.opened();
        const store = self.view.store;
        if (store.phase != .staging or self.preparing != self.paths.len or !self.available(1)) return error.RecordUnloaded;
        if (object.store != store.metadata.store) return error.ForeignObject;
        const path = &self.paths[self.consumed];
        try path.rebaseProposed(self.view.header.identities);
        if (path.cursor != null) return error.IdentityCollision;
        errdefer store.abort() catch unreachable;
        self.view.transaction = store.ticket;
        var header = self.view.header;
        header.identities = try path.stage(object);
        header.next_identity = try std.math.add(u64, header.next_identity, 1);
        const expected = if (try store.proposed(self.view.owner_object)) |proposal| proposal.expected else self.view.header_revision;
        var edges: [records.OwnerRecord.max_edges]loam.Edge = undefined;
        try record.putEncoded(store, self.view.owner_object, records.profile.owner, header, header.edges(&edges), expected, true);
        self.view.header = header;
        self.consumed += 1;
        return path.slot;
    }
};
