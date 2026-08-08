//! The Affordance: the published actor whose every invocation the host accounts
//! for, and the caller-side attestation it verifies.
//!
//! This is the load-bearing claim of the whole application, so it lives in one
//! place: the in-process host (`main.zig`), the standalone host (`host.zig`),
//! and the three-party attribution test (`three_party_test.zig`) all publish
//! this same behavior rather than transcribing the verify path three times.
//!
//! Attribution is attested, not trusted. The caller signs a canonical preimage
//! over the request with its KERI key, and presents that verkey together with
//! the key event log that binds it to the AID it claims. The host checks both
//! before it records an Outcome Episode, and refuses — as a clean broken
//! promise — anything it cannot attribute.

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

/// Environment override for gate runs that must not dirty the source tree.
pub const data_root_env = "PANCAKE_ACCOUNTABILITY_DATA_ROOT";
/// The root the public demo stores its `.data/` under; each host owns a
/// subdirectory.
pub const default_data_root = "apps/accountability-on-pancake/.data";

pub fn dataRoot(init: std.process.Init) []const u8 {
    return init.environ_map.get(data_root_env) orelse default_data_root;
}

/// The single verb the Affordance answers.
pub const invoke_verb = "invoke";

/// The signed preimage that binds a caller to the subject it claims and to the
/// request it is making. The caller signs it; the host verifies it before
/// attributing an Episode. Signer and host must hash the same bytes, so the form
/// is fixed here.
///
/// The subject is in the preimage because the Episode attributes it: a captured
/// (verkey, request, signature) triple cannot be re-presented under a different
/// AID, because the AID is part of what was signed. A caller signing under its
/// own key while naming an AID it does not control is caught one step later, by
/// the key event log it has to present alongside this signature.
///
/// The request arrives from the wire and can be as large as a frame, so the
/// preimage is allocated rather than built in a fixed buffer. Callers pass a
/// scratch allocator; the host passes its turn arena.
/// The subject is a fixed-width AID rather than a slice, so the two fields
/// cannot run together. With both unbounded, `("a|b", "c")` and `("a", "b|c")`
/// would sign identical bytes; the width is what makes the split unambiguous,
/// and it belongs here rather than in whichever caller happens to check it.
pub fn attestation(
    allocator: std.mem.Allocator,
    subject: *const [identity.SAID_LEN]u8,
    request: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "invoke|{s}|{s}", .{ subject, request });
}

pub fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

/// The signed part of an `invoke`, encoded once from a signing key and a
/// request: the verkey the caller presents and its signature over the preimage.
/// `tamper` corrupts the signature so the host must refuse to attest it — the
/// path that has to surface as a clean broken promise.
pub const Attestation = struct {
    /// The caller's verkey, `D`-coded base64url (44 bytes).
    verkey: [1 + enc.calcSize(32)]u8,
    /// The signature over the request preimage, base64url-no-pad (86 bytes).
    signature: [enc.calcSize(64)]u8,

    pub fn sign(
        allocator: std.mem.Allocator,
        key: identity.Key,
        subject: *const [identity.SAID_LEN]u8,
        request: []const u8,
        tamper: bool,
    ) std.mem.Allocator.Error!Attestation {
        const att = try attestation(allocator, subject, request);
        defer allocator.free(att);
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
        if (msg.args.len != 5) return error.BadInvocation;
        const subject = strArg(msg.args[0]) orelse return error.BadInvocation;
        const verkey_b64 = strArg(msg.args[1]) orelse return error.BadInvocation;
        const request = strArg(msg.args[2]) orelse return error.BadInvocation;
        const sig_b64 = strArg(msg.args[3]) orelse return error.BadInvocation;
        const kel = strArg(msg.args[4]) orelse return error.BadInvocation;

        // The subject is a fixed-width AID; a peer that sends a short one is
        // malformed, not attributable. Validate before the fixed-size copy below.
        if (subject.len != identity.SAID_LEN) return error.BadInvocation;

        // First: whoever holds the presented key signed this exact subject and
        // request. Because the subject is in the signed bytes, a captured
        // signature cannot be re-presented under a different AID.
        const verkey = identity.decodeVerkey(verkey_b64) catch return error.UnattestedCaller;
        const sig = identity.decodeSig(sig_b64) catch return error.UnattestedCaller;
        const att = try attestation(turn.arena, subject[0..identity.SAID_LEN], request);
        identity.verify(verkey, att, sig) catch return error.UnattestedCaller;

        // Second: that key really speaks for the AID being claimed. The caller
        // presents its key event log; the host derives the AID from the log's
        // inception event, walks the rotations, and requires the presented key to
        // be the one the log ends on. A caller signing under its own key while
        // naming somebody else's AID is refused here, and so is a caller
        // presenting a key its own log has already rotated away from.
        identity.verifyBinding(turn.arena, kel, subject, verkey) catch return error.UnboundCaller;

        // The capability invocation succeeds; account for it.
        const result = try std.fmt.allocPrint(turn.arena, "ack:{s}", .{request});
        _ = try self.store.record(.outcome, subject, "demo", result);
        self.served.* += 1;
        if (self.last_subject) |dst| @memcpy(dst, subject[0..identity.SAID_LEN]);
        return .{ .string = result };
    }
};
