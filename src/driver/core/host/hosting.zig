//! Value-shaped hosted behavior adaptation for the Host.
//!
//! This owner is the one boundary between an actor turn's wire-shaped values
//! and application-facing opaque Host capabilities. It owns no actor, session,
//! capability registry, or traversal state of its own.

const std = @import("std");

const model = @import("model");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const served_mod = @import("../served.zig");
const capability = @import("../capability.zig");
const value_mod = @import("../value.zig");
const capability_routing = @import("capabilities/routing.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Served = served_mod.Served;

/// One delivery into a Value-shaped hosted behavior (see `Hosting`): the
/// behavior's window onto the Host. It carries the composed Host, the
/// ingress session, and the underlying actor turn, so a handler can mint new
/// opaque capabilities without touching wire positions.
pub const HostTurn = struct {
    host: *Host,
    session: ?*HostSession,
    turn: *actors.Turn,

    /// Recover the same owning context for wire and trusted local deliveries.
    pub fn fromActorTurn(turn: *actors.Turn) !HostTurn {
        if (turn.port) |port| {
            const served: *Served = @fieldParentPtr("port", port);
            const session: *HostSession = @alignCast(@fieldParentPtr("served", served));
            return .{ .host = session.host, .session = session, .turn = turn };
        }
        const producer = try @import("local_delivery.zig").producer(turn);
        return .{ .host = producer.host, .session = null, .turn = turn };
    }

    pub fn beginLocal(self: *HostTurn) !void {
        try (try @import("local_delivery.zig").producer(self.turn)).enroll(self.turn);
    }

    /// Transfer a child lease from this already-admitted local delivery. The
    /// payload vtable and owning Vat prove its actual producer, not a handle.
    pub fn retainPendingWork(self: *HostTurn) !Host.PendingWorkLease {
        const source = try @import("local_delivery.zig").producer(self.turn);
        if (source.host != self.host) return error.ForeignTurn;
        const lease = if (source.lease) |*lease| lease else return error.NoPendingWork;
        return lease.fork();
    }

    pub fn localArguments(self: *HostTurn) !struct { verb: []const u8, args: []const value_mod.Value } {
        const args = try @import("local_delivery.zig").arguments(self.turn);
        return .{ .verb = args.verb, .args = args.args };
    }

    pub fn prepareLocalReply(self: *HostTurn, reply: value_mod.Value) !void {
        if (!self.turn.forwarded) try (try @import("local_delivery.zig").producer(self.turn)).prepare(reply);
    }

    /// Spawn a fresh local actor mid-turn and return its opaque capability.
    /// This is the owning-tier twin of `spawnAt`. The spawned behavior is
    /// Value-shaped like every owning-tier behavior.
    pub fn spawn(self: *HostTurn, comptime Behavior: type, initial: Behavior) !capability.Ref {
        const reservation = try self.host.reserveFreshCapability(self.session);
        const ref = try self.turn.vat.spawn(Hosting(Behavior), .{ .inner = initial });
        errdefer self.turn.vat.discardFreshActor(ref);
        return self.host.adoptReservedLocalCapability(reservation, ref);
    }

    /// Foreign-callback twin of `spawn`. This turn was admitted before any
    /// finish barrier, so it may mint its reply capability while that admitted
    /// work drains.
    pub fn spawnHosted(self: *HostTurn, hosted: actors.HostedActor) !capability.Ref {
        var hosted_pending = true;
        defer if (hosted_pending) if (hosted.free) |free| free(hosted.ctx);

        const reservation = try self.host.reserveFreshCapability(self.session);
        hosted_pending = false;
        const ref = try self.turn.vat.spawnHosted(hosted);
        errdefer self.turn.vat.discardFreshActor(ref);
        return self.host.adoptReservedLocalCapability(reservation, ref);
    }

    /// Defer this turn's answer and return the one-shot authority that settles
    /// it later from the Host's owning thread.
    pub fn deferAnswer(self: *HostTurn) !u64 {
        return self.host.deferTurn(self.session, self.turn);
    }

    /// Consume the application retains acquired while lifting incoming values.
    /// Call after storing/transferring any references the behavior keeps.
    pub fn releaseValues(self: *HostTurn, values: []const value_mod.Value) void {
        @import("capabilities/lower.zig").releaseValueCapabilitiesTerminalAt(self.host, values, null);
    }

    /// Transfer this answer to another capability. Local invocation uses the
    /// target's actual home and keeps its original owned reply destination.
    /// Wire invocation stays on its causal session. The returned placeholder is
    /// ignored while the forwarded completion owns the answer.
    pub fn forward(
        self: *HostTurn,
        target: capability.Ref,
        verb: []const u8,
        values: []const value_mod.Value,
    ) !value_mod.Value {
        const session = self.session orelse {
            try @import("local_delivery.zig").forward(self.turn, target, verb, values);
            return .{ .void = {} };
        };
        const routed = try self.host.routeTurnCapability(session, target, &.{});
        var prepared = try self.host.prepareValues(session, self.turn.arena, values);
        defer prepared.deinit();
        try capability_routing.validateRoutedArguments(self.host, session, prepared.values);
        const reply = try self.turn.forward(routed, .{ .verb = verb, .args = prepared.values });
        _ = prepared.commit();
        return self.host.liftValue(session, self.turn.arena, reply);
    }

    /// Eventual-send from this callback through the same Host authority as an
    /// owning Session. The returned id is observed with the Host vow surface.
    pub fn send(self: *HostTurn, target: capability.Ref, verb: []const u8, values: []const value_mod.Value) !u64 {
        const session = self.session orelse return @import("local_delivery.zig").send(self.turn, target, verb, values);
        return self.host.sendValues(session, target, verb, values, self.turn.arena);
    }

    /// Fire-and-forget delivery from this callback.
    pub fn tell(self: *HostTurn, target: capability.Ref, verb: []const u8, values: []const value_mod.Value) !void {
        const session = self.session orelse return @import("local_delivery.zig").tell(self.turn, target, verb, values);
        return self.host.tellValues(session, target, verb, values, self.turn.arena);
    }
};

/// Adapt a Value-shaped behavior to the actor layer's wire-shaped contract. It
/// is the Zig counterpart of the C ABI's hosted-behavior trampoline. `B`
/// declares
///
/// ```zig
/// pub fn handle(self: *B, ht: *HostTurn, verb: []const u8, args: []const Value) !Value
/// ```
///
/// Inbound wire arguments are lifted through the ingress session (so a
/// delivered capability arrives as one canonical opaque identity), and the
/// returned reply is lowered through the same session's Port. Both walks use
/// the turn arena, whose lifetime is the borrowed reply's contract. The owning
/// `Session.spawn` / `Session.publish` and Host-wide `publish` wrap every
/// behavior in this adapter. The base Vat and the serve core keep the
/// wire-shaped contract.
pub fn Hosting(comptime B: type) type {
    return struct {
        inner: B,

        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            const port = turn.port orelse {
                if (@hasDecl(B, "handleLocal")) return self.inner.handleLocal(turn, msg);
                return actors.Error.NotConnected;
            };
            const served: *Served = @fieldParentPtr("port", port);
            const session: *HostSession = @alignCast(@fieldParentPtr("served", served));
            const host = session.host;
            const values = try host.liftValues(session, turn.arena, msg.args);
            var host_turn = HostTurn{ .host = host, .session = session, .turn = turn };
            const reply = try self.inner.handle(&host_turn, msg.verb, values);
            return host.lowerValue(session, turn.arena, reply);
        }

        pub fn handleOpaque(self: *@This(), turn: *actors.Turn, _: actors.OpaqueMessage) !void {
            var host_turn = try HostTurn.fromActorTurn(turn);
            try host_turn.beginLocal();
            const input = try host_turn.localArguments();
            const reply = try self.inner.handle(&host_turn, input.verb, input.args);
            try host_turn.prepareLocalReply(reply);
        }

        /// Forward the wrapped behavior's state teardown, so a reclaimed or
        /// torn-down actor releases what its state owns. Like the C hosted
        /// bridge, the adapter itself declares no `clone`, so a Vat holding a
        /// Value-shaped actor is not snapshottable.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (@hasDecl(B, "deinit")) self.inner.deinit(allocator);
        }
    };
}
