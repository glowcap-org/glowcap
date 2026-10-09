//! Per-ingress queue admission, fair scheduling, cancellation, and driving.

const std = @import("std");
const model = @import("model");
const turn_mod = @import("turn.zig");
const vat_mod = @import("mod.zig");
const vows_mod = @import("vows.zig");

const Vat = vat_mod.Vat;
const Port = vat_mod.Port;
const Ref = vat_mod.Ref;
const Vow = vat_mod.Vow;
const Message = vat_mod.Message;
const Delivery = @import("behavior.zig").Delivery;
const Resolution = vat_mod.Resolution;
const Error = vat_mod.Error;
const IngressCancellationError = vat_mod.IngressCancellationError;
const steady_list_bytes = vat_mod.steady_list_bytes;
const steady_spare_arena_bytes = vat_mod.steady_spare_arena_bytes;

/// One causal source of queued turns. `.local` is the pure-local/application
/// source; a composed Host mints one additional id per session Port. The Vat
/// owns ids so two adapters cannot accidentally share accounting.
pub const IngressId = enum(u32) {
    local = 0,
    _,
};

/// Atomic admission limits for each ingress. `max_pending_bytes` charges the
/// exact requested payload bytes of the owned message clone plus its queue row;
/// allocator metadata and bounded chunk slack are held separately by footprint
/// tests. A single message must also fit `max_chunk_bytes`, so no exceptional
/// oversized chunk bypasses incremental reclamation.
pub const QueueLimits = struct {
    max_pending_turns: u32 = 4096,
    max_pending_bytes: u32 = 1024 * 1024,
    max_chunk_bytes: u32 = 64 * 1024,
};

const Queued = struct {
    target: u64,
    msg: Delivery,
    vow: u64,
    charged_bytes: u32,
    answered: bool,
    /// Port whose authority caused this turn, or null for pure-local work.
    port: ?*Port,
};

/// Queue metadata is bounded independently of message payload. A chunk owns
/// one arena for at most this many turns and is released as soon as its last
/// turn finishes, even while other ingress work remains.
const queue_chunk_turns = @max(1, steady_list_bytes / @sizeOf(Queued));

pub const QueueChunk = struct {
    next: ?*QueueChunk = null,
    arena: std.heap.ArenaAllocator,
    items: [queue_chunk_turns]Queued = undefined,
    head: usize = 0,
    len: usize = 0,
    owned_bytes: u32 = 0,
    /// Turns currently borrowing messages from this chunk. A nested drive may
    /// exhaust the remaining rows while an outer handler still reads an earlier
    /// row, so exhaustion detaches the chunk but reclamation waits for this to
    /// reach zero.
    active_turns: u32 = 0,
};

pub const IngressState = struct {
    id: IngressId,
    first: ?*QueueChunk = null,
    last: ?*QueueChunk = null,
    pending_turns: u32 = 0,
    pending_bytes: u32 = 0,
    active_turns: u32 = 0,
    /// Intrusive runnable ring, doubly linked so a budgeted drive can unlink
    /// one exact ingress in O(1) instead of walking from the head; with one
    /// shared Vat per Host the ring is every session with pending local work.
    runnable_next: ?*IngressState = null,
    runnable_prev: ?*IngressState = null,
    runnable: bool = false,
};

/// Local sends a running outermost turn made on one ingress (ADR-0191). They
/// hold admission in `turns`/`bytes` but sit outside the queue, so no drive
/// sees them until the turn commits. The Vat keeps these, not the ingress: a
/// turn's sends go to its own causal ingress, so the list is almost always one
/// entry, and no session pays for staging it is not doing.
pub const StagedIngress = struct {
    state: *IngressState,
    first: ?*QueueChunk = null,
    last: ?*QueueChunk = null,
    turns: u32 = 0,
    bytes: u32 = 0,
};

fn findStaged(self: *Vat, state: *const IngressState) ?*StagedIngress {
    for (self.staged.items) |*entry| {
        if (entry.state == state) return entry;
    }
    return null;
}

pub fn ingressState(self: *Vat, ingress: IngressId) Error!*IngressState {
    if (ingress == .local) return &self.local_ingress;
    return self.ingresses.get(ingress) orelse Error.UnknownIngress;
}

