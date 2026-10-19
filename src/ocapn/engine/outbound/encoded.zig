//! The row a deliver leaves the pending queue as: its frame (ADR-0064).
//!
//! Admission encodes a deliver with its inline result subscription, so the
//! queue holds one frame and what a retracted turn gives back: the near exports
//! recording retained and the answer it installed. The encoder reads the
//! tree here and nothing keeps it, so a caller that lent its values owns
//! them again when the send returns.
//!
//! The session acts on a message's references, never its values, and the
//! inventory listed every reference at admission (ADR-0064). What the row
//! keeps is that list's residue, so nothing after admission walks the tree.
//! A deliver's values may instead arrive as freight, a borrowed tree no
//! inventory walked (ADR-0064): the session certifies it here and the
//! encoder reads it, and the owned envelope carries the references.

const std = @import("std");

const codec = @import("codec");
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
/// empty owned slice `message` then carries (ADR-0064). The inventory saw
/// none of it, so the session certifies and measures it first, and the
/// producer check charges the envelope and that measure together, as it
/// charges an inventoried tree.
///
/// The inventory and the freight measure carry what the tree's values
/// encode to under the session's codec, so the encoder reads the tree once
/// (ADR-0064).
pub fn admit(self: *Peer, message: model.Message, inventory: session.Inventory, freight: ?model.view.Args) !void {
    std.debug.assert(admits(self, message));
    std.debug.assert(freight == null or (message == .deliver and message.deliver.args.len == 0));
    const freight_measure: session.Freight = if (freight) |args| try self.certifyFreight(args) else .{ .owned_bytes = 0, .wire_bytes = 0 };
    // The tree's retained bytes stand in for the frame's length, which the
    // exact reservation below takes once the frame exists.
    const charge = std.math.add(usize, try outbound.messageCharge(message, inventory), freight_measure.owned_bytes) catch
        return error.MalformedView;
    try self.admitOutboundProducer(charge);
    try self.session_state.validateSendInventoried(message, inventory);

    const answer = passable.answerProducedBy(message);
    const wants_resolver = answer != null and (message != .deliver or message.deliver.resolve_me_desc == null);
    const resolver: ?model.NearRef = if (wants_resolver)
        try self.session_state.mintMentionedResolverExport(answer.?, .object)
    else
        null;
    errdefer if (resolver) |near| self.session_state.abandonMentionedResolverExport(near.export_position);

    var wire = message;
    if (resolver) |near| wire.deliver.resolve_me_desc = .{ .near = near };
    var body = model.view.Body.fromOwned(&wire);
    if (freight) |args| body.deliver.args = args;
    const values = try valueBytes(self, &wire, inventory, freight_measure.wire_bytes);
    var frame = try self.encodeOutboundBody(&body, values);
    errdefer frame.deinit();
    const exports = try self.session_state.listSentExports(self.allocator, message, inventory);
    errdefer self.allocator.free(exports);

    const row: Encoded = .{
        .op = std.meta.activeTag(message),
        .frame = frame,
        .answer = answer,
        .resolver = if (resolver) |near| near.export_position else null,
        .exports = exports,
    };
    const reservation = try self.reservePendingCharged(row.charge(), false);
    errdefer self.cancelPendingReservation(reservation);
    try self.session_state.applyValidatedSend(message, inventory, row.resolver);
    self.pushPendingAssume(reservation, .{ .encoded = row });
}

/// What the admitted tree's values encode to under the session's codec: the
/// bytes its meter sized on the walk, each listed mention as lowering left
/// it, and the freight. Null for a codec without a meter, which sizes its
/// own frame. A value's wire bytes stay within a small factor of the bytes
/// its owned slice retains, which the admitted charge bounds, so the sum
/// cannot overflow.
fn valueBytes(self: *Peer, message: *const model.Message, inventory: session.Inventory, freight_values: usize) !?usize {
    inline for (codec.registry.active) |spec| if (self.session_state.codec == spec.id) {
        const Meter = spec.module.meter orelse return null;
        const root: ?*const model.Argument = if (message.* == .resolve and message.resolve.resolution == .fulfill)
            &message.resolve.resolution.fulfill
        else
            null;
        var total = inventory.wire_bytes + freight_values;
        for (inventory.slots) |slot| total += try Meter.mention(self.allocator, slot.read(root));
        return total;
    };
    return error.UnknownCodec;
}
