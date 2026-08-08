//! The per-peer composition link installed by a `Node`.
//!
//! A Peer owns one CapTP session. These callbacks let the node composition
//! supply cross-session facilities without making the Peer know the Node's
//! representation: outbound token lowering, Host-local object projection,
//! live gifter lookup, authority-neutral parked-withdraw scheduling, and V1
//! compatibility count issuance.

const std = @import("std");
const model = @import("model");
const bootstrap = @import("bootstrap.zig");
const PeerId = @import("peer_id.zig").PeerId;

pub const LoweringError = error{TokenNotLiftable};
pub const HandoffCountError = error{HandoffCountExhausted};
pub const PromiseShorteningError = std.mem.Allocator.Error || error{
    UnexpectedMessage,
    ProxyRecipientCapExceeded,
};

/// Scheduler-only identity for one gift dependency. The BLAKE3 tag keeps
/// attacker-selected gift ids out of the Node's coordination tables while the
/// gifter PeerId preserves session scope. This is never capability authority:
/// the exact signed give and exact registry key are checked again at withdraw,
/// so a digest collision can only cause an extra bounded wake.
pub const HandoffDependency = struct {
    gifter: PeerId,
    gift_tag: [16]u8,

    pub fn init(gifter: PeerId, gift_id: []const u8) HandoffDependency {
        var gift_tag: [16]u8 = undefined;
        std.crypto.hash.Blake3.hash(gift_id, &gift_tag, .{});
        return .{ .gifter = gifter, .gift_tag = gift_tag };
    }
};

