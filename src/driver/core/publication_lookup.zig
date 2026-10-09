//! Optional asynchronous restoration behind the Host's publication registry.
//! The Host borrows the provider until unregister, which must precede Host
//! destruction. The provider owns bounded pending requests and external work.
const engine = @import("engine");
const model = @import("model");
const Host = @import("host.zig").Host;
const capability = @import("capability.zig");
const pump = @import("host/pump.zig");
const Recipient = @import("enliven/observation.zig").Recipient;

pub const Lookup = struct {
    pub const Admission = union(enum) { accepted, unhandled, refused: anyerror };
    pub const Cancellation = union(enum) { origin: Fetch.Origin, local_shutdown: []const u8 };
    context: *anyopaque,
    /// Consult the provider's authoritative work custody before unregister.
    idle: *const fn (*anyopaque) bool,
    /// Accepted transfers the request; other outcomes leave it untouched. This callback
    /// runs during ingress and may only admit work, never perform storage I/O.
    start: *const fn (*anyopaque, []const u8, Fetch) Admission,
    /// Exact observer/session cancellation abandons matching requests. Host
    /// shutdown closes local recipients. Submitted work keeps its owner lease.
    cancel: *const fn (*anyopaque, Cancellation) void,
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
    destination: union(enum) {
        wire: struct { peer: engine.PeerHandle, answer: engine.AnswerTarget },
        local: struct { id: u64, recipient: Recipient, lifetime: Host.PendingWorkLease },
    },

    pub const Origin = union(enum) { peer: engine.PeerHandle, local: u64 };

    pub fn origin(self: Fetch) Origin {
        return switch (self.destination) {
            .wire => |wire| .{ .peer = wire.peer },
            .local => |local| .{ .local = local.id },
        };
    }

    pub fn abandon(self: *Fetch) void {
        const host = self.host orelse return;
        self.host = null;
        switch (self.destination) {
            .wire => |wire| host.finishSessionOperation(host.sessions.get(wire.peer) orelse unreachable),
            .local => |*local| {
                local.lifetime.complete();
                host.pending_enliven_count -= 1;
            },
        }
    }

    pub fn closeLocal(self: *Fetch, reason: []const u8) void {
        const host = self.host orelse return;
        const local = self.destination.local;
        local.recipient.failedLocal(host, local.id, .closed, reason);
        self.abandon();
    }

    /// A successful call consumes this request. Refusal leaves it retryable.
    /// The provider rechecks current publication authority before fulfillment.
    pub fn complete(self: *Fetch, result: union(enum) { found: capability.Ref, missing, failed: []const u8 }) !void {
        const host = self.host orelse return;
        try host.refuseReentry();
        if (self.destination == .local) {
            const local = self.destination.local;
            switch (result) {
                .found => |ref| {
                    const actor = host.localActorFor(ref) orelse return error.NotLocal;
                    const retained = try host.retainLocalCapability(actor);
                    local.recipient.foundLocal(host, local.id, retained);
                },
                .missing => local.recipient.failedLocal(host, local.id, .broken, "unknown swissnum"),
                .failed => |reason| local.recipient.failedLocal(host, local.id, .broken, reason),
            }
            self.abandon();
            return;
        }
        const wire = self.destination.wire;
        const session = host.sessions.get(wire.peer) orelse unreachable;
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
        peer.settleAnswerOwned(wire.answer, resolution) catch |err| {
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
    if (host.publications.get(request.swissnum)) |row| {
        // A hidden reservation already owns this name: never consult storage.
        if (!row.active) return .missing;
        return .{ .found = (try session.served.port.projectActor(&host.vat, row.actor)).export_position };
    }
    const lookup = host.publication_lookup orelse return .missing;
    host.admitApplicationOperation() catch |err| return .{ .refused = err };
    host.admitSessionOperation(session) catch |err| return .{ .refused = err };
    const fetch: Fetch = .{ .host = host, .destination = .{ .wire = .{ .peer = scope, .answer = request.answer } } };
    switch (lookup.start(lookup.context, request.swissnum, fetch)) {
        .unhandled => return .missing,
        .refused => |err| return .{ .refused = err },
        .accepted => {},
    }
    host.beginSessionOperation(session);
    return .deferred;
}

/// An authenticated locator naming this Host resolves through the same public
/// registry and cold provider as a wire fetch. It creates no self connection.
/// The name remains public fetch authority; no private owner lookup runs here.
pub fn resolveLocal(host: *Host, name: []const u8, recipient: Recipient, admission: @import("host/admission.zig").WorkAdmission) !u64 {
    const id = host.next_vow;
    if (recipient == .action) try host.reserveActions(1);
    if (host.publications.get(name)) |row| {
        if (row.active) {
            const retained = try host.retainLocalCapability(row.actor);
            host.next_vow += 1;
            recipient.foundLocal(host, id, retained);
        } else {
            host.next_vow += 1;
            recipient.failedLocal(host, id, .broken, "unknown swissnum");
        }
        return id;
    }
    const lookup = host.publication_lookup orelse {
        host.next_vow += 1;
        recipient.failedLocal(host, id, .broken, "unknown swissnum");
        return id;
    };
    var lifetime = switch (admission) {
        .application => try host.admitPendingWork(),
        .retained => |parent| try parent.fork(),
    };
    const fetch: Fetch = .{ .host = host, .destination = .{ .local = .{ .id = id, .recipient = recipient, .lifetime = lifetime } } };
    const admitted = admission: {
        const prior = host.in_callback;
        host.in_callback = true;
        defer host.in_callback = prior;
        break :admission lookup.start(lookup.context, name, fetch);
    };
    switch (admitted) {
        .accepted => {
            host.next_vow += 1;
            host.pending_enliven_count += 1;
            recipient.pendingLocal(id);
        },
        .unhandled => {
            lifetime.complete();
            host.next_vow += 1;
            recipient.failedLocal(host, id, .broken, "unknown swissnum");
        },
        .refused => |err| {
            lifetime.complete();
            return err;
        },
    }
    return id;
}
