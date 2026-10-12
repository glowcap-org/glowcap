//! `keyed-relay` and `noise-relay` over `Inner`, the platform's own policy,
//! as the transport policy `net.completion_resident.Resident` takes.
//!
//! Both relay symbols ride the same rendezvous socket. `noise-relay` is
//! sealed by the byte-fed Host on both halves (ADR-0107). A relay listener is
//! the backend's one registration, so its designator is the registered key,
//! which must be the identity of the Host it serves, and its locator names
//! the backend's relay as the rendezvous hint. Every other symbol passes to
//! `Inner` against the wrapped platform backend.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const netlayer = @import("../../../netlayer.zig");
const route = @import("../route.zig");
const target = @import("target.zig");

pub fn ResidentPolicy(comptime Backend: type, comptime Inner: type) type {
    return struct {
        fn isRelay(transport: []const u8) bool {
            return std.mem.eql(u8, transport, model.transport.keyed_relay) or
                std.mem.eql(u8, transport, model.transport.noise_relay);
        }

        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            if (!isRelay(locator.transport)) return .{ .tcp = try Inner.resolve(locator) };
            var carrier = locator;
            carrier.transport = model.transport.keyed_relay;
            return target.DialResolver.resolve(carrier);
        }

        /// The listener registers the listening Host's key. Empty asks for
        /// that key. Anything else must be it.
        pub fn listenTarget(backend: *const Backend, transport: []const u8, listen: netlayer.ListenConfig) !Backend.ListenTarget {
            if (!isRelay(transport)) return .{ .platform = try Inner.listenTarget(&backend.platform, transport, listen) };
            if (backend.registration.config == null) return error.RelayRegistrationNotConfigured;
            const identity = listen.identity orelse return error.InvalidAddress;
            if (listen.designator.len != 0 and !std.mem.eql(u8, listen.designator, &identity.toDesignator())) return error.InvalidAddress;
            return .{ .relay = identity };
        }

        pub fn localLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?foundation.crypto.PeerKey,
            allocator: std.mem.Allocator,
        ) !model.PeerLocator {
            switch (try backend.listenerAddress(fd)) {
                .relay => {},
                .platform => return Inner.localLocator(&backend.platform, fd, transport, identity, allocator),
            }
            const config = backend.registration.config orelse return error.RelayRegistrationNotConfigured;
            const relay = backend.relay orelse return error.NoRendezvousConfigured;
            const hints = [_]model.HintEntry{.{
                .name = route.rendezvous_relay_hint,
                .value = .{ .string = relay.routes.relay_url_text },
            }};
            return model.clonePeerLocator(allocator, .{
                .transport = transport,
                .designator = &config.id,
                .hints = .{ .entries = &hints },
            });
        }

        /// A relay listener may name any valid relay that forwards to its
        /// registered key.
        pub fn canonicalizeLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?foundation.crypto.PeerKey,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) !model.PeerLocator {
            if (!isRelay(transport)) return Inner.canonicalizeLocator(&backend.platform, fd, transport, identity, allocator, candidate);
            model.validatePeerLocator(candidate) catch return error.InvalidAddress;
            const config = backend.registration.config orelse return error.RelayRegistrationNotConfigured;
            if (!std.mem.eql(u8, candidate.transport, transport) or !std.mem.eql(u8, candidate.designator, &config.id)) return error.InvalidAddress;
            _ = route.relayHint(candidate.hints) catch return error.InvalidAddress;
            return model.clonePeerLocator(allocator, candidate);
        }
    };
}
