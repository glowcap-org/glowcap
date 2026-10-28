//! The drive of the retained-call lifecycle: advancing, invoking, and
//! settling the operations `calls.zig` admits.
//!
//! Admission (`calls.admit`) enqueues. This module owns every later phase:
//! preparation, invocation, result custody, settlement, and reset. One
//! direction: the drive reads the custody types and rows from `calls.zig`,
//! which never reaches back in.

const std = @import("std");

const core = @import("loam_core");
const actors = @import("actors");
const driver = @import("driver_core");
const model = @import("model");
const h = @import("attachment.zig");
const calls = @import("calls.zig");
const values = @import("values.zig");
const storage = @import("storage.zig");
const forwarding = @import("forwarding.zig");
const publication = @import("publication.zig");

/// Storage completions only change eligibility. Ready invocations run as
/// ordinary Vat turns. Settlement runs here at a top-level owner boundary.
pub fn advance(owner: *h.Attachment) !void {
    _ = try advanceProgress(owner);
}

/// Reports work that needs another owning Host turn, including effects emitted
/// during preparation. Parked foreign replies and storage workers stay idle.
pub fn advanceProgress(owner: *h.Attachment) !bool {
    try owner.topLevel();
    // Released endpoint rows still borrow their fixed entries until the next
    // ordinary Vat boundary. Host progress owns that retirement even with no
    // queued invocation; otherwise idle release leaves capacity occupied.
    var progressed = owner.host.vat.hasRetiredState();
    if (progressed) {
        owner.advancing = true;
        defer owner.advancing = false;
        _ = try owner.host.vat.near(owner.runner, .{ .verb = "barrier", .args = &.{} });
    }
    progressed = (if (owner.discovery) |discovery| try discovery.advanceProgress() else false) or progressed;
    if (owner.options.live_scope) |scope| progressed = (try scope.advanceProgress()) or progressed;
    progressed = (try advanceOperations(owner)) or progressed;
    // Preparation can emit a fetch or dial while its operation stays waiting.
    // The embedder must drain that Host work before parking for its reply.
    return progressed or owner.host.hasRunnableWork();
}

/// Where one phase block leaves its operation for the rest of the pass: the
/// next block in the cascade, or the next operation when this one parked,
/// failed, or restarted and must not advance further this pass.
const Flow = enum { fall_through, next_operation };

fn advanceOperations(owner: *h.Attachment) !bool {
    var progressed = false;
    owner.advancing = true;
    defer owner.advancing = false;
    for (owner.operations, 0..) |*op, index| {
        // The slice is the call capacity, not the live calls, so a free slot
        // leaves before the ladder.
        if (op.phase == .free or op.pending_read) continue;
        const prior_phase = op.phase;
        defer progressed = progressed or op.phase != prior_phase;
        // Retire uninvoked preparations; committed writes and effects keep custody.
        if ((op.phase == .waiting or op.phase == .restarting) and !owner.host.vat.hasIngress(op.ingress)) {
            op.failure = error.UnknownIngress;
            op.phase = .failed;
            continue;
        }
        if (op.phase == .restarting) {
            reset(owner, op);
            op.phase = .waiting;
            continue;
        }
        if (op.phase == .forwarding and beginForwarding(owner, op) == .next_operation) continue;
        if (op.phase == .forwarded) switch (op.forwarded.poll()) {
            .pending => continue,
            .failed => |failed| {
                op.failure = error.ForwardedCallFailed;
                op.failure_reason = failed.message;
                op.failure_kind = failed.kind;
                op.forwarded_failure = true;
                op.phase = .failed;
            },
            .ready => |reply| {
                op.reply = reply;
                op.phase = .settling;
            },
        };
        if (op.completion != .receipt and op.forwarded.call != null and (op.phase == .settling or (op.phase == .failed and op.forwarded_failure))) {
            // A resolver retry repeats admission against a fresh preparation.
            // Always start projection from the immutable upstream result.
            // Application lifetime can change without a storage revision.
            retirePreparation(owner, op);
            if (!op.forwarded_failure) op.reply = op.forwarded.poll().ready;
            op.disclosure = .pending;
            op.phase = .disclosing;
        }
        if (op.phase == .disclosing and disclose(owner, op, index) == .next_operation) continue;
        if (op.phase == .settling and op.completion != .receipt and op.forwarded.call != null) retainPublicResult(op) catch |err| {
            op.failure = err;
            op.failure_reason = null;
            op.phase = .failed;
        };
        if (op.phase == .materializing and op.call.?.replacement == null and op.call.?.transaction == null and
            (owner.store.phase != .idle or op.snapshot_revision != owner.store.metadata.revision))
        {
            reset(owner, op);
            op.phase = .waiting;
            continue;
        }
        if (op.phase == .materializing) finishInvocation(owner, index) catch |err| {
            if (owner.store.phase == .staging or owner.store.phase == .prepared) {
                owner.store.abort() catch unreachable;
                publication.releaseRetirements(owner, .release_fenced);
            }
            op.failure = err;
            op.phase = .failed;
        };
        if (op.phase == .settling or op.phase == .failed) try settle(owner, op);
        if (op.phase == .waiting and owner.store.phase == .idle) try schedule(owner, op, index);
    }
    return progressed;
}

