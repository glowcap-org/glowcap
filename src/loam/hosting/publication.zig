//! Durable publication descriptors and opt-in discovery. Stored names resolve
//! to exact actor targets through the shared transaction index and read lane.
const core = @import("loam_core");
const h = @import("attachment.zig");
const driver = @import("driver_core");

pub const Entropy = driver.Host.DurableSwiss.Entropy;
pub const LookupOptions = @import("discovery.zig").Options;

/// Enable bounded on-demand restoration for this Host's durable namespace.
/// Call once after opening the Store; no publication or actor scan is needed.
pub fn listen(attachment: *h.Attachment, options: LookupOptions) !void {
    _ = try @import("discovery.zig").Discovery.create(attachment, options);
}
pub const schema: core.Schema = .{ .id = 0x4c4f414d50554201, .version = 1, .max_payload = @sizeOf(Entropy), .max_edges = 1, .name_offset = 0 };

/// Add a publication to the caller's current transaction. It becomes usable
/// only after commit, through on-demand discovery or explicit restore. Entropy comes
/// from the embedding's entropy boundary, exactly as Host durable publication.
pub fn stage(attachment: *h.Attachment, entropy: Entropy, target: driver.Capability) !core.ObjectId {
    const edge = try attachment.capture(target);
    return stageTarget(attachment.store, entropy, edge.target);
}

/// Privileged transaction composition for a target allocated in the same batch.
/// This stores a recipe; it does not create or publish any Host capability.
pub fn stageTarget(store: *core.Store, entropy: Entropy, target: core.ObjectId) !core.ObjectId {
    const id = try store.allocateId();
    try store.putCopying(.{ .id = id, .revision = 0, .schema = schema.id, .rooted = true, .payload = &entropy, .edges = &.{.{ .target = target }} }, null);
    return id;
}

/// Restore the descriptor through the existing Host publication registry.
/// No behavior is loaded and no application initialization is replayed.
pub fn restore(attachment: *h.Attachment, lease: core.Lease) !driver.Host.DurableSwiss {
    try attachment.topLevel();
    const view = try attachment.store.currentView(lease);
    const target = try activeTarget(view);
    const ref = try h.restoreEdge(attachment, target);
    defer attachment.host.releaseCapability(ref, 1) catch unreachable;
    return attachment.host.publishDurableCapability(view.payload[0..@sizeOf(Entropy)].*, ref);
}

/// Checked target of an active durable publication recipe. This is storage
/// metadata for trusted composition, not authority to call the target.
pub fn activeTarget(view: core.RecordView) !core.ObjectId {
    try validate(view);
    if (!view.rooted) return error.RetiredPublication;
    if (view.edge_count != 1) return error.InvalidPublication;
    var edges = view.edges();
    const edge = edges.next().?;
    if (edge.strength != .strong) return error.InvalidPublication;
    return edge.target;
}

/// Stage discovery retirement, preserving a tombstone of the secret name.
/// Commit this transaction through the attachment's write lane: its terminal
/// outcome applies the registry transition (see `fenceRetirements`), so no
/// application coordination between commit and registry removal is required.
/// Staging reserves bounded retirement custody; it refuses while another
/// tombstone for this record is already pending or custody is exhausted.
pub fn stageRetirement(attachment: *h.Attachment, lease: core.Lease) !void {
    const view = try attachment.store.currentView(lease);
    try validate(view);
    if (!view.rooted) return error.RetiredPublication;
    try reserve(attachment, view.id, driver.Host.DurableSwiss.fromEntropy(view.payload[0..@sizeOf(Entropy)].*));
    try attachment.store.putCopying(.{ .id = view.id, .revision = 0, .schema = schema.id, .rooted = false, .payload = view.payload }, view.revision);
}

/// Reserved custody for one staged tombstone. Bounded by the attachment's
/// `max_retirements`; a duplicate record refuses rather than double-fencing.
fn reserve(attachment: *h.Attachment, record: core.ObjectId, swiss: driver.Host.DurableSwiss) !void {
    for (attachment.retirements) |slot| if (slot) |held| if (held.record.eql(record)) return error.RetirementPending;
    for (attachment.retirements) |*slot| if (slot.* == null) {
        slot.* = .{ .record = record, .swiss = swiss, .registered = attachment.host.giftables.contains(swiss.slice()) };
        return;
    };
    return error.RetirementCapacity;
}

