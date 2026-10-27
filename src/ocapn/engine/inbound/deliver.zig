//! Apply one inbound `op:deliver`: classify its route, prepare every row the
//! route needs, then commit it, surfacing an event for the routes that carry
//! one and answering the bootstrap request an accepted deliver made.

const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const Peer = engine.Peer;
const bootstrap = @import("../bootstrap.zig");
const bootstrap_request = @import("bootstrap_request.zig");
const copying = @import("../outbound/copying.zig");
const deliver_route = @import("deliver_route.zig");
const events = @import("../events.zig");
const inbound = @import("../inbound.zig");
const pipeline = @import("../pipeline.zig");
const remote_forward = @import("../remote_forward.zig");
const resolution_chain = @import("../resolution_chain.zig");
const shortening = @import("../inbound_shortening.zig");

const IntroducedImports = session.validate.IntroducedImports;

/// Where an inbound deliver goes, decided before any authority mutates: the
/// route the classifier chose, the event it surfaces as, and the callback it
/// settles. The classifier holds the probe order and the validate-before-
/// mutate boundary; this record holds what it decided.
const Route = struct {
    classified: deliver_route.Classification,
    /// Set once `Preparation.init` moves a pipelined classification into
    /// its composite, so `abandon` releases it from one owner. The
    /// classification stays inline: a null arm would zero its payload on
    /// every inbound deliver.
    classified_moved: bool,
    answer_override: events.AnswerOverride,
    callback: Callback,

    /// What the deliver settles beyond its own answer. Exactly one arm holds,
    /// so a tagged union says so and writes one tag where a row of optionals
    /// would zero every absent payload on every inbound deliver.
    const Callback = union(enum) {
        none,
        /// Surfaces as a semantic `Resolve` (ADR-0006, ADR-0003). The
        /// resolution is a *borrowed* view over the deliver's args, applied
        /// through the session's resolver-callback seam, with no owned
        /// materialization. `recordResolverCallbackResolve` settles the
        /// outbound answer and installs any `far` the fulfill introduces,
        /// but does not store the resolution itself: the surfaced frame,
        /// kept alive on the event queue, carries the value to the
        /// application. The borrow stays valid because that frame outlives
        /// the apply call.
        resolver_resolve: model.view.Resolve,
        shortening_callback: shortening.ShorteningCallbackPlan,
        retired_resolver: model.ExportPosition,
        node_resolver: model.ExportPosition,
        forwarding: Forwarding,
        /// Answered automatically once authority records the deliver
        /// (ADR-0002 responder half): the request stays on the classified
        /// route and applies after surfacing.
        bootstrap,
    };

    const Forwarding = struct {
        resolver: model.ExportPosition,
        /// The forwarded reply's target is gone, so the deliver releases
        /// what it introduced instead of answering.
        discarded: bool,
        /// The carried resolution. One naming the partner's own question has
        /// no form toward it (`remote_forward`), so the original answer
        /// breaks and the deliver releases what it introduced.
        carried: model.view.Resolution,
        carries_answer: bool,
    };

    /// Fills `route` in place: this record is close to a kilobyte, so building
    /// it by value would copy it once per inbound deliver.
    fn init(route: *Route, self: *Peer, body: *const model.view.Body, introduced: *IntroducedImports) !void {
        try deliver_route.classify(self, body, introduced, &route.classified);
        route.classified_moved = false;
        route.answer_override = .none;
        route.callback = .none;
        errdefer route.abandon(self);
        const deliver = &body.deliver;
        switch (route.classified.route) {
            .resolver_callback_resolve => |answer| {
                // A purpose row names the question its nomination installed
                // (ADR-0038), so a miss is a resolver for a question we never
                // asked: refuse the frame as the foreign reference it is.
                route.answer_override = .{ .resolve = self.session_state.outboundAnswerTarget(answer) orelse return error.InvalidReference };
                route.callback = .{ .resolver_resolve = .{
                    .answer = answer,
                    .resolution = try events.resolutionFromResolverCallback(deliver.args),
                } };
                try self.session_state.validateResolverCallbackResolve(route.callback.resolver_resolve, introduced);
                try self.session_state.validatePromiseSettlingFollowers(answer);
            },
            .shortening_callback => |resolver| route.callback = .{ .shortening_callback = try shortening.ShorteningCallbackPlan.init(
                self,
                resolver,
                body,
                introduced,
            ) },
            .retired_resolver_callback => |resolver| route.callback = .{ .retired_resolver = resolver },
            .node_resolver_callback => |resolver| route.callback = .{ .node_resolver = resolver },
            .forwarding_callback => |resolver| {
                const reply = session.ForwardedReply.find(&self.session_state, resolver) orelse unreachable;
                const carried = try events.resolutionFromResolverCallback(deliver.args);
                route.callback = .{ .forwarding = .{
                    .resolver = resolver,
                    .discarded = !session.ForwardedReply.targetIsLive(&self.session_state, reply.target),
                    .carried = carried,
                    .carries_answer = try carried.namesAnswer(),
                } };
            },
            // Queued or redirected against the answer it pipelined on
            // (ADR-0003). Commit waits for the same shortening and
            // maintenance preparation every other accepted deliver receives.
            .pipelined => {},
            .bootstrap => route.callback = .bootstrap,
            // A resolver-only deliver carries the virtual answer the
            // classifier allocated, so the surfaced deliver can be replied
            // to; an answered deliver carries null (the frame has the answer).
            .ordinary => |answer| {
                if (answer) |a| route.answer_override = .{ .virtual_deliver = a };
            },
        }
    }

    fn abandon(self: *Route, peer: *Peer) void {
        if (!self.classified_moved) self.classified.abandon(peer);
    }

    /// A retired resolver callback, or a forwarding callback whose target is
    /// gone or whose result breaks it, releases the imports the deliver
    /// introduced instead of shortening the promises among them.
    fn releasesIntroduced(self: *const Route) bool {
        return switch (self.callback) {
            .retired_resolver => true,
            .forwarding => |forwarding| forwarding.discarded or forwarding.carries_answer,
            else => false,
        };
    }

    /// The event kind the frame surfaces as: a resolver callback is the
    /// resolve it carries, and every other deliver is a deliver.
    fn tag(self: *const Route) events.EventKind {
        return if (self.callback == .resolver_resolve) .resolve else .deliver;
    }

    /// The most pending outbound rows the route's preparation may hold while
    /// authority is validated and committed as one transaction.
    fn pendingPreparationCount(self: *const Route, introduced: *const IntroducedImports) usize {
        if (self.releasesIntroduced()) return 1;
        if (self.callback == .shortening_callback) return self.callback.shortening_callback.pendingPreparationCount(introduced);
        return introduced.promise_mentions.count();
    }
};