/// Hand a prepared call to its forwarding target. The preparation retires
/// once the forwarded call owns the intent, and a store that moved under the
/// snapshot restarts the operation instead.
fn beginForwarding(owner: *h.Attachment, op: *calls.Operation) Flow {
    if (owner.store.phase != .idle or op.snapshot_revision != owner.store.metadata.revision) {
        reset(owner, op);
        op.phase = .waiting;
        return .next_operation;
    }
    const action = op.call.?.forward.?;
    // Source callbacks establish admission; private execution retains
    // the selected request rather than accepting rewritten arguments.
    const request = if (op.completion != .protected) op.dispatch.? else h.Call.Intent{ .verb = action.verb, .args = action.args };
    const arena = op.memory.input.allocator();
    op.forwarded.begin(&op.lifetime, action.target, request.verb, request.args, arena, owner.options.forward_reply_bytes) catch |err| {
        op.failure = err;
        op.phase = .failed;
        return .next_operation;
    };
    if (op.completion == .receipt) op.completion.receipt.admitted = true;
    retirePreparation(owner, op);
    op.phase = .forwarded;
    return .fall_through;
}

/// Re-admit a forwarded result against a fresh preparation before it is
/// disclosed to the caller.
fn disclose(owner: *h.Attachment, op: *calls.Operation, index: usize) Flow {
    if (owner.store.phase != .idle) return .next_operation;
    const ready = prepareCurrent(owner, op, index) catch |err| {
        op.failure = err;
        op.failure_reason = null;
        op.forwarded_failure = false;
        op.failure_kind = .broken;
        op.disclosure = .none;
        op.phase = .failed;
        return .next_operation;
    };
    if (!ready) return .next_operation;
    op.disclosure = .checked;
    op.phase = if (op.forwarded_failure) .failed else .settling;
    return .fall_through;
}

/// Prepare a waiting operation and send its invocation through the owning
/// ingress once no earlier operation on the same entry still holds it. status-allow: event or source ordering
fn schedule(owner: *h.Attachment, op: *calls.Operation, index: usize) !void {
    for (owner.operations) |*other| {
        // Forwarded calls hold immutable intent/result custody, not the
        // source's preparation or storage lease. Waiting on their target
        // cannot exclude that target's own invocation of this entry.
        if (other.phase != .free and other.phase != .forwarded and other.entry == op.entry and other.sequence < op.sequence) return;
    }
    const ready = prepareCurrent(owner, op, index) catch |err| {
        op.failure = err;
        op.phase = .failed;
        return;
    };
    if (!ready) return;
    _ = owner.host.vat.sendObservedFromIngress(op.ingress, owner.runner, .{
        .verb = "invoke",
        .args = &.{ .{ .integer = @intCast(index) }, .{ .integer = @intCast(op.sequence) } },
    }, .{ .ctx = op, .func = dispatched }) catch |err| {
        reset(owner, op);
        if (err == error.UnknownIngress) {
            // Session cancellation removes admission while this call may
            // still own storage preparation. Retire its exact operation;
            // a disconnected caller cannot condemn unrelated Host work.
            op.failure = err;
            op.phase = .failed;
            return;
        }
        return err;
    };
    op.phase = .scheduled;
    // Wake through the owning Host lane: its session quantum and
    // close verdict still govern deferred application work.
    if (op.peer) |peer| {
        if (owner.host.sessionForPeer(peer)) |session| try owner.host.flushSession(session);
    }
}

fn prepare(owner: *h.Attachment, op: *calls.Operation) !void {
    if (op.call != null) return;
    const view = try owner.store.view(op.lease.?);
    const behavior = try owner.findBehavior(view);
    op.call = .{ .memory = &op.memory, .attachment = owner, .view = view, .context = behavior.context, .dependent_target = op.dependent_target, .dispatch = op.dispatch, .work = &op.lifetime };
    if (behavior.prepare) |factory| op.call.?.preparation = try factory(&op.call.?, op.verb, op.args);
}

/// No outstanding read may borrow working storage. Terminal results occupy
/// input custody when they must survive a fresh admission preparation.
fn retirePreparation(owner: *h.Attachment, op: *calls.Operation) void {
    std.debug.assert(!op.pending_read);
    if (op.call) |*call| {
        call.release();
        if (call.preparation) |working| working.deinit();
    }
    op.call = null;
    if (op.lease) |lease| owner.store.release(lease) catch unreachable;
    op.lease = null;
    op.memory.resetWorking();
}

