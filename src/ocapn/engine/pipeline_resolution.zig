//! The pure half of the resolve seam (ADR-0003, ADR-0004): the math of what
//! falls out of a settled answer, with no `Peer` in sight.
//!
//! When a promise resolves, a few new messages fall out of it: the retargeted
//! version of a pipelined call that was waiting on it, the `op:deliver` that
//! fires a listener, and the projection of an `op:get` over the settled value.
//! The functions here compute exactly those. Keeping them pure is what makes the
//! whole matrix of cases testable without standing up a live session: resolution
//! shape, path shape, and the listener mode. The stateful
//! drain that applies these decisions lives in `pipeline.zig`, which re-exports
//! this module's surface.
//!
//! On ownership: anything here that produces an owned message takes ownership of
//! what you pass in, like the queued call, and moves its heap into the result.
//! It moves, it doesn't copy. The listener-fire math never owns anything: a
//! drain decision is POD (`ListenerDrainAction`), and the fire deliver itself is
//! a *borrowed* stack message (`borrowedListenerFire`) whose payload borrows the
//! stored resolution, the engine's carrier queue and encode-time borrow own the
//! lifecycle, never a clone.

const std = @import("std");

const model = @import("model");
const session = @import("session");

/// Replace a queued pipelined `op:deliver`'s target with `new_target`, taking
/// ownership of both `deliver`'s heap and `new_target`. The deliver's args,
/// answer, and `resolve_me_desc` are preserved (moved) into the returned message.
pub fn rewriteDeliverTarget(
    allocator: std.mem.Allocator,
    deliver: model.Deliver,
    new_target: model.Reference,
) model.Message {
    model.freeReference(allocator, deliver.target);
    return .{ .deliver = .{
        .target = new_target,
        .args = deliver.args,
        .answer = deliver.answer,
        .resolve_me_desc = deliver.resolve_me_desc,
        .listen_mode = deliver.listen_mode,
    } };
}

/// Build the *borrowed* `op:deliver` that fires a listener with `resolution`,
/// on the caller's stack: the method symbol is a static string, the payload
/// borrows `resolution` (for a break, the reason rides as a bare Symbol), and
/// the two-slot args array is the caller-supplied `args`. Nothing is allocated
/// and nothing is owned. The returned message is valid only while `args` and
/// the borrowed resolution live, and must never reach `model.freeMessage`. Per
/// the OCapN `op:listen` notification shape (the upstream conformance suite is
/// the authority), the args are `[Symbol("fulfill"), payload]` for a
/// fulfillment or `[Symbol("break"), Symbol(reason)]` for a break, the reason
/// as a bare Symbol, not an `<error>` record: the upstream suite asserts
/// exactly that for `test_op_listen_to_promise_and_break`, and Goblins'
/// unmarshaller rejects unknown records, so an `<error>` payload would kill
/// the break on a live Goblins partner. The listener target is rebuilt as
/// `FarRef.object(listener_position)`. Listener entries are only ever built
/// that shape (`pipeline.installAnswerListener` / the imported-promise
/// install), so a bare position loses nothing.
pub fn borrowedListenerFire(
    listener_position: u64,
    resolution: model.Resolution,
    args: *[2]model.Argument,
) model.Message {
    args.* = callbackArgs(resolution);
    return .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(listener_position) },
        .args = args,
        .answer = null,
        .resolve_me_desc = null,
    } };
}

/// The `['fulfill|'break, payload]` argument pair every resolver-shaped
/// notification carries: the listener fire and the V1.0 resolver callback.
/// Borrows `resolution`: a break's reason rides as a bare Symbol.
pub fn callbackArgs(resolution: model.Resolution) [2]model.Argument {
    return switch (resolution) {
        .fulfill => |arg| .{ .{ .symbol = "fulfill" }, arg },
        .@"break" => |err| .{ .{ .symbol = "break" }, .{ .symbol = err.message } },
    };
}

/// What draining one listener against a settled resolution produces, per
/// ADR-0003. The engine applies the action (queue the
/// fire carrier). Every variant is POD: a fire is a ticket (the far export
/// position the fire targets) that the engine's queue-time accounting and
/// encode-time borrow turn into the wire deliver (`borrowedListenerFire`).
pub const ListenerDrainAction = union(enum) {
    /// Fire the listener once with the resolution and drop the entry. The
    /// payload is the far export position the fire targets.
    fire: u64,
    /// The promise made a transition this subscription did not request.
    discard,
};

