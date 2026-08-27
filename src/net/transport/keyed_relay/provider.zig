//! Native composition of the keyed and Noise relay profiles.

const std = @import("std");

const foundation = @import("foundation");
const netlayer = @import("../../netlayer.zig");
const tls_runtime = @import("../../tls/runtime.zig");
const resident = @import("resident.zig");

/// One native realization of both relay channel profiles over the same
/// deployment rendezvous. Initialize only after the containing owner reaches
/// its final address: each netlayer context points at an inline resident.
pub const Provider = struct {
    keyed_resident: resident.Resident = undefined,
    noise_resident: resident.Resident = undefined,
    layers: [2]netlayer.Netlayer = undefined,

    pub fn init(
        self: *Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
    ) resident.Resident.InitError!void {
        self.keyed_resident = try resident.Resident.initProfile(allocator, io, relay_url, .keyed);
        self.noise_resident = self.keyed_resident.profileView(.noise);
        self.finishInit();
    }

    /// The TLS form with the default relay configuration. The native TLS
    /// provider (`native_mbedtls`) reaches `initConfiguredWithTls` with its own
    /// configuration; this default form is reached only by tests.
    pub fn initWithTls(
        self: *Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        tls: *tls_runtime.Runtime,
    ) resident.Resident.InitError!void {
        self.keyed_resident = try resident.Resident.initProfileWithTls(
            allocator,
            io,
            relay_url,
            .keyed,
            tls,
        );
        self.noise_resident = self.keyed_resident.profileView(.noise);
        self.finishInit();
    }

    /// Compose both relay profiles over one TLS-capable carrier. A null
    /// registration route is dial-only; a route defers listener identity to
    /// the Host that later calls the provider's listen seam.
    pub fn initConfiguredWithTls(
        self: *Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        relay_url: []const u8,
        register_url: ?[]const u8,
        tls: *tls_runtime.Runtime,
    ) resident.Resident.InitError!void {
        self.keyed_resident = if (register_url) |registration|
            try resident.Resident.initProviderProfile(
                allocator,
                io,
                relay_url,
                registration,
                .keyed,
                tls,
            )
        else
            try resident.Resident.initProfileWithTls(
                allocator,
                io,
                relay_url,
                .keyed,
                tls,
            );
        self.noise_resident = self.keyed_resident.profileView(.noise);
        self.finishInit();
    }

    fn finishInit(self: *Provider) void {
        self.layers = .{
            self.keyed_resident.netlayer(),
            self.noise_resident.netlayer(),
        };
    }

    pub fn deinit(self: *Provider) ?foundation.FailureChain {
        if (self.keyed_resident.carrier.releaseOwnerPairOutcome(
            &self.noise_resident.carrier,
        )) |failure| return failure;
        self.keyed_resident.config.release();
        self.noise_resident.config.release();
        self.* = undefined;
        return null;
    }

    pub fn netlayers(self: *Provider) []const netlayer.Netlayer {
        return &self.layers;
    }
};