/// One inbound pipelined deliver after its destination and maintenance are
/// prepared. It owns the prepared call, resolver link, and shortening work.
/// Commit borrows the validated frame view and its import record only long
/// enough to apply authority before publishing those consequences.
const PreparedPipelinedDeliver = struct {
    call: pipeline.PreparedPipelinedCall,
    resolver: ?session.PreparedDeliveryResolver,
    shortening: shortening.PreparedShortening,

    fn abandon(self: *PreparedPipelinedDeliver, peer: *Peer) void {
        self.shortening.abandon(peer);
        if (self.resolver) |*prepared| prepared.abandon(&peer.session_state);
        self.call.abandon(peer);
    }

    fn commit(
        self: *PreparedPipelinedDeliver,
        peer: *Peer,
        body: *const model.view.Body,
        introduced: *const IntroducedImports,
    ) !void {
        try peer.session_state.applyValidatedInboundDeliverView(body, introduced);
        if (self.resolver) |*prepared| prepared.commit(&peer.session_state);
        shortening.commitPreparedShortening(peer, &self.shortening);
        try self.call.commit(peer);
    }
};

/// Every resolver row, queue slot, and owned GC slice the route needs,
/// acquired before apply. Once the received frame commits, the required
/// protocol maintenance must not become optional under allocator pressure.
/// One arm holds per route. `abandon` runs only on a refusal, and each
/// commit verb leaves its arm empty, so a refusal after a partial commit
/// releases nothing twice. Replacing the arm instead would zero the union's
/// widest payload on every inbound deliver.
const Preparation = union(enum) {
    pipelined: PreparedPipelinedDeliver,
    shortening_callback: shortening.PreparedShorteningCallback,
    /// The import releases a route that releases what it introduced sends
    /// in place of shortening, or null when it introduced nothing.
    release: ?shortening.PreparedOutboundMessage,
    shortening: shortening.PreparedShortening,

    /// Fills `prepared` in place for the same reason `Route.init` does.
    fn init(prepared: *Preparation, self: *Peer, route: *Route, introduced: *IntroducedImports) !void {
        // Reserve the whole possible batch once; a per-row reservation cannot
        // express slots for rows that have not been appended yet. status-allow: pending state or quoted runtime label
        var pending_batch = try self.beginPendingBatch(route.pendingPreparationCount(introduced));
        if (route.releasesIntroduced()) {
            prepared.* = .{ .release = try shortening.prepareIntroducedImportReleases(self, &pending_batch, introduced.mentions.items()) };
        } else if (route.callback == .shortening_callback) {
            prepared.* = .{ .shortening_callback = try route.callback.shortening_callback.prepare(self, &pending_batch, introduced) };
        } else {
            const prepared_shortening = try shortening.prepareIntroducedPromiseShortening(self, &pending_batch, introduced);
            if (route.classified.route != .pipelined) {
                prepared.* = .{ .shortening = prepared_shortening };
                return;
            }
            // The composite is now the sole owner of all three preparations;
            // keep the route from abandoning a second copy.
            prepared.* = .{ .pipelined = .{
                .call = route.classified.route.pipelined,
                .resolver = route.classified.resolver,
                .shortening = prepared_shortening,
            } };
            route.classified_moved = true;
        }
    }

    fn abandon(self: *Preparation, peer: *Peer) void {
        switch (self.*) {
            .pipelined => |*prepared| prepared.abandon(peer),
            .shortening_callback => |*prepared| prepared.abandon(peer),
            .release => |prepared| if (prepared) |message| shortening.abandonPreparedOutboundMessage(peer, message),
            .shortening => |*prepared| prepared.abandon(peer),
        }
    }

    fn commitRelease(self: *Preparation, peer: *Peer) void {
        if (self.release) |message| shortening.commitPreparedImportRelease(peer, message);
        self.release = null;
    }

    /// `commitPreparedShortening` leaves the arm empty, so `abandon` after
    /// it releases nothing.
    fn commitShortening(self: *Preparation, peer: *Peer) void {
        shortening.commitPreparedShortening(peer, &self.shortening);
    }
};

