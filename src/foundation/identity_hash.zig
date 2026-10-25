//! Hash tables keyed by an identity a session hands out densely: a wire
//! position, a vow id, a connection slot. These keys are integers or
//! integer-backed enums, allocated in sequence, and every lookup on the call
//! path goes through one of these tables or a handle table (`handle_table`),
//! which a handle that names its own row indexes without a hash. The standard library's automatic
//! context hashes such a key byte by byte with a general-purpose hash, which
//! costs more than the probe it feeds. A multiplicative hash spreads the high
//! bits the table reads as its fingerprint and keeps sequential keys in
//! sequential slots, so one session's positions stay in cache together.
//!
//! A key type that is neither an integer nor an integer-backed enum declares
//! `pub fn identityKey(self) u64` to say how it folds to one word. A key
//! wider than one word declares `pub fn identityWords(self) [n]u64` instead,
//! an array that is equal for two keys exactly when they are the same key.
//! Both hashes run their multiplication once per word.
//!
//! The identity hash is exact only for keys this process allocates. A key a
//! peer chooses (an import position, an inbound answer position, a position
//! named in a GC message) can be chosen to collide, and an unkeyed hash of
//! any kind then degrades the table to a scan. Every table names who chooses
//! its keys through `Provenance`, and `MapOf` picks the hash for it: the
//! identity hash for `local`, and for `wire` a keyed hash under a secret
//! multiplier the table is built with (`WireMap.keyed`). The key is
//! multiplied by the secret first, a bijection for an odd multiplier, so a
//! peer that does not know it cannot tell which product its position
//! becomes. A public finisher then spreads that product across every bit,
//! so the sequential positions an honest peer allocates land as if random.
//! Seven arithmetic instructions and one word per table.

const std = @import("std");

/// Whether `K` is an identity: an integer, an integer-backed enum, an array
/// of words, or a type declaring `identityKey` or `identityWords`.
pub fn isIdentity(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .int, .@"enum" => true,
        .array => isWordArray(K),
        else => @hasDecl(K, "identityKey") or isComposite(K),
    };
}

/// Refuse a table over a key the hash cannot fold where the table is
/// declared, naming the key, instead of inside `fold` at its first hash.
fn assertIdentity(comptime K: type) void {
    if (!isIdentity(K)) @compileError("identity_hash tables take an integer, an integer-backed enum, " ++
        "an array of words, or a key declaring identityKey or identityWords: " ++ @typeName(K));
}

/// Whether `K` is an array of words: the words of some key, held as the key
/// itself so a table over it hashes and compares words computed once.
fn isWordArray(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .array => |array| array.child == u64,
        else => false,
    };
}

/// Whether `K` identifies itself by several words.
fn isComposite(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .@"struct", .@"union" => @hasDecl(K, "identityWords"),
        else => false,
    };
}

/// The array of words that identifies a `K`.
pub fn Words(comptime K: type) type {
    if (isComposite(K)) return @TypeOf(@as(K, undefined).identityWords());
    return if (isWordArray(K)) K else [1]u64;
}

/// The words that identify a key: its fold, the array it declares, or itself.
pub fn words(key: anytype) Words(@TypeOf(key)) {
    const K = @TypeOf(key);
    if (comptime isComposite(K)) return key.identityWords();
    return if (comptime isWordArray(K)) key else .{fold(key)};
}

/// Whether two keys are the same key: their words are equal.
pub fn eql(a: anytype, b: @TypeOf(a)) bool {
    // One compare for a one-word key, and one per word for a wider one, with
    // no call into a byte comparison that cannot see the lengths are fixed.
    const K = @TypeOf(a);
    if (comptime !isComposite(K) and !isWordArray(K)) return fold(a) == fold(b);
    const a_words = words(a);
    const b_words = words(b);
    inline for (a_words, b_words) |a_word, b_word| {
        if (a_word != b_word) return false;
    }
    return true;
}

/// Fold a key to the integer that identifies it.
pub fn fold(key: anytype) u64 {
    // Reduce the key to one 64-bit word and nothing else. A key we mint
    // ourselves, such as an export position or a handle, is a small
    // number handed out in order, so the word already spreads evenly
    // across a table. Only keys we mint are safe to use this way.
    const K = @TypeOf(key);
    return switch (@typeInfo(K)) {
        .int => |info| if (info.signedness == .signed) @bitCast(@as(i64, key)) else @intCast(key),
        .@"enum" => fold(@backingInt(key)),
        else => if (@hasDecl(K, "identityKey"))
            key.identityKey()
        else
            @compileError("identity_hash needs an integer, an integer-backed enum, or a key declaring identityKey: " ++ @typeName(K)),
    };
}

