//! Byte-fed Host sessions expose protocol cost without socket latency.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const driver = g.driver.core;

pub const Pair = struct {
    host: *driver.Host,
    witness: *driver.Host,
    session: *driver.HostSession,
    accepted: *driver.HostSession,
    frames: u64 = 0,
    frame_bytes: u64 = 0,

    pub fn open(host: *driver.Host, witness: *driver.Host, designator: []const u8) !Pair {
        const locator: g.ocapn.model.PeerLocator = .{ .transport = "tcp", .designator = designator, .hints = g.ocapn.model.Hints.emptyFalse() };
        try witness.setAdvertisedLocator(locator);
        const accepted = try witness.openAcceptedAdvertised("tcp");
        errdefer witness.releaseSession(accepted) catch unreachable;
        try host.ensureAdvertisedLocator("tcp");
        const session = try host.openDialedLocator(locator);
        errdefer host.releaseSession(session) catch unreachable;
        var self: Pair = .{ .host = host, .witness = witness, .session = session, .accepted = accepted };
        for (0..64) |_| {
            if (!try self.shuttle()) break;
        } else return error.HandshakeDidNotFinish;
        if (!session.sessionOpen() or !accepted.sessionOpen()) return error.HandshakeDidNotFinish;
        return self;
    }

    pub fn close(self: *Pair) void {
        self.host.releaseSession(self.session) catch unreachable;
        self.witness.releaseSession(self.accepted) catch unreachable;
    }

    pub fn shuttle(self: *Pair) !bool {
        var moved = false;
        for ([_]struct { from: *driver.HostSession, to: *driver.HostSession, host: *driver.Host }{
            .{ .from = self.session, .to = self.accepted, .host = self.witness },
            .{ .from = self.accepted, .to = self.session, .host = self.host },
        }) |direction| while (try direction.from.takeOutbound()) |outbound| {
            var frame = outbound;
            defer frame.deinit();
            self.frames += 1;
            self.frame_bytes += frame.view().bytes.len;
            try direction.host.feed(direction.to, frame.view());
            moved = true;
        };
        return moved;
    }

    pub fn drain(self: *Pair, workload: *m.Managed, other: anytype) !void {
        for (0..4096) |_| {
            try self.host.flushSession(self.session);
            try self.witness.flushSession(self.accepted);
            const moved = try self.shuttle();
            try service(workload);
            if (other) |target| try service(target);
            try actions(self.host);
            try actions(self.witness);
            const after_actions = try self.shuttle();
            if (!moved and !after_actions and !workload.attachment.hasPendingWork() and self.host.pendingVowCount() == 0 and self.witness.pendingVowCount() == 0) {
                if (other) |target| if (target.attachment.hasPendingWork()) continue;
                return;
            }
        }
        return error.DidNotQuiesce;
    }
};

fn actions(host: *driver.Host) !void {
    while (try host.nextAction()) |action| {
        switch (action) {
            // Notifications conservatively announce possible output. The
            // following shuttle decides progress from actual frames, not
            // from a flush hint repeated by an explicit flushSession call.
            .flush, .resume_work => {},
            .close => |peer| if (host.sessionForPeer(peer) != null) return error.UnexpectedSessionClose,
            // This workload connects its only two peers before restoration
            // and owns every answer. A new physical effect needs an executor.
            .dial, .cancel_dial, .need_gift_id, .settled, .failed => return error.UnexpectedHostAction,
        }
    }
}

fn service(workload: anytype) !void {
    try workload.attachment.advance();
    while (try workload.attachment.nextWork()) |work| switch (work) {
        .read => |read| {
            workload.reads += 1;
            try workload.attachment.completeRead(read.ticket, workload.db.read(read));
        },
        .lookup => |lookup| {
            workload.lookups += 1;
            try workload.attachment.completeLookup(lookup.ticket, workload.db.lookup(lookup));
        },
        .write => |batch| {
            const outcome = workload.db.commit(batch);
            try workload.attachment.completeWrite(batch.ticket, outcome);
            if (outcome != .committed) return error.CommitFailed;
            workload.writes += 1;
        },
    };
}
