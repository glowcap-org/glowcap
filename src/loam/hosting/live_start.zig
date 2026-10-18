//! Live startup uses the attachment's existing read and write completion lane.
const core = @import("loam_core");
const Scope = @import("live_scope.zig").Scope;
const std = @import("std");
const storage = @import("storage.zig");

pub const Start = struct {
    prior: ?core.ObjectId,
    phase: enum { loading, writing, confirming, ready, failed } = .loading,
    pending: ?core.Ticket = null,
    failure: anyerror = error.LiveScopeNotStarted,

    pub fn advance(self: *Start, scope: *Scope) !bool {
        if (self.pending != null or scope.store.phase != .idle) return false;
        switch (self.phase) {
            .loading => {
                var prior: ?core.Lease = null;
                defer if (prior) |lease| scope.store.release(lease) catch unreachable;
                if (self.prior) |id| {
                    prior = (try self.acquire(scope, id)) orelse return self.pending != null;
                }
                try scope.store.begin();
                errdefer scope.store.abort() catch unreachable;
                _ = try scope.stageStart(prior);
                _ = try scope.owner.?.submit();
                self.phase = .writing;
                return true;
            },
            .confirming => {
                const lease = (try self.acquire(scope, scope.proposal.?.epoch.object)) orelse return self.pending != null;
                defer scope.store.release(lease) catch unreachable;
                try scope.confirmStart(lease);
                self.phase = .ready;
                return true;
            },
            else => return false,
        }
    }

    fn acquire(self: *Start, scope: *Scope, id: core.ObjectId) !?core.Lease {
        const acquired = scope.store.acquire(id) catch |err| switch (err) {
            error.PendingRead, error.ResidentCapacity, error.LeaseCapacity, error.Busy => return null,
            else => return err,
        };
        switch (acquired) {
            .ready => |lease| return lease,
            .read => |read| {
                self.pending = read.ticket;
                storage.retainRead(scope.owner.?, read, .store);
                return null;
            },
        }
    }

    pub fn readFinished(self: *Start, ticket: core.Ticket, failure: ?anyerror) bool {
        if (self.pending == null or !std.meta.eql(self.pending.?, ticket)) return false;
        self.pending = null;
        if (failure) |err| {
            if (err == error.StaleCompletion) return false;
            self.failure = err;
            self.phase = .failed;
            return err == error.Gone;
        }
        return false;
    }

    pub fn writeFinished(self: *Start, scope: *Scope, ticket: core.Ticket, failure: ?anyerror) void {
        if (self.phase != .writing) return;
        const epoch = scope.proposal.?.epoch;
        if (epoch.opening.incarnation != ticket.incarnation or epoch.opening.sequence != ticket.sequence) return;
        if (failure) |err| {
            scope.proposal = null;
            self.failure = err;
            self.phase = .failed;
        } else self.phase = .confirming;
    }
};
