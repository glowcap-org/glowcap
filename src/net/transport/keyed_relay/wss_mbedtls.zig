//! Optional WSS relay composition over Glowcap's pinned Mbed TLS engine.
//!
//! This module is a separately composed public Zig module. The portable
//! `glowcap` module does not import or link Mbed TLS. Zig programs and
//! the relay C archive consume this same owner. It lives with the relay subject
//! because the archive is a projection of that provider, not a second transport
//! authority.

const std = @import("std");

const foundation = @import("foundation");
const tls_mbedtls = @import("tls_mbedtls");
const net = @import("net");

pub const Trust = tls_mbedtls.Trust;
pub const TrustSummary = tls_mbedtls.TrustSummary;
pub const max_trust_bytes = tls_mbedtls.max_trust_bytes;

pub const InitFailure = union(enum) {
    tls: net.tls.engine.Failure,
    relay: foundation.FailureChain,

    pub fn chain(self: *const InitFailure) *const foundation.FailureChain {
        return switch (self.*) {
            .tls => |*failure| &failure.chain,
            .relay => |*failure| failure,
        };
    }
};

pub const InitOutcome = union(enum) {
    ready: TrustSummary,
    failed: InitFailure,
};

pub const TlsOwnerOutcome = union(enum) {
    ready: struct { owner: net.tls.runtime_owner.Owner, trust: TrustSummary },
    failed: InitFailure,
};

/// The Mbed TLS runtime a completion relay backend leases
/// (`RelayOptions.tls_owner`). The caller releases the owner after every
/// backend holding a lease has retired.
pub fn initTlsOwner(io: std.Io, allocator: std.mem.Allocator, trust: Trust) TlsOwnerOutcome {
    const initialized = switch (tls_mbedtls.init(io, allocator, trust)) {
        .ready => |ready| ready,
        .failed => |failure| return .{ .failed = .{ .tls = failure } },
    };
    var runtime = initialized.runtime;
    const owner = net.tls.runtime_owner.Owner.init(allocator, &runtime) catch |err| {
        var failure = foundation.FailureChain.init(err);
        if (runtime.deinitOutcome()) |cleanup| failure.noteChain(cleanup);
        return .{ .failed = .{ .relay = failure } };
    };
    return .{ .ready = .{ .owner = owner, .trust = initialized.trust } };
}

/// One address-stable owner for both relay profiles, their carrier,
/// and the immutable trust snapshot below them.
pub const Provider = struct {
    relay: net.relay.Provider = undefined,

    /// Construct after `self` reaches its final address. All input bytes are
    /// borrowed only for this call. Refusal leaves no live state in `self`.
    /// The ready outcome carries the trust-load result once. The provider
    /// retains no copy of it.
    pub fn init(
        self: *Provider,
        io: std.Io,
        allocator: std.mem.Allocator,
        configuration: net.relay.Configuration,
        trust: Trust,
    ) InitOutcome {
        configuration.validate() catch
            return .{ .failed = .{ .relay = .init(error.InvalidRelayUrl) } };

        const initialized = switch (tls_mbedtls.init(io, allocator, trust)) {
            .ready => |ready| ready,
            .failed => |failure| return .{ .failed = .{ .tls = failure } },
        };
        var tls = initialized.runtime;
        self.relay.initConfiguredWithTls(
            allocator,
            io,
            configuration,
            &tls,
        ) catch |err| {
            var failure = foundation.FailureChain.init(err);
            if (tls.deinitOutcome()) |cleanup| failure.noteChain(cleanup);
            return .{ .failed = .{ .relay = failure } };
        };
        return .{ .ready = initialized.trust };
    }

    pub fn netlayers(self: *Provider) []const net.netlayer.Netlayer {
        return self.relay.netlayers();
    }

    pub fn resident(self: *Provider, profile: net.relay.ChannelProfile) *net.relay.Resident {
        return switch (profile) {
            .keyed => &self.relay.keyed_resident,
            .noise => &self.relay.noise_resident,
        };
    }

    pub fn sameConfiguration(self: *const Provider, other: *const Provider) bool {
        return self.relay.keyed_resident.sameConfiguration(&other.relay.keyed_resident);
    }

    /// The relay carrier owns the transferred TLS runtime. Its combined owner
    /// barrier is retryable and consumes this wrapper only on success.
    pub fn deinit(self: *Provider) ?foundation.FailureChain {
        if (self.relay.deinit()) |failure| return failure;
        self.* = undefined;
        return null;
    }
};
