//! Host-wide publication and select-or-dial capability enlivenment.

const std = @import("std");

const model = @import("model");
const driver_core = @import("driver_core");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;

/// Spawn `initial` once in the Host Vat and bind `name` as a Host-wide alias.
/// Fetching the name lazily projects that actor onto the requesting Port;
/// exact gifts retain the actor target and do not consult this name again.
pub fn publishGiftable(
    self: *HostRuntime,
    name: []const u8,
    comptime Behavior: type,
    initial: Behavior,
) !void {
    self.enterDriver();
    defer self.leaveDriver();
    _ = try self.core.publishGiftable(name, driver_core.Hosting(Behavior), .{ .inner = initial });
}

/// Remove a host-wide alias without affecting already-issued capabilities.
pub fn unpublish(self: *HostRuntime, name: []const u8) !void {
    self.enterDriver();
    defer self.leaveDriver();
    return self.core.unpublish(name);
}

/// Adopt the one completion an enliven wait parked before a listener existed.
pub fn claimCompletion(self: *HostRuntime, action: driver_core.HostAction) bool {
    if (!wouldClaimCompletion(self, action)) return false;
    self.claimed_completion = action;
    return true;
}

pub fn wouldClaimCompletion(self: *const HostRuntime, action: driver_core.HostAction) bool {
    const wanted = self.awaited_completion orelse return false;
    const vow_id = switch (action) {
        .settled => |settled| settled.vow_id,
        .failed => |failed| failed.vow_id,
        else => return false,
    };
    return vow_id == wanted and self.claimed_completion == null;
}

/// Resolve the sturdyref's peer to its live session or dial it, then enliven
/// under the same complete-peer check every enliven path shares.
pub fn enliven(self: *HostRuntime, sturdy: model.SturdyRef) !driver_core.Capability {
    self.enterDriver();
    defer self.leaveDriver();
    const hs = self.core.dialedSessionFor(sturdy.peer.transport, sturdy.peer.designator) orelse
        try self.connectLocator(sturdy.peer, .inherit);
    const vow_id = try self.core.enliven(hs, sturdy);
    var capture = driver_core.FetchCapture{};
    var flag = driver_core.SettleFlag{ .inner = .{ .ctx = &capture, .func = driver_core.FetchCapture.record } };
    self.core.vowOn(vow_id, .{ .ctx = &flag, .func = driver_core.SettleFlag.fire }) catch |err| switch (err) {
        // A session-cache hit settled inside the verb, before any listener
        // existed. Claim its parked action from the ordinary drain.
        error.NoSuchVow => {
            self.awaited_completion = vow_id;
            defer self.awaited_completion = null;
            try self.drainActions();
            const action = self.claimed_completion orelse return driver_core.Error.ConnectionClosed;
            self.claimed_completion = null;
            defer self.core.freeAction(action);
            const Projection = struct {
                fn identity(_: void, value: driver_core.Value) anyerror!driver_core.Value {
                    return value;
                }
            };
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            return switch (self.core.projectCompletion(action, arena.allocator(), {}, Projection.identity)) {
                .settled => |settled| switch (settled.value) {
                    .capability => |capability| capability,
                    else => driver_core.Error.FetchNotACapability,
                },
                .failed => |failed| switch (failed.failure) {
                    .broken => driver_core.Error.FetchBroken,
                    .closed => driver_core.Error.ConnectionClosed,
                },
            };
        },
        else => return err,
    };
    self.pumpUntilFlag(hs, &flag.done, self.opts.settle) catch |err| {
        hs.served.port.breakFarVows(hs.served.closeReason("wait failed"));
        return err;
    };
    return switch (capture.outcome orelse return driver_core.Error.ConnectionClosed) {
        .capability => |captured| self.core.liftCapability(hs, captured.reference()),
        .broken => driver_core.Error.FetchBroken,
        .not_a_capability => driver_core.Error.FetchNotACapability,
    };
}
