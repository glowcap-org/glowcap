//! The row a deliver leaves the pending queue as: its frame (ADR-0236).
//!
//! Admission encodes a deliver with its inline result subscription, so the
//! queue holds one frame and what a retracted turn gives back: the near exports
//! recording retained and the answer it installed. The encoder reads the
//! tree here and nothing keeps it, so a caller that lent its values owns
//! them again when the send returns.
//!
//! The session acts on a message's references, never its values, and the
//! inventory listed every reference at admission (ADR-0234). What the row
//! keeps is that list's residue, so nothing after admission walks the tree.
//! A deliver's values may instead arrive as freight, a borrowed tree no
//! inventory walked (ADR-0246): the session certifies it here and the
//! encoder reads it, and the owned envelope carries the references.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const outbound = @import("../outbound.zig");
const passable = @import("../node/passable.zig");

const Peer = engine.Peer;

pub const Encoded = struct {
    op: std.meta.Tag(model.Message),
    frame: foundation.Frame,
    answer: ?model.AnswerPosition,
    /// The resolver export minted for `answer`. V1.0 advertises it inline as
    /// `resolve_me_desc`; next also carries its listen mode inline.
    resolver: ?model.ExportPosition,
    /// The near exports recording retained, in wire order
    /// (`Session.listSentExports`).
    exports: []const model.ExportPosition,

    /// The row's admission charge: the wire bytes it holds plus its list.
    pub fn charge(self: Encoded) usize {
        return self.frame.bytes().len + self.exports.len * @sizeOf(model.ExportPosition);
    }

    /// Release a row whose frames never reached `outbound`.
    pub fn deinit(self: Encoded, peer: *Peer) void {
        var frame = self.frame;
        frame.deinit();
        self.deinitEmitted(peer);
    }

    /// Release what remains of a row whose frames moved to `outbound`.
    pub fn deinitEmitted(self: Encoded, peer: *Peer) void {
        peer.allocator.free(self.exports);
    }
};

/// Whether `message` leaves as an `Encoded` row rather than a queued tree.
pub fn admits(self: *const Peer, message: model.Message) bool {
    if (message == .deliver) return true;
    return self.session_state.captp_version == .next and passable.answerProducedBy(message) != null;
}

/// Validate, encode, reserve, record, and queue `message`, borrowing it and
/// its inventory for the call. The caller lowered and shortened the tree
/// already. A refusal keeps nothing: a malformed or oversized send is refused
/// before anything is allocated, and after that the resolver, the frames,
/// the list, and the seat return in order, with the session untouched
/// because applying the send is the last fallible step.
///
/// `freight` is a deliver's argument tree lent as views, in place of the
/// empty owned slice `message` then carries (ADR-0246). The inventory saw
/// none of it, so the session certifies and measures it first, and the
/// producer check charges the envelope and that measure together, as it
/// charges an inventoried tree.
pub fn admit(self: *Peer, message: model.Message, inventory: session.Inventory, freight: ?model.view.Args) !void {
    std.debug.assert(admits(self, message));
    std.debug.assert(freight == null or (message == .deliver and message.deliver.args.len == 0));
    const freight_bytes: usize = if (freight) |args| try self.session_state.certifyFreight(args) else 0;
    // The tree's retained bytes stand in for the frame's length, which the
    // exact reservation below takes once the frame exists.
    const charge = std.math.add(usize, try outbound.messageCharge(message, inventory), freight_bytes) catch
        return error.MalformedView;
    try self.admitOutboundProducer(charge);
    try self.session_state.validateSendInventoried(message, inventory);

    const answer = passable.answerProducedBy(message);
    const wants_resolver = answer != null and (message != .deliver or message.deliver.resolve_me_desc == null);
    const resolver: ?model.ExportPosition = if (wants_resolver)
        try self.session_state.mintMentionedResolverExport(answer.?, .object)
    else
        null;
    errdefer if (resolver) |position| self.session_state.abandonMentionedResolverExport(position);
    // Project the mention from the authoritative slot, never a hand-typed
    // kind (ADR-0080).
    const resolver_ref: ?model.Reference = if (resolver) |position|
        session.slot.toReference(self.session_state.exportSlot(position).?).?
    else
        null;

    var wire = message;
    if (resolver_ref != null) wire.deliver.resolve_me_desc = resolver_ref;
    var body = model.view.Body.fromOwned(&wire);
    if (freight) |args| body.deliver.args = args;
    var frame = try self.encodeOutboundBody(&body);
    errdefer frame.deinit();
    const exports = try self.session_state.listSentExports(self.allocator, message, inventory);
    errdefer self.allocator.free(exports);

    const row: Encoded = .{
        .op = std.meta.activeTag(message),
        .frame = frame,
        .answer = answer,
        .resolver = resolver,
        .exports = exports,
    };
    const reservation = try self.reservePendingCharged(row.charge(), false);
    errdefer self.cancelPendingReservation(reservation);
    try self.session_state.applyValidatedSend(message, inventory);
    self.pushPendingAssume(reservation, .{ .encoded = row });
}