/// Apply an inbound deliver, consuming `frame_in` and its `parse` on every
/// outcome: they move into the surfaced event, or are released once an
/// unsurfaced route commits or any step refuses.
pub fn apply(
    self: *Peer,
    frame_in: foundation.Frame,
    parse: events.Parse,
    wire_profile: model.CaptpVersion,
) !void {
    var surfaced = false;
    errdefer if (!surfaced) release(self, frame_in, parse);
    const body = parse.body();

    // The introduced-import record is filled by deliver validation before any
    // deliver-specific authority mutation and consumed by ordinary/bootstrap
    // apply below. It also survives long enough to annotate the surfaced event
    // for stateless GC without walking the argument tree again.
    var introduced: IntroducedImports = undefined;
    introduced.init(self.allocator, &self.session_state);
    defer introduced.deinit();

    var route: Route = undefined;
    try route.init(self, body, &introduced);
    errdefer route.abandon(self);

    // Callback routes validate through specialized semantic views after
    // classification and still need the shared import preflight. Ordinary
    // routes already reserved the full answer/import apply before retaining
    // their destination; do not replay that O(reference-count) capacity pass.
    if (route.classified.needsIntroducedImportPreparation())
        try self.session_state.prepareIntroducedImports(&introduced);

    var prepared: Preparation = undefined;
    try prepared.init(self, &route, &introduced);
    errdefer prepared.abandon(self);

    if (try commitUnsurfaced(self, &route, &prepared, body, &introduced)) {
        release(self, frame_in, parse);
        return;
    }
    surfaced = true;
    try surface(self, frame_in, parse, wire_profile, &route, &prepared, &introduced);
    if (route.callback == .bootstrap) try bootstrap_request.apply(self, route.classified.route.bootstrap);
}

/// Release a frame and its parse that no event took.
fn release(self: *Peer, frame_in: foundation.Frame, parse: events.Parse) void {
    parse.deinit(self.allocator);
    var frame = frame_in;
    frame.deinit();
}

/// Commit a route that surfaces no event, or return false for one that does.
fn commitUnsurfaced(
    self: *Peer,
    route: *Route,
    prepared: *Preparation,
    body: *const model.view.Body,
    introduced: *IntroducedImports,
) !bool {
    switch (prepared.*) {
        .pipelined => |*pipelined| {
            try pipelined.commit(self, body, introduced);
            return true;
        },
        .shortening_callback => |*callback| {
            try callback.commit(self, body, introduced);
            return true;
        },
        else => {},
    }
    switch (route.callback) {
        .retired_resolver => |resolver| {
            try self.session_state.applyValidatedInboundDeliverView(body, introduced);
            self.session_state.completeRetiredResolverCallback(resolver);
            prepared.commitRelease(self);
            return true;
        },
        .forwarding => |forwarding| {
            try commitForwardingCallback(self, forwarding, prepared, body, introduced);
            return true;
        },
        else => return false,
    }
}

