//! Canonical Host custody copied from a raw Node route. Existing identities
//! acquire an application retain. A fresh one pins its home import locally.
const std = @import("std");
const model = @import("model");
const engine = @import("engine");
const host_mod = @import("../../host.zig");
const capability = @import("../../capability.zig");

pub fn retain(host: *host_mod.Host, source: engine.PeerHandle, route: model.CapabilityRouteId) !capability.Ref {
    const routed = host.node.routeReference(source, .{ .routed = .{ .id = route, .kind = .object } }) orelse return error.UnknownCapability;
    const home = host.sessionForPeer(routed.peer_handle) orelse return error.UnknownCapability;
    const far = if (routed.target == .far) routed.target.far else return error.UnknownCapability;
    if (home.served.port.peer.session_state.hostImportIdentity(far.import_position)) |identity| {
        const ref = host.capabilities.refForRaw(identity.ref) orelse return error.UnknownCapability;
        const target = host.capabilities.resolve(ref) orelse return error.UnknownCapability;
        if (target != .remote or target.remote.peer_handle != routed.peer_handle or !std.meta.eql(target.remote.far, far))
            return error.UnknownCapability;
        return host.capabilities.retain(host.allocator, target);
    }
    const incarnation = host.next_import_incarnation;
    if (incarnation == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    const ref = try host.capabilities.retain(host.allocator, .{ .remote = .{
        .peer_handle = routed.peer_handle,
        .far = far,
        .incarnation = incarnation,
    } });
    errdefer _ = host.capabilities.release(ref, 1) catch unreachable;
    try home.served.port.peer.session_state.noteHostCapabilityHold(far.import_position, ref.raw());
    host.next_import_incarnation += 1;
    return ref;
}
