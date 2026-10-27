//! Forward a queued inbound call without borrowing the sender's namespaces.
//!
//! An answer reference names the question of the peer that wrote it, and
//! CapTP has no form for naming the reader's question back to it (upstream
//! issue 168). A queued call or a reply the partner wrote cannot go back to
//! the partner with one inside, so the forwarder breaks the question it
//! would have carried instead of sending a reference that would name a
//! different question on arrival.
const model = @import("model");
const session = @import("session");
const Peer = @import("mod.zig").Peer;
const maintenance = @import("inbound_shortening.zig");

fn abandonRelease(peer: *Peer, prepared: ?maintenance.PreparedOutboundMessage) void {
    if (prepared) |release| {
        peer.cancelPendingReservation(release.reservation);
        model.freeMessage(peer.allocator, release.message);
    }
}

fn prepareRelease(peer: *Peer, imports: ?[]model.ImportPosition) !?maintenance.PreparedOutboundMessage {
    const mentions = imports orelse return null;
    defer peer.allocator.free(mentions);
    var message = (try session.ImportRelease.messageForMentions(peer.allocator, mentions)) orelse return null;
    errdefer model.freeMessage(peer.allocator, message);
    const closure_len = try peer.session_state.expandShorteningGcExportReleases(peer.allocator, &message.gc_export);
    return .{ .message = message, .reservation = try peer.reservePending(.{ .message = message }), .closure_len = closure_len };
}

/// Release exact admitted argument mentions when a queued call has no local
/// event consumer. The validation record owns provenance even after shortening
/// rewrites the argument tree. Consumes the mention slice on every outcome.
pub fn releaseArguments(peer: *Peer, imports: ?[]model.ImportPosition) !void {
    if (try prepareRelease(peer, imports)) |release|
        maintenance.commitPreparedImportRelease(peer, release);
}

/// Consume a retargeted call and its exact original import mentions. The reply
/// remains the original inbound answer; our call has no wire answer and uses
/// our own resolver export. A collected baseline reply still executes the call.
pub fn send(peer: *Peer, message_in: model.Message, target: ?session.AnswerTarget, imports: ?[]model.ImportPosition) !void {
    var message = message_in;
    const release = prepareRelease(peer, imports) catch |err| {
        model.freeMessage(peer.allocator, message);
        return err;
    };
    errdefer abandonRelease(peer, release);
    // A reply rides only toward a target still waiting on it.
    const live: ?session.AnswerTarget = if (target) |answer|
        (if (session.ForwardedReply.targetIsLive(&peer.session_state, answer)) answer else null)
    else
        null;
    message.deliver.answer = null;
    message.deliver.resolve_me_desc = null;
    var reply: ?session.ForwardedReply = null;
    errdefer if (reply) |prepared| prepared.abandon(&peer.session_state);
    if (live) |answer| {
        const prepared = session.ForwardedReply.prepare(&peer.session_state, answer) catch |err| {
            model.freeMessage(peer.allocator, message);
            return err;
        };
        reply = prepared;
        message.deliver.resolve_me_desc = .{ .near = model.NearRef.object(prepared.resolver_export.int()) };
        // The original subscription decides which callbacks leave this peer.
        message.deliver.listen_mode = .shortening_or_settling;
    }
    try peer.send(message);
    if (release) |prepared| maintenance.commitPreparedImportRelease(peer, prepared);
}

/// Publish one final stored-result import release. Admission/encoding refusal
/// leaves the original batch intact for retry; accounting commits with frame
/// publication. The shared GC closure also spends retained shortening edges.
pub fn drainImportRelease(peer: *Peer) !bool {
    if (peer.sessionIsClosed()) return false;
    const outbox = peer.session_state.import_release_outbox orelse return false;
    const batch = outbox.head orelse return false;
    try peer.checkOutboundWaterline();
    var message = try model.cloneMessage(peer.allocator, .{ .gc_export = batch.release });
    defer model.freeMessage(peer.allocator, message);
    _ = try peer.session_state.expandSessionGcExportReleases(peer.allocator, &message.gc_export);
    var frame = try peer.encodeOutbound(message);
    errdefer frame.deinit();
    try peer.admitOutboundProducer(frame.bytes().len);
    try peer.ensureOutboundCapacity(1);
    peer.session_state.recordSessionImportRelease(message.gc_export);
    peer.outbound.pushAssumeCapacity(frame);
    outbox.removeHead(&peer.session_state);
    return true;
}
