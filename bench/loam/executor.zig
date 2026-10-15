//! Synchronous benchmark executor shared by ordinary and managed workloads.
const core = @import("glowcap").loam.core;
const Worker = @import("glowcap").loam.hosting.Worker;

/// A workload that declares `read_bytes` also totals the encoded length of every
/// record its backend returns.
fn countBytes(self: anytype, result: core.ReadResult) void {
    if (@hasField(@typeInfo(@TypeOf(self)).pointer.child, "read_bytes")) switch (result) {
        .found => |found| self.read_bytes += found.length,
        else => {},
    };
}

pub fn load(self: anytype, id: core.ObjectId) !core.Lease {
    return switch (try self.store.acquire(id)) {
        .ready => |lease| lease,
        .read => |request| blk: {
            self.reads += 1;
            const result = self.db.read(request);
            countBytes(self, result);
            try self.store.completeRead(request.ticket, result);
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

/// Advance the attachment and run its storage work, counting each read,
/// lookup, and committed write. Any other write outcome is `CommitFailed`.
pub fn service(self: anytype) !void {
    var slot: [1]Worker.Slot = undefined;
    var worker: Worker = .init(&slot, self.db.readerCapacity());
    try self.attachment.advance();
    while (try worker.next(self.attachment, false)) |work| {
        try Worker.run(work, self.db);
        try worker.complete(work, self.attachment);
        switch (work.request) {
            .read => {
                self.reads += 1;
                countBytes(self, work.result.?.read);
            },
            .lookup => self.lookups += 1,
            .write => if (work.result.?.write == .committed) {
                self.writes += 1;
            } else return error.CommitFailed,
            .recover => {},
        }
        try worker.release(work);
    }
}

pub fn drain(self: anytype) !void {
    for (0..4096) |_| {
        _ = try self.host.vat.driveIngressBudgeted(.local, 128);
        try service(self);
        if (!self.attachment.hasPendingWork()) {
            _ = try self.host.vat.driveIngressBudgeted(.local, 128);
            return;
        }
    }
    return error.DidNotQuiesce;
}
