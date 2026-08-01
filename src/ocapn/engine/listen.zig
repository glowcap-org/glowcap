//! Listening on a promise we hold: our side of CapTP `op:listen`, the half
//! that does no I/O.
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

/// Ask the partner to tell us how the promise at `target` settles, and return
/// the outbound answer its settlement arrives on. Register a listener on that
/// answer (the vat's far vow, a host vow) to observe it.
///
/// `target` must be a `far` this session already holds. Any other reference
/// shape is refused `InvalidReference`: a `near` names an export of ours, whose
/// settlement is ours to decide, and a `promise`, `sturdy`, or `broken` names
/// nothing a partner could notify us about. A far *object* target is legal.
/// CapTP answers a listen on a settled capability immediately, which is what
/// pancake's own inbound handler does
/// (`pipeline.fireLiveObjectExportListener`).
///
/// Named cost: three POD rows in tables the session already owns — the listener
/// export, the outbound answer, and the resolver link binding them. Outbound
/// answers carry no cap because the session mints them itself; the bound is the
/// application's own outstanding listens, the same bound an unanswered call
/// has. The rows are dropped when the answer is released (`op:gc-answers`) and
/// otherwise at session teardown; a failed send rolls all three back. The send
/// itself adds no per-message heap: `sendCopying` clones an `op:listen`'s two
/// references, and both are position-only.
pub fn listenOnPromise(peer: *Peer, target: model.Reference) !model.AnswerPosition {
    const far = switch (target) {
        .far => |far| far,
        .near, .promise, .sturdy, .broken => return session.Error.InvalidReference,
    };
    if (!peer.session_state.holdsImport(far.import_position)) return session.Error.InvalidReference;

    const nomination = try peer.session_state.nominateResolverExport();
    errdefer peer.session_state.abandonResolverNomination(nomination);

    try peer.sendCopying(.{
        .listen = .{
            .target = target,
            // Project the mention from the authoritative slot rather than
            // hand-typing the kind (ADR-0080): the nomination reserved an object
            // row, and the render path reads that row.
            .listener = session.slot.toReference(peer.session_state.exportSlot(nomination.resolver_export).?).?,
            .wants_partial = false,
        },
    });
    return nomination.answer;
}
