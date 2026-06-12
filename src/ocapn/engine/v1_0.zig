//! The Goblins V1.0 resolver-callback translation (ADR-0010), end to end.
//!
//! OCapN V1.0 has no wire `op:resolve`; a promise settles through a *resolver
//! capability* instead. The round trip lives in this one file. On the way out,
//! `installResolverForOutboundDeliver` augments an answered `op:deliver` with a
//! synthesized resolver export advertised as `resolve_me_desc`, committing the
//! answer-to-export link in the session. On the way back,
//! `interceptInboundDeliver` recognizes a deliver to one of those resolver
//! exports as the partner settling our answer (and installs the partner's own
//! advertised resolver as our import, so our eventual resolution has somewhere
//! to go). Our side of that settlement is `encodeResolveAsCallback`, which
//! renders a semantic `Resolve` as the `['fulfill|'break, payload]` deliver the
//! partner's resolver import expects. The functions take a `*Peer` and mutate
//! session authority through it — the names say so — exactly like the engine's
//! `pipeline` half.

const codec = @import("codec");
const model = @import("model");

const engine = @import("mod.zig");
const Peer = engine.Peer;

/// Augment an outbound answered `op:deliver` with a synthesized V1.0 resolver
/// export, *committing session authority*: the resolver export is minted, the
/// answer-to-export link is installed, and the export takes the wire-delta
/// retain its on-wire mention requires. A deliver with no answer, or one that
/// already carries a `resolve_me_desc`, passes through untouched. The returned
/// message borrows `deliver`'s heap; the caller's ownership of the original
/// message is unchanged. V1.0 sessions only — the caller gates on
/// `Session.needsV1_0Translation`.
pub fn installResolverForOutboundDeliver(peer: *Peer, deliver: model.Deliver) !model.Message {
    if (deliver.answer == null or deliver.resolve_me_desc != null) {
        return .{ .deliver = deliver };
    }
    // Synthesize a promise-shaped resolver export and commit the
    // answer→export link so the partner's subsequent resolver-callback
    // deliver translates back into a semantic `Resolve`.
    const resolver_export = try peer.session_state.allocateExport();
    try peer.session_state.installOutboundResolver(deliver.answer.?, resolver_export);
    // The resolver mention goes on the wire below, bypassing
    // `recordSend` (encode-time augmentation), so it must take the
    // same wire-delta retain `retainSentExports` would have added.
    // Without it the partner's matching `op:gc-exports` delta drives
    // the count to zero and removes the export row while
    // `v1_0_outbound_resolvers` still points at it.
    try peer.session_state.retainSentExportRef(.{ .near = model.NearRef.promise(resolver_export) });
    return .{
        .deliver = .{
            .target = deliver.target,
            .args = deliver.args,
            .answer = deliver.answer,
            .resolve_me_desc = .{ .near = model.NearRef.promise(resolver_export) },
        },
    };
}

/// Encode a semantic `Resolve` as its V1.0 resolver-callback `op:deliver`
/// (ADR-0010), addressed to the partner's resolver import recorded when their
/// augmented deliver arrived, and push the frame onto `peer.outbound`. The
/// resolution becomes `['fulfill, payload]` or `['break, reason-symbol]` args;
/// both borrow `resolve` for the encode call. The break reason rides as a bare
/// Symbol — the same payload shape the listener fire uses — because Goblins'
/// unmarshal table has no `<error …>` record: an unknown record tag raises
/// `captp-unknown-record-rag` on the partner and the break is lost (the
/// `<error>` record stays PreSpec / `.error`-argument vocabulary, which never
/// reaches this path).
pub fn encodeResolveAsCallback(peer: *Peer, resolve: model.Resolve) !void {
    const resolver_import = peer.session_state.resolverForInboundAnswer(resolve.answer) orelse
        return error.MissingV1_0Resolver;
    var args: [2]model.Argument = switch (resolve.resolution) {
        .fulfill => |value| .{ .{ .symbol = "fulfill" }, value },
        .@"break" => |err| .{ .{ .symbol = "break" }, .{ .symbol = err.message } },
    };
    const wire: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(resolver_import) },
        .args = &args,
        .answer = null,
        .resolve_me_desc = null,
    } };
    var frame = try codec.dispatch.encodeMessageForProfile(
        peer.session_state.codec,
        peer.allocator,
        peer.session_state.wire_profile,
        wire,
    );
    errdefer frame.deinit();
    try peer.outbound.push(peer.allocator, frame);
}

/// Intercept an inbound V1.0 deliver. Returns the answer a resolver-callback
/// settles — the caller surfaces a semantic `Resolve` — or null for an
/// ordinary deliver, first *installing session authority* for the partner's
/// advertised resolver: a `resolve_me_desc` registers the resolver import
/// (allocating and installing a virtual inbound answer when the deliver
/// carries no wire answer-position, the V1.0 resolver-only fetch pattern).
pub fn interceptInboundDeliver(peer: *Peer, deliver: model.view.Deliver) !?u64 {
    if (deliver.target.exportPosition()) |position| {
        if (peer.session_state.answerForResolverExport(position)) |answer| {
            return answer;
        }
    }
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
                // here would leave `v1_0_inbound_resolvers` referencing a
                // virtual answer absent from `inbound_answers`, breaking the
                // authoritative-state invariant on OOM.
                try peer.session_state.installInboundAnswer(virtual);
                break :blk virtual;
            };
            try peer.session_state.installInboundResolver(answer, import_position);
        }
    }
    return null;
}
