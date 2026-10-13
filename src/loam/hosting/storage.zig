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
    if (owner.discovery) |discovery| if (try discovery.nextWork()) |lookup| return .{ .lookup = lookup };
    return null;
}

pub fn completeLookup(owner: *h.Attachment, ticket: core.Ticket, result: core.NameResult) !void {
    try owner.topLevel();
    const discovery = owner.discovery orelse return error.StaleCompletion;
    return discovery.complete(ticket, result);
}

pub fn completeRead(owner: *h.Attachment, ticket: core.Ticket, result: core.ReadResult) !void {
    try owner.topLevel();
    const slot = for (owner.reads) |*slot| {
        if (slot.* != null and slot.*.?.submitted and std.meta.eql(slot.*.?.request.ticket, ticket)) break slot;
    } else return error.StaleCompletion;
    const id = slot.*.?.request.id;
    const prepared = slot.*.?.operation;
    slot.* = null;
    // The preparation may own the Store completion. Dispatch exactly once,
    // then notify every consumer of this shared read before handling refusal.
    const completion = if (prepared) |index| blk: {
        const op = &owner.operations[index];
        op.pending_read = false;
        break :blk op.call.?.preparation.?.completeRead(ticket, result);
    } else owner.store.completeRead(ticket, result);
    const failure: ?anyerror = if (completion) |_| null else |err| err;
    const discovered = if (owner.discovery) |discovery| discovery.readFinished(id, failure) else false;
    const live_missing = if (owner.options.live_scope) |scope| scope.readFinished(ticket, failure) else false;
    if (failure) |err| {
        if (prepared) |index| {
            const op = &owner.operations[index];
            if (err == error.StaleCompletion) {
                @import("drive.zig").reprepare(owner, op);
                return;
            }
            op.failure = err;
            op.phase = .failed;
        } else {
            if (err == error.StaleCompletion) return;
            for (owner.operations) |*operation| {
                if ((operation.phase == .waiting or operation.phase == .disclosing) and operation.entry.id.eql(id)) {
                    operation.failure = err;
                    operation.phase = .failed;
                }
            }
            // A retained index can name a collected descriptor. Discovery
            // owns this expected miss; no storage failure escapes its lane.
            if (err == error.Gone and (publication.forgetMissingRepublish(owner, id) or discovered or live_missing)) return;
        }
        return err;
    }
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

/// True while this attachment's own write is uncertain and waits for
/// `recoveryBatch` and `resolve`. A sibling's uncertain write is not this one.
pub fn awaitsRecovery(owner: *const h.Attachment) bool {
    return if (owner.writing) |writing| writing.uncertain else false;
}

pub fn recoveryBatch(owner: *h.Attachment) !core.Batch {
    try owner.topLevel();
    if (!awaitsRecovery(owner)) return error.WrongPhase;
    return owner.store.recoveryBatch();
}

pub fn resolve(owner: *h.Attachment, ticket: core.Ticket, resolution: core.Resolution) !void {
    try owner.topLevel();
    if (!awaitsRecovery(owner)) return error.WrongPhase;
    try owner.store.resolve(ticket, resolution);
    if (resolution == .committed) {
        publication.releaseRetirements(owner, false);
        finish(owner, null);
    } else {
        publication.deferRepublish(owner);
        finish(owner, error.WriteNotCommitted);
    }
}

fn finish(owner: *h.Attachment, failure: ?anyerror) void {
    if (owner.options.live_scope) |scope| scope.writeFinished(owner.writing.?.batch.ticket, failure);
    if (owner.writing.?.operation) |index| {
        const operation = &owner.operations[index];
        if (operation.call) |*call| if (call.references) |references| references.finish(owner.writing.?.batch.ticket, failure == null);
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
/// `store.begin()` and staging helpers. This prepares and claims the lane.
pub fn submit(owner: *h.Attachment) !core.Ticket {
    try owner.topLevel();
    if (owner.writing != null) return error.Busy;
    if (owner.options.live_scope) |scope| try scope.validateStaged();
    const ticket = try owner.store.prepare();
    owner.writing = .{ .batch = try owner.store.beginWrite(ticket), .operation = null };
    return ticket;
}
