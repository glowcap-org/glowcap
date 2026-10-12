//! The per-peer composition link installed by a `Node`.
//!
//! A Peer owns one CapTP session. These callbacks let the node composition
//! supply cross-session facilities without making the Peer know the Node's
//! representation: outbound capability-route lowering, Host-local object projection,
//! live gifter lookup, authority-neutral parked-withdraw scheduling, and V1
//! compatibility count issuance.

const std = @import("std");
const model = @import("model");
const session = @import("session");
const bootstrap = @import("bootstrap.zig");
const passable = @import("node/passable.zig");
const PeerHandle = @import("peer_handle.zig").PeerHandle;

pub const LoweringError = error{RouteNotLowerable};
pub const OutboundStagingError = std.mem.Allocator.Error || session.Error || error{
    RouteNotLowerable,
    QueueCapExceeded,
    CapabilitySpaceExhausted,
    OutboundBackpressure,
    MalformedView,
    ExportRangeExhausted,
    ProxyRecipientCapExceeded,
    PeerGone,
    session_not_open,
    MissingPartnerDesignator,
};
pub const HandoffCountError = error{HandoffCountExhausted};
pub const PromiseShorteningError = std.mem.Allocator.Error || error{
    UnexpectedMessage,
    ProxyRecipientCapExceeded,
};

/// Scheduler-only identity for one gift dependency. The BLAKE3 tag keeps
/// partner-chosen gift ids out of the Node's coordination tables while the
/// gifter PeerHandle preserves session scope. This is never capability authority:
/// the exact signed give and exact registry key are checked again at withdraw,
/// so a digest collision can only cause an extra bounded wake.
pub const HandoffDependency = struct {
    gifter: PeerHandle,
    gift_tag: [16]u8,

    pub fn init(gifter: PeerHandle, gift_id: []const u8) HandoffDependency {
        var gift_tag: [16]u8 = undefined;
        std.crypto.hash.Blake3.hash(gift_id, &gift_tag, .{});
        return .{ .gifter = gifter, .gift_tag = gift_tag };
    }
};