/// Retained preparations must observe cancellation even when no turn is ready.
pub fn hasIngress(self: *const Vat, ingress: IngressId) bool {
    return ingress == .local or self.ingresses.contains(ingress);
}

fn acquireQueueChunk(self: *Vat) std.mem.Allocator.Error!*QueueChunk {
    if (self.spare_chunk) |chunk| {
        self.spare_chunk = null;
        const arena = chunk.arena;
        chunk.* = .{ .arena = arena };
        return chunk;
    }
    const chunk = try self.allocator.create(QueueChunk);
    chunk.* = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
    return chunk;
}

fn releaseQueueChunk(self: *Vat, chunk: *QueueChunk) void {
    std.debug.assert(chunk.next == null);
    std.debug.assert(chunk.active_turns == 0);
    if (self.spare_chunk == null) {
        _ = chunk.arena.reset(.{ .retain_with_limit = steady_spare_arena_bytes });
        const arena = chunk.arena;
        chunk.* = .{ .arena = arena };
        self.spare_chunk = chunk;
        return;
    }
    chunk.arena.deinit();
    self.allocator.destroy(chunk);
}

pub fn freeIngressQueue(self: *Vat, state: *IngressState) void {
    freeChunks(self, state.first, "vat released");
    state.first = null;
    state.last = null;
    state.pending_turns = 0;
    state.pending_bytes = 0;
}

fn freeChunks(self: *Vat, head: ?*QueueChunk, reason: []const u8) void {
    var maybe_chunk = head;
    while (maybe_chunk) |chunk| {
        maybe_chunk = chunk.next;
        for (chunk.items[chunk.head..chunk.len]) |*queued|
            queued.msg.retire(reason);
        chunk.arena.deinit();
        self.allocator.destroy(chunk);
    }
}

/// Move one ingress's staged sends onto its queue. Admission already ran, so
/// this cannot fail.
pub fn commitStaged(self: *Vat, entry: StagedIngress) void {
    const state = entry.state;
    const first = entry.first orelse return;
    if (state.last) |last| last.next = first else state.first = first;
    state.last = entry.last;
    state.pending_turns += entry.turns;
    state.pending_bytes += entry.bytes;
    makeRunnable(self, state);
}

/// Discard one ingress's staged sends and break their vows with `reason`.
pub fn dropStaged(self: *Vat, entry: StagedIngress, reason: []const u8) void {
    var maybe_chunk = entry.first;
    while (maybe_chunk) |chunk| {
        maybe_chunk = chunk.next;
        chunk.next = null;
        for (chunk.items[chunk.head..chunk.len]) |*queued| {
            queued.msg.retire(reason);
            vows_mod.settleLocalPrepared(self, queued.vow, .{ .broken = reason });
        }
        releaseQueueChunk(self, chunk);
    }
}

/// Free staged sends without settling them, for a Vat torn down mid-turn.
pub fn discardStaged(self: *Vat, entry: StagedIngress) void {
    freeChunks(self, entry.first, "vat released");
}

fn makeRunnable(self: *Vat, state: *IngressState) void {
    if (state.runnable or state.pending_turns == 0) return;
    state.runnable = true;
    state.runnable_next = null;
    state.runnable_prev = self.runnable_tail;
    if (self.runnable_tail) |tail| tail.runnable_next = state else self.runnable_head = state;
    self.runnable_tail = state;
}

/// Unlink one runnable ingress wherever it sits in the ring.
fn unlinkRunnable(self: *Vat, state: *IngressState) void {
    if (state.runnable_prev) |prev| prev.runnable_next = state.runnable_next else self.runnable_head = state.runnable_next;
    if (state.runnable_next) |next| next.runnable_prev = state.runnable_prev else self.runnable_tail = state.runnable_prev;
    state.runnable_next = null;
    state.runnable_prev = null;
    state.runnable = false;
}

fn takeRunnable(self: *Vat) ?*IngressState {
    const state = self.runnable_head orelse return null;
    unlinkRunnable(self, state);
    return state;
}

fn takeSpecificRunnable(self: *Vat, wanted: *IngressState) bool {
    if (!wanted.runnable) return false;
    unlinkRunnable(self, wanted);
    return true;
}

