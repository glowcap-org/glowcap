//! Explicit storage submission, activation coalescing, and commit installation.
const std = @import("std");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const publication = @import("publication.zig");
const drive = @import("drive.zig");

pub fn prefetch(owner: *h.Attachment, ref: driver.Capability) !void {
    try owner.topLevel();
    const entry = try owner.entryFor(ref);
    const acquired = owner.store.acquire(entry.id) catch |err| switch (err) {
        error.PendingRead => return,
        else => return err,
    };
    switch (acquired) {
        .ready => |lease| try owner.store.release(lease),
        .read => |read| retainRead(owner, read, .store),
    }
}

/// Start the read for a record a preparation will need after the one it
/// waits on, so a backend that pays per transaction can serve several in
/// one turn. False once the Store keeps its remaining room for demand, or
/// when it cannot start one. Read-ahead never fails its caller, because the
/// demand step that follows has already taken its result.
pub fn readAhead(owner: *h.Attachment, id: core.ObjectId) bool {
    // tolerant: a refused read-ahead only ends the window, and the demand read
    // of that record reports the exact failure.
    const acquired = owner.store.acquireAhead(id) catch return false;
    switch (acquired) {
        .read => |read| retainRead(owner, read, .ahead),
        .held => {},
        .full => return false,
    }
    return true;
}

pub fn retainRead(owner: *h.Attachment, read: core.Read, reader: h.Reader) void {
    for (owner.reads) |*slot| if (slot.* == null) {
        slot.* = .{ .request = read, .reader = reader };
        owner.stats.loads += 1;
        return;
    };
    unreachable; // One slot per cache slot, which owns every pending read.
}

/// Submit the staged write, if one waits. A worker whose reads are full
/// takes only this.
pub fn nextWrite(owner: *h.Attachment) !?core.Batch {
    try owner.topLevel();
    const write = if (owner.writing) |*write| write else return null;
    if (write.submitted or write.uncertain) return null;
    write.submitted = true;
    return write.batch;
}

pub fn nextWork(owner: *h.Attachment) !?h.Work {
    if (try nextWrite(owner)) |batch| return .{ .write = batch };
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
    const reader = slot.*.?.reader;
    slot.* = null;
    // The preparation may own the Store completion. Dispatch exactly once,
    // then notify every consumer of this shared read before handling refusal.
    const prepared: ?usize = if (reader == .operation) reader.operation else null;
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
                drive.reprepare(owner, op);
                return;
            }
            op.failure = err;
            op.phase = .failed;
        } else {
            // tolerant: a failed read-ahead leaves nothing resident, and the
            // demand read that needs the record reports its exact failure.
            if (err == error.StaleCompletion or reader == .ahead) return;
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
        .unchanged => publication.releaseRetirements(owner, .release_fenced),
    }
    owner.store.completeWrite(ticket, outcome) catch |err| {
        // An install that cannot confirm locally leaves the batch uncertain;
        // fenced retirement custody survives for recovery.
        if (owner.store.phase == .uncertain) {
            owner.writing.?.uncertain = true;
            publication.releaseRetirements(owner, .keep_fenced);
        }
        return err;
    };
    switch (outcome) {
        // The fence applied; recovery now owns the transition.
        .unknown => {
            publication.releaseRetirements(owner, .keep_fenced);
            owner.writing.?.uncertain = true;
        },
        .committed => {
            publication.releaseRetirements(owner, .release_fenced);
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
        publication.releaseRetirements(owner, .release_fenced);
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
