//! Activation projects shared lifetime startup onto the ordinary work lane.
const common = @import("common.zig");
const attached = @import("attachment.zig");
const c = common.c;

/// Reserve bounded live custody and start a fresh or advanced restart marker.
/// Advance and execute ordinary attachment work until live_marker succeeds.
/// A null prior creates a marker. A prior name selects trusted startup metadata.
pub fn glowcap_loam_live_start(raw: ?*c.GlowcapLoamAttachment, prior: ?*const c.GlowcapLoamObject, capacity: u32) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const owner = attached.attachment(raw) catch |err| return common.code(err);
    owner.value.topLevel() catch |err| return common.code(err);
    if (owner.live_scope != null) return common.code(error.LiveScopeAlreadyStarted);
    const id = if (prior) |object| common.object(object.*) catch |err| return common.code(err) else null;
    const allocator = owner.store.allocator;
    const scope = allocator.create(common.hosting.LiveScope) catch |err| return common.code(err);
    scope.* = common.hosting.LiveScope.init(allocator, owner.host_borrow.core(), &owner.store.value, capacity) catch |err| {
        allocator.destroy(scope);
        return common.code(err);
    };
    scope.startHosted(owner.value, id) catch |err| {
        scope.deinit() catch unreachable;
        allocator.destroy(scope);
        return common.code(err);
    };
    owner.live_scope = scope;
    return common.shared.GLOWCAP_OK;
}

/// Return the confirmed lifetime marker as descriptive startup metadata.
/// WouldBlock keeps output zero while storage work or exact recovery is pending.
/// Marker bytes carry no capability and cannot restore a live field after restart.
pub fn glowcap_loam_live_marker(raw: ?*c.GlowcapLoamAttachment, out_marker: ?*c.GlowcapLoamObject) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const output = out_marker orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    output.* = .{ .key = @splat(0) };
    const epoch = confirmedEpoch(raw) catch |err| return common.code(err);
    output.* = common.objectToC(epoch.object);
    return common.shared.GLOWCAP_OK;
}

/// The confirmed generation advances on every restart of this marker row.
/// It is descriptive lifetime metadata. Pending and failed startup zero output.
pub fn glowcap_loam_live_generation(raw: ?*c.GlowcapLoamAttachment, out_generation: ?*u64) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const output = out_generation orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    output.* = 0;
    const epoch = confirmedEpoch(raw) catch |err| return common.code(err);
    output.* = epoch.generation;
    return common.shared.GLOWCAP_OK;
}

/// The confirmed epoch once startup has one. `StartupPending` (would block)
/// while storage work or exact recovery still runs, the startup's own failure
/// when it failed.
fn confirmedEpoch(raw: ?*c.GlowcapLoamAttachment) !common.hosting.LiveEpoch {
    const owner = try attached.attachment(raw);
    try owner.value.topLevel();
    const scope = owner.live_scope orelse return error.LiveScopeNotStarted;
    return switch (scope.result()) {
        .pending => error.StartupPending,
        .failed => |err| err,
        .ready => |epoch| epoch,
    };
}
