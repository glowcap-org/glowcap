//! The Affordance: the published actor whose every invocation the host accounts
//! for, and the caller-side attestation it verifies.
//!
//! This is the load-bearing claim of the whole application, so it lives in one
//! place: the in-process host (`main.zig`), the standalone host (`host.zig`),
//! and the three-party attribution test (`three_party_test.zig`) all publish
//! this same behavior rather than transcribing the verify path three times.
//!
//! Attribution is attested, not trusted. The caller signs a canonical preimage
//! over the request with its KERI key and presents its verkey; the host verifies
//! the signature before it records an Outcome Episode, and refuses — as a clean
//! broken promise — anything it cannot attribute.

const std = @import("std");
const pancake = @import("pancake");

const identity = @import("identity.zig");
const accountable = @import("accountable.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;

const enc = std.base64.url_safe_no_pad.Encoder;

/// The name the host publishes the Affordance under and callers fetch it by.
pub const AFFORDANCE_NAME = "affordance";

/// The maximum wire frame the demo peers admit. One value, shared by every host.
pub const frame_cap: usize = 1 << 16;

/// The root the demo stores its `.data/` under; each host owns a subdirectory.
pub const data_root = "apps/accountability-on-pancake/.data";

/// The single verb the Affordance answers.
pub const invoke_verb = "invoke";

/// The signed preimage that binds a caller to a request. The caller signs it; the
/// host verifies it before attributing an Episode. Signer and host must hash the
/// same bytes, so the form is fixed here.
pub fn attestation(buf: []u8, request: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "invoke|{s}", .{request}) catch unreachable;
}

pub fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

/// The four string arguments an `invoke` carries, encoded once from a signing
/// key and a request. `tamper` corrupts the signature so the host must refuse to
/// attest it — the path that has to surface as a clean broken promise.
pub const Attestation = struct {
    /// The caller's verkey, `D`-coded base64url (44 bytes).
    verkey: [1 + enc.calcSize(32)]u8,
    /// The signature over the request preimage, base64url-no-pad (86 bytes).
    signature: [enc.calcSize(64)]u8,

    pub fn sign(key: identity.Key, request: []const u8, tamper: bool) Attestation {
        var att_buf: [512]u8 = undefined;
        const att = attestation(&att_buf, request);
        var sig = key.sign(att);
        if (tamper) sig[0] ^= 0xff;

        var self: Attestation = undefined;
        _ = enc.encode(&self.signature, &sig);
        self.verkey[0] = 'D';
        _ = enc.encode(self.verkey[1..], &key.verkey());
        return self;
    }
};

/// A published Affordance bound to one accountability store. Every verified
/// invocation records an Outcome Episode attributing the true caller and, when
/// `last_subject` is set, captures that caller's AID for the demo to assert on.
pub const Affordance = struct {
    store: *accountable.Store,
    served: *usize,
    /// Optional attribution capture: the standalone host leaves it null.
    last_subject: ?*[identity.SAID_LEN]u8 = null,

    pub fn handle(self: *Affordance, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, invoke_verb)) return error.NoSuchMethod;
        if (msg.args.len != 4) return error.BadInvocation;
        const subject = strArg(msg.args[0]) orelse return error.BadInvocation;
        const verkey_b64 = strArg(msg.args[1]) orelse return error.BadInvocation;
        const request = strArg(msg.args[2]) orelse return error.BadInvocation;
        const sig_b64 = strArg(msg.args[3]) orelse return error.BadInvocation;

        // The subject is a fixed-width AID; a peer that sends a short one is
        // malformed, not attributable. Validate before the fixed-size copy below.
        if (subject.len != identity.SAID_LEN) return error.BadInvocation;

        // Attribution is attested, not trusted. Verify the caller's signature
        // over the request against the presented verkey; refuse otherwise.
        const verkey = identity.decodeVerkey(verkey_b64) catch return error.UnattestedCaller;
        const sig = identity.decodeSig(sig_b64) catch return error.UnattestedCaller;
        var att_buf: [512]u8 = undefined;
        const att = attestation(&att_buf, request);
        identity.verify(verkey, att, sig) catch return error.UnattestedCaller;

        // The capability invocation succeeds; account for it.
        const result = try std.fmt.allocPrint(turn.arena, "ack:{s}", .{request});
        _ = try self.store.record(.outcome, subject, "demo", result);
        self.served.* += 1;
        if (self.last_subject) |dst| @memcpy(dst, subject[0..identity.SAID_LEN]);
        return .{ .string = result };
    }
};
