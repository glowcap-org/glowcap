//! Fixed C vocabulary for the onion provider archive.

const net = @import("net");

pub const GlowcapOnionNetlayer = opaque {};
pub const GlowcapOnionConn = opaque {};
pub const GlowcapOnionListener = opaque {};

/// How the Tor control endpoint expects to be authenticated.
pub const GLOWCAP_ONION_AUTH_NONE: u32 = 0;
pub const GLOWCAP_ONION_AUTH_COOKIE: u32 = 1;
pub const GLOWCAP_ONION_AUTH_PASSWORD: u32 = 2;

/// Bounds callers use when allocating restoration-state buffers.
pub const GLOWCAP_ONION_SERVICE_ID_LEN: usize = 56;
pub const GLOWCAP_ONION_SERVICE_KEY_CAP: usize = net.onion.session.service_key_cap;

/// Everything the netlayer needs to reach Tor, and what to ask for when hosting.
///
/// Every pointer is borrowed only for construction and copied into the runtime.
/// `socks` is required. An empty `control_endpoint` creates a dial-only runtime.
/// An empty `service_key` asks Tor for a fresh service; an empty `forward` asks
/// glowcap to bind the local loopback endpoint Tor will forward to.
pub const GlowcapOnionConfig = extern struct {
    socks: ?[*]const u8 = null,
    socks_len: usize = 0,
    control_endpoint: ?[*]const u8 = null,
    control_endpoint_len: usize = 0,
    auth_kind: u32 = GLOWCAP_ONION_AUTH_NONE,
    auth_secret: ?[*]const u8 = null,
    auth_secret_len: usize = 0,
    service_key: ?[*]const u8 = null,
    service_key_len: usize = 0,
    forward: ?[*]const u8 = null,
    forward_len: usize = 0,
};