fn finishQueueTurn(self: *Vat, chunk: *QueueChunk) void {
    std.debug.assert(chunk.active_turns > 0);
    chunk.active_turns -= 1;
    if (chunk.head == chunk.len and chunk.active_turns == 0) releaseQueueChunk(self, chunk);
}

/// Mint a non-local ingress row. Each Host Port owns one such id; a pure-local
/// caller may use several to isolate admission and scheduling.
pub fn openIngress(self: *Vat) Error!IngressId {
    try self.admitMutation();
    if (self.next_ingress == std.math.maxInt(u32)) return Error.ResourceExhausted;
    const id: IngressId = @fromBackingInt(@intCast(self.next_ingress));
    const state = try self.allocator.create(IngressState);
    errdefer self.allocator.destroy(state);
    state.* = .{ .id = id };
    try self.ingresses.put(self.allocator, id, state);
    self.next_ingress += 1;
    return id;
}

/// Release an empty, inactive non-local ingress. Pending or running work is
/// authority: closing it early would erase accounting and reorder turns.
pub fn closeIngress(self: *Vat, ingress: IngressId) Error!void {
    try self.admitMutation();
    if (ingress == .local) return Error.IngressBusy;
    const state = self.ingresses.get(ingress) orelse return Error.UnknownIngress;
    if (state.pending_turns != 0 or state.active_turns != 0 or state.runnable) return Error.IngressBusy;
    std.debug.assert(state.first == null and state.last == null);
    std.debug.assert(self.ingresses.remove(ingress));
    self.allocator.destroy(state);
}

/// Roll back the exact ingress returned by `openIngress` when its owning
/// transaction fails before publishing the ingress or admitting work.
/// Unlike `closeIngress`, this is an infallible undo primitive: the caller
/// still owns the fresh row exclusively, so absence or queued work is an
/// internal transaction bug rather than a runtime failure to reinterpret.
pub fn discardFreshIngress(self: *Vat, ingress: IngressId) void {
    std.debug.assert(!self.queue_copy_active);
    std.debug.assert(ingress != .local);
    const removed = self.ingresses.fetchRemove(ingress) orelse unreachable;
    const state = removed.value;
    std.debug.assert(state.pending_turns == 0);
    std.debug.assert(state.active_turns == 0);
    std.debug.assert(!state.runnable);
    std.debug.assert(state.runnable_next == null);
    std.debug.assert(state.first == null and state.last == null);
    self.allocator.destroy(state);
}

/// Tear down a session ingress that can no longer run. It is removed from
/// admission and fair scheduling before listeners fire, so a break handler
/// cannot enqueue fresh work onto the closing Port. Every queued local vow
/// settles broken; unobserved turns are discarded with their chunk.
pub fn cancelIngress(self: *Vat, ingress: IngressId, reason: []const u8) IngressCancellationError!void {
    try self.admitMutation();
    if (ingress == .local) return error.IngressBusy;
    const state = self.ingresses.get(ingress) orelse return error.UnknownIngress;
    // A running turn's staged sends still point at this ingress.
    if (state.active_turns != 0 or findStaged(self, state) != null) return error.IngressBusy;
    std.debug.assert(self.ingresses.remove(ingress));

    _ = takeSpecificRunnable(self, state);

    cancelQueued(self, state, reason);
    self.allocator.destroy(state);
}

/// Terminal cleanup of trusted local work. Session cancellation has the same
/// queue owner but additionally removes its ingress row and runnable entry.
pub fn cancelLocalIngress(self: *Vat, reason: []const u8) IngressCancellationError!void {
    try self.admitMutation();
    const state = &self.local_ingress;
    if (state.active_turns != 0 or findStaged(self, state) != null) return error.IngressBusy;
    _ = takeSpecificRunnable(self, state);
    cancelQueued(self, state, reason);
}

fn cancelQueued(self: *Vat, state: *IngressState, reason: []const u8) void {
    // Detach custody before callbacks. The trusted local ingress remains
    // addressable, so callback-created work must own a separate queue even
    // when its listener immediately opens a nested drive.
    const cancelled = state.first;
    state.first = null;
    state.last = null;
    state.pending_turns = 0;
    state.pending_bytes = 0;
    var maybe_chunk = cancelled;
    while (maybe_chunk) |chunk| : (maybe_chunk = chunk.next) {
        std.debug.assert(chunk.active_turns == 0);
        for (chunk.items[chunk.head..chunk.len]) |*queued| {
            queued.msg.retire(reason);
            std.debug.assert(self.pending_local_vows.remove(.{ .id = queued.vow }));
            if (self.listeners.fetchRemove(queued.vow)) |entry|
                entry.value.func(entry.value.ctx, .{ .broken = reason });
        }
    }
    freeChunks(self, cancelled, reason);
}

