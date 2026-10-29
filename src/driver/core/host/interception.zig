//! Host policy between decoded CapTP events and the application Vat.
//!
//! This internal owner handles the complete interception transaction: session
//! handshake policy, signed-give redemption, withdraw resolution claims, and
//! proxy-listener projection. The supported hooks remain direct aliases on
//! `Host`. This module is not a consumer namespace.

const std = @import("std");

const foundation = @import("foundation");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const served_mod = @import("../served.zig");
const sessions = @import("../sessions.zig");
const value_mod = @import("../value.zig");
const crossed_hellos = @import("../crossed_hellos.zig");
const capability_lower = @import("capabilities/lower.zig");

/// Bound on the backing a proxy fan-out's recipient arena keeps between
/// recipients of one fire. A larger staging is released at the next reset.
const steady_proxy_recipient_arena_bytes = 4096;

const Host = host_mod.Host;
const HostError = host_mod.HostError;
const HostSession = host_mod.HostSession;
const Served = served_mod.Served;

fn redeemOutcome(resolve: model.view.Resolve) engine.Node.RedeemOutcome {
    return switch (resolve.resolution) {
        .fulfill => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far| .{ .far = far.import_position.int() },
                else => .not_capability,
            },
            else => .not_capability,
        },
        .@"break" => |b| .{ .broken = b.message },
    };
}

fn interceptFulfilled(
    node: *engine.Node,
    peer_handle: engine.PeerHandle,
    answer: engine.AnswerTarget,
    fulfilled: model.view.Argument,
) !actors.InterceptOutcome {
    if (fulfilled != .reference) return .{ .resolve = fulfilled };
    const reference = fulfilled.reference;
    if (reference == .routed) {
        const route_id = reference.routed.id;
        if (try node.proxyForeignPromiseFulfill(peer_handle, route_id)) |proxy|
            return .{ .resolve = .{ .reference = model.view.Reference.fromOwned(&proxy) } };
        if (try node.interceptFulfilledRouteNamed(peer_handle, answer, route_id))
            return .claimed;
        return .{ .resolve = fulfilled };
    }

    const far = if (reference == .far) reference.far else return .{ .resolve = fulfilled };
    // A plain far reply must belong to this session. Otherwise the application
    // bypassed Host identity and the Node has no home from which to gift it.
    if (node.peer(peer_handle)) |home_peer| {
        if (!home_peer.session_state.holdsImport(far.import_position))
            return error.ForeignArgument;
    }
    return .{ .resolve = fulfilled };
}

pub fn interceptFulfilledReference(
    self: *Host,
    session: *HostSession,
    answer: engine.AnswerTarget,
    reference: model.Reference,
) !actors.InterceptOutcome {
    return interceptFulfilled(&self.node, session.peer_handle, answer, .{ .reference = model.view.Reference.fromOwned(&reference) });
}

/// Everything the Host's before-serve hook can refuse, spelled from its steps
/// because `Served` names the hook's type before the hook exists.
pub const BeforeServeError = error{MissingAdvertisedLocator} ||
    model.view.ProjectError ||
    crossed_hellos.TiebreakError ||
    sessions.DuplicatePartnerError ||
    foundation.error_sets.Of(engine.Peer.answerDeferredHello) ||
    ProxyFireClaimError ||
    foundation.error_sets.Of(engine.handoff_recipient.projectGiveForRedeem) ||
    foundation.error_sets.Of(engine.Node.acceptGive) ||
    foundation.error_sets.Of(engine.Node.claimResolve);

/// The before-serve hook `sessions.zig` installs on every Host CapTP session.
pub fn hostBeforeServe(ctx: ?*anyopaque, served: *Served, event: *engine.Event) BeforeServeError!bool {
    _ = served;
    const session: *HostSession = @ptrCast(@alignCast(ctx.?));
    const host = session.host;
    const body = event.view();
    // Every event notices a just-opened session. Every deliver reports its
    // selector, including absence, using the actor layer's one splitter.
    host.traceNoteOpen(session);
    if (host.trace_sink != null and body.* == .deliver) {
        const delivery = try actors.Delivery.fromArgs(body.deliver.args);
        host.traceMessage(session, false, delivery.verb, event.bytes());
    }
    if (body.* == .start_session) {
        if (session.role == .accepted)
            try crossed_hellos.tiebreakInbound(host, session, body.start_session);
        try sessions.refuseDuplicatePartnerKey(host, session, body.start_session);
        // A duplicate/tiebreak loser must not learn the partner key or open on
        // the same feed turn.
        if (session.isTerminating()) return true;
        // Onion accepts defer their hello until the initiator's profile arrives
        // (ADR-0042); other transports have already sent theirs.
        if (session.role == .accepted and
            !session.served.port.peer.session_state.handshake_local_sent)
        {
            const advertised = host.node.acceptableLocator() orelse
                return error.MissingAdvertisedLocator;
            var secret = session.sessionSecret();
            defer std.crypto.secureZero(u8, std.mem.asBytes(&secret));
            try session.served.port.peer.answerDeferredHello(body.start_session, advertised, secret);
        }
        return false;
    }
    // A home-session listen fire for a re-exported foreign promise is Node
    // choreography, not a Vat deliver.
    if (try claimProxyListenerFire(host, session.peer_handle, event)) {
        // A converged subscription may also carry application answer aliases.
        if (body.* != .resolve) return true;
    }
    if (body.* != .resolve) {
        switch (body.*) {
            .deliver, .listen, .get, .index, .untag => host.node.exporterApplicationOwned(session.peer_handle),
            .resolve, .gc_export, .gc_answer, .start_session, .abort => {},
        }
        return false;
    }
    const resolve = body.resolve;
    if (resolve.resolution == .fulfill) {
        const value = resolve.resolution.fulfill;
        const handoff: ?model.view.Handoff = if (value == .handoff) try value.handoff.project() else null;
        if (handoff != null and handoff.? == .give) {
            var projected = try engine.handoff_recipient.projectGiveForRedeem(
                host.allocator,
                handoff.?.give,
            );
            defer projected.deinit(host.allocator);
            // Projection failure still claims: acceptGive breaks the answer
            // rather than exposing a raw give the Vat cannot settle.
            const locator = switch (projected.locator) {
                .uri => |uri| uri,
                .absent, .malformed => "",
            };
            try host.node.acceptGive(
                session.peer_handle,
                event.resolveTarget(),
                projected.bytes() orelse "",
                locator,
            );
            return true;
        }
    }
    const claimed = try host.node.claimResolve(
        session.peer_handle,
        event.resolveTarget(),
        redeemOutcome(resolve),
    );
    if (!claimed) host.node.exporterApplicationOwned(session.peer_handle);
    return claimed;
}

