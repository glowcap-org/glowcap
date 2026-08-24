//! Per-session projections of one Host-owned capability promise.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");

const capability = @import("../capability.zig");
const host_mod = @import("../host.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

pub const Prepared = struct {
    reference: model.Reference,
    created: bool,
};

/// Project a still-pending Host promise onto one session. The session owns the
/// paired export/answer rows once a surrounding send commits; `created` gives
/// that transaction exact rollback authority until then.
pub fn prepare(self: *Host, id: capability.PromiseId, session: *HostSession) !Prepared {
    const row = self.capability_promises.getPtr(id) orelse return error.UnknownCapability;
    if (row.state != .pending and row.state != .settling) return error.PromiseNotPending;
    for (row.projections.items) |projection| {
        if (projection.peer_handle == session.peer_handle) return .{
            .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) },
            .created = false,
        };
    }
    try row.projections.ensureUnusedCapacity(self.allocator, 1);
    const projection = try session.served.port.peer.session_state.allocateLocalPromiseProjection();
    row.projections.appendAssumeCapacity(.{
        .peer_handle = session.peer_handle,
        .export_position = projection.export_position,
        .answer_target = projection.answer_target,
    });
    return .{
        .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) },
        .created = true,
    };
}

pub fn rollback(
    self: *Host,
    id: capability.PromiseId,
    session: *HostSession,
    export_position: model.ExportPosition,
) void {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    for (row.projections.items, 0..) |projection, index| {
        if (projection.peer_handle != session.peer_handle or projection.export_position != export_position) continue;
        const removed = row.projections.swapRemove(index);
        std.debug.assert(removed.peer_handle == session.peer_handle and removed.export_position == export_position);
        session.served.port.peer.session_state.abandonLocalPromiseProjection(export_position);
        return;
    }
    unreachable;
}

/// Forget projections whose session is being destroyed. The session owns and
/// frees its export/answer rows; this removes only the Host's route to them.
pub fn forgetSession(self: *Host, peer_handle: engine.PeerHandle) void {
    var rows = self.capability_promises.valueIterator();
    while (rows.next()) |row| {
        var index: usize = 0;
        while (index < row.projections.items.len) {
            if (row.projections.items[index].peer_handle == peer_handle) {
                const removed = row.projections.swapRemove(index);
                std.debug.assert(removed.peer_handle == peer_handle);
            } else index += 1;
        }
    }
}
