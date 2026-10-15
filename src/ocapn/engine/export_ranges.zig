//! Disjoint per-session export numbering for one `Node` (the "Names carry
//! three things" defence): the node-slot arithmetic, the per-session range
//! allocator, and the recycle queue a released session's range returns
//! through. `Node` aliases each function as its own. The fields live on
//! `Node` because they are node state, and this file owns the operations
//! over them.

const std = @import("std");

const foundation = @import("foundation");
const crypto = foundation.crypto;
const session_mod = @import("session");

const engine = @import("mod.zig");
const node_mod = @import("node.zig");
const Node = node_mod.Node;

/// How far apart two sessions' export positions start, and where this
/// node's sessions begin.
///
/// A near reference is one integer, and it means whatever the session
/// reading it says it means, so the same number names a different object on
/// every session. An application holds capabilities from several sessions
/// at once, a call that redeems two handoffs hands it two, and offering one to
/// the wrong session is a one-word mistake. Disjoint ranges make that
/// mistake name a position no session holds, so the held-export check
/// refuses it, instead of it landing on whatever that session keeps at the
/// same number and resolving silently to the wrong object.
///
/// The split is 16 bits of node, 20 of session, 24 of export range: about a
/// million sessions per node, each able to export sixteen million objects,
/// both past what the connection budget admits. The node bits come from the
/// node's own identity rather than a shared counter, because a counter
/// would be process-wide mutable state in a layer whose whole point is not
/// to have any, and two nodes in one process must still number their
/// sessions apart, since an application can hold capabilities from both.
const export_range_bits: u6 = 24;
const export_node_shift: u6 = 44;
/// Sixteen bits of node identity. This defensive export partition is
/// independent of routed-capability ids. Their namespaces are distinct.
const export_node_slots: u64 = 1 << 16;
const export_range_span: u64 = 1 << export_range_bits;
comptime {
    // The fields must tile without overlapping, and the slots must tile the
    // configured export-allocation span exactly, a partial top slot would let the last node's
    // counter stop somewhere the arithmetic above does not describe. Held
    // here rather than in the prose above, because prose does not fail a
    // build.
    std.debug.assert(export_node_shift > export_range_bits);
    std.debug.assert(export_node_slots >= 1);
    // Every range a node draws is one span wide and starts on a span
    // boundary, so a slot must hold a whole number of them.
    std.debug.assert((@as(u64, 1) << export_node_shift) % export_range_span == 0);
}

/// This node's first range. The node bits come from its own identity, so
/// two nodes in one process usually land in different slots, though not
/// always: sixteen bits of hash collide by birthday somewhere around three
/// hundred nodes in one process, and colliding nodes number their sessions
/// alike again. That is the same defence-in-depth the ranges give a session
/// pair, not a guarantee, and a process running hundreds of nodes should
/// read it that way.
///
/// The `| export_range_span` skips slot zero's zeroth range: a
/// base of 0 would have the first session mint export position 0, which is
/// `session.BOOTSTRAP_POSITION`, aliasing the bootstrap export the session
/// installs at open. Every other slot's first range starts above zero
/// already. Paying one span in every slot keeps the rule uniform.
pub fn initialExportBase(seed: [crypto.SEED_BYTES]u8) u64 {
    const node_slot: u64 = std.hash.Wyhash.hash(0, &seed) % export_node_slots;
    return (node_slot << export_node_shift) | export_range_span;
}

/// The root of the wire-hash multipliers, derived from the identity seed
/// under its own domain so neither is recoverable from the other.
pub fn wireHashSecret(seed: [crypto.SEED_BYTES]u8) u64 {
    var out: [8]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("glowcap wire hash v1", .{});
    hasher.update(&seed);
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

/// One session's multiplier: the root mixed with the peer handle, so what a
/// peer could learn about its own tables says nothing about another
/// session's.
pub fn wireHashMultiplier(secret: u64, peer_handle: u64) u64 {
    const root = foundation.identity_hash.multiplierFromSeed(secret);
    return foundation.identity_hash.multiplierFromSeed(foundation.identity_hash.wireHash(peer_handle, root));
}

/// Give `peer`'s session the next range, the one door a session's export
/// numbers come through.
///
/// It runs at registration for both the owned and the adopted path, so
/// there is no verb that enrols a session without numbering it. That is the
/// whole point of it living here: the node is what holds many sessions, so
/// this makes equal numbering across sessions structurally unlikely, and a
/// layer above cannot forget to ask.
pub fn applyExportRange(self: *Node, target: *engine.Peer) !void {
    const promised = std.math.add(
        usize,
        self.freed_export_bases.liveLen(),
        self.export_base_return_reservations,
    ) catch return error.OutOfMemory;
    const required = std.math.add(usize, promised, 1) catch return error.OutOfMemory;
    try self.freed_export_bases.ensureTotalCapacity(self.allocator, required);
    self.export_base_return_reservations += 1;
    errdefer self.export_base_return_reservations -= 1;
    const base = try takeExportBase(self);
    target.session_state.setExportBase(base, export_range_span);
}

/// One past this node's last range: the top of the slot `base` sits in.
pub fn exportBaseEndFor(base: u64) u64 {
    return ((base >> export_node_shift) + 1) << export_node_shift;
}

/// Draw the next session's export range: a range a released session gave
/// back if there is one, otherwise a fresh one from the counter. Called
/// once per session, at the one place every session passes through: a
/// second draw would hand one session a range and throw another away.
///
/// Refuses rather than carrying past the node's slot. Reaching that needs
/// this node to hold every range in its slot at once, which the connection
/// budget stops first. A node that merely churns connections recycles.
pub fn takeExportBase(self: *Node) !u64 {
    if (self.freed_export_bases.pop(self.allocator)) |base| return base;
    if (self.next_export_base >= self.export_base_end) return session_mod.Error.ExportRangeExhausted;
    const base = self.next_export_base;
    self.next_export_base += export_range_span;
    return base;
}

/// Take a released session's range back for reuse. Registration reserved
/// this exact return slot before the range became session authority, so
/// release is infallible and connection churn cannot spend the node's
/// finite range space under allocator pressure.
pub fn recycleExportBase(self: *Node, base: u64) void {
    std.debug.assert(self.export_base_return_reservations != 0);
    self.freed_export_bases.pushReserved(base);
    self.export_base_return_reservations -= 1;
}
