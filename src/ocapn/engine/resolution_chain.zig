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

pub const StoreTarget = union(enum) {
    answer: struct {
        target: session.AnswerTarget,
        payload: *session.AnswerPayload,
    },
    import: struct { position: model.ImportPosition, row_id: u64 },
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

const Step = union(enum) {
    terminal: Outcome,
    next: Source,
};

fn step(peer: *Peer, current: Source) Step {
    const resolution = current.stored.value;
    const target = current.stored.promise_target orelse {
        // A wire answer must have captured its incarnation at admission. Other
        // terminal values have no chain target. Local promise exports carry
        // the same stamp through their Session-owned export/answer pairing.
        if (resolution == .fulfill and resolution.fulfill == .reference and
            resolution.fulfill.reference == .promise)
            return .{ .terminal = .{ .terminal_break = missing_target_message } };
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
        .target = .{ .answer = .{ .target = target, .payload = payload } },
        .stored = stored,
    } };
}

fn isPromise(source: Source) bool {
    const resolution = source.stored.value;
    return source.stored.promise_target != null or
        (resolution == .fulfill and resolution.fulfill == .reference and
            resolution.fulfill.reference == .promise);
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

pub fn followAnswer(
    peer: *Peer,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
) Outcome {
    const stored = peer.session_state.answerPayloadStoredResolution(payload) orelse
        return .{ .terminal_break = missing_target_message };
    return follow(peer, .{
        .target = .{ .answer = .{ .target = target, .payload = payload } },
        .stored = stored,
    });
}
