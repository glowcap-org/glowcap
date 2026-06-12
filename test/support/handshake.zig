//! Stub keyed-handshake vocabulary shared by the loopback tests.
//!
//! Test support (not a production module): the net_adapter and C ABI
//! loopback proofs all open their sessions with the same unsigned
//! `op:start-session` — zero key, zero signature, partner verification off —
//! because they prove transport and framing seams, not the handshake. The
//! stub message lives here once; tests that prove the real signed handshake
//! build their own.

const model = @import("pancake").ocapn.model;

pub const zero_pubkey = [_]u8{0} ** 32;
pub const zero_sig = [_]u8{0} ** 64;

/// The unsigned loopback `op:start-session`. The receiving peer must run
/// with `verify_partner_handshake = false`; a verifying peer refuses it.
pub fn startSession(transport: []const u8, designator: []const u8) model.Message {
    return .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &zero_pubkey },
        .acceptable_location = .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.emptyMap(),
        },
        .acceptable_location_sig = .{ .bytes = &zero_sig },
    } };
}
