//! The native TCP transport: one provider, three channel profiles.
//!
//! Plain `tcp`, identity-addressed `keyed-tcp`, and sealed `noise-tcp` share
//! one socket realization and differ only in locator posture and channel
//! profile. Their composition belongs here, beside that implementation. A
//! driver holds one `Provider` at a stable address and consumes `netlayers()`;
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
pub const at = plain.at;
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

/// One heap-stable native realization of every TCP channel profile.
/// Initialize only after the containing owner reaches its final address: each
/// netlayer context points at the corresponding inline resident.
pub const Provider = struct {
    plain_resident: plain.Resident,
    keyed_resident: keyed.Resident,
    noise_resident: noise.Resident,
    layers: [3]netlayer.Netlayer,

    pub fn init(self: *Provider, io: std.Io) void {
        self.plain_resident = .{ .io = io };
        self.keyed_resident = .{ .io = io };
        self.noise_resident = .{ .io = io };
        self.layers = .{
            self.plain_resident.netlayer(),
            self.keyed_resident.netlayer(),
            self.noise_resident.netlayer(),
        };
    }

    pub fn netlayers(self: *Provider) []const netlayer.Netlayer {
        return &self.layers;
    }
};