/// The golden-ratio multiplier: the identity hash's constant, and the wire
/// hash's multiplier for a session built with no secret, which keeps a bare
/// core deterministic.
pub const default_multiplier: u64 = 0x9E3779B97F4A7C15;

/// Fibonacci hashing: the golden-ratio multiplier mixes the high bits that
/// become the table's fingerprint while the low bits, which pick the slot,
/// follow the key.
pub fn hash(key: anytype) u64 {
    // One multiplication by a fixed public constant, with no secret. Keys that
    // this process minted come out in order and evenly spread, so nothing
    // heavier is needed. This is correct only for keys we mint. A peer can
    // choose its own keys to collide under a fixed constant, so those go
    // through `wireHash` instead. A key of several words folds each word into
    // the running product, so a change in any word changes the hash.
    var h: u64 = 0;
    for (words(key)) |word| h = (h ^ word) *% default_multiplier;
    return h;
}

/// The keyed hash for a wire-chosen key: the secret multiplication, then a
/// public finisher that spreads the product. The finisher alone would let a
/// peer precompute colliding positions, and the multiplication alone would
/// let sequential positions cluster when the multiplier sits near a small
/// fraction of the word.
pub fn wireHash(key: anytype, multiplier: u64) u64 {
    // The peer picks these keys, so a fixed constant is not safe. The
    // multiplier is a secret chosen for this session, and the peer cannot
    // work out which keys would pile into one bucket (ADR-0037).
    // Multiplying by an odd number never sends two keys to one value. A key
    // of several words multiplies once per word, so two keys that differ in
    // any word collide only at a value the secret decides. The shifts below
    // then spread the result across every bit.
    var h: u64 = 0;
    for (words(key)) |word| h = (h ^ word) *% multiplier;
    h ^= h >> 32;
    h *%= default_multiplier;
    return h ^ (h >> 29);
}

/// The multiplier a seed names: any 64-bit value, forced odd so the product
/// stays a bijection of the key.
pub fn multiplierFromSeed(seed: u64) u64 {
    return seed | 1;
}

/// The multiplier `multiplier` becomes under a fresh `salt`: the salt hashed
/// under the multiplier, so a session keyed from a durable root and a reused
/// handle still hashes under a secret no earlier session held. status-allow: event or source ordering
pub fn saltedMultiplier(multiplier: u64, salt: u64) u64 {
    return multiplierFromSeed(wireHash(salt, multiplier));
}

/// The hash-map context for a table whose keys arrive on the wire. It
/// carries the table's multiplier, so the standard map's context-taking
/// verbs are the ones `WireMap` calls.
pub fn WireContext(comptime K: type) type {
    comptime assertIdentity(K);
    return struct {
        multiplier: u64,

        pub fn hash(self: @This(), key: K) u64 {
            // Hash under this table's own secret multiplier, since the keys in
            // a wire table come from the peer (ADR-0037).
            return wireHash(key, self.multiplier);
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return identity_hash.eql(a, b);
        }
    };
}

