//! The Syrup signing domain: the exact bytes a `desc:sig-envelope` or an
//! `op:start-session` signature is computed over.
//!
//! A signature covers the Syrup-canonical encoding of a decoded record
//! (ADR-0039 / ADR-0001), regardless of which codec carried the envelope. These
//! functions name that signing domain and render it through `signing.zig`, the
//! same record owner the wire encoder uses.
//!
//! Codecs never sign or verify. They transport the typed object plus signature
//! bytes. The handoff and handshake drivers compute canonical bytes here and call
//! `foundation.crypto.sign` / `verify` at the wrap-and-intercept boundary.

const std = @import("std");

const model = @import("model");

const shared = @import("shared.zig");
const decode = @import("decode.zig");
const render = @import("render.zig");
const signing = @import("signing.zig");

const Error = shared.Error;

/// Canonical signed bytes for an `op:start-session` `acceptable-location`: the
/// Syrup encoding of `<my-location $acceptable-location>` (Goblins `captp.rkt`).
/// This is the exact byte domain `acceptable_location_sig` covers. Both ends must
/// produce identical bytes for verification to succeed. Caller owns the slice.
pub fn canonicalLocationSignedBytes(
    allocator: std.mem.Allocator,
    location: model.PeerLocator,
) ![]u8 {
    return render.renderRecordExact(allocator, signing.writeMyLocationRecord, .{ allocator, model.view.PeerLocator.fromOwned(&location) });
}

/// As `canonicalLocationSignedBytes`, but wraps the *exact received*
/// location-record bytes instead of re-encoding a decoded locator, so a verifier
/// agrees byte-for-byte with the signer even for a locator whose hints the
/// borrowed decode did not retain. Pass the `acceptable_location_raw` a Syrup
/// `op:start-session` decode captured. Caller owns the slice.
pub fn canonicalLocationSignedBytesRaw(
    allocator: std.mem.Allocator,
    location_record_bytes: []const u8,
) ![]u8 {
    return render.renderRecordExact(allocator, signing.writeMyLocationRecordRaw, .{location_record_bytes});
}

/// Canonical signed bytes for a `desc:handoff-give`: the Syrup encoding of the
/// inner `<desc:handoff-give recipient-key exporter-location
/// gifter-exporter-session gifter-side gift-id>` record, exactly the byte domain
/// the gifter's `desc:sig-envelope` signature covers. Hand this to `crypto.sign`
/// or `crypto.verify`. A give carrying verbatim signed bytes (`raw_signed`, a
/// forwarded give) re-derives the payload from those bytes so the exporter
/// re-verifies over what the gifter signed. Caller owns the slice.
pub fn canonicalHandoffGiveSignedBytes(
    allocator: std.mem.Allocator,
    give: model.HandoffGive,
) ![]u8 {
    return canonicalHandoffGiveViewSignedBytes(allocator, model.view.HandoffGive.fromOwned(&give));
}

/// Canonical signed bytes for a borrowed handoff give. The view remains
/// borrowed throughout. Only a lazy hint list, when present, is projected once
/// as canonical-encoding scratch shared by both render passes and freed before
/// return. A Syrup-forwarded give carries its exact signed envelope, so that
/// path reads no typed hints at all.
pub fn canonicalHandoffGiveViewSignedBytes(
    allocator: std.mem.Allocator,
    give: model.view.HandoffGive,
) ![]u8 {
    if (give.raw_signed) |raw| {
        return allocator.dupe(u8, try decode.signedGivePayload(raw));
    }
    var scratch: ProjectedHints = .{};
    defer scratch.deinit(allocator);
    var projected = give;
    projected.exporter.hints = try scratch.project(allocator, give.exporter.hints);
    return render.renderRecordExact(allocator, signing.writeHandoffGiveRecord, .{ allocator, projected });
}

/// One projection of a lazy hint list, held across both render passes so the
/// signing domain of a decoded give is parsed once, not once per pass.
const ProjectedHints = struct {
    owned: ?model.Hints = null,

    fn project(self: *ProjectedHints, allocator: std.mem.Allocator, hints: model.view.BorrowedHints) !model.view.BorrowedHints {
        if (hints != .lazy) return hints;
        self.owned = try hints.toOwned(allocator);
        return .{ .projected = self.owned.? };
    }

    fn deinit(self: *ProjectedHints, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| model.freeHints(allocator, owned);
    }
};

/// Build the inner `<desc:handoff-give ...>` record taking the exporter location as
/// verbatim Syrup bytes (see `signing.writeHandoffGiveRecordRawLocation`). The
/// returned bytes are the signing domain (caller owns them) and feed
/// `wrapSignedHandoffGive`.
pub fn handoffGiveRecordBytesRawLocation(
    allocator: std.mem.Allocator,
    recipient_key: []const u8,
    exporter_location_raw: []const u8,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
) ![]u8 {
    return render.renderRecordExact(allocator, signing.writeHandoffGiveRecordRawLocation, .{
        recipient_key,
        exporter_location_raw,
        gifter_exporter_session,
        gifter_side,
        gift_id,
    });
}

/// Wrap an inner `desc:handoff-give` record and its 64-byte signature into the
/// `<desc:sig-envelope <record> <sig-val …>>` a recipient forwards or a gifter
/// returns. Caller owns the result.
pub fn wrapSignedHandoffGive(
    allocator: std.mem.Allocator,
    give_record: []const u8,
    signature: []const u8,
) ![]u8 {
    return render.renderRecordExact(allocator, signing.writeSigEnvelope, .{ give_record, signature });
}

/// Canonical signed bytes for a `desc:handoff-receive`: the Syrup encoding of the
/// inner `<desc:handoff-receive receiving-session receiving-side handoff-count
/// <signed-give>>` record, the byte domain the recipient's `desc:sig-envelope`
/// signature covers. The record embeds the already-signed give envelope, so
/// verifying the receive does not re-derive the give's signature. Caller owns the
/// slice.
pub fn canonicalHandoffReceiveSignedBytes(
    allocator: std.mem.Allocator,
    receive: model.HandoffReceive,
) ![]u8 {
    return canonicalHandoffReceiveViewSignedBytes(allocator, model.view.HandoffReceive.fromOwned(&receive));
}

/// Canonical signed bytes for a borrowed handoff receive. No owned receive is
/// built: the embedded give is written from the view, and a Syrup receive
/// carrying the give's exact signed envelope embeds it verbatim, so its typed
/// hints and signature are never read. A lazy hint list on a typed give is
/// projected once for both render passes.
pub fn canonicalHandoffReceiveViewSignedBytes(
    allocator: std.mem.Allocator,
    receive: model.view.HandoffReceive,
) ![]u8 {
    var scratch: ProjectedHints = .{};
    defer scratch.deinit(allocator);
    var projected = receive;
    if (receive.signed_give.raw_signed == null) {
        projected.signed_give.exporter.hints = try scratch.project(allocator, receive.signed_give.exporter.hints);
    }
    return render.renderRecordExact(allocator, signing.writeHandoffReceiveRecord, .{ allocator, projected });
}
