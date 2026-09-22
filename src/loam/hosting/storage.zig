//! Explicit storage submission, activation coalescing, and commit installation.
const std = @import("std");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const publication = @import("publication.zig");

pub fn prefetch(owner: *h.Attachment, ref: driver.Capability) !void {
    try owner.topLevel();
    const entry = try owner.entryFor(ref);
    const acquired = owner.store.acquire(entry.id) catch |err| switch (err) {
        error.PendingRead => return,
        else => return err,
    };
    switch (acquired) {
        .ready => |lease| try owner.store.release(lease),
        .read => |read| retainRead(owner, read, null),
    }
}

pub fn retainRead(owner: *h.Attachment, read: core.Read, operation: ?usize) void {
    for (owner.reads) |*slot| if (slot.* == null) {
        slot.* = .{ .request = read, .operation = operation };
        owner.stats.loads += 1;
        return;
    };
    unreachable; // One slot per cache slot, which owns every pending read.
}

pub fn nextWork(owner: *h.Attachment) !?h.Work {
    try owner.topLevel();
    if (owner.writing) |*write| {
        if (!write.submitted and !write.uncertain) {
            write.submitted = true;
            return .{ .write = write.batch };
        }
    }
    for (owner.reads) |*slot| if (slot.*) |*read| {
        if (!read.submitted) {
            read.submitted = true;
            return .{ .read = read.request };
        }
    };
    return null;
}

pub fn completeRead(owner: *h.Attachment, ticket: core.Ticket, result: core.ReadResult) !void {
    try owner.topLevel();
    const slot = for (owner.reads) |*slot| {
        if (slot.* != null and slot.*.?.submitted and std.meta.eql(slot.*.?.request.ticket, ticket)) break slot;
    } else return error.StaleCompletion;
    const id = slot.*.?.request.id;
    const prepared = slot.*.?.operation;
    slot.* = null;
    if (prepared) |index| {
        const op = &owner.operations[index];
        op.pending_read = false;
        op.call.?.preparation.?.completeRead(ticket, result) catch |err| {
            if (err == error.StaleCompletion) {
                @import("calls.zig").reset(owner, op);
                return;
            }
            op.failure = err;
            op.phase = .failed;
            return err;
        };
        return;
    }
    owner.store.completeRead(ticket, result) catch |err| {
        if (err == error.StaleCompletion) return; // Current calls retry current data.
        for (owner.operations) |*operation| {
            if (operation.phase == .waiting and operation.entry.id.eql(id)) {
                operation.failure = err;
                operation.phase = .failed;
            }
        }
        return err;
    };
    return publication.finishRepublish(owner, id);
}

pub fn completeWrite(owner: *h.Attachment, ticket: core.Ticket, outcome: core.Outcome) !void {
    try owner.topLevel();
    const writing = owner.writing orelse return error.StaleCompletion;
    if (!writing.submitted or writing.uncertain or !std.meta.eql(ticket, writing.batch.ticket)) return error.StaleCompletion;
    switch (outcome) {
        .committed, .unknown => try publication.fenceRetirements(owner, writing.batch),
        .unchanged => publication.releaseRetirements(owner, false),
    }
    owner.store.completeWrite(ticket, outcome) catch |err| {
        // An install that cannot confirm locally leaves the batch uncertain;
        // fenced retirement custody survives for recovery.
        if (owner.store.phase == .uncertain) {
            owner.writing.?.uncertain = true;
            publication.releaseRetirements(owner, true);
        }
        return err;
    };
    switch (outcome) {
        // The fence applied; recovery now owns the transition.
        .unknown => {
            publication.releaseRetirements(owner, true);
            owner.writing.?.uncertain = true;
        },
        .committed => {
            publication.releaseRetirements(owner, false);
            finish(owner, null);
        },
        .unchanged => |err| finish(owner, err),
    }
}

pub fn recoveryBatch(owner: *h.Attachment) !core.Batch {
    try owner.topLevel();
    if (owner.writing == null or !owner.writing.?.uncertain) return error.WrongPhase;
    return owner.store.recoveryBatch();
}

pub fn resolve(owner: *h.Attachment, ticket: core.Ticket, resolution: core.Resolution) !void {
    try owner.topLevel();
    if (owner.writing == null or !owner.writing.?.uncertain) return error.WrongPhase;
    try owner.store.resolve(ticket, resolution);
    if (resolution == .committed) {
        publication.releaseRetirements(owner, false);
        finish(owner, null);
    } else {
        try publication.republishRetirements(owner);
        finish(owner, error.WriteNotCommitted);
    }
}

fn finish(owner: *h.Attachment, failure: ?anyerror) void {
    if (owner.writing.?.operation) |index| {
        const operation = &owner.operations[index];
        if (failure) |err| {
            operation.failure = err;
            operation.phase = .failed;
        } else operation.phase = .settling;
    }
    owner.writing = null;
}

/// Submit a transaction the embedding staged directly (outside any call)
/// through the owned write lane, so its terminal outcome runs the same
/// publication-retirement fence as call-driven writes. The caller staged via
/// `store.begin()` and staging helpers; this prepares and claims the lane.
pub fn submit(owner: *h.Attachment) !core.Ticket {
    try owner.topLevel();
    if (owner.writing != null) return error.Busy;
    const ticket = try owner.store.prepare();
    owner.writing = .{ .batch = try owner.store.beginWrite(ticket), .operation = null };
    return ticket;
}
