//! Resolver authority for a pipelined call forwarded back to its sender.
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const Session = session.Session;

/// One POD purpose row in the existing resolver map, with no reverse row or
/// payload allocation. The original inline subscription owns the answer's
/// lifetime and detaches it on GC. Its stamped target survives wire-name reuse.
/// The row dies on callback, refusal, resolver GC, or session teardown. Without
/// this identity a forwarded call aliases the opposite direction's question.
pub const ForwardedReply = struct {
    resolver_export: model.ExportPosition,
    target: session.AnswerTarget,

    pub fn prepare(owner: *Session, target: session.AnswerTarget) !ForwardedReply {
        if (!targetIsLive(owner, target)) return error.InvalidReference;
        const resolver = try owner.allocateExport();
        errdefer owner.releaseUnsharedExport(resolver);
        try owner.outbound_resolver_link.put(owner.allocator, resolver, .{
            .forwarding = .{ .resolver_export = resolver, .target = target },
        });
        return .{ .resolver_export = resolver, .target = target };
    }

    pub fn targetIsLive(owner: *Session, target: session.AnswerTarget) bool {
        if (owner.answerPayloadForTarget(target) != null) return true;
        const live = owner.answerTargetNamed(target.name) orelse return false;
        return live.row_id == target.row_id;
    }

    pub fn find(owner: *const Session, resolver: model.ExportPosition) ?ForwardedReply {
        const purpose = owner.outbound_resolver_link.getByKey(resolver) orelse return null;
        return switch (purpose) {
            .forwarding => |forwarding| forwarding,
            else => null,
        };
    }

    /// Undo an unmentioned nomination or a withdrawn send whose mention was
    /// returned. No independent retain exists on the original answer payload.
    pub fn abandon(self: ForwardedReply, owner: *Session) void {
        std.debug.assert(owner.outbound_resolver_link.removeByKey(self.resolver_export));
        owner.releaseUnsharedExport(self.resolver_export);
    }

    /// Consume the prepared result's import ownership after settlement has
    /// been accepted. Attaching that lifetime and retiring this resolver are
    /// one Session commit; the engine never mutates answer payload ownership.
    pub fn complete(self: ForwardedReply, owner: *Session, imports: ?*session.ImportRelease) void {
        if (imports) |batch| {
            const payload = owner.answerPayloadForTarget(self.target) orelse unreachable;
            std.debug.assert(payload.imported_result == null);
            batch.adopt(owner);
            payload.imported_result = batch;
        }
        owner.outbound_resolver_link.replaceValueForKey(self.resolver_export, .{ .retired = .{
            .resolver_export = self.resolver_export,
            .state = .complete,
        } });
        owner.releaseRetiredResolverIfUnmentioned(self.resolver_export);
    }
};

/// GC (including rollback of an unsent mention) cannot leave an unreachable
/// forwarding export and its purpose in the table.
pub fn releaseIfUnmentioned(owner: *Session, resolver: model.ExportPosition) void {
    const reply = ForwardedReply.find(owner, resolver) orelse return;
    if (owner.exports.wireHeld(resolver) != 0) return;
    reply.abandon(owner);
}
