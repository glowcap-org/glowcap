//! Exact-incarnation traversal for consequences of stored promise resolutions.
//!
//! Wire answers and paired local promise exports reach the same answer store.
//! A stored resolution captures that answer's exact incarnation at admission.
//! Every later listener, pipelined call, and projection follows that stamp.

const std = @import("std");

const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

/// A stored resolution's exact answer incarnation: the stamped target and the
/// retained payload box it resolved into.
pub const StoreTarget = struct {
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
};

pub const Source = struct {
    target: StoreTarget,
    stored: *const session.StoredResolution,
};

pub const Outcome = union(enum) {
    terminal: struct {
        target: StoreTarget,
        resolution: model.Resolution,
    },
    pending: session.AnswerTarget,
    terminal_break: []const u8,
};

pub const released_target_message = "promise resolution target was released";
pub const missing_target_message = "promise resolution target is unavailable";
pub const cycle_message = "promise resolution cycle";
pub const chain_limit_message = "promise resolution chain exceeds max_resolution_chain";
/// The sender rule (ADR-0068): a `desc:answer` names its sender's question,
/// so a call or reply forwarded to the partner cannot carry the partner's own.
pub const call_answer_reference_message = "a forwarded call cannot carry the partner's answer reference";
pub const reply_answer_reference_message = "a forwarded reply cannot carry the partner's answer reference";

const Step = union(enum) {
    terminal: Outcome,
    next: Source,
};

fn step(peer: *Peer, current: Source) Step {
    const resolution = current.stored.value;
    const target = current.stored.promise_target orelse {
        // Only a paired local promise export carries a chain target, captured
        // at admission with the answer's incarnation. Every other stored value
        // is terminal: admission admits no answer reference in a sent
        // resolution, so a terminal is never a promise.
        std.debug.assert(resolution.promiseAnswer() == null);
        return .{ .terminal = .{ .terminal = .{
            .target = current.target,
            .resolution = resolution,
        } } };
    };
    const payload = peer.session_state.answerPayloadForTarget(target) orelse {
        const live = peer.session_state.answerTargetNamed(target.name) orelse
            return .{ .terminal = .{ .terminal_break = released_target_message } };
        if (!std.meta.eql(live, target))
            return .{ .terminal = .{ .terminal_break = released_target_message } };
        return .{ .terminal = .{ .pending = target } };
    };
    const stored = peer.session_state.answerPayloadStoredResolution(payload) orelse
        return .{ .terminal = .{ .pending = target } };
    return .{ .next = .{
        .target = .{ .target = target, .payload = payload },
        .stored = stored,
    } };
}

/// Whether a stored value about to leave for the partner names a partner
/// object this session has released. A sent resolution takes no retain on
/// the imports it names, so the application may release the object while the
/// resolution stays stored, and a consumer that would send the value after
/// that breaks with `released_target_message` instead of naming a position
/// the partner may have retired. Each consumer checks only what it sends: a
/// call its target, a projection its selected subtree, a listener the whole
/// value. A local export named the same way keeps its row through the store,
/// so only imports can lapse. One table lookup per far reference in the value.
pub fn namesReleasedImport(peer: *Peer, value: model.Argument) bool {
    return model.anyReference(&.{value}, peer, isReleasedImport);
}

fn isReleasedImport(peer: *Peer, reference: model.Reference) bool {
    return reference == .far and !peer.session_state.holdsImport(reference.far.import_position);
}

fn isPromise(source: Source) bool {
    return source.stored.promise_target != null;
}

fn advanceCycleProbe(peer: *Peer, source: *Source) bool {
    switch (step(peer, source.*)) {
        .terminal => return false,
        .next => |next| {
            source.* = next;
            return true;
        },
    }
}

pub fn follow(peer: *Peer, first: Source) Outcome {
    var slow = first;
    var fast = first;
    var detect_cycle = true;
    var hops: usize = 0;
    while (true) {
        if (isPromise(slow) and hops >= peer.session_state.limits.max_resolution_chain)
            return .{ .terminal_break = chain_limit_message };
        slow = switch (step(peer, slow)) {
            .terminal => |outcome| return outcome,
            .next => |next| next,
        };
        hops += 1;

        if (!detect_cycle) continue;
        detect_cycle = advanceCycleProbe(peer, &fast) and advanceCycleProbe(peer, &fast);
        if (detect_cycle and std.meta.eql(slow.target, fast.target))
            return .{ .terminal_break = cycle_message };
    }
}

/// Walk the chain from an answer that holds its resolution.
pub fn followAnswer(
    peer: *Peer,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
) Outcome {
    const stored = peer.session_state.answerPayloadStoredResolution(payload) orelse
        return .{ .terminal_break = missing_target_message };
    return follow(peer, .{
        .target = .{ .target = target, .payload = payload },
        .stored = stored,
    });
}

/// The chain outcome for an answer that already holds its resolution, or
/// null while it is still pending. Peeking the stored value rather than the
/// status flag is what lets work that arrives while the answer's own resolve
/// is still a queued outbound message see the real value.
pub fn settledOutcome(peer: *Peer, target: session.AnswerTarget) ?Outcome {
    const payload = peer.session_state.answerPayloadForTarget(target) orelse return null;
    const stored = peer.session_state.answerPayloadStoredResolution(payload) orelse return null;
    return follow(peer, .{
        .target = .{ .target = target, .payload = payload },
        .stored = stored,
    });
}