/// Local eventual send (`<-`). A local target queues a turn for `drive`;
/// a far target is refused because only a session `Port` knows which peer
/// should receive the `op:deliver`. Returns a `Vow` for the result. The
/// message's verb and args are borrowed only for the duration of this call:
/// the local arm clones them into one ingress queue chunk.
pub fn send(self: *Vat, target: Ref, msg: Message) Error!Vow {
    return sendFromIngress(self, .local, target, msg);
}

/// Admit a queued call and its completion observer atomically. Cancellation
/// invokes the same observer, so an external continuation can retire its pins.
pub fn sendObservedFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message, listener: vat_mod.Listener) Error!Vow {
    try vows_mod.reserveLocalListener(self);
    const vow = try sendFromIngress(self, ingress, target, msg);
    vows_mod.onReservedLocal(self, vow.local, listener);
    return vow;
}

pub fn sendFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!Vow {
    _ = try ingressState(self, ingress);
    switch (target) {
        .local => |id| return .{ .local = try enqueueLocal(self, ingress, null, id, msg, true) },
        .far => return Error.NotConnected,
    }
}

/// The fire-and-forget eventual-send (Goblins `<-np`): like `send`, but it
/// requests no answer, so the partner's actor runs and sends no reply. A far
/// `tell` puts one `op:deliver` with no answer on the wire. That is the
/// right shape for a notification or broadcast, which would otherwise pay for
/// a reply nobody reads. A local `tell` queues a turn whose result is
/// discarded. Returns nothing: there is no vow to observe.
pub fn tell(self: *Vat, target: Ref, msg: Message) Error!void {
    return tellFromIngress(self, .local, target, msg);
}

pub fn tellFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!void {
    _ = try ingressState(self, ingress);
    switch (target) {
        // Queue a turn like `send`, but discard the vow id: it keeps the
        // queue entry uniform and `drive` settles it into no listener.
        .local => |id| _ = try enqueueLocal(self, ingress, null, id, msg, false),
        .far => return Error.NotConnected,
    }
}

/// The one local-enqueue spine `send` and `tell` share. Admission computes
/// the whole logical ownership charge before cloning; every mutation after
/// a successful clone is infallible, so refusal never partially enqueues.
pub fn enqueueLocal(self: *Vat, ingress: IngressId, port: ?*Port, id: u64, msg: Message, answered: bool) Error!u64 {
    return enqueue(self, ingress, port, id, .{ .message = msg }, answered);
}

/// Admit an adapter-owned local message and its listener on the same queue as
/// ordinary sends. Observer lifetime and payload custody are separate.
pub fn sendOpaqueFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: vat_mod.OpaqueMessage, listener: vat_mod.Listener) Error!Vow {
    const id = switch (target) {
        .local => |id| id,
        .far => return Error.NotConnected,
    };
    try vows_mod.reserveLocalListener(self);
    const vow = try enqueueOpaque(self, ingress, id, msg, true);
    vows_mod.onReservedLocal(self, vow, listener);
    return .{ .local = vow };
}

/// An unanswered adapter delivery owns its queue payload, without a listener
/// or reply owner. Rollback and retirement follow the same ingress transaction.
pub fn tellOpaqueFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: vat_mod.OpaqueMessage) Error!void {
    const id = switch (target) {
        .local => |id| id,
        .far => return Error.NotConnected,
    };
    _ = try enqueueOpaque(self, ingress, id, msg, false);
}

/// Queue custody is independent of whether a caller observes an answer.
pub fn enqueueOpaque(self: *Vat, ingress: IngressId, id: u64, msg: vat_mod.OpaqueMessage, answered: bool) Error!u64 {
    return enqueue(self, ingress, null, id, .{ .owned = msg }, answered);
}

