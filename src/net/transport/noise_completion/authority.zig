//! Sealing identity and entropy owned by one completion reactor.

const std = @import("std");
const foundation = @import("foundation");

const crypto = foundation.crypto;

pub const Authority = struct {
    identity: crypto.SecretKey,
    rng: std.Random.DefaultCsprng,

    pub fn deinit(self: *Authority) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&self.identity));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.rng));
    }
};
