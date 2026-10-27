//! Resolver authority for a pipelined call forwarded back to its sender.
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const Session = session.Session;

/// A forwarding purpose on the resolver's export row, with no payload
/// allocation. The original inline subscription owns the answer's lifetime
/// and detaches it on GC. Its stamped target survives wire-name reuse. The
/// purpose dies on callback, refusal, resolver GC, or session teardown.
/// Without this identity a forwarded call aliases the opposite direction's
/// question.
pub const ForwardedReply = struct {
    resolver_export: model.ExportPosition,
    target: session.AnswerTarget,

    pub fn prepare(owner: *Session, target: session.AnswerTarget) !ForwardedReply {
        if (!targetIsLive(owner, target)) return error.InvalidReference;
        const resolver = try owner.allocateExport();
        owner.exports.setPurpose(resolver, .{ .forwarding = target });
        return .{ .resolver_export = resolver, .target = target };
    }

    pub fn targetIsLive(owner: *Session, target: session.AnswerTarget) bool {
        if (owner.answerPayloadForTarget(target) != null) return true;
        const live = owner.answerTargetNamed(target.name) orelse return false;
        return live.row_id == target.row_id;
    }

    pub fn find(owner: *const Session, resolver: model.ExportPosition) ?ForwardedReply {
        const purpose = owner.exports.purpose(resolver) orelse return null;
        return switch (purpose) {
            .forwarding => |target| .{ .resolver_export = resolver, .target = target },
            else => null,
        };
    }

    /// Undo an unmentioned nomination or a withdrawn send whose mention was
    /// returned. No independent retain exists on the original answer payload.
    pub fn abandon(self: ForwardedReply, owner: *Session) void {
        std.debug.assert(owner.exports.clearPurpose(self.resolver_export) != null);
        owner.releaseUnsharedExport(self.resolver_export);
    }

    /// Retire this resolver once the carried result is stored, and give the
    /// stored resolution the retains the result introduced (`owned`), which
    /// have no caller: they leave with the resolution, behind its hold on the
    /// same rows. One Session commit; the engine never mutates answer payload
    /// ownership.
    pub fn complete(self: ForwardedReply, owner: *Session, owned: ?*session.ImportRelease) void {
        if (owned) |batch| {
            const payload = owner.answerPayloadForTarget(self.target) orelse unreachable;
            if (payload.held_imports) |holds| {
                std.debug.assert(holds.chained == null);
                holds.chained = batch;
            } else {
                payload.held_imports = batch;
            }
            batch.take(owner);
        }
        _ = owner.exports.replacePurpose(self.resolver_export, .{ .retired = .{ .state = .complete } });
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
