//! Relay package configuration and its complete profile inventory.

const std = @import("std");
const model = @import("model");
const net = @import("net");

pub const GLOWCAP_RELAY_CONFIG_ABI_VERSION: u32 = 1;
pub const GLOWCAP_RELAY_TRUST_SYSTEM: u32 = 0;
pub const GLOWCAP_RELAY_TRUST_COPIED_PEM: u32 = 1;

/// Deployment configuration shared by both relay profiles. The resident
/// copies the URL text it needs; this ABI borrows the fields for construction.
pub const GlowcapRelayConfig = extern struct {
    abi_version: u32 = GLOWCAP_RELAY_CONFIG_ABI_VERSION,
    struct_size: usize = @sizeOf(GlowcapRelayConfig),
    relay_url: ?[*]const u8 = null,
    relay_url_len: usize = 0,
    register_url: ?[*]const u8 = null,
    register_url_len: usize = 0,
    trust: u32 = GLOWCAP_RELAY_TRUST_SYSTEM,
    trust_pem: ?[*]const u8 = null,
    trust_pem_len: usize = 0,
};

pub const GlowcapRelayTrustSummary = extern struct {
    loaded: usize = 0,
    skipped_by_engine: usize = 0,
    first_skipped_engine_code: i32 = 0,
};

pub const Profile = net.relay.ChannelProfile;
pub const profile_count = @typeInfo(Profile).@"enum".field_names.len;

pub fn metadata(profile: Profile) model.transport.Metadata {
    return profile.known().metadata();
}

pub fn forTransport(transport: []const u8) ?Profile {
    if (std.mem.eql(u8, transport, model.transport.keyed_relay)) return .keyed;
    if (std.mem.eql(u8, transport, model.transport.noise_relay)) return .noise;
    return null;
}