/// A table keyed by values the peer chooses. It is built with `keyed` and
/// never with a default, so no table hashes under a multiplier its owner
/// did not name. The multiplier is the one word the table adds to the
/// standard map.
pub fn WireMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const KeyContext = WireContext(K);
        pub const Inner = std.HashMapUnmanaged(K, V, KeyContext, std.hash_map.default_max_load_percentage);
        pub const Entry = Inner.Entry;
        pub const KV = Inner.KV;
        pub const Iterator = Inner.Iterator;
        pub const KeyIterator = Inner.KeyIterator;
        pub const ValueIterator = Inner.ValueIterator;
        pub const GetOrPutResult = Inner.GetOrPutResult;

        inner: Inner,
        multiplier: u64,

        pub fn keyed(multiplier: u64) Self {
            return .{ .inner = .empty, .multiplier = multiplier };
        }

        /// Re-key an empty map under the session's secret. A map with rows
        /// in it could no longer find them, so emptiness is asserted. status-allow: lifecycle transition
        pub fn keyWire(self: *Self, multiplier: u64) void {
            std.debug.assert(self.inner.count() == 0);
            self.multiplier = multiplier;
        }

        fn ctx(self: *const Self) KeyContext {
            return .{ .multiplier = self.multiplier };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.inner.deinit(allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.inner.count();
        }

        pub fn capacity(self: *const Self) usize {
            return self.inner.capacity();
        }

        pub fn iterator(self: *const Self) Iterator {
            return self.inner.iterator();
        }

        pub fn keyIterator(self: *const Self) KeyIterator {
            return self.inner.keyIterator();
        }

        pub fn valueIterator(self: *const Self) ValueIterator {
            return self.inner.valueIterator();
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.inner.clearRetainingCapacity();
        }

        pub fn get(self: *const Self, key: K) ?V {
            return self.inner.getContext(key, self.ctx());
        }

        pub fn getPtr(self: *const Self, key: K) ?*V {
            return self.inner.getPtrContext(key, self.ctx());
        }

        pub fn getEntry(self: *const Self, key: K) ?Entry {
            return self.inner.getEntryContext(key, self.ctx());
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.inner.containsContext(key, self.ctx());
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: K, value: V) std.mem.Allocator.Error!void {
            return self.inner.putContext(allocator, key, value, self.ctx());
        }

        pub fn putNoClobber(self: *Self, allocator: std.mem.Allocator, key: K, value: V) std.mem.Allocator.Error!void {
            return self.inner.putNoClobberContext(allocator, key, value, self.ctx());
        }

        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            self.inner.putAssumeCapacityContext(key, value, self.ctx());
        }

        pub fn putAssumeCapacityNoClobber(self: *Self, key: K, value: V) void {
            self.inner.putAssumeCapacityNoClobberContext(key, value, self.ctx());
        }

        pub fn getOrPut(self: *Self, allocator: std.mem.Allocator, key: K) std.mem.Allocator.Error!GetOrPutResult {
            return self.inner.getOrPutContext(allocator, key, self.ctx());
        }

        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPutResult {
            return self.inner.getOrPutAssumeCapacityContext(key, self.ctx());
        }

        pub fn remove(self: *Self, key: K) bool {
            return self.inner.removeContext(key, self.ctx());
        }

        /// Remove the row `key_ptr` names, safe during an iteration.
        pub fn removeByPtr(self: *Self, key_ptr: *K) void {
            self.inner.removeByPtr(key_ptr);
        }

        pub fn fetchRemove(self: *Self, key: K) ?KV {
            return self.inner.fetchRemoveContext(key, self.ctx());
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: u32) std.mem.Allocator.Error!void {
            return self.inner.ensureUnusedCapacityContext(allocator, additional, self.ctx());
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, total: u32) std.mem.Allocator.Error!void {
            return self.inner.ensureTotalCapacityContext(allocator, total, self.ctx());
        }
    };
}

/// The hash-map context for one identity key type.
pub fn Context(comptime K: type) type {
    comptime assertIdentity(K);
    return struct {
        pub fn hash(_: @This(), key: K) u64 {
            return identityHash(key);
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return identity_hash.eql(a, b);
        }
    };
}

/// The array-hash-map context for one identity key type: the same hash,
/// narrowed to the 32 bits that map asks for.
pub fn ArrayContext(comptime K: type) type {
    comptime assertIdentity(K);
    return struct {
        pub fn hash(_: @This(), key: K) u32 {
            return @truncate(identityHash(key) >> 32);
        }

        pub fn eql(_: @This(), a: K, b: K, _: usize) bool {
            return identity_hash.eql(a, b);
        }
    };
}

const identityHash = hash;
const identity_hash = @This();

/// An unmanaged hash map keyed by an identity.
pub fn Map(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, Context(K), std.hash_map.default_max_load_percentage);
}

/// The managed form of `Map`, for a backend that keeps its allocator in the
/// table.
pub fn Managed(comptime K: type, comptime V: type) type {
    return std.HashMap(K, V, Context(K), std.hash_map.default_max_load_percentage);
}

/// Who chooses a table's keys.
pub const Provenance = enum {
    /// This process allocates them, in sequence: a position it exports, a
    /// handle, a slot.
    local,
    /// A peer chooses them and may choose adversarially.
    wire,
};

/// The map for a table whose keys `provenance` names.
pub fn MapOf(comptime provenance: Provenance, comptime K: type, comptime V: type) type {
    return switch (provenance) {
        .local => Map(K, V),
        .wire => WireMap(K, V),
    };
}

/// An unmanaged insertion-ordered hash map keyed by an identity.
pub fn ArrayMap(comptime K: type, comptime V: type) type {
    return std.ArrayHashMapUnmanaged(K, V, ArrayContext(K), false);
}