pub fn reset(owner: *h.Attachment, op: *calls.Operation) void {
    op.forwarded.deinit();
    op.failure_reason = null;
    retirePreparation(owner, op);
}

/// A stale preparation must preserve a completed target and its exact outcome.
pub fn reprepare(owner: *h.Attachment, op: *calls.Operation) void {
    if (op.disclosure != .none) retirePreparation(owner, op) else reset(owner, op);
}

fn prepareCurrent(owner: *h.Attachment, op: *calls.Operation, index: usize) !bool {
    try op.lifetime.checkHost(owner.host);
    if (op.lease != null and op.snapshot_revision != owner.store.metadata.revision) retirePreparation(owner, op);
    if (op.lease == null) {
        const acquired = owner.store.acquire(op.entry.id) catch |err| switch (err) {
            error.PendingRead, error.ResidentCapacity, error.LeaseCapacity => return false,
            else => return err,
        };
        switch (acquired) {
            .read => |read| {
                storage.retainRead(owner, read, .store);
                return false;
            },
            .ready => |lease| {
                op.lease = lease;
                op.snapshot_revision = owner.store.metadata.revision;
            },
        }
    }
    try prepare(owner, op);
    if (op.call.?.preparation) |working| switch (try working.advance()) {
        .waiting => return false,
        .read => |read| {
            op.pending_read = true;
            storage.retainRead(owner, read, .{ .operation = index });
            return false;
        },
        .ready => {},
    };
    return true;
}

fn dispatched(ctx: ?*anyopaque, _: actors.Resolution) void {
    const op: *calls.Operation = @ptrCast(@alignCast(ctx.?));
    if (op.phase != .scheduled) return;
    // The runner normally changes phase before resolving. A still-scheduled
    // operation was canceled or refused before invoking its behavior.
    op.failure = error.ActivationCanceled;
    op.phase = .failed;
}

pub const Runner = struct {
    owner: *h.Attachment,
    pub fn handle(self: *Runner, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "barrier")) return .{ .void = {} };
        if (!std.mem.eql(u8, msg.verb, "invoke") or (try msg.args.len()) != 2) return error.InvalidDelivery;
        const index = std.math.cast(usize, try msg.argInt(0)) orelse return error.InvalidDelivery;
        if (index >= self.owner.operations.len) return error.InvalidDelivery;
        const op = &self.owner.operations[index];
        if (op.phase != .scheduled or op.sequence != try msg.argInt(1)) return error.StaleCompletion;
        if (self.owner.store.phase != .idle or op.snapshot_revision != self.owner.store.metadata.revision) {
            // Retire preparation at the next top-level advance boundary.
            op.phase = .restarting;
            return .{ .void = {} };
        }
        invoke(self.owner, index) catch |err| {
            op.failure = err;
            if (err == error.ApplicationRefused) op.failure_reason = op.call.?.refusal;
            op.phase = .failed;
        };
        return .{ .void = {} };
    }
};

fn invoke(owner: *h.Attachment, index: usize) !void {
    const op = &owner.operations[index];
    try op.lifetime.checkHost(owner.host);
    // Preparation may borrow portrait bytes until its deinit at settlement.
    // Keep the lease through commit and resolver retries, even after invocation.
    const view = try owner.store.view(op.lease.?);
    // A queued lease is a snapshot. Another actor may have committed between
    // scheduling and execution; reacquire instead of invoking on stale state.
    if (op.lease.?.incarnation != owner.store.metadata.incarnation) return error.StaleCompletion;
    const behavior = try owner.findBehavior(view);
    const arena = op.memory.working.allocator();
    owner.stats.invocations += 1;
    op.reply = try behavior.invoke(&op.call.?, view, op.verb, op.args);
    if (op.completion != .protected) {
        const action = op.call.?.forward orelse return error.InvalidContinuationDispatch;
        if (!action.target.eql(op.dependent_target.?) or !std.mem.eql(u8, action.verb, op.dispatch.?.verb)) return error.InvalidContinuationDispatch;
    }
    if (op.call.?.confirmation) |confirmation| {
        if (confirmation.requires_commit and op.call.?.replacement == null and op.call.?.transaction == null) return error.ReceiptRequired;
    }
    if (op.call.?.forward != null) {
        if (op.call.?.replacement != null or op.call.?.transaction != null or op.call.?.result != null or op.call.?.confirmation != null) return error.InvalidForwarding;
        op.phase = .forwarding;
        return;
    }
    if (op.call.?.replacement != null or op.call.?.transaction != null) {
        // Local-only resolver results cannot transport owning capability values.
        try owner.store.begin();
        errdefer {
            if (owner.store.phase == .staging or owner.store.phase == .prepared) owner.store.abort() catch unreachable;
            publication.releaseRetirements(owner, .release_fenced);
        }
        if (op.call.?.replacement) |payload| {
            const edges = try arena.alloc(core.Edge, view.edge_count);
            var iterator = view.edges();
            for (edges) |*edge| edge.* = iterator.next().?;
            try owner.store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .schema_version = view.schema_version, .rooted = view.rooted, .payload = payload, .edges = edges }, view.revision);
        }
        if (op.call.?.transaction) |participant| try participant.stage(participant.context, owner.store);
        if (op.call.?.result != null) {
            op.phase = .materializing;
            return;
        }
        try finishInvocation(owner, index);
        return;
    }
    if (op.call.?.result != null) op.phase = .materializing else try finishInvocation(owner, index);
}

