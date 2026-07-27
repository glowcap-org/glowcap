//! A Sigstore-shaped Merkle transparency log over Episode bytes.
//!
//! Application vocabulary above pancake. Each appended leaf is the Blake3 hash of
//! one Episode's canonical bytes; the root is recomputed over all leaves on every
//! append. The log is the tamper-evidence layer: an auditor who has the root can
//! confirm an Episode was logged and that the log was not rewritten.
//!
//! This owns no protocol semantics. It is a local file-backed structure the
//! accountability adapter writes to. The hash is Blake3 (matching the identity
//! layer); the tree is a standard binary Merkle tree with duplicate-promotion of
//! a lone right node, the RFC 6962 shape minus its domain-separation prefixes
//! (named here so the simplification is not mistaken for the IETF profile).

const std = @import("std");

const Blake3 = std.crypto.hash.Blake3;

pub const DIGEST_BYTES = 32;
pub const Digest = [DIGEST_BYTES]u8;

pub fn leafHash(episode_bytes: []const u8) Digest {
    var out: Digest = undefined;
    Blake3.hash(episode_bytes, &out, .{});
    return out;
}

fn nodeHash(left: Digest, right: Digest) Digest {
    var hasher = Blake3.init(.{});
    hasher.update(&left);
    hasher.update(&right);
    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

/// An append-only transparency log. Owns its leaf vector; `deinit` frees it.
pub const Log = struct {
    allocator: std.mem.Allocator,
    leaves: std.ArrayList(Digest) = .empty,

    pub fn init(allocator: std.mem.Allocator) Log {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Log) void {
        self.leaves.deinit(self.allocator);
    }

    pub fn append(self: *Log, leaf: Digest) std.mem.Allocator.Error!void {
        try self.leaves.append(self.allocator, leaf);
    }

    /// Recompute the Merkle root over the current leaves. An empty log has the
    /// all-zero root; a single leaf is its own root.
    pub fn root(self: *const Log) std.mem.Allocator.Error!Digest {
        if (self.leaves.items.len == 0) return std.mem.zeroes(Digest);

        var level = try self.allocator.dupe(Digest, self.leaves.items);
        defer self.allocator.free(level);

        var len = level.len;
        while (len > 1) {
            var write: usize = 0;
            var read: usize = 0;
            while (read < len) : (read += 2) {
                const left = level[read];
                // A lone right node duplicates itself (RFC 6962-shaped promotion).
                const right = if (read + 1 < len) level[read + 1] else left;
                level[write] = nodeHash(left, right);
                write += 1;
            }
            len = write;
        }
        return level[0];
    }
};

pub fn toHex(digest: Digest) [DIGEST_BYTES * 2]u8 {
    var out: [DIGEST_BYTES * 2]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}