pub const NodeServices = struct {
    ctx: *anyopaque,
    peer_handle: PeerHandle,
    /// Node-wide gate for the outbound token walk only.
    lowering_active: *const bool,
    vtable: *const VTable,

    pub const VTable = struct {
        lower: *const fn (ctx: *anyopaque, peer_handle: PeerHandle, reference: model.Reference) LoweringError!model.Reference,
        stage_outbound: *const fn (ctx: *anyopaque, peer_handle: PeerHandle, outbound: *passable.Outbound) OutboundStagingError!bool,
        staged_withdrawn: *const fn (ctx: *anyopaque, peer_handle: PeerHandle, batch: passable.BatchId) void,
        provisional_closed: *const fn (ctx: *anyopaque, peer_handle: PeerHandle, retract: bool) void,
        local_object_projection: *const fn (ctx: *anyopaque) ?bootstrap.gifts.LocalObjectProjection,
        gifter_session_resolver: *const fn (ctx: *anyopaque) ?bootstrap.gifts.GifterSessionResolver,
        pending_withdraw_added: *const fn (ctx: *anyopaque, receiver: PeerHandle, dependency: HandoffDependency) std.mem.Allocator.Error!void,
        pending_withdraw_removed: *const fn (ctx: *anyopaque, receiver: PeerHandle, dependency: HandoffDependency) void,
        gift_deposited: *const fn (ctx: *anyopaque, dependency: HandoffDependency) void,
        session_closed: *const fn (ctx: *anyopaque, peer_handle: PeerHandle) void,
        prepare_v1_emitted_handoff_count: *const fn (ctx: *anyopaque) HandoffCountError!bootstrap.gifts.PreparedHandoffCount,
        prepare_promise_shortening: *const fn (ctx: *anyopaque, peer_handle: PeerHandle, source: u64, target: u64, target_listener: u64, converges: bool) PromiseShorteningError!void,
        commit_promise_shortening: *const fn (ctx: *anyopaque, peer_handle: PeerHandle, source: u64, target: u64, target_listener: u64, converges: bool) void,
        designator_scheme: *const fn (ctx: *anyopaque, transport: []const u8) ?model.transport.DesignatorScheme,
    };

    /// Bind a concrete node implementation to the erased link stored by a
    /// Peer. The implementation table is typed on the exact context pointer,
    /// so the compiler proves every callback accepts the context supplied here.
    /// Only this adapter performs the internal erasure.
    pub fn bind(
        ctx: anytype,
        peer_handle: PeerHandle,
        lowering_active: *const bool,
        comptime implementation: Implementation(@TypeOf(ctx)),
    ) NodeServices {
        const Context = @TypeOf(ctx);
        const Adapter = struct {
            fn context(erased: *anyopaque) Context {
                return @ptrCast(@alignCast(erased));
            }

            fn lowerThunk(erased: *anyopaque, id: PeerHandle, reference: model.Reference) LoweringError!model.Reference {
                return implementation.lower(context(erased), id, reference);
            }

            fn stageOutboundThunk(erased: *anyopaque, id: PeerHandle, outbound: *passable.Outbound) OutboundStagingError!bool {
                return implementation.stage_outbound(context(erased), id, outbound);
            }

            fn stagedWithdrawnThunk(erased: *anyopaque, id: PeerHandle, batch: passable.BatchId) void {
                implementation.staged_withdrawn(context(erased), id, batch);
            }

            fn provisionalClosedThunk(erased: *anyopaque, id: PeerHandle, retract: bool) void {
                implementation.provisional_closed(context(erased), id, retract);
            }

            fn localObjectProjectionThunk(erased: *anyopaque) ?bootstrap.gifts.LocalObjectProjection {
                return implementation.local_object_projection(context(erased));
            }

            fn gifterSessionResolverThunk(erased: *anyopaque) ?bootstrap.gifts.GifterSessionResolver {
                return implementation.gifter_session_resolver(context(erased));
            }

            fn pendingWithdrawAddedThunk(erased: *anyopaque, receiver: PeerHandle, dependency: HandoffDependency) std.mem.Allocator.Error!void {
                return implementation.pending_withdraw_added(context(erased), receiver, dependency);
            }

            fn pendingWithdrawRemovedThunk(erased: *anyopaque, receiver: PeerHandle, dependency: HandoffDependency) void {
                implementation.pending_withdraw_removed(context(erased), receiver, dependency);
            }

            fn giftDepositedThunk(erased: *anyopaque, dependency: HandoffDependency) void {
                implementation.gift_deposited(context(erased), dependency);
            }

            fn sessionClosedThunk(erased: *anyopaque, id: PeerHandle) void {
                implementation.session_closed(context(erased), id);
            }

            fn prepareV1EmittedHandoffCountThunk(erased: *anyopaque) HandoffCountError!bootstrap.gifts.PreparedHandoffCount {
                return implementation.prepare_v1_emitted_handoff_count(context(erased));
            }

            fn preparePromiseShorteningThunk(erased: *anyopaque, id: PeerHandle, source: u64, target: u64, target_listener: u64, converges: bool) PromiseShorteningError!void {
                return implementation.prepare_promise_shortening(context(erased), id, source, target, target_listener, converges);
            }

            fn commitPromiseShorteningThunk(erased: *anyopaque, id: PeerHandle, source: u64, target: u64, target_listener: u64, converges: bool) void {
                implementation.commit_promise_shortening(context(erased), id, source, target, target_listener, converges);
            }

            fn designatorSchemeThunk(erased: *anyopaque, transport: []const u8) ?model.transport.DesignatorScheme {
                return implementation.designator_scheme(context(erased), transport);
            }

            const vtable: VTable = .{
                .lower = lowerThunk,
                .stage_outbound = stageOutboundThunk,
                .staged_withdrawn = stagedWithdrawnThunk,
                .provisional_closed = provisionalClosedThunk,
                .local_object_projection = localObjectProjectionThunk,
                .gifter_session_resolver = gifterSessionResolverThunk,
                .pending_withdraw_added = pendingWithdrawAddedThunk,
                .pending_withdraw_removed = pendingWithdrawRemovedThunk,
                .gift_deposited = giftDepositedThunk,
                .session_closed = sessionClosedThunk,
                .prepare_v1_emitted_handoff_count = prepareV1EmittedHandoffCountThunk,
                .prepare_promise_shortening = preparePromiseShorteningThunk,
                .commit_promise_shortening = commitPromiseShorteningThunk,
                .designator_scheme = designatorSchemeThunk,
            };
        };

        return .{
            .ctx = ctx,
            .peer_handle = peer_handle,
            .lowering_active = lowering_active,
            .vtable = &Adapter.vtable,
        };
    }

    fn Implementation(comptime Context: type) type {
        return struct {
            lower: *const fn (Context, PeerHandle, model.Reference) LoweringError!model.Reference,
            stage_outbound: *const fn (Context, PeerHandle, *passable.Outbound) OutboundStagingError!bool,
            staged_withdrawn: *const fn (Context, PeerHandle, passable.BatchId) void,
            provisional_closed: *const fn (Context, PeerHandle, bool) void,
            local_object_projection: *const fn (Context) ?bootstrap.gifts.LocalObjectProjection,
            gifter_session_resolver: *const fn (Context) ?bootstrap.gifts.GifterSessionResolver,
            pending_withdraw_added: *const fn (Context, PeerHandle, HandoffDependency) std.mem.Allocator.Error!void,
            pending_withdraw_removed: *const fn (Context, PeerHandle, HandoffDependency) void,
            gift_deposited: *const fn (Context, HandoffDependency) void,
            session_closed: *const fn (Context, PeerHandle) void,
            prepare_v1_emitted_handoff_count: *const fn (Context) HandoffCountError!bootstrap.gifts.PreparedHandoffCount,
            prepare_promise_shortening: *const fn (Context, PeerHandle, u64, u64, u64, bool) PromiseShorteningError!void,
            commit_promise_shortening: *const fn (Context, PeerHandle, u64, u64, u64, bool) void,
            designator_scheme: *const fn (Context, []const u8) ?model.transport.DesignatorScheme,
        };
    }

    pub fn lower(self: NodeServices, reference: model.Reference) LoweringError!model.Reference {
        return self.vtable.lower(self.ctx, self.peer_handle, reference);
    }

    /// Transfer an owned semantic payload into Node staging when one of its
    /// Passable values needs cross-session projection. `true` means the Node
    /// adopted the complete payload. `false` leaves it with the caller.
    pub fn stageOutbound(self: NodeServices, outbound: *passable.Outbound) OutboundStagingError!bool {
        return self.vtable.stage_outbound(self.ctx, self.peer_handle, outbound);
    }

    /// A retracted provisional window removed the row of a carrier the Node
    /// is still staging (ADR-0194). The Node fails that batch.
    pub fn stagedWithdrawn(self: NodeServices, batch: passable.BatchId) void {
        self.vtable.staged_withdrawn(self.ctx, self.peer_handle, batch);
    }

    /// The Peer's provisional window closed (ADR-0194), after the Peer kept
    /// or retracted its own rows. The Node keeps or withdraws what the
    /// window's sends committed beyond them.
    pub fn provisionalClosed(self: NodeServices, retract: bool) void {
        self.vtable.provisional_closed(self.ctx, self.peer_handle, retract);
    }

    pub fn localObjectProjection(self: NodeServices) ?bootstrap.gifts.LocalObjectProjection {
        return self.vtable.local_object_projection(self.ctx);
    }

    pub fn gifterSessionResolver(self: NodeServices) ?bootstrap.gifts.GifterSessionResolver {
        return self.vtable.gifter_session_resolver(self.ctx);
    }

    pub fn pendingWithdrawAdded(self: NodeServices, dependency: HandoffDependency) std.mem.Allocator.Error!void {
        try self.vtable.pending_withdraw_added(self.ctx, self.peer_handle, dependency);
    }

    pub fn pendingWithdrawRemoved(self: NodeServices, dependency: HandoffDependency) void {
        self.vtable.pending_withdraw_removed(self.ctx, self.peer_handle, dependency);
    }

    pub fn giftDeposited(self: NodeServices, gift_id: []const u8) void {
        self.vtable.gift_deposited(self.ctx, HandoffDependency.init(self.peer_handle, gift_id));
    }

    pub fn sessionClosed(self: NodeServices) void {
        self.vtable.session_closed(self.ctx, self.peer_handle);
    }

    pub fn prepareV1EmittedHandoffCount(self: NodeServices) HandoffCountError!bootstrap.gifts.PreparedHandoffCount {
        return self.vtable.prepare_v1_emitted_handoff_count(self.ctx);
    }

    pub fn preparePromiseShortening(self: NodeServices, source: u64, target: u64, target_listener: u64, converges: bool) PromiseShorteningError!void {
        return self.vtable.prepare_promise_shortening(self.ctx, self.peer_handle, source, target, target_listener, converges);
    }

    pub fn commitPromiseShortening(self: NodeServices, source: u64, target: u64, target_listener: u64, converges: bool) void {
        self.vtable.commit_promise_shortening(self.ctx, self.peer_handle, source, target, target_listener, converges);
    }

    pub fn designatorScheme(self: NodeServices, transport: []const u8) ?model.transport.DesignatorScheme {
        return self.vtable.designator_scheme(self.ctx, transport);
    }
};