fn tombstone(batch_change: core.Mutation, owner: *h.Attachment) ?struct { record: core.ObjectId, swiss: driver.Host.DurableSwiss } {
    const bytes = batch_change.bytes orelse return null;
    const view = core.RecordView.decode(bytes, owner.store.limits.records, owner.store.cache.schemas) catch return null;
    if (view.schema != schema.id or view.schema_version != schema.version) return null;
    if (view.rooted or view.payload.len != @sizeOf(Entropy)) return null;
    return .{ .record = batch_change.id, .swiss = driver.Host.DurableSwiss.fromEntropy(view.payload[0..@sizeOf(Entropy)].*) };
}

fn removeFromRegistry(owner: *h.Attachment, swiss: driver.Host.DurableSwiss) !void {
    owner.host.removeDurable(swiss.slice()) catch |err| switch (err) {
        error.UnknownPublication => {},
        else => return err,
    };
}

/// The commit-to-registry fence for one terminal batch. Every tombstoned
/// publication record in the batch loses discovery now — including unknown
/// outcomes, which fail closed — and keeps its reserved custody until the
/// outcome resolves. Stale custody from abandoned staging clears here.
pub fn fenceRetirements(owner: *h.Attachment, batch: core.Batch) !void {
    for (batch.changes) |change| {
        const dead = tombstone(change, owner) orelse continue;
        try removeFromRegistry(owner, dead.swiss);
        for (owner.retirements) |*slot| {
            if (slot.*) |held| {
                if (held.record.eql(dead.record)) {
                    slot.*.?.fenced = true;
                    break;
                }
            }
        }
    }
}

/// Drop one record's staged retirement custody after the caller abandoned
/// its transaction. Fenced custody (an outcome already applied the fence)
/// refuses: recovery owns it.
pub fn dropRetirement(owner: *h.Attachment, record: core.ObjectId) !void {
    for (owner.retirements) |*slot| if (slot.*) |held| {
        if (!held.record.eql(record)) continue;
        if (held.fenced) return error.RetirementFenced;
        slot.* = null;
        return;
    };
    return error.UnknownRetirement;
}

/// Drop custody. `keep_fenced` preserves fenced slots across an unresolved
/// unknown outcome. Deferred restoration survives every later transaction.
pub fn releaseRetirements(owner: *h.Attachment, keep_fenced: bool) void {
    for (owner.retirements) |*slot| {
        const held = slot.* orelse continue;
        if (held.republish or (keep_fenced and held.fenced)) continue;
        slot.* = null;
    }
}

/// Record the known-absent outcome without performing fallible restoration.
/// Existing bounded retirement slots own retry custody until the name is back
/// in Host or a later committed retirement makes restoration unnecessary.
pub fn deferRepublish(owner: *h.Attachment) void {
    releaseRetirements(owner, true);
    for (owner.retirements) |*slot| if (slot.*) |*held| if (held.fenced and !held.republish) {
        if (held.registered) held.republish = true else slot.* = null;
    };
}

/// Retry through the ordinary top-level advance and read lane. A refusal
/// leaves the slot intact; successful reads only install cache residency, so
/// neither write recovery nor read completion has to perform Host allocation.
pub fn advanceRepublish(owner: *h.Attachment) !bool {
    if (owner.store.phase != .idle) return false;
    var progressed = false;
    for (owner.retirements) |*slot| if (slot.*) |held| if (held.republish) {
        const acquired = owner.store.acquire(held.record) catch |err| switch (err) {
            error.PendingRead => continue,
            else => return err,
        };
        switch (acquired) {
            .ready => |lease| {
                defer owner.store.release(lease) catch unreachable;
                _ = restore(owner, lease) catch |err| switch (err) {
                    error.RetiredPublication => {
                        slot.* = null;
                        progressed = true;
                        continue;
                    },
                    else => return err,
                };
                slot.* = null;
                progressed = true;
            },
            .read => |read| {
                @import("storage.zig").retainRead(owner, read, null);
                progressed = true;
            },
        }
    };
    return progressed;
}

/// Collection can retire a recipe while its restoration read is in flight.
/// Such a miss terminates only that recipe's deferred registry custody.
pub fn forgetMissingRepublish(owner: *h.Attachment, record: core.ObjectId) bool {
    for (owner.retirements) |*slot| if (slot.*) |held| {
        if (!held.republish or !held.record.eql(record)) continue;
        slot.* = null;
        return true;
    };
    return false;
}

fn validate(view: core.RecordView) !void {
    if (view.schema != schema.id or view.schema_version != schema.version or view.payload.len != @sizeOf(Entropy)) return error.InvalidPublication;
}