fn enqueue(self: *Vat, ingress: IngressId, port: ?*Port, id: u64, msg: Delivery, answered: bool) Error!u64 {
    try self.admitMutation();
    const state = try ingressState(self, ingress);
    try vat_mod.ensureFreshId(self.next_vow);
    const payload_bytes = switch (msg) {
        .message => |message| bytes: {
            const args = model.measureArgumentSliceOwnedBytes(message.args) catch return Error.MalformedView;
            break :bytes std.math.add(usize, message.verb.len, args) catch return Error.ResourceExhausted;
        },
        .owned => |body| body.owned_bytes,
    };
    const charge = std.math.add(usize, @sizeOf(Queued), payload_bytes) catch return Error.ResourceExhausted;
    const limits = self.queue_limits;
    if (charge > limits.max_chunk_bytes or charge > std.math.maxInt(u32)) return Error.ResourceExhausted;
    const charge32: u32 = @intCast(charge);
    // Inside a turn the send waits for the turn to commit (ADR-0191). Staged
    // sends count against the same limits, so committing them can never
    // overrun the queue.
    const staging = self.turn_depth != 0;
    var slot: ?*StagedIngress = if (staging) findStaged(self, state) else null;
    const held_turns = state.pending_turns + if (slot) |entry| entry.turns else 0;
    const held_bytes = state.pending_bytes + if (slot) |entry| entry.bytes else 0;
    if (held_turns >= limits.max_pending_turns) return Error.ResourceExhausted;
    if (held_bytes > limits.max_pending_bytes or charge32 > limits.max_pending_bytes - held_bytes)
        return Error.ResourceExhausted;
    try self.pending_local_vows.ensureUnusedCapacity(self.allocator, 1);
    if (staging and slot == null) try self.staged.ensureUnusedCapacity(self.allocator, 1);

    var chunk = if (staging) (if (slot) |entry| entry.last else null) else state.last;
    var acquired = false;
    if (chunk == null or chunk.?.len == queue_chunk_turns or
        chunk.?.owned_bytes > limits.max_chunk_bytes - charge32)
    {
        chunk = try acquireQueueChunk(self);
        acquired = true;
    }
    const owned = cloneForQueue(self, chunk.?, msg) catch |err| {
        if (acquired) releaseQueueChunk(self, chunk.?);
        return err;
    };
    const vow = self.next_vow;
    if (staging and slot == null) {
        self.staged.appendAssumeCapacity(.{ .state = state });
        slot = &self.staged.items[self.staged.items.len - 1];
    }
    if (acquired) {
        if (staging) {
            const entry = slot.?;
            if (entry.last) |last| last.next = chunk else entry.first = chunk;
            entry.last = chunk;
        } else {
            if (state.last) |last| last.next = chunk else state.first = chunk;
            state.last = chunk;
        }
    }
    chunk.?.items[chunk.?.len] = .{ .target = id, .msg = owned, .vow = vow, .charged_bytes = charge32, .answered = answered, .port = port };
    chunk.?.len += 1;
    chunk.?.owned_bytes += charge32;
    if (staging) {
        slot.?.turns += 1;
        slot.?.bytes += charge32;
    } else {
        state.pending_turns += 1;
        state.pending_bytes += charge32;
    }
    self.pending_local_vows.putAssumeCapacity(.{ .id = vow }, {});
    if (!staging) makeRunnable(self, state);
    self.next_vow += 1;
    return vow;
}

/// Clone `msg` into its vat-owned queue chunk: the one named boundary copy
/// of the local eventual-send path, symmetric with the far path's clone
/// inside `peer.sendCopying`. A queued message must outlive the sender's
/// turn — the drive that runs it begins by resetting the very turn arena
/// the documented handler pattern builds outgoing args in — so the queue
/// owns its bytes. Its chunk is reclaimed immediately after that chunk's
/// last turn, independent of every other ingress.
fn cloneForQueue(self: *Vat, chunk: *QueueChunk, msg: Delivery) Error!Delivery {
    std.debug.assert(!self.queue_copy_active);
    self.queue_copy_active = true;
    defer self.queue_copy_active = false;
    const arena = chunk.arena.allocator();
    return switch (msg) {
        .message => |message| .{ .message = .{
            .verb = try arena.dupe(u8, message.verb),
            .args = try model.cloneArgumentSlice(arena, message.args),
        } },
        .owned => |body| switch (body.vtable.copy(body.ctx, arena)) {
            .copied => |copy| .{ .owned = copy },
            .refused => |failure| failure.toError(),
        },
    };
}

