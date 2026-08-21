//! Inbound `op:deliver` routing.
//!
//! This module owns the special-case probe order for a decoded deliver. It
//! validates ordinary deliver authority before any route mutates session state.

const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const bootstrap = @import("../bootstrap.zig");
const events = @import("../events.zig");
const pipeline = @import("../pipeline.zig");
const v1_0 = @import("../v1_0.zig");

const Peer = engine.Peer;

/// The one route an inbound `op:deliver` takes. The variants are mutually
/// exclusive by construction: resolver callbacks target resolver exports,
/// pipelined calls target answers, and bootstrap delivers target export 0.
pub const Route = union(enum) {
    /// A deliver to one of our resolver exports, settling the outbound answer
    /// carried here; the frame surfaces as a semantic `Resolve`.
    resolver_callback_resolve: model.AnswerPosition,
    /// A next-profile shortening-only callback. It advances private session
    /// routing and is consumed before the application event queue.
    shortening_callback: model.ExportPosition,
    /// A resolver callback that raced with local answer release. Its arguments
    /// are admitted and immediately released, with no application event.
    retired_resolver_callback: model.ExportPosition,
    /// A Node-only settling callback. It remains a deliver event for the Host's
    /// Node composition hook, while session authority retires it as one-shot.
    node_resolver_callback: model.ExportPosition,
    /// Pipelined against an answer we owe (ADR-0007): the call was queued or
    /// redirected during classification, so the frame surfaces nothing.
    pipelined,
    /// A bootstrap-protocol deliver (ADR-0006): the caller applies the action
    /// after authority records the deliver.
    bootstrap: bootstrap.Request,
    /// An ordinary deliver, surfaced to the application. The optional answer is
    /// the virtual inbound answer allocated for a V1.0 resolver-only deliver.
    ordinary: ?model.VirtualAnswer,
};

/// Classify an inbound `op:deliver` into one route. Probe order is part of the
/// contract:
///
/// 1. Resolver-export callbacks run first on every session profile.
/// 2. Ordinary deliver validation runs before any route-specific mutation.
/// 3. V1.0 resolver registration must precede pipeline retention.
/// 4. Pipelining precedes bootstrap so answer targets are not mistaken for
///    bootstrap export calls.
/// 5. Bootstrap runs last and ordinary delivery is the fallback.
pub fn classify(
    peer: *Peer,
    deliver: model.view.Deliver,
    introduced: *session.validate.IntroducedImports,
) !Route {
    // A resolver export settles by an `['fulfill|'break, payload]` deliver on
    // every negotiated version, so this probe carries no version gate: the
    // V1.0 resolver callback and the `op:listen` notification a listener
    // export receives are the same wire shape (ADR-0095). Only a `.near`
    // reaches the link, so a partner-named `.far` in the same integer space
    // cannot key it.
    if (deliver.target.exportPosition()) |position| {
        if (peer.session_state.sourceForShorteningResolver(position)) |state| {
            return switch (state) {
                .pending => .{ .shortening_callback = position },
                .complete => session.Error.UnexpectedMessage,
            };
        }
        if (peer.session_state.isNodeSettlingResolver(position)) {
            _ = try events.resolutionFromResolverCallback(deliver.args);
            try peer.session_state.validateInboundDeliverView(deliver, introduced);
            return .{ .node_resolver_callback = position };
        }
        if (peer.session_state.retiredResolverState(position)) |state| {
            if (state == .complete) return session.Error.UnexpectedMessage;
            _ = try events.resolutionFromResolverCallback(deliver.args);
            try peer.session_state.validateInboundDeliverView(deliver, introduced);
            return .{ .retired_resolver_callback = position };
        }
        if (peer.session_state.answerForResolverExport(position)) |answer| {
            return .{ .resolver_callback_resolve = answer };
        }
    }
    // Every remaining route has ordinary deliver semantics. Validate the full
    // target, answer, resolver descriptor, and argument tree before resolver
    // registration or pipeline retention can mutate session authority.
    try peer.session_state.validateInboundDeliverView(deliver, introduced);
    // A resolver-only deliver (no wire answer) has a virtual answer allocated
    // here. Carry it to the ordinary surface so a local object can reply
    // through the resolver callback.
    var ordinary_answer: ?model.VirtualAnswer = null;
    if (peer.session_state.needsV1_0Translation()) {
        ordinary_answer = try v1_0.registerPartnerResolver(peer, deliver);
    }
    if (try pipeline.maybeEnqueuePipelinedCall(peer, deliver)) {
        return .pipelined;
    }
    if (try bootstrap.pendingBootstrapAction(deliver, &peer.session_state)) |action| {
        return .{ .bootstrap = action };
    }
    return .{ .ordinary = ordinary_answer };
}
