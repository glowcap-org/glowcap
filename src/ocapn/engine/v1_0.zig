//! The OCapN V1.0 resolver-callback translation (ADR-0006), end to end.
//!
//! OCapN V1.0 has no wire `op:resolve`. A promise settles through a *resolver
//! capability* instead. On the way out, admission mints the resolver export
//! an answered `op:deliver` advertises as `resolve_me_desc` and commits the
//! answer-to-export link in the session (`outbound/encoded.zig`, the same
//! mint next advertises inline). This file holds the rest of the
//! round trip. A projection's listener is prepared here at emission. On the way back,
//! `session.deliver_resolver` prepares the partner's advertised resolver as our
//! import, so our eventual resolution has somewhere to go. Recognizing a
//! deliver *to* one of our resolver exports is version-neutral and belongs to
//! the inbound classifier (ADR-0003). Our side of that settlement is
//! `encodeResolutionAsCallback`, which
//! renders a semantic resolution as the `['fulfill|'break, payload]` deliver the
//! partner's resolver import expects. The functions take a `*Peer` and mutate
//! session authority through it, as the names say, like the engine's
//! `pipeline` half.

const model = @import("model");

const engine = @import("mod.zig");
const resolution_math = @import("pipeline_resolution.zig");
const Peer = engine.Peer;

/// A V1.0 wire message whose synthesized resolver mention has been installed
/// in authoritative session state but has not reached the outbound queue yet. status-allow: pending state or quoted runtime label
/// The encode owner must call `abandon` on every failure before publication.
/// Once the frame is queued, the partner owns the mention and the preparation
/// is committed by doing nothing.
pub const PreparedMessage = struct {
    message: model.Message,
    resolver_export: ?model.ExportPosition = null,

    pub fn abandon(self: PreparedMessage, peer: *Peer) void {
        if (self.resolver_export) |resolver_export|
            peer.session_state.abandonMentionedResolverExport(resolver_export);
    }
};

/// Install the V1.0 carrier for a projection's resolution. A projection
/// (`op:get`/`op:index`/`op:untag`) opens a new answer, but V1.0 has no wire
/// `op:resolve` to push that answer's resolution back, and the projection ops
/// carry no inline `resolve_me_desc` slot the way `op:deliver` does. So once
/// the projection has shipped, the sender installs a listener on the projected
/// answer pointed at a synthesized resolver export: when the partner settles
/// the projection it fires the listener as a `['fulfill|'break, …]` deliver to
/// that export, which the inbound classifier recognizes and surfaces back as
/// a semantic `Resolve` for the projected answer, the same round trip an
/// answered deliver earns, carried on a separate `op:listen` frame. The
/// `op:listen` must reach the wire *after* the projection that opened the
/// answer. The caller orders the two pushes. V1.0 sessions only: the caller
/// gates on `Session.needsV1_0Translation`. Returns null when explicit release
/// retired the projected answer before deferred encoding reached this step.
pub fn prepareProjectionListener(peer: *Peer, projected_answer: model.AnswerPosition) !?PreparedMessage {
    if (peer.session_state.outboundAnswer(projected_answer) == null) return null;
    // Mint the resolver export and commit its answer link and wire-delta retain
    // through the session's single accounting seam, then carry the mention on
    // `op:listen`.
    const resolver = try peer.session_state.mintOutboundResolver(projected_answer);
    return .{
        .message = .{
            .listen = .{
                .target = .{ .promise = .{ .answer_position = projected_answer } },
                // The mint projects the listener from the cell it registered (ADR-0006).
                .listener = .{ .near = resolver },
                .mode = .settling_only,
            },
        },
        .resolver_export = resolver.export_position,
    };
}

/// Encode a semantic `Resolve` as its V1.0 resolver-callback `op:deliver`
/// (ADR-0006), addressed to the partner's resolver import recorded when their
/// augmented deliver arrived. The callback and the `op:gc-exports` that releases
/// its one-shot resolver import publish as one adjacent pair. The
/// resolution becomes `['fulfill, payload]` or `['break, reason-symbol]` args.
/// Both borrow `resolve` for the encode call. The break reason rides as a bare
/// Symbol, the same payload shape the listener fire uses, because Goblins'
/// unmarshal table has no `<error …>` record: an unknown record tag raises
/// `captp-unknown-record-rag` on the partner and the break is lost (the
/// `<error>` record stays next / `.error`-argument vocabulary, which never
/// reaches this path).
pub fn encodeResolutionAsCallback(
    peer: *Peer,
    resolution: model.Resolution,
    resolver_import: model.ImportPosition,
) !void {
    var args = resolution_math.callbackArgs(resolution);
    const wire: model.Message = .{
        .deliver = .{
            // A far import carries no wire kind, `desc:export` names it regardless,
            // and the `Slot` sum makes remote-mint value object-only
            // (ADR-0006).
            .target = .{ .far = .{ .import_position = resolver_import } },
            .args = &args,
            .answer = null,
            .resolve_me_desc = null,
        },
    };
    if (!peer.session_state.importRequiresWireRelease(resolver_import))
        return peer.pushEncodedFromPending(wire);
    const positions = [_]u64{resolver_import.int()};
    const deltas = [_]u64{1};
    const release: model.Message = .{ .gc_export = .{
        .positions = &positions,
        .deltas = &deltas,
    } };
    try peer.pushEncodedPairFromPending(
        wire,
        release,
        .session_release_at_commit,
    );
}
