//! Handoff-certificate verification for bootstrap withdrawal.
//!
//! The bootstrap registry owns gift lifetime and replay authority; this leaf
//! owns only canonical signing bytes and cryptographic verification. Malformed
//! certificates are a deterministic `false`, while allocation pressure remains
//! a host failure so it cannot be mislabeled as a peer protocol violation.

const std = @import("std");

const codec = @import("codec");
const crypto = @import("foundation").crypto;
const model = @import("model");

pub fn verifyReceiveWithGifterKey(
    allocator: std.mem.Allocator,
    receive: model.view.HandoffReceive,
    gifter_key_bytes: []const u8,
) error{OutOfMemory}!bool {
    const give = receive.signed_give;
    const give_signed = codec.signed.giveViewBytes(allocator, give) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer allocator.free(give_signed);

    const gifter_key = crypto.PeerKey.fromSlice(gifter_key_bytes) catch return false;
    const give_sig = parseBorrowedSignature(give.signature) orelse return false;
    crypto.verify(gifter_key, give_signed, give_sig) catch return false;

    const receive_signed = codec.signed.receiveViewBytes(allocator, receive) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    defer allocator.free(receive_signed);

    const recipient_key = crypto.PeerKey.fromSlice(give.recipient_key) catch return false;
    const receive_sig = parseBorrowedSignature(receive.signature) orelse return false;
    crypto.verify(recipient_key, receive_signed, receive_sig) catch return false;

    return true;
}

fn parseBorrowedSignature(signature: model.view.Signature) ?crypto.Signature {
    return switch (signature) {
        .raw => |raw| crypto.Signature.fromSlice(raw) catch null,
        .halves => |halves| crypto.Signature.fromParts(halves.r, halves.s) catch null,
    };
}
