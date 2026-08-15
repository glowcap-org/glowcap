//! The vat's state-box machinery: one heap block per actor, refcounted for
//! local time-travel (ADR-0060).
//!
//! A `StateBox` heads the single `Boxed` allocation that also carries the
//! behavior's state; a `Cell` is the vat's one owning reference plus the
//! bookkeeping that keeps `become` safe under reentrant near-calls. Snapshots
//! share boxes by refcount (zero bytes copied), copy-on-write clones a shared
//! box the first time a turn would mutate it, and a persistent actor's
//! functional `become` stages a fresh box installed when its outermost frame
//! unwinds. `releaseBox` is the one lifetime chokepoint. The `Vat` re-binds
//! the public verbs (`snapshot`, `restore`); everything else is reached by the
//! sibling vat modules.

const std = @import("std");
const model = @import("model");

const vat_mod = @import("mod.zig");
const Vat = vat_mod.Vat;
const Turn = vat_mod.Turn;
const Message = vat_mod.Message;
const HostedActor = vat_mod.HostedActor;
const Error = vat_mod.Error;

/// Whether a behavior is a *persistent* actor: it never mutates `self` and
/// produces its next state with `Turn.become`, so a snapshot may share its state
/// with no copy-on-write. Opt in with `pub const snapshot_persistent = true;`.
fn behaviorIsPersistent(comptime Behavior: type) bool {
    return @hasDecl(Behavior, "snapshot_persistent") and Behavior.snapshot_persistent;
}