/// The outcome of a budgeted drive: whether the local queue emptied.
pub const DriveProgress = enum {
    /// Every ingress queue drained fully within the budget.
    drained,
    /// The budget was spent with turns still queued. The next call resumes
    /// at the head of the fair runnable ring.
    more_pending,
};

/// Run queued local eventual-sends to quiescence, settling each vow with
/// the handler's value (or a break on error) and firing its listener. Turns
/// queued by a turn run in the same drive. FIFO holds within one ingress;
/// runnable ingresses rotate one turn at a time.
pub fn drive(self: *Vat) Error!void {
    _ = try driveBudgeted(self, std.math.maxInt(usize));
}

/// Like `drive`, but runs at most `max_turns` queued local turns, then
/// yields `.more_pending` with every ingress queue intact (a later call
/// resumes at the fair ring head). A vat whose handlers re-send to
/// themselves without bound makes `drive` never return; on a loop host
/// that would starve every other connection the loop serves. `driveBudgeted`
/// gives the loop host a bound to act on: it drives each inbound batch to
/// `.drained` and treats `.more_pending` as a runaway amplification, closing
/// that connection. The connection-per-thread
/// `BlockingSession` keeps the unbounded `drive` by contract: it serves one
/// partner, so a self-send chain there starves only itself.
///
/// Call this at the top level (the loop host's per-connection drive point),
/// not re-entrantly: a nested full `drive` a listener opens runs to
/// quiescence by its own contract, draining past this budget.
pub fn driveBudgeted(self: *Vat, max_turns: usize) Error!DriveProgress {
    try self.admitMutation();
    // A *finite* budget must not nest (the documented contract above): a
    // nested full `drive` (a listener's) is legal and runs unbudgeted.
    std.debug.assert(max_turns == std.math.maxInt(usize) or self.drive_depth == 0);
    self.drive_depth += 1;
    defer self.drive_depth -= 1;
    var ran: usize = 0;
    while (ran < max_turns) {
        const state = takeRunnable(self) orelse break;
        ran += 1;
        try runQueuedTurn(self, state);
    }
    return if (self.runnable_head == null) .drained else .more_pending;
}

/// Drive only one causal ingress. A Host invokes this at a Port's batch
/// boundary so work enqueued onto a sibling remains attributed to that
/// sibling's own budget and close policy.
pub fn driveIngressBudgeted(self: *Vat, ingress: IngressId, max_turns: usize) Error!DriveProgress {
    try self.admitMutation();
    std.debug.assert(max_turns == std.math.maxInt(usize) or self.drive_depth == 0);
    const state = try ingressState(self, ingress);
    self.drive_depth += 1;
    defer self.drive_depth -= 1;
    var ran: usize = 0;
    while (ran < max_turns and takeSpecificRunnable(self, state)) : (ran += 1)
        try runQueuedTurn(self, state);
    return if (state.pending_turns == 0) .drained else .more_pending;
}

fn runQueuedTurn(self: *Vat, state: *IngressState) Error!void {
    const chunk = state.first orelse unreachable;
    std.debug.assert(chunk.head < chunk.len);
    var queued = chunk.items[chunk.head];
    chunk.head += 1;
    state.pending_turns -= 1;
    state.pending_bytes -= queued.charged_bytes;
    if (chunk.head == chunk.len) {
        state.first = chunk.next;
        if (state.first == null) state.last = null;
        chunk.next = null;
    }
    // Rotate before running the handler. A nested drive therefore sees
    // the next ingress, while a causal send from this turn appends this
    // ingress once at the tail if it had become empty.
    makeRunnable(self, state);
    state.active_turns += 1;
    chunk.active_turns += 1;
    const resolution = turn_mod.callQueued(self, queued.port, state.id, queued.target, queued.msg, if (queued.answered) queued.vow else null);
    if (resolution) |settled| {
        const retirement = if (queued.msg == .owned) &queued.msg else null;
        vows_mod.settleLocalWithRetirement(self, queued.vow, settled, retirement) catch |err| {
            state.active_turns -= 1;
            finishQueueTurn(self, chunk);
            return err;
        };
    }
    queued.msg.retire(null);
    state.active_turns -= 1;
    finishQueueTurn(self, chunk);
}
