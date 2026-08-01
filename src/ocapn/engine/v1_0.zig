//! The OCapN V1.0 resolver-callback translation (ADR-0010), end to end.
//!
//! OCapN V1.0 has no wire `op:resolve`; a promise settles through a *resolver
//! capability* instead. The round trip lives in this one file. On the way out,
//! `installResolverForOutboundDeliver` augments an answered `op:deliver` with a
//! synthesized resolver export advertised as `resolve_me_desc`, committing the
//! answer-to-export link in the session. On the way back,
//! `registerPartnerResolver` installs the partner's own advertised resolver as
//! our import, so our eventual resolution has somewhere to go; recognizing a
//! deliver *to* one of our resolver exports is version-neutral and belongs to
//! the inbound classifier (ADR-0095). Our side of that settlement is
//! `encodeResolveAsCallback`, which
//! renders a semantic `Resolve` as the `['fulfill|'break, payload]` deliver the
//! partner's resolver import expects. The functions take a `*Peer` and mutate
//! session authority through it — the names say so — exactly like the engine's
//! `pipeline` half.

const model = @import("model");
const session_mod = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

/// Augment an outbound answered `op:deliver` with a synthesized V1.0 resolver
/// export, *committing session authority*: the resolver export is minted, the
/// answer-to-export link is installed, and the export takes the wire-delta
/// retain its on-wire mention requires. A deliver with no answer, or one that
/// already carries a `resolve_me_desc`, passes through untouched. The returned
/// message borrows `deliver`'s heap; the caller's ownership of the original
/// message is unchanged. V1.0 sessions only, the caller gates on
/// `Session.needsV1_0Translation`.
pub fn installResolverForOutboundDeliver(peer: *Peer, deliver: model.Deliver) !model.Message {
    if (deliver.answer == null or deliver.resolve_me_desc != null) {
        return .{ .deliver = deliver };
    }
    // Synthesize a promise-shaped resolver export and commit the
    // answer→export link (plus the wire-delta retain its on-wire mention
    // needs) through the session's single accounting seam, so the partner's
    // subsequent resolver-callback deliver translates back into a semantic
    // `Resolve`.
    const resolver_export = try peer.session_state.mintOutboundResolver(deliver.answer.?);
    return .{
        .deliver = .{
            .target = deliver.target,
            .args = deliver.args,
            .answer = deliver.answer,
            // Project the mention from the authoritative slot (the resolver was
            // minted `local_unresolved`), never a hand-typed kind (ADR-0080).
            .resolve_me_desc = session_mod.slot.toReference(peer.session_state.exportSlot(resolver_export).?).?,
        },
    };
}

/// Install the V1.0 carrier for a projection's resolution. A projection
/// (`op:get`/`op:index`/`op:untag`) opens a new answer, but V1.0 has no wire
/// `op:resolve` to push that answer's resolution back, and the projection ops
/// carry no inline `resolve_me_desc` slot the way `op:deliver` does. So once
/// the projection has shipped, the sender installs a listener on the projected
/// answer pointed at a synthesized resolver export: when the partner settles
/// the projection it fires the listener as a `['fulfill|'break, …]` deliver to
/// that export, which the inbound classifier recognizes and surfaces back as
/// a semantic `Resolve` for the projected answer — the same round trip an
/// answered deliver earns, carried on a separate `op:listen` frame. The
/// `op:listen` must reach the wire *after* the projection that opened the
/// answer; the caller orders the two pushes. V1.0 sessions only — the caller
/// gates on `Session.needsV1_0Translation`.
pub fn installListenerForOutboundProjection(peer: *Peer, projected_answer: model.AnswerPosition) !void {
    // Mint the resolver export and commit its answer link and wire-delta retain
    // through the session's single accounting seam (see
    // `installResolverForOutboundDeliver`), then carry the mention on `op:listen`.
    const resolver_export = try peer.session_state.mintOutboundResolver(projected_answer);
    const wire: model.Message = .{
        .listen = .{
            .target = .{ .promise = .{ .answer_position = projected_answer } },
            // Project from the authoritative slot, never a hand-typed kind (ADR-0080).
            .listener = session_mod.slot.toReference(peer.session_state.exportSlot(resolver_export).?).?,
            .wants_partial = false,
        },
    };
    try peer.pushEncoded(wire);
}

