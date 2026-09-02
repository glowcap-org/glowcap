//! Blocking onion resident configuration.
//!
//! Every endpoint and credential is explicit because Glowcap neither starts
//! nor supervises Tor. The configuration is borrowed for the resident's
//! lifetime; provider archives and bindings own any copied projection.

const control = @import("control.zig");

pub const Config = struct {
    /// Tor's SOCKS endpoint, as `/path/to/socket` or `host:port`.
    socks: []const u8,
    /// Tor's control endpoint in the same forms. Empty means dial-only.
    control_endpoint: []const u8 = &.{},
    /// How the control endpoint expects to be authenticated.
    auth: control.Auth = .none,
    /// The service key returned by Tor, or empty to mint a fresh service.
    service_key: []const u8 = &.{},
    /// The local target Tor forwards to. Empty binds a loopback port.
    forward: []const u8 = &.{},
};
