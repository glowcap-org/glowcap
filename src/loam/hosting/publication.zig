//! Durable publication descriptors. Applications retain their bootstrap record
//! name; the stored descriptor retains the secret name and exact actor target.
const core = @import("loam_core");
const h = @import("attachment.zig");
const driver = @import("driver_core");

pub const Entropy = driver.Host.DurableSwiss.Entropy;
pub const schema: core.Schema = .{ .id = 0x4c4f414d50554201, .version = 1, .max_payload = @sizeOf(Entropy), .max_edges = 1 };

/// Add a publication to the caller's current transaction. It becomes usable
/// only after commit, through a checked lease and restore below. Entropy comes
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
/// Commit this transaction and applyRetirement before admitting another fetch.
/// An unknown outcome must be resolved before changing the Host registry.
pub fn stageRetirement(attachment: *h.Attachment, lease: core.Lease) !void {
    const view = try attachment.store.currentView(lease);
    try validate(view);
    if (!view.rooted) return error.RetiredPublication;
    try attachment.store.putCopying(.{ .id = view.id, .revision = 0, .schema = schema.id, .rooted = false, .payload = view.payload }, view.revision);
}

/// Apply a committed tombstone, including after restart. Held capabilities
/// remain valid; only subsequent discovery through this name is removed.
pub fn applyRetirement(attachment: *h.Attachment, lease: core.Lease) !void {
    try attachment.topLevel();
    const view = try attachment.store.currentView(lease);
    try validate(view);
    if (view.rooted or view.edge_count != 0) return error.InvalidPublication;
    const swiss = driver.Host.DurableSwiss.fromEntropy(view.payload[0..@sizeOf(Entropy)].*);
    attachment.host.removeDurable(swiss.slice()) catch |err| switch (err) {
        error.UnknownPublication => {},
        else => return err,
    };
}

fn validate(view: core.RecordView) !void {
    if (view.schema != schema.id or view.schema_version != schema.version or view.payload.len != @sizeOf(Entropy)) return error.InvalidPublication;
}