/// Decide how `entry` drains against a settled `resolution` (ADR-0003).
/// The re-anchor case, spec-strict `Fulfill(Promise(_))`, never reaches a
/// drain site: admission refuses an answer reference in a sent resolution
/// (`validate/passable.zig`), and the chain walk (`resolution_chain.follow`)
/// re-anchors on a same-peer promise before any listener is classified, so
/// that case is a precondition here. Settled values
/// conclude listeners that requested settling. A far promise is the listener's
/// own peer's promise. On next it concludes only shortening listeners, because
/// every next settling listener is paired with a shortening one that reissues
/// it against the target (ADR-0003). V1.0 has no such pair: Goblins listens
/// with wants-partial #f alone, and the spec exempts only same-peer promises,
/// so the far promise concludes every V1.0 listener and its peer follows it
/// locally. Pure and infallible: listener entries are POD `FarRef` values, so
/// the decision moves values and touches no heap.
pub fn classifyListenerDrain(
    entry: session.ListenerEntry,
    resolution: model.Resolution,
    profile: model.CaptpVersion,
) ListenerDrainAction {
    std.debug.assert(resolution.promiseAnswer() == null);
    const fire_position = entry.listener.import_position.int();
    if (resolution == .fulfill and resolution.fulfill == .reference and
        resolution.fulfill.reference == .far and
        resolution.fulfill.reference.far.kind == .promise)
    {
        return switch (profile) {
            .v1_0 => .{ .fire = fire_position },
            .next => if (entry.mode.wantsShortening()) .{ .fire = fire_position } else .discard,
        };
    }
    return if (entry.mode.wantsSettling()) .{ .fire = fire_position } else .discard;
}

/// Compute an `op:get` / `op:index` / `op:untag` projection over a settled
/// resolution (ADR-0004). A field projection requires a Struct fulfillment,
/// an element projection a List, and an untag projection a Tagged with the
/// asserted tag. A broken receiver passes its break through (the spec's
/// inherited rejection). A fulfillment that is itself a promise never reaches
/// this: the stored-resolution walker follows a paired local promise export
/// to its answer first. Every other shape breaks with a typed reason. Pure.
/// The result borrows `resolution`, and the caller's send clones it (the one
/// named boundary copy).
pub fn projectResolution(resolution: model.Resolution, kind: session.ProjectionKind) model.Resolution {
    const value = switch (resolution) {
        .@"break" => return resolution,
        .fulfill => |arg| arg,
    };
    switch (kind) {
        .field => |field| {
            if (value != .@"struct") return .{ .@"break" = .{
                .message = "op:get receiver did not resolve to a Struct",
            } };
            for (value.@"struct") |entry| {
                if (std.mem.eql(u8, entry.key, field)) return .{ .fulfill = entry.value };
            }
            return .{ .@"break" = .{ .message = "op:get field is absent on the Struct" } };
        },
        .index => |index| {
            if (value != .list) return .{ .@"break" = .{
                .message = "op:index receiver did not resolve to a List",
            } };
            const candidate = switch (index) {
                .candidate => |candidate| candidate,
                .out_of_bounds => return .{ .@"break" = .{
                    .message = "op:index position is out of the List's bounds",
                } },
            };
            if (candidate >= value.list.len) return .{ .@"break" = .{
                .message = "op:index position is out of the List's bounds",
            } };
            return .{ .fulfill = value.list[candidate] };
        },
        .untag => |tag| {
            if (value != .tagged) return .{ .@"break" = .{
                .message = "op:untag receiver did not resolve to a Tagged",
            } };
            if (!std.mem.eql(u8, value.tagged.tag, tag)) return .{ .@"break" = .{
                .message = "op:untag tag does not match the receiver's Tagged tag",
            } };
            // The spec's Tagged carries a single value; glowcap's model carries
            // the Goblins user-record payload as a slice (ADR-0005). One value
            // unwraps to that value; any other arity unwraps to the payload as
            // the List it is, so nothing is guessed and nothing is dropped.
            if (value.tagged.value.len == 1) {
                return .{ .fulfill = value.tagged.value[0] };
            }
            return .{ .fulfill = .{ .list = value.tagged.value } };
        },
    }
}
