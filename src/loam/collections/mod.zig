//! Persistent immutable collections, actor-support for vat time-travel.
//!
//! A persistent actor (see `actors/vat/mod.zig`, ADR-0015) produces its next state
//! with `Turn.become` instead of mutating `self`, so a vat snapshot can
//! share the value with no copy-on-write. If that state is a large map,
//! rebuilding it every turn would make `become` O(size). `PersistentMap` closes
//! that: an immutable hash array mapped trie (HAMT) whose updates copy only the
//! path to the changed leaf and share every untouched subtree by reference, so a
//! `put` is O(log n) and the prior version, and any snapshot that holds it,
//! stays valid and untouched (ADR-0015).
//!
//! Nodes are reference-counted. The count is non-atomic because the vat is
//! single-threaded, and an immutable trie is acyclic, so a plain count frees
//! correctly with no collector, the same reasoning as the vat's `StateBox`.
//! `put`, `remove`, and `deinit` are the only operations that move a refcount.
//!
//! Scope (ADR-0015): one map keyed by `u64`, values stored by value. It is a
//! dependency-free leaf under `glowcap.loam.collections`. Actor snapshots can
//! use it without Loam storage, managed access, or a persistent database.
//! Values are POD-shaped, stored and copied by value: leaves are shared across
//! versions and freed inside the trie's own refcounting with no per-value
//! hook, so an external owner could never learn when the last copy of a value
//! drops. A `V` that owns heap (signalled by a `deinit` method) is rejected at
//! compile time rather than silently leaked.

const std = @import("std");

