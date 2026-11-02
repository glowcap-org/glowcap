//! The C behavior bridge: the foreign callback bound to one hosted object, the
//! allocation that hands the actor descriptor to a Vat or Host publication, and
//! the callback-context transfer preflight. Declares no `export fn`.

const std = @import("std");

const actors = @import("actors");
const driver_core = @import("driver_core");
const model = @import("model");
const shared = @import("c_abi_shared");

const c = @import("mod.zig");
const host_error = @import("error.zig");
const instance = @import("instance.zig");
const marshal = @import("marshal.zig");

/// Preflight a foreign callback-context transfer before the C bridge takes
/// ownership. The Host remains the admission authority. This early call only
/// preserves the ABI promise that a reentry refusal leaves `ctx` caller-owned.
pub fn preflightHostedTransfer(inst: *instance.Instance) ?i32 {
    inst.core.refuseReentry() catch |err| return host_error.errToCode(err);
    return null;
}

/// The C behavior bound to one hosted object. Allocated on the host's
/// allocator and freed by its own `freeThunk` when the actor's box drops
/// (Host release, or a failed construction after ownership transfers).
pub const HostedBehavior = struct {
    behavior: c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
    allocator: std.mem.Allocator,

    /// The vat calls this on each deliver. It marshals the message into C,
    /// invokes the consumer's callback with the turn, and materializes its
    /// reply into `turn.arena`. The consumer lends its reply storage across
    /// callback return; the copied reply then borrows the whole turn.
    pub fn handle(erased: *anyopaque, turn: *actors.Turn, msg: actors.Delivery) actors.HostedActor.Result {
        return actors.HostedActor.Result.fromResult(handleOwned(erased, turn, msg));
    }

    fn handleOwned(erased: *anyopaque, turn: *actors.Turn, msg: actors.Delivery) anyerror!model.Argument {
        const self: *HostedBehavior = @ptrCast(@alignCast(erased));
        const arena = turn.arena;
        var host_turn = try driver_core.HostTurn.fromActorTurn(turn);
        const session = host_turn.session orelse return error.OwningReplyRequired;
        const inst = instance.instOf(host_turn.host);
        const input = try inst.core.projectValues(session, arena, msg.args, &host_turn, projectCallbackArguments);
        errdefer if (input.lease) |held| held.release();
        const c_args = input.args;
        var reply = shared.zero_argument;
        const code = self.behavior(
            self.ctx,
            @ptrCast(turn),
            if (msg.verb) |method| method.ptr else null,
            if (msg.verb) |method| method.len else 0,
            if (c_args.len > 0) c_args.ptr else null,
            c_args.len,
            &reply,
        );
        if (code != shared.GLOWCAP_OK) return error.ForeignBehaviorBroke;
        return try marshal.hostArgumentFromCOwned(inst, session, arena, reply, 0);
    }

    /// The same foreign callback receives owning values on a trusted local
    /// turn. It has no session, and its reply is copied directly into the
    /// bounded owning result before the actor's frame can retire.
    pub fn handleOpaque(erased: *anyopaque, turn: *actors.Turn, msg: actors.OpaqueMessage) ?[]const u8 {
        handleOpaqueOwned(erased, turn, msg) catch |err| return @errorName(err);
        return null;
    }

    fn handleOpaqueOwned(erased: *anyopaque, turn: *actors.Turn, _: actors.OpaqueMessage) anyerror!void {
        const self: *HostedBehavior = @ptrCast(@alignCast(erased));
        var host_turn = try driver_core.HostTurn.fromActorTurn(turn);
        try host_turn.beginLocal();
        const inst = instance.instOf(host_turn.host);
        const input = try host_turn.localArguments();
        const input_values = try input.args.values();
        const c_args = marshal.valuesToC(turn.arena, input_values) catch |err| {
            // Observation custody transfers at callback entry. Projection
            // refusal must retract it independently of the queue keepers.
            host_turn.releaseValues(input_values);
            return err;
        };
        var reply = shared.zero_argument;
        const code = self.behavior(self.ctx, @ptrCast(turn), if (input.verb) |method| method.ptr else null, if (input.verb) |method| method.len else 0, if (c_args.len == 0) null else c_args.ptr, c_args.len, &reply);
        if (code != shared.GLOWCAP_OK) return error.ForeignBehaviorBroke;
        if (turn.forwarded) return;
        const replies = [_]shared.GlowcapArgument{reply};
        const values = try shared.valuesFromCWith(driver_core.Value, anyerror, inst, marshal.decodeHostCapability, turn.arena, &replies, 1, 0, false);
        try host_turn.prepareLocalReply(values[0]);
    }

    /// The actor's box `free`: run the consumer's `free` on the foreign `ctx`,
    /// then free the bridge itself. Runs exactly once when the Host Vat drops
    /// the actor.
    pub fn freeThunk(erased: *anyopaque) void {
        const self: *HostedBehavior = @ptrCast(@alignCast(erased));
        if (self.free) |f| f(self.ctx);
        self.allocator.destroy(self);
    }
};

const CallbackArguments = struct {
    args: []shared.GlowcapArgument,
    lease: ?*driver_core.HostTurn.ArgumentLease,
};

/// Marshal and acquire reply custody inside the lift transaction, before any
/// observation reaches foreign code or a redeemed route is consumed.
fn projectCallbackArguments(turn: *driver_core.HostTurn, values: []const driver_core.Value) !CallbackArguments {
    const args = try marshal.valuesToC(turn.turn.arena, values);
    const lease = try turn.retainArguments(.fromValues(values, turn.turn.arena));
    return .{ .args = args, .lease = lease };
}

/// Allocate the C callback bridge and return the actor descriptor a Vat or
/// Host publication consumes. On allocation failure this owns the foreign
/// `ctx` contract and invokes `free`. After return, `HostedActor.free` does.
pub fn hostedBridge(
    alloc: std.mem.Allocator,
    behavior: c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
) !actors.HostedActor {
    const bridge = alloc.create(HostedBehavior) catch |e| {
        if (free) |f| f(ctx);
        return e;
    };
    bridge.* = .{ .behavior = behavior, .ctx = ctx, .free = free, .allocator = alloc };
    return .{ .ctx = bridge, .handle = HostedBehavior.handle, .handleOpaque = HostedBehavior.handleOpaque, .free = HostedBehavior.freeThunk };
}
