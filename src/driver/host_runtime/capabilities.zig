//! Host-wide publication and select-or-dial capability enlivenment.

const model = @import("model");
const driver_core = @import("driver_core");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;

/// Spawn `initial` once in the Host Vat and bind `name` as a Host-wide alias.
/// Fetching the name lazily projects that actor onto the requesting Port;
/// exact gifts retain the actor target and do not consult this name again.
pub fn publish(
    self: *HostRuntime,
    name: []const u8,
    comptime Behavior: type,
    initial: Behavior,
) !void {
    self.enterDriver();
    defer self.leaveDriver();
    _ = try self.core.publish(name, driver_core.Hosting(Behavior), .{ .inner = initial });
}

/// Remove a host-wide alias without affecting already-issued capabilities.
pub fn unpublish(self: *HostRuntime, name: []const u8) !void {
    self.enterDriver();
    defer self.leaveDriver();
    return self.core.unpublish(name);
}

/// Resolve the sturdyref's peer to its live session or dial it, then enliven
/// under the same complete-peer check every enliven path shares.
pub fn enliven(self: *HostRuntime, sturdy: model.SturdyRef) !driver_core.Capability {
    self.enterDriver();
    defer self.leaveDriver();
    const hs = self.core.dialedSessionFor(sturdy.peer.transport, sturdy.peer.designator) orelse
        try self.connectLocator(sturdy.peer, .inherit);
    const operation = try self.core.enlivenCapability(self.allocator, sturdy);
    defer operation.deinit();
    var probe = EnlivenProbe{ .runtime = self, .session = hs, .operation = operation };
    try runtime.Internal.pumpUntilProbe(self, &probe, self.opts.settle);
    return switch (operation.result()) {
        .ready => try operation.take(),
        .failed => |failed| switch (failed.kind) {
            .broken => driver_core.Error.FetchBroken,
            .closed => driver_core.Error.ConnectionClosed,
        },
        .pending => unreachable,
    };
}

const EnlivenProbe = struct {
    runtime: *HostRuntime,
    session: *driver_core.HostSession,
    operation: *driver_core.Host.Enliven,

    pub fn done(self: *EnlivenProbe) bool {
        if (self.operation.result() == .pending) return false;
        const wire = self.runtime.wires.get(self.session.peer_handle) orelse return true;
        return wire.closed or wire.link.pending == null;
    }

    pub fn resumeSkip(_: *EnlivenProbe) ?*driver_core.HostSession {
        return null;
    }
};