/// A refcounted home for one actor's state. A `Cell` holds a `*StateBox`, and a
/// snapshot shares that pointer instead of copying the bytes behind it. The count
/// is non-atomic because a vat is single-threaded, and an immutable/shared state
/// value never points back at a box, so the graph is acyclic and a plain count
/// frees correctly with no collector. The behavior's identity travels in the box
/// (`handle`/`drop`/`clone`) so a snapshot can rebuild a working cell from a
/// shared box alone. The box is the header of a single `Boxed` heap block that
/// also carries the state (`ptr` points at that trailing field), so an actor's
/// lifetime is one allocation and one free, never a box/state pair.
pub const StateBox = struct {
    ptr: *anyopaque,
    /// Live references: the vat's own cell plus one per snapshot that shares it.
    refs: usize,
    handle: *const fn (state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument,
    /// Free the whole `Boxed` block this box heads, running the state's
    /// `deinit` first. The box and its state are one allocation, so there is
    /// no separate state free.
    drop: *const fn (box: *StateBox, allocator: std.mem.Allocator) void,
    /// Deep-copy this box's state into a fresh `Boxed` block, for copy-on-write.
    /// Null when the actor opted out of cloning; such a box is snapshottable only
    /// if it is `persistent`.
    clone: ?*const fn (box: *const StateBox, allocator: std.mem.Allocator) std.mem.Allocator.Error!*StateBox,
    /// Set at spawn for a persistent actor: its state is never mutated in place,
    /// so copy-on-write is skipped and a snapshot shares it directly.
    persistent: bool,
};

/// The one heap block behind an actor: the refcounted `StateBox` header and the
/// behavior's state, side by side. A spawn, a `become`, and a copy-on-write
/// clone each cost exactly one allocation, and `releaseBox` frees exactly one
/// block through the box's `drop`.
fn Boxed(comptime Behavior: type) type {
    return struct {
        box: StateBox,
        state: Behavior,
    };
}

/// The heap block behind a *hosted* actor (ADR-0071): the refcounted `StateBox`
/// header beside the `HostedActor` the vat calls through. `box.ptr` points at
/// the block, so the box-level `handle` recovers the callback and `ctx` from it.
/// The box carries no `clone`, so such an actor is not snapshottable — the vat
/// cannot copy state it does not own — and copy-on-write already no-ops on a
/// null clone. One allocation, one free through `drop`, like `Boxed`.
const HostedBlock = struct {
    box: StateBox,
    actor: HostedActor,

    fn handle(state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
        const self: *HostedBlock = @ptrCast(@alignCast(state));
        return self.actor.handle(self.actor.ctx, turn, msg);
    }

    fn drop(box: *StateBox, allocator: std.mem.Allocator) void {
        const self: *HostedBlock = @fieldParentPtr("box", box);
        if (self.actor.free) |f| f(self.actor.ctx);
        allocator.destroy(self);
    }
};

/// One actor slot in the vat's heap: a single owning reference to a `StateBox`,
/// plus the bookkeeping that keeps a `become` safe under reentrant near-calls.
pub const Cell = struct {
    box: *StateBox,
    /// Frames currently executing this actor. Near-calls can re-enter the same
    /// actor (a handler near-calls itself, directly or through a cycle), so this
    /// nests. A staged `become` installs only when it returns to zero, so the
    /// box an outer frame still holds as `self` is never freed under it.
    running: u32 = 0,
    /// Explicit roots (ADR-0101): the spawn's own root plus one per rooting
    /// relationship (host-wide alias row, Host capability slot, Port export
    /// binding, exact gift row). The count reaching zero retires the row —
    /// deferred past any running frame — while queued turns deliberately hold
    /// none and take the typed `NoSuchActor` refusal instead.
    roots: u32 = 1,
    /// The next state box, promoted here by a frame that returned successfully
    /// and installed when `running` reaches zero. Last write wins across the
    /// frames of one reentrant run, matching Goblins's last-`bcom`-wins.
    pending_become: ?*StateBox = null,
};

/// A staged `Turn.become`: the next state box, held on the turn until the frame
/// returns. On success it is promoted onto the actor's `Cell`; on a handler
/// error it is discarded, so a failed turn leaves the actor unchanged.
pub const PendingBecome = struct { id: u64, box: *StateBox };

/// Release one reference to `box`, freeing its whole `Boxed` block (state
/// `deinit` included) when the last reference drops. The single chokepoint for
/// box lifetime, shared by the vat and by `Snapshot.deinit` so both count the
/// same way.
pub fn releaseBox(allocator: std.mem.Allocator, box: *StateBox) void {
    box.refs -= 1;
    if (box.refs == 0) box.drop(box, allocator);
}

/// A captured local actor heap: a point-in-time sharing of each actor's
/// `StateBox` (refcount raised, no bytes copied).
/// Reusable across repeated `restore`s. The owner frees it with `deinit`, which
/// drops the snapshot's reference to every shared box. Captures local state
/// only, never `peer`, `exports`, far listeners, or the turn arenas.
pub const Snapshot = struct {
    boxes: std.AutoHashMapUnmanaged(u64, *StateBox) = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        var it = self.boxes.valueIterator();
        while (it.next()) |box| releaseBox(self.allocator, box.*);
        self.boxes.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Allocate a fresh `Boxed` block (`refs = 1`) owning a heap copy of
/// `initial`, wiring the behavior's `handle`/`drop`/`clone` and persistent
/// flavor. The one place a box is born from a value, shared by `spawn` and
/// `become`; the copy-on-write path births its box through the wired
/// `clone`. One allocation total — the merged header + state block. On
/// failure it owns nothing: `initial`'s resources are reclaimed before the
/// error returns.
pub fn makeBox(self: *Vat, comptime Behavior: type, initial: Behavior) Error!*StateBox {
    const Block = Boxed(Behavior);
    const Glue = struct {
        fn handle(erased: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
            // A persistent actor never mutates `self` (that is why a snapshot
            // may share its state with no copy-on-write), so it is dispatched
            // through a `*const` receiver: the ordinary `self.field = x` then
            // fails to compile instead of silently writing through the pointer
            // a live snapshot shares. This enforces shallow immutability only;
            // a persistent actor still must not mutate through an interior
            // pointer it owns, which `*const self` cannot reach.
            if (comptime behaviorIsPersistent(Behavior)) {
                const behavior: *const Behavior = @ptrCast(@alignCast(erased));
                return behavior.handle(turn, msg);
            }
            const behavior: *Behavior = @ptrCast(@alignCast(erased));
            return behavior.handle(turn, msg);
        }
        fn drop(box: *StateBox, allocator: std.mem.Allocator) void {
            const block: *Block = @fieldParentPtr("box", box);
            if (@hasDecl(Behavior, "deinit")) block.state.deinit(allocator);
            allocator.destroy(block);
        }
        fn clone(box: *const StateBox, allocator: std.mem.Allocator) std.mem.Allocator.Error!*StateBox {
            // Reached only when `clone` was wired below, i.e. the actor
            // defines it; the guard keeps the body compilable for actors
            // that do not.
            if (@hasDecl(Behavior, "clone")) {
                const behavior: *const Behavior = @ptrCast(@alignCast(box.ptr));
                const fresh = try allocator.create(Block);
                errdefer allocator.destroy(fresh);
                // The by-value clone contract: the state's `clone` builds
                // the next value, and the vat moves it into the fresh
                // block, so the clone path is also one allocation.
                fresh.state = try behavior.clone(allocator);
                fresh.box = .{
                    .ptr = @ptrCast(&fresh.state),
                    .refs = 1,
                    .handle = box.handle,
                    .drop = box.drop,
                    .clone = box.clone,
                    .persistent = box.persistent,
                };
                return &fresh.box;
            }
            unreachable;
        }
    };

    const block = self.allocator.create(Block) catch |e| {
        // `initial` was never moved into heap state, but the contract still
        // promises its resources are reclaimed. `initial` is a by-value
        // parameter, so take a mutable local to reach its `deinit`.
        var orphan = initial;
        if (@hasDecl(Behavior, "deinit")) orphan.deinit(self.allocator);
        return e;
    };
    block.state = initial;
    block.box = .{
        .ptr = @ptrCast(&block.state),
        .refs = 1,
        .handle = Glue.handle,
        .drop = Glue.drop,
        .clone = if (@hasDecl(Behavior, "clone")) Glue.clone else null,
        .persistent = behaviorIsPersistent(Behavior),
    };
    return &block.box;
}

pub fn makeHostedBox(self: *Vat, hosted: HostedActor) Error!*StateBox {
    const block = self.allocator.create(HostedBlock) catch |e| {
        // The box was never built, but the contract promises `ctx` is
        // reclaimed on failure, mirroring how `spawn` reclaims a native
        // `initial` through its `deinit`.
        if (hosted.free) |f| f(hosted.ctx);
        return e;
    };
    block.actor = hosted;
    block.box = .{
        .ptr = @ptrCast(block),
        .refs = 1,
        .handle = HostedBlock.handle,
        .drop = HostedBlock.drop,
        .clone = null,
        .persistent = false,
    };
    return &block.box;
}

/// Copy-on-write: if `cell`'s box is shared with a snapshot, deep-clone its
/// state into a fresh box before the turn that is about to run can mutate it,
/// so the snapshot's copy is never touched. A persistent box is skipped — it is
/// never mutated in place — and an unshared box (`refs == 1`) costs nothing.
/// Conservative by necessity: a read-only near-call to a shared mutable actor
/// still clones, because mutable `self` hides reads from writes.
pub fn ensureUnshared(self: *Vat, cell: *Cell) Error!void {
    const box = cell.box;
    if (box.persistent or box.refs == 1) return;
    // A shared, non-persistent box can only exist because `snapshot`
    // admitted it, and `snapshot` refuses a clone-less mutable box
    // (`NotSnapshottable`) — so `clone` is non-null here by invariant.
    // Failing loud is load-bearing: returning instead would silently
    // mutate state a live snapshot shares.
    const clone_fn = box.clone orelse unreachable;
    // The wired `clone` builds the whole fresh `Boxed` block (state cloned
    // by value into it), so the copy costs one block allocation.
    const new_box = try clone_fn(box, self.allocator);
    // Drop this cell's reference to the shared box (the snapshot keeps it
    // alive, so this never frees it) and point the cell at the private copy.
    box.refs -= 1;
    cell.box = new_box;
}

/// Stage `next` as the running actor's pending become (see `Turn.become`).
pub fn stageBecome(self: *Vat, turn: *Turn, comptime Behavior: type, next: Behavior) Error!void {
    const id = switch (turn.self_ref) {
        .local => |a| a,
        .far => return Error.NotLocal,
    };
    const box = try makeBox(self, Behavior, next);
    errdefer releaseBox(self.allocator, box);
    // Reserve the slots the installs will need to retire their outgoing boxes.
    // An install runs during frame unwind, which cannot fail, so the room has to
    // be taken here where a failure is still the caller's to see.
    //
    // One slot is not enough. Every frame open right now can hold a staged
    // become, and none of them has installed yet, so they all see the same list
    // length: reserving one slot per stage reserves one slot in total, and the
    // unwind then appends once per frame. An actor installs at most once per
    // run and every install is preceded by a stage in some open frame, so the
    // number of appends still to come is bounded by the open frame count.
    try vat_mod.reserveRetirementCapacity(self, 0, self.turn_depth);
    // Last become in a turn wins: release any value staged earlier this turn.
    if (turn.pending_become) |prev| releaseBox(self.allocator, prev.box);
    turn.pending_become = .{ .id = id, .box = box };
}

/// Promote a successful frame's staged become onto the actor's `Cell`, to be
/// installed when the actor's outermost running frame unwinds. Last write
/// wins across the frames of one reentrant run: an earlier promoted box that
/// never installed is released here.
pub fn promoteBecome(self: *Vat, pending: PendingBecome) void {
    // A running actor is never removed — the same invariant `callLocal`'s
    // reload already banks on, held loud in all three places it matters.
    const cell = self.actors.getPtr(pending.id).?;
    if (cell.pending_become) |prev| releaseBox(self.allocator, prev);
    cell.pending_become = pending.box;
}

/// Whether the vat is idle: no turn or drive in flight and no queued sends.
/// `snapshot` and `restore` require it, so time-travel never captures or
/// rewinds a half-mutated heap.
fn quiescent(self: *const Vat) bool {
    return self.turn_depth == 0 and self.drive_depth == 0 and self.runnable_head == null;
}

/// Capture the local actor heap: share every actor's `StateBox` (refcount up,
/// no bytes copied, O(objects), Goblins's `snapshot-whactormap` shape) and
/// Requires quiescence (`NotQuiescent`) and every
/// actor to be cloneable or persistent (`NotSnapshottable`); on either failure
/// nothing is left shared. The returned `Snapshot` is the owner's to `deinit`.
pub fn snapshot(self: *Vat) Error!Snapshot {
    if (!quiescent(self)) return Error.NotQuiescent;
    var snap = Snapshot{ .allocator = self.allocator };
    errdefer snap.deinit();
    var it = self.actors.iterator();
    while (it.next()) |entry| {
        const box = entry.value_ptr.box;
        if (box.clone == null and !box.persistent) return Error.NotSnapshottable;
        try snap.boxes.put(self.allocator, entry.key_ptr.*, box);
        box.refs += 1;
    }
    return snap;
}

/// Rewind the local actor heap to `snap`: re-point every actor at the
/// snapshot's shared boxes. Requires quiescence. The
/// new table is built (sharing the snapshot's boxes) before the live boxes are
/// released, so a mid-build failure leaves the live heap intact. `snap` stays
/// reusable across repeated restores. Touches local actor state only, never
/// the peer, exports, far listeners, or arenas.
pub fn restore(self: *Vat, snap: *const Snapshot) Error!void {
    if (!quiescent(self)) return Error.NotQuiescent;
    var rebuilt: std.AutoHashMapUnmanaged(u64, Cell) = .{};
    errdefer {
        var rit = rebuilt.valueIterator();
        while (rit.next()) |cell| releaseBox(self.allocator, cell.box);
        rebuilt.deinit(self.allocator);
    }
    var sit = snap.boxes.iterator();
    while (sit.next()) |entry| {
        // Intersect with the live table (ADR-0101): roots are authority and
        // are never rewound, so a row reclaimed since the snapshot is not
        // resurrected — no surviving authority could reach it, and a rootless
        // row would be exactly the leak reclamation removes — while a
        // surviving row keeps its current count and takes the snapshot state.
        const current = self.actors.getPtr(entry.key_ptr.*) orelse continue;
        try rebuilt.put(self.allocator, entry.key_ptr.*, .{ .box = entry.value_ptr.*, .roots = current.roots });
        entry.value_ptr.*.refs += 1;
    }
    // Commit: the rebuilt table is fully built and ref-counted, so releasing
    // the live boxes and swapping cannot fail.
    var lit = self.actors.valueIterator();
    while (lit.next()) |cell| releaseBox(self.allocator, cell.box);
    self.actors.deinit(self.allocator);
    self.actors = rebuilt;
    // `next_actor` is deliberately *not* rewound. An actor id is what the
    // export table maps a wire position to, and that table is not part of a
    // snapshot: rewinding it would rewind authority a partner already holds,
    // which is not local state. But rewinding only the counter is worse than
    // either choice, because the next spawn then takes an id a live export
    // still names, and the partner's capability quietly reaches a different
    // object. Leaving the counter alone costs nothing but reproducible ids
    // across repeated restores, which nothing relies on.
}
