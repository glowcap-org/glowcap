//! Locator helpers every resident shares: the designator scheme, the
//! direct-address hint, and fixed-identity canonicalization.

const std = @import("std");

const model = @import("model");

pub const DesignatorScheme = model.transport.DesignatorScheme;
pub const hint_direct_addresses = model.transport.hint_direct_addresses;

/// The locator's direct-address string hint, or null when it is absent or has
/// a different value kind.
pub fn directAddrHint(hints: model.Hints) ?[]const u8 {
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, hint_direct_addresses)) continue;
        switch (entry.value) {
            .string => |s| return s,
            else => return null,
        }
    }
    return null;
}

/// Clone a validated locator only when its immutable transport identity matches
/// the listener that is canonicalizing it.
pub fn canonicalizeFixedLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    expected_transport: []const u8,
    expected_designator: []const u8,
) (error{InvalidAddress} || std.mem.Allocator.Error)!model.PeerLocator {
    model.validatePeerLocator(locator) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, locator.transport, expected_transport) or
        !std.mem.eql(u8, locator.designator, expected_designator))
        return error.InvalidAddress;
    return model.clonePeerLocator(allocator, locator);
}
