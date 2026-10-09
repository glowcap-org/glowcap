//! A held control walks its own child index with one revision-bound path.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const loam = @import("loam_core");
const op = @import("capability_operation.zig");
const read_mod = @import("read.zig");
const Query = @import("directory_query.zig").DirectoryQuery;

pub const Inventory = struct {
    operation: *op.Operation,
    query: ?Query = null,
    floor: u64,
    entry: ?Query.Entry = null,
    lease: ?loam.Lease = null,
    done: bool = false,
    load: @import("load.zig").Load = .{},

    /// Scalar copies survive the next model lookup. No use endpoint, bearer
    /// secret or owner's unrelated grant population participates in this page.
    pub const Item = struct {
        id: core.GrantId,
        revision: core.Revision,
        label: core.GrantLedger.Label,
        status: core.GrantLedger.Status,
        effective_status: core.GrantLedger.Status,
        ceiling: core.Policy.Value,
        configured: core.Policy.Value,
        delegation_depth: u16,
    };

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
            const binding = (try state.read.?.binding(.{ .grant = own.id })).?;
            const row = (try read_mod.Read.rowFor(state.binding.owner.store, binding)).?.view;
            var fixed = std.heap.FixedBufferAllocator.init(state.read.?.grantScratch());
            var record = try records.GrantRecord.decodeOwned(fixed.allocator(), row.payload);
            defer record.deinit(fixed.allocator());
            self.query = Query.initAt(&state.read.?, record.value.children, .grant, self.floor);
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
        _ = try self.operation.inspectGrant(null);
        if (self.entry == null) return null;
        const lease = self.lease orelse return error.NotPrepared;
        const store = state.binding.owner.store;
        var fixed = std.heap.FixedBufferAllocator.init(state.read.?.grantScratch());
        var decoded = try records.GrantRecord.decodeOwned(fixed.allocator(), (try store.currentView(lease)).payload);
        defer decoded.deinit(fixed.allocator());
        const value = decoded.value.grant;
        if (value.id.slot != self.entry.?.slot or value.parent == null or !value.parent.?.eql(state.descriptor.grant)) return error.InvalidRecord;
        const inherited = (try self.operation.describeControl()).grant_status;
        const status: core.GrantLedger.Status = if (inherited == .revoked or value.status == .revoked) .revoked else if (inherited == .paused or value.status == .paused) .paused else .active;
        const result: Item = .{ .id = value.id, .revision = value.revision, .label = value.label, .status = value.status, .effective_status = status, .ceiling = value.ceiling.policy, .configured = value.configured.policy, .delegation_depth = value.delegation_depth };
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