/// An immutable, structurally-shared map from `u64` to `V`. Construct with
/// `init`, derive new versions with `put`/`remove` (each returns a new map that
/// shares structure with the old one), and free each version with `deinit`.
/// Every version is independently owned: deriving `b` from `a` does not consume
/// `a`, and both must be `deinit`-ed.
pub fn PersistentMap(comptime V: type) type {
    return struct {
        // Leaves are shared across versions and freed inside `releaseNode`
        // with no value hook, so nobody outside the trie can observe the
        // last copy of a value dropping. A heap-owning value type would
        // therefore leak silently; refuse it where the type is built. A
        // `deinit` method is the signal (only container types can carry
        // one, so anything else passes).
        comptime {
            const holds_decls = switch (@typeInfo(V)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => true,
                else => false,
            };
            if (holds_decls and @hasDecl(V, "deinit")) {
                @compileError("PersistentMap values must be POD-shaped; a V with a deinit method owns heap the map could never release");
            }
        }

        const Self = @This();

        const Leaf = struct { key: u64, value: V };
        const Slot = union(enum) {
            leaf: Leaf,
            node: *Node,
        };
        /// A refcounted trie node: a 64-way branch whose `bitmap` marks which
        /// chunks are present. The node is the header of a single heap block
        /// whose trailing storage is the compact slot array (`children()`),
        /// so a fresh node costs one allocation, not a header/array pair.
        const Node = struct {
            refs: usize,
            bitmap: u64,
            /// Inline slot count of the trailing storage. `popCount(bitmap)`
            /// equals it at every construction site today, but the free is
            /// sized from this stored byte, store enough metadata to free
            /// correctly, never recomputed from the bitmap.
            capacity: u8,

            /// The compact slot array in this node's trailing storage.
            fn children(self: *Node) []Slot {
                const base: [*]align(node_alignment) u8 = @ptrCast(@alignCast(self));
                const slots: [*]Slot = @ptrCast(@alignCast(base + slots_offset));
                return slots[0..self.capacity];
            }
        };

        /// Alignment of the merged node block: the header's and the slots'.
        const node_alignment = @max(@alignOf(Node), @alignOf(Slot));
        /// Byte offset of the trailing slot array within the block.
        const slots_offset = std.mem.alignForward(usize, @sizeOf(Node), @alignOf(Slot));

        fn nodeBlockLen(capacity: usize) usize {
            return slots_offset + capacity * @sizeOf(Slot);
        }

        /// Allocate one node block (`refs = 1`) with room for `capacity`
        /// slots. The caller fills `children()` before sharing the node.
        fn createNode(allocator: std.mem.Allocator, bitmap: u64, capacity: usize) std.mem.Allocator.Error!*Node {
            const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(node_alignment), nodeBlockLen(capacity));
            const node: *Node = @ptrCast(@alignCast(bytes.ptr));
            node.* = .{ .refs = 1, .bitmap = bitmap, .capacity = @intCast(capacity) };
            return node;
        }

        /// Free one node block, sized from the stored capacity.
        fn destroyNode(allocator: std.mem.Allocator, node: *Node) void {
            const base: [*]align(node_alignment) u8 = @ptrCast(@alignCast(node));
            allocator.free(base[0..nodeBlockLen(node.capacity)]);
        }

        /// Bits consumed per trie level: 64-way branching.
        const chunk_bits: u5 = 6;

        allocator: std.mem.Allocator,
        root: ?*Node,
        count: usize,

        /// An empty map. Cheap: it allocates nothing until the first `put`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .root = null, .count = 0 };
        }

        /// Drop this version's reference to the trie, freeing every node a later
        /// version or snapshot no longer shares.
        pub fn deinit(self: *Self) void {
            if (self.root) |root| releaseNode(self.allocator, root);
            self.* = undefined;
        }

        /// The number of keys in this version.
        pub fn len(self: Self) usize {
            return self.count;
        }

        /// The value bound to `key`, or null. O(log n), allocation-free, and it
        /// never mutates a refcount.
        pub fn get(self: Self, key: u64) ?V {
            var node = self.root orelse return null;
            var shift: u32 = 0;
            while (true) {
                const chunk = chunkAt(key, shift);
                const bit = slotBit(chunk);
                if (node.bitmap & bit == 0) return null;
                switch (node.children()[slotPos(node.bitmap, chunk)]) {
                    .leaf => |leaf| return if (leaf.key == key) leaf.value else null,
                    .node => |child| {
                        node = child;
                        shift += chunk_bits;
                    },
                }
            }
        }

        /// Whether `key` is bound.
        pub fn contains(self: Self, key: u64) bool {
            return self.get(key) != null;
        }

        /// A new map with `key` bound to `value`, sharing every untouched subtree
        /// with `self` (their refcounts rise). Both maps stay valid. Both must be
        /// `deinit`-ed. O(log n) freshly-allocated nodes.
        pub fn put(self: Self, key: u64, value: V) std.mem.Allocator.Error!Self {
            const root = self.root orelse {
                const node = try leafNode(self.allocator, key, value);
                return .{ .allocator = self.allocator, .root = node, .count = 1 };
            };
            const result = try nodePut(self.allocator, root, key, value, 0);
            return .{
                .allocator = self.allocator,
                .root = result.node,
                .count = self.count + @intFromBool(result.added),
            };
        }

        /// A new map without `key`, sharing untouched subtrees with `self`. If
        /// `key` was absent, the result shares `self`'s root outright (one
        /// refcount bump, no path copy). Both maps stay valid and must be
        /// `deinit`-ed.
        pub fn remove(self: Self, key: u64) std.mem.Allocator.Error!Self {
            const root = self.root orelse return self;
            const result = try nodeRemove(self.allocator, root, key, 0);
            if (!result.removed) {
                root.refs += 1;
                return .{ .allocator = self.allocator, .root = root, .count = self.count };
            }
            return .{ .allocator = self.allocator, .root = result.node, .count = self.count - 1 };
        }

        // ── trie internals ────────────────────────────────────────────────

        fn chunkAt(key: u64, shift: u32) u6 {
            return @intCast((key >> @intCast(shift)) & 0x3f);
        }

        fn slotBit(chunk: u6) u64 {
            return @as(u64, 1) << chunk;
        }

        /// The dense index of `chunk` within a node: how many present chunks sit
        /// below it.
        fn slotPos(bitmap: u64, chunk: u6) usize {
            return @popCount(bitmap & (slotBit(chunk) - 1));
        }

        fn retainSlot(slot: Slot) void {
            switch (slot) {
                .leaf => {},
                .node => |node| node.refs += 1,
            }
        }

        /// A fresh same-shape copy of `node` (same bitmap and slot count) with the
        /// slot at `pos` replaced by `slot`, every surviving sibling shared and
        /// retained. The old slot at `pos` is neither retained nor released here.
        /// `slot` is installed owning whatever refcount the caller handed it. The
        /// one same-size path-copy spine `nodePut` and `nodeRemove` share. The only
        /// fallible step is the allocation, before `slot` is installed, so a caller
        /// holding a fresh child under an `errdefer` frees it correctly when this
        /// fails and hands it off cleanly when this succeeds.
        fn copyReplacing(allocator: std.mem.Allocator, node: *Node, pos: usize, slot: Slot) std.mem.Allocator.Error!*Node {
            const old = node.children();
            const fresh = try createNode(allocator, node.bitmap, old.len);
            const children = fresh.children();
            @memcpy(children, old);
            for (old, 0..) |s, i| {
                if (i != pos) retainSlot(s);
            }
            children[pos] = slot;
            return fresh;
        }

        fn releaseNode(allocator: std.mem.Allocator, node: *Node) void {
            node.refs -= 1;
            if (node.refs != 0) return;
            for (node.children()) |slot| {
                switch (slot) {
                    .leaf => {},
                    .node => |child| releaseNode(allocator, child),
                }
            }
            destroyNode(allocator, node);
        }

        /// A fresh single-leaf root node (`refs = 1`).
        fn leafNode(allocator: std.mem.Allocator, key: u64, value: V) std.mem.Allocator.Error!*Node {
            const node = try createNode(allocator, slotBit(chunkAt(key, 0)), 1);
            node.children()[0] = .{ .leaf = .{ .key = key, .value = value } };
            return node;
        }

        /// A fresh node (`refs = 1`) holding two distinct keys at `shift`, pushing
        /// deeper while their chunks collide. The keys differ within 64 bits, so
        /// the recursion terminates by `shift == 60`.
        fn twoLeafNode(
            allocator: std.mem.Allocator,
            shift: u32,
            k1: u64,
            v1: V,
            k2: u64,
            v2: V,
        ) std.mem.Allocator.Error!*Node {
            const c1 = chunkAt(k1, shift);
            const c2 = chunkAt(k2, shift);
            if (c1 == c2) {
                const sub = try twoLeafNode(allocator, shift + chunk_bits, k1, v1, k2, v2);
                errdefer releaseNode(allocator, sub);
                const node = try createNode(allocator, slotBit(c1), 1);
                node.children()[0] = .{ .node = sub };
                return node;
            }
            const node = try createNode(allocator, slotBit(c1) | slotBit(c2), 2);
            const children = node.children();
            if (c1 < c2) {
                children[0] = .{ .leaf = .{ .key = k1, .value = v1 } };
                children[1] = .{ .leaf = .{ .key = k2, .value = v2 } };
            } else {
                children[0] = .{ .leaf = .{ .key = k2, .value = v2 } };
                children[1] = .{ .leaf = .{ .key = k1, .value = v1 } };
            }
            return node;
        }

        const PutResult = struct { node: *Node, added: bool };

        /// Path-copy `node` with `key` => `value`: returns a fresh node
        /// (`refs = 1`) whose untouched children are shared with `node` (their
        /// refcounts raised). Retains happen only after every allocation
        /// succeeds, so an out-of-memory mid-build leaves no over-counted box.
        fn nodePut(
            allocator: std.mem.Allocator,
            node: *Node,
            key: u64,
            value: V,
            shift: u32,
        ) std.mem.Allocator.Error!PutResult {
            const chunk = chunkAt(key, shift);
            const bit = slotBit(chunk);
            const pos = slotPos(node.bitmap, chunk);
            const old = node.children();

            if (node.bitmap & bit == 0) {
                // Absent here: insert a leaf, keeping the dense array sorted.
                const fresh = try createNode(allocator, node.bitmap | bit, old.len + 1);
                const children = fresh.children();
                @memcpy(children[0..pos], old[0..pos]);
                children[pos] = .{ .leaf = .{ .key = key, .value = value } };
                @memcpy(children[pos + 1 ..], old[pos..]);
                for (old) |slot| retainSlot(slot);
                return .{ .node = fresh, .added = true };
            }

            switch (old[pos]) {
                .leaf => |leaf| {
                    if (leaf.key == key) {
                        // Replace the value in place on a copy.
                        const fresh = try copyReplacing(allocator, node, pos, .{ .leaf = .{ .key = key, .value = value } });
                        return .{ .node = fresh, .added = false };
                    }
                    // Two distinct keys collide here: push both down a level.
                    const sub = try twoLeafNode(allocator, shift + chunk_bits, leaf.key, leaf.value, key, value);
                    errdefer releaseNode(allocator, sub);
                    const fresh = try copyReplacing(allocator, node, pos, .{ .node = sub });
                    return .{ .node = fresh, .added = true };
                },
                .node => |child| {
                    const sub = try nodePut(allocator, child, key, value, shift + chunk_bits);
                    errdefer releaseNode(allocator, sub.node);
                    // The recursed child is replaced by the fresh `sub.node`, so the
                    // old child keeps its own refcount (copyReplacing skips pos).
                    const fresh = try copyReplacing(allocator, node, pos, .{ .node = sub.node });
                    return .{ .node = fresh, .added = sub.added };
                },
            }
        }

        const RemoveResult = struct { node: *Node, removed: bool };

        /// Path-copy `node` without `key`. `removed` is false when `key` was
        /// absent, in which case `node` is returned unchanged (the caller shares
        /// it). Nodes are not canonicalized on the way down: a branch may shrink to
        /// a single entry, or to none, at any level, not only the root.
        /// `get`/`len`/`remove` stay correct over such a node, and `deinit` frees
        /// it. The only cost is a little wasted depth, never a leak or a wrong
        /// answer.
        fn nodeRemove(
            allocator: std.mem.Allocator,
            node: *Node,
            key: u64,
            shift: u32,
        ) std.mem.Allocator.Error!RemoveResult {
            const chunk = chunkAt(key, shift);
            const bit = slotBit(chunk);
            if (node.bitmap & bit == 0) return .{ .node = node, .removed = false };
            const pos = slotPos(node.bitmap, chunk);
            const old = node.children();

            switch (old[pos]) {
                .leaf => |leaf| {
                    if (leaf.key != key) return .{ .node = node, .removed = false };
                    const fresh = try dropSlot(allocator, node, pos, bit);
                    return .{ .node = fresh, .removed = true };
                },
                .node => |child| {
                    const sub = try nodeRemove(allocator, child, key, shift + chunk_bits);
                    if (!sub.removed) return .{ .node = node, .removed = false };
                    // Replace the child unconditionally: `sub.node` may be empty or
                    // single-leaf (remove does not canonicalize), which `get` and
                    // `deinit` tolerate.
                    errdefer releaseNode(allocator, sub.node);
                    const fresh = try copyReplacing(allocator, node, pos, .{ .node = sub.node });
                    return .{ .node = fresh, .removed = true };
                },
            }
        }

        /// A fresh copy of `node` with the slot at `pos` (chunk `bit`) dropped,
        /// sharing the surviving children. Remove does not canonicalize, so at any
        /// level this can leave a node holding a single slot, or none, a two-leaf
        /// node whose other leaf a later remove also drops becomes empty in place,
        /// not collapsed into its parent. `get`, `len`, `remove`, and `deinit` are
        /// all written to tolerate empty and single-entry interior nodes. The only
        /// cost is a little wasted depth, bounded by the ~11-level key ceiling.
        fn dropSlot(allocator: std.mem.Allocator, node: *Node, pos: usize, bit: u64) std.mem.Allocator.Error!*Node {
            const old = node.children();
            const fresh = try createNode(allocator, node.bitmap & ~bit, old.len - 1);
            const children = fresh.children();
            @memcpy(children[0..pos], old[0..pos]);
            @memcpy(children[pos..], old[pos + 1 ..]);
            for (children) |slot| retainSlot(slot);
            return fresh;
        }
    };
}
