//! Optional asynchronous restoration behind the Host's publication registry.
//! The Host borrows the provider until unregister, which must precede Host
//! destruction. The provider owns bounded pending requests and external work.
const engine = @import("engine");
const model = @import("model");
const Host = @import("host.zig").Host;
const capability = @import("capability.zig");
const pump = @import("host/pump.zig");

pub const Lookup = struct {
    pub const Admission = union(enum) { accepted, unhandled, refused: anyerror };
    context: *anyopaque,
    /// Consult the provider's authoritative work custody before unregister.
    idle: *const fn (*anyopaque) bool,
    /// Accepted transfers the request; other outcomes leave it untouched. This callback
    /// runs during ingress and may only admit work, never perform storage I/O.
    start: *const fn (*anyopaque, []const u8, Fetch) Admission,
    /// Called before a session is destroyed. Release each matching request
    /// with abandon; submitted external work keeps its separate owner lease.
    cancel: *const fn (*anyopaque, engine.PeerHandle) void,
};

pub fn install(host: *Host, lookup: *const Lookup) !void {
    try host.refuseReentry();
    try host.admitApplicationOperation();
    if (host.publication_lookup != null) return error.PublicationLookupInstalled;
    host.publication_lookup = lookup;
}

/// Provider must first settle/cancel every accepted request and join its work.
pub fn uninstall(host: *Host, lookup: *const Lookup) !void {
    try host.refuseReentry();
    if (host.publication_lookup != lookup) return error.ForeignPublicationLookup;
    if (!lookup.idle(lookup.context)) return error.Busy;
    host.publication_lookup = null;
}

/// Linear authority to settle one exact inbound fetch. No secret name is
/// retained here. A reused wire answer position cannot receive this result.
pub const Fetch = struct {
    host: ?*Host,
    peer: engine.PeerHandle,
    answer: engine.AnswerTarget,

    pub fn abandon(self: *Fetch) void {
        const host = self.host orelse return;
        const session = host.sessions.get(self.peer) orelse unreachable;
        self.host = null;
        host.finishSessionOperation(session);
    }

    /// A successful call consumes this request. Refusal leaves it retryable.
    /// The provider rechecks current publication authority before fulfillment.
    pub fn complete(self: *Fetch, result: union(enum) { found: capability.Ref, missing, failed: []const u8 }) !void {
        const host = self.host orelse return;
        try host.refuseReentry();
        const session = host.sessions.get(self.peer) orelse unreachable;
        const peer = session.served.port.peer;
        var projected: ?struct { actor: @import("actors").Ref, position: model.ExportPosition, created: bool } = null;
        const resolution: model.Resolution = switch (result) {
            .found => |ref| blk: {
                const actor = host.localActorFor(ref) orelse return error.NotLocal;
                const projection = try session.served.port.prepareProjection(&host.vat, actor);
                projected = .{ .actor = actor, .position = projection.near.export_position, .created = projection.created };
                break :blk .{ .fulfill = .{ .reference = .{ .near = projection.near } } };
            },
            .missing => .{ .@"break" = .{ .message = try host.allocator.dupe(u8, "unknown swissnum") } },
            .failed => |reason| .{ .@"break" = .{ .message = try host.allocator.dupe(u8, reason) } },
        };
        // The engine consumes the resolution on every outcome. Its stable
        // answer stamp refuses a canceled/reused answer without retargeting.
        peer.settleAnswerOwned(self.answer, resolution) catch |err| {
            if (projected) |p| if (p.created) session.served.port.rollbackExport(&host.vat, p.actor, p.position.int());
            if (err == error.InvalidReference) {
                self.abandon();
                return;
            }
            return err;
        };
        self.abandon();
        pump.markDirty(host, session.peer_handle);
        // Settlement consumed this request before callbacks can cancel the
        // provider's waiter. The Host owns encoding and committed progress.
        pump.finishCommittedWork(host, session);
    }
};

pub fn resolveFetch(context: ?*anyopaque, scope: engine.PeerHandle, request: engine.bootstrap.FetchContext) !engine.bootstrap.FetchOutcome {
    const host: *Host = @ptrCast(@alignCast(context.?));
    const session = host.sessions.get(scope) orelse return error.UnknownCapability;
    const fallback: engine.bootstrap.FetchOutcome = if (request.session_fallback) |position| .{ .found = position } else .missing;
    if (host.giftables.get(request.swissnum)) |row| {
        // A hidden reservation already owns this name: never consult storage.
        if (!row.active) return fallback;
        return .{ .found = (try session.served.port.projectActor(&host.vat, row.actor)).export_position };
    }
    if (request.session_fallback != null) return fallback;
    const lookup = host.publication_lookup orelse return .missing;
    host.admitApplicationOperation() catch |err| return .{ .refused = err };
    host.admitSessionOperation(session) catch |err| return .{ .refused = err };
    const fetch: Fetch = .{ .host = host, .peer = scope, .answer = request.answer };
    switch (lookup.start(lookup.context, request.swissnum, fetch)) {
        .unhandled => return .missing,
        .refused => |err| return .{ .refused = err },
        .accepted => {},
    }
    host.beginSessionOperation(session);
    return .deferred;
}
