//! The native TCP transport: one provider, three channel profiles.
//!
//! Plain `tcp`, identity-addressed `keyed-tcp`, and sealed `noise-tcp` share
//! one socket realization and differ only in locator posture and channel
//! profile. Their composition belongs here, beside that implementation. A
//! driver holds one `Provider` at a stable address and stores `netlayers()`;
//! it does not construct or enumerate the members itself.
//!
//! This provider is native-only because it owns `std.Io` socket residents.
//! A byte-fed host, including the wasm build, carries the same transport
//! symbols and sealed-channel profiles without pretending to own TCP sockets.

const std = @import("std");

const model = @import("model");
const netlayer = @import("../netlayer.zig");
const addressing = @import("tcp_addressing.zig");
pub const plain = @import("tcp_plain.zig");
const key_profile = @import("tcp_key_addressed.zig");
pub const keyed = key_profile.Profile(.keyed_tcp);
pub const noise = key_profile.Profile(.noise_tcp);

// Plain TCP is the namespace's default profile. Keep its stream primitives at
// `tcp.*` for the common case while the explicit `tcp.plain` spelling remains
// available beside `tcp.keyed`, `tcp.noise`, and `tcp.Provider`.
pub const Keepalive = plain.Keepalive;
pub const StreamOptions = plain.StreamOptions;
pub const RawConnection = plain.RawConnection;
pub const connectRaw = plain.connectRaw;
pub const ProfileListener = @import("tcp_listener.zig").Listener;
pub const connectionOver = plain.connectionOver;
pub const transport_name = model.transport.tcp;
pub const Error = addressing.Error;
pub const connectAddress = plain.connectAddress;
pub const designator_buf_len = plain.designator_buf_len;
pub const locator = plain.locator;
pub const locatorFromAddress = plain.locatorFromAddress;
pub const connect = plain.connect;
pub const connectFrameStream = plain.connectFrameStream;
pub const Listener = plain.Listener;
pub const Resident = plain.Resident;
pub const classifyConnect = plain.classifyConnect;
pub const acceptOnListener = plain.acceptOnListener;
pub const waitAcceptableOnListener = plain.waitAcceptableOnListener;
pub const parseHostPort = addressing.parseHostPort;
pub const parseDesignator = addressing.parseDesignator;
pub const DialResolver = addressing.DialResolver;
pub const resolveProfile = addressing.resolveProfile;

/// The complete archive-owned TCP profile inventory. Native and C projections
/// consume this one declaration; adding a profile cannot silently update only
/// one surface.
pub const profiles = [_]model.transport.Known{ .tcp, .keyed_tcp, .noise_tcp };

/// Defaults inherited by every stream this provider dials or accepts. A direct
/// TCP primitive still takes `StreamOptions` for a one-operation override; the
/// provider keeps the common case once, beside the socket runtime that applies
/// it. The library default leaves keepalive disabled.
pub const Config = struct {
    stream: StreamOptions = .{},
};

/// One dial or listener override. Passing this view selects these stream
/// settings for that operation; omitting it inherits `Provider` configuration.
/// An explicit `.stream = .{}` disables keepalive even when the provider
/// default enables it.
pub const OperationOptions = plain.OperationOptions;

/// One heap-pinned native realization of every TCP channel profile. The
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
