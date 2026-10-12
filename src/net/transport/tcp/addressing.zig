//! Locator admission shared by every profile backed by TCP.
//!
//! This module owns the only conversion from OCapN transport/designator/hint
//! vocabulary to a socket address. Socket creation stays in `runtime.zig` and
//! `stream.zig`. Callers cannot reach it through a locator without passing
//! this admission.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const netlayer = @import("../../netlayer.zig");

const IpAddress = std.Io.net.IpAddress;

pub const Error = error{
    InvalidAddress,
    UnknownTransport,
};

/// Resolve a host literal (IPv4 / IPv6, unbracketed) and port.
pub fn parseHostPort(host: []const u8, port: u16) Error!IpAddress {
    return IpAddress.parse(host, port) catch Error.InvalidAddress;
}

/// Parse the canonical `host:port` designator used by TCP listeners.
pub fn parseDesignator(designator: []const u8) Error!IpAddress {
    const split = model.uri.splitHostPort(designator) catch return Error.InvalidAddress;
    return parseHostPort(split.host, split.port);
}

/// Resolve one TCP-backed locator to its socket address. Plain `tcp` carries
/// the address in its designator. `keyed-tcp` and `noise-tcp` carry a canonical
/// peer key there and require the address hint.
pub const DialResolver = struct {
    pub fn resolve(
        locator: model.PeerLocator,
    ) Error!IpAddress {
        const known = model.transport.parseKnown(locator.transport) orelse return Error.UnknownTransport;
        return resolveProfile(
            known.metadata(),
            locator.designator,
            netlayer.directAddrHint(locator.hints) orelse "",
        );
    }
};

/// Resolve from an already-selected provider profile. Transport packages use
/// this entry so implementation does not re-dispatch on its own symbol.
pub fn resolveProfile(
    profile: model.transport.Metadata,
    designator: []const u8,
    direct_addresses_hint: []const u8,
) Error!IpAddress {
    if (profile.dial_shape != .host_port or profile.address_source == .none)
        return Error.UnknownTransport;
    if (profile.designator_scheme == .key and crypto.PeerKey.fromDesignator(designator) == null)
        return Error.InvalidAddress;
    const hp = model.uri.connectHostPort(profile, designator, direct_addresses_hint) catch
        return Error.InvalidAddress;
    return parseHostPort(hp.host, hp.port);
}
