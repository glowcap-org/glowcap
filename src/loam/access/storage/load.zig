//! One explicit read submission, retaining ownership until exact completion.
const std = @import("std");
const loam = @import("loam_core");

pub const Load = struct {
    pending: ?loam.Read = null,
    failure: ?anyerror = null,

    pub const Step = union(enum) { ready: loam.Lease, read: loam.Read, waiting };
    pub const Row = struct {
        view: loam.RecordView,
        lease: ?loam.Lease = null,

        pub fn release(self: Row, store: *loam.Store) void {
            if (self.lease) |lease| store.release(lease) catch unreachable;
        }
    };
    pub const Resolved = union(enum) { ready: Row, read: loam.Read, waiting };

    /// Borrow a proposal for synchronous use or own one transient committed
    /// lease. Release a ready row before staging or advancing its transaction.
    pub fn resolve(self: *Load, store: *loam.Store, id: loam.ObjectId) !Resolved {
        if (self.failure) |err| return err;
        if (self.pending != null) return .waiting;
        if (try store.proposed(id)) |proposal| return .{ .ready = .{ .view = proposal.view } };
        return switch (try self.acquire(store, id)) {
            .read => |request| .{ .read = request },
            .waiting => .waiting,
            .ready => |lease| result: {
                errdefer store.release(lease) catch unreachable;
                break :result .{ .ready = .{ .view = try store.currentView(lease), .lease = lease } };
            },
        };
    }

    pub fn acquire(self: *Load, store: *loam.Store, id: loam.ObjectId) !Step {
        if (self.failure) |err| return err;
        if (self.pending != null) return .waiting;
        const result = store.acquire(id) catch |err| switch (err) {
            error.PendingRead => return .waiting,
            else => return err,
        };
        return switch (result) {
            .ready => |lease| .{ .ready = lease },
            .read => |read| blk: {
                self.pending = read;
                break :blk .{ .read = read };
            },
        };
    }

    pub fn complete(self: *Load, store: *loam.Store, ticket: loam.Ticket, result: loam.ReadResult) !void {
        const pending = self.pending orelse return error.StaleCompletion;
        if (!std.meta.eql(pending.ticket, ticket)) return error.StaleCompletion;
        self.pending = null;
        store.completeRead(ticket, result) catch |err| {
            self.failure = err;
            return err;
        };
    }

    pub fn cancel(self: *Load, store: *loam.Store) !void {
        if (self.pending) |pending| try store.cancelRead(pending.ticket);
    }
};
