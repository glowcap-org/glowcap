//! Pure dial and accept planning: the transport dispatch, designator
//! validation, host:port resolution, and reachability decision that every
//! language binding used to re-express in its own `connect` / `dial_exporter`
//! and `Server.accept`. It is sans-io — it decides *what* to dial or sign, and
//! the caller opens the byte channel — so it lives in `driver_core` under the
//! I/O ban and reuses the one policy table `vocab` already owns
//! (`designatorSchemeForTransport`, `requiresDirectAddressesHint`) and the one
//! host:port grammar `model.uri.splitHostPort` already defines. Nothing here
//! parses a URI or re-encodes those rules; it composes them. The native
//! `driver.connect` dials the same three transports through a netlayer vtable
//! instead, so this is that path's byte-fed twin, not a second copy of its
//! rules.
//!
//! Every returned view borrows the caller's `transport` / `designator` / hint
//! buffers (or, for a missing accept address, a static placeholder). The plan
//! is a value; the caller holds the inputs across the open.

const std = @import("std");

const model = @import("model");
const vocab = @import("vocab.zig");

pub const Error = error{
    /// The locator names a transport this planner does not dial (only `tcp`,
    /// `keyed-tcp`, and `iroh` are dialable here).
    UnknownTransport,
    /// A `tcp` designator, or the first entry of a `keyed-tcp` direct-addresses
    /// hint, is not the `host:port` grammar.
    DesignatorNotHostPort,
    /// A `keyed-tcp` dial has no direct-addresses hint to dial: the key
    /// designator says who to trust, and the hint says where to reach them, so
    /// a keyed-tcp dial cannot proceed without it.
    MissingDirectAddressesHint,
    /// An `iroh` `connect` named no reachability posture. There is no default:
    /// a caller dialing an iroh locator must choose how the endpoint becomes
    /// reachable.
    ReachabilityRequired,
};

/// Which byte channel the caller opens for a resolved dial. `host_port` covers
/// `tcp` and `keyed-tcp` (a TCP socket to `host:port`); `iroh` covers an iroh
/// endpoint dialed by node id.
pub const Shape = enum { host_port, iroh };

/// The iroh reachability posture a resolved dial uses. The planner makes the
/// decision every binding used to duplicate; the caller maps each arm onto its
/// own reachability value. `direct` is the relay-less posture a hinted redeem
/// takes; `configured` is the node's own redeem posture, which is caller state
/// the planner cannot see; `explicit` is the posture a `connect` caller named.
pub const Reach = union(enum) {
    direct,
    configured,
    explicit: u32,
};

/// A resolved dial: what to open and what to sign. Views borrow the planner's
/// inputs. `reach` is set only on the `iroh` shape.
pub const DialPlan = struct {
    transport: []const u8,
    designator: []const u8,
    shape: Shape,
    host: []const u8 = &.{},
    port: u16 = 0,
    addresses: []const u8 = &.{},
    reach: ?Reach = null,
};

/// The reachability policy the two dial spines differ on. A redeem (a DIAL
/// action) takes the relay-less `direct` posture when it has a hint and the
/// node's configured posture otherwise; a `connect` takes the caller's posture
/// and refuses when none was named.
pub const Posture = union(enum) {
    redeem,
    explicit: ?u32,
};

/// The first entry of a comma-separated direct-addresses hint, trimmed. A
/// `keyed-tcp` hint carries the one address to dial; an implementation that
/// published several picks the first. Returns a sub-slice of `hint`.
fn firstAddress(hint: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, hint, ',') orelse hint.len;
    return std.mem.trim(u8, hint[0..comma], " \t");
}

/// Resolve a dial. `transport` and `designator` are the locator's pieces (a
/// DIAL action already carries them parsed); `direct_addresses_hint` is the
/// locator's `direct-addresses` hint, empty when there is none; `posture`
/// selects the iroh reachability policy.
pub fn planDial(
    transport: []const u8,
    designator: []const u8,
    direct_addresses_hint: []const u8,
    posture: Posture,
) Error!DialPlan {
    if (std.mem.eql(u8, transport, model.transport.tcp)) {
        // The address designator is itself the host:port to dial.
        const hp = model.uri.splitHostPort(designator) catch return Error.DesignatorNotHostPort;
        return .{
            .transport = transport,
            .designator = designator,
            .shape = .host_port,
            .host = hp.host,
            .port = hp.port,
        };
    }

    if (std.mem.eql(u8, transport, model.transport.keyed_tcp)) {
        // The key designator pins the partner's identity; the socket address
        // rides the hint (keyed TCP has no discovery).
        if (direct_addresses_hint.len == 0) return Error.MissingDirectAddressesHint;
        const first = firstAddress(direct_addresses_hint);
        if (first.len == 0) return Error.MissingDirectAddressesHint;
        const hp = model.uri.splitHostPort(first) catch return Error.DesignatorNotHostPort;
        return .{
            .transport = transport,
            .designator = designator,
            .shape = .host_port,
            .host = hp.host,
            .port = hp.port,
        };
    }

    if (std.mem.eql(u8, transport, model.transport.iroh)) {
        // The key designator is the node id; the direct addresses ride the hint
        // verbatim, and the reachability posture follows the caller's policy.
        const reach: Reach = switch (posture) {
            .redeem => if (direct_addresses_hint.len != 0) .direct else .configured,
            .explicit => |p| .{ .explicit = p orelse return Error.ReachabilityRequired },
        };
        return .{
            .transport = transport,
            .designator = designator,
            .shape = .iroh,
            .addresses = direct_addresses_hint,
            .reach = reach,
        };
    }

    return Error.UnknownTransport;
}

/// What an accepted CapTP session signs as its own locator: the designator a
/// partner names it by, and the direct-addresses hint that names where to reach
/// it. Views borrow the caller's inputs, except the address-transport
/// empty-address fallback, which is the static unreachable-client placeholder.
pub const AcceptPlan = struct {
    designator: []const u8,
    direct_addresses_hint: []const u8 = &.{},
};

/// Resolve what an accepted CapTP session signs. `server_designator` is the
/// listener's own signing designator (its key for a key transport; unused for
/// an address transport, which signs the accepted address). `accepted_local_addr`
/// is the address the accept reported, empty when unavailable.
///
/// An address transport (`tcp`, `inproc`) signs the accepted address itself, or
/// the unreachable-client placeholder when the accept reported none, and carries
/// no hint. A key transport signs its own key designator; `keyed-tcp` puts the
/// accepted address in the hint (a partner dials it there), while `iroh` carries
/// no hint (discovery resolves the node id).
pub fn planAccept(
    transport: []const u8,
    server_designator: []const u8,
    accepted_local_addr: []const u8,
) AcceptPlan {
    return switch (vocab.designatorSchemeForTransport(transport)) {
        .address => .{
            .designator = if (accepted_local_addr.len != 0)
                accepted_local_addr
            else
                vocab.unreachable_client_designator,
        },
        .key => .{
            .designator = server_designator,
            .direct_addresses_hint = if (vocab.requiresDirectAddressesHint(transport))
                accepted_local_addr
            else
                &.{},
        },
    };
}