/// Encode a semantic `Resolve` as its V1.0 resolver-callback `op:deliver`
/// (ADR-0010), addressed to the partner's resolver import recorded when their
/// augmented deliver arrived, and push the frame onto `peer.outbound`. The
/// resolution becomes `['fulfill, payload]` or `['break, reason-symbol]` args;
/// both borrow `resolve` for the encode call. The break reason rides as a bare
/// Symbol — the same payload shape the listener fire uses — because Goblins'
/// unmarshal table has no `<error …>` record: an unknown record tag raises
/// `captp-unknown-record-rag` on the partner and the break is lost (the
/// `<error>` record stays next / `.error`-argument vocabulary, which never
/// reaches this path).
pub fn encodeResolveAsCallback(peer: *Peer, resolve: model.Resolve, resolver_import: model.ImportPosition) !void {
    var args: [2]model.Argument = switch (resolve.resolution) {
        .fulfill => |value| .{ .{ .symbol = "fulfill" }, value },
        .@"break" => |err| .{ .{ .symbol = "break" }, .{ .symbol = err.message } },
    };
    const wire: model.Message = .{
        .deliver = .{
            // A far import carries no wire kind — `desc:export` names it regardless
            // (ADR-0010), and the `Slot` sum makes remote-mint value object-only
            // (ADR-0080). The old `.kind = .promise` here was dead and misleading.
            .target = .{ .far = .{ .import_position = resolver_import } },
            .args = &args,
            .answer = null,
            .resolve_me_desc = null,
        },
    };
    try peer.pushEncoded(wire);
}

/// Register the resolver the partner advertised on an inbound V1.0 deliver,
/// *installing session authority*: a `resolve_me_desc` registers the resolver
/// import, allocating and installing a virtual inbound answer when the deliver
/// carries no wire answer-position (the V1.0 resolver-only call pattern).
///
/// Returns that virtual answer when one was allocated, so the surfaced deliver
/// can carry it and the application's reply routes back through the resolver
/// callback. Null when the deliver already carried a wire answer (the frame has
/// it) or advertised no resolver at all.
///
/// The other half of the V1.0 round trip — recognizing a deliver *to* one of
/// our resolver exports — is version-neutral and lives in the inbound
/// classifier (`engine.inbound.classifyInboundDeliver`, ADR-0095).
pub fn registerPartnerResolver(peer: *Peer, deliver: model.view.Deliver) !?model.AnswerPosition {
    if (deliver.resolve_me_desc) |rmd| {
        if (rmd.position()) |import_position| {
            // V1.0 resolver: the partner introduces their resolver export as
            // our import. Use the deliver's answer if present; otherwise
            // allocate a fresh virtual answer (the V1.0 fetch-with-resolver
            // pattern the OCapN suite uses: no answer-position on the wire,
            // only a resolve-me-desc).
            const answer = deliver.answer orelse blk: {
                const virtual = peer.session_state.allocateInboundAnswer();
                // Install before the resolver row below: a swallowed failure
                // here would leave `v1_0_inbound_resolver_link` referencing a
                // virtual answer absent from `inbound_answers`, breaking the
                // authoritative-state invariant on OOM.
                try peer.session_state.installInboundAnswer(virtual);
                break :blk virtual;
            };
            try peer.session_state.installInboundResolver(answer, model.ImportPosition.from(import_position));
            // A resolver-only deliver (no wire answer) surfaces with the virtual
            // answer so the application's reply has a target; a deliver that
            // already carried a wire answer surfaces unchanged.
            if (deliver.answer == null) return answer;
        }
    }
    return null;
}
