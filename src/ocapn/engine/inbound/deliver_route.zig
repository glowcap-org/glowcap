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

const Peer = engine.Peer;

fn validateResolverCallbackEnvelope(deliver: *const model.view.Deliver) session.Error!void {
    if (deliver.answer != null or deliver.resolve_me_desc != null)
        return error.UnexpectedMessage;
}

/// The one route an inbound `op:deliver` takes. The variants are mutually
/// exclusive by construction: resolver callbacks target resolver exports,
/// pipelined calls target answers, and bootstrap delivers target export 0.
pub const Route = union(enum) {
    /// A deliver to one of our resolver exports, settling the outbound answer
    /// carried here. The frame surfaces as a semantic `Resolve`.
    resolver_callback_resolve: model.AnswerPosition,
    /// A next-profile shortening-only callback. It advances private session
    /// routing and is consumed before the application event queue.
    shortening_callback: model.ExportPosition,
    forwarding_callback: model.ExportPosition,
    /// A resolver callback that raced with local answer release. Its arguments
    /// are admitted and immediately released, with no application event.
    retired_resolver_callback: model.ExportPosition,
    /// A Node-only settling callback. It remains a deliver event for the Host's
    /// Node composition hook, while session authority retires it as one-shot.
    node_resolver_callback: model.ExportPosition,
    /// Pipelined against an answer we owe (ADR-0003): the call was queued or
    /// redirected during classification, so the frame surfaces nothing.
    pipelined: pipeline.PreparedPipelinedCall,
    /// A bootstrap-protocol deliver (ADR-0002): the caller applies the action
    /// after authority records the deliver.
    bootstrap: bootstrap.Request,
    /// An ordinary deliver, surfaced to the application. The optional answer is
    /// the virtual inbound answer allocated for a V1.0 resolver-only deliver.
    ordinary: ?model.VirtualAnswer,
};

/// Route selection with the resolver and destination state prepared by the
/// routes that can do so here. The inbound owner commits prepared authority
/// only after securing the chosen destination. Specialized callback views are
/// validated there before the shared import preparation.
pub const Classification = struct {
    route: Route,
    resolver: ?session.PreparedDeliveryResolver = null,

    /// Ordinary routes reserve their answer/import apply before retaining a
    /// destination. Callback routes validate through specialized semantic
    /// views in the inbound owner and need that owner's shared import preflight.
    pub fn needsIntroducedImportPreparation(self: *const Classification) bool {
        return switch (self.route) {
            .resolver_callback_resolve,
            .shortening_callback,
            .forwarding_callback,
            .retired_resolver_callback,
            .node_resolver_callback,
            => true,
            .pipelined, .bootstrap, .ordinary => false,
        };
    }

    pub fn abandon(self: *Classification, peer: *Peer) void {
        if (self.resolver) |*prepared| prepared.abandon(&peer.session_state);
        if (self.route == .pipelined) self.route.pipelined.abandon(peer);
    }
};

/// Admit a callback that settles something the session holds: its args must
/// project to a resolution, and the deliver must validate as a whole.
fn admitSettlingCallback(
    peer: *Peer,
    body: *const model.view.Body,
    introduced: *session.validate.IntroducedImports,
) !void {
    _ = try events.resolutionFromResolverCallback(body.deliver.args);
    try peer.session_state.validateInboundDeliverView(body, introduced);
}

/// Classify an inbound `op:deliver` into one route. Probe order is part of the
/// contract:
///
/// 1. Resolver-export callbacks run first on every session profile.
/// 2. Ordinary deliver validation runs before any route-specific mutation.
/// 3. V1.0 resolver, answer/import, and pipeline storage prepare together.
/// 4. Pipelining precedes bootstrap so answer targets are not mistaken for
///    bootstrap export calls.
/// 5. Bootstrap runs last and ordinary delivery is the fallback.
pub fn classify(
    peer: *Peer,
    body: *const model.view.Body,
    introduced: *session.validate.IntroducedImports,
    out: *Classification,
) !void {
    const deliver = &body.deliver;
    // A resolver export settles by an `['fulfill|'break, payload]` deliver on
    // every negotiated version, so this read carries no version gate: the
    // V1.0 resolver callback and the `op:listen` notification a listener
    // export receives are the same wire shape (ADR-0003). Only a `.near`
    // names an export row, so a partner-named `.far` in the same integer
    // space cannot reach a purpose. One read of the row classifies every
    // resolver kind; a local promise's projection is an ordinary target.
    if (deliver.target.exportPosition()) |position| {
        if (peer.session_state.resolverPurpose(position)) |purpose| if (purpose.isCallback()) {
            try validateResolverCallbackEnvelope(deliver);
            switch (purpose) {
                .forwarding => {
                    try admitSettlingCallback(peer, body, introduced);
                    out.* = .{ .route = .{ .forwarding_callback = position } };
                },
                .shortening_pending => out.* = .{ .route = .{ .shortening_callback = position } },
                .shortening_complete => return session.Error.UnexpectedMessage,
                .node_settling => {
                    try admitSettlingCallback(peer, body, introduced);
                    out.* = .{ .route = .{ .node_resolver_callback = position } };
                },
                .retired => |retired| {
                    if (retired.state == .complete) return error.UnexpectedMessage;
                    try admitSettlingCallback(peer, body, introduced);
                    out.* = .{ .route = .{ .retired_resolver_callback = position } };
                },
                .application_answer => |answer| out.* = .{ .route = .{ .resolver_callback_resolve = answer } },
                .none, .local_promise_answer => unreachable,
            }
            return;
        };
    }
    // Every remaining route has ordinary deliver semantics. Validate the full
    // target, answer, resolver descriptor, and argument tree before any route
    // prepares storage or commits session authority.
    try peer.session_state.validateInboundDeliverView(body, introduced);
    // A resolver-only deliver (no wire answer) has a virtual answer allocated
    // here. Carry it to the ordinary surface so a local object can reply
    // through the resolver callback.
    var resolver = try peer.session_state.prepareDeliveryResolver(deliver);
    errdefer if (resolver) |*prepared| prepared.abandon(&peer.session_state);
    // Reserve the ordinary answer/import apply in the same preparation epoch.
    // The conservative extra row covers a fresh resolver import; over-reserving
    // when it aliases an argument or an existing import is private capacity.
    try peer.session_state.prepareValidatedInboundDeliver(
        deliver,
        introduced,
    );
    const virtual_answer = if (resolver) |prepared| prepared.virtualAnswer() else null;
    const call_answer: ?model.AnswerName = .ofDeliver(deliver.answer, virtual_answer);
    if (try pipeline.preparePipelinedCall(peer, deliver, call_answer, introduced)) |prepared| {
        out.* = .{ .route = .{ .pipelined = prepared }, .resolver = resolver };
        return;
    }
    if (try bootstrap.pendingBootstrapAction(deliver, virtual_answer)) |action| {
        out.* = .{ .route = .{ .bootstrap = action }, .resolver = resolver };
        return;
    }
    out.* = .{ .route = .{ .ordinary = virtual_answer }, .resolver = resolver };
}
