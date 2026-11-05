//! Private forwarding actors for projected answer roots. The Port roots the
//! actor, its state retains the destination, and the answer retires the binding.
const std = @import("std");
const engine = @import("engine");
const model = @import("model");
const host_mod = @import("../host.zig");
const hosting = @import("hosting.zig");
const args_mod = @import("args.zig");
const capability = @import("../capability.zig");
const values = @import("../value.zig");

const Forwarder = struct {
    host: *host_mod.Host,
    target: capability.Ref,

    pub fn handle(self: *Forwarder, turn: *hosting.HostTurn, verb: ?[]const u8, args: args_mod.Args) !values.Value {
        defer turn.releaseArguments(args);
        return turn.forward(self.target, verb, try args.values());
    }

    pub fn deinit(self: *Forwarder, _: std.mem.Allocator) void {
        self.host.releaseCapabilityTerminal(self.target, null);
    }
};

pub fn prepare(ctx: ?*anyopaque, peer: engine.PeerHandle, route: model.CapabilityRouteId, raw: ?u64) engine.node_services.OutboundStagingError!engine.Node.PipelineProjection.Result {
    const host: *host_mod.Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessionForPeer(peer) orelse return error.PeerGone;
    // A lowering lease already has canonical custody. Raw Actors roots use
    // the same canonical identity through a real home-owned local import pin.
    const retained = (if (raw) |id| retainCanonical(host, id) else @import("capabilities/route_hold.zig").retain(host, peer, route)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RouteNotLowerable,
    };
    // Vat.spawn adopts initial state even when it refuses.
    const actor = host.vat.spawn(hosting.Hosting(Forwarder), .{ .inner = .{ .host = host, .target = retained } }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RouteNotLowerable,
    };
    errdefer host.vat.discardFreshActor(actor);
    const projected = session.served.port.prepareProjection(&host.vat, actor) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RouteNotLowerable,
    };
    // The Port binding takes the only root; the constructor transfers its
    // spawn root so retirement can reclaim the actor and destination retain.
    host.vat.releaseActor(actor.local);
    return .{ .near = projected.near, .target = actor.local };
}

fn retainCanonical(host: *host_mod.Host, raw: u64) !capability.Ref {
    const ref = host.capabilities.refForRaw(raw) orelse return error.UnknownCapability;
    const destination = host.capabilities.resolve(ref) orelse return error.UnknownCapability;
    return host.capabilities.retain(host.allocator, destination);
}