fn finishInvocation(owner: *h.Attachment, index: usize) !void {
    const op = &owner.operations[index];
    if (op.call.?.result) |result| op.reply = try result(&op.call.?);
    try retainResult(op, op.reply);
    if (op.call.?.replacement != null or op.call.?.transaction != null) {
        if (owner.options.live_scope) |scope| try scope.validateStaged();
        try owner.store.retainOnCommit();
        const ticket = try owner.store.prepare();
        const batch = try owner.store.beginWrite(ticket);
        owner.writing = .{ .batch = batch, .operation = index };
        op.phase = .writing;
    } else op.phase = .settling;
}

fn retainResult(op: *calls.Operation, reply: driver.Value) !void {
    const local = op.resolver == .local;
    const has_capability = try op.call.?.prepareReply(reply, if (local) .validate_only else .retain);
    if (local and has_capability) return error.OwningReplyRequired;
    // Invocation/result callbacks return call-lifetime data. A foreign Host
    // result keeps its Call owner until reset; local forwarded replies already
    // copy at their callback boundary. Capability custody is prepared above.
    op.reply = reply;
}

fn retainPublicResult(op: *calls.Operation) !void {
    // Projection is after current source admission, before outward retention.
    // It cannot lend the raw capability that arrived from the target.
    const reply = if (op.completion == .mediated)
        try op.completion.mediated.project(op.completion.mediated.context, &op.call.?, op.reply)
    else
        op.reply;
    try retainResult(op, reply);
}

fn settle(owner: *h.Attachment, op: *calls.Operation) !void {
    const failed = op.phase == .failed;
    if (!failed and !op.confirmed) {
        if (op.call) |*call| if (call.confirmation) |confirmation| {
            call.confirmation = null;
            confirmation.apply(confirmation.context);
        };
        op.confirmed = true;
    }
    switch (op.resolver) {
        .none => {},
        .local => |resolver| {
            if (failed) try owner.host.vat.breakVow(resolver, op.failure_reason orelse @errorName(op.failure)) else {
                // Conversion may be retried after allocation refusal. This is
                // preparation only; it does not rerun the actor or its write.
                var arena = std.heap.ArenaAllocator.init(owner.allocator);
                defer arena.deinit();
                try owner.host.vat.fulfillVow(resolver, try values.copy(model.Argument, arena.allocator(), op.reply));
            }
        },
        .host => |resolver| host_reply: {
            var arena = std.heap.ArenaAllocator.init(owner.allocator);
            defer arena.deinit();
            if (!failed) owner.host.resolverFulfillValue(resolver, op.reply, arena.allocator()) catch |err| {
                if (err == error.AlreadySettled) break :host_reply;
                if (!driver.Host.Call.replyRefusalIsPermanent(err)) return err;
                // This reply is immutable. Retrying cannot enlarge its buffer
                // or restore a retired capability home. Keep its owner until
                // rejection succeeds; temporary heap refusal retries rejection.
                op.failure = err;
                op.failure_reason = null;
                op.failure_kind = .broken;
                op.phase = .failed;
            };
            if (op.phase == .failed) owner.host.resolverReject(resolver, op.failure_kind, op.failure_reason orelse @errorName(op.failure)) catch |err| switch (err) {
                error.AlreadySettled => {},
                else => return err,
            };
        },
    }
    reset(owner, op);
    if (owner.options.sleep_policy == .every_turn) {
        if (owner.store.evictObject(op.entry.id) catch false) owner.stats.sleeps += 1;
    }
    owner.host.vat.releaseActor(op.entry.actor.?.local);
    if (op.dependent_target) |target| owner.host.releaseCapabilityTerminal(target, null);
    for (op.argument_retains) |retained| owner.host.releaseCapabilityTerminal(retained, null);
    for (op.dispatch_retains) |retained| owner.host.releaseCapabilityTerminal(retained, null);
    op.lifetime.complete();
    owner.pending_bytes -= owner.options.call_bytes;
    op.memory.deinit();
    op.completion.release();
    op.* = .{};
}
