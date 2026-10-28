//! The listen side of `net.completion_resident`: opening listeners through
//! the transport policy, claiming accepted connections, and stopping.
//!
//! A backend that can open a listener whose setup finishes later (a foreign
//! provider waiting on its own service) declares `listenerPending` and
//! `submitListenReady`. Such a listen returns pending, the ready completion
//! emits `ev_listen` for the listener's route, and `finish` claims it.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const netlayer = @import("../netlayer.zig");
const resident_mod = @import("../multiplexed_resident.zig");
const userData = @import("completions.zig").userData;

const MultiplexedResident = resident_mod.MultiplexedResident;

pub fn Machine(comptime Self: type, comptime Policy: type) type {
    const Backend = @FieldType(Self, "backend");
    return struct {
        const Listener = Self.Listener;

        pub const can_pend = @hasDecl(Backend, "submitListenReady");

        fn of(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        pub fn listen(
            ctx: *anyopaque,
            route_id: usize,
            transport: []const u8,
            config: netlayer.ListenConfig,
        ) MultiplexedResident.RawListenStartOutcome {
            const self = of(ctx);
            defer self.pump();
            config.options.requireInherited() catch |err| return .{ .failed = .init(err) };
            const target = Policy.listenTarget(&self.backend, transport, config) catch |err|
                return .{ .failed = .init(err) };
            self.listeners.ensureUnusedCapacity(self.allocator, 1) catch |err| return .{ .failed = .init(err) };
            const listener = self.allocator.create(Listener) catch |err| return .{ .failed = .init(err) };
            const fd = self.backend.openListener(target) catch |err| {
                self.allocator.destroy(listener);
                return .{ .failed = .init(err) };
            };
            listener.* = .{ .token = self.next_listener, .route = route_id, .fd = fd, .identity = config.identity };
            if (comptime can_pend) if (self.backend.listenerPending(fd)) {
                self.backend.submitListenReady(userData(.listen_ready, listener.token), fd) catch |err| {
                    self.backend.closeFd(fd);
                    self.allocator.destroy(listener);
                    return .{ .failed = .init(err) };
                };
                self.listen_waits += 1;
                listener.setup = .pending;
                self.next_listener += 1;
                self.listeners.putAssumeCapacity(listener.token, listener);
                return .{ .admitted = .pending };
            };
            self.armAccept(listener) catch |err| {
                self.backend.closeFd(fd);
                self.allocator.destroy(listener);
                return .{ .failed = .init(err) };
            };
            self.next_listener += 1;
            self.listeners.putAssumeCapacity(listener.token, listener);
            return .{ .admitted = .{ .ready = listener } };
        }

        fn forRoute(self: *Self, route_id: usize) ?*Listener {
            var listeners = self.listeners.valueIterator();
            while (listeners.next()) |listener| if (listener.*.route == route_id) return listener.*;
            return null;
        }

        /// Claim a listener after its `ev_listen`.
        pub fn finish(ctx: *anyopaque, route_id: usize) MultiplexedResident.RawListenFinishOutcome {
            const self = of(ctx);
            defer self.pump();
            const listener = forRoute(self, route_id) orelse return .{ .failed = .init(error.ProviderContract) };
            const cause: anyerror = switch (listener.setup) {
                .ready => if (self.armAccept(listener)) return .{ .listener = listener } else |err| err,
                .failed => |err| err,
                .pending => error.ProviderContract,
            };
            var failure: netlayer.ListenFailure = .init(cause);
            switch (stopListen(self, listener)) {
                .complete => {},
                .failed => |cleanup| failure.noteChain(cleanup),
                .pending => unreachable,
            }
            return .{ .failed = failure };
        }

        /// Abandon a listener still finishing its setup. Retirement is
        /// synchronous here: the close completes through the drain.
        pub fn cancel(ctx: *anyopaque, route_id: usize) ?foundation.FailureChain {
            const self = of(ctx);
            const listener = forRoute(self, route_id) orelse return null;
            return switch (stopListen(self, listener)) {
                .complete => null,
                .failed => |cleanup| cleanup,
                .pending => unreachable,
            };
        }

        pub fn localLocator(
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            transport: []const u8,
            allocator: std.mem.Allocator,
        ) netlayer.ListenerLocatorOutcome {
            const self = of(ctx);
            const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
            return .{ .locator = Policy.localLocator(&self.backend, listener.fd, transport, listener.identity, allocator) catch |err|
                return .{ .failed = .init(err) } };
        }

        pub fn restorationState(ctx: *anyopaque, listener_ctx: *anyopaque, out: []u8) netlayer.ListenerRestorationOutcome {
            const self = of(ctx);
            const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
            return Policy.restorationState(&self.backend, listener.fd, out);
        }

        pub fn canonicalizeLocator(
            ctx: *anyopaque,
            listener_ctx: *anyopaque,
            transport: []const u8,
            allocator: std.mem.Allocator,
            requested: model.PeerLocator,
        ) netlayer.ListenerLocatorOutcome {
            const self = of(ctx);
            const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
            return .{ .locator = Policy.canonicalizeLocator(&self.backend, listener.fd, transport, listener.identity, allocator, requested) catch |err|
                return .{ .failed = .init(err) } };
        }

        pub fn finishAccept(ctx: *anyopaque, listener_ctx: *anyopaque) MultiplexedResident.RawFinishAcceptOutcome {
            const self = of(ctx);
            defer self.pump();
            const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
            if (listener.accepted.items.len == 0) {
                // Arrivals accepted before the refusal are claimed first;
                // the refusal follows them once, and the runtime decides.
                const failure = listener.accept_failure orelse return .{ .connection = null };
                listener.accept_failure = null;
                return .{ .failed = .fromChain(error.AcceptRefused, .init(failure)) };
            }
            const fd = listener.accepted.orderedRemove(0);
            // A listener that stopped at the unclaimed bound accepts again
            // once a claim makes room.
            if (!listener.accept_armed and listener.accept_failure == null and listener.setup == .ready)
                self.armAccept(listener) catch |err| self.latch(err);
            const id = self.adopt(fd) catch |err| {
                self.backend.closeFd(fd);
                return .{ .failed = .init(err) };
            };
            return .{ .connection = id };
        }

        pub fn stopListen(ctx: *anyopaque, listener_ctx: *anyopaque) resident_mod.TeardownOutcome {
            const self = of(ctx);
            const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
            defer self.pump();
            for (listener.accepted.items) |fd| self.backend.closeFd(fd);
            listener.accepted.deinit(self.allocator);
            std.debug.assert(self.listeners.remove(listener.token));
            // The close cancels the armed accept or setup wait. Their
            // completions arrive later and find no listener under this token.
            var outcome: resident_mod.TeardownOutcome = .complete;
            if (self.backend.submitClose(userData(.listen_close, listener.token), listener.fd)) {
                self.closing_listeners += 1;
            } else |err| {
                self.backend.closeFd(listener.fd);
                outcome = .{ .failed = .init(err) };
            }
            self.allocator.destroy(listener);
            return outcome;
        }
    };
}
