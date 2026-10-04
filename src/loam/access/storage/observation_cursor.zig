//! Deterministic authenticated cursors reveal equality only within one context.
const std = @import("std");
const loam = @import("loam_core");
const Siv = std.crypto.aead.aes_siv.Aes128Siv;

pub const Cursor = [56]u8;
pub const Position = struct { sequence: u64, digest: [32]u8 };

pub fn seal(key: [32]u8, context: loam.ObjectId, position: Position) Cursor {
    var plaintext: [40]u8 = undefined;
    std.mem.writeInt(u64, plaintext[0..8], position.sequence, .big);
    plaintext[8..].* = position.digest;
    var cursor: Cursor = undefined;
    Siv.encrypt(cursor[0..40], cursor[40..56], &plaintext, &context.key(), null, key);
    return cursor;
}

pub fn open(key: [32]u8, context: loam.ObjectId, cursor: Cursor) !Position {
    var plaintext: [40]u8 = undefined;
    Siv.decrypt(&plaintext, cursor[0..40], cursor[40..56].*, &context.key(), null, key) catch return error.InvalidCursor;
    return .{ .sequence = std.mem.readInt(u64, plaintext[0..8], .big), .digest = plaintext[8..40].* };
}