/// The reply interceptor `sessions.zig` installs on every Host CapTP session.
pub fn hostResolveInterceptor(
    ctx: ?*anyopaque,
    answer: engine.AnswerTarget,
    fulfilled: model.view.Argument,
) anyerror!actors.InterceptOutcome {
    const session: *HostSession = @ptrCast(@alignCast(ctx.?));
    return interceptFulfilled(&session.host.node, session.peer_handle, answer, fulfilled);
}

/// Claim a proxy home-listener delivery. The ordinary miss path only peeks.
/// Materialization and application projection happen after the exact export has
/// been identified.
const ProxyFireClaimError = error{ UnexpectedMessage, UnknownConnection } ||
    std.mem.Allocator.Error ||
    foundation.error_sets.Of(engine.Node.claimProjectedProxyListenerFire) ||
    foundation.error_sets.Of(model.view.Resolution.toOwned);

fn claimProxyListenerFire(host: *Host, peer_handle: engine.PeerHandle, event: *const engine.Event) ProxyFireClaimError!bool {
    const body = event.wireView();
    if (body.* != .deliver) return false;
    const deliver = body.deliver;
    const export_pos = switch (deliver.target) {
        .near => |near| near.export_position.int(),
        else => return false,
    };
    if (!host.node.isProxyHomeListener(peer_handle, export_pos)) return false;
    // Malformed use of a legitimately held export is a session-state
    // violation, not a codec malformation.
    const view_res = engine.events.resolutionFromResolverCallback(deliver.args) catch
        return error.UnexpectedMessage;
    switch (view_res) {
        .@"break" => return try host.node.claimProjectedProxyListenerFire(
            host.allocator,
            peer_handle,
            export_pos,
            view_res,
        ),
        .fulfill => {},
    }

    const session = host.sessions.get(peer_handle) orelse return error.UnknownConnection;
    const owned = try view_res.toOwned(host.allocator);
    defer model.freeResolution(host.allocator, owned);
    var arena_state = std.heap.ArenaAllocator.init(host.allocator);
    defer arena_state.deinit();
    const value = host.projectValue(
        session,
        arena_state.allocator(),
        owned.fulfill,
        {},
        struct {
            fn project(_: void, projected: value_mod.Value) !value_mod.Value {
                return projected;
            }
        }.project,
    ) catch {
        std.debug.assert(host.node.breakProxyListenerFire(peer_handle, export_pos));
        return true;
    };
    defer capability_lower.releaseValueCapabilitiesTerminalAt(host, &.{value}, null);

    // One arena serves every recipient of this fire, reset between them:
    // each recipient's staging dies before the next begins, so the walk pays
    // one backing allocation rather than one per recipient, and a fire at
    // `Node.max_proxy_recipients` cannot turn into a thousand page churns.
    // `arena_state` above is not reusable here because `value` lives in it.
    var recipient_arena = std.heap.ArenaAllocator.init(host.allocator);
    defer recipient_arena.deinit();
    const Projection = struct {
        host: *Host,
        value: *const value_mod.Value,
        arena: *std.heap.ArenaAllocator,

        fn recipient(context: *@This(), relay: *engine.Node.RelayRecipient) void {
            // Every refusal below is best-effort toward this one recipient:
            // until `adopt` clears it, the recipient's reserved terminal break
            // stays armed, and the fire walk delivers that break to any
            // recipient left unadopted. The other recipients are unaffected.
            const recipient_session = context.host.sessions.get(relay.peerHandle()) orelse return;
            _ = context.arena.reset(.{ .retain_with_limit = steady_proxy_recipient_arena_bytes });
            const allocator = context.arena.allocator();
            const values = [_]value_mod.Value{context.value.*};
            var prepared = capability_lower.prepareValues(
                context.host,
                recipient_session,
                allocator,
                &values,
            ) catch return; // best-effort: the armed terminal break fires instead
            defer prepared.deinit();
            prepared.beginStaging();
            const adopted = relay.adopt(.{ .fulfill = prepared.values[0] });
            prepared.endStaging();
            if (adopted) _ = prepared.commit();
        }
    };
    var projection: Projection = .{ .host = host, .value = &value, .arena = &recipient_arena };
    std.debug.assert(host.node.projectProxyListenerFire(
        peer_handle,
        export_pos,
        &projection,
        Projection.recipient,
    ));
    return true;
}
