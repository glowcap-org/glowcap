//! Synchronous benchmark executor shared by ordinary and managed workloads.
const core = @import("glowcap").loam.core;

pub fn load(self: anytype, id: core.ObjectId) !core.Lease {
    return switch (try self.store.acquire(id)) {
        .ready => |lease| lease,
        .read => |request| blk: {
            self.reads += 1;
            try self.store.completeRead(request.ticket, self.db.read(request));
            break :blk (try self.store.acquire(id)).ready;
        },
    };
}

pub fn finish(self: anytype, ticket: core.Ticket) !void {
    const outcome = self.db.commit(try self.store.beginWrite(ticket));
    try self.store.completeWrite(ticket, outcome);
    switch (outcome) {
        .committed => self.writes += 1,
        .unchanged => |err| return err,
        .unknown => return error.OutcomeUnknown,
    }
}

pub fn drain(self: anytype) !void {
    for (0..4096) |_| {
        _ = try self.host.vat.driveIngressBudgeted(.local, 128);
        try self.attachment.advance();
        while (try self.attachment.nextWork()) |work| switch (work) {
            .lookup => |request| try self.attachment.completeLookup(request.ticket, self.db.lookup(request)),
            .read => |request| {
                self.reads += 1;
                try self.attachment.completeRead(request.ticket, self.db.read(request));
            },
            .write => |batch| {
                const outcome = self.db.commit(batch);
                try self.attachment.completeWrite(batch.ticket, outcome);
                if (outcome != .committed) return error.CommitFailed;
                self.writes += 1;
            },
        };
        if (!self.attachment.hasPendingWork()) {
            _ = try self.host.vat.driveIngressBudgeted(.local, 128);
            return;
        }
    }
    return error.DidNotQuiesce;
}
