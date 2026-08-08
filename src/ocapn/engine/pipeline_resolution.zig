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
//! stored resolution — the engine's carrier queue and encode-time borrow own the
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
/// and nothing is owned — the returned message is valid only while `args` and
/// the borrowed resolution live, and must never reach `model.freeMessage`. Per
/// the OCapN `op:listen` notification shape (the upstream conformance suite is
/// the authority), the args are `[Symbol("fulfill"), payload]` for a
/// fulfillment or `[Symbol("break"), Symbol(reason)]` for a break — the reason
/// as a bare Symbol, not an `<error>` record: the upstream suite asserts
/// exactly that for `test_op_listen_to_promise_and_break`, and Goblins'
/// unmarshaller rejects unknown records, so an `<error>` payload would kill
/// the break on a live Goblins partner. The listener target is rebuilt as
/// `FarRef.object(listener_position)` — listener entries are only ever built
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

/// The single-hop chain a multi-hop pipelined deliver decomposes into:
/// zero-or-more intermediate messages in send order, plus the guaranteed-present
/// terminal deliver carrying the caller's outer args / answer / `resolve_me_desc`.
/// Splitting intermediates from the terminal makes non-emptiness structural, a
/// caller can't observe an empty chain.
pub const DecomposedChain = struct {
    /// One flat `op:deliver` per path step, in send order. The `intermediates`
    /// backing slice is the caller's to free; each element is an owned message.
    intermediates: []model.Message,
    /// The caller's outer deliver against the last intermediate answer. Always
    /// present (an empty path never reaches decomposition).
    terminal: model.Message,
};

/// Errors decomposition surfaces beyond allocation failure.
pub const DecomposeError = std.mem.Allocator.Error || error{
    /// A `field` path step reached the Syrup decomposer. `field` navigation is
    /// Cap'n-Proto-only (the model contract: `desc:answer` has no structural
    /// analog on `op:deliver`); surfacing it loudly beats a silently-dropped step.
    UnsupportedPipelineOp,
};

/// Decompose an owned multi-hop pipelined `op:deliver` (target = promise with a
/// non-empty path) into the chain of single-hop messages the Syrup wire admits.
/// `desc:answer` carries no path operand (ADR-0007 § Multi-hop decomposition at
/// the sender), so each `call`
/// step becomes its own flat `op:deliver` against a freshly-allocated
/// intermediate answer, and the caller's outer deliver chains against the last.
///
/// Pure move, no clone: each `call` op's args move into its intermediate deliver,
/// the outer args / `resolve_me_desc` move into the terminal, and the emptied
/// `path.ops` backing slice is freed (its elements live in the chain).
///
/// Ownership on error: a `field` step is rejected up front and `OutOfMemory`
/// fires on the single allocation — both before any move — so `message` is left
/// whole for the caller to release. Decomposition never partially consumes
/// `message`.
pub fn decomposeOutboundDeliver(
    allocator: std.mem.Allocator,
    sess: *session.Session,
    message: model.Message,
) DecomposeError!DecomposedChain {
    const deliver = message.deliver;
    const promise = deliver.target.promise;
    const ops = promise.path.ops;
    std.debug.assert(ops.len != 0);

    // Pre-flight: Syrup admits only `call` steps as chained delivers. Reject a
    // `field` step before moving anything, leaving `message` whole.
    for (ops) |op| {
        if (op == .field) return DecomposeError.UnsupportedPipelineOp;
    }

    const intermediates = try allocator.alloc(model.Message, ops.len);
    // Infallible from here: allocateOutboundAnswer never fails and building a
    // deliver struct only moves heap, so no partial-move cleanup is needed.
    var prev_answer = promise.answer_position;
    for (ops, 0..) |op, i| {
        const intermediate_id = sess.allocateOutboundAnswer();
        intermediates[i] = .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = prev_answer } },
            .args = op.call,
            .answer = intermediate_id,
            .resolve_me_desc = null,
        } };
        prev_answer = intermediate_id;
    }
    const terminal: model.Message = .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = prev_answer } },
        .args = deliver.args,
        .answer = deliver.answer,
        .resolve_me_desc = deliver.resolve_me_desc,
    } };
    // Every op payload + the outer args moved into the chain; release only the
    // emptied `ops` backing slice.
    allocator.free(ops);
    return .{ .intermediates = intermediates, .terminal = terminal };
}

/// What draining one listener against a resolution produces, per ADR-0007
/// § Listener fire matrix. The engine applies the action (queue the fire
/// carrier, reinstall the entry). Every variant is POD: a fire is a ticket —
/// the far export position the fire targets — that the engine's queue-time
/// accounting and encode-time borrow turn into the wire deliver
/// (`borrowedListenerFire`); a listener entry is a POD `FarRef` with no heap.
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
/// without notification. A far promise is shortening and concludes listeners
/// that requested it; settled values conclude listeners that requested
/// settling. Pure and infallible: listener entries are POD `FarRef` values, so
/// the decision moves values and touches no heap.
pub fn classifyListenerDrain(
    entry: session.ListenerEntry,
    resolution: model.Resolution,
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
        return if (entry.mode.wantsShortening()) .{ .fire = fire_position } else .discard;
    }
    return if (entry.mode.wantsSettling()) .{ .fire = fire_position } else .discard;
}

/// What `projectResolution` decided for one `op:get` / `op:index`
/// projection over a settled resolution.
pub const Projected = union(enum) {
    /// The projection settled. The payload *borrows* the input resolution;
    /// the caller's send clones it (the one named boundary copy).
    resolved: model.Resolution,
    /// The resolution was itself a promise; re-anchor the projection on that
    /// promise's answer.
    reanchor: model.AnswerPosition,
};

/// Compute an `op:get` / `op:index` / `op:untag` projection over a settled
/// resolution (ADR-0050). A field projection requires a Struct fulfillment,
/// an element projection a List, and an untag projection a Tagged with the
/// asserted tag; a broken receiver passes its break through (the spec's
/// inherited rejection); a fulfillment that is itself a promise reference
/// re-anchors. Every other shape breaks with a typed reason. Pure; the
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
            // The spec's Tagged carries a single value; pancake's model carries
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
