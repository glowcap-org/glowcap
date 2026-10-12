//! Keyed-handshake vocabulary shared by the tests that do not build hellos the
//! way production does.
//!
//! Test support, not a production module. Two shapes live here. The net and C
//! ABI loopback tests open their sessions with the same unsigned
//! `op:start-session`: zero key, zero signature, and partner verification off,
//! because they prove transport and framing seams, not the handshake. The
//! refusal matrices instead need a *validly signed* hello carrying exactly the
//! hints they name, including hints a peer this project wrote would refuse to
//! send, so `signedHelloFrame` builds one the way an untrusted or mistaken
//! partner would: message first, with exactly the requested hint list.
//! `engine.Peer.sendKeyedStartSession` is the production builder and is under
//! both disciplines, which is why it cannot serve these arms.

const std = @import("std");

const glowcap = @import("glowcap");
const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const crypto = foundation.crypto;

pub const zero_pubkey = @as([32]u8, @splat(0));
pub const zero_sig = @as([64]u8, @splat(0));

/// The unsigned loopback `op:start-session`. The receiving peer must run
/// with `verify_partner_handshake = false`. A verifying peer refuses it.
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

/// One validly signed keyed `op:start-session` frame carrying exactly `hints`,
/// returned owned. The location signature is real, so an arm that feeds this
/// isolates whatever it means to test rather than riding a broken hello.
/// `secret` is the fresh session signing key.
///
/// `hints` is the whole hint list. A production hello goes through
/// `engine.Peer.advertisedLocator`, which stamps this peer's preferred CapTP
/// version and codec into the signed location, so every hello built here
/// carries no preference hints and its partner reads it as a peer asking for
/// the interop baseline unless the test supplies those hints explicitly.
pub fn signedHelloFrame(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    transport: []const u8,
    designator: []const u8,
    hints: model.Hints,
) !foundation.Frame {
    const locator: model.PeerLocator = .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
    const signed = try codec.signed.locationBytes(allocator, locator);
    defer allocator.free(signed);
    const sig = crypto.sign(&secret, signed);
    return codec.syrup.encodeMessageForProfile(allocator, .v1_0, .{ .start_session = .{
        .captp_version = model.Preference.baseline.captp_version,
        .session_pubkey = .{ .bytes = secret.publicKey().asBytes() },
        .acceptable_location = locator,
        .acceptable_location_sig = .{ .bytes = sig.asBytes() },
    } });
}
