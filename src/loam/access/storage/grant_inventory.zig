//! A held control walks its own child index with one revision-bound path.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const loam = @import("loam_core");
const op = @import("capability_operation.zig");
const read_mod = @import("read.zig");
const Query = @import("directory_query.zig").DirectoryQuery;
const load = @import("load.zig");

pub const Inventory = struct {
    operation: *op.Operation,
    query: ?Query = null,
    floor: u64,
    entry: ?Query.Entry = null,
    lease: ?loam.Lease = null,
    done: bool = false,
    load: load.Load = .{},

    /// Scalar copies survive the next model lookup. No use endpoint, bearer
    /// secret or owner's unrelated grant population participates in this page.
    pub const Item = @import("inspected_grant.zig").InspectedGrant;

    pub fn init(operation: *op.Operation, floor: u64) !Inventory {
        _ = try operation.inspectGrant(null);
        const state = op.state(operation);
        if (state.children != 0) return error.Busy;
        state.children += 1;
        return .{ .operation = operation, .floor = floor };
    }

    pub fn advance(self: *Inventory) !read_mod.Step {
        const state = op.state(self.operation);
        const own = try self.operation.inspectGrant(null);
        if (self.done) return .ready;
        if (self.query == null) {
            var grants = try state.read.grantView();
            _ = try grants.borrow(own.id);
            defer grants.release();
            self.query = Query.initAt(&state.read, state.read.heldRow().children, .grant, self.floor);
        }
        if (self.entry == null) {
            const step = try self.query.?.advance();
            if (step != .ready) return step;
            self.entry = self.query.?.entry;
            if (self.entry == null) {
                self.done = self.query.?.done;
                return .ready;
            }
        }
        if (self.lease == null) switch (try self.load.acquire(state.binding.owner.store, self.entry.?.object)) {
            .read => |request| return .{ .read = request },
            .waiting => return .waiting,
            .ready => |lease| self.lease = lease,
        };
        return .ready;
    }

    pub fn take(self: *Inventory) !?Item {
        const state = op.state(self.operation);
        const inherited = (try self.operation.inspectGrant(null)).effective_status;
        if (self.entry == null) return null;
        const lease = self.lease orelse return error.NotPrepared;
        const store = state.binding.owner.store;
        var fixed = std.heap.FixedBufferAllocator.init(try state.read.grantScratch());
        var decoded: records.GrantRecord = undefined;
        try decoded.decodeOwned(fixed.allocator(), (try store.currentView(lease)).payload);
        defer decoded.deinit(fixed.allocator());
        const value = &decoded.grant;
        if (value.id.slot != self.entry.?.slot or value.parent == null or !value.parent.?.eql(state.descriptor.grant)) return error.InvalidRecord;
        const result = Item.of(value, inherited);
        self.floor = @as(u64, value.id.slot) + 1;
        try store.release(lease);
        self.lease = null;
        self.entry = null;
        return result;
    }

    pub fn completeRead(self: *Inventory, ticket: loam.Ticket, result: loam.ReadResult) !void {
        const state = op.state(self.operation);
        if (self.load.pending != null) return self.load.complete(state.binding.owner.store, ticket, result);
        return self.query.?.completeRead(ticket, result);
    }

    pub fn deinit(self: *Inventory) void {
        const state = op.state(self.operation);
        if (self.lease) |lease| state.binding.owner.store.release(lease) catch unreachable;
        state.children -= 1;
    }
};