/// A forwarding callback answers the forwarded reply's target with the
/// resolution it carried, or releases what it introduced when that target
/// is gone or the result breaks it. A stored result keeps the retains the
/// reply introduced, behind its hold on the rows they name.
fn commitForwardingCallback(
    self: *Peer,
    forwarding: Route.Forwarding,
    prepared: *Preparation,
    body: *const model.view.Body,
    introduced: *IntroducedImports,
) !void {
    const stores = !forwarding.discarded and !forwarding.carries_answer;
    var held = if (stores) try session.ImportRelease.prepareForIntroduced(&self.session_state, introduced.mentions.items()) else null;
    defer if (held) |batch| batch.destroy(&self.session_state);
    const reply = session.ForwardedReply.find(&self.session_state, forwarding.resolver) orelse unreachable;
    const target = reply.target;
    try self.session_state.applyValidatedInboundDeliverView(body, introduced);
    if (!stores) {
        prepared.commitRelease(self);
        if (forwarding.carries_answer)
            try copying.answerTargetView(self, target, .{ .@"break" = .{ .message = resolution_chain.reply_answer_reference_message } });
        reply.complete(&self.session_state, null);
        return;
    }
    prepared.commitShortening(self);
    try copying.answerTargetView(self, target, forwarding.carried);
    reply.complete(&self.session_state, held);
    held = null;
}

/// Queue the deliver as an event, then apply its authority. Until authority
/// applies, a refusal takes the event back; after that the frame is applied
/// and stays surfaced whatever follows. Consumes `frame_in` and `parse_in`
/// on every outcome.
fn surface(
    self: *Peer,
    frame_in: foundation.Frame,
    parse_in: events.Parse,
    wire_profile: model.CaptpVersion,
    route: *Route,
    prepared: *Preparation,
    introduced: *IntroducedImports,
) !void {
    var parse = parse_in;
    var stored = false;
    errdefer if (!stored) release(self, frame_in, parse);

    // Acquire the event's GC annotation before authority applies. The event can
    // fall back to walking its frame, but allocator refusal is still a real
    // admission failure: accepting the frame while quietly dropping derived
    // state makes memory pressure alter the observable bookkeeping path.
    var prepared_far_imports = try introduced.dupeArgumentMentions(self.allocator);
    defer if (prepared_far_imports) |positions| self.allocator.free(positions);

    const resolve: ?*const model.view.Resolve = switch (route.callback) {
        .resolver_resolve => |*callback| callback,
        else => null,
    };
    if (resolve) |callback| {
        const translated = try events.Parse.storeTranslated(self.allocator, parse.body(), .{ .resolve = callback.* });
        // The translation carries its own copy of the wire body.
        parse.deinit(self.allocator);
        parse = translated;
    }
    try inbound.pushAdmittedEvent(self, frame_in, parse, route.tag(), route.answer_override, wire_profile);
    stored = true;
    var appended = true;
    errdefer if (appended) inbound.abandonPushedEvent(self);

    const was_closed = self.session_state.state == .closed;
    if (resolve) |callback| {
        try self.session_state.applyValidatedResolverCallbackResolve(callback.*, introduced);
        self.session_state.applyPromiseSettlingFollowers(callback.answer, callback.resolution);
        self.events.backPtr().?.resolve_aliases = self.session_state.takePromiseSettlingFollowers(callback.answer);
    } else {
        const body = parse.body();
        try self.session_state.applyValidatedInboundDeliverView(body, introduced);
        self.events.backPtr().?.reference_slots = introduced.reference_slots;
        if (route.classified.resolver) |*resolver|
            resolver.commit(&self.session_state);
        if (route.callback == .node_resolver)
            self.session_state.completeNodeSettlingResolverCallback(route.callback.node_resolver);
        // The answer this deliver settles, read from the body already decoded
        // rather than by decoding the queued frame again.
        const answer_name: ?model.AnswerName = switch (route.answer_override) {
            .virtual_deliver => |answer| .fromVirtual(answer),
            else => if (body.deliver.answer) |answer| .fromWire(answer) else null,
        };
        self.events.backPtr().?.deliver_answer_target = if (answer_name) |answer|
            self.session_state.answerTargetNamed(answer)
        else
            null;
    }
    if (!was_closed and self.session_state.state == .closed) self.retireClosedSessionAuthority();
    appended = false;

    prepared.commitShortening(self);

    // Publish the pre-commit GC annotation onto the just-pushed event. Nothing
    // between the push and here can grow `self.events`, so the back pointer is
    // stable and this transfer is infallible.
    if (prepared_far_imports) |positions| {
        self.events.backPtr().?.introduced_far_imports = positions;
        prepared_far_imports = null;
    }
}
