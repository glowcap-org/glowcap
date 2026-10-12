//! What a TCP-backed listener advertises, for every owner of one.
//!
//! Address-designated TCP publishes its bound address as the designator.
//! Key-designated TCP publishes the durable peer key there and the bound
//! address as its direct-addresses hint. A listener's replacement locator
//! answers to the same grammar: it keeps the listener's key and must resolve.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const netlayer = @import("../../netlayer.zig");
const addressing = @import("addressing.zig");

const IpAddress = std.Io.net.IpAddress;

pub const designator_buf_len = 64;

/// The locator a `profile` listener bound at `address` publishes, owned by
/// `allocator`. `identity` is required exactly when the profile is
/// key-designated.
pub fn locator(
    allocator: std.mem.Allocator,
    profile: model.transport.Metadata,
    address: IpAddress,
    identity: ?crypto.PeerKey,
) error{ InvalidAddress, OutOfMemory }!model.PeerLocator {
    var address_storage: [designator_buf_len]u8 = undefined;
    const bound = std.fmt.bufPrint(&address_storage, "{f}", .{address}) catch unreachable;
    var identity_storage: [crypto.PeerKey.designator_len]u8 = undefined;
    const designator: []const u8 = switch (profile.designator_scheme) {
        .address => bound,
        .key => blk: {
            identity_storage = (identity orelse return error.InvalidAddress).toDesignator();
            break :blk &identity_storage;
        },
    };
    var hint_storage: [1]model.HintEntry = undefined;
    const hints = if (profile.address_source == .direct_addresses_hint)
        model.Hints.forDirectAddresses(bound, &hint_storage)
    else
        model.Hints.emptyFalse();
    return model.clonePeerLocator(allocator, .{
        .transport = profile.symbol,
        .designator = designator,
        .hints = hints,
    });
}

/// Admit `candidate` as a replacement publication for a `profile` listener
/// serving `identity`. Address-designated TCP may publish a different
/// reachable address (for example after NAT discovery). Key-designated
/// profiles keep the listener's durable identity and require a dialable
/// address hint.
pub fn validate(
    profile: model.transport.Metadata,
    identity: ?crypto.PeerKey,
    candidate: model.PeerLocator,
) error{InvalidAddress}!void {
    model.validatePeerLocator(candidate) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, candidate.transport, profile.symbol)) return error.InvalidAddress;
    if (profile.designator_scheme == .key) {
        const expected = (identity orelse return error.InvalidAddress).toDesignator();
        if (!std.mem.eql(u8, candidate.designator, &expected)) return error.InvalidAddress;
    }
    _ = addressing.resolveProfile(
        profile,
        candidate.designator,
        netlayer.directAddrHint(candidate.hints) orelse "",
    ) catch return error.InvalidAddress;
}
