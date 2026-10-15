//! The listen subject of the multiplexed-resident contract: the attempt a
//! runtime holds while a resident's listener setup is externally paced, the
//! listener it claims, and the outcomes those operations report. The
//! attempt owns cancellation, and a listener owns its stop.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const netlayer = @import("../netlayer.zig");
const resident = @import("../multiplexed_resident.zig");

const Acceptor = resident.MultiplexedResident.Acceptor;
const ClaimedConnection = resident.ClaimedConnection;
const ListenCompletionVTable = resident.MultiplexedResident.ListenCompletionVTable;
const TeardownOutcome = resident.TeardownOutcome;

pub const ListenAttempt = struct {
    acceptor: Acceptor,
    route_id: ?usize,
    transport: []const u8,
    completion: ListenCompletionVTable,

    pub fn id(self: ListenAttempt) ?usize {
        return self.route_id;
    }

    pub fn deinit(self: *ListenAttempt) ?foundation.FailureChain {
        const route_id = self.route_id orelse return null;
        self.route_id = null;
        return self.completion.cancel(self.acceptor.resident.ctx, route_id);
    }

    pub fn finish(self: *ListenAttempt) ListenFinishOutcome {
        const route_id = self.route_id orelse
            return .{ .failed = .init(error.ProviderContract) };
        self.route_id = null;
        return switch (self.completion.finish(
            self.acceptor.resident.ctx,
            route_id,
        )) {
            .failed => |failure| .{ .failed = failure },
            .listener => |ctx| .{ .ready = .{
                .acceptor = self.acceptor,
                .ctx = ctx,
                .route_id = route_id,
                .transport = self.transport,
            } },
        };
    }
};

pub const ListenStartOutcome = union(enum) {
    admitted: ListenResult,
    failed: netlayer.ListenFailure,
};

pub const ListenFinishOutcome = union(enum) {
    ready: Listener,
    failed: netlayer.ListenFailure,
};

pub const ListenResult = union(enum) {
    ready: Listener,
    pending: ListenAttempt,

    pub fn deinit(self: *ListenResult) ?foundation.FailureChain {
        const failure = switch (self.*) {
            .ready => |listener| listener.stopListen(),
            .pending => |*attempt| attempt.deinit(),
        };
        self.* = undefined;
        return failure;
    }
};

/// One profile-scoped listener owned by a multiplexed runtime. Its opaque
/// provider handle owns listener state. `route_id` is the caller's stable
/// readiness identity and is what `ev_accept` records carry.
pub const Listener = struct {
    acceptor: Acceptor,
    ctx: *anyopaque,
    route_id: usize,
    transport: []const u8,

    pub fn localLocator(
        self: Listener,
        allocator: std.mem.Allocator,
    ) netlayer.ListenError!model.PeerLocator {
        return switch (self.localLocatorOutcome(allocator)) {
            .locator => |locator| locator,
            .failed => |failure| netlayer.projectListenError(failure),
        };
    }

    pub fn localLocatorOutcome(
        self: Listener,
        allocator: std.mem.Allocator,
    ) netlayer.ListenerLocatorOutcome {
        return self.acceptor.operations().local_locator(
            self.acceptor.resident.ctx,
            self.ctx,
            self.transport,
            allocator,
        );
    }

    pub fn canonicalizeLocator(
        self: Listener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) netlayer.ListenError!model.PeerLocator {
        return switch (self.canonicalizeLocatorOutcome(allocator, locator)) {
            .locator => |canonical| canonical,
            .failed => |failure| netlayer.projectListenError(failure),
        };
    }

    pub fn canonicalizeLocatorOutcome(
        self: Listener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) netlayer.ListenerLocatorOutcome {
        return self.acceptor.operations().canonicalize_locator(
            self.acceptor.resident.ctx,
            self.ctx,
            self.transport,
            allocator,
            locator,
        );
    }

    pub fn restorationState(self: Listener, out: []u8) netlayer.RestorationStateError!?usize {
        return switch (self.restorationStateOutcome(out)) {
            .unsupported => null,
            .size => |needed| needed,
            .failed => error.ProviderFailure,
        };
    }

    pub fn restorationStateOutcome(self: Listener, out: []u8) netlayer.ListenerRestorationOutcome {
        const f = self.acceptor.operations().restoration_state orelse return .unsupported;
        return f(self.acceptor.resident.ctx, self.ctx, out);
    }

    pub fn finishAccept(self: Listener) netlayer.AcceptError!?ClaimedConnection {
        return switch (self.finishAcceptOutcome()) {
            .connection => |connection| connection,
            .failed => |failure| failure.classification,
        };
    }

    pub fn finishAcceptOutcome(self: Listener) FinishAcceptOutcome {
        const result = self.acceptor.operations().finish_accept(self.acceptor.resident.ctx, self.ctx);
        return switch (result) {
            .connection => |id| .{ .connection = if (id) |value| .{ .resident = self.acceptor.resident, .id = value } else null },
            .failed => |failure| .{ .failed = failure },
        };
    }

    pub fn stopListen(self: Listener) ?foundation.FailureChain {
        return self.stopListenOutcome().requireComplete();
    }

    pub fn stopListenOutcome(self: Listener) TeardownOutcome {
        return self.acceptor.operations().stop_listen(self.acceptor.resident.ctx, self.ctx);
    }
};

pub const FinishAcceptOutcome = union(enum) {
    connection: ?ClaimedConnection,
    failed: netlayer.AcceptFailure,
};