pub const NodeServices = struct {
    ctx: *anyopaque,
    peer_id: PeerId,
    /// Node-wide gate for the outbound token walk only.
    lowering_active: *const bool,
    vtable: *const VTable,

    pub const VTable = struct {
        lower: *const fn (ctx: *anyopaque, peer_id: PeerId, reference: model.Reference) LoweringError!model.Reference,
        local_object_projection: *const fn (ctx: *anyopaque) ?bootstrap.LocalObjectProjection,
        gifter_session_resolver: *const fn (ctx: *anyopaque) ?bootstrap.GifterSessionResolver,
        pending_withdraw_added: *const fn (ctx: *anyopaque, receiver: PeerId, dependency: HandoffDependency) std.mem.Allocator.Error!void,
        pending_withdraw_removed: *const fn (ctx: *anyopaque, receiver: PeerId, dependency: HandoffDependency) void,
        gift_deposited: *const fn (ctx: *anyopaque, dependency: HandoffDependency) void,
        session_closed: *const fn (ctx: *anyopaque, peer_id: PeerId) void,
        next_v1_emitted_handoff_count: *const fn (ctx: *anyopaque) HandoffCountError!u64,
        prepare_promise_shortening: *const fn (ctx: *anyopaque, peer_id: PeerId, source: u64, target: u64, target_listener: u64, converges: bool) PromiseShorteningError!void,
        commit_promise_shortening: *const fn (ctx: *anyopaque, peer_id: PeerId, source: u64, target: u64, target_listener: u64, converges: bool) void,
    };

    /// Bind a concrete node implementation to the erased link stored by a
    /// Peer. The implementation table is typed on the exact context pointer,
    /// so the compiler proves every callback accepts the context supplied here;
    /// only this adapter performs the internal erasure.
    pub fn bind(
        ctx: anytype,
        peer_id: PeerId,
        lowering_active: *const bool,
        comptime implementation: Implementation(@TypeOf(ctx)),
    ) NodeServices {
        const Context = @TypeOf(ctx);
        const Adapter = struct {
            fn context(erased: *anyopaque) Context {
                return @ptrCast(@alignCast(erased));
            }

            fn lowerThunk(erased: *anyopaque, id: PeerId, reference: model.Reference) LoweringError!model.Reference {
                return implementation.lower(context(erased), id, reference);
            }

            fn localObjectProjectionThunk(erased: *anyopaque) ?bootstrap.LocalObjectProjection {
                return implementation.local_object_projection(context(erased));
            }

            fn gifterSessionResolverThunk(erased: *anyopaque) ?bootstrap.GifterSessionResolver {
                return implementation.gifter_session_resolver(context(erased));
            }

            fn pendingWithdrawAddedThunk(erased: *anyopaque, receiver: PeerId, dependency: HandoffDependency) std.mem.Allocator.Error!void {
                return implementation.pending_withdraw_added(context(erased), receiver, dependency);
            }

            fn pendingWithdrawRemovedThunk(erased: *anyopaque, receiver: PeerId, dependency: HandoffDependency) void {
                implementation.pending_withdraw_removed(context(erased), receiver, dependency);
            }

            fn giftDepositedThunk(erased: *anyopaque, dependency: HandoffDependency) void {
                implementation.gift_deposited(context(erased), dependency);
            }

            fn sessionClosedThunk(erased: *anyopaque, id: PeerId) void {
                implementation.session_closed(context(erased), id);
            }

            fn nextV1EmittedHandoffCountThunk(erased: *anyopaque) HandoffCountError!u64 {
                return implementation.next_v1_emitted_handoff_count(context(erased));
            }

            fn preparePromiseShorteningThunk(erased: *anyopaque, id: PeerId, source: u64, target: u64, target_listener: u64, converges: bool) PromiseShorteningError!void {
                return implementation.prepare_promise_shortening(context(erased), id, source, target, target_listener, converges);
            }

            fn commitPromiseShorteningThunk(erased: *anyopaque, id: PeerId, source: u64, target: u64, target_listener: u64, converges: bool) void {
                implementation.commit_promise_shortening(context(erased), id, source, target, target_listener, converges);
            }

            const vtable: VTable = .{
                .lower = lowerThunk,
                .local_object_projection = localObjectProjectionThunk,
                .gifter_session_resolver = gifterSessionResolverThunk,
                .pending_withdraw_added = pendingWithdrawAddedThunk,
                .pending_withdraw_removed = pendingWithdrawRemovedThunk,
                .gift_deposited = giftDepositedThunk,
                .session_closed = sessionClosedThunk,
                .next_v1_emitted_handoff_count = nextV1EmittedHandoffCountThunk,
                .prepare_promise_shortening = preparePromiseShorteningThunk,
                .commit_promise_shortening = commitPromiseShorteningThunk,
            };
        };

        return .{
            .ctx = ctx,
            .peer_id = peer_id,
            .lowering_active = lowering_active,
            .vtable = &Adapter.vtable,
        };
    }

    fn Implementation(comptime Context: type) type {
        return struct {
            lower: *const fn (Context, PeerId, model.Reference) LoweringError!model.Reference,
            local_object_projection: *const fn (Context) ?bootstrap.LocalObjectProjection,
            gifter_session_resolver: *const fn (Context) ?bootstrap.GifterSessionResolver,
            pending_withdraw_added: *const fn (Context, PeerId, HandoffDependency) std.mem.Allocator.Error!void,
            pending_withdraw_removed: *const fn (Context, PeerId, HandoffDependency) void,
            gift_deposited: *const fn (Context, HandoffDependency) void,
            session_closed: *const fn (Context, PeerId) void,
            next_v1_emitted_handoff_count: *const fn (Context) HandoffCountError!u64,
            prepare_promise_shortening: *const fn (Context, PeerId, u64, u64, u64, bool) PromiseShorteningError!void,
            commit_promise_shortening: *const fn (Context, PeerId, u64, u64, u64, bool) void,
        };
    }

    pub fn lower(self: NodeServices, reference: model.Reference) LoweringError!model.Reference {
        return self.vtable.lower(self.ctx, self.peer_id, reference);
    }

    pub fn localObjectProjection(self: NodeServices) ?bootstrap.LocalObjectProjection {
        return self.vtable.local_object_projection(self.ctx);
    }

    pub fn gifterSessionResolver(self: NodeServices) ?bootstrap.GifterSessionResolver {
        return self.vtable.gifter_session_resolver(self.ctx);
    }

    pub fn pendingWithdrawAdded(self: NodeServices, dependency: HandoffDependency) std.mem.Allocator.Error!void {
        try self.vtable.pending_withdraw_added(self.ctx, self.peer_id, dependency);
    }

    pub fn pendingWithdrawRemoved(self: NodeServices, dependency: HandoffDependency) void {
        self.vtable.pending_withdraw_removed(self.ctx, self.peer_id, dependency);
    }

    pub fn giftDeposited(self: NodeServices, gift_id: []const u8) void {
        self.vtable.gift_deposited(self.ctx, HandoffDependency.init(self.peer_id, gift_id));
    }

    pub fn sessionClosed(self: NodeServices) void {
        self.vtable.session_closed(self.ctx, self.peer_id);
    }

    pub fn nextV1EmittedHandoffCount(self: NodeServices) HandoffCountError!u64 {
        return self.vtable.next_v1_emitted_handoff_count(self.ctx);
    }

    pub fn preparePromiseShortening(self: NodeServices, source: u64, target: u64, target_listener: u64, converges: bool) PromiseShorteningError!void {
        return self.vtable.prepare_promise_shortening(self.ctx, self.peer_id, source, target, target_listener, converges);
    }

    pub fn commitPromiseShortening(self: NodeServices, source: u64, target: u64, target_listener: u64, converges: bool) void {
        self.vtable.commit_promise_shortening(self.ctx, self.peer_id, source, target, target_listener, converges);
    }
};
