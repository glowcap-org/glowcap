//! Listening on a far reference we hold: our side of CapTP `op:listen`, the
//! half that does no I/O.
//!
//! A partner can hand us a promise, usually a `desc:import-promise` in a
//! fulfill that an introducing session is proxying for a third party
//! (ADR-0009). The only way to learn how that promise settles is to ask, and
//! this is the verb that asks. It nominates an export of ours as the listener,
//! and the partner delivers the notification there as an `op:deliver` carrying
//! `['fulfill|'break, payload]`. The inbound classifier reads that deliver
//! through the session's resolver-export link and surfaces it as a semantic
//! `Resolve` on the answer this verb returns (ADR-0095). A caller therefore
//! observes a listen exactly as it observes the reply to a call.

const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

/// Ask the partner to tell us how `target` settles, and return
/// the outbound answer its settlement arrives on. Register a listener on that
/// answer (the vat's far vow, a host vow) to observe it.
///
/// `target` must be a `far` this session already holds. Any other reference
/// shape is refused `InvalidReference`: a `near` names an export of ours, whose
/// settlement is ours to decide, and a `promise`, `sturdy`, or `broken` names
/// nothing a partner could notify us about. A far *object* target is legal.
/// CapTP answers a listen on a settled capability immediately, as glowcap's
/// own inbound handler does
/// (`pipeline.fireLiveObjectExportListener`).
///
/// Named cost: three POD rows in tables the session already owns, the listener
/// export, the outbound answer, and the resolver link binding them. Outbound
/// answers carry no cap because the session mints them itself. The bound is the
/// application's own outstanding listens, the same bound an unanswered call
/// has. The rows are dropped when the answer is released (`op:gc-answers`) and
/// otherwise at session teardown. A failed send rolls all three back. The send
/// itself adds no per-message heap: the listen's two references are
/// position-only and move through `send`.
pub fn listenOnFar(peer: *Peer, target: model.Reference) !session.OutboundAnswerTarget {
    const far = switch (target) {
        .far => |far| far,
        .near, .routed, .promise, .sturdy, .broken => return error.InvalidReference,
    };
    if (!peer.session_state.holdsImport(far.import_position)) return error.InvalidReference;
    const is_next_promise = peer.session_state.captp_version == .next;
    if (is_next_promise and far.kind != .promise) return error.InvalidReference;

    const nomination = try peer.session_state.nominateResolverExport();
    errdefer peer.session_state.abandonResolverNomination(nomination);
    const settling_target = peer.session_state.promiseWirePosition(far.import_position);
    if (is_next_promise and !peer.session_state.claimPromiseSettlingListener(
        settling_target,
        nomination.resolver_export,
        nomination.answer,
    ))
        return error.UnexpectedMessage;
    errdefer if (is_next_promise)
        peer.session_state.abandonPromiseSettlingListener(settling_target);

    try peer.send(.{
        .listen = .{
            .target = .{ .far = if (is_next_promise)
                model.FarRef.promise(settling_target.int())
            else
                far },
            // Project the mention from the authoritative slot rather than
            // hand-typing the kind (ADR-0080): the nomination reserved an object
            // row, and the render path reads that row.
            .listener = peer.session_state.exportReference(nomination.resolver_export).?,
            // Next already installed the one protocol-required shortening
            // listener when this remote promise arrived. This application
            // question adds only the one settling listener PR 282 permits.
            .mode = .settling_only,
        },
    });
    return peer.session_state.outboundAnswerTarget(nomination.answer) orelse unreachable;
}

/// Install the protocol-required shortening-only listener for one imported
/// remote promise. Its resolver is private session maintenance: callbacks are
/// consumed by inbound dispatch and never mint an application answer.
/// Production installs the listener through `inbound_shortening`'s prepare and
/// commit pair inside the dispatch transaction. This direct form is reached
/// only by tests that stage the listener before driving a scenario.
pub fn ensureShorteningListener(peer: *Peer, source: model.ImportPosition) !void {
    if (peer.session_state.captp_version != .next) return;
    const nomination = (try peer.session_state.nominateShorteningResolver(source)) orelse return;
    errdefer peer.session_state.abandonShorteningResolver(nomination);

    try peer.send(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(source.int()) },
        .listener = peer.session_state.exportReference(nomination.resolver_export).?,
        .mode = .shortening_only,
    } });
}
