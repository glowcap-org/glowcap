//! `onion` over `Inner`, the platform's own policy, as the transport policy
//! `net.completion_resident.Resident` takes.
//!
//! An onion listener's designator is the service id Tor mints when it
//! publishes, so a listen names none, and its locator is that id with no
//! hints (ADR-0108). The service forwards to the loopback endpoint the inner
//! listener binds, so the platform backend must bind loopback. Every other
//! symbol passes to `Inner` against the wrapped platform backend.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const netlayer = @import("../../../netlayer.zig");
const state = @import("state.zig");

const crypto = foundation.crypto;
const loopback = [4]u8{ 127, 0, 0, 1 };

pub fn ResidentPolicy(comptime Backend: type, comptime Inner: type) type {
    const Platform = @FieldType(Backend, "inner");
    const Resolver = state.DialResolver(Inner, Platform);
    return struct {
        fn isOnion(transport: []const u8) bool {
            return std.mem.eql(u8, transport, model.transport.onion);
        }

        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            return Resolver.resolve(locator);
        }

        pub fn listenTarget(backend: *const Backend, transport: []const u8, config: netlayer.ListenConfig) !Backend.ListenTarget {
            if (!isOnion(transport)) return .{ .platform = try Inner.listenTarget(&backend.inner, transport, config) };
            if (config.designator.len != 0) return error.InvalidAddress;
            if (!std.mem.eql(u8, &backend.inner.listenerIp4(), &loopback)) return error.ListenerNotForwardable;
            return .{ .onion = Platform.loopListenTarget(0) };
        }

        pub fn localLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
        ) !model.PeerLocator {
            const service_id = switch (try backend.listenerAddress(fd)) {
                .onion => |id| id,
                .platform => return Inner.localLocator(&backend.inner, fd, transport, identity, allocator),
            };
            return model.clonePeerLocator(allocator, .{
                .transport = transport,
                .designator = &service_id,
                .hints = model.Hints.emptyFalse(),
            });
        }

        /// An onion listener restores from its service key; any other
        /// listener answers through `Inner`.
        pub fn restorationState(backend: *Backend, fd: Backend.Fd, out: []u8) netlayer.ListenerRestorationOutcome {
            if (backend.listenerServiceKey(fd)) |key| return .{ .size = netlayer.writeListenerRestorationState(out, key) };
            if (comptime !@hasDecl(Inner, "restorationState")) return .unsupported;
            return Inner.restorationState(&backend.inner, fd, out);
        }

        /// A service id names exactly one service, so a listener advertises
        /// only its own.
        pub fn canonicalizeLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) !model.PeerLocator {
            if (!isOnion(transport)) return Inner.canonicalizeLocator(&backend.inner, fd, transport, identity, allocator, candidate);
            model.validatePeerLocator(candidate) catch return error.InvalidAddress;
            const service_id = switch (try backend.listenerAddress(fd)) {
                .onion => |id| id,
                .platform => return error.InvalidAddress,
            };
            if (!isOnion(candidate.transport) or !std.mem.eql(u8, candidate.designator, &service_id)) return error.InvalidAddress;
            return model.clonePeerLocator(allocator, candidate);
        }
    };
}
