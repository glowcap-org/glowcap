//! The pure half of the resolve seam (ADR-0007, ADR-0050): the math of what
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
    args.* = switch (resolution) {
        .fulfill => |arg| .{ .{ .symbol = "fulfill" }, arg },
        .@"break" => |err| .{ .{ .symbol = "break" }, .{ .symbol = err.message } },
    };
    return .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(listener_position) },
        .args = args,
        .answer = null,
        .resolve_me_desc = null,
    } };
}

/// What draining one listener against a resolution produces, per ADR-0007
/// § Listener fire matrix. The engine applies the action (queue the fire
/// carrier, reinstall the entry). Every variant is POD: a fire is a ticket
/// (the far export position the fire targets) that the engine's queue-time
/// accounting and encode-time borrow turn into the wire deliver
/// (`borrowedListenerFire`). A listener entry is a POD `FarRef` with no heap.
pub const ListenerDrainAction = union(enum) {
    /// Fire the listener once with the resolution and drop the entry. Every
    /// resolution shape except `Fulfill(Promise(_))` lands here. The payload
    /// is the far export position the fire targets.
    fire: u64,
    /// Re-anchor the entry on `next_answer` without firing. Spec-strict
    /// `Fulfill(Promise(_))`: a same-peer promise has not yet met any mode.
    reinstall: struct {
        next_answer: model.AnswerPosition,
        entry: session.ListenerEntry,
    },
    /// The promise made a transition this subscription did not request.
    discard,
};

/// Decide how `entry` drains against `resolution` (ADR-0007 § Listener fire matrix).
/// `Fulfill(Promise(_))` re-anchors the listener on the same peer's answer
/// without notification. Settled values conclude listeners that requested
/// settling. A far promise is the listener's own peer's promise. On next it
/// concludes only shortening listeners, because every next settling listener
/// is paired with a shortening one that reissues it against the target
/// (ADR-0111). V1.0 has no such pair: Goblins listens with wants-partial #f
/// alone, and the spec exempts only same-peer promises, so the far promise
/// concludes every V1.0 listener and its peer follows it locally. Pure and
/// infallible: listener entries are POD `FarRef` values, so the decision
/// moves values and touches no heap.
pub fn classifyListenerDrain(
    entry: session.ListenerEntry,
    resolution: model.Resolution,
    profile: model.CaptpVersion,
) ListenerDrainAction {
    const fire_position = entry.listener.import_position.int();
    if (resolution == .fulfill and resolution.fulfill == .reference and
        resolution.fulfill.reference == .promise)
    {
        const next_answer = resolution.fulfill.reference.promise.answer_position;
        return .{ .reinstall = .{ .next_answer = next_answer, .entry = entry } };
    }
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

/// `ListenerDrainAction` narrowed to the settled resolutions drain sites hold.
pub const TerminalDrainAction = union(enum) {
    fire: u64,
    discard,
};

/// `classifyListenerDrain` for a resolution already proven settled: either
/// `resolution_chain.Outcome.terminal`, whose `step` returns terminal only
/// for a value that is not a same-peer promise, or a locally constructed
/// fulfill or break. The matrix's re-anchor row is excluded by that
/// precondition: re-anchoring is the chain walk's job before any drain site
/// classifies. So the exclusion lives here once instead of as an arm every
/// drain switch must refuse.
pub fn classifyTerminalListenerDrain(
    entry: session.ListenerEntry,
    resolution: model.Resolution,
    profile: model.CaptpVersion,
) TerminalDrainAction {
    return switch (classifyListenerDrain(entry, resolution, profile)) {
        .fire => |position| .{ .fire = position },
        .discard => .discard,
        .reinstall => unreachable,
    };
}

/// What `projectResolution` decided for one `op:get` / `op:index`
/// projection over a settled resolution.
pub const Projected = union(enum) {
    /// The projection settled. The payload *borrows* the input resolution.
    /// The caller's send clones it (the one named boundary copy).
    resolved: model.Resolution,
    /// The resolution was itself a promise. Re-anchor the projection on that
    /// promise's answer.
    reanchor: model.AnswerPosition,
};

/// Compute an `op:get` / `op:index` / `op:untag` projection over a settled
/// resolution (ADR-0050). A field projection requires a Struct fulfillment,
/// an element projection a List, and an untag projection a Tagged with the
/// asserted tag. A broken receiver passes its break through (the spec's
/// inherited rejection). A fulfillment that is itself a promise reference
/// re-anchors. Every other shape breaks with a typed reason. Pure. The
/// `.resolved` payload borrows `resolution`.
pub fn projectResolution(resolution: model.Resolution, kind: session.ProjectionKind) Projected {
    const value = switch (resolution) {
        .@"break" => |err| return .{ .resolved = .{ .@"break" = err } },
        .fulfill => |arg| arg,
    };
    if (value == .reference and value.reference == .promise) {
        return .{ .reanchor = value.reference.promise.answer_position };
    }
    switch (kind) {
        .field => |field| {
            if (value != .@"struct") return .{ .resolved = .{ .@"break" = .{
                .message = "op:get receiver did not resolve to a Struct",
            } } };
            for (value.@"struct") |entry| {
                if (std.mem.eql(u8, entry.key, field)) {
                    return .{ .resolved = .{ .fulfill = entry.value } };
                }
            }
            return .{ .resolved = .{ .@"break" = .{
                .message = "op:get field is absent on the Struct",
            } } };
        },
        .index => |index| {
            if (value != .list) return .{ .resolved = .{ .@"break" = .{
                .message = "op:index receiver did not resolve to a List",
            } } };
            const candidate = switch (index) {
                .candidate => |candidate| candidate,
                .out_of_bounds => return .{ .resolved = .{ .@"break" = .{
                    .message = "op:index position is out of the List's bounds",
                } } },
            };
            if (candidate >= value.list.len) return .{ .resolved = .{ .@"break" = .{
                .message = "op:index position is out of the List's bounds",
            } } };
            return .{ .resolved = .{ .fulfill = value.list[candidate] } };
        },
        .untag => |tag| {
            if (value != .tagged) return .{ .resolved = .{ .@"break" = .{
                .message = "op:untag receiver did not resolve to a Tagged",
            } } };
            if (!std.mem.eql(u8, value.tagged.tag, tag)) return .{ .resolved = .{ .@"break" = .{
                .message = "op:untag tag does not match the receiver's Tagged tag",
            } } };
            // The spec's Tagged carries a single value; glowcap's model carries
            // the Goblins user-record payload as a slice (ADR-0021). One value
            // unwraps to that value; any other arity unwraps to the payload as
            // the List it is, so nothing is guessed and nothing is dropped.
            if (value.tagged.value.len == 1) {
                return .{ .resolved = .{ .fulfill = value.tagged.value[0] } };
            }
            return .{ .resolved = .{ .fulfill = .{ .list = value.tagged.value } } };
        },
    }
}
