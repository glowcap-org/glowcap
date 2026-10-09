//! Foreign stream providers over `Inner`, the platform's own policy, as the
//! transport policy `net.completion_resident.Resident` takes.
//!
//! A symbol `Inner` does not know belongs to a provider, the precedence
//! `completion.DialResolver` applies to dials. A provider listener reports
//! its own locator, and advertises only that.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const netlayer = @import("../../netlayer.zig");

const crypto = foundation.crypto;

pub fn ResidentPolicy(comptime Backend: type, comptime Inner: type) type {
    return struct {
        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            const inner = Inner.resolve(locator) catch |err| {
                if (err == error.UnknownTransport) return .{ .external = locator };
                return err;
            };
            return .{ .platform = inner };
        }

        pub fn listenTarget(backend: *const Backend, transport: []const u8, config: netlayer.ListenConfig) !Backend.ListenTarget {
            const inner = Inner.listenTarget(&backend.platform, transport, config) catch |err| {
                if (err == error.UnknownTransport) return .{ .provider = .{
                    .transport = transport,
                    .designator = config.designator,
                    .identity = config.identity,
                } };
                return err;
            };
            return .{ .platform = inner };
        }

        pub fn localLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
        ) !model.PeerLocator {
            return switch (try backend.listenerAddress(fd)) {
                .external => backend.listenerLocator(allocator),
                .platform => Inner.localLocator(&backend.platform, fd, transport, identity, allocator),
            };
        }

        /// A provider listener restores through its provider; any other
        /// through the adapter beneath.
        pub fn restorationState(backend: *Backend, fd: Backend.Fd, out: []u8) netlayer.ListenerRestorationOutcome {
            const address = backend.listenerAddress(fd) catch |err| return .{ .failed = .init(err) };
            return switch (address) {
                .external => backend.listenerRestorationState(out),
                .platform => if (comptime @hasDecl(Inner, "restorationState")) Inner.restorationState(&backend.platform, fd, out) else .unsupported,
            };
        }

        pub fn canonicalizeLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) !model.PeerLocator {
            switch (try backend.listenerAddress(fd)) {
                .external => {},
                .platform => return Inner.canonicalizeLocator(&backend.platform, fd, transport, identity, allocator, candidate),
            }
            model.validatePeerLocator(candidate) catch return error.InvalidAddress;
            if (try backend.listenerCanonicalize(allocator, candidate)) |canonical| return canonical;
            const own = try backend.listenerLocator(allocator);
            defer model.freePeerLocator(allocator, own);
            if (!std.mem.eql(u8, candidate.transport, own.transport) or !std.mem.eql(u8, candidate.designator, own.designator))
                return error.InvalidAddress;
            return model.clonePeerLocator(allocator, candidate);
        }
    };
}

/// The base policy for a resident that serves providers only: the platform
/// beneath dials and listens for no symbol of its own.
pub fn PlatformRefused(comptime Platform: type) type {
    return struct {
        pub fn resolve(_: model.PeerLocator) !Platform.ConnectTarget {
            return error.UnknownTransport;
        }
        pub fn listenTarget(_: *const Platform, _: []const u8, _: netlayer.ListenConfig) !Platform.ListenTarget {
            return error.UnknownTransport;
        }
        pub fn localLocator(_: *Platform, _: Platform.Fd, _: []const u8, _: ?crypto.PeerKey, _: std.mem.Allocator) !model.PeerLocator {
            return error.UnknownTransport;
        }
        pub fn canonicalizeLocator(_: *Platform, _: Platform.Fd, _: []const u8, _: ?crypto.PeerKey, _: std.mem.Allocator, _: model.PeerLocator) !model.PeerLocator {
            return error.UnknownTransport;
        }
    };
}
