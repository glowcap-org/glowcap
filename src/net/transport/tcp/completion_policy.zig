//! The TCP profiles on a platform completion backend, as the transport policy
//! `net.completion_resident.Resident` takes: testing `tcp`, `keyed-tcp`, and
//! `noise-tcp`.
//!
//! All three carry the Host's bytes unchanged. `noise-tcp` is sealed by the
//! byte-fed Host on both halves (ADR-0041), so the socket under it is the
//! `keyed-tcp` socket exactly. A platform backend binds every listener on the
//! one interface it was built with, so a listen designator must name that
//! interface. Any other host is refused rather than silently rebound.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const netlayer = @import("../../netlayer.zig");
const addressing = @import("addressing.zig");
const advertisement = @import("advertisement.zig");
const profiles = @import("../tcp.zig").profiles;

pub fn Policy(comptime Backend: type) type {
    return struct {
        fn profileFor(transport: []const u8) addressing.Error!model.transport.Metadata {
            const known = model.transport.parseKnown(transport) orelse return error.UnknownTransport;
            if (std.mem.indexOfScalar(model.transport.Known, &profiles, known) == null) return error.UnknownTransport;
            return known.metadata();
        }

        pub fn resolve(locator: model.PeerLocator) addressing.Error!Backend.ConnectTarget {
            _ = try profileFor(locator.transport);
            return addressing.DialResolver.resolve(locator);
        }

        /// The designator is where to bind, for every profile. A key profile
        /// also needs the identity it publishes.
        pub fn listenTarget(backend: *const Backend, transport: []const u8, config: netlayer.ListenConfig) addressing.Error!Backend.ListenTarget {
            const profile = try profileFor(transport);
            if (profile.designator_scheme == .key and config.identity == null) return error.InvalidAddress;
            const address = try addressing.parseDesignator(config.designator);
            const ip4 = switch (address) {
                .ip4 => |ip4| ip4,
                .ip6 => return error.InvalidAddress,
            };
            if (!std.mem.eql(u8, &ip4.bytes, &backend.listenerIp4())) return error.InvalidAddress;
            return Backend.loopListenTarget(ip4.port);
        }

        pub fn localLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
        ) !model.PeerLocator {
            const bound = try backend.listenerAddress(fd);
            return advertisement.locator(allocator, try profileFor(transport), .{ .ip4 = .{
                .bytes = bound.bytes,
                .port = bound.port,
            } }, identity);
        }

        pub fn canonicalizeLocator(
            _: *Backend,
            _: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) !model.PeerLocator {
            try advertisement.validate(try profileFor(transport), identity, candidate);
            return model.clonePeerLocator(allocator, candidate);
        }
    };
}
