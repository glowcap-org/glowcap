//! The Zig TCP transport: one provider, three channel profiles.
//!
//! Plain `tcp`, identity-addressed `keyed-tcp`, and sealed `noise-tcp` share
//! one socket realization and differ only in locator posture and channel
//! profile. Their composition belongs here, beside that implementation. A
//! driver holds one `Provider` at a stable address and stores `netlayers()`.
//! It does not construct or enumerate the members itself.
//!
//! This provider is Zig-only because it owns `std.Io` socket residents.
//! A byte-fed host, including the wasm build, carries the same transport
//! symbols and sealed-channel profiles without pretending to own TCP sockets.

const std = @import("std");

const model = @import("model");
const netlayer = @import("../netlayer.zig");
const addressing = @import("tcp/addressing.zig");
const profile = @import("tcp/profile.zig");
const stream = @import("tcp/stream.zig");
pub const plain = profile.Profile(.tcp);
pub const keyed = profile.Profile(.keyed_tcp);
pub const noise = profile.Profile(.noise_tcp);

// Plain TCP is the namespace's default profile. Its byte-stream primitives and
// typed listener sit at `tcp.*` for the common case, while `tcp.plain` names
// its resident beside `tcp.keyed`, `tcp.noise`, and `tcp.Provider`.
pub const Keepalive = stream.Keepalive;
pub const StreamOptions = stream.StreamOptions;
pub const RawConnection = stream.RawConnection;
pub const ConnectRawError = stream.ConnectRawError;
pub const connectRaw = stream.connectRaw;
pub const ProfileListener = @import("tcp/listener.zig").Listener;
pub const transport_name = model.transport.tcp;
pub const Error = addressing.Error;
pub const connectAddress = stream.connectAddress;
pub const designator_buf_len = stream.designator_buf_len;
pub const locator = stream.locator;
pub const locatorFromAddress = stream.locatorFromAddress;
pub const connect = stream.connect;
pub const connectFrameStream = stream.connectFrameStream;
pub const Listener = stream.Listener;
pub const Resident = plain.Resident;
pub const classifyConnect = stream.classifyConnect;
pub const parseHostPort = addressing.parseHostPort;
pub const parseDesignator = addressing.parseDesignator;
pub const DialResolver = addressing.DialResolver;
pub const resolveProfile = addressing.resolveProfile;
pub const CompletionPolicy = @import("tcp/completion_policy.zig").Policy;

/// The complete archive-owned TCP profile inventory. Zig and C projections
/// consume this one declaration. Adding a profile cannot silently update only
/// one surface.
pub const profiles = [_]model.transport.Known{ .tcp, .keyed_tcp, .noise_tcp };

/// Defaults inherited by every stream this provider dials or accepts. A direct
/// TCP primitive still takes `StreamOptions` for a one-operation override. The
/// provider keeps the common case once, beside the socket runtime that applies
/// it. The library default leaves keepalive disabled.
pub const Config = struct {
    stream: StreamOptions = .{},
};

/// One dial or listener override. Passing this view selects these stream
/// settings for that operation. Omitting it inherits `Provider` configuration.
/// An explicit `.stream = .{}` disables keepalive even when the provider
/// default enables it.
pub const OperationOptions = stream.OperationOptions;

/// One heap-pinned Zig realization of every TCP channel profile. The
/// netlayer vtables borrow its resident fields, so `create` makes moving the
/// owner impossible and `destroy` names the one setup allocation explicitly.
pub const Provider = struct {
    plain_resident: plain.Resident,
    keyed_resident: keyed.Resident,
    noise_resident: noise.Resident,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, config: Config) !*Provider {
        const self = try allocator.create(Provider);
        self.* = .{
            .plain_resident = .{ .io = io, .stream_options = config.stream },
            .keyed_resident = .{ .io = io, .stream_options = config.stream },
            .noise_resident = .{ .io = io, .stream_options = config.stream },
        };
        return self;
    }

    pub fn destroy(self: *Provider, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    /// Return the complete borrowed profile set. The caller stores this array
    /// for at least as long as the runtime that consumes its slice.
    pub fn netlayers(self: *Provider) [profiles.len]netlayer.Netlayer {
        return .{
            self.plain_resident.netlayer(),
            self.keyed_resident.netlayer(),
            self.noise_resident.netlayer(),
        };
    }
};
